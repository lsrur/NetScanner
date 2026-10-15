import Foundation
import Observation

/// One run of macOS's `networkQuality` (Apple's speed and responsiveness test, which measures
/// against Apple's CDN with several parallel connections).
struct SpeedTestResult: Equatable, Sendable {
    /// Bits per second.
    var download: Double
    var upload: Double
    /// Round-trip time on an idle connection, in milliseconds.
    var idleLatency: Double?
    /// Round trips per minute while the link is loaded (higher is better).
    var responsiveness: Double?
    var interface: String?
    var server: String?
    var date: Date
}

enum NetworkQuality {
    static let executable = URL(filePath: "/usr/bin/networkQuality")

    enum Failure: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "networkQuality isn't available on this Mac."
            case .failed(let message): message
            }
        }
    }

    /// Runs the test (about 15–20 s) and returns its result; cancelling the task stops it.
    static func run(maxSeconds: Int = 30) async throws -> SpeedTestResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        // Touched from the cancellation handler only to terminate it.
        nonisolated(unsafe) let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "-M", String(maxSeconds)]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Read while it runs (a full pipe would block it); EOF arrives when it exits.
        let data = await withTaskCancellationHandler {
            await Task.detached { (try? output.fileHandleForReading.readToEnd()) ?? Data() }.value
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let result = parse(data) else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(message.isEmpty ? "The speed test didn't finish (status \(process.terminationStatus))." : message)
        }
        return result
    }

    /// The `-c` JSON: throughputs in bits/s, `base_rtt` in ms, `responsiveness` in RPM.
    static func parse(_ data: Data) -> SpeedTestResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let download = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let upload = (json["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return SpeedTestResult(
            download: download,
            upload: upload,
            idleLatency: (json["base_rtt"] as? NSNumber)?.doubleValue,
            responsiveness: (json["responsiveness"] as? NSNumber)?.doubleValue,
            interface: json["interface_name"] as? String,
            server: json["test_endpoint"] as? String,
            date: (json["end_date"] as? String).flatMap(formatter.date(from:)) ?? .now
        )
    }

    /// "271 Mbps", "1.2 Gbps", "850 kbps".
    static func formatRate(_ bitsPerSecond: Double) -> String {
        let units: [(Double, String)] = [(1e9, "Gbps"), (1e6, "Mbps"), (1e3, "kbps")]
        for (scale, unit) in units where bitsPerSecond >= scale {
            let value = bitsPerSecond / scale
            return (value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)) + " " + unit
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }
}

@MainActor
@Observable
final class SpeedTestModel {
    private(set) var result: SpeedTestResult?
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        errorMessage = nil
        isRunning = true
        startedAt = .now
        task = Task {
            do {
                let result = try await NetworkQuality.run()
                self.result = result
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if !Task.isCancelled { isRunning = false }
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }
}

#if DEBUG
extension SpeedTestModel {
    func loadDemo(_ result: SpeedTestResult) {
        self.result = result
        isRunning = false
    }
}
#endif
