import SwiftUI

/// Reads ~30 s of the user's voice into a voiceprint. The audio itself is erased.
struct VoiceTrainingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var trainer: VoiceTrainer { model.trainer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Train Your Voice")
                .font(.title2.weight(.semibold))
            Text("Read this aloud at your normal speaking volume:")
                .foregroundStyle(.secondary)
            GroupBox {
                Text("The best meetings end with a clear next step. Before we leave, let's agree on who is doing what, and when we'll check in again. If anything changes this week, I'll send a short update to everyone. Thanks for making the time today; I know these weeks are full.")
                    .font(.body)
                    .lineSpacing(3)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Gauge(value: min(trainer.speechSeconds, VoiceTrainer.requiredSpeech), in: 0...VoiceTrainer.requiredSpeech) {
                Text("Speech heard")
            } currentValueLabel: {
                Text("\(Int(trainer.speechSeconds)) of \(Int(VoiceTrainer.requiredSpeech)) seconds")
            }
            .gaugeStyle(.linearCapacity)

            Gauge(value: Double(min(1, max(0, (20 * log10(max(trainer.level, 1e-6)) + 60) / 60)))) {
                Text("Level")
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.green)

            status

            if model.session.isActive, trainer.state != .listening {
                Text("Stop the meeting to train your voice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Your voice stays in memory and is erased afterward. Minutes keeps only a voiceprint — 192 numbers that can't be played back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    trainer.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                switch trainer.state {
                case .idle, .failed:
                    Button("Start Reading") { Task { await trainer.start(models: model.models) } }
                        .buttonStyle(.glassProminent)
                        .disabled(model.session.isActive)
                case .listening:
                    Button("Done") { Task { await trainer.finish() } }
                        .buttonStyle(.glassProminent)
                        .disabled(trainer.speechSeconds < 8)
                case .processing:
                    ProgressView().controlSize(.small)
                case .saved:
                    Button("Close") {
                        model.refreshVoicePrint()
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { trainer.reset() }
        .onDisappear {
            if trainer.state == .listening { trainer.cancel() }
            model.refreshVoicePrint()
        }
    }

    @ViewBuilder private var status: some View {
        switch trainer.state {
        case .saved:
            Label("Voice saved. Your lines will be labeled “Me”.", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.green, .primary)
        case .failed(let message):
            ProblemRow(message: message)
        case .processing:
            Text("Making your voiceprint…").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
