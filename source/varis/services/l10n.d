/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// `varis l10n`: extraction of display text into catalogs, translation status, and the CSV
/// adapter (NARRATIVE_LOCALIZATION_PLAN §7). Reads the project index; runs nothing.
module varis.services.l10n;

import core.stdc.stdio;
import core.sys.posix.sys.stat : mkdir;

import varis.services.catalog;
import varis.services.diagnostic;
import varis.services.index;
import varis.services.manifest;
import varis.services.xliff;
import varis.narrative.translation : parseTranslation, TranslationTemplate;
import varis.narrative.plural : pluralCategoryAllowed, requiredPluralCategories;
import std.algorithm : sort;
import varis.workbench.server : jsonQuote, readFile, writeFile;

private enum catalogDirectory = "l10n";
private enum sourcePath = "l10n/source.json";

private void say(string text) {
    fwrite(text.ptr, 1, text.length, stdout);
}

private void warn(string text) {
    fwrite(text.ptr, 1, text.length, stderr);
}

private string number(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}

private string localePath(string locale) {
    return catalogDirectory ~ "/" ~ locale ~ ".json";
}

/// A locale tag is letters, digits, `-` and `_`: it becomes a file name.
private bool validLocale(string locale) {
    if (locale.length == 0 || locale.length > 32)
        return false;
    foreach (char c; locale)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return false;
    return true;
}

private struct Project {
    Manifest manifest;
    ProjectIndex index;
    Diagnostic[] problems;
    SourceCatalog source;
    int computed; // messages that are not string literals
    bool ok;
}

private Project loadProject() {
    Project project;
    project.manifest = loadManifest(".");
    project.problems ~= project.manifest.problems;
    foreach (file; projectFiles(".", project.manifest)) {
        string content;
        if (!readFile(file, content)) {
            project.problems ~= makeDiagnostic("error", "io", file, 0, 0, 0, 0, "cannot read file");
            continue;
        }
        auto indexed = indexFile(file, content);
        project.problems ~= indexed.problems;
        project.index.files ~= indexed;
    }
    project.source = buildSourceCatalog(project.index, project.manifest, project.problems);
    foreach (ref f; project.index.files)
        foreach (ref m; f.messages)
            if (m.computed) {
                ++project.computed;
                project.problems ~= makeDiagnostic("warning", "computed-text", m.file, m.range.line, m.range.column,
                        m.range.endLine, m.range.endColumn, "display text built by code cannot be extracted for translation", m
                        .owner);
            }
    project.ok = true;
    foreach (ref d; project.problems)
        if (d.isError)
            project.ok = false;
    return project;
}

private void report(ref Project project) {
    sortDiagnostics(project.problems);
    foreach (ref d; project.problems)
        say(diagnosticText(d) ~ "\n");
}

private bool loadSource(ref SourceCatalog catalog, out bool exists) {
    string text;
    exists = readFile(sourcePath, text);
    if (!exists)
        return true;
    string error;
    if (!readSourceCatalog(text, catalog, error)) {
        warn(sourcePath ~ ": " ~ error ~ "\n");
        return false;
    }
    return true;
}

private bool loadLocale(string locale, ref LocaleCatalog catalog) {
    catalog.locale = locale;
    string text;
    if (!readFile(localePath(locale), text))
        return true;
    string error;
    if (!readLocaleCatalog(text, catalog, error)) {
        warn(localePath(locale) ~ ": " ~ error ~ "\n");
        return false;
    }
    catalog.locale = locale;
    return true;
}

