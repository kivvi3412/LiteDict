import Combine
import Foundation

@MainActor
final class SentenceTranslateStore: ObservableObject {
    static let shared = SentenceTranslateStore()

    @Published var inputText = ""
    @Published var selectedText = ""
    @Published var selectionRange = NSRange(location: 0, length: 0)
    @Published var sentences: [SentencePair] = []
    @Published var translatedInput = ""
    @Published var markdownResult = ""
    @Published var thinkingText = ""
    @Published var streamingTranslation = ""
    @Published var sourceSentenceRanges: [SourceSentenceRange] = []
    @Published var hoveredSourceSentenceID: Int?
    @Published var status: TranslationStatus = .idle
    @Published var selectionResetToken = 0

    var sourceScrollOffset: CGFloat = 0
    var targetScrollOffset: CGFloat = 0

    private var translationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var suppressSelectionRestart = false

    private init() {}

    var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSelection: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAIGenerating: Bool {
        status == .translating || status == .analyzing
    }

    var hasActionableSelection: Bool {
        guard !trimmedSelection.isEmpty, !trimmedInput.isEmpty else { return false }
        let sourceLength = (trimmedInput as NSString).length
        return sourceLength == 0 || Double(selectionRange.length) / Double(sourceLength) <= 0.9
    }

    var direction: TranslationDirection {
        TranslationDirection.detect(from: trimmedInput)
    }

    var highlightedSourceRange: NSRange? {
        guard let hoveredSentenceID = hoveredSourceSentenceID else { return nil }
        if let alignedRange = sourceSentenceRanges.first(where: {
            $0.id == hoveredSentenceID
        })?.range {
            return alignedRange
        }

        guard let sentence = sentences.first(where: { $0.id == hoveredSentenceID }) else {
            return nil
        }
        return SentenceAlignmentEngine.exactSourceRange(
            for: direction.sourceText(for: sentence),
            in: inputText
        )
    }

    func updateHoveredSourceCharacter(_ characterIndex: Int?) {
        guard let characterIndex else {
            if hoveredSourceSentenceID != nil {
                hoveredSourceSentenceID = nil
            }
            return
        }

        let sentenceID = SentenceAlignmentEngine.sentenceID(
            at: characterIndex,
            in: inputText,
            ranges: sourceSentenceRanges
        )
        if hoveredSourceSentenceID != sentenceID {
            hoveredSourceSentenceID = sentenceID
        }
    }

    func inputDidChange(
        _ newValue: String,
        configuration: AIConfiguration,
        instructions: String
    ) {
        selectionTask?.cancel()
        translationTask?.cancel()
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        sourceSentenceRanges = []
        sentences = []
        translatedInput = ""
        targetScrollOffset = 0
        if newValue.isEmpty {
            sourceScrollOffset = 0
        }
        status = .idle

        if !selectedText.isEmpty {
            selectedText = ""
            selectionRange = NSRange(location: 0, length: 0)
            selectionResetToken &+= 1
        }

        let source = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        scheduleParagraphTranslation(
            for: source,
            configuration: configuration,
            instructions: instructions
        )
    }

