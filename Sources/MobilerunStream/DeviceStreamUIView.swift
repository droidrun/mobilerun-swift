// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import UIKit
    import Combine
    import MobilerunProtocol
    import MobilerunStreamCore
    @preconcurrency import LiveKitWebRTC

    /// UIKit renderer and input surface. All video and input coordinates use the same aspect-fit rect.
    @MainActor public final class DeviceStreamUIView: UIView {
        private let renderer = LKRTCMTLVideoView(frame: .zero)
        private let textClient = StreamTextInput(frame: .zero, textContainer: nil)
        private var session: DeviceStreamSession
        private var track: LKRTCVideoTrack?
        private var subscriptions = Set<AnyCancellable>()
        private var pointers = PointerInput<ObjectIdentifier>()
        private var geometry: InputGeometry?
        private var displayLink: DisplayLinkTarget?
        private weak var controller: DeviceStreamViewController?
        private var pressedKeys: [Int: (String, InputModifiers)] = [:]

        #if DEBUG
            var onInput: ((Data, Bool) -> Void)?
        #endif

        /// Disabling local control clears composition, focus and active input.
        public var hasControl: Bool {
            willSet {
                if hasControl && !newValue { cancelInput() }
            }
            didSet {
                if !hasControl {
                    textClient.discardComposition()
                    hideKeyboard()
                }
            }
        }

        /// Rendered upright video rect in local view points, or nil before a frame arrives.
        public var renderedVideoRect: CGRect? { geometry?.rect }

        public init(session: DeviceStreamSession, hasControl: Bool) {
            self.session = session
            self.hasControl = hasControl
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            isOpaque = false
            renderer.videoContentMode = .scaleAspectFit
            renderer.isUserInteractionEnabled = false
            renderer.isHidden = true
            addSubview(renderer)
            textClient.alpha = 0.01
            textClient.accessibilityElementsHidden = true
            textClient.onCommit = { [weak self] in self?.send(KeyInput.committedText($0)) }
            textClient.onDelete = { [weak self] in self?.send(KeyInput.press(AndroidKey.del)) }
            textClient.onPaste = { [weak self] in self?.paste(nil) }
            textClient.onPresses = { [weak self] in self?.handlePresses($0, down: $1) ?? [] }
            addSubview(textClient)
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.allowedTouchTypes = [] // Direct finger drags stay in touchesMoved.
            scroll.cancelsTouchesInView = false
            addGestureRecognizer(scroll)
            observeSession()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(session:hasControl:)") }

        deinit {
            let track = track
            let renderer = renderer
            let displayLink = displayLink
            Task { @MainActor in
                displayLink?.invalidate()
                track?.remove(renderer)
            }
        }

        public override var canBecomeFirstResponder: Bool { hasControl }

        public func showKeyboard() {
            guard hasControl, window != nil else { return }
            textClient.becomeFirstResponder()
        }

        public func hideKeyboard() {
            if textClient.isFirstResponder { textClient.resignFirstResponder() }
            if isFirstResponder { resignFirstResponder() }
        }

        public func sendSystemKey(_ key: SystemKey) {
            let code: Int
            switch key {
            case .back: code = AndroidKey.keycodeBack
            case .home: code = AndroidKey.keycodeHome
            case .recent: code = AndroidKey.keycodeAppSwitch
            }
            send(KeyInput.press(code))
        }

        public override func paste(_ sender: Any?) {
            guard hasControl, let text = UIPasteboard.general.string, !text.isEmpty else { return }
            send([ControlMessages.setClipboard(text: text, paste: true)])
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            renderer.frame = bounds
            textClient.frame = CGRect(x: bounds.minX - 2, y: bounds.minY - 2, width: 1, height: 1)
            updateGeometry()
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                cancelInput()
                hideKeyboard()
                displayLink?.invalidate()
                displayLink = nil
            } else if displayLink == nil {
                displayLink = DisplayLinkTarget(view: self)
            }
        }

        func update(session: DeviceStreamSession, hasControl: Bool) {
            if self.session !== session {
                cancelInput()
                textClient.discardComposition()
                subscriptions.removeAll()
                setTrack(nil)
                self.session = session
                observeSession()
            }
            self.hasControl = hasControl
        }

        func bind(_ controller: DeviceStreamViewController?) {
            if self.controller !== controller {
                if self.controller?.view === self { self.controller?.view = nil }
                self.controller = controller
            }
            controller?.view = self
        }

        func detach() {
            cancelInput()
            hideKeyboard()
            subscriptions.removeAll()
            setTrack(nil)
            geometry = nil
            displayLink?.invalidate()
            displayLink = nil
            if controller?.view === self { controller?.view = nil }
        }

        private func observeSession() {
            session.$videoTrack.sink { [weak self] in self?.setTrack($0) }.store(in: &subscriptions)
            session.$videoSize.sink { [weak self] size in
                self?.updateGeometry(video: size)
            }.store(in: &subscriptions)
            session.$status.sink { [weak self] status in
                if status != .connected {
                    self?.cancelInput()
                    self?.textClient.discardComposition()
                }
            }.store(in: &subscriptions)
        }

        private func setTrack(_ newTrack: LKRTCVideoTrack?) {
            guard track !== newTrack else { return }
            cancelInput()
            track?.remove(renderer)
            track = newTrack
            renderer.isHidden = newTrack == nil
            newTrack?.add(renderer)
        }

        private func updateGeometry() { updateGeometry(video: session.videoSize) }

        private func updateGeometry(video: VideoSize?) {
            let updated = InputGeometry(bounds: bounds, video: video)
            if geometry != updated {
                cancelInput()
                geometry = updated
            }
        }

        private func send(_ packets: [Data]) {
            guard hasControl else { return }
            for packet in packets {
                let sent = session.sendControl(packet)
                #if DEBUG
                    onInput?(packet, sent)
                #endif
            }
        }

        private func cancelInput() {
            send(pointers.cancel())
            for (usage, key) in pressedKeys.sorted(by: { $0.key < $1.key }) {
                send(KeyInput.route(usage: usage, text: key.0, down: false, modifiers: key.1,
                                    clipboard: { nil }))
            }
            pressedKeys.removeAll()
        }

        func flushMoves() { send(pointers.flushMoves()) }

        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard hasControl else { return }
            if !textClient.isFirstResponder { becomeFirstResponder() }
            for touch in touches {
                if touch.type == .indirectPointer && event?.buttonMask.contains(.primary) != true { continue }
                beginPointer(ObjectIdentifier(touch), at: touch.location(in: self),
                             mouse: touch.type == .indirectPointer)
            }
        }

        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard hasControl else { return }
            for touch in touches { movePointer(ObjectIdentifier(touch), to: touch.location(in: self)) }
        }

        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, cancelled: false)
        }

        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, cancelled: true)
        }

        private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
            for touch in touches {
                endPointer(ObjectIdentifier(touch), cancelled: cancelled)
            }
        }

        // Shared by native events and the Debug example's deterministic simulator input driver.
        func beginPointer(_ id: ObjectIdentifier, at point: CGPoint, mouse: Bool = false) {
            guard hasControl, let geometry,
                  let packet = pointers.down(id, at: point, geometry: geometry, mouse: mouse) else { return }
            send([packet])
        }

        func movePointer(_ id: ObjectIdentifier, to point: CGPoint) {
            guard hasControl else { return }
            pointers.move(id, to: point)
        }

        func endPointer(_ id: ObjectIdentifier, cancelled: Bool = false) {
            if let packet = pointers.up(id, cancelled: cancelled) { send([packet]) }
        }

        @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            routeHover(at: recognizer.location(in: self), buttons: recognizer.buttonMask)
        }

        func routeHover(at location: CGPoint, buttons: UIEvent.ButtonMask) {
            guard hasControl, let geometry, let point = geometry.map(location) else { return }
            session.sendHover(ControlMessages.hover(
                videoWidth: geometry.videoWidth, videoHeight: geometry.videoHeight,
                x: point.x, y: point.y, buttons: Int(buttons.rawValue)
            ))
        }

        @objc private func scroll(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            guard recognizer.state == .changed else { return }
            routeScroll(at: recognizer.location(in: self), translation: delta, buttons: recognizer.buttonMask)
        }

        func routeScroll(at location: CGPoint, translation: CGPoint, buttons: UIEvent.ButtonMask) {
            guard hasControl, let geometry, let point = geometry.map(location) else { return }
            // Pan translation follows the pointer/content; browser wheel deltas have the opposite sign.
            let ticks = ScrollInput.ticks(horizontal: -translation.x, vertical: -translation.y, unit: .pixel)
            send([ControlMessages.scroll(
                videoWidth: geometry.videoWidth, videoHeight: geometry.videoHeight, x: point.x, y: point.y,
                hscrollTicks: ticks.0, vscrollTicks: ticks.1, buttons: Int(buttons.rawValue)
            )])
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(handlePresses(presses, down: true))
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        }

        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(handlePresses(presses, down: false))
            if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
        }

        public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(handlePresses(presses, down: false))
            if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
        }

        private func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
            guard hasControl else { return [] }
            var handled = Set<UIPress>()
            for press in presses {
                guard let key = press.key else { continue }
                let usage = key.keyCode.rawValue
                guard HIDCode.values[usage] != nil else { continue }
                let modifiers = Self.modifiers(key.modifierFlags)
                // Shortcut matching uses unmodified characters, printable input uses the actual layout text.
                let shortcut = !modifiers.intersection([.control, .command]).isEmpty
                routeKey(usage: usage, text: shortcut ? key.charactersIgnoringModifiers : key.characters,
                         down: down, flags: key.modifierFlags)
                handled.insert(press)
            }
            return handled
        }

        @discardableResult func routeKey(
            usage: Int, text: String, down: Bool, flags: UIKeyModifierFlags = []
        ) -> Bool {
            guard hasControl, HIDCode.values[usage] != nil else { return false }
            let modifiers = Self.modifiers(flags)
            if down { pressedKeys[usage] = (text, modifiers) }
            else { pressedKeys.removeValue(forKey: usage) }
            send(KeyInput.route(usage: usage, text: text, down: down, modifiers: modifiers,
                                clipboard: { UIPasteboard.general.string }))
            return true
        }

        private static func modifiers(_ flags: UIKeyModifierFlags) -> InputModifiers {
            var result: InputModifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.alternate) { result.insert(.alternate) }
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.alphaShift) { result.insert(.capsLock) }
            return result
        }
    }

    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var view: DeviceStreamUIView?
        private var link: CADisplayLink?
        init(view: DeviceStreamUIView) {
            self.view = view
            super.init()
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }
        func invalidate() {
            link?.invalidate()
            link = nil
        }
        @objc func tick() { view?.flushMoves() }
    }
#endif
