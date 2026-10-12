/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Language services (AUTHORING_TOOLS_PLAN stage A5): diagnostics, completion, definition,
/// references, hover, outline and rename, answered from the project index. One library; the
/// workbench calls it in process and `varis lsp` (services/lsp.d) exposes it to other editors.
///
/// Positions are 1-based lines and 1-based byte columns, as in the index. Nothing here runs
/// project code or reads the live state (AUTHORING_TOOLS_PLAN §3.1).
module varis.services.lang;

import varis.services.checks;
import varis.services.diagnostic;
import varis.services.index;
import varis.services.manifest;
import varis.services.tier;
import varis.workbench.server : readFile, listFiles, sortStrings;

struct Location {
    string file;
    Range range;
}

struct TextEdit {
    string file;
    Range range;
    string newText;
}

struct Completion {
    string label;
    string kind; // storylet, relation, quality, deck, keyword, ...
    string detail;
}

struct OutlineItem {
    string name;
    string kind;
    string container;
    string file;
    Range range; // the name
    Range extent; // the whole definition
}

/// What the cursor is on.
struct Target {
    bool found;
    string kind; // relation, quality, deck, symbol, placeholder, or a declaration kind
    string name;
    string file;
    Range range;
    bool declaration;
    string owner; // a choice's storylet
}

struct RenameResult {
    bool ok;
    string error;
    TextEdit[] edits;
    string[] notes; // things the rename did not touch and the writer should look at
}

private bool contains(Range r, int line, int column) {
    if (r.line == 0 || line < r.line || line > r.endLine)
        return false;
    if (line == r.line && column < r.column)
        return false;
    if (line == r.endLine && column >= r.endColumn)
        return false;
    return true;
}

private bool isNameChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private immutable string[] reservedWords = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not",
    "or", "repeat", "return", "then", "true", "until", "while"
];

private immutable string[] contentKeywords = [
    "storylet", "action", "choice", "deck", "relation", "rule", "fact", "retract", "set", "delete",
    "adjust", "when",
    "title", "text", "effect", "priority", "weight", "cooldown", "repeatable", "sticky", "order",
    "phase", "once_per",
    "query", "transaction", "rollback", "local", "function", "if", "then", "else", "end", "for",
    "while", "return"
];

final class Workspace {
    Manifest manifest;
    string[string] contents; // path -> text, for files the editor holds and files read from disk
    FileIndex[string] indexes;
    string[] order; // paths, sorted

    /// Reads every file of the project from the current directory.
    void load() {
        manifest = loadManifest(".");
        foreach (path; projectFiles(".", manifest)) {
            string text;
            if (readFile(path, text))
                setContent(path, text);
        }
    }

    /// Re-indexes one file (a new file joins the project).
    void setContent(string path, string text) {
        contents[path] = text;
        indexes[path] = indexFile(path, text);
        bool known;
        foreach (p; order)
            if (p == path)
                known = true;
        if (!known) {
            order ~= path;
            sortStrings(order);
        }
    }

    void remove(string path) {
        contents.remove(path);
        indexes.remove(path);
        string[] kept;
        foreach (p; order)
            if (p != path)
                kept ~= p;
        order = kept;
    }

    bool has(string path) const {
        return (path in indexes) !is null;
    }

    /// The whole project as an index (files in path order).
    ProjectIndex project() {
        ProjectIndex result;
        foreach (path; order)
            result.files ~= indexes[path];
        return result;
    }

    /// Diagnostics per file: syntax errors of each file, then the project-wide checks over the
    /// files that parsed. The load and analysis passes run project code and are not here.
    Diagnostic[][string] diagnostics() {
        Diagnostic[][string] result;
        ProjectIndex whole;
        foreach (path; order) {
            auto f = indexes[path];
            result[path] = f.problems.dup;
            if (f.parsed) {
                bool isContent;
                foreach (pattern; manifest.content)
                    isContent = isContent || globMatch(pattern, path);
                if (isContent)
                    result[path] ~= checkTier(path, contents[path]);
            }
            if (f.parsed)
                whole.files ~= f;
        }
        Diagnostic[] found;
        projectChecks(whole, found);
        pluralChecks(whole, manifest.language.length ? manifest.language : "en", found);
        foreach (ref d; found)
            if (auto list = d.file in result)
                *list ~= d;
        foreach (path, ref list; result)
            sortDiagnostics(list);
        return result;
    }

