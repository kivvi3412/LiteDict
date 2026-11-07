import AppKit
import SwiftUI

enum SentenceHighlightPalette {
    static func color(opacity: Double) -> Color {
        Color(nsColor: nsColor(opacity: opacity))
    }

    static func nsColor(opacity: Double) -> NSColor {
        NSColor.systemYellow.withAlphaComponent(CGFloat(opacity))
    }
}

struct SelectableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    @Binding var selectionRange: NSRange
    let clearSelectionToken: Int
    let highlightedSentenceRange: NSRange?
    let onHoveredCharacterIndex: ((Int?) -> Void)?
    let highlightOpacity: Double
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SentenceHighlightingTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 320)
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 320,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6

        textView.delegate = context.coordinator
        textView.onHoveredCharacterIndex = { [weak coordinator = context.coordinator] index in
            coordinator?.parent.onHoveredCharacterIndex?(index)
        }
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.placeholder = "Input text here"
        if !text.isEmpty {
            textView.string = text
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        scrollView.isHidden = !isActive
        if isActive {
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let becameActive = !context.coordinator.wasActive && isActive
        let becameInactive = context.coordinator.wasActive && !isActive
        context.coordinator.wasActive = isActive
        context.coordinator.parent = self
        nsView.isHidden = !isActive
        guard let textView = nsView.documentView as? SentenceHighlightingTextView else {
            return
        }

        if becameInactive {
            textView.resetHoveredCharacter()
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.resetHoveredCharacter()
        }
        textView.placeholder = "Input text here"

        if !context.coordinator.didRestoreInitialScroll,
           nsView.contentView.bounds.height > 0,
           !textView.string.isEmpty {
            let savedOffset = SentenceTranslateStore.shared.sourceScrollOffset
            if savedOffset > 0, let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
                nsView.contentView.setBoundsOrigin(NSPoint(x: 0, y: savedOffset))
                nsView.reflectScrolledClipView(nsView.contentView)
            }
            context.coordinator.didRestoreInitialScroll = true
        }

        if becameActive {
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }

        if context.coordinator.lastClearSelectionToken != clearSelectionToken {
            context.coordinator.lastClearSelectionToken = clearSelectionToken
            if !textView.hasMarkedText() {
                let range = textView.selectedRange()
                if range.length > 0 {
                    textView.setSelectedRange(NSRange(location: range.location, length: 0))
                }
            }
        }

        applySentenceHighlight(to: textView, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        var lastClearSelectionToken: Int
        var lastHighlightedRange: NSRange?
        var lastHighlightedText = ""
        var lastHighlightOpacity: Double?
        var wasActive: Bool
        var didRestoreInitialScroll = false

        init(_ parent: SelectableTextView) {
            self.parent = parent
            lastClearSelectionToken = parent.clearSelectionToken
            lastHighlightedRange = parent.highlightedSentenceRange
            lastHighlightedText = parent.text
            wasActive = parent.isActive
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard parent.isActive,
                  let clipView = notification.object as? NSClipView,
                  clipView.bounds.height > 0 else {
                return
            }
            SentenceTranslateStore.shared.sourceScrollOffset = max(0, clipView.bounds.origin.y)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.needsDisplay = true
            guard !textView.hasMarkedText() else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !textView.hasMarkedText() else { return }
            let range = textView.selectedRange()

            if range.length > 0, let swiftRange = Range(range, in: textView.string) {
                let selection = String(textView.string[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.parent.selectedText = selection
                    self.parent.selectionRange = range
                }
            } else {
                let sourceLength = (textView.string as NSString).length
                let isUserNavigation: Bool = {
                    guard let eventType = NSApp.currentEvent?.type else { return false }
                    switch eventType {
                    case .leftMouseDown, .leftMouseUp, .keyDown:
                        return true
                    default:
                        return false
                    }
                }()
                let caretIndex: Int? = (isUserNavigation && sourceLength > 0)
                    ? min(max(0, range.location), sourceLength - 1)
                    : nil
                DispatchQueue.main.async {
                    if !self.parent.selectedText.isEmpty {
                        self.parent.selectedText = ""
                    }
                    if self.parent.selectionRange.length != 0 {
                        self.parent.selectionRange = NSRange(location: 0, length: 0)
                    }
                    if let caretIndex,
                       let highlightingTextView = textView as? SentenceHighlightingTextView {
                        highlightingTextView.setHoveredCharacterIndex(caretIndex)
                    }
                }
            }
        }
    }

    private func applySentenceHighlight(
        to textView: SentenceHighlightingTextView,
        coordinator: Coordinator
    ) {
        guard coordinator.lastHighlightedRange != highlightedSentenceRange
                || coordinator.lastHighlightedText != textView.string
                || coordinator.lastHighlightOpacity != highlightOpacity else {
            return
        }

        coordinator.lastHighlightedRange = highlightedSentenceRange
        coordinator.lastHighlightedText = textView.string
        coordinator.lastHighlightOpacity = highlightOpacity

        guard let highlightedSentenceRange else {
            textView.highlightedRange = nil
            return
        }

        let sourceLength = (textView.string as NSString).length
        guard highlightedSentenceRange.location != NSNotFound,
              highlightedSentenceRange.length > 0,
              NSMaxRange(highlightedSentenceRange) <= sourceLength else {
            textView.highlightedRange = nil
            return
        }

        textView.highlightColor = SentenceHighlightPalette.nsColor(
            opacity: highlightOpacity
        )
        textView.highlightedRange = highlightedSentenceRange
    }
}

struct TranslatedParagraphTextView: NSViewRepresentable {
    let sentences: [SentencePair]
    let direction: TranslationDirection
    let highlightedSentenceID: Int?
    let highlightOpacity: Double
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SentenceHighlightingTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 320)
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 320,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 4

        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.isHidden = !isActive

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.isActive = isActive
        nsView.isHidden = !isActive
        guard let textView = nsView.documentView as? SentenceHighlightingTextView else {
            return
        }

        let (combinedText, rangeMap) = buildTargetContent()
        if textView.string != combinedText {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.paragraphSpacing = 4
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: combinedText, attributes: attributes)
            )
            context.coordinator.lastHighlightedSentenceID = nil
        }

        if !context.coordinator.didRestoreInitialScroll,
           nsView.contentView.bounds.height > 0,
           !textView.string.isEmpty {
            let savedOffset = SentenceTranslateStore.shared.targetScrollOffset
            if savedOffset > 0, let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
                nsView.contentView.setBoundsOrigin(NSPoint(x: 0, y: savedOffset))
                nsView.reflectScrolledClipView(nsView.contentView)
            }
            context.coordinator.didRestoreInitialScroll = true
        }

        let targetRange = highlightedSentenceID.flatMap { rangeMap[$0] }
        let highlightChanged = context.coordinator.lastHighlightedSentenceID != highlightedSentenceID
            || context.coordinator.lastHighlightOpacity != highlightOpacity

        guard highlightChanged else { return }
        context.coordinator.lastHighlightedSentenceID = highlightedSentenceID
        context.coordinator.lastHighlightOpacity = highlightOpacity

        textView.highlightColor = SentenceHighlightPalette.nsColor(
            opacity: highlightOpacity
        )
        textView.highlightedRange = targetRange

        if let targetRange,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: targetRange,
                actualCharacterRange: nil
            )
            let boundingRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )

            let clipView = nsView.contentView
            let visibleHeight = clipView.bounds.height
            let documentHeight = textView.bounds.height
            guard documentHeight > visibleHeight, visibleHeight > 0 else { return }

            let currentMinY = clipView.bounds.origin.y
            let currentMaxY = currentMinY + visibleHeight

            let targetY: CGFloat
            if boundingRect.minY < currentMinY || boundingRect.height > visibleHeight {
                targetY = boundingRect.minY
            } else if boundingRect.maxY > currentMaxY {
                targetY = boundingRect.maxY - visibleHeight
            } else {
                return
            }

            let clampedY = min(max(0, targetY), max(0, documentHeight - visibleHeight))
            guard abs(clampedY - currentMinY) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.18
                clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            }
            nsView.reflectScrolledClipView(clipView)
        }
    }

    private func buildTargetContent() -> (String, [Int: NSRange]) {
        var combined = ""
        var ranges: [Int: NSRange] = [:]
        var cursor = 0

        for (index, sentence) in sentences.enumerated() {
            if index > 0 {
                combined += "\n"
                cursor += 1
            }
            let text = direction.targetText(for: sentence)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let length = (text as NSString).length
            ranges[sentence.id] = NSRange(location: cursor, length: length)
            combined += text
            cursor += length
        }
        return (combined, ranges)
    }

    final class Coordinator: NSObject {
        var lastHighlightedSentenceID: Int?
        var lastHighlightOpacity: Double?
        var isActive: Bool
        var didRestoreInitialScroll = false

        init(isActive: Bool) {
            self.isActive = isActive
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard isActive,
                  let clipView = notification.object as? NSClipView,
                  clipView.bounds.height > 0 else {
                return
            }
            SentenceTranslateStore.shared.targetScrollOffset = max(0, clipView.bounds.origin.y)
        }
    }
}