    func selectionDidChange(
        _ newValue: String,
        configuration: AIConfiguration,
        translationInstructions: String,
        contextPromptTemplate: String
    ) {
        let selection = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        selectionTask?.cancel()

        guard !selection.isEmpty, !trimmedInput.isEmpty else {
            if suppressSelectionRestart {
                suppressSelectionRestart = false
                markdownResult = ""
                thinkingText = ""
                status = .idle
                return
            }
            markdownResult = ""
            thinkingText = ""
            if !trimmedInput.isEmpty, translatedInput != trimmedInput {
                scheduleParagraphTranslation(
                    for: trimmedInput,
                    configuration: configuration,
                    instructions: translationInstructions,
                    delayNanoseconds: 250_000_000
                )
            } else if !sentences.isEmpty {
                status = .idle
            }
            return
        }

        let context = SentenceAlignmentEngine.makeSelectionContext(
            for: selection,
            in: inputText,
            selectionRange: selectionRange,
            sourceSentenceRanges: sourceSentenceRanges
        )
        if let context, context.coverage > 0.9 {
            selectionTask?.cancel()
            markdownResult = ""
            thinkingText = ""
            streamingTranslation = ""
            hoveredSourceSentenceID = nil
            status = .idle
            return
        }

        translationTask?.cancel()
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        status = .idle

        let source = trimmedInput

        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                guard self.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection,
                      self.trimmedInput == source else {
                    return
                }

                self.status = .analyzing
                let result = try await Services.shared.analyzeSelectionStreaming(
                    selectedText: selection,
                    allInputText: source,
                    configuration: configuration,
                    promptTemplate: contextPromptTemplate,
                    selectionContext: context,
                    onThinkingDelta: { [weak self] delta in
                        guard !Task.isCancelled else { return }
                        self?.thinkingText += delta
                    },
                    onMarkdownUpdate: { [weak self] partialMarkdown in
                        guard !Task.isCancelled else { return }
                        self?.thinkingText = ""
                        self?.markdownResult = partialMarkdown
                    }
                )
                try Task.checkCancellation()
                guard self.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection else {
                    return
                }

                self.markdownResult = result
                self.thinkingText = ""
                self.status = .idle
            } catch is CancellationError {
                return
            } catch {
                guard self.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection else {
                    return
                }
                self.markdownResult = ""
                self.thinkingText = ""
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func scheduleParagraphTranslation(
        for source: String,
        configuration: AIConfiguration,
        instructions: String,
        delayNanoseconds: UInt64 = 1_000_000_000
    ) {
        translationTask?.cancel()
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                guard self.trimmedInput == input, self.trimmedSelection.isEmpty else { return }

                self.thinkingText = ""
                self.streamingTranslation = ""
                self.hoveredSourceSentenceID = nil
                self.sourceSentenceRanges = []
                self.status = .translating
                let pairs = try await Services.shared.translateSentencesStreaming(
                    allInputText: input,
                    configuration: configuration,
                    instructions: instructions,
                    onThinkingDelta: { [weak self] delta in
                        guard !Task.isCancelled else { return }
                        self?.thinkingText += delta
                    },
                    onTranslationUpdate: { [weak self] preview in
                        guard !Task.isCancelled else { return }
                        self?.thinkingText = ""
                        self?.streamingTranslation = preview
                    }
                )
                try Task.checkCancellation()
                guard self.trimmedInput == input, self.trimmedSelection.isEmpty else { return }

                self.sentences = pairs
                self.sourceSentenceRanges = SentenceAlignmentEngine.alignSourceSentences(
                    pairs,
                    in: self.inputText,
                    direction: self.direction
                )
                self.translatedInput = input
                self.thinkingText = ""
                self.streamingTranslation = ""
                self.status = .idle
            } catch is CancellationError {
                return
            } catch {
                guard self.trimmedInput == input, self.trimmedSelection.isEmpty else { return }
                self.thinkingText = ""
                self.streamingTranslation = ""
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func dismissSelection(
        configuration: AIConfiguration,
        instructions: String
    ) {
        guard !selectedText.isEmpty else { return }
        selectionTask?.cancel()
        selectedText = ""
        selectionRange = NSRange(location: 0, length: 0)
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        selectionResetToken &+= 1
        status = .idle

        if !trimmedInput.isEmpty, translatedInput != trimmedInput {
            scheduleParagraphTranslation(
                for: trimmedInput,
                configuration: configuration,
                instructions: instructions,
                delayNanoseconds: 250_000_000
            )
        }
    }

    func stopAIGeneration() {
        let wasAnalyzing = status == .analyzing
        translationTask?.cancel()
        selectionTask?.cancel()
        thinkingText = ""
        streamingTranslation = ""
        markdownResult = ""
        status = .idle

        guard wasAnalyzing else { return }
        suppressSelectionRestart = true
        selectedText = ""
        selectionRange = NSRange(location: 0, length: 0)
        selectionResetToken &+= 1
    }
}
