import Foundation
import Observation

enum PortSpec {
    /// nmap's top 100 TCP ports.
    static let top100: [UInt16] = [
        7, 9, 13, 21, 22, 23, 25, 26, 37, 53, 79, 80, 81, 88, 106, 110, 111, 113, 119, 135,
        139, 143, 144, 179, 199, 389, 427, 443, 444, 445, 465, 513, 514, 515, 543, 544, 548, 554, 587, 631,
        646, 873, 990, 993, 995, 1025, 1026, 1027, 1028, 1029, 1110, 1433, 1720, 1723, 1755, 1900, 2000, 2001, 2049, 2121,
        2717, 3000, 3128, 3306, 3389, 3986, 4899, 5000, 5009, 5051, 5060, 5101, 5190, 5357, 5432, 5631, 5666, 5800, 5900, 6000,
        6001, 6646, 7070, 8000, 8008, 8009, 8080, 8081, 8443, 8888, 9100, 9999, 10000, 32768, 49152, 49153, 49154, 49155, 49156, 49157,
    ]

    /// Services typical of a home LAN that Internet-derived lists miss: NAS, media servers,
    /// home automation, cameras, printers, TVs and Apple devices.
    static let homeIoT: [UInt16] = [
        21, 22, 23, 53, 80, 81, 139, 443, 445, 548, // FTP, SSH, Telnet, DNS, web, cameras, SMB, AFP
        554, 631, 1400, 1880, 1883, 1900, 3000, 3001, 3689, 5000, // RTSP, IPP, Sonos, Node-RED, MQTT, UPnP, LG TV, DAAP, Synology/AirPlay
        5001, 6053, 7000, 8001, 8002, 8008, 8009, 8060, 8080, 8081, // Synology, ESPHome, AirPlay, Samsung TV, Chromecast, Roku
        8096, 8123, 8443, 8554, 8883, 8888, 9100, 9443, 32400, 49152, // Jellyfin, Home Assistant, RTSP alt, MQTT TLS, printers, Plex, UPnP
        62078, // iPhone/iPad sync
    ]

    /// Parses "22, 80, 8000-8100" into sorted unique ports; nil if any token is invalid.
    static func parse(_ text: String) -> [UInt16]? {
        var ports = Set<UInt16>()
        for token in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let bounds = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let low = UInt16(bounds[0]), low > 0 else { return nil }
            guard let high = bounds.count == 2 ? UInt16(bounds[1]) : low, high >= low else { return nil }
            ports.formUnion(low...high)
        }
        return ports.isEmpty ? nil : ports.sorted()
    }

    /// Compact text for a port list, collapsing consecutive ports: [1, 2, 3, 80] → "1-3, 80".
    static func format(_ ports: [UInt16]) -> String {
        var parts: [String] = []
        var index = 0
        let sorted = Array(Set(ports)).sorted()
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 {
                end += 1
            }
            parts.append(end > index ? "\(sorted[index])-\(sorted[end])" : "\(sorted[index])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }
}

/// A named, user-editable list of ports.
struct PortList: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var ports: String

    var parsedPorts: [UInt16]? { PortSpec.parse(ports) }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var validationError: String? {
        parsedPorts == nil ? "Invalid ports. Example: 22, 80, 8000-8100" : nil
    }
}

/// The user's port lists, persisted. Starts with the built-in presets.
@MainActor
@Observable
final class PortListStore {
    static var builtIn: [PortList] {
        [
            PortList(name: "Top 100", ports: PortSpec.format(PortSpec.top100)),
            PortList(name: "Home/IoT", ports: PortSpec.format(PortSpec.homeIoT)),
            PortList(name: "1–1024", ports: "1-1024"),
            PortList(name: "1–65535", ports: "1-65535"),
        ]
    }

    private(set) var lists: [PortList]
    private let defaults: UserDefaults
    private static let listsKey = "portLists"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lists = Persisted.load([PortList].self, forKey: Self.listsKey, from: defaults).map(Self.renamingLegacyDefaults)
            ?? Self.builtIn
    }

    /// The built-in lists used to have Spanish names; rename them unless the user renamed them.
    private static func renamingLegacyDefaults(_ lists: [PortList]) -> [PortList] {
        let renames = ["100 más comunes": "Top 100", "Hogar/IoT": "Home/IoT"]
        return lists.map { list in
            var list = list
            list.name = renames[list.name] ?? list.name
            return list
        }
    }

    func setLists(_ lists: [PortList]) {
        self.lists = lists
        Persisted.save(lists, forKey: Self.listsKey, to: defaults)
    }

    func list(_ id: PortList.ID?) -> PortList? {
        lists.first { $0.id == id }
    }
}

