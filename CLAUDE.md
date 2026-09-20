# CLAUDE.md

Native macOS window around the `task` CLI (taskwarrior 3.x). Swift package,
macOS 14+, SwiftUI shell with AppKit where SwiftUI is unreliable (text view,
command field). See README.md for user-facing behaviour; this file is for
working on the code.

## Commands

- `make debug` – fast build of `build/Taskwarrior.app`; `make` for release; `make run` opens it.
- `make test` – unit tests for `TaskwarriorCore` (parsing, policy, ANSI). Keep them green.
  Needs Xcode: XCTest ships only with Xcode, so this target cannot run at all on a
  Command Line Tools install (`unable to resolve module dependency: 'XCTest'`).
- Verify UI changes visually with a scripted run (no clicking, no screen-recording permission needed):
  ```sh
  TASKDATA=/tmp/tw-scratch TASKWARRIOR_APP_SCRIPT="add project:work x;;1 done;;next" \
  TASKWARRIOR_APP_SNAPSHOT=/tmp/w.png TASKWARRIOR_APP_QUIT=1 build/Taskwarrior.app/Contents/MacOS/Taskwarrior
  ```
  then look at the PNG. `TASKWARRIOR_APP_DUMP=1` prints the view hierarchy and any confirmation asked.
- Never run mutating commands against the user's real data while testing; always set `TASKDATA`
  to a scratch directory. The user's `~/.taskrc` (context `work`, `bulk=0`, sync server) is still read.

## Architecture in one paragraph

