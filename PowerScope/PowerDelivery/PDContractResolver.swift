import Foundation

/// Works out which PD contract is in use from the three places macOS reports it.
///
/// None of them is reliable alone:
/// - The power manager's selection (`UsbHvcHvcIndex`) names the PDO but not the port,
///   and reads 255 while the link re-attaches.
/// - The port controller's RDO is not refreshed for every contract (an EPR 28 V contract
///   keeps the last SPR request), so it can point at an old PDO.
/// - The PMU input setpoint (`IPDInputVoltage`) gives the voltage the system is configured
///   for, and drops to 5 V when no PD contract is in use.
///
/// The resolver uses them in that order of authority and only accepts a candidate that
/// is consistent with the PMU setpoint when one is published.
nonisolated enum PDContractResolver {
    struct Result {
        let port: PDPortState
        let contract: PDContract
    }

    /// Voltage tolerance when comparing a PDO with the PMU setpoint, in mV.
    static let tolerance = 100

    /// Ports in order of likelihood: one with a power budget, then ones with an RDO.
    static func candidates(_ ports: [PDPortState]) -> [PDPortState] {
        ports.filter { ($0.maxPower ?? 0) > 0 }
            + ports.filter { ($0.maxPower ?? 0) == 0 && $0.rdoContract != nil }
            + ports.filter { ($0.maxPower ?? 0) == 0 && $0.rdoContract == nil }
    }

    static func resolve(ports: [PDPortState], selectedIndex: Int?, reportsSelection: Bool,
                        pmuVoltage: Int?) -> Result? {
        // A setpoint at or below 5 V means the PMU is on the USB default, not a PD contract.
        let pmu = pmuVoltage.flatMap { $0 > 5000 ? $0 : nil }
        if reportsSelection, selectedIndex == nil, pmu == nil, pmuVoltage != nil { return nil }

        let ordered = candidates(ports)

        // 1. The power manager's selected profile, on a port where it matches the PMU.
        if let index = selectedIndex {
            for port in ordered {
                guard let pdo = port.pdos.first(where: { $0.position == index + 1 }),
                      let contract = contract(pdo: pdo, port: port, pmu: pmu,
                                              matched: .confirmed, unmatched: .powerManager) else { continue }
                return Result(port: port, contract: contract)
            }
        }

        // 2. A PDO whose voltage matches the PMU setpoint; prefer the one the RDO names.
        if let pmu {
            for port in ordered {
                let matching = port.pdos.filter { covers($0, pmu) }
                let preferred = matching.first { $0.position == port.rdoContract?.pdo.position } ?? matching.first
                if let pdo = preferred,
                   let contract = contract(pdo: pdo, port: port, pmu: pmu,
                                           matched: .confirmed, unmatched: .pmuSetpoint) {
                    return Result(port: port, contract: contract)
                }
            }
            return nil
        }

        // 3. Nothing else is published: trust the RDO, flagged as such.
        for port in ordered {
            if let contract = port.rdoContract { return Result(port: port, contract: contract) }
        }
        return nil
    }

    /// Builds a contract for `pdo`, or nil if it contradicts the PMU setpoint or its
    /// voltage cannot be determined.
    private static func contract(pdo: DecodedPDO, port: PDPortState, pmu: Int?,
                                 matched: ContractBasis, unmatched: ContractBasis) -> PDContract? {
        if let pmu, !covers(pdo, pmu) { return nil }
        let rdo = port.rdoContract.flatMap { $0.pdo.position == pdo.position ? $0.rdo : nil }
        var programmed: Int?
        if pdo.kind.isProgrammable {
            // A programmable supply's voltage is only known from a matching RDO or the PMU.
            programmed = rdo?.requestedVoltage ?? pmu
            guard programmed != nil else { return nil }
        }
        return PDContract(pdo: pdo, rdo: rdo, basis: rdo == nil ? unmatched : matched,
                          programmedVoltage: programmed)
    }

    /// Whether a PDO can deliver `voltage` (mV) within the tolerance.
    static func covers(_ pdo: DecodedPDO, _ voltage: Int) -> Bool {
        voltage >= pdo.minVoltage - tolerance && voltage <= pdo.maxVoltage + tolerance
    }
}
