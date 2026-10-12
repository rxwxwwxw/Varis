/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.registry;

import varis.types;
import varis.logic.model;
import varis.state;
import varis.narrative.codec;
import varis.narrative.templates;
import varis.vm : VM;
import varis.exception : LuaException;
import std.conv : to;
import std.math : isFinite;
import std.algorithm : sort;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

class ContentDefinition {
    string kind;
    string id;
    string[] parameters;
    string[] incomingParameters;
    string[] groundedParameters;
    LuaValue availability;
    LuaValue effect;
    LuaValue[string] options;
    ContentDefinition[] choices;
    NarrativeTemplate titleTemplate;
    NarrativeTemplate textTemplate;
    string fingerprint;

    LuaValue option(string key, LuaValue fallback = LuaValue.init) {
        return options.get(key, fallback);
    }

    long integerOption(string key, long fallback) {
        return option(key, LuaValue(fallback)).match!((long n) => n, _ => fallback);
    }

    bool sticky() {
        return option("sticky", LuaValue(false)).match!((bool b) => b, _ => false);
    }

    string symbolOption(string key, string fallback) {
        return option(key, LuaValue(Symbol(fallback))).match!((Symbol symbol) => symbol.name, _ => fallback);
    }
}

struct DeckDefinition {
    long draw = 1;
    bool replacement = true;
}

class QualityDefinition {
    string id;
    LuaValue initial;
    LuaValue minimum;
    LuaValue maximum;
    bool visible = true;
    string label;
}

/// State-owned immutable-after-sealing authored content, independent of worlds.
class ContentRegistry {
    LuaState state;
    private ContentDefinition[string] storylets_;
    private ContentDefinition[string] actions_;
    private DeckDefinition[string] decks_;
    private QualityDefinition[string] qualities_;
    private string[string] names_;
    private LuaValue[string] handlers_;
    private LuaValue[string] formatters_;
    private bool sealed_;
    string contentVersion;
    bool explicitContentVersion;
    // Last result of portableRegistryFingerprint and the entries it was computed from.
    string[] fingerprintEntries;
    string fingerprintDigest;

    this(LuaState state) {
        this.state = state;
        decks_["default"] = DeckDefinition();
    }

    bool sealed() {
        return sealed_;
    }

    void requireOpen() {
        import varis.logic.world : currentTransaction, isReadOnlyEvaluation;

        if (isReadOnlyEvaluation())
            throw new LuaException("content registration prohibited during read-only narrative evaluation");
        if (sealed_)
            throw new LuaException("narrative registry is sealed");
        if (currentTransaction() !is null)
            throw new LuaException("content registration prohibited during a transaction");
    }

    ContentDefinition[] storylets() {
        return storylets_.values;
    }

    ContentDefinition[] actions() {
        return actions_.values;
    }

    ContentDefinition storylet(string id) {
        return storylets_.get(id, null);
    }

    ContentDefinition action(string id) {
        return actions_.get(id, null);
    }

    QualityDefinition quality(string id) {
        return qualities_.get(id, null);
    }

    string[] handlerNames() {
        return handlers_.keys;
    }

    LuaValue handler(string id) {
        return handlers_.get(id, luaNil());
    }

    DeckDefinition deck(string id) {
        if (auto existing = id in decks_)
            return *existing;
        throw new LuaException("unknown narrative deck '" ~ id ~ "'");
    }

    void registerContent(ContentDefinition definition) {
        requireOpen();
        if (definition.kind != "storylet" && definition.kind != "action")
            throw new LuaException("invalid content kind");
        auto registry = definition.kind == "storylet" ? &storylets_ : &actions_;
        if (definition.id in *registry)
            throw new LuaException("duplicate " ~ definition.kind ~ " identifier '" ~ definition.id ~ "'");
        (*registry)[definition.id] = definition;
    }

    private bool[string] explicitDecks;
    void registerDeck(string id, DeckDefinition definition) {
        requireOpen();
        if (id in explicitDecks)
            throw new LuaException("duplicate deck identifier '" ~ id ~ "'");
        if (definition.draw <= 0)
            throw new LuaException("deck draw must be a positive integer");
        explicitDecks[id] = true;
        decks_[id] = definition;
    }

    void registerQuality(QualityDefinition definition) {
        requireOpen();
        if (definition.id in qualities_)
            throw new LuaException("duplicate quality identifier '" ~ definition.id ~ "'");
        import varis.logic.model : RelTuple;

        if ((!isNil(definition.minimum) && !isNumber(definition.minimum)) || (!isNil(definition.maximum) && !isNumber(
                definition.maximum)))
            throw new LuaException("quality bounds must be numeric");
        foreach (bound; [definition.minimum, definition.maximum])
            if (isNumber(bound) && !isFinite(bound.match!((long n) => cast(double) n, (double n) => n, _ => 0.0)))
                throw new LuaException("quality bounds must be finite");
        if (!isNil(definition.minimum) && !isNil(definition.maximum) && luaNumberLess(definition.maximum, definition
                .minimum))
            throw new LuaException("quality minimum exceeds maximum");
        validateQualityValue(definition, definition.initial);
        qualities_[definition.id] = definition;
    }

