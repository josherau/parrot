# ADR-006 :: Transcript history

Last updated: `2026.10.16`

> Parrot keeps the last 20 transcripts, text only, in one owner-only file, so a paste that landed nowhere can be recovered from the menu bar's Recent or with Paste Last (⌥⌘V). A setting turns the file off; Paste Last then works from the last transcript, held in memory only.

## 1. Decision

- **What.** Transcript text only: no audio, app, URL or time. The newest 20, newest first.
- **Where.** `~/Library/Application Support/parrot/history.json` (`Paths.historyFile`), 0600 in the 0700 directory, written to a fixed 0600 temporary file created with `O_EXCL | O_NOFOLLOW` and renamed over the target. A symlinked, foreign or oversized file is never read or written through. A temporary file left by a crash is removed at startup and on Clear.
- **When.** Recorded by `TextDelivery` just before a transcript is pasted or copied, so it exists even if the paste lands nowhere. A transcript headed for a password field is never recorded: that decision is made in `TextDelivery`, which is why history hooks there and not as a `TranscriptProcessor`.
- **Off.** `history.enabled: false` in `settings.json` (Settings ▸ History) deletes the file and keeps only the last transcript, in memory, for Paste Last. Clear History, in Settings and the Recent menu, deletes the file and empties memory.
- **Paste Last.** A global shortcut through Carbon `RegisterEventHotKey`: the system delivers only that combo, it needs no Accessibility grant, and `HotkeyMonitor`'s tap stays flagsChanged-only (ADR-003). It waits for the shortcut's modifiers to come up, then pastes through the same `PasteboardSession` as dictation. It refuses a password field and any time secure keyboard entry is on. The default, ⌥⌘V, leaves Control alone, since Control is a common push-to-talk key.
- **Logs.** Still never text (ADR-004): counts and file paths only.

## 2. Rationale

Paste mode borrows the clipboard for 250 ms and restores it. If no text field takes the ⌘V, the transcript is lost and the user dictates again. Wispr Flow keeps a history database and a paste-last shortcut for this case. Twenty entries of text cover the recovery case without becoming an archive.

## 3. Design Implications

- ADR-004's "no transcript text at rest" now has one exception, this file, which the user can turn off and clear.
- **On by default in this fork, by the owner's decision.** ADR-004 asks for an explicit opt-in. Asked to choose, the fork's owner kept it on (2026-10-16: "Keep history on by default in my fork; I want the Recent list."), with the switch in Settings ▸ History to turn it off. Upstream, the default should be off, or onboarding should ask.
- Uninstall leaves Application Support, and so the history; Clear History or turning it off removes it.

## 4. When to Revisit

- If upstream takes this feature, flip the default to opt-in or add an onboarding step.
- If users want more than recovery (search, audio replay), that is an archive and needs its own decision.
