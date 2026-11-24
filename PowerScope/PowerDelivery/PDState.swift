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
    /// The contract the RDO points to. The port controller does not refresh the RDO
    /// for every contract (EPR contracts keep the last SPR request), so it can be stale.
    let rdoContract: PDContract?
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

/// A physical power input (a USB-C or MagSafe port) and the sources macOS reports on it.
struct PhysicalPort: Identifiable {
    let name: String          // e.g. "Port-USB-C@1", "Port-MagSafe 3@1"
    let sources: [PortSource]
    var id: String { name }

    var isMagSafe: Bool { name.localizedCaseInsensitiveContains("MagSafe") }

    /// "USB-C 1", "MagSafe 3 · 1"
    var displayName: String {
        let base = name.replacingOccurrences(of: "Port-", with: "")
        let parts = base.split(separator: "@")
        guard parts.count == 2 else { return base }
        return "\(parts[0].replacingOccurrences(of: "-", with: " ")) · port \(parts[1])"
    }

    var inUse: PortSource? { sources.first(where: \.inUse) }
}

struct PortSource: Identifiable {
    struct Option: Hashable {
        let voltage: Int   // mV
        let current: Int   // mA
        let power: Int     // mW
    }
    let name: String       // "USB-PD", "Brick ID", "TypeC"
    let inUse: Bool
    let options: [Option]
    let winning: ElectedSource?
    var id: String { name }

    var maxPower: Int { options.map(\.power).max() ?? winning?.power ?? 0 }
}

struct PDState {
    var ports: [PDPortState] = []
    var elected: [ElectedSource] = []
    var physicalPorts: [PhysicalPort] = []
    /// The power manager's selected source profile (`UsbHvcHvcIndex`, 0-based);
    /// nil when it reports 255 (no PD profile in use).
    var selectedIndex: Int?
    /// Whether the system publishes `UsbHvcHvcIndex` at all.
    var reportsSelection = false
    /// The PMU's configured input voltage in mV (`IPDInputVoltage`); 5000 means the 5 V fallback.
    var pmuVoltage: Int?

    var resolved: PDContractResolver.Result? {
        PDContractResolver.resolve(ports: ports, selectedIndex: selectedIndex,
                                   reportsSelection: reportsSelection, pmuVoltage: pmuVoltage)
    }

    /// The port that powers the Mac.
    var activePort: PDPortState? {
        resolved?.port ?? PDContractResolver.candidates(ports).first
    }

    /// The contract in use, or nil when no PD profile is in use.
    var contract: PDContract? { resolved?.contract }

    /// The elected USB-PD source, if macOS published one.
    var electedPD: ElectedSource? {
        elected.first { $0.name == "USB-PD" } ?? elected.first
    }

    static func read(battery: [String: Any]) -> PDState {
        var state = PDState()
        if let infos = battery["PortControllerInfo"] as? [[String: Any]] {
            state.ports = infos.enumerated().compactMap { index, info in port(index: index, info: info) }
        }
        if let adapter = battery["AdapterDetails"] as? [String: Any], let index = int(adapter["UsbHvcHvcIndex"]) {
            state.reportsSelection = true
            state.selectedIndex = index == 255 ? nil : index
        }
        state.pmuVoltage = int((battery["PowerDistribution"] as? [String: Any])?["IPDInputVoltage"])
        state.physicalPorts = physicalPorts()
        // Sources macOS currently uses first, then the last values other ports reported.
        let sources = state.physicalPorts.flatMap(\.sources)
        state.elected = (sources.filter(\.inUse) + sources.filter { !$0.inUse }).compactMap(\.winning)
        return state
    }

