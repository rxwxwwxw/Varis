/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.quality;

import varis.types;
import core.thread : Fiber;
import varis.state;
import varis.table;
import varis.logic.world;
import varis.logic.model;
import varis.narrative.registry;
import varis.narrative.codec : immutableRecord;
import varis.narrative.session : currentEffectSession;
import varis.exception : LuaException;

/// Install the reserved extensional schema; validators survive snapshots/savepoints.
/// Returns null, or the reason the world cannot hold qualities.
string configureQualityWorld(LuaState state, World world) {
    auto relation = world.getRelation("quality");
    if (relation is null)
        relation = world.declareNamedRelation("quality", ["entity", "name", "value"], [
        "entity", "name"
    ]);
    if (relation.columns != ["entity", "name", "value"] || relation.keyColumns != [cast(size_t) 0, 1] || relation
            .rules.length)
        return "quality requires schema quality(entity, name, value) key(entity, name)";
    foreach (tuple; relation.baseFacts.keys)
        state.narrativeRegistry.validateQualityTuple(tuple);
    relation.validateTuple = &state.narrativeRegistry.validateQualityTuple;
    relation.clampTuple = &state.narrativeRegistry.clampQualityTuple;
    return null;
}

private bool qualityName(LuaState state, LuaValue value, out string result) {
    if (!isSymbol(value)) {
        raise(state, new LuaException("quality name must be a symbol"));
        return false;
    }
    result = value.match!((Symbol s) => s.name, _ => "");
    return true;
}

void openQualityLib(LuaState state) {
    state.configureWorld = (World world) { return configureQualityWorld(state, world); };
    configureWorld(state)(state.globalWorld); // a fresh global world always accepts the schema
    auto library = new LuaTable();
    void add(string name, LuaNativeFunction.NativeDelegate callback) {
        library.rawset(LuaValue(name), LuaValue(new LuaNativeFunction(callback, "quality." ~ name)));
    }

    add("define", (void* pointer, LuaValue[] args) {
        auto state = cast(LuaState) pointer;
        if (args.length != 2 || !isTable(args[1]))
            return raise(state, new LuaException("quality.define requires a symbol and metadata table"));
        auto definition = new QualityDefinition();
        if (!qualityName(state, args[0], definition.id))
            return null;
        auto metadata = args[1].match!((LuaTable t) => t, _ => null);
        LuaValue previous, key, value;
        while (metadata.next(previous, key, value)) {
            previous = key;
            if (!isString(key))
                return raise(cast(LuaState) pointer, new LuaException("quality metadata keys must be strings"));
            auto name = key.match!((string s) => s, _ => "");
            if (name != "initial" && name != "minimum" && name != "maximum" && name != "visible" && name != "label")
                return raise(cast(LuaState) pointer, new LuaException("unknown quality metadata field '" ~ name ~ "'"));
        }
        definition.initial = metadata.rawget(LuaValue("initial"));
        definition.minimum = metadata.rawget(LuaValue("minimum"));
        definition.maximum = metadata.rawget(LuaValue("maximum"));
        auto visible = metadata.rawget(LuaValue("visible"));
        if (!isNil(visible) && !isBoolean(visible))
            return raise(cast(LuaState) pointer, new LuaException("quality visible must be Boolean"));
        definition.visible = isNil(visible) || visible.match!((bool b) => b, _ => true);
        auto label = metadata.rawget(LuaValue("label"));
        if (!isNil(label) && !isString(label))
            return raise(cast(LuaState) pointer, new LuaException("quality label must be a string"));
        definition.label = isNil(label) ? definition.id : label.match!((string s) => s, _ => "");
        state.narrativeRegistry.registerQuality(definition);
        return cast(LuaValue[])[];
    });
    void addOperation(string name) {
        add(name, (void* pointer, LuaValue[] args) {
            auto state = cast(LuaState) pointer;
            size_t required = (name == "set" || name == "add") ? 3 : 2;
            bool clamp;
            if (name == "add" && args.length > required && isTable(args[required])) {
                // quality.add(entity, name, delta, {clamp = true} [, world])
                auto options = args[required].match!((LuaTable t) => t, _ => null);
                LuaValue previous, optionKey, optionValue;
                while (options.next(previous, optionKey, optionValue)) {
                    previous = optionKey;
                    if (!isString(optionKey) || optionKey.match!((string s) => s, _ => "") != "clamp")
                        return raise(cast(LuaState) pointer, new LuaException("unknown quality.add option"));
                    if (!isBoolean(optionValue))
                        return raise(cast(LuaState) pointer, new LuaException(
                            "quality.add clamp option must be Boolean"));
                    clamp = optionValue.match!((bool b) => b, _ => false);
                }
                args = args[0 .. required] ~ args[required + 1 .. $];
            }
            if (args.length < required || args.length > required + 1)
                return raise(cast(LuaState) pointer, new LuaException("bad arguments to quality." ~ name));
            string id;
            if (!qualityName(state, args[1], id))
                return null;
            auto definition = state.narrativeRegistry.quality(id);
            if (definition is null)
                return raise(cast(LuaState) pointer, new LuaException("unknown quality '" ~ id ~ "'"));
            auto effect = currentEffectSession();
            auto world = args.length > required ? unwrapWorld(args[required]) : (effect is null ? state.globalWorld
                : (state.callWorld !is null ? state.callWorld : effect.world));
            auto relation = world.getRelation("quality");
            if (relation is null) {
                if (name == "get")
                    return [luaNil()];
                auto problem = configureQualityWorld(state, world);
                if (problem !is null)
                    return raise(state, new LuaException(problem));
                relation = world.getRelation("quality");
            }
            if (relation.columns != ["entity", "name", "value"] || relation.keyColumns != [
                cast(size_t) 0, 1
            ])
                return raise(cast(LuaState) pointer, new LuaException("invalid quality relation schema"));
            // Foreign authored worlds must receive the same metadata validator.
            relation.validateTuple = &state.narrativeRegistry.validateQualityTuple;
            relation.clampTuple = &state.narrativeRegistry.clampQualityTuple;
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
                world.updateFact("quality", key, "adjust", args[2], clamp);
            return cast(LuaValue[])[];
        });
    }

    foreach (name; ["initialize", "get", "set", "add"])
        addOperation(name);
    add("metadata", (void* pointer, LuaValue[] args) {
        auto state = cast(LuaState) pointer;
        if (args.length != 1)
            return raise(cast(LuaState) pointer, new LuaException("quality.metadata requires a quality symbol"));
        string id;
        if (!qualityName(state, args[0], id))
            return null;
        auto definition = state.narrativeRegistry.quality(id);
        if (definition is null)
            return raise(cast(LuaState) pointer, new LuaException("unknown quality '" ~ id ~ "'"));
        // Fields that are absent stay absent (nil), so `minimum == nil` means unbounded below.
        return [
            immutableRecord([
                "initial": definition.initial,
                "minimum": definition.minimum,
                "maximum": definition.maximum,
                "visible": LuaValue(definition.visible),
                "label": LuaValue(definition.label)
            ])
        ];
    });
    state.setGlobal("quality", LuaValue(library));
}
