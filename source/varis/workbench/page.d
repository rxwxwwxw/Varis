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
/// JavaScript with no build step; the editor is a text area in this first version.
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
  #grid { display: grid; height: 100%; gap: 6px; padding: 6px;
          grid-template-columns: minmax(280px, 42%) 1fr;
          grid-template-rows: minmax(120px, 30%) 1fr minmax(120px, 26%);
          grid-template-areas: "story editor" "command editor" "workspace problems"; }
  section { background: var(--panel); border: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  section > header { padding: 4px 8px; border-bottom: 1px solid var(--line); color: var(--soft);
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
  #source { flex: 1; width: 100%; border: 0; outline: 0; padding: 8px; background: transparent; color: var(--ink); resize: none; tab-size: 4; }
  button, select { font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 3px; padding: 2px 8px; }
  button:hover { border-color: var(--accent); }
  table { border-collapse: collapse; width: 100%; }
  td, th { text-align: left; padding: 2px 8px 2px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--soft); font-weight: 500; }
  .storylet { margin-bottom: 10px; } .storylet h3 { margin: 0 0 2px; font-size: 14px; }
  .storylet p { margin: 0 0 4px; white-space: pre-wrap; }
  .link { color: var(--accent); cursor: pointer; text-decoration: underline; }
  .muted { color: var(--soft); } .spacer { flex: 1; }
  #debugBar { padding: 4px 8px; border-bottom: 1px solid var(--line); color: var(--bad); }
  #breaks { padding: 2px 8px; font-size: 12px; } #breaks:empty { display: none; }
  #breakLine { border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 3px; padding: 2px 4px; }
  @media (max-width: 760px) {
    #grid { grid-template-columns: 1fr; grid-template-rows: auto; height: auto;
            grid-template-areas: "story" "command" "workspace" "editor" "problems"; }
    section { min-height: 220px; }
  }
</style>
</head>
<body>
<div id="grid">
  <section id="story"><header>Story <span class="spacer"></span><span id="turn" class="muted"></span>
      <select id="whyId" title="Why is this storylet showing or not?"></select><button id="why">Why?</button>
      <button id="refreshStory">Present</button></header>
    <div class="body" id="storyBody"><span class="muted">No session. In the command window, create one and call <code>story(session)</code>.</span></div></section>
  <section id="command"><header>Command window</header>
    <div class="body"><pre id="log"></pre></div>
    <div id="prompt"><span>&gt;&gt;</span><textarea id="input" rows="1" spellcheck="false" autofocus></textarea></div></section>
  <section id="workspace"><header>Workspace <span class="spacer"></span><span id="crumb" class="muted"></span></header>
    <div class="body" id="workspaceBody"></div></section>
  <section id="editor"><header>Editor <select id="files"></select><span id="dirty" class="muted"></span>
      <span class="spacer"></span><input id="breakLine" class="mono" size="4" placeholder="line" title="Line number for a breakpoint in this file">
      <button id="toggleBreak">Break</button><button id="save">Save</button><button id="run">Run</button></header>
    <div id="debugBar" class="mono" hidden><span id="where"></span> <button id="dbgContinue">Continue</button>
      <button id="dbgOver">Step over</button><button id="dbgInto">Step into</button><button id="dbgOut">Step out</button></div>
    <div id="breaks" class="muted mono"></div>
    <textarea id="source" spellcheck="false"></textarea></section>
  <section id="problems"><header>Problems</header><div class="body mono" id="problemsBody"><span class="muted">None.</span></div></section>
</div>
<script>
const token = new URLSearchParams(location.search).get("token") || "";
const $ = id => document.getElementById(id);
async function api(path, params, body) {
  const query = new URLSearchParams(Object.assign({ token }, params || {}));
  const response = await fetch(path + "?" + query, body === undefined ? {} : { method: "POST", body });
  const type = response.headers.get("Content-Type") || "";
  return type.includes("json") ? response.json() : response.text();
}
function el(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes || {})) {
    if (key === "onclick") node.onclick = value; else if (key === "class") node.className = value; else node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}

