import AVFAudio
import SwiftUI

/// First-run setup checklist. Each row shows its state and the one action that fixes it.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showTraining = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.tint)
                Text("Welcome to Minutes")
                    .font(.largeTitle.weight(.semibold))
                Text("Minutes turns what's said in your meetings into text and saves it in Notes. Sound is turned into words on this Mac and thrown away — audio is never recorded. Claude can then search your notes and transcripts for you.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                SetupRow(icon: "mic", title: "Microphone", detail: "Hears people in the room.",
                         done: model.microphoneAllowed, actionTitle: "Allow") {
                    Task { await model.requestMicrophone() }
                }
                Divider()
                SetupRow(icon: "phone.connection", title: "Call audio", detail: model.callAudioError ?? "Hears Teams, Zoom, and browser calls playing on this Mac.",
                         done: model.callAudioChecked, actionTitle: "Allow") {
                    model.checkCallAudio()
                }
                Divider()
                SetupRow(icon: "note.text", title: "Notes", detail: model.indexer?.lastError ?? "Saves transcripts to “\(model.transcriptFolder)” and indexes your notes for Claude.",
                         done: model.notesReady, actionTitle: "Allow") {
                    Task { await model.indexer?.refreshNow() }
                }
                Divider()
                SetupRow(icon: "arrow.down.circle", title: "Speech models", detail: modelDetail,
                         done: model.models.isReady, actionTitle: "Download") {
                    Task { await model.models.prepare() }
                }
                Divider()
                SetupRow(icon: "person.wave.2", title: "Your voice (optional)", detail: "So your lines are labeled “Me”.",
                         done: model.hasVoicePrint, actionTitle: "Train…") {
                    showTraining = true
                }
                Divider()
                SetupRow(icon: "sparkle", title: "Claude", detail: claudeDetail,
                         done: model.claudeStatus == .connected, actionTitle: "Connect",
                         actionEnabled: model.claudeStatus == .notConnected) {
                    Task { await model.connectClaude() }
                }
            }
            .padding(.horizontal, 4)
            .background(.background.secondary, in: .rect(cornerRadius: 12))

            Button("Done") {
                model.onboarded = true
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 520)
        .sheet(isPresented: $showTraining) { VoiceTrainingView(model: model) }
        .task { await model.refreshClaudeStatus() }
    }

    private var modelDetail: String {
        switch model.models.state {
        case .preparing(let step): step
        case .failed(let message): message
        default: "Speech-to-text and speaker models, kept on this Mac."
        }
    }

    private var claudeDetail: String {
        if let error = model.claudeError { return error }
        if model.claudeStatus == .claudeNotFound { return "Install Claude Code, then connect." }
        return "Lets Claude Code search your notes and transcripts."
    }
}

private struct SetupRow: View {
    let icon: String
    let title: String
    let detail: String
    let done: Bool
    let actionTitle: String
    var actionEnabled = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .disabled(!actionEnabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
