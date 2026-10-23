import AirbagCore
import AppKit
import SwiftUI

/// Visual rules shared by every screen.
///
/// Colour carries one meaning each: red = Airbag stopped something or data is at risk; orange = needs your action now;
/// green = running fine or done; secondary grey = history or information. Coloured text is never used for sentences:
/// the symbol carries the colour and the words stay in label colours (contrast).
/// Commands are always set in the surrounding font made monospaced; they are never quoted or put in backticks.
enum Theme {
    static let danger = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let ok = Color(nsColor: .systemGreen)
    static let accent = Color.accentColor
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    /// Grouped content: lighter than the window in both appearances (white in light mode, a lifted grey in dark mode).
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : .controlBackgroundColor
    })
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)
    })
}

extension View {
    /// The card look used by Timeline and Guard rows.
    func card(cornerRadius: CGFloat = 10) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.cardStroke))
    }

    /// Briefly highlights a row the user was sent to ("Show", a notification click).
    func flash(_ active: Bool) -> some View { modifier(FlashModifier(active: active)) }
}

private struct FlashModifier: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(on ? 0.18 : 0)))
            .onChange(of: active, initial: true) { _, now in
                guard now else { return }
                on = true
                withAnimation(.easeOut(duration: 1.2).delay(0.4)) { on = false }
            }
    }
}

