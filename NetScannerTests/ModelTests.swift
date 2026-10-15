import Foundation
import Testing
@testable import NetScanner

/// End-to-end model runs against loopback. These assert main-actor isolation at runtime,
/// which is how the scan crash (results delivered off the main actor) surfaced.
@MainActor
struct ModelTests {
    @Test func limitedConcurrencyDeliversResultsOnMainActor() async {
        var received = 0
        await withLimitedConcurrency(Array(0..<100), limit: 8) { $0 * 2 } onResult: { _ in
            MainActor.assertIsolated()
            received += 1
        }
        #expect(received == 100)
    }

    /// Fresh defaults per test, and a fake lo0 /30 where we are .2 so the only peer is 127.0.0.1.
    private func makeScanner(_ suite: String, interfaces: [String] = ["lo0"]) -> (ScannerModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let fakes = interfaces.map {
            NetworkInterface(name: $0, address: NetScanner.IPv4Address("127.0.0.2")!,
                             netmask: NetScanner.IPv4Address("255.255.255.252")!, macAddress: nil)
        }
        return (ScannerModel(defaults: defaults, interfaceProvider: { fakes }), defaults)
    }

    private func runAll(_ scanner: ScannerModel) async {
        for task in scanner.startAllInterfaces() { await task.value }
    }

    private func run(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
    }

