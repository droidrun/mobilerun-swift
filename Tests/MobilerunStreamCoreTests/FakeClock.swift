// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import MobilerunStreamCore

final class FakeClock: ReconnectScheduler {
    final class Task: ScheduledTask {
        let due: Int
        let order: Int
        let action: () -> Void
        var cancelled = false
        init(due: Int, order: Int, action: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var now = 0
    private var nextOrder = 0
    private var tasks: [Task] = []
    var pendingCount: Int { tasks.filter { !$0.cancelled }.count }

    func schedule(delayMs: Int, action: @escaping () -> Void) -> any ScheduledTask {
        let task = Task(due: now + delayMs, order: nextOrder, action: action)
        nextOrder += 1
        tasks.append(task)
        return task
    }

    func advance(to time: Int) {
        precondition(time >= now, "Fixture replay must not move backwards")
        while let next = tasks.filter({ !$0.cancelled && $0.due <= time })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = next.due
            next.action()
        }
        now = time
        tasks.removeAll { $0.cancelled }
    }
}
