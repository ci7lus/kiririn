#if os(macOS)
    import AppKit
    import Testing

    #if !TITLEBAR_MODEL_STANDALONE
        @testable import kiririn
    #endif

    @Suite @MainActor struct PlayerTitlebarLayoutTests {
        @Test func programAvailabilityPreservesWindowOwnerTextAndToolbarLayout() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let controller = PlayerTitlebarController_macOS()
            defer {
                controller.detach()
                window.close()
            }

            let known = PlayerTitlebarContent_macOS(
                title: "ニュース", serviceName: "放送局", timeRange: "10:00-10:30",
                nextProgram: "次の番組 10:30-11:00 天気予報"
            )
            let unknown = PlayerTitlebarContent_macOS(
                title: "放送局", serviceName: "放送局", timeRange: nil, nextProgram: nil
            )
            controller.update(known)
            controller.attach(to: window)

            for content in [known, unknown, known] {
                window.title = content.title
                window.subtitle = content.subtitle
                controller.update(content)
                #expect(window.title == (content == known ? "ニュース" : "放送局"))
                #expect(
                    window.subtitle
                        == (content == known
                            ? "放送局｜10:00-10:30｜次の番組 10:30-11:00 天気予報" : ""))
                #expect(window.toolbarStyle == .unified)
            }
        }

        @Test func controllerContentDoesNotOverwriteWindowOwnerText() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let controller = PlayerTitlebarController_macOS()
            defer {
                controller.detach()
                window.close()
            }

            window.title = "ウィンドウ所有者の番組名"
            window.subtitle = "ウィンドウ所有者の放送局"
            controller.attach(to: window)
            #expect(window.title == "ウィンドウ所有者の番組名")
            #expect(window.subtitle == "ウィンドウ所有者の放送局")

            controller.update(
                PlayerTitlebarContent_macOS(
                    title: "フォント照合用の番組名", serviceName: "フォント照合用の放送局",
                    timeRange: nil, nextProgram: nil
                )
            )
            #expect(window.title == "ウィンドウ所有者の番組名")
            #expect(window.subtitle == "ウィンドウ所有者の放送局")
            #expect(window.toolbarStyle == .unified)
        }
    }
#endif
