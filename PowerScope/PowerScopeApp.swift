import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep sampling from the menu bar after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct PowerScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = BatteryMonitor()

    var body: some Scene {
        Window("PowerScope", id: "main") {
            ContentView()
                .environment(monitor)
        }
        .defaultSize(width: 1040, height: 760)

        MenuBarExtra {
            MenuBarPanel()
                .environment(monitor)
        } label: {
            MenuBarLabel(snapshot: monitor.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let snapshot: BatterySnapshot

    var body: some View {
        let watts = snapshot.batteryPowerW ?? 0
        let power = abs(watts) >= 0.5 ? " " + Format.signed(watts, digits: 0, unit: "W") : ""
        HStack(spacing: 4) {
            Image(systemName: snapshot.batterySymbol)
            Text("\(snapshot.percent)%\(power)")
        }
    }
}