// Command window
const history = []; let historyAt = 0; let pending = "";
function logLine(text, cls) { const span = el("span", { class: cls || "" }, text); $("log").append(span); $("log").parentNode.scrollTop = 1e9; }
async function submit(text) {
  const full = pending ? pending + "\n" + text : text;
  logLine((pending ? ".. " : ">> ") + text + "\n", "in");
  const result = await api("/api/eval", {}, full);
  if (result.incomplete) { pending = full; return; }
  pending = "";
  showOutcome(result);
}
// An evaluation either finishes or stops at a breakpoint; a resumed one reports the same way.
async function showOutcome(result) {
  if (result.stopped) {
    $("debugBar").hidden = false;
    $("where").textContent = "stopped at " + result.file + ":" + result.line;
    logLine("stopped at " + result.file + ":" + result.line + "\n", "err");
    if (result.file !== current && [...$("files").options].some(o => o.value === result.file)) await openFile(result.file);
    if (result.file === current) selectLine(result.line);
    showLocals();
    return;
  }
  $("debugBar").hidden = true;
  if (result.output) logLine(result.output);
  if (!result.ok && result.error) logLine(result.error + "\n", "err");
  refreshWorkspace();
}
function selectLine(line) {
  const text = $("source").value; let start = 0;
  for (let i = 1; i < line; i++) { const next = text.indexOf("\n", start); if (next < 0) break; start = next + 1; }
  let end = text.indexOf("\n", start); if (end < 0) end = text.length;
  $("source").focus(); $("source").setSelectionRange(start, end);
  // Bring the line into view (line height is 13px * 1.45; long wrapped lines make this approximate).
  $("source").scrollTop = Math.max(0, (line - 4) * 18.85);
}
async function showLocals() {
  const [locals, stack] = await Promise.all([api("/api/locals"), api("/api/stack")]);
  const body = $("workspaceBody"); body.textContent = ""; back("workspace", refreshWorkspace);
  const table = el("table", {}, el("tr", {}, el("th", {}, "Local"), el("th", {}, "Type"), el("th", {}, "Value")));
  for (const row of locals.locals) table.append(el("tr", {}, el("td", { class: "mono" }, row.name), el("td", {}, row.type), el("td", { class: "mono" }, row.value)));
  body.append(table, el("div", { class: "muted mono" }, stack.frames.map(f => f.name + " " + f.file + ":" + f.line).join("  <  ")));
}
async function resume(path, params) { showOutcome(await api(path, params, "")); }
$("dbgContinue").onclick = () => resume("/api/continue");
$("dbgOver").onclick = () => resume("/api/step", { mode: "over" });
$("dbgInto").onclick = () => resume("/api/step", { mode: "into" });
$("dbgOut").onclick = () => resume("/api/step", { mode: "out" });
let breakpoints = [];
function renderBreaks() { $("breaks").textContent = breakpoints.length ? "breakpoints: " + breakpoints.join("  ") : ""; }
$("toggleBreak").onclick = async () => {
  const line = parseInt($("breakLine").value, 10); if (!current || !(line > 0)) return;
  const key = current + ":" + line;
  breakpoints = breakpoints.includes(key) ? breakpoints.filter(b => b !== key) : breakpoints.concat([key]);
  const data = await api("/api/breakpoints", {}, breakpoints.join("\n"));
  breakpoints = data.breakpoints.map(b => b.file + ":" + b.line); renderBreaks();
};
// Tab completes the name before the cursor (in the command window and the editor).
async function completeIn(area) {
  const at = area.selectionStart; const before = area.value.slice(0, at);
  const line = before.slice(before.lastIndexOf("\n") + 1);
  const data = await api("/api/complete", {}, line);
  if (!data.items || !data.items.length) return false;
  let common = data.items[0].name;
  for (const item of data.items) { while (!item.name.startsWith(common)) common = common.slice(0, -1); }
  const extra = common.slice(data.prefix.length);
  if (extra) { area.setRangeText(extra, at, at, "end"); if (area === $("source")) markDirty(); }
  if (data.items.length > 1) logLine(data.items.map(i => i.name).join("  ") + "\n");
  return true;
}
$("input").addEventListener("keydown", event => {
  if (event.key === "Tab") { event.preventDefault(); completeIn($("input")); return; }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    const text = $("input").value; $("input").value = "";
    if (text.trim() === "" && !pending) return;
    history.push(text); historyAt = history.length; submit(text);
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
    const name = row.world ? el("span", { class: "link", onclick: () => showWorld(row.name) }, row.name) : row.name;
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
    table.append(el("tr", {}, el("td", { class: "mono" }, el("span", { class: "link", onclick: () => showFacts(world, r.name, 0) }, r.name)),
      el("td", {}, String(r.arity)), el("td", {}, String(r.count)), el("td", { class: "muted" }, (r.derived ? "derived " : "") + (r.keyed ? "keyed" : ""))));
  body.append(table);
}
async function showFacts(world, name, start) {
  const data = await api("/api/facts", { world, name, start, count: 100 });
  const body = $("workspaceBody"); body.textContent = ""; back(world, () => showWorld(world));
  if (data.error) { body.append(el("span", { class: "muted" }, data.error)); return; }
  const table = el("table", {}, el("tr", {}, ...data.columns.map(c => el("th", {}, c))));
  for (const row of data.rows) table.append(el("tr", {}, ...row.map(v => el("td", { class: "mono" }, v))));
  body.append(el("div", { class: "muted" }, name + ": " + data.total + " base facts" + (data.total > data.rows.length ? ", showing " + (start + 1) + "-" + (start + data.rows.length) : "")), table);
  if (start + data.rows.length < data.total) body.append(el("button", { onclick: () => showFacts(world, name, start + 100) }, "Next 100"));
}

// Story
async function refreshStory(explicit) {
  const data = await api("/api/present");
  if (data.error) { if (explicit) { $("storyBody").textContent = ""; $("storyBody").append(el("span", { class: "muted" }, data.error)); } return; }
  renderStory(data);
}
function renderStory(data) {
  const body = $("storyBody");
  if (!data.session) return;
  body.textContent = ""; $("turn").textContent = "turn " + data.turn;
  if (!data.storylets.length) body.append(el("span", { class: "muted" }, "Nothing is available."));
  data.storylets.forEach((st, i) => {
    const box = el("div", { class: "storylet" }, el("h3", {}, st.title), el("p", {}, st.text));
    st.choices.forEach((c, j) => box.append(el("button", { onclick: () => choose(i + 1, j + 1) }, c.title), " "));
    body.append(box);
  });
}
async function choose(s, c) {
  const data = await api("/api/choose", { s, c }, "");
  if (data.error) { logLine(data.error + "\n", "err"); return; }
  renderStory(data);
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
}
$("whyId").addEventListener("focus", loadContent);
$("why").onclick = async () => {
  await loadContent();
  const id = $("whyId").value; if (!id) return;
  const data = await api("/api/why", { id });
  if (data.error && !data.goals) { logLine(data.error + "\n", "err"); return; }
  logLine("why " + id + ": " + (data.eligible ? "available" : "not available") + ", " + data.instances.length + " instance(s)\n", "in");
  for (const g of data.goals) logLine("  condition " + g.index + " (" + g.kind + "): " + g.outcome + ", " + g.before + " -> " + g.after + " candidates\n");
  for (const i of data.instances) logLine("  instance " + i.key + ": " + (i.eligible ? "eligible" : "excluded: " + i.exclusions.join(", ")) + "\n");
  if (data.error) logLine("  " + data.error + "\n", "err");
};
$("refreshStory").onclick = () => refreshStory(true);

// Editor
let current = ""; let saved = "";
function markDirty() { $("dirty").textContent = $("source").value !== saved ? "modified" : ""; }
async function loadFiles() {
  const data = await api("/api/files");
  const select = $("files"); select.textContent = "";
  for (const name of data.files) select.append(el("option", { value: name }, name));
  if (data.files.length) openFile(data.files.includes("main.lua") ? "main.lua" : data.files[0]);
}
async function openFile(path) {
  current = path; $("files").value = path;
  saved = await api("/api/file", { path }); $("source").value = saved; markDirty(); check();
}
async function check() {
  if (!current.endsWith(".lua")) { showProblems([]); return; }
  const data = await api("/api/check", { path: current }, $("source").value);
  showProblems(data.problems || []);
}
function showProblems(list) {
  const body = $("problemsBody"); body.textContent = "";
  if (!list.length) { body.append(el("span", { class: "muted" }, "None.")); return; }
  for (const item of list) body.append(el("div", {}, item));
}
async function saveFile() { if (!current) return; await api("/api/file", { path: current }, $("source").value); saved = $("source").value; markDirty(); }
$("files").onchange = () => openFile($("files").value);
$("save").onclick = saveFile;
$("run").onclick = async () => {
  await saveFile();
  logLine(">> run " + current + "\n", "in");
  showOutcome(await api("/api/run", { path: current }, ""));
};
let checkTimer = 0;
$("source").addEventListener("input", () => { markDirty(); clearTimeout(checkTimer); checkTimer = setTimeout(check, 400); });
$("source").addEventListener("keydown", event => {
  if (event.key === "Tab") {
    event.preventDefault();
    const before = $("source").value.slice(0, $("source").selectionStart);
    // After a name character Tab completes; otherwise it indents.
    if (/[\w.:]$/.test(before)) completeIn($("source")); else document.execCommand("insertText", false, "    ");
  }
  if ((event.metaKey || event.ctrlKey) && event.key === "s") { event.preventDefault(); saveFile(); }
});

// The story is presented only on request: presenting advances the session's replay log.
loadFiles(); refreshWorkspace();
</script>
</body>
</html>
HTML";
