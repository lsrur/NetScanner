import SwiftUI

/// Tools that aren't tied to a host of the LAN (their targets are usually on the internet),
/// each in its own window, opened from the toolbar's 🔧 menu or the Tools menu.
enum NetworkTool: String, CaseIterable, Identifiable {
    case traceroute
    case dns
    case whois

    var id: Self { self }
    var windowID: String { "tool-\(rawValue)" }

    var title: String {
        switch self {
        case .traceroute: "Traceroute"
        case .dns: "DNS Lookup"
        case .whois: "Whois"
        }
    }

    var systemImage: String {
        switch self {
        case .traceroute: "point.topleft.down.to.point.bottomright.curvepath"
        case .dns: "network"
        case .whois: "doc.text.magnifyingglass"
        }
    }
}

/// Minimum size of a tool window.
let toolWindowMinSize = CGSize(width: 420, height: 380)

extension View {
    func toolWindowFrame() -> some View {
        padding()
            .frame(minWidth: toolWindowMinSize.width, maxWidth: .infinity,
                   minHeight: toolWindowMinSize.height, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The three windows, one per tool. `Window` (not `WindowGroup`): reopening a tool brings back
/// its single window with the last results.
struct NetworkToolScenes: Scene {
    let model: AppModel

    var body: some Scene {
        Window(NetworkTool.traceroute.title, id: NetworkTool.traceroute.windowID) {
            TracePanel(session: model.trace).toolWindowFrame()
        }
        .defaultSize(width: 520, height: 520)
        Window(NetworkTool.dns.title, id: NetworkTool.dns.windowID) {
            DNSLookupPanel(model: model.dnsLookup).toolWindowFrame()
        }
        .defaultSize(width: 560, height: 480)
        Window(NetworkTool.whois.title, id: NetworkTool.whois.windowID) {
            WhoisPanel(model: model.whois).toolWindowFrame()
        }
        .defaultSize(width: 620, height: 620)
    }
}

/// Menu bar: Tools → Traceroute… / DNS Lookup… / Whois…
struct NetworkToolCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            ForEach(NetworkTool.allCases) { tool in
                Button(tool.title + "…") { openWindow(id: tool.windowID) }
            }
        }
    }
}

/// Toolbar: a button that drops down the same three tools.
struct NetworkToolsMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Network Tools", systemImage: "wrench.and.screwdriver") {
            ForEach(NetworkTool.allCases) { tool in
                Button(tool.title + "…", systemImage: tool.systemImage) { openWindow(id: tool.windowID) }
            }
        }
        .menuIndicator(.hidden)
        .help("Network tools: traceroute, DNS lookup and whois")
    }
}