    private void validateQualityValue(QualityDefinition definition, LuaValue value) {
        canonicalScalar(value);
        if (!isNil(definition.minimum) || !isNil(definition.maximum)) {
            if (!isNumber(value))
                throw new LuaException("bounded quality requires a numeric value: " ~ definition.id);
            if (!isNil(definition.minimum) && luaNumberLess(value, definition.minimum))
                throw new LuaException("quality value below minimum: " ~ definition.id);
            if (!isNil(definition.maximum) && luaNumberLess(definition.maximum, value))
                throw new LuaException("quality value above maximum: " ~ definition.id);
        }
    }

    void validateQualityTuple(varis.logic.model.RelTuple tuple) {
        if (tuple.length != 3 || !isSymbol(tuple.values[1]))
            throw new LuaException("quality name must be a symbol");
        auto id = tuple.values[1].match!((Symbol s) => s.name, _ => "");
        auto definition = quality(id);
        if (definition is null)
            throw new LuaException("unknown quality '" ~ id ~ "'");
        validateQualityValue(definition, tuple.values[2]);
    }

    string[] nameIds() {
        return names_.keys;
    }

    string name(string id) {
        return names_.get(id, "");
    }

    void registerName(string id, string name) {
        requireOpen();
        names_[id] = name;
    }

    void registerHandler(string id, LuaValue handler) {
        requireOpen();
        if (!isFunction(handler))
            throw new LuaException("narrative event handler must be a function");
        if (id in handlers_)
            throw new LuaException("duplicate narrative handler '" ~ id ~ "'");
        handlers_[id] = handler;
    }

    void registerFormatter(string key, LuaValue formatter) {
        requireOpen();
        if (!isFunction(formatter))
            throw new LuaException("narrative formatter must be a function");
        if (key in formatters_)
            throw new LuaException("duplicate narrative formatter '" ~ key ~ "'");
        formatters_[key] = formatter;
    }

    string[] formatterKeys() {
        return formatters_.keys;
    }

    LuaValue formatter(string key) {
        return formatters_.get(key, luaNil());
    }

    string display(LuaValue value) {
        if (isNil(value)) {
            if ("nil" in formatters_) {
                auto res = VM.callValue(state, formatters_["nil"], [value]);
                if (res.length && isString(res[0]))
                    return res[0].match!((string s) => s, _ => "");
            }
            if ("default" in formatters_) {
                auto res = VM.callValue(state, formatters_["default"], [value]);
                if (res.length && isString(res[0]))
                    return res[0].match!((string s) => s, _ => "");
            }
            return "";
        }
        if (isSymbol(value)) {
            string id = value.match!((Symbol symbol) => symbol.name, _ => "");
            if (id in formatters_) {
                auto res = VM.callValue(state, formatters_[id], [value]);
                if (res.length && isString(res[0]))
                    return res[0].match!((string s) => s, _ => "");
            }
            if (auto name = id in names_)
                return *name;
            if ("symbol" in formatters_) {
                auto res = VM.callValue(state, formatters_["symbol"], [value]);
                if (res.length && isString(res[0]))
                    return res[0].match!((string s) => s, _ => "");
            }
            if ("default" in formatters_) {
                auto res = VM.callValue(state, formatters_["default"], [value]);
                if (res.length && isString(res[0]))
                    return res[0].match!((string s) => s, _ => "");
            }
            return id;
        }
        string typeKey = value.match!(
                (bool _) => "boolean",
                (long _) => "number",
                (double _) => "number",
                (string _) => "string",
                _ => "other"
        );
        if (typeKey in formatters_) {
            auto res = VM.callValue(state, formatters_[typeKey], [value]);
            if (res.length && isString(res[0]))
                return res[0].match!((string s) => s, _ => "");
        }
        if ("default" in formatters_) {
            auto res = VM.callValue(state, formatters_["default"], [value]);
            if (res.length && isString(res[0]))
                return res[0].match!((string s) => s, _ => "");
        }
        return toLuaString(value);
    }

