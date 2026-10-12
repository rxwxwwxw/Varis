/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Message templates without Lua (NARRATIVE_LOCALIZATION_PLAN §2, §3): the template grammar parsed
/// and rendered without compiling any code, so that a translation can be checked and rendered
/// without running anything, and so that the structure of a source text (its conditions and
/// variants) can be read for the gameplay fingerprint.
///
/// Rendering a translation is a pure function of the captured render trace of the source message:
/// the results of its `{#if query ...}` conditions and the variants it drew. A translation may use
/// the conditions and the variant groups the source has, no others; anything else makes the whole
/// message fall back to the source text.
///
/// Grammar (all tags in braces): `{name}`, `{{`, `}}`, `{#if query ...}..{#else}..{/if}`,
/// `{#variants}{#variant [weight] [name]}..{/variants}` and the one-tag form
/// `{#variant [weight] [name]}..{#variant ..}..{/variant}`, `{#plural n}{#one}..{#other}..{/plural}`
/// (`other` required) and `{#select v}{#case x}..{#default}..{/select}` (`default` required).
module varis.narrative.translation;

import varis.types;
import varis.narrative.plural;

/// What rendering a source message looked at. Kept with a presentation so that the same
/// presentation can be rendered again in another language without evaluating anything.
struct RenderTrace {
    bool[string] conditions; // normalized condition source -> whether the query had a result
    size_t[] variants; // the option drawn for each variant group, in the order encountered
    string[] variantNames; // the name of each drawn option ("" when it has none)
    bool recorded; // false when the source had no template to trace
}

private struct TNode {
    enum Kind : ubyte {
        literal,
        placeholder,
        conditional,
        variants,
        plural,
        select
    }

    Kind kind;
    string text; // literal text, placeholder name, condition source, or the plural/select parameter
    TNode[] yes;
    TNode[] no; // else branch, `{#other}` or `{#default}`
    TNode[][] options; // variant options, or the plural/select branches
    string[] names; // variant option names, or the plural/select branch labels
    string[] weights; // variant option weights as written ("" when absent)
}

final class TranslationTemplate {
    private TNode[] nodes;
    string[] placeholders; // arguments used, in order of appearance (plural and select parameters too)
    string[] conditions; // normalized sources of `{#if ...}`
    size_t[] variantOptionCounts; // per group, in parse (closing) order
    string[][] variantNames; // per group, the option names ("" for an unnamed one)
    string[][] choiceLabels; // per plural/select, the branch labels written (`one`, `case:x`, ...)
    string[] choiceKinds; // "plural" or "select", parallel to choiceLabels
    string[] choiceParameters; // the argument each plural/select chooses on, parallel too
    bool hasStructure; // `structure` is meaningful (the text parsed)

    /// The text of a message that is only text (a translated name).
    string literalText() const {
        string text;
        foreach (ref node; nodes)
            if (node.kind == TNode.Kind.literal)
                text ~= node.text;
        return text;
    }