private bool saveText(string path, string text) {
    mkdir((catalogDirectory ~ "\0").ptr, 493); // 0755; exists is fine
    if (!writeFile(path, text)) {
        warn("cannot write " ~ path ~ "\n");
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// extract
// -----------------------------------------------------------------------------

private int extract(string[] args) {
    bool check, carry;
    foreach (a; args) {
        if (a == "--check")
            check = true;
        else if (a == "--carry-renames")
            carry = true;
        else {
            warn("usage: varis l10n extract [--check] [--carry-renames]\n");
            return 2;
        }
    }
    auto project = loadProject();
    report(project);
    if (!project.ok)
        return 1;
    SourceCatalog before;
    bool existed;
    if (!loadSource(before, existed))
        return 1;
    auto changes = diffSource(before, project.source);
    if (!existed)
        say("no " ~ sourcePath ~ " yet; every message is new\n");
    foreach (ref c; changes) {
        if (!existed)
            break; // a first extraction: the summary says it
        if (c.kind == "rename")
            say("probable rename: " ~ c.key ~ " -> " ~ c.other ~ (carry ? " (translations carried over)" : "") ~ "\n");
        else if (c.kind == "cosmetic" || c.kind == "substantive")
            say("changed (" ~ c.kind ~ "): " ~ c.key ~ "\n");
        else
            say(c.kind ~ ": " ~ c.key ~ "\n");
    }
    size_t added, removed, changed;
    foreach (ref c; changes) {
        if (c.kind == "added")
            ++added;
        else if (c.kind == "removed" || c.kind == "rename")
            ++removed;
        else
            ++changed;
    }
    if (!existed)
        added = project.source.messages.length;
    auto text = sourceJson(project.source);
    string current;
    bool same = readFile(sourcePath, current) && current == text;
    say(sourcePath ~ ": " ~ number(project.source.messages.length) ~ " message(s), +" ~ number(
            added) ~ " -" ~ number(
            removed) ~ " ~" ~ number(changed) ~ (same ? " (up to date)" : "") ~ "\n");
    if (project.computed)
        say(number(project.computed) ~ " text(s) built by code are not extracted\n");
    if (check) {
        if (!same) {
            say(sourcePath ~ " is out of date; run `varis l10n extract`\n");
            return 1;
        }
        return 0;
    }
    if (!same && !saveText(sourcePath, text))
        return 1;
    // Translations follow the source: renames are carried when asked, stale is marked.
    foreach (locale; project.manifest.locales) {
        if (!validLocale(locale))
            continue;
        LocaleCatalog catalog;
        if (!loadLocale(locale, catalog))
            return 1;
        if (catalog.entries.length == 0)
            continue;
        catalog.package_ = project.source.package_;
        bool dirty;
        if (carry)
            foreach (ref c; changes)
                if (c.kind == "rename")
                    if (auto entry = catalog.find(c.key)) {
                        entry.key = c.other;
                        dirty = true;
                    }
        foreach (ref e; catalog.entries) {
            auto message = project.source.find(e.key);
            auto status = effectiveStatus(e, message);
            if (status != e.status) {
                e.status = status;
                dirty = true;
            }
        }
        if (dirty) {
            sortEntries(catalog.entries);
            if (!saveText(localePath(locale), localeJson(catalog)))
                return 1;
        }
    }
    return 0;
}

// -----------------------------------------------------------------------------
// status
// -----------------------------------------------------------------------------

private int status() {
    auto project = loadProject();
    report(project);
    if (!project.ok)
        return 1;
    // The catalog on disk is what translations were made against; fall back to the project.
    SourceCatalog source;
    bool existed;
    if (!loadSource(source, existed))
        return 1;
    if (!existed)
        source = project.source;
    say(number(source.messages.length) ~ " message(s) in " ~ (existed ? sourcePath
            : "the project (not yet extracted)") ~ "\n");
    if (project.manifest.locales.length == 0) {
        say("the manifest lists no locales\n");
        return 0;
    }
    foreach (locale; project.manifest.locales) {
        if (!validLocale(locale)) {
            warn("not a locale tag: " ~ locale ~ "\n");
            continue;
        }
        LocaleCatalog catalog;
        if (!loadLocale(locale, catalog))
            return 1;
        size_t reviewed, draft, stale, missing;
        size_t[string] incomplete;
        string[] owners;
        foreach (ref m; source.messages) {
            string state = "untranslated";
            if (auto e = catalog.find(m.key))
                state = effectiveStatus(*e, &m);
            if (state == "reviewed")
                ++reviewed;
            else if (state == "draft")
                ++draft;
            else if (state == "stale")
                ++stale;
            else
                ++missing;
            if (state != "reviewed") {
                // Grouped by the definition a key belongs to: `lamp.light.title` is `lamp`.
                string group = m.key;
                foreach (i, char c; m.key)
                    if (c == '.') {
                        group = m.key[0 .. i];
                        break;
                    }
                if (group !in incomplete)
                    owners ~= group;
                incomplete[group] += 1;
            }
        }
        say(locale ~ ": " ~ number(reviewed) ~ " reviewed, " ~ number(draft) ~ " draft, " ~ number(
                stale) ~ " stale, " ~ number(
                missing) ~ " untranslated\n");
        foreach (owner; owners)
            say("  " ~ owner ~ ": " ~ number(incomplete[owner]) ~ " to do\n");
    }
    return 0;
}

// -----------------------------------------------------------------------------
// export and import (CSV)
// -----------------------------------------------------------------------------

private bool endsWith(string text, string suffix) {
    return text.length >= suffix.length && text[$ - suffix.length .. $] == suffix;
}

/// The id of a kit: a hash of the source catalog it was made from.
private string kitIdOf(string sourceText) {
    ulong h = 14695981039346656037UL;
    foreach (char c; sourceText) {
        h ^= cast(ubyte) c;
        h *= 1099511628211UL;
    }
    char[16] digits;
    static immutable hex = "0123456789abcdef";
    foreach (i; 0 .. 16)
        digits[15 - i] = hex[(h >> (4 * i)) & 15];
    return digits.idup;
}

private SourceCatalog currentSource(out bool ok) {
    SourceCatalog source;
    bool existed;
    ok = true;
    if (!loadSource(source, existed)) {
        ok = false;
        return source;
    }
    if (!existed) {
        auto project = loadProject();
        if (!project.ok) {
            report(project);
            ok = false;
            return source;
        }
        source = project.source;
    }
    return source;
}

/// The code points of a text, for the character set a font must cover.
private void collectCodePoints(string text, ref bool[uint] seen) {
    size_t i;
    while (i < text.length) {
        ubyte c = text[i];
        uint code;
        size_t length;
        if (c < 0x80) {
            code = c;
            length = 1;
        } else if (c < 0xE0) {
            code = c & 0x1F;
            length = 2;
        } else if (c < 0xF0) {
            code = c & 0x0F;
            length = 3;
        } else {
            code = c & 0x07;
            length = 4;
        }
        foreach (k; 1 .. length)
            if (i + k < text.length)
                code = (code << 6) | (text[i + k] & 0x3F);
        seen[code] = true;
        i += length;
    }
}

private string codePointsText(bool[uint] seen) {
    uint[] codes = seen.keys;
    foreach (i; 1 .. codes.length) {
        auto item = codes[i];
        size_t j = i;
        while (j > 0 && codes[j - 1] > item) {
            codes[j] = codes[j - 1];
            --j;
        }
        codes[j] = item;
    }
    char[] out_;
    foreach (code; codes) {
        if (code < 0x20)
            continue;
        if (code < 0x80)
            out_ ~= cast(char) code;
        else if (code < 0x800) {
            out_ ~= cast(char)(0xC0 | (code >> 6));
            out_ ~= cast(char)(0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            out_ ~= cast(char)(0xE0 | (code >> 12));
            out_ ~= cast(char)(0x80 | ((code >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (code & 0x3F));
        } else {
            out_ ~= cast(char)(0xF0 | (code >> 18));
            out_ ~= cast(char)(0x80 | ((code >> 12) & 0x3F));
            out_ ~= cast(char)(0x80 | ((code >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (code & 0x3F));
        }
    }
    return cast(string) out_;
}

private string[] splitList(string text) {
    string[] items;
    size_t from;
    foreach (i; 0 .. text.length + 1)
        if (i == text.length || text[i] == ',') {
            if (i > from)
                items ~= text[from .. i];
            from = i + 1;
        }
    return items;
}

/// `export --kit DIR`: a handoff kit (§6.4): messages for each locale in the chosen format with
/// context, the source catalog, a glossary, the character sets, and a kit id. With
/// `--changed-since ID` only the new and substantively changed messages are sent, each with the
/// previous English.
private int exportKit(string kitDirectory, string[] locales, string format, string changedSince) {
    bool ok;
    auto source = currentSource(ok);
    if (!ok)
        return 1;
    auto sourceText = sourceJson(source);
    auto id = kitIdOf(sourceText);
    SourceMessage[] only;
    SourceMessage[] previous;
    if (changedSince.length) {
        string oldText;
        if (!readFile(catalogDirectory ~ "/kits/" ~ changedSince ~ ".json", oldText)) {
            warn("no record of kit " ~ changedSince ~ " in l10n/kits/\n");
            return 1;
        }
        SourceCatalog old;
        string error;
        if (!readSourceCatalog(oldText, old, error)) {
            warn("l10n/kits/" ~ changedSince ~ ".json: " ~ error ~ "\n");
            return 1;
        }
        previous = old.messages;
        foreach (ref m; source.messages) {
            auto before = old.find(m.key);
            if (before is null || before.revision != m.revision)
                only ~= m;
        }
        if (only is null)
            only = [];
    }
    import core.sys.posix.sys.stat : mkdir;

    mkdir((catalogDirectory ~ "\0").ptr, 493);
    mkdir((catalogDirectory ~ "/kits\0").ptr, 493);
    mkdir((kitDirectory ~ "\0").ptr, 493);
    // The record that makes later delta kits possible: what the publisher was sent.
    if (!writeFile(catalogDirectory ~ "/kits/" ~ id ~ ".json", sourceText)) {
        warn("cannot write l10n/kits/" ~ id ~ ".json\n");
        return 1;
    }
    string kit = `{"format":1,"kit":` ~ jsonQuote(id) ~ `,"package":` ~ jsonQuote(
            source.package_) ~ `,"source_language":`
        ~ jsonQuote(source.language) ~ `,"locales":[`;
    foreach (i, locale; locales)
        kit ~= (i ? "," : "") ~ jsonQuote(locale);
    kit ~= `],"format_of_messages":` ~ jsonQuote(format);
    if (changedSince.length)
        kit ~= `,"changed_since":` ~ jsonQuote(changedSince) ~ `,"messages":` ~ number(only.length);
    kit ~= "}\n";
    bool[uint] sourceChars;
    foreach (ref m; source.messages)
        collectCodePoints(m.text, sourceChars);
    string charsets = "{";
    bool firstLocale = true;
    foreach (locale; locales) {
        if (!validLocale(locale)) {
            warn("not a locale tag: " ~ locale ~ "\n");
            return 2;
        }
        LocaleCatalog catalog;
        if (!loadLocale(locale, catalog))
            return 1;
        catalog.package_ = source.package_;
        string path = kitDirectory ~ "/" ~ locale ~ (format == "xliff" ? ".xlf" : (format == "json" ? ".json" : ".csv"));
        string text;
        if (format == "xliff")
            text = xliffExport(source, locale, id, &catalog, only.length || changedSince.length ? only : null, previous);
        else if (format == "json")
            text = localeJson(catalog);
        else
            text = csvExport(source, &catalog);
        if (!writeFile(path, text)) {
            warn("cannot write " ~ path ~ "\n");
            return 1;
        }
        bool[uint] chars;
        foreach (ref e; catalog.entries)
            collectCodePoints(e.text, chars);
        charsets ~= (firstLocale ? "" : ",") ~ jsonQuote(locale) ~ `:` ~ jsonQuote(codePointsText(chars));
        firstLocale = false;
    }
    charsets ~= `,"source":` ~ jsonQuote(codePointsText(sourceChars)) ~ "}\n";
    // A glossary: the project's own file when there is one, else the labels of named things.
    string glossary;
    if (!readFile(catalogDirectory ~ "/glossary.json", glossary)) {
        glossary = `{"terms":[` ~ "\n";
        bool first = true;
        foreach (ref m; source.messages)
            if (m.field == "label" || m.field == "name") {
                glossary ~= (first ? " " : ",\n ") ~ `{"term":` ~ jsonQuote(
                        m.text) ~ `,"source":` ~ jsonQuote(m.key)
                    ~ `,"note":""}`;
                first = false;
            }
        glossary ~= "\n]}\n";
    }
    bool written = writeFile(kitDirectory ~ "/kit.json", kit) && writeFile(kitDirectory ~ "/source.json", sourceText)
        && writeFile(kitDirectory ~ "/glossary.json", glossary) && writeFile(kitDirectory ~ "/charset.json", charsets);
    if (!written) {
        warn("cannot write the kit files in " ~ kitDirectory ~ "\n");
        return 1;
    }
    say("kit " ~ id ~ " written to " ~ kitDirectory ~ ": " ~ number(changedSince.length ? only.length
            : source.messages.length)
            ~ " message(s) for " ~ number(locales.length) ~ " locale(s)\n");
    return 0;
}

private int exportCatalog(string[] args) {
    string locale, format = "csv", output, kitDirectory, changedSince;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i] == "--format" && i + 1 < args.length)
            format = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            output = args[++i];
        else if (args[i] == "--kit" && i + 1 < args.length)
            kitDirectory = args[++i];
        else if (args[i] == "--changed-since" && i + 1 < args.length)
            changedSince = args[++i];
        else {
            warn("usage: varis l10n export [--locale L[,L...]] [--format csv|xliff|json] (--out FILE | --kit DIR [--changed-since ID])\n");
            return 2;
        }
    }
    if (format != "csv" && format != "xliff" && format != "json") {
        warn("unknown format `" ~ format ~ "`; the formats are: csv, xliff, json\n");
        return 2;
    }
    if (kitDirectory.length) {
        auto locales = splitList(locale);
        if (locales.length == 0) {
            warn("a kit needs --locale\n");
            return 2;
        }
        return exportKit(kitDirectory, locales, format, changedSince);
    }
    if (locale.length && !validLocale(locale)) {
        warn("not a locale tag: " ~ locale ~ "\n");
        return 2;
    }
    if (format != "csv") {
        warn("--out writes CSV; use --kit DIR for " ~ format ~ "\n");
        return 2;
    }
    bool ok;
    auto source = currentSource(ok);
    if (!ok)
        return 1;
    LocaleCatalog catalog;
    LocaleCatalog* use;
    if (locale.length) {
        if (!loadLocale(locale, catalog))
            return 1;
        use = &catalog;
    }
    auto text = csvExport(source, use);
    if (output.length) {
        if (!writeFile(output, text)) {
            warn("cannot write " ~ output ~ "\n");
            return 1;
        }
        say("wrote " ~ output ~ " (" ~ number(source.messages.length) ~ " message(s))\n");
    } else
        say(text);
    return 0;
}

/// One row of a translation file, whatever its format.
private struct Row {
    string key;
    string text;
    string revision; // the source revision the translator saw, when the file says
}

/// Reads the rows of a CSV, XLIFF or canonical JSON file. `error` is set when it cannot.
private bool readRows(string file, out Row[] rows, out string error) {
    string text;
    if (!readFile(file, text)) {
        error = "cannot read " ~ file;
        return false;
    }
    if (endsWith(file, ".xlf") || endsWith(file, ".xliff")) {
        XliffFile parsed;
        if (!xliffImport(text, parsed, error))
            return false;
        foreach (ref u; parsed.units)
            rows ~= Row(u.key, u.target, u.revision);
        return true;
    }
    if (endsWith(file, ".json")) {
        LocaleCatalog catalog;
        if (!readLocaleCatalog(text, catalog, error))
            return false;
        foreach (ref e; catalog.entries)
            rows ~= Row(e.key, e.text, e.revision);
        return true;
    }
    string[][] table;
    if (!csvParse(text, table, error))
        return false;
    if (table.length == 0) {
        error = "empty file";
        return false;
    }
    int keyColumn = -1, translationColumn = -1, revisionColumn = -1;
    foreach (i, name; table[0]) {
        if (name == "key")
            keyColumn = cast(int) i;
        else if (name == "translation")
            translationColumn = cast(int) i;
        else if (name == "revision")
            revisionColumn = cast(int) i;
    }
    if (keyColumn < 0 || translationColumn < 0) {
        error = "the header needs `key` and `translation` columns";
        return false;
    }
    foreach (row; table[1 .. $]) {
        if (row.length <= keyColumn || row.length <= translationColumn)
            continue;
        string revision = revisionColumn >= 0 && row.length > revisionColumn ? row[revisionColumn] : null;
        rows ~= Row(row[keyColumn], row[translationColumn], revision);
    }
    return true;
}

private int importCatalog(string[] args) {
    string file, locale, kitDirectory;
    bool apply;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i] == "--kit" && i + 1 < args.length)
            kitDirectory = args[++i];
        else if (args[i] == "--apply")
            apply = true;
        else if (file.length == 0 && args[i].length && args[i][0] != '-')
            file = args[i];
        else {
            warn("usage: varis l10n import FILE(.csv|.xlf|.json) --locale L [--kit DIR] [--apply]\n");
            return 2;
        }
    }
    if (file.length == 0 || !validLocale(locale)) {
        warn("usage: varis l10n import FILE(.csv|.xlf|.json) --locale L [--kit DIR] [--apply]\n");
        return 2;
    }
    Row[] rows;
    string error;
    if (!readRows(file, rows, error)) {
        warn(file ~ ": " ~ error ~ "\n");
        return 1;
    }
    SourceCatalog source;
    bool existed;
    if (!loadSource(source, existed) || !existed) {
        warn("no " ~ sourcePath ~ "; run `varis l10n extract` first\n");
        return 1;
    }
    // What the translator saw: the kit's revisions, when the kit is at hand.
    SourceCatalog sentWith;
    bool haveKit;
    if (kitDirectory.length) {
        string kitText;
        if (!readFile(kitDirectory ~ "/source.json", kitText) || !readSourceCatalog(kitText, sentWith, error)) {
            warn("cannot read the kit's source.json in " ~ kitDirectory ~ "\n");
            return 1;
        }
        haveKit = true;
    }
    LocaleCatalog catalog;
    if (!loadLocale(locale, catalog))
        return 1;
    catalog.package_ = source.package_;
    size_t drafted, stale, unchanged, rejected;
    foreach (row; rows) {
        auto key = row.key;
        auto translation = row.text;
        if (translation.length == 0)
            continue;
        auto message = source.find(key);
        if (message is null) {
            say("rejected: " ~ key ~ ": no such message in the source catalog\n");
            ++rejected;
            continue;
        }
        TranslationTemplate parsed;
        string reason;
        if (!parseTranslation(translation, parsed, reason)) {
            say("rejected: " ~ key ~ ": " ~ reason ~ "\n");
            ++rejected;
            continue;
        }
        // Whole messages only; a translation may drop or reorder arguments, never add one.
        bool bad;
        foreach (placeholder; parsed.placeholders) {
            bool known;
            foreach (argument; message.arguments)
                if (argument == placeholder)
                    known = true;
            if (!known) {
                say("rejected: " ~ key ~ ": unknown placeholder {" ~ placeholder ~ "}\n");
                bad = true;
                break;
            }
        }
        if (bad) {
            ++rejected;
            continue;
        }
        string seen = message.revision;
        if (haveKit) {
            if (auto sent = sentWith.find(key))
                seen = sent.revision;
        } else if (row.revision.length)
            seen = row.revision;
        string newStatus = seen == message.revision ? "draft" : "stale";
        auto existing = catalog.find(key);
        if (existing !is null && existing.text == translation && existing.revision == seen) {
            ++unchanged;
            continue;
        }
        if (existing is null) {
            catalog.entries ~= LocaleEntry(key, translation, newStatus, seen);
        } else {
            existing.text = translation;
            existing.status = newStatus;
            existing.revision = seen;
        }
        if (newStatus == "stale")
            ++stale;
        else
            ++drafted;
    }
    say(file ~ ": " ~ number(drafted) ~ " draft, " ~ number(stale) ~ " stale, " ~ number(
            unchanged) ~ " unchanged, " ~ number(
            rejected) ~ " rejected" ~ (apply ? "" : " (nothing written; use --apply)") ~ "\n");
    if (apply) {
        sortEntries(catalog.entries);
        if (!saveText(localePath(locale), localeJson(catalog)))
            return 1;
    }
    return rejected ? 1 : 0;
}

/// `review --locale L [KEY...]`: the only way a translation becomes `reviewed`.
private int reviewCommand(string[] args) {
    string locale;
    string[] keys;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i].length && args[i][0] != '-')
            keys ~= args[i];
        else {
            warn("usage: varis l10n review --locale L [KEY...]\n");
            return 2;
        }
    }
    if (!validLocale(locale)) {
        warn("usage: varis l10n review --locale L [KEY...]\n");
        return 2;
    }
    bool ok;
    auto source = currentSource(ok);
    if (!ok)
        return 1;
    LocaleCatalog catalog;
    if (!loadLocale(locale, catalog))
        return 1;
    catalog.package_ = source.package_;
    size_t marked, skipped;
    foreach (ref e; catalog.entries) {
        bool wanted = keys.length == 0;
        foreach (k; keys)
            if (k == e.key)
                wanted = true;
        if (!wanted || e.status == "reviewed")
            continue;
        auto message = source.find(e.key);
        if (effectiveStatus(e, message) == "stale" || message is null) {
            say("not reviewed: " ~ e.key ~ " is stale; its source text changed\n");
            ++skipped;
            continue;
        }
        e.status = "reviewed";
        ++marked;
    }
    if (marked && !saveText(localePath(locale), localeJson(catalog)))
        return 1;
    say(locale ~ ": " ~ number(marked) ~ " marked reviewed, " ~ number(skipped) ~ " skipped\n");
    return 0;
}

