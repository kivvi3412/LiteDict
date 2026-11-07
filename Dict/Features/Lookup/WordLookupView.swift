import Combine
import SwiftUI

struct WordLookupView: View {
    var isActive = true
    let lookupRequest: WordLookupRequest?
    let restoredWord: String
    let restoredQuery: String
    let canGoBack: Bool
    let canGoForward: Bool
    let onQueryChange: (String) -> Void
    let onRecordHistory: (String) -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    @AppStorage(PreferenceKey.autoPlayAudio) private var autoPlayAudio = false

    @State private var query: String
    @State private var submittedWord: String
    @State private var suggestions: [SuggestEntry] = []
    @State private var nativeEntryNames: Set<String> = []
    @State private var result: WordLookupResult?
    @State private var status: LookupStatus
    @State private var showsSuggestions = false
    @State private var highlightedSuggestionIndex: Int?
    @State private var suppressAutocomplete: Bool
    @State private var pendingProgrammaticQuery: String?
    @State private var querySubject = PassthroughSubject<String, Never>()
    @State private var suggestionCancellable: AnyCancellable?
    @State private var autocompleteTask: Task<Void, Never>?
    @State private var lookupTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    init(
        isActive: Bool = true,
        lookupRequest: WordLookupRequest?,
        restoredWord: String,
        restoredQuery: String,
        canGoBack: Bool,
        canGoForward: Bool,
        onQueryChange: @escaping (String) -> Void,
        onRecordHistory: @escaping (String) -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.lookupRequest = lookupRequest
        self.restoredWord = restoredWord
        self.restoredQuery = restoredQuery
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onQueryChange = onQueryChange
        self.onRecordHistory = onRecordHistory
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward

        let trimmedWord = restoredWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = restoredQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if lookupRequest == nil,
           !trimmedWord.isEmpty,
           trimmedQuery == trimmedWord,
           let cached = Services.shared.cachedLookupResult(for: trimmedWord) {
            _query = State(initialValue: trimmedWord)
            _submittedWord = State(initialValue: trimmedWord)
            _result = State(initialValue: cached)
            _status = State(initialValue: .loaded)
            _suppressAutocomplete = State(initialValue: true)
        } else if lookupRequest == nil, !trimmedQuery.isEmpty, trimmedQuery != trimmedWord {
            _query = State(initialValue: restoredQuery)
            _submittedWord = State(initialValue: "")
            _result = State(initialValue: nil)
            _status = State(initialValue: .idle)
            _suppressAutocomplete = State(initialValue: true)
        } else {
            _query = State(initialValue: "")
            _submittedWord = State(initialValue: "")
            _result = State(initialValue: nil)
            _status = State(initialValue: .idle)
            _suppressAutocomplete = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchArea

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onAppear {
            configureAutocomplete()
            if let lookupRequest {
                applyLookupRequest(lookupRequest)
            } else {
                restoreLastWordIfNeeded()
            }
        }
        .onChange(of: lookupRequest) { _, newRequest in
            applyLookupRequest(newRequest)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                searchFieldFocused = false
                showsSuggestions = false
            }
        }
        .onDisappear {
            suggestionCancellable?.cancel()
            autocompleteTask?.cancel()
        }
    }