`TaskwarriorCore` has no UI: `ParsedCommand` splits a typed line into
`[filter] command [args]` using `CommandCatalog` (built from `task _zshcommands`
and `alias.*`, mirroring taskwarrior's abbreviation rules); `DisplayPolicy` maps
the command's taskwarrior category to one of replace-display / log-and-refresh /
log-only / refuse, and `ConfirmationPolicy` says when to ask first; `TaskRunner`
runs the binary; `ANSIParser` turns coloured output into `StyledRun`s.
`AppModel` (main actor, `@Observable`) owns all state, runs commands through a
strict serial queue, remembers the "current view" (last listing) and re-runs it
after modifications or when the window geometry changes. Views are thin.

## Invariants and gotchas (learned the hard way)

- All `task` invocations carry `rc.confirmation=off rc.allow.empty.filter=no rc._forcecolor=on
  rc.verbose=<user's list minus override,context> rc.defaultwidth=<cols> rc.defaultheight=<rows>`.
  The app must therefore do its own confirmations for anything destructive.
- `task _show` reports the *effective* config: never query it with overrides you don't want read back.
- Reports with `limit:page` (the user's `next`) size themselves from `rc.defaultheight`; without it
  the app shows only ~20 rows. Column fit comes from `rc.defaultwidth` computed from the text view.
- No shell is ever involved in running a command. `ShellTokenizer` splits the typed line,
  `ParsedCommand.parse` drops a leading `task` word, and `TaskRunner` passes the tokens as argv
  to the binary via `Process`. So quoting works but globs, `$VAR`, pipes and redirection do not,
  and nothing but `task` can be run. (`displayString` re-adds the `task ` prefix for confirmations
  and the log only.) The single shell invocation in the codebase is `TaskRunner.locate`'s
  `zsh -lc "command -v task"` fallback, used to find the binary because a Finder-launched app
  gets a minimal `PATH`.
- An ambiguous abbreviation (`ne`) is a filter word to taskwarrior, not a command; the parser
  returns `command == nil` and the default command runs. Do not "fix" this.
- Taskwarrior's default colour theme assumes a black terminal (row shading is colour 234), so the
  window is forced dark. A light theme needs a palette remap, not just a background change.
- `edit` and `execute` need a tty and are refused. `task sync` is `synchronize` (category migration)
  and is treated as an operation (log + refresh).
- Rules for what refreshes live only in `DisplayPolicy.swift`; keep new behaviour there.
- SwiftUI's `@State` is a macro in the macOS 27 SDK and only Xcode's toolchain ships the
  `SwiftUIMacros` plugin that expands it, so a Command Line Tools install cannot build the app
  against that SDK at all. `Scripts/swiftui-sdk.sh` probes for the newest SDK that typechecks a
  trivial SwiftUI view and the Makefile exports it as `SDKROOT`, printing a one-line note when it
  does. The probe is deliberately uncached so it goes dormant as soon as Xcode is installed; an
  `SDKROOT` already set in the environment skips it. Installing Xcode is the real fix.
- Command output for listings goes to the status line, not the log, so refreshes stay quiet.
- All display colour comes from the user's theme via `rc._forcecolor=on`; the app adds none of its own.
  `dark-256.theme` only colours state (due/overdue/active/recurring/blocked), so a list of plain
  tasks is legitimately monochrome. "No colours" is a `.taskrc` question, not an app bug.
- The app icon is a committed `Resources/AppIcon.icns` that `make app` copies in (before the
  `codesign` line, which seals `Contents/Resources`) plus `CFBundleIconFile` in the checked-in
  plist. `Scripts/make-icon.swift` draws it and is run **by hand**, not by the Makefile.
  It is a deliberate twin of `~/vimango_hybrid/scripts/make-icon.swift` — same tile grid and
  corner treatment, differing only in letter and hue — so the two apps read as a pair in the
  Dock; a change to the tile style belongs in both copies. Two traps: `CALayer.render(in:)`
  ignores the layer's frame origin and draws at the context origin (translate the context
  instead), and inspecting the result by running `iconutil -c iconset` *backwards* on the
  `.icns` unpremultiplies with clipping, so edges come back blown out and the art looks like
  it has a fringe it does not have — read the PNGs the script writes instead.
- **A new icon will not show in the Dock until its cache is cleared.** `lsregister -f` does not
  do it, and neither does quitting and relaunching the app. Delete
  `com.apple.dock.iconcache` under `/private/var/folders/…/C/` and `killall Dock`.

## Conventions

- Anything testable without AppKit goes in `TaskwarriorCore` with a test.
- Prefer AppKit-backed views where keyboard handling or text layout matters; keep them small
  `NSViewRepresentable`s with a coordinator, driven by plain values not the model.
- Persisted preferences use `UserDefaults` keys in `AppModel.Keys`.
- Commit messages: imperative summary line, short body on why.

## Future improvements under consideration

Stage 2 is the structured view; the rest are candidates in rough priority order.

1. **Structured table view** – run `task <filter> export` alongside the report, render an
   `NSTableView` using the report's `report.<name>.columns` from `_show`; checkbox per row issues
   `task <uuid> done`. `ParsedCommand.filter` already isolates the filter. Keep the verbatim text
   view as a fallback/toggle so custom reports never break.
2. **Auto-sync** – debounced `task sync` a few seconds after any modification, plus periodic pull
   (e.g. every 10 min and on app activation); spinner and last-sync time in the status line;
   failures surface once, not on every retry.
3. **In-place editing** – double-click description / due / project cell to edit; commit via
   `task <uuid> modify ...`; Esc cancels.
4. **Row actions** – keyboard selection (j/k or arrows) with shortcuts for done, start/stop,
   delete; context menu with annotate, priority, due, tags; selected task drives a detail pane
   showing `task <uuid> information`.
5. **Quick-add form** – fields for description, project, due, tags, priority with autocompletion
   from `task _projects` / `_tags`; also a global hotkey or menu-bar item for capture.
6. **Command-field autocompletion** – commands, report names, `project:`/`+tag` values.
7. **Context and report switcher** – sidebar or popup listing contexts and reports; switching
   context should not refresh until a listing is requested (current rule) unless the user opts in.
8. **Notifications** – due/overdue reminders via UNUserNotificationCenter.
9. **Appearance** – optional light palette, font family choice, per-window state, multiple windows.
10. **Undo affordance** – after done/delete, a transient "Undo" button in the status line.
