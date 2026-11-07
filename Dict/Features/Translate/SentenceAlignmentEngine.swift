import Foundation

enum SentenceAlignmentEngine {
    static func alignSourceSentences(
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
                in: source,
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

    static func sentenceID(
        at characterIndex: Int,
        in source: String,
        ranges: [SourceSentenceRange]
    ) -> Int? {
        if let exact = ranges.first(where: {
            NSLocationInRange(characterIndex, $0.range)
        }) {
            return exact.id
        }

        let nsSource = source as NSString
        guard characterIndex >= 0, characterIndex < nsSource.length else {
            return nil
        }
        let lineRange = nsSource.lineRange(
            for: NSRange(location: characterIndex, length: 0)
        )

        var bestID: Int?
        var bestDistance = Int.max
        for item in ranges {
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

    static func exactSourceRange(
        for sentence: String,
        in sourceText: String,
        startingAt location: Int = 0
    ) -> NSRange? {
        let source = sourceText as NSString
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

    static func makeSelectionContext(
        for selection: String,
        in inputText: String,
        selectionRange: NSRange,
        sourceSentenceRanges: [SourceSentenceRange]
    ) -> SelectionContext? {
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

    static func sentenceRanges(in source: NSString) -> [NSRange] {
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

    static func trimmedRange(_ range: NSRange, in source: NSString) -> NSRange {
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
}

struct NormalizedTextIndex {
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