/// Menu bar glyph: an SF Symbol rendered as a template image. The badge dot sits top-right with a transparent ring cut
/// around it, so it reads as a badge on light and dark menu bars (status items have no badge API).
enum MenuBarIcon {
    static func image(_ state: IconState, badge: Bool, tick: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = tick && state == .protected ? "checkmark.shield.fill" : state.symbol
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Airbag")?.withSymbolConfiguration(config) ?? NSImage()
        let size = NSSize(width: max(base.size.width, 16) + (badge ? 2 : 0), height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let b = base.size
            base.draw(in: NSRect(x: 0, y: (rect.height - b.height) / 2, width: b.width, height: b.height))
            if badge {
                let dot = NSRect(x: rect.width - 6.5, y: rect.height - 7, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.6, dy: -1.6)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
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
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let count, count > 0 { Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A status: coloured dot and a word, in a light capsule of the same colour (sentence case: "Live", "Session ended").
struct Pill: View {
    let text: LocalizedStringKey
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.primary.opacity(0.8)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// A status without a capsule (Finder tag style), for table cells and settings rows.
struct StatusDot: View {
    let text: LocalizedStringKey
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// A warning or note: the symbol carries the colour, the text stays readable.
struct Callout: View {
    enum Kind { case info, warning, danger, success }
    let kind: Kind
    let text: Text
    init(_ kind: Kind, _ text: Text) { self.kind = kind; self.text = text }
    init(_ kind: Kind, _ key: LocalizedStringKey) { self.kind = kind; self.text = Text(key) }
    init(_ kind: Kind, verbatim: String) { self.kind = kind; self.text = Text(verbatim: verbatim) }
    var body: some View {
        Label {
            text.foregroundStyle(kind == .info ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
    var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch kind {
        case .info: return .secondary
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .success: return Theme.ok
        }
    }
}

/// A shell command in the surrounding text size, monospaced, truncated in the middle, selectable.
struct CommandText: View {
    let command: String
    var lines: Int = 1
    var font: Font = .callout
    var body: some View {
        Text(verbatim: command)
            .font(font.monospaced())
            .lineLimit(lines)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(Text(verbatim: command))
    }
}

extension Text {
    /// Placeholder for a command inside a localized sentence: interpolate it where the command goes, e.g.
    /// String(localized: …"from \(Text.commandMarker)?"), and pass the result to `withCommand`.
    static let commandMarker = "\u{FFFC}"

    /// A localized sentence with the command set in monospace where the marker is (word order stays the translator's).
    static func withCommand(_ sentence: String, _ command: String) -> Text {
        let parts = sentence.components(separatedBy: commandMarker)
        guard parts.count == 2 else { return Text(verbatim: sentence) }
        return Text(verbatim: parts[0]) + Text(verbatim: command).monospaced() + Text(verbatim: parts[1])
    }
}

struct AgentBadge: View {
    let agent: AgentKind?
    var body: some View {
        if let agent {
            Label(agent.displayName, systemImage: Self.symbol(agent)).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
        }
    }
    static func symbol(_ a: AgentKind) -> String {
        switch a {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "diamond"
        case .copilot: return "airplane"
        }
    }
}

/// One vocabulary for Guard decisions everywhere (popover, Guard, Timeline, notifications).
struct GuardStyle {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color

    init(_ decision: String) {
        switch decision {
        case "deny": title = "Blocked"; symbol = "hand.raised.fill"; color = Theme.danger
        case "deny_fallback": title = "Needs approval"; symbol = "questionmark.circle.fill"; color = Theme.warning
        case "ask": title = "Asked in agent"; symbol = "bubble.left"; color = .secondary
        case "allow_once": title = "Allowed once"; symbol = "checkmark.circle"; color = Theme.ok
        case "allow_fallback": title = "Ran without asking"; symbol = "exclamationmark.triangle"; color = Theme.warning
        default: title = LocalizedStringKey(decision); symbol = "circle"; color = .secondary
        }
    }

    var label: some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}

/// Full-width row that highlights on hover like a menu item (popover rows).
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    configuration.isPressed ? Theme.accent.opacity(0.25) : (hover && enabled ? Color.primary.opacity(0.08) : .clear)))
                .onHover { hover = $0 }
        }
    }
}

/// The message shown at the top of the popover and the bottom of the main window.
struct ToastView: View {
    @EnvironmentObject var model: AppModel
    let toast: Toast
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: toast.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let title = toast.actionTitle {
                Button(title) { model.performToastAction() }.controlSize(.small)
            }
            Button { model.dismissToast() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
        .onAppear {
            model.holdToast(false)
            AccessibilityNotification.Announcement(toast.text).post()
        }
        .onHover { model.holdToast($0) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    var symbol: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch toast.style {
        case .info: return .secondary
        case .success: return Theme.ok
        case .warning: return Theme.warning
        case .failure: return Theme.danger
        }
    }
}

/// A port that opens the server in the browser.
struct PortLink: View {
    let port: Int
    var font: Font = .caption
    var body: some View {
        let portText = String(port)
        Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(portText)")!) } label: { Text(verbatim: ":" + portText) }
            .buttonStyle(.link).font(font.monospacedDigit())
            .help(Text("Open localhost:\(portText) in Browser"))
    }
}

/// What a moment did to files, in words: "2 deleted · 1 changed · 3 added".
struct ChangeCounts: View {
    let changes: [FileChange]
    var font: Font = .caption
    var body: some View {
        let deletedCount = changes.filter { $0.status == .deleted }.count
        let changedCount = changes.filter { $0.status == .modified || $0.status == .typeChanged }.count
        let addedCount = changes.filter { $0.status == .added }.count
        HStack(spacing: 8) {
            if deletedCount > 0 { item(Text("\(deletedCount) deleted"), Theme.danger) }
            if changedCount > 0 { item(Text("\(changedCount) changed"), Theme.warning) }
            if addedCount > 0 { item(Text("\(addedCount) added"), Theme.ok) }
        }
        .font(font)
    }
    func item(_ text: Text, _ color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 6, height: 6); text.foregroundStyle(.secondary) }
    }

    /// The symbol for a moment by its effect: deletions win, then edits, then additions.
    static func symbol(_ changes: [FileChange]) -> (String, Color) {
        if changes.contains(where: { $0.status == .deleted }) { return ("trash", Theme.danger) }
        if changes.contains(where: { $0.status == .modified || $0.status == .typeChanged }) { return ("pencil", .secondary) }
        if changes.contains(where: { $0.status == .added }) { return ("plus", .secondary) }
        return ("circle.dashed", .secondary)
    }
}

/// Empty and "nothing found" states in the system style.
struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var body: some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(message) }
    }
}

struct ChangeRow: View {
    let change: FileChange
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: letter).font(Theme.monoSmall.weight(.bold)).foregroundStyle(color).frame(width: 14)
                .accessibilityLabel(Text(label))
            Text(verbatim: change.path).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle).help(Text(verbatim: change.path))
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

/// A unified diff, pinned to the leading edge (long lines scroll sideways in the caller's horizontal scroll view).
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
                            Text(verbatim: line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(verbatim: line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(verbatim: (line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(Theme.monoSmall)
                        .foregroundStyle(line.kind == .same ? Color.primary : (line.kind == .added ? Theme.ok : Theme.danger))
                        .padding(.vertical, 0.5)
                        .background(line.kind == .added ? Theme.ok.opacity(0.10) : line.kind == .removed ? Theme.danger.opacity(0.10) : .clear)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
