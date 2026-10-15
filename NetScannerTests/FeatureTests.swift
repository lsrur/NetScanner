import Testing
@testable import NetScanner

struct PingStatsTests {
    @Test func aggregatesRepliesAndLoss() {
        var stats = PingStats()
        for rtt in [10.0, 20.0, nil, 30.0] {
            stats.record(rtt)
        }
        #expect(stats.sent == 4)
        #expect(stats.received == 3)
        #expect(stats.lost == 1)
        #expect(stats.lossPercent == 25)
        #expect(stats.minimum == 10)
        #expect(stats.maximum == 30)
        #expect(stats.average == 20)
        #expect(abs(stats.standardDeviation! - (200.0 / 3).squareRoot()) < 1e-9)
        #expect(stats.jitter == 10)
    }

    @Test func emptyAndAllLost() {
        var stats = PingStats()
        #expect(stats.lossPercent == 0)
        #expect(stats.average == nil)
        stats.record(nil)
        stats.record(nil)
        #expect(stats.lossPercent == 100)
        #expect(stats.minimum == nil)
        #expect(stats.jitter == nil)
    }

    @Test func singleReplyHasZeroDeviation() {
        var stats = PingStats()
        stats.record(5)
        #expect(stats.standardDeviation == 0)
        #expect(stats.jitter == nil)
    }
}

struct PortSpecTests {
    @Test func parsesListsAndRanges() {
        #expect(PortSpec.parse("22, 80,443") == [22, 80, 443])
        #expect(PortSpec.parse("8000-8003 22 8001") == [22, 8000, 8001, 8002, 8003])
        #expect(PortSpec.parse("65535")?.last == 65535)
    }

    @Test(arguments: ["", "0", "80-", "-80", "90-80", "abc", "70000", "1-2-3"])
    func rejectsInvalid(_ text: String) {
        #expect(PortSpec.parse(text) == nil)
    }

    @Test func formatsCollapsingRanges() {
        #expect(PortSpec.format([80, 1, 2, 3, 443, 2]) == "1-3, 80, 443")
        #expect(PortSpec.parse(PortSpec.format(PortSpec.top100)) == PortSpec.top100)
        #expect(PortSpec.format([]) == "")
    }

    @Test func homeIoTIsSortedAndUnique() {
        #expect(PortSpec.homeIoT == Array(Set(PortSpec.homeIoT)).sorted())
        #expect([1883, 8123, 62078].allSatisfy(PortSpec.homeIoT.contains))
    }

    @Test func everyPresetPortHasADescription() {
        let missing = Set(PortSpec.top100 + PortSpec.homeIoT).filter { PortDescriptions.description(for: $0) == nil }
        #expect(missing.isEmpty, "Sin descripción: \(missing.sorted())")
    }

    @Test func tooltipFallsBackToRegisteredName() {
        #expect(PortDescriptions.tooltip(for: 22).hasPrefix("SSH"))
        #expect(PortDescriptions.tooltip(for: 5353) == "Registered service: mdns")
        #expect(PortDescriptions.tooltip(for: 60001) == "Dynamic/private port")
    }

    @Test func top100IsUnique() {
        #expect(PortSpec.top100.count == 100)
        #expect(Set(PortSpec.top100).count == 100)
    }
}

struct LookupTableTests {
    @Test func knownVendorAndService() {
        #expect(OUIDatabase.vendor(for: MACAddress("00:03:93:00:00:01")!) == "Apple, Inc.")
        #expect(OUIDatabase.vendor(for: MACAddress("02:00:00:00:00:01")!) == "Private (randomized)")
        #expect(ServiceNames.name(for: 22) == "ssh")
    }
}
