/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.narrative.fingerprint;

import dlua.types;
import dlua.logic.world;
import dlua.narrative.persistence : canonicalJSON;
import dlua.vm;
import dlua.opcode;
import dlua.narrative.registry;
import dlua.narrative.codec;
import std.algorithm : sort;
import std.conv : to;

string prototypeFingerprint(Prototype prototype) {
    string result = prototype.numParams.to!string ~ ":" ~ prototype.isVararg.to!string;
    foreach (instruction; prototype.code) result ~= ":" ~ instruction.toString();
    auto callPCs = prototype.callWorlds.keys; callPCs.sort;
    foreach (pc; callPCs) result ~= ":call-world:" ~ pc.to!string ~ ":" ~ prototype.callWorlds[pc].to!string;
    auto namedPCs = prototype.callNames.keys; namedPCs.sort;
    foreach (pc; namedPCs) result ~= ":call-name:" ~ pc.to!string ~ ":" ~ prototype.callNames[pc].name ~ ":" ~ prototype.callNames[pc].kind;
    foreach (local; prototype.debugLocals) result ~= ":local:" ~ local.name ~ ":" ~ local.register.to!string ~ ":" ~ local.startPC.to!string ~ ":" ~ local.endPC.to!string ~ ":" ~ local.readOnly.to!string;
    foreach (constant; prototype.constants) result ~= ":" ~ canonicalScalar(constant);
    foreach (upvalue; prototype.upvalues) result ~= ":upvalue:" ~ upvalue.name ~ ":" ~ upvalue.inStack.to!string ~ ":" ~ upvalue.index.to!string;
    foreach (schema; prototype.relationSchemas) result ~= ":schema:" ~ schema.columns.to!string ~ ":" ~ schema.keys.to!string;
    foreach (child; prototype.subPrototypes) result ~= ":" ~ prototypeFingerprint(child);
    void terms(TermTemplate[] terms) {
        foreach (term; terms) result ~= ":term:" ~ term.kind.to!string ~ ":" ~ term.varName ~ ":" ~ term.reg.to!string ~ ":" ~ term.varId.to!string ~ ":" ~ term.isStatic.to!string ~ (term.isStatic ? canonicalScalar(term.staticVal) : "");
    }
    void goals(GoalTemplate[] goalTemplates) {
        foreach (goal; goalTemplates) {
            result ~= ":goal:" ~ goal.kind.to!string ~ ":" ~ goal.relName ~ ":" ~ goal.aggregateOp ~ ":" ~ goal.resultVariable ~ ":" ~ goal.compOp.to!string ~ ":" ~ goal.worldReg.to!string ~ ":" ~ goal.localRelReg.to!string;
            terms(goal.terms); terms([goal.leftTerm, goal.rightTerm]); goals(goal.aggregateGoals);
            result ~= ":metadata:" ~ goal.arity.to!string ~ ":" ~ goal.localRelUpval.to!string ~ ":" ~ goal.aggregateExpressionProto.to!string ~ ":" ~ goal.aggregateExpressionVariables.to!string ~ ":" ~ goal.guardSubProtoIdx.to!string ~ ":" ~ goal.guardVarNames.to!string ~ ":" ~ goal.guardVarIds.to!string;
        }
    }
    foreach (query; prototype.queryTemplates) { goals(query.goals); result ~= query.returnedVarNames.to!string ~ query.isBraced.to!string; }
    foreach (rule; prototype.ruleTemplates) { result ~= ":head:" ~ rule.headRelName; terms(rule.headTerms); goals(rule.bodyGoals); }
    return result;
}

string contentFingerprint(ContentDefinition definition) {
    string result = definition.kind ~ ":" ~ definition.id;
    foreach (parameter; definition.incomingParameters ~ definition.parameters) result ~= ":parameter:" ~ parameter;
    auto names = definition.options.keys; names.sort;
    foreach (name; names) {
        string encoded;
        try { encoded = canonicalScalar(definition.options[name]); }
        catch (Exception) { encoded = "invalid:" ~ typeName(definition.options[name]) ~ ":" ~ toLuaString(definition.options[name]); }
        result ~= ":option:" ~ name ~ ":" ~ encoded;
    }
    foreach (function_; [definition.availability, definition.effect]) {
        auto functionObject = function_.match!((LuaFunction fn) => fn, _ => null);
        if (auto closure = cast(LuaClosure)functionObject) result ~= ":closure:" ~ prototypeFingerprint(closure.proto);
    }
    foreach (choice; definition.choices) result ~= ":choice:" ~ contentFingerprint(choice);
    return result;
}

