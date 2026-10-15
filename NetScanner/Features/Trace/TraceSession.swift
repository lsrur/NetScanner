import Foundation
import Observation

@MainActor
@Observable
final class TraceSession {
    struct Hop: Identifiable {
        let ttl: Int
        var address: IPv4Address?
        /// One entry per probe; nil = no answer.
        var rtts: [Double?]
        var hostname: String?
        var isDestination = false
        var unreachable = false

        var id: Int { ttl }
    }

    static let probesPerHop = 3

    var host = ""
    var maxHops = 30
    var timeout: TimeInterval = 1

    private(set) var hops: [Hop] = []
    private(set) var resolvedAddress: IPv4Address?
    private(set) var isRunning = false
    private(set) var reachedDestination = false
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var runID = 0

    func retarget(_ host: String) {
        guard host != self.host else { return }
        stop()
        self.host = host
        reset()
    }

    func start() {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        task?.cancel()
        reset()
        isRunning = true
        runID += 1
        let runID = runID
        task = Task {
            await run(host: host)
            if self.runID == runID { isRunning = false }
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    private func reset() {
        hops = []
        resolvedAddress = nil
        reachedDestination = false
        errorMessage = nil
    }

    private func run(host: String) async {
        do {
            let address = try await HostResolver.resolveIPv4(host)
            try Task.checkCancellation()
            resolvedAddress = address
            let tracer = try ICMPTracer()
            let timeout = timeout

            for ttl in 1...maxHops {
                // The probes of one hop go out together; hops are sequential.
                let results = await withTaskGroup(of: (Int, TraceProbeResult).self) { group in
                    for index in 0..<Self.probesPerHop {
                        group.addTask { (index, await tracer.probe(address, ttl: ttl, timeout: timeout)) }
                    }
                    var ordered = [TraceProbeResult](repeating: .timeout, count: Self.probesPerHop)
                    for await (index, result) in group { ordered[index] = result }
                    return ordered
                }
                try Task.checkCancellation()

                var hop = Hop(ttl: ttl, rtts: [])
                for result in results {
                    guard case .answer(let from, let rtt, let kind) = result else {
                        hop.rtts.append(nil)
                        continue
                    }
                    hop.address = hop.address ?? from
                    hop.rtts.append(rtt)
                    switch kind {
                    case .echoReply: hop.isDestination = true
                    case .unreachable: hop.unreachable = true
                    case .timeExceeded: break
                    }
                }
                hops.append(hop)
                if let hopAddress = hop.address {
                    resolveName(of: hopAddress, ttl: ttl)
                }
                if hop.isDestination || hop.address == address {
                    reachedDestination = true
                    break
                }
                if hop.unreachable { break }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Router names arrive later; private addresses also try Bonjour.
    private func resolveName(of address: IPv4Address, ttl: Int) {
        Task {
            async let dns = HostResolver.reverseLookup(address)
            async let bonjour = MulticastDNS.reverseLookup(address, timeout: 1)
            let (dnsName, bonjourName) = await (dns, bonjour)
            guard let name = dnsName ?? bonjourName, let index = hops.firstIndex(where: { $0.ttl == ttl && $0.address == address }) else {
                return
            }
            hops[index].hostname = name
        }
    }
}

#if DEBUG
extension TraceSession {
    /// A finished trace, for screenshots.
    func loadDemo(host: String, destination: IPv4Address, hops: [Hop]) {
        stop()
        self.host = host
        resolvedAddress = destination
        self.hops = hops
        reachedDestination = hops.last?.isDestination == true
    }
}
#endif