/// `build --out DIR`: language packs for a release. A locale with an error does not build.
private int buildPacks(string[] args) {
    string output = "packs";
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--out" && i + 1 < args.length)
            output = args[++i];
        else {
            warn("usage: varis l10n build [--out DIR]\n");
            return 2;
        }
    }
    auto project = loadProject();
    report(project);
    if (!project.ok)
        return 1;
    import core.sys.posix.sys.stat : mkdir;

    mkdir((output ~ "\0").ptr, 493);
    bool failed;
    string index = `{"format":1,"package":` ~ jsonQuote(project.source.package_) ~ `,"packs":[`;
    bool first = true;
    foreach (locale; project.manifest.locales) {
        if (!validLocale(locale))
            continue;
        LocaleCoverage coverage;
        auto found = checkLocale(project.source, locale, coverage);
        bool bad;
        foreach (ref d; found) {
            say(diagnosticText(d) ~ "\n");
            if (d.isError)
                bad = true;
        }
        if (bad) {
            say(locale ~ ": not built\n");
            failed = true;
            continue;
        }
        LocaleCatalog catalog;
        if (!loadLocale(locale, catalog))
            return 1;
        string messages = "{";
        size_t count;
        bool[uint] chars;
        foreach (ref e; catalog.entries) {
            auto message = project.source.find(e.key);
            // A stale translation answers an older English: the source text is better.
            if (message is null || effectiveStatus(e, message) == "stale")
                continue;
            messages ~= (count ? "," : "") ~ "\n " ~ jsonQuote(e.key) ~ `:` ~ jsonQuote(e.text);
            collectCodePoints(e.text, chars);
            ++count;
        }
        messages ~= "\n}";
        string pack = `{"format":1,"package":` ~ jsonQuote(project.source.package_) ~ `,"locale":` ~ jsonQuote(
                locale)
            ~ `,"source_language":` ~ jsonQuote(project.source.language) ~ `,"charset":` ~ jsonQuote(
                    codePointsText(chars))
            ~ `,"messages":` ~ messages ~ "}\n";
        mkdir((output ~ "/" ~ locale ~ "\0").ptr, 493);
        if (!writeFile(output ~ "/" ~ locale ~ "/pack.json", pack)) {
            warn("cannot write the pack of " ~ locale ~ "\n");
            return 1;
        }
        index ~= (first ? "" : ",") ~ `{"locale":` ~ jsonQuote(locale) ~ `,"messages":` ~ number(count) ~ `}`;
        first = false;
        say(locale ~ ": pack of " ~ number(count) ~ " message(s) written to " ~ output ~ "/" ~ locale ~ "\n");
    }
    index ~= "]}\n";
    if (!writeFile(output ~ "/index.json", index)) {
        warn("cannot write " ~ output ~ "/index.json\n");
        return 1;
    }
    return failed ? 1 : 0;
}

