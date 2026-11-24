import Foundation

/// Decodes raw USB Power Delivery 3.x data objects as reported by the port controller.
/// Bit layouts follow the USB PD 3.1 specification (section 6.4.1 PDOs, 6.4.2 RDOs).
nonisolated enum PDOKind: String, Sendable {
    case fixed = "Fixed"
    case battery = "Battery"
    case variable = "Variable"
    case pps = "PPS"
    case eprAVS = "EPR AVS"
    case sprAVS = "SPR AVS"
    case unknown = "Unknown"

    /// Programmable supplies: the negotiated voltage comes from the RDO, not the PDO.
    var isProgrammable: Bool { self == .pps || self == .eprAVS || self == .sprAVS }
}

nonisolated struct DecodedPDO: Identifiable, Hashable, Sendable {
    let position: Int          // 1-based object position, as referenced by the RDO
    let raw: UInt32
    let kind: PDOKind
    let minVoltage: Int        // mV (equals maxVoltage for fixed supplies)
    let maxVoltage: Int        // mV
    let maxCurrent: Int?       // mA
    let maxPower: Int?         // mW (battery supplies and EPR AVS)
    let flags: [String]

    var id: Int { position }

    var powerW: Double {
        if let maxPower { return Double(maxPower) / 1000 }
        return Double(maxVoltage) * Double(maxCurrent ?? 0) / 1_000_000
    }

    var voltageText: String {
        if minVoltage == maxVoltage { return Format.number(Double(maxVoltage) / 1000, digits: 2, unit: "V") }
        return "\(Format.number(Double(minVoltage) / 1000, digits: 1))–\(Format.number(Double(maxVoltage) / 1000, digits: 1, unit: "V"))"
    }

    init(raw: UInt32, position: Int) {
        self.raw = raw
        self.position = position
        var flags: [String] = []
        switch raw >> 30 {
        case 0b00:
            kind = .fixed
            let v = Int((raw >> 10) & 0x3FF) * 50
            minVoltage = v
            maxVoltage = v
            maxCurrent = Int(raw & 0x3FF) * 10
            maxPower = nil
            if position == 1 {
                if raw & (1 << 29) != 0 { flags.append("Dual-role power") }
                if raw & (1 << 28) != 0 { flags.append("USB suspend") }
                if raw & (1 << 27) != 0 { flags.append("Unconstrained power") }
                if raw & (1 << 26) != 0 { flags.append("USB data") }
                if raw & (1 << 25) != 0 { flags.append("Dual-role data") }
                if raw & (1 << 24) != 0 { flags.append("Unchunked messages") }
                if raw & (1 << 23) != 0 { flags.append("EPR capable") }
            }
        case 0b01:
            kind = .battery
            maxVoltage = Int((raw >> 20) & 0x3FF) * 50
            minVoltage = Int((raw >> 10) & 0x3FF) * 50
            maxCurrent = nil
            maxPower = Int(raw & 0x3FF) * 250
        case 0b10:
            kind = .variable
            maxVoltage = Int((raw >> 20) & 0x3FF) * 50
            minVoltage = Int((raw >> 10) & 0x3FF) * 50
            maxCurrent = Int(raw & 0x3FF) * 10
            maxPower = nil
        default:
            switch (raw >> 28) & 0b11 {
            case 0b00:
                kind = .pps
                maxVoltage = Int((raw >> 17) & 0xFF) * 100
                minVoltage = Int((raw >> 8) & 0xFF) * 100
                maxCurrent = Int(raw & 0x7F) * 50
                maxPower = nil
                if raw & (1 << 27) != 0 { flags.append("Power limited") }
            case 0b01:
                kind = .eprAVS
                maxVoltage = Int((raw >> 17) & 0x1FF) * 100
                minVoltage = Int((raw >> 8) & 0xFF) * 100
                maxCurrent = nil
                maxPower = Int(raw & 0xFF) * 1000
            case 0b10:
                kind = .sprAVS
                minVoltage = 9000
                maxVoltage = 20000
                maxCurrent = Int(raw & 0x3FF) * 10   // current available at 20 V
                maxPower = nil
            default:
                kind = .unknown
                minVoltage = 0
                maxVoltage = 0
                maxCurrent = nil
                maxPower = nil
            }
        }
        self.flags = flags
    }
}

