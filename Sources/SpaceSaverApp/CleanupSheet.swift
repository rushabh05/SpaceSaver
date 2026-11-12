import SpaceSaverCore
import SwiftUI

/// Review → run → result. Nothing is touched until the user presses the button here.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CleanupRequest

    enum Phase { case review, running, done(CleanupReport) }

    @State private var phase: Phase = .review
    @State private var acknowledged = false
    @State private var progressText = ""
    @State private var progressValue = 0.0

    private var undoable: [CleanupItem] { request.items.filter { $0.method.isUndoable } }
    private var permanent: [CleanupItem] { request.items.filter { !$0.method.isUndoable } }
    private var cautions: [CleanupItem] { request.items.filter { $0.risk == .caution } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .review: review
            case .running: running
            case .done(let report): result(report)
            }
        }
        .frame(width: 600)
        .frame(minHeight: 300, maxHeight: 640)
        .interactiveDismissDisabled({ if case .running = phase { return true } else { return false } }())
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill((permanent.isEmpty ? Theme.brand : Theme.danger).opacity(0.15)).frame(width: 52, height: 52)
                    Image(systemName: permanent.isEmpty ? "trash" : "exclamationmark.octagon")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(permanent.isEmpty ? Theme.brand : Theme.danger)
                        .symbolEffect(.bounce, value: request.id)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.title2.weight(.bold))
                    Text("\(request.items.count) item\(request.items.count == 1 ? "" : "s") · \(ByteFormat.string(request.items.totalSize))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            Divider()
            List {
                if !undoable.isEmpty {
                    Section {
                        ForEach(undoable) { row($0) }
                    } header: {
                        Label("Moved to the Trash: restorable from Activity for \(model.settings.trashRetentionDays) days",
                              systemImage: "arrow.uturn.backward.circle")
                    }
                }
                if !permanent.isEmpty {
                    Section {
                        ForEach(permanent) { row($0) }
                    } header: {
                        Label("Permanent: can't be undone", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !cautions.isEmpty {
                    Label("\(cautions.count) item\(cautions.count == 1 ? " is" : "s are") marked Caution and may contain personal data.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                if !permanent.isEmpty || !cautions.isEmpty {
                    Toggle(permanent.isEmpty ? "I've checked these items" : "I understand some of this can't be undone",
                           isOn: $acknowledged)
                }
                HStack {
                    if request.planID != nil {
                        Text("Requested by an AI agent. You're the approval step.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") {
                        if let id = request.planID { PlanStore(paths: model.paths).decide(id, status: .pending) ; model.refreshPlans() }
                        dismiss()
                    }
                    .buttonStyle(SoftButtonStyle(tint: .secondary))
                    .keyboardShortcut(.cancelAction)
                    Button {
                        run()
                    } label: {
                        Label(undoable.count == request.items.count ? "Move \(ByteFormat.string(request.items.totalSize)) to Trash"
                                                                    : "Clean \(ByteFormat.string(request.items.totalSize))",
                              systemImage: "trash")
                    }
                    .buttonStyle(PrimaryButtonStyle(colors: permanent.isEmpty ? Theme.brandColors : Theme.dangerColors, large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled((!permanent.isEmpty || !cautions.isEmpty) && !acknowledged)
                }
            }
            .padding(20)
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.symbol).foregroundStyle(item.category.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    RiskBadge(risk: item.risk, compact: true)
                }
                Text(item.method.isUndoable ? item.subtitle : item.method.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SizeText(bytes: item.size, font: .callout)
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle().trim(from: 0, to: max(progressValue, 0.02))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.brandColors[0].opacity(0.4), radius: 8)
                Text("\(Int(progressValue * 100))%")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: progressValue))
            }
            .frame(width: 120, height: 120)
            .animation(Theme.spring, value: progressValue)
            Text("Cleaning").font(.title3.weight(.semibold))
            Text(progressText).foregroundStyle(.secondary).lineLimit(1).contentTransition(.opacity)
                .animation(Theme.snappy, value: progressText)
        }
        .padding(44)
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func run() {
        phase = .running
        Task {
            let report = await model.performCleanup(request) { done, total, title in
                Task { @MainActor in
                    progressValue = total > 0 ? Double(done) / Double(total) : 1
                    progressText = title
                }
            }
            phase = .done(report)
        }
    }

    // MARK: Result

    private func result(_ report: CleanupReport) -> some View {
        let inTrash = report.bytesMovedToTrash
        let freedNow = max(report.bytesCleaned - inTrash, 0)
        let ids = Set(report.entries.map(\.id))
        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 4) {
                if report.errors.isEmpty || report.bytesCleaned > 0 {
                    SuccessBadge(size: 70).frame(height: 130)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 54)).foregroundStyle(.orange)
                        .frame(height: 130)
                }
                CountUpBytes(target: report.bytesCleaned)
                Text(freedNow > 0 ? "\(ByteFormat.string(freedNow)) freed immediately" : "cleaned")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            if inTrash > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(ByteFormat.string(inTrash)) is in the Trash")
                        .font(.headline)
                    Text("macOS only frees that space when the Trash is emptied. SpaceSaver permanently deletes its own items after \(model.settings.trashRetentionDays) days (Settings › Safety), and you can restore anything from Activity until then.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Free \(ByteFormat.string(inTrash)) Now (permanent)") {
                        model.purge(ids: ids)
                        dismiss()
                    }
                    .buttonStyle(SoftButtonStyle(tint: .red))
                }
                .padding(14)
                .surface(radius: 14, tint: .blue)
            }
            if !report.errors.isEmpty {
                Text("Some items were skipped").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Button("Show Activity") {
                    model.section = .activity
                    dismiss()
                }
                .buttonStyle(SoftButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

/// Rolls a byte total up from zero.
struct CountUpBytes: View {
    let target: Int64
    @State private var shown: Int64 = 0

    var body: some View {
        BytesText(bytes: shown, font: .system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.success)
            .onAppear {
                let steps = 24
                for i in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.03) {
                        let t = Double(i) / Double(steps)
                        let eased = 1 - pow(1 - t, 3)
                        shown = Int64(Double(target) * eased)
                    }
                }
            }
    }
}