// -----------------------------------------------------------------------------
// check --locale, and the pseudo-locale
// -----------------------------------------------------------------------------

enum pseudoLocale = "x-pseudo";

/// Accents the letters outside template tags and lengthens the text by a third, inside
/// brackets: clipped text boxes and hard-coded strings show before any translator is involved.
string pseudoLocalize(string text) {
    static immutable string[2][] accents = [
        ["a", "á"], ["e", "é"], ["i", "í"], ["o", "ó"], ["u", "ú"], ["c", "ç"], ["n", "ñ"],
        ["y", "ý"],
        ["A", "Á"], ["E", "É"], ["I", "Í"], ["O", "Ó"], ["U", "Ú"], ["C", "Ç"], ["N", "Ñ"],
        ["Y", "Ý"],
    ];
    char[] result;
    result ~= '[';
    size_t letters;
    size_t i;
    while (i < text.length) {
        char c = text[i];
        if (c == '{' && i + 1 < text.length && text[i + 1] == '{') {
            result ~= "{{";
            i += 2;
            continue;
        }
        if (c == '}' && i + 1 < text.length && text[i + 1] == '}') {
            result ~= "}}";
            i += 2;
            continue;
        }
        if (c == '{') {
            // A template tag is copied as it is: its words are code.
            int depth;
            size_t j = i;
            while (j < text.length) {
                if (text[j] == '{')
                    ++depth;
                else if (text[j] == '}' && --depth == 0)
                    break;
                ++j;
            }
            size_t end = j < text.length ? j + 1 : text.length;
            result ~= text[i .. end];
            i = end;
            continue;
        }
        bool replaced;
        foreach (pair; accents)
            if (pair[0][0] == c) {
                result ~= pair[1];
                replaced = true;
                break;
            }
        if (!replaced)
            result ~= c;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
            ++letters;
        ++i;
    }
    foreach (_; 0 .. letters / 3)
        result ~= '~';
    result ~= ']';
    return cast(string) result;
}

