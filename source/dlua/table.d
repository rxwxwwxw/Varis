/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.table;

import dlua.types;
import dlua.exception;
import std.math : isNaN;
import std.sumtype;

/// Emulates an allocation failure: the array part of a table never grows past this many slots
/// (C Lua fails the allocation when the machine runs out of memory; a bounded limit keeps the
/// process from being killed instead of raising a catchable "not enough memory").
__gshared size_t maxArrayElements = 1UL << 27;

/// A pair of LuaValues returned by table iteration
struct TableEntry {
    LuaValue key;
    LuaValue value;
}

/// Hidden-pointer helpers used to emulate weak references on top of D's collector.
private enum size_t weakMask = 0x5A5A_5A5A_5A5A_5A5AUL;

size_t hideReference(Object o) @trusted nothrow {
    return cast(size_t)cast(void*)o ^ weakMask;
}

bool hiddenReferenceAlive(size_t hidden) @trusted nothrow {
    import core.memory : GC;
    return GC.addrOf(cast(void*)(hidden ^ weakMask)) !is null;
}

/// Like `hiddenReferenceAlive`, but also checks that the block still holds a `LuaTable`: a block
/// freed by an ordinary D collection may have been reused for something else.
bool hiddenTableAlive(size_t hidden) @trusted nothrow {
    import core.memory : GC;
    auto address = cast(void*)(hidden ^ weakMask);
    if (GC.addrOf(address) !is address) return false;
    if (GC.sizeOf(address) < typeid(LuaTable).initializer.length) return false;
    return *cast(void**)address == *cast(void**)typeid(LuaTable).initializer.ptr;
}

Object revealReference(size_t hidden) @trusted nothrow {
    return cast(Object)cast(void*)(hidden ^ weakMask);
}

bool isCollectable(LuaValue v) {
    auto t = v.typeOf();
    return t == LuaType.Table || t == LuaType.Function || t == LuaType.UserData || t == LuaType.Thread;
}

Object collectableObject(LuaValue v) {
    return v.match!((LuaTable x) => cast(Object)x, (LuaFunction x) => cast(Object)x, (LuaUserData x) => cast(Object)x,
        (LuaThread x) => cast(Object)x, _ => cast(Object)null);
}

LuaValue collectableValue(LuaType kind, Object o) {
    final switch (kind) {
        case LuaType.Table: return LuaValue(cast(LuaTable)o);
        case LuaType.Function: return LuaValue(cast(LuaFunction)o);
        case LuaType.UserData: return LuaValue(cast(LuaUserData)o);
        case LuaType.Thread: return LuaValue(cast(LuaThread)o);
        case LuaType.Nil, LuaType.Boolean, LuaType.LightUserData, LuaType.Number, LuaType.String, LuaType.Symbol: return luaNil();
    }
}

/// An entry whose weak references were hidden from the collector (see `LuaTable.weakHide`).
struct WeakSaved {
    bool inArray;
    size_t index;
    bool hiddenKey, hiddenValue;
    bool ephemeron;     // weak key whose strong value must live exactly as long as the key (see dlua.gc)
    size_t keyRef, valueRef;
    LuaType keyKind, valueKind;
    LuaValue strongKey, strongValue;
}

/// Lua Table: dual-storage combining a 1-based array part and an
/// insertion-ordered hash part. Removed keys stay in the hash as dead nodes
/// (nil value) until the next rehash, so `next` remains valid while a
/// traversal clears fields.
class LuaTable {
    LuaValue[] arrayPart;
    LuaTable metatable;
    bool weakRegistered;  // listed in the weak-table registry (see dlua.gc)

    private struct Node {
        LuaValue key;
        LuaValue value;
        // A removed entry whose key was released at a collection cycle: the key only remains
        // identifiable by hash, so that `next` can still continue from it.
        bool dead;
        size_t deadHash;
    }
    private Node[] nodes;     // insertion ordered; nodes[0 .. nodeCount] are in use
    private size_t nodeCount;
    private size_t liveCount; // nodes with a non-nil value
    private int[] buckets;    // open addressing; node index + 1, 0 = empty

    this(size_t arrayCapacity = 0, size_t hashCapacity = 0) {
        if (arrayCapacity > 0) {
            arrayPart.length = arrayCapacity;
        }
        if (hashCapacity > 0) reserveHash(hashCapacity);
    }

    private static size_t mix(size_t h) nothrow @safe {
        h ^= h >> 33;
        h *= 0xff51afd7ed558ccdUL;
        h ^= h >> 29;
        return h;
    }

