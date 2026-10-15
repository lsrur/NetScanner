import CoreWLAN
import Foundation

enum WiFiBand: String, Sendable, Comparable {
    case ghz2 = "2.4"
    case ghz5 = "5"
    case ghz6 = "6"
    case unknown = "?"

    static func < (lhs: WiFiBand, rhs: WiFiBand) -> Bool {
        let order: [WiFiBand] = [.ghz2, .ghz5, .ghz6, .unknown]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// One access point (BSSID) as one scan saw it.
struct WiFiObservation: Equatable, Sendable {
    /// Nil for hidden networks, and for every network until the app has Location access.
    var ssid: String?
    /// Nil without Location access.
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int
    var band: WiFiBand
    /// MHz.
    var width: Int
    var security: String
    /// Supported 802.11 modes, oldest first: "b/g/n", "a/n/ac/ax".
    var modes: String
    var isSecured: Bool { !security.hasPrefix("Open") }
}

/// The link the Mac is on right now.
struct WiFiLink: Equatable, Sendable {
    var bssid: String?
    var channel: Int?
    var rssi: Int
    var noise: Int
    /// Mbps.
    var transmitRate: Double
}

enum WiFiScanner {
    enum Failure: LocalizedError {
        case noInterface
        case poweredOff

        var errorDescription: String? {
            switch self {
            case .noInterface: "This Mac has no Wi-Fi interface."
            case .poweredOff: "Wi-Fi is turned off."
            }
        }
    }

    /// Blocks for a few seconds while the radio scans every channel; call off the main actor.
    static func scan() throws -> (networks: [WiFiObservation], link: WiFiLink?) {
        guard let interface = CWWiFiClient.shared().interface() else { throw Failure.noInterface }
        guard interface.powerOn() else { throw Failure.poweredOff }
        let networks = try interface.scanForNetworks(withSSID: nil, includeHidden: true).map(observation)
        var link: WiFiLink?
        if interface.wlanChannel() != nil {
            link = WiFiLink(bssid: interface.bssid()?.lowercased(), channel: interface.wlanChannel()?.channelNumber,
                            rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                            transmitRate: interface.transmitRate())
        }
        return (networks, link)
    }

    static func observation(_ network: CWNetwork) -> WiFiObservation {
        WiFiObservation(
            ssid: network.ssid,
            bssid: network.bssid?.lowercased(),
            rssi: network.rssiValue,
            noise: network.noiseMeasurement,
            channel: network.wlanChannel?.channelNumber ?? 0,
            band: band(network.wlanChannel?.channelBand),
            width: widthMHz(network.wlanChannel?.channelWidth),
            security: securityLabel(supports: network.supportsSecurity),
            modes: modesLabel(supports: network.supportsPHYMode)
        )
    }

    static func band(_ band: CWChannelBand?) -> WiFiBand {
        switch band {
        case .band2GHz: .ghz2
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: .unknown
        }
    }

    static func widthMHz(_ width: CWChannelWidth?) -> Int {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: 0
        }
    }

    /// Built only from the concrete schemes: `supportsSecurity` also answers true for the
    /// umbrella values (`.personal`, `.wpaPersonalMixed`, `.wpa3Transition`…) whenever any
    /// compatible scheme is offered, so a WPA2-only network "supports" WPA3 Transition.
    static func securityLabel(supports: (CWSecurity) -> Bool) -> String {
        func combine(_ wpa: Bool, _ wpa2: Bool, _ wpa3: Bool, _ kind: String) -> String? {
            let versions = [wpa ? "WPA" : nil, wpa2 ? "WPA2" : nil, wpa3 ? "WPA3" : nil].compactMap { $0 }
            return versions.isEmpty ? nil : versions.joined(separator: "/") + " " + kind
        }
        if let enterprise = combine(supports(.wpaEnterprise), supports(.wpa2Enterprise), supports(.wpa3Enterprise), "Enterprise") {
            return enterprise
        }
        if let personal = combine(supports(.wpaPersonal), supports(.wpa2Personal), supports(.wpa3Personal), "Personal") {
            return personal
        }
        if supports(.dynamicWEP) { return "Dynamic WEP" }
        if supports(.WEP) { return "WEP" }
        if supports(.OWE) { return "OWE" }
        if supports(.oweTransition) { return "Open (OWE)" }
        return "Open"
    }

    static func modesLabel(supports: (CWPHYMode) -> Bool) -> String {
        let ordered: [(CWPHYMode, String)] = [
            (.mode11a, "a"), (.mode11b, "b"), (.mode11g, "g"), (.mode11n, "n"), (.mode11ac, "ac"), (.mode11ax, "ax"),
        ]
        return ordered.filter { supports($0.0) }.map(\.1).joined(separator: "/")
    }
}

/// Where a network sits on the channel axis: the center of its (possibly bonded) block and
/// how far it reaches on each side, in channel numbers.
enum WiFiChannelSpan {
    static func span(channel: Int, width: Int, band: WiFiBand) -> (center: Double, halfWidth: Double) {
        let width = max(width, 20)
        // 2.4 GHz channels are 5 MHz apart, 5/6 GHz channel numbers too (a 20 MHz channel = 4 numbers).
        let halfWidth = Double(width) / 5 / 2
        switch band {
        case .ghz5, .ghz6:
            // Bonded blocks are aligned: 5 GHz from 36, 100 and 149; 6 GHz from 1.
            let base = band == .ghz6 ? 1 : channel <= 64 ? 36 : channel <= 144 ? 100 : 149
            let block = width / 5
            let start = base + max(0, (channel - base) / block) * block
            return (Double(start) + Double(block - 4) / 2, halfWidth)
        default:
            // The secondary 40 MHz channel isn't reported; assume above for low channels.
            let center = width == 40 ? Double(channel) + (channel <= 7 ? 2 : -2) : Double(channel)
            return (center, halfWidth)
        }
    }
}
