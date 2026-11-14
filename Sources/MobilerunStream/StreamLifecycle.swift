// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Combine
import Network
import UIKit
import MobilerunStreamCore

/// Optional adapter for custom UI. One adapter per session; start/stop with the visible host.
@MainActor public final class StreamLifecycleAdapter: ObservableObject {
    private weak var session: DeviceStreamSession?
    private var transitions: StreamWakeTransitions
    private var observers: Set<AnyCancellable> = []
    private var monitor: NWPathMonitor?
    private var epoch = 0
    public init(session: DeviceStreamSession) {
        self.session = session
        transitions = StreamWakeTransitions(foreground: UIApplication.shared.applicationState != .background)
    }
    public func start() {
        guard monitor == nil else { return }
        let foreground = UIApplication.shared.applicationState != .background
        transitions = StreamWakeTransitions(foreground: foreground)
        session?.setHidden(!foreground)
        epoch += 1
        let current = epoch
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.foreground(false, epoch: current) } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.foreground(true, epoch: current) } }
            .store(in: &observers)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.epoch == current, self.monitor != nil else { return }
                if self.transitions.setOnline(online) { self.session?.handleWake() }
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "stream.network"))
    }
    public func stop() {
        epoch += 1; observers.removeAll(); monitor?.cancel(); monitor = nil
    }
    deinit { monitor?.cancel() }
    private func foreground(_ value: Bool, epoch: Int) {
        guard self.epoch == epoch, monitor != nil else { return }
        session?.setHidden(!value)
        if transitions.setForeground(value) { session?.handleWake() }
    }
}
#endif
