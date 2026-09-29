import SwiftUI

struct AssistantView: View {
    @ObservedObject var viewModel: AssistantViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                statusOrb

                VStack(spacing: 8) {
                    Text(viewModel.state.displayText)
                        .font(.title2.bold())
                    Text(viewModel.standbyEnabled ? "백그라운드 음성 대기 활성화" : "음성 대기 꺼짐")
                        .font(.subheadline)
                        .foregroundStyle(viewModel.standbyEnabled ? .green : .secondary)
                }

                transcriptPanel

                Spacer()

                controls
                textInput
            }
            .padding()
            .navigationTitle("JARVIS")
        }
    }

    private var statusOrb: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.15))
                .frame(width: 170, height: 170)
            Circle()
                .fill(viewModel.isActivelyListening ? .blue : .gray.opacity(0.5))
                .frame(width: viewModel.isActivelyListening ? 105 : 88,
                       height: viewModel.isActivelyListening ? 105 : 88)
                .animation(.easeInOut(duration: 0.35), value: viewModel.isActivelyListening)
            Image(systemName: viewModel.isActivelyListening ? "waveform" : "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.state.displayText)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.transcript.isEmpty {
                Label("나", systemImage: "person.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(viewModel.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !viewModel.response.isEmpty {
                Divider()
                Label("자비스", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(viewModel.response)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.startOneShotConversation()
            } label: {
                Label("한 번만 대화하기", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.standbyEnabled ? viewModel.stopAll() : viewModel.startStandby()
            } label: {
                Label(
                    viewModel.standbyEnabled ? "음성 대기 종료" : "음성 대기 시작",
                    systemImage: viewModel.standbyEnabled ? "stop.circle" : "ear"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var textInput: some View {
        HStack {
            TextField("명령을 입력하세요", text: $viewModel.textInput)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(viewModel.submitText)

            Button(action: viewModel.submitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(viewModel.textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("보내기")
        }
    }
}
