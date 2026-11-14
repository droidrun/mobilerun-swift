// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import MobilerunStreamCore
import Testing

@Test("H.264 fallback retains retransmission and redundancy codecs", arguments: [true, false])
func h264AuxiliaryCodecs(explicit: Bool) {
    let codecs = ["video/VP8", "video/AVC", "rtx", "RED", "ulpfec", "flexfec-03", "flexfec-99"]
    #expect(
        CodecPreferences.ordered(codecs, h264Only: explicit, name: { $0 })
            == Array(codecs.dropFirst()))
}

@Test("Automatic codec priority uses the same alias families as filtering")
func automaticCodecFamilies() {
    let codecs = ["video/AVC", "rtx", "HEVC", "VP9", "H265", "video/AV1"]
    #expect(
        CodecPreferences.ordered(codecs, h264Only: false, name: { $0 })
            == ["VP9", "HEVC", "H265", "video/AVC", "rtx", "video/AV1"])
    #expect(CodecPreferences.ordered(codecs, h264Only: true, name: { $0 }) == ["video/AVC", "rtx"])
    #expect(CodecPreferences.ordered(["rtx", "flexfec-03"], h264Only: true, name: { $0 }) == nil)
}

@Test("Scheduler safely converts huge and negative delays") @MainActor
func schedulerOverflowProtection() {
    #expect(MainActorScheduler.nanoseconds(delayMs: Int.max) == UInt64.max - UInt64.max % 1_000_000)
    #expect(MainActorScheduler.nanoseconds(delayMs: -1) == 0)
    let task = MainActorScheduler().schedule(delayMs: Int.max) { Issue.record("unexpected timer") }
    task.cancel()
}
