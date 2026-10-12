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
import varis.narrative.persistence : canonicalJSON;
import varis.narrative.scenes;
import varis.narrative.templates;
import varis.narrative.translation;
import varis.vm : VM;
import varis.exception : LuaException;
import std.conv : to;
import std.math : isFinite;
import std.algorithm : sort;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

/// Installed by `varis.narrative.vmops`: computes `ContentDefinition.legacyFingerprint`.
__gshared string function(ContentDefinition) legacyFingerprintHook;

class ContentDefinition {
    string kind;
    string id;
    string[] parameters;
    string[] incomingParameters;
    string[] groundedParameters;
    LuaValue availability;
    /// The `require` query of a choice, over storylet and choice parameters; nil when absent.
    LuaValue requirement;
    LuaValue effect;
    LuaValue[string] options;
    ContentDefinition[] choices;
    NarrativeTemplate titleTemplate;
    NarrativeTemplate textTemplate;
    NarrativeTemplate becauseTemplate;
    string fingerprint;
    /// The identity first-format saves recorded: wording included. Computed on first use, by the
    /// hook the narrative layer installs; only reading a first-format save needs it.
    string legacyFingerprint() {
        if (legacyFingerprint_ is null && legacyFingerprintHook !is null)
            legacyFingerprint_ = legacyFingerprintHook(this);
        return legacyFingerprint_;
    }

    void legacyFingerprint(string value) {
        legacyFingerprint_ = value;
    }

    private string legacyFingerprint_;
    /// Lazily built by Session.instances (stage W5): a fact that must hold for this definition
    /// to have any instance, when its availability is a plain query. Not part of the content.
    Object availabilityFilter;
    bool availabilityFilterBuilt;

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

/// The state's content registry (the core keeps it as an opaque reference). Found by UFCS, so
/// `state.narrativeRegistry` reads and assigns as before.
ContentRegistry narrativeRegistry(LuaState state) {
    return cast(ContentRegistry) cast(void*) state.narrativeRegistryObject;
}

/// ditto
void narrativeRegistry(LuaState state, ContentRegistry registry) {
    state.narrativeRegistryObject = registry;
}

/// State-owned immutable-after-sealing authored content, independent of worlds.
class ContentRegistry {
    LuaState state;
    SceneDefinition[] scenes;
    CharacterDefinition[] characters;

    SceneDefinition* scene(string id) {
        foreach (ref definition; scenes)
            if (definition.id == id)
                return &definition;
        return null;
    }

    CharacterDefinition* character(string id) {
        foreach (ref definition; characters)
            if (definition.id == id)
                return &definition;
        return null;
    }

    string[] sceneIdentity() {
        string[] entries;
        foreach (definition; scenes) {
            auto beats = new LuaValue[definition.beats.length];
            foreach (i, beat; definition.beats)
                beats[i] = structural(beat);
            entries ~= "scene:" ~ definition.id ~ ":" ~ canonicalJSON(encodeValue(immutableSequence(beats)));
        }
        foreach (definition; characters)
            entries ~= "character:" ~ definition.id ~ ":" ~ canonicalJSON(
                    encodeValue(replaceField(definition.fields, "name", LuaValue.init)));
        return entries;
    }

    private ContentDefinition[string] storylets_;
    private ContentDefinition[string] actions_;
    private ContentDefinition[string] procedures_;
    private DeckDefinition[string] decks_;
    private QualityDefinition[string] qualities_;
    private string[string] names_;
    private TranslationTemplate[string][string] translations_; // locale -> key -> message
    private LuaValue[string] handlers_;
    private LuaValue[string] formatters_;
    private bool sealed_;
    string contentVersion;
    /// The language the authored text is written in (its plural rules apply to source templates).
    string sourceLanguage = "en";
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

    ContentDefinition[] procedures() {
        return procedures_.values;
    }

