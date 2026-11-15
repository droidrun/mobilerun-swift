// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Combine
import Foundation
import MobilerunStreamCore

/// SDK-owned observable statistics. Subscribe through `session.$stats`; cancelling the last
/// subscription stops native sampling. The enclosing session owns writes and change notifications.
@propertyWrapper @MainActor public struct StreamStatsPublished {
    private let storage = Storage()
    init(observingSubscriptions: Void) {}

    /// The latest sample, or nil when sampling is inactive.
    public var wrappedValue: StreamStats? {
        get { storage.isObserved ? storage.subject.value : nil }
        set { storage.subject.send(newValue) }
    }

    /// A publisher that counts active subscribers, including the lifetime of SwiftUI `onReceive`.
    public var projectedValue: AnyPublisher<StreamStats?, Never> {
        let storage = storage
        return storage.subject.handleEvents(
            receiveSubscription: { _ in storage.adjustObservers(1) },
            receiveCancel: { storage.adjustObservers(-1) }
        ).eraseToAnyPublisher()
    }

    var isObserved: Bool { storage.isObserved }
    var onObserversChanged: (@MainActor () -> Void)? {
        get { storage.onObserversChanged }
        nonmutating set { storage.onObserversChanged = newValue }
    }

    private final class Storage: @unchecked Sendable {
        let subject = CurrentValueSubject<StreamStats?, Never>(nil)
        private let lock = NSLock()
        private var observers = 0
        @MainActor var onObserversChanged: (@MainActor () -> Void)?
        var isObserved: Bool { lock.withLock { observers > 0 } }
        func adjustObservers(_ delta: Int) {
            lock.withLock { observers += delta }
            Task { @MainActor [weak self] in self?.onObserversChanged?() }
        }
    }
}
#endif
