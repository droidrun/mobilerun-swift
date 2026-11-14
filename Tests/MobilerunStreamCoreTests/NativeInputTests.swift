// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
    import UIKit
    import Testing
    import MobilerunProtocol
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
    }
#endif
