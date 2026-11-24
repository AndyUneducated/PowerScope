import Testing
@testable import PowerScope

/// Cached data from chargers that are no longer attached must never become the contract.
/// Values captured with a 100 W charger on controller 2 while controllers 0 and 1 still held
/// the PDOs and RDOs of earlier 94 W and 140 W chargers.
@Suite("Stale charger data")
struct StaleDataTests {
    static let caps100W: [UInt32] = [0x2E01_912C, 0x0002_D12C, 0x0003_C12C, 0x0004_B12C, 0x0006_41F4]
    static let rdo100W: UInt32 = 0x53C7_59D6   // PDO 5, 4.7 A

    private func port(_ index: Int, caps: [UInt32], spr: Int, rdo: UInt32, maxPower: Int?,
                      pdState: Int, sourceTypes: Int, loser: Int) -> PDPortState {
        let pdos = PDState.decodePDOs(caps, sprCount: spr)
        return PDPortState(index: index, pdos: pdos, rawRDO: rdo,
                           rdoContract: PDContract.decode(rdo: rdo, pdos: pdos),
                           maxPower: maxPower, loserReason: loser, firmware: nil, counters: PDCounters(),
                           pdState: pdState, sourceTypes: sourceTypes)
    }

    private var cached94W: PDPortState {
        port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: nil, pdState: 0, sourceTypes: 0, loser: 1)
    }
    private var cached140W: PDPortState {
        port(1, caps: Captured.caps140W, spr: 4, rdo: Captured.rdo94W, maxPower: nil, pdState: 0, sourceTypes: 0, loser: 1)
    }
    private var live100W: PDPortState {
        port(2, caps: Self.caps100W, spr: 5, rdo: Self.rdo100W, maxPower: 100_000, pdState: 5, sourceTypes: 7, loser: 0)
    }

    @Test func connectionState() {
        #expect(cached94W.isConnected == false)
        #expect(live100W.isConnected == true)
        #expect(live100W.isSupplying)
        #expect(!cached94W.isSupplying)
    }

    @Test func liveChargerWins() throws {
        let result = try #require(PDContractResolver.resolve(ports: [cached94W, cached140W, live100W], selectedIndex: 4,
                                                            reportsSelection: true, pmuVoltage: 20000))
        #expect(result.port.index == 2)
        #expect(result.contract.pdo.position == 5)
        #expect(result.contract.voltage == 20000)
        #expect(result.contract.current == 4700)
        #expect(result.contract.basis == .confirmed)
    }

    /// Index 3 names PDO 4, which exists only on the cached controllers (20 V 4.7 A and 20 V 5 A).
    /// Even with a leftover budget on a cached controller, it must not win.
    @Test func cachedControllerWithBudgetIsIgnored() {
        var stale = cached94W
        stale = PDPortState(index: stale.index, pdos: stale.pdos, rawRDO: stale.rawRDO, rdoContract: stale.rdoContract,
                            maxPower: 14_000, loserReason: 1, firmware: nil, counters: PDCounters(), pdState: 0, sourceTypes: 0)
        // PDO 4 on the cached controller is 20 V and would match the PMU; on the live one it is 15 V.
        let result = PDContractResolver.resolve(ports: [stale, live100W], selectedIndex: 3,
                                                reportsSelection: true, pmuVoltage: 20000)
        #expect(result?.port.index == 2)
        #expect(result?.contract.pdo.position == 5)
        #expect(result?.contract.voltage == 20000)
    }

    @Test func nothingAttachedMeansNoContract() {
        let result = PDContractResolver.resolve(ports: [cached94W, cached140W], selectedIndex: nil,
                                                reportsSelection: false, pmuVoltage: nil)
        #expect(result == nil)
    }

    @Test func unpluggedMeansNoContract() {
        var pd = PDState()
        pd.ports = [cached94W, cached140W, live100W]
        pd.selectedIndex = 4
        pd.reportsSelection = true
        pd.pmuVoltage = 20000
        #expect(pd.contract != nil)
        pd.externalConnected = false
        #expect(pd.contract == nil)
        #expect(pd.activePort?.index == 2)   // still the attached controller, but no contract claimed
    }

    /// Controllers that do not report attachment keep the previous behavior.
    @Test func controllersWithoutConnectionInfoStillResolve() {
        let pdos = PDState.decodePDOs(Captured.caps94W, sprCount: 4)
        let legacy = PDPortState(index: 0, pdos: pdos, rawRDO: Captured.rdo94W,
                                 rdoContract: PDContract.decode(rdo: Captured.rdo94W, pdos: pdos),
                                 maxPower: nil, loserReason: nil, firmware: nil, counters: PDCounters())
        #expect(legacy.isConnected == nil)
        #expect(PDContractResolver.resolve(ports: [legacy], selectedIndex: nil, reportsSelection: false, pmuVoltage: nil)?.contract.voltage == 20000)
    }
}