/// Portable code identity includes supported captures; authored versions opt into
/// host reconstruction of native callbacks and mutable captured environments.
string portableFunctionFingerprint(LuaValue value, dlua.logic.world.World world, bool authored, string path, size_t depth = 0) {
    import dlua.exception : LuaException;
    import dlua.logic.world : World;
    if (depth > 32) throw new LuaException("non-reconstructible recursive closure at " ~ path);
    if (isNil(value)) return "none";
    auto functionObject = value.match!((LuaFunction fn) => fn, _ => null);
    auto closure = cast(LuaClosure)functionObject;
    if (closure is null) {
        if (authored && functionObject !is null) return "authored-native:" ~ functionObject.name;
        throw new LuaException("non-reconstructible native function at " ~ path ~ "; supply an authored reconstruction version");
    }
    string result = prototypeFingerprint(closure.proto);
    foreach (i, captured; closure.upvalues) {
        string name = closure.proto.upvalues[i].name;
        if (name == "_ENV") continue; // Reinstalled authored global environment.
        auto capture = captured.get();
        if (isFunction(capture)) result ~= ":capture:" ~ name ~ ":" ~ portableFunctionFingerprint(capture, world, authored, path ~ "." ~ name, depth + 1);
        else if (capture.typeOf() == LuaType.UserData && world !is null && capture.match!((LuaUserData u) => cast(World)u.payload, _ => null) is world)
            result ~= ":capture:" ~ name ~ ":own-world";
        else {
            try { result ~= ":capture:" ~ name ~ ":" ~ canonicalJSON(encodeValue(capture, path ~ "." ~ name)); }
            catch (Exception error) {
                if (!authored) throw new LuaException("non-reconstructible capture at " ~ path ~ "." ~ name ~ ": " ~ error.msg);
                result ~= ":capture:" ~ name ~ ":host-reconstructed:" ~ typeName(capture);
            }
        }
    }
    return result;
}

string portableRegistryFingerprint(ContentRegistry registry) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    string[] entries;
    void content(ContentDefinition definition) {
        entries ~= contentFingerprint(definition);
        foreach (value; [definition.availability, definition.effect])
            entries ~= portableFunctionFingerprint(value, null, registry.explicitContentVersion, definition.kind ~ "." ~ definition.id);
        foreach (choice; definition.choices) content(choice);
    }
    foreach (definition; registry.storylets() ~ registry.actions()) content(definition);
    foreach (name; registry.handlerNames())
        entries ~= name ~ portableFunctionFingerprint(registry.handler(name), null, registry.explicitContentVersion, "handler." ~ name);
    foreach (key; registry.formatterKeys())
        entries ~= "formatter." ~ key ~ portableFunctionFingerprint(registry.formatter(key), null, registry.explicitContentVersion, "formatter." ~ key);
    foreach (id; registry.nameIds())
        entries ~= "name." ~ id ~ ":" ~ registry.name(id);
    entries.sort;
    string result;
    foreach (entry; entries) result ~= entry.length.to!string ~ ":" ~ entry;
    return result.sha256Of.toHexString.idup;
}

string portableProgramFingerprint(dlua.logic.world.World world, bool authored = false) {
    import dlua.logic.model;
    import dlua.exception : LuaException;
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    string[string] anonymousNames;
    string variable(string name) {
        import std.string : startsWith;
        if (!name.startsWith("@anonymous")) return name;
        if (auto existing = name in anonymousNames) return *existing;
        auto canonical = "@anonymous" ~ anonymousNames.length.to!string;
        anonymousNames[name] = canonical; return canonical;
    }
    string variableList(string[] names) {
        string result;
        string[] canonicalNames;
        foreach (name; names) canonicalNames ~= variable(name);
        canonicalNames.sort;
        foreach (canonical; canonicalNames) result ~= canonical.length.to!string ~ ":" ~ canonical;
        return result;
    }
    string term(Term value) {
        if (value.kind == TermKind.Constant) return "constant:" ~ canonicalJSON(encodeValue(value.constantValue, "rule.constant"));
        return value.kind.to!string ~ ":" ~ variable(value.varName);
    }
    string reference(RelationRef relation) {
        if (relation is null) return "";
        if (relation.isLocal || relation.resolvedRelation is null || relation.resolvedRelation.ownerWorld !is world)
            throw new LuaException("non-reconstructible local or foreign rule relation '" ~ relation.name ~ "'");
        return relation.name.length.to!string ~ ":" ~ relation.name ~ ":" ~ relation.arity.to!string;
    }
    string goals(Goal[] input) {
        string result;
        foreach (goal; input) {
            result ~= ":goal:" ~ goal.kind.to!string ~ ":" ~ reference(goal.relRef);
            foreach (value; goal.terms) result ~= ":term:" ~ term(value);
            if (goal.kind == GoalKind.Comparison) result ~= term(goal.leftTerm) ~ goal.compOp.to!string ~ term(goal.rightTerm);
            if (goal.kind == GoalKind.Guard) {
                if (!authored) throw new LuaException("non-reconstructible runtime rule guard; call narrative.program(world, version) during authored initialization");
                result ~= portableFunctionFingerprint(goal.guardFn, world, true, "rule.guard") ~ goal.guardVarNames.to!string;
            }
            if (goal.kind == GoalKind.Aggregate) {
                result ~= goal.aggregateOp ~ goal.resultVariable ~ goals(goal.aggregateGoals) ~ variableList(goal.aggregateInputs) ~ variableList(goal.aggregateLocals);
                if (isFunction(goal.aggregateExpression)) {
                    if (!authored) throw new LuaException("non-reconstructible aggregate expression; declare an authored program version");
                    result ~= portableFunctionFingerprint(goal.aggregateExpression, world, true, "rule.aggregate") ~ goal.aggregateExpressionVariables.to!string;
                }
            }
        }
        return result;
    }
    string[] entries;
    foreach (rule; world.rules) {
        anonymousNames = null;
        string entry = reference(rule.headRel);
        foreach (value; rule.headTerms) entry ~= ":head:" ~ term(value);
        entry ~= goals(rule.bodyGoals);
        entries ~= entry;
    }
    entries.sort;
    string result;
    foreach (entry; entries) result ~= entry.length.to!string ~ ":" ~ entry;
    return result.sha256Of.toHexString.idup;
}