final class SentenceHighlightingTextView: NSTextView {
    var onHoveredCharacterIndex: ((Int?) -> Void)?

    var placeholder = "" {
        didSet {
            needsDisplay = true
        }
    }

    var highlightedRange: NSRange? {
        didSet {
            needsDisplay = true
        }
    }

    var highlightColor = NSColor.systemYellow.withAlphaComponent(0.2) {
        didSet {
            needsDisplay = true
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredCharacterIndex: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredCharacter(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredCharacterIndex(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHoveredCharacter(at: event.locationInWindow)
    }

    func resetHoveredCharacter() {
        setHoveredCharacterIndex(nil)
    }

    private func updateHoveredCharacter(at windowPoint: NSPoint) {
        guard let layoutManager,
              let textContainer,
              !string.isEmpty,
              layoutManager.numberOfGlyphs > 0 else {
            setHoveredCharacterIndex(nil)
            return
        }

        let viewPoint = convert(windowPoint, from: nil)
        guard visibleRect.contains(viewPoint) else {
            setHoveredCharacterIndex(nil)
            return
        }

        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let usedRect = layoutManager.usedRect(for: textContainer)
        guard containerPoint.x >= -4,
              containerPoint.y >= usedRect.minY - 4,
              containerPoint.y <= usedRect.maxY + 4 else {
            setHoveredCharacterIndex(nil)
            return
        }

        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            setHoveredCharacterIndex(nil)
            return
        }

        var lineGlyphRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineGlyphRange
        )
        guard lineRect.insetBy(dx: -4, dy: -4).contains(containerPoint) else {
            setHoveredCharacterIndex(nil)
            return
        }

        let nsString = string as NSString
        let lineCharRange = layoutManager.characterRange(
            forGlyphRange: lineGlyphRange,
            actualGlyphRange: nil
        )
        guard lineCharRange.location != NSNotFound,
              lineCharRange.length > 0,
              NSMaxRange(lineCharRange) <= nsString.length else {
            setHoveredCharacterIndex(nil)
            return
        }

        let lineSubstring = nsString.substring(with: lineCharRange)
        guard !lineSubstring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setHoveredCharacterIndex(nil)
            return
        }

        var characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < nsString.length else {
            setHoveredCharacterIndex(nil)
            return
        }

        let whitespace = CharacterSet.whitespacesAndNewlines
        if let scalar = UnicodeScalar(nsString.character(at: characterIndex)),
           whitespace.contains(scalar) {
            var resolved: Int?
            var backward = characterIndex - 1
            while backward >= lineCharRange.location {
                if let s = UnicodeScalar(nsString.character(at: backward)),
                   !whitespace.contains(s) {
                    resolved = backward
                    break
                }
                backward -= 1
            }
            if resolved == nil {
                var forward = characterIndex + 1
                while forward < NSMaxRange(lineCharRange) {
                    if let s = UnicodeScalar(nsString.character(at: forward)),
                       !whitespace.contains(s) {
                        resolved = forward
                        break
                    }
                    forward += 1
                }
            }
            if let resolved {
                characterIndex = resolved
            } else {
                setHoveredCharacterIndex(nil)
                return
            }
        }

        setHoveredCharacterIndex(characterIndex)
    }

