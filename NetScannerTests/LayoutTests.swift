import AppKit
import SwiftUI
import Testing
@testable import NetScanner

@MainActor
struct LayoutTests {
    /// Switching between Ping and Puertos must not resize the inspector column.
    @Test func inspectorPanelsShareIdealWidth() {
        let ping = NSHostingView(rootView: PingPanel(session: PingSession()).inspectorPanelFrame()).fittingSize
        let ports = NSHostingView(rootView: PortScanPanel(model: PortScanModel(lists: PortListStore(defaults: UserDefaults(suiteName: "layout")!))).inspectorPanelFrame()).fittingSize
        #expect(ping.width == ports.width)
        #expect(ping.width == inspectorPanelWidth)
    }

    /// The ideal width alone isn't enough: if a panel's minimum exceeds the inspector width,
    /// the column grows when that tab is shown ("100 más comunes" next to Timeout did that).
    @Test func inspectorPanelsFitWithinPanelWidth() {
        func minimumWidth(_ view: some View) -> CGFloat {
            NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1, height: 2000)).width
        }
        #expect(minimumWidth(PingPanel(session: PingSession()).inspectorPanelFrame()) <= inspectorPanelWidth)
        #expect(minimumWidth(PortScanPanel(model: PortScanModel(lists: PortListStore(defaults: UserDefaults(suiteName: "layout")!))).inspectorPanelFrame()) <= inspectorPanelWidth)
        var host = DiscoveredHost(interface: "en0", address: IPv4Address("192.168.0.63")!, source: .local)
        host.ipv6Global = ["2001:db8:1:2:aaaa:bbbb:cccc:1", "2001:db8:1:2:aaaa:bbbb:cccc:2"]
        host.bonjourName = "Android_0123456789abcdef0123456789abcdef"
        #expect(minimumWidth(HostDetails(host: host).inspectorPanelFrame()) <= inspectorPanelWidth)
        // A long user-defined list name must not widen the panel either.
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = PortListStore(defaults: defaults)
        store.setLists([PortList(name: "Una lista con un nombre larguísimo para probar el ancho", ports: "22")])
        #expect(minimumWidth(PortScanPanel(model: PortScanModel(lists: store)).inspectorPanelFrame()) <= inspectorPanelWidth)
    }
}
