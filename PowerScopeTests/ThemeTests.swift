import Testing
@testable import PowerScope

@Suite("Color rules")
struct ThemeTests {
    /// A snapshot with the given battery power (W, + charging) at 12 V.
    private func snapshot(percent: Int, onPower: Bool, watts: Double, full: Bool = false) -> BatterySnapshot {
        var s = BatterySnapshot()
        s.hasBattery = true
        s.percent = percent
        s.externalConnected = onPower
        s.fullyCharged = full
        s.voltage = 12000
        s.amperage = Int(watts / 12 * 1000)
        return s
    }

    @Test("Green only while energy flows into the battery, brighter when faster", arguments: [
        (45.0, Tone.chargingFast), (20.0, Tone.charging), (5.0, Tone.chargingSlow),
    ])
    func charging(watts: Double, tone: Tone) {
        #expect(snapshot(percent: 50, onPower: true, watts: watts).tone == tone)
    }

    @Test func idleAndFullAreNeutral() {
        #expect(snapshot(percent: 80, onPower: true, watts: 0).tone == .neutral)
        let full = snapshot(percent: 100, onPower: true, watts: 0, full: true)
        #expect(full.tone == .neutral)
        #expect(full.statusSymbolColor == Tone.chargingFast.color)   // the check mark stays green
    }

    @Test("On battery is neutral until the level is low", arguments: [
        (60, Tone.neutral), (21, Tone.neutral), (20, Tone.attention), (11, Tone.attention), (10, Tone.critical), (3, Tone.critical),
    ])
    func onBattery(percent: Int, tone: Tone) {
        #expect(snapshot(percent: percent, onPower: false, watts: -15).tone == tone)
    }

    @Test func batteryAssistingNeedsAttention() {
        #expect(snapshot(percent: 60, onPower: true, watts: -10).tone == .attention)
        #expect(snapshot(percent: 8, onPower: true, watts: -10).tone == .critical)
    }

    @Test func readingLevels() {
        #expect(ReadingLevel.temperature(35) == .normal)
        #expect(ReadingLevel.temperature(41) == .attention)
        #expect(ReadingLevel.temperature(46) == .critical)
        #expect(ReadingLevel.health(96.6) == .normal)
        #expect(ReadingLevel.health(79) == .attention)
        #expect(ReadingLevel.cycles(25, design: 1000) == .normal)
        #expect(ReadingLevel.cycles(1000, design: 1000) == .attention)
    }
}

@Suite("Battery current source")
struct BatteryCurrentTests {
    /// Captured right after plugging back in: the gauge still reported −1.474 A from the
    /// unplugged period for over 30 s while the SMC showed the battery idle.
    @Test func smcWinsOverAStaleGauge() {
        var s = BatterySnapshot()
        s.hasBattery = true
        s.externalConnected = true
        s.percent = 100
        s.fullyCharged = true
        s.voltage = 13007
        s.amperage = -1474
        s.smc.batteryVoltage = 13.093
        s.smc.batteryCurrent = 0
        #expect(s.currentA == 0)
        #expect(s.batteryPowerW == 0)
        #expect(s.gaugeCurrentA == -1.474)
        #expect(s.mode == .full)            // not "battery assisting"
    }

    /// If the SMC's sign ever disagreed with the energy balance, the gauge is used instead.
    @Test func energyBalanceGuardsTheSign() {
        var s = BatterySnapshot()
        s.externalConnected = true
        s.voltage = 12000
        s.amperage = 2500                     // gauge: charging
        s.telemetry.systemPowerIn = 60_000    // 60 W in
        s.telemetry.systemLoad = 30_000       // 30 W used, so about 30 W into the battery
        s.smc.batteryCurrent = -2.5           // contradicts the balance
        #expect(s.currentA == 2.5)
        s.smc.batteryCurrent = 2.4            // agrees
        #expect(s.currentA == 2.4)
    }

    @Test func gaugeIsTheFallback() {
        var s = BatterySnapshot()
        s.voltage = 12000
        s.amperage = 2500
        #expect(s.currentA == 2.5)
        #expect(s.batteryPowerW == 30)
    }
}
