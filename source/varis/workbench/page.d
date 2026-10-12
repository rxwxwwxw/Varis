/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The workbench's web page (WORKBENCH_PLAN.md §3): story and command window on the left with the
/// workspace under them, editor on the right with problems under it. Plain HTML, CSS and
/// JavaScript with no build step for users; the vendored CodeMirror bundle is embedded.
module varis.workbench.page;

immutable string workbenchPage = q"HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Varis workbench</title>
<style>
  :root { --line: #c9ccd1; --ink: #1c1e21; --soft: #5f6368; --bg: #fafafa; --panel: #ffffff; --accent: #205493; --bad: #a4262c; }
  @media (prefers-color-scheme: dark) {
    :root { --line: #3a3d42; --ink: #e6e6e6; --soft: #a0a4ab; --bg: #17181a; --panel: #1f2023; --accent: #8ab4f8; --bad: #f28b82; }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body { background: var(--bg); color: var(--ink); font: 14px/1.4 system-ui, sans-serif; }
  #grid { position: relative; --left: 42%; --top: 30%; --bottom: 26%; display: grid; height: 100%; gap: 6px; padding: 6px;
          grid-template-columns: minmax(280px, var(--left)) 1fr;
          grid-template-rows: minmax(120px, var(--top)) 1fr minmax(120px, var(--bottom));
          grid-template-areas: "story editor" "command editor" "workspace problems"; }
  .splitter { position: absolute; z-index: 3; touch-action: none; border-radius: 2px; }
  .splitter:hover, .splitter:focus { background: var(--accent); outline: 0; }
  .splitter.vertical { width: 6px; cursor: col-resize; }
  .splitter.horizontal { height: 6px; cursor: row-resize; }
  #commandHistory { border-top: 1px solid var(--line); max-height: 35%; overflow: auto; }
  #commandHistory button { display: block; width: 100%; text-align: left; white-space: pre-wrap; border: 0; border-radius: 0; font-family: ui-monospace, monospace; }
  section { background: var(--panel); border: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  section > header { flex-wrap: wrap; padding: 4px 8px; border-bottom: 1px solid var(--line); color: var(--soft);
                     font-size: 12px; text-transform: uppercase; letter-spacing: .04em; display: flex; gap: 8px; align-items: center; }
  section > .body { flex: 1; overflow: auto; padding: 8px; min-height: 0; }
  #story { grid-area: story; } #command { grid-area: command; } #workspace { grid-area: workspace; }
  #editor { grid-area: editor; } #problems { grid-area: problems; }
  pre, code, textarea, input, .mono { font: 13px/1.45 ui-monospace, Menlo, Consolas, monospace; }
  #log { white-space: pre-wrap; word-break: break-word; margin: 0; }
  #log .in { color: var(--accent); } #log .err { color: var(--bad); }
  #prompt { display: flex; border-top: 1px solid var(--line); }
  #prompt span { padding: 6px 4px 6px 8px; color: var(--accent); }
  #input { flex: 1; border: 0; outline: 0; padding: 6px 8px 6px 0; background: transparent; color: var(--ink); resize: none; }
  #edwrap { position: relative; flex: 1; min-height: 0; overflow: hidden; }
  .branches { margin: 2px 0 4px 8px; padding-left: 8px; border-left: 2px solid var(--line); }
  button, select { font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 3px; padding: 2px 8px; }
  button:hover { border-color: var(--accent); }
  table { border-collapse: collapse; width: 100%; }
  td, th { text-align: left; padding: 2px 8px 2px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--soft); font-weight: 500; }
  .storylet { margin-bottom: 10px; } .storylet h3 { margin: 0 0 2px; font-size: 14px; }
  .storylet p { margin: 0 0 4px; white-space: pre-wrap; }
  .link { color: var(--accent); cursor: pointer; text-decoration: underline; }
  dialog { color: var(--ink); background: var(--panel); border: 1px solid var(--line); border-radius: 4px; width: min(850px, 94vw); max-height: 88vh; overflow: auto; }
  dialog::backdrop { background: #0006; }
  dialog h3 { margin: 4px 0 12px; }
  dialog details { margin: 8px 0; }
  dialog summary { cursor: pointer; }
  dialog pre { white-space: pre-wrap; overflow-wrap: anywhere; }
  #analysisForm { display: flex; flex-wrap: wrap; gap: 8px; align-items: end; margin: 12px 0; }
  #analysisForm label { display: flex; flex-direction: column; }
  #analysisForm input { width: 8em; }
  .muted { color: var(--soft); } .spacer { flex: 1; }
  #debugBar { padding: 4px 8px; border-bottom: 1px solid var(--line); color: var(--bad); }
  #editorInfo { padding: 8px; border-bottom: 1px solid var(--line); max-height: 30%; overflow: auto; white-space: pre-wrap; }
  #breaks { padding: 2px 8px; font-size: 12px; } #breaks:empty { display: none; }
  #breakLine { border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 3px; padding: 2px 4px; }
  @media (max-width: 760px) {
    #grid { grid-template-columns: 1fr; grid-template-rows: auto; height: auto;
            grid-template-areas: "story" "command" "workspace" "editor" "problems"; }
    section { min-height: 220px; }
    .splitter { display: none; }
  }
</style>
</head>
<body>
<div id="grid">
  <section id="story"><header>Story <span class="spacer"></span><span id="turn" class="muted"></span>
      <select id="whyId" title="Why is this storylet showing or not?"></select><button id="why">Why?</button><button id="analyzeStory">Analyze</button>
      <select id="language" title="Language of the story (a view: nothing is presented again)"><option value="">source</option></select>
      <input id="seed" type="number" value="42" aria-label="Playtest seed" style="width:5em"><button id="startStory">Start</button><button id="reloadStory">Reload</button><button id="rewindStory">Rewind</button><button id="storyHistory">History</button><button id="refreshStory">Present</button><select id="sceneId" aria-label="Scene to play"></select><button id="playScene">Play scene</button></header>
    <div class="body" id="storyBody"><span class="muted">No session. In the command window, create one and call <code>story(session)</code>.</span></div>
    <div class="body" id="translations"></div></section>
  <section id="command"><header>Command window <span class="spacer"></span><button id="pauseRun" title="Pause the running command at its next line">Pause</button><button id="stopRun" title="Abort the running command">Stop</button><button id="toggleHistory" aria-expanded="false" aria-controls="commandHistory">History</button></header>
    <div class="body"><pre id="log"></pre></div>
    <div id="commandHistory" hidden></div>
    <div id="prompt"><span>&gt;&gt;</span><textarea id="input" rows="1" spellcheck="false" autofocus></textarea></div></section>
  <section id="workspace"><header>Workspace <span class="spacer"></span><span id="crumb" class="muted"></span></header>
    <div class="body" id="workspaceBody"></div></section>
  <section id="editor"><header>Editor <select id="files"></select><span id="dirty" class="muted"></span>
      <span class="spacer"></span><input id="breakLine" class="mono" size="4" placeholder="line" title="Line number for a breakpoint in this file">
      <button id="toggleBreak">Break</button><button id="definition" title="Go to the definition of the name under the cursor (F12)">Definition</button><button id="hover">Hover</button><button id="rename">Rename</button><button id="save">Save all</button><button id="run">Run</button></header>
    <div id="debugBar" class="mono" hidden><span id="where"></span> <button id="dbgContinue">Continue</button>
      <button id="dbgOver">Step over</button><button id="dbgInto">Step into</button><button id="dbgOut">Step out</button></div>
    <div id="breaks" class="muted mono"></div>
    <div id="editorInfo" class="mono" hidden></div><div id="edwrap"></div></section>
  <section id="problems"><header>Problems</header><div class="body mono" id="problemsBody"><span class="muted">None.</span></div></section>
  <div id="columnSplit" class="splitter vertical" role="separator" aria-label="Resize command and editor columns" aria-orientation="vertical" tabindex="0"></div>
  <div id="storySplit" class="splitter horizontal" role="separator" aria-label="Resize story panel" aria-orientation="horizontal" tabindex="0"></div>
  <div id="workspaceSplit" class="splitter horizontal" role="separator" aria-label="Resize workspace and problems row" aria-orientation="horizontal" tabindex="0"></div>
</div>
<dialog id="storyInspection"><button id="closeStoryInspection">Close</button><div id="storyInspectionBody"></div></dialog>
<dialog id="analysisDialog"><button id="closeAnalysis">Close</button>
  <h3>Bounded story analysis</h3>
  <p>Explores choices from this session in isolated copies, using one seeded presentation at each node.
  It excludes alternate random draws, repeated presentations, future host inputs and observer queues. Scene boundaries stop this exploration; they can appear as nodes without storylet choices.
  Not reached within these bounds does not prove unreachable.</p>
  <form id="analysisForm">
    <label>Depth<input name="depth" type="number" min="0" max="32" value="3" required></label>
    <label>Nodes<input name="max_nodes" type="number" min="1" max="10000" value="100" required></label>
    <label>VM steps<input name="max_steps" type="number" min="1" value="1000000" required></label>
    <label>Graph objects<input name="max_objects" type="number" min="1" value="200000" required></label>
    <button type="submit">Run analysis</button>
  </form><div id="analysisResult" aria-live="polite"></div>
</dialog>
<script>
HTML"
    ~ import("editor.bundle.js") ~ q"HTML
</script>
<script>
const token = new URLSearchParams(location.search).get("token") || "";
const $ = id => document.getElementById(id);
async function api(path, params, body) {
  const query = new URLSearchParams(Object.assign({ token }, params || {}));
  const response = await fetch(path + "?" + query, body === undefined ? {} : { method: "POST", body });
  const type = response.headers.get("Content-Type") || "";
  if (!response.ok) throw new Error(await response.text());
  return type.includes("json") ? response.json() : response.text();
}
function el(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes || {})) {
    if (key === "onclick") node.onclick = value; else if (key === "class") node.className = value; else if (value !== false && value != null) node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children) node.append(child);
  return node;
}