struct LocaleCoverage {
    size_t total, reviewed, draft, stale, untranslated;
}

/// The checks on a set of translations against a source catalog: syntax, placeholders,
/// conditions and variants must come from the source message, and a translation made from older
/// text is stale. `file` is only what diagnostics say.
Diagnostic[] checkEntries(ref const SourceCatalog source, string locale, string file, const(LocaleEntry)[] entries) {
    Diagnostic[] found;
    foreach (ref e; entries) {
        auto message = source.find(e.key);
        if (message is null) {
            found ~= makeDiagnostic("warning", "unknown-key", file, 0, 0, 0, 0,
                    locale ~ ": `" ~ e.key ~ "` is no message of the source", e.key);
            continue;
        }
        TranslationTemplate translated;
        string error;
        if (!parseTranslation(e.text, translated, error)) {
            found ~= makeDiagnostic("error", "translation-syntax", file, 0, 0, 0, 0, locale ~ ": " ~ e.key ~ ": " ~ error, e
                    .key);
            continue;
        }
        TranslationTemplate original;
        string ignored;
        if (!parseTranslation(message.text, original, ignored))
            continue;
        foreach (placeholder; translated.placeholders) {
            bool known;
            foreach (name; original.placeholders)
                if (name == placeholder)
                    known = true;
            if (!known)
                found ~= makeDiagnostic("error", "translation-placeholder", file, 0, 0, 0, 0,
                        locale ~ ": " ~ e.key ~ ": {" ~ placeholder ~ "} is not an argument of the source message", e
                        .key);
        }
        foreach (condition; translated.conditions) {
            bool known;
            foreach (c; original.conditions)
                if (c == condition)
                    known = true;
            if (!known)
                found ~= makeDiagnostic("error", "translation-condition", file, 0, 0, 0, 0,
                        locale ~ ": " ~ e.key ~ ": {#if " ~ condition ~ "} is not a condition of the source message; "
                        ~ "the message will fall back to the source text", e.key);
        }
        bool sameVariants = translated.variantOptionCounts.length == original.variantOptionCounts.length;
        if (sameVariants)
            foreach (i, n; translated.variantOptionCounts) {
                if (n != original.variantOptionCounts[i])
                    sameVariants = false;
                // Named alternatives may be reordered, not renamed.
                string[] a = original.variantNames[i].dup, b = translated.variantNames[i].dup;
                bool anyNamed;
                foreach (name; a)
                    anyNamed = anyNamed || name.length > 0;
                if (anyNamed && sameVariants) {
                    a.sort;
                    b.sort;
                    if (a != b)
                        sameVariants = false;
                }
            }
        if (!sameVariants && (translated.variantOptionCounts.length || original.variantOptionCounts.length))
            found ~= makeDiagnostic("error", "translation-variants", file, 0, 0, 0, 0,
                    locale ~ ": " ~ e.key ~ ": the variants do not match the source's (the same groups, with the same "
                    ~ "number of options); the message will fall back to the source text", e.key);
        // Plural branches: exactly the categories the language has.
        foreach (g, kind; translated.choiceKinds) {
            if (kind != "plural")
                continue;
            auto labels = translated.choiceLabels[g];
            foreach (label; labels)
                if (!pluralCategoryAllowed(locale, label))
                    found ~= makeDiagnostic("error", "translation-plural", file, 0, 0, 0, 0,
                            locale ~ ": " ~ e.key ~ ": {#" ~ label ~ "} is not a plural category of " ~ locale, e.key);
            foreach (needed; requiredPluralCategories(locale)) {
                if (needed == "other")
                    continue;
                bool present;
                foreach (label; labels)
                    if (label == needed)
                        present = true;
                if (!present)
                    found ~= makeDiagnostic("error", "translation-plural", file, 0, 0, 0, 0,
                            locale ~ ": " ~ e.key ~ ": a plural in " ~ locale ~ " needs {#" ~ needed ~ "} (and {#other})", e
                            .key);
            }
        }
        auto status = effectiveStatus(e, message);
        if (status == "stale")
            found ~= makeDiagnostic("warning", "stale", file, 0, 0, 0, 0,
                    locale ~ ": " ~ e.key ~ ": translated from older source text", e.key);
    }
    return found;
}

