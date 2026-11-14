// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import UIKit
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
            #expect(commits.count == 3)
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
            let input = try #require(view.subviews.compactMap { $0 as? StreamTextInput }.first)
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

        @Test func forwardingUsesEncodersAndDisplayOnlySuppressesEveryPath() {
            let session = DeviceStreamSession(credentials: { nil })
            let view = DeviceStreamUIView(session: session, hasControl: true)
            var packets: [Data] = []
            view.onInput = { data, sent in
                packets.append(data)
                #expect(!sent) // No channel has been opened in this widget test.
            }
            view.routeKey(usage: 4, text: "a", down: true)
            view.routeKey(usage: 4, text: "a", down: false)
            #expect(packets == [ControlMessages.text("a")])
            packets.removeAll()
            for key: SystemKey in [.back, .home, .recent] { view.sendSystemKey(key) }
            #expect(packets == [4, 3, 187].flatMap { code in
                [ControlMessages.keycode(action: 0, keycode: code),
                 ControlMessages.keycode(action: 1, keycode: code)]
            })
            view.hasControl = false
            packets.removeAll()
            view.routeKey(usage: 4, text: "a", down: true)
            view.sendSystemKey(.back)
            let input = view.subviews.compactMap { $0 as? StreamTextInput }.first
            input?.insertText("ignored")
            input?.deleteBackward()
            view.paste(nil)
            #expect(packets.isEmpty)
            view.detach()
            session.close()
        }

        private func recordingView() async throws
            -> (SessionHarness, DeviceStreamSession, DeviceStreamUIView) {
            let harness = try SessionHarness()
            let session = DeviceStreamSession(
                engine: harness.engine, videoSize: VideoSize(width: 100, height: 200))
            try await harness.connected()
            harness.peers[0].onEvent?(.channel(id: 1, open: true))
            harness.peers[0].onEvent?(.channel(id: 2, open: true))
            let view = DeviceStreamUIView(session: session, hasControl: true)
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
            let input = try #require(view.subviews.compactMap { $0 as? StreamTextInput }.first)
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
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            #expect(h.peers[0].packets.count == 9)
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
            let input = try #require(view.subviews.compactMap { $0 as? StreamTextInput }.first)
            input.insertText("ignored")
            input.deleteBackward()
            input.insertText("\n")
            view.paste(nil)
            for key: SystemKey in [.back, .home, .recent] { view.sendSystemKey(key) }
            #expect(h.peers[0].packets.isEmpty)
        }
    }
#endif
