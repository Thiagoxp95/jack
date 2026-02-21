import SwiftUI

@main
struct KinshasaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Hosts the @StateObject in a View instead of the App struct.
/// SwiftUI wraps App.body content in a LazyView, and in Swift 6.2 the
/// MainActor isolation check during that LazyView re-evaluation can crash
/// (PAC trap in swift_getObjectType) when @StateObject references a
/// @MainActor class. Moving the StateObject here avoids that code path.
private struct RootView: View {
    @StateObject private var controller = DictationController()
    @State private var recordingController = RecordingSessionController()

    var body: some View {
        ContentView(controller: controller, recordingController: recordingController)
            .frame(minWidth: 640, minHeight: 460)
            .task {
                await controller.initialize()
                await recordingController.initialize()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                controller.applicationWillTerminate()
            }
    }
}
