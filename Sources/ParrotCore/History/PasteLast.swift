import CoreGraphics
import Foundation

/// Paste Last: a global shortcut (⌥⌘V by default) that pastes the newest
/// transcript at the cursor, for a dictation whose paste landed nowhere.
///
/// The shortcut comes from `HistorySettings.pasteLastHotkey` and is
/// re-registered when it changes.
@MainActor
final class PasteLast {
    /// How long to wait for the shortcut's modifiers to come up before
    /// pasting anyway.
    static let releaseTimeout: TimeInterval = 1
    private static let pollInterval: TimeInterval = 0.02

    private let history: TranscriptHistory
    private let delivery: TextDelivery
    private let hotkey = GlobalHotkey()
    /// The registered shortcut, for the menu. Nil when off.
    private(set) var combo: KeyCombo?
    /// Bumped on each press, so only the latest press pastes.
    private var pressGeneration = 0

    init(history: TranscriptHistory, delivery: TextDelivery) {
        self.history = history
        self.delivery = delivery
    }

    /// Registers the shortcut `name` names, or none for `"off"`.
    func apply(_ name: String) {
        hotkey.unregister()
        combo = nil
        if KeyCombo.isOff(name) {
            Log.info("paste last: off")
            return
        }
        guard let parsed = KeyCombo(name) else {
            Log.warning("settings.json: paste last hotkey \"\(name)\" is not a combo such as \"option+command+v\"; paste last is off")
            return
        }
        if hotkey.register(parsed, onPress: { [weak self] in self?.pressed() }) {
            combo = parsed
            Log.info("paste last: \(parsed.displayName)")
        }
    }

    /// Pastes once the shortcut's modifiers are up, so the target app sees a
    /// plain ⌘V rather than ⌥⌘V (in Finder, Move Item Here).
    private func pressed() {
        guard history.last != nil else {
            Log.info("paste last: no transcript yet")
            return
        }
        pressGeneration += 1
        let generation = pressGeneration
        let held = Self.flags(for: combo?.modifiers ?? [])
        let deadline = Date().addingTimeInterval(Self.releaseTimeout)
        func attempt() {
            guard generation == pressGeneration else { return }
            let down = CGEventSource.flagsState(.combinedSessionState).intersection(held)
            if !down.isEmpty, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) {
                    MainActor.assumeIsolated { attempt() }
                }
                return
            }
            // Read now, not at the press: a dictation may have finished since.
            guard let text = history.last else { return }
            if delivery.pasteAgain(text) {
                Log.info("paste last: pasted \(text.count) chars")
            }
        }
        attempt()
    }

    private static func flags(for modifiers: KeyCombo.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
