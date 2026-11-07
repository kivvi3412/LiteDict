import Foundation

// MARK: - App state

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case lookup
    case sentence
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .lookup: "查词"
        case .sentence: "翻译"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .lookup: "magnifyingglass"
        case .sentence: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

enum LookupStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct WordLookupRequest: Equatable {
    let id = UUID()
    let word: String
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

enum DictError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case missingAPIKey
    case emptyText
    case emptyAIResponse
    case streamingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "接口地址无效，请在设置中检查 Base URL。"
        case .invalidResponse:
            "服务器返回了无法识别的响应。"
        case let .httpStatus(code, message):
            message.isEmpty ? "请求失败（HTTP \(code)）。" : "请求失败（HTTP \(code)）：\(message)"
        case .missingAPIKey:
            "尚未配置 API Key，请先前往设置填写。"
        case .emptyText:
            "请输入要处理的文本。"
        case .emptyAIResponse:
            "模型没有返回可用的文本。"
        case let .streamingFailed(message):
            "流式响应失败：\(message)"
        case let .decodingFailed(message):
            "数据解析失败：\(message)"
        }
    }
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

// MARK: - Youdao

struct YoudaoSuggestResponse: Decodable {
    let data: SuggestData?

    struct SuggestData: Decodable {
        let entries: [SuggestEntry]?
    }
}

struct SuggestEntry: Identifiable, Decodable {
    var id: String { entry }
    let entry: String
    let explain: String?
}

struct YoudaoDetailResponse: Decodable {
    let ec: ECNode?
    let phrs: PhrsNode?
    let typos: TyposNode?
    let ce: ChineseEnglishNode?
    let web_trans: WebTranslationNode?
    let blng_sents_part: BilingualSentencesNode?

    struct ECNode: Decodable {
        let exam_type: [String]?
        let word: [WordNode]?
    }

    struct WordNode: Decodable {
        let usphone: String?
        let ukphone: String?
        let trs: [TrsNode]?
        let wfs: [WfWrapper]?
    }

    struct TrsNode: Decodable {
        let tr: [TrNode]?
    }

    struct TrNode: Decodable {
        let l: LNode?
    }

    struct LNode: Decodable {
        let i: [String]?
    }

    struct WfWrapper: Decodable {
        let wf: WfNode?
    }

    struct WfNode: Decodable {
        let name: String?
        let value: String?
    }

    struct PhrsNode: Decodable {
        let phrs: [PhrWrapper]?
    }

    struct PhrWrapper: Decodable {
        let phr: PhrDetail?
    }

    struct PhrDetail: Decodable {
        let headword: HeadwordL?
        let trs: [PhrTrWrapper]?
    }

    struct HeadwordL: Decodable {
        let l: SimpleL?
    }

    struct PhrTrWrapper: Decodable {
        let tr: HeadwordL?
    }

    struct SimpleL: Decodable {
        let i: String?
    }

    struct TyposNode: Decodable {
        let typo: [TypoEntry]?
    }

    struct TypoEntry: Decodable {
        let word: String
        let trans: String?
    }

    struct ChineseEnglishNode: Decodable {
        let word: [ChineseWordNode]?
    }

    struct ChineseWordNode: Decodable {
        let phone: String?
        let trs: [ChineseTranslationGroup]?
    }

    struct ChineseTranslationGroup: Decodable {
        let tr: [ChineseTranslationNode]?
    }

    struct ChineseTranslationNode: Decodable {
        let l: ChineseDefinitionNode?
    }

    struct ChineseDefinitionNode: Decodable {
        let pos: String?
        let translation: String?
        let entries: [ChineseInlineEntry]?

        enum CodingKeys: String, CodingKey {
            case pos
            case translation = "#tran"
            case entries = "i"
        }
    }

    enum ChineseInlineEntry: Decodable {
        case text(String)
        case linked(String)

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let value = try? container.decode(String.self) {
                self = .text(value)
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .linked(value)
        }

        enum CodingKeys: String, CodingKey {
            case text = "#text"
        }

        var value: String {
            switch self {
            case let .text(value), let .linked(value): value
            }
        }
    }

    struct WebTranslationNode: Decodable {
        let web_translation: [WebTranslationEntry]?

        enum CodingKeys: String, CodingKey {
            case web_translation = "web-translation"
        }
    }

    struct WebTranslationEntry: Decodable {
        let key: String?
        let trans: [WebTranslationValue]?
    }

    struct WebTranslationValue: Decodable {
        let value: String?
    }