/// The checks of `varis check --locale L` on the catalog of one locale against a source catalog.
Diagnostic[] checkLocale(ref const SourceCatalog source, string locale, ref LocaleCoverage coverage) {
    Diagnostic[] found;
    LocaleCatalog catalog;
    if (locale == pseudoLocale) {
        // Generated, not stored: nothing to check but that every source message survives.
        coverage.total = source.messages.length;
        coverage.reviewed = source.messages.length;
        return found;
    }
    if (!loadLocale(locale, catalog)) {
        found ~= makeDiagnostic("error", "catalog", localePath(locale), 0, 0, 0, 0, "the catalog cannot be read");
        return found;
    }
    string file = localePath(locale);
    coverage.total = source.messages.length;
    found ~= checkEntries(source, locale, file, catalog.entries);
    foreach (ref m; source.messages) {
        string state = "untranslated";
        if (auto e = catalog.find(m.key))
            state = effectiveStatus(*e, &m);
        if (state == "reviewed")
            ++coverage.reviewed;
        else if (state == "draft")
            ++coverage.draft;
        else if (state == "stale")
            ++coverage.stale;
        else
            ++coverage.untranslated;
    }
    return found;
}

/// The messages of a locale as key -> text, for a front end that plays in it. The pseudo-locale
/// is made from the source catalog. Entries of every status are used: a stale translation is
/// still the best text there is, and the checker has already said it is stale.
bool localeMessages(string locale, out string[string] messages, out string error) {
    SourceCatalog source;
    bool exists;
    if (!loadSource(source, exists) || !exists) {
        auto project = loadProject();
        if (!project.ok) {
            error = "the project has errors; run `varis check`";
            return false;
        }
        source = project.source;
    }
    if (locale == pseudoLocale) {
        foreach (ref m; source.messages)
            messages[m.key] = pseudoLocalize(m.text);
        return true;
    }
    if (!validLocale(locale)) {
        error = "not a locale tag: " ~ locale;
        return false;
    }
    LocaleCatalog catalog;
    string text;
    if (!readFile(localePath(locale), text)) {
        error = "no catalog " ~ localePath(locale);
        return false;
    }
    if (!loadLocale(locale, catalog)) {
        error = "cannot read " ~ localePath(locale);
        return false;
    }
    foreach (ref e; catalog.entries)
        messages[e.key] = e.text;
    return true;
}

