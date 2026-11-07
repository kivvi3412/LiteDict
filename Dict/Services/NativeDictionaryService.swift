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

extension Services {
    nonisolated func lookupNativeOxford(for word: String) async -> String? {
        await NativeDictionaryLookup.shared.definition(for: word)
    }

    nonisolated static func nativeOxfordDefinition(for word: String) async -> String? {
        await NativeDictionaryLookup.shared.definition(for: word)
    }

    nonisolated static func hasNativeOxfordEntry(for word: String) async -> Bool {
        await NativeDictionaryLookup.shared.hasEntry(for: word)
    }
}
