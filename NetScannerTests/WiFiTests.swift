import CoreWLAN
import Foundation
import Testing
@testable import NetScanner

struct WiFiLabelTests {
    /// Signatures CoreWLAN really reports (raw CWSecurity values), umbrella values included.
    private func label(_ raw: Set<Int>) -> String {
        WiFiScanner.securityLabel { raw.contains($0.rawValue) }
    }

    @Test func securityIgnoresUmbrellaValues() {
        #expect(label([3, 4, 5, 13]) == "WPA2 Personal")         // WPA2 only
        #expect(label([2, 3, 4, 5, 13]) == "WPA/WPA2 Personal")
        #expect(label([4, 5, 11, 13]) == "WPA2/WPA3 Personal")    // transition
        #expect(label([5, 11, 13]) == "WPA3 Personal")
        #expect(label([9, 10]) == "WPA2 Enterprise")
        #expect(label([0, 15]) == "Open (OWE)")
        #expect(label([0]) == "Open")
        #expect(label([1]) == "WEP")
    }

    @Test func modesBandAndWidth() {
        let ac: Set<CWPHYMode> = [.mode11a, .mode11n, .mode11ac]
        #expect(WiFiScanner.modesLabel { ac.contains($0) } == "a/n/ac")
        #expect(WiFiScanner.band(.band5GHz) == .ghz5 && WiFiScanner.band(nil) == .unknown)
        #expect(WiFiScanner.widthMHz(.width80MHz) == 80)
        let open = WiFiObservation(ssid: "x", bssid: nil, rssi: -50, noise: -90, channel: 1, band: .ghz2, width: 20,
                                   security: "Open (OWE)", modes: "b/g/n")
        #expect(!open.isSecured)
    }

    @Test func formatsAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WiFiAnalyzerView.ago(now, now: now) == "now")
        #expect(WiFiAnalyzerView.ago(now.addingTimeInterval(-45), now: now) == "45s ago")
        #expect(WiFiAnalyzerView.ago(now.addingTimeInterval(-185), now: now) == "3m 5s ago")
        #expect(WiFiAnalyzerView.ago(now.addingTimeInterval(-7440), now: now) == "2h 4m ago")
        #expect(LevelBar.filled(-30) == 20 && LevelBar.filled(-100) == 0 && LevelBar.filled(-65) == 10)
    }
}

@MainActor
struct WiFiAnalyzerModelTests {
    private func ap(_ bssid: String?, _ rssi: Int, ssid: String? = "Net", channel: Int = 6) -> WiFiObservation {
        WiFiObservation(ssid: bssid == nil ? nil : ssid, bssid: bssid, rssi: rssi, noise: -90, channel: channel,
                        band: .ghz2, width: 20, security: "WPA2 Personal", modes: "b/g/n")
    }

    @Test func mergesScansIntoHistory() throws {
        let model = WiFiAnalyzerModel()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let link = WiFiLink(bssid: "aa:aa:aa:aa:aa:01", channel: 6, rssi: -40, noise: -90, transmitRate: 300)
        model.merge([ap("aa:aa:aa:aa:aa:01", -40), ap("aa:aa:aa:aa:aa:02", -85)], link: link, at: t0)
        model.merge([ap("aa:aa:aa:aa:aa:01", -50)], link: link, at: t0.addingTimeInterval(5))

        let strong = try #require(model.networks.first { $0.id == "aa:aa:aa:aa:aa:01" })
        #expect(strong.samples.map(\.rssi) == [-40, -50])
        #expect(strong.average == -45 && strong.maximum == -40 && strong.minimum == -50)
        #expect(strong.isConnected)
        #expect(model.isInRange(strong))
        let weak = try #require(model.networks.first { $0.id == "aa:aa:aa:aa:aa:02" })
        #expect(!model.isInRange(weak))                       // missing from the latest scan
        #expect(model.checked == ["aa:aa:aa:aa:aa:01"])        // only the strong one auto-checked
        #expect(weak.colorIndex == 1)
    }

    @Test func dropsAnonymousRowsOnceBSSIDsArrive() {
        let model = WiFiAnalyzerModel()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        model.merge([ap(nil, -50), ap(nil, -50)], link: nil, at: t0)   // no Location access yet
        #expect(model.networks.count == 2)
        model.merge([ap("aa:aa:aa:aa:aa:01", -50)], link: nil, at: t0.addingTimeInterval(5))
        #expect(model.networks.map(\.id) == ["aa:aa:aa:aa:aa:01"])
        #expect(model.checked == ["aa:aa:aa:aa:aa:01"])
    }

    @Test func filtersByBand() {
        let model = WiFiAnalyzerModel()
        var five = ap("aa:aa:aa:aa:aa:05", -60, channel: 36)
        five.band = .ghz5
        model.merge([ap("aa:aa:aa:aa:aa:01", -50), five], link: nil, at: .now)
        model.bandFilter = .ghz5
        #expect(model.visibleNetworks.map(\.id) == ["aa:aa:aa:aa:aa:05"])
    }
}
