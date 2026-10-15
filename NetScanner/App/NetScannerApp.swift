import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let scanner = ScannerModel()
    let ping = PingSession()
    let portLists = PortListStore()
    let ports: PortScanModel
    let tools = NetworkToolsModel()
    let publicNetwork = PublicNetworkModel()
    let speedTest = SpeedTestModel()
    let wifi = WiFiAnalyzerModel()
    var showInspector = true
    /// The host table's filter, typed in the toolbar.
    var hostQuery = ""
    /// Bumped by ⌘F; the toolbar's filter field takes focus when it changes.
    var searchFocusRequests = 0
    var inspectorTab = InspectorTab.info
    /// The saved-scans dialog; opened from the ⌄ menu or the Scan menu.
    var isShowingScanSettings = false
    /// The sidebar selection, remembered across launches.
    var section = AppSection(rawValue: UserDefaults.standard.string(forKey: AppSection.storageKey) ?? "") ?? .lanScan {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: AppSection.storageKey) }
    }

    /// Ping and port scan always target the selected row; Network Tools has its own destination.
    var selectedHostID: HostID? {
        didSet {
            guard oldValue != selectedHostID else { return }
            let target = selectedHostID?.address.description ?? ""
            ping.retarget(target)
            ports.retarget(target)
        }
    }

    var selectedHost: DiscoveredHost? { scanner.host(selectedHostID) }

    init() {
        ports = PortScanModel(lists: portLists)
    }
}

@main
struct NetScannerApp: App {
    @State private var model = AppModel()

    init() {
        ResourceLimits.raiseOpenFileLimit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1440, height: 820)
        .commands {
            SectionCommands(model: model)
            // Scanning commands bring the LAN Scan section forward.
            CommandMenu("Scan") {
                Button(model.scanner.isScanningAny ? "Stop Scan" : "Scan All Interfaces") {
                    model.section = .lanScan
                    if model.scanner.isScanningAny {
                        model.scanner.stopAll()
                    } else {
                        model.scanner.startAllInterfaces()
                    }
                }
                .keyboardShortcut("r")
                Divider()
                // Same items as the toolbar's ⌄ menu.
                ScanMenuItems(scanner: model.scanner, onSelect: { model.section = .lanScan }) {
                    model.section = .lanScan
                    model.isShowingScanSettings = true
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Find Hosts…") {
                    model.section = .lanScan
                    model.searchFocusRequests += 1
                }
                .keyboardShortcut("f")
            }
        }
    }
}

/// One window: the sidebar picks the section shown on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Starts expanded; the toolbar's sidebar button hides it.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(model: model)
        } detail: {
            switch model.section {
            case .lanScan:
                LanScanView()
            case .wifi:
                WiFiAnalyzerView(model: model.wifi)
                    .navigationTitle(AppSection.wifi.title)
            case .internet:
                InternetConnectionView(publicNetwork: model.publicNetwork, speedTest: model.speedTest)
                    .navigationTitle(AppSection.internet.title)
            case .tools:
                NetworkToolsView(model: model.tools)
                    .navigationTitle(AppSection.tools.title)
            }
        }
        // Keeps the interfaces in the ⌄ menu current when Wi-Fi, cable or VPN change.
        .onChange(of: model.publicNetwork.pathChanges) {
            model.scanner.refreshInterfaces()
        }
        #if DEBUG
        // Lets screenshots and manual checks start with real data: NETSCANNER_AUTOSCAN=1,
        // optionally NETSCANNER_SELECT=<ip> to select that host when the scan ends.
        .task {
            let environment = ProcessInfo.processInfo.environment
            if let scene = environment["NETSCANNER_DEMO"] {
                try? await Task.sleep(for: .milliseconds(300))
                DemoData.load(scene, into: model)
                model.section = DemoData.section(for: scene)
                return
            }
            guard environment["NETSCANNER_AUTOSCAN"] == "1" else { return }
            model.section = .lanScan
            for task in model.scanner.startAllInterfaces() { await task.value }
            if let ip = environment["NETSCANNER_SELECT"] {
                model.selectedHostID = model.scanner.hosts.first { $0.address.description == ip }?.id
            }
        }
        #endif
    }
}

/// The host table, its inspector and the scan toolbar.
struct LanScanView: View {
    @Environment(AppModel.self) private var model
    @State private var isExporting = false

