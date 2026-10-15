import CoreLocation
import Foundation
import Observation

/// The Wi-Fi Analyzer section: scans every few seconds while it's shown and keeps each
/// access point's signal history for the session.
@MainActor
@Observable
final class WiFiAnalyzerModel {
    struct Sample: Equatable, Sendable {
        let date: Date
        let rssi: Int
    }

    struct Network: Identifiable, Equatable {
        /// BSSID, or a best-effort key without Location access.
        let id: String
        var latest: WiFiObservation
        var samples: [Sample] = []
        var firstSeen: Date
        var lastSeen: Date
        /// Order of discovery; picks the network's color.
        let colorIndex: Int
        var isConnected = false
        /// Consecutive real scans that didn't report it.
        var missedScans = 0

        var ssidText: String { latest.ssid.map { $0.isEmpty ? "[Hidden SSID]" : $0 } ?? (latest.bssid == nil ? "—" : "[Hidden SSID]") }
        var bssidText: String { latest.bssid ?? "" }
        var vendorText: String {
            guard let bssid = latest.bssid, let mac = MACAddress(bssid) else { return "" }
            return OUIDatabase.vendor(for: mac) ?? String(mac.description.prefix(8)).uppercased()
        }
        var rssi: Int { latest.rssi }
        var average: Double { samples.isEmpty ? Double(rssi) : Double(samples.map(\.rssi).reduce(0, +)) / Double(samples.count) }
        var maximum: Int { samples.map(\.rssi).max() ?? rssi }
        var minimum: Int { samples.map(\.rssi).min() ?? rssi }
        var channel: Int { latest.channel }
        var bandText: String { latest.band.rawValue }
        var bandSortKey: Int { [WiFiBand.ghz2, .ghz5, .ghz6, .unknown].firstIndex(of: latest.band) ?? 9 }
        var width: Int { latest.width }
        var security: String { latest.security }
        var modes: String { latest.modes }
        var noise: Int { latest.noise }
    }

    enum BandFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case ghz2 = "2.4 GHz"
        case ghz5 = "5 GHz"
        case ghz6 = "6 GHz"
        var id: Self { self }

        func includes(_ band: WiFiBand) -> Bool {
            switch self {
            case .all: true
            case .ghz2: band == .ghz2
            case .ghz5: band == .ghz5
            case .ghz6: band == .ghz6
            }
        }
    }

    static let maxSamples = 360
    /// A single scan misses about a quarter of the networks around (short dwell per channel,
    /// DFS channels), even strong ones; only this many misses in a row mean out of range.
    static let missesBeforeOutOfRange = 3
    /// macOS rate-limits scans and answers early ones from its cache, almost instantly and with
    /// the previous values; those add nothing and would flatten the history.
    static let cachedScanDuration: TimeInterval = 1
    /// Networks checked automatically when first found, if strong enough.
    static let autoCheckThreshold = -70
    static let autoCheckLimit = 8

    private(set) var networks: [Network] = []
    /// Networks drawn in the signal chart.
    var checked: Set<Network.ID> = []
    var interval: TimeInterval = 5
    var bandFilter = BandFilter.all

    private(set) var isRunning = false
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var link: WiFiLink?
    private(set) var errorMessage: String?
    let location = LocationAccess()
    private var task: Task<Void, Never>?
    private var isFrozen = false

    /// Fictional demo data doesn't need Location access.
    var needsLocationAccess: Bool { !isFrozen && !location.isGranted }

    var visibleNetworks: [Network] { networks.filter { bandFilter.includes($0.latest.band) } }

    /// Whether the network answered one of the last few scans.
    func isInRange(_ network: Network) -> Bool {
        network.missedScans < Self.missesBeforeOutOfRange
    }

    func start() {
        guard !isFrozen, !isRunning else { return }
        location.requestIfNeeded()
        isRunning = true
        task = Task {
            while !Task.isCancelled {
                isScanning = true
                let started = Date.now
                let result = await Task.detached { Result { try WiFiScanner.scan() } }.value
                isScanning = false
                guard !Task.isCancelled else { break }
                switch result {
                case .success(let (observations, link)):
                    errorMessage = nil
                    let isCached = Date.now.timeIntervalSince(started) < Self.cachedScanDuration
                    if isCached, lastScan != nil {
                        self.link = link
                    } else {
                        merge(observations, link: link, at: .now)
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        isScanning = false
    }

    func clear() {
        networks = []
        checked = []
        lastScan = nil
    }

    /// Folds one scan into the history.
    func merge(_ observations: [WiFiObservation], link: WiFiLink?, at date: Date) {
        self.link = link
        lastScan = date
        // Once BSSIDs arrive (Location access granted), rows keyed without one are duplicates.
        if observations.contains(where: { $0.bssid != nil }) {
            let anonymous = Set(networks.filter { $0.latest.bssid == nil }.map(\.id))
            networks.removeAll { anonymous.contains($0.id) }
            checked.subtract(anonymous)
        }
        var seen = Set<Network.ID>()
        for observation in observations {
            var id = Self.key(for: observation)
            // Without BSSIDs two APs can share a key; keep them apart within one scan.
            var suffix = 2
            while seen.contains(id) {
                id = Self.key(for: observation) + "#\(suffix)"
                suffix += 1
            }
            seen.insert(id)
            let sample = Sample(date: date, rssi: observation.rssi)
            if let index = networks.firstIndex(where: { $0.id == id }) {
                networks[index].latest = observation
                networks[index].lastSeen = date
                networks[index].missedScans = 0
                networks[index].samples.append(sample)
                if networks[index].samples.count > Self.maxSamples {
                    networks[index].samples.removeFirst(networks[index].samples.count - Self.maxSamples)
                }
            } else {
                networks.append(Network(id: id, latest: observation, samples: [sample], firstSeen: date,
                                        lastSeen: date, colorIndex: networks.count))
                if observation.rssi >= Self.autoCheckThreshold, checked.count < Self.autoCheckLimit {
                    checked.insert(id)
                }
            }
        }
        for index in networks.indices where !seen.contains(networks[index].id) {
            networks[index].missedScans += 1
        }
        for index in networks.indices {
            networks[index].isConnected = link?.bssid != nil && networks[index].latest.bssid == link?.bssid
        }
    }

    static func key(for observation: WiFiObservation) -> String {
        observation.bssid ?? "\(observation.ssid ?? "?")|\(observation.channel)|\(observation.security)|\(observation.modes)"
    }
}

#if DEBUG
extension WiFiAnalyzerModel {
    /// Fictional scans for screenshots; real scanning stays off.
    func loadDemo(_ scans: [(Date, [WiFiObservation])], link: WiFiLink?) {
        stop()
        isFrozen = true
        clear()
        for (date, observations) in scans {
            merge(observations, link: link, at: date)
        }
    }
}
#endif

/// Location Services permission: macOS hides SSIDs and BSSIDs from apps without it.
@MainActor
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isGranted: Bool { status == .authorizedAlways || status == .authorized }
    var isDenied: Bool { status == .denied || status == .restricted }

    func requestIfNeeded() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
