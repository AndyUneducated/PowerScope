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

    @Test("Charging speed sets the mode", arguments: [
        (75.0, ChargeMode.veryFastCharging), (60.0, .veryFastCharging), (59.0, .fastCharging), (30.0, .fastCharging),
        (29.0, .charging), (10.1, .charging), (9.0, .slowCharging), (1.0, .slowCharging),
    ])
    func chargingModes(watts: Double, mode: ChargeMode) {
        let s = snapshot(percent: 50, onPower: true, watts: watts)
        #expect(s.mode == mode)
        #expect(s.mode.isCharging)
        #expect(s.tone == .neutral)            // charging needs no attention
        #expect(s.chargingWatts != nil)
        #expect(s.stateColor == ColorScale.speed.color(at: s.chargingWatts!))
    }

    @Test func idleAndFullAreNeutral() {
        let idle = snapshot(percent: 80, onPower: true, watts: 0)
        #expect(idle.tone == .neutral)
        #expect(idle.stateColor == nil)
        #expect(idle.chargingWatts == nil)
        let full = snapshot(percent: 100, onPower: true, watts: 0, full: true)
        #expect(full.tone == .neutral)
        #expect(full.stateColor == ColorScale.green.color)   // full reads as green, like the level ring
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
        #expect(snapshot(percent: 60, onPower: true, watts: -10).stateColor == Tone.attention.color)
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

@Suite("Color scales")
struct ColorScaleTests {
    private func close(_ a: RGB, _ b: RGB) -> Bool {
        abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9
    }

    @Test("Level stops", arguments: [
        (0.0, ColorScale.red), (10.0, ColorScale.red), (20.0, ColorScale.orange),
        (40.0, ColorScale.yellow), (60.0, ColorScale.yellowGreen), (100.0, ColorScale.green),
    ])
    func levelStops(percent: Double, rgb: RGB) {
        #expect(close(ColorScale.level.rgb(at: percent), rgb))
    }

    @Test func levelInterpolatesBetweenStops() {
        // 30 % is halfway from orange to yellow.
        #expect(close(ColorScale.level.rgb(at: 30), ColorScale.orange.mixed(with: ColorScale.yellow, by: 0.5)))
        // Red gets less and green more as the level rises from 20 % to full.
        let reds = stride(from: 20.0, through: 100, by: 5).map { ColorScale.level.rgb(at: $0).r }
        #expect(zip(reds, reds.dropFirst()).allSatisfy { $0 >= $1 })
        let greens = stride(from: 0.0, through: 60, by: 5).map { ColorScale.level.rgb(at: $0).g }
        #expect(zip(greens, greens.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func scalesClampAtBothEnds() {
        #expect(ColorScale.level.rgb(at: -5) == ColorScale.red)
        #expect(ColorScale.level.rgb(at: 120) == ColorScale.green)
        #expect(ColorScale.speed.rgb(at: -1) == ColorScale.paleChartreuse)
        #expect(ColorScale.speed.rgb(at: 140) == ColorScale.electricSky)
    }

    @Test("Speed stops", arguments: [
        (0.0, ColorScale.paleChartreuse), (20.0, ColorScale.green), (40.0, ColorScale.mint),
        (60.0, ColorScale.teal), (80.0, ColorScale.cyan), (100.0, ColorScale.electricSky),
    ])
    func speedStops(watts: Double, rgb: RGB) {
        #expect(close(ColorScale.speed.rgb(at: watts), rgb))
    }

    /// Hue in degrees and saturation (HSV) of a color.
    private func hueAndSaturation(_ c: RGB) -> (hue: Double, saturation: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 0 else { return (0, 0) }
        var h: Double
        if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, d / mx)
    }

    @Test func speedMovesFromChartreuseToSkyAndGetsMoreVivid() {
        let hues = stride(from: 0.0, through: 100, by: 5).map { hueAndSaturation(ColorScale.speed.rgb(at: $0)).hue }
        #expect(zip(hues, hues.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(hues.last! - hues.first! > 100)      // a wide sweep, not shades of one green
        #expect(hueAndSaturation(ColorScale.speed.rgb(at: 0)).saturation
                < hueAndSaturation(ColorScale.speed.rgb(at: 100)).saturation)
        #expect(ColorScale.speed.rgb(at: 100) != RGB(0, 0.48, 1))   // not the charts' input blue
    }
}