    private var searchArea: some View {
        HStack(spacing: 12) {
            TextField("输入单词或文本", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .focused($searchFieldFocused)
                .onKeyPress(.downArrow) {
                    moveSuggestionHighlight(by: 1)
                }
                .onKeyPress(.upArrow) {
                    moveSuggestionHighlight(by: -1)
                }
                .onSubmit {
                    submitSearch()
                }
                .onExitCommand {
                    clearSearch()
                }

            HStack(spacing: 4) {
                Button(action: onGoBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoBack ? Color.primary : Color.secondary.opacity(0.35))
                .disabled(!canGoBack)
                .help("上一个查过的词")

                Button(action: onGoForward) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoForward ? Color.primary : Color.secondary.opacity(0.35))
                .disabled(!canGoForward)
                .help("下一个查过的词")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 21)
        .background(.ultraThinMaterial)
        .onChange(of: query) { _, newValue in
            onQueryChange(newValue)
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                suggestions = []
                nativeEntryNames = []
                showsSuggestions = false
                highlightedSuggestionIndex = nil
                result = nil
                submittedWord = ""
                status = .idle
                autocompleteTask?.cancel()
                suppressAutocomplete = true
                pendingProgrammaticQuery = nil
                return
            }

            if pendingProgrammaticQuery == newValue {
                pendingProgrammaticQuery = nil
                highlightedSuggestionIndex = nil
                return
            }

            if suppressAutocomplete {
                suppressAutocomplete = false
            }

            highlightedSuggestionIndex = nil
            querySubject.send(newValue)

            if trimmed != submittedWord {
                lookupTask?.cancel()
            }
        }
        .onChange(of: searchFieldFocused) { _, isFocused in
            showsSuggestions = isFocused
                && !suppressAutocomplete
                && !suggestions.isEmpty
            if isFocused,
               !suppressAutocomplete,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                querySubject.send(query)
            }
        }
    }

    @ViewBuilder
    private var suggestionsContent: some View {
        let displayedSuggestions = Array(suggestions.prefix(6))
        if !displayedSuggestions.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(
                        Array(displayedSuggestions.enumerated()),
                        id: \.element.id
                    ) { index, entry in
                        Button {
                            selectSuggestion(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: nativeEntryNames.contains(entry.entry)
                                      ? "book.closed.fill" : "character.cursor.ibeam")
                                    .font(.system(size: 12))
                                    .foregroundStyle(nativeEntryNames.contains(entry.entry)
                                                     ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.entry)
                                        .font(.system(size: 15, weight: .semibold))

                                    if let explain = entry.explain, !explain.isEmpty {
                                        Text(explain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 12)
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(
                                highlightedSuggestionIndex == index
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(
                                    cornerRadius: 8,
                                    style: .continuous
                                )
                            )
                        }
                        .buttonStyle(.plain)

                        if index < displayedSuggestions.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsSuggestions, !suggestions.isEmpty {
            suggestionsContent
        } else {
            switch status {
            case .idle:
                Color.clear
            case .loading:
                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 28)
            case let .failed(message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
            case .loaded:
                if let result {
                    ScrollView {
                        WordDetailView(
                            result: result,
                            onPlay: { word, type in
                                Task {
                                    await Services.shared.playAudio(word: word, type: type)
                                }
                            },
                            onLookup: { word in
                                beginLookup(word, recordHistory: true)
                            }
                        )
                        .id(result.word)
                        .frame(maxWidth: 880, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                        .padding(.bottom, 30)
                    }
                }
            }
        }
    }

    private func configureAutocomplete() {
        guard suggestionCancellable == nil else { return }
        suggestionCancellable = querySubject
            .debounce(for: .milliseconds(25), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { term in
                startAutocomplete(for: term)
            }
    }

    private func startAutocomplete(for rawTerm: String) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        autocompleteTask?.cancel()
        guard !term.isEmpty,
              searchFieldFocused,
              !suppressAutocomplete else {
            suggestions = []
            nativeEntryNames = []
            showsSuggestions = false
            highlightedSuggestionIndex = nil
            return
        }

        autocompleteTask = Task { @MainActor in
            do {
                let entries = try await Services.shared.fetchSuggestions(for: term)
                try Task.checkCancellation()
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }

                result = nil
                status = .idle
                suggestions = Array(entries.prefix(6))
                nativeEntryNames = []
                highlightedSuggestionIndex = nil
                showsSuggestions = searchFieldFocused && !entries.isEmpty

                let nativeNames = await findNativeDictionaryEntries(
                    in: suggestions.map(\.entry)
                )
                try Task.checkCancellation()
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                nativeEntryNames = nativeNames
            } catch is CancellationError {
                return
            } catch {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                result = nil
                status = .idle
                suggestions = []
                nativeEntryNames = []
                showsSuggestions = false
            }
        }
    }

    private func findNativeDictionaryEntries(in words: [String]) async -> Set<String> {
        var matches: Set<String> = []
        for word in words {
            guard !Task.isCancelled else { break }
            if await Services.hasNativeOxfordEntry(for: word) {
                matches.insert(word)
            }
        }
        return matches
    }

    private func moveSuggestionHighlight(by offset: Int) -> KeyPress.Result {
        let displayedSuggestions = Array(suggestions.prefix(6))
        guard searchFieldFocused,
               showsSuggestions,
               !suppressAutocomplete,
               !displayedSuggestions.isEmpty else {
            return .ignored
        }

        if let highlightedSuggestionIndex,
           displayedSuggestions.indices.contains(highlightedSuggestionIndex) {
            let nextIndex = highlightedSuggestionIndex + offset
            self.highlightedSuggestionIndex = min(
                max(0, nextIndex),
                displayedSuggestions.count - 1
            )
        } else {
            highlightedSuggestionIndex = offset > 0
                ? 0
                : displayedSuggestions.count - 1
        }
        return .handled
    }

    private func submitSearch() {
        let displayedSuggestions = Array(suggestions.prefix(6))
        if let highlightedSuggestionIndex,
           displayedSuggestions.indices.contains(highlightedSuggestionIndex) {
            selectSuggestion(displayedSuggestions[highlightedSuggestionIndex])
        } else {
            beginLookup(query)
        }
    }

    private func selectSuggestion(_ entry: SuggestEntry) {
        pendingProgrammaticQuery = entry.entry
        query = entry.entry
        beginLookup(entry.entry)
    }

    private func clearSearch() {
        onQueryChange("")
        autocompleteTask?.cancel()
        lookupTask?.cancel()
        pendingProgrammaticQuery = ""
        suppressAutocomplete = true
        query = ""
        submittedWord = ""
        suggestions = []
        nativeEntryNames = []
        showsSuggestions = false
        highlightedSuggestionIndex = nil
        result = nil
        status = .idle
        searchFieldFocused = true
    }

    private func applyLookupRequest(_ request: WordLookupRequest?) {
        guard let request, !request.word.isEmpty else { return }
        beginLookup(request.word, recordHistory: false)
    }

    private func restoreLastWordIfNeeded() {
        let word = restoredWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = restoredQuery
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result == nil,
              status == .idle else {
            return
        }

        if trimmedQuery == word, !word.isEmpty {
            beginLookup(word, recordHistory: false, playAudio: false)
        } else {
            suppressAutocomplete = true
            pendingProgrammaticQuery = queryText
            query = queryText
        }
    }

    private func beginLookup(
        _ rawWord: String,
        recordHistory: Bool = true,
        playAudio: Bool = true
    ) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if recordHistory {
            onRecordHistory(word)
        }

        autocompleteTask?.cancel()
        lookupTask?.cancel()
        suppressAutocomplete = true
        if query != word {
            pendingProgrammaticQuery = word
        }
        query = word
        submittedWord = word
        suggestions = []
        nativeEntryNames = []
        showsSuggestions = false
        highlightedSuggestionIndex = nil
        searchFieldFocused = false

        if let cached = Services.shared.cachedLookupResult(for: word) {
            result = cached
            status = .loaded
            if playAudio, autoPlayAudio {
                Task { @MainActor in
                    await Services.shared.playAudio(word: cached.word, type: 2)
                }
            }
            return
        }

        result = nil
        status = .loading

        lookupTask = Task { @MainActor in
            do {
                let lookupResult = try await Services.shared.lookupWord(word)
                try Task.checkCancellation()
                result = lookupResult
                status = .loaded

                if playAudio, autoPlayAudio {
                    await Services.shared.playAudio(word: lookupResult.word, type: 2)
                }
            } catch is CancellationError {
                return
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
