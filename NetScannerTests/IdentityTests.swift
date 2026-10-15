import Darwin
import Foundation
import Testing
@testable import NetScanner

struct BonjourParsingTests {
    @Test func parsesTXTRecords() {
        let entries = ["md=Smart TV", "fn=Living Room", "flag", "", "MD=ignored duplicate"]
        let bytes = entries.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
        let txt = BonjourBrowser.parseTXT(bytes)
        #expect(txt["md"] == "Smart TV")
        #expect(txt["fn"] == "Living Room")
        #expect(txt["flag"] == "")
        #expect(txt.count == 3)
        #expect(BonjourBrowser.parseTXT([9, 65]).isEmpty)
    }

    @Test func everyKnownTypeIsDeclaredInInfoPlist() {
        let declared = Set(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? [])
        let missing = Set(BonjourBrowser.knownTypes.keys).union([BonjourBrowser.metaQueryType]).subtracting(declared)
        #expect(missing.isEmpty, "Add to NSBonjourServices in project.yml: \(missing.sorted())")
    }
}

struct UPnPParsingTests {
    @Test func parsesSSDPResponse() throws {
        let text = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://192.168.1.1:49152/desc.xml\r\nSERVER: Linux UPnP/1.0\r\nST: upnp:rootdevice\r\n\r\n"
        let response = try #require(SSDP.parseResponse(text, from: IPv4Address("192.168.1.1")!))
        #expect(response.location?.absoluteString == "http://192.168.1.1:49152/desc.xml")
        #expect(response.searchTarget == "upnp:rootdevice")
        #expect(SSDP.parseResponse("M-SEARCH * HTTP/1.1\r\n\r\n", from: IPv4Address("192.168.1.1")!) == nil)
    }

