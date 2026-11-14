// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import UIKit

    /// UIKit owns selection and IME composition; only committed content leaves this local buffer.
    @MainActor final class StreamTextInput: UITextView, UITextViewDelegate {
        var onCommit: ((String) -> Void)?
        var onDelete: (() -> Void)?
        var onPaste: (() -> Void)?
        var onPresses: ((Set<UIPress>, Bool) -> Set<UIPress>)?
        private var updatingMarkedText = false

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            delegate = self
            autocorrectionType = .no
            autocapitalizationType = .none
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
            textContentType = .oneTimeCode
            if #available(iOS 17, *) { inlinePredictionType = .no }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(frame:textContainer:)") }

        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            updatingMarkedText = true
            super.setMarkedText(markedText, selectedRange: selectedRange)
            updatingMarkedText = false
            commitIfReady()
        }

        override func unmarkText() {
            super.unmarkText()
            commitIfReady()
        }

        override func insertText(_ text: String) {
            super.insertText(text)
            commitIfReady()
        }

        override func deleteBackward() {
            if markedTextRange == nil && text.isEmpty { onDelete?() }
            else { super.deleteBackward() }
        }

        override func paste(_ sender: Any?) { onPaste?() }

        func textViewDidChange(_ textView: UITextView) { commitIfReady() }
        func textViewDidEndEditing(_ textView: UITextView) { commitIfReady() }

        func discardComposition() {
            updatingMarkedText = true
            super.unmarkText()
            text = ""
            updatingMarkedText = false
        }

        private func commitIfReady() {
            guard !updatingMarkedText, markedTextRange == nil, !text.isEmpty else { return }
            let committed = text ?? ""
            text = ""
            onCommit?(committed)
        }

        /// Public UIKit exposes a language tag, not an ASCII-capability flag. Conservatively
        /// leave non-Latin input modes (including CJK) to UIKit's text/composition system.
        var usesTextSystem: Bool {
            if markedTextRange != nil { return true }
            guard let language = textInputMode?.primaryLanguage else { return false }
            return !Self.isASCIICapable(language: language)
        }

        static func isASCIICapable(language: String) -> Bool {
            let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
            return !(NSLocale(localeIdentifier: language).exemplarCharacterSet as CharacterSet)
                .intersection(letters).isEmpty
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if usesTextSystem { super.pressesBegan(presses, with: event); return }
            let remaining = presses.subtracting(onPresses?(presses, true) ?? [])
            if !remaining.isEmpty { next?.pressesBegan(remaining, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(onPresses?(presses, false) ?? [])
            if !remaining.isEmpty {
                if usesTextSystem { super.pressesEnded(remaining, with: event) }
                else { next?.pressesEnded(remaining, with: event) }
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(onPresses?(presses, false) ?? [])
            if !remaining.isEmpty {
                if usesTextSystem { super.pressesCancelled(remaining, with: event) }
                else { next?.pressesCancelled(remaining, with: event) }
            }
        }
    }
#endif
