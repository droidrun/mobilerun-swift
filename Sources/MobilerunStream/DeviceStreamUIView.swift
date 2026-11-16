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
        let textClient = StreamTextInput(frame: .zero, textContainer: nil)
        private var session: DeviceStreamSession
        private var track: LKRTCVideoTrack?
        private var subscriptions = Set<AnyCancellable>()
        private var pointers = PointerInput<ObjectIdentifier>()
        private var keyState = KeyInputState()
        private var geometry: InputGeometry?
        private var displayLink: DisplayLinkTarget?
        private weak var handle: DeviceStreamHandle?
        private var pressedKeys: [Int: (code: String, key: String, modifiers: InputModifiers,
                                         timer: (any ScheduledTask)?)] = [:]
        private let scheduler: any ReconnectScheduler

        #if DEBUG
            var onInput: ((Data, Bool) -> Void)?
            private(set) var inputEventSource = "driver"
        #endif

        private var controlEnabled: Bool
        /// Disabling local control clears composition, focus and active input.
        public var hasControl: Bool {
            get { controlEnabled && !session.isClosed }
            set {
                if hasControl && !newValue { stopLocalInput() }
                controlEnabled = newValue
            }
        }

        /// Rendered upright video rect in local view points, or nil before a frame arrives.
        var renderedVideoRect: CGRect? { geometry?.rect }

        public convenience init(session: DeviceStreamSession, hasControl: Bool) {
            self.init(session: session, hasControl: hasControl, scheduler: MainActorScheduler())
        }

        init(session: DeviceStreamSession, hasControl: Bool, scheduler: any ReconnectScheduler) {
            self.scheduler = scheduler
            self.session = session
            self.controlEnabled = hasControl
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
            if window == nil { stopLocalInput() }
        }

        func update(session: DeviceStreamSession, hasControl: Bool) {
            if self.session !== session {
                stopLocalInput()
                subscriptions.removeAll()
                setTrack(nil)
                self.session = session
                observeSession()
            }
            self.hasControl = hasControl
        }

        func bind(_ handle: DeviceStreamHandle?) {
            if self.handle !== handle {
                if self.handle?.view === self { self.handle?.view = nil }
                self.handle = handle
            }
            handle?.view = self
        }

        func detach() {
            stopLocalInput()
            subscriptions.removeAll()
            setTrack(nil)
            geometry = nil
            displayLink?.invalidate()
            displayLink = nil
            if handle?.view === self { handle?.view = nil }
        }

        private func observeSession() {
            session.$videoTrack.sink { [weak self] in self?.setTrack($0) }.store(in: &subscriptions)
            session.$videoSize.sink { [weak self] size in
                self?.updateGeometry(video: size)
            }.store(in: &subscriptions)
            session.$isClosed.sink { [weak self] closed in
                if closed { self?.stopLocalInput() }
            }.store(in: &subscriptions)
            session.$status.sink { [weak self] status in
                if status != .connected {
                    self?.stopLocalInput()
                }
            }.store(in: &subscriptions)
        }

        private func setTrack(_ newTrack: LKRTCVideoTrack?) {
            guard track !== newTrack else { return }
            resetInput()
            track?.remove(renderer)
            track = newTrack
            renderer.isHidden = newTrack == nil
            newTrack?.add(renderer)
        }

        private func updateGeometry() { updateGeometry(video: session.videoSize) }

        private func updateGeometry(video: VideoSize?) {
            let updated = InputGeometry(bounds: bounds, video: video)
            if geometry != updated {
                resetInput()
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

        private func resetInput() {
            send(pointers.cancel())
            displayLink?.invalidate()
            displayLink = nil
        }

        private func stopLocalInput() {
            resetInput()
            for (_, key) in pressedKeys.sorted(by: { $0.key < $1.key }) {
                key.timer?.cancel()
                send(keyPackets(code: key.code, key: key.key, down: false, modifiers: key.modifiers))
            }
            pressedKeys.removeAll()
            textClient.discardComposition()
            hideKeyboard()
        }

        public override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            // UIKit consults the hit-tested view before an ancestor recognizer cancels its touches.
            if pointers.isActive, let owner = recognizer.view, owner !== self,
               isDescendant(of: owner),
               recognizer is UIPanGestureRecognizer || recognizer is UISwipeGestureRecognizer {
                return false
            }
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        func flushMoves() { send(pointers.flushMoves()) }

        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            #if DEBUG
                inputEventSource = "touch"
                defer { inputEventSource = "driver" }
            #endif
            guard hasControl else { return }
            for touch in touches {
                beginPointer(ObjectIdentifier(touch), at: touch.location(in: self),
                             mouse: touch.type == .indirectPointer,
                             button: touch.type == .indirectPointer ? Self.clickButton(event) : 0)
            }
        }

        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard hasControl else { return }
            for touch in touches { movePointer(ObjectIdentifier(touch), to: touch.location(in: self)) }
        }

        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, event: event, cancelled: false)
        }

        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, event: event, cancelled: true)
        }

        private static func clickButton(_ event: UIEvent?) -> Int {
            let mask = event?.buttonMask ?? []
            if mask.isEmpty || mask.contains(.primary) { return 0 }
            return mask.contains(.secondary) ? 2 : 1
        }

        private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
            for touch in touches {
                endPointer(ObjectIdentifier(touch), cancelled: cancelled,
                           button: touch.type == .indirectPointer ? Self.clickButton(event) : 0)
            }
        }

        // Shared by native events and the Debug example's deterministic simulator input driver.
        func beginPointer(_ id: ObjectIdentifier, at point: CGPoint, mouse: Bool = false, button: Int = 0) {
            guard hasControl, let geometry,
                  let packet = pointers.down(id, at: point, geometry: geometry, mouse: mouse, button: button) else { return }
            if !textClient.isFirstResponder { becomeFirstResponder() }
            if displayLink == nil { displayLink = DisplayLinkTarget(view: self) }
            send([packet])
        }

        func movePointer(_ id: ObjectIdentifier, to point: CGPoint) {
            guard hasControl else { return }
            pointers.move(id, to: point)
        }

        func endPointer(_ id: ObjectIdentifier, cancelled: Bool = false, button: Int = 0) {
            if let packet = pointers.up(id, cancelled: cancelled, button: button) { send([packet]) }
            if !pointers.isActive {
                displayLink?.invalidate()
                displayLink = nil
            }
        }

        @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            routeHover(at: recognizer.location(in: self), buttons: recognizer.buttonMask)
        }

        func routeHover(at location: CGPoint, buttons: UIEvent.ButtonMask) {
            guard hasControl, let geometry,
                  let packet = PointerInput<ObjectIdentifier>.hover(at: location, geometry: geometry, buttons: Int(buttons.rawValue)) else { return }
            session.sendHover(packet)
        }

        @objc private func scroll(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            guard [.began, .changed, .ended].contains(recognizer.state) else { return }
            routeScroll(at: recognizer.location(in: self), translation: delta, buttons: recognizer.buttonMask)
        }

        func routeScroll(at location: CGPoint, translation: CGPoint, buttons: UIEvent.ButtonMask) {
            guard hasControl, let geometry,
                  let packet = ScrollInput.route(at: location, geometry: geometry,
                    h: translation.x * ScrollInput.ticksPerPoint,
                    v: translation.y * ScrollInput.ticksPerPoint, buttons: Int(buttons.rawValue)) else { return }
            send([packet])
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if hasControl, textClient.usesTextSystem, !textClient.isFirstResponder,
               textClient.becomeFirstResponder() {
                textClient.pressesBegan(presses, with: event)
                return
            }
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
            #if DEBUG
                inputEventSource = "press"
                defer { inputEventSource = "driver" }
            #endif
            guard hasControl else { return [] }
            return Set(presses.filter { press in
                guard let key = press.key else { return false }
                return routeKey(usage: key.keyCode.rawValue, text: key.characters,
                                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                down: down, flags: key.modifierFlags)
            })
        }

        @discardableResult func routeKey(
            usage: Int, text: String, charactersIgnoringModifiers: String? = nil,
            down: Bool, flags: UIKeyModifierFlags = []
        ) -> Bool {
            guard hasControl, !textClient.usesTextSystem || (!down && pressedKeys[usage] != nil) else {
                return false
            }
            if down, pressedKeys[usage] != nil { return true }
            let modifiers = Self.modifiers(flags)
            let code = HIDCode.values[usage] ?? "Unknown\(usage)"
            let unmodified = charactersIgnoringModifiers ?? text
            let key = modifiers.isShortcut ? unmodified : text
            let packets = keyPackets(code: code, key: key, down: down, modifiers: modifiers)
            let isShortcut = modifiers.isShortcut && ["v", "m"].contains(unmodified.lowercased())
            guard HIDCode.values[usage] != nil || !packets.isEmpty || pressedKeys[usage] != nil
                    || (down && isShortcut) else { return false }
            if down {
                // UIKit does not promise repeated pressesBegan. Own the cadence.
                pressedKeys[usage] = (code, key, modifiers, nil)
                if !(224...231).contains(usage) { scheduleRepeat(usage, delayMs: 500) }
            } else {
                pressedKeys.removeValue(forKey: usage)?.timer?.cancel()
            }
            send(packets)
            return true
        }

        private func scheduleRepeat(_ usage: Int, delayMs: Int) {
            pressedKeys[usage]?.timer = scheduler.schedule(delayMs: delayMs) { [weak self] in
                guard let self, let key = self.pressedKeys[usage], self.hasControl else { return }
                if self.textClient.usesTextSystem {
                    self.pressedKeys[usage]?.timer = nil
                    return
                }
                self.send(self.keyPackets(code: key.code, key: key.key, down: true, modifiers: key.modifiers))
                self.scheduleRepeat(usage, delayMs: 33)
            }
        }

        private func keyPackets(code: String, key: String, down: Bool, modifiers: InputModifiers) -> [Data] {
            keyState.route(code: code, text: key, down: down, modifiers: modifiers,
                           clipboard: { UIPasteboard.general.string })
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