    private void validateContent(ContentDefinition definition) {
        import std.algorithm : canFind;

        bool[string] parameters;
        foreach (parameter; definition.incomingParameters ~ definition.parameters) {
            if (parameter in parameters)
                throw new LuaException("duplicate content parameter '" ~ parameter ~ "'");
            parameters[parameter] = true;
        }
        foreach (parameter; definition.parameters)
            if (!definition.groundedParameters.canFind(parameter))
                throw new LuaException(
                        "unbound " ~ definition.kind ~ " parameter '?" ~ parameter ~ "' in '" ~ definition.id ~ "'");
        auto priority = definition.option("priority", LuaValue(0L));
        if (!isInteger(priority))
            throw new LuaException("content priority must be an integer: " ~ definition.id);
        if (definition.kind == "storylet") {
            deck(definition.symbolOption("deck", "default"));
            auto weight = definition.option("weight", LuaValue(1L));
            double number = weight.match!((long n) => cast(double) n, (double n) => n, _ => -1.0);
            if (!isNumber(weight) || !isFinite(number) || number < 0)
                throw new LuaException("storylet weight must be finite and nonnegative: " ~ definition.id);
            auto cooldown = definition.option("cooldown", LuaValue(0L));
            if (!isInteger(cooldown) || cooldown.match!((long n) => n, _ => -1L) < 0)
                throw new LuaException("storylet cooldown must be a nonnegative integer");
            if (!isBoolean(definition.option("repeatable", LuaValue(true))))
                throw new LuaException("storylet repeatable must be Boolean");
            if (!isBoolean(definition.option("sticky", LuaValue(false))))
                throw new LuaException("storylet sticky must be Boolean");
            if (!isInteger(definition.option("order", LuaValue(0L))))
                throw new LuaException("storylet order must be an integer");
            if (!isSymbol(definition.option("deck", LuaValue(Symbol("default")))))
                throw new LuaException("storylet deck must be a symbol");
            if (!definition.choices.length)
                throw new LuaException("storylet requires at least one choice: " ~ definition.id);
            bool[string] choices;
            foreach (choice; definition.choices) {
                if (choice.id in choices)
                    throw new LuaException("duplicate choice identifier '" ~ choice.id ~ "'");
                choices[choice.id] = true;
                validateContent(choice);
            }
        } else if (definition.kind == "action") {
            string phase = definition.symbolOption("phase", "post");
            if (!isSymbol(definition.option("phase", LuaValue(Symbol("post")))) || (phase != "pre" && phase != "post"))
                throw new LuaException("action phase must be :pre or :post");
            if (!isSymbol(definition.option("once_per", LuaValue(Symbol("turn")))))
                throw new LuaException("action once_per must be a symbol");
        }
        if (definition.kind != "storylet" && !isFunction(definition.effect))
            throw new LuaException("content effect is required: " ~ definition.id);
        if (definition.kind == "storylet" && !isString(definition.option("title")))
            throw new LuaException("storylet title is required: " ~ definition.id);
        foreach (field; ["title", "text"]) {
            auto value = definition.option(field, LuaValue(""));
            if (!isString(value))
                throw new LuaException("content template must be a string");
            auto parsed = new NarrativeTemplate(value.match!((string text) => text, _ => ""), definition
                    .incomingParameters ~ definition.parameters);
            if (field == "title")
                definition.titleTemplate = parsed;
            else
                definition.textTemplate = parsed;
        }
    }

    /// Copy into an already allocated registry shell, preserving capture cycles.
    void copyForAnalysis(ContentRegistry destination, LuaValue delegate(LuaValue) cloneValue,
            ContentDefinition delegate(ContentDefinition) cloneDefinition) {
        destination.contentVersion = contentVersion;
        destination.explicitContentVersion = explicitContentVersion;
        destination.decks_ = decks_.dup;
        destination.explicitDecks = explicitDecks.dup;
        destination.names_ = names_.dup;
        foreach (name, definition; qualities_) {
            auto copied = new QualityDefinition();
            copied.id = definition.id;
            copied.initial = cloneValue(definition.initial);
            copied.minimum = cloneValue(definition.minimum);
            copied.maximum = cloneValue(definition.maximum);
            copied.visible = definition.visible;
            copied.label = definition.label;
            destination.qualities_[name] = copied;
        }
        foreach (name, definition; storylets_)
            destination.storylets_[name] = cloneDefinition(definition);
        foreach (name, definition; actions_)
            destination.actions_[name] = cloneDefinition(definition);
        foreach (name, handler; handlers_)
            destination.handlers_[name] = cloneValue(handler);
        destination.sealed_ = sealed_;
    }

    void seal(string authoredVersion = "") {
        if (sealed_) {
            if (authoredVersion.length && authoredVersion != contentVersion)
                throw new LuaException("registry already sealed with another version");
            return;
        }
        foreach (definition; storylets_.values ~ actions_.values)
            validateContent(definition);
        string[] manifests;
        foreach (definition; storylets_.values ~ actions_.values)
            manifests ~= definition.kind ~ ":" ~ definition.id ~ ":" ~ definition.fingerprint;
        foreach (name, definition; decks_)
            manifests ~= "deck:" ~ name ~ ":" ~ definition.draw.to!string ~ ":" ~ definition.replacement.to!string;
        foreach (name, definition; qualities_) {
            manifests ~= "quality:" ~ name ~ ":" ~ canonicalScalar(definition.initial) ~ ":" ~ canonicalScalar(
                    definition.minimum) ~ ":" ~ canonicalScalar(
                    definition.maximum) ~ ":" ~ definition.visible.to!string ~ ":" ~ definition.label;
        }
        foreach (name, label; names_)
            manifests ~= "name:" ~ name ~ ":" ~ label;
        foreach (name; handlers_.keys)
            manifests ~= "handler:" ~ name;
        manifests.sort;
        string manifest;
        foreach (entry; manifests)
            manifest ~= entry.length.to!string ~ ":" ~ entry;
        explicitContentVersion = authoredVersion.length != 0;
        contentVersion = authoredVersion.length ? authoredVersion : manifest.sha256Of.toHexString.idup;
        sealed_ = true;
    }
}
