// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure encoders for control-channel packets (hover uses its own channel).
/// Narrow integers wrap as in JavaScript DataView; coordinates round half toward positive infinity.
public enum ControlMessages {
    /// Touch packet. The pointer ID is big-endian; all other multibyte fields are little-endian.
    /// A mouse uses pointer ID -1. Pressure defaults to 1 and is scaled by 65535.
    public static func touch(
        action: Int, pointerId: Int64, videoWidth: Int, videoHeight: Int,
        x: Double, y: Double, pressure: Double = 1, actionButton: Int = 0, buttons: Int = 0
    ) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectTouchEvent))
        out.integer(UInt8(truncatingIfNeeded: action))
        out.integer(pointerId.bigEndian)
        out.position(x: x, y: y, width: videoWidth, height: videoHeight)
        out.integer(UInt16(truncatingIfNeeded: jsInteger(jsRound(pressure * 65535))).littleEndian)
        out.integer(Int32(truncatingIfNeeded: actionButton).littleEndian)
        out.integer(Int32(truncatingIfNeeded: buttons).littleEndian)
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
        out.integer(scrollValue(hscrollTicks).littleEndian)
        out.integer(scrollValue(vscrollTicks).littleEndian)
        out.integer(Int32(truncatingIfNeeded: buttons).littleEndian)
        return out.data
    }

    /// Mouse hover packet, sent on the unordered hover channel.
    public static func hover(
        videoWidth: Int, videoHeight: Int, x: Double, y: Double, buttons: Int = 0
    ) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectMouseHoverEvent))
        out.position(x: x, y: y, width: videoWidth, height: videoHeight)
        out.integer(Int32(truncatingIfNeeded: buttons).littleEndian)
        return out.data
    }

    /// Android key packet with an action, repeat count, and modifier mask.
    public static func keycode(action: Int, keycode: Int, repeat: Int = 0, metaState: Int = 0) -> Data {
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectKeycode))
        out.integer(UInt8(truncatingIfNeeded: action))
        out.integer(Int32(truncatingIfNeeded: keycode).littleEndian)
        out.integer(Int32(truncatingIfNeeded: `repeat`).littleEndian)
        out.integer(Int32(truncatingIfNeeded: metaState).littleEndian)
        return out.data
    }

    /// UTF-8 text without normalization, prefixed by its little-endian byte count.
    /// Swift repairs unpaired UTF-16 surrogates to U+FFFD when constructing a String.
    public static func text(text: String) -> Data {
        let payload = Data(text.utf8)
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.injectText))
        out.integer(UInt32(truncatingIfNeeded: payload.count).littleEndian)
        out.data.append(payload)
        return out.data
    }

    /// UTF-8 clipboard packet with a zero acknowledgement sequence and big-endian byte count.
    /// Swift repairs unpaired UTF-16 surrogates to U+FFFD when constructing a String.
    public static func setClipboard(text: String, paste: Bool = true) -> Data {
        let payload = Data(text.utf8)
        var out = ByteWriter()
        out.integer(UInt8(ControlMessageType.setClipboard))
        out.integer(UInt64(0))
        out.integer(UInt8(paste ? 1 : 0))
        out.integer(UInt32(truncatingIfNeeded: payload.count).bigEndian)
        out.data.append(payload)
        return out.data
    }

    private static func scrollValue(_ ticks: Double) -> Int16 {
        let clamped = ticks.isNaN ? ticks : max(-1, min(1, ticks / 16))
        let scaled = jsRound(clamped * 32768)
        return Int16(truncatingIfNeeded: jsInteger(scaled >= 32767 ? 32767 : scaled))
    }
}

private struct ByteWriter {
    var data = Data()

    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    mutating func position(x: Double, y: Double, width: Int, height: Int) {
        integer(Int32(truncatingIfNeeded: jsInteger(jsRound(x))).littleEndian)
        integer(Int32(truncatingIfNeeded: jsInteger(jsRound(y))).littleEndian)
        integer(UInt16(truncatingIfNeeded: width).littleEndian)
        integer(UInt16(truncatingIfNeeded: height).littleEndian)
    }
}

private func jsRound(_ value: Double) -> Double {
    guard value.isFinite else { return value }
    let lower = floor(value)
    return value - lower >= 0.5 ? lower + 1 : lower
}

// Only the low 32 bits reach the wire. Reduce before converting to avoid Swift integer traps.
private func jsInteger(_ value: Double) -> Int64 {
    guard value.isFinite else { return 0 }
    return Int64(value.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296))
}
