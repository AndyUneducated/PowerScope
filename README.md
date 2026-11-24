<div align="center">

# ⚡ PowerScope

**A native macOS battery and USB-C Power Delivery monitor that tells you what your charger actually negotiated, and whether the numbers can be trusted.**

![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Charts%20%7C%20Observation-0A84FF?logo=swift&logoColor=white)
![SwiftData](https://img.shields.io/badge/SwiftData-history-5E5CE6)
![IOKit](https://img.shields.io/badge/IOKit-AppleSmartBattery-555555?logo=apple&logoColor=white)
![SMC](https://img.shields.io/badge/SMC-read--only-555555?logo=apple&logoColor=white)
![USB PD](https://img.shields.io/badge/USB%20PD-3.1%20%C2%B7%20EPR-34C759)
![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-27-1575F9?logo=xcode&logoColor=white)
![Tests](https://img.shields.io/badge/tests-32%20passing-34C759)

<img src="docs/screenshots/overview.png" width="760" alt="Overview">

</div>

---

## ✨ Features

### 🔋 Battery
- 💚 **Health**: full charge ÷ design capacity, plus nominal health and Apple's 80 % service threshold
- 🔁 **Cycles**: cycle count against the rated cycle life
- 🌡️ **Temperature**: current, virtual and lifetime min / max / average
- 🧱 **Cells**: per cell-group voltage and Qmax, with the voltage spread between groups
- 🏷️ **Identity**: serial, gauge chip, cell vendor, manufacture code, chemistry ID, gauge firmware

### 🔌 Charging and USB-C PD
- 🤝 **Negotiated contract**: the PDO actually in use (Fixed, PPS, AVS, including EPR 28 V), with voltage, current and power
- 🧮 **Source capabilities**: every PDO the charger offers, decoded per USB PD 3.1, with source flags
- ✅ **Cross-check**: the contract is compared with four other places macOS reports it
- 📡 **Voltage sources**: every voltage labeled as measured, setpoint or derived, with where it comes from
- 🩺 **Consistency checks**: pack vs cells, gauge vs SMC, telemetry vs SMC, input stability, link stability, data freshness
- 🔗 **PD link health**: reconnects, hard resets, renegotiations and rejected requests, logged even between samples
- 🚀 **Fast charging**: judged by measured battery power (≥ 30 W), not by the `IsCharging` flag

### 📈 History
- ⏱️ Readings every **1 s**, stored per **5 s window** with average, minimum and maximum
- 🗓️ Kept for **7 days** in SwiftData, together with the PD event log
- 📊 Charts for power, current, battery voltage, input voltage (with the negotiated contract), charge and temperature
- 🕳️ Periods when the app was not running show as gaps, not as straight lines

### 🧭 App
- 🪟 Main window with Overview, Charging, History, Battery Health and Raw Data pages
- 📍 Menu bar item with percentage and live battery power, and a panel with the key numbers
- 💤 Keeps sampling from the menu bar after the window closes, at about 1.8 % of one core

---

## 📸 Screenshots

| Charging | Charging details |
| :---: | :---: |
| <img src="docs/screenshots/charging.png" width="420"> | <img src="docs/screenshots/charging-details.png" width="420"> |
| **Battery health** | **History** |
| <img src="docs/screenshots/battery.png" width="420"> | <img src="docs/screenshots/history.png" width="420"> |
| **Light mode** | **Menu bar** |
| <img src="docs/screenshots/overview-light.png" width="420"> | <img src="docs/screenshots/menubar.png" width="260"> |

---

## 🏗️ Architecture

```mermaid
flowchart TB
    subgraph Sources["🍎 macOS data sources"]
        direction LR
        B["AppleSmartBattery<br/>Pack · Bank · Cells"]
        PC["PortControllerInfo<br/>PDOs · RDO · counters"]
        CH["AppleChargerData"]
        PS["IOPortFeaturePowerSource"]
        IOPS["IOPowerSources"]
        SMC["AppleSMC<br/>VD0R · B0AV · PDTR"]
    end

    subgraph Read["📥 Reading"]
        direction LR
        BR["BatteryReader"]
        PD["PDState + PDDecoder"]
        RES["PDContractResolver"]
        SR["SMCReadings"]
    end

    subgraph Core["🧠 State"]
        direction LR
        SNAP["BatterySnapshot<br/>+ cross-checks"]
        MON["BatteryMonitor<br/>@Observable · 1 Hz + IOKit notifications"]
        EV["PD event tracker"]
        WIN["5 s window<br/>avg · min · max"]
    end

    subgraph Store["💾 SwiftData"]
        direction LR
        PSM["PowerSample"]
        PDE["PDEvent"]
    end

    subgraph UI["🖥️ SwiftUI"]
        direction LR
        MAIN["Main window<br/>5 pages"]
        MB["Menu bar<br/>label + panel"]
        TH["Theme<br/>color rules"]
    end

    B --> BR
    CH --> BR
    IOPS --> BR
    PC --> PD
    PS --> PD
    SMC --> SR
    PD --> RES
    BR --> SNAP
    RES --> SNAP
    SR --> SNAP
    SNAP --> MON
    MON --> EV --> PDE
    MON --> WIN --> PSM
    PSM --> MON
    PDE --> MON
    MON --> MAIN
    MON --> MB
    TH -.-> MAIN
    TH -.-> MB
```

### 🧩 Modules
- 📥 **`BatteryReader`**: copies each IOKit registry entry in one call, so all values come from the same instant
- 🔬 **`PDDecoder`**: pure USB PD 3.1 decoding of PDOs and RDOs (Fixed, Battery, Variable, PPS, EPR AVS, SPR AVS)
- 🧭 **`PDContractResolver`**: decides which contract is in use (see below)
- 🗂️ **`PDState`**: port controllers, the source macOS elected, and the cross-checks
- 🎛️ **`SMC`**: minimal read-only AppleSMC client (no root needed on Apple Silicon)
- 🫀 **`BatteryMonitor`**: 1 Hz polling plus battery notifications, live 3-minute buffer, 5 s windows, PD event log, retention
- 🎨 **`Theme`**: the single source of every color in the app
- 🖥️ **`Views/`**: pages, charts and the menu bar panel; views stop observing data while their window is hidden

---

## 🎯 How accuracy works

### 🤝 Which PD contract is in use
macOS reports the contract in several places, and none is reliable alone:

| Source | What it gives | Caveat |
| --- | --- | --- |
| 🧭 Power manager (`UsbHvcHvcIndex`) | Which PDO is selected | Reads 255 while the link re-attaches |
| 📟 PMU setpoint (`IPDInputVoltage`) | The input voltage the system is configured for | Falls back to 5 V without a contract |
| 📨 Port controller RDO | The request, including operating current | Lags: kept the old 20 V request for minutes after an EPR 28 V contract started |
| 🗳️ Elected source (`WinningPowerSourceOption`) | macOS's chosen option per port | Can keep a previous charger's value |

`PDContractResolver` uses them in this order:
1. 🥇 The power manager's selection, on a port where that PDO agrees with the PMU setpoint
2. 🥈 Otherwise the PDO whose voltage matches the PMU setpoint
3. 🥉 Otherwise the RDO, flagged as unconfirmed

Then:
- 🔢 PDO positions follow the spec: SPR objects at 1–7, EPR objects from 8
- 🧷 The RDO supplies the operating current only when it names the same PDO; otherwise the PDO limit is shown as `≤`
- 🎚️ PPS / AVS voltages come from a matching RDO or the PMU, never from the PDO maximum

### 📡 Which voltage is real
- 🔵 **Setpoints**: negotiated VBUS, elected VBUS, PMU input setpoint, charge target per cell
- 🟢 **Measured**: system input (telemetry and SMC `VD0R`), battery pack (gauge and SMC `B0AV`)
- ⚪ **Derived**: sum of cell groups
- ℹ️ The system input is an internal rail behind the input switches, not VBUS; it reads slightly below the negotiated voltage under load
- ℹ️ This Mac does not report a measured VBUS (`ChargerVBUS` is 0), and the app says so instead of guessing

### 🩺 Consistency checks
- 🔋 Gauge pack vs sum of cells: within 30 mV + 35 mΩ × |I|
- 🔄 Gauge pack vs SMC pack: only when the gauge value is under 2 s old
- 🔌 Telemetry input vs SMC input: only while the input is steady
- 🤝 Negotiated vs elected source
- 📉 Input stability over the last 30 s
- 🔗 PD link stability over the last 10 minutes
- ⏳ Gauge data freshness

---

## 🎨 Colors

One rule, defined in `Theme.swift`: **a color says where energy flows and whether anything needs attention.**

| Color | Meaning | Examples |
| --- | --- | --- |
| 🟢 Green | Energy flowing into the battery, brighter when faster | Fast ≥ 30 W, charging, trickle < 10 W |
| ⚪ Neutral | Normal and calm | Plugged in and paused, full (green check), on battery above 20 % |
| 🟠 Amber | Needs attention | Battery assisting a weak adapter, ≤ 20 % on battery, PD link problems |
| 🔴 Red | Act now | ≤ 10 % on battery, critical level |

- 📊 **Chart series** are colored by source everywhere: 🔵 supply side, 🟢 battery, 🟣 system load, ⚪ temperature
- 🧮 **Metric tiles** stay neutral and only turn amber or red when a value is off (temperature ≥ 40 / 45 °C, health < 80 %, cycles past design)
- 🎛️ The app follows the system accent color

---

## ⚙️ Performance
- 📥 One full read costs under 1 ms; reading only selected keys would save about 0.07 ms and lose the single-instant snapshot
- 💤 SwiftUI keeps closed windows and the menu bar panel alive, so views stop observing data while hidden
- 🗃️ The Raw Data list is built only while that page is open
- 📏 Measured on the Release build: **~1.8 %** of one core in the background, **~2.8 %** with the main window open

---

## 🧪 Tests
Swift Testing suites in `PowerScopeTests/`, replaying PD data captured from a real Mac with Apple's 140 W adapter over three cables:
- 🔬 PDO / RDO decoding: 60 W, 94 W and 140 W objects, EPR AVS, PPS, source flags, EPR positions
- 🧭 Contract resolution: stale RDO, RDO catching up, 5 V fallback, stale power budget, PMU vs selection, AVS, PPS, RDO-only
- ✅ Cross-checks for the EPR case
- 🎨 Color rules: charging speed, battery thresholds, battery assisting, reading levels
- 📊 History downsampling, formatting and registry parsing

```bash
xcodebuild test -project PowerScope.xcodeproj -scheme PowerScope -destination 'platform=macOS'
```

---

## 🛠️ Build and run

```bash
xcodebuild -project PowerScope.xcodeproj -scheme PowerScope -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/PowerScope.app
```

- 🔏 Signed ad hoc ("Sign to Run Locally"); App Sandbox is off because the app reads the IOKit registry and the SMC directly
- 🍏 Requires macOS 15 or later on Apple Silicon
- 🧭 `open PowerScope.app --args -page charging` opens a given page (`overview`, `charging`, `history`, `battery`, `raw`)

---

## 📁 Project structure

```
PowerScope/
├── PowerScopeApp.swift          App, window and menu bar scenes
├── BatteryMonitor.swift         Polling, live buffer, 5 s windows, PD events, persistence
├── BatteryReader.swift          IOKit and IOPowerSources reading
├── BatterySnapshot.swift        One reading and its derived values
├── PowerSample.swift            SwiftData models (PowerSample, PDEvent)
├── Theme.swift                  Color rules
├── Format.swift                 Number and time formatting
├── PowerDelivery/
│   ├── PDDecoder.swift          USB PD 3.1 PDO / RDO decoding
│   ├── PDContractResolver.swift Which contract is in use
│   ├── PDState.swift            Port controllers, elected source, cross-checks
│   └── SMC.swift                Read-only AppleSMC client
└── Views/                       Pages, charts, menu bar panel, components
PowerScopeTests/                 Swift Testing suites
docs/screenshots/                Screenshots used in this README
```

---

## ⚠️ Limitations
- 🔌 The registry does not say whether the source is on USB-C or MagSafe 3, so the type reads "USB PD"
- 📏 Without a measured VBUS, the true adapter output voltage needs an external USB-C meter to verify
- 🍎 Relies on undocumented IOKit keys and SMC keys that Apple may change between macOS releases
