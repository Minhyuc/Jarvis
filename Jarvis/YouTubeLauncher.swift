import UIKit

@MainActor
struct YouTubeLauncher {
    func openSearch(query: String) async -> Bool {
        guard let url = YouTubeURLBuilder().searchURL(for: query) else { return false }
        return await UIApplication.shared.open(url)
    }
}
