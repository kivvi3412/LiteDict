import AppKit
import SwiftUI

enum AppWindowMetrics {
    static let defaultWidth: CGFloat = 760
    static let defaultHeight: CGFloat = 520
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 159
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
                canGoBack: lookupHistory.canGoBack,
                canGoForward: lookupHistory.canGoForward,
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
