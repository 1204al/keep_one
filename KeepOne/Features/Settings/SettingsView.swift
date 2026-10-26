import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var versionTaps = 0
    @State private var confirmClear = false
    @State private var confirmRebuild = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Label {
                        LabeledContent("On-device analysis") { Image(systemName: "checkmark").foregroundStyle(.green) }
                    } icon: { Image(systemName: "cpu") }
                    Label {
                        LabeledContent("No cloud uploads") { Image(systemName: "checkmark").foregroundStyle(.green) }
                    } icon: { Image(systemName: "icloud.slash") }
                    Label {
                        LabeledContent("No account, ads or tracking") { Image(systemName: "checkmark").foregroundStyle(.green) }
                    } icon: { Image(systemName: "hand.raised") }
                    Toggle(isOn: $model.settings.allowICloudDownloads) {
                        Label("Use iCloud originals when needed", systemImage: "icloud.and.arrow.down")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("KeepOne has no server. With iCloud Photos optimized storage, the last option lets Photos fetch your own originals from iCloud for analysis. Off by default, so analysis works fully offline; opening a photo full screen may still load it from iCloud, just like the Photos app.")
                }

                Section {
                    Toggle(isOn: $model.settings.protectFavorites) { Label("Protect Favorites", systemImage: "heart") }
                    Toggle(isOn: $model.settings.protectEdited) { Label("Protect edited photos", systemImage: "slider.horizontal.3") }
                    Toggle(isOn: $model.settings.protectRecent) { Label("Protect recent photos", systemImage: "clock") }
                    if model.settings.protectRecent {
                        Stepper("Last \(Format.plural(model.settings.recentDays, "day"))", value: $model.settings.recentDays, in: 1...60)
                    }
                    Toggle(isOn: $model.settings.protectImportantDocuments) {
                        Label("Protect important documents", systemImage: "lock.shield")
                    }
                } header: {
                    Text("Protection")
                } footer: {
                    Text("Protected items are never suggested. Exact copies of a kept original can still be suggested even if recent.")
                }

                Section {
                    NavigationLink(value: Route.retention) {
                        Label("Temporary item rules", systemImage: "calendar.badge.clock")
                    }
                    Toggle(isOn: $model.settings.livePhotoCleanupEnabled) {
                        Label("Live Photo cleanup mode", systemImage: "livephoto")
                    }
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text("Live Photo cleanup adds a tool in Review that saves still copies so the paired videos can be removed.")
                }

                Section {
                    LabeledContent("Model") {
                        Text(model.semanticStatus.title).foregroundStyle(.secondary)
                    }
                    if case .ready(_, let units) = model.semanticStatus {
                        LabeledContent("Runs on", value: units)
                    } else if case .unavailable = model.semanticStatus {
                        Text("Content categories such as receipts, tickets and memes are off on this build. Duplicates, similar shots, blurry photos and text recognition still work.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink(value: Route.learning) {
                        LabeledContent("Learned preferences") {
                            Text(Format.plural(model.decisionCount, "decision")).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("AI")
                }

                Section {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Rescan library", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning)
                    Button {
                        confirmRebuild = true
                    } label: {
                        Label("Rebuild AI index", systemImage: "wand.and.stars")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear analysis cache", systemImage: "trash.slash")
                    }
                    Toggle(isOn: $model.settings.allowBackgroundScanning) {
                        Label("Continue scanning in background", systemImage: "moon.zzz")
                    }
                    Toggle(isOn: $model.settings.autoResumeScan) {
                        Label("Resume unfinished scans automatically", systemImage: "play.circle")
                    }
                } header: {
                    Text("Scan")
                } footer: {
                    Text("Your photos and videos are never touched by these actions. Background scanning only happens while charging, or briefly after you leave the app.")
                }

                if model.settings.developerMode {
                    Section("Developer") {
                        NavigationLink(value: Route.developer) {
                            Label("Performance & diagnostics", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        Toggle("Developer mode", isOn: $model.settings.developerMode)
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 7 {
                                model.settings.developerMode = true
                                versionTaps = 0
                            }
                        }
                    if model.lifetimeFreedBytes > 0 {
                        LabeledContent("Freed with KeepOne", value: Format.bytes(model.lifetimeFreedBytes))
                    }
                } footer: {
                    Text("KeepOne · Private by design. All analysis happens on this iPhone. Nothing is uploaded.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .confirmationDialog("Clear analysis cache?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear and rescan", role: .destructive) { Task { await model.clearAnalysisCache() } }
            } message: {
                Text("Removes all cached analysis and starts a fresh scan. Your photos, Trash Queue, protections and learned preferences are kept.")
            }
            .confirmationDialog("Rebuild AI index?", isPresented: $confirmRebuild, titleVisibility: .visible) {
                Button("Rebuild") { Task { await model.rebuildAIIndex() } }
            } message: {
                Text("Re-runs Vision, semantic, text and video analysis. Fingerprints are kept, so duplicates stay available meanwhile.")
            }
        }
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct RetentionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                rule("Parking photos", symbol: "parkingsign.circle", binding: $model.settings.retention.parking)
                rule("Screenshots", symbol: "iphone", binding: $model.settings.retention.screenshots)
                rule("Receipts", symbol: "receipt", binding: $model.settings.retention.receipts)
                rule("Screen recordings", symbol: "record.circle", binding: $model.settings.retention.screenRecordings)
                rule("Tickets & QR codes", symbol: "qrcode", binding: $model.settings.retention.tickets)
                rule("Other references", symbol: "pin", binding: $model.settings.retention.otherReferences)
            } header: {
                Text("Suggest temporary items")
            } footer: {
                Text("Items younger than the rule aren't suggested yet. “Never by age” keeps them as “Needs review” only. Receipts may matter for warranty, returns or taxes — the default is conservative.")
            }
        }
        .navigationTitle("Temporary item rules")
    }

    private func rule(_ title: String, symbol: String, binding: Binding<RetentionPeriod>) -> some View {
        Picker(selection: binding) {
            ForEach(RetentionPeriod.choices) { Text($0.title).tag($0) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct LearningSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Decisions recorded", value: "\(model.decisionCount)")
                LabeledContent("Personal ranking", value: model.preference.isActive ? "Active" : "Learning (needs \(PreferenceModel.minimumExamples))")
            } footer: {
                Text("KeepOne learns from your Keep, Trash, Protect and best-shot choices — on this iPhone only. It reorders suggestions and becomes more careful where you disagree. It never deletes on its own.")
            }
            let stats = model.preference.categoryStats.sorted { $0.key.displayOrder < $1.key.displayOrder }
            if !stats.isEmpty {
                Section("How you decide") {
                    ForEach(stats, id: \.key) { category, stat in
                        HStack {
                            Label(category.title, systemImage: category.symbol)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(stat.accepted) removed · \(stat.rejected) kept").font(.caption).monospacedDigit()
                                Text(trustText(model.preference.trust(for: category))).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Best-shot weights") {
                let w = model.settings.bestShotWeights.normalized()
                weightRow("Sharpness", w.sharpness)
                weightRow("Face quality", w.faceQuality)
                weightRow("Aesthetics", w.aesthetics)
                weightRow("Exposure", w.exposure)
                weightRow("Personal preference", w.personal)
                weightRow("Framing", w.framing)
                weightRow("Resolution", w.resolution)
            }
            Section {
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Export learned preferences", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("Import preferences", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset learned preferences", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("The export contains your decisions as numeric features and settings — no photos, thumbnails or text. Useful before reinstalling a development build.")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Learned preferences")
        // Rebuilt on every visit (settings and marks change too), removed when leaving.
        .task(id: model.decisionCount) { exportURL = try? model.exportPreferences() }
        .onDisappear {
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
            exportURL = nil
        }
        .confirmationDialog("Reset learned preferences?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetLearning() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    try await model.importPreferences(from: url)
                    message = "Preferences imported."
                } catch {
                    message = "That file couldn't be imported."
                }
            }
        }
    }

    private func trustText(_ trust: CategoryTrust) -> String {
        switch trust {
        case .normal: "Normal"
        case .reduced: "Shown for review only"
        case .boosted: "Ranked higher"
        }
    }

    private func weightRow(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Format.percent(value)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
