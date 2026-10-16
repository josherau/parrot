import Carbon.HIToolbox
import Foundation

/// A transcript that was not inserted at the cursor, with the line the
/// overlay shows.
enum DeliveryError: UserFacingError, Equatable {
    /// A password field had focus at start or at delivery. Nothing was typed
    /// or copied.
    case secureField
    /// Focus moved during the dictation. The transcript is on the clipboard.
    case focusChanged

    var userMessage: String {
        switch self {
        case .secureField: return "password field, transcript discarded"
        case .focusChanged: return "focus changed, transcript copied"
        }
    }
}

/// Where a finished transcript goes. Pure, so it is tested.
enum DeliveryDecision: Equatable {
    /// Insert at the cursor.
    case inject
    /// A secure field had focus at start or at delivery: drop the transcript.
    case discardSecure
    /// Focus moved: leave the transcript on the clipboard instead.
    case copyToClipboard

    /// `start` is nil when no recording start was seen; then only the
    /// secure-field check applies.
    static func decide(start: FocusSnapshot?, now: FocusSnapshot) -> DeliveryDecision {
        if start?.isSecure == true || now.isSecure { return .discardSecure }
        if let start, start.hasChanged(to: now) { return .copyToClipboard }
        return .inject
    }
}

/// The delivery step of the dictation loop: checks focus against the
/// snapshot from recording start, then injects, copies or discards. An
/// injected transcript gets a trailing space, and a leading one when the
/// text before the cursor needs it (`Spacing`).
///
/// A transcript that will be injected or copied goes to `record` first, so
/// the history has it even if the paste lands nowhere. One headed for a
/// password field is never recorded: the decision is made here, which is why
/// the history hooks in here rather than as a `TranscriptProcessor`.
@MainActor
final class TextDelivery {
    private let injector: TextInjector
    private let record: (String) -> Void

    init(mode: InjectMode, record: @escaping (String) -> Void = { _ in }) {
        self.injector = TextInjector(mode: mode)
        self.record = record
    }

    /// Paste Last: pastes `text` at the cursor through the clipboard, spaced
    /// like a dictation. Refuses a password field, as a dictation does, and
    /// also while any app holds secure keyboard entry (Terminal's Secure
    /// Keyboard Entry, a sudo or password-manager prompt), whose fields
    /// Accessibility often doesn't mark: the shortcut makes this one key.
    /// Returns false if refused.
    @discardableResult
    func pasteAgain(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let now = FocusSnapshot.capture()
        guard !now.isSecure, !IsSecureEventInputEnabled() else {
            Log.info("paste last: secure field focused; not pasted")
            return false
        }
        let before = now.element?.textBeforeCursor() ?? .unknown
        injector.paste(Spacing.spaced(text, before: before))
        return true
    }

    /// Recent menu: leaves `text` on the clipboard.
    func copy(_ text: String) {
        injector.copyToClipboard(text)
    }

    /// Throws `DeliveryError` when the transcript did not reach the cursor.
    func deliver(_ text: String, focusAtStart: FocusSnapshot?) throws {
        guard !text.isEmpty else { return }
        let now = FocusSnapshot.capture()
        switch DeliveryDecision.decide(start: focusAtStart, now: now) {
        case .inject:
            let before = now.element?.textBeforeCursor() ?? .unknown
            let spaced = Spacing.spaced(text, before: before)
            // The kind of character only: the log never carries text.
            Log.info("  before cursor: \(before.kind)\(spaced.first == " " && text.first != " " ? " · leading space" : "")")
            record(text)
            injector.inject(spaced)
        case .discardSecure:
            let when = focusAtStart?.isSecure == true ? "recording start" : "delivery"
            Log.info("  secure field focused at \(when); transcript discarded")
            throw DeliveryError.secureField
        case .copyToClipboard:
            record(text)
            injector.copyToClipboard(text)
            Log.info("  focus changed during dictation; transcript copied to clipboard")
            throw DeliveryError.focusChanged
        }
    }
}
