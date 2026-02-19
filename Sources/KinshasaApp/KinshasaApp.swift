import SwiftUI

@main
struct KinshasaApp: App {
    @StateObject private var controller = DictationController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 640, minHeight: 460)
                .task {
                    await controller.initialize()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    controller.applicationWillTerminate()
                }
        }
    }
}
