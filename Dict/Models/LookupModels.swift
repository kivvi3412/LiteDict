import Foundation

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
