import Carbon.HIToolbox

/// A global shortcut: one letter or digit plus modifiers, as Carbon's
/// `RegisterEventHotKey` takes it. Written in `settings.json` as names
/// joined by `+`, modifiers first: `"option+command+v"`.
///
/// At least one of Command, Option or Control is required, so the shortcut
/// can't swallow plain typing.
struct KeyCombo: Equatable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let modifiers: Modifiers
    /// Lowercase letter or digit.
    let key: Character

    /// ⌥⌘V. Leaves Control alone, which a push-to-talk key may use; in
    /// Finder it shadows "Move Item Here".
    static let defaultPasteLast = KeyCombo(modifiers: [.option, .command], key: "v")

    /// What the Settings window offers; `settings.json` takes any combo.
    static let pasteLastChoices: [KeyCombo] = [
        defaultPasteLast,
        KeyCombo(modifiers: [.shift, .option, .command], key: "v"),
        KeyCombo(modifiers: [.control, .option, .command], key: "v"),
        KeyCombo(modifiers: [.option, .command], key: "p"),
    ]

    /// The value written for no shortcut.
    static let offName = "off"

    /// Parses `name`, ignoring case and spaces. Nil for `"off"`, an empty
    /// string, or anything that isn't a valid combo; `isOff` tells those apart.
    init?(_ name: String) {
        let parts = name.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, last.count == 1, let key = last.first,
              Self.keyCodes[key] != nil
        else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = Self.modifierNames[part], !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    init(modifiers: Modifiers, key: Character) {
        self.modifiers = modifiers
        self.key = key
    }

    /// True if `name` asks for no shortcut.
    static func isOff(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty || trimmed == offName
    }

    /// The `settings.json` form: `"option+command+v"`.
    var name: String {
        let order: [(Modifiers, String)] = [(.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command")]
        return (order.filter { modifiers.contains($0.0) }.map(\.1) + [String(key)]).joined(separator: "+")
    }

    /// The menu form, in Apple's modifier order: `⌥⌘V`.
    var displayName: String {
        let order: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }

    /// The ANSI virtual keycode `RegisterEventHotKey` takes.
    var keyCode: UInt32 { UInt32(Self.keyCodes[key] ?? 0) }

    /// The Carbon modifier mask `RegisterEventHotKey` takes.
    var carbonModifiers: UInt32 {
        var mask = 0
        if modifiers.contains(.control) { mask |= controlKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        if modifiers.contains(.command) { mask |= cmdKey }
        return UInt32(mask)
    }

    private static let modifierNames: [String: Modifiers] = [
        "control": .control, "ctrl": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "command": .command, "cmd": .command, "⌘": .command,
    ]

    private static let keyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
}
