/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.narrative.templates;

import dlua.types;
import dlua.state;
import dlua.ast;
import dlua.parser;
import dlua.compiler;
import dlua.vm;
import dlua.logic.world;
import dlua.exception : LuaException;
import std.string : strip, startsWith;
import std.algorithm : canFind;
import std.conv : to;
import std.math : isFinite;

class VariantOption {
    double weight = 1.0;
    TemplateNode[] nodes;
}

class VariantGroup {
    VariantOption[] options;
}

private class TemplateNode {
    string literal;
    string parameter;
    LuaValue condition;
    TemplateNode[] yes;
    TemplateNode[] no;
    VariantGroup variantGroup;
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

    private TemplateNode[] parseNodes(string text, ref size_t cursor, out string terminator, bool insideVariant = false) {
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
            auto node = new TemplateNode();
            if (token.length > 4 && token[0 .. 4] == "#if ") {
                string condition = token[4 .. $].strip;
                if (condition.length < 6 || condition[0 .. 6] != "query ")
                    throw new LuaException("template condition must be a query existence test");
                auto parser = new Parser("return " ~ condition);
                auto prototype = Compiler.contextPrototype(parser.parse(), parameters, parameters);
                node.condition = LuaValue(new LuaClosure(prototype));
                string ending;
                node.yes = parseNodes(text, cursor, ending, insideVariant);
                if (ending == "#else")
                    node.no = parseNodes(text, cursor, ending, insideVariant);
                if (ending != "/if")
                    throw new LuaException("template conditional requires {/if}");
            } else if (token == "#variants") {
                auto group = new VariantGroup();
                string nextTag;
                while (cursor < text.length) {
                    parseNodes(text, cursor, nextTag, true);
                    if (nextTag == "/variants")
                        break;
                    if (nextTag.length >= 8 && nextTag[0 .. 8] == "#variant") {
                        string arg = nextTag[8 .. $].strip;
                        double w = 1.0;
                        if (arg.length) {
                            if (arg.startsWith("weight="))
                                arg = arg[7 .. $].strip;
                            try {
                                w = arg.to!double;
                            } catch (Exception) {
                                throw new LuaException("variant weight must be numeric");
                            }
                        }
                        if (w <= 0.0 || !isFinite(w))
                            throw new LuaException("variant weight must be positive and finite");
                        string optEnding;
                        auto optNodes = parseNodes(text, cursor, optEnding, true);
                        auto opt = new VariantOption();
                        opt.weight = w;
                        opt.nodes = optNodes;
                        group.options ~= opt;
                        if (optEnding == "/variants")
                            break;
                        if (optEnding != "/variant" && !(optEnding.length >= 8 && optEnding[0 .. 8] == "#variant"))
                            throw new LuaException("template variant requires {/variant}");
                        if (optEnding.length >= 8 && optEnding[0 .. 8] == "#variant") {
                            nextTag = optEnding;
                            // continue with this tag directly
                            string innerArg = nextTag[8 .. $].strip;
                            double innerW = 1.0;
                            if (innerArg.length) {
                                if (innerArg.startsWith("weight="))
                                    innerArg = innerArg[7 .. $].strip;
                                try {
                                    innerW = innerArg.to!double;
                                } catch (Exception) {
                                    throw new LuaException("variant weight must be numeric");
                                }
                            }
                            if (innerW <= 0.0 || !isFinite(innerW))
                                throw new LuaException("variant weight must be positive and finite");
                            auto innerOptNodes = parseNodes(text, cursor, optEnding, true);
                            auto innerOpt = new VariantOption();
                            innerOpt.weight = innerW;
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
                    string arg = currentTag[8 .. $].strip;
                    double w = 1.0;
                    if (arg.length) {
                        if (arg.startsWith("weight="))
                            arg = arg[7 .. $].strip;
                        try {
                            w = arg.to!double;
                        } catch (Exception) {
                            throw new LuaException("variant weight must be numeric");
                        }
                    }
                    if (w <= 0.0 || !isFinite(w))
                        throw new LuaException("variant weight must be positive and finite");
                    string ending;
                    auto optNodes = parseNodes(text, cursor, ending, true);
                    auto opt = new VariantOption();
                    opt.weight = w;
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
                if (!parameters.canFind(token))
                    throw new LuaException("unknown narrative template placeholder '" ~ token ~ "'");
                node.parameter = token;
            }
            result ~= node;
        }
        flush();
        terminator = "";
        return result;
    }

    string render(LuaState state, World snapshot, LuaValue[string] bindings, string delegate(LuaValue) display, const(
            size_t)[] variantSelections = null) {
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
                if (node.parameter.length)
                    output ~= display(bindings.get(node.parameter, luaNil()));
                if (isFunction(node.condition)) {
                    LuaValue[] arguments = [wrapWorld(snapshot)];
                    foreach (name; parameters)
                        arguments ~= bindings.get(name, luaNil());
                    auto iterator = VM.callValue(state, node.condition, arguments);
                    auto records = VM.callValue(state, iterator[0], []);
                    bool exists = records.length && !isNil(records[0]);
                    output ~= renderNodes(exists ? node.yes : node.no);
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
                    output ~= renderNodes(node.variantGroup.options[optIdx].nodes);
                }
            }
            return output;
        }

        return renderNodes(nodes);
    }
}
