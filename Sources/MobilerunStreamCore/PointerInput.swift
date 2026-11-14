// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// Serial input state. UIKit supplies touch identities; every finger gets its own DOWN/UP.
package struct PointerInput<Identity: Hashable> {
    private struct Pointer {
        let slot: Int64
        let geometry: InputGeometry
        var point: InputPoint
        var pendingMove = false
    }
    private var active: [Identity: Pointer] = [:]

    package init() {}

    package var mouseIsDown: Bool { active.values.contains { $0.slot == -1 } }

    package mutating func down(
        _ id: Identity, at point: CGPoint, geometry: InputGeometry, mouse: Bool = false
    ) -> Data? {
        guard active[id] == nil, let position = geometry.map(point) else { return nil }
        let used = Set(active.values.map(\.slot))
        let slot = mouse ? (used.contains(-1) ? nil : Int64(-1)) : (Int64(0)...9).first { !used.contains($0) }
        guard let slot else { return nil }
        let pointer = Pointer(slot: slot, geometry: geometry, point: position)
        active[id] = pointer
        return packet(MotionEvent.actionDown, pointer)
    }

    package mutating func move(_ id: Identity, to point: CGPoint) {
        guard var pointer = active[id], let position = pointer.geometry.map(point) else { return }
        pointer.point = position
        pointer.pendingMove = true
        active[id] = pointer
    }

    /// Call once per display frame. Newer samples replace older unsent MOVE samples.
    package mutating func flushMoves() -> [Data] {
        let ordered = active.sorted { $0.value.slot < $1.value.slot }
        return ordered.compactMap { id, pointer in
            guard pointer.pendingMove else { return nil }
            active[id]?.pendingMove = false
            return packet(MotionEvent.actionMove, pointer)
        }
    }

    package mutating func up(_ id: Identity, cancelled: Bool = false) -> Data? {
        guard let pointer = active.removeValue(forKey: id) else { return nil }
        return packet(cancelled ? MotionEvent.actionCancel : MotionEvent.actionUp, pointer)
    }

    package mutating func cancel() -> [Data] {
        let packets = active.values.sorted { $0.slot < $1.slot }.map { packet(MotionEvent.actionCancel, $0) }
        active.removeAll()
        return packets
    }

    package mutating func reset() { active.removeAll() }

    private func packet(_ action: Int, _ pointer: Pointer) -> Data {
        ControlMessages.touch(
            action: action, pointerID: pointer.slot,
            videoWidth: pointer.geometry.videoWidth, videoHeight: pointer.geometry.videoHeight,
            x: pointer.point.x, y: pointer.point.y, pressure: 1,
            actionButton: MotionEvent.buttonPrimary, buttons: MotionEvent.buttonPrimary
        )
    }
}
