/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Emulation of Lua's weak tables and `__gc` finalizers on top of D's collector.
///
/// D's collector offers no weak references, resurrection or conditional roots. A collection
/// cycle therefore (1) clears dead registers of the active frames, (2) hides the weak
/// references of registered weak tables and the references to finalizable objects behind
/// XOR-masked integers, (3) decides in forked probe processes which values of weak-key entries
/// (ephemerons) stay reachable, (4) runs a D collection, (5) reinstates the weak entries whose
/// referents survived and (6) calls `__gc` for finalizable objects that did not, passing a storage-sharing copy of the
/// dead object.
module varis.gc;

import varis.types;
import varis.table;
import varis.state;
import varis.vm : VM, LuaClosure;
import varis.exception : LuaException, isControlSignal;
import core.memory : GC;

private enum size_t weakMaskValue = 0x5A5A_5A5A_5A5A_5A5AUL; // see varis.table.hideReference
private __gshared size_t[] weakTables; // hidden references to registered weak tables

/// True once weak tables or finalizers exist. The VM then clears the dead native stack below each
/// Lua call, so that frames created later do not inherit stale words (which the conservative
/// stack scan would treat as references) from earlier, deeper calls.
__gshared bool stackHygiene;

/// Zeroes the dead part of the native stack below the caller.
pragma(inline, false) @trusted
void scrubDeadStack() {
    // Clearing 16 KB costs far more than a typical Lua call, so only every 32nd call pays it;
    // frames created in between rarely add stale words that survive to the next explicit collection.
    static __gshared uint calls;
    if ((++calls & 31) != 0)
        return;
    ubyte[16384] junk = void;
    scrubMemset(junk.ptr, 0, junk.length);
}

/// Registers `t` for weak-reference processing if its metatable declares weakness.
void registerWeakIfNeeded(LuaTable t) {
    if (t is null || t.metatable is null || t.weakRegistered)
        return;
    auto mode = t.metatable.rawget(LuaValue("__mode"));
    if (!isString(mode))
        return;
    string text = mode.match!((string s) => s, _ => "");
    foreach (c; text)
        if (c == 'k' || c == 'v') {
            t.weakRegistered = true;
            stackHygiene = true;
            weakTables ~= hideReference(t);
            return;
        }
}

@property bool hasWeakTables() {
    return weakTables.length != 0;
}

private struct HiddenTable {
    size_t reference;
    WeakSaved[] saved;
}

private struct HiddenFinalizer {
    size_t reference;
    LuaValue shadow;
}

pragma(inline, false)
private void hideWeakEntries(ref HiddenTable[] hidden) {
    size_t[] live;
    foreach (reference; weakTables) {
        if (!hiddenTableAlive(reference))
            continue;
        auto table = cast(LuaTable) revealReference(reference);
        live ~= reference;
        if (table.metatable is null)
            continue;
        auto mode = table.metatable.rawget(LuaValue("__mode"));
        if (!isString(mode))
            continue;
        bool weakKeys, weakValues;
        foreach (c; mode.match!((string s) => s, _ => "")) {
            if (c == 'k')
                weakKeys = true;
            if (c == 'v')
                weakValues = true;
        }
        if (!weakKeys && !weakValues)
            continue;
        hidden ~= HiddenTable(reference, table.weakHide(weakKeys, weakValues));
    }
    weakTables = live;
}

pragma(inline, false)
private void hideFinalizable(LuaState state, ref HiddenFinalizer[] hidden) {
    foreach (object; state.finalizers) {
        LuaValue shadow;
        size_t reference;
        if (object.typeOf() == LuaType.Table) {
            auto t = object.match!((LuaTable x) => x, _ => null);
            shadow = LuaValue(t.shareStorage());
            reference = hideReference(t);
        } else {
            auto u = object.match!((LuaUserData x) => x, _ => null);
            auto copy = new LuaUserData(u.payload, u.metatable);
            copy.rawPayload = u.rawPayload;
            copy.userValues = u.userValues;
            shadow = LuaValue(copy);
            reference = hideReference(u);
        }
        hidden ~= HiddenFinalizer(reference, shadow);
    }
    state.finalizers = null;
}

