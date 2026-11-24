// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit
import MobilerunStreamCore

@MainActor final class PublishPillInteraction: ObservableObject {
    @Published private(set) var opacity = 1.0
    private let scheduler: any ReconnectScheduler
    private var timer: (any ScheduledTask)?
    init(scheduler: any ReconnectScheduler = MainActorScheduler()) { self.scheduler = scheduler }
    func interact() {
        opacity = 1
        timer?.cancel()
        timer = scheduler.schedule(delayMs: 3_000) { [weak self] in self?.opacity = 0.5 }
    }
    func stop() { timer?.cancel(); timer = nil }
}

/// Observes proximity from the window without claiming a hit area or recognizing a touch gesture.
struct PublishPillProximity: UIViewRepresentable {
    var onInteraction: @MainActor () -> Void
    func makeUIView(context: Context) -> ProximityView { ProximityView() }
    func updateUIView(_ view: ProximityView, context: Context) { view.onInteraction = onInteraction }
    static func dismantleUIView(_ view: ProximityView, coordinator: ()) { view.unbind() }

    @MainActor final class ProximityView: UIView, UIGestureRecognizerDelegate {
        var onInteraction: (@MainActor () -> Void)?
        private weak var observedWindow: UIWindow?
        private lazy var touches = TouchObserver(target: nil, action: nil)
        private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        init() { super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            unbind()
            guard let window else { return }
            observedWindow = window
            touches.onLocation = { [weak self] in self?.observe($0) }
            for gesture in [touches, hover] {
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                gesture.delegate = self
                window.addGestureRecognizer(gesture)
            }
        }
        func unbind() {
            observedWindow?.removeGestureRecognizer(touches)
            observedWindow?.removeGestureRecognizer(hover)
            observedWindow = nil
        }
        func observe(_ point: CGPoint) {
            guard let window = observedWindow, !isHidden,
                  bounds.insetBy(dx: -24, dy: -24).contains(convert(point, from: window)) else { return }
            onInteraction?()
        }
        @objc private func hovered(_ gesture: UIHoverGestureRecognizer) { observe(gesture.location(in: observedWindow)) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }

    @MainActor private final class TouchObserver: UIGestureRecognizer {
        var onLocation: ((CGPoint) -> Void)?
        private func observe(_ touches: Set<UITouch>) {
            for touch in touches { onLocation?(touch.location(in: view)) }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { observe(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { observe(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { observe(touches); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }
}
#endif
