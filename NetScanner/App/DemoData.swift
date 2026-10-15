#if DEBUG
import AppKit
import Foundation

/// Fictional network for README screenshots: `NETSCANNER_DEMO=hosts|ping|ports|wifi|wifi-channels|wifi-live|internet|tools|netping|trace|dns|whois|new|moved|history|summary`.
/// Addresses use private and documentation ranges (192.168.1.0/24, 2001:db8::/32,
/// 203.0.113.0/24); MAC addresses and names are made up.
@MainActor
enum DemoData {
    static func load(_ scene: String, into model: AppModel) {
        model.publicNetwork.loadDemo(PublicNetworkInfo(ipv4: "203.0.113.42", ipv6: "2001:db8:4a2c:100::1f",
                                                       isp: "Example Broadband Co.", asn: "AS64500",
                                                       countryCode: "US", city: "Springfield", region: "Illinois"))
        let target = ScanTarget.subnet(of: "en0")
        var state = ScanState(name: target.name, interface: "en0", summary: "192.168.1.0/24")
        state.progress = 1
        state.completedAt = .now
        state.hostCount = hosts.count
        state.gateway = IPv4Address("192.168.1.1")
        model.scanner.loadDemo(hosts: hosts, scans: [(target, state)], dnsServers: ["192.168.1.1", "2001:db8:4a2c:100::1"])

        // Selecting retargets ping and ports, so select first and load their data afterwards.
        switch scene {
        case "ping":
            model.selectedHostID = HostID(interface: "en0", address: tv)
            model.inspectorTab = .ping
            model.ping.loadDemo(address: tv, rtts: tvPings)
        case "ports":
            model.selectedHostID = HostID(interface: "en0", address: nas)
            model.inspectorTab = .ports
            model.ports.loadDemo(address: nas, listName: "Home/IoT", results: nasPorts, elapsed: .milliseconds(2340))
        case "wifi-live":
            break  // only opens the window: real scans
        case "wifi", "wifi-channels":
            UserDefaults.standard.set(scene == "wifi" ? "Signal over Time" : "Channels", forKey: "wifiChartMode")
            model.wifi.loadDemo(wifiScans, link: WiFiLink(bssid: "50:c7:bf:3a:91:05", channel: 36, rssi: -48, noise: -92,
                                                           transmitRate: 866))
        case "internet":
            model.selectedHostID = HostID(interface: "en0", address: nas)
            model.speedTest.loadDemo(SpeedTestResult(download: 287_400_000, upload: 41_800_000, idleLatency: 18,
                                                      responsiveness: 642, interface: "en0",
                                                      server: "edge.speedtest.example", date: .now))
        case "tools":
            model.selectedHostID = HostID(interface: "en0", address: nas)
        case "trace", "dns", "whois", "netping":
            model.selectedHostID = HostID(interface: "en0", address: nas)
            model.tools.ping.loadDemo(address: IPv4Address("203.0.113.80")!, rtts: tvPings)
            model.tools.trace.loadDemo(host: "example.com", destination: IPv4Address("203.0.113.80")!, hops: traceHops)
            model.tools.dns.loadDemo(records: dnsRecords)
            model.tools.whois.loadDemo(answers: whoisAnswers)
            model.tools.loadDemo(destination: "example.com")
        case "summary":
            model.selectedHostID = nil
        case "moved", "history":
            model.selectedHostID = HostID(interface: "en0", address: IPv4Address("192.168.1.12")!)
            model.inspectorTab = scene == "history" ? .history : .info
        case "new":
            model.selectedHostID = nil
            model.showInspector = false
        default:
            model.selectedHostID = HostID(interface: "en0", address: nas)
            model.inspectorTab = .info
        }

        NSApp.windows.first { $0.isVisible && $0.frame.width > 500 }?
            .setFrame(NSRect(x: 80, y: 80, width: 1480, height: 860), display: true)
    }

    /// The sidebar section a scene shows.
    static func section(for scene: String) -> AppSection {
        if scene.hasPrefix("wifi") { return .wifi }
        if scene == "internet" { return .internet }
        if ["tools", "netping", "trace", "dns", "whois"].contains(scene) { return .tools }
        return .lanScan
    }

