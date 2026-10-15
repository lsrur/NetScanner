import Foundation
import Observation

/// The same address can show up on two interfaces attached to the same network.
struct HostID: Hashable, Sendable {
    let interface: String
    let address: IPv4Address
}

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case local = "This Mac"
        case icmp = "ICMP"
        case tcp = "TCP"
        case arp = "ARP"
    }

    let interface: String
    let address: IPv4Address
    var source: Source
    var latency: Double?
    var mac: MACAddress?
    var ipv6LinkLocal: [String] = []
    /// Global and unique-local addresses (a device often has a stable one plus temporary ones).
    var ipv6Global: [String] = []
    var vendor: String?
    /// Only set for this Mac (its user-facing computer name).
    var computerName: String?
    var bonjourName: String?
    var netbiosName: String?
    var dnsName: String?
    /// From the user's saved annotation.
    var customName: String?
    var comment: String?
    /// Identity evidence: advertised Bonjour services, UPnP description, web page title.
    var services: [BonjourService] = []
    var upnp: UPnPDevice?
    var webTitle: String?
    var isGateway = false
    /// Only set for this Mac (`hw.model`, e.g. "MacBookPro18,2").
    var hardwareModel: String?
    /// When NetScanner first found this device (by MAC, or IP without one), across sessions.
    var firstSeen: Date?

    /// The name a device gives itself in its services ("Living Room", "Kitchen speaker").
    var advertisedName: String? {
        for type in ["_googlecast._tcp", "_airplay._tcp", "_device-info._tcp", "_raop._tcp", "_hap._tcp"] {
            guard let service = services.first(where: { $0.type == type }) else { continue }
            if let friendly = service.txt["fn"], !friendly.isEmpty { return friendly }
            // RAOP instances are "MACADDRESS@Name".
            let name = service.name.split(separator: "@", maxSplits: 1).last.map(String.init) ?? service.name
            if !name.isEmpty { return name }
        }
        return nil
    }

    var detectedName: String? {
        computerName ?? advertisedName ?? bonjourName ?? netbiosName ?? upnp?.friendlyName ?? dnsName
    }
    var hostname: String? { customName ?? detectedName }
    var kind: DeviceKind { DeviceClassifier.kind(for: self) }
    var model: String? { DeviceClassifier.model(for: self) }

    var id: HostID { HostID(interface: interface, address: address) }

    // Non-optional keys for Table sorting.
    var macText: String { mac?.description ?? "" }
    var ipv6LinkLocalText: String { ipv6LinkLocal.first ?? "" }
    var ipv6GlobalText: String { ipv6Global.first ?? "" }
    var vendorText: String { vendor ?? "" }
    var hostnameText: String { hostname ?? "" }
    var commentText: String { comment ?? "" }
    var kindText: String { kind.rawValue }
    var modelText: String { model ?? "" }
    var latencySortKey: Double { latency ?? .infinity }
    var firstSeenSortKey: Date { firstSeen ?? .distantFuture }
}

struct ScanState: Sendable {
    let name: String
    let interface: String
    var isScanning = false
    var progress = 0.0
    /// What is being scanned, e.g. "192.168.0.0/24" or "21 IPs".
    var summary: String?
    var notice: String?
    var completedAt: Date?
    var hostCount = 0
    var gateway: IPv4Address?
    /// Nothing but ourselves answered: most likely Local Network access was denied.
    var foundNothing = false
}

@MainActor
@Observable
final class ScannerModel {
    /// Larger subnets are narrowed to the /24 around the interface address.
    static let minimumPrefixLength = 22
    nonisolated static let discoveryPorts: [UInt16] = [80, 443, 22, 445, 62078]

    private(set) var interfaces: [NetworkInterface] = []
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var scans: [ScanTarget.ID: ScanState] = [:]
    /// Resolvers in use, read when a scan starts.
    private(set) var dnsServers: [String] = []
    /// Targets of the current/last run, in launch order.
    private var runOrder: [ScanTarget.ID] = []
    /// Named ranges from "Personalizar…", persisted. Interfaces are not stored: they come and go.
    private(set) var savedScans: [ScanTarget]
    /// Host names and comments, persisted, keyed by `HostAnnotation.key(for:)`.
    private(set) var annotations: [String: HostAnnotation]
    /// When each device was first found, persisted, keyed like the annotations.
    private(set) var firstSeen: [String: Date]
    private let defaults: UserDefaults
    private let interfaceProvider: () -> [NetworkInterface]
    private var tasks: [ScanTarget.ID: Task<Void, Never>] = [:]
    /// Bumped on every run so results from a cancelled run are dropped instead of mixed in.
    private var generation = 0

