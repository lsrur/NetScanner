import Foundation

enum DeviceKind: String, CaseIterable, Sendable {
    case router = "Router"
    case computer = "Computer"
    case laptop = "Laptop"
    case phone = "Phone"
    case tablet = "Tablet"
    case watch = "Watch"
    case tv = "TV"
    case mediaPlayer = "Media Player"
    case speaker = "Speaker"
    case printer = "Printer"
    case nas = "NAS"
    case camera = "Camera"
    case smartHome = "Smart Home"
    case console = "Game Console"
    case unknown = "Unknown"

    var systemImage: String {
        switch self {
        case .router: "wifi.router"
        case .computer: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .watch: "applewatch"
        case .tv: "tv"
        case .mediaPlayer: "appletv"
        case .speaker: "hifispeaker"
        case .printer: "printer"
        case .nas: "externaldrive.connected.to.line.below"
        case .camera: "web.camera"
        case .smartHome: "homekit"
        case .console: "gamecontroller"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Guesses what a host is from everything the scan learned. Rules run from the most to the least
/// reliable evidence: this Mac and the gateway, model identifiers, advertised services, names
/// (including the user's), UPnP device type, vendor, and finally weak hints.
enum DeviceClassifier {
    static func kind(for host: DiscoveredHost) -> DeviceKind {
        let model = (host.model ?? "").lowercased()
        if host.source == .local { return model.contains("book") ? .laptop : .computer }
        if host.isGateway { return .router }
        if let apple = appleKind(model) { return apple }

        let types = Set(host.services.map(\.type))
        if !types.isDisjoint(with: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_uscan._tcp"]) {
            return .printer
        }
        if let category = host.services.first(where: { $0.type == "_hap._tcp" })?.txt["ci"].flatMap(Int.init) {
            switch category {  // HomeKit accessory categories
            case 17, 18: return .camera
            case 31: return .tv
            case 26: return .speaker
            case 33: return .router
            default: break
            }
        }
        let names = searchableNames(host)
        if types.contains("_googlecast._tcp") {
            if names.contains(where: { $0.contains("tv") }) { return .tv }
            if names.contains(where: { $0.contains("nest") || $0.contains("home") || $0.contains("speaker") || $0.contains("audio") }) {
                return .speaker
            }
            return .mediaPlayer
        }
        if !types.isDisjoint(with: ["_androidtvremote2._tcp", "_amzn-wplay._tcp"]) { return .tv }
        if types.contains("_sonos._tcp") { return .speaker }

        if let kind = kindFromNames(names) { return kind }
        if let kind = kindFromUPnP(host.upnp, names: names) { return kind }
        if let kind = kindFromVendor((host.vendor ?? "").lowercased()) { return kind }
        if !types.isDisjoint(with: ["_hap._tcp", "_homekit._tcp", "_home-assistant._tcp", "_esphomelib._tcp",
                                    "_matter._tcp", "_hue._tcp", "_shelly._tcp", "_mqtt._tcp"]) {
            return .smartHome
        }
        if host.netbiosName != nil
            || !types.isDisjoint(with: ["_rfb._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_workstation._tcp", "_smb._tcp", "_afpovertcp._tcp"]) {
            return .computer
        }
        // Phones and tablets use randomized "private" MACs by default.
        if host.mac?.isLocallyAdministered == true { return .phone }
        return .unknown
    }

    /// Model from the most specific source (this Mac's hardware, Bonjour TXT records, UPnP),
    /// prefixed with the UPnP manufacturer when the model doesn't already name it.
    static func model(for host: DiscoveredHost) -> String? {
        if let hardware = host.hardwareModel { return friendlyAppleModel(hardware) }
        guard let base = baseModel(for: host) else { return nil }
        if let maker = host.upnp?.maker, !base.lowercased().contains(maker.lowercased()), base == friendlyAppleModel(base) {
            return "\(maker) \(base)"
        }
        return base
    }

    private static func baseModel(for host: DiscoveredHost) -> String? {
        let preferred = ["_device-info._tcp", "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_ipp._tcp", "_ipps._tcp",
                         "_printer._tcp", "_pdl-datastream._tcp", "_hap._tcp", "_companion-link._tcp"]
        let services = host.services.sorted { (preferred.firstIndex(of: $0.type) ?? 99) < (preferred.firstIndex(of: $1.type) ?? 99) }
        for service in services {
            for key in ["model", "md", "ty", "am", "rpmd", "product", "usb_mdl"] {
                guard var value = service.txt[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
                if key == "product" { value = value.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
                return friendlyAppleModel(value)
            }
        }
        return host.upnp?.model
    }

    /// "MacBookPro18,2" → "MacBook Pro (MacBookPro18,2)"; anything else unchanged.
    static func friendlyAppleModel(_ identifier: String) -> String {
        let families = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("iMac", "iMac"),
                        ("Macmini", "Mac mini"), ("MacStudio", "Mac Studio"), ("MacPro", "Mac Pro"), ("Mac", "Mac"),
                        ("iPhone", "iPhone"), ("iPad", "iPad"), ("AppleTV", "Apple TV"), ("AudioAccessory", "HomePod"),
                        ("Watch", "Apple Watch"), ("iPod", "iPod")]
        for (prefix, name) in families where identifier.hasPrefix(prefix) {
            guard identifier.dropFirst(prefix.count).first?.isNumber == true else { continue }
            return "\(name) (\(identifier))"
        }
        return identifier
    }

    private static func appleKind(_ model: String) -> DeviceKind? {
        if model.contains("macbook") { return .laptop }
        if model.hasPrefix("imac") || model.hasPrefix("mac mini") || model.hasPrefix("mac studio") || model.hasPrefix("mac pro")
            || model.hasPrefix("mac (") { return .computer }
        if model.hasPrefix("iphone") { return .phone }
        if model.hasPrefix("ipad") { return .tablet }
        if model.hasPrefix("apple tv") { return .mediaPlayer }
        if model.hasPrefix("homepod") { return .speaker }
        if model.hasPrefix("apple watch") { return .watch }
        return nil
    }

    /// Every name and label we know, lowercased.
    private static func searchableNames(_ host: DiscoveredHost) -> [String] {
        let candidates: [String?] = [
            host.customName, host.computerName, host.advertisedName, host.bonjourName, host.netbiosName, host.dnsName,
            host.upnp?.friendlyName, host.upnp?.modelName, host.upnp?.modelDescription, host.webTitle, host.model,
        ]
        return candidates.compactMap { $0?.lowercased() }
    }

    private static let nameRules: [(DeviceKind, [String])] = [
        (.phone, ["iphone", "android", "galaxy-s", "galaxy s", "pixel", "oneplus", "redmi", "xiaomi", "motorola"]),
        (.tablet, ["ipad", "galaxy-tab", "galaxy tab", "kindle", "fire hd"]),
        (.laptop, ["macbook", "laptop", "notebook", "thinkpad"]),
        (.mediaPlayer, ["chromecast", "apple-tv", "appletv", "apple tv", "shield", "fire-tv", "firetv", "fire tv", "roku"]),
        (.tv, ["webos", "bravia", "smart tv", "smarttv", "television", "-tv", " tv", "_tv"]),
        (.speaker, ["sonos", "homepod", "echo", "nest-mini", "nest mini", "nest-audio", "nest audio", "speaker", "soundbar"]),
        (.printer, ["printer", "laserjet", "officejet", "deskjet", "envy", "pixma", "epson", "brother", "mfc-"]),
        (.nas, ["diskstation", "synology", "qnap", "truenas", "unraid", " nas", "nas-", "-nas", "nas "]),
        (.camera, ["camera", "doorbell", "ipcam", "-cam", " cam", "cam-", "nvr", "dvr"]),
        (.console, ["xbox", "playstation", "ps4", "ps5", "nintendo"]),
        (.smartHome, ["homeassistant", "home assistant", "home-assistant", "hue bridge", "esphome", "esp32", "esp8266",
                      "shelly", "tasmota", "zigbee", "thermostat"]),
        (.router, ["router", "gateway", "access point", "openwrt", "unifi", "mikrotik", "luci"]),
        (.computer, ["desktop-", "imac", "mac-mini", "macmini", "workstation", "-pc", "pc-", "raspberrypi"]),
    ]

    private static func kindFromNames(_ names: [String]) -> DeviceKind? {
        for (kind, keywords) in nameRules where names.contains(where: { name in
            keywords.contains { name.contains($0) } || (kind == .tv && name.hasSuffix("tv"))
        }) {
            return kind
        }
        return nil
    }

    private static func kindFromUPnP(_ device: UPnPDevice?, names: [String]) -> DeviceKind? {
        guard let type = device?.deviceType?.lowercased() else { return nil }
        if type.contains("internetgatewaydevice") || type.contains("wlanaccesspoint") { return .router }
        if type.contains("printer") { return .printer }
        if type.contains("camera") { return .camera }
        if type.contains("zoneplayer") { return .speaker }
        if type.contains("mediarenderer") { return .mediaPlayer }
        if type.contains("mediaserver") { return .nas }
        return nil
    }

    private static let vendorRules: [(DeviceKind, [String])] = [
        (.nas, ["synology", "qnap", "western digital", "asustor", "buffalo"]),
        (.camera, ["hikvision", "dahua", "reolink", "axis communications", "wyze", "amcrest", "ezviz", "arlo", "ring llc"]),
        (.printer, ["hp inc", "hewlett", "canon", "seiko epson", "epson", "brother", "xerox", "lexmark", "kyocera", "ricoh"]),
        (.speaker, ["sonos", "bose", "denon", "harman"]),
        (.mediaPlayer, ["roku"]),
        (.console, ["nintendo", "sony interactive"]),
        (.smartHome, ["espressif", "tuya", "shelly", "allterco", "signify", "philips lighting", "ecobee", "nest labs", "lifx", "ikea"]),
        (.router, ["ubiquiti", "mikrotik", "eero", "aruba", "cisco", "juniper", "netgear"]),
        (.computer, ["raspberry pi", "micro-star", "gigabyte", "intel corporate", "dell", "lenovo"]),
    ]

    private static func kindFromVendor(_ vendor: String) -> DeviceKind? {
        guard !vendor.isEmpty else { return nil }
        return vendorRules.first { $0.1.contains { vendor.contains($0) } }?.0
    }
}
