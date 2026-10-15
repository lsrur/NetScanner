#if DEBUG
import AppKit
import Foundation

/// Fictional network for README screenshots: `NETSCANNER_DEMO=hosts|ping|ports`.
/// Addresses use private and documentation ranges (192.168.1.0/24, 2001:db8::/32,
/// 203.0.113.0/24); MAC addresses and names are made up.
@MainActor
enum DemoData {
    static func load(_ scene: String, into model: AppModel) {
        model.publicNetwork.loadDemo(PublicNetworkInfo(ipv4: "203.0.113.42", ipv6: "2001:db8:4a2c:100::1f",
                                                       isp: "Example Broadband Co.", countryCode: "US", city: nil))
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
        case "summary":
            model.selectedHostID = nil
        default:
            model.selectedHostID = HostID(interface: "en0", address: nas)
            model.inspectorTab = .info
        }

        NSApp.windows.first { $0.isVisible && $0.frame.width > 500 }?
            .setFrame(NSRect(x: 80, y: 80, width: 1480, height: 860), display: true)
    }

    private static let nas = IPv4Address("192.168.1.20")!
    private static let tv = IPv4Address("192.168.1.41")!

    private static func host(_ last: UInt8, _ source: DiscoveredHost.Source, latency: Double?, mac: String,
                             vendor: String, bonjour: String? = nil, netbios: String? = nil, dns: String? = nil,
                             computer: String? = nil, name: String? = nil, comment: String? = nil,
                             linkLocal: String? = nil, global: [String] = [],
                             services: [(String, [String: String])] = [], upnp: UPnPDevice? = nil,
                             gateway: Bool = false, hardware: String? = nil, title: String? = nil) -> DiscoveredHost {
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
             services: [("_companion-link._tcp", ["rpmd": "iPhone15,2"])]),
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
             name: "Front Door Camera", comment: "Garage", title: "IPC Web Login"),
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
        .init(port: 22, state: .open),
        .init(port: 80, state: .open, webURL: URL(string: "http://192.168.1.20")),
        .init(port: 139, state: .open),
        .init(port: 443, state: .open, webURL: URL(string: "https://192.168.1.20")),
        .init(port: 445, state: .open),
        .init(port: 548, state: .open),
        .init(port: 5000, state: .open, webURL: URL(string: "http://192.168.1.20:5000")),
        .init(port: 5001, state: .open, webURL: URL(string: "https://192.168.1.20:5001")),
        .init(port: 32400, state: .open, webURL: URL(string: "http://192.168.1.20:32400")),
    ]
}
#endif