/// `check --kit DIR FILE`: what a publisher runs on their own file, with no source tree: the same
/// checks as `check --locale`, against the source catalog the kit carries.
private int checkKitFile(string kitDirectory, string file) {
    string kitText;
    SourceCatalog source;
    string error;
    if (!readFile(kitDirectory ~ "/source.json", kitText) || !readSourceCatalog(kitText, source, error)) {
        warn("cannot read the kit's source.json in " ~ kitDirectory ~ "\n");
        return 1;
    }
    Row[] rows;
    if (!readRows(file, rows, error)) {
        warn(file ~ ": " ~ error ~ "\n");
        return 1;
    }
    LocaleEntry[] entries;
    foreach (ref r; rows) {
        if (r.text.length == 0)
            continue;
        string revision = r.revision;
        if (auto message = source.find(r.key))
            if (revision.length == 0)
                revision = message.revision;
        entries ~= LocaleEntry(r.key, r.text, "draft", revision);
    }
    auto found = checkEntries(source, "kit", file, entries);
    sortDiagnostics(found);
    bool failed;
    foreach (ref d; found) {
        say(diagnosticText(d) ~ "\n");
        if (d.isError)
            failed = true;
    }
    say(file ~ ": " ~ number(entries.length) ~ " translation(s) checked, " ~ number(found.length) ~ " problem(s)\n");
    return failed ? 1 : 0;
}

private int checkCommand(string[] args) {
    string locale;
    string kitDirectory, kitFile;
    bool requireReviewed;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--kit" && i + 1 < args.length)
            kitDirectory = args[++i];
        else if (kitDirectory.length && args[i].length && args[i][0] != '-')
            kitFile = args[i];
        else if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i] == "--require" && i + 1 < args.length) {
            requireReviewed = args[++i] == "reviewed";
        } else {
            warn("usage: varis l10n check --locale L|all [--require reviewed]\n");
            return 2;
        }
    }
    if (kitDirectory.length) {
        if (kitFile.length == 0) {
            warn("usage: varis l10n check --kit DIR FILE\n");
            return 2;
        }
        return checkKitFile(kitDirectory, kitFile);
    }
    if (locale.length == 0) {
        warn("usage: varis l10n check --locale L|all [--require reviewed]\n");
        return 2;
    }
    auto project = loadProject();
    report(project);
    if (!project.ok)
        return 1;
    string[] locales;
    if (locale == "all")
        locales = project.manifest.locales.dup;
    else
        locales = [locale];
    // Translations are checked against the source as it is now, not against the last extraction.
    auto source = project.source;
    bool failed;
    foreach (tag; locales) {
        LocaleCoverage coverage;
        auto found = checkLocale(source, tag, coverage);
        sortDiagnostics(found);
        foreach (ref d; found) {
            say(diagnosticText(d) ~ "\n");
            if (d.isError)
                failed = true;
        }
        say(tag ~ ": " ~ number(coverage.reviewed) ~ " reviewed, " ~ number(
                coverage.draft) ~ " draft, " ~ number(
                coverage.stale) ~ " stale, " ~ number(
                coverage.untranslated) ~ " untranslated of " ~ number(
                coverage.total) ~ "\n");
        if (requireReviewed && coverage.reviewed != coverage.total) {
            say(tag ~ ": the release gate needs every message reviewed\n");
            failed = true;
        }
    }
    return failed ? 1 : 0;
}

