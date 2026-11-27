import SwiftUI
import AppKit
import JarvisCore

@MainActor
final class USBInstallation: ObservableObject {
    @Published var ready = !JarvisStorage.portable
    @Published var message = "APFS 볼륨 JARVIS의 Jarvis 폴더를 선택하면 앱 데이터와 프로젝트를 SSD에서만 사용합니다. 접근 권한은 이번 실행 동안만 유지합니다."
    private var granted: URL?
    private let root = URL(fileURLWithPath: "/Volumes/JARVIS/Jarvis")
    func connect() {
        guard JarvisStorage.portable,
              Bundle.main.bundleURL.path.hasPrefix(root.path + "/"),
              case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.codeConnect), context: .init(externalActionsLocked: UserDefaults.standard.bool(forKey: SharedProjectStore.lockKey), wasExplicitlyConfirmed: true)) else {
            message = "USB 앱과 안전 잠금 상태를 확인해주세요."; return
        }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = root; panel.prompt = "USB 저장 공간 사용"
        panel.message = "JARVIS 볼륨 안의 Jarvis 폴더를 선택해주세요. Mac 내부 폴더는 사용할 수 없습니다."
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.standardizedFileURL == root, selected.startAccessingSecurityScopedResource() else { return }
        do {
            let store = try USBDataStore(root: selected, expectedVolume: "8B1F8F32-6526-49B0-8C21-9C472EB5D8E8", confirmed: true, locked: false)
            granted = selected; JarvisStorage.activate(store); ready = true
        } catch { selected.stopAccessingSecurityScopedResource(); message = "USB 식별자·권한·설정 파일을 확인하지 못했습니다. 로컬 저장소로 대체하지 않습니다." }
    }
    func check() {
        guard JarvisStorage.portable, ready else { return }
        if JarvisStorage.store?.available != true || JarvisStorage.store?.preferences.persistenceFailed == true { disconnect() }
    }
    func disconnect() {
        guard JarvisStorage.portable else { return }
        ready = false; SharedProjectStore.shared.disconnect(); JarvisStorage.revoke()
        message = "USB 연결 또는 저장을 확인하지 못해 작업을 중단했습니다. 다시 연결한 뒤 저장 공간을 선택하세요."
        if let granted { granted.stopAccessingSecurityScopedResource(); self.granted = nil }
    }
}

/// USB distribution remains sandboxed. No desktop store is used as fallback.
@main
struct JarvisMacApp: App {
    @StateObject private var installation = USBInstallation()
    var body: some Scene {
        WindowGroup("JARVIS · 개발 공간") {
            Group {
                if installation.ready {
                    NavigationStack { DevelopmentHubView() }
                        .defaultAppStorage(JarvisStorage.preferences)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "externaldrive").font(.system(size: 48))
                        Text("JARVIS · USB 전용").font(.title.bold())
                        Text(installation.message).multilineTextAlignment(.center).frame(maxWidth: 520)
                        Button("JARVIS 저장 공간 연결") { installation.connect() }.buttonStyle(.borderedProminent)
                        Button("종료") { NSApplication.shared.terminate(nil) }
                    }.padding(40)
                }
            }
            .frame(minWidth: 960, minHeight: 680)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notice in
                if let url = notice.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                   url.path == "/Volumes/JARVIS" { installation.disconnect() }
            }
            .task {
                while !Task.isCancelled {
                    installation.check()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }.defaultSize(width: 1180, height: 820)
    }
}
