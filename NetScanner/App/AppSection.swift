import SwiftUI

/// The sidebar: every part of the app lives in the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case lanScan
    case wifi
    case internet
    case tools

    var id: Self { self }

    var title: String {
        switch self {
        case .lanScan: "LAN Scan"
        case .wifi: "Wi-Fi Analyzer"
        case .internet: "Internet Connection"
        case .tools: "Network Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .lanScan: "network"
        case .wifi: "wifi"
        case .internet: "globe"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// ⌘1…⌘4 in the View menu.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((AppSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    static let storageKey = "selectedSection"
}

/// View → LAN Scan / Wi-Fi Analyzer / Internet Connection / Network Tools.
struct SectionCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(section.shortcut)
            }
            Divider()
        }
    }
}

struct Sidebar: View {
    let model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            ForEach(AppSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
                    .tag(section)
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
    }

    /// Hosts found / networks in range, once there are any.
    private func badge(for section: AppSection) -> Int {
        switch section {
        case .lanScan: model.scanner.hosts.count
        case .wifi: model.wifi.networks.filter(model.wifi.isInRange).count
        case .internet, .tools: 0
        }
    }
}
