# CLAUDE.md

Native macOS window around the `task` CLI (taskwarrior 3.x). Swift package,
macOS 15+ (only the current macOS matters), SwiftUI shell with AppKit where SwiftUI is unreliable (text view,
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
  then look at the PNG. `TASKWARRIOR_APP_DUMP=1` prints the view hierarchy, the header menus'
  choices and any confirmation asked. Script lines `@report x`, `@project x|-`, `@context x` act as
  the header menus do (menus can't be opened from a script); `@context` writes the rc file, so
  give it `TASKRC=<scratch copy of ~/.taskrc>`. `@edit <id>` opens a row's description editor,
  `@edit <id> <text>` commits it, `@keys <vim notation>` posts real key events (`@keys cwnew<Esc><CR>`).
  The context comes from the rc file, not `TASKDATA`: when scratch tasks don't show, the real
  `~/.taskrc` is probably in another context, so use a scratch copy with `task context none`.
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
  rc.verbose=<user's list minus override,context> rc.defaultwidth=<cols> rc.defaultheight=<h>`.
  The app must therefore do its own confirmations for anything destructive.
- `task _show` reports the *effective* config: never query it with overrides you don't want read back.
- Reports with `limit:page` (the user's `next`) size themselves from `rc.defaultheight`; without the
  override the app showed only ~20 rows. Both views scroll, so reports run with `rc.defaultheight=0`,
  which lifts the page limit (`DisplayPolicy.height`). Graphs draw to the height and get the
  window's rows: at 0 burndown fails ("Terminal window too large to draw a graph"). Column fit
  comes from `rc.defaultwidth` computed from the text view.
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
- The list view gets its rows by running the report with `rc.report.<name>.columns=uuid`
  and then `task <uuid…> export`. Do not use `task export <report>` instead: it applies the
  report's filter and sort but **ignores the context**. An empty UUID list must never reach
  `export` (no filter exports every task). Only reports with `report.<name>.columns` are
  listable (`ReportQuery.listableReport`); everything else falls back to the text view.
- Rows leave out badges the listing's filters pin (`FilterPins`): the context's read filter, the
  report's `filter` and the typed words, including those after the report name (`next +x`).
  Taskwarrior ANDs these sources, so each is read alone and one with `or`, `not`, `!` or
  parentheses pins nothing; missing a pin only shows a badge, a wrong pin hides information.
  `project:work` is a plain prefix in taskwarrior (it matches `workshop` too), so only an exact
  match is hidden and a subproject shows the rest of its name. The context filter is re-read
  with `_get` after context/config commands, since the startup config goes stale.
- The header menus (`ListingView`) only compose a command line and `run(line:)` it: the report
  word is replaced, the project term replaced (with operators in the typed filter, the whole
  filter), other words kept. `_projects` and `_unique` ignore the context, so the project menu
  filters by the context's pin itself. A context picked from the menu refreshes the view,
  unlike a typed `task context`, and drops the typed project.
- Row actions in the list call `AppModel.perform`, which goes through `run(line:)` with the
  task's UUID (ids are renumbered by the refresh after each modification), so the usual
  confirmation, log and refresh rules apply. Don't add a separate path.
- Inline description editing (`e` / Edit Description, `AppModel.editingUUID`) commits
  `modify description:<text>` as **one** token, quoted with `ShellTokenizer.join`. Taskwarrior 3
  keeps a single `description:` argv whole (`+x`, `due:`, `--`, a leading `-` stay text), whereas
  bare words after `modify` would be parsed as attributes and tags. While editing, the list's
  `onKeyPress` handlers return `.ignored`: they sit above the text field and could take its keys.
- The description field is vi-mode (`ViLineField` + `TaskwarriorCore/ViLineEditor`, starting in
  normal mode). `ViLineEditor` is the only owner of text and cursor; the field is a display. A
  local `NSEvent` key monitor reads the field editor's text and caret into the editor before each
  key and writes them back after, with the normal-mode cursor as a one-character selection. In
  insert mode the monitor takes only Esc, Return, Ctrl-W and Ctrl-U and the field types natively
  (input methods, dead keys); Esc recovers the typed text by diffing, for `.`. Keep vi behaviour
  in `ViLineEditor` with a test, not in the view. Not supported: visual mode, registers other
  than the unnamed one, marks, macros. `:` (outcome `.commandLine`) drops the edit and calls
  `focusCommandField`, without `endEditing`'s refocusing of the list. The focus moves a run-loop
  turn later, so in a script put the keys for the command line in a separate `@keys` line.
- **Focus around the description field is AppKit's job, not `@FocusState`.** SwiftUI doesn't see
  the AppKit field take focus, so a list `@FocusState` still reads true and setting it again
  is a no-op; the window was left with a vanished field editor as first responder and every
  key beeped. `ViLineField` focuses itself from `viewDidMoveToWindow` (one async hop wasn't
  always enough), and on Return / Esc makes the enclosing `NSTableView` first responder
  before the field is removed. `TASKWARRIOR_APP_DUMP` prints the first responder.
- **The command line is visited, like vim's `:` line.** `:` (list, text view, row editor)
  goes there; Return (`submit`, even for an empty line or a failing command) and Esc both
  call `focusDisplay()`, at once, so keys typed during a slow `sync` reach the list. The app
  starts in the list. The selection is the model's (`selectedUUID`, kept while text is shown):
  `ListLanding.intent` is worked out from the typed line against the last listed tasks
  (`listed`) and `resolve`d in `showList`; keep landing rules there, with a test. Focus is
  moved by `DisplayFocus` (AppKit, the same `@FocusState` trap as above): a request always
  moves it to the table or `TerminalNSTextView`, waiting until the view for what is shown now
  is in the window; a list ⇄ text swap moves it only from the old display view or from
  nowhere, never from the command line. Esc in the text view leaves a one-off
  (`displayIsTransient`, i.e. `information`) for the current view. A read-only `NSTextView`
  doesn't scroll for arrows or Page Down, so `TerminalNSTextView` scrolls its clip view itself
  (j/k, Space, g/G too).
- **The help sheet (`HelpView.swift`) is a hand-written table, `HelpSection.all`.** A new key
  or a changed one goes there too; nothing checks it against the code. `help` / `h` / `?` on the
  command line are the app's (`AppCommand`, intercepted at the top of `run(line:)`); `task help`
  typed in full is taskwarrior's, shown as a one-off in the raw view. The sheet scrolls with
  vimango_hybrid's `SheetKeyScroller` (a key monitor scoped to the sheet's window). A bitmap of
  the sheet's window comes out blank, so the scripted snapshot draws `HelpContent` instead.
- **vimango notes are linked by the task's uuid**, the protocol taskchamp and VimNotes use on iOS
  (`TaskwarriorCore/VimangoLink.swift`). "Open/Create vimango Note" (row menu, or a click on the
  indigo icon) opens `vimango://task-note?uuid=&title=&project=`. vimango_hybrid finds the note
  whose `taskwarrior_uuid` column holds the uuid, or creates it (the link moved out of the note's
  frontmatter on 2026-10-16; `~/vimango/docs/taskwarrior-link-column.md`). The task's `vimango`
  annotation is added only after the URL has been accepted, and only once, through `perform`. The
  app claims `taskchampdev` (Info.plist) so `taskchampdev://task/<uuid>`, which hybrid's
  `:task` / File > Open Task sends, shows the task here. `task/new` (creating a task from a note)
  isn't handled yet, since `task add` can't set a uuid (`task import` can).
- Only the text view, log pane and command field are forced dark; the list follows the system.
  `NSView`s in the dark area get `.darkAqua` explicitly because SwiftUI's colour scheme
  environment doesn't reach them.
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

1. **Structured list view (started)** – `TaskListView` draws taskchamp-style one-line rows with a
   context menu, hiding pinned badges; List/Raw toggle (⌘1/⌘2). The done checkbox was removed
   on trial (Space and the menu still mark done). Next: detail pane, grouping by project/due bucket, scheduled/wait hints.
2. **Auto-sync** – debounced `task sync` a few seconds after any modification, plus periodic pull
   (e.g. every 10 min and on app activation); spinner and last-sync time in the status line;
   failures surface once, not on every retry.
3. **In-place editing** – the description is done, with vi keys (`ViLineEditor`). Next: due /
   project the same way, maybe `v` (visual) mode. Decided against libvim for this:
   vimango_macos's libvim + NSTextView editor failed on caret/cursor sync
   (`~/vimango_hybrid/PLAN.md`), and a C dependency is too much for one line. Revisit (starting from
   vimango_macos's `CLibVim` shim, self-drawn view) only if registers or macros are ever wanted.
4. **Row actions** – keyboard selection (j/k or arrows) with shortcuts for done, start/stop,
   delete; context menu with annotate, priority, due, tags; selected task drives a detail pane
   showing `task <uuid> information`.
5. **Quick-add form** – fields for description, project, due, tags, priority with autocompletion
   from `task _projects` / `_tags`; also a global hotkey or menu-bar item for capture.
6. **Command-field autocompletion** – commands, report names, `project:`/`+tag` values.
7. **Context and report switcher (done as header menus)** – report, context and project menus
   in the list header. Possible next steps: a tag menu, and the menus in the Raw view too.
8. **Notifications** – due/overdue reminders via UNUserNotificationCenter.
9. **Appearance** – optional light palette, font family choice, per-window state, multiple windows.
10. **Undo affordance** – after done/delete, a transient "Undo" button in the status line.
11. **Task from a vimango note** – handle `taskchampdev://task/new?uuid=&title=&project=` with
    `task import` of a one-task JSON file (check the uuid doesn't exist first), and give
    vimango_hybrid a command that links the note (`Repository.linkTask`, a metadata write).
