import SwiftUI
import AppKit

// MARK: - Menubar icon

/// SF Symbols render as template images in the menubar, which strips color. To
/// keep the tint we build the NSImage ourselves with a palette configuration and
/// turn the template flag off.
enum MenuBarIcon {

    static func image(pending: Int, dryRun: Bool, running: Bool,
                      busy: Bool = false, phase: Int = 0, alert: Bool = false) -> NSImage {
        // Each state has its own shape, not only its own colour — dry run and
        // live used to be the same tray in orange and green, which red-green
        // colour blindness cannot tell apart, and an error looked like idle.
        //   working  arrows, pulsing        alert    warning triangle, red
        //   pending  full tray, blue        dry run  outlined tray, orange
        //   live     filled tray, green     paused   outlined tray, grey
        let symbol = alert ? "exclamationmark.triangle.fill"
                   : busy ? "arrow.triangle.2.circlepath"
                   : pending > 0 ? "tray.full.fill"
                   : (running && !dryRun) ? "tray.and.arrow.down.fill" : "tray.and.arrow.down"
        var accent = alert ? NSColor.systemRed : tint(pending: pending, dryRun: dryRun, running: running)
        if busy { accent = accent.withAlphaComponent(phase % 2 == 0 ? 1.0 : 0.62) }

        let base = NSImage(systemSymbolName: symbol,
                           accessibilityDescription: "Usher")
            ?? NSImage(size: NSSize(width: 16, height: 16))

        let configuration = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                accent,
                accent.withAlphaComponent(0.42)
            ]))

        guard let rendered = base.withSymbolConfiguration(configuration) else { return base }
        rendered.isTemplate = false
        return rendered
    }

    private static func tint(pending: Int, dryRun: Bool, running: Bool) -> NSColor {
        if !running { return .systemGray }
        if pending > 0 { return .systemBlue }
        return dryRun ? .systemOrange : .systemGreen
    }
}

// MARK: - Outcome styling

extension Outcome {

    var symbol: String {
        switch self {
        case .moved:            return "checkmark.circle.fill"
        case .dryRun:           return "eye.circle.fill"
        case .pendingApproval:  return "questionmark.circle.fill"
        case .unsorted:         return "tray.circle.fill"
        case .lowConfidence:    return "minus.circle.fill"
        case .heldSensitive:    return "lock.circle.fill"
        case .alreadyFiled:     return "checkmark.circle"
        case .duplicate:        return "doc.on.doc.fill"
        case .neverClassified:  return "key.fill"
        case .failed:           return "exclamationmark.triangle.fill"
        case .trashed:          return "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .moved:            return .green
        case .dryRun:           return .orange
        case .pendingApproval:  return .blue
        case .unsorted:         return .secondary
        case .lowConfidence:    return .secondary
        case .heldSensitive:    return .purple
        case .alreadyFiled:     return .secondary
        case .duplicate:        return .orange
        case .neverClassified:  return .purple
        case .failed:           return .red
        case .trashed:          return .gray
        }
    }

    /// A probability only means something when it is a probability *of a
    /// folder*. On an unsorted row the number is P(no match), and drawing it on
    /// a threshold-banded bar rendered "78% sure of nothing" in green.
    var showsConfidence: Bool {
        switch self {
        case .moved, .pendingApproval, .dryRun, .lowConfidence: return true
        default: return false
        }
    }

    /// One plain line: what happened, and what you can do about it. Shown in
    /// the panel's legend and in Settings — the same words in both.
    var explanation: String {
        switch self {
        case .pendingApproval:
            return "The model was sure enough to propose a folder but not sure enough to act, or the move would create a folder. Nothing happens until you say."
        case .moved:
            return "Filed, and renamed if the name needed it. Undo puts it back."
        case .heldSensitive:
            return "Matched one of your privacy rules, so it was never sent anywhere. A local rule may still have filed it."
        case .unsorted:
            return "No folder fits. Add a route or a rule and it gets another look."
        case .lowConfidence:
            return "Below your ask threshold, so it was left alone. Looked at again after a day, or sooner if routes, rules or the app change."
        case .duplicate:
            return "The same bytes are already filed somewhere. Set aside in your duplicates folder instead of filed twice."
        case .alreadyFiled:
            return "Already in the right folder under the right name. Nothing to do."
        case .neverClassified:
            return "A password vault, key, certificate or wallet. Never read, never sent, never moved — by design, not by setting."
        case .dryRun:
            return "Dry run is on, so the decision was made and logged but nothing moved. Turn it off with the Dry run pill at the top of the panel; Usher asks before filing these."
        case .failed:
            return "Something went wrong; the row says what. Retry runs it through again."
        case .trashed:
            return "You binned it from this panel. It is in the Trash, and Undo brings it back."
        }
    }

