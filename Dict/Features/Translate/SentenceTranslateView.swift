import SwiftUI

struct SentenceTranslateView: View {
    var isActive = true

    @AppStorage(PreferenceKey.openAIBaseURL) private var baseURL = "https://api.deepseek.com"
    @AppStorage(PreferenceKey.openAIAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKey.openAIModel) private var model = "deepseek-flash"
    @AppStorage(PreferenceKey.reasoningEffort) private var reasoningEffort = "low"
    @AppStorage(PreferenceKey.highlightOpacity) private var highlightOpacity = 0.2
    @AppStorage(PreferenceKey.translationInstructions)
    private var translationInstructions = PromptDefaults.translationInstructions
    @AppStorage(PreferenceKey.contextPromptTemplate)
    private var contextPromptTemplate = PromptDefaults.contextPromptTemplate

    @ObservedObject private var store = SentenceTranslateStore.shared

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - 1) / 2)

            HStack(spacing: 0) {
                sourcePane
                    .frame(width: paneWidth, height: geometry.size.height)

                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: geometry.size.height)

                resultPane
                    .frame(width: paneWidth, height: geometry.size.height)
            }
            .onHover { isHovered in
                if !isHovered {
                    store.hoveredSourceSentenceID = nil
                }
            }
        }
        .background(Color.clear)
        .onChange(of: store.inputText) { _, newValue in
            store.inputDidChange(
                newValue,
                configuration: configuration,
                instructions: translationPrompt
            )
        }
        .onChange(of: store.selectedText) { _, newValue in
            store.selectionDidChange(
                newValue,
                configuration: configuration,
                translationInstructions: translationPrompt,
                contextPromptTemplate: contextPrompt
            )
        }
    }

    private var sourcePane: some View {
        SelectableTextView(
            text: $store.inputText,
            selectedText: $store.selectedText,
            selectionRange: $store.selectionRange,
            clearSelectionToken: store.selectionResetToken,
            highlightedSentenceRange: store.highlightedSourceRange,
            onHoveredCharacterIndex: store.updateHoveredSourceCharacter,
            highlightOpacity: highlightOpacity,
            isActive: isActive
        )
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var resultPane: some View {
        Group {
            if store.hasActionableSelection {
                selectionResult
            } else if store.status == .translating {
                translationInProgress
            } else if case let .failed(message) = store.status {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
            } else if !store.sentences.isEmpty {
                paragraphTranslation
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if store.isAIGenerating {
                stopGenerationButton
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    @ViewBuilder
    private var translationInProgress: some View {
        if !store.thinkingText.isEmpty {
            thinkingProcessView
        } else if !store.streamingTranslation.isEmpty {
            ScrollView {
                Text(store.streamingTranslation)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 16)
        } else {
            ProgressView()
                .controlSize(.regular)
        }
    }

    private var thinkingProcessView: some View {
        ScrollView {
            Text(store.thinkingText)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .opacity(0.72)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var paragraphTranslation: some View {
        TranslatedParagraphTextView(
            sentences: store.sentences,
            direction: store.direction,
            highlightedSentenceID: store.hoveredSourceSentenceID,
            highlightOpacity: highlightOpacity,
            isActive: isActive
        )
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var selectionResult: some View {
        if case let .failed(message) = store.status, store.markdownResult.isEmpty {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 26)
                .padding(.top, 24)
        } else if !store.thinkingText.isEmpty {
            thinkingProcessView
        } else if store.markdownResult.isEmpty {
            ProgressView()
                .controlSize(.regular)
        } else {
            ScrollView {
                Text(LocalizedStringKey(store.markdownResult))
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
    }

    private var stopGenerationButton: some View {
        Button {
            store.stopAIGeneration()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("停止")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .help("停止本次 AI 生成")
    }

    private var configuration: AIConfiguration {
        let effort = reasoningEffort == "custom" ? "low" : reasoningEffort
        return AIConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            reasoningEffort: effort
        )
    }

    private var translationPrompt: String {
        let trimmed = translationInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PromptDefaults.translationInstructions : translationInstructions
    }

    private var contextPrompt: String {
        let trimmed = contextPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PromptDefaults.contextPromptTemplate : contextPromptTemplate
    }
}
