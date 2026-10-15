import Observation
import SwiftUI

/// Tools that aren't tied to a host of the LAN; their destinations are usually on the internet.
enum NetworkTool: String, CaseIterable, Identifiable {
    case ping
    case traceroute
    case dns
    case whois

    var id: Self { self }

    var title: String {
        switch self {
        case .ping: "Ping"
        case .traceroute: "Traceroute"
        case .dns: "DNS Lookup"
        case .whois: "Whois"
        }
    }
}

/// One destination, the tools checked for it, run one after the other.
@MainActor
@Observable
final class NetworkToolsModel {
    enum Status { case idle, waiting, running, done }

    var destination = ""
    var enabled: Set<NetworkTool> = Set(NetworkTool.allCases)
    var selectedTab: NetworkTool?

    let ping: PingSession = {
        let session = PingSession()
        session.count = 5
        return session
    }()
    let trace = TraceSession()
    let dns = DNSLookupModel()
    let whois = WhoisModel()

    /// The tools of the last run, in order: one tab each.
    private(set) var tabs: [NetworkTool] = []
    private(set) var isRunning = false
    private var statuses: [NetworkTool: Status] = [:]
    private var task: Task<Void, Never>?
    private var runID = 0

    var canRun: Bool {
        !destination.trimmingCharacters(in: .whitespaces).isEmpty && !enabled.isEmpty
    }

    func status(of tool: NetworkTool) -> Status { statuses[tool] ?? .idle }

    func run() {
        let target = destination.trimmingCharacters(in: .whitespaces)
        guard canRun else { return }
        task?.cancel()
        let tools = NetworkTool.allCases.filter(enabled.contains)
        ping.clear()
        trace.clear()
        dns.clear()
        whois.clear()
        tabs = tools
        statuses = Dictionary(uniqueKeysWithValues: tools.map { ($0, .waiting) })
        if selectedTab.map(tools.contains) != true { selectedTab = tools.first }
        isRunning = true
        runID += 1
        let runID = runID
        task = Task {
            for tool in tools {
                guard !Task.isCancelled else { break }
                statuses[tool] = .running
                switch tool {
                case .ping: await ping.ping(target)
                case .traceroute: await trace.trace(target)
                case .dns: await dns.lookup(target)
                case .whois: await whois.lookup(target)
                }
                if self.runID == runID { statuses[tool] = .done }
            }
            guard self.runID == runID else { return }
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        runID += 1
        isRunning = false
        // What already finished keeps its ✓; the rest go back to idle.
        statuses = statuses.filter { $0.value == .done }
    }
}

#if DEBUG
extension NetworkToolsModel {
    /// Finished results of every tool, for screenshots.
    func loadDemo(destination: String, tab: NetworkTool) {
        self.destination = destination
        tabs = NetworkTool.allCases
        statuses = Dictionary(uniqueKeysWithValues: tabs.map { ($0, .done) })
        selectedTab = tab
    }
}
#endif

/// Minimum size of the Network Tools section (the tool options fit on one line).
let toolWindowMinSize = CGSize(width: 680, height: 440)

struct NetworkToolsView: View {
    @Bindable var model: NetworkToolsModel
    @Bindable var ping: PingSession
    @Bindable var trace: TraceSession
    @Bindable var dns: DNSLookupModel

    init(model: NetworkToolsModel) {
        self.model = model
        ping = model.ping
        trace = model.trace
        dns = model.dns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Destination", text: $model.destination, prompt: Text("Domain or IP address"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !model.isRunning { model.run() } }
                Button(action: { model.isRunning ? model.stop() : model.run() }) {
                    Label(model.isRunning ? "Stop" : "Run", systemImage: model.isRunning ? "stop.fill" : "play.fill")
                        .frame(minWidth: 60)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.isRunning && !model.canRun)
            }
            // One line: each tool's checkbox followed by its option.
            HStack(spacing: 22) {
                HStack(spacing: 6) {
                    toggle(.ping)
                    Picker("Count", selection: $ping.count) {
                        ForEach([3, 5, 10, 20, 50], id: \.self) { Text("\($0) pings").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Number of echo requests, one per second")
                }
                HStack(spacing: 6) {
                    toggle(.traceroute)
                    Picker("Max hops", selection: $trace.maxHops) {
                        ForEach([15, 30, 64], id: \.self) { Text("\($0) hops").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Maximum number of hops")
                }
                HStack(spacing: 6) {
                    toggle(.dns)
                    Picker("Record type", selection: $dns.recordType) {
                        ForEach(DNSLookup.RecordType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Record type. An IPv4 address is always looked up as PTR.")
                }
                toggle(.whois)
            }
            .disabled(model.isRunning)

            if model.tabs.isEmpty {
                ContentUnavailableView("No Results Yet", systemImage: "network",
                                       description: Text("Type a domain or IP address, check the tools to run and press Run."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Results", selection: $model.selectedTab) {
                    ForEach(model.tabs) { Text(tabTitle($0)).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                Group {
                    switch model.selectedTab {
                    case .ping: PingResultsView(session: model.ping, statColumns: 4)
                    case .traceroute: TraceResultsView(session: model.trace)
                    case .dns: DNSResultsView(model: model.dns)
                    case .whois: WhoisResultsView(model: model.whois)
                    case nil: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .frame(minWidth: toolWindowMinSize.width, maxWidth: .infinity,
               minHeight: toolWindowMinSize.height, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggle(_ tool: NetworkTool) -> some View {
        Toggle(tool.title, isOn: Binding(
            get: { model.enabled.contains(tool) },
            set: { isOn in
                if isOn { model.enabled.insert(tool) } else { model.enabled.remove(tool) }
            }))
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    /// "Traceroute", "DNS Lookup …" while it runs, "Whois ✓" when done.
    private func tabTitle(_ tool: NetworkTool) -> String {
        switch model.status(of: tool) {
        case .idle, .waiting: tool.title
        case .running: tool.title + " …"
        case .done: tool.title + " ✓"
        }
    }
}
