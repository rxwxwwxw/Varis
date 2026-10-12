/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The translation catalog model (NARRATIVE_LOCALIZATION_PLAN §6.1, §7.1): the source catalog of a
/// package, the catalog of one locale, the canonical JSON they are stored as, change detection
/// between two source catalogs, and the CSV adapter.
///
/// Statuses of a translation: `untranslated` (no entry), `draft`, `reviewed`, `stale`. Only a
/// source change sets `stale`; only an explicit review sets `reviewed`.
module varis.services.catalog;

import varis.services.diagnostic;
import varis.services.index;
import varis.services.json;
import varis.services.manifest;
import varis.workbench.server : jsonQuote;

enum catalogFormat = 1;

struct SourceMessage {
    string key;
    string text;
    string revision; // hash of the normalized text: what a translator has to read again
    string owner; // `storylet lamp`
    string field; // title, text, label, name
    string file;
    int line;
    string[] arguments; // placeholders, in order of appearance
    string[] conditions; // relations read by `{#if query ...}`
    string when; // the owner's availability clause, as written
}

struct SourceCatalog {
    string package_;
    string language;
    SourceMessage[] messages;

    const(SourceMessage)* find(string key) const {
        foreach (ref m; messages)
            if (m.key == key)
                return &m;
        return null;
    }
}

struct LocaleEntry {
    string key;
    string text;
    string status; // draft, reviewed or stale
    string revision; // the source revision this translation was made from
}

struct LocaleCatalog {
    string package_;
    string locale;
    LocaleEntry[] entries;

    LocaleEntry* find(string key) {
        foreach (ref e; entries)
            if (e.key == key)
                return &e;
        return null;
    }
}

// -----------------------------------------------------------------------------
// Revisions
// -----------------------------------------------------------------------------

