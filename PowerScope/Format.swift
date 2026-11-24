import Foundation

nonisolated enum Format {
    static func number(_ value: Double?, digits: Int = 1, unit: String = "") -> String {
        guard let value else { return "—" }
        let text = value.formatted(.number.precision(.fractionLength(digits)))
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    static func signed(_ value: Double?, digits: Int = 1, unit: String = "") -> String {
        guard let value else { return "—" }
        let text = value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always(includingZero: false)))
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    static func int(_ value: Int?, unit: String = "") -> String {
        guard let value else { return "—" }
        return unit.isEmpty ? "\(value)" : "\(value) \(unit)"
    }

    static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func hex(_ value: Int?) -> String {
        guard let value else { return "—" }
        // 32-bit registers arrive sign-extended to 64 bits; show them as 32-bit.
        if Int(Int32.min)...Int(UInt32.max) ~= value {
            return String(format: "0x%X", UInt32(truncatingIfNeeded: value))
        }
        return String(format: "0x%llX", UInt64(bitPattern: Int64(value)))
    }

    static func percent(_ value: Double?) -> String {
        number(value, digits: 1, unit: "%")
    }
}
