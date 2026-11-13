import AppKit
import SpaceSaverCore
import SwiftUI

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(Date)
    case available
    case downloading
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking for updates…"
        case .upToDate(let date): return "Up to date. Checked \(RelativeTime.string(since: date))."
        case .available: return "An update is available."
        case .downloading: return "Downloading and verifying…"
        case .installing: return "Installing. SpaceSaver will relaunch."
        case .failed(let message): return message
        }
    }
}

extension AppModel {
    static let lastUpdateCheckKey = "lastUpdateCheck"

    var updateConfig: UpdateConfig { UpdateConfig.forInstalledApp(InstalledApp.current) }

    /// True when this build can verify and install updates itself (a bundled app with a key).
    var canSelfUpdate: Bool { InstalledApp.current != nil && updateConfig.publicKey != nil }

    /// Checks at most once a day, and only if automatic checks are on.
    func checkForUpdatesIfDue() {
        guard settings.autoCheckUpdates, canSelfUpdate, update == nil, !updateStatus.isBusy else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 22 * 3600 { checkForUpdates(manual: false) }
    }

    func checkForUpdates(manual: Bool) {
        guard !updateStatus.isBusy else { return }
        updateStatus = .checking
        let config = updateConfig
        let current = AppVersion.installed
        Task {
            do {
                let found = try await UpdateChecker.check(current: current, config: config)
                UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
                withAnimation(Theme.spring) {
                    update = found
                    updateStatus = found == nil ? .upToDate(Date()) : .available
                }
                if let found {
                    peek("arrow.down.circle.fill", .blue, "Update available", "SpaceSaver \(found.version) is ready to install")
                    if manual { show("SpaceSaver \(found.version) is available.") }
                } else if manual {
                    show("SpaceSaver \(current) is up to date.")
                }
            } catch {
                updateStatus = manual ? .failed(error.localizedDescription) : .idle
                if manual { show(error.localizedDescription, error: true) }
            }
        }
    }

    /// Downloads, verifies (Ed25519 signature, bundle ID, version, code signature), swaps the app
    /// bundle after this process quits, and relaunches.
    func installUpdate() {
        guard let release = update, !updateStatus.isBusy else { return }
        guard let app = InstalledApp.current, let key = updateConfig.publicKey else {
            openReleasePage()
            return
        }
        let installer = UpdateInstaller(publicKey: key, expectedBundleID: app.bundleID)
        do {
            try installer.preflight(target: app)
        } catch {
            updateStatus = .failed(error.localizedDescription)
            show(error.localizedDescription, error: true)
            return
        }
        withAnimation(Theme.spring) { updateStatus = .downloading }
        Task {
            do {
                let dmg = try await installer.download(release)
                withAnimation(Theme.spring) { updateStatus = .installing }
                let staged = try await Task.detached(priority: .userInitiated) {
                    try installer.stage(dmg: dmg, expectedVersion: release.version)
                }.value
                try installer.install(staged: staged, over: app, waitForPID: getpid(), relaunch: true)
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.terminate(nil)
            } catch {
                withAnimation(Theme.spring) { updateStatus = .failed(error.localizedDescription) }
                show(error.localizedDescription, error: true)
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(update?.pageURL ?? URL(string: "https://rushabh05.github.io/SpaceSaver/")!)
    }
}

/// Shown on the Overview when a newer release exists.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.update {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.brand).frame(width: 40, height: 40)
                    Image(systemName: "arrow.down").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .symbolEffect(.bounce, value: model.updateStatus == .available)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpaceSaver \(update.version) is available").font(.headline)
                    Text(subtitle(update)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("What's New") { model.openReleasePage() }
                    .buttonStyle(SoftButtonStyle(compact: true))
                if model.updateStatus.isBusy {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    Button {
                        model.canSelfUpdate ? model.installUpdate() : model.openReleasePage()
                    } label: {
                        Label(model.canSelfUpdate ? "Install and Relaunch" : "Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
            .surface(radius: 16, tint: Theme.brandColors[0])
        }
    }

    private func subtitle(_ update: UpdateRelease) -> String {
        switch model.updateStatus {
        case .downloading, .installing, .failed: return model.updateStatus.label
        default:
            let size = ByteFormat.string(update.size)
            return update.summary.isEmpty ? "\(size) download, verified before it's installed." : "\(update.summary) (\(size))"
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { model.settings.autoCheckUpdates },
                set: { model.settings.autoCheckUpdates = $0 }))
            LabeledContent("Version") {
                Text(AppVersion.installed).monospacedDigit()
            }
            HStack {
                Text(statusText).font(.callout).foregroundStyle(statusIsError ? .red : .secondary)
                Spacer()
                if model.updateStatus.isBusy { ProgressView().controlSize(.small) }
                if let update = model.update, !model.updateStatus.isBusy {
                    Button("Install \(update.version)") { model.installUpdate() }
                } else {
                    Button("Check Now") { model.checkForUpdates(manual: true) }.disabled(model.updateStatus.isBusy)
                }
            }
            Text("Updates come from GitHub releases and are only installed if they're signed with SpaceSaver's release key. Checking sends no personal data.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if !model.canSelfUpdate { return "This build can't update itself. Download new versions from the website." }
        if model.updateStatus == .idle, let update = model.update { return "SpaceSaver \(update.version) is available." }
        return model.updateStatus == .idle ? "" : model.updateStatus.label
    }

    private var statusIsError: Bool {
        if case .failed = model.updateStatus { return true }
        return false
    }
}
