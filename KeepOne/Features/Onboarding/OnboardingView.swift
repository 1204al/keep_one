import SwiftUI

/// One screen, one button: what KeepOne does, that it stays on the iPhone, and why it needs Photos.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var requesting = false

    private var denied: Bool { model.authorization == .denied || model.authorization == .restricted }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    Text("Clean your library intelligently")
                        .font(.largeTitle.bold())
                    Text("Find duplicates, bad shots and temporary photos without uploading anything.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 18) {
                    point("lock.iphone", "Everything stays on this iPhone",
                          "Photos are analyzed locally. No account. No cloud. No tracking.")
                    point("hand.raised", "You decide",
                          "KeepOne only suggests. Nothing is deleted until you confirm a final review, and deleted items stay in Recently Deleted for about 30 days.")
                    point("photo.on.rectangle.angled", "Access to your photos",
                          "To analyze your library, KeepOne needs access to the photos you want it to review.")
                }

                if denied {
                    Label("Photos access is turned off. Allow it in Settings ▸ KeepOne ▸ Photos.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    requesting = true
                    Task {
                        await model.requestAccess()
                        requesting = false
                    }
                }
            } label: {
                Group {
                    if requesting { ProgressView() } else { Text(denied ? "Open Settings" : "Allow Access to Photos") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(requesting)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
