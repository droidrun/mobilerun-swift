// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import UIKit
    import Combine
    import Testing
    import MobilerunProtocol
    import MobilerunStreamCore
    @testable import MobilerunStream

    @MainActor struct NativeInputTests {
        @Test func compositionCommitsOnceAndDeleteWorksWithAnEmptyBuffer() {
            let input = StreamTextInput(frame: .zero, textContainer: nil)
            var commits: [String] = []
            var deletes = 0
            input.onCommit = { commits.append($0) }
            input.onDelete = { deletes += 1 }
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            input.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
            #expect(commits.isEmpty)
            input.unmarkText()
            #expect(commits == ["你"])
            input.insertText("好🙂")
            #expect(commits == ["你", "好🙂"])
            input.deleteBackward()
            #expect(deletes == 1)
            input.setMarkedText("discard", selectedRange: NSRange(location: 7, length: 0))
            input.discardComposition()
            #expect(commits == ["你", "好🙂"])
            #expect(input.text.isEmpty)
            input.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0))
            // UIKit can finalize composition via a text-change notification without insertText/unmarkText.
            input.text = "好"
            input.textViewDidChange(input)
            #expect(commits == ["你", "好🙂", "好"])
            #expect(input.text.isEmpty)
            input.textViewDidChange(input)
            #expect(commits == ["你", "好🙂", "好"])
        }

        @Test func displayOnlyRejectsFocusAndHasNoVideoRect() {
            let session = DeviceStreamSession(credentials: { nil })
            let view = DeviceStreamUIView(session: session, hasControl: false)
            view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
            view.layoutIfNeeded()
            #expect(!view.canBecomeFirstResponder)
            #expect(view.renderedVideoRect == nil)
            view.showKeyboard()
            #expect(!view.isFirstResponder)
            view.detach()
            session.close()
        }

        @Test func explicitKeyboardFocusAndControlLossResignTheTextClient() throws {
            let session = DeviceStreamSession(credentials: { nil })
            let view = DeviceStreamUIView(session: session, hasControl: true)
            let host = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
            window.rootViewController = host
            host.view.addSubview(view)
            view.frame = host.view.bounds
            window.makeKeyAndVisible()
            defer {
                view.detach()
                window.isHidden = true
                session.close()
            }
            let input = view.textClient
            view.showKeyboard()
            #expect(input.isFirstResponder)
            view.hasControl = false
            #expect(!input.isFirstResponder)
            view.showKeyboard()
            #expect(!input.isFirstResponder)
            let hostInput = UITextField(frame: CGRect(x: 10, y: 10, width: 100, height: 30))
            host.view.addSubview(hostInput)
            hostInput.becomeFirstResponder()
            #expect(hostInput.isFirstResponder)
            view.hideKeyboard()
            #expect(hostInput.isFirstResponder)
            view.detach()
            #expect(hostInput.isFirstResponder)
        }

        private func recordingView() async throws
            -> (SessionHarness, DeviceStreamSession, DeviceStreamUIView) {
            let harness = try SessionHarness()
            let session = DeviceStreamSession(
                engine: harness.engine, videoSize: VideoSize(width: 100, height: 200))
            try await harness.connected()
            harness.peers[0].onEvent?(.channel(id: 1, open: true))
            harness.peers[0].onEvent?(.channel(id: 2, open: true))
            let view = DeviceStreamUIView(session: session, hasControl: true, scheduler: harness.clock)
            view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            view.layoutIfNeeded()
            return (harness, session, view)
        }

        private func packets(_ harness: SessionHarness) -> [String] {
            harness.peers[0].packets.map { "\($0.channel):\(hex($0.data))" }
        }

        @Test func sessionTransportRecordsTwoFingersCancelMouseHoverAndScroll() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            let first = NSObject()
            let second = NSObject()
            let mouse = NSObject()
            let a = ObjectIdentifier(first)
            let b = ObjectIdentifier(second)
            let m = ObjectIdentifier(mouse)
            view.beginPointer(a, at: CGPoint(x: 60, y: 20))
            view.beginPointer(b, at: CGPoint(x: 80, y: 40))
            view.movePointer(a, to: CGPoint(x: 65, y: 25))
            view.movePointer(a, to: CGPoint(x: 70, y: 30))
            view.flushMoves()
            view.endPointer(a, cancelled: true)
            view.endPointer(b)
            view.beginPointer(m, at: CGPoint(x: 100, y: 100), mouse: true)
            view.routeHover(at: CGPoint(x: 100, y: 100), buttons: [.primary, .secondary])
            view.endPointer(m, cancelled: true)
            view.routeScroll(at: CGPoint(x: 100, y: 100), translation: CGPoint(x: -100, y: 200),
                             buttons: .secondary)
            #expect(packets(h) == [
                "1:020000000000000000000a000000140000006400c800ffff0100000001000000",
                "1:020000000000000000011e000000280000006400c800ffff0100000001000000",
                "1:02020000000000000000140000001e0000006400c800ffff0100000001000000",
                "1:02030000000000000000140000001e0000006400c800ffff0100000001000000",
                "1:020100000000000000011e000000280000006400c800ffff0100000001000000",
                "1:0200ffffffffffffffff32000000640000006400c800ffff0100000001000000",
                "2:1532000000640000006400c80003000000",
                "1:0203ffffffffffffffff32000000640000006400c800ffff0100000001000000",
                "1:0332000000640000006400c80000f8001002000000",
            ])
            h.peers[0].packets.removeAll()
            h.peers[0].onEvent?(.channel(id: 2, open: false))
            view.routeHover(at: CGPoint(x: 100, y: 100), buttons: .primary)
            #expect(h.peers[0].packets.isEmpty) // No fallback to the still-open control channel.
        }

        @Test func sessionTransportRecordsKeysIMEAndSystemNavigation() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            let input = view.textClient
            view.routeKey(usage: 88, text: "\r", down: true)
            view.routeKey(usage: 88, text: "\r", down: false)
            let flags: UIKeyModifierFlags = [.shift, .alternate, .control, .command, .numericPad]
            view.routeKey(usage: 4, text: "a", down: true, flags: flags)
            view.routeKey(usage: 4, text: "a", down: false, flags: flags)
            let capsFlags: [UIKeyModifierFlags] = [[.control, .alphaShift], [.control, .alphaShift, .shift]]
            for modifiers in capsFlags {
                view.routeKey(usage: 4, text: "a", down: true, flags: modifiers)
                view.routeKey(usage: 4, text: "a", down: false, flags: modifiers)
            }
            for usage in [127, 128, 129, 163, 999] {
                #expect(!view.routeKey(usage: usage, text: "", down: true))
            }
            input.insertText("a")
            let beforeComposition = packets(h)
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            #expect(packets(h) == beforeComposition)
            input.text = "你"
            input.textViewDidChange(input)
            input.deleteBackward()
            input.insertText("\n")
            for key: SystemKey in [.back, .home, .recent] { view.sendSystemKey(key) }
            #expect(packets(h) == [
                "1:0000a00000000000000000000000", "1:0001a00000000000000000000000",
                "1:00001d0000000000000003100100", "1:00011d0000000000000003100100",
                "1:00001d0000000000000001100000", "1:00011d0000000000000001100000",
                "1:00001d0000000000000000100000", "1:00011d0000000000000000100000",
                "1:010100000061", "1:0103000000e4bda0",
                "1:0000430000000000000000000000", "1:0001430000000000000000000000",
                "1:0000420000000000000000000000", "1:0001420000000000000000000000",
                "1:0000040000000000000000000000", "1:0001040000000000000000000000",
                "1:0000030000000000000000000000", "1:0001030000000000000000000000",
                "1:0000bb0000000000000000000000", "1:0001bb0000000000000000000000",
            ])
        }

        @Test func ownedTouchesBlockAncestorScrollAndEdgeSwipeOnlyWhileActive() async throws {
            let (_, session, view) = try await recordingView()
            let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            scroll.addSubview(view)
            let edge = UIScreenEdgePanGestureRecognizer()
            edge.edges = .left
            scroll.addGestureRecognizer(edge)
            let finger = NSObject()
            let id = ObjectIdentifier(finger)
            defer { view.detach(); session.close() }
            view.beginPointer(id, at: .zero) // Letterbox does not own the gesture.
            #expect(view.gestureRecognizerShouldBegin(edge))
            view.beginPointer(id, at: CGPoint(x: 60, y: 20))
            #expect(!view.gestureRecognizerShouldBegin(scroll.panGestureRecognizer))
            #expect(!view.gestureRecognizerShouldBegin(edge))
            view.endPointer(id)
            #expect(view.gestureRecognizerShouldBegin(edge))
            view.hasControl = false
            view.beginPointer(id, at: CGPoint(x: 60, y: 20))
            #expect(view.gestureRecognizerShouldBegin(edge))
        }

        @Test func onlyAcceptedPointerDownTakesFocus() async throws {
            let (_, session, view) = try await recordingView()
            let host = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.rootViewController = host
            host.view.addSubview(view)
            window.makeKeyAndVisible()
            let finger = NSObject()
            let id = ObjectIdentifier(finger)
            defer { view.detach(); session.close(); window.isHidden = true }
            view.beginPointer(id, at: .zero)
            #expect(!view.isFirstResponder)
            view.beginPointer(id, at: CGPoint(x: 60, y: 20))
            #expect(view.isFirstResponder)
            view.endPointer(id)
            view.hasControl = false
            view.beginPointer(id, at: CGPoint(x: 60, y: 20))
            #expect(!view.isFirstResponder)
        }

        @Test func keyRepeatUsesBrowserCadenceAndGeometryDoesNotReleaseKeys() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            let down = ControlMessages.keycode(action: 0, keycode: 22)
            let up = ControlMessages.keycode(action: 1, keycode: 22)
            func sent() -> [Data] { h.peers[0].packets.map(\.data) }
            view.routeKey(usage: 79, text: "", down: true)
            view.routeKey(usage: 79, text: "", down: true) // Duplicate UIKit down is not a second cadence.
            let start = h.clock.now
            h.clock.advance(to: start + 499)
            #expect(sent() == [down])
            h.clock.advance(to: start + 500)
            #expect(sent() == [down, down])
            view.frame.size.width = 300
            view.layoutIfNeeded()
            #expect(sent() == [down, down])
            h.clock.advance(to: start + 533)
            #expect(sent() == [down, down, down])
            view.routeKey(usage: 79, text: "", down: false)
            h.clock.advance(to: start + 1000)
            #expect(sent() == [down, down, down, up])
            view.routeKey(usage: 79, text: "", down: true)
            view.hasControl = false
            h.clock.advance(to: start + 2000)
            #expect(sent() == [down, down, down, up, down, up])
        }

        @Test func hardwareCompositionAndInputTraits() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            let input = view.textClient
            #expect(StreamTextInput.isASCIICapable(language: "en-US"))
            #expect(StreamTextInput.isASCIICapable(language: "de-DE"))
            for language in ["zh-Hans", "ja-JP", "ko-KR", "ar"] {
                #expect(!StreamTextInput.isASCIICapable(language: language))
            }
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            #expect(!view.routeKey(usage: 4, text: "a", down: true))
            #expect(h.peers[0].packets.isEmpty)
            input.unmarkText()
            #expect(h.peers[0].packets.map(\.data) == [ControlMessages.text("ni")])
            input.setMarkedText("你好🙂", selectedRange: NSRange(location: 2, length: 0))
            input.unmarkText()
            #expect(h.peers[0].packets.map(\.data) == [ControlMessages.text("ni"), ControlMessages.text("你好🙂")])
            #expect(input.keyboardType == .default)
            #expect(input.textContentType == nil)
            #expect(!input.isSecureTextEntry)
            #expect(input.autocorrectionType == .no)
            #expect(input.spellCheckingType == .no)
            #expect(input.smartQuotesType == .no)
            #expect(input.smartDashesType == .no)
            #expect(input.smartInsertDeleteType == .no)
            if #available(iOS 17, *) { #expect(input.inlinePredictionType == .no) }
        }

        @Test func fallbackRoutingBalancesKeycodesAndPreservesText() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            #expect(view.routeKey(usage: 999, text: "\u{1}", down: true))
            #expect(view.routeKey(usage: 999, text: "\u{1}", down: false))
            #expect(view.routeKey(usage: 89, text: "\u{1}", down: true))
            #expect(view.routeKey(usage: 89, text: "\u{1}", down: false))
            #expect(view.routeKey(usage: 999, text: "x", down: true))
            #expect(view.routeKey(usage: 999, text: "x", down: false))
            #expect(!view.routeKey(usage: 999, text: "", down: true))
            #expect(!view.routeKey(usage: 999, text: "", down: false))
            view.routeKey(usage: 4, text: "", down: true)
            view.routeKey(usage: 4, text: "a", down: false) // The release still matches the fallback down.
            view.routeKey(usage: 4, text: "a", down: true)
            view.routeKey(usage: 4, text: "", down: false) // Text injection must not gain a keycode UP.
            view.routeKey(usage: 4, text: "Dead", down: true)
            view.hasControl = false
            h.clock.advance(to: h.clock.now + 2000)
            #expect(packets(h) == [
                "1:010100000001", "1:010100000001", "1:010100000078",
                "1:00001d0000000000000000000000", "1:00011d0000000000000000000000",
                "1:010100000061",
                "1:00001d0000000000000000000000", "1:00011d0000000000000000000000",
            ])
        }

        @Test func deletingMarkedCompositionStaysLocal() {
            let input = StreamTextInput(frame: .zero, textContainer: nil)
            var commits: [String] = []
            var deletes = 0
            input.onCommit = { commits.append($0) }
            input.onDelete = { deletes += 1 }
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            input.deleteBackward()
            #expect(commits.isEmpty)
            #expect(deletes == 0)
            input.discardComposition()
            input.deleteBackward()
            #expect(deletes == 1)
        }

        @Test func physicalEnterAndTabNeverInjectProducedControlText() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            view.routeKey(usage: 40, text: "\r", down: true)
            view.routeKey(usage: 40, text: "\r", down: false)
            view.routeKey(usage: 43, text: "\t", down: true)
            view.routeKey(usage: 43, text: "\t", down: false)
            view.routeKey(usage: 40, text: "\n", down: true)
            view.routeKey(usage: 40, text: "\n", down: false)
            view.routeKey(usage: 42, text: "\u{8}", down: true)
            view.routeKey(usage: 42, text: "\u{8}", down: false)
            view.routeKey(usage: 41, text: "\u{1b}", down: true)
            view.routeKey(usage: 41, text: "\u{1b}", down: false)
            #expect(packets(h) == [
                "1:0000420000000000000000000000", "1:0001420000000000000000000000",
                "1:00003d0000000000000000000000", "1:00013d0000000000000000000000",
                "1:0000420000000000000000000000", "1:0001420000000000000000000000",
                "1:0000430000000000000000000000", "1:0001430000000000000000000000",
                "1:00006f0000000000000000000000", "1:00016f0000000000000000000000",
            ])
        }

        private var videoReport: [StatsRecord] {
            [StatsRecord(id: "video", type: "inbound-rtp", timestampUs: 1_000_000,
                         values: ["kind": .string("video"), "framesPerSecond": .number(30)])]
        }

        @Test func statsRequireObserversAndStopAfterLastCancellation() async throws {
            let h = try SessionHarness()
            var requests: [StreamStatsSampler.Completion] = []
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200),
                statsScheduler: h.clock, statistics: { requests.append($0) })
            defer { session.close() }
            try await h.connected()
            #expect(requests.isEmpty)
            let first = session.statsPublisher.sink { _ in }
            await drain()
            #expect(requests.count == 1)
            requests[0](videoReport, 250)
            #expect(session.stats?.fps == 30)
            let second = session.statsPublisher.sink { _ in }
            first.cancel()
            await drain()
            #expect(session.stats?.fps == 30)
            second.cancel()
            await drain()
            #expect(session.stats == nil)
            h.clock.advance(to: h.clock.now + 2000)
            #expect(requests.count == 1)
        }

        @Test func subscribedWhileConnectingDoesNotRequestStatistics() async throws {
            let h = try SessionHarness()
            var requests: [StreamStatsSampler.Completion] = []
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200),
                statsScheduler: h.clock, statistics: { requests.append($0) })
            let subscription = session.statsPublisher.sink { _ in }
            defer { subscription.cancel(); session.close() }
            await h.start()
            await drain()
            h.clock.advance(to: h.clock.now + 1000)
            #expect(session.status == .connecting)
            #expect(requests.isEmpty)
        }

        @Test func hiddenStatisticsStopRequestsAndRejectOldReports() async throws {
            let h = try SessionHarness()
            var requests: [StreamStatsSampler.Completion] = []
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200),
                statsScheduler: h.clock, statistics: { requests.append($0) })
            let subscription = session.statsPublisher.sink { _ in }
            defer { subscription.cancel(); session.close() }
            try await h.connected()
            await drain()
            #expect(requests.count == 1)
            session.setVisible(false)
            requests[0](videoReport, 999)
            h.clock.advance(to: h.clock.now + 2000)
            #expect(session.stats == nil)
            #expect(requests.count == 1)
            session.setVisible(true)
            #expect(requests.count == 2)
            requests[1](videoReport, 250)
            #expect(session.stats?.timeToFirstFrameMs == 250)
        }

        @Test func suppressedPeerDipClearsStatisticsUntilRawConnectivityReturns() async throws {
            let h = try SessionHarness()
            var requests: [StreamStatsSampler.Completion] = []
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200),
                statsScheduler: h.clock, statistics: { requests.append($0) })
            let subscription = session.statsPublisher.sink { _ in }
            defer { subscription.cancel(); session.close() }
            try await h.connected()
            await drain()
            requests[0](videoReport, 250)
            #expect(session.stats?.fps == 30)
            h.clock.advance(to: h.clock.now + 1000)
            #expect(requests.count == 2)
            try h.sockets[0].receive(h.sequenceMessage("refresh", step: 1))
            await settle { h.peers[0].restarts.count == 2 }
            h.peers[0].onEvent?(.state(.connecting))
            #expect(session.status == .connected)
            #expect(session.stats == nil)
            requests[1](videoReport, 999)
            #expect(session.stats == nil)
            h.clock.advance(to: h.clock.now + 1000)
            #expect(requests.count == 2)
            h.peers[0].onEvent?(.state(.connected))
            #expect(requests.count == 3)
            requests[2](videoReport, 250)
            #expect(session.stats?.fps == 30)
        }

        @Test func closeFreezesStatusAndDisablesControls() async throws {
            let h = try SessionHarness()
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200))
            let view = DeviceStreamUIView(session: session, hasControl: true)
            try await h.connected()
            var updates: [StreamStatus] = []
            let subscription = session.$status.sink { updates.append($0) }
            let beforeClose = updates
            session.close()
            session.retry()
            session.start()
            view.hasControl = true
            #expect(session.status == .connected)
            #expect(updates == beforeClose)
            #expect(!view.hasControl)
            #expect(!view.canBecomeFirstResponder)
            subscription.cancel()
        }

        @Test func closeFinishesStatisticsWithoutViewInvalidationPerSample() async throws {
            let h = try SessionHarness()
            var requests: [StreamStatsSampler.Completion] = []
            let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 100, height: 200),
                statsScheduler: h.clock, statistics: { requests.append($0) })
            var finished = false
            let subscription = session.statsPublisher.sink(receiveCompletion: { _ in finished = true }, receiveValue: { _ in })
            try await h.connected()
            await drain()
            var invalidations = 0
            let changes = session.objectWillChange.sink { invalidations += 1 }
            requests[0](videoReport, 250)
            #expect(session.stats?.fps == 30)
            #expect(invalidations == 0)
            h.clock.advance(to: h.clock.now + 1000)
            #expect(requests.count == 2)
            session.close()
            #expect(finished)
            #expect(session.stats == nil)
            requests[1](videoReport, 999)
            h.clock.advance(to: h.clock.now + 5000)
            #expect(session.stats == nil)
            #expect(requests.count == 2)
            changes.cancel()
            subscription.cancel()
        }

        @Test func nativeStatisticsProjectionPreservesFoundationValueTypes() throws {
            let record = try #require(projectStatistics(id: "pair", type: "candidate-pair", timestampUs: 123,
                values: ["selected": NSNumber(value: true), "currentRoundTripTime": NSNumber(value: 0.025),
                         "localCandidateId": NSString(string: "local"), "unsupported": NSArray(array: [1, 2])]))
            #expect(record.id == "pair")
            #expect(record.type == "candidate-pair")
            #expect(record.timestampUs == 123)
            #expect(record.values == ["selected": .bool(true), "currentRoundTripTime": .number(0.025),
                                     "localCandidateId": .string("local")])
        }

        @Test(arguments: ["inbound-rtp", "codec", "transport", "candidate-pair", "local-candidate", "remote-candidate"])
        func nativeStatisticsProjectionRetainsRequiredTypes(type: String) {
            #expect(projectStatistics(id: "record", type: type, timestampUs: 1, values: [:])?.type == type)
        }

        @Test func nativeStatisticsProjectionDropsUnrelatedRecords() {
            #expect(projectStatistics(id: "data", type: "data-channel", timestampUs: 1, values: [:]) == nil)
        }

        @Test func heldPhysicalEnterRepeatsOnlyKeycodeDowns() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            view.routeKey(usage: 40, text: "\r", down: true)
            let start = h.clock.now
            h.clock.advance(to: start + 500)
            h.clock.advance(to: start + 533)
            view.routeKey(usage: 40, text: "\r", down: false)
            h.clock.advance(to: start + 1000)
            #expect(packets(h) == [
                "1:0000420000000000000000000000", "1:0000420000000000000000000000",
                "1:0000420000000000000000000000", "1:0001420000000000000000000000",
            ])
        }

        @Test func pointerButtonsUseTheSharedPrimaryOnlyRule() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            let mouse = NSObject()
            let id = ObjectIdentifier(mouse)
            view.beginPointer(id, at: CGPoint(x: 100, y: 100), mouse: true, button: 2)
            #expect(h.peers[0].packets.isEmpty)
            view.beginPointer(id, at: CGPoint(x: 100, y: 100), mouse: true, button: 0)
            view.endPointer(id, button: 2)
            #expect(h.peers[0].packets.count == 1)
            view.endPointer(id, button: 0)
            #expect(packets(h) == [
                "1:0200ffffffffffffffff32000000640000006400c800ffff0100000001000000",
                "1:0201ffffffffffffffff32000000640000006400c800ffff0100000001000000",
            ])
        }

        @Test func displayOnlySendsNothingToTheSessionTransport() async throws {
            let (h, session, view) = try await recordingView()
            defer { view.detach(); session.close() }
            view.hasControl = false
            h.peers[0].packets.removeAll()
            let finger = NSObject()
            let id = ObjectIdentifier(finger)
            view.beginPointer(id, at: CGPoint(x: 100, y: 100))
            view.movePointer(id, to: CGPoint(x: 110, y: 110))
            view.flushMoves()
            view.endPointer(id, cancelled: true)
            view.beginPointer(id, at: CGPoint(x: 100, y: 100), mouse: true)
            view.routeHover(at: CGPoint(x: 100, y: 100), buttons: [.primary, .secondary])
            view.routeScroll(at: CGPoint(x: 100, y: 100), translation: CGPoint(x: 0, y: 100), buttons: [])
            #expect(!view.routeKey(usage: 4, text: "a", down: true))
            let input = view.textClient
            input.insertText("ignored")
            input.deleteBackward()
            input.insertText("\n")
            view.paste(nil)
            for key: SystemKey in [.back, .home, .recent] { view.sendSystemKey(key) }
            #expect(h.peers[0].packets.isEmpty)
        }
    }
#endif