    @Test func scanFindsLoopbackPeerAndReplacesPreviousResults() async {
        let (scanner, _) = makeScanner(#function)
        await runAll(scanner)
        #expect(scanner.hosts.map(\.address.description).sorted() == ["127.0.0.1", "127.0.0.2"])
        #expect(scanner.hosts.first { $0.address.description == "127.0.0.1" }?.source == .icmp)
        let state = try! #require(scanner.orderedScans.first?.state)
        #expect(state.name == "Interface lo0")
        #expect(state.hostCount == 2)
        #expect(!state.isScanning && !state.foundNothing)

        await runAll(scanner)
        #expect(scanner.hosts.count == 2)
    }

    @Test func savedScansRunOnlyTheirAddressesAndPersist() async {
        let (scanner, defaults) = makeScanner(#function)
        var range = ScanTarget.newRange()
        range.name = "Solo .1"
        range.kind = .range("127.0.0.300")
        #expect(range.validationError != nil)
        #expect(scanner.plan(for: range) == nil)

        // .3 is inside the /30 but outside the range; this Mac (.2) is outside too.
        range.kind = .range("127.0.0.1")
        scanner.setSavedScans([range])
        await run(scanner.start([range]))
        #expect(scanner.hosts.map(\.address.description) == ["127.0.0.1"])
        #expect(scanner.orderedScans.map(\.state.name) == ["Solo .1"])
        #expect(scanner.orderedScans.first?.state.summary == "1 IP")

        #expect(ScannerModel(defaults: defaults, interfaceProvider: { [] }).savedScans == [range])
    }

    @Test func savedScansNeverStoreInterfaces() {
        let (scanner, _) = makeScanner(#function)
        scanner.setSavedScans([.subnet(of: "lo0"), ScanTarget(name: "R", kind: .range("10.0.0.1"))])
        #expect(scanner.savedScans.map(\.name) == ["R"])
    }

    @Test func migratesRangesFromPreviousTargetList() throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Previous format: {id, name, kind, isEnabled} with interface subnets mixed in.
        let legacy = """
        [{"id":"0E8C3A1C-6A3B-4D7B-9E0F-1A2B3C4D5E6F","name":"Subred de en0","kind":{"interfaceSubnet":{"_0":"en0"}},"isEnabled":true},
         {"id":"1E8C3A1C-6A3B-4D7B-9E0F-1A2B3C4D5E6F","name":"Cámaras","kind":{"range":{"_0":"192.168.0.100-120"}},"isEnabled":false}]
        """
        defaults.set(Data(legacy.utf8), forKey: "scanTargets")
        let scanner = ScannerModel(defaults: defaults, interfaceProvider: { [] })
        #expect(scanner.savedScans.map(\.name) == ["Cámaras"])
        #expect(scanner.savedScans.first?.rangeText == "192.168.0.100-120")
    }

    @Test func singleInterfaceScanReplacesPreviousResults() async {
        let (scanner, _) = makeScanner(#function, interfaces: ["a", "b"])
        await runAll(scanner)
        #expect(Set(scanner.hosts.map(\.interface)) == ["a", "b"])
        #expect(scanner.orderedScans.map(\.state.name) == ["Interface a", "Interface b"])

        await run(scanner.start(interface: "b"))
        #expect(Set(scanner.hosts.map(\.interface)) == ["b"])
        #expect(scanner.orderedScans.map(\.state.name) == ["Interface b"])
        #expect(!scanner.isScanningAny)
    }

    @Test func scanRecordsDNSAndWakeNeedsAMAC() async {
        let (scanner, _) = makeScanner(#function)
        await runAll(scanner)
        #expect(!scanner.dnsServers.isEmpty)
        let peer = try! #require(scanner.hosts.first { $0.address.description == "127.0.0.1" })
        #expect(peer.mac == nil)
        #expect(!scanner.wake(peer.id))
    }

    @Test func clearResultsEmptiesHostsButKeepsAnnotations() async {
        let (scanner, _) = makeScanner(#function)
        await runAll(scanner)
        let peer = try! #require(scanner.hosts.first { $0.address.description == "127.0.0.1" })
        scanner.setComment("Keep me", for: peer.id)
        #expect(scanner.hasResults)

        scanner.clearResults()
        #expect(scanner.hosts.isEmpty && scanner.orderedScans.isEmpty && !scanner.hasResults)
        #expect(!scanner.annotations.isEmpty)

        // A scan that was still running must not repopulate the table after clearing.
        let tasks = scanner.startAllInterfaces()
        scanner.clearResults()
        for task in tasks { await task.value }
        #expect(scanner.hosts.isEmpty && !scanner.isScanningAny)
    }

    @Test func annotationsPersistAndOverrideDetectedName() async {
        let (scanner, defaults) = makeScanner(#function)
        await runAll(scanner)
        let peer = try! #require(scanner.hosts.first { $0.address.description == "127.0.0.1" })

        scanner.setCustomName("Router de prueba", for: peer.id)
        scanner.setComment("Rack 2", for: peer.id)
        #expect(scanner.host(peer.id)?.hostname == "Router de prueba")
        #expect(scanner.host(peer.id)?.comment == "Rack 2")

        // A new session re-applies them when the host shows up again (keyed by IP here: no MAC).
        let lo0 = NetworkInterface(name: "lo0", address: NetScanner.IPv4Address("127.0.0.2")!,
                                   netmask: NetScanner.IPv4Address("255.255.255.252")!, macAddress: nil)
        let reloaded = ScannerModel(defaults: defaults, interfaceProvider: { [lo0] })
        await runAll(reloaded)
        #expect(reloaded.host(peer.id)?.customName == "Router de prueba")

        // Clearing the fields removes the stored annotation.
        reloaded.setCustomName("  ", for: peer.id)
        reloaded.setComment("", for: peer.id)
        #expect(reloaded.annotations.isEmpty)
        #expect(reloaded.host(peer.id)?.hostname == reloaded.host(peer.id)?.detectedName)
    }

    @Test func annotationKeyPrefersMAC() {
        var host = DiscoveredHost(interface: "en0", address: NetScanner.IPv4Address("192.168.0.9")!, source: .icmp)
        #expect(HostAnnotation.key(for: host) == "ip:192.168.0.9")
        host.mac = MACAddress("00:11:22:33:44:55")
        #expect(HostAnnotation.key(for: host) == "mac:00:11:22:33:44:55")
    }

    @Test func renamesLegacySpanishDefaultLists() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        Persisted.save([PortList(name: "100 más comunes", ports: "22"), PortList(name: "Mis puertos", ports: "80")],
                       forKey: "portLists", to: defaults)
        #expect(PortListStore(defaults: defaults).lists.map(\.name) == ["Top 100", "Mis puertos"])
    }

    @Test func portListsPersistAndRestore() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = PortListStore(defaults: defaults)
        #expect(store.lists.map(\.name) == ["Top 100", "Home/IoT", "1–1024", "1–65535"])
        #expect(store.lists[0].parsedPorts == PortSpec.top100)
        #expect(store.lists[1].parsedPorts == PortSpec.homeIoT)

        let custom = PortList(name: "Web", ports: "80, 443, 8000-8002")
        store.setLists([custom])
        #expect(PortListStore(defaults: defaults).lists == [custom])

        let model = PortScanModel(lists: store)
        #expect(model.ports() == [80, 443, 8000, 8001, 8002])
        model.selectedListID = UUID()  // deleted list falls back to the first
        #expect(model.selectedList == custom)
    }

    @Test func portScanFindsOpenLoopbackPort() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = PortListStore(defaults: defaults)
        store.setLists([PortList(name: "Bajos", ports: "1-1024")])
        let model = PortScanModel(lists: store)
        model.retarget("127.0.0.1")
        model.showClosed = true
        model.start()
        while model.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.errorMessage == nil)
        #expect(model.scannedCount == 1024)
    }

    @Test func pingSessionCollectsStats() async throws {
        let session = PingSession()
        session.retarget("127.0.0.1")
        session.count = 3
        session.interval = 0.2
        session.start()
        while session.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.stats.sent == 3)
        #expect(session.stats.received == 3)
    }
}
