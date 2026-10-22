import AppKit
import SwiftUI

private enum SentenceHighlightPalette {
    static func color(opacity: Double) -> Color {
        Color(nsColor: nsColor(opacity: opacity))
    }

    static func nsColor(opacity: Double) -> NSColor {
        NSColor.systemYellow.withAlphaComponent(CGFloat(opacity))
    }
}

private struct SourceSentenceRange: Identifiable {
    let id: Int
    let range: NSRange
}

struct SentenceTranslateView: View {
    @AppStorage(PreferenceKey.openAIBaseURL) private var baseURL = "https://api.deepseek.com"
    @AppStorage(PreferenceKey.openAIAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKey.openAIModel) private var model = "deepseek-flash"
    @AppStorage(PreferenceKey.reasoningEffort) private var reasoningEffort = "low"
    @AppStorage(PreferenceKey.customReasoningEffort)
    private var customReasoningEffort = ""
    @AppStorage(PreferenceKey.highlightOpacity)
    private var highlightOpacity = 0.2
    @AppStorage(PreferenceKey.translationInstructions)
    private var translationInstructions = PromptDefaults.translationInstructions
    @AppStorage(PreferenceKey.contextPromptTemplate)
    private var contextPromptTemplate = PromptDefaults.contextPromptTemplate

