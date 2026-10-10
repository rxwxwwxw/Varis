/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.lib.quality;

import dlua.types;
import core.thread : Fiber;
import dlua.state;
import dlua.table;
import dlua.logic.world;
import dlua.logic.model;
import dlua.narrative.registry;
import dlua.narrative.session : currentEffectSession;
import dlua.exception : LuaException;

/// Install the reserved extensional schema; validators survive snapshots/savepoints.
void configureQualityWorld(LuaState state, World world) {
    auto relation = world.getRelation("quality");
    if (relation is null)
        relation = world.declareNamedRelation("quality", ["entity", "name", "value"], [
        "entity", "name"
    ]);
    if (relation.columns != ["entity", "name", "value"] || relation.keyColumns != [cast(size_t) 0, 1] || relation
            .rules.length)
        throw new LuaException("quality requires schema quality(entity, name, value) key(entity, name)");
    foreach (tuple; relation.baseFacts.keys)
        state.narrativeRegistry.validateQualityTuple(tuple);
    relation.validateTuple = &state.narrativeRegistry.validateQualityTuple;
}

private string qualityName(LuaValue value) {
    if (!isSymbol(value))
        throw new LuaException("quality name must be a symbol");
    return value.match!((Symbol s) => s.name, _ => "");
}

void openQualityLib(LuaState state) {
    state.configureWorld = (World world) { configureQualityWorld(state, world); };
    state.configureWorld(state.globalWorld);
    auto library = new LuaTable();
    void add(string name, LuaNativeFunction.NativeDelegate callback) {
        library.rawset(LuaValue(name), LuaValue(new LuaNativeFunction(callback, "quality." ~ name)));
    }

    add("define", (void* pointer, LuaValue[] args) {
        if (args.length != 2 || !isTable(args[1]))
            throw new LuaException("quality.define requires a symbol and metadata table");
        auto state = cast(LuaState) pointer;
        auto definition = new QualityDefinition();
        definition.id = qualityName(args[0]);
        auto metadata = args[1].match!((LuaTable t) => t, _ => null);
        LuaValue previous, key, value;
        while (metadata.next(previous, key, value)) {
            previous = key;
            if (!isString(key))
                throw new LuaException("quality metadata keys must be strings");
            auto name = key.match!((string s) => s, _ => "");
            if (name != "initial" && name != "minimum" && name != "maximum" && name != "visible" && name != "label")
                throw new LuaException("unknown quality metadata field '" ~ name ~ "'");
        }
        definition.initial = metadata.rawget(LuaValue("initial"));
        definition.minimum = metadata.rawget(LuaValue("minimum"));
        definition.maximum = metadata.rawget(LuaValue("maximum"));
        auto visible = metadata.rawget(LuaValue("visible"));
        if (!isNil(visible) && !isBoolean(visible))
            throw new LuaException("quality visible must be Boolean");
        definition.visible = isNil(visible) || visible.match!((bool b) => b, _ => true);
        auto label = metadata.rawget(LuaValue("label"));
        if (!isNil(label) && !isString(label))
            throw new LuaException("quality label must be a string");
        definition.label = isNil(label) ? definition.id : label.match!((string s) => s, _ => "");
        state.narrativeRegistry.registerQuality(definition);
        return cast(LuaValue[])[];
    });
    void addOperation(string name) {
        add(name, (void* pointer, LuaValue[] args) {
            auto state = cast(LuaState) pointer;
            size_t required = (name == "set" || name == "add") ? 3 : 2;
            if (args.length < required || args.length > required + 1)
                throw new LuaException("bad arguments to quality." ~ name);
            auto id = qualityName(args[1]);
            auto definition = state.narrativeRegistry.quality(id);
            if (definition is null)
                throw new LuaException("unknown quality '" ~ id ~ "'");
            auto effect = currentEffectSession();
            auto world = args.length > required ? unwrapWorld(args[required]) : (effect is null ? state.globalWorld
                : (state.callWorld !is null ? state.callWorld : effect.world));
            auto relation = world.getRelation("quality");
            if (relation is null) {
                if (name == "get")
                    return [luaNil()];
                configureQualityWorld(state, world);
                relation = world.getRelation("quality");
            }
            if (relation.columns != ["entity", "name", "value"] || relation.keyColumns != [
                cast(size_t) 0, 1
            ])
                throw new LuaException("invalid quality relation schema");
            // Foreign authored worlds must receive the same metadata validator.
            relation.validateTuple = &state.narrativeRegistry.validateQualityTuple;
            auto key = RelTuple([args[0], args[1]]);
            auto old = key in visibleRelation(relation).keyIndex;
            if (name == "get")
                return [old is null ? luaNil() : old.values[2]];
            if (name == "initialize") {
                if (old is null)
                    world.updateFact("quality", RelTuple([args[0], args[1], definition.initial]), "set");
            } else if (name == "set")
                world.updateFact("quality", RelTuple([args[0], args[1], args[2]]), "set");
            else
                world.updateFact("quality", key, "adjust", args[2]);
            return cast(LuaValue[])[];
        });
    }

    foreach (name; ["initialize", "get", "set", "add"])
        addOperation(name);
    state.setGlobal("quality", LuaValue(library));
}
