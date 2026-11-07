import Foundation

struct SourceSentenceRange: Identifiable, Equatable {
    let id: Int
    let range: NSRange
}

struct SelectionContext: Equatable {
    let text: String
    let range: NSRange
    let sourceLength: Int
    let sentence: String
    let sentenceIndex: Int
    let occurrenceIndex: Int
    let occurrenceCount: Int

    var coverage: Double {
        guard sourceLength > 0 else { return 1 }
        return Double(range.length) / Double(sourceLength)
    }
}

enum TranslationStatus: Equatable {
    case idle
    case translating
    case analyzing
    case failed(String)
}

struct AIConfiguration {
    let baseURL: String
    let apiKey: String
    let model: String
    let reasoningEffort: String

    init(
        baseURL: String,
        apiKey: String,
        model: String,
        reasoningEffort: String = "low"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

struct OpenAIResponsesAPIResult: Decodable {
    let output: [OutputItem]?
    let outputText: String?

    enum CodingKeys: String, CodingKey {
        case output
        case outputText = "output_text"
    }

    struct OutputItem: Decodable {
        let type: String?
        let content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        let type: String?
        let text: String?
    }

    var extractedText: String {
        var textParts: [String] = []

        for item in output ?? [] where item.type == nil || item.type == "message" {
            for content in item.content ?? [] {
                guard content.type == nil || content.type == "output_text",
                      let text = content.text else {
                    continue
                }
                textParts.append(text)
            }
        }

        let structuredText = textParts.joined()
        if !structuredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return structuredText
        }
        return outputText ?? ""
    }
}

struct OpenAIResponsesStreamEvent: Decodable {
    let type: String?
    let delta: String?
    let error: StreamError?

    struct StreamError: Decodable {
        let message: String?
    }
}

struct OpenAIChatAPIResult: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let message: Message?
    }

    struct Message: Decodable {
        let content: String?
    }

    var extractedText: String {
        choices?.first?.message?.content ?? ""
    }
}

struct BilingualAlignmentResponse: Decodable {
    let sentences: [SentencePair]
}

struct SentencePair: Identifiable, Codable, Equatable {
    let id: Int
    let en: String
    let zh: String
}

enum TranslationDirection {
    case englishToChinese
    case chineseToEnglish

    static func detect(from text: String) -> TranslationDirection {
        text.containsCJK ? .chineseToEnglish : .englishToChinese
    }

    func sourceText(for pair: SentencePair) -> String {
        switch self {
        case .englishToChinese: pair.en
        case .chineseToEnglish: pair.zh
        }
    }

    func targetText(for pair: SentencePair) -> String {
        switch self {
        case .englishToChinese: pair.zh
        case .chineseToEnglish: pair.en
        }
    }

    var targetJSONField: String {
        switch self {
        case .englishToChinese: "zh"
        case .chineseToEnglish: "en"
        }
    }
}
