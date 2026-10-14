import SwiftUI
import UIKit

@main
struct LunaSyncApp: App {
    @StateObject private var model = BackupModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background && model.busy {
                        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish resource IO") {
                            Task { @MainActor in model.pause(); endBackgroundTask() }
                        }
                        model.pause()
                    } else if phase == .active { model.refreshAuthorization() }
                }
                .onChange(of: model.busy) { _, busy in if !busy { endBackgroundTask() } }
        }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
        }
    }
}
