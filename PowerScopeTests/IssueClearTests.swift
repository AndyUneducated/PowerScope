import Testing
@testable import PowerScope

@Suite("Clearing issues")
struct IssueClearTests {
    /// Counter values from the failing-cable capture.
    private let atClear = PDCounters(attach: 4699, detach: 4699, hardResets: 24, sourceCapabilities: 4772,
                                     requestRejects: 140, psReadyRejects: 9)

    @Test func countsOnlyWhatHappenedAfterTheClear() {
        let later = PDCounters(attach: 4701, detach: 4700, hardResets: 25, sourceCapabilities: 4775,
                               requestRejects: 141, psReadyRejects: 9)
        let since = later.since(atClear)
        #expect(since.attach == 2)
        #expect(since.hardResets == 1)
        #expect(since.sourceCapabilities == 3)
        #expect(since.requestRejects + since.psReadyRejects == 1)
        #expect(since.problems == 2 + 1 + 1)
    }

    @Test func nothingNewMeansZero() {
        #expect(atClear.since(atClear) == PDCounters())
        #expect(atClear.since(atClear).problems == 0)
    }

    @Test func noBaselineShowsTheChipTotals() {
        #expect(atClear.since(nil) == atClear)
    }

    /// If the controller reset after the clear, its new counts all happened after the clear.
    @Test func controllerResetAfterClear() {
        let afterReset = PDCounters(attach: 3, detach: 2, hardResets: 0, sourceCapabilities: 4)
        #expect(afterReset.since(atClear) == afterReset)
    }

    @Test func clearedEventIsNotAProblem() {
        #expect(!PDEventKind.cleared.isProblem)
        #expect(PDEventKind(rawValue: "cleared") == .cleared)
    }
}