/// Zeroes the stack region below the caller so that stale words left by earlier calls
/// (which the conservative collector would treat as pointers) do not show up in the
/// frames of the collection itself.
pragma(inline, false) @trusted
private void scrubStack() {
    ubyte[65536] junk = void;
    scrubMemset(junk.ptr, 0, junk.length);
}

// Called through a mutable pointer: the optimizer cannot prove the memset dead (the array is
// never read), which is what removed the scrubbing when it called memset directly.
private __gshared extern (C) void* function(void*, int, size_t) nothrow @nogc scrubMemset = &scrubFill;

private extern (C) void* scrubFill(void* p, int c, size_t n) nothrow @nogc {
    import core.stdc.string : memset;

    return memset(p, c, n);
}

private void clearDeadRegisters(LuaState state) {
    foreach (ref frame; state.callStack)
        frame.clearDead();
    auto main = state.mainStack();
    foreach (ref frame; main)
        frame.clearDead();
}

/// Runs a full collection cycle with weak-table clearing and finalization.
/// The frame of this entry point is tiny and the stack below it is scrubbed first, so
/// the frames of the cycle itself start without stale words.
pragma(inline, false)
void runGcCycle(LuaState state, bool settle = false) {
    if (state.inGcCycle)
        return;
    scrubStack();
    runGcCycleImpl(state);
    if (settle) {
        // The cycle's own bookkeeping is garbage now; reclaim it so that an explicit
        // collection leaves `collectgarbage("count")` close to the live size.
        scrubStack();
        GC.collect();
    }
}

pragma(inline, false)
private void runGcCycleImpl(LuaState state) {
    if (state.inGcCycle)
        return;
    state.inGcCycle = true;
    scope (exit)
        state.inGcCycle = false;

    clearDeadRegisters(state);
    HiddenTable[] weak;
    HiddenFinalizer[] finalizable;
    hideWeakEntries(weak);
    hideFinalizable(state, finalizable);

    resolveEphemerons(weak);

    // Nothing may be allocated between the collection and the liveness checks below: a new
    // object could reuse the address of a dead one and make it look alive.
    auto survivors = new size_t[weakTables.length];
    auto finalizerAlive = new bool[finalizable.length];
    LuaValue[] pending;
    pending.reserve(finalizable.length);
    scrubStack();
    GC.collect();
    size_t survivorCount;
    foreach (reference; weakTables)
        if (hiddenReferenceAlive(reference))
            survivors[survivorCount++] = reference;
    foreach (i, ref entry; finalizable)
        finalizerAlive[i] = hiddenReferenceAlive(entry.reference);
    // Dead weak tables and threads must leave the registries now: once Lua code runs, their
    // addresses may be reused by other objects.
    weakTables = survivors[0 .. survivorCount];

    size_t removedEntries;
    foreach (ref entry; weak) {
        if (!hiddenReferenceAlive(entry.reference))
            continue;
        removedEntries += (cast(LuaTable) revealReference(entry.reference)).weakRestore(entry.saved);
    }

    foreach (i, ref entry; finalizable) {
        if (finalizerAlive[i]) {
            auto original = revealReference(entry.reference);
            state.finalizers ~= cast(LuaTable) original !is null && entry.shadow.typeOf() == LuaType.Table
                ? LuaValue(cast(LuaTable) original) : LuaValue(cast(LuaUserData) original);
        } else {
            state.finalizerMarked.remove(entry.reference);
            pending ~= entry.shadow;
        }
    }
    if (removedEntries != 0) {
        // Entries removed above may have been the last references to values the first collection
        // had to keep (a string key, for instance); collect again so that memory is reclaimed in
        // the same cycle, as it is with an incremental collector's atomic phase.
        weak = null;
        scrubStack();
        GC.collect();
        size_t kept;
        foreach (reference; weakTables)
            if (hiddenReferenceAlive(reference))
                weakTables[kept++] = reference;
        weakTables = weakTables[0 .. kept];
    }
    // Finalizers run in the reverse order of marking.
    foreach_reverse (shadow; pending)
        callFinalizer(state, shadow);
}