window.addEventListener("unhandledrejection", event => {
  logLine(String(event.reason?.message || event.reason) + "\n", "err");
  event.preventDefault();
});

// Command window
function readPreference(key, fallback) {
  try { const value = localStorage.getItem(key); return value ? JSON.parse(value) : fallback; } catch { return fallback; }
}
function writePreference(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch {} }
const storedHistory = readPreference("varis.workbench.commands", []);
const history = Array.isArray(storedHistory) ? storedHistory.filter(x => typeof x === "string").slice(-500) : [];
let historyAt = history.length; let pending = "";
function renderCommandHistory() {
  const body = $("commandHistory"); body.textContent = "";
  for (const command of [...history].reverse()) body.append(el("button", { onclick: () => {
    $("input").value = command; $("input").focus();
  } }, command));
  if (!history.length) body.textContent = "No commands yet.";
}
$("toggleHistory").onclick = () => {
  $("commandHistory").hidden = !$("commandHistory").hidden;
  $("toggleHistory").setAttribute("aria-expanded", String(!$("commandHistory").hidden));
  renderCommandHistory();
};
function logLine(text, cls) { const span = el("span", { class: cls || "" }, text); $("log").append(span); $("log").parentNode.scrollTop = 1e9; }
async function submit(text) {
  const full = pending ? pending + "\n" + text : text;
  logLine((pending ? ".. " : ">> ") + text + "\n", "in");
  const inspecting = !$("debugBar").hidden;
  const result = await api(inspecting ? "/api/inspect" : "/api/eval", inspecting && selectedFrame >= 0 ? { frame: selectedFrame } : {}, full);
  if (result.incomplete) { pending = full; return; }
  pending = "";
  if (inspecting) {
    if (result.output) logLine(result.output);
    if (result.error) logLine(result.error + "\n", "err");
  } else showOutcome(result);
}
// An evaluation either finishes or stops at a breakpoint; a resumed one reports the same way.
async function showOutcome(result) {
  if (result.stopped) {
    $("debugBar").hidden = false;
    $("where").textContent = "stopped at " + result.file + ":" + result.line;
    logLine("stopped at " + result.file + ":" + result.line + "\n", "err");
    if (result.file !== current && [...$("files").options].some(o => o.value === result.file)) await openFile(result.file);
    if (result.file === current) { selectLine(result.line); source.stoppedLine(result.line); }
    showLocals();
    return;
  }
  if (result.session) renderStory(result);
  $("debugBar").hidden = true; source.stoppedLine(0);
  if (result.output) logLine(result.output);
  if (!result.ok && result.error) logLine(result.error + "\n", "err");
  refreshWorkspace();
}
function selectLine(line) { source.selectLine(line); }
let selectedFrame = -1;
async function showLocals(frame = -1) {
  selectedFrame = frame;
  const [locals, stack] = await Promise.all([api("/api/locals", frame < 0 ? {} : { frame }), api("/api/stack")]);
  const body = $("workspaceBody"); body.textContent = ""; back("workspace", refreshWorkspace);
  const table = el("table", {}, el("tr", {}, el("th", {}, "Local"), el("th", {}, "Type"), el("th", {}, "Value")));
  for (const row of locals.locals) table.append(el("tr", {}, el("td", { class: "mono" }, row.name), el("td", {}, row.type), el("td", { class: "mono" }, row.value)));
  body.append(table);
  for (const f of stack.frames) body.append(el("div", { class: "link mono", onclick: async () => {
    await showLocals(f.frame);
    if ([...$("files").options].some(o => o.value === f.file)) { await openFile(f.file); selectLine(f.line); }
  } }, (frame === f.frame ? "▶ " : "") + f.name + " " + f.file + ":" + f.line));
}
async function resume(path, params) { showOutcome(await api(path, params, "")); }
// Pause and Stop are answered while a command is running, so they bypass the request queue
// that the running command's own response is waiting in.
$("pauseRun").onclick = async () => {
  const r = await api("/api/pause", {}, "");
  if (r.error) logLine(r.error + "\n", "err");
};
$("stopRun").onclick = async () => {
  const r = await api("/api/interrupt", {}, "");
  if (r.running) return;
  if (r.error && r.ok === false && r.output === undefined) logLine(r.error + "\n", "err");
  else showOutcome(r);
};
$("dbgContinue").onclick = () => resume("/api/continue");
$("dbgOver").onclick = () => resume("/api/step", { mode: "over" });
$("dbgInto").onclick = () => resume("/api/step", { mode: "into" });
$("dbgOut").onclick = () => resume("/api/step", { mode: "out" });
let breakpoints = [];
function renderBreaks() {
  $("breaks").textContent = breakpoints.length ? "breakpoints: " + breakpoints.join("  ") : "";
  source.breakpoints(breakpoints.filter(b => b.startsWith(current + ":")).map(b => Number(b.slice(current.length + 1))));
}
let breakRequest = Promise.resolve(), breakRevision = 0;
function commitBreakpoints(next) {
  breakpoints = next; renderBreaks();
  const revision = ++breakRevision, body = breakpoints.join("\n");
  breakRequest = breakRequest.catch(() => {}).then(async () => {
    const data = await api("/api/breakpoints", {}, body);
    if (revision === breakRevision) { breakpoints = data.breakpoints.map(b => b.file + ":" + b.line); renderBreaks(); }
  });
  return breakRequest;
}
function movedBreakpoints(lines) {
  const prefix = current + ":";
  const next = breakpoints.filter(b => !b.startsWith(prefix)).concat(lines.map(line => prefix + line));
  if (next.join("\n") !== breakpoints.join("\n")) commitBreakpoints(next);
}
$("toggleBreak").onclick = () => toggleBreakpoint(parseInt($("breakLine").value, 10));
function toggleBreakpoint(line) {
  if (!current || !(line > 0)) return;
  const key = current + ":" + line;
  return commitBreakpoints(breakpoints.includes(key) ? breakpoints.filter(b => b !== key) : breakpoints.concat([key]));
}
// Tab completes the name before the cursor (in the command window and the editor).
async function completeIn(area) {
  const at = area.selectionStart; const before = area.value.slice(0, at);
  const line = before.slice(before.lastIndexOf("\n") + 1);
  const indexed = area === source;
  const result = indexed ? await editorRequest("complete") : await api("/api/complete", {}, line);
  const data = indexed ? { prefix: (before.match(/\w*$/) || [""])[0], items: (result.items || []).map(i => ({ name: i.label })) } : result;
  if (!data.items || !data.items.length) return false;
  let common = data.items[0].name;
  for (const item of data.items) { while (!item.name.startsWith(common)) common = common.slice(0, -1); }
  const extra = common.slice(data.prefix.length);
  if (extra) { area.setRangeText(extra, at, at, "end"); if (area === source) markDirty(); }
  if (data.items.length > 1) logLine(data.items.map(i => i.name).join("  ") + "\n");
  return true;
}
$("input").addEventListener("keydown", event => {
  if (event.key === "Tab") { event.preventDefault(); completeIn($("input")); return; }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    const text = $("input").value; $("input").value = "";
    if (text.trim() === "" && !pending) return;
    history.push(text); if (history.length > 500) history.shift();
    writePreference("varis.workbench.commands", history); renderCommandHistory();
    historyAt = history.length; submit(text);
  } else if (event.key === "ArrowUp" && historyAt > 0) { historyAt--; $("input").value = history[historyAt]; event.preventDefault(); }
  else if (event.key === "ArrowDown" && historyAt < history.length) { historyAt++; $("input").value = history[historyAt] || ""; event.preventDefault(); }
});