    // --- what is under the cursor ---------------------------------------------

    Target targetAt(string path, int line, int column) {
        Target result;
        auto entry = path in indexes;
        if (entry is null)
            return result;
        // A declaration's own name.
        foreach (ref d; entry.declarations)
            if (d.name.length && contains(d.range, line, column)) {
                result.found = true;
                result.kind = d.kind;
                result.name = d.name;
                result.file = d.file;
                result.range = d.range;
                result.declaration = true;
                result.owner = d.owner;
                return result;
            }
        // The most specific reference: relation and quality beat the plain symbol under them.
        int bestRank = -1;
        foreach (ref r; entry.references) {
            if (!contains(r.range, line, column))
                continue;
            int rank = r.kind == "relation" ? 3 : (r.kind == "quality" ? 3 : (r.kind == "deck" ? 3 : (
                    r.kind == "placeholder" ? 2 : 1)));
            if (rank > bestRank) {
                bestRank = rank;
                result.found = true;
                result.kind = r.kind;
                result.name = r.name;
                result.file = r.file;
                result.range = r.range;
                result.declaration = false;
            }
        }
        return result;
    }

    // --- definition, references, hover ----------------------------------------

    private bool sameClass(string a, string b) {
        bool relational(string k) {
            return k == "relation" || k == "rule" || k == "local-relation";
        }

        bool symbolic(string k) {
            return k == "symbol" || k == "quality" || k == "deck" || k == "name";
        }

        if (relational(a) && relational(b))
            return true;
        if (symbolic(a) && symbolic(b))
            return true;
        return a == b;
    }

    Location[] definition(string path, int line, int column) {
        Location[] found;
        auto target = targetAt(path, line, column);
        if (!target.found)
            return found;
        if (target.kind == "placeholder") {
            // The parameter belongs to the definition the text sits in; show that definition.
            foreach (ref r; indexes[path].references)
                if (r.kind == "placeholder" && contains(r.range, line, column))
                    foreach (ref d; indexes[path].declarations)
                        if (d.subject == r.inside)
                            found ~= Location(d.file, d.range);
            return found;
        }
        foreach (p; order)
            foreach (ref d; indexes[p].declarations) {
                if (d.name != target.name || !sameClass(d.kind, target.kind))
                    continue;
                // A symbol may name a storylet, a deck, a quality or a name label.
                if (target.kind == "symbol" && (d.kind == "relation" || d.kind == "rule" || d.kind == "local-relation"))
                    continue;
                if (d.kind == "choice" && target.kind != "choice")
                    continue;
                if (d.kind == "rule" && hasRelationDeclaration(d.name))
                    continue;
                found ~= Location(d.file, d.range);
            }
        // A symbol that is a storylet or an action also counts when written as a plain symbol.
        if (target.kind == "symbol" || target.kind == "storylet" || target.kind == "action") {
            foreach (p; order)
                foreach (ref d; indexes[p].declarations)
                    if (d.name == target.name && (d.kind == "storylet" || d.kind == "action")) {
                        bool seen;
                        foreach (ref l; found)
                            if (l.file == d.file && l.range.line == d.range.line && l.range.column == d.range.column)
                                seen = true;
                        if (!seen)
                            found ~= Location(d.file, d.range);
                    }
        }
        return found;
    }

    private bool hasRelationDeclaration(string name) {
        foreach (p; order)
            foreach (ref d; indexes[p].declarations)
                if (d.name == name && d.kind == "relation")
                    return true;
        return false;
    }

    /// Where the identifier of a reference lies: a symbol's range starts at its colon, and a
    /// qualified relation reference ends with its own name.
    private Range nameRange(ref const Reference r) {
        Range range = r.range;
        if (r.kind == "relation" && r.qualifier.length && range.line == range.endLine)
            range.column = range.endColumn - cast(int) r.name.length;
        else if (r.kind == "symbol" || r.kind == "quality" || r.kind == "deck")
            if (range.column + 1 + cast(int) r.name.length == range.endColumn && range.line == range.endLine)
                range.column += 1; // skip the colon
        return range;
    }

