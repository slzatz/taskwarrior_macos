# Taskwarrior for macOS

A native macOS window around the `task` command line. The top pane shows the
current taskwarrior report, either as a list of native rows (the default) or
exactly as the terminal would print it (colours included); the field at the
bottom accepts any taskwarrior command; an output pane in between shows what
non-report commands said.

Requirements: macOS 15+, Xcode 15+ command line tools, taskwarrior 3.x on the
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

- **List / Raw** (the switch in the output pane header, or **⌘1** / **⌘2**) chooses how
  reports are drawn. List shows each task as one line: the description in the system font,
  then project, priority and tag badges, and a short due date at the right (red when
  overdue). A task with no due date shows its scheduled date there instead, after a
  calendar glyph, so the `facts`-style reports read as they do in Raw. Badges that the context or filter already pin are left out: under the
  `work` context no row says `work`, and `work.infra` shows as `infra`.
  The list's header is three menus, **report ▾ · context ▾ · project ▾**, followed by
  any other words of the typed filter. Each builds a command line and runs it as if
  typed (`task +ops project:work.infra all`), keeping the filter words the other menus
  don't own. Picking a context runs `task context <name>`, which changes it for the
  command line too, and shows the listing again without the old project. The
  projects offered are those inside the context, nested by subproject; when there are
  none (a context on a project without subprojects) the project menu is left out.
  The rows are exactly the report's, in its order, with the context applied. The app
  starts with the list focused on its first task. Select
  a row (arrows, or **j** / **k**) and press **Space** (or right-click → Done) to mark it done; double-click or
  **Return** shows `information` (**Esc** there goes back to the list, on the same task);
  right-click also has start/stop, delete and Copy UUID.
  **:** moves to the command line (from the raw view too). As with vim's `:` line, you go
  back to the list from it either way: **Return** runs the line, **Esc** drops it.
  A command that acts on tasks typed without a filter acts on the selected one, as an ex
  command does on vim's current line: `:done`, `:modify due:fri +home`, `:annotate …`,
  `:start`, `:delete` (also `append`, `prepend`, `denotate`, `duplicate`, `info`, `purge`).
  This also works on a task's `information` page, but nowhere else in the raw view, where the
  selection isn't shown. A filter is used as typed (`5 done`, `+home done`); the ids are in
  the raw view. After
  `:done`, `5 done`, `3 modify …` or a row action the selection is on that task, or on the row that
  took its place if it left the list; after `add`, on the new task if the list shows it;
  after a new listing, on its first row; after anything else (`sync`, `show`, …) it stays
  where it was.
  **e** (or right-click → Edit Description) edits the description in its row with vi keys,
  starting in normal mode on the last character: motions (`h l w b e W B E 0 ^ $ f t F T ; ,`),
  `x X r s S C D ~ p P`, `i a I A`, `d c y` with a motion or text object (`iw aw`, quotes,
  brackets), counts, `u`, Ctrl-R and `.`; in insert mode the field types normally, plus Ctrl-W
  and Ctrl-U. A NORMAL/INSERT badge shows the mode. **Return** (either mode) saves it with
  `task <uuid> modify description:…`; **Esc** in normal mode, or clicking away, cancels, and
  **:** in normal mode cancels and moves to the command line. The text is passed as one argument, so
  `+tag` or `due:` in it stays text.
  Graphs, `information` and other non-task output always use the raw view. There **j** / **k**
  (or Down / Up) scroll a line, **Space** / Page Down and Page Up a page, **g** and **G** go to
  the top and bottom, and **:** moves to the command line. The list
  follows the system light/dark appearance; the raw view stays dark because
  taskwarrior's colours assume a black terminal.
- **help** (or **h**, **?**) on the command line, **?** in the list or the raw view, and
  Help > Keyboard and Commands (**⌘?**) open a sheet listing every key and how commands
  behave; it scrolls with j/k, Space, g/G and Ctrl-D/U, and **Esc** closes it. Typed in full,
  `task help` shows taskwarrior's own help in the raw view (**Esc** goes back).
- **Up / Down** walk the command history (kept between launches), so **:** then **Up**
  repeats or fixes the last line. **Esc** clears the field and goes back to the list.
- **⌘=** / **⌘-** / **⌘0** change the font size; the report is re-run so columns fit the window.
- **⌘R** re-runs the current listing, **⌘L** focuses the command field,
  **⌘⇧O** shows or hides the output pane, **⌘K** clears it.
- Window size and font size are remembered. Resizing the window re-runs the
  listing at the new width (and a graph at the new height). Reports aren't cut to
  the window: `limit:page` (as in `next`) shows every task, since both views scroll.

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
rc._forcecolor=on rc.defaultwidth=<columns> rc.defaultheight=<h>` (0, no page limit,
except the window's rows for graphs) and a
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

A script line starting with `@` does what a header menu does, on the listing
the lines before it produced: `@report ready`, `@project work.infra` (`@project -`
for all projects), `@context personal` (`@context none`). `@context` runs
`task context`, which writes to the rc file, so point `TASKRC` at a scratch copy.
`@edit 3` opens task 3's description editor as **e** does; `@edit 3 new text` saves
`new text` as Return would. `@keys 0cwnew<Esc><CR>` types keys in vim notation
(`<Esc> <CR> <BS> <Left> <Right> <Up> <Down> <C-w>`) as real key events. The dump below
includes the window's first responder, which is where keys go, and the selected task.
While the help sheet is open, keys go to it and the snapshot shows its contents.

`TASKWARRIOR_APP_DUMP=1` additionally prints the view hierarchy, the header menus'
choices and any confirmation the app would have asked for.

## Layout

```
Sources/TaskwarriorCore   no UI; unit-tested
  CommandCatalog.swift    command names/categories/aliases from taskwarrior, abbreviation rules
  ParsedCommand.swift     "[filter] command [args]" split of a typed line
  DisplayPolicy.swift     what to do with each command's output; confirmation rules
  ANSIParser.swift        colour escape codes -> styled runs
  TaskRunner.swift        runs the task binary
  TaskItem.swift          one task decoded from `task export`
  ReportQuery.swift       which reports can be listed; the uuid-listing + export queries
  FilterPins.swift        the project/priority/tags a listing's filters pin, so rows skip them
  TaskEnvironment.swift   reads the user's relevant rc settings
Sources/TaskwarriorApp    SwiftUI + AppKit
  AppModel.swift          all state; serial command queue; geometry -> defaultwidth/height
  TerminalTextView.swift  non-wrapping monospaced NSTextView for the report
  TaskListView.swift      the report as native rows (styled after taskchamp's task cells)
  CommandField.swift      NSTextField with history navigation
  ContentView.swift       layout, output pane, confirmation alert
  TerminalStyle.swift     palette and attributed-string building
```

## Roadmap

1. **Done (this stage):** verbatim report display, command field with history,
   refresh rules, output pane, confirmations, font zoom, geometry-aware reports.
2. **Structured view (started):** reports are drawn as native rows with a
   context menu. Next: a detail pane for the selected task,
   editing other fields in place, keyboard navigation, grouping by project or due date.
3. **Quick-add form** with project/tag completion.
4. Optional light theme / font choice; auto-sync on a timer.