// Workspace
async function refreshWorkspace() {
  const data = await api("/api/workspace");
  $("crumb").textContent = "";
  const body = $("workspaceBody"); body.textContent = "";
  if (!data.variables || !data.variables.length) { body.append(el("span", { class: "muted" }, "No variables yet. Globals you create appear here.")); return; }
  const table = el("table", {}, el("tr", {}, el("th", {}, "Name"), el("th", {}, "Type"), el("th", {}, "Value")));
  for (const row of data.variables) {
    const name = row.world ? el("span", { class: "link", onclick: () => showWorld(row.name) }, row.name)
      : row.table ? el("span", { class: "link", onclick: () => showTable({ name: row.name }) }, row.name)
      : row.session ? el("span", { class: "link", onclick: showSession }, row.name) : row.name;
    table.append(el("tr", {}, el("td", { class: "mono" }, name), el("td", {}, row.type), el("td", { class: "mono" }, row.preview)));
  }
  body.append(table);
}
function back(label, action) { $("crumb").textContent = ""; $("crumb").append(el("span", { class: "link", onclick: action }, "< " + label)); }
async function showWorld(world) {
  const data = await api("/api/relations", { world });
  const body = $("workspaceBody"); body.textContent = ""; back("workspace", refreshWorkspace);
  if (data.error) { body.append(el("span", { class: "muted" }, data.error)); return; }
  const table = el("table", {}, el("tr", {}, el("th", {}, "Relation of " + world), el("th", {}, "Arity"), el("th", {}, "Base facts"), el("th", {}, "")));
  for (const r of data.relations)
    table.append(el("tr", {}, el("td", { class: "mono" }, el("span", { class: "link", onclick: () => showFacts(world, r.name, 0, r.derived) }, r.name)),
      el("td", {}, String(r.arity)), el("td", {}, String(r.count)), el("td", { class: "muted" }, (r.derived ? "derived " : "") + (r.keyed ? "keyed" : ""))));
  body.append(table);
}
async function showFacts(world, name, start, derived = false) {
  const data = await api("/api/facts", { world, name, start, count: 100, derived });
  const body = $("workspaceBody"); body.textContent = ""; back(world, () => showWorld(world));
  if (data.error) { body.append(el("span", { class: "muted" }, data.error)); return; }
  const table = el("table", {}, el("tr", {}, ...data.columns.map(c => el("th", {}, c))));
  for (const row of data.rows) table.append(el("tr", {}, ...row.map(v => el("td", { class: "mono" }, v))));
  body.append(el("div", { class: "muted" }, name + ": " + data.total + (derived ? " facts (including derived)" : " base facts") + (data.total > data.rows.length ? ", showing " + (start + 1) + "-" + (start + data.rows.length) : "")), table);
  if (start + data.rows.length < data.total) body.append(el("button", { onclick: () => showFacts(world, name, start + 100, derived) }, "Next 100"));
}

