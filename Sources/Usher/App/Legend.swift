import SwiftUI

/// What the panel's icons and words mean, written once and shown in two places:
/// a strip inside the panel and a tab in Settings. Two hand-written copies of
/// this drift within a week, and the one nobody reads is the one that lies.
enum Legend {

    struct Item: Identifiable {
        let symbol: String
        let tint: Color
        let name: String
        let meaning: String
        var id: String { name }
    }

    /// Every outcome a row can have, in the order they matter to you.
    static var outcomes: [Item] {
        let order: [Outcome] = [.pendingApproval, .moved, .heldSensitive, .unsorted,
                                .lowConfidence, .duplicate, .alreadyFiled,
                                .neverClassified, .dryRun, .failed, .trashed]
        return order.map {
            Item(symbol: $0.symbol, tint: $0.tint, name: $0.shortLabel, meaning: $0.explanation)
        }
    }

    /// The buttons on a row. Show and Delete appear when the pointer is over it.
    static let actions: [Item] = [
        Item(symbol: "checkmark", tint: .blue, name: "Move",
             meaning: "File it where the row says. Checked once more for secrets first."),
        Item(symbol: "xmark", tint: .secondary, name: "Leave",
             meaning: "Keep the file exactly where it is and stop asking about it."),
        Item(symbol: "arrow.uturn.backward", tint: .secondary, name: "Undo",
             meaning: "Put the file back where it came from, under its original name."),
        Item(symbol: "arrow.clockwise", tint: .orange, name: "Retry",
             meaning: "Run a file that failed through the whole pipeline again."),
        Item(symbol: "folder", tint: .secondary, name: "Show in Finder",
             meaning: "Reveal the file wherever it is now. Appears when you hover the row."),
        Item(symbol: "trash", tint: .red, name: "Move to Trash",
             meaning: "Bin the file from here. It goes to the Trash, never deleted outright, and Undo brings it back.")
    ]

    /// The footer. Three of these are icons only, so this is where they are named.
    static let footer: [Item] = [
        Item(symbol: "magnifyingglass", tint: .secondary, name: "Sweep",
             meaning: "Look through a watched folder's existing files, rather than waiting for new ones."),
        Item(symbol: "questionmark.circle", tint: .secondary, name: "Guide",
             meaning: "This list. Click it again to go back to the files."),
        Item(symbol: "gearshape", tint: .secondary, name: "Settings",
             meaning: "Watched folders, thresholds, privacy lists and the API key."),
        Item(symbol: "checkmark.circle", tint: .secondary, name: "Clear",
             meaning: "Dismiss handled rows from the panel (⌘K). Nothing is deleted, and Undo stays under Cleared."),
        Item(symbol: "power", tint: .secondary, name: "Quit",
             meaning: "Stop watching and quit. Nothing is filed while Usher is not running.")
    ]

    static let confidence =
        "The bar on the right is how sure the model was of the folder, read against your two thresholds: "
        + "grey is below the ask threshold and nothing happens, blue asks you, green files itself. "
        + "It is only shown where the number is about a folder."
}

/// Compact list for the menubar panel.
struct LegendStrip: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                group("What a row says", Legend.outcomes)
                group("What the buttons do", Legend.actions)
                group("Along the bottom", Legend.footer)
                Text(Legend.confidence)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .frame(maxHeight: 330)
    }

    private func group(_ title: String, _ items: [Legend.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.tint)
                        .frame(width: 15, height: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 11, weight: .medium))
                        Text(item.meaning)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
