/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Translated message templates (NARRATIVE_LOCALIZATION_PLAN §2, §3): the same template grammar
/// as source text, parsed without compiling any Lua, so that a translation can be checked and
/// rendered without running code and cannot add a query, a weight or a random choice of its own.
///
/// Rendering is a pure function of the captured render trace of the source message: the results
/// of its `{#if query ...}` conditions and the variants it drew. A translation may use the
/// conditions and the variant groups the source has, no others; anything else makes the whole
/// message fall back to the source text.
module varis.narrative.translation;

import varis.types;

/// What rendering a source message looked at. Kept with a presentation so that the same
/// presentation can be rendered again in another language without evaluating anything.
struct RenderTrace {
    bool[string] conditions; // normalized condition source -> whether the query had a result
    size_t[] variants; // the draw of each variant group, as given to the renderer
    bool recorded; // false when the source had no template to trace
}

private struct TNode {
    enum Kind : ubyte {
        literal,
        placeholder,
        conditional,
        variants
    }

    Kind kind;
    string text; // literal text, placeholder name, or condition source
    TNode[] yes;
    TNode[] no;
    TNode[][] options; // variant options
}

final class TranslationTemplate {
    private TNode[] nodes;
    string[] placeholders; // in order of appearance
    string[] conditions; // normalized sources of `{#if ...}`
    size_t[] variantOptionCounts; // per group, in parse (closing) order

    /// The text of a message that is only text (a translated name).
    string literalText() const {
        string text;
        foreach (ref node; nodes)
            if (node.kind == TNode.Kind.literal)
                text ~= node.text;
        return text;
    }
}

/// Whitespace runs become one space and the ends are trimmed: two spellings of one condition
/// compare equal.
string normalizeCondition(string text) {
    char[] result;
    bool space;
    foreach (char c; text) {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            space = result.length > 0;
            continue;
        }
        if (space)
            result ~= ' ';
        space = false;
        result ~= c;
    }
    return cast(string) result;
}

private bool isSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

private string strip(string s) {
    size_t a, b = s.length;
    while (a < b && isSpace(s[a]))
        ++a;
    while (b > a && isSpace(s[b - 1]))
        --b;
    return s[a .. b];
}

private struct Parser {
    string text;
    size_t cursor;
    string error;
    TranslationTemplate result;

    bool fail(string message) {
        if (error.length == 0)
            error = message;
        return false;
    }

    static bool isVariantTag(string token) {
        return token.length >= 8 && token[0 .. 8] == "#variant";
    }

    static bool weightOk(string argument) {
        argument = strip(argument);
        if (argument.length == 0)
            return true;
        if (argument.length > 7 && argument[0 .. 7] == "weight=")
            argument = strip(argument[7 .. $]);
        bool digit, dot;
        foreach (char c; argument) {
            if (c >= '0' && c <= '9')
                digit = true;
            else if (c == '.' && !dot)
                dot = true;
            else
                return false;
        }
        return digit;
    }

