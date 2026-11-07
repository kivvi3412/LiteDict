import Combine
import Foundation

final class LookupHistoryStore: ObservableObject {
    @Published private(set) var history: [String]
    @Published private(set) var currentIndex: Int?
    @Published private(set) var currentWord: String
    @Published private(set) var currentQuery: String

    private let defaults: UserDefaults
    private let historyLimit = 200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var loadedHistory = (defaults.stringArray(
            forKey: PreferenceKey.wordHistory
        ) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if loadedHistory.count > historyLimit {
            loadedHistory = Array(loadedHistory.suffix(historyLimit))
        }

        let storedIndex = defaults.object(
            forKey: PreferenceKey.wordHistoryIndex
        ) as? Int
        let storedWord = defaults.string(
            forKey: PreferenceKey.lastLookupWord
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedQuery = defaults.string(
            forKey: PreferenceKey.lastSearchQuery
        ) ?? storedWord

        let resolvedIndex: Int?
        if let storedIndex,
           storedIndex >= 0,
           storedIndex <= loadedHistory.count {
            resolvedIndex = storedIndex
        } else {
            resolvedIndex = loadedHistory.indices.last
        }

        let resolvedWord: String
        if !storedWord.isEmpty {
            resolvedWord = storedWord
        } else if let resolvedIndex {
            resolvedWord = loadedHistory[resolvedIndex]
        } else {
            resolvedWord = ""
        }

        history = loadedHistory
        currentIndex = resolvedIndex
        currentWord = resolvedWord
        currentQuery = storedQuery
    }

    var canGoBack: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    var canGoForward: Bool {
        guard let currentIndex else { return false }
        return currentIndex < history.count - 1
    }

    func record(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }

        if let currentIndex, history.indices.contains(currentIndex),
           history[currentIndex] == word {
            if currentIndex < history.count - 1 {
                history.removeSubrange((currentIndex + 1)..<history.count)
            }
            self.currentIndex = history.count - 1
            currentWord = word
            currentQuery = word
            persist()
            return
        }

        if let currentIndex, currentIndex < history.count - 1 {
            history.removeSubrange((currentIndex + 1)..<history.count)
        }

        if history.last != word {
            history.append(word)
        }
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        currentIndex = history.indices.last
        currentWord = word
        currentQuery = word
        persist()
    }

    func goBack() -> String? {
        guard canGoBack, let currentIndex else { return nil }
        let newIndex = currentIndex - 1
        self.currentIndex = newIndex
        currentWord = history[newIndex]
        currentQuery = currentWord
        persist()
        return currentWord
    }

    func goForward() -> String? {
        guard canGoForward, let currentIndex else { return nil }
        let newIndex = currentIndex + 1
        self.currentIndex = newIndex
        currentWord = history[newIndex]
        currentQuery = currentWord
        persist()
        return currentWord
    }

    func updateCurrentQuery(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == currentWord {
            if let matchingIndex = history.lastIndex(of: normalized) {
                currentIndex = matchingIndex
            }
        } else if currentIndex != history.count {
            currentIndex = history.count
        }

        guard currentQuery != query else { return }
        currentQuery = query
        persist()
    }

    private func persist() {
        defaults.set(history, forKey: PreferenceKey.wordHistory)
        if let currentIndex {
            defaults.set(currentIndex, forKey: PreferenceKey.wordHistoryIndex)
        } else {
            defaults.removeObject(forKey: PreferenceKey.wordHistoryIndex)
        }
        defaults.set(currentWord, forKey: PreferenceKey.lastLookupWord)
        defaults.set(currentQuery, forKey: PreferenceKey.lastSearchQuery)
    }
}
