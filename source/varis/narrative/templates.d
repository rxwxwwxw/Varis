/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.templates;

import varis.types;
import varis.state;
import varis.ast;
import varis.parser;
import varis.compiler;
import varis.vm;
import varis.logic.world;
import varis.logic.model : RelTuple;
import varis.narrative.translation : RenderTrace, normalizeCondition, variantArguments;
import varis.narrative.plural : pluralCategory, isPluralCategory;
import varis.exception : LuaException;
import std.string : strip, startsWith, split;
import std.algorithm : canFind;
import std.conv : to;
import std.math : isFinite;

class VariantOption {
    double weight = 1.0;
    string name; // optional, from `{#variant 3 name}`: what a translation and the replay log call it
    TemplateNode[] nodes;
}

private bool isChoiceTag(string token) {
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

/// The weight and name of a `{#variant ...}` tag's arguments; raises a language error otherwise.
private void variantWeightAndName(string arguments, out double weight, out string name) {
    string weightText;
    foreach (word; arguments.strip.split) {
        if (word.length > 7 && word[0 .. 7] == "weight=") {
            auto rest = word[7 .. $];
            bool numeric = rest.length > 0;
            foreach (char c; rest)
                if (!((c >= '0' && c <= '9') || c == '.'))
                    numeric = false;
            if (!numeric)
                throw new LuaException("variant weight must be numeric");
        }
    }
    if (!variantArguments(arguments, weightText, name))
        throw new LuaException("variant takes a positive weight and a name");
    weight = 1.0;
    if (weightText.length) {
        try {
            weight = weightText.to!double;
        } catch (Exception) {
            throw new LuaException("variant weight must be numeric");
        }
    }
    if (weight <= 0.0 || !isFinite(weight))
        throw new LuaException("variant weight must be positive and finite");
}

/// A `{#plural n}` or `{#select v}` branch.
private class ChoiceBranch {
    string label;
    TemplateNode[] nodes;
}

class VariantGroup {
    VariantOption[] options;
}

private class TemplateNode {
    string literal;
    string parameter;
    LuaValue condition;
    string conditionSource; // normalized `query ...` or `lua ...` text, for render traces
    bool luaCondition;
    TemplateNode[] yes;
    TemplateNode[] no;
    VariantGroup variantGroup;
    // `{#plural n}` and `{#select v}`: the parameter, the labelled branches and the required
    // `{#other}` or `{#default}` branch.
    string choiceParameter;
    bool choiceIsPlural;
    ChoiceBranch[] choiceBranches;
    TemplateNode[] choiceDefault;
    bool isChoice;
}

/// Parsed content-only interpolation; ordinary Lua strings are unchanged.
class NarrativeTemplate {
    private TemplateNode[] nodes;
    private string[] parameters;
    VariantGroup[] variantGroups;

    this(string text, string[] parameters) {
        this.parameters = parameters.dup;
        size_t cursor;
        string terminator;
        nodes = parseNodes(text, cursor, terminator, false);
        if (terminator.length)
            throw new LuaException("unexpected template conditional terminator");
    }

    private TemplateNode[] parseNodes(string text, ref size_t cursor, out string terminator, bool insideVariant = false,
            bool insideChoice = false) {
        TemplateNode[] result;
        string literal;
        void flush() {
            if (!literal.length)
                return;
            auto node = new TemplateNode();
            node.literal = literal;
            result ~= node;
            literal = "";
        }

        while (cursor < text.length) {
            if (cursor + 1 < text.length && text[cursor .. cursor + 2] == "{{") {
                literal ~= "{";
                cursor += 2;
                continue;
            }
            if (cursor + 1 < text.length && text[cursor .. cursor + 2] == "}}") {
                literal ~= "}";
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
            // Skip Lua lexemes before looking for the template's closing brace.
            // Queries can contain tables, strings and comments with literal braces.
            bool skipLongBracket() {
                if (text[cursor] != '[')
                    return false;
                size_t opening = cursor, end = cursor + 1;
                while (end < text.length && text[end] == '=')
                    end++;
                if (end == text.length || text[end] != '[')
                    return false;
                string closing = "]" ~ text[opening + 1 .. end] ~ "]";
                cursor = end + 1;
                while (cursor + closing.length <= text.length) {
                    if (text[cursor .. cursor + closing.length] == closing) {
                        cursor += closing.length;
                        return true;
                    }
                    cursor++;
                }
                throw new LuaException("unterminated long bracket in narrative template condition");
            }

            while (cursor < text.length) {
                char c = text[cursor];
                if (c == '\"' || c == '\'') {
                    auto quote = c;
                    cursor++;
                    while (cursor < text.length && text[cursor] != quote) {
                        if (text[cursor] == '\\' && cursor + 1 < text.length)
                            cursor++;
                        cursor++;
                    }
                    if (cursor == text.length)
                        break;
                    cursor++;
                    continue;
                }
                if (c == '[' && skipLongBracket())
                    continue;
                if (c == '-' && cursor + 1 < text.length && text[cursor + 1] == '-') {
                    cursor += 2;
                    if (cursor < text.length && text[cursor] == '[' && skipLongBracket())
                        continue;
                    while (cursor < text.length && text[cursor] != '\n' && text[cursor] != '\r')
                        cursor++;
                    continue;
                }
                if (c == '{')
                    braces++;
                else if (c == '}' && braces == 0)
                    break;
                else if (c == '}')
                    braces--;
                cursor++;
            }
            if (cursor >= text.length)
                throw new LuaException("unterminated narrative template placeholder");
            string token = text[start .. cursor++].strip;
            if (token == "#else" || token == "/if" || token == "/variant" || token == "/variants") {
                terminator = token;
                return result;
            }
            if (insideVariant && token.length >= 8 && token[0 .. 8] == "#variant") {
                terminator = token;
                return result;
            }
            if (insideChoice && isChoiceTag(token)) {
                terminator = token;
                return result;
            }
            auto node = new TemplateNode();
            if (token.length > 4 && token[0 .. 4] == "#if ") {
                string condition = token[4 .. $].strip;
                bool luaExpression = condition.length > 4 && condition[0 .. 4] == "lua ";
                if (!luaExpression && (condition.length < 6 || condition[0 .. 6] != "query "))
                    throw new LuaException("template condition must be {#if query ...} or {#if lua ...}");
                // `lua EXPR`: a read-only Lua expression over the parameters, true by Lua truthiness.
                auto parser = new Parser(luaExpression ? "return (" ~ condition[4 .. $] ~ ")" : "return " ~ condition);
                auto conditionBlock = parser.parse();
                if (conditionBlock is null)
                    throw parser.error; // the narrative layer still reports by exception
                LuaException compileFailure;
                auto prototype = Compiler.contextPrototype(conditionBlock, parameters, parameters, compileFailure);
                if (prototype is null)
                    throw compileFailure;
                node.condition = LuaValue(new LuaClosure(prototype));
                node.luaCondition = luaExpression;
                node.conditionSource = normalizeCondition(condition);
                string ending;
                node.yes = parseNodes(text, cursor, ending, insideVariant);
                if (ending == "#else")
                    node.no = parseNodes(text, cursor, ending, insideVariant);
                if (ending != "/if")
                    throw new LuaException("template conditional requires {/if}");
            } else if (token.length > 8 && (token[0 .. 8] == "#plural " || token[0 .. 8] == "#select ")) {
                bool plural = token[1] == 'p';
                string parameter = token[8 .. $].strip;
                if (!parameters.canFind(parameter))
                    throw new LuaException("unknown narrative template placeholder '" ~ parameter ~ "'");
                node.isChoice = true;
                node.choiceIsPlural = plural;
                node.choiceParameter = parameter;
                string closing = plural ? "/plural" : "/select";
                string tag;
                auto before = parseNodes(text, cursor, tag, insideVariant, true);
                foreach (b; before)
                    if (b.literal.strip.length || b.parameter.length || isFunction(b.condition) || b
                            .variantGroup !is null
                            || b.isChoice)
                        throw new LuaException("template {" ~ token[0 .. 7] ~ "} may contain only branches");
                bool haveDefault;
                while (tag != closing) {
                    if (tag.length == 0)
                        throw new LuaException("template {" ~ token[0 .. 7] ~ "} requires {" ~ closing ~ "}");
                    string label;
                    bool isDefault;
                    if (plural) {
                        if (tag == "#other")
                            isDefault = true;
                        else if (tag.length > 1 && tag[0] == '#' && isPluralCategory(tag[1 .. $]))
                            label = tag[1 .. $];
                        else
                            throw new LuaException("unexpected {" ~ tag ~ "} in {#plural}");
                    } else {
                        if (tag == "#default")
                            isDefault = true;
                        else if (tag.length > 6 && tag[0 .. 6] == "#case ")
                            label = tag[6 .. $].strip;
                        else
                            throw new LuaException("unexpected {" ~ tag ~ "} in {#select}");
                    }
                    string next;
                    auto branchNodes = parseNodes(text, cursor, next, insideVariant, true);
                    if (isDefault) {
                        if (haveDefault)
                            throw new LuaException("{" ~ tag ~ "} appears twice");
                        haveDefault = true;
                        node.choiceDefault = branchNodes;
                    } else {
                        foreach (existing; node.choiceBranches)
                            if (existing.label == label)
                                throw new LuaException("{" ~ tag ~ "} appears twice");
                        auto branch = new ChoiceBranch();
                        branch.label = label;
                        branch.nodes = branchNodes;
                        node.choiceBranches ~= branch;
                    }
                    tag = next;
                }
                if (!haveDefault)
                    throw new LuaException(plural ? "template {#plural} requires {#other}"
                            : "template {#select} requires {#default}");
            } else if (token == "#variants") {
                auto group = new VariantGroup();
                string nextTag;
                while (cursor < text.length) {
                    parseNodes(text, cursor, nextTag, true);
                    if (nextTag == "/variants")
                        break;
                    if (nextTag.length >= 8 && nextTag[0 .. 8] == "#variant") {
                        double w;
                        string optionName;
                        variantWeightAndName(nextTag[8 .. $], w, optionName);
                        string optEnding;
                        auto optNodes = parseNodes(text, cursor, optEnding, true);
                        auto opt = new VariantOption();
                        opt.weight = w;
                        opt.name = optionName;
                        opt.nodes = optNodes;
                        group.options ~= opt;
                        if (optEnding == "/variants")
                            break;
                        if (optEnding != "/variant" && !(optEnding.length >= 8 && optEnding[0 .. 8] == "#variant"))
                            throw new LuaException("template variant requires {/variant}");
                        if (optEnding.length >= 8 && optEnding[0 .. 8] == "#variant") {
                            nextTag = optEnding;
                            // continue with this tag directly
                            double innerW;
                            string innerName;
                            variantWeightAndName(nextTag[8 .. $], innerW, innerName);
                            auto innerOptNodes = parseNodes(text, cursor, optEnding, true);
                            auto innerOpt = new VariantOption();
                            innerOpt.weight = innerW;
                            innerOpt.name = innerName;
                            innerOpt.nodes = innerOptNodes;
                            group.options ~= innerOpt;
                            if (optEnding == "/variants")
                                break;
                        }
                    } else {
                        throw new LuaException("unexpected token in {#variants}: " ~ nextTag);
                    }
                }
                if (group.options.length == 0)
                    throw new LuaException("empty {#variants} block");
                node.variantGroup = group;
                variantGroups ~= group;
            } else if (token.length >= 8 && token[0 .. 8] == "#variant") {
                auto group = new VariantGroup();
                string currentTag = token;
                while (currentTag.length >= 8 && currentTag[0 .. 8] == "#variant") {
                    double w;
                    string optionName;
                    variantWeightAndName(currentTag[8 .. $], w, optionName);
                    string ending;
                    auto optNodes = parseNodes(text, cursor, ending, true);
                    auto opt = new VariantOption();
                    opt.weight = w;
                    opt.name = optionName;
                    opt.nodes = optNodes;
                    group.options ~= opt;
                    if (ending == "#else") {
                        string elseEnding;
                        auto elseNodes = parseNodes(text, cursor, elseEnding, true);
                        auto elseOpt = new VariantOption();
                        elseOpt.weight = 1.0;
                        elseOpt.nodes = elseNodes;
                        group.options ~= elseOpt;
                        if (elseEnding != "/variant")
                            throw new LuaException("template variant requires {/variant}");
                        currentTag = "";
                        break;
                    }
                    if (ending == "/variant") {
                        currentTag = "";
                        break;
                    }
                    if (ending.length >= 8 && ending[0 .. 8] == "#variant") {
                        currentTag = ending;
                        continue;
                    }
                    throw new LuaException("template variant requires {/variant}");
                }
                node.variantGroup = group;
                variantGroups ~= group;
            } else {
                // `{$name}` shows the story variable `name` (narrative.var / the `var` statement).
                bool variable = token.length > 1 && token[0] == '$';
                if (!variable && !parameters.canFind(token))
                    throw new LuaException("unknown narrative template placeholder '" ~ token ~ "'");
                node.parameter = token;
            }
            result ~= node;
        }
        flush();
        terminator = "";
        return result;
    }

    /// Renders the template. When `trace` is given it receives what was looked at: the result of
    /// each condition and the option drawn for each variant group, in the order encountered, so
    /// that a translation of this message can be rendered without evaluating anything again.
    string render(LuaState state, World snapshot, LuaValue[string] bindings, string delegate(LuaValue) display, const(
            size_t)[] variantSelections = null, RenderTrace* trace = null, string locale = "en") {
        beginReadOnlyEvaluation();
        scope (exit)
            endReadOnlyEvaluation();
        snapshot.readOnlyDepth++;
        scope (exit)
            snapshot.readOnlyDepth--;
        size_t groupIndex = 0;
        string renderNodes(TemplateNode[] nodes) {
            string output;
            foreach (node; nodes) {
                output ~= node.literal;
                if (node.parameter.length && node.parameter[0] == '$') {
                    LuaValue value;
                    if (auto relation = snapshot.getRelation("var")) {
                        auto row = RelTuple([state.getSymbol(node.parameter[1 .. $])]) in relation.keyIndex;
                        if (row !is null)
                            value = row.values[1];
                    }
                    if (trace !is null)
                        trace.vars[node.parameter] = value;
                    output ~= display(value);
                } else if (node.parameter.length)
                    output ~= display(bindings.get(node.parameter, luaNil()));
                if (isFunction(node.condition)) {
                    LuaValue[] arguments = [wrapWorld(snapshot)];
                    foreach (name; parameters)
                        arguments ~= bindings.get(name, luaNil());
                    auto iterator = VM.callValue(state, node.condition, arguments);
                    bool exists;
                    if (node.luaCondition)
                        exists = iterator.length && iterator[0].isTruthy();
                    else {
                        auto records = VM.callValue(state, iterator[0], []);
                        exists = records.length && !isNil(records[0]);
                    }
                    if (trace !is null)
                        trace.conditions[node.conditionSource] = exists;
                    output ~= renderNodes(exists ? node.yes : node.no);
                }
                if (node.isChoice) {
                    auto value = bindings.get(node.choiceParameter, luaNil());
                    TemplateNode[] chosen = node.choiceDefault;
                    string key;
                    if (node.choiceIsPlural) {
                        key = "other";
                        if (isInteger(value))
                            key = pluralCategory(locale, value.match!((long n) => cast(double) n, _ => 0.0));
                        else if (isFloat(value))
                            key = pluralCategory(locale, value.match!((double d) => d, _ => 0.0));
                    } else if (isSymbol(value))
                        key = value.match!((Symbol symbol) => symbol.name, _ => "");
                    else if (isString(value))
                        key = value.match!((string t) => t, _ => "");
                    else if (isInteger(value))
                        key = value.match!((long n) => n.to!string, _ => "");
                    else if (isBoolean(value))
                        key = value.match!((bool b) => b ? "true" : "false", _ => "");
                    foreach (branch; node.choiceBranches)
                        if (branch.label == key) {
                            chosen = branch.nodes;
                            break;
                        }
                    output ~= renderNodes(chosen);
                }
                if (node.variantGroup !is null) {
                    size_t optIdx = 0;
                    if (groupIndex < variantSelections.length) {
                        optIdx = variantSelections[groupIndex];
                        if (optIdx >= node.variantGroup.options.length)
                            optIdx = 0;
                    } else {
                        double bestWeight = -1.0;
                        foreach (i, opt; node.variantGroup.options) {
                            if (opt.weight > bestWeight) {
                                bestWeight = opt.weight;
                                optIdx = i;
                            }
                        }
                    }
                    groupIndex++;
                    if (trace !is null) {
                        trace.variants ~= optIdx;
                        trace.variantNames ~= node.variantGroup.options[optIdx].name;
                    }
                    output ~= renderNodes(node.variantGroup.options[optIdx].nodes);
                }
            }
            return output;
        }

        if (trace !is null)
            trace.recorded = true;
        return renderNodes(nodes);
    }
}