    Location[] references(string path, int line, int column, bool includeDeclaration = true) {
        Location[] found;
        auto target = targetAt(path, line, column);
        if (!target.found || target.kind == "placeholder")
            return found;
        foreach (p; order) {
            auto f = indexes[p];
            if (includeDeclaration)
                foreach (ref d; f.declarations)
                    if (d.name == target.name && sameClass(d.kind, target.kind) && (d.kind != "choice" || d.owner == target
                            .owner))
                        found ~= Location(d.file, d.range);
            foreach (ref r; f.references) {
                if (r.name != target.name || !sameClass(r.kind, target.kind) || r.kind == "placeholder")
                    continue;
                // A quality reference shares its range with the symbol under it: list once.
                if (r.kind == "symbol") {
                    bool covered;
                    foreach (ref other; f.references)
                        if (other.kind != "symbol" && other.name == r.name && other.range.line == r.range.line
                                && other.range.column == r.range.column)
                            covered = true;
                    if (covered)
                        continue;
                }
                found ~= Location(r.file, nameRange(r));
            }
        }
        return found;
    }

    string hover(string path, int line, int column) {
        auto target = targetAt(path, line, column);
        if (!target.found)
            return null;
        if (target.kind == "placeholder") {
            foreach (ref r; indexes[path].references)
                if (r.kind == "placeholder" && contains(r.range, line, column))
                    return "`{" ~ r.name ~ "}`: parameter of " ~ r.inside;
            return null;
        }
        string text;
        foreach (p; order)
            foreach (ref d; indexes[p].declarations) {
                if (d.name != target.name || d.detail.length == 0)
                    continue;
                bool relational = target.kind == "relation";
                if (relational && d.kind != "relation")
                    continue;
                if (!relational && d.kind == "relation")
                    continue;
                if (target.kind == "quality" && d.kind != "quality")
                    continue;
                if (target.kind == "deck" && d.kind != "deck")
                    continue;
                if (text.length == 0)
                    text = d.detail;
            }
        if (text.length == 0 && target.kind == "symbol") {
            // A plain symbol: say what it names, if anything.
            foreach (p; order)
                foreach (ref d; indexes[p].declarations)
                    if (d.name == target.name && d.detail.length && d.kind != "relation" && d.kind != "choice"
                            && d.kind != "function" && d.kind != "local-function" && text.length == 0)
                        text = d.detail;
        }
        return text;
    }

    // --- outline ----------------------------------------------------------------

    OutlineItem[] outline(string path) {
        OutlineItem[] items;
        auto entry = path in indexes;
        if (entry is null)
            return items;
        foreach (ref d; entry.declarations) {
            if (d.name.length == 0 || d.kind == "label")
                continue;
            OutlineItem item;
            item.name = d.name;
            item.kind = d.kind;
            item.container = d.owner;
            item.file = d.file;
            item.range = d.range;
            item.extent = d.extent.line > 0 ? d.extent : d.range;
            items ~= item;
        }
        return items;
    }

    // --- completion ----------------------------------------------------------

