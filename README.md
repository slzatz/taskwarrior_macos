# Taskwarrior for macOS

A native macOS window around the `task` command line. The top pane shows a
taskwarrior report exactly as the terminal would print it (colours included);
the field at the bottom accepts any taskwarrior command; an output pane in
between shows what non-report commands said.

Requirements: macOS 14+, Xcode 15+ command line tools, taskwarrior 3.x on the
machine (`brew install task`).

## Build and run

```sh
make          # release build -> build/Taskwarrior.app
make run      # build and open it
make debug    # faster debug build
make test     # unit tests for the core library
```

The app is a plain Swift package; `open Package.swift` works in Xcode too.

## Using it

Type commands with or without the leading `task`:

```
next
project:work +urgent
5 done
add Buy milk due:tomorrow
sync
```

The line is not run through a shell. A leading `task` is stripped, the rest is
split into arguments (honouring quotes, so `add "Buy milk" due:tomorrow` is three
arguments) and handed straight to the `task` binary. Globs, `$VARIABLES`, pipes,
`&&` and redirection are therefore passed to taskwarrior verbatim rather than
expanded, and no other program can be run from the field.

- **Up / Down** walk the command history (kept between launches). **Esc** clears the field.
- **⌘=** / **⌘-** / **⌘0** change the font size; the report is re-run so columns fit the window.
- **⌘R** re-runs the current listing, **⌘L** focuses the command field,
  **⌘⇧O** shows or hides the output pane, **⌘K** clears it.
- Window size and font size are remembered. Resizing the window re-runs the
  listing at the new width and height (so `limit:page` reports fill the window).

### What refreshes the display

The app asks taskwarrior how it classifies each command (`task _zshcommands`),
so custom reports and aliases are recognised automatically. The rules live in
`Sources/TaskwarriorCore/DisplayPolicy.swift`:

| Command kind (taskwarrior category)                 | Behaviour                                                        |
|-----------------------------------------------------|------------------------------------------------------------------|
| report, graphs (`next`, `list`, `calendar`, ...)     | Output replaces the display and becomes the *current view*.      |
| filter only (`project:work`)                        | Runs the default command with that filter; same as a report.     |
| `information`, `projects`, `tags`, `stats`           | Shown in the display but not remembered as the current view.     |
| operation (`add`, `done`, `modify`, `undo`, ...), `sync`, `import` | Output goes to the output pane, then the current view is re-run. |
| `context`, `config`, `show`, `export`, `help`, ...  | Output goes to the output pane; the display is left alone.       |
| `edit`, `execute`                                   | Refused (they need a terminal).                                  |

Ambiguous abbreviations behave as in taskwarrior: `task ne` is a filter word,
not `next`; `task nex` is `next`.

### Confirmations

Taskwarrior's own yes/no prompts are disabled (`rc.confirmation=off`) because
there is no terminal to answer them in. Instead the app shows a native dialog
before `delete`, `purge` and `undo`, and before any operation whose filter
matches more tasks than your `bulk` setting (a `bulk` of 0 disables that, as
in taskwarrior). `rc.allow.empty.filter=no` is always passed, so a bare
`task delete` cannot touch every task.

### Overrides the app applies

Every invocation gets `rc.confirmation=off rc.allow.empty.filter=no
rc._forcecolor=on rc.defaultwidth=<columns> rc.defaultheight=<rows>` and a
`rc.verbose=` list equal to yours minus `override` and `context` (the status
line shows the active context instead). Your own `rc.` tokens on the command
line still win because they come later.

The `task` binary is found in the usual Homebrew/MacPorts locations, then
`PATH`, then via a login shell. To pin it:

```sh
defaults write com.szatz.taskwarrior-macos taskExecutable /path/to/task
```

## Scripted runs (development)

Environment variables drive the app for testing without clicking:

```sh
TASKDATA=/tmp/scratch \
TASKWARRIOR_APP_SCRIPT="add project:work Buy milk;;1 done;;next" \
TASKWARRIOR_APP_SNAPSHOT=/tmp/window.png \
TASKWARRIOR_APP_QUIT=1 \
build/Taskwarrior.app/Contents/MacOS/Taskwarrior
```

`TASKWARRIOR_APP_DUMP=1` additionally prints the view hierarchy and any
confirmation the app would have asked for.

## Layout

```
Sources/TaskwarriorCore   no UI; unit-tested
  CommandCatalog.swift    command names/categories/aliases from taskwarrior, abbreviation rules
  ParsedCommand.swift     "[filter] command [args]" split of a typed line
  DisplayPolicy.swift     what to do with each command's output; confirmation rules
  ANSIParser.swift        colour escape codes -> styled runs
  TaskRunner.swift        runs the task binary
  TaskEnvironment.swift   reads the user's relevant rc settings
Sources/TaskwarriorApp    SwiftUI + AppKit
  AppModel.swift          all state; serial command queue; geometry -> defaultwidth/height
  TerminalTextView.swift  non-wrapping monospaced NSTextView for the report
  CommandField.swift      NSTextField with history navigation
  ContentView.swift       layout, output pane, confirmation alert
  TerminalStyle.swift     palette and attributed-string building
```

## Roadmap

1. **Done (this stage):** verbatim report display, command field with history,
   refresh rules, output pane, confirmations, font zoom, geometry-aware reports.
2. **Structured view:** run `task <filter> export` alongside the report and
   render a real table (NSTableView) with a checkbox per row that issues
   `task <uuid> done`. The report's column list comes from `task _show`
   (`report.<name>.columns`). `ParsedCommand.filter` already isolates the
   filter for this.
3. **Quick-add form** and per-row context menu (start/stop, annotate, modify).
4. Optional light theme / font choice; auto-sync on a timer.
