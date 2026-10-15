import Foundation

/// SSDP discovery (UPnP): an M-SEARCH to 239.255.255.250:1900 makes UPnP devices answer with
/// the URL of their XML description.
enum SSDP {
    struct Response: Equatable, Sendable {
        let address: IPv4Address
        let location: URL?
        let server: String?
        let searchTarget: String?
    }

    static let searchRequest = [
        "M-SEARCH * HTTP/1.1",
        "HOST: 239.255.255.250:1900",
        "MAN: \"ssdp:discover\"",
        "MX: 2",
        "ST: ssdp:all",
        "USER-AGENT: macOS UPnP/1.1 NetScanner",
        "", "",
    ].joined(separator: "\r\n")

    static func discover(interfaceAddress: IPv4Address, timeout: TimeInterval = 2.5) async -> [Response] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: search(from: interfaceAddress, timeout: timeout))
            }
        }
    }

    private static func search(from interfaceAddress: IPv4Address, timeout: TimeInterval) -> [Response] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var outgoing = interfaceAddress.inAddr
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
        var ttl: UInt8 = 2
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var group = sockaddr_in()
        group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        group.sin_family = sa_family_t(AF_INET)
        group.sin_port = UInt16(1900).bigEndian
        group.sin_addr = IPv4Address("239.255.255.250")!.inAddr
        let message = Array(searchRequest.utf8)
        for _ in 0..<2 {  // UDP may drop one
            _ = withUnsafePointer(to: &group) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    message.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }

        var responses: [Response] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, bytes.baseAddress, capacity, 0, $0, &fromLength) }
                }
            }
            guard count > 0 else { continue }
            if let response = parseResponse(String(decoding: buffer[..<count], as: UTF8.self), from: IPv4Address(from.sin_addr)) {
                responses.append(response)
            }
        }
        return responses
    }

    static func parseResponse(_ text: String, from address: IPv4Address) -> Response? {
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("NOTIFY") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Response(address: address, location: headers["LOCATION"].flatMap(URL.init(string:)),
                        server: headers["SERVER"], searchTarget: headers["ST"] ?? headers["NT"])
    }
}

/// The root device of a UPnP description document.
struct UPnPDevice: Hashable, Sendable {
    var deviceType: String?
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var modelNumber: String?
    var modelDescription: String?

    var isEmpty: Bool { self == UPnPDevice() }

    /// "OLED55C1PUB" or "Sonos One (S18)". The number is only added when it looks like one
    /// (some devices put the manufacturer there) and isn't already part of the name.
    var model: String? {
        guard let modelName, !modelName.isEmpty else { return modelNumber }
        guard let modelNumber, modelNumber.contains(where: \.isNumber), !modelName.contains(modelNumber) else { return modelName }
        return "\(modelName) (\(modelNumber))"
    }

    /// "TCL" from "TCL|极光TV".
    var maker: String? {
        manufacturer?.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How useful this description is when a device publishes several: the gateway and DIAL
    /// (cast) descriptions name the product; Wi-Fi Alliance WPS stubs and generic renderers don't.
    var informativeness: Int {
        let type = deviceType?.lowercased() ?? ""
        var score = 1
        if type.contains("internetgatewaydevice") { score += 3 }
        if type.contains("dial") { score += 2 }
        if type.contains("wfadevice") { score -= 3 }
        if manufacturer?.contains("|") == true { score -= 1 }
        return score
    }
}

enum UPnP {
    /// Fetches every description a device published and keeps the most informative one.
    static func describe(_ locations: [URL]) async -> UPnPDevice? {
        await withTaskGroup(of: UPnPDevice?.self) { group in
            for location in locations.prefix(4) {
                group.addTask { await LocalHTTP.get(location).flatMap { parse($0.0) } }
            }
            var best: UPnPDevice?
            for await device in group {
                if let device, device.informativeness > (best?.informativeness ?? .min) { best = device }
            }
            return best
        }
    }

    static func parse(_ data: Data) -> UPnPDevice? {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.device.isEmpty ? nil : delegate.device
    }

    /// Reads fields of the first (root) <device>, ignoring embedded devices.
    private final class DescriptionParser: NSObject, XMLParserDelegate {
        private static let fields: Set<String> = ["deviceType", "friendlyName", "manufacturer", "modelName", "modelNumber", "modelDescription"]
        var device = UPnPDevice()
        private var depth = 0
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if elementName == "device" { depth += 1 }
            if depth == 1, Self.fields.contains(elementName) {
                current = elementName
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == current {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    switch elementName {
                    case "deviceType": device.deviceType = value
                    case "friendlyName": device.friendlyName = value
                    case "manufacturer": device.manufacturer = value
                    case "modelName": device.modelName = value
                    case "modelNumber": device.modelNumber = value
                    default: device.modelDescription = value
                    }
                }
                current = nil
            }
            if elementName == "device" {
                depth -= 1
                if depth == 0 { parser.abortParsing() }
            }
        }
    }
}

/// HTTP(S) to LAN devices: short timeouts and self-signed certificates accepted (routers, NAS and
/// printers rarely have real ones). Plain HTTP is allowed by NSAllowsLocalNetworking.
enum LocalHTTP {
    private final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 4
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScanner"]
        return URLSession(configuration: configuration, delegate: TrustingDelegate(), delegateQueue: nil)
    }()

    /// Body (capped) and response for a 2xx answer, nil otherwise.
    static func get(_ url: URL, maxBytes: Int = 256_000) async -> (Data, HTTPURLResponse)? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (data.prefix(maxBytes), http)
    }
}

/// The <title> of a device's web interface ("Synology DiskStation", "OpenWrt - LuCI"…).
enum WebTitle {
    static func fetch(_ address: IPv4Address) async -> String? {
        for scheme in ["http", "https"] {
            if let url = URL(string: "\(scheme)://\(address)/"),
               let (data, _) = await LocalHTTP.get(url), let title = extract(from: data) {
                return title
            }
        }
        return nil
    }

    static func extract(from data: Data) -> String? {
        let html = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let title = decodeEntities(String(html[range]))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return title.count > 80 ? String(title.prefix(79)) + "…" : title
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result) else { continue }
            let isHex = match.range(at: 1).length > 0
            if let value = UInt32(result[digits], radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }
}
