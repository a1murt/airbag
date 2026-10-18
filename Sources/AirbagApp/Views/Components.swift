import AirbagCore
import AppKit
import SwiftUI

enum Theme {
    static let danger = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let ok = Color(nsColor: .systemGreen)
    static let accent = Color.accentColor
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
}

/// Menu bar glyph: an SF Symbol rendered as a template image, with a dot drawn into it for the badge (status items
/// have no badge API, and drawing keeps it monochrome on light and dark menu bars).
enum MenuBarIcon {
    static func image(_ state: IconState, badge: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let base = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Airbag")?.withSymbolConfiguration(config) ?? NSImage()
        let size = NSSize(width: max(base.size.width, 16) + (badge ? 3 : 0), height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let b = base.size
            base.draw(in: NSRect(x: 0, y: (rect.height - b.height) / 2, width: b.width, height: b.height))
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 6.5, y: 0.5, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

struct Pill: View {
    let text: LocalizedStringKey
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CommandText: View {
    let command: String
    var lines: Int = 1
    var body: some View {
        Text(verbatim: command)
            .font(Theme.mono)
            .lineLimit(lines)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

struct AgentBadge: View {
    let agent: AgentKind?
    var body: some View {
        if let agent {
            Label(agent.displayName, systemImage: symbol(agent)).labelStyle(.titleAndIcon).font(.caption).lineLimit(1).fixedSize()
        }
    }
    func symbol(_ a: AgentKind) -> String {
        switch a {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "diamond"
        case .copilot: return "airplane"
        }
    }
}

struct ChangeRow: View {
    let change: FileChange
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: letter).font(Theme.monoSmall.weight(.bold)).foregroundStyle(color).frame(width: 14)
                .accessibilityLabel(Text(label))
            Text(verbatim: change.path).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let s = change.newSize ?? change.oldSize {
                Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
    var letter: String {
        switch change.status { case .added: return "A"; case .modified: return "M"; case .deleted: return "D"; case .typeChanged: return "T" }
    }
    var label: LocalizedStringKey {
        switch change.status { case .added: return "added"; case .modified: return "modified"; case .deleted: return "deleted"; case .typeChanged: return "type changed" }
    }
    var color: Color {
        switch change.status { case .added: return Theme.ok; case .modified: return Theme.warning; case .deleted: return Theme.danger; case .typeChanged: return .purple }
    }
}

struct DiffView: View {
    let diff: TextDiff
    var body: some View {
        switch diff.summary {
        case .identical: Text("No changes in this file").foregroundStyle(.secondary)
        case .binary(let oldSize, let newSize):
            Text("Binary file · \(bytes(oldSize)) → \(bytes(newSize))").foregroundStyle(.secondary)
        case .tooLarge(let oldSize, let newSize):
            Text("File too large to show · \(bytes(oldSize)) → \(bytes(newSize))").foregroundStyle(.secondary)
        case .text:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(verbatim: hunk.header).font(Theme.monoSmall).foregroundStyle(.secondary).padding(.vertical, 2)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Text(verbatim: line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                            Text(verbatim: line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                            Text(verbatim: (line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(Theme.monoSmall)
                        .foregroundStyle(line.kind == .same ? Color.primary : (line.kind == .added ? Theme.ok : Theme.danger))
                        .padding(.vertical, 0.5)
                        .background(line.kind == .added ? Theme.ok.opacity(0.10) : line.kind == .removed ? Theme.danger.opacity(0.10) : .clear)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
    func bytes(_ value: Int?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—" }
}

extension RadarProcess {
    var portsText: String {
        listeners.map { ":\($0.port)" }.joined(separator: " ")
    }
    var uptimeText: String {
        let secs = max(0, Int(Date().timeIntervalSince1970) - Int(startedAtMs / 1000))
        let f = DateComponentsFormatter()
        f.allowedUnits = secs >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(secs)) ?? ""
    }
    var memoryText: String { footprintBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—" }
}
