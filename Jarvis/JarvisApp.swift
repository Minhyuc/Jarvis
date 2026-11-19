import GoogleSignIn
import SwiftUI
import UserNotifications

final class JarvisAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(JarvisAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AssistantViewModel()

    init() {
        JarvisShortcutsProvider.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            AssistantView(viewModel: viewModel)
                .task {
                    YouTubeAccountService.shared.restoreSession()
                    await JarvisCalendarNotificationService.shared.refreshUpcomingNotifications()
                }
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) {
                        return
                    }
                    if viewModel.handleIncomingURL(url) {
                        return
                    }
                    viewModel.consumePendingIntent(isForeground: scenePhase == .active)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .jarvisStartConversationRequested)
                ) { _ in
                    viewModel.consumePendingIntent(isForeground: scenePhase == .active)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingIntent()
                Task {
                    await JarvisCalendarNotificationService.shared.refreshUpcomingNotifications()
                }
            } else {
                viewModel.suspendForBackground()
                if newPhase == .background { CommandPracticeStore.shared.cancel() }
            }
        }
    }
}
