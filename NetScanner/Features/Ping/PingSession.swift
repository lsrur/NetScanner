import Foundation
import Observation

@MainActor
@Observable
final class PingSession {
    struct Sample: Identifiable {
        let id: Int
        let outcome: PingOutcome

        var rtt: Double? {
            if case .reply(let ms) = outcome { return ms }
            return nil
        }
    }

    static let maxSamples = 1000

    var host = ""
    /// 0 means ping until stopped.
    var count = 10
    var interval: TimeInterval = 1
    var timeout: TimeInterval = 1

    private(set) var samples: [Sample] = []
    private(set) var stats = PingStats()
    private(set) var resolvedAddress: IPv4Address?
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    /// Lets a finished run tell whether it is still the latest one.
    private var runID = 0

    /// Points the session at a new host, discarding the previous run.
    func retarget(_ host: String) {
        guard host != self.host else { return }
        stop()
        self.host = host
        samples = []
        stats = PingStats()
        resolvedAddress = nil
        errorMessage = nil
    }

    func start() {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        task?.cancel()
        samples = []
        stats = PingStats()
        resolvedAddress = nil
        errorMessage = nil
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

    private func run(host: String) async {
        do {
            let address = try await HostResolver.resolveIPv4(host)
            try Task.checkCancellation()
            resolvedAddress = address
            let pinger = try ICMPPinger()
            let count = count, interval = interval, timeout = timeout
            var sequence = 0

            while !Task.isCancelled, count == 0 || sequence < count {
                let started = ContinuousClock.now
                let outcome = await pinger.ping(address, timeout: timeout)
                guard !Task.isCancelled else { break }

                let sample = Sample(id: sequence, outcome: outcome)
                stats.record(sample.rtt)
                samples.append(sample)
                if samples.count > Self.maxSamples {
                    samples.removeFirst(samples.count - Self.maxSamples)
                }
                sequence += 1

                guard count == 0 || sequence < count else { break }
                let remaining = .seconds(interval) - (ContinuousClock.now - started)
                if remaining > .zero {
                    try await Task.sleep(for: remaining)
                }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
