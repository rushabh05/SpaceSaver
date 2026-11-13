import AppKit
import SpaceSaverCore
import SwiftUI

extension AppModel {
    func loadApps(force: Bool = false) {
        guard !appsLoading, force || !appsLoaded else { return }
        appsLoading = true
        let env = ScanEnvironment(settings: settings)
        Task.detached(priority: .userInitiated) {
            let records = AppInventory(env: env).load()
            await MainActor.run {
                withAnimation(Theme.spring) {
                    self.apps = records
                    self.appsLoading = false
                    self.appsLoaded = true
                }
            }
        }
    }

    /// Opens the usual review sheet for removing `app` and the chosen leftovers.
    func uninstall(_ app: AppRecord, leftovers: Set<String>) {
        let items = AppInventory(env: ScanEnvironment(settings: settings))
            .uninstallItems(app, leftovers: leftovers, running: RunningApps.snapshot())
        if let reason = items.first?.blockedReason {
            show(reason, error: true)
            return
        }
        requestCleanup(items, title: "Uninstall \(app.name)?")
    }

    /// Keeps the app list in sync after a cleanup removed some of these paths.
    func pruneApps(removed paths: Set<String>) {
        guard !apps.isEmpty else { return }
        apps = apps.compactMap { app in
            if paths.contains(app.path) { return nil }
            var copy = app
            copy.leftovers.removeAll { paths.contains($0.path) }
            return copy
        }
    }
}

struct AppsView: View {
    enum Sort: String, CaseIterable { case size = "Size", lastUsed = "Least recently used", name = "Name" }

    @Environment(AppModel.self) private var model
    @Environment(\.contentWidth) private var width
    @State private var search = ""
    @State private var sort: Sort = .size
    @State private var selectedID: String?

    private var visible: [AppRecord] {
        let filtered = search.isEmpty ? model.apps : model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .size: return filtered.sorted { $0.totalSize > $1.totalSize }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var selected: AppRecord? { model.apps.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.appsLoading && model.apps.isEmpty {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Looking through your apps…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.apps.isEmpty {
                EmptyStateView(symbol: "xmark.bin", title: "No apps found",
                               message: "SpaceSaver looks in /Applications and ~/Applications. Apple's own apps aren't listed.",
                               action: ("Look Again", { model.loadApps(force: true) }))
            } else if width < 720 {
                // Narrow window: the details sit under the list.
                VStack(spacing: 0) {
                    list.frame(maxHeight: .infinity)
                    Divider()
                    detailPane.frame(height: 300)
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: 240)
                    Divider()
                    detailPane.frame(width: width < 960 ? 300 : 360)
                }
            }
        }
        .onAppear {
            model.loadApps()
            if selectedID == nil { selectedID = visible.first?.id }
        }
        .onChange(of: model.apps) {
            if selectedID == nil || selected == nil { selectedID = visible.first?.id }
        }
    }

    private var detailPane: some View {
                    Group {
                        if let selected {
                            AppDetail(app: selected).id(selected.id)
                                .transition(.blurReplace)
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "hand.point.left").font(.largeTitle).foregroundStyle(.tertiary)
                                Text("Choose an app to see what it keeps on your Mac.").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .animation(Theme.spring, value: selectedID)
    }

    private var header: some View {
        AdaptiveStack(stacked: width < 820, spacing: 12, alignment: .center) {
            HStack(spacing: 14) {
                CategoryIcon(category: .apps, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps").font(.system(size: 24, weight: .bold))
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.numericText())
                }
            }
            if width >= 820 { Spacer(minLength: 0) }
            headerControls
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search).textFieldStyle(.plain).frame(minWidth: 90, maxWidth: 150)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(minWidth: 120, maxWidth: 170)
            Button { model.loadApps(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle()).help("Look again").disabled(model.appsLoading)
        }
    }

    private var summary: String {
        guard !model.apps.isEmpty else { return CleanupCategory.apps.blurb }
        let size = model.apps.reduce(Int64(0)) { $0 + $1.size }
        let library = model.apps.reduce(Int64(0)) { $0 + $1.leftoverSize }
        return "\(model.apps.count) apps, \(ByteFormat.string(size)), plus \(ByteFormat.string(library)) of their files in your Library."
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(visible) { app in
                AppRow(app: app).tag(app.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct AppIconImage: View {
    let path: String
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private func lastUsedText(_ date: Date?) -> String {
    guard let date else { return "Last opened: unknown" }
    return "Opened \(RelativeTime.string(since: date))"
}

private func isStale(_ date: Date?) -> Bool {
    guard let date else { return false }
    return Date().timeIntervalSince(date) > 180 * 86_400
}

struct AppRow: View {
    let app: AppRecord

    var body: some View {
        HStack(spacing: 12) {
            AppIconImage(path: app.path, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    if isStale(app.lastUsed) { Tag(text: "Unused 6+ months", color: .orange) }
                    if app.fromAppStore { Tag(text: "App Store", color: .blue) }
                    if app.hasSystemExtension { Tag(text: "System extension", color: .purple) }
                }
                Text(lastUsedText(app.lastUsed)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(app.totalSize)).font(.callout.monospacedDigit().weight(.semibold))
                if app.leftoverSize > 0 {
                    Text("+\(ByteFormat.compact(app.leftoverSize)) in Library").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AppDetail: View {
    let app: AppRecord
    @Environment(AppModel.self) private var model
    @State private var chosen: Set<String> = []
    @State private var appeared = false

    private var running: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty == false }
    private var total: Int64 { app.size + app.leftovers.filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.size } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AppIconImage(path: app.path, size: 64)
                        .scaleEffect(appeared ? 1 : 0.85).opacity(appeared ? 1 : 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3.weight(.bold)).lineLimit(2)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if let version = app.version { Text("Version \(version)").font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if app.hasSystemExtension {
                    Label("\(app.name) installs a system extension (common for security, VPN and driver apps). Use its own uninstaller if it has one, or turn the extension off in System Settings › General › Login Items & Extensions first.",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                }

                HStack(spacing: 10) {
                    stat("App", app.size)
                    stat("In your Library", app.leftoverSize)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Files it keeps").font(.headline)
                    if app.leftovers.isEmpty {
                        Text("Nothing found in your Library under its name.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(app.leftovers) { leftover in
                        Button {
                            withAnimation(Theme.bouncy) {
                                if chosen.contains(leftover.path) { chosen.remove(leftover.path) } else { chosen.insert(leftover.path) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                CheckCircle(isOn: chosen.contains(leftover.path), tint: CleanupCategory.apps.color)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(leftover.kind).font(.callout)
                                    Text(Paths.abbreviate(leftover.path)).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormat.string(leftover.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button { Finder.reveal([leftover.path]) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(IconButtonStyle(size: 22)).help("Show in Finder")
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button { model.uninstall(app, leftovers: chosen) } label: {
                        Label(running ? "Quit \(app.name) to uninstall" : "Uninstall · \(ByteFormat.string(total))",
                              systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(PrimaryButtonStyle(colors: Theme.dangerColors, large: true))
                    .disabled(running)
                    Text(app.fromAppStore
                         ? "Moves everything to the Trash; restore it from Activity. App Store apps may ask for your password."
                         : "Moves everything to the Trash; restore it from Activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show App in Finder") { Finder.reveal([app.path]) }
                        .buttonStyle(SoftButtonStyle(compact: true))
                }
            }
            .padding(20)
        }
        .onAppear {
            chosen = Set(app.leftovers.map(\.path))
            withAnimation(Theme.bouncy) { appeared = true }
        }
    }

    private func stat(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ByteFormat.string(bytes)).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 12)
    }
}
