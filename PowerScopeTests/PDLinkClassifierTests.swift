import Foundation
import Testing
@testable import PowerScope

@Suite("Plug-in vs flaky link")
struct PDLinkClassifierTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    private func event(_ kind: PDEventKind, count: Int = 1) -> DetectedPDEvent {
        DetectedPDEvent(kind: kind, port: 2, count: count, detail: "", voltage: 20000, current: 4700)
    }

    /// The real plug-in of the 100 W charger: all of this happened in two seconds.
    @Test func plugInIsOneNonProblemEvent() {
        var c = PDLinkClassifier()
        let first = c.classify([event(.lost), event(.reconnected), event(.renegotiated), event(.rejected)],
                               at: t0, externalConnected: true, externalJustConnected: false)
        let second = c.classify([event(.established)], at: t0.addingTimeInterval(1),
                                externalConnected: true, externalJustConnected: false)
        let all = first + second
        #expect(all.map(\.kind) == [.plugIn, .established])
        #expect(all.allSatisfy { !$0.kind.isProblem })
        #expect(all.first?.detail.contains("request rejected") == true)
    }

    /// The failing cable: a re-attach every 2–3 seconds. After the first one, all count.
    @Test func repeatedReattachesAreProblems() {
        var c = PDLinkClassifier()
        _ = c.classify([event(.reconnected)], at: t0, externalConnected: true, externalJustConnected: false)
        let again = c.classify([event(.reconnected), event(.hardReset)], at: t0.addingTimeInterval(3),
                               externalConnected: true, externalJustConnected: false)
        #expect(again.map(\.kind) == [.reconnected, .hardReset])
        let later = c.classify([event(.rejected)], at: t0.addingTimeInterval(5),
                               externalConnected: true, externalJustConnected: false)
        #expect(later.map(\.kind) == [.rejected])   // the settling window was cancelled
        #expect(later.allSatisfy { $0.kind.isProblem })
    }

    @Test func plugInsFarApartAreBothNormal() {
        var c = PDLinkClassifier()
        let a = c.classify([event(.reconnected)], at: t0, externalConnected: true, externalJustConnected: false)
        let b = c.classify([event(.reconnected)], at: t0.addingTimeInterval(600), externalConnected: true, externalJustConnected: false)
        #expect(a.map(\.kind) == [.plugIn])
        #expect(b.map(\.kind) == [.plugIn])
    }

    @Test func unplugIsNotAProblem() {
        var c = PDLinkClassifier()
        let out = c.classify([event(.lost)], at: t0, externalConnected: false, externalJustConnected: false)
        #expect(out.map(\.kind) == [.unplugged])
        #expect(!PDEventKind.unplugged.isProblem)
    }

    @Test func externalPowerAppearingOpensTheWindow() {
        var c = PDLinkClassifier()
        let out = c.classify([event(.renegotiated), event(.rejected)], at: t0,
                             externalConnected: true, externalJustConnected: true)
        #expect(out.map(\.kind) == [.plugIn])
    }

    /// A contract lost while plugged in, with no plug-in around it, is still a problem.
    @Test func contractLostWhilePluggedInCounts() {
        var c = PDLinkClassifier()
        let out = c.classify([event(.lost)], at: t0, externalConnected: true, externalJustConnected: false)
        #expect(out.map(\.kind) == [.lost])
        #expect(out.allSatisfy { $0.kind.isProblem })
    }

    /// Once the settling window has passed, problems count again.
    @Test func windowExpires() {
        var c = PDLinkClassifier()
        _ = c.classify([event(.reconnected)], at: t0, externalConnected: true, externalJustConnected: false)
        let later = c.classify([event(.rejected)], at: t0.addingTimeInterval(PDLinkClassifier.settleWindow + 1),
                               externalConnected: true, externalJustConnected: false)
        #expect(later.map(\.kind) == [.rejected])
    }
}
