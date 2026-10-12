# Workbench plan: a web editor served by the Varis executable

Status: **proposal with a first version implemented**, October 11, 2026. Section 1a says what
exists; everything else is still the plan. It details milestones 42,
43 and 44 of [ROADMAP.md](ROADMAP.md) Phase 10 and implements decisions D10 and D11 of the ROADMAP
decision record. Language behaviour is defined only by the [manual](docs/README.md).

## 1. What it is and who it is for

The workbench is the main tool for working on a Varis game. One command starts it:

```sh
varis serve path/to/project        # planned; does not exist yet
```

The Varis executable loads the project, keeps its state alive, and serves a web application on
the local machine. The user opens it in a browser. There is nothing else to install: no editor
plug-in, no separate language server process, the same on Windows, macOS and Linux.

Users, in order of how much it must suit them:

1. **The owner**, who prefers the way MATLAB works: type a command, look at the result, inspect
   the variables, edit a file, run again.
2. **Contracted writers**, who write storylets and need to see mistakes and playtest.
3. **Modders**, who write full Lua against a game and need to see what the game's state looks
   like.

## 1a. What exists today

`varis serve [--port N] [project directory]` works (`source/varis/workbench/server.d`,
`page.d`; test: `python3 tools/suite test --suite workbench`). It prints a loopback address with
a token and serves one page with the layout of §3.

| Panel | State |
| --- | --- |
| Command window | Works: expressions print, statements run, multi-line input continues, history with the arrow keys. Output of `print` and `io.write` is captured. |
| Workspace | Works: user-created globals with type and preview. A world opens as its list of relations; a relation opens as a paged table of its base facts. Read-only. |
| Story | Works after `story(session)` in the command window: presents on request, choices are buttons. It presents only when asked, because presenting appends to the session's replay log. |
| Story-level debugging | Partly: after a choice the command window lists the facts the turn added and removed, per relation (computed from the immutable fact tables before and after). "Why?" explains any storylet through `narrative.explain`: eligible or not, each condition's outcome and candidate counts, each instance's exclusions. Rewind and seeds are not implemented. |
| Editor | A plain text area with open, save and Run (runs the file in the live state). No completion or navigation. |
| Source-level debugging | Works for code started from the command window or Run: line breakpoints (file and line), stop with every frame alive, locals of the innermost frame and the call stack in the workspace, step over/into/out, continue, and evaluating in the command window while stopped. Built on the executor's per-line slow path, installed only while a breakpoint or step is pending. Not yet: breakpoints inside the story panel's present/choose, selecting an outer frame, evaluating in a frame's scope, pause, stop-on-error. |
| Problems | Syntax errors of the open file only (the full checker of milestone 30 does not exist). |

Differences from the rest of this plan, all deliberate for a first version: plain HTTP
request/response instead of a WebSocket with pushed events (§6); text bodies and query parameters
instead of JSON requests; no language services; no rewind or history views; derived relations
show only their base facts. While stopped at a breakpoint the server answers requests from inside
the line hook, and the connection that resumes execution receives the evaluation's result.

## 2. The model: MATLAB, with a story

MATLAB's desktop has a command window, an editor, a workspace browser that lists every variable
with its size and value, a variable editor that opens a matrix as a table, a file browser and a
command history. The workbench copies that model because it suits exploratory work on a live
state, which is what developing a story game is.

