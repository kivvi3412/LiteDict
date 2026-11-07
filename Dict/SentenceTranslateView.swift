import AppKit
import Combine
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

@MainActor
private final class SentenceTranslateStore: ObservableObject {
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
    var translationTask: Task<Void, Never>?
    var selectionTask: Task<Void, Never>?
    var suppressSelectionRestart = false
}

struct SentenceTranslateView: View {
    var isActive = true

    @AppStorage(PreferenceKey.openAIBaseURL) private var baseURL = "https://api.deepseek.com"
    @AppStorage(PreferenceKey.openAIAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKey.openAIModel) private var model = "deepseek-flash"
    @AppStorage(PreferenceKey.reasoningEffort) private var reasoningEffort = "low"
    @AppStorage(PreferenceKey.highlightOpacity)
    private var highlightOpacity = 0.2
    @AppStorage(PreferenceKey.translationInstructions)
    private var translationInstructions = PromptDefaults.translationInstructions
    @AppStorage(PreferenceKey.contextPromptTemplate)
    private var contextPromptTemplate = PromptDefaults.contextPromptTemplate

    @ObservedObject private var store = SentenceTranslateStore.shared

    private var inputText: String {
        get { store.inputText }
        nonmutating set { store.inputText = newValue }
    }

    private var selectedText: String {
        get { store.selectedText }
        nonmutating set { store.selectedText = newValue }
    }

    private var selectionRange: NSRange {
        get { store.selectionRange }
        nonmutating set { store.selectionRange = newValue }
    }

    private var sentences: [SentencePair] {
        get { store.sentences }
        nonmutating set { store.sentences = newValue }
    }

    private var translatedInput: String {
        get { store.translatedInput }
        nonmutating set { store.translatedInput = newValue }
    }

    private var markdownResult: String {
        get { store.markdownResult }
        nonmutating set { store.markdownResult = newValue }
    }

    private var thinkingText: String {
        get { store.thinkingText }
        nonmutating set { store.thinkingText = newValue }
    }

    private var streamingTranslation: String {
        get { store.streamingTranslation }
        nonmutating set { store.streamingTranslation = newValue }
    }

    private var sourceSentenceRanges: [SourceSentenceRange] {
        get { store.sourceSentenceRanges }
        nonmutating set { store.sourceSentenceRanges = newValue }
    }

    private var hoveredSourceSentenceID: Int? {
        get { store.hoveredSourceSentenceID }
        nonmutating set { store.hoveredSourceSentenceID = newValue }
    }

    private var status: TranslationStatus {
        get { store.status }
        nonmutating set { store.status = newValue }
    }

    private var translationTask: Task<Void, Never>? {
        get { store.translationTask }
        nonmutating set { store.translationTask = newValue }
    }

    private var selectionTask: Task<Void, Never>? {
        get { store.selectionTask }
        nonmutating set { store.selectionTask = newValue }
    }

    private var selectionResetToken: Int {
        get { store.selectionResetToken }
        nonmutating set { store.selectionResetToken = newValue }
    }

