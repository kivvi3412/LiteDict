import Foundation

extension Services {
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

    // MARK: - Sentence Translation

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
            do {
                let text = try await chatCompletionText(
                    configuration: configuration,
                    systemPrompt: directionalInstructions(instructions, input: input),
                    userPrompt: input,
                    jsonMode: true
                )
                return try decodeBilingualAlignment(from: text)
            } catch let DictError.httpStatus(code, _) where code == 400 {
                let text = try await chatCompletionText(
                    configuration: configuration,
                    systemPrompt: directionalInstructions(instructions, input: input),
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

    // MARK: - Selection Context Analysis

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

    // MARK: - OpenAI Request & Parsing Helpers

    private func validate(_ configuration: AIConfiguration) throws {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictError.missingAPIKey
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictError.invalidURL
        }
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
            "instructions": directionalInstructions(instructions, input: input),
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
        let url = try openAIURL(baseURL: configuration.baseURL, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(
            "Bearer \(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
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
            "temperature": 0.2
        ]
        if configuration.reasoningEffort == "none" {
            payload["thinking"] = ["type": "disabled"]
        } else {
            payload["thinking"] = ["type": "enabled"]
            payload["reasoning_effort"] = configuration.reasoningEffort
        }
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
