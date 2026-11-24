import Testing
@testable import PowerScope

/// The situation from a real report: a 100 W charger on USB-C port 3, while ports 1 and 2
/// still carry "[*]" entries from an earlier 94 W charger that are no longer registered.
@Suite("Physical ports")
struct PortsTests {
    private func source(marked: Bool, registered: Bool, watts: Int, current: Int) -> PortSource {
        let winning = ElectedSource(name: "USB-PD", path: "", portNumber: nil, voltage: 20000, current: current, power: watts * 1000)
        return PortSource(name: "USB-PD", marked: marked, registered: registered,
                          options: [.init(voltage: 20000, current: current, power: watts * 1000)], winning: winning)
    }

    @Test func onlyTheRegisteredSourceIsInUse() {
        let port1 = PhysicalPort(name: "Port-USB-C@1", sources: [source(marked: true, registered: false, watts: 94, current: 4700)])
        let port2 = PhysicalPort(name: "Port-USB-C@2", sources: [source(marked: true, registered: false, watts: 94, current: 4700)])
        let port3 = PhysicalPort(name: "Port-USB-C@3", sources: [source(marked: true, registered: true, watts: 100, current: 5000)])

        #expect(port1.inUse == nil)
        #expect(port2.inUse == nil)
        #expect(port1.stale != nil)   // shown as a cached entry, not as a charger
        #expect(port3.inUse?.winning?.power == 100_000)
        #expect(port3.stale == nil)
        #expect([port1, port2, port3].filter { $0.inUse != nil }.count == 1)
    }

    @Test func registeredButUnmarkedIsNotInUse() {
        let port = PhysicalPort(name: "Port-USB-C@3", sources: [source(marked: false, registered: true, watts: 100, current: 5000)])
        #expect(port.inUse == nil)
        #expect(port.stale == nil)
    }

    @Test func displayNames() {
        #expect(PhysicalPort(name: "Port-USB-C@3", sources: []).displayName == "USB C · port 3")
        #expect(PhysicalPort(name: "Port-MagSafe 3@1", sources: []).isMagSafe)
    }
}
