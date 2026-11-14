// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure encoders for control-channel packets (hover uses its own channel).
/// Narrow integers wrap as in JavaScript DataView; coordinates round half toward positive infinity.
public enum ControlMessages {
    /// Touch packet. The pointer ID is big-endian; all other multibyte fields are little-endian.
    /// A mouse uses pointer ID -1. Pressure defaults to 1 and is scaled by 65535.
    public static func touch(
        action: Int, pointerID: Int64, videoWidth: Int, videoHeight: Int,
        x: Double, y: Double, pressure: Double = 1, actionButton: Int = 0, buttons: Int = 0
    ) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectTouchEvent))
        out.integer(UInt8(truncatingIfNeeded: action))
        out.bigEndian(pointerID)
        out.position(x: x, y: y, width: videoWidth, height: videoHeight)
        out.littleEndian(UInt16(truncatingIfNeeded: jsInt32(jsRound(pressure * 65535))))
        out.littleEndian(Int32(truncatingIfNeeded: actionButton))
        out.littleEndian(Int32(truncatingIfNeeded: buttons))
        return out.data
    }

    /// Scroll packet. Ticks are wheel notches; positive values mean up or left.
    /// Ticks are divided by 16, clamped to [-1, 1], and stored as signed fixed-point.
    public static func scroll(
        videoWidth: Int, videoHeight: Int, x: Double, y: Double,
        hscrollTicks: Double, vscrollTicks: Double, buttons: Int = 0
    ) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectScrollEvent))
        out.position(x: x, y: y, width: videoWidth, height: videoHeight)
        out.littleEndian(scrollValue(hscrollTicks))
        out.littleEndian(scrollValue(vscrollTicks))
        out.littleEndian(Int32(truncatingIfNeeded: buttons))
        return out.data
    }

    /// Mouse hover packet, sent on the unordered hover channel.
    public static func hover(
        videoWidth: Int, videoHeight: Int, x: Double, y: Double, buttons: Int = 0
    ) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectMouseHoverEvent))
        out.position(x: x, y: y, width: videoWidth, height: videoHeight)
        out.littleEndian(Int32(truncatingIfNeeded: buttons))
        return out.data
    }

    /// Android key packet with an action, repeat count, and modifier mask.
    public static func keycode(action: Int, keycode: Int, repeat: Int = 0, metaState: Int = 0) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectKeycode))
        out.integer(UInt8(truncatingIfNeeded: action))
        out.littleEndian(Int32(truncatingIfNeeded: keycode))
        out.littleEndian(Int32(truncatingIfNeeded: `repeat`))
        out.littleEndian(Int32(truncatingIfNeeded: metaState))
        return out.data
    }

    /// UTF-8 text without normalization, prefixed by its little-endian byte count.
    /// Swift repairs unpaired UTF-16 surrogates to U+FFFD when constructing a String.
    public static func text(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectText))
        out.littleEndian(UInt32(truncatingIfNeeded: payload.count))
        out.data.append(payload)
        return out.data
    }

    /// UTF-8 clipboard packet with a zero acknowledgement sequence and big-endian byte count.
    /// Swift repairs unpaired UTF-16 surrogates to U+FFFD when constructing a String.
    public static func setClipboard(text: String, paste: Bool = true) -> Data {
        let payload = Data(text.utf8)
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.setClipboard))
        out.bigEndian(UInt64(0))
        out.integer(UInt8(paste ? 1 : 0))
        out.bigEndian(UInt32(truncatingIfNeeded: payload.count))
        out.data.append(payload)
        return out.data
    }

    private static func scrollValue(_ ticks: Double) -> Int16 {
        // Swift min/max do not propagate NaN like Math.min/Math.max; preserve it for DataView.
        let clamped = ticks.isNaN ? ticks : max(-1, min(1, ticks / 16))
        let scaled = jsRound(clamped * 32768)
        return Int16(truncatingIfNeeded: jsInt32(min(scaled, 32767)))
    }
}

private struct ByteWriter {
    var data = Data()

    mutating func littleEndian<T: FixedWidthInteger>(_ value: T) { integer(value.littleEndian) }
    mutating func bigEndian<T: FixedWidthInteger>(_ value: T) { integer(value.bigEndian) }

    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    mutating func position(x: Double, y: Double, width: Int, height: Int) {
        littleEndian(jsInt32(jsRound(x)))
        littleEndian(jsInt32(jsRound(y)))
        littleEndian(UInt16(truncatingIfNeeded: width))
        littleEndian(UInt16(truncatingIfNeeded: height))
    }
}

private func jsRound(_ value: Double) -> Double {
    guard value.isFinite else { return value }
    let lower = floor(value)
    return value - lower >= 0.5 ? lower + 1 : lower
}

// Only the low 32 bits reach the wire. Reduce before converting to avoid Swift integer traps.
private func jsInt32(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    return Int32(truncatingIfNeeded:
        Int64(value.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)))
}
