import Foundation
import GoogleSignIn
import UIKit

struct YouTubeOwnedPlaylist: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let itemCount: Int

    var url: URL? {
        var components = URLComponents(string: "https://www.youtube.com/playlist")
        components?.queryItems = [URLQueryItem(name: "list", value: id)]
        return components?.url
    }
}

enum YouTubeOwnedPlaylistStore {
    private static let storageKey = "jarvis.youtube.ownedPlaylists"

    static func load() -> [YouTubeOwnedPlaylist] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let playlists = try? JSONDecoder().decode([YouTubeOwnedPlaylist].self, from: data) else {
            return []
        }
        return playlists
    }

    static func save(_ playlists: [YouTubeOwnedPlaylist]) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func playlist(named requestedName: String) -> YouTubeOwnedPlaylist? {
        let requested = normalized(requestedName)
        guard !requested.isEmpty else { return nil }
        let playlists = load()
        return playlists.first(where: { normalized($0.title) == requested })
            ?? playlists.first(where: {
                normalized($0.title).contains(requested) || requested.contains(normalized($0.title))
            })
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

@MainActor
final class YouTubeAccountService: ObservableObject {
    static let shared = YouTubeAccountService()

    private static let readOnlyScope = "https://www.googleapis.com/auth/youtube.readonly"

    @Published private(set) var accountName: String?
    @Published private(set) var playlists = YouTubeOwnedPlaylistStore.load()
    @Published private(set) var statusMessage = "Google 계정을 연결하지 않았습니다."
    @Published private(set) var isWorking = false
    @Published var connectionAlertMessage: String?

    var isSignedIn: Bool { GIDSignIn.sharedInstance.currentUser != nil }

    private init() {}

    func restoreSession() {
        guard configureGoogleSignIn() else { return }
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            statusMessage = "Google 계정을 연결하지 않았습니다."
            return
        }

        isWorking = true
        Task {
            do {
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                accountName = user.profile?.email ?? user.profile?.name
                try await synchronize(using: user)
            } catch {
                isWorking = false
                statusMessage = "Google 로그인 복원 실패: \(error.localizedDescription)"
            }
        }
    }

    func signIn() {
        guard configureGoogleSignIn(showAlert: true),
              let presenter = UIApplication.shared.jarvisTopViewController else {
            if UIApplication.shared.jarvisTopViewController == nil {
                let message = "Google 로그인 화면을 열 수 없습니다. 화면을 닫았다가 다시 열어주세요."
                statusMessage = message
                connectionAlertMessage = message
            }
            return
        }

        isWorking = true
        Task {
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                var user = result.user
                if !(user.grantedScopes ?? []).contains(Self.readOnlyScope) {
                    user = try await user.addScopes([Self.readOnlyScope], presenting: presenter).user
                }
                accountName = user.profile?.email ?? user.profile?.name
                try await synchronize(using: user)
            } catch {
                isWorking = false
                let message = "Google 로그인 실패: \(error.localizedDescription)"
                statusMessage = message
                connectionAlertMessage = message
            }
        }
    }

    func synchronize() {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            statusMessage = "먼저 Google 계정을 연결해주세요."
            return
        }

        isWorking = true
        Task {
            do {
                try await synchronize(using: user)
            } catch {
                isWorking = false
                statusMessage = "재생목록 동기화 실패: \(error.localizedDescription)"
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        accountName = nil
        playlists = []
        YouTubeOwnedPlaylistStore.clear()
        statusMessage = "Google 계정 연결을 해제했습니다."
    }

    func freshAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw YouTubeAccountError.notSignedIn
        }
        let refreshedUser = try await user.refreshTokensIfNeeded()
        return refreshedUser.accessToken.tokenString
    }

    private func synchronize(using user: GIDGoogleUser) async throws {
        let authorizedUser: GIDGoogleUser
        if (user.grantedScopes ?? []).contains(Self.readOnlyScope) {
            authorizedUser = user
        } else {
            guard let presenter = UIApplication.shared.jarvisTopViewController else {
                throw YouTubeAccountError.noPresenter
            }
            authorizedUser = try await user.addScopes([Self.readOnlyScope], presenting: presenter).user
        }

        let refreshedUser = try await authorizedUser.refreshTokensIfNeeded()
        let fetched = try await fetchOwnedPlaylists(accessToken: refreshedUser.accessToken.tokenString)
        YouTubeOwnedPlaylistStore.save(fetched)
        playlists = fetched
        accountName = refreshedUser.profile?.email ?? refreshedUser.profile?.name
        isWorking = false
        statusMessage = fetched.isEmpty
            ? "직접 만든 YouTube 재생목록이 없습니다."
            : "직접 만든 재생목록 \(fetched.count)개를 동기화했습니다."
    }

    private func fetchOwnedPlaylists(accessToken: String) async throws -> [YouTubeOwnedPlaylist] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Snippet: Decodable { let title: String }
                struct ContentDetails: Decodable { let itemCount: Int }
                let id: String
                let snippet: Snippet
                let contentDetails: ContentDetails
            }

            let nextPageToken: String?
            let items: [Item]
        }

        var allPlaylists: [YouTubeOwnedPlaylist] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw YouTubeAccountError.invalidRequest }

            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw YouTubeAccountError.apiRequestFailed
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            allPlaylists.append(contentsOf: decoded.items.map {
                YouTubeOwnedPlaylist(
                    id: $0.id,
                    title: $0.snippet.title,
                    itemCount: $0.contentDetails.itemCount
                )
            })
            pageToken = decoded.nextPageToken
        } while pageToken != nil

        return allPlaylists.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    @discardableResult
    private func configureGoogleSignIn(showAlert: Bool = false) -> Bool {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty,
              !clientID.contains("REPLACE_ME") else {
            reportConfigurationError(
                "Google 로그인 설정이 아직 완료되지 않았습니다. "
                    + "Jarvis/Info.plist의 GIDClientID에 Google Cloud에서 발급받은 "
                    + "iOS OAuth 클라이언트 ID를 입력해주세요.",
                showAlert: showAlert
            )
            return false
        }

        let expectedScheme = reversedClientIDScheme(for: clientID)
        let registeredSchemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            ?? []
        guard let expectedScheme, registeredSchemes.contains(expectedScheme) else {
            reportConfigurationError(
                "Google OAuth 콜백 URL 스키마가 일치하지 않습니다. "
                    + "Jarvis/Info.plist의 URL Types에 Google Cloud의 iOS URL scheme"
                    + (expectedScheme.map { " (\($0))" } ?? "")
                    + "을 추가해주세요.",
                showAlert: showAlert
            )
            return false
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        return true
    }

    private func reversedClientIDScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let identifier = clientID.dropLast(suffix.count)
        guard !identifier.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(identifier)"
    }

    private func reportConfigurationError(_ message: String, showAlert: Bool) {
        statusMessage = message
        if showAlert { connectionAlertMessage = message }
    }
}

enum YouTubeAccountError: LocalizedError {
    case notSignedIn
    case noPresenter
    case invalidRequest
    case apiRequestFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Google 계정에 로그인되어 있지 않습니다."
        case .noPresenter: return "Google 로그인 화면을 열 수 없습니다."
        case .invalidRequest: return "YouTube 요청 주소를 만들지 못했습니다."
        case .apiRequestFailed: return "YouTube에서 재생목록을 가져오지 못했습니다."
        }
    }
}

private extension UIApplication {
    var jarvisTopViewController: UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return topViewController(from: root)
    }

    func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigation = viewController as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = viewController as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = viewController?.presentedViewController {
            return topViewController(from: presented)
        }
        return viewController
    }
}