    /// Candidates at the cursor: symbols after a colon (narrowed to decks after `deck`, to
    /// qualities in `quality(...)`), relations where a goal can stand, otherwise declared names
    /// and the content keywords. Names come from the static index, so they cover files that have
    /// not been run.
    Completion[] complete(string path, int line, int column) {
        Completion[] items;
        auto text = path in contents;
        if (text is null)
            return items;
        // The text of the line up to the cursor.
        string lineText;
        int current = 1;
        size_t start;
        foreach (i, char c; *text) {
            if (current == line) {
                size_t end = i;
                while (end < text.length && (*text)[end] != '\n')
                    ++end;
                lineText = (*text)[start .. end];
                break;
            }
            if (c == '\n') {
                ++current;
                start = i + 1;
            }
        }
        if (current != line && line > 1 && lineText.length == 0)
            lineText = (start <= text.length ? (*text)[start .. $] : "");
        size_t cursor = column > 0 ? column - 1 : 0;
        if (cursor > lineText.length)
            cursor = lineText.length;
        auto before = lineText[0 .. cursor];
        size_t wordStart = before.length;
        while (wordStart > 0 && isNameChar(before[wordStart - 1]))
            --wordStart;
        string prefix = before[wordStart .. $];
        bool afterColon = wordStart > 0 && before[wordStart - 1] == ':' && !(wordStart > 1 && before[wordStart - 2] == ':');
        // A colon after a name or a bracket is a method call, not a symbol.
        if (afterColon && wordStart > 1 && (isNameChar(before[wordStart - 2]) || before[wordStart - 2] == ')' || before[wordStart - 2] == ']'))
            afterColon = false;
        bool[string] seen;
        void add(string label, string kind, string detail) {
            if (label.length == 0 || label in seen)
                return;
            if (prefix.length && (label.length < prefix.length || label[0 .. prefix.length] != prefix))
                return;
            seen[label] = true;
            items ~= Completion(label, kind, detail);
        }

        if (afterColon) {
            auto head = wordStart >= 2 ? before[0 .. wordStart - 1] : "";
            bool decksOnly = endsWithWord(head, "deck");
            bool qualitiesOnly = insideQualityCall(head);
            foreach (p; order)
                foreach (ref d; indexes[p].declarations) {
                    if (decksOnly && d.kind != "deck")
                        continue;
                    if (qualitiesOnly && d.kind != "quality")
                        continue;
                    if (d.kind == "deck" || d.kind == "quality" || d.kind == "storylet" || d.kind == "action" || d
                            .kind == "name")
                        add(d.name, d.kind, d.detail);
                }
            if (!decksOnly && !qualitiesOnly)
                foreach (p; order)
                    foreach (ref r; indexes[p].references)
                        if (r.kind == "symbol" && r.role != "engine")
                            add(r.name, "symbol", "");
            return items;
        }
        // Relations where a goal can stand.
        bool goalPosition = endsWithWord(before[0 .. wordStart], "query") || endsWithWord(before[0 .. wordStart], "not")
            || endsWithWord(before[0 .. wordStart], "fact") || endsWithWord(before[0 .. wordStart], "retract")
            || endsWithWord(before[0 .. wordStart], "set") || endsWithWord(before[0 .. wordStart], "delete")
            || endsWithWord(before[0 .. wordStart], "adjust") || endsWithWord(before[0 .. wordStart], "rule")
            || (wordStart > 0 && (before[wordStart - 1] == '{' || before[wordStart - 1] == ' ') && insideWhen(before));
        if (goalPosition)
            foreach (p; order)
                foreach (ref d; indexes[p].declarations)
                    if (d.kind == "relation" || d.kind == "local-relation")
                        add(d.name, "relation", d.detail);
        if (prefix.length || !goalPosition) {
            foreach (p; order)
                foreach (ref d; indexes[p].declarations)
                    if (d.kind == "relation" || d.kind == "local-relation" || d.kind == "function" || d.kind == "local-function")
                        add(d.name, d.kind, d.detail);
            foreach (word; contentKeywords)
                add(word, "keyword", "");
        }
        return items;
    }