async function showTable(reference, start = 0) {
  const data = await api("/api/table", { ...reference, start, count: 100 });
  const body = $("workspaceBody"); body.textContent = ""; back("workspace", refreshWorkspace);
  if (data.error) { body.textContent = data.error; return; }
  const table = el("table", {}, el("tr", {}, ...["Key", "Type", "Value"].map(t => el("th", {}, t))));
  for (const r of data.rows) table.append(el("tr", {}, el("td", { class: "mono" }, r.key), el("td", {}, r.type),
    el("td", { class: "mono" }, r.ref < 0 ? r.preview : el("span", { class: "link", onclick: () => showTable({ ref: r.ref }) }, r.preview))));
  body.append(table);
  if (start) body.append(el("button", { onclick: () => showTable(reference, Math.max(0, start - 100)) }, "Previous 100"));
  if (start + data.rows.length < data.total) body.append(el("button", { onclick: () => showTable(reference, start + 100) }, "Next 100"));
}
async function showSession() {
  const data = await api("/api/session");
  const body = $("workspaceBody"); body.textContent = ""; back("workspace", refreshWorkspace);
  if (data.error) { body.textContent = data.error; return; }
  body.append(el("div", {}, "Turn " + data.turn + " · deck " + data.deck));
  for (const p of data.periods) body.append(el("div", {}, "Period " + p.name + ": " + p.value));
  for (const d of data.decks) body.append(el("div", {}, "Deck " + d.name + ": " + d.drawn + " drawn"));
  for (const c of data.completed) body.append(el("div", { class: "mono" }, "Turn " + c.turn + ": " + c.instance));
}