    var body: some View {
        @Bindable var model = model
        // Stacked rather than a safe-area inset: the inspector column ignores insets
        // and would scroll under the status bar.
        VStack(spacing: 0) {
            // A classic AppKit split instead of .inspector: on macOS 26 the inspector is a
            // floating glass column and the table keeps the full window width underneath it,
            // so wide tables scroll beneath the panel.
            HSplitView {
                HostTableView(scanner: model.scanner, selection: $model.selectedHostID)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    // Extra width goes to the table; the inspector starts at its ideal width.
                    .layoutPriority(1)
                if model.showInspector {
                    HostInspector()
                        .frame(minWidth: inspectorPanelWidth + 32, maxWidth: 560, maxHeight: .infinity)
                        .background(.background.secondary)
                }
            }
            .toolbar {
                // Leading edge, LanScan style: scan + customize share one control,
                // every other action is its own capsule.
                ToolbarItem(placement: .navigation) {
                    ScanButton(scanner: model.scanner) { model.isShowingScanSettings = true }
                }
                ToolbarItem(placement: .navigation) {
                    Button("Export CSV", systemImage: "square.and.arrow.down") { isExporting = true }
                        .help("Export CSV")
                        .disabled(model.scanner.hosts.isEmpty)
                        .standaloneToolbarButton()
                }
                .standaloneToolbarItem()
                ToolbarItem(placement: .navigation) {
                    Button("Clear Results", systemImage: "trash") {
                        model.selectedHostID = nil
                        model.scanner.clearResults()
                    }
                    .help("Clear results")
                    .disabled(!model.scanner.hasResults)
                    .standaloneToolbarButton()
                }
                .standaloneToolbarItem()
                ToolbarItem(placement: .navigation) {
                    Button("Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
                        .help(model.showInspector ? "Hide Inspector" : "Show Inspector")
                        .standaloneToolbarButton()
                }
                .standaloneToolbarItem()
                ToolbarItem(placement: .navigation) {
                    HostFilterField(model: model)
                }
                .standaloneToolbarItem()
            }

            if StatusBar.isVisible(model: model.publicNetwork, scanner: model.scanner) {
                StatusBar(model: model.publicNetwork, scanner: model.scanner)
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: CSVDocument(text: model.scanner.csv),
                      contentType: .commaSeparatedText,
                      defaultFilename: "hosts.csv") { _ in }
        .sheet(isPresented: $model.isShowingScanSettings) {
            ScanSettingsView(scanner: model.scanner)
        }
    }
}

/// Split button like LanScan's. ▶ scans every interface on its subnet (■ stops). The chevron
/// lists single interfaces, then saved scans, then "Customize…" to edit the saved scans.
private struct ScanButton: View {
    let scanner: ScannerModel
    let customize: () -> Void

    var body: some View {
        // Read here, not only inside the menu: SwiftUI builds menu content when it opens,
        // outside this body, so those reads alone wouldn't refresh it after the dialog saves.
        let interfaces = scanner.interfaces
        let savedScans = scanner.savedScans
        Menu {
            ScanMenuItems(scanner: scanner, interfaces: interfaces, savedScans: savedScans, customize: customize)
        } label: {
            if scanner.isScanningAny {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Label("Scan", systemImage: "play.fill")
            }
        } primaryAction: {
            if scanner.isScanningAny {
                scanner.stopAll()
            } else {
                scanner.startAllInterfaces()
            }
        }
        // No .keyboardShortcut here: on a Menu it is copied onto every item. ⌘R lives in the
        // "Scan" menu-bar menu instead.
        .help(scanner.isScanningAny ? "Stop scanning" : "Scan all interfaces (⌘R)")
        // A new identity whenever the menu's data changes, so AppKit never shows a stale menu.
        .id([AnyHashable(interfaces), AnyHashable(savedScans)])
    }
}

/// Single interfaces, then saved scans, then "Customize…": the ⌄ menu and the Scan menu.
struct ScanMenuItems: View {
    let scanner: ScannerModel
    /// The ⌄ menu passes what its own body already read; the Scan menu reads them here, in a
    /// view body, so Observation rebuilds the menu when they change.
    var interfaces: [NetworkInterface]?
    var savedScans: [ScanTarget]?
    /// Runs before a scan starts from the menu (the Scan menu shows the LAN Scan section).
    var onSelect: () -> Void = {}
    let customize: () -> Void

    var body: some View {
        let interfaces = interfaces ?? scanner.interfaces
        let savedScans = savedScans ?? scanner.savedScans
        ForEach(interfaces) { interface in
            Button("Interface \(interface.name) — \(scanner.defaultSubnet(for: interface).description)") {
                onSelect()
                scanner.start(interface: interface.name)
            }
        }
        Divider()
        if savedScans.isEmpty {
            Text("No Saved Scans")
        }
        ForEach(savedScans) { saved in
            Button("\(saved.displayName) — \(scanner.describe(saved))") {
                onSelect()
                scanner.start([saved])
            }
            .disabled(scanner.plan(for: saved) == nil)
        }
        Divider()
        Button("Customize…", action: customize)
    }
}

/// The host filter as a toolbar capsule next to the buttons (⌘F focuses it, Esc clears it).
private struct HostFilterField: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter hosts", text: $model.hostQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    model.hostQuery = ""
                    isFocused = false
                }
            if !model.hostQuery.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") { model.hostQuery = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 220, height: toolbarControlHeight)
        .toolbarCapsule()
        .help("Filter hosts by IP, MAC, vendor, model, type, name or comment (⌘F)")
        .onChange(of: model.searchFocusRequests) { isFocused = true }
    }
}

/// Height of the glass toolbar buttons (`.extraLarge` circles), so the filter lines up with them.
private let toolbarControlHeight: CGFloat = 36

private extension View {
    @ViewBuilder
    func toolbarCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.quaternary, in: .capsule)
        }
    }
}

/// macOS 26 merges adjacent leading toolbar items into one glass capsule; these give an item
/// its own capsule instead. Earlier systems draw separate buttons anyway.
private extension ToolbarItem {
    @ToolbarContentBuilder
    func standaloneToolbarItem() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

private extension View {
    @ViewBuilder
    func standaloneToolbarButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
        } else {
            self
        }
    }
}