    private static bool endsWithWord(string text, string word) {
        size_t end = text.length;
        while (end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t'))
            --end;
        if (end < word.length || text[end - word.length .. end] != word)
            return false;
        return end == word.length || !isNameChar(text[end - word.length - 1]);
    }

    private static bool insideQualityCall(string head) {
        // `quality(` ... with the colon being an argument of the call.
        size_t at = head.length;
        int depth;
        while (at > 0) {
            char c = head[at - 1];
            if (c == ')')
                ++depth;
            else if (c == '(') {
                if (depth == 0)
                    return endsWithWord(head[0 .. at - 1], "quality");
                --depth;
            }
            --at;
        }
        return false;
    }

    private static bool insideWhen(string before) {
        // A `when {` earlier on the line that has not been closed.
        foreach_reverse (i; 0 .. before.length) {
            if (before[i] == '}')
                return false;
            if (before[i] == '{')
                return endsWithWord(before[0 .. i], "when") || endsWithWord(before[0 .. i], "query");
        }
        return false;
    }

    // --- rename ---------------------------------------------------------------

    RenameResult rename(string path, int line, int column, string newName) {
        RenameResult result;
        auto target = targetAt(path, line, column);
        if (!target.found) {
            result.error = "nothing to rename here";
            return result;
        }
        if (target.kind == "placeholder" || target.kind == "function" || target.kind == "local-function"
                || target.kind == "label" || target.kind == "local-relation") {
            result.error = "renaming " ~ target.kind ~ " names is not supported";
            return result;
        }
        if (newName.length == 0 || (newName[0] >= '0' && newName[0] <= '9')) {
            result.error = "`" ~ newName ~ "` is not a name";
            return result;
        }
        foreach (char c; newName)
            if (!isNameChar(c)) {
                result.error = "`" ~ newName ~ "` is not a name: use letters, digits and `_`";
                return result;
            }
        foreach (word; reservedWords)
            if (word == newName) {
                result.error = "`" ~ newName ~ "` is a reserved word";
                return result;
            }
        // What kind of thing, to look for a clash with an existing one.
        string kind = target.kind;
        string clashKind = kind;
        if (kind == "symbol" || kind == "quality" || kind == "deck" || kind == "name")
            clashKind = "symbol";
        if (kind == "rule")
            clashKind = "relation";
        foreach (p; order)
            foreach (ref d; indexes[p].declarations) {
                if (d.name != newName)
                    continue;
                string other = d.kind == "rule" ? "relation" : (d.kind == "quality" || d.kind == "deck" || d.kind == "name" ? "symbol" : d
                        .kind);
                if (other != clashKind)
                    continue;
                if (kind == "choice" && d.owner != target.owner)
                    continue;
                if (kind == "symbol")
                    continue; // symbols are not declared: sharing a name merges, as written
                result.error = d.subject ~ " already exists at " ~ d.file ~ ":" ~ numberText(d.range.line);
                return result;
            }
        TextEdit[] edits;
        void edit(string file, Range r) {
            foreach (ref e; edits)
                if (e.file == file && e.range.line == r.line && e.range.column == r.column)
                    return;
            edits ~= TextEdit(file, r, newName);
        }

        foreach (location; references(path, line, column, true))
            edit(location.file, location.range);
        // A symbol's declarations are written inside a call, with the colon in front.
        if (kind == "symbol" || kind == "quality" || kind == "deck" || kind == "name")
            foreach (p; order)
                foreach (ref d; indexes[p].declarations) {
                    if (d.name != target.name)
                        continue;
                    if (d.kind == "quality" || d.kind == "name") {
                        Range r = d.range;
                        if (r.line == r.endLine && r.column + 1 + cast(int) d.name.length == r.endColumn)
                            r.column += 1;
                        edit(d.file, r);
                    } else if (d.kind == "deck")
                        edit(d.file, d.range);
                }
        // A storylet or choice is also named by the message keys of the catalogs.
        string oldPrefix, newPrefix, oldOwner, newOwner;
        if (kind == "storylet" || kind == "action") {
            oldPrefix = oldOwner = target.name;
            newPrefix = newOwner = newName;
        } else if (kind == "choice") {
            oldPrefix = oldOwner = target.owner ~ "." ~ target.name;
            newPrefix = newOwner = target.owner ~ "." ~ newName;
        } else if (kind == "quality") {
            oldPrefix = "quality." ~ target.name;
            newPrefix = "quality." ~ newName;
            oldOwner = target.name;
            newOwner = newName;
        } else if (kind == "name") {
            oldPrefix = "name." ~ target.name;
            newPrefix = "name." ~ newName;
            oldOwner = target.name;
            newOwner = newName;
        }
        if (oldPrefix.length)
            catalogEdits(oldPrefix, newPrefix, oldOwner, newOwner, result.edits);
        if (kind == "storylet" || kind == "action" || kind == "choice") {
            // Symbols that spell the name may refer to it (`:lamp` in an explain call) or to an
            // entity of the same name. They are not changed.
            int count;
            foreach (p; order)
                foreach (ref r; indexes[p].references)
                    if (r.kind == "symbol" && r.name == target.name)
                        ++count;
            if (count)
                result.notes ~= numberText(count) ~ " symbol(s) `:" ~ target.name
                    ~ "` were not changed; they may name this " ~ kind ~ " or something else";
        }
        result.edits = edits ~ result.edits;
        result.ok = true;
        return result;
    }

    /// Edits of `"key":"old..."` in the catalogs under `l10n/`: the file for the source and one per
    /// locale of the manifest. A key matches when it is `old` or begins `old.`.
    private void catalogEdits(string oldPrefix, string newPrefix, string oldOwner, string newOwner, ref TextEdit[] edits) {
        string[] paths = ["l10n/source.json"];
        foreach (locale; manifest.locales)
            paths ~= "l10n/" ~ locale ~ ".json";
        foreach (file; paths) {
            string text;
            if (!readFile(file, text))
                continue;
            int line = 1;
            size_t lineStart;
            enum marker = `"key":"`;
            foreach (i; 0 .. text.length + 1) {
                if (i < text.length && text[i] != '\n')
                    continue;
                auto row = text[lineStart .. i];
                size_t at = 0;
                bool found;
                for (; at + marker.length <= row.length; ++at)
                    if (row[at .. at + marker.length] == marker) {
                        found = true;
                        break;
                    }
                if (found) {
                    size_t keyStart = at + marker.length;
                    size_t keyEnd = keyStart;
                    while (keyEnd < row.length && row[keyEnd] != '"')
                        ++keyEnd;
                    auto key = row[keyStart .. keyEnd];
                    bool matches = key == oldPrefix || (key.length > oldPrefix.length && key[0 .. oldPrefix.length] == oldPrefix
                            && key[oldPrefix.length] == '.');
                    if (matches) {
                        // Replace only the prefix of the key.
                        edits ~= TextEdit(file, Range(line, cast(int) keyStart + 1, line, cast(int)(
                                keyStart + oldPrefix.length) + 1),
                                newPrefix);
                        // The owner field quotes the name too: `"owner":"choice lamp.light"`.
                        enum ownerMarker = `"owner":"`;
                        for (size_t o = 0; o + ownerMarker.length <= row.length; ++o)
                            if (row[o .. o + ownerMarker.length] == ownerMarker) {
                                size_t nameStart = o + ownerMarker.length;
                                while (nameStart < row.length && row[nameStart] != ' ' && row[nameStart] != '"')
                                    ++nameStart;
                                if (nameStart < row.length && row[nameStart] == ' ')
                                    ++nameStart;
                                size_t nameEnd = nameStart;
                                while (nameEnd < row.length && row[nameEnd] != '"')
                                    ++nameEnd;
                                auto owner = row[nameStart .. nameEnd];
                                if (owner == oldOwner || (owner.length > oldOwner.length
                                        && owner[0 .. oldOwner.length] == oldOwner && owner[oldOwner.length] == '.'))
                                    edits ~= TextEdit(file, Range(line, cast(int) nameStart + 1, line,
                                            cast(int)(nameStart + oldOwner.length) + 1), newOwner);
                                break;
                            }
                    }
                }
                ++line;
                lineStart = i + 1;
            }
        }
    }
}

/// Applies edits to the text of one file. Edits must not overlap; they are applied from the end.
string applyEdits(string text, TextEdit[] edits) {
    // Offsets of each line start.
    size_t[] starts = [0];
    foreach (i, char c; text)
        if (c == '\n')
            starts ~= i + 1;
    struct Span {
        size_t from;
        size_t to;
        string with_;
    }

    Span[] spans;
    foreach (ref e; edits) {
        if (e.range.line < 1 || e.range.line > starts.length || e.range.endLine < 1 || e.range.endLine > starts.length)
            continue;
        spans ~= Span(starts[e.range.line - 1] + e.range.column - 1, starts[e.range.endLine - 1] + e.range.endColumn - 1,
                e.newText);
    }
    foreach (i; 1 .. spans.length) {
        auto item = spans[i];
        size_t j = i;
        while (j > 0 && spans[j - 1].from < item.from) {
            spans[j] = spans[j - 1];
            --j;
        }
        spans[j] = item;
    }
    string result = text;
    foreach (ref s; spans)
        if (s.to <= result.length && s.from <= s.to)
            result = result[0 .. s.from] ~ s.with_ ~ result[s.to .. $];
    return result;
}

private string numberText(long value) {
    import core.stdc.stdio : snprintf;

    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}
