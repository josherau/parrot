import SwiftUI

/// Recent transcripts and the Paste Last shortcut.
struct HistorySection: View {
    @ObservedObject var store: SettingsStore
    /// Forgets every transcript; owned by the daemon's `TranscriptHistory`.
    let onClear: () -> Void
    @State private var cleared = false

    private var hotkeyName: String { store.current.history.pasteLastHotkey }

    /// The menu's title: the shortcut, Off, or the hand-edited value as written.
    private var hotkeyTitle: String {
        if KeyCombo.isOff(hotkeyName) { return "Off" }
        return KeyCombo(hotkeyName)?.displayName ?? hotkeyName
    }

    var body: some View {
        SettingsGroup("History") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep recent transcripts")
                    Text(store.current.history.enabled
                        ? "The last \(TranscriptHistory.limit), text only, on this Mac. Copy them from the menu bar's Recent."
                        : "Only the last transcript, in memory, for Paste Last. Nothing is written to disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Keep recent transcripts", isOn: Binding(
                    get: { store.current.history.enabled },
                    set: { on in store.update { $0.history.enabled = on } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            PillRow("Paste last") {
                PillMenu(title: hotkeyTitle) {
                    ForEach(KeyCombo.pasteLastChoices, id: \.name) { combo in
                        Toggle(combo.displayName, isOn: Binding(
                            get: { KeyCombo(hotkeyName) == combo },
                            set: { on in if on { store.update { $0.history.pasteLastHotkey = combo.name } } }
                        ))
                    }
                    Divider()
                    Toggle("Off", isOn: Binding(
                        get: { KeyCombo.isOff(hotkeyName) },
                        set: { on in if on { store.update { $0.history.pasteLastHotkey = KeyCombo.offName } } }
                    ))
                }
            }

            PillRow("Clear") {
                Button(cleared ? "Cleared" : "Clear History") {
                    onClear()
                    cleared = true
                }
                .buttonStyle(.pill)
                .disabled(cleared)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                cleared = false
            }
        }
    }
}