@MainActor
@Observable
final class PortScanModel {
    struct Result: Identifiable {
        let port: UInt16
        let state: PortState
        /// Set when the port answered an HTTP request (over TLS for https).
        var webURL: URL?
        var id: UInt16 { port }
        var service: String { webURL?.scheme ?? ServiceNames.name(for: port) ?? "" }
    }

    static let timeouts: [TimeInterval] = [0.25, 0.5, 1, 2]

    let lists: PortListStore
    var host = ""
    var selectedListID: PortList.ID?
    var timeout: TimeInterval = 0.5
    var showClosed = false

    private(set) var results: [Result] = []
    private(set) var scannedCount = 0
    private(set) var totalCount = 0
    private(set) var isRunning = false
    private(set) var resolvedAddress: IPv4Address?
    private(set) var elapsed: Duration?
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    /// Lets a finished run tell whether it is still the latest one.
    private var runID = 0

    init(lists: PortListStore) {
        self.lists = lists
        selectedListID = lists.lists.first?.id
    }

    /// Falls back to the first list when the selected one was deleted.
    var selectedList: PortList? {
        lists.list(selectedListID) ?? lists.lists.first
    }

    var openCount: Int { results.count { $0.state == .open } }

    var visibleResults: [Result] {
        showClosed ? results : results.filter { $0.state == .open }
    }

    var progress: Double { totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount) }

    func ports() -> [UInt16]? {
        selectedList?.parsedPorts
    }

    /// Points the scanner at a new host, discarding the previous run.
    func retarget(_ host: String) {
        guard host != self.host else { return }
        stop()
        self.host = host
        results = []
        scannedCount = 0
        totalCount = 0
        resolvedAddress = nil
        elapsed = nil
        errorMessage = nil
    }

    func start() {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        guard let ports = ports() else {
            errorMessage = selectedList.map { "The list “\($0.displayName)” has invalid ports." }
                ?? "No port lists. Create one with the edit button."
            return
        }
        task?.cancel()
        results = []
        scannedCount = 0
        totalCount = ports.count
        resolvedAddress = nil
        elapsed = nil
        errorMessage = nil
        isRunning = true
        runID += 1
        let runID = runID
        task = Task {
            await run(host: host, ports: ports)
            if self.runID == runID { isRunning = false }
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    private func run(host: String, ports: [UInt16]) async {
        let address: IPv4Address
        do {
            address = try await HostResolver.resolveIPv4(host)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        resolvedAddress = address

        let timeout = timeout
        let started = ContinuousClock.now
        await withLimitedConcurrency(ports, limit: 256) { port in
            let state = await TCPProbe.probe(address, port: port, timeout: timeout)
            guard state == .open, let scheme = await WebProbe.detect(address, port: port) else {
                return Result(port: port, state: state)
            }
            return Result(port: port, state: state, webURL: WebProbe.url(scheme, address: address, port: port))
        } onResult: { result in
            // In-flight probes still report after a cancel; they belong to the old run.
            guard !Task.isCancelled else { return }
            scannedCount += 1
            if result.state != .filtered {
                results.append(result)
            }
        }
        guard !Task.isCancelled else { return }
        results.sort { $0.port < $1.port }
        elapsed = ContinuousClock.now - started
    }
}

#if DEBUG
extension PortScanModel {
    /// A finished port scan with the given results, for screenshots.
    func loadDemo(address: IPv4Address, listName: String, results: [Result], elapsed: Duration) {
        stop()
        host = address.description
        resolvedAddress = address
        selectedListID = lists.lists.first { $0.name == listName }?.id ?? selectedListID
        totalCount = ports()?.count ?? results.count
        scannedCount = totalCount
        self.results = results.sorted { $0.port < $1.port }
        self.elapsed = elapsed
        errorMessage = nil
    }
}
#endif
