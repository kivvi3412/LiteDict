import AppKit
import Combine
import SwiftUI

private enum AppWindowMetrics {
    static let defaultWidth: CGFloat = 760
    static let defaultHeight: CGFloat = 520
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 159
}

private final class LookupHistoryStore: ObservableObject {
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

@main
struct LiteDictApp: App {
    @StateObject private var lookupHistory = LookupHistoryStore()
    @State private var selection: AppSection = .lookup
    @State private var lookupRequest: WordLookupRequest?
    @AppStorage(PreferenceKey.glassOpacity) private var glassOpacity = 0.86

    var body: some Scene {
        WindowGroup("LiteDict") {
            ZStack {
                VisualEffectBackground()
                    .ignoresSafeArea()

                Color(nsColor: .windowBackgroundColor)
                    .opacity(glassOpacity)
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    sidebar

                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)

                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                }
                .ignoresSafeArea(.container, edges: .top)

                WindowControlConfigurator()
                    .frame(width: 0, height: 0)
            }
            .frame(
                minWidth: AppWindowMetrics.minimumWidth,
                minHeight: AppWindowMetrics.minimumHeight
            )
        }
        .defaultSize(
            width: AppWindowMetrics.defaultWidth,
            height: AppWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: 34)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 18)

                            Text(section.title)
                                .font(.system(size: 14))

                            Spacer()
                        }
                        .foregroundStyle(selection == section ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(
                            selection == section ? Color.primary.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .frame(width: AppWindowMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var pageContent: some View {
        ZStack {
            WordLookupView(
                isActive: selection == .lookup,
                lookupRequest: lookupRequest,
                restoredWord: lookupHistory.currentWord,
                restoredQuery: lookupHistory.currentQuery,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                onQueryChange: queryDidChange,
                onRecordHistory: recordWord,
                onGoBack: goBack,
                onGoForward: goForward
            )
            .opacity(selection == .lookup ? 1 : 0)
            .allowsHitTesting(selection == .lookup)

            SentenceTranslateView(isActive: selection == .sentence)
                .opacity(selection == .sentence ? 1 : 0)
                .allowsHitTesting(selection == .sentence)

            if selection == .settings {
                SettingsView()
            }
        }
    }

    private var canGoBack: Bool {
        lookupHistory.canGoBack
    }

    private var canGoForward: Bool {
        lookupHistory.canGoForward
    }

    private func recordWord(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        lookupHistory.record(word)
        lookupRequest = nil
    }

    private func queryDidChange(_ query: String) {
        lookupHistory.updateCurrentQuery(query)
        lookupRequest = nil
    }

    private func goBack() {
        guard let word = lookupHistory.goBack() else { return }
        lookupRequest = WordLookupRequest(word: word)
        selection = .lookup
    }

    private func goForward() {
        guard let word = lookupHistory.goForward() else { return }
        lookupRequest = WordLookupRequest(word: word)
        selection = .lookup
    }
}

private struct WindowControlConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(window: nsView.window)
        }
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var originalFrames: [NSWindow.ButtonType: NSRect] = [:]

        func configure(window: NSWindow?) {
            guard let window else { return }
            if configuredWindow !== window {
                configuredWindow = window
                originalFrames = [:]
            }

            for type in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(type) else { continue }
                if originalFrames[type] == nil {
                    originalFrames[type] = button.frame
                }
                guard var frame = originalFrames[type] else { continue }
                frame.origin.y -= 6
                button.frame = frame
            }
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}
