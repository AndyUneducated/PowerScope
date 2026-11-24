import Testing
@testable import PowerScope

/// Scenarios observed on this Mac, replayed against the resolver.
@Suite("PD contract resolution")
struct PDContractResolverTests {
    private func port(_ index: Int, caps: [UInt32], spr: Int, rdo: UInt32, maxPower: Int?) -> PDPortState {
        let pdos = PDState.decodePDOs(caps, sprCount: spr)
        return PDPortState(index: index, pdos: pdos, rawRDO: rdo,
                           rdoContract: PDContract.decode(rdo: rdo, pdos: pdos),
                           maxPower: maxPower, loserReason: nil, firmware: nil, counters: PDCounters())
    }

    private func resolve(_ ports: [PDPortState], selected: Int?, reports: Bool = true, pmu: Int?) -> PDContractResolver.Result? {
        PDContractResolver.resolve(ports: ports, selectedIndex: selected, reportsSelection: reports, pmuVoltage: pmu)
    }

    /// 140 W over an EPR cable: the RDO still names the old 20 V request, the power
    /// manager selects index 7 and the PMU is set to 28 V. Was shown as 20 V before the fix.
    @Test func eprContractWithStaleRDO() throws {
        let ports = [
            port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: nil),
            port(1, caps: Captured.caps140W, spr: 4, rdo: Captured.rdo94W, maxPower: 140_000),
        ]
        let result = try #require(resolve(ports, selected: 7, pmu: 28000))
        #expect(result.port.index == 1)
        #expect(result.contract.voltage == 28000)
        #expect(result.contract.pdo.position == 8)
        #expect(result.contract.basis == .powerManager)
        #expect(result.contract.current == nil)          // the stale RDO must not supply 4.7 A
        #expect(result.contract.currentLimit == 5000)
        #expect(result.contract.powerW == 140)
    }

    /// The same 140 W contract a few minutes later, once the controller refreshed its RDO
    /// to the EPR request: PDO 8, EPR mode, 4.7 A. Now confirmed with an operating current.
    @Test func eprContractOnceRDOCatchesUp() throws {
        let rdo: UInt32 = 0x83C7_59D6
        let ports = [port(1, caps: Captured.caps140W, spr: 4, rdo: rdo, maxPower: 140_000)]
        let result = try #require(resolve(ports, selected: 7, pmu: 28000))
        #expect(result.contract.voltage == 28000)
        #expect(result.contract.basis == .confirmed)
        #expect(result.contract.current == 4700)
        #expect(result.contract.rdo?.eprMode == true)
    }

    /// 94 W over a 5 A cable: selection, RDO and PMU all agree.
    @Test func confirmedSPRContract() throws {
        let ports = [port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: 94_000)]
        let result = try #require(resolve(ports, selected: 3, pmu: 20000))
        #expect(result.contract.voltage == 20000)
        #expect(result.contract.current == 4700)
        #expect(result.contract.basis == .confirmed)
    }

    /// The failing cable: between re-attaches the power manager reports 255 and the PMU 5 V.
    @Test func reattachingAtFiveVolts() {
        let ports = [port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: 94_000)]
        #expect(resolve(ports, selected: nil, pmu: 5000)?.contract == nil)
    }

    /// The power budget can sit on a port with stale capabilities (seen: port 0 at 14 W).
    @Test func budgetOnStalePortIsSkipped() throws {
        let ports = [
            port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: 14_000),
            port(1, caps: Captured.caps140W, spr: 4, rdo: Captured.rdo94W, maxPower: nil),
        ]
        let result = try #require(resolve(ports, selected: 7, pmu: 28000))
        #expect(result.port.index == 1)
        #expect(result.contract.voltage == 28000)
    }

    /// A selection that contradicts the PMU is rejected; the PDO matching the PMU wins.
    @Test func pmuOverridesInconsistentSelection() throws {
        let ports = [port(1, caps: Captured.caps140W, spr: 4, rdo: Captured.rdo94W, maxPower: 140_000)]
        let result = try #require(resolve(ports, selected: 3, pmu: 28000))
        #expect(result.contract.voltage == 28000)
        #expect(result.contract.pdo.kind == .fixed)
        #expect(result.contract.basis == .pmuSetpoint)
    }

    /// An AVS contract without a matching RDO takes its voltage from the PMU, not the PDO maximum.
    @Test func avsVoltageComesFromPMU() throws {
        let ports = [port(1, caps: Captured.caps140W, spr: 4, rdo: Captured.rdo94W, maxPower: 140_000)]
        let result = try #require(resolve(ports, selected: 8, pmu: 24000))
        #expect(result.contract.pdo.kind == .eprAVS)
        #expect(result.contract.voltage == 24000)
    }

    /// A PPS contract with a matching RDO uses the requested voltage and current.
    @Test func ppsWithMatchingRDO() throws {
        let caps: [UInt32] = [Captured.first, Captured.fixed9V, Captured.fixed15V, Captured.fixed20V3A, 0xC1A4_213C]
        let ports = [port(0, caps: caps, spr: 5, rdo: 0x5003_8428, maxPower: 60_000)]
        let result = try #require(resolve(ports, selected: 4, pmu: 9000))
        #expect(result.contract.voltage == 9000)
        #expect(result.contract.current == 2000)
        #expect(result.contract.basis == .confirmed)
    }

    /// Macs that publish neither a selection nor a PMU setpoint fall back to the RDO.
    @Test func rdoOnlyFallback() throws {
        let ports = [port(0, caps: Captured.caps94W, spr: 4, rdo: Captured.rdo94W, maxPower: nil)]
        let result = try #require(resolve(ports, selected: nil, reports: false, pmu: nil))
        #expect(result.contract.voltage == 20000)
        #expect(result.contract.basis == .rdoOnly)
    }

    @Test func noPortsNoContract() {
        #expect(resolve([], selected: 3, pmu: 20000)?.contract == nil)
    }
}

@Suite("Contract cross-checks")
struct CrossCheckTests {
    /// The 140 W EPR case: the stale RDO must be flagged, the PMU and measured input must agree.
    @Test func eprCrossChecks() {
        var snapshot = BatterySnapshot()
        let pdos = PDState.decodePDOs(Captured.caps140W, sprCount: 4)
        snapshot.pd.ports = [PDPortState(index: 1, pdos: pdos, rawRDO: Captured.rdo94W,
                                         rdoContract: PDContract.decode(rdo: Captured.rdo94W, pdos: pdos),
                                         maxPower: 140_000, loserReason: nil, firmware: nil, counters: PDCounters())]
        snapshot.pd.reportsSelection = true
        snapshot.pd.selectedIndex = 7
        snapshot.pd.pmuVoltage = 28000
        snapshot.ipdInputVoltage = 28000
        snapshot.telemetry.systemVoltageIn = 27140

        let checks = Dictionary(uniqueKeysWithValues: snapshot.contractCrossChecks.map { ($0.id, $0.status) })
        #expect(checks["rdo"] == .mismatch)
        #expect(checks["hvc"] == .match)
        #expect(checks["ipd"] == .match)
        #expect(checks["measured"] == .match)
    }
}
