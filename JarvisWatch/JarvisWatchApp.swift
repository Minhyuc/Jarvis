import SwiftUI
import WatchKit

@main
struct JarvisWatchApp: App {
    var body: some Scene {
        WindowGroup {
            JarvisWatchView()
        }
    }
}

struct JarvisWatchView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("YouTube 제어") {
                    NavigationLink {
                        NowPlayingView()
                            .navigationTitle("지금 재생 중")
                    } label: {
                        Label("재생 제어", systemImage: "play.circle.fill")
                    }
                }
            }
            .navigationTitle("JARVIS")
        }
    }
}
