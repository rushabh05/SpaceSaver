import AppKit
import SpaceSaverCore
import SwiftUI

@main
struct SpaceSaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("SpaceSaver", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    model.start()
                    DebugSnapshot.runIfRequested(model: model)
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates(manual: true) }
                    .disabled(model.updateStatus.isBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Scan for Reclaimable Space") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                Button("Scan Storage Map") {
                    model.section = .storageMap
                    model.startMapScan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.start()
        IslandController.shared.start(model: AppModel.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running while the menu bar item or the Dynamic Island is on.
        let defaults = UserDefaults.standard
        let menuBar = defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true
        let island = defaults.object(forKey: "islandEnabled") as? Bool ?? true
        return !menuBar && !island
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarShowsFree") private var showsFree = true

    var body: some View {
        label.onAppear { model.openWindowAction = openWindow }
    }

    @ViewBuilder private var label: some View {
        if showsFree, let disk = model.disk {
            Label(ByteFormat.compact(disk.free), systemImage: disk.usedFraction > 0.92 ? "externaldrive.fill.badge.exclamationmark" : "internaldrive")
        } else {
            Image(systemName: "internaldrive")
        }
    }
}
