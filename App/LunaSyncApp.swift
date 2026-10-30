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
                    #if DEBUG
                    BackgroundBackupProbe.shared.sceneChanged(phase)
                    #endif
                    if phase == .background {
                        model.enteredBackground()
                    } else if phase == .active {
                        model.enteredForeground()
                        model.refreshAuthorization()
                    }
                    // Integrity checks retain the existing short cleanup window.
                    if phase == .background && model.busy && model.isVerifying {
                        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish resource IO") {
                            Task { @MainActor in model.pause(); endBackgroundTask() }
                        }
                        model.pause()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    model.protectedDataBecameUnavailable()
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
