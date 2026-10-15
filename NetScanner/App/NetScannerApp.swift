import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let scanner = ScannerModel()
    let ping = PingSession()
    let portLists = PortListStore()
    let ports: PortScanModel
    let trace = TraceSession()
    let lookup = LookupModel()
    let publicNetwork = PublicNetworkModel()
    var showInspector = true
    /// The host table's filter, typed in the toolbar.
    var hostQuery = ""
    /// Bumped by ⌘F; the toolbar's filter field takes focus when it changes.
    var searchFocusRequests = 0
    var inspectorTab = InspectorTab.info

    /// Ping and port scan always target the selected row.
    var selectedHostID: HostID? {
        didSet {
            guard oldValue != selectedHostID else { return }
            let target = selectedHostID?.address.description ?? ""
            ping.retarget(target)
            ports.retarget(target)
            trace.retarget(target)
            lookup.retarget(target)
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
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandMenu("Scan") {
                Button(model.scanner.isScanningAny ? "Stop Scan" : "Scan All Interfaces") {
                    if model.scanner.isScanningAny {
                        model.scanner.stopAll()
                    } else {
                        model.scanner.startAllInterfaces()
                    }
                }
                .keyboardShortcut("r")
            }
            CommandGroup(after: .textEditing) {
                Button("Find Hosts…") { model.searchFocusRequests += 1 }
                    .keyboardShortcut("f")
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingScanSettings = false
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
                    ScanButton(scanner: model.scanner, isShowingSettings: $isShowingScanSettings)
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

            StatusBar(model: model.publicNetwork, scanner: model.scanner)
        }
        .fileExporter(isPresented: $isExporting,
                      document: CSVDocument(text: model.scanner.csv),
                      contentType: .commaSeparatedText,
                      defaultFilename: "hosts.csv") { _ in }
        .sheet(isPresented: $isShowingScanSettings) {
            ScanSettingsView(scanner: model.scanner)
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
                return
            }
            guard environment["NETSCANNER_AUTOSCAN"] == "1" else { return }
            for task in model.scanner.startAllInterfaces() { await task.value }
            if let ip = environment["NETSCANNER_SELECT"] {
                model.selectedHostID = model.scanner.hosts.first { $0.address.description == ip }?.id
            }
        }
        #endif
    }
}

/// Split button like LanScan's. ▶ scans every interface on its subnet (■ stops). The chevron
/// lists single interfaces, then saved scans, then "Customize…" to edit the saved scans.
private struct ScanButton: View {
    let scanner: ScannerModel
    @Binding var isShowingSettings: Bool

    var body: some View {
        // Read here, not only inside the menu: SwiftUI builds menu content when it opens,
        // outside this body, so those reads alone wouldn't refresh it after the dialog saves.
        let interfaces = scanner.interfaces
        let savedScans = scanner.savedScans
        Menu {
            ForEach(interfaces) { interface in
                Button("Interface \(interface.name) — \(scanner.defaultSubnet(for: interface).description)") {
                    scanner.start(interface: interface.name)
                }
            }
            Divider()
            if savedScans.isEmpty {
                Text("No Saved Scans")
            }
            ForEach(savedScans) { saved in
                Button("\(saved.displayName) — \(scanner.describe(saved))") {
                    scanner.start([saved])
                }
                .disabled(scanner.plan(for: saved) == nil)
            }
            Divider()
            Button("Customize…") { isShowingSettings = true }
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
