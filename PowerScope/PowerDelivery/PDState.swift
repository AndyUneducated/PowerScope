import Foundation
import IOKit

/// Cumulative link counters kept by the USB-C port controller firmware.
/// They keep counting between our samples, so their deltas reveal every
/// reconnect or renegotiation even when polling is too slow to see it.
nonisolated struct PDCounters: Hashable, Sendable {
    var attach = 0
    var detach = 0
    var hardResets = 0
    var sourceCapabilities = 0   // Source_Capabilities messages received
    var requestRejects = 0
    var psReadyRejects = 0
    var capabilityMismatches = 0
}

nonisolated struct PDPortState: Identifiable, Sendable {
    let index: Int
    let pdos: [DecodedPDO]
    let rawRDO: UInt32
    let contract: PDContract?
    let maxPower: Int?            // mW, reported for the port that supplies the system
    let loserReason: Int?
    let firmware: Int?
    let counters: PDCounters

    var id: Int { index }
}

/// The power source macOS elected for a port (IOPortFeaturePowerSource "WinningPowerSourceOption").
nonisolated struct ElectedSource: Hashable, Sendable {
    let name: String
    let path: String
    let portNumber: Int?
    let voltage: Int          // mV
    let current: Int          // mA
    let power: Int            // mW
}

enum CheckStatus {
    case match, mismatch, unavailable

    var symbol: String {
        switch self {
        case .match: "checkmark.circle.fill"
        case .mismatch: "exclamationmark.triangle.fill"
        case .unavailable: "minus.circle"
        }
    }
}

struct ContractCrossCheck: Identifiable {
    let id: String
    let source: String
    let detail: String
    let voltage: Int?     // mV
    let current: Int?     // mA
    let status: CheckStatus
}

struct PDState {
    var ports: [PDPortState] = []
    var elected: [ElectedSource] = []

    /// The port that powers the Mac: a live contract, preferring the one with a power budget.
    var activePort: PDPortState? {
        let live = ports.filter { $0.contract != nil }
        return live.first { ($0.maxPower ?? 0) > 0 } ?? live.first
    }

    var contract: PDContract? { activePort?.contract }

    /// The elected USB-PD source, if macOS published one.
    var electedPD: ElectedSource? {
        elected.first { $0.name == "USB-PD" } ?? elected.first
    }

    static func read(battery: [String: Any]) -> PDState {
        var state = PDState()
        if let infos = battery["PortControllerInfo"] as? [[String: Any]] {
            state.ports = infos.enumerated().compactMap { index, info in port(index: index, info: info) }
        }
        state.elected = electedSources()
        return state
    }

    private static func port(index: Int, info: [String: Any]) -> PDPortState? {
        let rawPDOs = (info["PortControllerPortPDO"] as? [NSNumber]) ?? []
        let pdos = rawPDOs.enumerated().compactMap { offset, n -> DecodedPDO? in
            let raw = UInt32(truncatingIfNeeded: n.int64Value)
            return raw == 0 ? nil : DecodedPDO(raw: raw, position: offset + 1)
        }
        let rdo = UInt32(truncatingIfNeeded: int(info["PortControllerActiveContractRdo"]) ?? 0)
        // Skip ports that have never seen a PD source.
        guard !pdos.isEmpty || rdo != 0 else { return nil }
        let counters = PDCounters(
            attach: int(info["PortControllerAttachCount"]) ?? 0,
            detach: int(info["PortControllerDetachCount"]) ?? 0,
            hardResets: int(info["PortControllerHardResetCount"]) ?? 0,
            sourceCapabilities: int(info["PortControllerIrqCntRxSrcCap"]) ?? 0,
            requestRejects: int(info["PortControllerSrdoRejectCount"]) ?? 0,
            psReadyRejects: int(info["PortControllerSrdyRejectCount"]) ?? 0,
            capabilityMismatches: int(info["PortControllerCapMismatch"]) ?? 0
        )
        let maxPower = int(info["PortControllerMaxPower"])
        return PDPortState(
            index: index,
            pdos: pdos,
            rawRDO: rdo,
            contract: PDContract.decode(rdo: rdo, pdos: pdos),
            maxPower: maxPower == 0 ? nil : maxPower,
            loserReason: int(info["PortControllerLoserReason"]),
            firmware: int(info["PortControllerFwVersion"]),
            counters: counters
        )
    }

