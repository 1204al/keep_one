import SwiftUI

/// Hub for temporary-reference photos: receipts, parking, labels, tickets…
struct TemporaryReferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summaries = CleanupCategory.temporaryCategories.compactMap { model.snapshot.summary($0) }
        List {
            Section {
                ForEach(summaries) { summary in
                    NavigationLink(value: Route.category(summary.category)) {
                        HStack(spacing: 14) {
                            PreviewMosaic(ids: Array(summary.previewIDs.prefix(1)))
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Label(summary.category.title, systemImage: summary.category.symbol)
                                        .labelStyle(CategoryLabelStyle())
                                        .font(.headline)
                                    Spacer()
                                    Text("\(summary.count)").font(.headline).monospacedDigit()
                                }
                                if let oldest = summary.oldest, let newest = summary.newest {
                                    Text("Oldest \(Format.relative(oldest)) · newest \(Format.relative(newest))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    TierBadge(tier: summary.dominantTier, compact: true)
                                    Text(Format.bytes(summary.bytes, approximate: !summary.bytesExact))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Photos you probably took to remember something")
            } footer: {
                Text("Suggestions follow your age rules. Anything that looks like an ID, contract, medical or financial document, or damage evidence, is protected and never appears here.")
            }
            if summaries.isEmpty {
                EmptyStateView(symbol: "pin", title: "No temporary photos",
                               message: "Receipts, parking spots, labels and tickets will appear here once analyzed.")
            }
            Section {
                NavigationLink(value: Route.retention) {
                    Label("Suggestion rules", systemImage: "calendar.badge.clock")
                }
                NavigationLink(value: Route.importantDocuments) {
                    Label("Important & sensitive (protected)", systemImage: "lock.shield")
                }
            }
        }
        .navigationTitle("Temporary photos")
    }
}