// Story
async function refreshStory(explicit) {
  const data = await api("/api/present");
  if (data.stopped) { showOutcome(data); return; }
  if (data.error) { if (explicit) { $("storyBody").textContent = ""; $("storyBody").append(el("span", { class: "muted" }, data.error)); } return; }
  renderStory(data);
}
// Language: the select lists the project's locales and the pseudo-locale. A switch renders the
// presentation again; the translation panel lists its messages and saves a translation as a draft.
async function loadLanguages() {
  const project = await api("/api/project");
  const select = $("language"); const keep = select.value;
  select.textContent = ""; select.append(el("option", { value: "" }, "source"));
  for (const tag of (project.locales || []).concat(["x-pseudo"])) select.append(el("option", { value: tag }, tag));
  select.value = keep;
}
$("language").onchange = async () => {
  const data = await api("/api/language", { lang: $("language").value }, "");
  if (data.error) { logLine(data.error + "\n", "err"); return; }
  renderStory(data);
  showTranslations();
};
async function showTranslations() {
  const lang = $("language").value;
  const panel = $("translations"); panel.textContent = "";
  if (!lang || lang === "x-pseudo") return;
  const [messages, catalog] = await Promise.all([api("/api/messages"), api("/api/catalog", { lang })]);
  const status = {}; for (const e of catalog.entries || []) status[e.key] = e.status;
  for (const m of messages.messages || []) {
    const area = el("textarea", { rows: 2, spellcheck: "false" }); area.value = m.shown === m.source ? "" : m.shown;
    const save = el("button", { onclick: async () => {
      const r = await api("/api/translate", { lang, key: m.key }, area.value);
      if (!r.ok) { logLine(m.key + ": " + r.error + "\n", "err"); return; }
      $("language").onchange();
    } }, "Save draft");
    const preview = el("div", { class: "branches muted" });
    const showBranches = async () => {
      const r = await api("/api/branches", { lang, key: m.key }, area.value || m.source);
      preview.textContent = "";
      for (const p of r.previews || []) {
        preview.append(el("div", {}, p.kind + " on {" + p.param + "}:"));
        for (const row of p.rows) preview.append(el("div", { class: "mono" }, "  " + row.value + (row.category ? " (" + row.category + ")" : "") + " → " + row.text));
      }
    };
    area.addEventListener("input", showBranches);
    panel.append(el("div", { class: "translation" },
      el("div", { class: "muted mono" }, m.key + "  [" + (status[m.key] || "untranslated") + "]"),
      el("div", {}, m.source), area, save, preview));
    if (/\{#(plural|select) /.test(m.source)) showBranches();
  }
}
function renderStory(data) {
  const body = $("storyBody");
  if (!data.session) return;
  body.textContent = ""; $("turn").textContent = "turn " + data.turn;
  if (data.sceneView) {
    const scene = data.sceneView, beat = scene.beats[0];
    const box = el("div", { class: "sceneBeat" }, el("h3", {}, scene.scene + " · beat " + scene.beat_index + " · " + beat.kind));
    if (beat.speaker?.name) box.append(el("strong", {}, beat.speaker.name));
    if (beat.text) box.append(el("p", {}, beat.text));
    if (beat.kind === "menu") {
      beat.choices.forEach((c, index) => box.append(el("button", { onclick: () => sceneCommand("/api/advance", { choice: index + 1 }) }, c.text), " "));
    } else if (beat.kind === "input") {
      const form = el("form", {}), mode = el("select", { "aria-label": "Scene input type" },
        el("option", { value: "text" }, "Text"), el("option", { value: "json" }, "JSON scalar"), el("option", { value: "symbol" }, "Symbol"));
      const input = el("input", { "aria-label": "Scene input", placeholder: beat.local || "Input", autocomplete: "off" });
      form.append(mode, " ", input, " ", el("button", { type: "submit" }, "Submit"));
      form.onsubmit = event => { event.preventDefault(); sceneCommand("/api/advance", {},
        mode.value === "json" ? input.value : JSON.stringify(mode.value === "symbol" ? { symbol: input.value } : input.value)); };
      box.append(form);
    } else box.append(el("button", { onclick: () => sceneCommand("/api/advance") }, beat.kind === "ended" ? "Finish scene" : "Next beat"));
    const details = el("details", {}, el("summary", {}, "Stage, locals and beat directives"),
      el("pre", {}, JSON.stringify({ stage: scene.stage, locals: scene.locals, beat }, null, 2)));
    box.append(details); body.append(box); return;
  }
  if (!data.storylets.length) body.append(el("span", { class: "muted" }, "Nothing is available."));
  data.storylets.forEach((st, i) => {
    const box = el("div", { class: "storylet" }, el("h3", {}, st.title), el("p", {}, st.text));
    st.choices.forEach((c, j) => box.append(el("button", { onclick: () => choose(i + 1, j + 1) }, c.title), " ",
      el("button", { title: "Explain this choice", onclick: () => explainStory(st.id.replace(/^:/, ""), c.id) }, "Why?"), " "));
    body.append(box);
  });
}
async function sceneCommand(path, params = {}, input = "") {
  await breakRequest;
  const data = await api(path, params, input);
  if (data.error) { logLine(data.error + "\n", "err"); return; }
  if (data.stopped) { showOutcome(data); return; }
  renderStory(data); if (data.output) logLine(data.output);
  refreshWorkspace();
}
$("playScene").onclick = () => { if ($("sceneId").value) sceneCommand("/api/play", { id: $("sceneId").value }); };
$("sceneId").addEventListener("focus", loadContent);
async function choose(s, c) {
  const data = await api("/api/choose", { s, c }, "");
  if (data.error) { logLine(data.error + "\n", "err"); return; }
  if (data.stopped) { showOutcome(data); return; }
  renderStory(data);
  if (data.output) logLine(data.output);
  // What the turn changed, as the engine committed it.
  const diff = await api("/api/changes");
  for (const change of diff.changes || []) {
    for (const row of change.removed) logLine("- " + change.relation + "(" + row.join(", ") + ")\n", "err");
    for (const row of change.added) logLine("+ " + change.relation + "(" + row.join(", ") + ")\n", "in");
  }
  refreshWorkspace();
}
async function loadContent() {
  const data = await api("/api/content");
  const select = $("whyId"); const keep = select.value; select.textContent = "";
  for (const id of data.storylets || []) select.append(el("option", { value: id }, id));
  if (keep) select.value = keep;
  const scenes = $("sceneId"), selected = scenes.value; scenes.textContent = "";
  for (const id of data.scenes || []) scenes.append(el("option", { value: id }, id));
  if (selected) scenes.value = selected;
  $("playScene").disabled = !scenes.value;
}
$("whyId").addEventListener("focus", loadContent);
function traceDetails(trace) {
  const body = el("div", {});
  if (trace.error) body.append(el("p", {}, trace.error));
  if (trace.goals?.length) {
    const table = el("table", {}, el("tr", {}, ...["Condition", "Kind", "Outcome", "Candidates"].map(x => el("th", {}, x))));
    for (const g of trace.goals) table.append(el("tr", {}, ...[g.index, g.kind, g.outcome, g.before + " → " + g.after].map(x => el("td", {}, String(x)))));
    body.append(table);
  } else body.append(el("p", { class: "muted" }, "No authored conditions."));
  return body;
}
async function explainStory(id, selectedChoice = "") {
  const data = await api("/api/why", { id });
  const body = $("storyInspectionBody"); body.textContent = "";
  $("storyInspection").showModal();
  if (data.error && !data.goals) { body.append(el("p", {}, data.error)); return; }
  body.append(el("h3", {}, id + ": " + (data.eligible ? "available" : "not available")), traceDetails(data));
  if (!data.instances.length) body.append(el("p", {}, "No parent instance satisfies the storylet conditions. Choice conditions require a grounded parent instance."));
  for (const instance of data.instances) {
    const details = el("details", {}, el("summary", {}, instance.key + ": " + (instance.eligible ? "eligible" : "excluded")));
    details.open = true;
    if (instance.exclusions.length) details.append(el("p", {}, instance.exclusions.join(", ")));
    for (const choice of instance.choices || []) {
      const row = el("details", {}, el("summary", {}, choice.id + ": " + (choice.eligible ? "available" : "not available")), traceDetails(choice));
      row.open = !selectedChoice || choice.id === selectedChoice;
      details.append(row);
    }
    body.append(details);
  }
}
$("why").onclick = async () => { await loadContent(); const id = $("whyId").value; if (id) await explainStory(id); };
$("closeStoryInspection").onclick = () => $("storyInspection").close();
$("analyzeStory").onclick = () => $("analysisDialog").showModal();
$("closeAnalysis").onclick = () => $("analysisDialog").close();
$("analysisForm").onsubmit = async event => {
  event.preventDefault();
  const button = event.submitter, body = $("analysisResult");
  button.disabled = true; body.textContent = "Analyzing…";
  try {
    const data = await api("/api/analyze", Object.fromEntries(new FormData(event.target)), "");
    body.textContent = "";
    if (data.error) { body.append(el("p", {}, data.error)); return; }
    body.append(el("h3", {}, data.complete ? "Complete within the stated scope" : "Incomplete within the stated scope"),
      el("p", {}, data.nodes + " nodes, " + data.transitions + " transitions, depth " + data.depth_reached + "/" + data.depth_limit + ", " + data.instructions + " VM steps."));
    const sections = [
      ["Reached content", data.reached_content], ["Not reached within scope", data.unreachable_content],
      ["Nodes without presented storylet choices", data.dead_ends], ["Potential action cycles or action budget exhaustion", data.action_cycles],
      ["Frontier (bounds reached)", data.frontier], ["Errors", data.errors], ["Blocked external effects", data.blocked_external_effects]
    ];
    for (const [title, rows] of sections) {
      const section = el("details", {}, el("summary", {}, title + " (" + rows.length + ")"));
      section.open = rows.length > 0;
      for (const row of rows) section.append(el("pre", {}, typeof row === "string" ? row : JSON.stringify(row, null, 2)));
      body.append(section);
    }
  } catch (error) { body.textContent = error.message; }
  finally { button.disabled = false; }
};
async function projectOperation(path, params = {}) {
  await saveFile();
  await breakRequest;
  const data = await api(path, params, "");
  if (data.error) { logLine(data.error + "\n", "err"); return; }
  renderStory(data); if (data.output) logLine(data.output);
  refreshWorkspace(); loadContent();
}
$("startStory").onclick = () => projectOperation("/api/start", { seed: $("seed").value });
$("reloadStory").onclick = () => projectOperation("/api/reload");
$("rewindStory").onclick = () => {
  const turn = window.prompt("Rewind to turn", "0");
  if (turn !== null && /^\d+$/.test(turn)) projectOperation("/api/rewind", { turn });
};
$("storyHistory").onclick = async () => {
  const data = await api("/api/history");
  logLine("Playtest history (seed " + data.seed + ")\n", "in");
  const body = $("storyInspectionBody"); body.textContent = "";
  body.append(el("h3", {}, "Playtest history (seed " + data.seed + ")"));
  const table = el("table", {});
  (data.commands || []).forEach((c, index) => table.append(el("tr", {},
    el("td", {}, String(index + 1)), el("td", {}, "turn " + c.turn),
    el("td", {}, c.kind + (c.story ? " " + c.story + " / " + c.choice : c.scene ? " " + c.scene + (c.beat ? " · beat " + c.beat : "") : "")),
    el("td", {}, el("button", { disabled: !data.replayable, onclick: async () => {
      $("storyInspection").close(); await projectOperation("/api/rewind", { command: index + 1 });
    } }, "Rewind here")))));
  body.append(table); $("storyInspection").showModal();
};
$("refreshStory").onclick = () => refreshStory(true);

// Editor
let current = ""; let saved = "";
const buffers = new Map();
let editVersion = 0;
const source = VarisEditor.create($("edwrap"), {
  breakpoint: toggleBreakpoint,
  breakpointChanges: movedBreakpoints,
  complete: async (text, offset) => (await editorRequest("complete", { text, ...positionAt(text, offset) })).items || [],
  hover: async (text, offset) => (await editorRequest("hover", { text, ...positionAt(text, offset) })).text || ""
});
function retainBuffer() {
  if (current && buffers.has(current)) buffers.get(current).text = source.value;
}
function dirtyBuffers() {
  retainBuffer();
  return Object.fromEntries([...buffers].filter(([path, b]) => b.text !== b.saved).map(([path, b]) => [path, b.text]));
}
function positionAt(text, offset) {
  const before = text.slice(0, offset);
  const lines = before.split("\n");
  return { line: lines.length, column: new TextEncoder().encode(lines[lines.length - 1]).length + 1 };
}
function cursorPosition() { return positionAt(source.value, source.selectionStart); }
async function editorRequest(operation, extra = {}) {
  return api("/api/editor/" + operation, {}, JSON.stringify({ path: current, text: source.value,
    buffers: dirtyBuffers(), ...cursorPosition(), ...extra }));
}
// Convert frontend byte columns to browser UTF-16 offsets, including non-ASCII text.
function textOffset(text, line, column) {
  let start = 0;
  for (let i = 1; i < line; ++i) { const end = text.indexOf("\n", start); if (end < 0) return text.length; start = end + 1; }
  let bytes = 0, at = start;
  while (at < text.length && bytes < column - 1 && text[at] !== "\n") {
    const char = String.fromCodePoint(text.codePointAt(at));
    bytes += new TextEncoder().encode(char).length; at += char.length;
  }
  return at;
}
function showEditorInfo(text) { $("editorInfo").textContent = text; $("editorInfo").hidden = !text; }
window.addEventListener("beforeunload", event => {
  if (Object.keys(dirtyBuffers()).length) { event.preventDefault(); event.returnValue = ""; }
});
function markDirty() {
  retainBuffer(); ++editVersion;
  const count = [...buffers.values()].filter(b => b.text !== b.saved).length;
  $("dirty").textContent = count ? count + " modified" : "";
}
async function loadFiles() {
  const data = await api("/api/files");
  const select = $("files"); select.textContent = "";
  for (const name of data.files) select.append(el("option", { value: name }, name));
  if (data.files.length) openFile(data.files.includes("main.lua") ? "main.lua" : data.files[0]);
}
async function openFile(path) {
  retainBuffer();
  if (!buffers.has(path)) { const text = await api("/api/file", { path }); buffers.set(path, { text, saved: text }); }
  current = path;
  if (![...$("files").options].some(o => o.value === path)) $("files").append(el("option", { value: path }, path));
  $("files").value = path;
  const buffer = buffers.get(path); saved = buffer.saved; source.open(path, buffer.text); renderBreaks();
  showEditorInfo(""); markDirty(); check();
}
async function check() {
  if (!current.endsWith(".lua")) { source.diagnostics([]); return; }
  const version = editVersion;
  const data = await editorRequest("check");
  if (version === editVersion) showProblems(data.diagnostics || []);
}
function showProblems(list) {
  source.diagnostics(list.filter(d => d.file === current && d.line > 0).map(d => {
    const from = textOffset(source.value, d.line, d.column || 1);
    const to = Math.max(from, textOffset(source.value, d.endLine || d.line, d.endColumn || (d.column || 1) + 1));
    return { from, to, severity: d.severity === "note" ? "info" : d.severity,
      source: d.code, message: d.message + (d.suggestion ? " (did you mean " + d.suggestion + "?)" : "") };
  }));
  const body = $("problemsBody"); body.textContent = "";
  if (!list.length) { body.append(el("span", { class: "muted" }, "None.")); return; }
  for (const item of list) {
    const text = item.file + (item.line ? ":" + item.line + ":" + item.column : "") + " " + item.severity + ": " + item.message
      + (item.suggestion ? " (did you mean " + item.suggestion + "?)" : "") + " [" + item.code + "]";
    body.append(el("div", { class: "link", onclick: async () => {
      await openFile(item.file); if (item.line) selectLine(item.line);
    } }, text));
  }
}
async function saveFile() {
  retainBuffer();
  for (const [path, buffer] of buffers) {
    if (buffer.text === buffer.saved) continue;
    await api("/api/file", { path }, buffer.text);
    buffer.saved = buffer.text;
  }
  saved = buffers.get(current)?.saved || ""; markDirty(); check();
}
$("hover").onclick = async () => showEditorInfo((await editorRequest("hover")).text || "No description at this position.");
$("rename").onclick = async () => {
  const newName = window.prompt("New name"); if (!newName) return;
  const version = editVersion;
  const result = await editorRequest("rename", { newName });
  if (version !== editVersion) return;
  if (!result.ok) { showEditorInfo(result.error); return; }
  const panel = $("editorInfo"); panel.hidden = false; panel.textContent = "Rename preview (unsaved edits):\n";
  for (const edit of result.edits) panel.append(document.createTextNode(edit.file + ":" + edit.range.line + ":" + edit.range.column + " → " + edit.newText + "\n"));
  for (const note of result.notes || []) panel.append(document.createTextNode(note + "\n"));
  const apply = el("button", { onclick: async () => {
    if (version !== editVersion) { showEditorInfo("Text changed; preview the rename again."); return; }
    const grouped = new Map();
    for (const edit of result.edits) {
      if (!grouped.has(edit.file)) grouped.set(edit.file, []);
      grouped.get(edit.file).push(edit);
    }
    // Read every file before applying any edit. Nothing is written until Save all.
    const changed = new Map();
    for (const [path, edits] of grouped) {
      if (!buffers.has(path)) { const text = await api("/api/file", { path }); buffers.set(path, { text, saved: text }); }
      let text = buffers.get(path).text;
      if (text !== result.originals[path]) { showEditorInfo(path + " changed; preview the rename again."); return; }
      const spans = edits.map(e => ({ start: textOffset(text, e.range.line, e.range.column),
        end: textOffset(text, e.range.endLine, e.range.endColumn), text: e.newText })).sort((a, b) => b.start - a.start);
      for (const e of spans) text = text.slice(0, e.start) + e.text + text.slice(e.end);
      changed.set(path, text);
    }
    if (version !== editVersion) { showEditorInfo("Text changed; preview the rename again."); return; }
    for (const [path, text] of changed) buffers.get(path).text = text;
    source.value = buffers.get(current).text; markDirty(); check();
    showEditorInfo("Renamed in " + changed.size + " file(s). Review the edits, then Save all.");
  } }, "Apply to drafts");
  panel.append(apply);
};
$("files").onchange = () => openFile($("files").value);
$("definition").onclick = goToDefinition;
$("save").onclick = saveFile;
$("run").onclick = async () => {
  await saveFile();
  await breakRequest;
  logLine(">> run " + current + "\n", "in");
  const history = await api("/api/history");
  if (history.replayable) await projectOperation("/api/reload");
  else showOutcome(await api("/api/run", { path: current }, ""));
};
// F12 or the Definition button: jump to where the name under the cursor is declared.
async function goToDefinition() {
  const data = await editorRequest("definition");
  if (!data.definitions?.length) { showEditorInfo("No definition at this position."); return; }
  const target = data.definitions[0];
  if (target.file !== current) await openFile(target.file);
  const text = source.value, r = target.range;
  selectLine(r.line);
  source.setSelectionRange(textOffset(text, r.line, r.column), textOffset(text, r.endLine, r.endColumn));
}
let checkTimer = 0;
source.addEventListener("input", () => { markDirty(); clearTimeout(checkTimer); checkTimer = setTimeout(check, 400); });
source.addEventListener("keydown", event => {
  if (event.key === "Tab") {
    event.preventDefault();
    const before = source.value.slice(0, source.selectionStart);
    // After a name character Tab completes; otherwise it indents.
    if (event.shiftKey) source.indent(true);
    else if (/[\w.:]$/.test(before)) source.complete(); else source.indent();
  }
  if ((event.metaKey || event.ctrlKey) && event.key === "s") { event.preventDefault(); saveFile(); }
  if (event.key === "F12") { event.preventDefault(); goToDefinition(); }
});

// Panel sizes are a user preference. Pointer and keyboard resizing keep the default layout.
const layout = Object.assign({ left: 42, top: 30, bottom: 26 }, readPreference("varis.workbench.layout", {}));
function applyLayout() {
  layout.left = Math.max(20, Math.min(75, Number(layout.left) || 42));
  layout.top = Math.max(12, Math.min(60, Number(layout.top) || 30));
  layout.bottom = Math.max(12, Math.min(80 - layout.top, Number(layout.bottom) || 26));
  for (const name of ["left", "top", "bottom"]) $("grid").style.setProperty("--" + name, layout[name] + "%");
  writePreference("varis.workbench.layout", layout); requestAnimationFrame(placeSplitters);
}
function placeSplitters() {
  const grid = $("grid").getBoundingClientRect(), story = $("story").getBoundingClientRect(), workspace = $("workspace").getBoundingClientRect();
  Object.assign($("columnSplit").style, { left: (story.right - grid.left) + "px", top: "6px", height: (grid.height - 12) + "px" });
  Object.assign($("storySplit").style, { left: "6px", top: (story.bottom - grid.top) + "px", width: story.width + "px" });
  Object.assign($("workspaceSplit").style, { left: "6px", top: (workspace.top - grid.top - 6) + "px", width: (grid.width - 12) + "px" });
  $("columnSplit").setAttribute("aria-valuenow", String(Math.round(layout.left)));
  $("storySplit").setAttribute("aria-valuenow", String(Math.round(layout.top)));
  $("workspaceSplit").setAttribute("aria-valuenow", String(Math.round(layout.bottom)));
}
for (const [id, name] of [["columnSplit", "left"], ["storySplit", "top"], ["workspaceSplit", "bottom"]]) {
  const splitter = $(id); let dragging = false;
  splitter.addEventListener("pointerdown", event => { if (event.button !== 0) return; dragging = true; splitter.setPointerCapture(event.pointerId); event.preventDefault(); });
  splitter.addEventListener("pointermove", event => {
    if (!dragging) return;
    const box = $("grid").getBoundingClientRect();
    layout[name] = name === "left" ? 100 * (event.clientX - box.left) / box.width
      : name === "top" ? 100 * (event.clientY - box.top) / box.height : 100 * (box.bottom - event.clientY) / box.height;
    applyLayout();
  });
  splitter.addEventListener("pointerup", () => { dragging = false; });
  splitter.addEventListener("lostpointercapture", () => { dragging = false; });
  splitter.addEventListener("keydown", event => {
    const negative = name === "left" ? "ArrowLeft" : "ArrowUp", positive = name === "left" ? "ArrowRight" : "ArrowDown";
    if (event.key !== negative && event.key !== positive) return;
    event.preventDefault(); layout[name] += (event.key === positive ? 2 : -2) * (name === "bottom" ? -1 : 1); applyLayout();
  });
}
new ResizeObserver(placeSplitters).observe($("grid"));
applyLayout();

// The story is presented only on request: presenting advances the session's replay log.
loadFiles(); refreshWorkspace(); loadLanguages(); loadContent();
</script>
</body>
</html>
HTML";
