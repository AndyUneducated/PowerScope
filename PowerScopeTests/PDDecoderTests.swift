import Testing
@testable import PowerScope

/// Raw objects captured from this Mac's port controller with Apple's 140 W USB-C Power Adapter
/// over three different cables. Expected values were decoded independently from the
/// USB PD 3.1 bit layouts.
nonisolated enum Captured {
    // 5 V 3 A first PDO with the source flags set.
    static let first: UInt32 = 0x0981_912C
    static let fixed9V: UInt32 = 0x0002_D12C
    static let fixed15V: UInt32 = 0x0004_B12C
    /// 20 V 3 A: the adapter over a 3 A cable (60 W).
    static let fixed20V3A: UInt32 = 0x0006_412C
    /// 20 V 4.7 A: the adapter over a 5 A cable without EPR (94 W).
    static let fixed20V4A7: UInt32 = 0x0006_41D6
    /// 20 V 5 A and the EPR objects: the adapter over an EPR cable (140 W).
    static let fixed20V5A: UInt32 = 0x0006_41F4
    static let epr28V: UInt32 = 0x0008_C1F4
    static let eprAVS: UInt32 = 0xD230_968C
    /// The RDO the controller kept reporting throughout: PDO 4, 4.7 A.
    static let rdo94W: UInt32 = 0x43C7_59D6

    static let caps94W = [first, fixed9V, fixed15V, fixed20V4A7]
    static let caps140W = [first, fixed9V, fixed15V, fixed20V5A, epr28V, eprAVS]
}

@Suite("PDO decoding")
struct PDODecodingTests {
    @Test("Fixed supplies", arguments: [
        (Captured.first, 5000, 3000),
        (Captured.fixed9V, 9000, 3000),
        (Captured.fixed15V, 15000, 3000),
        (Captured.fixed20V3A, 20000, 3000),
        (Captured.fixed20V4A7, 20000, 4700),
        (Captured.fixed20V5A, 20000, 5000),
        (Captured.epr28V, 28000, 5000),
    ])
    func fixed(raw: UInt32, voltage: Int, current: Int) {
        let pdo = DecodedPDO(raw: raw, position: 1)
        #expect(pdo.kind == .fixed)
        #expect(pdo.minVoltage == voltage)
        #expect(pdo.maxVoltage == voltage)
        #expect(pdo.maxCurrent == current)
    }

    @Test func firstPDOFlags() {
        let pdo = DecodedPDO(raw: Captured.first, position: 1)
        #expect(pdo.flags == ["Unconstrained power", "Unchunked messages", "EPR capable"])
        // Flags only live in the first PDO.
        #expect(DecodedPDO(raw: Captured.first, position: 2).flags.isEmpty)
    }

    @Test func eprAVS() {
        let pdo = DecodedPDO(raw: Captured.eprAVS, position: 9)
        #expect(pdo.kind == .eprAVS)
        #expect(pdo.minVoltage == 15000)
        #expect(pdo.maxVoltage == 28000)
        #expect(pdo.maxPower == 140_000)
        #expect(pdo.powerW == 140)
    }

    @Test func pps() {
        // 3.3–21 V, 3 A programmable supply.
        let pdo = DecodedPDO(raw: 0xC1A4_213C, position: 5)
        #expect(pdo.kind == .pps)
        #expect(pdo.minVoltage == 3300)
        #expect(pdo.maxVoltage == 21000)
        #expect(pdo.maxCurrent == 3000)
    }

    @Test func eprPositionsStartAtEight() {
        let pdos = PDState.decodePDOs(Captured.caps140W + [0, 0, 0], sprCount: 4)
        #expect(pdos.map(\.position) == [1, 2, 3, 4, 8, 9])
        #expect(pdos.first { $0.position == 8 }?.maxVoltage == 28000)
    }
}

@Suite("RDO decoding")
struct RDODecodingTests {
    @Test func fixedRequest() {
        let pdos = PDState.decodePDOs(Captured.caps94W, sprCount: 4)
        let contract = PDContract.decode(rdo: Captured.rdo94W, pdos: pdos)
        #expect(contract?.pdo.position == 4)
        #expect(contract?.voltage == 20000)
        #expect(contract?.current == 4700)
        #expect(contract?.rdo?.maxCurrent == 4700)
        #expect(contract?.rdo?.capabilityMismatch == false)
    }

    @Test func ppsRequestCarriesVoltage() {
        let pps = DecodedPDO(raw: 0xC1A4_213C, position: 5)
        // Position 5, 9.00 V (450 × 20 mV), 2.0 A (40 × 50 mA).
        let contract = PDContract.decode(rdo: 0x5003_8428, pdos: [pps])
        #expect(contract?.voltage == 9000)
        #expect(contract?.current == 2000)
    }

    @Test func rdoForMissingPDOIsIgnored() {
        let pdos = PDState.decodePDOs([Captured.first], sprCount: 1)
        #expect(PDContract.decode(rdo: Captured.rdo94W, pdos: pdos) == nil)
        #expect(PDContract.decode(rdo: 0, pdos: pdos) == nil)
    }
}