    private static func port(index: Int, info: [String: Any]) -> PDPortState? {
        let raws = ((info["PortControllerPortPDO"] as? [NSNumber]) ?? [])
            .map { UInt32(truncatingIfNeeded: $0.int64Value) }
        let pdos = decodePDOs(raws, sprCount: int(info["PortControllerNPDOs"]))
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
            rdoContract: PDContract.decode(rdo: rdo, pdos: pdos),
            maxPower: maxPower == 0 ? nil : maxPower,
            loserReason: int(info["PortControllerLoserReason"]),
            firmware: int(info["PortControllerFwVersion"]),
            counters: counters
        )
    }

    /// Decodes the controller's PDO list. It lists SPR objects first, then EPR objects;
    /// per USB PD 3.1, SPR objects occupy positions 1–7 and EPR objects start at position 8.
    static func decodePDOs(_ raws: [UInt32], sprCount: Int?) -> [DecodedPDO] {
        let objects = raws.filter { $0 != 0 }
        let spr = sprCount ?? objects.count
        return objects.enumerated().map { k, raw in
            DecodedPDO(raw: raw, position: k < spr ? k + 1 : 8 + (k - spr))
        }
    }

    /// Walks every port's "Power In" node and reads its power-source children.
    /// Sources are often not registered (so IOServiceGetMatchingServices misses them);
    /// the registry name carries "[*]" for the source macOS currently uses.
    /// Walks every physical port's "Power In" node and reads its power-source children.
    /// Sources are often not registered (so IOServiceGetMatchingServices misses them);
    /// the registry name carries "[*]" for the source macOS currently uses.
    private static func physicalPorts() -> [PhysicalPort] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortFeaturePowerIn"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [PhysicalPort] = []
        while case let powerIn = IOIteratorNext(iterator), powerIn != 0 {
            defer { IOObjectRelease(powerIn) }
            let portName = parentName(of: powerIn)
            var sources: [PortSource] = []
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(powerIn, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard IOObjectConformsTo(child, "IOPortFeaturePowerSource") != 0 else { continue }
                    var props: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                          let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
                    let registryName = name(of: child)
                    let sourceName = dict["PowerSourceName"] as? String
                        ?? registryName.replacingOccurrences(of: " [*]", with: "")
                    // Published as a set, not an array.
                    let rawOptions = (dict["PowerSourceOptions"] as? [[String: Any]])
                        ?? ((dict["PowerSourceOptions"] as? NSSet)?.allObjects as? [[String: Any]]) ?? []
                    let options = rawOptions.compactMap(option)
                    var winning: ElectedSource?
                    if let w = dict["WinningPowerSourceOption"] as? [String: Any], let o = option(w) {
                        winning = ElectedSource(
                            name: sourceName,
                            path: dict["Description"] as? String ?? "\(portName)/Power In/\(sourceName)",
                            portNumber: int(dict["ParentPortNumber"]) ?? portNumber(from: portName),
                            voltage: o.voltage, current: o.current, power: o.power)
                    }
                    sources.append(PortSource(name: sourceName, inUse: registryName.contains("[*]"),
                                              options: options.sorted { $0.voltage < $1.voltage }, winning: winning))
                }
            }
            ports.append(PhysicalPort(name: portName, sources: sources))
        }
        return ports.sorted { $0.name < $1.name }
    }

    private static func option(_ dict: [String: Any]) -> PortSource.Option? {
        guard let voltage = int(dict["Voltage (mV)"]) else { return nil }
        return PortSource.Option(voltage: voltage, current: int(dict["Max Current (mA)"]) ?? 0,
                                 power: int(dict["Max Power (mW)"]) ?? 0)
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
    /// Compares the contract in use with every other place the system reports it.
    var contractCrossChecks: [ContractCrossCheck] {
        let reference = pd.contract
        func status(_ voltage: Int?, below: Int = 50, above: Int = 50) -> CheckStatus {
            guard let voltage, let reference else { return .unavailable }
            let diff = voltage - reference.voltage
            return (-below...above).contains(diff) ? .match : .mismatch
        }
        var checks: [ContractCrossCheck] = []

        if let rdo = pd.activePort?.rdoContract {
            let stale = reference.map { $0.pdo.position != rdo.pdo.position } ?? false
            checks.append(ContractCrossCheck(
                id: "rdo", source: "Port controller RDO",
                detail: stale ? "Refers to PDO \(rdo.pdo.position); not refreshed for the current contract"
                              : "PDO \(rdo.pdo.position), \(rdo.pdo.kind.rawValue)",
                voltage: rdo.voltage, current: rdo.current, status: status(rdo.voltage)))
        } else {
            checks.append(ContractCrossCheck(id: "rdo", source: "Port controller RDO", detail: "No RDO",
                                             voltage: nil, current: nil, status: .unavailable))
        }

        let selected = pd.selectedIndex
        checks.append(ContractCrossCheck(
            id: "hvc", source: "Power manager profile (UsbHvcHvcIndex)",
            detail: selected.map { "Index \($0) → PDO \($0 + 1)" } ?? (pd.reportsSelection ? "No profile selected (255)" : "Not reported"),
            voltage: selected.flatMap { i in pd.activePort?.pdos.first { $0.position == i + 1 }?.maxVoltage },
            current: selected.flatMap { i in pd.activePort?.pdos.first { $0.position == i + 1 }?.maxCurrent },
            status: selected == nil ? .unavailable : .match))

        checks.append(ContractCrossCheck(
            id: "ipd", source: "PMU input setpoint (IPDInputVoltage)",
            detail: ipdInputVoltage.map { $0 <= 5000 ? "At 5 V fallback" : "Configured" } ?? "Not reported",
            voltage: ipdInputVoltage, current: ipdInputCurrent, status: status(ipdInputVoltage)))

        // The internal input rail sits behind the input switches, so it reads a little
        // below VBUS under load: accept up to 10 % below and 5 % above.
        let measured = telemetry.systemVoltageIn
        let tolerance = reference.map { $0.voltage / 10 } ?? 0
        checks.append(ContractCrossCheck(
            id: "measured", source: "Measured system input (SystemVoltageIn)",
            detail: "Accepts 10 % drop under load", voltage: measured, current: telemetry.systemCurrentIn,
            status: status(measured, below: tolerance, above: tolerance / 2)))

        if let elected = pd.electedPD {
            checks.append(ContractCrossCheck(
                id: "elected", source: "macOS elected USB-C source",
                detail: (elected.path.isEmpty ? elected.name : elected.path) + " · may keep a previous charger's value",
                voltage: elected.voltage, current: elected.current, status: status(elected.voltage)))
        }
        return checks
    }
}
