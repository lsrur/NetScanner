import Foundation
import OSLog
import SwiftData

/// A device NetScanner has found at least once, keyed by MAC (or by IP when it has none, see
/// `HostAnnotation.key`). Holds the user's name and comment and the sighting history.
@Model
final class KnownDevice {
    @Attribute(.unique) var key: String
    var customName: String?
    var comment: String?
    var firstSeen: Date
    var lastSeen: Date
    /// IPv4 address of the latest sighting; a scan that finds the MAC elsewhere flags the change.
    var lastAddress: String?
    @Relationship(deleteRule: .cascade, inverse: \AddressRecord.device)
    var addresses: [AddressRecord] = []

    init(key: String, firstSeen: Date) {
        self.key = key
        self.firstSeen = firstSeen
        lastSeen = firstSeen
    }
}

/// One IPv4 address a device has used, and when.
@Model
final class AddressRecord {
    var address: String
    var firstSeen: Date
    var lastSeen: Date
    var device: KnownDevice?

    init(address: String, seen: Date) {
        self.address = address
        firstSeen = seen
        lastSeen = seen
    }
}

/// A value copy of `AddressRecord` for the UI.
struct AddressSighting: Hashable, Sendable {
    let address: String
    let firstSeen: Date
    let lastSeen: Date
}

/// The SwiftData store of known devices. Everything runs on the main actor (the table and
/// the scanner live there); all devices are loaded once, the store is small.
@MainActor
final class DeviceStore {
    /// Kept alive on purpose: a ModelContext doesn't retain its container, and inserting into a
    /// context whose container was released traps.
    private let container: ModelContainer
    private let context: ModelContext
    private var devices: [String: KnownDevice] = [:]
    private static let log = Logger(subsystem: "com.lautarosrur.NetScanner", category: "DeviceStore")

    init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
        context.autosaveEnabled = false
        let all = (try? context.fetch(FetchDescriptor<KnownDevice>())) ?? []
        devices = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `Application Support/NetScanner/Devices.store` inside the sandbox container. Falls back to
    /// memory if the file can't be opened, so the app still works (without history).
    static func persistent() -> DeviceStore {
        let directory = URL.applicationSupportDirectory.appending(path: "NetScanner", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = ModelConfiguration(url: directory.appending(path: "Devices.store"))
            return DeviceStore(container: try ModelContainer(for: KnownDevice.self, AddressRecord.self,
                                                             configurations: configuration))
        } catch {
            log.error("Couldn't open the device store: \(error.localizedDescription, privacy: .public)")
            return inMemory()
        }
    }

    static func inMemory() -> DeviceStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return DeviceStore(container: try! ModelContainer(for: KnownDevice.self, AddressRecord.self,
                                                          configurations: configuration))
    }

    var count: Int { devices.count }

    func device(_ key: String) -> KnownDevice? { devices[key] }

    /// The device's addresses, most recent first.
    func history(_ key: String) -> [AddressSighting] {
        (devices[key]?.addresses ?? [])
            .map { AddressSighting(address: $0.address, firstSeen: $0.firstSeen, lastSeen: $0.lastSeen) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: Names and comments

    func setName(_ name: String?, for key: String) {
        existingOrNew(key).customName = name
        save()
    }

    func setComment(_ comment: String?, for key: String) {
        existingOrNew(key).comment = comment
        save()
    }

    // MARK: Sightings

    /// Records that the device answered at `address` and returns the address it had before,
    /// if it was a different one. Only MAC-keyed devices can change address: an IP key *is*
    /// the address.
    @discardableResult
    func recordSighting(_ key: String, address: IPv4Address, at date: Date = .now) -> IPv4Address? {
        let device = existingOrNew(key, seen: date)
        let current = address.description
        let previous = device.lastAddress.flatMap { $0 == current ? nil : IPv4Address($0) }
        device.lastSeen = max(device.lastSeen, date)
        device.lastAddress = current
        if let record = device.addresses.first(where: { $0.address == current }) {
            record.lastSeen = max(record.lastSeen, date)
        } else {
            let record = AddressRecord(address: current, seen: date)
            context.insert(record)
            device.addresses.append(record)
        }
        return key.hasPrefix("mac:") ? previous : nil
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Self.log.error("Couldn't save the device store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func existingOrNew(_ key: String, seen date: Date = .now) -> KnownDevice {
        if let device = devices[key] { return device }
        let device = KnownDevice(key: key, firstSeen: date)
        context.insert(device)
        devices[key] = device
        return device
    }

    // MARK: Migration

    /// Imports names, comments and first-seen dates that v0.2 and earlier kept in UserDefaults.
    /// Runs once; the old keys are left in place so an older version still finds them.
    func importLegacy(from defaults: UserDefaults) {
        let doneKey = "deviceStoreImported"
        guard !defaults.bool(forKey: doneKey) else { return }
        let annotations = Persisted.load([String: HostAnnotation].self, forKey: "hostAnnotations", from: defaults) ?? [:]
        let firstSeen = Persisted.load([String: Date].self, forKey: "hostFirstSeen", from: defaults) ?? [:]
        for key in Set(annotations.keys).union(firstSeen.keys) {
            let device = existingOrNew(key, seen: firstSeen[key] ?? .now)
            if let date = firstSeen[key] {
                device.firstSeen = min(device.firstSeen, date)
                device.lastSeen = max(device.lastSeen, date)
            }
            device.customName = device.customName ?? annotations[key]?.name
            device.comment = device.comment ?? annotations[key]?.comment
            // An IP key also tells the address it was seen at.
            if key.hasPrefix("ip:"), device.addresses.isEmpty, let address = IPv4Address(String(key.dropFirst(3))) {
                recordSighting(key, address: address, at: device.firstSeen)
            }
        }
        save()
        defaults.set(true, forKey: doneKey)
    }
}