    /// What the text contributes to gameplay: its conditions, the weights and names of its
    /// variants, and the parameters it selects on. Wording is not part of it.
    string structure() const {
        string describe(const(TNode)[] list) {
            string text;
            foreach (ref node; list) {
                final switch (node.kind) {
                case TNode.Kind.literal:
                case TNode.Kind.placeholder:
                    break;
                case TNode.Kind.conditional:
                    text ~= "[if " ~ node.text ~ " " ~ describe(node.yes) ~ "|" ~ describe(node.no) ~ "]";
                    break;
                case TNode.Kind.variants:
                    text ~= "[variants";
                    foreach (i, option; node.options)
                        text ~= " (" ~ node.weights[i] ~ "," ~ node.names[i] ~ ":" ~ describe(option) ~ ")";
                    text ~= "]";
                    break;
                case TNode.Kind.plural:
                case TNode.Kind.select:
                    text ~= (node.kind == TNode.Kind.plural ? "[plural " : "[select ") ~ node.text;
                    foreach (i, branch; node.options)
                        text ~= " (" ~ node.names[i] ~ ":" ~ describe(branch) ~ ")";
                    text ~= " (default:" ~ describe(node.no) ~ ")]";
                    break;
                }
            }
            return text;
        }

        return describe(nodes);
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

private bool isIdentifier(string text) {
    if (text.length == 0)
        return false;
    foreach (i, char c; text) {
        bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        bool digit = c >= '0' && c <= '9';
        if (!(letter || (digit && i > 0)))
            return false;
    }
    return true;
}

private bool isNumber(string text) {
    bool digit, dot;
    foreach (char c; text) {
        if (c >= '0' && c <= '9')
            digit = true;
        else if (c == '.' && !dot)
            dot = true;
        else
            return false;
    }
    return digit;
}

/// Arguments of a `#variant` tag: an optional weight (`3`, `weight=3`) and an optional name.
bool variantArguments(string argument, out string weight, out string name) {
    size_t i;
    while (i < argument.length) {
        while (i < argument.length && isSpace(argument[i]))
            ++i;
        size_t start = i;
        while (i < argument.length && !isSpace(argument[i]))
            ++i;
        if (start == i)
            break;
        auto word = argument[start .. i];
        if (word.length > 7 && word[0 .. 7] == "weight=")
            word = word[7 .. $];
        else if (!isNumber(word)) {
            if (!isIdentifier(word) || name.length)
                return false;
            name = word;
            continue;
        }
        if (!isNumber(word) || weight.length)
            return false;
        weight = word;
    }
    return true;
}

private bool isBranchTag(string token) {
    switch (token) {
    case "#zero":
    case "#one":
    case "#two":
    case "#few":
    case "#many":
    case "#other":
    case "#default":
    case "/plural":
    case "/select":
        return true;
    default:
        return token.length > 6 && token[0 .. 6] == "#case ";
    }
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
        return token.length >= 8 && token[0 .. 8] == "#variant" && (token.length == 8 || isSpace(token[8]));
    }

    /// Parses nodes until a closing tag; `terminator` receives it (empty at the end of the text).
    /// `insideVariant` and `insideChoice` say which enclosing constructs' tags end this list.
    bool nodes(out TNode[] list, out string terminator, bool insideVariant, bool insideChoice = false) {
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
            if (insideChoice && isBranchTag(token)) {
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
            } else if (token.length > 8 && token[0 .. 8] == "#plural " || token.length > 8 && token[0 .. 8] == "#select ") {
                bool plural = token[1] == 'p';
                auto parameter = strip(token[8 .. $]);
                if (!isIdentifier(parameter))
                    return fail("{" ~ token[0 .. 7] ~ " needs the name of an argument");
                node.kind = plural ? TNode.Kind.plural : TNode.Kind.select;
                node.text = parameter;
                result.placeholders ~= parameter;
                string[] labels;
                // Text before the first branch must be empty.
                TNode[] before;
                string tag;
                if (!nodes(before, tag, insideVariant, true))
                    return false;
                foreach (ref b; before)
                    if (b.kind != TNode.Kind.literal || strip(b.text).length)
                        return fail("{" ~ token[0 .. 7] ~ "} may contain only branches");
                bool haveDefault;
                string closing = plural ? "/plural" : "/select";
                while (tag != closing) {
                    if (tag.length == 0)
                        return fail("{" ~ token[0 .. 7] ~ "} needs {" ~ closing ~ "}");
                    string label;
                    bool isDefault;
                    if (plural) {
                        if (tag == "#other")
                            isDefault = true;
                        else if (tag.length > 1 && tag[0] == '#' && isPluralCategory(tag[1 .. $]))
                            label = tag[1 .. $];
                        else
                            return fail("unexpected {" ~ tag ~ "} in {#plural}");
                    } else {
                        if (tag == "#default")
                            isDefault = true;
                        else if (tag.length > 6 && tag[0 .. 6] == "#case ")
                            label = strip(tag[6 .. $]);
                        else
                            return fail("unexpected {" ~ tag ~ "} in {#select}");
                        if (!isDefault && label.length == 0)
                            return fail("a {#case} needs a value");
                    }
                    TNode[] branch;
                    string next;
                    if (!nodes(branch, next, insideVariant, true))
                        return false;
                    if (isDefault) {
                        if (haveDefault)
                            return fail("{" ~ tag ~ "} appears twice");
                        haveDefault = true;
                        node.no = branch;
                    } else {
                        foreach (l; node.names)
                            if (l == label)
                                return fail("{" ~ tag ~ "} appears twice");
                        node.names ~= label;
                        node.options ~= branch;
                        labels ~= label;
                    }
                    tag = next;
                }
                if (!haveDefault)
                    return fail(plural ? "{#plural} needs {#other}" : "{#select} needs {#default}");
                result.choiceKinds ~= plural ? "plural" : "select";
                result.choiceParameters ~= parameter;
                result.choiceLabels ~= labels;
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
                        string weight, name;
                        if (!variantArguments(tag[8 .. $], weight, name))
                            return fail("a variant takes a positive weight and a name: {" ~ tag ~ "}");
                        TNode[] optionNodes;
                        string ending;
                        if (!nodes(optionNodes, ending, true))
                            return false;
                        node.options ~= optionNodes;
                        node.weights ~= weight;
                        node.names ~= name;
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
                result.variantNames ~= node.names.dup;
            } else if (isVariantTag(token)) {
                node.kind = TNode.Kind.variants;
                string tag = token;
                while (isVariantTag(tag)) {
                    string weight, name;
                    if (!variantArguments(tag[8 .. $], weight, name))
                        return fail("a variant takes a positive weight and a name: {" ~ tag ~ "}");
                    TNode[] optionNodes;
                    string ending;
                    if (!nodes(optionNodes, ending, true))
                        return false;
                    node.options ~= optionNodes;
                    node.weights ~= weight;
                    node.names ~= name;
                    if (ending == "#else") {
                        TNode[] elseNodes;
                        string elseEnding;
                        if (!nodes(elseNodes, elseEnding, true))
                            return false;
                        node.options ~= elseNodes;
                        node.weights ~= "";
                        node.names ~= "";
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
                result.variantNames ~= node.names.dup;
            } else {
                if (!isIdentifier(token))
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

/// Parses a template. On failure returns false and `error` says what is wrong.
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
    parser.result.hasStructure = true;
    result = parser.result;
    return true;
}

/// The text a plural or select branch is chosen by, from the value of its parameter.
private string selectKey(LuaValue value) {
    import std.conv : to;

    if (isNil(value))
        return "";
    if (isSymbol(value))
        return value.match!((Symbol symbol) => symbol.name, _ => "");
    if (isString(value))
        return value.match!((string s) => s, _ => "");
    if (isInteger(value))
        return value.match!((long n) => n.to!string, _ => "");
    if (isBoolean(value))
        return value.match!((bool b) => b ? "true" : "false", _ => "");
    return "";
}

private bool numericValue(LuaValue value, out double number) {
    if (isInteger(value)) {
        number = value.match!((long n) => cast(double) n, _ => 0.0);
        return true;
    }
    if (isFloat(value)) {
        number = value.match!((double d) => d, _ => 0.0);
        return true;
    }
    return false;
}

/// Renders a translation with the captured trace, in `locale` (its plural rules). Returns false
/// when the trace lacks what the translation asks for (a condition the source never evaluated, a
/// variant name the source's drawn option does not have): the caller then uses the source text,
/// as a whole.
bool renderTranslation(TranslationTemplate template_, LuaValue[string] bindings, string delegate(LuaValue) display,
        ref const RenderTrace trace, string locale, out string output) {
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
                    // A translation may reorder named alternatives: the drawn one is found by name.
                    if (groupIndex < trace.variantNames.length && trace.variantNames[groupIndex].length) {
                        bool found;
                        foreach (i, name; node.names)
                            if (name == trace.variantNames[groupIndex]) {
                                chosen = i;
                                found = true;
                            }
                        if (!found && node.names.length && node.names[0].length)
                            failed = true;
                    }
                    if (chosen >= node.options.length)
                        chosen = 0;
                } else if (trace.recorded && trace.variants.length)
                    failed = true;
                ++groupIndex;
                if (node.options.length)
                    text ~= renderNodes(node.options[chosen]);
                break;
            case TNode.Kind.plural:
                double number;
                string category = "other";
                if (numericValue(bindings.get(node.text, luaNil()), number))
                    category = pluralCategory(locale, number);
                bool chose;
                foreach (i, label; node.names)
                    if (label == category) {
                        text ~= renderNodes(node.options[i]);
                        chose = true;
                        break;
                    }
                if (!chose)
                    text ~= renderNodes(node.no);
                break;
            case TNode.Kind.select:
                auto key = selectKey(bindings.get(node.text, luaNil()));
                bool chose;
                foreach (i, label; node.names)
                    if (label == key) {
                        text ~= renderNodes(node.options[i]);
                        chose = true;
                        break;
                    }
                if (!chose)
                    text ~= renderNodes(node.no);
                break;
            }
        }
        return text;
    }

    output = renderNodes(template_.nodes);
    return !failed;
}