/// A sink's Request Data Object: which PDO it asked for and how much current.
nonisolated struct DecodedRDO: Hashable, Sendable {
    let raw: UInt32
    let objectPosition: Int
    let operatingCurrent: Int?     // mA
    let maxCurrent: Int?           // mA
    let operatingPower: Int?       // mW (battery supplies)
    let requestedVoltage: Int?     // mV (PPS / AVS only)
    let capabilityMismatch: Bool
    let eprMode: Bool

    /// Decodes the RDO against the PDO it references (the layout depends on that PDO's type).
    init(raw: UInt32, referencing pdo: DecodedPDO?) {
        self.raw = raw
        objectPosition = Int((raw >> 28) & 0xF)
        capabilityMismatch = raw & (1 << 26) != 0
        eprMode = raw & (1 << 22) != 0
        switch pdo?.kind {
        case .pps:
            requestedVoltage = Int((raw >> 9) & 0xFFF) * 20
            operatingCurrent = Int(raw & 0x7F) * 50
            maxCurrent = nil
            operatingPower = nil
        case .eprAVS, .sprAVS:
            requestedVoltage = Int((raw >> 9) & 0xFFF) * 25
            operatingCurrent = Int(raw & 0x7F) * 50
            maxCurrent = nil
            operatingPower = nil
        case .battery:
            requestedVoltage = nil
            operatingCurrent = nil
            maxCurrent = nil
            operatingPower = Int((raw >> 10) & 0x3FF) * 250
        default:
            requestedVoltage = nil
            operatingCurrent = Int((raw >> 10) & 0x3FF) * 10
            maxCurrent = Int(raw & 0x3FF) * 10
            operatingPower = nil
        }
    }
}

/// How the active PDO was identified.
nonisolated enum ContractBasis: Sendable {
    /// The power manager's selected profile and the port controller's RDO agree.
    case confirmed
    /// Only the power manager's selection; the RDO points elsewhere (the port
    /// controller does not refresh it for every contract, e.g. EPR).
    case powerManager
    /// The PMU input setpoint matches this PDO; no power manager selection or RDO confirms it.
    case pmuSetpoint
    /// Only the RDO; nothing else is published to confirm it.
    case rdoOnly
}

/// The contract in use between the Mac and the source.
nonisolated struct PDContract: Hashable, Sendable {
    let pdo: DecodedPDO
    /// The RDO, only when it references this PDO.
    let rdo: DecodedRDO?
    var basis: ContractBasis = .rdoOnly
    /// For PPS/AVS supplies: the requested voltage when no matching RDO carries it
    /// (taken from the PMU setpoint).
    var programmedVoltage: Int? = nil

    /// Negotiated bus voltage in mV: the PDO voltage for fixed supplies,
    /// the requested voltage for programmable ones.
    var voltage: Int {
        if pdo.kind.isProgrammable { return rdo?.requestedVoltage ?? programmedVoltage ?? pdo.maxVoltage }
        return pdo.maxVoltage
    }

    /// Negotiated operating current in mA, known only from a matching RDO.
    var current: Int? {
        guard let rdo else { return nil }
        if let c = rdo.operatingCurrent { return c }
        if let p = rdo.operatingPower, voltage > 0 { return p * 1000 / voltage }
        return nil
    }

    /// The most current the source allows at this voltage (PDO limit), in mA.
    var currentLimit: Int? {
        if let c = pdo.maxCurrent { return c }
        if let p = pdo.maxPower, voltage > 0 { return p * 1000 / voltage }
        return nil
    }

    /// Operating current if known, otherwise the PDO limit.
    var displayCurrent: Int? { current ?? currentLimit }

    var powerW: Double? {
        displayCurrent.map { Double(voltage) * Double($0) / 1_000_000 }
    }

    static func decode(rdo raw: UInt32, pdos: [DecodedPDO]) -> PDContract? {
        guard raw != 0 else { return nil }
        let position = Int((raw >> 28) & 0xF)
        guard let pdo = pdos.first(where: { $0.position == position }) else { return nil }
        return PDContract(pdo: pdo, rdo: DecodedRDO(raw: raw, referencing: pdo), basis: .rdoOnly)
    }
}