    /// Walks every port's "Power In" node and reads its power-source children.
    /// Sources are often not registered (so IOServiceGetMatchingServices misses them);
    /// the registry name carries "[*]" for the source macOS currently uses.
    private static func electedSources() -> [ElectedSource] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortFeaturePowerIn"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var active: [ElectedSource] = []
        var others: [ElectedSource] = []
        while case let powerIn = IOIteratorNext(iterator), powerIn != 0 {
            defer { IOObjectRelease(powerIn) }
            let portName = parentName(of: powerIn)
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(powerIn, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "IOPortFeaturePowerSource") != 0 else { continue }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any],
                      let winning = dict["WinningPowerSourceOption"] as? [String: Any],
                      let voltage = int(winning["Voltage (mV)"]) else { continue }
                let registryName = name(of: child)
                let sourceName = dict["PowerSourceName"] as? String
                    ?? registryName.replacingOccurrences(of: " [*]", with: "")
                let source = ElectedSource(
                    name: sourceName,
                    path: dict["Description"] as? String ?? "\(portName)/Power In/\(sourceName)",
                    portNumber: int(dict["ParentPortNumber"]) ?? portNumber(from: portName),
                    voltage: voltage,
                    current: int(winning["Max Current (mA)"]) ?? 0,
                    power: int(winning["Max Power (mW)"]) ?? 0
                )
                if registryName.contains("[*]") { active.append(source) } else { others.append(source) }
            }
        }
        return active + others
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func parentName(of entry: io_registry_entry_t) -> String {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(parent) }
        // Port nodes are named like "Port-USB-C"; the "@3" location is separate.
        var location = [CChar](repeating: 0, count: 64)
        let base = name(of: parent)
        if IORegistryEntryGetLocationInPlane(parent, kIOServicePlane, &location) == KERN_SUCCESS {
            return "\(base)@\(String(cString: location))"
        }
        return base
    }

    private static func portNumber(from portName: String) -> Int? {
        portName.split(separator: "@").last.flatMap { Int($0) }
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}

extension BatterySnapshot {
    /// Compares the negotiated PD contract with every other place the system reports it.
    var contractCrossChecks: [ContractCrossCheck] {
        let reference = pd.contract
        func status(_ voltage: Int?) -> CheckStatus {
            guard let voltage, let reference else { return .unavailable }
            return abs(voltage - reference.voltage) <= 50 ? .match : .mismatch
        }

        var checks: [ContractCrossCheck] = []
        if let elected = pd.electedPD {
            checks.append(ContractCrossCheck(
                id: "elected", source: "macOS elected source",
                detail: elected.path.isEmpty ? elected.name : elected.path,
                voltage: elected.voltage, current: elected.current, status: status(elected.voltage)))
        } else {
            checks.append(ContractCrossCheck(id: "elected", source: "macOS elected source",
                                             detail: "Not published", voltage: nil, current: nil, status: .unavailable))
        }

        let hvc = adapter?.profiles.first { $0.index == adapter?.activeProfileIndex }
        checks.append(ContractCrossCheck(
            id: "hvc", source: "Adapter profile index (UsbHvcHvcIndex)",
            detail: hvc.map { "Index \($0.index)" } ?? "No profile selected (index 255)",
            voltage: hvc?.maxVoltage, current: hvc?.maxCurrent, status: status(hvc?.maxVoltage)))

        checks.append(ContractCrossCheck(
            id: "ipd", source: "PMU input setpoint (IPDInputVoltage)",
            detail: ipdInputVoltage.map { $0 <= 5000 ? "At 5 V fallback" : "Configured" } ?? "Not reported",
            voltage: ipdInputVoltage, current: ipdInputCurrent, status: status(ipdInputVoltage)))
        return checks
    }
}
