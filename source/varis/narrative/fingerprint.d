/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.fingerprint;

import varis.types;
import varis.logic.world;
import varis.narrative.persistence : canonicalJSON;
import varis.vm;
import varis.opcode;
import varis.narrative.registry;
import varis.narrative.codec;
import std.algorithm : sort;
import std.conv : to;

/// A prototype is immutable once compiled, so its fingerprint is computed once and kept on it.
/// (Captured values are not part of it; `portableFunctionFingerprint` reads those every time.)
string prototypeFingerprint(Prototype prototype) {
    if (prototype.fingerprintCache.length == 0)
        prototype.fingerprintCache = computePrototypeFingerprint(prototype);
    return prototype.fingerprintCache;
}

private string computePrototypeFingerprint(Prototype prototype) {
    string result = prototype.numParams.to!string ~ ":" ~ prototype.isVararg.to!string;
    foreach (instruction; prototype.code)
        result ~= ":" ~ instruction.toString();
    auto callPCs = prototype.callWorlds.keys;
    callPCs.sort;
    foreach (pc; callPCs)
        result ~= ":call-world:" ~ pc.to!string ~ ":" ~ prototype.callWorlds[pc].to!string;
    auto namedPCs = prototype.callNames.keys;
    namedPCs.sort;
    foreach (pc; namedPCs)
        result ~= ":call-name:" ~ pc.to!string ~ ":" ~ prototype.callNames[pc].name ~ ":" ~ prototype
            .callNames[pc].kind;
    foreach (local; prototype.debugLocals)
        result ~= ":local:" ~ local.name ~ ":" ~ local.register.to!string ~ ":" ~ local.startPC.to!string ~ ":" ~ local
            .endPC.to!string ~ ":" ~ local.readOnly.to!string;
    foreach (constant; prototype.constants)
        result ~= ":" ~ canonicalScalar(constant);
    foreach (upvalue; prototype.upvalues)
        result ~= ":upvalue:" ~ upvalue.name ~ ":" ~ upvalue.inStack.to!string ~ ":" ~ upvalue.index.to!string;
    foreach (schema; prototype.relationSchemas)
        result ~= ":schema:" ~ schema.columns.to!string ~ ":" ~ schema.keys.to!string;
    foreach (child; prototype.subPrototypes)
        result ~= ":" ~ prototypeFingerprint(child);
    void terms(TermTemplate[] terms) {
        foreach (term; terms)
            result ~= ":term:" ~ term.kind.to!string ~ ":" ~ term.varName ~ ":" ~ term.reg.to!string ~ ":" ~ term.varId.to!string ~ ":" ~ term.isStatic.to!string ~ (term.isStatic ? canonicalScalar(
                    term.staticVal) : "");
    }

    void goals(GoalTemplate[] goalTemplates) {
        foreach (goal; goalTemplates) {
            result ~= ":goal:" ~ goal.kind.to!string ~ ":" ~ goal.relName ~ ":" ~ goal.aggregateOp ~ ":" ~ goal
                .resultVariable ~ ":" ~ goal.compOp.to!string ~ ":" ~ goal.worldReg.to!string ~ ":" ~ goal
                .localRelReg.to!string;
            terms(goal.terms);
            terms([goal.leftTerm, goal.rightTerm]);
            goals(goal.aggregateGoals);
            result ~= ":metadata:" ~ goal.arity.to!string ~ ":" ~ goal.localRelUpval.to!string ~ ":" ~ goal
                .aggregateExpressionProto.to!string ~ ":" ~ goal.aggregateExpressionVariables.to!string ~ ":" ~ goal
                .guardSubProtoIdx.to!string ~ ":" ~ goal.guardVarNames.to!string ~ ":" ~ goal.guardVarIds.to!string;
        }
    }

    foreach (query; prototype.queryTemplates) {
        goals(query.goals);
        result ~= query.returnedVarNames.to!string ~ query.isBraced.to!string;
    }
    foreach (rule; prototype.ruleTemplates) {
        result ~= ":head:" ~ rule.headRelName;
        terms(rule.headTerms);
        goals(rule.bodyGoals);
    }
    return result;
}

