import Foundation
import IOKit
import IOKit.ps

/// Reads battery and charger state from the IOKit registry (`AppleSmartBattery` and children)
/// and from the IOPowerSources API.
enum BatteryReader {
    /// - Parameter includeRaw: also build the flattened key/value list for the Raw Data page.
    static func read(now: Date = .now, includeRaw: Bool = false) -> BatterySnapshot {
        var s = BatterySnapshot(date: now)
        let battery = registryProperties(className: "AppleSmartBattery") ?? [:]
        let batteryData = battery["BatteryData"] as? [String: Any] ?? [:]
        let pack = registryProperties(className: "AppleSmartBatteryPack")
        let packData = pack?["BatteryData"] as? [String: Any] ?? [:]
        let banks = registryPropertiesAll(className: "AppleSmartBatteryBank")
        let source = powerSourceDescription()

        s.hasBattery = !battery.isEmpty && (bool(battery["BatteryInstalled"]) ?? true)
        s.externalConnected = bool(battery["ExternalConnected"]) ?? bool(battery["AppleRawExternalConnected"]) ?? false
        s.isCharging = bool(battery["IsCharging"]) ?? false
        s.fullyCharged = bool(battery["FullyCharged"]) ?? false
        s.atCritical = bool(battery["AtCriticalLevel"]) ?? false

        // Percent: IOPS always reports percent; the registry reports percent on Apple Silicon
        // and mAh on Intel Macs.
        if let p = int(source?[kIOPSCurrentCapacityKey]) {
            s.percent = p
        } else if let cur = int(battery["CurrentCapacity"]), let max = int(battery["MaxCapacity"]), max > 0 {
            s.percent = max > 100 ? cur * 100 / max : cur
        }

        s.voltage = int(battery["Voltage"]) ?? int(battery["AppleRawBatteryVoltage"])
        s.amperage = int(battery["Amperage"])
        s.instantAmperage = int(battery["InstantAmperage"])

        s.designCapacity = int(battery["DesignCapacity"]) ?? int(batteryData["DesignCapacity"])
        s.fullChargeCapacity = int(battery["AppleRawMaxCapacity"]) ?? int(batteryData["FullChargeCapacity"])
        s.nominalChargeCapacity = int(battery["NominalChargeCapacity"]) ?? int(batteryData["NominalChargeCapacity"])
        s.remainingCapacity = int(battery["AppleRawCurrentCapacity"]) ?? int(batteryData["RemainingCapacity"])
        s.cycleCount = int(battery["CycleCount"]) ?? int(packData["CycleCount"])
        s.designCycleCount = int(battery["DesignCycleCount9C"]) ?? int(battery["DesignCycleCount70"])

        // Temperature is in hundredths of a degree Celsius.
        s.temperature = (int(battery["Temperature"]) ?? int(packData["Temperature"])).map { Double($0) / 100 }
        s.virtualTemperature = (int(battery["VirtualTemperature"]) ?? int(packData["VirtualTemperature"])).map { Double($0) / 100 }

        s.timeToFull = validMinutes(int(battery["AvgTimeToFull"])) ?? validMinutes(int(source?[kIOPSTimeToFullChargeKey]))
        s.timeToEmpty = validMinutes(int(battery["AvgTimeToEmpty"])) ?? validMinutes(int(source?[kIOPSTimeToEmptyKey]))

        s.serial = battery["Serial"] as? String ?? battery["BatterySerialNumber"] as? String
        s.deviceName = battery["DeviceName"] as? String
        if let mfg = packData["MfgData"] as? Data ?? battery["ManufacturerData"] as? Data {
            s.mfgStrings = lengthPrefixedStrings(mfg)
        }
        s.manufactureCode = manufactureDate(packData["ManufactureDate"] ?? battery["ManufactureDate"])
        s.chemID = int(packData["ChemID"])
        s.gaugeFirmware = int(packData["GasGaugeFirmwareVersion"])
        s.dailyMinSoc = int(packData["DailyMinSoc"])
        s.dailyMaxSoc = int(packData["DailyMaxSoc"])
        s.healthText = source?["BatteryHealth"] as? String
        s.healthCondition = source?["BatteryHealthCondition"] as? String
        s.optimizedCharging = bool(source?["Optimized Battery Charging Engaged"])
        s.lowPowerMode = bool(source?["LPM Active"])

        if let life = packData["LifetimeData"] as? [String: Any] {
            s.lifetime = LifetimeInfo(
                maxTemperature: int(life["MaximumTemperature"]),
                minTemperature: int(life["MinimumTemperature"]),
                averageTemperature: int(life["AverageTemperature"]).map { Double($0) / 10 },
                maxChargeCurrent: int(life["MaximumChargeCurrent"]),
                maxDischargeCurrent: int(life["MaximumDischargeCurrent"]),
                maxPackVoltage: int(life["MaximumPackVoltage"]),
                minPackVoltage: int(life["MinimumPackVoltage"]),
                operatingTime: int(life["TotalOperatingTime"])
            )
        }

        if !banks.isEmpty {
            s.cells = banks.enumerated().map { index, bank in
                let data = bank["BatteryData"] as? [String: Any] ?? [:]
                return CellInfo(id: int(bank["BankID"]) ?? index, voltage: int(data["CellVoltage"]), qmax: int(data["Qmax"]))
            }
        } else if let voltages = batteryData["CellVoltage"] as? [Any] {
            s.cells = voltages.enumerated().map { CellInfo(id: $0.offset, voltage: int($0.element), qmax: nil) }
        }

        if let t = battery["PowerTelemetryData"] as? [String: Any] {
            s.telemetry = Telemetry(
                systemPowerIn: int(t["SystemPowerIn"]),
                systemVoltageIn: int(t["SystemVoltageIn"]),
                systemCurrentIn: int(t["SystemCurrentIn"]),
                systemLoad: int(t["SystemLoad"]),
                batteryPower: int(t["BatteryPower"]),
                adapterEfficiencyLoss: int(t["AdapterEfficiencyLoss"]),
                wallEnergyEstimate: int(t["WallEnergyEstimate"])
            )
        }

        if let c = battery["ChargerData"] as? [String: Any] {
            s.notChargingReason = int(c["NotChargingReason"])
            s.slowChargingReason = int(c["SlowChargingReason"])
            s.thermallyLimitedTime = int(c["TimeChargingThermallyLimited"])
        }

        if s.externalConnected {
            s.adapter = adapter(registry: battery["AdapterDetails"] as? [String: Any])
        }

        s.pd = PDState.read(battery: battery)
        s.smc = SMCReadings.read()
        s.gaugeUpdateTime = int(battery["UpdateTime"])
        if let ipd = battery["PowerDistribution"] as? [String: Any] {
            s.ipdInputVoltage = int(ipd["IPDInputVoltage"])
            s.ipdInputCurrent = int(ipd["IPDInputCurrent"])
            s.ipdInputPower = int(ipd["IPDInputPower"])
        }
        if let charger = registryProperties(className: "AppleChargerData")?["ChargerData"] as? [String: Any] {
            s.chargerVBUS = int(charger["ChargerVBUS"]).flatMap { $0 > 0 ? $0 : nil }
            s.chargerIBUS = int(charger["ChargerIBUS"]).flatMap { $0 > 0 ? $0 : nil }
            s.chargeTargetCellVoltage = int(charger["ChargingVoltage"]).flatMap { $0 > 0 ? $0 : nil }
            s.chargeCurrentLimit = int(charger["ChargingCurrent"]).flatMap { $0 > 0 ? $0 : nil }
        }

        if includeRaw {
            s.raw = flatten(battery, prefix: "") + flatten(packData, prefix: "Pack.")
        }
        return s
    }