    private static let traceHops: [TraceSession.Hop] = [
        .init(ttl: 1, address: IPv4Address("192.168.1.1"), rtts: [1.8, 1.6, 1.7], hostname: "router.lan"),
        .init(ttl: 2, address: IPv4Address("100.64.0.1"), rtts: [8.9, 9.4, 8.7]),
        .init(ttl: 3, address: IPv4Address("198.51.100.17"), rtts: [11.2, 10.8, 12.5], hostname: "core1.isp.example.net"),
        .init(ttl: 4, address: nil, rtts: [nil, nil, nil]),
        .init(ttl: 5, address: IPv4Address("198.51.100.94"), rtts: [24.1, 23.7, nil], hostname: "edge2.isp.example.net"),
        .init(ttl: 6, address: IPv4Address("203.0.113.1"), rtts: [31.6, 30.9, 31.2], hostname: "ix.transit.example"),
        .init(ttl: 7, address: IPv4Address("203.0.113.80"), rtts: [32.4, 31.8, 32.0], hostname: "www.example.com", isDestination: true),
    ]

    private static let dnsRecords: [DNSRecord] = [
        DNSRecord(type: "A", value: "203.0.113.80", ttl: 300),
        DNSRecord(type: "AAAA", value: "2001:db8:80::1", ttl: 300),
        DNSRecord(type: "MX", value: "10 mail.example.com.", ttl: 3600),
        DNSRecord(type: "NS", value: "ns1.example.net.", ttl: 86400),
        DNSRecord(type: "NS", value: "ns2.example.net.", ttl: 86400),
        DNSRecord(type: "TXT", value: "\"v=spf1 mx -all\"", ttl: 3600),
        DNSRecord(type: "SOA", value: "ns1.example.net. hostmaster.example.com. serial 2026101501 refresh 7200 retry 3600 expire 1209600 minimum 300", ttl: 3600),
    ]

    /// Twelve minutes of scans every 10 s; a neighbor's network fades out halfway.
    private static var wifiScans: [(Date, [WiFiObservation])] {
        func ap(_ ssid: String?, _ bssid: String, _ channel: Int, _ band: WiFiBand, _ width: Int, _ security: String,
                _ modes: String, _ rssi: Double, _ noise: Int) -> (WiFiObservation, Double) {
            (WiFiObservation(ssid: ssid, bssid: bssid, rssi: Int(rssi), noise: noise, channel: channel, band: band,
                             width: width, security: security, modes: modes), rssi)
        }
        let aps = [
            ap("Home-5G", "50:c7:bf:3a:91:05", 36, .ghz5, 80, "WPA2/WPA3 Personal", "a/n/ac/ax", -48, -92),
            ap("Home", "50:c7:bf:3a:91:02", 6, .ghz2, 20, "WPA2/WPA3 Personal", "b/g/n/ax", -55, -90),
            ap("Home-6G", "50:c7:bf:3a:91:06", 37, .ghz6, 160, "WPA3 Personal", "ax", -63, -95),
            ap("Neighbor-2.4", "a4:91:b1:22:10:7c", 1, .ghz2, 20, "WPA2 Personal", "b/g/n", -71, -90),
            ap("Neighbor-5", "a4:91:b1:22:10:7d", 44, .ghz5, 80, "WPA2 Personal", "a/n/ac", -78, -92),
            ap(nil, "ce:91:b1:22:10:7e", 44, .ghz5, 80, "WPA2 Personal", "a/n/ac", -80, -92),
            ap("CoffeeShop Guest", "3c:a6:2f:41:08:aa", 11, .ghz2, 20, "Open", "b/g/n", -84, -91),
            ap("Printer-Direct", "b0:45:02:7e:61:19", 11, .ghz2, 20, "WPA2 Personal", "b/g/n", -67, -91),
            ap("Office", "7c:ff:4d:90:12:30", 149, .ghz5, 40, "WPA2 Enterprise", "a/n/ac", -86, -93),
        ]
        let start = Date.now.addingTimeInterval(-720)
        return (0..<72).map { step in
            let date = start.addingTimeInterval(Double(step) * 10)
            let observations = aps.enumerated().compactMap { index, entry -> WiFiObservation? in
                if index == 6, step > 36 { return nil }
                var observation = entry.0
                let wobble = sin(Double(step + index * 7) / 4) * 3 + sin(Double(step * (index + 2)) / 9) * 2
                observation.rssi = Int((entry.1 + wobble).rounded())
                return observation
            }
            return (date, observations)
        }
    }

    private static let whoisAnswers: [(server: String, text: String)] = [
        ("whois.iana.org", """
        domain:       COM
        organisation: Example Registry Services
        whois:        whois.registry.example
        status:       ACTIVE
        """),
        ("whois.registry.example", """
        Domain Name: EXAMPLE.COM
        Registrar: Example Registrar, LLC
        Registrar WHOIS Server: whois.registrar.example
        Creation Date: 1995-08-14T04:00:00Z
        Registry Expiry Date: 2027-08-13T04:00:00Z
        Name Server: NS1.EXAMPLE.NET
        Name Server: NS2.EXAMPLE.NET
        DNSSEC: signedDelegation
        """),
    ]