    private void reserveHash(size_t wanted) {
        size_t capacity = 4;
        while (capacity < wanted) capacity <<= 1;
        rebuild(capacity);
    }

    /// Rebuilds the hash part with room for `capacity` nodes, dropping dead nodes.
    private void rebuild(size_t capacity) {
        auto old = nodes[0 .. nodeCount];
        nodes = new Node[capacity];
        buckets = new int[capacity * 2];
        size_t n = 0;
        size_t mask = buckets.length - 1;
        foreach (ref node; old) {
            if (isNil(node.value)) continue;
            nodes[n] = node;
            size_t h = mix(node.key.toHash()) & mask;
            while (buckets[h] != 0) h = (h + 1) & mask;
            buckets[h] = cast(int)(n + 1);
            ++n;
        }
        nodeCount = n;
        liveCount = n;
    }

    /// Returns node index of `key` (already normalized) or -1.
    private ptrdiff_t findNode(LuaValue key) {
        if (buckets.length == 0) return -1;
        size_t mask = buckets.length - 1;
        size_t h = mix(key.toHash()) & mask;
        while (true) {
            int slot = buckets[h];
            if (slot == 0) return -1;
            if (!nodes[slot - 1].dead && nodes[slot - 1].key.opEquals(key)) return slot - 1;
            h = (h + 1) & mask;
        }
    }

    /// Finds a released key by hash (used to continue a traversal from a removed entry).
    private ptrdiff_t findDeadNode(LuaValue key) {
        if (buckets.length == 0) return -1;
        size_t mask = buckets.length - 1;
        size_t hash = key.toHash();
        size_t h = mix(hash) & mask;
        while (true) {
            int slot = buckets[h];
            if (slot == 0) return -1;
            if (nodes[slot - 1].dead && nodes[slot - 1].deadHash == hash) return slot - 1;
            h = (h + 1) & mask;
        }
    }

    private void insertNode(LuaValue key, LuaValue val) {
        if (nodeCount == nodes.length) {
            size_t live = liveCount + 1;
            size_t capacity = nodes.length < 4 ? 4 : nodes.length;
            while (capacity < live * 2 && capacity < live + 4) capacity <<= 1;
            if (live > capacity / 2 + capacity / 4) capacity <<= 1;
            rebuild(capacity);
        }
        size_t mask = buckets.length - 1;
        size_t h = mix(key.toHash()) & mask;
        while (buckets[h] != 0) h = (h + 1) & mask;
        nodes[nodeCount] = Node(key, val);
        buckets[h] = cast(int)(nodeCount + 1);
        ++nodeCount;
        ++liveCount;
    }

    /// Raw get without metamethod invocation
    LuaValue rawget(LuaValue key) {
        if (isNil(key)) return luaNil();

        key = normalizeKey(key);

        // Check if key is a 1-based positive integer in arrayPart
        if (isInteger(key)) {
            long idx = key.match!((long i) => i, _ => 0);
            if (idx >= 1 && idx <= cast(long)arrayPart.length) {
                return arrayPart[cast(size_t)(idx - 1)];
            }
        }
        auto found = findNode(key);
        return found < 0 ? luaNil() : nodes[found].value;
    }

    /// Raw get for an integer key.
    LuaValue rawgetInt(long idx) {
        if (idx >= 1 && idx <= cast(long)arrayPart.length) return arrayPart[cast(size_t)(idx - 1)];
        if (liveCount == 0) return luaNil();
        auto found = findNode(LuaValue(idx));
        return found < 0 ? luaNil() : nodes[found].value;
    }

    /// Raw set without metamethod invocation
    void rawset(LuaValue key, LuaValue val) {
        if (isNil(key)) {
            throw new LuaException("table index is nil");
        }
        if (isFloat(key) && isNaN(key.match!((double d) => d, _ => 0.0))) {
            throw new LuaException("table index is NaN");
        }

        key = normalizeKey(key);

        if (isInteger(key)) {
            long idx = key.match!((long i) => i, _ => 0);
            if (idx >= 1) {
                size_t arrIdx = cast(size_t)(idx - 1);
                if (arrIdx < arrayPart.length) {
                    arrayPart[arrIdx] = val;
                    return;
                } else if (arrIdx == arrayPart.length && !isNil(val)) {
                    // Append contiguous element to arrayPart, pulling its successors out of the hash.
                    if (liveCount != 0) {
                        auto stale = findNode(key);
                        if (stale >= 0 && !isNil(nodes[stale].value)) { nodes[stale].value = luaNil(); --liveCount; }
                    }
                    if (arrayPart.length >= maxArrayElements) throw new LuaException("not enough memory");
                    arrayPart ~= val;
                    if (liveCount != 0) migrateFromHash();
                    return;
                }
            }
        }

        auto found = findNode(key);
        if (found >= 0) {
            bool wasLive = !isNil(nodes[found].value);
            nodes[found].value = val;
            if (wasLive && isNil(val)) --liveCount;
            else if (!wasLive && !isNil(val)) ++liveCount;
            return;
        }
        if (!isNil(val)) insertNode(key, val);
    }

