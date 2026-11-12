import ServiceManagement
import SpaceSaverCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ScanningSettings().tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            SafetySettings().tabItem { Label("Safety", systemImage: "checkmark.shield") }
            ScheduleSettingsView().tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }
            AgentSettings().tabItem { Label("AI & Agents", systemImage: "brain") }
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("menuBarShowsFree") private var menuBarShowsFree = true
    @AppStorage("islandEnabled") private var islandEnabled = true
    @AppStorage("islandHover") private var islandHover = true
    @AppStorage("islandShowsFree") private var islandShowsFree = false
    @AppStorage("islandLowDisk") private var islandLowDisk = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show the Dynamic Island around the notch", isOn: $islandEnabled)
                    .onChange(of: islandEnabled) { _, on in IslandController.shared.setEnabled(on) }
                Toggle("Expand when the pointer is over it", isOn: $islandHover).disabled(!islandEnabled)
                Toggle("Always show free space beside the notch", isOn: $islandShowsFree).disabled(!islandEnabled)
                Toggle("Warn beside the notch when the disk is nearly full", isOn: $islandLowDisk).disabled(!islandEnabled)
            } header: {
                Text("Dynamic Island")
            } footer: {
                Text("Scan and cleanup progress, agent requests and results appear around the notch. On Macs without a notch, it sits at the top center of the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show SpaceSaver in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Show free space next to the icon", isOn: $menuBarShowsFree).disabled(!showMenuBarExtra)
                Text("With the menu bar item on, closing the window keeps SpaceSaver running there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Only works when SpaceSaver runs from the installed .app: \(error.localizedDescription)"
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Data") {
                LabeledContent("Settings, history and activity") {
                    Button("Show in Finder") { Finder.reveal([AppPaths.default.base]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScanningSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Code projects") {
                ForEach(model.settings.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root)
                        Spacer()
                        Button { model.settings.projectRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(model.settings.projectRoots.count == 1)
                    }
                }
                Button("Add Folder…") {
                    if let p = Finder.chooseFolder(message: "Choose a folder that contains code projects") {
                        model.settings.projectRoots.append(Paths.abbreviate(p))
                    }
                }
                Stepper("Dormant after \(model.settings.dormantDays) days without activity",
                        value: $model.settings.dormantDays, in: 7...365, step: 7)
                Text("Activity means git commits, checkouts or edits at the project root. Active projects are never recommended for cleaning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Thresholds") {
                Stepper("Large files: over \(model.settings.largeFileThresholdMB) MB", value: $model.settings.largeFileThresholdMB, in: 10...10_000, step: 50)
                Stepper("Downloads: older than \(model.settings.downloadsAgeDays) days", value: $model.settings.downloadsAgeDays, in: 1...365)
                Stepper("AI session logs: older than \(model.settings.aiSessionAgeDays) days", value: $model.settings.aiSessionAgeDays, in: 1...365)
                Stepper("Duplicates: files over \(model.settings.duplicateMinSizeMB) MB", value: $model.settings.duplicateMinSizeMB, in: 1...1000)
            }
            Section("Custom rules") {
                Text("Add your own locations in ~/.spacesaver/rules.json using the same fields as the built-in rules (id, category, title, paths, risk, explanation, regenerate).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open rules.json") {
                    let path = AppPaths.default.customRules
                    if !FileManager.default.fileExists(atPath: path) {
                        let sample = """
                        [
                          {
                            "id": "my-cache",
                            "category": "custom",
                            "title": "My tool cache",
                            "paths": ["~/.mytool/cache"],
                            "risk": "safe",
                            "explanation": "Download cache for mytool.",
                            "regenerate": "Re-downloaded automatically."
                          }
                        ]
                        """
                        try? sample.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SafetySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Guards") {
                Toggle("Skip caches of running apps (Xcode, Docker, browsers…)", isOn: $model.settings.activeAppGuard)
                Text("Strongly recommended. Scheduled cleaning always uses this guard.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Trash") {
                Stepper("Keep cleaned items restorable for \(model.settings.trashRetentionDays) days",
                        value: $model.settings.trashRetentionDays, in: 0...90)
                Toggle("Then delete them from the Trash permanently", isOn: $model.settings.schedule.purgeExpiredTrash)
                Text("Only items SpaceSaver moved to the Trash are ever deleted. Space isn't freed until they leave the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never touch") {
                if model.settings.excludedPaths.isEmpty {
                    Text("No exclusions. Right-click any item and choose Always Ignore.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.callout.monospaced())
                        Spacer()
                        Button { model.settings.excludedPaths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    if let p = Finder.chooseFolder(message: "SpaceSaver will never scan or clean this folder") {
                        model.settings.excludedPaths.append(Paths.abbreviate(p))
                    }
                }
                Text("Always protected: system folders, your home and its top-level folders, ~/.ssh, ~/.aws, ~/.gnupg, keychains, Mail, Messages, iCloud Drive, .git folders and Claude Code memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(model.hasFullDiskAccess ? "Granted" : "Not granted").foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                        Button("Open Settings") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScheduleSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed = Scheduler.isInstalled
    @State private var status: String?
    @State private var running = false

    private let weekdays = Calendar.current.weekdaySymbols

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Clean automatically on a schedule", isOn: $model.settings.schedule.enabled)
                Text("Runs in the background through launchd, even when SpaceSaver is closed. Only cleans recommended Safe items, and only to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When") {
                Picker("Frequency", selection: $model.settings.schedule.frequency) {
                    Text("Daily").tag(ScheduleSettings.Frequency.daily)
                    Text("Weekly").tag(ScheduleSettings.Frequency.weekly)
                }
                if model.settings.schedule.frequency == .weekly {
                    Picker("Day", selection: $model.settings.schedule.weekday) {
                        ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) }
                    }
                }
                Picker("Time", selection: $model.settings.schedule.hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Stepper(model.settings.schedule.onlyBelowFreeGB == 0 ? "Run every time"
                        : "Only when free space is under \(model.settings.schedule.onlyBelowFreeGB) GB",
                        value: $model.settings.schedule.onlyBelowFreeGB, in: 0...500, step: 5)
                Toggle("Skip when on battery or Low Power Mode", isOn: $model.settings.schedule.skipOnBattery)
            }
            Section("What") {
                ForEach(CleanupCategory.reclaimScanCategories.filter { $0 != .trash && $0 != .custom }) { category in
                    Toggle(isOn: Binding(
                        get: { model.settings.schedule.categories.contains(category) },
                        set: { on in
                            if on { model.settings.schedule.categories.append(category) }
                            else { model.settings.schedule.categories.removeAll { $0 == category } }
                        })) {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
            Section {
                HStack {
                    Button(installed ? "Update Schedule" : "Install Schedule") { install() }
                        .disabled(!model.settings.schedule.enabled)
                    if installed { Button("Remove") { Scheduler.uninstall(); installed = false; status = "Schedule removed." } }
                    Spacer()
                    Button {
                        runNow()
                    } label: {
                        if running { ProgressView().controlSize(.small) } else { Text("Run Now") }
                    }
                    .disabled(running)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        guard let cli = model.cliPath else {
            status = "Can't find the spacesaver helper. Run SpaceSaver from the built .app."
            return
        }
        do {
            try Scheduler.install(cliPath: cli, schedule: model.settings.schedule)
            installed = true
            status = "Installed. Log: ~/.spacesaver/auto.log"
        } catch {
            status = error.localizedDescription
        }
    }

    private func runNow() {
        running = true
        let settings = model.settings
        Task.detached {
            let outcome = AutoCleaner(settings: settings).run(force: true)
            await MainActor.run {
                running = false
                status = outcome.message
                model.refreshActivity()
                model.refreshDisk()
                model.scan = LastScanStore.load()
            }
        }
    }
}

struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var ollamaStatus: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Local AI explanations (Ollama)") {
                Toggle("Explain unknown folders with a local model", isOn: $model.settings.ai.ollamaEnabled)
                TextField("Server", text: $model.settings.ai.ollamaURL)
                TextField("Model", text: $model.settings.ai.ollamaModel)
                HStack {
                    Button("Test Connection") {
                        ollamaStatus = "Checking…"
                        let explainer = OllamaExplainer(settings: model.settings.ai)
                        Task {
                            ollamaStatus = await explainer.isReachable() ? "Connected." : "Not reachable. Is Ollama running?"
                        }
                    }
                    if let ollamaStatus { Text(ollamaStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Paths are anonymized (your username is removed) and nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MCP server for AI coding agents") {
                MCPSetupView()
            }
        }
        .formStyle(.grouped)
    }
}

struct MCPSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cli = model.cliPath ?? "/Applications/SpaceSaver.app/Contents/Helpers/spacesaver"
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents can check free space, list reclaimable caches, explain folders and propose cleanups. They can't delete anything: proposals wait for you in Agent Requests. Every call is logged to ~/.spacesaver/mcp-audit.jsonl.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            snippet("Claude Code", "claude mcp add spacesaver -- \"\(cli)\" mcp")
            snippet("Codex (~/.codex/config.toml)", "[mcp_servers.spacesaver]\ncommand = \"\(cli)\"\nargs = [\"mcp\"]")
            snippet("Cursor / Windsurf (mcp.json)", "{\n  \"mcpServers\": {\n    \"spacesaver\": { \"command\": \"\(cli)\", \"args\": [\"mcp\"] }\n  }\n}")
            snippet("Command line", "ln -sf \"\(cli)\" /usr/local/bin/spacesaver")
        }
    }

    private func snippet(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button { Finder.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(code).font(.caption.monospaced()).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
