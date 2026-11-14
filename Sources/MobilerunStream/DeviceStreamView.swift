// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import SwiftUI

    /// Explicit Android navigation. Host Back actions are never forwarded automatically.
    public enum SystemKey: Sendable { case back, home, recent }

    /// Optional imperative handle for one mounted SwiftUI stream view.
    @MainActor public final class DeviceStreamHandle {
        weak var view: DeviceStreamUIView?
        public init() {}
        /// Focuses the text client and asks UIKit to show its keyboard.
        public func showKeyboard() { view?.showKeyboard() }
        public func hideKeyboard() { view?.hideKeyboard() }
        public func sendSystemKey(_ key: SystemKey) { view?.sendSystemKey(key) }
    }

    /// Transparent, aspect-fit video with local input. The session remains owned by the app.
    /// `hasControl` enables local forwarding; the server still decides whether input is allowed.
    @MainActor public struct DeviceStreamView: UIViewRepresentable {
        @ObservedObject private var session: DeviceStreamSession
        private let hasControl: Bool
        private let handle: DeviceStreamHandle?

        public init(
            session: DeviceStreamSession, hasControl: Bool,
            handle: DeviceStreamHandle? = nil
        ) {
            self.session = session
            self.hasControl = hasControl
            self.handle = handle
        }

        public func makeUIView(context: Context) -> DeviceStreamUIView {
            let view = DeviceStreamUIView(session: session, hasControl: hasControl)
            view.bind(handle)
            return view
        }

        public func updateUIView(_ view: DeviceStreamUIView, context: Context) {
            view.update(session: session, hasControl: hasControl)
            view.bind(handle)
        }

        public static func dismantleUIView(_ view: DeviceStreamUIView, coordinator: ()) {
            view.detach()
        }
    }
#endif