    /// Moves keys length+1, length+2, ... from the hash part into the array part.
    private void migrateFromHash() {
        while (liveCount != 0) {
            auto found = findNode(LuaValue(cast(long)arrayPart.length + 1));
            if (found < 0 || isNil(nodes[found].value)) return;
            arrayPart ~= nodes[found].value;
            nodes[found].value = luaNil();
            --liveCount;
        }
    }

    /// Grows the array part to `n` slots (nil padded), absorbing matching hash entries.
    void ensureArray(size_t n) {
        while (arrayPart.length < n) {
            LuaValue v;
            if (liveCount != 0) {
                auto found = findNode(LuaValue(cast(long)arrayPart.length + 1));
                if (found >= 0 && !isNil(nodes[found].value)) { v = nodes[found].value; nodes[found].value = luaNil(); --liveCount; }
            }
            arrayPart ~= v;
        }
    }

    /// Get metamethod from metatable if present
    LuaValue getMetamethod(string event) {
        if (metatable is null) return luaNil();
        return metatable.rawget(LuaValue(event));
    }

    /// Compute length operator `#` according to Lua border rules
    long rawLen() {
        size_t arrLen = arrayPart.length;
        if (arrLen > 0) {
            if (isNil(arrayPart[$ - 1])) {
                // Binary search for a border inside the array part.
                size_t low = 0;
                size_t high = arrLen;
                while (low < high) {
                    size_t mid = (low + high) / 2;
                    if (isNil(arrayPart[mid])) high = mid; else low = mid + 1;
                }
                return cast(long)low;
            }
        }
        if (liveCount == 0) return cast(long)arrLen;
        // Continue into the hash part (unbound search as luaH_getn's hash_search).
        long idx = cast(long)arrLen;
        while (!isNil(rawgetInt(idx + 1))) idx++;
        return idx;
    }

    /// Get next key-value pair for iteration (pairs/next). Throws for an invalid key.
    bool next(LuaValue currentKey, out LuaValue nextKey, out LuaValue nextVal) {
        size_t nodeStart = 0;
        if (!isNil(currentKey)) {
            currentKey = normalizeKey(currentKey);
            long idx = isInteger(currentKey) ? currentKey.match!((long i) => i, _ => 0L) : 0L;
            if (idx >= 1 && idx <= cast(long)arrayPart.length) {
                for (size_t i = cast(size_t)idx; i < arrayPart.length; ++i) {
                    if (!isNil(arrayPart[i])) {
                        nextKey = LuaValue(cast(long)(i + 1));
                        nextVal = arrayPart[i];
                        return true;
                    }
                }
            } else {
                auto found = findNode(currentKey);
                if (found < 0) found = findDeadNode(currentKey);
                if (found < 0) throw new LuaException("invalid key to 'next'");
                nodeStart = cast(size_t)found + 1;
            }
        } else {
            foreach (size_t i, slot; arrayPart) {
                if (!isNil(slot)) {
                    nextKey = LuaValue(cast(long)(i + 1));
                    nextVal = slot;
                    return true;
                }
            }
        }
        for (size_t i = nodeStart; i < nodeCount; ++i) {
            if (!isNil(nodes[i].value)) {
                nextKey = nodes[i].key;
                nextVal = nodes[i].value;
                return true;
            }
        }
        return false;
    }

    /// Live hash-part entries in insertion order.
    TableEntry[] hashEntries() {
        TableEntry[] result;
        foreach (ref node; nodes[0 .. nodeCount]) if (!isNil(node.value)) result ~= TableEntry(node.key, node.value);
        return result;
    }

    /// Removes every hash-part entry.
    void clearHash() {
        nodes = null; buckets = null; nodeCount = 0; liveCount = 0;
    }

