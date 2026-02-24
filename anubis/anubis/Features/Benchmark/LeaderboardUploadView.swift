//
//  LeaderboardUploadView.swift
//  anubis
//
//  Sheet for uploading a benchmark result to the community leaderboard.
//

import SwiftUI

struct LeaderboardUploadView: View {
    let session: BenchmarkSession

    @State private var displayName: String
    @State private var uploading = false
    @State private var uploaded = false
    @State private var errorMessage: String?
    @State private var submissionId: Int?

    @Environment(\.dismiss) private var dismiss

    init(session: BenchmarkSession) {
        self.session = session
        let saved = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.leaderboardDisplayName) ?? ""
        _displayName = State(initialValue: saved)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Upload to Leaderboard")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: uploaded ? "xmark" : "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.md)

            Divider()

            if uploaded {
                successView
            } else {
                formView
            }
        }
        .frame(width: 420, height: 380)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(spacing: Spacing.md) {
            // Session preview
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Benchmark Summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.modelName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        let chip = session.chipInfo ?? ChipInfo.current
                        Text(chip.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        if let tps = session.tokensPerSecond {
                            Text(String(format: "%.2f tok/s", tps))
                                .font(.mono(16, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                        Text(session.backend)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.cardBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.cardBorder, lineWidth: 1)
                        }
                }
            }

            // Display name
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Display Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Your name on the leaderboard", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(uploading)
                    .onChange(of: displayName) { _, newValue in
                        if newValue.count > Constants.Leaderboard.maxDisplayNameLength {
                            displayName = String(newValue.prefix(Constants.Leaderboard.maxDisplayNameLength))
                        }
                    }

                Text("This will be visible to everyone on the leaderboard.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.orange.opacity(0.1))
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if uploading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        upload()
                    } label: {
                        Label("Upload", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Uploaded!")
                .font(.title2.weight(.semibold))

            if let id = submissionId {
                Text("Submission #\(id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.open(Constants.URLs.leaderboardPage)
            } label: {
                Label("View Leaderboard", systemImage: "globe")
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.md)
    }

    // MARK: - Upload

    private func upload() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Save display name for next time
        UserDefaults.standard.set(trimmed, forKey: Constants.UserDefaultsKeys.leaderboardDisplayName)

        uploading = true
        errorMessage = nil

        Task {
            do {
                let service = LeaderboardService()
                let response = try await service.submit(session: session, displayName: trimmed)
                await MainActor.run {
                    submissionId = response.id
                    uploaded = true
                    uploading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    uploading = false
                }
            }
        }
    }
}
