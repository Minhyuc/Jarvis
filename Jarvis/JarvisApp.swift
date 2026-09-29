import SwiftUI

@main
struct JarvisApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AssistantViewModel()

    var body: some Scene {
        WindowGroup {
            AssistantView(viewModel: viewModel)
                .onOpenURL { _ in
                    viewModel.consumePendingIntent()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.consumePendingIntent()
        }
    }
}
