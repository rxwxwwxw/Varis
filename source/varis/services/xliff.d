/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The XLIFF 1.2 adapter of the translation catalogs (NARRATIVE_LOCALIZATION_PLAN §6.2): export a
/// locale's messages as one `trans-unit` each, and read back what a translator returns. Only the
/// parts translation tools need are written and read; everything else in a file is ignored.
///
/// What XLIFF cannot carry natively travels as notes: the owner of a message, its arguments, the
/// `when` clause, and for a delta kit the previous source text. The revision a translator saw is
/// the kit's: the importer takes it from the kit's source catalog, not from the file.
module varis.services.xliff;

import varis.services.catalog;

struct XliffUnit {
    string key;
    string source;
    string target;
    string revision; // when the file carries one
}

struct XliffFile {
    string sourceLanguage;
    string targetLanguage;
    string original; // the kit id, when written by `l10n export`
    XliffUnit[] units;
}

private string escape(string text) {
    char[] result;
    foreach (char c; text) {
        switch (c) {
        case '&':
            result ~= "&amp;";
            break;
        case '<':
            result ~= "&lt;";
            break;
        case '>':
            result ~= "&gt;";
            break;
        case '"':
            result ~= "&quot;";
            break;
        default:
            result ~= c;
        }
    }
    return cast(string) result;
}

private string unescape(string text) {
    char[] result;
    size_t i;
    while (i < text.length) {
        if (text[i] != '&') {
            result ~= text[i++];
            continue;
        }
        size_t end = i + 1;
        while (end < text.length && text[end] != ';' && end - i < 10)
            ++end;
        if (end >= text.length || text[end] != ';') {
            result ~= text[i++];
            continue;
        }
        auto name = text[i + 1 .. end];
        if (name == "amp")
            result ~= '&';
        else if (name == "lt")
            result ~= '<';
        else if (name == "gt")
            result ~= '>';
        else if (name == "quot")
            result ~= '"';
        else if (name == "apos")
            result ~= '\'';
        else if (name.length > 1 && name[0] == '#') {
            uint code;
            bool ok = true;
            if (name[1] == 'x' || name[1] == 'X') {
                foreach (char c; name[2 .. $]) {
                    int v = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
                    if (v < 0)
                        ok = false;
                    else
                        code = code * 16 + v;
                }
            } else {
                foreach (char c; name[1 .. $]) {
                    if (c < '0' || c > '9')
                        ok = false;
                    else
                        code = code * 10 + (c - '0');
                }
            }
            if (!ok) {
                result ~= text[i .. end + 1];
            } else if (code < 0x80)
                result ~= cast(char) code;
            else if (code < 0x800) {
                result ~= cast(char)(0xC0 | (code >> 6));
                result ~= cast(char)(0x80 | (code & 0x3F));
            } else if (code < 0x10000) {
                result ~= cast(char)(0xE0 | (code >> 12));
                result ~= cast(char)(0x80 | ((code >> 6) & 0x3F));
                result ~= cast(char)(0x80 | (code & 0x3F));
            } else {
                result ~= cast(char)(0xF0 | (code >> 18));
                result ~= cast(char)(0x80 | ((code >> 12) & 0x3F));
                result ~= cast(char)(0x80 | ((code >> 6) & 0x3F));
                result ~= cast(char)(0x80 | (code & 0x3F));
            }
        } else {
            result ~= text[i .. end + 1];
        }
        i = end + 1;
    }
    return cast(string) result;
}

/// One `<file>` of a kit for `locale`. `previous` gives the old source text of a delta kit.
string xliffExport(ref const SourceCatalog source, string locale, string kitId, LocaleCatalog* translations,
        const(SourceMessage)[] only = null, const(SourceMessage)[] previous = null) {
    string text = `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n" ~ `<xliff version="1.2" xmlns="urn:oasis:names:tc:xliff:document:1.2">`
        ~ "\n" ~ ` <file original="` ~ escape(
                kitId) ~ `" source-language="` ~ escape(
                source.language) ~ `" target-language="`
        ~ escape(locale) ~ `" datatype="plaintext">` ~ "\n  <body>\n";
    const(SourceMessage)[] list = only !is null ? only : source.messages;
    foreach (ref m; list) {
        string target, state = "new";
        if (translations !is null)
            if (auto e = translations.find(m.key)) {
                target = e.text;
                auto status = effectiveStatus(*e, &m);
                state = status == "reviewed" ? "final" : (status == "stale" ? "needs-review-translation" : "translated");
            }
        text ~= `   <trans-unit id="` ~ escape(m.key) ~ `" resname="` ~ escape(m.key) ~ `">` ~ "\n";
        text ~= `    <source xml:lang="` ~ escape(source.language) ~ `">` ~ escape(m.text) ~ `</source>` ~ "\n";
        text ~= `    <target xml:lang="` ~ escape(locale) ~ `" state="` ~ state ~ `">` ~ escape(
                target) ~ `</target>` ~ "\n";
        text ~= `    <note from="varis" priority="1">` ~ escape(m.owner ~ " (" ~ m.field ~ ")") ~ `</note>` ~ "\n";
        if (m.arguments.length) {
            string arguments;
            foreach (i, a; m.arguments)
                arguments ~= (i ? ", " : "") ~ "{" ~ a ~ "}";
            text ~= `    <note from="varis" annotates="source">arguments: ` ~ escape(arguments) ~ `</note>` ~ "\n";
        }
        if (m.when.length)
            text ~= `    <note from="varis" annotates="source">shown when: ` ~ escape(m.when) ~ `</note>` ~ "\n";
        foreach (ref p; previous)
            if (p.key == m.key && p.text != m.text)
                text ~= `    <note from="varis-previous-source">` ~ escape(p.text) ~ `</note>` ~ "\n";
        text ~= "   </trans-unit>\n";
    }
    return text ~ "  </body>\n </file>\n</xliff>\n";
}

