import Foundation

/// Running ping statistics, updated incrementally (Welford for the standard deviation).
/// Stddev is the population value, matching `ping`; jitter is the mean |Δ| between consecutive replies.
struct PingStats: Equatable, Sendable {
    private(set) var sent = 0
    private(set) var received = 0
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    private var mean = 0.0
    private var m2 = 0.0
    private var lastRTT: Double?
    private var jitterSum = 0.0
    private var jitterCount = 0

    /// Records one probe; `nil` means the reply was lost.
    mutating func record(_ rtt: Double?) {
        sent += 1
        guard let rtt else { return }
        received += 1
        minimum = min(minimum ?? rtt, rtt)
        maximum = max(maximum ?? rtt, rtt)
        let delta = rtt - mean
        mean += delta / Double(received)
        m2 += delta * (rtt - mean)
        if let lastRTT {
            jitterSum += abs(rtt - lastRTT)
            jitterCount += 1
        }
        lastRTT = rtt
    }

    var lost: Int { sent - received }
    var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }
    var average: Double? { received > 0 ? mean : nil }
    var standardDeviation: Double? { received > 0 ? (m2 / Double(received)).squareRoot() : nil }
    var jitter: Double? { jitterCount > 0 ? jitterSum / Double(jitterCount) : nil }
}
