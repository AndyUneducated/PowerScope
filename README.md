# PowerScope

A native macOS battery and charging monitor (Swift 6, SwiftUI, Swift Charts, SwiftData) with a main window and a menu bar panel. The menu bar keeps sampling after the window is closed.

## Data sources
- IOKit `AppleSmartBattery`, `AppleSmartBatteryPack`, `AppleSmartBatteryBank`: voltage, current, capacity, cycle count, temperature, cell voltages, lifetime stats, power telemetry (`PowerTelemetryData`), port controller state (`PortControllerInfo`)
- IOKit `AppleChargerData`: charge target voltage per cell, charge current limit, charger-IC VBUS/IBUS when the Mac reports them
- IOKit `IOPortFeaturePowerIn` → `IOPortFeaturePowerSource`: the power source macOS elected per USB-C port
- SMC (`AppleSMC`, read-only, no root): `VD0R`/`ID0R`/`PDTR` system input, `PSTR` system power, `B0AV`/`B0AC` battery
- `IOPSCopyPowerSourcesInfo` / `IOPSCopyExternalPowerAdapterDetails`: percentage, adapter details

## Precision features
### Negotiated PD voltage
- Source capabilities come from the port controller (`PortControllerPortPDO`) and are decoded per USB PD 3.1: Fixed, Battery, Variable, PPS and AVS. SPR objects take positions 1–7 and EPR objects start at position 8.
- The PDO in use is the power manager's selection (`UsbHvcHvcIndex`, 0-based). The port controller's RDO (`PortControllerActiveContractRdo`) supplies the operating current only when it points to the same PDO; it is not refreshed for every contract (an EPR 28 V contract keeps the last SPR request), so on its own it can be stale. When the RDO does not match, the PDO's current limit is shown instead.
- The contract is cross-checked against the RDO, the PMU input setpoint (`IPDInputVoltage`), the measured system input (within 10 % below / 5 % above) and the source macOS elected (`WinningPowerSourceOption`, which can keep a previous charger's value).
- Port controller counters (attach, hard reset, Source_Capabilities, rejects) are compared every second. Because the firmware keeps counting between samples, every reconnect and renegotiation is logged in the PD timeline even when it happens faster than the polling rate. Repeats within 60 s are folded into one event.

### Charging voltage
- Every voltage is shown with its source and type: setpoint (agreed or requested), measured or derived. "System input" is an internal power rail, not VBUS.
- Readings are taken every second and on IOKit battery notifications. Each stored 5-second window keeps average, minimum and maximum, so short dips are not averaged away.
- Battery voltage prefers SMC `B0AV` (updates every second) over the gauge `Voltage` (updates every few seconds). The gauge's age is shown.
- Consistency checks: gauge pack vs sum of cells (30 mV + 35 mΩ × |I|), gauge vs SMC pack (only when the gauge value is fresh), telemetry vs SMC input (only while input is steady), negotiated vs elected source, input stability, PD link stability, gauge freshness.

## Rules
- Fast charging: battery charging power ≥ 30 W (`BatterySnapshot.fastChargeWatts`); below 10 W counts as slow/trickle charging.
- Charge state is judged by measured battery power, not the `IsCharging` flag, which lags.
- On AC power with the battery discharging is shown as "Adapter insufficient · battery assisting".
- Health = FullChargeCapacity ÷ DesignCapacity; nominal health = NominalChargeCapacity ÷ DesignCapacity.

## History
Readings every second, stored per 5-second window (average, min, max), kept for 7 days in `~/Library/Application Support/PowerScope/history.store` together with the PD event log. Periods when the app was not running show as gaps.

## Build
```
xcodebuild -project PowerScope.xcodeproj -scheme PowerScope -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/PowerScope.app
```
Signing is ad-hoc ("Sign to Run Locally") with App Sandbox off, because the app reads the IOKit registry and the SMC directly. The minimum system version is macOS 15.
`--args -page charging|history|battery|raw` opens the app on a given page.