/// The text with what does not change its meaning removed: case, spacing and punctuation outside
/// template tags. Tags (`{name}`, `{#if ...}`) are kept, with spacing removed, so a change in
/// words, placeholders or branches is never normalized away.
string normalizeText(string text) {
    char[] result;
    bool pendingSpace;
    size_t i;
    while (i < text.length) {
        char c = text[i];
        if (c == '{' && i + 1 < text.length && text[i + 1] == '{') {
            result ~= "{{";
            i += 2;
            continue;
        }
        if (c == '{') {
            int depth;
            size_t j = i;
            while (j < text.length) {
                if (text[j] == '{')
                    ++depth;
                else if (text[j] == '}' && --depth == 0)
                    break;
                ++j;
            }
            if (pendingSpace && result.length)
                result ~= ' ';
            pendingSpace = false;
            // Spacing inside a tag is not meaningful; inside quotes it is, but quoted text in
            // conditions is rare enough that treating it as spacing only errs towards "cosmetic"
            // never: collapse runs, keep one.
            bool space;
            foreach (char t; text[i .. (j < text.length ? j + 1 : text.length)]) {
                if (t == ' ' || t == '\t' || t == '\n' || t == '\r') {
                    space = true;
                    continue;
                }
                if (space && result.length && result[$ - 1] != '{')
                    result ~= ' ';
                space = false;
                result ~= t;
            }
            i = j < text.length ? j + 1 : text.length;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            pendingSpace = true;
            ++i;
            continue;
        }
        bool punctuation = (c >= '!' && c <= '/' && c != '{') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`')
            || c == '|' || c == '~' || c == '}';
        if (punctuation) {
            ++i;
            continue;
        }
        if (pendingSpace && result.length)
            result ~= ' ';
        pendingSpace = false;
        result ~= (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
        ++i;
    }
    return cast(string) result;
}

string revisionOf(string text) {
    ulong h = 14695981039346656037UL;
    foreach (char c; normalizeText(text)) {
        h ^= cast(ubyte) c;
        h *= 1099511628211UL;
    }
    char[16] digits;
    static immutable hex = "0123456789abcdef";
    foreach (i; 0 .. 16)
        digits[15 - i] = hex[(h >> (4 * i)) & 15];
    return digits.idup;
}

// -----------------------------------------------------------------------------
// Building the source catalog
// -----------------------------------------------------------------------------

/// Collects every extractable message of the index. Two messages with one key are reported as
/// errors (`duplicate-key`); the first is kept. A message that is not a string literal is
/// reported as a `computed-text` warning by the checker and is not in the catalog.
SourceCatalog buildSourceCatalog(ref const ProjectIndex index, ref const Manifest manifest, ref Diagnostic[] problems) {
    SourceCatalog catalog;
    catalog.package_ = manifest.id;
    catalog.language = manifest.language.length ? manifest.language : "en";
    foreach (ref f; index.files)
        foreach (ref m; f.messages) {
            // An empty text has nothing to translate.
            if (m.computed || m.key.length == 0 || m.text.length == 0)
                continue;
            if (auto previous = catalog.find(m.key)) {
                auto d = makeDiagnostic("error", "duplicate-key", m.file, m.range.line, m.range.column, m.range.endLine,
                        m.range.endColumn, "message key `" ~ m.key ~ "` is already used at " ~ previous.file ~ ":" ~ lineText(
                        previous.line), m.owner);
                d.related ~= Related(previous.file, previous.line, 1, "first use");
                problems ~= d;
                continue;
            }
            SourceMessage s;
            s.key = m.key;
            s.text = m.text;
            s.revision = revisionOf(m.text);
            s.owner = m.owner;
            s.field = m.field;
            s.file = m.file;
            s.line = m.range.line;
            s.arguments = m.placeholders.dup;
            s.conditions = m.conditionRelations.dup;
            s.when = m.when;
            catalog.messages ~= s;
        }
    sortMessages(catalog.messages);
    return catalog;
}

private string lineText(int line) {
    import core.stdc.stdio : snprintf;

    char[16] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%d", line);
    return buffer[0 .. n].idup;
}

private void sortMessages(SourceMessage[] items) {
    foreach (i; 1 .. items.length) {
        auto item = items[i];
        size_t j = i;
        while (j > 0 && items[j - 1].key > item.key) {
            items[j] = items[j - 1];
            --j;
        }
        items[j] = item;
    }
}

// -----------------------------------------------------------------------------
// Canonical JSON
// -----------------------------------------------------------------------------

private string quoteList(const(string)[] items) {
    string text = "[";
    foreach (i, item; items)
        text ~= (i ? "," : "") ~ jsonQuote(item);
    return text ~ "]";
}

private string numberText(long value) {
    return lineText(cast(int) value);
}

/// One message per line, sorted by key, so a change shows as a changed line.
string sourceJson(ref const SourceCatalog catalog) {
    string text = `{"format":` ~ numberText(catalogFormat) ~ `,"package":` ~ jsonQuote(
            catalog.package_) ~ `,"language":` ~ jsonQuote(
            catalog.language) ~ `,"messages":[` ~ "\n";
    foreach (i, ref m; catalog.messages) {
        text ~= ` {"key":` ~ jsonQuote(m.key) ~ `,"text":` ~ jsonQuote(
                m.text) ~ `,"revision":` ~ jsonQuote(m.revision)
            ~ `,"owner":` ~ jsonQuote(
                    m.owner) ~ `,"field":` ~ jsonQuote(m.field) ~ `,"file":` ~ jsonQuote(
                    m.file)
            ~ `,"line":` ~ numberText(m.line);
        if (m.arguments.length)
            text ~= `,"arguments":` ~ quoteList(m.arguments);
        if (m.conditions.length)
            text ~= `,"conditions":` ~ quoteList(m.conditions);
        if (m.when.length)
            text ~= `,"when":` ~ jsonQuote(m.when);
        text ~= `}` ~ (i + 1 < catalog.messages.length ? "," : "") ~ "\n";
    }
    return text ~ "]}\n";
}

bool readSourceCatalog(string text, out SourceCatalog catalog, out string error) {
    JsonValue root;
    if (!parseJson(text, root, error))
        return false;
    if (root.kind != JsonValue.Kind.object) {
        error = "a catalog is a JSON object";
        return false;
    }
    catalog.package_ = root.stringOr("package");
    catalog.language = root.stringOr("language");
    auto list = root.get("messages");
    if (list is null || list.kind != JsonValue.Kind.array) {
        error = "missing `messages`";
        return false;
    }
    foreach (ref item; list.items) {
        SourceMessage m;
        m.key = item.stringOr("key");
        m.text = item.stringOr("text");
        m.revision = item.stringOr("revision");
        m.owner = item.stringOr("owner");
        m.field = item.stringOr("field");
        m.file = item.stringOr("file");
        m.line = cast(int) item.integerOr("line");
        m.when = item.stringOr("when");
        if (auto a = item.get("arguments"))
            foreach (ref v; a.items)
                m.arguments ~= v.text;
        if (auto c = item.get("conditions"))
            foreach (ref v; c.items)
                m.conditions ~= v.text;
        catalog.messages ~= m;
    }
    return true;
}

string localeJson(ref const LocaleCatalog catalog) {
    string text = `{"format":` ~ numberText(catalogFormat) ~ `,"package":` ~ jsonQuote(
            catalog.package_) ~ `,"locale":` ~ jsonQuote(
            catalog.locale) ~ `,"entries":[` ~ "\n";
    foreach (i, ref e; catalog.entries)
        text ~= ` {"key":` ~ jsonQuote(e.key) ~ `,"text":` ~ jsonQuote(
                e.text) ~ `,"status":` ~ jsonQuote(e.status)
            ~ `,"revision":` ~ jsonQuote(
                    e.revision) ~ `}` ~ (i + 1 < catalog.entries.length ? "," : "") ~ "\n";
    return text ~ "]}\n";
}

bool readLocaleCatalog(string text, out LocaleCatalog catalog, out string error) {
    JsonValue root;
    if (!parseJson(text, root, error))
        return false;
    if (root.kind != JsonValue.Kind.object) {
        error = "a catalog is a JSON object";
        return false;
    }
    catalog.package_ = root.stringOr("package");
    catalog.locale = root.stringOr("locale");
    auto list = root.get("entries");
    if (list is null || list.kind != JsonValue.Kind.array) {
        error = "missing `entries`";
        return false;
    }
    foreach (ref item; list.items) {
        LocaleEntry e;
        e.key = item.stringOr("key");
        e.text = item.stringOr("text");
        e.status = item.stringOr("status", "draft");
        e.revision = item.stringOr("revision");
        catalog.entries ~= e;
    }
    return true;
}

void sortEntries(LocaleEntry[] items) {
    foreach (i; 1 .. items.length) {
        auto item = items[i];
        size_t j = i;
        while (j > 0 && items[j - 1].key > item.key) {
            items[j] = items[j - 1];
            --j;
        }
        items[j] = item;
    }
}

// -----------------------------------------------------------------------------
// Change detection
// -----------------------------------------------------------------------------

struct SourceChange {
    string kind; // added, removed, cosmetic, substantive, rename
    string key;
    string other; // for a rename: the new key
}

/// What changed between the catalog on disk and the one just extracted. A change that leaves the
/// normalized text equal is `cosmetic`: translations keep their status. A removed key and an
/// added key with the same text and owner kind are reported as a probable `rename`.
SourceChange[] diffSource(ref const SourceCatalog before, ref const SourceCatalog after) {
    SourceChange[] changes;
    string[] removed;
    string[] added;
    foreach (ref b; before.messages) {
        auto a = after.find(b.key);
        if (a is null) {
            removed ~= b.key;
            continue;
        }
        if (a.text == b.text)
            continue;
        changes ~= SourceChange(revisionOf(a.text) == revisionOf(b.text) ? "cosmetic" : "substantive", b.key, null);
    }
    foreach (ref a; after.messages)
        if (before.find(a.key) is null)
            added ~= a.key;
    // Pair removed and added keys that carry the same words.
    bool[string] pairedAdded;
    string[] stillRemoved;
    foreach (oldKey; removed) {
        auto b = before.find(oldKey);
        string match;
        foreach (newKey; added) {
            if (newKey in pairedAdded)
                continue;
            auto a = after.find(newKey);
            if (a.revision == b.revision && a.field == b.field) {
                match = newKey;
                break;
            }
        }
        if (match.length) {
            pairedAdded[match] = true;
            changes ~= SourceChange("rename", oldKey, match);
        } else
            stillRemoved ~= oldKey;
    }
    foreach (key; stillRemoved)
        changes ~= SourceChange("removed", key, null);
    foreach (key; added)
        if (key !in pairedAdded)
            changes ~= SourceChange("added", key, null);
    return changes;
}

/// What a translation is, now: `stale` when it was made from other words than the source has.
string effectiveStatus(ref const LocaleEntry entry, const(SourceMessage)* source) {
    if (source is null)
        return entry.status;
    if ((entry.status == "draft" || entry.status == "reviewed") && entry.revision != source.revision)
        return "stale";
    return entry.status;
}

// -----------------------------------------------------------------------------
// CSV
// -----------------------------------------------------------------------------

private void csvField(ref char[] out_, string field) {
    bool quote;
    foreach (char c; field)
        if (c == ',' || c == '"' || c == '\n' || c == '\r')
            quote = true;
    if (!quote) {
        out_ ~= field;
        return;
    }
    out_ ~= '"';
    foreach (char c; field) {
        if (c == '"')
            out_ ~= '"';
        out_ ~= c;
    }
    out_ ~= '"';
}

/// `key,source,translation,status,revision,context,arguments`. A byte order mark leads, so that
/// spreadsheets read the file as UTF-8. CSV has no status or notes fields of its own, so they
/// travel as columns; the importer reads `key`, `translation` and `revision` only.
string csvExport(ref const SourceCatalog source, LocaleCatalog* locale) {
    char[] out_;
    out_ ~= "\xEF\xBB\xBF";
    out_ ~= "key,source,translation,status,revision,context,arguments\r\n";
    foreach (ref m; source.messages) {
        string translation, status = "untranslated", revision = m.revision;
        if (locale !is null)
            if (auto e = locale.find(m.key)) {
                translation = e.text;
                status = effectiveStatus(*e, &m);
                revision = e.revision;
            }
        string[7] fields = [
            m.key, m.text, translation, status, revision, m.owner ~ " (" ~ m.field ~ ")",
            quoteJoin(m.arguments)
        ];
        foreach (i, field; fields) {
            if (i)
                out_ ~= ',';
            csvField(out_, field);
        }
        out_ ~= "\r\n";
    }
    return cast(string) out_;
}

private string quoteJoin(const(string)[] items) {
    string text;
    foreach (i, item; items)
        text ~= (i ? " " : "") ~ item;
    return text;
}

/// Parses CSV into rows of fields. Returns false with an error when a quote is not closed.
bool csvParse(string text, out string[][] rows, out string error) {
    size_t i;
    if (text.length >= 3 && text[0] == 0xEF && text[1] == 0xBB && text[2] == 0xBF)
        i = 3;
    string[] row;
    char[] field;
    bool inQuotes, fieldStarted;
    while (i < text.length) {
        char c = text[i];
        if (inQuotes) {
            if (c == '"') {
                if (i + 1 < text.length && text[i + 1] == '"') {
                    field ~= '"';
                    i += 2;
                    continue;
                }
                inQuotes = false;
                ++i;
                continue;
            }
            field ~= c;
            ++i;
            continue;
        }
        if (c == '"' && field.length == 0) {
            inQuotes = true;
            fieldStarted = true;
            ++i;
            continue;
        }
        if (c == ',') {
            row ~= cast(string) field.idup;
            field.length = 0;
            fieldStarted = false;
            ++i;
            continue;
        }
        if (c == '\r' || c == '\n') {
            if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n')
                ++i;
            ++i;
            row ~= cast(string) field.idup;
            field.length = 0;
            if (!(row.length == 1 && row[0].length == 0 && !fieldStarted))
                rows ~= row;
            row = null;
            fieldStarted = false;
            continue;
        }
        field ~= c;
        ++i;
    }
    if (inQuotes) {
        error = "a quoted field is not closed";
        return false;
    }
    if (field.length || row.length || fieldStarted) {
        row ~= cast(string) field.idup;
        rows ~= row;
    }
    return true;
}