    private static let savedScansKey = "savedScans"
    /// Previous format: interface and range targets mixed; only the ranges carry over.
    private static let legacyTargetsKey = "scanTargets"
    private static let annotationsKey = "hostAnnotations"
    private static let firstSeenKey = "hostFirstSeen"

    init(defaults: UserDefaults = .standard,
         interfaceProvider: @escaping () -> [NetworkInterface] = NetworkInterface.current) {
        self.defaults = defaults
        self.interfaceProvider = interfaceProvider
        savedScans = Persisted.load([ScanTarget].self, forKey: Self.savedScansKey, from: defaults)
            ?? (Persisted.load([ScanTarget].self, forKey: Self.legacyTargetsKey, from: defaults) ?? [])
                .filter { $0.rangeText != nil }
        annotations = Persisted.load([String: HostAnnotation].self, forKey: Self.annotationsKey, from: defaults) ?? [:]
        firstSeen = Persisted.load([String: Date].self, forKey: Self.firstSeenKey, from: defaults) ?? [:]
        refreshInterfaces()
    }

    // MARK: Interfaces and saved scans

    func refreshInterfaces() {
        interfaces = interfaceProvider()
    }

    func setSavedScans(_ scans: [ScanTarget]) {
        savedScans = scans.filter { $0.rangeText != nil }
        Persisted.save(savedScans, forKey: Self.savedScansKey, to: defaults)
    }

    func interface(named name: String) -> NetworkInterface? {
        interfaces.first { $0.name == name }
    }

    /// The subnet scanned for an interface; very large subnets shrink to the local /24.
    func defaultSubnet(for interface: NetworkInterface) -> IPv4Subnet {
        let subnet = interface.subnet
        return subnet.prefixLength < Self.minimumPrefixLength
            ? IPv4Subnet(address: interface.address, prefixLength: 24)
            : subnet
    }

    /// What a target covers right now, for menus and the settings list.
    func describe(_ target: ScanTarget) -> String {
        switch target.kind {
        case .interfaceSubnet(let name):
            interface(named: name).map { defaultSubnet(for: $0).description } ?? "interface not connected"
        case .range(let text):
            text
        }
    }

    struct ScanPlan {
        let target: ScanTarget
        let interface: NetworkInterface
        let addresses: [IPv4Address]
        let includesLocal: Bool
        let summary: String
        let notice: String?
    }

    /// Nil when the target can't run now: invalid range or disconnected interface.
    func plan(for target: ScanTarget) -> ScanPlan? {
        switch target.kind {
        case .interfaceSubnet(let name):
            guard let interface = interface(named: name) else { return nil }
            let subnet = defaultSubnet(for: interface)
            let notice = subnet == interface.subnet
                ? nil
                : "The \(interface.subnet) subnet is too large; scanning \(subnet) instead."
            return ScanPlan(target: target, interface: interface,
                            addresses: subnet.hosts.filter { $0 != interface.address },
                            includesLocal: true, summary: subnet.description, notice: notice)
        case .range(let text):
            guard target.validationError == nil,
                  let addresses = try? ScanRange.parse(text), let first = addresses.first,
                  // Results are filed under the interface on that network, else the primary one.
                  let interface = interfaces.first(where: { $0.subnet.contains(first) }) ?? interfaces.first
            else { return nil }
            let count = addresses.count
            return ScanPlan(target: target, interface: interface,
                            addresses: addresses.filter { $0 != interface.address },
                            includesLocal: addresses.contains(interface.address),
                            summary: "\(count) IP\(count == 1 ? "" : "s")", notice: nil)
        }
    }

    // MARK: Running

    var isScanningAny: Bool {
        scans.values.contains { $0.isScanning }
    }