private void callFinalizer(LuaState state, LuaValue object) {
    auto mt = state.getMetatable(object);
    auto gc = mt is null ? luaNil() : mt.rawget(LuaValue("__gc"));
    if (!isFunction(gc))
        return;
    bool previous = state.inFinalizer;
    state.inFinalizer = true;
    scope (exit)
        state.inFinalizer = previous;
    VM.callValue(state, gc, [object], false, "__gc", "metamethod", false, true);
    if (state.raisedError !is null) {
        auto e = state.takeRaised();
        if (isControlSignal(e)) {
            state.deferControl(e); // raised at the next safepoint
            return;
        }
        string text = isString(e.errorObject) ? toLuaString(e.errorObject) : "error object is not a string";
        state.warning("error in ", true);
        state.warning("__gc", true);
        state.warning(" (", true);
        state.warning(text, true);
        state.warning(")", false);
    }
}

/// Called from allocation sites; runs a cycle when enough allocations happened
/// and weak tables, finalizers or coroutines exist. The frames between the interpreter loop and
/// the collection are kept tiny: their uninitialized slots would otherwise be scanned as roots.
pragma(inline, false)
void gcTick(LuaState state) {
    state.allocTicks = 0;
    if (!state.gcRunning || state.inGcCycle || state.closing)
        return;
    if (weakTables.length == 0 && state.finalizers.length == 0)
        return;
    gcTickRun(state);
}

pragma(inline, false)
private void gcTickRun(LuaState state) {
    runGcCycle(state);
    retuneThreshold(state);
}

pragma(inline, false)
private void retuneThreshold(LuaState state) {
    // Keep collection cost proportional to the heap.
    size_t used = GC.stats().usedSize;
    state.gcThreshold = used / 400 > 50_000 ? used / 400 : 50_000;
}

// --- reachability probes ----------------------------------------------------------------------

/// Ephemeron semantics (a weak key keeps its value alive only while the key itself is reachable)
/// cannot be expressed with one collection, because a value that refers back to other weak keys
/// would keep them alive. The hidden values of weak-key entries are therefore resolved by running
/// the reachability probe in forked children, each starting from the untouched heap: a child
/// reinstates the values whose keys are known to be reachable, collects, and reports which keys
/// survived. The rounds repeat until the set of reachable keys is stable; the parent then
/// reinstates exactly those values before its own collection.
private struct EphemeronRef {
    size_t table;
    size_t index;
}

pragma(inline, false)
private void resolveEphemerons(ref HiddenTable[] weak) {
    import core.sys.posix.unistd : fork, pipe, close, read, _exit;
    import core.sys.posix.sys.wait : waitpid;

    EphemeronRef[] entries;
    foreach (ref t; weak)
        foreach (i, ref rec; t.saved)
            if (rec.ephemeron)
                entries ~= EphemeronRef(t.reference, i);
    if (entries.length == 0)
        return;

    HiddenTable* find(size_t reference) {
        foreach (ref t; weak)
            if (t.reference == reference)
                return &t;
        return null;
    }

    auto reveal = new bool[entries.length];
    bool known = true;
    for (size_t round = 0; round <= entries.length; round++) {
        int[2] fds;
        if (pipe(fds) != 0) {
            known = false;
            break;
        }
        auto pid = fork();
        if (pid < 0) {
            close(fds[0]);
            close(fds[1]);
            known = false;
            break;
        }
        if (pid == 0) {
            close(fds[0]);
            ephemeronProbe(weak, entries, reveal, fds[1]);
            _exit(0);
        }
        close(fds[1]);
        auto reported = new ubyte[entries.length];
        size_t got;
        while (got < reported.length) {
            auto n = read(fds[0], reported.ptr + got, reported.length - got);
            if (n <= 0)
                break;
            got += cast(size_t) n;
        }
        close(fds[0]);
        int status;
        waitpid(pid, &status, 0);
        if (got != reported.length) {
            known = false;
            break;
        }
        bool changed;
        foreach (i, flag; reported)
            if (flag && !reveal[i]) {
                reveal[i] = true;
                changed = true;
            }
        if (!changed)
            break;
    }
    if (!known)
        reveal[] = true; // could not probe: keep every value (conservative)
    foreach (i, ref e; entries) {
        if (!reveal[i])
            continue;
        auto t = find(e.table);
        (cast(LuaTable) revealReference(t.reference)).ephemeronReveal(t.saved[e.index]);
    }
}