    @Test func parsesRootDeviceIgnoringEmbeddedOnes() throws {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
          <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
          <friendlyName>Example Router</friendlyName><manufacturer>ExampleCorp</manufacturer>
          <modelName>XR-500</modelName><modelNumber>ExampleCorp</modelNumber>
          <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
            <friendlyName>WAN</friendlyName></device></deviceList>
        </device></root>
        """
        let device = try #require(UPnP.parse(Data(xml.utf8)))
        #expect(device.friendlyName == "Example Router")
        #expect(device.deviceType?.hasSuffix("InternetGatewayDevice:1") == true)
        #expect(device.model == "XR-500")  // a non-numeric "model number" is dropped
        #expect(UPnP.parse(Data("not xml".utf8)) == nil)
    }

    @Test func prefersInformativeDescriptions() {
        let wps = UPnPDevice(deviceType: "urn:schemas-wifialliance-org:device:WFADevice:1", friendlyName: "WFADevice")
        let gateway = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1", friendlyName: "Router")
        let renderer = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1", manufacturer: "Maker|Brand")
        let dial = UPnPDevice(deviceType: "urn:dial-multiscreen-org:device:dial:1", manufacturer: "Maker")
        #expect(gateway.informativeness > wps.informativeness)
        #expect(dial.informativeness > renderer.informativeness)
        #expect(renderer.maker == "Maker")
        #expect(UPnPDevice(modelName: "Sonos One", modelNumber: "S18").model == "Sonos One (S18)")
    }

    @Test func extractsWebTitles() {
        #expect(WebTitle.extract(from: Data("<html><head><TITLE>\n  Synology&nbsp;DiskStation </TITLE>".utf8)) == "Synology DiskStation")
        #expect(WebTitle.extract(from: Data("<title>A &amp; B &#8211; C &#x41;</title>".utf8)) == "A & B – C A")
        #expect(WebTitle.extract(from: Data("<title>  </title>".utf8)) == nil)
        #expect(WebTitle.extract(from: Data("<p>no title</p>".utf8)) == nil)
    }
}

struct DefaultGatewayParsingTests {
    /// rt_msghdr + DST, GATEWAY and (truncated) NETMASK sockaddrs.
    private func route(index: UInt16, destination: [UInt8], gateway: [UInt8], maskLength: UInt8 = 0) -> [UInt8] {
        let header = MemoryLayout<rt_msghdr>.size
        func sin(_ ip: [UInt8]) -> [UInt8] { [16, UInt8(AF_INET), 0, 0] + ip + [UInt8](repeating: 0, count: 8) }
        let mask: [UInt8] = maskLength == 0 ? [0, 0, 0, 0] : [8, 0, 0, 0, 255, 255, 255, 0]
        let body = sin(destination) + sin(gateway) + mask
        var bytes = [UInt8](repeating: 0, count: header)
        bytes[0] = UInt8((header + body.count) & 0xFF)
        bytes[1] = UInt8((header + body.count) >> 8)
        let indexOffset = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_index)!
        bytes[indexOffset] = UInt8(index & 0xFF)
        let addrsOffset = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_addrs)!
        bytes[addrsOffset] = UInt8(RTA_DST | RTA_GATEWAY | RTA_NETMASK)
        return bytes + body
    }

    @Test func findsDefaultRoutesOnly() {
        let data = route(index: 14, destination: [0, 0, 0, 0], gateway: [192, 168, 1, 1])
            + route(index: 14, destination: [10, 0, 0, 0], gateway: [192, 168, 1, 254], maskLength: 8)
            + route(index: 7, destination: [0, 0, 0, 0], gateway: [10, 8, 0, 1])
        let routes = DefaultGateway.parse(data)
        #expect(routes.map(\.interfaceIndex) == [14, 7])
        #expect(routes.map(\.gateway.description) == ["192.168.1.1", "10.8.0.1"])
    }
}

struct DeviceClassifierTests {
    private func host(_ last: UInt8 = 50, vendor: String? = nil, mac: String? = "00:11:22:33:44:55",
                      services: [BonjourService] = [], upnp: UPnPDevice? = nil, name: String? = nil) -> DiscoveredHost {
        var host = DiscoveredHost(interface: "en0", address: IPv4Address(raw: 0xC0A8_0100 | UInt32(last)), source: .icmp,
                                  mac: mac.flatMap(MACAddress.init), vendor: vendor)
        host.services = services
        host.upnp = upnp
        host.bonjourName = name
        return host
    }

    private func service(_ type: String, _ txt: [String: String] = [:], name: String = "Device") -> BonjourService {
        BonjourService(type: type, name: name, txt: txt)
    }

    @Test func gatewayAndThisMac() {
        var gateway = host(1, vendor: "Example Corp")
        gateway.isGateway = true
        #expect(gateway.kind == .router)
        var mac = DiscoveredHost(interface: "en0", address: IPv4Address("192.168.1.10")!, source: .local)
        mac.hardwareModel = "MacBookPro18,2"
        #expect(mac.kind == .laptop)
        #expect(mac.model == "MacBook Pro (MacBookPro18,2)")
    }

    @Test func appleModelsFromTXT() {
        #expect(host(services: [service("_airplay._tcp", ["model": "AppleTV14,1"])]).kind == .mediaPlayer)
        #expect(host(services: [service("_airplay._tcp", ["model": "AudioAccessory5,1"])]).kind == .speaker)
        #expect(host(services: [service("_device-info._tcp", ["model": "iPad13,4"])]).kind == .tablet)
        #expect(host(services: [service("_raop._tcp", ["am": "Mac14,3"])]).kind == .computer)
    }

    @Test func servicesDecide() {
        #expect(host(services: [service("_ipp._tcp", ["ty": "Example LaserJet 200"])]).kind == .printer)
        #expect(host(services: [service("_ipp._tcp", ["ty": "Example LaserJet 200"])]).model == "Example LaserJet 200")
        #expect(host(services: [service("_googlecast._tcp", ["md": "Smart TV", "fn": "Living Room"])]).kind == .tv)
        #expect(host(services: [service("_googlecast._tcp", ["md": "Google Nest Mini"])]).kind == .speaker)
        #expect(host(services: [service("_googlecast._tcp", ["md": "Chromecast"])]).kind == .mediaPlayer)
        #expect(host(services: [service("_hap._tcp", ["ci": "17", "md": "Doorbell"])]).kind == .camera)
        #expect(host(services: [service("_esphomelib._tcp")]).kind == .smartHome)
    }

    @Test func advertisedNameAndMakerModel() {
        let tv = host(services: [service("_googlecast._tcp", ["md": "Smart TV", "fn": "Living Room"], name: "Smart-TV-0123")],
                      upnp: UPnPDevice(manufacturer: "Maker|Brand"))
        #expect(tv.advertisedName == "Living Room")
        #expect(tv.hostname == "Living Room")
        #expect(tv.model == "Maker Smart TV")
        let speaker = host(services: [service("_raop._tcp", name: "0011223344@Kitchen")])
        #expect(speaker.advertisedName == "Kitchen")
    }

    @Test func namesUPnPAndVendorFallbacks() {
        #expect(host(name: "DESKTOP-ABC123").kind == .computer)
        #expect(host(name: "Galaxy-S23").kind == .phone)
        #expect(host(upnp: UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaServer:1")).kind == .nas)
        #expect(host(vendor: "Synology Incorporated").kind == .nas)
        #expect(host(vendor: "Hangzhou Hikvision Digital Technology").kind == .camera)
        #expect(host(vendor: "Espressif Inc.").kind == .smartHome)
        #expect(host(mac: "6a:1b:3c:4d:5e:12").kind == .phone)  // randomized MAC, nothing else known
        #expect(host(vendor: "Example Widgets").kind == .unknown)
    }
}