/// The identity of a definition as saves of the first format knew it: every option, wording
/// included. Kept to read those saves; new saves use `contentFingerprint`.
string legacyContentFingerprint(ContentDefinition definition) {
    return definitionFingerprint(definition, true);
}

/// The gameplay identity of a definition (save format 2): its parameters and options, effects
/// and conditions, and the **structure** of its `title` and `text` (the conditions they embed and
/// the weights, names and parameters of their variants, plurals and selects), but not their
/// wording. A typo fix does not change it.
string contentFingerprint(ContentDefinition definition) {
    return definitionFingerprint(definition, false);
}

private string definitionFingerprint(ContentDefinition definition, bool legacy) {
    import varis.narrative.translation : parseTranslation, TranslationTemplate;

    string result = definition.kind ~ ":" ~ definition.id;
    foreach (parameter; definition.incomingParameters ~ definition.parameters)
        result ~= ":parameter:" ~ parameter;
    foreach (name; definition.exposed)
        result ~= ":expose:" ~ name;
    auto names = definition.options.keys;
    names.sort;
    foreach (name; names) {
        // Wording is not gameplay: a template contributes what it asks the engine to evaluate.
        if (!legacy && (name == "title" || name == "text" || name == "because")) {
            auto value = definition.options[name];
            if (isString(value)) {
                auto text = value.match!((string s) => s, _ => "");
                // Text with no tag has no structure; most titles are such.
                bool tagged;
                foreach (char c; text)
                    if (c == '{') {
                        tagged = true;
                        break;
                    }
                if (!tagged) {
                    result ~= ":template:" ~ name ~ ":";
                    continue;
                }
                TranslationTemplate parsed;
                string error;
                if (parseTranslation(text, parsed, error)) {
                    result ~= ":template:" ~ name ~ ":" ~ parsed.structure();
                    continue;
                }
            }
        }
        string encoded;
        try {
            encoded = canonicalScalar(definition.options[name]);
        } catch (Exception) {
            encoded = "invalid:" ~ typeName(definition.options[name]) ~ ":" ~ toLuaString(definition.options[name]);
        }
        result ~= ":option:" ~ name ~ ":" ~ encoded;
    }
    foreach (function_; [definition.availability, definition.requirement, definition.effect]) {
        auto functionObject = function_.match!((LuaFunction fn) => fn, _ => null);
        if (auto closure = cast(LuaClosure) functionObject)
            result ~= ":closure:" ~ prototypeFingerprint(closure.proto);
    }
    foreach (choice; definition.choices)
        result ~= ":choice:" ~ definitionFingerprint(choice, legacy);
    return result;
}

/// A digest of everything a player reads that is wording: titles, texts, names and labels. It
/// does not decide compatibility; it says that the presentation changed.
string presentationRevision(ContentRegistry registry) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;

    string[] parts;
    void collect(ContentDefinition definition, string prefix) {
        foreach (field; ["title", "text"]) {
            auto value = definition.option(field, LuaValue(""));
            if (isString(value))
                parts ~= prefix ~ definition.id ~ "." ~ field ~ "=" ~ value.match!((string s) => s, _ => "");
        }
        foreach (choice; definition.choices)
            collect(choice, prefix ~ definition.id ~ ".");
    }

    foreach (definition; registry.storylets() ~ registry.actions() ~ registry.procedures())
        collect(definition, "");
    foreach (definition; registry.scenes)
        foreach (beat; definition.beats) {
            import varis.narrative.scenes : field, nameOf, sequence;

            auto text = field(beat, "text");
            if (text.isString)
                parts ~= "scene." ~ definition.id ~ "." ~ nameOf(field(beat, "id")) ~ "=" ~ text.asString;
            foreach (choice; sequence(field(beat, "choices")))
                parts ~= "menu." ~ definition.id ~ "." ~ nameOf(field(choice, "id")) ~ "=" ~ nameOf(field(choice, "text"));
        }
    foreach (definition; registry.characters) {
        import varis.narrative.scenes : field, nameOf;

        parts ~= "character." ~ definition.id ~ "=" ~ nameOf(field(definition.fields, "name"));
    }
    foreach (id; registry.nameIds())
        parts ~= "name." ~ id ~ "=" ~ registry.name(id);
    parts.sort;
    string joined;
    foreach (part; parts)
        joined ~= part.length.to!string ~ ":" ~ part;
    return joined.sha256Of.toHexString.idup;
}

