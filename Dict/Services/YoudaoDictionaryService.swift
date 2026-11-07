import AppKit
import AVFoundation
import Foundation

extension Services {
    // MARK: - Cache

    func cachedLookupResult(for rawWord: String) -> WordLookupResult? {
        let key = Self.cacheKey(for: rawWord)
        guard !key.isEmpty else { return nil }
        return wordLookupCache[key]
    }

    func storeCachedLookupResult(_ result: WordLookupResult, for rawWord: String) {
        let key = Self.cacheKey(for: rawWord)
        guard !key.isEmpty else { return }
        wordLookupCache[key] = result
        wordLookupCacheOrder.removeAll { $0 == key }
        wordLookupCacheOrder.append(key)

        if wordLookupCacheOrder.count > wordLookupCacheLimit {
            let overflow = wordLookupCacheOrder.count - wordLookupCacheLimit
            let evictedKeys = wordLookupCacheOrder.prefix(overflow)
            for evicted in evictedKeys {
                wordLookupCache.removeValue(forKey: evicted)
            }
            wordLookupCacheOrder.removeFirst(overflow)
        }
        persistWordLookupCache()
    }

    func loadPersistedWordLookupCache() {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.wordLookupCache),
              let entries = try? decoder.decode([WordLookupResult].self, from: data) else {
            return
        }
        for entry in entries {
            let key = Self.cacheKey(for: entry.word)
            guard !key.isEmpty else { continue }
            wordLookupCache[key] = entry
            wordLookupCacheOrder.removeAll { $0 == key }
            wordLookupCacheOrder.append(key)
        }
    }

    private func persistWordLookupCache() {
        let orderedEntries = wordLookupCacheOrder.compactMap { wordLookupCache[$0] }
        guard let data = try? encoder.encode(orderedEntries) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.wordLookupCache)
    }

    private static func cacheKey(for rawWord: String) -> String {
        rawWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Suggestions & Lookup

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

    func lookupWord(_ query: String) async throws -> WordLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictError.emptyText }

        if let cached = cachedLookupResult(for: trimmed) {
            return cached
        }

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
            .compactMap { wrapper -> WordForm? in
                guard let name = wrapper.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let value = wrapper.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, !value.isEmpty else {
                    return nil
                }
                return WordForm(name: name, value: value)
            } ?? []

        let phrases = response.phrs?.phrs?
            .compactMap(\.phr)
            .compactMap { detail -> WordPhrase? in
                guard let headword = detail.headword?.l?.i?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let translation = detail.trs?.first?.tr?.l?.i?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !headword.isEmpty, !translation.isEmpty else {
                    return nil
                }
                return WordPhrase(headword: headword, translation: translation)
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

        let lookupResult = WordLookupResult(
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
        storeCachedLookupResult(lookupResult, for: trimmed)
        return lookupResult
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

    // MARK: - Private Helpers

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
}
