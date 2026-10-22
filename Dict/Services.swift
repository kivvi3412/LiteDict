import AppKit
import AVFoundation
import CoreServices
import Foundation

// DictionaryServices keeps mutable process-wide state and is not safe to
// call concurrently. All native dictionary access must pass through this actor.
private actor NativeDictionaryLookup {
    static let shared = NativeDictionaryLookup()

    private var availabilityCache: [String: Bool] = [:]
    private let cacheLimit = 256

    func hasEntry(for rawWord: String) -> Bool {
        let word = normalized(rawWord)
        guard !word.isEmpty, !Task.isCancelled else { return false }

        if let cached = availabilityCache[word] {
            return cached
        }

        let hasEntry = Self.copyDefinition(for: word) != nil
        cache(hasEntry, for: word)
        return hasEntry
    }

    func definition(for rawWord: String) -> String? {
        let word = normalized(rawWord)
        guard !word.isEmpty, !Task.isCancelled else { return nil }

        if availabilityCache[word] == false {
            return nil
        }

        let definition = Self.copyDefinition(for: word)
        cache(definition != nil, for: word)
        return definition
    }

    private func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cache(_ value: Bool, for word: String) {
        if availabilityCache.count >= cacheLimit, availabilityCache[word] == nil {
            availabilityCache.removeAll(keepingCapacity: true)
        }
        availabilityCache[word] = value
    }

    private static func copyDefinition(for word: String) -> String? {
        let nsString = word as NSString
        let range = CFRangeMake(0, nsString.length)
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, range) else {
            return nil
        }

        let text = (definition.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

@MainActor
final class Services {
    static let shared = Services()

    private static let youdaoUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var audioPlayer: AVAudioPlayer?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Youdao

    func fetchSuggestions(for query: String) async throws -> [SuggestEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [SuggestEntry] = []

        if let suggestURL = try? youdaoURL(
            path: "/suggest",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "num", value: "6"),
                URLQueryItem(name: "doctype", value: "json")
            ]
        ) {
            do {
                let data = try await youdaoData(from: suggestURL)
                let response: YoudaoSuggestResponse = try decode(data)
                candidates = response.data?.entries ?? []
            } catch {
                candidates = []
            }
        }

        if candidates.isEmpty {
            candidates = await youdaoTypoSuggestions(for: trimmed)
        }

        for completion in nativeSpellCompletions(for: trimmed) {
            guard candidates.count < 6 else { break }
            if !candidates.contains(where: {
                $0.entry.compare(completion, options: .caseInsensitive) == .orderedSame
            }) {
                candidates.append(SuggestEntry(entry: completion, explain: nil))
            }
        }

        return Array(candidates.prefix(6))
    }

    private func youdaoTypoSuggestions(for query: String) async -> [SuggestEntry] {
        guard let url = try? youdaoURL(
            path: "/jsonapi",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "doctype", value: "json"),
                URLQueryItem(name: "jsonversion", value: "2")
            ]
        ) else {
            return []
        }

        do {
            let data = try await youdaoData(from: url)
            let response: YoudaoDetailResponse = try decode(data)
            return response.typos?.typo?.map {
                SuggestEntry(entry: $0.word, explain: $0.trans)
            } ?? []
        } catch {
            return []
        }
    }

    private func nativeSpellCompletions(for query: String) -> [String] {
        let nsQuery = query as NSString
        let range = NSRange(location: 0, length: nsQuery.length)
        return NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: query,
            language: "en",
            inSpellDocumentWithTag: 0
        ) ?? []
    }

    func lookupWord(_ query: String) async throws -> WordLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictError.emptyText }

        let url = try youdaoURL(
            path: "/jsonapi",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "doctype", value: "json"),
                URLQueryItem(name: "jsonversion", value: "2")
            ]
        )
        let data = try await youdaoData(from: url)
        let response: YoudaoDetailResponse = try decode(data)
        let wordNode = response.ec?.word?.first
        let isChineseInput = trimmed.containsCJK

        var definitions = wordNode?.trs?
            .flatMap { $0.tr ?? [] }
            .compactMap { node in
                node.l?.i?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "; ")
            }
            .filter { !$0.isEmpty } ?? []

        if definitions.isEmpty, isChineseInput {
            let webEntries = response.web_trans?.web_translation ?? []
            let primaryEntry = webEntries.first(where: { $0.key == trimmed }) ?? webEntries.first
            let translations = primaryEntry?.trans?
                .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if !translations.isEmpty {
                definitions = [translations.joined(separator: "; ")]
            }
        }

        if definitions.isEmpty,
           !isChineseInput,
           trimmed.split(whereSeparator: \.isWhitespace).count > 1,
           let translatedPhrase = await youdaoPhraseTranslation(for: trimmed) {
            definitions = [translatedPhrase]
        }

        let wordForms = wordNode?.wfs?
            .compactMap(\.wf)
            .compactMap { wrapper -> (name: String, value: String)? in
                guard let name = wrapper.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let value = wrapper.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, !value.isEmpty else {
                    return nil
                }
                return (name, value)
            } ?? []

        let phrases = response.phrs?.phrs?
            .compactMap(\.phr)
            .compactMap { detail -> (headword: String, translation: String)? in
                guard let headword = detail.headword?.l?.i?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let translation = detail.trs?.first?.tr?.l?.i?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !headword.isEmpty, !translation.isEmpty else {
                    return nil
                }
                return (headword, translation)
            } ?? []

        var examTags: [String] = []
        for tag in response.ec?.exam_type ?? [] {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !examTags.contains(normalized) {
                examTags.append(normalized)
            }
        }

        let examples = (response.blng_sents_part?.sentencePair ?? [])
            .compactMap { pair -> WordExample? in
                guard let source = pair.sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let translation = pair.sentenceTranslation?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !source.isEmpty, !translation.isEmpty else {
                    return nil
                }
                return WordExample(id: 0, source: source, translation: translation)
            }
            .enumerated()
            .map { index, example in
                WordExample(id: index, source: example.source, translation: example.translation)
            }
        let chinesePhonetic = response.ce?.word?.first?.phone ?? ""
        var translations: [WordTranslationOption] = []
        if isChineseInput {
            var seenTerms: Set<String> = []

            for group in response.ce?.word?.flatMap({ $0.trs ?? [] }) ?? [] {
                for node in group.tr ?? [] {
                    guard let definitionNode = node.l else { continue }
                    let term = definitionNode.entries?
                        .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? ""
                    let key = term.lowercased()
                    guard !term.isEmpty, !seenTerms.contains(key) else { continue }
                    seenTerms.insert(key)
                    translations.append(
                        WordTranslationOption(
                            id: translations.count,
                            term: term,
                            partOfSpeech: definitionNode.pos ?? "",
                            definition: definitionNode.translation?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        )
                    )
                }
            }

            if translations.isEmpty {
                for value in response.web_trans?.web_translation?
                    .first?.trans?
                    .compactMap({ $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }) ?? [] {
                    let key = value.lowercased()
                    guard !value.isEmpty, !seenTerms.contains(key) else { continue }
                    seenTerms.insert(key)
                    translations.append(
                        WordTranslationOption(
                            id: translations.count,
                            term: value,
                            partOfSpeech: "",
                            definition: ""
                        )
                    )
                }
            }
        }

        return WordLookupResult(
            word: trimmed,
            usPhonetic: isChineseInput
                ? chinesePhonetic
                : (wordNode?.usphone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            ukPhonetic: isChineseInput
                ? ""
                : (wordNode?.ukphone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            examTags: examTags,
            definitions: definitions,
            wordForms: wordForms,
            phrases: phrases,
            examples: Array(examples.prefix(8)),
            translations: translations
        )
    }

    private func youdaoPhraseTranslation(for phrase: String) async -> String? {
        let slug = phrase.replacingOccurrences(of: " ", with: "_")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dict.youdao.com"
        components.path = "/w/eng/\(slug)/"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.youdaoUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            _ = try validatedHTTPResponse(response, data: data)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return parseYoudaoTranslation(from: html)
        } catch {
            return nil
        }
    }

    private func parseYoudaoTranslation(from html: String) -> String? {
        guard let start = html.range(of: "<div id=\"fanyiToggle\">"),
              let end = html.range(of: "</div>", range: start.upperBound..<html.endIndex) else {
            return nil
        }

        let block = String(html[start.upperBound..<end.lowerBound])
        guard let expression = try? NSRegularExpression(
            pattern: "<p[^>]*>([\\s\\S]*?)</p>",
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(location: 0, length: (block as NSString).length)
        let matches = expression.matches(in: block, range: range)
        guard matches.count >= 2,
              let translationRange = Range(matches[1].range(at: 1), in: block) else {
            return nil
        }

        let rawTranslation = String(block[translationRange])
        let withoutTags = rawTranslation.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    func playAudio(word: String, type: Int) async {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = try? youdaoURL(
                path: "/dictvoice",
                queryItems: [
                    URLQueryItem(name: "audio", value: trimmed),
                    URLQueryItem(name: "type", value: type == 1 ? "1" : "2")
                ]
              ) else {
            return
        }

        var request = URLRequest(url: url)
        request.setValue(Self.youdaoUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try validatedHTTPResponse(response, data: data)
            guard (200..<300).contains(httpResponse.statusCode), !data.isEmpty else { return }

            audioPlayer?.stop()
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            audioPlayer = player
            player.play()
        } catch {
            // Pronunciation failures should not interrupt dictionary lookup.
        }
    }

    // MARK: - Native Oxford dictionary

    nonisolated func lookupNativeOxford(for word: String) async -> String? {
        await NativeDictionaryLookup.shared.definition(for: word)
    }

    nonisolated static func nativeOxfordDefinition(for word: String) async -> String? {
        await NativeDictionaryLookup.shared.definition(for: word)
    }

    nonisolated static func hasNativeOxfordEntry(for word: String) async -> Bool {
        await NativeDictionaryLookup.shared.hasEntry(for: word)
    }

    // MARK: - OpenAI-compatible AI APIs

    func translateSentences(
        allInputText: String,
        configuration: AIConfiguration,
        instructions: String
    ) async throws -> [SentencePair] {
        let input = allInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw DictError.emptyText }
        try validate(configuration)

        let responsesPayload = bilingualResponsesPayload(
            input: input,
            configuration: configuration,
            instructions: instructions
        )

        do {
            let data = try await postJSON(
                payload: responsesPayload,
                configuration: configuration,
                endpoint: .responses
            )
            let response: OpenAIResponsesAPIResult = try decode(data)
            return try decodeBilingualAlignment(from: response.extractedText)
        } catch let DictError.httpStatus(code, _) where [400, 404, 405, 422].contains(code) {
            // Some OpenAI-compatible providers expose Responses or structured outputs
            // only through Chat Completions. Keep the same model and prompts in that case.
            do {
                let text = try await chatCompletionText(
                    configuration: configuration,
                    systemPrompt: directionalInstructions(
                        instructions,
                        input: input
                    ),
                    userPrompt: input,
                    jsonMode: true
                )
                return try decodeBilingualAlignment(from: text)
            } catch let DictError.httpStatus(code, _) where code == 400 {
                let text = try await chatCompletionText(
                    configuration: configuration,
                    systemPrompt: directionalInstructions(
                        instructions,
                        input: input
                    ),
                    userPrompt: input,
                    jsonMode: false
                )
                return try decodeBilingualAlignment(from: text)
            }
        }
    }

    func translateSentencesStreaming(
        allInputText: String,
        configuration: AIConfiguration,
        instructions: String,
        onThinkingDelta: @escaping (String) -> Void,
        onTranslationUpdate: @escaping (String) -> Void
    ) async throws -> [SentencePair] {
        let input = allInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw DictError.emptyText }
        try validate(configuration)

        var payload = bilingualResponsesPayload(
            input: input,
            configuration: configuration,
            instructions: instructions
        )
        payload["stream"] = true

        do {
            let request = try makeOpenAIRequest(
                payload: payload,
                configuration: configuration,
                endpoint: .responses,
                accept: "text/event-stream"
            )
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw DictError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DictError.httpStatus(httpResponse.statusCode, "")
            }

            var rawOutput = ""
            let targetField = input.containsCJK ? "en" : "zh"
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payloadText = String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payloadText.isEmpty else { continue }
                if payloadText == "[DONE]" { break }

                guard let eventData = payloadText.data(using: .utf8),
                      let event = try? decoder.decode(
                        OpenAIResponsesStreamEvent.self,
                        from: eventData
                      ) else {
                    continue
                }

                switch event.type {
                case "response.reasoning_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        onThinkingDelta(delta)
                    }
                case "response.output_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        rawOutput += delta
                        onTranslationUpdate(
                            streamingTranslationPreview(
                                from: rawOutput,
                                targetField: targetField
                            )
                        )
                    }
                case "response.failed", "error":
                    throw DictError.streamingFailed(
                        event.error?.message ?? "模型返回了错误事件。"
                    )
                default:
                    break
                }
            }

            guard !rawOutput.isEmpty else {
                return try await translateSentences(
                    allInputText: input,
                    configuration: configuration,
                    instructions: instructions
                )
            }
            return try decodeBilingualAlignment(from: rawOutput)
        } catch let DictError.httpStatus(code, _) where [400, 404, 405, 422].contains(code) {
            return try await translateSentences(
                allInputText: input,
                configuration: configuration,
                instructions: instructions
            )
        }
    }

    func analyzeSelection(
        selectedText: String,
        allInputText: String,
        configuration: AIConfiguration,
        promptTemplate: String,
        selectionContext: SelectionContext?
    ) async throws -> String {
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allText = allInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { throw DictError.emptyText }
        guard !allText.isEmpty else { throw DictError.emptyText }
        try validate(configuration)

        let prompt = PromptDefaults.contextPrompt(
            selectedText: selected,
            allText: allText,
            template: promptTemplate,
            context: selectionContext
        )
        let responsesPayload: [String: Any] = [
            "model": configuration.model,
            "instructions": PromptDefaults.contextInstructions,
            "input": prompt,
            "reasoning": [
                "effort": configuration.reasoningEffort
            ]
        ]

        do {
            let data = try await postJSON(
                payload: responsesPayload,
                configuration: configuration,
                endpoint: .responses
            )
            let response: OpenAIResponsesAPIResult = try decode(data)
            return try nonEmptyMarkdown(response.extractedText)
        } catch let DictError.httpStatus(code, _) where [400, 404, 405, 422].contains(code) {
            let text = try await chatCompletionText(
                configuration: configuration,
                systemPrompt: PromptDefaults.contextInstructions,
                userPrompt: prompt,
                jsonMode: false
            )
            return try nonEmptyMarkdown(text)
        }
    }

    func analyzeSelectionStreaming(
        selectedText: String,
        allInputText: String,
        configuration: AIConfiguration,
        promptTemplate: String,
        selectionContext: SelectionContext?,
        onThinkingDelta: @escaping (String) -> Void,
        onMarkdownUpdate: @escaping (String) -> Void
    ) async throws -> String {
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allText = allInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { throw DictError.emptyText }
        guard !allText.isEmpty else { throw DictError.emptyText }
        try validate(configuration)

        let prompt = PromptDefaults.contextPrompt(
            selectedText: selected,
            allText: allText,
            template: promptTemplate,
            context: selectionContext
        )
        let payload: [String: Any] = [
            "model": configuration.model,
            "instructions": PromptDefaults.contextInstructions,
            "input": prompt,
            "reasoning": [
                "effort": configuration.reasoningEffort
            ],
            "stream": true
        ]

        do {
            let request = try makeOpenAIRequest(
                payload: payload,
                configuration: configuration,
                endpoint: .responses,
                accept: "text/event-stream"
            )
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw DictError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DictError.httpStatus(httpResponse.statusCode, "")
            }

            var output = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payloadText = String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payloadText.isEmpty else { continue }
                if payloadText == "[DONE]" { break }

                guard let eventData = payloadText.data(using: .utf8),
                      let event = try? decoder.decode(
                        OpenAIResponsesStreamEvent.self,
                        from: eventData
                      ) else {
                    continue
                }

                switch event.type {
                case "response.reasoning_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        onThinkingDelta(delta)
                    }
                case "response.output_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        output += delta
                        onMarkdownUpdate(output)
                    }
                case "response.failed", "error":
                    throw DictError.streamingFailed(
                        event.error?.message ?? "模型返回了错误事件。"
                    )
                default:
                    break
                }
            }

            guard !output.isEmpty else {
                return try await analyzeSelection(
                    selectedText: selected,
                    allInputText: allText,
                    configuration: configuration,
                    promptTemplate: promptTemplate,
                    selectionContext: selectionContext
                )
            }
            return try nonEmptyMarkdown(output)
        } catch let DictError.httpStatus(code, _) where [400, 404, 405, 422].contains(code) {
            let fallback = try await chatCompletionText(
                configuration: configuration,
                systemPrompt: PromptDefaults.contextInstructions,
                userPrompt: prompt,
                jsonMode: false
            )
            return try nonEmptyMarkdown(fallback)
        }
    }

    // MARK: - Networking helpers

    private enum OpenAIEndpoint {
        case responses
        case chatCompletions

        var pathComponent: String {
            switch self {
            case .responses: "responses"
            case .chatCompletions: "chat/completions"
            }
        }
    }

    private func validate(_ configuration: AIConfiguration) throws {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictError.missingAPIKey
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictError.invalidURL
        }
    }

    private func youdaoURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dict.youdao.com"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw DictError.invalidURL }
        return url
    }

    private func youdaoData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.youdaoUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        _ = try validatedHTTPResponse(response, data: data)
        return data
    }

    private func openAIURL(baseURL: String, endpoint: OpenAIEndpoint) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw DictError.invalidURL
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let knownEndpointSuffixes = ["responses", "chat/completions"]

        if let suffix = knownEndpointSuffixes.first(where: { path == $0 || path.hasSuffix("/\($0)") }) {
            path.removeLast(suffix.count)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let endpointPath = endpoint.pathComponent
        path = path.isEmpty ? endpointPath : "\(path)/\(endpointPath)"
        components.path = "/" + path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw DictError.invalidURL }
        return url
    }

    private func bilingualResponsesPayload(
        input: String,
        configuration: AIConfiguration,
        instructions: String
    ) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "sentences": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "integer"],
                            "en": ["type": "string"],
                            "zh": ["type": "string"]
                        ],
                        "required": ["id", "en", "zh"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["sentences"],
            "additionalProperties": false
        ]

        return [
            "model": configuration.model,
            "instructions": directionalInstructions(
                instructions,
                input: input
            ),
            "input": input,
            "reasoning": [
                "effort": configuration.reasoningEffort
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "bilingual_alignment",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
    }

    private func directionalInstructions(_ base: String, input: String) -> String {
        let directionRule: String
        if input.containsCJK {
            directionRule = """
            The source text is Chinese. Translate each source sentence into natural English.
            For every item, "zh" must be the original Chinese sentence and "en" must be its English translation.
            """
        } else {
            directionRule = """
            The source text is English. Translate each source sentence into natural Chinese.
            For every item, "en" must be the original English sentence and "zh" must be its Chinese translation.
            """
        }
        return base + "\n\n" + directionRule
    }

    private func postJSON(
        payload: [String: Any],
        configuration: AIConfiguration,
        endpoint: OpenAIEndpoint
    ) async throws -> Data {
        let request = try makeOpenAIRequest(
            payload: payload,
            configuration: configuration,
            endpoint: endpoint
        )
        let (data, response) = try await session.data(for: request)
        _ = try validatedHTTPResponse(response, data: data)
        return data
    }

    private func makeOpenAIRequest(
        payload: [String: Any],
        configuration: AIConfiguration,
        endpoint: OpenAIEndpoint,
        accept: String = "application/json"
    ) throws -> URLRequest {
        let url = try openAIURL(
            baseURL: configuration.baseURL,
            endpoint: endpoint
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func chatCompletionText(
        configuration: AIConfiguration,
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2,
            "reasoning_effort": configuration.reasoningEffort
        ]
        if jsonMode {
            payload["response_format"] = ["type": "json_object"]
        }

        let data = try await postJSON(
            payload: payload,
            configuration: configuration,
            endpoint: .chatCompletions
        )
        let response: OpenAIChatAPIResult = try decode(data)
        return try nonEmptyMarkdown(response.extractedText)
    }

    private func validatedHTTPResponse(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DictError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DictError.httpStatus(httpResponse.statusCode, serverMessage(from: data))
        }
        return httpResponse
    }

    private func serverMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(raw.prefix(800))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DictError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Result normalization

    private func streamingTranslationPreview(
        from rawText: String,
        targetField: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: "\"\(targetField)\"\\s*:\\s*\""
        ) else {
            return ""
        }

        let source = rawText as NSString
        let matches = expression.matches(
            in: rawText,
            range: NSRange(location: 0, length: source.length)
        )
        var values: [String] = []

        for match in matches {
            let start = NSMaxRange(match.range)
            var index = start
            var end = source.length
            var isEscaped = false

            while index < source.length {
                let character = source.character(at: index)
                if isEscaped {
                    isEscaped = false
                } else if character == 92 {
                    isEscaped = true
                } else if character == 34 {
                    end = index
                    break
                }
                index += 1
            }

            guard end >= start else { continue }
            let fragment = source.substring(
                with: NSRange(location: start, length: end - start)
            )
            if let decoded = decodePartialJSONString(fragment), !decoded.isEmpty {
                values.append(decoded)
            }
        }

        return values
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodePartialJSONString(_ fragment: String) -> String? {
        var candidate = fragment
        let partialDecoder = JSONDecoder()

        while !candidate.isEmpty {
            let wrapped = "\"\(candidate)\""
            if let data = wrapped.data(using: .utf8),
               let decoded = try? partialDecoder.decode(String.self, from: data) {
                return decoded
            }
            candidate.removeLast()
        }
        return nil
    }

    private func decodeBilingualAlignment(from text: String) throws -> [SentencePair] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned.removeLast(3)
            }
        }

        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            cleaned = String(cleaned[firstBrace...lastBrace])
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw DictError.emptyAIResponse
        }
        let response: BilingualAlignmentResponse = try decode(data)
        let sorted = response.sentences.sorted { $0.id < $1.id }

        if Set(sorted.map(\.id)).count == sorted.count {
            return sorted
        }

        return sorted.enumerated().map { index, sentence in
            SentencePair(id: index, en: sentence.en, zh: sentence.zh)
        }
    }

    private func nonEmptyMarkdown(_ text: String) throws -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw DictError.emptyAIResponse }

        if cleaned.hasPrefix("```markdown") && cleaned.hasSuffix("```") {
            cleaned.removeFirst("```markdown".count)
            cleaned.removeLast(3)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}
