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
import varis.workbench.server : readFile, writeFile;

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

private int exportCatalog(string[] args) {
    string locale, format = "csv", output;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i] == "--format" && i + 1 < args.length)
            format = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            output = args[++i];
        else {
            warn("usage: varis l10n export [--locale L] [--format csv] [--out FILE]\n");
            return 2;
        }
    }
    if (format != "csv") {
        warn("unknown format `" ~ format ~ "`; the formats are: csv\n");
        return 2;
    }
    if (locale.length && !validLocale(locale)) {
        warn("not a locale tag: " ~ locale ~ "\n");
        return 2;
    }
    SourceCatalog source;
    bool existed;
    if (!loadSource(source, existed))
        return 1;
    if (!existed) {
        auto project = loadProject();
        if (!project.ok) {
            report(project);
            return 1;
        }
        source = project.source;
    }
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

private int importCatalog(string[] args) {
    string file, locale;
    bool apply;
    for (size_t i = 0; i < args.length; ++i) {
        if (args[i] == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (args[i] == "--apply")
            apply = true;
        else if (file.length == 0 && args[i].length && args[i][0] != '-')
            file = args[i];
        else {
            warn("usage: varis l10n import FILE.csv --locale L [--apply]\n");
            return 2;
        }
    }
    if (file.length == 0 || !validLocale(locale)) {
        warn("usage: varis l10n import FILE.csv --locale L [--apply]\n");
        return 2;
    }
    string text;
    if (!readFile(file, text)) {
        warn("cannot read " ~ file ~ "\n");
        return 1;
    }
    string[][] rows;
    string error;
    if (!csvParse(text, rows, error)) {
        warn(file ~ ": " ~ error ~ "\n");
        return 1;
    }
    if (rows.length == 0) {
        warn(file ~ ": empty file\n");
        return 1;
    }
    int keyColumn = -1, translationColumn = -1, revisionColumn = -1;
    foreach (i, name; rows[0]) {
        if (name == "key")
            keyColumn = cast(int) i;
        else if (name == "translation")
            translationColumn = cast(int) i;
        else if (name == "revision")
            revisionColumn = cast(int) i;
    }
    if (keyColumn < 0 || translationColumn < 0) {
        warn(file ~ ": the header needs `key` and `translation` columns\n");
        return 1;
    }
    SourceCatalog source;
    bool existed;
    if (!loadSource(source, existed) || !existed) {
        warn("no " ~ sourcePath ~ "; run `varis l10n extract` first\n");
        return 1;
    }
    LocaleCatalog catalog;
    if (!loadLocale(locale, catalog))
        return 1;
    catalog.package_ = source.package_;
    size_t drafted, stale, unchanged, rejected;
    foreach (row; rows[1 .. $]) {
        if (row.length <= keyColumn || row.length <= translationColumn)
            continue;
        auto key = row[keyColumn];
        auto translation = row[translationColumn];
        if (translation.length == 0)
            continue;
        auto message = source.find(key);
        if (message is null) {
            say("rejected: " ~ key ~ ": no such message in the source catalog\n");
            ++rejected;
            continue;
        }
        // Whole messages only; a translation may drop or reorder arguments, never add one.
        bool bad;
        foreach (placeholder; templatePlaceholders(translation)) {
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
        // The revision the translator saw; absent means they translated the current text.
        string seen = revisionColumn >= 0 && row.length > revisionColumn && row[revisionColumn].length ? row[revisionColumn] : message
            .revision;
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

/// `varis l10n <command> ...`: returns the process exit status.
int l10nMain(string[] args) {
    if (args.length == 0) {
        warn("usage: varis l10n extract|status|export|import ...\n");
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
    default:
        warn("unknown l10n command `" ~ args[0] ~ "`; the commands are: extract, status, export, import\n");
        return 2;
    }
}