    private var suppressSelectionRestart: Bool {
        get { store.suppressSelectionRestart }
        nonmutating set { store.suppressSelectionRestart = newValue }
    }

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
                    hoveredSourceSentenceID = nil
                }
            }
        }
        .background(Color.clear)
        .onChange(of: store.inputText) { _, newValue in
            inputDidChange(newValue)
        }
        .onChange(of: store.selectedText) { _, newValue in
            selectionDidChange(newValue)
        }
    }

    private var sourcePane: some View {
        SelectableTextView(
            text: $store.inputText,
            selectedText: $store.selectedText,
            selectionRange: $store.selectionRange,
            clearSelectionToken: selectionResetToken,
            highlightedSentenceRange: highlightedSourceRange,
            onHoveredCharacterIndex: updateHoveredSourceCharacter,
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
        TranslatedParagraphTextView(
            sentences: sentences,
            direction: direction,
            highlightedSentenceID: hoveredSentenceID,
            highlightOpacity: highlightOpacity,
            isActive: isActive
        )
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
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
        hoveredSourceSentenceID
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

    private func updateHoveredSourceCharacter(_ characterIndex: Int?) {
        guard let characterIndex else {
            if hoveredSourceSentenceID != nil {
                hoveredSourceSentenceID = nil
            }
            return
        }

        let sentenceID = sentenceID(at: characterIndex)
        if hoveredSourceSentenceID != sentenceID {
            hoveredSourceSentenceID = sentenceID
        }
    }

    private func sentenceID(at characterIndex: Int) -> Int? {
        if let exact = sourceSentenceRanges.first(where: {
            NSLocationInRange(characterIndex, $0.range)
        }) {
            return exact.id
        }

        let nsSource = inputText as NSString
        guard characterIndex >= 0, characterIndex < nsSource.length else {
            return nil
        }
        let lineRange = nsSource.lineRange(
            for: NSRange(location: characterIndex, length: 0)
        )

        var bestID: Int?
        var bestDistance = Int.max
        for item in sourceSentenceRanges {
            let intersection = NSIntersectionRange(item.range, lineRange)
            guard intersection.length > 0 else { continue }

            let distance: Int
            if characterIndex < item.range.location {
                distance = item.range.location - characterIndex
            } else {
                distance = characterIndex - NSMaxRange(item.range) + 1
            }

            if distance < bestDistance {
                bestDistance = distance
                bestID = item.id
            }
        }
        return bestID
    }

    private func exactSourceRange(
        for sentence: String,
        startingAt location: Int = 0
    ) -> NSRange? {
        let source = inputText as NSString
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, source.length > 0 else { return nil }

        let safeStart = min(max(0, location), source.length)
        let searchRange = NSRange(
            location: safeStart,
            length: source.length - safeStart
        )
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var range = source.range(of: trimmed, options: options, range: searchRange)
        if range.location != NSNotFound {
            return range
        }

        let unquoted = trimmed.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"“”'‘’")
        )
        range = source.range(of: unquoted, options: options, range: searchRange)
        return range.location == NSNotFound ? nil : range
    }

    private func alignSourceSentences(
        _ sentences: [SentencePair],
        in source: String,
        direction: TranslationDirection
    ) -> [SourceSentenceRange] {
        guard !sentences.isEmpty else { return [] }
        let nsSource = source as NSString
        let sourceIndex = NormalizedTextIndex(source)
        var normalizedSearchStart = 0
        var rawSearchStart = 0
        var matchedRanges: [NSRange?] = Array(repeating: nil, count: sentences.count)

        for (index, sentence) in sentences.enumerated() {
            let target = direction.sourceText(for: sentence)
            if let match = sourceIndex.firstMatch(
                for: target,
                startingAt: normalizedSearchStart
            ) {
                matchedRanges[index] = match.rawRange
                normalizedSearchStart = match.normalizedEnd
                rawSearchStart = NSMaxRange(match.rawRange)
            } else if let fallback = exactSourceRange(
                for: target,
                startingAt: rawSearchStart
            ) {
                matchedRanges[index] = fallback
                rawSearchStart = NSMaxRange(fallback)
            }
        }

        var index = 0
        while index < sentences.count {
            guard matchedRanges[index] == nil else {
                index += 1
                continue
            }

            let gapStart = index > 0
                ? (matchedRanges[index - 1].map { NSMaxRange($0) } ?? 0)
                : 0
            var nextMatchedIndex = index + 1
            while nextMatchedIndex < sentences.count,
                  matchedRanges[nextMatchedIndex] == nil {
                nextMatchedIndex += 1
            }
            let gapEnd = nextMatchedIndex < sentences.count
                ? (matchedRanges[nextMatchedIndex]?.location ?? nsSource.length)
                : nsSource.length

            if gapEnd > gapStart {
                let rawGap = NSRange(location: gapStart, length: gapEnd - gapStart)
                let fallbackSlices = sentenceRanges(
                    in: nsSource.substring(with: rawGap) as NSString
                )
                let count = nextMatchedIndex - index
                for offset in 0..<count {
                    if offset < fallbackSlices.count {
                        let local = fallbackSlices[offset]
                        let global = NSRange(
                            location: gapStart + local.location,
                            length: local.length
                        )
                        matchedRanges[index + offset] = trimmedRange(
                            global,
                            in: nsSource
                        )
                    } else {
                        matchedRanges[index + offset] = trimmedRange(
                            rawGap,
                            in: nsSource
                        )
                    }
                }
            }
            index = nextMatchedIndex
        }

        return zip(sentences, matchedRanges).compactMap { sentence, range in
            guard let range, range.length > 0 else { return nil }
            return SourceSentenceRange(id: sentence.id, range: range)
        }
    }

    private func trimmedRange(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end,
              let scalar = UnicodeScalar(source.character(at: start)),
              whitespace.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(source.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func inputDidChange(_ newValue: String) {
        selectionTask?.cancel()
        translationTask?.cancel()
        markdownResult = ""
        thinkingText = ""
        streamingTranslation = ""
        hoveredSourceSentenceID = nil
        sourceSentenceRanges = []
        sentences = []
        translatedInput = ""
        store.targetScrollOffset = 0
        if newValue.isEmpty {
            store.sourceScrollOffset = 0
        }
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
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SentenceHighlightingTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 320)
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 320,
            height: CGFloat.greatestFiniteMagnitude
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

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6

        textView.delegate = context.coordinator
        textView.onHoveredCharacterIndex = { [weak coordinator = context.coordinator] index in
            coordinator?.parent.onHoveredCharacterIndex?(index)
        }
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.placeholder = "Input text here"
        if !text.isEmpty {
            textView.string = text
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        scrollView.isHidden = !isActive
        if isActive {
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let becameActive = !context.coordinator.wasActive && isActive
        let becameInactive = context.coordinator.wasActive && !isActive
        context.coordinator.wasActive = isActive
        context.coordinator.parent = self
        nsView.isHidden = !isActive
        guard let textView = nsView.documentView as? SentenceHighlightingTextView else {
            return
        }

        if becameInactive {
            textView.resetHoveredCharacter()
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.resetHoveredCharacter()
        }
        textView.placeholder = "Input text here"

        if !context.coordinator.didRestoreInitialScroll,
           nsView.contentView.bounds.height > 0,
           !textView.string.isEmpty {
            let savedOffset = SentenceTranslateStore.shared.sourceScrollOffset
            if savedOffset > 0 {
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                nsView.contentView.setBoundsOrigin(NSPoint(x: 0, y: savedOffset))
                nsView.reflectScrolledClipView(nsView.contentView)
            }
            context.coordinator.didRestoreInitialScroll = true
        }

        if becameActive {
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }

        if context.coordinator.lastClearSelectionToken != clearSelectionToken {
            context.coordinator.lastClearSelectionToken = clearSelectionToken
            if !textView.hasMarkedText() {
                let range = textView.selectedRange()
                if range.length > 0 {
                    textView.setSelectedRange(NSRange(location: range.location, length: 0))
                }
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
        var wasActive: Bool
        var didRestoreInitialScroll = false

        init(_ parent: SelectableTextView) {
            self.parent = parent
            lastClearSelectionToken = parent.clearSelectionToken
            lastHighlightedRange = parent.highlightedSentenceRange
            lastHighlightedText = parent.text
            wasActive = parent.isActive
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard parent.isActive,
                  let clipView = notification.object as? NSClipView,
                  clipView.bounds.height > 0 else {
                return
            }
            SentenceTranslateStore.shared.sourceScrollOffset = max(0, clipView.bounds.origin.y)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.needsDisplay = true
            guard !textView.hasMarkedText() else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !textView.hasMarkedText() else { return }
            let range = textView.selectedRange()

            if range.length > 0, let swiftRange = Range(range, in: textView.string) {
                let selection = String(textView.string[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.parent.selectedText = selection
                    self.parent.selectionRange = range
                }
            } else {
                let sourceLength = (textView.string as NSString).length
                let isUserNavigation: Bool = {
                    guard let eventType = NSApp.currentEvent?.type else { return false }
                    switch eventType {
                    case .leftMouseDown, .leftMouseUp, .keyDown:
                        return true
                    default:
                        return false
                    }
                }()
                let caretIndex: Int? = (isUserNavigation && sourceLength > 0)
                    ? min(max(0, range.location), sourceLength - 1)
                    : nil
                DispatchQueue.main.async {
                    if !self.parent.selectedText.isEmpty {
                        self.parent.selectedText = ""
                    }
                    if self.parent.selectionRange.length != 0 {
                        self.parent.selectionRange = NSRange(location: 0, length: 0)
                    }
                    if let caretIndex {
                        self.parent.onHoveredCharacterIndex?(caretIndex)
                    }
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
    }
}

private struct TranslatedParagraphTextView: NSViewRepresentable {
    let sentences: [SentencePair]
    let direction: TranslationDirection
    let highlightedSentenceID: Int?
    let highlightOpacity: Double
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SentenceHighlightingTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 320)
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 320,
            height: CGFloat.greatestFiniteMagnitude
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

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 4

        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.isHidden = !isActive

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.isActive = isActive
        nsView.isHidden = !isActive
        guard let textView = nsView.documentView as? SentenceHighlightingTextView else {
            return
        }

        let (combinedText, rangeMap) = buildTargetContent()
        if textView.string != combinedText {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.paragraphSpacing = 4
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: combinedText, attributes: attributes)
            )
            context.coordinator.lastHighlightedSentenceID = nil
        }

        if !context.coordinator.didRestoreInitialScroll,
           nsView.contentView.bounds.height > 0,
           !textView.string.isEmpty {
            let savedOffset = SentenceTranslateStore.shared.targetScrollOffset
            if savedOffset > 0, let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
                nsView.contentView.setBoundsOrigin(NSPoint(x: 0, y: savedOffset))
                nsView.reflectScrolledClipView(nsView.contentView)
            }
            context.coordinator.didRestoreInitialScroll = true
        }

        let targetRange = highlightedSentenceID.flatMap { rangeMap[$0] }
        let highlightChanged = context.coordinator.lastHighlightedSentenceID != highlightedSentenceID
            || context.coordinator.lastHighlightOpacity != highlightOpacity

        guard highlightChanged else { return }
        context.coordinator.lastHighlightedSentenceID = highlightedSentenceID
        context.coordinator.lastHighlightOpacity = highlightOpacity

        textView.highlightColor = SentenceHighlightPalette.nsColor(
            opacity: highlightOpacity
        )
        textView.highlightedRange = targetRange

        if let targetRange,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: targetRange,
                actualCharacterRange: nil
            )
            let boundingRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )

            let clipView = nsView.contentView
            let visibleHeight = clipView.bounds.height
            let documentHeight = textView.bounds.height
            guard documentHeight > visibleHeight, visibleHeight > 0 else { return }

            let targetY = boundingRect.midY - (visibleHeight / 2)
            let clampedY = min(max(0, targetY), max(0, documentHeight - visibleHeight))
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.18
                clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            }
            nsView.reflectScrolledClipView(clipView)
        }
    }

    private func buildTargetContent() -> (String, [Int: NSRange]) {
        var combined = ""
        var ranges: [Int: NSRange] = [:]
        var cursor = 0

        for (index, sentence) in sentences.enumerated() {
            if index > 0 {
                combined += "\n"
                cursor += 1
            }
            let text = direction.targetText(for: sentence)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let length = (text as NSString).length
            ranges[sentence.id] = NSRange(location: cursor, length: length)
            combined += text
            cursor += length
        }
        return (combined, ranges)
    }

    final class Coordinator: NSObject {
        var lastHighlightedSentenceID: Int?
        var lastHighlightOpacity: Double?
        var isActive: Bool
        var didRestoreInitialScroll = false

        init(isActive: Bool) {
            self.isActive = isActive
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard isActive,
                  let clipView = notification.object as? NSClipView,
                  clipView.bounds.height > 0 else {
                return
            }
            SentenceTranslateStore.shared.targetScrollOffset = max(0, clipView.bounds.origin.y)
        }
    }
}