    /// Number of elements stored (array non-nil + hash items)
    size_t count() {
        size_t c = 0;
        foreach (slot; arrayPart) {
            if (!isNil(slot)) c++;
        }
        return c + liveCount;
    }

    /// Removes the strong references held by weak entries so a collection may reclaim their referents.
    /// The returned records must be passed to `weakRestore` right after the collection.
    WeakSaved[] weakHide(bool weakKeys, bool weakValues) {
        WeakSaved[] saved;
        if (weakValues) {
            foreach (i, ref slot; arrayPart) {
                if (!isCollectable(slot)) continue;
                WeakSaved rec;
                rec.inArray = true; rec.index = i;
                rec.hiddenValue = true; rec.valueKind = slot.typeOf(); rec.valueRef = hideReference(collectableObject(slot));
                saved ~= rec;
                slot = luaNil();
            }
        }
        foreach (i, ref node; nodes[0 .. nodeCount]) {
            if (isNil(node.value)) {
                // Removed entries keep their key only for `next`; do not let it pin memory.
                if (!node.dead && !isNil(node.key)) {
                    node.deadHash = node.key.toHash();
                    node.dead = true;
                    node.key = luaNil();
                }
                continue;
            }
            bool wk = weakKeys && isCollectable(node.key);
            bool wv = weakValues && isCollectable(node.value);
            if (!wk && !wv) continue;
            WeakSaved rec;
            rec.index = i;
            if (wk) { rec.hiddenKey = true; rec.keyKind = node.key.typeOf(); rec.keyRef = hideReference(collectableObject(node.key)); }
            else rec.strongKey = node.key;
            if (wv || (wk && isCollectable(node.value))) {
                rec.hiddenValue = true; rec.valueKind = node.value.typeOf(); rec.valueRef = hideReference(collectableObject(node.value));
                rec.ephemeron = wk && !wv;
            } else rec.strongValue = node.value;
            saved ~= rec;
            node.key = luaNil();
            node.value = luaNil();
        }
        return saved;
    }

    /// Calls `visit` on every key and value currently stored (hidden weak entries are absent).
    void forEachReference(scope void delegate(LuaValue) visit) {
        foreach (ref v; arrayPart) if (isCollectable(v)) visit(v);
        foreach (ref n; nodes[0 .. nodeCount]) {
            if (isNil(n.value)) continue;
            if (isCollectable(n.key)) visit(n.key);
            if (isCollectable(n.value)) visit(n.value);
        }
    }

    /// Makes the value of a hidden ephemeron entry strong again (its key was found reachable).
    void ephemeronReveal(ref const WeakSaved rec) {
        nodes[rec.index].value = collectableValue(rec.valueKind, revealReference(rec.valueRef));
    }

    /// Reinstates the entries whose referents survived; the others are removed. Returns the
    /// number of removed entries.
    size_t weakRestore(WeakSaved[] saved) {
        size_t removed;
        foreach (ref rec; saved) {
            bool alive = (!rec.hiddenKey || hiddenReferenceAlive(rec.keyRef)) &&
                (!rec.hiddenValue || hiddenReferenceAlive(rec.valueRef));
            if (rec.inArray) {
                if (alive) arrayPart[rec.index] = collectableValue(rec.valueKind, revealReference(rec.valueRef));
                else ++removed;
                continue;
            }
            if (alive) {
                nodes[rec.index].key = rec.hiddenKey ? collectableValue(rec.keyKind, revealReference(rec.keyRef)) : rec.strongKey;
                nodes[rec.index].value = rec.hiddenValue ? collectableValue(rec.valueKind, revealReference(rec.valueRef)) : rec.strongValue;
            } else {
                // An ephemeron value may have been made strong again for the collection.
                nodes[rec.index].key = luaNil();
                nodes[rec.index].value = luaNil();
                rec.strongKey = luaNil();
                rec.strongValue = luaNil();
                --liveCount;
                ++removed;
            }
        }
        return removed;
    }

    /// A new table object sharing this table's storage (used to hand dead objects to finalizers).
    LuaTable shareStorage() {
        auto copy = new LuaTable();
        copy.arrayPart = arrayPart;
        copy.nodes = nodes; copy.nodeCount = nodeCount; copy.liveCount = liveCount; copy.buckets = buckets;
        copy.metatable = metatable;
        return copy;
    }

    /// True when the hash part holds live entries.
    @property bool hasHashEntries() const { return liveCount != 0; }
}
