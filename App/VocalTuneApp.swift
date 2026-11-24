import SwiftUI

@main
struct VocalTuneApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, p in model.sceneChanged(active: p == .active) }
        }
    }
}