| MATLAB | Workbench | Notes |
| --- | --- | --- |
| Command Window | **Command window** | A prompt bound to the live state. Any statement of the language runs here, including `query`, `fact`, `transaction` and narrative calls. Results print below the command. |
| Editor | **Editor** | Project files, with diagnostics from the language services (ROADMAP milestone 32), completion, go-to-definition, and a margin for breakpoints. |
| Workspace | **Workspace** | Global variables, and when paused, the locals of the selected frame. Also what Varis has that MATLAB does not: each world with its relations, the qualities, and the session (turn, period, decks, history). |
| Variable editor | **Table view** | Opening a relation shows its facts as a table (columns are the relation's named columns; derived relations are marked). Opening a Lua table shows keys and values. Large values are paged. |
| Current Folder | **Files** | The project tree. |
| Command History | **History** | Commands typed, and the session's command log (the replay log), from which any earlier turn can be revisited. |
| Run / Run Section | **Run** | Reload the project and replay the session's command log, so the game is back where it was with the edited content. |
| (none) | **Story** | Plays the game as text: the current presentation, its choices as buttons. Shows why a storylet or choice is or is not available. |
| (none) | **Problems** | Every diagnostic in the project, as `varis check` reports them. |

## 3. Layout

Default layout (owner preference: command window on the left, editor on the right, a workspace
that is pleasant to use). Panels can be resized; the exact arrangement is an open choice (§9).

```
+-----------------------------------+------------------------------------------+
| Story                             | Editor                                   |
|   The lamp room.                  |   content/lamp.lua  x   world.lua        |
|   > Trim the wick                 |   12  storylet trim_wick()               |
|   > Go down the stairs            |   13      when { at(:player, :lamp) }    |
+-----------------------------------+   14      ...                            |
| Command window                    |                                          |
|   >> query at(:player, ?room)     |                                          |
|   room = :lamp_room               +------------------------------------------+
|   >> s:present()                  | Problems                                 |
|   >> _                            |   lamp.lua:14 unknown symbol :keepr      |
+-----------------------------------+------------------------------------------+
| Workspace          | Files / History                                         |
|   s        session (turn 12)      |   content/  world.lua  game.lua  ...     |
|   w        world (9 relations)    |                                          |
|   at       relation, 51 facts     |                                          |
|   resolve  quality = 14           |                                          |
+-----------------------------------+------------------------------------------+
```

## 4. Architecture

```
  browser (user interface only)            varis executable (native)
  +----------------------------+           +------------------------------------------+
  | editor, command window,    |  HTTP     | workbench server (D)                      |
  | workspace, story, problems | <-------> |   static files of the web application     |
  |                            | WebSocket |   message protocol (JSON)                 |
  +----------------------------+           |        |                |                 |
                                           |  language services   debugger             |
                                           |  (frontend: lexer,   (instrumented        |
                                           |   parser, checker)    executor)           |
                                           |        |                |                 |
                                           |  project state: Lua state, worlds,        |
                                           |  content registry, session                |
                                           +------------------------------------------+
```

Rules that the design must keep:

1. **The engine runs natively.** The browser never runs Varis code. No WebAssembly build is
   needed or planned (ROADMAP D13).
2. **The server is a layer above everything else.** It imports the language services, the
   narrative layer and the core. Nothing below imports the server (ROADMAP D9, AGENTS §4.1).
3. **A state is single-threaded.** One thread owns the project state and runs every command,
   query and debugger request in turn. Network threads only pass messages to it. The pause button
   works by setting a flag the instrumented executor checks; it never touches the state from
   another thread.
4. **Inspection is read-only and uses snapshots.** The workspace and the table view read through
   the existing snapshot queries and read-only explanations, so looking at a value can never
   change the game or consume random numbers. Changing state is always an explicit command in
   the command window, which goes through the same transactions as game code.
5. **Local by default.** The server listens on the loopback address only and requires a token
   printed at start-up, because the command window can run arbitrary code with the user's
   permissions. Listening on another address is an explicit option.
6. **The same services serve external editors.** The language services are a D library. The
   workbench calls it in process; the language server of milestone 32 exposes it over the
   Language Server Protocol. There is one implementation of diagnostics, completion and rename.
7. **Style.** The server is D in the project's style (ROADMAP D6): return values, no exceptions
   in new code, little Phobos.

## 5. Debugging at a higher level

The owner asked for debugging "at a higher level" than Lua's hooks (ROADMAP D11). There are three
levels; the workbench offers the first two.

### 5.1 Story level (needs no interpreter changes)

Built on facilities that already exist and are documented in the manual: `narrative.explain`,
`narrative.observe`, `narrative.analyze`, `session:replay_log()`, saves and replay.

| Feature | Built on |
| --- | --- |
| Step one turn; choose from the story panel | `session:present()`, `session:choose(token)` |
| "Why is this storylet (or choice) not showing?" | `narrative.explain` (reports goal and policy outcomes without consuming random numbers) |
| "What did the last turn change?" | committed tuple changes from `narrative.observe` |
| Rewind to an earlier turn | reload and replay the command log up to that turn; deterministic by construction |
| Try a different seed | `session:seed` on a replayed session |
| "Can this storylet ever appear?" | `narrative.analyze`, which reports its bounds and completeness |
| Browse any relation as a table, at any turn | snapshot queries |

### 5.2 Source level (needs the instrumented executor)

| Feature | Meaning |
| --- | --- |
| Breakpoint | Stop before the first instruction of a source line in a file. Works in content files, engine scripts and mods. |
| Pause | Stop a running command at the next instruction boundary. |
| Step over, into, out | Run to the next line in this function, into a call, or back to the caller. |
| Call stack | The Lua frames, each with file, line and function name. Selecting a frame shows its locals in the workspace. |
| Evaluate | Run an expression in the selected paused frame from the command window. Read-only by default; changing a local is an explicit action. |
| Error stop | When an error is about to leave the outermost call, stop there with the stack intact, as MATLAB's "pause on errors" does. |

How it is built: stage S1 of [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md)
generates two executors from one handler source. The **fast** executor contains no debugging
code. The **instrumented** executor checks, per instruction, a per-function table of breakpoint
positions and the stepping state. A function runs on the instrumented executor when a debugger is
attached. Because errors will be values (ROADMAP D7), "stop where the error happened" is a status
check, not an exception filter.

Stopping inside an effect means stopping inside an open transaction. While stopped, the workspace
shows the transaction's tentative state; continuing commits or rolls back exactly as it would
have. The debugger never commits or rolls back on its own.

### 5.3 Not offered

- Lua's `debug.sethook`, `debug.getlocal` and friends as the tool interface. The `debug` library
  stays as a frozen Lua feature for existing scripts (ROADMAP compatibility policy); the workbench
  does not use it.
- Stepping by bytecode instruction, or showing registers.
- Attaching to a shipped game on a player's machine.

## 6. Protocol sketch

Messages are JSON over one WebSocket: requests with an id, responses with the same id, and events
pushed by the server. Where the Language Server Protocol already defines a message shape
(diagnostics, completion, hover, definition, rename, positions and ranges), use that shape, so the
language server of milestone 32 is a thin transport over the same handlers.

| Group | Requests (client to server) | Events (server to client) |
| --- | --- | --- |
| Command window | `eval {text}` | `output {text}`, `result {values}`, `error {message, trace}` |
| Files | `open`, `save`, `list` | `fileChanged` |
| Language | LSP-shaped `completion`, `hover`, `definition`, `rename` | LSP-shaped `publishDiagnostics` |
| Workspace | `scopes`, `variables {ref, start, count}`, `relation {world, name, start, count}` | `workspaceChanged` |
| Story | `present`, `choose {token}`, `explain {id}`, `rewind {turn}`, `reload` | `presentation`, `turnDiff` |
| Debugger | `setBreakpoints`, `pause`, `continue`, `stepOver`, `stepInto`, `stepOut`, `stack`, `evaluate {frame, text}` | `stopped {reason, file, line}`, `continued` |

Values sent to the workspace are descriptions (type, short preview, child count, a reference for
fetching children page by page), never whole tables.

## 7. Milestones

| Milestone | Deliverable | Depends on | Exit |
| --- | --- | --- | --- |
| 42 | **Server.** `varis serve`; loopback HTTP and WebSocket; `eval`, files, story requests; a minimal page with a command window and the story panel. | The existing CLI and narrative library. | The sample game can be played and queried from a browser; a transcript test drives the protocol without a browser. |
| 43 | **User interface.** Editor with diagnostics, workspace, table view, files, history, problems, the layout of §3. | 42; `varis check` (milestone 30) for diagnostics; milestone 32 for completion and navigation. | The owner can fix a storylet, press Run and see the fixed presentation without leaving the page. |
| 44 | **Debugger.** Story level first (§5.1), then source level (§5.2). | 42 for story level; stage S1 for source level; stage L1 for error stops. | A breakpoint in an effect stops there, shows the tentative transaction state, and continuing gives the same result as running without the debugger. |

Every milestone ships with tests that speak the protocol directly (a script sends requests and
compares responses with golden output), so the server is tested without a browser. User-interface
tests are a separate, smaller layer.

## 8. What to reuse

| Need | Existing code |
| --- | --- |
| Running typed commands | The REPL in `source/varis/cli.d` (`doREPL`): incomplete-statement detection and expression echo. |
| Source positions | AST nodes carry line and column (`ast.d`). |
| Explanations, change sets, analysis, replay | `narrative/diagnostics.d`, `observe.d`, `analysis.d`, `persistence.d`. |
| Per-instruction slow path | The `vmSlowMode` / `vmAttention` mechanism in `state.d` and `vm.d`, which becomes the instrumented executor in stage S1. |
| A scripted playthrough to test against | `sample-game/tools/check.lua`. |

## 9. Open choices (owner)

Use the default until the owner decides, and say so in the change.

| Choice | Default | Reason for the default |
| --- | --- | --- |
| Editor component in the browser | CodeMirror 6, vendored as a prebuilt bundle | Small, no build step in this repository, good custom-language support. Monaco is the alternative if a VS Code-like editor is wanted. |
| HTTP and WebSocket implementation | A small hand-written loopback server in D | The build has no package manager (the Makefile lists every source file) and the style avoids large dependencies (D6). vibe.d is the alternative. |
| Where the workspace panel sits | Bottom left, under the command window | Owner asked for command window left, editor right. |
| Whether the web application's source lives in this repository | Yes, under `workbench/`, as plain HTML, CSS and JavaScript with no build step | Keeps "one executable, nothing to install". |
| Whether `varis serve` also speaks the Language Server Protocol on standard input and output | Yes, as `varis lsp`, in milestone 32 | Writers who prefer their own editor. |