    /// Average progress of the targets currently scanning.
    var overallProgress: Double {
        let running = scans.values.filter(\.isScanning)
        guard !running.isEmpty else { return 1 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    /// Scan states in launch order.
    var orderedScans: [(id: ScanTarget.ID, state: ScanState)] {
        runOrder.compactMap { id in scans[id].map { (id, $0) } }
    }

    var targetsWithoutResponses: [String] {
        orderedScans.filter { $0.state.foundNothing && !$0.state.isScanning }.map(\.state.name)
    }

    /// ▶: every interface, each on its own subnet. Previous results are cleared.
    @discardableResult
    func startAllInterfaces() -> [Task<Void, Never>] {
        refreshInterfaces()
        return start(interfaces.map { ScanTarget.subnet(of: $0.name) })
    }

    /// ⌄ menu: one interface's subnet.
    @discardableResult
    func start(interface name: String) -> [Task<Void, Never>] {
        refreshInterfaces()
        return start([ScanTarget.subnet(of: name)])
    }

    @discardableResult
    func start(_ selected: [ScanTarget]) -> [Task<Void, Never>] {
        stopAll()
        generation += 1
        let generation = generation
        hosts = []
        scans = [:]
        dnsServers = DNSServers.current()
        let plans = selected.compactMap(plan(for:))
        runOrder = plans.map(\.target.id)
        return plans.map { plan in
            let task = Task { await scan(plan, generation: generation) }
            tasks[plan.target.id] = task
            return task
        }
    }

    /// 🗑: stops any scan and empties the results. Saved names, comments and first-seen dates are kept.
    func clearResults() {
        stopAll()
        generation += 1
        hosts = []
        scans = [:]
        runOrder = []
    }

    var hasResults: Bool {
        !hosts.isEmpty || !scans.isEmpty
    }

    func stopAll() {
        for (id, task) in tasks {
            task.cancel()
            scans[id]?.isScanning = false
        }
        tasks = [:]
    }

    func host(_ id: HostID?) -> DiscoveredHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    // MARK: Wake-on-LAN

    /// Sends a magic packet to the host's subnet broadcast and the limited broadcast.
    /// Returns false when the host has no MAC or nothing could be sent.
    @discardableResult
    func wake(_ id: HostID) -> Bool {
        guard let host = host(id), let mac = host.mac else { return false }
        var targets = [IPv4Address(raw: .max)]
        if let subnet = interface(named: host.interface)?.subnet {
            targets.insert(subnet.broadcast, at: 0)
        }
        return WakeOnLAN.wake(mac, to: targets) > 0
    }

    // MARK: Annotations

    func setCustomName(_ name: String, for id: HostID) {
        updateAnnotation(for: id) { $0.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name }
    }

    func setComment(_ comment: String, for id: HostID) {
        updateAnnotation(for: id) { $0.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment }
    }

    private func updateAnnotation(for id: HostID, _ change: (inout HostAnnotation) -> Void) {
        guard let index = index(of: id) else { return }
        let key = HostAnnotation.key(for: hosts[index])
        var annotation = annotations[key] ?? HostAnnotation()
        change(&annotation)
        annotations[key] = annotation.isEmpty ? nil : annotation
        Persisted.save(annotations, forKey: Self.annotationsKey, to: defaults)
        for index in hosts.indices where HostAnnotation.key(for: hosts[index]) == key {
            applyAnnotation(at: index)
        }
    }

    private func applyAnnotation(at index: Int) {
        let key = HostAnnotation.key(for: hosts[index])
        let annotation = annotations[key]
        hosts[index].customName = annotation?.name
        hosts[index].comment = annotation?.comment
        hosts[index].firstSeen = firstSeen[key]
    }

    /// Stamps devices seen for the first time. Runs once their MACs are known, so a device
    /// isn't first recorded by IP and then again by MAC.
    private func recordFirstSeen(where belongs: (DiscoveredHost) -> Bool) {
        let now = Date.now
        var changed = false
        for index in hosts.indices where belongs(hosts[index]) && hosts[index].firstSeen == nil {
            let key = HostAnnotation.key(for: hosts[index])
            if firstSeen[key] == nil {
                firstSeen[key] = now
                changed = true
            }
            hosts[index].firstSeen = firstSeen[key]
        }
        if changed {
            Persisted.save(firstSeen, forKey: Self.firstSeenKey, to: defaults)
        }
    }

    // MARK: Export

    var csv: String {
        let header = "IP,Type,IPv6 Local,IPv6 Global,MAC,Vendor,Model,Hostname,Comment,First Seen,Latency (ms),Source,Interface"
        let rows = hosts.sorted { ($0.interface, $0.address.raw) < ($1.interface, $1.address.raw) }.map { host in
            [host.address.description, host.kindText, host.ipv6LinkLocal.joined(separator: " "), host.ipv6Global.joined(separator: " "),
             host.macText, host.vendorText, host.modelText, host.hostnameText, host.commentText,
             host.firstSeen?.ISO8601Format() ?? "",
             host.latency.map { String(format: "%.2f", $0) } ?? "", host.source.rawValue, host.interface]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    // MARK: Scan

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func scan(_ plan: ScanPlan, generation: Int) async {
        // Cleared or restarted before this task got to run.
        guard isCurrent(generation) else { return }
        let id = plan.target.id
        let interface = plan.interface
        let name = interface.name
        let addressSet = Set(plan.addresses)
        scans[id] = ScanState(name: plan.target.displayName, interface: name, isScanning: true,
                              summary: plan.summary, notice: plan.notice)
        if plan.includesLocal {
            var local = DiscoveredHost(interface: name, address: interface.address, source: .local,
                                       mac: interface.macAddress, computerName: Host.current().localizedName)
            local.ipv6LinkLocal = interface.ipv6Addresses.filter { $0.lowercased().hasPrefix("fe80:") }.sorted()
            local.ipv6Global = interface.ipv6Addresses.filter { !$0.lowercased().hasPrefix("fe80:") }.sorted()
            local.hardwareModel = Self.hardwareModel()
            upsert(local)
        }
        func belongs(_ host: DiscoveredHost) -> Bool {
            host.interface == name && (addressSet.contains(host.address) || (plan.includesLocal && host.source == .local))
        }

        // IPv6 hosts answer an all-nodes ping; their addresses land in the neighbor cache by step 2.
        IPv6Neighbors.pingAllNodes(interface: name)

        // 1. Liveness: ICMP first, TCP connect as a fallback for hosts that drop pings.
        let pinger = try? ICMPPinger()
        var completed = 0
        await withLimitedConcurrency(plan.addresses, limit: 128) { address in
            await Self.probe(address, on: name, pinger: pinger)
        } onResult: { host in
            guard isCurrent(generation) else { return }
            completed += 1
            scans[id]?.progress = Double(completed) / Double(max(plan.addresses.count, 1)) * 0.85
            if let host {
                upsert(host)
                scans[id]?.hostCount = hosts.count(where: belongs)
            }
        }
        guard isCurrent(generation) else { return }

        // 2. Probing populated the ARP cache: pick up MACs, plus hosts that only answered ARP.
        for (address, mac) in ARPTable.read() where addressSet.contains(address) {
            if let index = index(of: HostID(interface: name, address: address)) {
                hosts[index].mac = mac
                applyAnnotation(at: index)
            } else {
                upsert(DiscoveredHost(interface: name, address: address, source: .arp, mac: mac))
            }
        }
        recordFirstSeen(where: belongs)
        IPv6Neighbors.pingAllNodes(interface: name)
        try? await Task.sleep(for: .milliseconds(500))
        let ipv6ByMAC = IPv6Neighbors.classify(IPv6Neighbors.read(interface: name))
        for index in hosts.indices where belongs(hosts[index]) {
            if let mac = hosts[index].mac {
                hosts[index].vendor = OUIDatabase.vendor(for: mac)
                if let ipv6 = ipv6ByMAC[mac] {
                    hosts[index].ipv6LinkLocal = ipv6.linkLocal
                    hosts[index].ipv6Global = ipv6.global
                }
            }
        }
        guard isCurrent(generation) else { return }
        scans[id]?.progress = 0.9

        // 3. Names and identity. Bonjour browsing and SSDP are network-wide and run alongside the
        //    per-host name lookups; then each host's UPnP description and web page title.
        async let advertised = BonjourBrowser.discover(timeout: 3)
        async let upnpAnswers = SSDP.discover(interfaceAddress: interface.address, timeout: 2.5)
        let gateway = DefaultGateway.read()[name]
        scans[id]?.gateway = gateway

        let addresses = hosts.filter { belongs($0) && $0.source != .local }.map(\.address)
        await withLimitedConcurrency(addresses, limit: 32) { address in
            async let bonjour = MulticastDNS.reverseLookup(address)
            async let netbios = NetBIOS.lookup(address)
            async let dns = HostResolver.reverseLookup(address)
            return (address, await bonjour, await netbios, await dns)
        } onResult: { address, bonjour, netbios, dns in
            guard isCurrent(generation),
                  let index = index(of: HostID(interface: name, address: address)) else { return }
            hosts[index].bonjourName = bonjour
            hosts[index].netbiosName = netbios
            hosts[index].dnsName = dns
        }
        let (services, answers) = await (advertised, upnpAnswers)
        guard isCurrent(generation) else { return }
        for index in hosts.indices where belongs(hosts[index]) {
            let address = hosts[index].address
            // This Mac's own services resolve to loopback.
            let isLocal = hosts[index].source == .local
            hosts[index].services = services.filter { $0.addresses.contains(address) || (isLocal && $0.addresses.contains(.loopback)) }
                .sorted { $0.type < $1.type }
            hosts[index].isGateway = address == gateway
        }
        scans[id]?.progress = 0.95

        var locations: [IPv4Address: [URL]] = [:]
        for answer in answers {
            if let location = answer.location, locations[answer.address]?.contains(location) != true {
                locations[answer.address, default: []].append(location)
            }
        }
        let lookupLocations = locations
        await withLimitedConcurrency(addresses, limit: 16) { address in
            async let title = WebTitle.fetch(address)
            async let device = UPnP.describe(lookupLocations[address] ?? [])
            return (address, await title, await device)
        } onResult: { address, title, device in
            guard isCurrent(generation),
                  let index = index(of: HostID(interface: name, address: address)) else { return }
            hosts[index].webTitle = title
            hosts[index].upnp = device
        }
        guard isCurrent(generation) else { return }

        let found = hosts.filter(belongs)
        scans[id]?.progress = 1
        scans[id]?.isScanning = false
        scans[id]?.completedAt = .now
        scans[id]?.hostCount = found.count
        scans[id]?.foundNothing = !found.contains { $0.source != .local }
        tasks[id] = nil
    }

    /// This Mac's model identifier, e.g. "MacBookPro18,2".
    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private nonisolated static func probe(_ address: IPv4Address, on interface: String, pinger: ICMPPinger?) async -> DiscoveredHost? {
        if let pinger, case .reply(let ms) = await pinger.ping(address, timeout: 1) {
            return DiscoveredHost(interface: interface, address: address, source: .icmp, latency: ms)
        }
        // A RST (closed) proves the host is up just as well as an accept.
        let alive = await withTaskGroup(of: Bool.self) { group in
            for port in discoveryPorts {
                group.addTask { await TCPProbe.probe(address, port: port, timeout: 1) != .filtered }
            }
            for await isAlive in group where isAlive {
                return true
            }
            return false
        }
        return alive ? DiscoveredHost(interface: interface, address: address, source: .tcp) : nil
    }

    private func index(of id: HostID) -> Int? {
        hosts.firstIndex { $0.id == id }
    }

    /// Overlapping targets can report the same host; the first report wins, a later ping
    /// only fills in what was missing.
    private func upsert(_ host: DiscoveredHost) {
        if let index = index(of: host.id) {
            if hosts[index].latency == nil, host.latency != nil {
                hosts[index].latency = host.latency
                hosts[index].source = host.source
            }
        } else {
            hosts.append(host)
            applyAnnotation(at: hosts.count - 1)
        }
    }
}

#if DEBUG
extension ScannerModel {
    /// Fills the table with fictional results (README screenshots, see DemoData).
    func loadDemo(hosts: [DiscoveredHost], scans: [(ScanTarget, ScanState)], dnsServers: [String] = []) {
        stopAll()
        generation += 1
        self.hosts = hosts
        self.dnsServers = dnsServers
        self.scans = Dictionary(uniqueKeysWithValues: scans.map { ($0.0.id, $0.1) })
        runOrder = scans.map(\.0.id)
    }
}
#endif