@Suite("Battery ring")
struct BatteryRingTests {
    private func snapshot(percent: Int = 50, onPower: Bool, watts: Double, full: Bool = false) -> BatterySnapshot {
        var s = BatterySnapshot()
        s.hasBattery = true
        s.percent = percent
        s.externalConnected = onPower
        s.fullyCharged = full
        s.voltage = 12000
        s.amperage = Int((watts / 12 * 1000).rounded())
        return s
    }

    @Test func innerRingShowsChargingSpeedOnA100WScale() throws {
        let ring = try #require(RingSpeed(snapshot(onPower: true, watts: 45)))
        #expect(abs(ring.fraction - 0.45) < 0.01)
        #expect(!ring.reversed)
        #expect(ring.rgb == ColorScale.speed.rgb(at: snapshot(onPower: true, watts: 45).batteryPowerW!))
        #expect(snapshot(percent: 30, onPower: true, watts: 45).ringCaption == "45 W · Fast")
    }

    @Test func innerRingCapsAtFullScale() throws {
        let ring = try #require(RingSpeed(snapshot(onPower: true, watts: 130)))
        #expect(ring.fraction == 1)
        #expect(ring.rgb == ColorScale.electricSky)
    }

    @Test func innerRingIsHiddenWhenNotCharging() {
        #expect(RingSpeed(snapshot(onPower: false, watts: -15)) == nil)              // on battery
        #expect(RingSpeed(snapshot(percent: 100, onPower: true, watts: 0, full: true)) == nil)
        #expect(RingSpeed(snapshot(percent: 80, onPower: true, watts: 0)) == nil)    // paused
    }

    @Test func assistingDrawsBackwardsInAmber() throws {
        let ring = try #require(RingSpeed(snapshot(onPower: true, watts: -20)))
        #expect(ring.reversed)
        #expect(ring.rgb == ColorScale.orange)
        #expect(abs(ring.fraction - 0.2) < 0.01)
    }

    @Test func captions() {
        #expect(snapshot(onPower: true, watts: 70).ringCaption == "70 W · Very fast")
        #expect(snapshot(onPower: true, watts: 5).ringCaption == "5 W · Trickle")
        #expect(snapshot(percent: 100, onPower: true, watts: 0, full: true).ringCaption == "Full")
        #expect(snapshot(onPower: false, watts: -15).ringCaption == "On battery")
    }
}

@Suite("Power budget legend")
struct PowerBudgetLegendTests {
    @Test func legendSplitsTheBudget() {
        let b = PowerBudget(budget: 100, system: 21.1, battery: 0, assist: 0)
        #expect(b.legend.map(\.label) == ["Mac", "Battery", "Spare"])
        #expect(abs(b.legend[2].watts - 78.9) < 1e-9)
    }

    @Test func spareNeverGoesNegative() {
        let b = PowerBudget(budget: 60, system: 50, battery: 20, assist: 0)
        #expect(b.headroom == 0)
        #expect(b.legend[2].watts == 0)
    }

    @Test func budgetFromSnapshot() throws {
        var s = BatterySnapshot()
        s.hasBattery = true
        s.externalConnected = true
        s.voltage = 12000
        s.amperage = 2500                        // 30 W into the battery
        s.telemetry.systemPowerIn = 50_000       // 50 W from the charger
        s.adapter = AdapterInfo(watts: 100)
        let b = try #require(PowerBudget(s))
        #expect(b.budget == 100)
        #expect(abs(b.battery - 30) < 1e-9)
        #expect(abs(b.system - 20) < 1e-9)
        #expect(abs(b.headroom - 50) < 1e-9)
    }
}
