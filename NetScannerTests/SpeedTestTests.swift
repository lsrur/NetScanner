import Foundation
import Testing
@testable import NetScanner

struct SpeedTestTests {
    @Test func parsesNetworkQualityJSON() throws {
        let json = """
        {"dl_throughput": 270833696, "ul_throughput": 86684040, "base_rtt": 18.5, "responsiveness": 642.3,
         "interface_name": "en0", "test_endpoint": "edge.speedtest.example", "end_date": "2026-10-15 05:15:41.590",
         "other": {}}
        """
        let result = try #require(NetworkQuality.parse(Data(json.utf8)))
        #expect(result.download == 270_833_696 && result.upload == 86_684_040)
        #expect(result.idleLatency == 18.5 && result.responsiveness == 642.3)
        #expect(result.interface == "en0" && result.server == "edge.speedtest.example")
        #expect(Calendar(identifier: .gregorian).component(.minute, from: result.date) == 15)
        #expect(NetworkQuality.parse(Data("{}".utf8)) == nil)
        #expect(NetworkQuality.parse(Data("not json".utf8)) == nil)
    }

    @Test func formatsRates() {
        #expect(NetworkQuality.formatRate(270_833_696) == "271 Mbps")
        #expect(NetworkQuality.formatRate(86_684_040) == "86.7 Mbps")
        #expect(NetworkQuality.formatRate(1_260_000_000) == "1.3 Gbps")
        #expect(NetworkQuality.formatRate(850_000) == "850 kbps")
    }

    @Test func extractsASN() {
        #expect(PublicNetworkLookup.asn(fromOrg: "AS64500 Example Telecom S.A.") == "AS64500")
        #expect(PublicNetworkLookup.asn(fromOrg: "Some ISP") == nil)
        #expect(PublicNetworkLookup.asn(fromOrg: nil) == nil)
    }
}
