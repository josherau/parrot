import AppKit

/// The menu bar's Recent submenu: the last transcripts, newest first.
/// Clicking one copies it to the clipboard. Rebuilt each time it opens, so it
/// never holds text longer than the history does.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    /// Longest title before it is cut with an ellipsis.
    nonisolated static let titleLength = 60

    let menu = NSMenu(title: "Recent")
    /// Newest first; set by the daemon.
    var transcripts: () -> [String] = { [] }
    /// The Paste Last shortcut, shown in the header. Nil when off.
    var pasteLastShortcut: () -> String? = { nil }
    var onCopy: ((String) -> Void)?
    var onClear: (() -> Void)?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let transcripts = transcripts()
        guard !transcripts.isEmpty else {
            let empty = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let hint = pasteLastShortcut().map { "Click to copy · \($0) pastes the newest" } ?? "Click to copy"
        let header = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, text) in transcripts.enumerated() {
            let item = NSMenuItem(title: Self.title(text), action: #selector(copyClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearClicked), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// One line: whitespace runs collapsed, cut to `titleLength`.
    nonisolated static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > titleLength else { return line }
        return String(line.prefix(titleLength - 1)) + "…"
    }

    @objc private func copyClicked(_ sender: NSMenuItem) {
        // By index into the history as it is now; the menu holds no text.
        let transcripts = transcripts()
        guard transcripts.indices.contains(sender.tag) else { return }
        onCopy?(transcripts[sender.tag])
    }

    @objc private func clearClicked() {
        onClear?()
    }
}