    // MARK: Adapter

    private static func adapter(registry: [String: Any]?) -> AdapterInfo? {
        var merged = registry ?? [:]
        if let ps = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            merged.merge(ps) { _, new in new }
        }
        guard !merged.isEmpty else { return nil }
        var a = AdapterInfo()
        a.watts = int(merged["Watts"])
        a.voltage = int(merged["AdapterVoltage"]) ?? int(merged["Voltage"])
        a.current = int(merged["Current"])
        a.description = merged["Description"] as? String
        a.name = merged["Name"] as? String
        a.manufacturer = merged["Manufacturer"] as? String
        a.model = merged["Model"] as? String
        a.serial = merged["SerialString"] as? String ?? merged["SerialNumber"] as? String
        a.firmware = merged["FwVersion"] as? String
        a.hardware = merged["HwVersion"] as? String
        a.isWireless = bool(merged["IsWireless"])
        a.familyCode = int(merged["FamilyCode"])
        a.powerTier = int(merged["AdapterPowerTier"])
        if let menu = merged["UsbHvcMenu"] as? [[String: Any]] {
            a.profiles = menu.compactMap { item in
                guard let i = int(item["Index"]), let v = int(item["MaxVoltage"]), let c = int(item["MaxCurrent"]) else { return nil }
                return PDProfile(index: i, maxVoltage: v, maxCurrent: c)
            }
        }
        if let idx = int(merged["UsbHvcHvcIndex"]), a.profiles.contains(where: { $0.index == idx }) {
            a.activeProfileIndex = idx
        }
        return a
    }

    // MARK: IOKit helpers

    private static func registryProperties(className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return properties(of: service)
    }

    private static func registryPropertiesAll(className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let props = properties(of: service) { result.append(props) }
            IOObjectRelease(service)
        }
        return result
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    private static func powerSourceDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return desc
            }
        }
        return nil
    }

    // MARK: Value helpers

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        return int(value).map { $0 != 0 }
    }

    /// 65535 and negative values mean "still calculating"; IOPS reports 0 when not applicable.
    private static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65535 else { return nil }
        return value
    }

    /// `MfgData` holds length-prefixed ASCII strings such as "3516", "00A", "ATL".
    static func lengthPrefixedStrings(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var result: [String] = []
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            if (2...16).contains(len), i + len < bytes.count {
                let slice = bytes[(i + 1)...(i + len)]
                if slice.allSatisfy({ (0x20...0x7E).contains($0) }), let str = String(bytes: slice, encoding: .ascii) {
                    result.append(str)
                    i += len + 1
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// Apple Silicon stores the manufacture date as packed ASCII; Intel Macs as a
    /// day/month/year bitfield.
    static func manufactureDate(_ value: Any?) -> String? {
        guard let n = int(value), n > 0 else { return nil }
        if n < 0x10000 {
            let day = n & 0x1F, month = (n >> 5) & 0x0F, year = 1980 + (n >> 9)
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        var bytes: [UInt8] = []
        var v = UInt64(bitPattern: Int64(n))
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }), let str = String(bytes: bytes, encoding: .ascii) {
            return str
        }
        return String(n)
    }

    private static let skippedRawKeys: Set<String> = [
        "IORegistryEntryChildren", "IOGeneralInterest", "IOReportLegend", "PortControllerInfo",
    ]

    private static func flatten(_ dict: [String: Any], prefix: String) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        for key in dict.keys.sorted() where !skippedRawKeys.contains(key) {
            let path = prefix + key
            switch dict[key] {
            case let nested as [String: Any]:
                out += flatten(nested, prefix: path + ".")
            case let array as [Any]:
                for (i, element) in array.prefix(16).enumerated() {
                    if let nested = element as? [String: Any] {
                        out += flatten(nested, prefix: "\(path)[\(i)].")
                    } else {
                        out.append((key: "\(path)[\(i)]", value: describe(element)))
                    }
                }
            case let value?:
                out.append((key: path, value: describe(value)))
            case nil:
                break
            }
        }
        return out
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data:
            let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined()
            return data.count > 32 ? "<\(hex)…> (\(data.count) B)" : "<\(hex)>"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "Yes" : "No" }
            return number.stringValue
        default:
            return "\(value)"
        }
    }
}