    var shortLabel: String {
        switch self {
        case .moved:            return "Filed"
        case .dryRun:           return "Dry run"
        case .pendingApproval:  return "Needs you"
        case .unsorted:         return "No match"
        case .lowConfidence:    return "Unsure"
        case .heldSensitive:    return "Held"
        case .alreadyFiled:     return "Already filed"
        case .duplicate:        return "Duplicate"
        case .neverClassified:  return "Secret — left alone"
        case .failed:           return "Failed"
        case .trashed:          return "Trashed"
        }
    }
}

/// Colored glyph for the file itself, so the list scans by type at a glance.
enum FileGlyph {

    static func symbol(for ext: String) -> (name: String, tint: Color) {
        switch ext.lowercased() {
        case "pdf":
            return ("doc.richtext.fill", .red)
        case "zip", "tar", "gz", "7z", "rar", "jar":
            return ("doc.zipper", .brown)
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp", "svg":
            return ("photo.fill", .teal)
        case "csv", "tsv", "xlsx", "parquet":
            return ("tablecells.fill", .green)
        case "json", "jsonl", "yaml", "yml", "xml", "plist":
            return ("curlybraces", .orange)
        case "dmg", "pkg", "app":
            return ("shippingbox.fill", .indigo)
        case "epub", "mobi", "azw3":
            return ("book.fill", .purple)
        case "mp4", "mov", "mkv", "avi", "webm":
            return ("film.fill", .pink)
        case "mp3", "wav", "flac", "m4a", "aac":
            return ("waveform", .mint)
        case "md", "markdown", "txt", "rtf":
            return ("doc.text.fill", .gray)
        default:
            return ("doc.fill", .secondary)
        }
    }
}

// MARK: - Small components

/// Rounded label used for counts in the header and the DRY RUN marker.
struct Chip: View {
    let text: String
    let tint: Color
    var filled: Bool = false
    /// Smaller, for use beside a filename rather than alone in the header.
    var compact: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 9 : 10, weight: .semibold))
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1.5 : 2.5)
            .background(tint.opacity(filled ? 0.9 : 0.14))
            .foregroundStyle(filled ? Color.white : tint)
            .clipShape(Capsule())
    }
}

/// Probability rendered against the two thresholds, so the bar shows not just how
/// sure Jev was but which band that lands in.
struct ConfidenceBar: View {
    let probability: Double
    let askThreshold: Double
    let autoThreshold: Double

    private var tint: Color {
        if probability >= autoThreshold { return .green }
        if probability >= askThreshold { return .blue }
        return .secondary
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(2, geometry.size.width * probability))
            }
        }
        .frame(width: 34, height: 3.5)
        .help(String(format: "%.0f%% confident", probability * 100))
    }
}

/// Toggle styled as a pill, used for dry run where a system switch reads too heavy.
struct PillToggle: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isOn ? tint.opacity(0.16) : Color.primary.opacity(0.06))
            .foregroundStyle(isOn ? tint : Color.secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(isOn ? tint.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isOn)
    }
}

/// Compact action button for row-level Move / Undo / Reveal.
struct RowButton: View {
    /// Nil renders the symbol alone in a 20x18 square. Three labelled pills on
    /// every row left the filename ~190pt and made "Show" wrap to "Sho/w".
    var title: String?
    var symbol: String?
    var tint: Color = .accentColor
    var prominent: Bool = false
    /// No background until hovered. For an action that should be readable at
    /// rest without competing with the row's text.
    var quiet: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var background: Color {
        if prominent { return tint.opacity(hovering ? 1.0 : 0.88) }
        if quiet { return tint.opacity(hovering ? 0.16 : 0) }
        return tint.opacity(hovering ? 0.22 : 0.13)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    HStack(spacing: 3) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                        }
                        Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                } else {
                    Image(systemName: symbol ?? "questionmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
            }
            .background(background)
            .foregroundStyle(prominent ? Color.white : tint)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