/// Portable code identity includes supported captures; authored versions opt into
/// host reconstruction of native callbacks and mutable captured environments.
string portableFunctionFingerprint(LuaValue value, varis.logic.world.World world, bool authored, string path, size_t depth = 0) {
    import varis.exception : LuaException;
    import varis.logic.world : World;

    if (depth > 32)
        throw new LuaException("non-reconstructible recursive closure at " ~ path);
    if (isNil(value))
        return "none";
    auto functionObject = value.match!((LuaFunction fn) => fn, _ => null);
    auto closure = cast(LuaClosure) functionObject;
    if (closure is null) {
        if (authored && functionObject !is null)
            return "authored-native:" ~ functionObject.name;
        throw new LuaException(
                "non-reconstructible native function at " ~ path ~ "; supply an authored reconstruction version");
    }
    string result = prototypeFingerprint(closure.proto);
    foreach (i, captured; closure.upvalues) {
        string name = closure.proto.upvalues[i].name;
        if (name == "_ENV")
            continue; // Reinstalled authored global environment.
        auto capture = captured.get();
        if (isFunction(capture))
            result ~= ":capture:" ~ name ~ ":" ~ portableFunctionFingerprint(capture, world, authored, path ~ "." ~ name, depth + 1);
        else if (capture.typeOf() == LuaType.UserData && world !is null && capture.match!(
                (LuaUserData u) => cast(World) u.payload, _ => null) is world)
            result ~= ":capture:" ~ name ~ ":own-world";
        else {
            try {
                result ~= ":capture:" ~ name ~ ":" ~ canonicalJSON(encodeValue(capture, path ~ "." ~ name));
            } catch (Exception error) {
                if (!authored)
                    throw new LuaException("non-reconstructible capture at " ~ path ~ "." ~ name ~ ": " ~ error.msg);
                result ~= ":capture:" ~ name ~ ":host-reconstructed:" ~ typeName(capture);
            }
        }
    }
    return result;
}

string portableRegistryFingerprint(ContentRegistry registry, bool legacy = false) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;

    string[] entries;
    void content(ContentDefinition definition) {
        // Registration stores the fingerprint of a top-level definition; its fields are frozen then.
        auto stored = legacy ? definition.legacyFingerprint : definition.fingerprint;
        entries ~= registry.sealed && stored.length ? stored : (legacy ? legacyContentFingerprint(definition)
                : contentFingerprint(definition));
        foreach (value; definition.requirement.isNil ? [definition.availability, definition.effect]
                : [definition.availability, definition.requirement, definition.effect])
            entries ~= portableFunctionFingerprint(value, null, registry.explicitContentVersion, definition.kind ~ "." ~ definition
                    .id);
        foreach (choice; definition.choices)
            content(choice);
    }

    foreach (definition; registry.storylets() ~ registry.actions() ~ registry.procedures())
        content(definition);
    entries ~= registry.sceneIdentity();
    foreach (name; registry.handlerNames())
        entries ~= name ~ portableFunctionFingerprint(registry.handler(name), null, registry.explicitContentVersion, "handler." ~ name);
    foreach (key; registry.formatterKeys())
        entries ~= "formatter." ~ key ~ portableFunctionFingerprint(registry.formatter(key), null, registry
                .explicitContentVersion, "formatter." ~ key);
    foreach (id; registry.nameIds())
        entries ~= legacy ? "name." ~ id ~ ":" ~ registry.name(id) : "name." ~ id;
    entries.sort;
    // Hashing the concatenated text dominates a save. The entries are mostly cached strings, so
    // when they equal the previous call's (usually by pointer) the previous digest is reused.
    // The cache serves the current identity; reading a first-format save is rare and uncached.
    if (legacy) {
        string legacyResult;
        foreach (entry; entries)
            legacyResult ~= entry.length.to!string ~ ":" ~ entry;
        return legacyResult.sha256Of.toHexString.idup;
    }
    bool unchanged = registry.fingerprintDigest.length != 0 && registry.fingerprintEntries.length == entries.length;
    for (size_t i = 0; unchanged && i < entries.length; ++i) {
        auto previous = registry.fingerprintEntries[i];
        unchanged = previous.length == entries[i].length && (previous.ptr is entries[i].ptr || previous == entries[i]);
    }
    if (unchanged)
        return registry.fingerprintDigest;
    string result;
    foreach (entry; entries)
        result ~= entry.length.to!string ~ ":" ~ entry;
    registry.fingerprintEntries = entries;
    registry.fingerprintDigest = result.sha256Of.toHexString.idup;
    return registry.fingerprintDigest;
}

