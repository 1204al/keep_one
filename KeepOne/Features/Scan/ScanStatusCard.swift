import SwiftUI

/// The first scan should feel alive (live findings); later incremental scans stay to one quiet line.
struct ScanStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.scan
        NavigationLink(value: Route.scanDetails) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(scan)).font(.headline)
                        Text(subtitle(scan))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    control(scan)
                }
                ProgressView(value: scan.overallFraction)
                    .tint(Color.accentColor)
                    .accessibilityLabel("Overall progress")
                    .accessibilityValue([Format.percent(scan.overallFraction), remainingText].compactMap { $0 }.joined(separator: ", "))
                HStack {
                    Text(Format.percent(scan.overallFraction))
                    Spacer()
                    if let remainingText { Text(remainingText) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityHidden(true)
                if scan.isFirstScan, !foundLine.isEmpty {
                    Label(foundLine, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .animation(.default, value: foundLine)
                }
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "About 12 min left" — rounded up, and only once the estimate has settled.
    private var remainingText: String? {
        guard model.scan.state.isRunning, let seconds = model.scanTimeRemaining else { return nil }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "About \(hours) h left" : "About \(hours) h \(rest) min left"
    }

    private func title(_ scan: ScanProgress) -> String {
        switch scan.state {
        case .running: scan.isFirstScan ? "Analyzing your library" : "Checking new items"
        case .paused(let reason): reason.message
        case .failed(let message): message
        case .completed: "Analysis complete"
        case .idle: scan.totalCount == 0 ? "Getting ready…" : "Analysis not finished"
        }
    }

    private func subtitle(_ scan: ScanProgress) -> String {
        let counts = scan.totalCount > 0 ? "\(Format.count(scan.analyzedCount)) of \(Format.count(scan.totalCount))" : "Preparing…"
        if let label = scan.currentLabel, scan.state.isRunning { return counts + " · " + label }
        return counts
    }

    @ViewBuilder
    private func control(_ scan: ScanProgress) -> some View {
        if scan.state.isRunning {
            Button {
                model.pauseScan()
            } label: {
                Image(systemName: "pause.fill").frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Pause analysis")
        } else if case .failed = scan.state {
            Button("Try again") { model.startScan() }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.semibold))
        } else if !scan.isComplete, !(scan.state == .idle && scan.totalCount == 0) {
            Button {
                model.startScan()
                BackgroundScanScheduler.shared.beginContinuedScanIfUseful(pendingItems: scan.totalCount - scan.analyzedCount)
            } label: {
                Image(systemName: "play.fill").frame(width: 36, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Resume analysis")
        }
    }

    /// "34 exact duplicates · 71 similar groups · 42 receipts" — what's already usable.
    private var foundLine: String {
        let s = model.snapshot
        var parts: [String] = []
        if let d = s.summary(.exactDuplicates) { parts.append(Format.plural(d.count, "duplicate")) }
        if let g = s.summary(.similarPhotos) { parts.append(Format.plural(g.groupCount, "similar group")) }
        let temporary = CleanupCategory.temporaryCategories.compactMap { s.summary($0)?.count }.reduce(0, +)
        if temporary > 0 { parts.append(Format.plural(temporary, "temporary photo")) }
        if let v = s.summary(.largeVideos) { parts.append(Format.plural(v.count, "large video")) }
        return parts.joined(separator: " · ")
    }
}

struct ScanDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.scan
        List {
            Section {
                ForEach(ScanStage.allCases) { stage in
                    let progress = scan.stage(stage)
                    HStack {
                        Label(stage.title, systemImage: stage.symbol)
                        Spacer()
                        if progress.isDone {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Done")
                        } else if progress.total > 0 {
                            Text(Format.percent(progress.fraction)).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            Text("Waiting").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Stages")
            } footer: {
                Text("Results appear as soon as each stage has something useful. You can start reviewing while analysis continues.")
            }
            Section {
                LabeledContent("Analyzed", value: "\(Format.count(scan.analyzedCount)) of \(Format.count(scan.totalCount))")
                if let last = scan.lastCompleted {
                    LabeledContent("Last completed", value: Format.relative(last))
                }
                LabeledContent("Working on", value: scan.concurrency == 1 ? "1 photo at a time" : "\(scan.concurrency) photos at a time")
                if scan.thermalLimited {
                    Label("Slowed down to keep your iPhone cool", systemImage: "thermometer.medium")
                }
            }
            Section {
                if scan.state.isRunning {
                    Button("Pause analysis") { model.pauseScan() }
                } else {
                    Button("Scan for new items now") { model.startScan() }
                }
            } footer: {
                Text("Only new, edited or not-yet-analyzed items are processed. Progress is saved continuously, so KeepOne resumes where it left off.")
            }
        }
        .navigationTitle("Analysis")
    }
}