    @State private var inputText = ""
    @State private var selectedText = ""
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var sentences: [SentencePair] = []
    @State private var translatedInput = ""
    @State private var markdownResult = ""
    @State private var thinkingText = ""
    @State private var streamingTranslation = ""
    @State private var sourceSentenceRanges: [SourceSentenceRange] = []
    @State private var hoveredSourceSentenceID: Int?
    @State private var hoveredTargetSentenceID: Int?
    @State private var status: TranslationStatus = .idle
    @State private var translationTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionResetToken = 0
    @State private var suppressSelectionRestart = false

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
        }
        .background(Color.clear)
        .onChange(of: inputText) { _, newValue in
            inputDidChange(newValue)
        }
        .onChange(of: selectedText) { _, newValue in
            selectionDidChange(newValue)
        }
        .onDisappear {
            translationTask?.cancel()
            selectionTask?.cancel()
        }
    }

    private var sourcePane: some View {
        SelectableTextView(
            text: $inputText,
            selectedText: $selectedText,
            selectionRange: $selectionRange,
            clearSelectionToken: selectionResetToken,
            highlightedSentenceRange: highlightedSourceRange,
            onHoveredCharacterIndex: updateHoveredSourceCharacter,
            highlightOpacity: highlightOpacity
        )
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var resultPane: some View {
        Group {
            if hasActionableSelection {
                selectionResult
            } else if status == .translating {
                translationInProgress
            } else if case let .failed(message) = status {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
            } else if !sentences.isEmpty {
                paragraphTranslation
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if !isAIGenerating {
                    dismissSelection()
                }
            }
        )
        .overlay(alignment: .topTrailing) {
            if isAIGenerating {
                stopGenerationButton
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    @ViewBuilder
    private var translationInProgress: some View {
        if !thinkingText.isEmpty {
            thinkingProcessView
        } else if !streamingTranslation.isEmpty {
            ScrollView {
                Text(streamingTranslation)
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
            Text(thinkingText)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sentences) { sentence in
                    Text(direction.targetText(for: sentence))
                        .font(.system(size: 17))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            hoveredSentenceID == sentence.id
                                ? SentenceHighlightPalette.color(opacity: highlightOpacity)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onHover { isHovered in
                            if isHovered {
                                hoveredTargetSentenceID = sentence.id
                            } else if hoveredTargetSentenceID == sentence.id {
                                hoveredTargetSentenceID = nil
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.12), value: hoveredSentenceID)
    }

    @ViewBuilder
    private var selectionResult: some View {
        if case let .failed(message) = status, markdownResult.isEmpty {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 26)
                .padding(.top, 24)
        } else if !thinkingText.isEmpty {
            thinkingProcessView
        } else if markdownResult.isEmpty {
            ProgressView()
                .controlSize(.regular)
        } else {
            ScrollView {
                Text(LocalizedStringKey(markdownResult))
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

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSelection: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAIGenerating: Bool {
        status == .translating || status == .analyzing
    }

    private var stopGenerationButton: some View {
        Button {
            stopAIGeneration()
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

    private var hasActionableSelection: Bool {
        guard !trimmedSelection.isEmpty, !trimmedInput.isEmpty else { return false }
        let sourceLength = (trimmedInput as NSString).length
        return sourceLength == 0 || Double(selectionRange.length) / Double(sourceLength) <= 0.9
    }

    private var direction: TranslationDirection {
        TranslationDirection.detect(from: trimmedInput)
    }

    private var hoveredSentenceID: Int? {
        hoveredSourceSentenceID ?? hoveredTargetSentenceID
    }

    private var highlightedSourceRange: NSRange? {
        guard let hoveredSentenceID else { return nil }
        if let alignedRange = sourceSentenceRanges.first(where: {
            $0.id == hoveredSentenceID
        })?.range {
            return alignedRange
        }

        guard let sentence = sentences.first(where: { $0.id == hoveredSentenceID }) else {
            return nil
        }
        return exactSourceRange(for: direction.sourceText(for: sentence))
    }

    private var configuration: AIConfiguration {
        let custom = customReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = reasoningEffort == "custom"
            ? (custom.isEmpty ? "low" : custom)
            : reasoningEffort
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

    private func updateHoveredSourceCharacter(_ characterIndex: Int?) {
        guard let characterIndex else {
            if hoveredSourceSentenceID != nil {
                hoveredSourceSentenceID = nil
            }
            return
        }

        let sentenceID = sourceSentenceRanges.first(where: {
            NSLocationInRange(characterIndex, $0.range)
        })?.id
        if hoveredSourceSentenceID != sentenceID {
            hoveredSourceSentenceID = sentenceID
        }
    }

    private func exactSourceRange(for sentence: String) -> NSRange? {
        let source = inputText as NSString
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var range = source.range(of: trimmed, options: options)
        if range.location != NSNotFound {
            return range
        }

        let unquoted = trimmed.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"“”'‘’")
        )
        range = source.range(of: unquoted, options: options)
        return range.location == NSNotFound ? nil : range
    }

    private func alignSourceSentences(
        _ sentences: [SentencePair],
        in source: String,
        direction: TranslationDirection
    ) -> [SourceSentenceRange] {
        let sourceIndex = NormalizedTextIndex(source)
        var normalizedSearchStart = 0
        var alignedRanges: [SourceSentenceRange] = []

        for sentence in sentences {
            guard let match = sourceIndex.firstMatch(
                for: direction.sourceText(for: sentence),
                startingAt: normalizedSearchStart
            ) else {
                continue
            }

            alignedRanges.append(
                SourceSentenceRange(id: sentence.id, range: match.rawRange)
            )
            normalizedSearchStart = match.normalizedEnd
        }

        return alignedRanges
    }

    private func inputDidChange(_ newValue: String) {
        selectionTask?.cancel()
        translationTask?.cancel()
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        hoveredTargetSentenceID = nil
        sourceSentenceRanges = []
        sentences = []
        translatedInput = ""
        status = .idle

        if !selectedText.isEmpty {
            selectedText = ""
            selectionRange = NSRange(location: 0, length: 0)
            selectionResetToken &+= 1
        }

        let source = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        scheduleParagraphTranslation(for: source)
    }

    private func selectionDidChange(_ newValue: String) {
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
                    delayNanoseconds: 250_000_000
                )
            } else if !sentences.isEmpty {
                status = .idle
            }
            return
        }

        let context = makeSelectionContext(for: selection)
        if let context, context.coverage > 0.9 {
            selectionTask?.cancel()
            markdownResult = ""
            thinkingText = ""
            streamingTranslation = ""
            hoveredSourceSentenceID = nil
            hoveredTargetSentenceID = nil
            status = .idle
            return
        }

        translationTask?.cancel()
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        hoveredTargetSentenceID = nil
        status = .idle

        let source = trimmedInput
        let currentConfiguration = configuration
        let prompt = contextPrompt

        selectionTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                guard selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection,
                      trimmedInput == source else {
                    return
                }

                status = .analyzing
                let result = try await Services.shared.analyzeSelectionStreaming(
                    selectedText: selection,
                    allInputText: source,
                    configuration: currentConfiguration,
                    promptTemplate: prompt,
                    selectionContext: context,
                    onThinkingDelta: { delta in
                        guard !Task.isCancelled else { return }
                        thinkingText += delta
                    },
                    onMarkdownUpdate: { partialMarkdown in
                        guard !Task.isCancelled else { return }
                        thinkingText = ""
                        markdownResult = partialMarkdown
                    }
                )
                try Task.checkCancellation()
                guard selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection else {
                    return
                }

                markdownResult = result
                thinkingText = ""
                status = .idle
            } catch is CancellationError {
                return
            } catch {
                guard selectedText.trimmingCharacters(in: .whitespacesAndNewlines) == selection else {
                    return
                }
                markdownResult = ""
                thinkingText = ""
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func makeSelectionContext(for selection: String) -> SelectionContext? {
        let source = inputText as NSString
        guard source.length > 0 else { return nil }

        let searchOptions: NSString.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive
        ]
        var range = selectionRange

        if range.length == 0
            || NSMaxRange(range) > source.length
            || source.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(selection, options: searchOptions) != .orderedSame {
            range = source.range(of: selection, options: searchOptions)
        }

        guard range.location != NSNotFound, range.length > 0 else {
            return nil
        }

        let alignedSentenceIndex = sourceSentenceRanges.firstIndex {
            NSLocationInRange(range.location, $0.range)
        }
        let fallbackSentenceRanges = alignedSentenceIndex == nil
            ? sentenceRanges(in: source)
            : []
        let fallbackSentenceIndex = fallbackSentenceRanges.firstIndex {
            NSLocationInRange(range.location, $0)
        } ?? 0
        let contextSentenceRange: NSRange?

        if let alignedSentenceIndex {
            contextSentenceRange = sourceSentenceRanges[alignedSentenceIndex].range
        } else {
            contextSentenceRange = fallbackSentenceRanges.indices.contains(fallbackSentenceIndex)
                ? fallbackSentenceRanges[fallbackSentenceIndex]
                : nil
        }

        let sentence = contextSentenceRange
            .map {
                source.substring(with: $0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? source as String
        let sentenceIndex = alignedSentenceIndex ?? fallbackSentenceIndex

        var occurrences: [NSRange] = []
        var searchLocation = 0
        while searchLocation < source.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let found = source.range(of: selection, options: searchOptions, range: searchRange)
            guard found.location != NSNotFound else { break }
            occurrences.append(found)
            searchLocation = NSMaxRange(found)
        }

        let occurrenceIndex = occurrences.firstIndex(where: {
            $0.location == range.location && $0.length == range.length
        }).map { $0 + 1 }
            ?? occurrences.filter { $0.location < range.location }.count + 1

        return SelectionContext(
            text: selection,
            range: range,
            sourceLength: source.length,
            sentence: sentence,
            sentenceIndex: sentenceIndex + 1,
            occurrenceIndex: max(occurrenceIndex, 1),
            occurrenceCount: max(occurrences.count, 1)
        )
    }

    private func sentenceRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var sentenceStart = 0
        var index = 0

        while index < source.length {
            let character = source.character(at: index)
            let isTerminator = character == 46
                || character == 33
                || character == 63
                || character == 0x3002
                || character == 0xFF01
                || character == 0xFF1F

            if isTerminator {
                var end = index + 1
                while end < source.length,
                      [9, 10, 13, 32].contains(source.character(at: end)) {
                    end += 1
                }

                let range = NSRange(location: sentenceStart, length: end - sentenceStart)
                if !source.substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ranges.append(range)
                }
                sentenceStart = end
                index = end
            } else {
                index += 1
            }
        }

        if sentenceStart < source.length {
            let range = NSRange(
                location: sentenceStart,
                length: source.length - sentenceStart
            )
            if !source.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranges.append(range)
            }
        }

        return ranges.isEmpty
            ? [NSRange(location: 0, length: source.length)]
            : ranges
    }

    private func scheduleParagraphTranslation(
        for source: String,
        delayNanoseconds: UInt64 = 1_000_000_000
    ) {
        translationTask?.cancel()
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let currentConfiguration = configuration
        let instructions = translationPrompt

        translationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                guard trimmedInput == input, trimmedSelection.isEmpty else { return }

                thinkingText = ""
                streamingTranslation = ""
                hoveredSourceSentenceID = nil
                hoveredTargetSentenceID = nil
                sourceSentenceRanges = []
                status = .translating
                let pairs = try await Services.shared.translateSentencesStreaming(
                    allInputText: input,
                    configuration: currentConfiguration,
                    instructions: instructions,
                    onThinkingDelta: { delta in
                        guard !Task.isCancelled else { return }
                        thinkingText += delta
                    },
                    onTranslationUpdate: { preview in
                        guard !Task.isCancelled else { return }
                        thinkingText = ""
                        streamingTranslation = preview
                    }
                )
                try Task.checkCancellation()
                guard trimmedInput == input, trimmedSelection.isEmpty else { return }

                sentences = pairs
                sourceSentenceRanges = alignSourceSentences(
                    pairs,
                    in: inputText,
                    direction: direction
                )
                translatedInput = input
                thinkingText = ""
                streamingTranslation = ""
                status = .idle
            } catch is CancellationError {
                return
            } catch {
                guard trimmedInput == input, trimmedSelection.isEmpty else { return }
                thinkingText = ""
                streamingTranslation = ""
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func dismissSelection() {
        guard !selectedText.isEmpty else { return }
        selectionTask?.cancel()
        selectedText = ""
        selectionRange = NSRange(location: 0, length: 0)
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        hoveredTargetSentenceID = nil
        selectionResetToken &+= 1
        status = .idle

        if !trimmedInput.isEmpty, translatedInput != trimmedInput {
            scheduleParagraphTranslation(
                for: trimmedInput,
                delayNanoseconds: 250_000_000
            )
        }
    }

    private func stopAIGeneration() {
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

// MARK: - NSTextView bridge

struct SelectableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    @Binding var selectionRange: NSRange
    let clearSelectionToken: Int
    let highlightedSentenceRange: NSRange?
    let onHoveredCharacterIndex: ((Int?) -> Void)?
    let highlightOpacity: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = SentenceHighlightingTextView(
            frame: .zero,
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.onHoveredCharacterIndex = { [weak coordinator = context.coordinator] index in
            coordinator?.parent.onHoveredCharacterIndex?(index)
        }
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.placeholder = "Input text here"

        DispatchQueue.main.async {
            if let window = textView.window {
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? SentenceHighlightingTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
            textView.resetHoveredCharacter()
        }
        textView.placeholder = "Input text here"

        if context.coordinator.lastClearSelectionToken != clearSelectionToken {
            context.coordinator.lastClearSelectionToken = clearSelectionToken
            let range = textView.selectedRange()
            if range.length > 0 {
                textView.setSelectedRange(NSRange(location: range.location, length: 0))
            }
        }

        applySentenceHighlight(to: textView, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        var lastClearSelectionToken: Int
        var lastHighlightedRange: NSRange?
        var lastHighlightedText = ""
        var lastHighlightOpacity: Double?

        init(_ parent: SelectableTextView) {
            self.parent = parent
            lastClearSelectionToken = parent.clearSelectionToken
            lastHighlightedRange = parent.highlightedSentenceRange
            lastHighlightedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()

            if range.length > 0, let swiftRange = Range(range, in: textView.string) {
                let selection = String(textView.string[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.parent.selectedText = selection
                    self.parent.selectionRange = range
                }
            } else {
                DispatchQueue.main.async {
                    self.parent.selectedText = ""
                    self.parent.selectionRange = NSRange(location: 0, length: 0)
                }
            }
        }
    }

    private func applySentenceHighlight(
        to textView: SentenceHighlightingTextView,
        coordinator: Coordinator
    ) {
        guard coordinator.lastHighlightedRange != highlightedSentenceRange
                || coordinator.lastHighlightedText != textView.string
                || coordinator.lastHighlightOpacity != highlightOpacity else {
            return
        }

        coordinator.lastHighlightedRange = highlightedSentenceRange
        coordinator.lastHighlightedText = textView.string
        coordinator.lastHighlightOpacity = highlightOpacity

        guard let highlightedSentenceRange else {
            textView.highlightedRange = nil
            return
        }

        let sourceLength = (textView.string as NSString).length
        guard highlightedSentenceRange.location != NSNotFound,
              highlightedSentenceRange.length > 0,
              NSMaxRange(highlightedSentenceRange) <= sourceLength else {
            textView.highlightedRange = nil
            return
        }

        textView.highlightColor = SentenceHighlightPalette.nsColor(
            opacity: highlightOpacity
        )
        textView.highlightedRange = highlightedSentenceRange
        textView.scrollRangeToVisible(highlightedSentenceRange)
    }
}

private struct NormalizedTextIndex {
    struct Match {
        let rawRange: NSRange
        let normalizedEnd: Int
    }

    private let normalizedText: NSString
    private let rawStarts: [Int]
    private let rawEnds: [Int]

    init(_ source: String) {
        var normalized = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var rawLocation = 0

        for character in source {
            let characterLength = (String(character) as NSString).length
            let normalizedCharacter = Self.normalize(character)
            let normalizedLength = (normalizedCharacter as NSString).length

            if normalizedLength > 0 {
                normalized += normalizedCharacter
                starts.append(contentsOf: repeatElement(
                    rawLocation,
                    count: normalizedLength
                ))
                ends.append(contentsOf: repeatElement(
                    rawLocation + characterLength,
                    count: normalizedLength
                ))
            }
            rawLocation += characterLength
        }

        normalizedText = normalized as NSString
        rawStarts = starts
        rawEnds = ends
    }

    func firstMatch(for candidate: String, startingAt location: Int) -> Match? {
        var query = ""
        for character in candidate {
            query += Self.normalize(character)
        }
        guard !query.isEmpty else { return nil }

        let start = min(max(0, location), normalizedText.length)
        let searchRange = NSRange(
            location: start,
            length: normalizedText.length - start
        )
        let normalizedRange = normalizedText.range(
            of: query,
            options: [],
            range: searchRange
        )
        guard normalizedRange.location != NSNotFound,
              normalizedRange.length > 0,
              NSMaxRange(normalizedRange) <= rawEnds.count else {
            return nil
        }

        let rawStart = rawStarts[normalizedRange.location]
        let rawEnd = rawEnds[NSMaxRange(normalizedRange) - 1]
        return Match(
            rawRange: NSRange(location: rawStart, length: rawEnd - rawStart),
            normalizedEnd: NSMaxRange(normalizedRange)
        )
    }

    private static func normalize(_ character: Character) -> String {
        if character.isWhitespace {
            return ""
        }

        let text = String(character)
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
            switch scalar.value {
            case 0x002D, 0x00AD, 0x200B, 0x2010, 0x2011:
                return ""
            default:
                break
            }
        }

        return text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: "...")
    }
}

private final class SentenceHighlightingTextView: NSTextView {
    var onHoveredCharacterIndex: ((Int?) -> Void)?

    var placeholder = "" {
        didSet {
            needsDisplay = true
        }
    }

    var highlightedRange: NSRange? {
        didSet {
            needsDisplay = true
        }
    }

    var highlightColor = NSColor.systemYellow.withAlphaComponent(0.2) {
        didSet {
            needsDisplay = true
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredCharacterIndex: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredCharacter(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredCharacterIndex(nil)
    }

    func resetHoveredCharacter() {
        setHoveredCharacterIndex(nil)
    }

    private func updateHoveredCharacter(at windowPoint: NSPoint) {
        guard let layoutManager, let textContainer, !string.isEmpty else {
            setHoveredCharacterIndex(nil)
            return
        }

        let viewPoint = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        guard containerPoint.x >= 0, containerPoint.y >= 0 else {
            setHoveredCharacterIndex(nil)
            return
        }

        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            setHoveredCharacterIndex(nil)
            return
        }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard glyphRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else {
            setHoveredCharacterIndex(nil)
            return
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < (string as NSString).length else {
            setHoveredCharacterIndex(nil)
            return
        }
        setHoveredCharacterIndex(characterIndex)
    }

    private func setHoveredCharacterIndex(_ index: Int?) {
        guard hoveredCharacterIndex != index else { return }
        hoveredCharacterIndex = index
        DispatchQueue.main.async { [weak self] in
            self?.onHoveredCharacterIndex?(index)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        if string.isEmpty, !placeholder.isEmpty {
            let placeholderColor = NSColor.placeholderTextColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 17),
                .foregroundColor: placeholderColor
            ]
            let origin = textContainerOrigin
            let padding = textContainer?.lineFragmentPadding ?? 0
            (placeholder as NSString).draw(
                at: NSPoint(x: origin.x + padding, y: origin.y),
                withAttributes: attributes
            )
        }

        guard let highlightedRange,
              let layoutManager,
              let textContainer,
              highlightedRange.location != NSNotFound else {
            return
        }

        let sourceLength = (string as NSString).length
        let validRange = NSIntersectionRange(
            highlightedRange,
            NSRange(location: 0, length: sourceLength)
        )
        guard validRange.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: validRange,
            actualCharacterRange: nil
        )
        let origin = textContainerOrigin
        let color = highlightColor

        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            let drawRect = rect
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -1, dy: 1)
            color.setFill()
            NSBezierPath(rect: drawRect).fill()
        }
    }
}
