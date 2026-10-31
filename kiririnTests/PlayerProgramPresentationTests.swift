import Testing

#if !PLAYABLE_MODEL_STANDALONE
    @testable import kiririn
#endif

@Suite struct PlayerProgramPresentationTests {
    @Test func earlyReceivedProgramWaitsForUnknownPresentation() {
        var presentation = PlayerProgramPresentation<String>()
        presentation.presented = "番組A"
        presentation.received = "番組B"
        #expect(presentation.selected(allowsReceived: true) == "番組A")
        presentation.presented = nil
        #expect(presentation.selected(allowsReceived: true) == "番組B")
    }

    @Test func sameServiceGenerationKeepsReceivedAndRestoresFrozenProgram() {
        var presentation = PlayerProgramPresentation<String>()
        presentation.presented = "番組A"
        presentation.received = "番組B"
        presentation.resetPresented()
        #expect(presentation.selected(allowsReceived: true) == "番組B")
        presentation.presented = "番組A"
        #expect(presentation.selected(allowsReceived: true) == "番組A")
    }

    @Test func recordedOrDVRPlaybackDoesNotUseReceivedProgram() {
        var presentation = PlayerProgramPresentation<String>()
        presentation.received = "受信側の番組B"
        #expect(presentation.selected(allowsReceived: false) == nil)
        presentation.presented = "再生側の番組A"
        #expect(presentation.selected(allowsReceived: false) == "再生側の番組A")
    }

    @Test func sourceOrServiceResetClearsBothProgramSources() {
        var presentation = PlayerProgramPresentation<String>()
        presentation.presented = "番組A"
        presentation.received = "番組B"
        presentation = .init()
        #expect(presentation.selected(allowsReceived: true) == nil)
        #expect(presentation.selected(allowsReceived: false) == nil)
    }

    @Test func followingProgramStaysWithItsSelectedCurrentProgram() {
        var presentation = PlayerProgramPresentation<[String]>()
        presentation.presented = ["番組A", "次番組A"]
        presentation.received = ["番組B", "次番組B"]
        #expect(presentation.selected(allowsReceived: true) == ["番組A", "次番組A"])
        presentation.presented = nil
        #expect(presentation.selected(allowsReceived: true) == ["番組B", "次番組B"])
    }
}