private string attribute(string tag, string name) {
    auto marker = name ~ `="`;
    for (size_t i = 0; i + marker.length <= tag.length; ++i) {
        if (tag[i .. i + marker.length] != marker)
            continue;
        if (i > 0 && tag[i - 1] != ' ' && tag[i - 1] != '\t' && tag[i - 1] != '\n' && tag[i - 1] != '\r')
            continue;
        size_t from = i + marker.length;
        size_t to = from;
        while (to < tag.length && tag[to] != '"')
            ++to;
        return unescape(tag[from .. to]);
    }
    return null;
}

private bool findElement(string text, string name, size_t from, out size_t tagStart, out size_t tagEnd, out size_t bodyEnd) {
    auto open = "<" ~ name;
    size_t i = from;
    while (i + open.length <= text.length) {
        if (text[i .. i + open.length] == open && i + open.length < text.length
                && (text[i + open.length] == ' ' || text[i + open.length] == '>' || text[i + open.length] == '/'
                    || text[i + open.length] == '\n' || text[i + open.length] == '\t' || text[i + open.length] == '\r')) {
            tagStart = i;
            size_t j = i;
            while (j < text.length && text[j] != '>')
                ++j;
            if (j >= text.length)
                return false;
            tagEnd = j + 1;
            if (text[j - 1] == '/') {
                bodyEnd = tagEnd; // an empty element
                return true;
            }
            auto close = "</" ~ name ~ ">";
            size_t k = tagEnd;
            while (k + close.length <= text.length && text[k .. k + close.length] != close)
                ++k;
            if (k + close.length > text.length)
                return false;
            bodyEnd = k;
            return true;
        }
        ++i;
    }
    return false;
}

private string elementText(string body_) {
    // CDATA sections are taken as they are; entities are decoded elsewhere.
    char[] result;
    size_t i;
    while (i < body_.length) {
        enum open = "<![CDATA[";
        if (i + open.length <= body_.length && body_[i .. i + open.length] == open) {
            size_t j = i + open.length;
            while (j + 3 <= body_.length && body_[j .. j + 3] != "]]>")
                ++j;
            result ~= body_[i + open.length .. j];
            i = j + 3;
            continue;
        }
        if (body_[i] == '<') {
            // An inline tag (`<x/>`, `<g>`): translators' tools add them; their content stays.
            while (i < body_.length && body_[i] != '>')
                ++i;
            ++i;
            continue;
        }
        size_t j = i;
        while (j < body_.length && body_[j] != '<')
            ++j;
        result ~= unescape(body_[i .. j]);
        i = j;
    }
    return cast(string) result;
}

/// Reads the translation units of an XLIFF 1.2 file. Returns false with `error` when the file has
/// no `<file>` or no unit.
bool xliffImport(string text, out XliffFile file, out string error) {
    size_t tagStart, tagEnd, bodyEnd;
    if (!findElement(text, "file", 0, tagStart, tagEnd, bodyEnd)) {
        error = "no <file> element: this is not an XLIFF 1.2 file";
        return false;
    }
    auto tag = text[tagStart .. tagEnd];
    file.original = attribute(tag, "original");
    file.sourceLanguage = attribute(tag, "source-language");
    file.targetLanguage = attribute(tag, "target-language");
    size_t at = tagEnd;
    while (true) {
        size_t us, ue, ub;
        if (!findElement(text, "trans-unit", at, us, ue, ub))
            break;
        auto unitTag = text[us .. ue];
        auto unitBody = text[ue .. ub];
        XliffUnit unit;
        unit.key = attribute(unitTag, "resname");
        if (unit.key.length == 0)
            unit.key = attribute(unitTag, "id");
        size_t a, b, c;
        if (findElement(unitBody, "source", 0, a, b, c))
            unit.source = elementText(unitBody[b .. c]);
        if (findElement(unitBody, "target", 0, a, b, c))
            unit.target = elementText(unitBody[b .. c]);
        file.units ~= unit;
        at = ub;
    }
    if (file.units.length == 0) {
        error = "the file has no <trans-unit>";
        return false;
    }
    return true;
}