    struct BilingualSentencesNode: Decodable {
        let sentencePair: [BilingualSentence]?

        enum CodingKeys: String, CodingKey {
            case sentencePair = "sentence-pair"
        }
    }

    struct BilingualSentence: Decodable {
        let sentence: String?
        let sentenceTranslation: String?

        enum CodingKeys: String, CodingKey {
            case sentence
            case sentenceTranslation = "sentence-translation"
        }
    }
}

struct WordExample: Identifiable, Codable {
    let id: Int
    let source: String
    let translation: String
}

struct WordTranslationOption: Identifiable, Codable {
    let id: Int
    let term: String
    let partOfSpeech: String
    let definition: String
}

struct WordForm: Codable {
    let name: String
    let value: String
}

struct WordPhrase: Codable {
    let headword: String
    let translation: String
}

struct WordLookupResult: Codable {
    var word: String = ""
    var usPhonetic: String = ""
    var ukPhonetic: String = ""
    var examTags: [String] = []
    var definitions: [String] = []
    var wordForms: [WordForm] = []
    var phrases: [WordPhrase] = []
    var examples: [WordExample] = []
    var translations: [WordTranslationOption] = []
}

// MARK: - AI

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

struct SentencePair: Identifiable, Codable {
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

extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }
}

// MARK: - Preferences and prompts

enum PreferenceKey {
    static let openAIBaseURL = "openaiBaseURL"
    static let openAIAPIKey = "openaiApiKey"
    static let openAIModel = "openaiModel"
    static let autoPlayAudio = "autoPlayAudio"
    static let wordHistory = "wordHistory"
    static let wordHistoryIndex = "wordHistoryIndex"
    static let lastLookupWord = "lastLookupWord"
    static let lastSearchQuery = "lastSearchQuery"
    static let wordLookupCache = "wordLookupCache"
    static let translationInstructions = "translationInstructions"
    static let contextPromptTemplate = "contextPromptTemplate"
    static let reasoningEffort = "reasoningEffort"
    static let customReasoningEffort = "customReasoningEffort"
    static let glassOpacity = "glassOpacity"
    static let highlightOpacity = "highlightOpacity"
}

enum PromptDefaults {
    static let translationInstructions = """
    You are an expert bidirectional English-Chinese translator. Split the user's input into logical sentences.
    Translate English input into natural Chinese; translate Chinese input into natural English.
    Always put the original English sentence in "en" and the original Chinese sentence in "zh". If the input is English, "zh" is its Chinese translation. If the input is Chinese, "en" is its English translation.
    Ensure every source sentence corresponds strictly 1-to-1 with its translation in sequence.
    Output raw JSON strictly following the provided schema.
    """

    static let contextInstructions = """
    你是一个精准的上下文词典助手。请严格遵循用户给出的 Markdown 列表缩进与加粗格式输出结果，不要输出任何开场白或额外解释。
    """

    static let contextPromptTemplate = """
    用户输入的是 {input_select}，翻译单词或者短语在当前句子中的意思，根据以下规范:

    输出词语短语 {input_select} 提供音标（IPA） **常见含义**：列出2-3个最常见的定义
    输出这个单词在文中的句子，句子翻译
    在上下文中这个单词的意思，以下是输出例子严格按照这个例子的格式输出(包括加粗，换行)

    -  **distributions** /ˌdɪstrɪˈbjuːʃənz/
       -  n. 版本, 发行版; 分配, 分发
       -  There are many Linux distributions available.
          有许许多多的Linux发行版可供选择。
       -  **文中语境义**：在此处特指软件系统的不同发行版本。

    全文文本: {all_input}
    """

    static func contextPrompt(
        selectedText: String,
        allText: String,
        template: String,
        context: SelectionContext? = nil
    ) -> String {
        var prompt = template
            .replacingOccurrences(of: "{input_select}", with: selectedText)
            .replacingOccurrences(of: "{all_input}", with: allText)

        if let context {
            prompt += """


            [用户选区定位]
            选中文本：\(context.text)
            字符位置：第 \(context.range.location + 1) 个字符，长度 \(context.range.length)
            所在句子：\(context.sentence)
            句子序号：第 \(context.sentenceIndex) 句
            出现位置：该选区在全文中的第 \(context.occurrenceIndex) 次出现（全文共 \(context.occurrenceCount) 次）
            请只针对上述位置的文本，结合所在句子和全文语境解析，不要误用其他相同单词。
            """
        }
        return prompt
    }
}
