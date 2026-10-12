// Varis workbench editor. Rebuild the vendored bundle with `node build.mjs`.
import { basicSetup } from "codemirror";
import { EditorState, StateEffect, StateField, RangeSet, Compartment, MapMode } from "@codemirror/state";
import { EditorView, GutterMarker, gutter, Decoration, hoverTooltip } from "@codemirror/view";
import { StreamLanguage } from "@codemirror/language";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { setDiagnostics, lintGutter } from "@codemirror/lint";
import { autocompletion, startCompletion, acceptCompletion } from "@codemirror/autocomplete";
import { indentMore, indentLess } from "@codemirror/commands";

// Visual tokens only. Parsing, diagnostics, completion and navigation come from the D frontend.
const words = new Set(("storylet action choice deck scene character relation rule fact retract set delete adjust when title text effect priority weight cooldown repeatable sticky order phase once_per query transaction rollback key by beat line say menu input jump call return show hide background audio transition expose leads").split(" "));
const luaNormal = lua.startState().cur;
const varis = StreamLanguage.define({ ...lua, name: "Varis", token(stream, state) {
  // Lua's tokenizer retains a closure while it reads a string/comment. Let it own those tokens.
  const previous = stream.pos ? stream.string[stream.pos - 1] : "";
  if (state.cur === luaNormal && !/[\w)\]}]/.test(previous) && stream.match(/^:[A-Za-z_]\w*/)) return "atom";
  if (state.cur === luaNormal && stream.match(/^\?[A-Za-z_]\w*/)) return "variableName";
  const style = lua.token(stream, state);
  return style !== "string" && style !== "comment" && words.has(stream.current()) ? "keyword" : style;
} });

const setBreaks = StateEffect.define();
const setStopped = StateEffect.define();
class BreakMarker extends GutterMarker {
  constructor() { super(); this.startSide = this.endSide = 1; this.mapMode = MapMode.TrackAfter; }
  toDOM() { const dot = document.createElement("span"); dot.textContent = "●"; dot.title = "Breakpoint (click to remove)"; return dot; }
}
const breakMarker = new BreakMarker();
const breaks = StateField.define({
  create: () => RangeSet.empty,
  update(markers, transaction) {
    if (transaction.docChanged) {
      const mapped = [], seen = new Set();
      for (let cursor = markers.iter(); cursor.value; cursor.next()) {
        const position = transaction.changes.mapPos(cursor.from, 1, MapMode.TrackAfter);
        if (position === null) continue;
        const from = transaction.state.doc.lineAt(position).from;
        if (!seen.has(from)) { mapped.push(breakMarker.range(from)); seen.add(from); }
      }
      markers = RangeSet.of(mapped, true);
    }
    for (const effect of transaction.effects) if (effect.is(setBreaks)) {
      markers = RangeSet.of(effect.value.filter(n => n > 0 && n <= transaction.state.doc.lines)
        .map(n => breakMarker.range(transaction.state.doc.line(n).from)).sort((a, b) => a.from - b.from));
    }
    return markers;
  }
});
const stopped = StateField.define({
  create: () => Decoration.none,
  update(markers, transaction) {
    markers = markers.map(transaction.changes);
    for (const effect of transaction.effects) if (effect.is(setStopped)) {
      const line = effect.value;
      markers = line > 0 && line <= transaction.state.doc.lines
        ? Decoration.set([Decoration.line({ class: "cm-stoppedLine" }).range(transaction.state.doc.line(line).from)]) : Decoration.none;
    }
    return markers;
  }, provide: field => EditorView.decorations.from(field)
});
const theme = EditorView.theme({
  "&": { height: "100%", color: "var(--ink)", backgroundColor: "var(--panel)" },
  ".cm-scroller": { overflow: "auto", fontFamily: "ui-monospace, Menlo, Consolas, monospace", fontSize: "13px", lineHeight: "1.45" },
  ".cm-content": { caretColor: "var(--ink)" },
  ".cm-gutters": { backgroundColor: "var(--bg)", color: "var(--soft)", borderColor: "var(--line)" },
  ".cm-breakpoints .cm-gutterElement": { color: "var(--bad)", cursor: "pointer", minWidth: "16px", textAlign: "center" },
  ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: "color-mix(in srgb, var(--accent) 7%, transparent)" },
  ".cm-stoppedLine": { backgroundColor: "color-mix(in srgb, #e8b44d 20%, transparent)" },
  ".cm-tooltip": { backgroundColor: "var(--panel)", color: "var(--ink)", borderColor: "var(--line)", maxWidth: "40em" },
  ".cm-tooltip-hover": { whiteSpace: "pre-wrap", padding: "6px 8px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": { backgroundColor: "color-mix(in srgb, var(--accent) 25%, transparent)" }
});