    func setHoveredCharacterIndex(_ index: Int?) {
        guard hoveredCharacterIndex != index else { return }
        hoveredCharacterIndex = index
        DispatchQueue.main.async { [weak self] in
            self?.onHoveredCharacterIndex?(index)
        }
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        if string.isEmpty, !hasMarkedText(), !placeholder.isEmpty {
            let placeholderColor = NSColor.placeholderTextColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 17),
                .foregroundColor: placeholderColor
            ]
            let origin = textContainerOrigin
            let padding = textContainer?.lineFragmentPadding ?? 0
            (placeholder as NSString).draw(
                at: NSPoint(x: origin.x + padding, y: origin.y),
                withAttributes: attributes
            )
        }

        guard let highlightedRange,
              let layoutManager,
              let textContainer,
              highlightedRange.location != NSNotFound else {
            return
        }

        let sourceLength = (string as NSString).length
        let validRange = NSIntersectionRange(
            highlightedRange,
            NSRange(location: 0, length: sourceLength)
        )
        guard validRange.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: validRange,
            actualCharacterRange: nil
        )
        let origin = textContainerOrigin
        let color = highlightColor

        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            let drawRect = rect
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -1, dy: 1)
            color.setFill()
            NSBezierPath(rect: drawRect).fill()
        }
    }
}