    private static let nas = IPv4Address("192.168.1.20")!
    private static let tv = IPv4Address("192.168.1.41")!

    private static func host(_ last: UInt8, _ source: DiscoveredHost.Source, latency: Double?, mac: String,
                             vendor: String, bonjour: String? = nil, netbios: String? = nil, dns: String? = nil,
                             computer: String? = nil, name: String? = nil, comment: String? = nil,
                             linkLocal: String? = nil, global: [String] = [],
                             services: [(String, [String: String])] = [], upnp: UPnPDevice? = nil,
                             gateway: Bool = false, hardware: String? = nil, title: String? = nil,
                             seenDaysAgo: Double? = nil, movedFrom: UInt8? = nil) -> DiscoveredHost {
        var host = DiscoveredHost(interface: "en0", address: IPv4Address(raw: 0xC0A8_0100 | UInt32(last)),
                                  source: source, latency: latency, mac: MACAddress(mac), vendor: vendor)
        host.bonjourName = bonjour
        host.netbiosName = netbios
        host.dnsName = dns
        host.computerName = computer
        host.customName = name
        host.comment = comment
        host.ipv6LinkLocal = linkLocal.map { [$0] } ?? []
        host.ipv6Global = global
        host.services = services.map { BonjourService(type: $0.0, name: bonjour ?? "Device", txt: $0.1) }
        host.upnp = upnp
        host.isGateway = gateway
        host.hardwareModel = hardware
        host.webTitle = title
        // Spread over the last months unless given; whole minutes so the column looks natural.
        let days = seenDaysAgo ?? Double(Int(last) % 40) * 4.3 + 12
        host.firstSeen = Date(timeIntervalSinceNow: (-days * 86_400 / 60).rounded() * 60)
        host.lastSeen = .now
        host.addressHistory = [AddressSighting(address: host.address.description, firstSeen: .now, lastSeen: .now)]
        if let movedFrom, let firstSeen = host.firstSeen {
            // DHCP handed it a new address since the previous scan.
            let previous = IPv4Address(raw: 0xC0A8_0100 | UInt32(movedFrom))
            host.previousAddress = previous
            host.addressHistory = [
                AddressSighting(address: host.address.description, firstSeen: .now, lastSeen: .now),
                AddressSighting(address: previous.description, firstSeen: firstSeen, lastSeen: .now.addingTimeInterval(-86_400)),
            ]
        } else if let firstSeen = host.firstSeen {
            host.addressHistory = [AddressSighting(address: host.address.description, firstSeen: firstSeen, lastSeen: .now)]
        }
        return host
    }