/// The entries of a locale's catalog for the workbench's translation panel, with the status each
/// has against the source as it is now: `{"entries":[{"key":..,"text":..,"status":..}]}`.
string catalogEntriesJson(string locale) {
    if (!validLocale(locale))
        return `{"entries":[]}`;
    auto project = loadProject();
    LocaleCatalog catalog;
    if (!loadLocale(locale, catalog))
        return `{"entries":[]}`;
    string json = `{"entries":[`;
    bool first = true;
    foreach (ref e; catalog.entries) {
        json ~= (first ? "" : ",") ~ `{"key":` ~ jsonQuote(e.key) ~ `,"text":` ~ jsonQuote(
                e.text) ~ `,"status":`
            ~ jsonQuote(effectiveStatus(e, project.source.find(e.key))) ~ `}`;
        first = false;
    }
    return json ~ "]}";
}

/// Saves one translation as a draft, after the checks an import makes. Returns the problem, or
/// null when it was saved. An empty text removes the entry.
string saveTranslation(string locale, string key, string text) {
    if (!validLocale(locale) || locale == pseudoLocale)
        return "not a locale that has a catalog: " ~ locale;
    auto project = loadProject();
    auto message = project.source.find(key);
    if (message is null)
        return "no such message: " ~ key;
    LocaleCatalog catalog;
    if (!loadLocale(locale, catalog))
        return "the catalog cannot be read";
    catalog.package_ = project.source.package_;
    if (text.length == 0) {
        LocaleEntry[] kept;
        foreach (ref e; catalog.entries)
            if (e.key != key)
                kept ~= e;
        catalog.entries = kept;
    } else {
        TranslationTemplate parsed;
        string error;
        if (!parseTranslation(text, parsed, error))
            return error;
        foreach (placeholder; parsed.placeholders) {
            bool known;
            foreach (argument; message.arguments)
                if (argument == placeholder)
                    known = true;
            if (!known)
                return "{" ~ placeholder ~ "} is not an argument of this message";
        }
        if (auto existing = catalog.find(key)) {
            existing.text = text;
            existing.status = "draft";
            existing.revision = message.revision;
        } else
            catalog.entries ~= LocaleEntry(key, text, "draft", message.revision);
    }
    sortEntries(catalog.entries);
    if (!saveText(localePath(locale), localeJson(catalog)))
        return "cannot write the catalog";
    return null;
}

/// For the translation panel: every branch of the plurals and selects in `text` (a translation
/// being typed, or the source), rendered with sample values, in the rules of `locale`. Returns
/// `{"previews":[{"param":..,"kind":..,"rows":[{"value":..,"category":..,"text":..}]}]}`.
string branchPreviewJson(string locale, string text) {
    import varis.narrative.translation : renderTranslation, RenderTrace;
    import varis.narrative.plural : pluralCategory, requiredPluralCategories;
    import varis.types : LuaValue, Symbol;

    TranslationTemplate parsed;
    string error;
    if (!parseTranslation(text, parsed, error))
        return `{"previews":[],"error":` ~ jsonQuote(error) ~ `}`;
    string tag = locale.length && locale != pseudoLocale ? locale : "en";
    string json = `{"previews":[`;
    bool firstPreview = true;
    foreach (g, kind; parsed.choiceKinds) {
        auto parameter = parsed.choiceParameters[g];
        struct Sample {
            string value;
            string category;
            LuaValue bound;
        }

        Sample[] samples;
        if (kind == "plural") {
            string[] categories = requiredPluralCategories(tag).dup;
            foreach (label; parsed.choiceLabels[g]) {
                bool known;
                foreach (c; categories)
                    known = known || c == label;
                if (!known)
                    categories ~= label;
            }
            foreach (category; categories) {
                // The smallest number the language puts in this category.
                bool found;
                foreach (n; 0 .. 1000) {
                    if (pluralCategory(tag, n) == category) {
                        samples ~= Sample(number(n), category, LuaValue(cast(long) n));
                        found = true;
                        break;
                    }
                }
                if (!found && category == "other")
                    samples ~= Sample("1.5", category, LuaValue(1.5));
            }
        } else {
            foreach (label; parsed.choiceLabels[g])
                samples ~= Sample(label, "", LuaValue(Symbol(label)));
            samples ~= Sample("(any other value)", "default", LuaValue(Symbol("\u0001other")));
        }
        string rows;
        foreach (i, sample; samples) {
            LuaValue[string] bindings;
            foreach (name; parsed.placeholders)
                bindings[name] = LuaValue("\u2039" ~ name ~ "\u203a");
            bindings[parameter] = sample.bound;
            RenderTrace trace;
            string output;
            renderTranslation(parsed, bindings, (LuaValue v) {
                import varis.types : toLuaString;

                return toLuaString(v);
            }, trace, tag, output);
            rows ~= (i ? "," : "") ~ `{"value":` ~ jsonQuote(sample.value) ~ `,"category":` ~ jsonQuote(
                    sample.category)
                ~ `,"text":` ~ jsonQuote(output) ~ `}`;
        }
        json ~= (firstPreview ? "" : ",") ~ `{"param":` ~ jsonQuote(parameter) ~ `,"kind":` ~ jsonQuote(
                kind) ~ `,"rows":[` ~ rows ~ `]}`;
        firstPreview = false;
    }
    return json ~ "]}";
}

/// `varis l10n <command> ...`: returns the process exit status.
int l10nMain(string[] args) {
    if (args.length == 0) {
        warn("usage: varis l10n extract|status|export|import|check|review|build ...\n");
        return 2;
    }
    switch (args[0]) {
    case "extract":
        return extract(args[1 .. $]);
    case "status":
        return status();
    case "export":
        return exportCatalog(args[1 .. $]);
    case "import":
        return importCatalog(args[1 .. $]);
    case "check":
        return checkCommand(args[1 .. $]);
    case "review":
        return reviewCommand(args[1 .. $]);
    case "build":
        return buildPacks(args[1 .. $]);
    default:
        warn("unknown l10n command `" ~ args[0] ~ "`; the commands are: extract, status, export, import, check, review, build\n");
        return 2;
    }
}
