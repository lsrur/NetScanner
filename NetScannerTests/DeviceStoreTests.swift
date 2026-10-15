import Foundation
import Testing
@testable import NetScanner

@MainActor
struct DeviceStoreTests {
    private let mac = "mac:00:11:22:33:44:55"
    private func address(_ text: String) -> NetScanner.IPv4Address { NetScanner.IPv4Address(text)! }

    @Test func tracksSightingsAndAddressChanges() throws {
        let store = DeviceStore.inMemory()
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let day3 = day2.addingTimeInterval(86_400)

        // New device: no previous address.
        #expect(store.recordSighting(mac, address: address("192.168.1.20"), at: day1) == nil)
        // Same address again: still nothing to flag.
        #expect(store.recordSighting(mac, address: address("192.168.1.20"), at: day2) == nil)
        // DHCP gave it another one: the old address comes back once.
        #expect(store.recordSighting(mac, address: address("192.168.1.35"), at: day3) == address("192.168.1.20"))
        #expect(store.recordSighting(mac, address: address("192.168.1.35"), at: day3) == nil)

        let device = try #require(store.device(mac))
        #expect(device.firstSeen == day1 && device.lastSeen == day3)
        #expect(store.history(mac) == [
            AddressSighting(address: "192.168.1.35", firstSeen: day3, lastSeen: day3),
            AddressSighting(address: "192.168.1.20", firstSeen: day1, lastSeen: day2),
        ])
    }

    @Test func ipKeyedDevicesNeverFlagAChange() {
        let store = DeviceStore.inMemory()
        store.recordSighting("ip:192.168.1.9", address: address("192.168.1.9"))
        #expect(store.recordSighting("ip:192.168.1.9", address: address("192.168.1.9")) == nil)
    }

    @Test func namesAndCommentsCreateTheDevice() {
        let store = DeviceStore.inMemory()
        store.setName("NAS", for: mac)
        store.setComment("Rack", for: mac)
        #expect(store.device(mac)?.customName == "NAS")
        #expect(store.device(mac)?.comment == "Rack")
        #expect(store.count == 1)
    }

    @Test func importsLegacyUserDefaultsOnce() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        Persisted.save([mac: HostAnnotation(name: "Router", comment: "Hall")], forKey: "hostAnnotations", to: defaults)
        Persisted.save([mac: seen, "ip:10.0.0.7": seen], forKey: "hostFirstSeen", to: defaults)

        let store = DeviceStore.inMemory()
        store.importLegacy(from: defaults)
        let router = try #require(store.device(mac))
        #expect(router.customName == "Router" && router.comment == "Hall" && router.firstSeen == seen)
        #expect(store.history("ip:10.0.0.7").map(\.address) == ["10.0.0.7"])

        // A second import doesn't overwrite later edits.
        store.setName("Main router", for: mac)
        store.importLegacy(from: defaults)
        #expect(store.device(mac)?.customName == "Main router")
    }

    @Test func persistsAcrossContainers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "devices-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        func open() throws -> DeviceStore {
            DeviceStore(container: try .init(for: KnownDevice.self, AddressRecord.self,
                                             configurations: .init(url: url)))
        }
        do {
            let store = try open()
            store.recordSighting(mac, address: address("192.168.1.20"))
            store.setName("NAS", for: mac)
        }
        let reopened = try open()
        #expect(reopened.device(mac)?.customName == "NAS")
        #expect(reopened.device(mac)?.lastAddress == "192.168.1.20")
        #expect(reopened.recordSighting(mac, address: address("192.168.1.21")) == address("192.168.1.20"))
    }
}

struct AddressChangeFilterTests {
    @Test func previousAddressIsSearchable() {
        var host = DiscoveredHost(interface: "en0", address: NetScanner.IPv4Address("192.168.1.35")!, source: .icmp)
        #expect(!HostFilter.matches(host, query: "192.168.1.20"))
        host.previousAddress = NetScanner.IPv4Address("192.168.1.20")
        #expect(HostFilter.matches(host, query: "192.168.1.20"))
        #expect(HostFilter.matches(host, query: "changed"))
    }
}