/// Marks (in `seen`, keyed by object address) every object reachable through tables, closure
/// upvalues and userdata uservalues from `start`. Native closures are opaque, so this
/// under-approximates reachability; the probe rounds still converge, only more slowly.
pragma(inline, false)
private void traceReachable(LuaValue start, ref bool[size_t] seen) {
    LuaValue[] work = [start];
    while (work.length) {
        auto v = work[$ - 1];
        work = work[0 .. $ - 1];
        auto object = collectableObject(v);
        if (object is null)
            continue;
        auto address = cast(size_t) cast(void*) object;
        if (address in seen)
            continue;
        seen[address] = true;
        if (auto t = cast(LuaTable) object) {
            if (t.metatable !is null)
                work ~= LuaValue(t.metatable);
            t.forEachReference((LuaValue child) { work ~= child; });
        } else if (auto c = cast(LuaClosure) object) {
            foreach (up; c.upvalues) {
                if (up is null)
                    continue;
                auto value = up.get();
                if (isCollectable(value))
                    work ~= value;
            }
        } else if (auto u = cast(LuaUserData) object) {
            if (u.metatable !is null)
                work ~= LuaValue(u.metatable);
            foreach (value; u.userValues)
                if (isCollectable(value))
                    work ~= value;
        }
    }
}

/// Body of a probe child: never returns to normal execution (the caller exits the process).
pragma(inline, false)
private void ephemeronProbe(ref HiddenTable[] weak, EphemeronRef[] entries, bool[] reveal, int fd) {
    import core.sys.posix.unistd : write;

    HiddenTable* find(size_t reference) {
        foreach (ref t; weak)
            if (t.reference == reference)
                return &t;
        return null;
    }
    // Values of entries already known reachable are strong again; objects reachable from them make
    // further keys reachable, which cascades without another collection.
    bool[size_t] seen;
    auto known = reveal.dup;
    foreach (i, ref e; entries) {
        if (!known[i])
            continue;
        auto t = find(e.table);
        (cast(LuaTable) revealReference(t.reference)).ephemeronReveal(t.saved[e.index]);
        traceReachable(collectableValue(t.saved[e.index].valueKind, revealReference(t.saved[e.index].valueRef)), seen);
    }
    bool progress = true;
    while (progress) {
        progress = false;
        foreach (i, ref e; entries) {
            if (known[i])
                continue;
            auto t = find(e.table);
            if ((t.saved[e.index].keyRef ^ weakMaskValue) !in seen)
                continue;
            known[i] = true;
            progress = true;
            (cast(LuaTable) revealReference(t.reference)).ephemeronReveal(t.saved[e.index]);
            traceReachable(collectableValue(t.saved[e.index].valueKind, revealReference(t.saved[e.index].valueRef)), seen);
        }
    }
    seen = null;
    // Nothing may be allocated between the collection and the liveness checks: a new object could
    // reuse the address of a dead key.
    auto flags = new ubyte[entries.length];
    auto refs = new size_t[entries.length];
    foreach (i, ref e; entries)
        refs[i] = find(e.table).saved[e.index].keyRef;
    scrubStack();
    GC.collect();
    foreach (i; 0 .. entries.length)
        flags[i] = known[i] || hiddenReferenceAlive(refs[i]) ? 1 : 0;
    size_t sent;
    while (sent < flags.length) {
        auto n = write(fd, flags.ptr + sent, flags.length - sent);
        if (n <= 0)
            break;
        sent += cast(size_t) n;
    }
}