string portableProgramFingerprint(varis.logic.world.World world, bool authored = false) {
    import varis.logic.model;
    import varis.exception : LuaException;
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;

    string[string] anonymousNames;
    string variable(string name) {
        import std.string : startsWith;

        if (!name.startsWith("@anonymous"))
            return name;
        if (auto existing = name in anonymousNames)
            return *existing;
        auto canonical = "@anonymous" ~ anonymousNames.length.to!string;
        anonymousNames[name] = canonical;
        return canonical;
    }

    string variableList(string[] names) {
        string result;
        string[] canonicalNames;
        foreach (name; names)
            canonicalNames ~= variable(name);
        canonicalNames.sort;
        foreach (canonical; canonicalNames)
            result ~= canonical.length.to!string ~ ":" ~ canonical;
        return result;
    }

    string term(Term value) {
        if (value.kind == TermKind.Constant)
            return "constant:" ~ canonicalJSON(encodeValue(value.constantValue, "rule.constant"));
        return value.kind.to!string ~ ":" ~ variable(value.varName);
    }

    string reference(RelationRef relation) {
        if (relation is null)
            return "";
        if (relation.isLocal || relation.resolvedRelation is null || relation.resolvedRelation.ownerWorld !is world)
            throw new LuaException("non-reconstructible local or foreign rule relation '" ~ relation.name ~ "'");
        return relation.name.length.to!string ~ ":" ~ relation.name ~ ":" ~ relation.arity.to!string;
    }

    string goals(Goal[] input) {
        string result;
        foreach (goal; input) {
            result ~= ":goal:" ~ goal.kind.to!string ~ ":" ~ reference(goal.relRef);
            foreach (value; goal.terms)
                result ~= ":term:" ~ term(value);
            if (goal.kind == GoalKind.Comparison)
                result ~= term(goal.leftTerm) ~ goal.compOp.to!string ~ term(goal.rightTerm);
            if (goal.kind == GoalKind.Guard) {
                if (!authored)
                    throw new LuaException("non-reconstructible runtime rule guard; call narrative.program(world, version) during authored initialization");
                result ~= portableFunctionFingerprint(goal.guardFn, world, true, "rule.guard") ~ goal
                    .guardVarNames.to!string;
            }
            if (goal.kind == GoalKind.Aggregate) {
                result ~= goal.aggregateOp ~ goal.resultVariable ~ goals(goal.aggregateGoals) ~ variableList(
                        goal.aggregateInputs) ~ variableList(goal.aggregateLocals);
                if (isFunction(goal.aggregateExpression)) {
                    if (!authored)
                        throw new LuaException(
                                "non-reconstructible aggregate expression; declare an authored program version");
                    result ~= portableFunctionFingerprint(goal.aggregateExpression, world, true, "rule.aggregate") ~ goal
                        .aggregateExpressionVariables.to!string;
                }
            }
        }
        return result;
    }

    string[] entries;
    foreach (rule; world.rules) {
        anonymousNames = null;
        string entry = reference(rule.headRel);
        foreach (value; rule.headTerms)
            entry ~= ":head:" ~ term(value);
        entry ~= goals(rule.bodyGoals);
        entries ~= entry;
    }
    entries.sort;
    string result;
    foreach (entry; entries)
        result ~= entry.length.to!string ~ ":" ~ entry;
    return result.sha256Of.toHexString.idup;
}