    private static let hosts: [DiscoveredHost] = [
        host(1, .icmp, latency: 2.1, mac: "50:c7:bf:3a:91:01", vendor: "TP-Link Systems Inc.", dns: "router.lan",
             name: "Router", linkLocal: "fe80::52c7:bfff:fe3a:9101", global: ["2001:db8:4a2c:100::1"],
             upnp: UPnPDevice(deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1", manufacturer: "TP-Link", modelName: "Archer AX55"),
             gateway: true, title: "Archer AX55"),
        host(10, .local, latency: nil, mac: "3c:22:fb:7e:10:aa", vendor: "Apple, Inc.", bonjour: "Alexs-MacBook-Pro",
             computer: "Alex’s MacBook Pro", linkLocal: "fe80::1c4a:9be2:77d1:3a10",
             global: ["2001:db8:4a2c:100:8d3:4f21:a9c0:1e77", "2001:db8:4a2c:100:5b1e:c2d4:907a:3f02"],
             services: [("_airplay._tcp", [:]), ("_rfb._tcp", [:]), ("_smb._tcp", [:])], hardware: "MacBookPro18,2"),
        host(12, .icmp, latency: 48.3, mac: "6a:1b:3c:4d:5e:12", vendor: "Private (randomized)", bonjour: "Alexs-iPhone",
             linkLocal: "fe80::c81:22ff:fe9a:4412", global: ["2001:db8:4a2c:100:c81:22ff:fe9a:4412"],
             services: [("_companion-link._tcp", ["rpmd": "iPhone15,2"])], movedFrom: 34),
        host(20, .icmp, latency: 0.9, mac: "00:11:32:a4:b2:20", vendor: "Synology Incorporated", bonjour: "DiskStation",
             netbios: "DISKSTATION", name: "Synology NAS", comment: "Backups + Plex",
             linkLocal: "fe80::211:32ff:fea4:b220", global: ["2001:db8:4a2c:100:211:32ff:fea4:b220"],
             services: [("_adisk._tcp", [:]), ("_smb._tcp", [:]), ("_http._tcp", [:])],
             upnp: UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaServer:1", manufacturer: "Synology", modelName: "DS920+"),
             title: "Synology DiskStation"),
        host(25, .icmp, latency: 1.4, mac: "dc:a6:32:5c:18:25", vendor: "Raspberry Pi Trading Ltd", bonjour: "homeassistant",
             name: "Home Assistant", linkLocal: "fe80::dea6:32ff:fe5c:1825",
             services: [("_home-assistant._tcp", [:]), ("_hap._tcp", ["md": "Home Assistant Bridge", "ci": "2"])], title: "Home Assistant"),
        host(30, .icmp, latency: 3.2, mac: "a0:8c:fd:61:2e:30", vendor: "HP Inc.", bonjour: "HP-LaserJet-M234",
             comment: "Office", linkLocal: "fe80::a28c:fdff:fe61:2e30",
             services: [("_ipp._tcp", ["ty": "HP LaserJet M234sdw"]), ("_uscan._tcp", [:])]),
        host(41, .icmp, latency: 6.8, mac: "a8:23:fe:0d:77:41", vendor: "LG Electronics", bonjour: "LGwebOSTV",
             name: "Living Room TV", linkLocal: "fe80::aa23:feff:fe0d:7741", global: ["2001:db8:4a2c:100:aa23:feff:fe0d:7741"],
             services: [("_airplay._tcp", ["model": "OLED55C1PUB"])],
             upnp: UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1", friendlyName: "[LG] webOS TV", manufacturer: "LG Electronics", modelName: "OLED55C1PUB")),
        host(52, .icmp, latency: 4.4, mac: "48:a6:b8:2c:91:52", vendor: "Sonos, Inc.", bonjour: "Sonos-Living-Room",
             linkLocal: "fe80::4aa6:b8ff:fe2c:9152",
             services: [("_sonos._tcp", [:]), ("_spotify-connect._tcp", [:])],
             upnp: UPnPDevice(deviceType: "urn:schemas-upnp-org:device:ZonePlayer:1", manufacturer: "Sonos, Inc.", modelName: "Sonos One", modelNumber: "S18")),
        host(63, .tcp, latency: nil, mac: "d8:bb:c1:44:0e:63", vendor: "Micro-Star INTL Co., Ltd.", netbios: "DESKTOP-7Q2K4LM",
             comment: "Gaming PC", linkLocal: "fe80::5d1c:8a2e:b07f:63c4"),
        host(77, .arp, latency: nil, mac: "bc:ad:28:9f:13:77", vendor: "Hangzhou Hikvision Digital Technology Co.,Ltd.",
             name: "Front Door Camera", comment: "Garage", title: "IPC Web Login", seenDaysAgo: 0.03),
        host(88, .icmp, latency: 12.6, mac: "f4:f5:d8:6b:20:88", vendor: "Google, Inc.", bonjour: "Chromecast-Kitchen",
             linkLocal: "fe80::f6f5:d8ff:fe6b:2088",
             services: [("_googlecast._tcp", ["md": "Chromecast", "fn": "Kitchen"])]),
    ]

    /// Wi-Fi to a TV: mostly 5–10 ms, a couple of spikes and one lost packet.
    private static let tvPings: [Double?] = [
        6.8, 7.2, 5.9, 8.4, 6.1, 9.7, 6.5, 21.4, 6.9, 7.1,
        6.3, nil, 8.9, 6.6, 7.4, 17.6, 6.7, 7.0, 6.2, 8.1,
    ]

    private static let nasPorts: [PortScanModel.Result] = [
        .init(port: 22, state: .open, banner: "OpenSSH 8.2"),
        .init(port: 80, state: .open, webURL: URL(string: "http://192.168.1.20"), banner: "nginx"),
        .init(port: 139, state: .open),
        .init(port: 443, state: .open, webURL: URL(string: "https://192.168.1.20")),
        .init(port: 445, state: .open),
        .init(port: 548, state: .open),
        .init(port: 5000, state: .open, webURL: URL(string: "http://192.168.1.20:5000"), banner: "nginx"),
        .init(port: 5001, state: .open, webURL: URL(string: "https://192.168.1.20:5001")),
        .init(port: 32400, state: .open, webURL: URL(string: "http://192.168.1.20:32400")),
    ]
}
#endif