function textChange(previous, next) {
  let from = 0, oldEnd = previous.length, newEnd = next.length;
  while (from < oldEnd && from < newEnd && previous[from] === next[from]) ++from;
  while (oldEnd > from && newEnd > from && previous[oldEnd - 1] === next[newEnd - 1]) { --oldEnd; --newEnd; }
  return { from, to: oldEnd, insert: next.slice(from, newEnd) };
}

/// A small editing interface, with complete CodeMirror states retained per file.
export function create(parent, options = {}) {
  const listeners = new Map();
  const documents = new Map();
  const language = new Compartment();
  let path = "", switching = false;
  const extensions = [basicSetup, language.of(varis), theme, breaks, stopped, lintGutter(),
    gutter({ class: "cm-breakpoints", markers: view => view.state.field(breaks),
      initialSpacer: () => breakMarker, renderEmptyElements: true,
      domEventHandlers: { mousedown(view, line, event) {
        if (event.button !== 0) return false;
        event.preventDefault(); options.breakpoint?.(view.state.doc.lineAt(line.from).number); return true;
      } } }),
    EditorView.contentAttributes.of({ "aria-label": "Varis source editor", spellcheck: "false" }),
    autocompletion({ override: [async context => {
      const word = context.matchBefore(/\w*/);
      if (!context.explicit && (!word || word.from === word.to)) return null;
      const items = await options.complete?.(context.state.doc.toString(), context.pos) || [];
      return { from: word ? word.from : context.pos, options: items.map(i => ({ label: i.label,
        type: i.kind === "keyword" ? "keyword" : i.kind === "function" ? "function" : "variable", detail: i.detail || i.kind })), validFor: /^\w*$/ };
    }] }),
    hoverTooltip(async (view, pos) => {
      const text = await options.hover?.(view.state.doc.toString(), pos);
      if (!text) return null;
      return { pos, create() { const dom = document.createElement("div"); dom.textContent = text; return { dom }; } };
    }),
    EditorView.updateListener.of(update => {
      if (update.docChanged && !switching) {
        for (const callback of listeners.get("input") || []) callback();
        const lines = [];
        update.state.field(breaks).between(0, update.state.doc.length, from => lines.push(update.state.doc.lineAt(from).number));
        options.breakpointChanges?.(lines);
      }
    }),
    EditorView.domEventHandlers({ keydown(event) {
      for (const callback of listeners.get("keydown") || []) callback(event);
      return event.defaultPrevented;
    } })];
  const view = new EditorView({ parent, state: EditorState.create({ extensions }) });
  return {
    view,
    get value() { return view.state.doc.toString(); },
    set value(text) {
      if (text !== view.state.doc.toString()) view.dispatch({ changes: textChange(view.state.doc.toString(), text) });
    },
    get selectionStart() { return view.state.selection.main.from; },
    get selectionEnd() { return view.state.selection.main.to; },
    focus() { view.focus(); },
    addEventListener(type, callback) { if (!listeners.has(type)) listeners.set(type, []); listeners.get(type).push(callback); },
    setSelectionRange(from, to) { view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: "center" }) }); },
    setRangeText(text, from, to) { view.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + text.length } }); },
    selectLine(number) { const line = view.state.doc.line(Math.min(Math.max(1, number), view.state.doc.lines)); this.focus(); this.setSelectionRange(line.from, line.to); },
    open(nextPath, text) {
      if (path) documents.set(path, view.state);
      path = nextPath;
      let state = documents.get(path) || EditorState.create({ doc: text, extensions });
      if (text !== state.doc.toString()) state = state.update({ changes: textChange(state.doc.toString(), text) }).state;
      switching = true;
      try { view.setState(state); view.dispatch({ effects: language.reconfigure(path.endsWith(".lua") ? varis : []) }); }
      finally { switching = false; }
    },
    diagnostics(list) { view.dispatch(setDiagnostics(view.state, list)); },
    breakpoints(lines) { view.dispatch({ effects: setBreaks.of([...new Set(lines)]) }); },
    stoppedLine(line) { view.dispatch({ effects: setStopped.of(line) }); },
    complete() { if (!acceptCompletion(view)) startCompletion(view); },
    indent(backwards = false) { (backwards ? indentLess : indentMore)(view); }
  };
}