private struct NormalizedTextIndex {
    struct Match {
        let rawRange: NSRange
        let normalizedEnd: Int
    }

    private let sourceText: NSString
    private let normalizedText: NSString
    private let rawStarts: [Int]
    private let rawEnds: [Int]

    private static let leadingSentencePunctuation = CharacterSet(
        charactersIn: "\"“'‘(（[【《「『"
    )
    private static let trailingSentencePunctuation = CharacterSet(
        charactersIn: ".!?。！？;；:：,，\"”'’)）]】》」』…"
    )

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

        sourceText = source as NSString
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

        var rawStart = rawStarts[normalizedRange.location]
        var rawEnd = rawEnds[NSMaxRange(normalizedRange) - 1]

        while rawStart > 0,
              let scalar = UnicodeScalar(sourceText.character(at: rawStart - 1)),
              Self.leadingSentencePunctuation.contains(scalar) {
            rawStart -= 1
        }
        while rawEnd < sourceText.length,
              let scalar = UnicodeScalar(sourceText.character(at: rawEnd)),
              Self.trailingSentencePunctuation.contains(scalar) {
            rawEnd += 1
        }

        return Match(
            rawRange: NSRange(location: rawStart, length: rawEnd - rawStart),
            normalizedEnd: NSMaxRange(normalizedRange)
        )
    }

    private static func normalize(_ character: Character) -> String {
        if character.isWhitespace || character.isPunctuation || character.isSymbol {
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

        return text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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
                .activeAlways,
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
        hoveredCharacterIndex = nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHoveredCharacter(at: event.locationInWindow)
    }

    func resetHoveredCharacter() {
        setHoveredCharacterIndex(nil)
    }

    private func updateHoveredCharacter(at windowPoint: NSPoint) {
        guard let layoutManager,
              let textContainer,
              !string.isEmpty,
              layoutManager.numberOfGlyphs > 0 else {
            setHoveredCharacterIndex(nil)
            return
        }

        let viewPoint = convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint) else { return }

        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let usedRect = layoutManager.usedRect(for: textContainer)
        guard containerPoint.x >= -4,
              containerPoint.y >= usedRect.minY - 4,
              containerPoint.y <= usedRect.maxY + 4 else {
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

        var lineGlyphRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineGlyphRange
        )
        guard lineRect.insetBy(dx: -4, dy: -4).contains(containerPoint) else {
            setHoveredCharacterIndex(nil)
            return
        }

        let nsString = string as NSString
        let lineCharRange = layoutManager.characterRange(
            forGlyphRange: lineGlyphRange,
            actualGlyphRange: nil
        )
        guard lineCharRange.location != NSNotFound,
              lineCharRange.length > 0,
              NSMaxRange(lineCharRange) <= nsString.length else {
            setHoveredCharacterIndex(nil)
            return
        }

        let lineSubstring = nsString.substring(with: lineCharRange)
        guard !lineSubstring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setHoveredCharacterIndex(nil)
            return
        }

        var characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < nsString.length else {
            setHoveredCharacterIndex(nil)
            return
        }

        let whitespace = CharacterSet.whitespacesAndNewlines
        if let scalar = UnicodeScalar(nsString.character(at: characterIndex)),
           whitespace.contains(scalar) {
            var resolved: Int?
            var backward = characterIndex - 1
            while backward >= lineCharRange.location {
                if let s = UnicodeScalar(nsString.character(at: backward)),
                   !whitespace.contains(s) {
                    resolved = backward
                    break
                }
                backward -= 1
            }
            if resolved == nil {
                var forward = characterIndex + 1
                while forward < NSMaxRange(lineCharRange) {
                    if let s = UnicodeScalar(nsString.character(at: forward)),
                       !whitespace.contains(s) {
                        resolved = forward
                        break
                    }
                    forward += 1
                }
            }
            if let resolved {
                characterIndex = resolved
            } else {
                setHoveredCharacterIndex(nil)
                return
            }
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

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        if string.isEmpty, !hasMarkedText(), !placeholder.isEmpty {
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
