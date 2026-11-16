// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Combine
import Foundation
import MobilerunStreamCore

/// Subscriber lifetime is internal; statistics never invalidate the session's whole view tree.
@MainActor final class StreamStatsObservation {
    private let storage = Storage()

    var value: StreamStats? { isObserved ? storage.subject.value : nil }
    var isObserved: Bool { storage.isObserved }
    var onObserversChanged: (@MainActor () -> Void)? {
        get { storage.onObserversChanged }
        set { storage.onObserversChanged = newValue }
    }

    var publisher: AnyPublisher<StreamStats?, Never> {
        let storage = storage
        return storage.subject.handleEvents(
            receiveSubscription: { _ in storage.adjustObservers(1) },
            receiveCompletion: { _ in storage.adjustObservers(-1) },
            receiveCancel: { storage.adjustObservers(-1) }
        ).eraseToAnyPublisher()
    }

    func send(_ value: StreamStats?) { storage.subject.send(value) }
    func finish() {
        guard storage.markFinished() else { return }
        storage.subject.send(completion: .finished)
    }

    private final class Storage: @unchecked Sendable {
        let subject = CurrentValueSubject<StreamStats?, Never>(nil)
        private let lock = NSLock()
        private var observers = 0
        private var finished = false
        @MainActor var onObserversChanged: (@MainActor () -> Void)?
        var isObserved: Bool { lock.withLock { observers > 0 && !finished } }
        func markFinished() -> Bool {
            lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
        }
        func adjustObservers(_ delta: Int) {
            lock.withLock { observers += delta }
            Task { @MainActor [weak self] in self?.onObserversChanged?() }
        }
    }
}
#endif