    /// Parses nodes until a closing tag; `terminator` receives it (empty at the end of the text).
    bool nodes(out TNode[] list, out string terminator, bool insideVariant) {
        char[] literal;
        void flush() {
            if (literal.length) {
                TNode node;
                node.kind = TNode.Kind.literal;
                node.text = cast(string) literal.idup;
                list ~= node;
                literal.length = 0;
            }
        }

        while (cursor < text.length) {
            if (cursor + 1 < text.length && text[cursor] == '{' && text[cursor + 1] == '{') {
                literal ~= '{';
                cursor += 2;
                continue;
            }
            if (cursor + 1 < text.length && text[cursor] == '}' && text[cursor + 1] == '}') {
                literal ~= '}';
                cursor += 2;
                continue;
            }
            if (text[cursor] != '{') {
                literal ~= text[cursor++];
                continue;
            }
            flush();
            size_t start = ++cursor;
            int braces;
            while (cursor < text.length) {
                char c = text[cursor];
                if (c == '"' || c == '\'') {
                    auto quote = c;
                    ++cursor;
                    while (cursor < text.length && text[cursor] != quote) {
                        if (text[cursor] == '\\' && cursor + 1 < text.length)
                            ++cursor;
                        ++cursor;
                    }
                    if (cursor == text.length)
                        break;
                    ++cursor;
                    continue;
                }
                if (c == '{')
                    ++braces;
                else if (c == '}' && braces == 0)
                    break;
                else if (c == '}')
                    --braces;
                ++cursor;
            }
            if (cursor >= text.length)
                return fail("unterminated placeholder: a `{` has no closing `}`");
            string token = strip(text[start .. cursor++]);
            if (token == "#else" || token == "/if" || token == "/variant" || token == "/variants") {
                terminator = token;
                return true;
            }
            if (insideVariant && isVariantTag(token)) {
                terminator = token;
                return true;
            }
            TNode node;
            if (token.length > 4 && token[0 .. 4] == "#if ") {
                auto condition = normalizeCondition(token[4 .. $]);
                if (condition.length < 6 || condition[0 .. 6] != "query ")
                    return fail("a condition must be a query existence test: {#if query ...}");
                node.kind = TNode.Kind.conditional;
                node.text = condition;
                bool known;
                foreach (c; result.conditions)
                    if (c == condition)
                        known = true;
                if (!known)
                    result.conditions ~= condition;
                string ending;
                if (!nodes(node.yes, ending, insideVariant))
                    return false;
                if (ending == "#else")
                    if (!nodes(node.no, ending, insideVariant))
                        return false;
                if (ending != "/if")
                    return fail("a condition needs {/if}");
            } else if (token == "#variants") {
                node.kind = TNode.Kind.variants;
                string next;
                while (true) {
                    TNode[] ignored;
                    if (!nodes(ignored, next, true))
                        return false;
                    if (next == "/variants")
                        break;
                    if (!isVariantTag(next)) {
                        if (next.length == 0)
                            return fail("{#variants} needs {/variants}");
                        return fail("unexpected tag {" ~ next ~ "} in {#variants}");
                    }
                    // Options: each `#variant` tag opens one, until `/variant` or the next tag.
                    string tag = next;
                    while (isVariantTag(tag)) {
                        if (!weightOk(tag[8 .. $]))
                            return fail("a variant weight must be a positive number");
                        TNode[] optionNodes;
                        string ending;
                        if (!nodes(optionNodes, ending, true))
                            return false;
                        node.options ~= optionNodes;
                        if (ending == "/variants") {
                            tag = "";
                            next = "/variants";
                            break;
                        }
                        if (ending == "/variant") {
                            tag = "";
                            break;
                        }
                        if (isVariantTag(ending)) {
                            tag = ending;
                            continue;
                        }
                        return fail("a variant needs {/variant}");
                    }
                    if (next == "/variants")
                        break;
                }
                if (node.options.length == 0)
                    return fail("empty {#variants} block");
                result.variantOptionCounts ~= node.options.length;
            } else if (isVariantTag(token)) {
                node.kind = TNode.Kind.variants;
                string tag = token;
                while (isVariantTag(tag)) {
                    if (!weightOk(tag[8 .. $]))
                        return fail("a variant weight must be a positive number");
                    TNode[] optionNodes;
                    string ending;
                    if (!nodes(optionNodes, ending, true))
                        return false;
                    node.options ~= optionNodes;
                    if (ending == "#else") {
                        TNode[] elseNodes;
                        string elseEnding;
                        if (!nodes(elseNodes, elseEnding, true))
                            return false;
                        node.options ~= elseNodes;
                        if (elseEnding != "/variant")
                            return fail("a variant needs {/variant}");
                        break;
                    }
                    if (ending == "/variant")
                        break;
                    if (isVariantTag(ending)) {
                        tag = ending;
                        continue;
                    }
                    return fail("a variant needs {/variant}");
                }
                result.variantOptionCounts ~= node.options.length;
            } else {
                bool plain = token.length > 0;
                foreach (char c; token)
                    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
                        plain = false;
                if (!plain)
                    return fail("unknown tag {" ~ token ~ "}");
                node.kind = TNode.Kind.placeholder;
                node.text = token;
                result.placeholders ~= token;
            }
            list ~= node;
        }
        flush();
        terminator = "";
        return true;
    }
}

/// Parses a translation. On failure returns false and `error` says what is wrong.
bool parseTranslation(string text, out TranslationTemplate result, out string error) {
    Parser parser;
    parser.text = text;
    parser.result = new TranslationTemplate();
    string terminator;
    TNode[] list;
    if (!parser.nodes(list, terminator, false)) {
        error = parser.error;
        return false;
    }
    if (terminator.length) {
        error = "unexpected {" ~ terminator ~ "}";
        return false;
    }
    parser.result.nodes = list;
    result = parser.result;
    return true;
}

/// Renders a translation with the captured trace. Returns false when the trace lacks what the
/// translation asks for (a condition the source never evaluated, a variant group it never drew):
/// the caller then uses the source text, as a whole.
bool renderTranslation(TranslationTemplate template_, LuaValue[string] bindings, string delegate(LuaValue) display,
        ref const RenderTrace trace, out string output) {
    size_t groupIndex;
    bool failed;
    string renderNodes(const(TNode)[] list) {
        string text;
        foreach (ref node; list) {
            final switch (node.kind) {
            case TNode.Kind.literal:
                text ~= node.text;
                break;
            case TNode.Kind.placeholder:
                text ~= display(bindings.get(node.text, luaNil()));
                break;
            case TNode.Kind.conditional:
                if (auto known = node.text in trace.conditions)
                    text ~= renderNodes(*known ? node.yes : node.no);
                else
                    failed = true;
                break;
            case TNode.Kind.variants:
                size_t chosen;
                if (groupIndex < trace.variants.length) {
                    chosen = trace.variants[groupIndex];
                    if (chosen >= node.options.length)
                        chosen = 0;
                } else if (trace.recorded && trace.variants.length)
                    failed = true;
                ++groupIndex;
                text ~= renderNodes(node.options[chosen]);
                break;
            }
        }
        return text;
    }

    output = renderNodes(template_.nodes);
    return !failed;
}