    ContentDefinition procedure(string id) {
        return procedures_.get(id, null);
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
        if (definition.kind != "storylet" && definition.kind != "action" && definition.kind != "procedure")
            throw new LuaException("invalid content kind");
        auto registry = definition.kind == "storylet" ? &storylets_ : definition.kind == "action" ? &actions_
            : &procedures_;
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

    /// Registers the translations of one locale. The whole set is rejected, with one problem per
    /// message (naming its key), when any message does not parse; nothing is registered then.
    /// Translations are presentation data: not content, not fingerprinted, not saved.
    string[] registerTranslations(string locale, string[string] messages) {
        string[] problems;
        TranslationTemplate[string] parsed;
        foreach (key, text; messages) {
            TranslationTemplate template_;
            string error;
            if (parseTranslation(text, template_, error))
                parsed[key] = template_;
            else
                problems ~= locale ~ " " ~ key ~ ": " ~ error;
        }
        if (problems.length == 0) {
            auto existing = locale in translations_;
            if (existing is null) {
                translations_[locale] = parsed;
            } else {
                foreach (key, template_; parsed)
                    (*existing)[key] = template_;
            }
        }
        problems.sort;
        return problems;
    }

    string[] languages() {
        auto names = translations_.keys;
        names.sort;
        return names;
    }

    /// The translation of a message in a locale, or null (the source text is used).
    TranslationTemplate translation(string locale, string key) {
        if (auto catalog = locale in translations_)
            return catalog.get(key, null);
        return null;
    }

    /// `display` in a locale: a symbol with a translated name (`name.keeper`) shows it.
    string displayIn(string locale, LuaValue value) {
        if (locale.length && isSymbol(value)) {
            string id = value.match!((Symbol symbol) => symbol.name, _ => "");
            if (auto catalog = locale in translations_)
                if (auto label = ("name." ~ id) in *catalog)
                    return label.literalText;
        }
        return display(value);
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
                try {
                    validateContent(choice);
                } catch (LuaException failure) {
                    if (failure.contentId.length == 0) {
                        failure.contentKind = "choice";
                        failure.contentId = choice.id;
                        failure.contentOwner = definition.id;
                    }
                    throw failure;
                }
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
        if (isFunction(definition.requirement) != isString(definition.option("because")))
            throw new LuaException("choice 'require' and 'because' go together: " ~ definition.id);
        if (isFunction(definition.requirement))
            definition.becauseTemplate = new NarrativeTemplate(definition.option("because")
                    .match!((string text) => text,
                        _ => ""), definition.incomingParameters ~ definition.parameters);
    }

    /// Copy into an already allocated registry shell, preserving capture cycles.
    void copyForAnalysis(ContentRegistry destination, LuaValue delegate(LuaValue) cloneValue,
            ContentDefinition delegate(ContentDefinition) cloneDefinition) {
        destination.scenes = scenes.dup;
        destination.characters = characters.dup;
        destination.contentVersion = contentVersion;
        destination.explicitContentVersion = explicitContentVersion;
        destination.decks_ = decks_.dup;
        destination.explicitDecks = explicitDecks.dup;
        destination.names_ = names_.dup;
        foreach (locale, catalog; translations_)
            destination.translations_[locale] = catalog.dup;
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
        foreach (name, definition; procedures_)
            destination.procedures_[name] = cloneDefinition(definition);
        foreach (name, handler; handlers_)
            destination.handlers_[name] = cloneValue(handler);
        destination.sealed_ = sealed_;
    }

    private static string manifestDigest(string[] entries) {
        entries.sort;
        string text;
        foreach (entry; entries)
            text ~= entry.length.to!string ~ ":" ~ entry;
        return text.sha256Of.toHexString.idup;
    }

    /// The content version as first-format saves recorded it, with wording in it. Computed on
    /// demand: only reading such a save needs it.
    string legacyContentVersion() {
        if (explicitContentVersion)
            return contentVersion;
        string[] entries;
        foreach (definition; storylets_.values ~ actions_.values)
            entries ~= definition.kind ~ ":" ~ definition.id ~ ":" ~ definition.legacyFingerprint;
        foreach (name, definition; decks_)
            entries ~= "deck:" ~ name ~ ":" ~ definition.draw.to!string ~ ":" ~ definition.replacement.to!string;
        foreach (name, definition; qualities_)
            entries ~= "quality:" ~ name ~ ":" ~ canonicalScalar(definition.initial) ~ ":" ~ canonicalScalar(
                    definition.minimum) ~ ":" ~ canonicalScalar(
                    definition.maximum) ~ ":" ~ definition.visible.to!string
                ~ ":" ~ definition.label;
        foreach (name, label; names_)
            entries ~= "name:" ~ name ~ ":" ~ label;
        foreach (name; handlers_.keys)
            entries ~= "handler:" ~ name;
        return manifestDigest(entries);
    }

    void seal(string authoredVersion = "") {
        if (sealed_) {
            if (authoredVersion.length && authoredVersion != contentVersion)
                throw new LuaException("registry already sealed with another version");
            return;
        }
        auto sceneProblem = validateScenes(this);
        if (sceneProblem.length)
            throw new LuaException(sceneProblem);
        foreach (definition; storylets_.values ~ actions_.values ~ procedures_.values) {
            try {
                validateContent(definition);
            } catch (LuaException failure) {
                if (failure.contentId.length == 0) {
                    failure.contentKind = definition.kind;
                    failure.contentId = definition.id;
                }
                throw failure;
            }
        }
        // The identity of the content: wording (titles, texts, names, labels) is not part of it.
        string[] manifests = sceneIdentity();
        foreach (definition; storylets_.values ~ actions_.values ~ procedures_.values)
            manifests ~= definition.kind ~ ":" ~ definition.id ~ ":" ~ definition.fingerprint;
        foreach (name, definition; decks_)
            manifests ~= "deck:" ~ name ~ ":" ~ definition.draw.to!string ~ ":" ~ definition.replacement.to!string;
        foreach (name, definition; qualities_)
            manifests ~= "quality:" ~ name ~ ":" ~ canonicalScalar(definition.initial) ~ ":" ~ canonicalScalar(
                    definition.minimum) ~ ":" ~ canonicalScalar(definition.maximum) ~ ":" ~ definition
                .visible.to!string;
        foreach (name, label; names_)
            manifests ~= "name:" ~ name;
        foreach (name; handlers_.keys)
            manifests ~= "handler:" ~ name;
        explicitContentVersion = authoredVersion.length != 0;
        contentVersion = authoredVersion.length ? authoredVersion : manifestDigest(manifests);
        sealed_ = true;
    }
}
