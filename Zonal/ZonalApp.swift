import AppKit
import Darwin
import OSLog
import SwiftUI

@main
struct ZonalApp: App {
    @StateObject private var container = AppContainer.shared

    init() {
        // The test host must not start real event taps, observers, or shared-file writers.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        LocalAutomationClient.runIfRequested()
        NSApplication.shared.setActivationPolicy(.accessory)
        guard AppContainer.shared.start() else { exit(EXIT_SUCCESS) }
        StatusItemController.shared.install()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
