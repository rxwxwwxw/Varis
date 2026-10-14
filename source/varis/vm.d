/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.vm;

import varis.types;
import varis.table;
import varis.opcode;
import varis.state;
import varis.exception : LuaException, ExitRequest;
import varis.lib.auxlib : ArgError;
import varis.fiber : VarisFiber, CoroutineClose, currentLuaFiber, isNoYieldScope, isReadOnlyEvaluation,
    isNotificationDispatch;
import core.thread : Fiber;
import std.format : format;
import std.conv : to;
import std.array : replace;
import std.math : isNaN, floor, ceil;
import core.stdc.math : pow;
import std.algorithm : max;

/// Represents an upvalue (either open pointing to stack slot, or closed holding value)
class UpValue {
    LuaValue* valPtr;
    LuaValue closedVal;
    bool isClosed = false;
    int stackIndex;
    UpValue nextOpen; // next open upvalue of the same frame (see VM.executeFrame)

    this(LuaValue* ptr, int stackIndex) {
        this.valPtr = ptr;
        this.stackIndex = stackIndex;
        this.isClosed = false;
    }

    /// Address of the current value (the stack slot while open, `closedVal` once closed).
    pragma(inline, true)
    final LuaValue* ptr() {
        return isClosed ? &closedVal : valPtr;
    }

    LuaValue get() {
        return isClosed ? closedVal : *valPtr;
    }

    void set(LuaValue val) {
        if (isClosed) {
            closedVal = val;
        } else {
            *valPtr = val;
        }
    }

    void close() {
        if (!isClosed) {
            closedVal = *valPtr;
            valPtr = &closedVal;
            isClosed = true;
        }
    }
}

/// A callable Lua closure wrapping a bytecode prototype and upvalues
class LuaClosure : LuaFunction {
    Prototype proto;
    UpValue[] upvalues;

    UpValue[2] inlineUpvalues; // storage for closures with at most two upvalues (saves an allocation)

    this(Prototype proto, UpValue[] upvalues = null) {
        super(proto.functionName);
        this.isLuaClosure = true;
        this.proto = proto;
        this.upvalues = upvalues;
    }

    /// A closure with room for `count` upvalues, which the caller then fills in.
    this(Prototype proto, size_t count) {
        super(proto.functionName);
        this.isLuaClosure = true;
        this.proto = proto;
        upvalues = count <= inlineUpvalues.length ? inlineUpvalues[0 .. count] : new UpValue[count];
    }

    override LuaValue[] call(void* statePtr, LuaValue[] args) {
        auto state = cast(LuaState) statePtr;
        return VM.execute(state, this, args);
    }
}

enum size_t luaMaxStack = 1_000_000;

/// Set asynchronously (SIGINT handler) to stop the running Lua code with "interrupted!".
__gshared bool vmInterrupt;

/// Inline integer/float fast path of a binary arithmetic instruction (breaks out of the
/// dispatch `switch` when it applies). The operator is a D operator token.
private string fastArithmetic(string op) {
    return `{
        auto left = instr.bIsK ? &proto.constants[instr.b] : &registers[instr.b];
        auto right = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
        if (left.isInteger && right.isInteger) {
            setInteger(registers[instr.a], left.asInteger `
        ~ op ~ ` right.asInteger);
            continue;
        }
        if (left.isFloat && right.isFloat) {
            setFloat(registers[instr.a], left.asFloat `
        ~ op ~ ` right.asFloat);
            continue;
        }
        if ((left.isFloat || left.isInteger) && (right.isFloat || right.isInteger)) {
            // Mixed operands: the integer converts to float, as in C Lua.
            setFloat(registers[instr.a], (left.isFloat ? left.asFloat : cast(double) left.asInteger) `
        ~ op ~ ` (right.isFloat ? right.asFloat : cast(double) right.asInteger));
            continue;
        }
    }`;
}

/// Inline path of `/`: any two numbers divide as floats.
private enum string fastDivision = q{{
    auto left = instr.bIsK ? &proto.constants[instr.b] : &registers[instr.b];
    auto right = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
    if ((left.isFloat || left.isInteger) && (right.isFloat || right.isInteger)) {
        setFloat(registers[instr.a], (left.isFloat ? left.asFloat : cast(double) left.asInteger)
                / (right.isFloat ? right.asFloat : cast(double) right.asInteger));
        continue;
    }
}};

private static immutable size_t indexNameHash = hashOf("__index");
private static immutable size_t newindexNameHash = hashOf("__newindex");

/// Field lookup with a constant string key through chains of plain-table `__index` handlers.
/// Returns 1 with the stored value in `found`, 0 for a definite nil, or -1 when the generic
/// path must run (function handlers, deep chains).
private int lookupFieldFast(LuaTable table, string key, size_t hash, ref int hint, out LuaValue* found) {
    auto current = table;
    auto slot = current.findStringHintedHashed(key, hash, hint);
    for (int depth = 0;; ++depth) {
        if (slot !is null && !slot.isNil) {
            found = slot;
            return 1;
        }
        auto meta = current.metatable;
        if (meta is null)
            return 0;
        auto handler = meta.findStringHashed("__index", indexNameHash);
        if (handler is null || handler.isNil)
            return 0;
        if (!handler.isTable || depth >= 64)
            return -1;
        current = handler.asTable;
        slot = current.findStringHashed(key, hash);
    }
}

/// A frame-scoped transaction (BeginTransaction ... EndTransaction).
private struct FrameTransaction {
    FrameScope transaction;
    int startPC;
    int endPC;
    int firstRegister;
}

/// The state of a Lua frame that is waiting for a callee executed inline by `executeDeepFrame`.
/// Records live in fixed-size chunks that are never moved, so call records may point into them.
private struct SavedFrame {
    LuaClosure closure;
    LuaValue[] registers, cachedBuffer, varargs;
    UpValue openUpvalues;
    int[] toClose;
    FrameTransaction[] frameTransactions;
    const(Instruction)* ip;
    int top, debugLimit;
    int resultBase, wanted; // where the callee's results go, and how many are wanted (-1: all)

    void release() {
        closure = null;
        registers = null;
        cachedBuffer = null;
        varargs = null;
        openUpvalues = null;
        toClose = null;
        frameTransactions = null;
        ip = null;
    }
}

private enum size_t savedFrameChunk = 256;
private final class SavedFrameChunk {
    SavedFrame[savedFrameChunk] frames;
}

private SavedFrame* parkedFrame(LuaThread thread, size_t index) {
    auto chunk = cast(SavedFrameChunk) cast(void*) thread.inlineFrames[index / savedFrameChunk];
    return &chunk.frames[index % savedFrameChunk];
}

private SavedFrame* parkNewFrame(LuaThread thread) {
    size_t index = thread.inlineTop++;
    if (index / savedFrameChunk == thread.inlineFrames.length)
        thread.inlineFrames ~= new SavedFrameChunk();
    return parkedFrame(thread, index);
}

// Frame transitions of VM.executeFrame, expanded in place (string mixins) so that the frame's
// variables stay ordinary locals instead of being captured by nested functions.
private enum string enterFrameCode = q{
{
            auto p = efClosure.proto;
            if (!p.prepared) prepareForExecution(p);
            size_t slots = cast(size_t)p.maxStackSize + 1;
            checkStackLimits(frameThread, sp, slots);
            if (slots > LuaThread.smallFrameSlots) frameThread.stackSlots += slots;
            frameSlots = slots;
            closure = efClosure;
            proto = p;
            size_t stackSize = max(cast(size_t)p.maxStackSize + 8, 8);
            registerDepth = frameThread.registerDepth++;
            // Registers come from the thread's value stack, as in executeFrame: a bump allocation
            // whose free area is always nil, so entering a frame allocates nothing. `cachedBuffer`
            // remembers the frame's region (the registers may later move to their own array).
            {
                auto stackArray = frameThread.valueStack;
                size_t stackBase = frameThread.valueTop;
                if (stackBase + stackSize > stackArray.length) {
                    // Chunks stop doubling at 64K values: a runaway recursion then adds memory in
                    // steps instead of allocating (and scanning) ever larger arrays.
                    size_t capacity = stackArray.length * 2;
                    if (capacity < 128) capacity = 128;
                    if (capacity > 65_536) capacity = 65_536;
                    if (capacity < stackSize * 2) capacity = stackSize * 2;
                    stackArray = new LuaValue[capacity];
                    stackBase = 0;
                    frameThread.valueStack = stackArray;
                }
                frameThread.valueTop = stackBase + stackSize;
                cachedBuffer = stackArray[stackBase .. stackBase + stackSize];
                registers = cachedBuffer;
            }
            for (int i = 0; i < p.numParams; ++i) {
                if (i < efArgs.length) registers[i] = efArgs[i];
            }
            varargs = null;
            if (p.isVararg && efArgs.length > cast(size_t)p.numParams)
                // Plain calls leave the arguments untouched in the caller's registers (the caller is
                // suspended until this frame ends), so the varargs can alias them; tail-called
                // frames get a reused buffer that is cleared below and need their own copy.
                varargs = efTail ? efArgs[cast(size_t)p.numParams .. $].dup : efArgs[cast(size_t)p.numParams .. $];
            // Tail-called frames receive their arguments in a reused buffer: release the references.
            if (efTail) clearValues(efArgs);
            openUpvalues = null;
            toClose = null;
            frameTransactions = null;
            transactionError = false;
            code = p.execCode;
            codeBase = code.ptr;
            ip = codeBase;
            ipSlot = ip;
            top = p.maxStackSize;
            debugLimit = p.maxStackSize;
            lastHookPC = -1;
            lastHookLine = -1;
            frameLive = true;
            callVisible = true;
            state.pushCall(efClosure, p.sourceName, -1, efTail, efName, efKind, &registers, &varargs, &ipSlot, &debugLimit);
        }
};

private enum string leaveFrameCode = q{
{
            if (frameLive) {
            frameLive = false;
            closeUpvaluesFrom(0);
            if (callVisible) { state.popCall(); callVisible = false; }
            while (frameTransactions.length) {
                frameTransactions[$ - 1].transaction.finish(!transactionError);
                frameTransactions.length--;
            }
            // Close handlers, transactions and open upvalues have finished: the buffer can be reused.
            // Only the frame's own view is cleared; the rest of a cached buffer is nil.
            clearValues(cachedBuffer);
            {
                auto live = frameThread.valueStack;
                if (cachedBuffer.length && live.ptr <= cachedBuffer.ptr && cachedBuffer.ptr < live.ptr + live.length) {
                    frameThread.valueTop = cachedBuffer.ptr - live.ptr;
                    // Do not keep the stack of a very deep recursion alive once it is empty.
                    if (frameThread.valueTop == 0 && live.length > 65_536)
                        frameThread.valueStack = null;
                }
            }
            --frameThread.registerDepth;
            if (frameSlots > LuaThread.smallFrameSlots) frameThread.stackSlots -= frameSlots;
            if (frameThread.overflowed && frameThread.stackUse() + 400 <= luaMaxStack
                && sp > frameThread.nativeSoftLimit + 256 * 1024)
                frameThread.overflowed = false;
        
            }
}
};

private enum string saveCallerCode = q{
{
            auto rec = parkNewFrame(frameThread);
            rec.closure = closure;
            rec.registers = registers; rec.cachedBuffer = cachedBuffer; rec.varargs = varargs;
            rec.openUpvalues = openUpvalues; rec.toClose = toClose; rec.frameTransactions = frameTransactions;
            rec.ip = ip; rec.top = top; rec.debugLimit = debugLimit;
            rec.resultBase = scResultBase; rec.wanted = scWanted;
            record = rec;
        }
};

private enum string restoreCallerCode = q{
{
            auto rec = parkedFrame(frameThread, --frameThread.inlineTop);
            closure = rec.closure; proto = closure.proto;
            registers = rec.registers; cachedBuffer = rec.cachedBuffer; varargs = rec.varargs;
            openUpvalues = rec.openUpvalues; toClose = rec.toClose; frameTransactions = rec.frameTransactions;
            transactionError = false; callVisible = true; frameLive = true;
            code = proto.execCode; codeBase = code.ptr; ip = rec.ip; ipSlot = ip;
            top = rec.top; debugLimit = rec.debugLimit;
            --registerDepth;                          // the callee ran one level above its caller
            frameSlots = cast(size_t)proto.maxStackSize + 1;
            lastHookPC = -1; lastHookLine = -1;
            auto info = &(*frameCalls)[$ - 1];
            info.registers = &registers; info.varargs = &varargs; info.pc = &ipSlot; info.debugLimit = &debugLimit;
            rec.release();
        }
};

/// Raises the Lua/native stack overflow errors before any state of the frame being entered exists.
private void checkStackLimits(LuaThread frameThread, size_t sp, size_t slots) {
    // Approximate (see LuaThread.stackUse): small frames are charged a flat amount each.
    size_t total = frameThread.stackUse() + (slots > LuaThread.smallFrameSlots ? slots : LuaThread.smallFrameCharge);
    if (total > luaMaxStack || (frameThread.nativeStackLimit != 0 && sp < frameThread.nativeSoftLimit)) {
        bool nativeSoft = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeSoftLimit;
        bool nativeHard = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeStackLimit;
        if (nativeHard || total > luaMaxStack + 200) {
            auto nested = new LuaException("error in error handling");
            nested.needsLocation = false;
            throw nested;
        }
        if ((nativeSoft || total > luaMaxStack) && !frameThread.overflowed) {
            frameThread.overflowed = true;
            throw new LuaException("stack overflow");
        }
    }
}

/// Sets every value to nil with one memset (`LuaValue.init` is all zero bytes; the element-wise
/// assignment of `LuaValue.init` compiles to a per-element loop).
pragma(inline, true) @trusted
private void clearValues(LuaValue[] values) {
    import core.stdc.string : memset;

    if (values.length)
        memset(values.ptr, 0, values.length * LuaValue.sizeof);
}

/// Recomputes the interpreter's attention flag (kept out of line so the loop's fast path stays small).
pragma(inline, false)
private void refreshAttention() {
    vmAttention = vmSlowMode;
}

// One iteration of VM.executeFrame's dispatch loop: fetch, the instrumented duties, and the
// switch over the opcode. It is expanded twice in that function, with `instrumented` false and
// true (see there). Inside it `continue` goes straight to the next instruction and `break` out
// of the switch reaches the fast loop's safepoint first; only paths that cannot have called out
// of the loop, and are not backward jumps, may use `continue`.
private enum string frameLoopBody = q{
                // The instrumented loop does every rare per-instruction duty (instruction budget,
                // pending collection, interrupt, hooks); the fast loop contains none of that code.
                enum bool attention = instrumented;
                static if (instrumented) {
                    if (vmSlowMode && state.analysisBudget !is null && ip.op != OpCode.ExitTransaction) {
                        if (budgetPrepaid)
                            budgetPrepaid = false;
                        else {
                            if (!state.analysisBudget.remaining)
                                {
                                    state.raisedError = new LuaException("ANALYSIS_STEP_LIMIT: VM instruction budget exhausted");
                                    mixin(reportedFailure);
                                }
                            state.analysisBudget.remaining--;
                        }
                    }
                    // Every way out of a transaction block ends it: EndTransaction, Rollback, an
                    // ExitTransaction trampoline, a return or an error.
                    assert(!frameTransactions.length || ip.op == OpCode.ExitTransaction
                            || (curPC() >= frameTransactions[$ - 1].startPC && curPC() < frameTransactions[$ - 1].endPC));
                }
                ref const instr = *ip++;
                // An ExitTransaction trampoline is not an instruction of the program: no hook, no
                // collection and no interrupt is attributed to it.
                static if (instrumented) if (instr.op != OpCode.ExitTransaction) {
                    vmAttention = vmSlowMode;
                    if (state.pendingCollect) {
                        // collectgarbage requested a collection: run it here, where the native stack is
                        // shallow, so stale words in dead frames cannot keep objects alive.
                        state.pendingCollect = false;
                        import varis.gc : runGcCycle;

                        runGcCycle(state, true);
                    }
                    if (vmInterrupt) {
                        vmInterrupt = false;
                        {
                            state.raisedError = new LuaException("interrupted!");
                            mixin(reportedFailure);
                        }
                    }
                    auto thread = frameThread;
                    if (thread !is null && !thread.hookActive) {
                        // Hooks installed mid-frame: the last executed instruction was the one before
                        // this fetch (the call that installed them), which is not recorded in fast mode.
                        if (lastHookPC < 0 && curPC() > 1) {
                            lastHookPC = curPC() - 2;
                            lastHookLine = code[curPC() - 2].line;
                        }
                        if ((thread.hookMask & 8) && --thread.hookRemaining == 0) {
                            thread.hookRemaining = thread.hookCount;
                            state.debugHook("count");
                        }
                        if ((thread.hookMask & 4) && (instr.line > 0 ? (curPC() - 1 <= lastHookPC || instr.line != lastHookLine) : (
                                lastHookPC < 0 || curPC() - 1 <= lastHookPC)))
                            state.debugHook("line", instr.line > 0 ? instr.line : -1);
                        lastHookPC = curPC() - 1;
                        lastHookLine = instr.line;
                    }
                    // Leaving the detailed checks: the position tracker goes stale, so forget it and
                    // let the next entry rebuild it from the preceding instruction.
                    if (!vmSlowMode)
                        lastHookPC = -1;
                    if (state.pendingCollect || vmInterrupt)
                        vmAttention = true;
                }
                auto op = instr.op;

                switch (op) {
                    mixin(sharedOpcodeCases1);

                case OpCode.TailCall: {
                        checkCallable(state, registers[instr.a]);
                        if (isNativeFunction(registers[instr.a])) {
                            // A C function is called in place, as a regular call (lua 5.4 precallC):
                            // its errors are attributed to this frame and call site.
                            int nativeArgs = instr.b == 0 ? top - instr.a - 1 : instr.b - 1;
                            auto nativeFunction = registers[instr.a].asFunction;
                            if (nativeFunction.fastCall !is null && frameThread.hookFunction is null) {
                                // Hot built-ins (`return setmetatable(...)`) run straight on the registers.
                                int produced = nativeFunction.fastCall(cast(void*) state, registers, instr.a, nativeArgs);
                                if (produced < -1) {
                                    // Results that did not fit the registers were stashed.
                                    auto stashed = state.stashedResults;
                                    state.stashedResults = null;
                                    closeValuesFrom(0);
                                    return stashed.dup;
                                }
                                if (produced >= 0) {
                                    closeValuesFrom(0);
                                    if (produced == 0)
                                        return [];
                                    if (frameThread.returnBuffers.length <= registerDepth)
                                        frameThread.returnBuffers.length = registerDepth + 1;
                                    if (frameThread.returnBuffers[registerDepth].length < cast(size_t) produced)
                                        frameThread.returnBuffers[registerDepth] = new LuaValue[produced];
                                    auto buffer = frameThread.returnBuffers[registerDepth][0 .. produced];
                                    for (int i = 0; i < produced; ++i)
                                        copyValue(buffer[i], registers[instr.a + i]);
                                    return buffer;
                                }
                            }
                            debugLimit = instr.a;
                            auto nativeResults = doCall(state, closure, proto, registers, instr.a, nativeArgs, curPC() - 1);
                            if (state.raisedError !is null) {
                                raisedError = state.takeRaised(); // no throw: straight to the frame's handler
                                break interpret;
                            }
                            debugLimit = proto.maxStackSize;
                            closeValuesFrom(0);
                            state.debugHook("return", -1, nativeResults, true);
                            return nativeResults;
                        }
                        int count = instr.b == 0 ? top - instr.a - 1 : instr.b - 1;
                        if (!registers[instr.a].isFunction) {
                            // A callable object may resolve to a native, which is handed the lexical
                            // world of this site (see runTailCalls); a Lua callee needs none.
                            int context = proto.callSites[curPC() - 1].world;
                            frameThread.tailWorld = context > 0 ? unwrapWorld(registers[context - 1]) : context < 0 ? unwrapWorld(
                                    closure.upvalues[-context - 1].get()) : state.globalWorldObject;
                        }
                        frameThread.tailCallee = registers[instr.a];
                        if (toClose.length) {
                            // Close handlers may run Lua code (and tail calls of their own): keep a private copy.
                            frameThread.tailArguments = count > 0 ? registers[instr.a + 1 .. instr.a + 1 + count].dup
                                : [
                            ];
                            closeValuesFrom(0);
                        } else {
                            // The callee copies its arguments into its own registers on entry (and clears
                            // them, see `transferred`), so a per-thread buffer is enough.
                            if (frameThread.tailBuffer.length < cast(size_t) count)
                                frameThread.tailBuffer = new LuaValue[cast(size_t) count * 2 + 8];
                            auto buffer = frameThread.tailBuffer[0 .. count];
                            for (int i = 0; i < count; ++i)
                                copyValue(buffer[i], registers[instr.a + 1 + i]);
                            frameThread.tailArguments = buffer;
                            closeUpvaluesFrom(0);
                        }
                        tail.pending = true;
                        return [];
                    }

                case OpCode.Call: {
                        int numArgs = (instr.b == 0) ? cast(int)(top - (instr.a + 1)) : (instr.b - 1);
                        int numWantedResults = instr.c - 1;
                        if (numWantedResults >= 0 && instr.a + numWantedResults >= registers.length)
                            growRegisters(instr.a + numWantedResults + 8);

                        if (registers[instr.a].isFunction) {
                            auto calleeFunction = registers[instr.a].asFunction;
                            if (calleeFunction is state.errorFunction && frameThread.hookFunction is null && numArgs >= 1
                                    && (numArgs == 1 || registers[instr.a + 2].isNil || registers[instr.a + 2]
                                        .isInteger)) {
                                // `error(message [, level])` raised straight from the interpreter: one throw
                                // instead of two (no native call wrapper to unwind through).
                                long level = numArgs >= 2 && registers[instr.a + 2].isInteger ? registers[instr.a + 2]
                                    .asInteger : 1;
                                auto site = &proto.callSites[curPC() - 1];
                                state.pushCall(calleeFunction, "[C]", -1, false, site.name, site.kind);
                                auto errorObject = registers[instr.a + 1];
                                if (errorObject.isString && level > 0)
                                    errorObject = LuaValue(
                                            state.locationPrefix(cast(int) level) ~ toLuaString(errorObject));
                                auto raised = new LuaException(errorObject);
                                raised.needsLocation = false;
                                raised.originFunction = calleeFunction;
                                raised.originName = site.name;
                                raised.originKind = site.kind;
                                state.dispatchError(raised);
                                state.popCall();
                                raisedError = raised;
                                break interpret;
                            }
                            if (calleeFunction.fastCall !is null && frameThread.hookFunction is null) {
                                // Hot built-ins run straight on the registers (see varis.lib.fastcall).
                                int produced = calleeFunction.fastCall(cast(void*) state, registers, instr.a, numArgs);
                                if (produced < -1) {
                                    // Results that did not fit were stashed (see lib.coroutine.fastWrapCall).
                                    int stashed = -2 - produced;
                                    growRegisters(instr.a + (stashed > numWantedResults ? stashed : numWantedResults) + 8);
                                    placeStashedResults(state, registers, instr.a);
                                    produced = stashed;
                                }
                                if (produced >= 0) {
                                    if (numWantedResults >= 0) {
                                        for (int i = produced; i < numWantedResults; ++i)
                                            registers[instr.a + i] = luaNil();
                                        top = instr.a + numWantedResults;
                                    } else
                                        top = instr.a + produced;
                                    break;
                                }
                            }
                        }
                        debugLimit = instr.a;
                        int resultTop;
                        if (registers[instr.a].isFunction && registers[instr.a].asFunction.isLuaClosure) {
                            // Lua → Lua call: run the callee directly; its results are written into
                            // R[a ...] by its Return (see TailRequest.placeInDest).
                            auto callee = cast(LuaClosure) cast(void*) registers[instr.a].asFunction;
                            auto site = &proto.callSites[curPC() - 1];
                            import varis.gc : stackHygiene, scrubDeadStack;

                            if (stackHygiene)
                                scrubDeadStack();
                            TailRequest childTail;
                            childTail.placeInDest = true;
                            childTail.returnErrors = true; // a failing callee returns its error (no rethrow per frame)
                            childTail.wanted = numWantedResults;
                            childTail.dest = numWantedResults >= 0 ? registers[instr.a .. instr.a + numWantedResults]
                                : registers[instr.a .. $];
                            auto childResults = registerDepth >= inlineDepthThreshold
                                ? executeDeepFrame(state, callee, registers[instr.a + 1 .. instr.a + 1 + numArgs],
                                        childTail, false, site.name, site.kind) : executeFrame(state, callee, registers[instr
                                        .a + 1 .. instr.a + 1 + numArgs],
                            childTail, false, site.name, site.kind);
                            bool childPlaced = childTail.placed;
                            size_t childCount = childTail.placedCount;
                            if (childTail.pending)
                                childResults = runTailCalls(state, childTail, childPlaced, childCount);
                            if (childTail.error !is null) {
                                raisedError = childTail.error;
                                break interpret;
                            }
                            if (childPlaced)
                                resultTop = instr.a + cast(int) childCount;
                            else if (numWantedResults >= 0) {
                                size_t available = childResults.length < cast(size_t) numWantedResults ? childResults
                                    .length : cast(size_t) numWantedResults;
                                for (size_t i = 0; i < available; ++i)
                                    copyValue(registers[instr.a + i], childResults[i]);
                                for (size_t i = available; i < cast(size_t) numWantedResults; ++i)
                                    registers[instr.a + i] = luaNil();
                                resultTop = instr.a + numWantedResults;
                            } else if (instr.a + childResults.length >= registers.length) {
                                state.stashedResults = childResults;
                                resultTop = -cast(int) childResults.length;
                            } else {
                                for (size_t i = 0; i < childResults.length; ++i)
                                    copyValue(registers[instr.a + i], childResults[i]);
                                resultTop = instr.a + cast(int) childResults.length;
                            }
                        } else {
                            // The call and the placement of its results happen in one frame of their own so
                            // that no array holding result values stays referenced from this frame.
                            resultTop = callAndPlace(state, closure, proto, registers, instr.a, numArgs, numWantedResults, curPC() - 1);
                            if (resultTop == callRaised) {
                                raisedError = state.takeRaised(); // no throw: straight to the frame's handler
                                break interpret;
                            }
                        }
                        debugLimit = proto.maxStackSize;
                        if (resultTop < 0) {
                            // Variable results did not fit: grow, then copy the stashed values.
                            growRegisters(instr.a + (-resultTop) + 8);
                            resultTop = placeStashedResults(state, registers, instr.a);
                        }
                        top = resultTop;
                        break;
                    }

                case OpCode.Return: {
                        int numRet = instr.b - 1;
                        LuaValue[] returned;
                        if (numRet < 0) {
                            int endReg = (top > instr.a) ? top : instr.a;
                            if (endReg > registers.length)
                                endReg = cast(int) registers.length;
                            returned = (endReg > instr.a) ? registers[instr.a .. endReg] : [];
                        } else if (numRet == 0) {
                            returned = [];
                        } else {
                            returned = registers[instr.a .. instr.a + numRet];
                        }
                        if (tail.placeInDest) {
                            // Deliver results straight into the caller's registers.
                            auto destination = tail.dest;
                            size_t count = returned.length;
                            if (tail.wanted >= 0) {
                                size_t want = cast(size_t) tail.wanted;
                                size_t copied = count < want ? count : want;
                                for (size_t i = 0; i < copied; ++i)
                                    copyValue(destination[i], returned[i]);
                                for (size_t i = copied; i < want; ++i)
                                    destination[i] = luaNil();
                                tail.placed = true;
                                tail.placedCount = want;
                            } else if (count < destination.length) {
                                for (size_t i = 0; i < count; ++i)
                                    copyValue(destination[i], returned[i]);
                                tail.placed = true;
                                tail.placedCount = count;
                            }
                        }
                        if (!tail.placed && frameThread !is null && returned.length > 0) {
                            if (frameThread.returnBuffers.length <= registerDepth)
                                frameThread.returnBuffers.length = registerDepth + 1;
                            if (frameThread.returnBuffers[registerDepth].length < returned.length)
                                frameThread.returnBuffers[registerDepth] = new LuaValue[returned.length];
                            auto dest = frameThread.returnBuffers[registerDepth][0 .. returned.length];
                            dest[] = returned[];
                            returned = dest;
                        }
                        if (toClose.length)
                            closeValuesFrom(0);
                        else
                            closeUpvaluesFrom(0);
                        if (frameThread.hookFunction !is null)
                            state.debugHook("return", -1, returned, true);
                        return tail.placed ? null : returned;

                        // Numeric For
                    }

                    mixin(sharedOpcodeCases2);

                default:
                    {
                        state.raisedError = new LuaException(format("unknown opcode: %s", op));
                        mixin(reportedFailure);
                    }
                }
};

// One iteration of VM.executeDeepFrame's dispatch loop; see frameLoopBody. A switch of frames
// (an inline call, a tail call, a return to a parked caller) leaves the switch with `break`, so
// the next instruction is reached through the safepoint.
private enum string deepFrameLoopBody = q{
                        // See frameLoopBody: the instrumented loop does the rare per-instruction duties.
                        enum bool attention = instrumented;
                        static if (instrumented) {
                            if (vmSlowMode && state.analysisBudget !is null && ip.op != OpCode.ExitTransaction) {
                                if (budgetPrepaid)
                                    budgetPrepaid = false;
                                else {
                                    if (!state.analysisBudget.remaining)
                                        {
                                            state.raisedError = new LuaException("ANALYSIS_STEP_LIMIT: VM instruction budget exhausted");
                                            mixin(reportedFailure);
                                        }
                                    state.analysisBudget.remaining--;
                                }
                            }
                            // See executeFrame: every way out of a transaction block ends it.
                            assert(!frameTransactions.length || ip.op == OpCode.ExitTransaction
                                    || (cast(int)(ip - codeBase) >= frameTransactions[$ - 1].startPC
                                        && cast(int)(ip - codeBase) < frameTransactions[$ - 1].endPC));
                        }
                        ref const instr = *ip++;
                        ipSlot = ip;
                        // See executeFrame: a trampoline is not an instruction of the program.
                        static if (instrumented) if (instr.op != OpCode.ExitTransaction) {
                            refreshAttention();
                            if (state.pendingCollect) {
                                // collectgarbage requested a collection: run it here, where the native stack is
                                // shallow, so stale words in dead frames cannot keep objects alive.
                                state.pendingCollect = false;
                                import varis.gc : runGcCycle;

                                runGcCycle(state, true);
                            }
                            if (vmInterrupt) {
                                vmInterrupt = false;
                                {
                                    state.raisedError = new LuaException("interrupted!");
                                    mixin(reportedFailure);
                                }
                            }
                            auto thread = frameThread;
                            if (thread !is null && !thread.hookActive) {
                                // Hooks installed mid-frame: the last executed instruction was the one before
                                // this fetch (the call that installed them), which is not recorded in fast mode.
                                if (lastHookPC < 0 && cast(int)(ip - codeBase) > 1) {
                                    lastHookPC = cast(int)(ip - codeBase) - 2;
                                    lastHookLine = code[cast(int)(ip - codeBase) - 2].line;
                                }
                                if ((thread.hookMask & 8) && --thread.hookRemaining == 0) {
                                    thread.hookRemaining = thread.hookCount;
                                    state.debugHook("count");
                                }
                                if ((thread.hookMask & 4) && (instr.line > 0 ? (
                                        cast(int)(ip - codeBase) - 1 <= lastHookPC || instr.line != lastHookLine) : (
                                        lastHookPC < 0 || cast(int)(ip - codeBase) - 1 <= lastHookPC)))
                                    state.debugHook("line", instr.line > 0 ? instr.line : -1);
                                lastHookPC = cast(int)(ip - codeBase) - 1;
                                lastHookLine = instr.line;
                            }
                            // Leaving the detailed checks: the position tracker goes stale, so forget it and
                            // let the next entry rebuild it from the preceding instruction.
                            if (!vmSlowMode)
                                lastHookPC = -1;
                            if (state.pendingCollect || vmInterrupt)
                                vmAttention = true;
                        }
                        auto op = instr.op;

                        switch (op) {
                            mixin(sharedOpcodeCases1);

                        case OpCode.TailCall: {
                                checkCallable(state, registers[instr.a]);
                                auto target = registers[instr.a];
                                int count = instr.b == 0 ? top - instr.a - 1 : instr.b - 1;
                                LuaValue[] callArgs; // set when the callee needs a private argument array
                                bool replaceFrame = target.isFunction && target.asFunction.isLuaClosure;
                                if (!replaceFrame && !isNativeFunction(target)) {
                                    // A callable object: resolve __call chains, then treat the result as above.
                                    callArgs = count > 0 ? registers[instr.a + 1 .. instr.a + 1 + count].dup : [
                                    ];
                                    resolveCallable(state, target, callArgs);
                                    replaceFrame = target.isFunction && target.asFunction.isLuaClosure;
                                    if (!replaceFrame) {
                                        // Native handler: called in place, its results are this frame's results.
                                        // It runs with the lexical world of this site, as in executeFrame.
                                        debugLimit = instr.a;
                                        int context = proto.callSites[cast(int)(ip - codeBase) - 1].world;
                                        auto previousWorld = state.callWorldObject;
                                        state.callWorldObject = context > 0 ? unwrapWorld(registers[context - 1]) : context < 0 ? unwrapWorld(
                                                closure.upvalues[-context - 1].get()) : state.globalWorldObject;
                                        LuaValue[] resolved;
                                        {
                                            scope (exit)
                                                state.callWorldObject = previousWorld;
                                            resolved = callValue(state, target, callArgs, true);
                                        }
                                        debugLimit = proto.maxStackSize;
                                        forcedReturn = resolved;
                                        useForcedReturn = true;
                                        goto case OpCode.Return;
                                    }
                                }
                                if (!replaceFrame) {
                                    // A C function is called in place, as a regular call (lua 5.4 precallC):
                                    // its errors are attributed to this frame and call site.
                                    debugLimit = instr.a;
                                    forcedReturn = doCall(state, closure, proto, registers, instr.a, count, cast(int)(
                                            ip - codeBase) - 1);
                                    if (state.raisedError !is null)
                                        throw state.takeRaised(); // see the Call handler below
                                    debugLimit = proto.maxStackSize;
                                    useForcedReturn = true;
                                    goto case OpCode.Return;
                                }
                                auto newClosure = cast(LuaClosure) cast(void*) target.asFunction;
                                LuaValue[] newArgs;
                                if (callArgs !is null) {
                                    closeValuesFrom(0);
                                    newArgs = callArgs;
                                } else if (toClose.length) {
                                    // Close handlers may run Lua code (and tail calls of their own): keep a private copy.
                                    newArgs = count > 0 ? registers[instr.a + 1 .. instr.a + 1 + count].dup : [
                                    ];
                                    closeValuesFrom(0);
                                } else {
                                    // The callee copies its arguments into its own registers on entry (and clears
                                    // them, see `isTail`), so a per-thread buffer is enough.
                                    if (frameThread.tailBuffer.length < cast(size_t) count)
                                        frameThread.tailBuffer = new LuaValue[cast(size_t) count * 2 + 8];
                                    newArgs = frameThread.tailBuffer[0 .. count];
                                    for (int i = 0; i < count; ++i)
                                        copyValue(newArgs[i], registers[instr.a + 1 + i]);
                                    closeUpvaluesFrom(0);
                                }
                                // This frame is replaced by the callee: same record, same place for results.
                                auto newProto = newClosure.proto;
                                if (!newProto.prepared)
                                    prepareForExecution(newProto);
                                mixin(leaveFrameCode);
                                efClosure = newClosure;
                                efArgs = newArgs;
                                efTail = true;
                                efName = "";
                                efKind = "";
                                mixin(enterFrameCode);
                                if (frameThread.hookFunction !is null)
                                    state.debugHook("tail call", -1, registers[0 .. proto.numParams], true);
                                break; // next instruction, through the safepoint
                            }

                        case OpCode.Call: {
                                int numArgs = (instr.b == 0) ? cast(int)(top - (instr.a + 1)) : (instr.b - 1);
                                int numWantedResults = instr.c - 1;
                                if (numWantedResults >= 0 && instr.a + numWantedResults >= registers.length)
                                    growRegisters(instr.a + numWantedResults + 8);

                                if (registers[instr.a].isFunction) {
                                    auto calleeFunction = registers[instr.a].asFunction;
                                    if (calleeFunction is state.errorFunction && frameThread.hookFunction is null && numArgs >= 1
                                            && (numArgs == 1 || registers[instr.a + 2].isNil || registers[instr.a + 2]
                                                .isInteger)) {
                                        // `error(message [, level])` raised straight from the interpreter: one throw
                                        // instead of two (no native call wrapper to unwind through).
                                        long level = numArgs >= 2 && registers[instr.a + 2].isInteger ? registers[instr
                                                .a + 2]
                                            .asInteger : 1;
                                        auto site = &proto.callSites[cast(int)(ip - codeBase) - 1];
                                        state.pushCall(calleeFunction, "[C]", -1, false, site.name, site.kind);
                                        auto errorObject = registers[instr.a + 1];
                                        if (errorObject.isString && level > 0)
                                            errorObject = LuaValue(state.locationPrefix(
                                                    cast(int) level) ~ toLuaString(errorObject));
                                        auto raised = new LuaException(errorObject);
                                        raised.needsLocation = false;
                                        raised.originFunction = calleeFunction;
                                        raised.originName = site.name;
                                        raised.originKind = site.kind;
                                        state.dispatchError(raised);
                                        state.popCall();
                                        throw raised;
                                    }
                                    if (calleeFunction.fastCall !is null && frameThread.hookFunction is null) {
                                        // Hot built-ins run straight on the registers (see varis.lib.fastcall).
                                        int produced = calleeFunction.fastCall(cast(void*) state, registers, instr.a, numArgs);
                                        if (produced < -1) {
                                            // Results that did not fit were stashed (see lib.coroutine.fastWrapCall).
                                            int stashed = -2 - produced;
                                            growRegisters(instr.a + (stashed > numWantedResults ? stashed
                                                    : numWantedResults) + 8);
                                            placeStashedResults(state, registers, instr.a);
                                            produced = stashed;
                                        }
                                        if (produced >= 0) {
                                            if (numWantedResults >= 0) {
                                                for (int i = produced; i < numWantedResults; ++i)
                                                    registers[instr.a + i] = luaNil();
                                                top = instr.a + numWantedResults;
                                            } else
                                                top = instr.a + produced;
                                            break;
                                        }
                                    }
                                }
                                if (registers[instr.a].isFunction && registers[instr.a].asFunction.isLuaClosure
                                        && frameThread.hookFunction is null && registerDepth >= inlineDepthThreshold) {
                                    // Deep Lua → Lua call: park this frame and run the callee in the same native
                                    // frame (no native stack, cheap unwinding). Its Return delivers the results into
                                    // R[a ...] and resumes here. Shallow calls recurse natively, which is faster.
                                    auto callee = cast(LuaClosure) cast(void*) registers[instr.a].asFunction;
                                    auto site = &proto.callSites[cast(int)(ip - codeBase) - 1];
                                    auto calleeProto = callee.proto;
                                    if (!calleeProto.prepared)
                                        prepareForExecution(calleeProto);
                                    checkStackLimits(frameThread, sp, cast(size_t) calleeProto.maxStackSize + 1);
                                    import varis.gc : stackHygiene, scrubDeadStack;

                                    if (stackHygiene)
                                        scrubDeadStack();
                                    scResultBase = instr.a;
                                    scWanted = numWantedResults;
                                    mixin(saveCallerCode);
                                    record.debugLimit = instr.a;
                                    auto callerInfo = &(*frameCalls)[$ - 1];
                                    callerInfo.registers = &record.registers;
                                    callerInfo.varargs = &record.varargs;
                                    callerInfo.pc = &record.ip;
                                    callerInfo.debugLimit = &record.debugLimit;
                                    efClosure = callee;
                                    efArgs = record.registers[instr.a + 1 .. instr.a + 1 + numArgs];
                                    efTail = false;
                                    efName = site.name;
                                    efKind = site.kind;
                                    mixin(enterFrameCode);
                                    break; // next instruction, through the safepoint
                                }
                                debugLimit = instr.a;
                                int resultTop;
                                if (registers[instr.a].isFunction && registers[instr.a].asFunction.isLuaClosure) {
                                    // Lua → Lua call: run the callee directly; its results are written into
                                    // R[a ...] by its Return (see TailRequest.placeInDest).
                                    auto callee = cast(LuaClosure) cast(void*) registers[instr.a].asFunction;
                                    auto site = &proto.callSites[cast(int)(ip - codeBase) - 1];
                                    import varis.gc : stackHygiene, scrubDeadStack;

                                    if (stackHygiene)
                                        scrubDeadStack();
                                    TailRequest childTail;
                                    childTail.placeInDest = true;
                                    childTail.wanted = numWantedResults;
                                    childTail.dest = numWantedResults >= 0 ? registers[instr.a .. instr.a + numWantedResults] : registers[instr
                                            .a .. $];
                                    auto childResults = executeFrame(state, callee, registers[instr.a + 1 .. instr.a + 1 + numArgs],
                                            childTail, false, site.name, site.kind);
                                    bool childPlaced = childTail.placed;
                                    size_t childCount = childTail.placedCount;
                                    // A callee run natively reports proper tail calls through `pending`.
                                    if (childTail.pending)
                                        childResults = runTailCalls(state, childTail, childPlaced, childCount);
                                    if (childPlaced)
                                        resultTop = instr.a + cast(int) childCount;
                                    else if (numWantedResults >= 0) {
                                        size_t available = childResults.length < cast(size_t) numWantedResults ? childResults
                                            .length : cast(size_t) numWantedResults;
                                        for (size_t i = 0; i < available; ++i)
                                            copyValue(registers[instr.a + i], childResults[i]);
                                        for (size_t i = available; i < cast(size_t) numWantedResults;
                                                ++i)
                                            registers[instr.a + i] = luaNil();
                                        resultTop = instr.a + numWantedResults;
                                    } else if (instr.a + childResults.length >= registers.length) {
                                        state.stashedResults = childResults;
                                        resultTop = -cast(int) childResults.length;
                                    } else {
                                        for (size_t i = 0; i < childResults.length; ++i)
                                            copyValue(registers[instr.a + i], childResults[i]);
                                        resultTop = instr.a + cast(int) childResults.length;
                                    }
                                } else // The call and the placement of its results happen in one frame of their own so
                                    // that no array holding result values stays referenced from this frame.
                                    resultTop = callAndPlace(state, closure, proto, registers, instr.a, numArgs, numWantedResults, cast(
                                            int)(ip - codeBase) - 1);
                                // This executor's frame handler is exception-based: an error reported
                                // as a value is thrown here, at its boundary.
                                if (resultTop == callRaised)
                                    throw state.takeRaised();
                                debugLimit = proto.maxStackSize;
                                if (resultTop < 0) {
                                    // Variable results did not fit: grow, then copy the stashed values.
                                    growRegisters(instr.a + (-resultTop) + 8);
                                    resultTop = placeStashedResults(state, registers, instr.a);
                                }
                                top = resultTop;
                                break;
                            }

                        case OpCode.Return: {
                                int numRet = instr.b - 1;
                                LuaValue[] returned;
                                if (useForcedReturn) {
                                    // Results of a native function tail-called in place (see TailCall).
                                    returned = forcedReturn;
                                    forcedReturn = null;
                                    useForcedReturn = false;
                                } else if (numRet < 0) {
                                    int endReg = (top > instr.a) ? top : instr.a;
                                    if (endReg > registers.length)
                                        endReg = cast(int) registers.length;
                                    returned = (endReg > instr.a) ? registers[instr.a .. endReg] : [
                                    ];
                                } else if (numRet == 0) {
                                    returned = [];
                                } else {
                                    returned = registers[instr.a .. instr.a + numRet];
                                }
                                if (frameThread.inlineTop > inlineBase) {
                                    // Returning from an inline callee: hand the results to the parked caller.
                                    auto parked = parkedFrame(frameThread, frameThread.inlineTop - 1);
                                    int base = parked.resultBase;
                                    int wanted = parked.wanted;
                                    auto destination = parked.registers;
                                    size_t produced = returned.length;
                                    int newTop;
                                    LuaValue[] overflow;
                                    if (wanted >= 0) {
                                        size_t want = cast(size_t) wanted;
                                        size_t copied = produced < want ? produced : want;
                                        for (size_t i = 0; i < copied; ++i)
                                            copyValue(destination[base + i], returned[i]);
                                        for (size_t i = copied; i < want; ++i)
                                            destination[base + i] = luaNil();
                                        newTop = base + wanted;
                                    } else if (base + produced < destination.length) {
                                        for (size_t i = 0; i < produced; ++i)
                                            copyValue(destination[base + i], returned[i]);
                                        newTop = base + cast(int) produced;
                                    } else {
                                        // Does not fit: keep a copy until the caller's registers have grown.
                                        overflow = returned.dup;
                                    }
                                    if (toClose.length)
                                        closeValuesFrom(0);
                                    else
                                        closeUpvaluesFrom(0);
                                    if (frameThread.hookFunction !is null)
                                        state.debugHook("return", -1, returned, true);
                                    mixin(leaveFrameCode);
                                    mixin(restoreCallerCode);
                                    debugLimit = proto.maxStackSize;
                                    if (overflow is null)
                                        top = newTop;
                                    else {
                                        growRegisters(base + overflow.length + 8);
                                        for (size_t i = 0; i < overflow.length; ++i)
                                            copyValue(registers[base + i], overflow[i]);
                                        top = base + cast(int) overflow.length;
                                    }
                                    break; // next instruction, through the safepoint
                                }
                                if (tail.placeInDest) {
                                    // Deliver results straight into the caller's registers.
                                    auto destination = tail.dest;
                                    size_t count = returned.length;
                                    if (tail.wanted >= 0) {
                                        size_t want = cast(size_t) tail.wanted;
                                        size_t copied = count < want ? count : want;
                                        for (size_t i = 0; i < copied; ++i)
                                            copyValue(destination[i], returned[i]);
                                        for (size_t i = copied; i < want; ++i)
                                            destination[i] = luaNil();
                                        tail.placed = true;
                                        tail.placedCount = want;
                                    } else if (count < destination.length) {
                                        for (size_t i = 0; i < count; ++i)
                                            copyValue(destination[i], returned[i]);
                                        tail.placed = true;
                                        tail.placedCount = count;
                                    }
                                }
                                if (!tail.placed && frameThread !is null && returned.length > 0) {
                                    if (frameThread.returnBuffers.length <= registerDepth)
                                        frameThread.returnBuffers.length = registerDepth + 1;
                                    if (frameThread.returnBuffers[registerDepth].length < returned.length)
                                        frameThread.returnBuffers[registerDepth] = new LuaValue[returned.length];
                                    auto dest = frameThread.returnBuffers[registerDepth][0 .. returned.length];
                                    dest[] = returned[];
                                    returned = dest;
                                }
                                if (toClose.length)
                                    closeValuesFrom(0);
                                else
                                    closeUpvaluesFrom(0);
                                if (frameThread.hookFunction !is null)
                                    state.debugHook("return", -1, returned, true);
                                return tail.placed ? null : returned;

                                // Numeric For
                            }

                            mixin(sharedOpcodeCases2);

                        default:
                            {
                                state.raisedError = new LuaException(format("unknown opcode: %s", op));
                                mixin(reportedFailure);
                            }
                        }
};

// Opcode handlers shared by VM.executeFrame and VM.executeDeepFrame, expanded into both
// dispatch switches (string mixins), so the two executors cannot drift apart. They use only names
// both functions define: state, closure, proto, registers, ip, codeBase, top, instr, frameThread and
// the frame's nested helpers. Handlers that differ between the executors (calls, returns,
// transactions) stay in the functions themselves.
// Nop, Move, LoadNil, LoadBool, LoadInt, LoadK, GetGlobal, SetGlobal, GetUpval, SetUpval, NewTable, GetTable, SetTable, SetList, Self, Add, Sub, Mul, Div, Concat, Not, Len, Unm, BNot, Jmp, Eq, Test, TestSet
private enum string sharedOpcodeCases1 = q{
                case OpCode.Nop:
                    continue;

                case OpCode.Move:
                    copyValue(registers[instr.a], registers[instr.b]);
                    continue;

                case OpCode.LoadNil:
                    for (int i = instr.a; i <= instr.a + instr.b; ++i) {
                        registers[i] = luaNil();
                    }
                    continue;

                case OpCode.LoadBool:
                    registers[instr.a] = luaValue(instr.b != 0);
                    if (instr.c != 0)
                        ip++;
                    continue;

                case OpCode.LoadInt:
                    registers[instr.a] = luaValue(cast(long) instr.sBx);
                    continue;

                case OpCode.LoadK:
                    copyValue(registers[instr.a], proto.constants[instr.b]);
                    continue;

                case OpCode.GetGlobal: {
                        // Plain global table (or an _ENV upvalue holding one) with a cached node.
                        auto nameConstant = &proto.constants[instr.b];
                        LuaTable environment;
                        if (instr.c < 0) {
                            auto upvalue = closure.upvalues[-instr.c - 1].ptr();
                            if (upvalue.isTable)
                                environment = upvalue.asTable;
                        } else if (instr.c == 0)
                            environment = state.globals;
                        if (environment !is null && nameConstant.isString) {
                            auto found = environment.findStringHinted(nameConstant.asString, proto.lookupHints[cast(int)(ip - codeBase) - 1]);
                            if (found !is null && !found.isNil) {
                                copyValue(registers[instr.a], *found);
                                continue;
                            }
                        }
                    }
                    if (!execGetGlobal(state, closure, proto, registers, instr, cast(int)(ip - codeBase) - 1)) {
                        mixin(reportedFailure);
                    }
                    break;

                case OpCode.SetGlobal:
                    if (!execSetGlobal(state, closure, proto, registers, instr, cast(int)(ip - codeBase) - 1)) {
                        mixin(reportedFailure);
                    }
                    break;

                case OpCode.GetUpval:
                    if (instr.b < closure.upvalues.length) {
                        copyValue(registers[instr.a], *closure.upvalues[instr.b].ptr());
                    }
                    continue;

                case OpCode.SetUpval:
                    if (instr.b < closure.upvalues.length) {
                        copyValue(*closure.upvalues[instr.b].ptr(), registers[instr.a]);
                    }
                    continue;

                case OpCode.NewTable:
                    registers[instr.a] = luaNil(); // the old value is dead; do not keep it across a collection
                    state.allocationTick();
                    newTableInto(registers[instr.a], proto.newTableSizes[cast(int)(ip - codeBase) - 1]);
                    break;

                case OpCode.GetTable: {
                        // Array-part hit with an integer key: no call, no metatable lookup.
                        auto container = &registers[instr.b];
                        auto key = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
                        if (container.isTable && key.isInteger) {
                            auto elements = container.asTable.arrayPart;
                            ulong slot = cast(ulong) key.asInteger - 1;
                            if (slot < elements.length && !elements[slot].isNil) {
                                copyValue(registers[instr.a], elements[slot]);
                                continue;
                            }
                        } else if (container.isTable && instr.cIsK && key.isString) {
                            // Field read with a constant name: the node this site hit last time.
                            auto hit = container.asTable.hintedHit(key.asString, proto.lookupHints[cast(int)(ip - codeBase) - 1]);
                            if (hit !is null) {
                                copyValue(registers[instr.a], *hit);
                                continue;
                            }
                        }
                    }
                    if (!execGetTable(state, proto, registers, instr, cast(int)(ip - codeBase) - 1)) {
                        mixin(reportedFailure);
                    }
                    break;

                case OpCode.SetTable: {
                        auto container = &registers[instr.a];
                        auto key = instr.bIsK ? &proto.constants[instr.b] : &registers[instr.b];
                        if (container.isTable && key.isInteger) {
                            auto table = container.asTable;
                            ulong slot = cast(ulong) key.asInteger - 1;
                            auto value = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
                            if (table.metatable is null && slot < table.arrayPart.length && !value.isNil) {
                                copyValue(table.arrayPart[slot], *value);
                                continue;
                            }
                        } else if (container.isTable && instr.bIsK && key.isString) {
                            // Field write with a constant name to a field that already holds a value
                            // (__newindex does not apply to an existing field).
                            auto value = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
                            auto hit = container.asTable.hintedHit(key.asString, proto.lookupHints[cast(int)(ip - codeBase) - 1]);
                            if (hit !is null && !value.isNil) {
                                copyValue(*hit, *value);
                                continue;
                            }
                        }
                    }
                    if (!execSetTable(state, proto, registers, instr, cast(int)(ip - codeBase) - 1)) {
                        mixin(reportedFailure);
                    }
                    break;

                case OpCode.SetList:
                    execSetList(registers, instr.a, instr.b, instr.c, top);
                    break;

                case OpCode.Self:
                    if (!execSelf(state, proto, registers, instr, cast(int)(ip - codeBase) - 1)) {
                        mixin(reportedFailure);
                    }
                    break;

                    // Arithmetic, bitwise and concatenation operations. Same-type integer/float
                    // operands are handled inline; everything else takes the generic path.
                case OpCode.Add:
                    mixin(fastArithmetic("+"));
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.Sub:
                    mixin(fastArithmetic("-"));
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.Mul:
                    mixin(fastArithmetic("*"));
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.Div:
                    mixin(fastDivision);
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.IDiv, OpCode.Mod, OpCode.Pow,
                    OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr:
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.Concat:
                    if ((instr.bIsK || instr.a != instr.b) && (instr.cIsK || instr.a != instr.c))
                        registers[instr.a] = luaNil();
                    state.allocationTick();
                    if (!execArith(state, proto, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;

                    // Unary operations
                case OpCode.Not:
                    setBoolean(registers[instr.a], !registers[instr.b].isTruthy);
                    continue;
                case OpCode.Len: {
                        auto operand = &registers[instr.b];
                        if (operand.isTable && operand.asTable.metatable is null) {
                            setInteger(registers[instr.a], operand.asTable.rawLen());
                            continue;
                        }
                        if (operand.isString) {
                            setInteger(registers[instr.a], cast(long) operand.asString.length);
                            continue;
                        }
                    }
                    if (!execUnary(state, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.Unm: {
                        auto operand = &registers[instr.b];
                        if (operand.isInteger) {
                            setInteger(registers[instr.a], cast(long)(0UL - cast(ulong) operand.asInteger));
                            continue;
                        }
                        if (operand.isFloat) {
                            setFloat(registers[instr.a], -operand.asFloat);
                            continue;
                        }
                    }
                    if (!execUnary(state, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;
                case OpCode.BNot:
                    if (!execUnary(state, registers, instr)) {
                        mixin(reportedFailure);
                    }
                    break;

                    // Jumps & Comparisons
                case OpCode.Jmp:
                    ip += instr.sBx;
                    if (instr.sBx < 0)
                        break; // a backward jump is a safepoint
                    continue;

                case OpCode.Eq, OpCode.Lt, OpCode.Le: {
                        auto left = instr.aIsK ? &proto.constants[instr.a] : &registers[instr.a];
                        auto right = instr.bIsK ? &proto.constants[instr.b] : &registers[instr.b];
                        bool outcome, direct = true;
                        if (left.isInteger && right.isInteger) {
                            long x = left.asInteger, y = right.asInteger;
                            outcome = op == OpCode.Eq ? x == y : op == OpCode.Lt ? x < y : x <= y;
                        } else if (left.isFloat && right.isFloat) {
                            double x = left.asFloat, y = right.asFloat;
                            outcome = op == OpCode.Eq ? x == y : op == OpCode.Lt ? x < y : x <= y;
                        } else {
                            outcome = execCompare(state, proto, registers, instr);
                            if (state.raisedError !is null) {
                                mixin(reportedFailure);
                            }
                            direct = false; // a metamethod may have run
                        }
                        if (outcome != (instr.c != 0))
                            ip++;
                        else if (!attention && ip.op == OpCode.Jmp) {
                            int distance = ip.sBx;
                            ip += distance + 1; // fused compare-and-jump: no dispatch of the Jmp
                            if (distance < 0)
                                break; // a backward jump is a safepoint
                        }
                        if (direct)
                            continue;
                    }
                    break;

                case OpCode.Test:
                    if (isTruthy(registers[instr.a]) == (instr.c != 0)) {
                        ip += instr.sBx;
                        if (instr.sBx < 0)
                            break; // a backward jump is a safepoint
                    }
                    continue;

                case OpCode.TestSet:
                    if (isTruthy(registers[instr.b]) == (instr.c != 0)) {
                        registers[instr.a] = registers[instr.b];
                        ip += instr.sBx;
                        if (instr.sBx < 0)
                            break; // a backward jump is a safepoint
                    }
                    continue;

                    // Calls and Returns
};

// ForPrep, ForLoop, TForCall, TForLoop, Closure, Vararg, Close, ToClose, BeginTransaction, EndTransaction, Rollback, DefineContent
private enum string sharedOpcodeCases2 = q{
                case OpCode.ForPrep:
                    {
                        int prepared = forPrepare(state, registers, instr.a);
                        if (prepared < 0) {
                            mixin(reportedFailure);
                        }
                        if (prepared > 0)
                            ip += instr.sBx;
                    }
                    continue;

                case OpCode.ForLoop: {
                        // Prepared integer loops keep the remaining iteration count in R[a+1].
                        auto control = &registers[instr.a];
                        if (control[2].isInteger) {
                            long count = control[1].asInteger;
                            if (count > 0) {
                                long index = control[0].asInteger + control[2].asInteger;
                                setInteger(control[1], count - 1);
                                setInteger(control[0], index);
                                setInteger(control[3], index);
                                ip += instr.sBx;
                                break; // the loop's backward jump is a safepoint
                            }
                        } else if (forStep(registers, instr.a)) {
                            ip += instr.sBx;
                            break;
                        }
                        continue;
                    }

                    // Generic For
                case OpCode.TForCall:
                    execTForCall(state, registers, instr.a, instr.c, frameThread.hookFunction is null);
                    break;

                case OpCode.TForLoop:
                    if (!isNil(registers[instr.a + 2])) {
                        copyValue(registers[instr.a], registers[instr.a + 2]);
                        ip += instr.sBx;
                    }
                    break;

                    // Closures and Upvalues
                case OpCode.Closure:
                    registers[instr.a] = luaNil();
                    state.allocationTick();
                    execClosure(closure, proto, registers, instr.a, instr.b, &findOrCreateUpvalue);
                    break;

                case OpCode.Vararg:
                    int numWanted = instr.b - 1;
                    if (numWanted >= 0) {
                        for (int i = 0; i < numWanted; ++i) {
                            if (instr.a + i >= registers.length)
                                growRegisters(instr.a + i + 8);
                            registers[instr.a + i] = (i < varargs.length) ? varargs[i] : luaNil();
                        }
                        top = instr.a + numWanted;
                    } else {
                        if (instr.a + varargs.length >= registers.length) {
                            growRegisters(instr.a + varargs.length + 8);
                        }
                        for (size_t i = 0; i < varargs.length; ++i) {
                            registers[instr.a + i] = varargs[i];
                        }
                        top = instr.a + cast(int) varargs.length;
                    }
                    break;

                case OpCode.Close:
                    closeValuesFrom(instr.a);
                    break;

                case OpCode.ToClose:
                    if (isNil(registers[instr.a]) || (registers[instr.a].typeOf() == LuaType.Boolean && !isTruthy(
                            registers[instr.a])))
                        break;
                    auto closeMetatable = state.getMetatable(registers[instr.a]);
                    if (closeMetatable is null || isNil(closeMetatable.rawget(LuaValue("__close")))) {
                        string variable = "?";
                        foreach (local; proto.debugLocals)
                            if (local.register == instr.a && local.startPC <= cast(int)(ip - codeBase) - 1 && cast(int)(ip - codeBase) - 1 < local.endPC)
                                variable = local.name;
                        {
                            state.raisedError = new LuaException("variable '" ~ variable ~ "' got a non-closable value");
                            mixin(reportedFailure);
                        }
                    }
                    toClose ~= instr.a;
                    break;

                case OpCode.BeginTransaction:
                    Object transactionWorld = instr.a < 0 ? state.globalWorldObject
                        : unwrapWorld(registers[instr.a]);
                    if (beginFrameScopeHook is null)
                        {
                            state.raisedError = new LuaException("transactions need the world model");
                            mixin(reportedFailure);
                        }
                    frameTransactions ~= FrameTransaction(beginFrameScopeHook(transactionWorld), cast(int)(ip - codeBase), instr.b, instr.c);
                    break;
                case OpCode.EndTransaction:
                    frameTransactions[$ - 1].transaction.finish(true);
                    frameTransactions.length--;
                    break;
                case OpCode.ExitTransaction:
                    // A jump out of a transaction block lands here (see prepareForExecution). The
                    // frame is at the jump's target while the blocks it left are committed, which
                    // is where an error raised by a close handler or a commit is attributed.
                    ip = codeBase + instr.b;
                    if (vmSlowMode && state.analysisBudget !is null) {
                        // The target's instruction is charged before the commits, as it always was.
                        if (!state.analysisBudget.remaining)
                            {
                                state.raisedError = new LuaException("ANALYSIS_STEP_LIMIT: VM instruction budget exhausted");
                                mixin(reportedFailure);
                            }
                        state.analysisBudget.remaining--;
                        budgetPrepaid = true;
                    }
                    while (frameTransactions.length && (instr.b < frameTransactions[$ - 1].startPC
                            || instr.b >= frameTransactions[$ - 1].endPC)) {
                        closeValuesFrom(frameTransactions[$ - 1].firstRegister);
                        frameTransactions[$ - 1].transaction.finish(true);
                        frameTransactions.length--;
                    }
                    break;
                case OpCode.Rollback:
                    if (!frameTransactions.length)
                        {
                            state.raisedError = new LuaException("rollback outside a transaction");
                            mixin(reportedFailure);
                        }
                    auto rolledBack = frameTransactions[$ - 1];
                    closeValuesFrom(rolledBack.firstRegister);
                    rolledBack.transaction.finish(false);
                    ip = codeBase + rolledBack.endPC;
                    frameTransactions.length--;
                    break;

                case OpCode.DefineContent, OpCode.DefineDeck, OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.DeclRel,
                    OpCode.SetFact, OpCode.DeleteKey, OpCode.AdjustKey, OpCode.AdjustClamp, OpCode.AddFact, OpCode.RetractFact,
                    OpCode.RegRule, OpCode.MakeQuery:
                    declarativeOp(state, closure, proto, registers, &findOrCreateUpvalue, instr);
                    break;
};

// The seam between the Lua core and the layers above it (benchmarks/PERFORMANCE_PLAN.md, stage S1).
// The executor carries a call's lexical world as an opaque reference, opens transaction scopes
// through an interface, and hands relational and narrative instructions to a handler; the world
// model installs all three from its module constructor (varis.narrative.vmops).

/// Executes one relational or narrative instruction.
__gshared void function(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        scope UpValue delegate(int) findUp, Instruction instr) declarativeOpHook;
/// The world a value denotes (raises a Lua error when it is not a world).
__gshared Object function(LuaValue value) worldOfValueHook;
/// Opens a transaction on a world for a `transaction ... do` block.
__gshared FrameScope function(Object world) beginFrameScopeHook;

private void declarativeOp(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        scope UpValue delegate(int) findUp, Instruction instr) {
    if (declarativeOpHook is null)
        throw new LuaException("relational and narrative instructions need the world model");
    declarativeOpHook(state, closure, proto, registers, findUp, instr);
}

pragma(inline, true)
private Object unwrapWorld(LuaValue value) {
    if (worldOfValueHook is null)
        throw new LuaException("worlds need the world model");
    return worldOfValueHook(value);
}

/// Lua frames of native recursion after which calls run in `executeDeepFrame`.
private enum size_t inlineDepthThreshold = 150;

/// Bytecode Virtual Machine Dispatcher
struct VM {
    private struct TailRequest {
        bool pending; // a proper tail call is waiting in the thread's tailCallee/Arguments/World
        // Results may be delivered straight into the caller's registers (see the Lua → Lua case of OpCode.Call).
        bool returnErrors; // pcall: hand a LuaException back in `error` instead of throwing it
        LuaException error;
        bool placeInDest;
        int wanted; // requested result count, or -1 for all
        LuaValue[] dest; // caller registers receiving the results
        bool placed;
        size_t placedCount;
    }

    static LuaValue[] execute(LuaState state, LuaClosure closure, LuaValue[] args, string name = "", string nameKind = "") {
        bool placed;
        size_t placedCount;
        return executeFrames(state, closure, args, name, nameKind, null, false, 0, null, placed, placedCount);
    }

    /// `callValue` for `pcall`/`xpcall`: a Lua function's error comes back in `failure` (and the
    /// result is null) instead of being thrown, which saves one throw-and-catch per caught error.
    static LuaValue[] callProtected(LuaState state, LuaValue callee, LuaValue[] args, out LuaException failure) {
        failure = null;
        auto fn = callee.isFunction ? callee.asFunction : null;
        if (fn is null || !fn.isLuaClosure) {
            // A native that reports its error as a value: no throw between it and pcall.
            auto results = callValue(state, callee, args, false, "", "", false, true);
            if (state.raisedError !is null) {
                failure = state.takeRaised();
                return null;
            }
            return results;
        }
        auto cThread = state.currentThread();
        if (cThread !is null) {
            ++cThread.cCalls;
            if (cThread.cCalls == 200) {
                --cThread.cCalls;
                throw new LuaException("C stack overflow");
            }
            if (cThread.cCalls >= 220) {
                --cThread.cCalls;
                auto nested = new LuaException("error in error handling");
                nested.needsLocation = false;
                throw nested;
            }
        }
        scope (exit)
            if (cThread !is null)
                --cThread.cCalls;
        auto previousWorld = state.callWorldObject;
        scope (exit)
            state.callWorldObject = previousWorld;
        TailRequest tail;
        tail.returnErrors = true;
        auto closure = cast(LuaClosure) cast(void*) fn;
        auto results = executeFrame(state, closure, args, tail, false, "", "");
        if (tail.error !is null) {
            failure = tail.error;
            return null;
        }
        if (tail.pending) {
            bool placed;
            size_t placedCount;
            results = runTailCalls(state, tail, placed, placedCount);
            if (tail.error !is null) {
                failure = tail.error;
                return null;
            }
        }
        return results;
    }

    /// Runs `closure` and any proper tail calls it makes. With `placeInDest`, results are copied
    /// into `dest` (exactly `wanted` slots, or as many as fit when `wanted` is -1) and `placed`
    /// is set; otherwise they are returned in a buffer valid until the next call at this depth.
    private static LuaValue[] executeFrames(LuaState state, LuaClosure closure, LuaValue[] args, string name,
            string nameKind, LuaValue[] dest, bool placeInDest, int wanted, Object entryWorld, out bool placed,
            out size_t placedCount) {
        auto previous = state.callWorldObject;
        if (entryWorld !is null)
            state.callWorldObject = entryWorld;
        scope (exit)
            state.callWorldObject = previous;
        TailRequest tail;
        tail.placeInDest = placeInDest;
        tail.wanted = wanted;
        tail.dest = dest;
        auto results = executeFrame(state, closure, args, tail, false, name, nameKind);
        placed = tail.placed;
        placedCount = tail.placedCount;
        if (!tail.pending)
            return results;
        return runTailCalls(state, tail, placed, placedCount);
    }

    /// Follows a chain of proper tail calls starting from a pending request in `tail`.
    private static LuaValue[] runTailCalls(LuaState state, ref TailRequest first, out bool placed, out size_t placedCount) {
        placed = false;
        TailRequest tail = first;
        auto thread = state.currentThread();
        while (true) {
            auto callee = thread.tailCallee;
            auto args = thread.tailArguments;
            LuaClosure closure;
            if (callee.isFunction && callee.asFunction.isLuaClosure)
                closure = cast(LuaClosure) cast(void*) callee.asFunction;
            else {
                resolveCallable(state, callee, args);
                auto function_ = callee.match!((LuaFunction fn) => fn, _ => null);
                if (function_ is null || !function_.isLuaClosure) {
                    // A native reached through `__call`: it runs with the lexical world of the
                    // tail call's site (the TailCall handler recorded it for this case).
                    auto previousWorld = state.callWorldObject;
                    state.callWorldObject = thread.tailWorld;
                    scope (exit)
                        state.callWorldObject = previousWorld;
                    return callValue(state, callee, args.dup, true);
                }
                closure = cast(LuaClosure) cast(void*) function_;
            }
            TailRequest next;
            next.placeInDest = tail.placeInDest;
            next.wanted = tail.wanted;
            next.dest = tail.dest;
            next.returnErrors = tail.returnErrors;
            auto results = executeFrame(state, closure, args, next, true, "", "");
            if (next.error !is null) {
                first.error = next.error;
                return null;
            }
            if (!next.pending) {
                placed = next.placed;
                placedCount = next.placedCount;
                return results;
            }
            tail = next;
        }
    }

    /// One-time per-prototype setup: ends the code with a Return (so the loop needs no end test)
    /// and builds the dense call-site table.
    private static void prepareForExecution(Prototype proto) {
        if (proto.code.length == 0 || proto.code[$ - 1].op != OpCode.Return) {
            // `code` stays untouched (fingerprints and dumps read it); the loop runs a copy.
            Instruction ending;
            ending.op = OpCode.Return;
            ending.b = 1;
            ending.line = proto.code.length ? proto.code[$ - 1].line : 0;
            proto.execCode = proto.code ~ ending;
        } else
            proto.execCode = proto.code;
        addTransactionExits(proto);
        proto.buildCallSites();
        proto.lookupHints = new int[proto.execCode.length];
        proto.newTableSizes = new uint[proto.execCode.length];
        foreach (pc, packed; proto.tableSizeHints)
            if (pc >= 0 && pc < proto.newTableSizes.length)
                proto.newTableSizes[pc] = cast(uint) packed;
        proto.constantHashes = new size_t[proto.constants.length];
        foreach (index, ref constant; proto.constants)
            if (constant.isString) {
                // Equal string constants of different functions become one slice, so table lookups
                // with constant keys succeed on the pointer comparison (same bytes: fingerprints
                // and dumps are unaffected). Only compile-time constants are interned.
                auto text = constant.asString;
                if (auto known = text in internedConstants)
                    constant = LuaValue(*known);
                else
                    internedConstants[text] = text;
                proto.constantHashes[index] = hashOf(constant.asString);
            }
        proto.prepared = true;
    }

    private static string[string] internedConstants;

    /// A transaction block ends when control leaves it. Leaving by `break` or `goto` is a jump
    /// whose target lies outside the block; each such jump is pointed, in `execCode` only, at an
    /// ExitTransaction instruction appended after the program, which commits the blocks left and
    /// continues at the original target. The loop therefore checks nothing per instruction while
    /// a transaction is open. `proto.code` is not touched.
    private static void addTransactionExits(Prototype proto) {
        auto code = proto.code;
        bool any;
        foreach (ref instr; code)
            if (instr.op == OpCode.BeginTransaction) {
                any = true;
                break;
            }
        if (!any)
            return;
        Instruction[] exec = proto.execCode.dup;
        foreach (pc, ref instr; code) {
            switch (instr.op) {
            case OpCode.Jmp, OpCode.Test, OpCode.TestSet, OpCode.ForPrep, OpCode.ForLoop, OpCode.TForLoop:
                break;
            default:
                continue;
            }
            int target = cast(int) pc + 1 + instr.sBx;
            // The innermost block containing this jump: the last BeginTransaction before it whose
            // range (the instruction after it up to its end pc) still covers it.
            bool leaves;
            for (int begin = cast(int) pc - 1; begin >= 0; --begin)
                if (code[begin].op == OpCode.BeginTransaction && cast(int) pc < code[begin].b) {
                    leaves = target <= begin || target >= code[begin].b;
                    break;
                }
            if (!leaves)
                continue;
            Instruction exit;
            exit.op = OpCode.ExitTransaction;
            exit.b = target;
            exit.line = instr.line;
            exec[pc].sBx = cast(int) exec.length - cast(int) pc - 1;
            exec ~= exit;
        }
        proto.execCode = exec;
    }

    private static LuaValue[] executeFrame(LuaState state, LuaClosure closure,
            LuaValue[] args, ref TailRequest tail, bool transferred, string entryName, string entryKind) {
        import core.thread : Fiber;

        auto proto = closure.proto;

        // Emulate Lua's stack limits: 1,000,000 slots ("stack overflow"; the extra 200 are
        // reserved for error handling) plus a native guard for the real D stack.
        auto frameThread = state.currentThread();
        size_t nativeMarker;
        size_t sp = cast(size_t)&nativeMarker;
        // The slot count is approximate (owner decision): frames of up to smallFrameSlots slots are
        // charged a flat amount through the frame depth, so an ordinary call updates no counter;
        // only larger frames are counted exactly, which still bounds memory.
        size_t frameSlots = cast(size_t) proto.maxStackSize + 1;
        immutable bool bigFrame = frameSlots > LuaThread.smallFrameSlots;
        if (bigFrame)
            frameThread.stackSlots += frameSlots;
        scope (exit) {
            if (bigFrame)
                frameThread.stackSlots -= frameSlots;
            if (frameThread.overflowed && frameThread.stackUse() + 400 <= luaMaxStack
                    && sp > frameThread.nativeSoftLimit + 256 * 1024)
                frameThread.overflowed = false;
        }
        immutable size_t stackUse = frameThread.stackUse() + LuaThread.smallFrameCharge;
        // Far from both limits (the soft native limit lies above the hard one): nothing to check.
        if (stackUse > luaMaxStack ||
                (frameThread.nativeStackLimit != 0 && sp < frameThread.nativeSoftLimit)) {
            bool nativeSoft = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeSoftLimit;
            bool nativeHard = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeStackLimit;
            if (nativeHard || stackUse > luaMaxStack + 200) {
                auto nested = new LuaException("error in error handling");
                nested.needsLocation = false;
                throw nested;
            }
            if ((nativeSoft || stackUse > luaMaxStack) && !frameThread.overflowed) {
                frameThread.overflowed = true;
                throw new LuaException("stack overflow");
            }
        }
        size_t stackSize = max(cast(size_t) proto.maxStackSize + 8, 8);
        size_t registerDepth = frameThread.registerDepth++;
        scope (exit)
            --frameThread.registerDepth;
        // Registers are a slice of the thread's value stack (a bump allocator whose free area is
        // always nil). A frame that outgrows its slice moves to its own array, see growRegisters.
        auto stackArray = frameThread.valueStack;
        size_t stackBase = frameThread.valueTop;
        if (stackBase + stackSize > stackArray.length) {
            size_t capacity = stackArray.length * 2;
            if (capacity < 128)
                capacity = 128;
            if (capacity < stackSize * 2)
                capacity = stackSize * 2;
            stackArray = new LuaValue[capacity];
            stackBase = 0;
            frameThread.valueStack = stackArray;
        }
        frameThread.valueTop = stackBase + stackSize;
        LuaValue[] registers = stackArray[stackBase .. stackBase + stackSize];
        scope (exit) {
            // Registered before frame cleanup: close handlers, transactions and open upvalues
            // finish before the registers are cleared and handed to the next frame.
            clearValues(stackArray[stackBase .. stackBase + stackSize]);
            if (frameThread.valueStack.ptr is stackArray.ptr)
                frameThread.valueTop = stackBase;
        }

        // Both newly allocated and returned cached registers are nil.

        // Pass parameters into registers R[0 .. numParams-1]
        for (int i = 0; i < proto.numParams; ++i) {
            if (i < args.length) {
                registers[i] = args[i];
            }
        }

        // Varargs
        LuaValue[] varargs;
        if (proto.isVararg && args.length > cast(size_t) proto.numParams) {
            // See enterFrameCode: a plain call's arguments stay put in the suspended caller.
            varargs = transferred ? args[cast(size_t) proto.numParams .. $].dup : args[cast(size_t) proto.numParams .. $];
        }
        // Tail-called frames receive their arguments in a reused buffer: release the references.
        if (transferred)
            clearValues(args);

        // Open upvalues tracked in this frame
        UpValue openUpvalues; // head of the frame's list of open upvalues (linked by nextOpen)

        void growRegisters(size_t length) {
            registers.length = length;
            for (auto up = openUpvalues; up !is null; up = up.nextOpen)
                up.valPtr = &registers[up.stackIndex];
        }

        UpValue findOrCreateUpvalue(int regIdx) {
            for (auto up = openUpvalues; up !is null; up = up.nextOpen)
                if (up.stackIndex == regIdx)
                    return up;
            auto newUp = new UpValue(&registers[regIdx], regIdx);
            newUp.nextOpen = openUpvalues;
            openUpvalues = newUp;
            return newUp;
        }

        void closeUpvaluesFrom(int regIdx) {
            // Closing unlinks, so the list only ever holds open upvalues.
            UpValue previous;
            for (auto up = openUpvalues; up !is null;) {
                auto following = up.nextOpen;
                if (up.stackIndex >= regIdx) {
                    up.close();
                    up.nextOpen = null;
                    if (previous is null)
                        openUpvalues = following;
                    else
                        previous.nextOpen = following;
                } else
                    previous = up;
                up = following;
            }
        }

        int[] toClose;
        void closeValuesFrom(int first, LuaValue error = LuaValue.init) {
            auto thread = state.currentThread();
            if (thread !is null)
                thread.closeDepth++;
            scope (exit)
                if (thread !is null)
                    thread.closeDepth--;
            LuaException closeError;
            while (toClose.length && toClose[$ - 1] >= first) {
                int slot = toClose[$ - 1];
                toClose.length--;
                auto value = registers[slot];
                auto metatable = state.getMetatable(value);
                auto method = metatable is null ? luaNil() : metatable.rawget(LuaValue("__close"));
                try {
                    callValue(state, method, [value, error], false, "close", "metamethod");
                } catch (LuaException failure) {
                    closeError = failure;
                    error = failure.errorObject;
                }
            }
            closeUpvaluesFrom(first);
            if (closeError !is null)
                throw closeError;
        }

        if (!proto.prepared)
            prepareForExecution(proto);
        auto code = proto.execCode;
        auto codeBase = code.ptr;
        const(Instruction)* ip = codeBase; // next instruction to execute
        int curPC() {
            return cast(int)(ip - codeBase);
        }

        int top = cast(int) proto.maxStackSize;
        int codeLen = cast(int) code.length;
        int debugLimit = proto.maxStackSize;

        bool callVisible = state !is null;
        if (state !is null) {
            state.pushCall(closure, proto.sourceName, -1, transferred, entryName, entryKind,
                    &registers, &varargs, &ip, &debugLimit);
        }

        struct FrameTransaction {
            FrameScope transaction;
            int startPC;
            int endPC;
            int firstRegister;
        }

        FrameTransaction[] frameTransactions;
        bool transactionError;
        scope (exit) {
            while (frameTransactions.length) {
                frameTransactions[$ - 1].transaction.finish(!transactionError);
                frameTransactions.length--;
            }
        }
        scope (failure)
            transactionError = true;

        scope (exit) {
            closeUpvaluesFrom(0);
            if (callVisible)
                state.popCall();
        }

        // A native execution frame always resumes on its original Fiber. Cache
        // the owning slice descriptor, not its backing array: nested calls can
        // grow/reallocate the array, but the descriptor remains on its owner.
        auto frameCalls = &state.callStack();
        int lastHookPC = -1;
        int lastHookLine = -1;
        bool budgetPrepaid; // the next instruction's analysis charge was taken by an ExitTransaction
        // A Lua error that reached this frame. Errors raised by `error` in this frame, and errors
        // returned by a Lua callee, arrive here without a throw; errors thrown by natives and by
        // the out-of-line helpers arrive through the catch below. Either way the frame's handler
        // after the try block runs once.
        LuaException raisedError;
        // What a handler does when an out-of-line helper reported its error as a value: straight
        // to the frame's handler, without a throw.
        enum string reportedFailure = q{
            raisedError = state.takeRaised();
            break interpret;
        };
        try {
            if (frameThread.hookFunction !is null)
                state.debugHook(transferred ? "tail call" : "call", -1, registers[0 .. proto.numParams], true);
            // The loop exists twice, generated from one text (frameLoopBody): a fast variant that
            // looks at nothing but the program, and an instrumented variant that does the rare
            // per-instruction duties. A frame runs the fast one until `vmAttention` is seen set
            // at a safepoint (after any instruction that is not known to be free of calls out of
            // the loop, and on every backward jump), and returns to it when the flag clears.
            interpret: for (;;) {
                if (!vmAttention) {
                    enum bool instrumented = false;
                    fastLoop: for (;;) {
                        mixin(frameLoopBody);
                        if (vmAttention)
                            break fastLoop;
                    }
                }
                {
                    enum bool instrumented = true;
                    instrumentedLoop: for (;;) {
                        if (!vmAttention)
                            continue interpret;
                        mixin(frameLoopBody);
                    }
                }
            }
        } catch (CoroutineClose signal) {
            transactionError = true;
            if (callVisible) {
                state.popCall();
                callVisible = false;
            }
            try {
                closeValuesFrom(0, signal.errorObject);
            } catch (LuaException failure) {
                signal.errorObject = failure.errorObject;
                signal.failed = true;
            }
            throw signal;
        } catch (LuaException e) {
            raisedError = e;
        } catch (ExitRequest request) {
            if (callVisible) {
                state.popCall();
                callVisible = false;
            }
            closeValuesFrom(0);
            throw request;
        } catch (Exception e) {
            transactionError = true;
            closeValuesFrom(0, LuaValue(e.msg));
            throw e;
        }

        if (raisedError !is null) {
            auto e = raisedError;
            transactionError = true;
            if (e.culprit > 0 && curPC() > 0 && curPC() <= codeLen)
                applyVariableInfo(e, proto, curPC() - 1);
            if (auto argFailure = cast(ArgError) e) {
                if (!argFailure.formatted && curPC() > 0 && curPC() <= codeLen) {
                    auto site = proto.code[curPC() - 1];
                    string calledName, calledKind;
                    if (site.op == OpCode.Call || site.op == OpCode.TailCall)
                        calledKind = objectName(proto, curPC() - 1, site.a, calledName);
                    formatArgError(state, argFailure, argFailure.function_, calledName, calledKind);
                }
            }
            if (curPC() > 0 && curPC() <= codeLen)
                e.locateLua(proto.sourceName, proto.code[curPC() - 1].line);
            if (state.errorStopHook !is null && !e.stopOffered) {
                // A debugger may stop here, with this frame and its callers still alive.
                e.stopOffered = true;
                state.errorStopHook(state, e);
            }
            state.dispatchError(e);
            auto fiber = currentLuaFiber();
            if (fiber !is null && !fiber.closing && !fiber.protectedDepth &&
                    !isNoYieldScope() && !isReadOnlyEvaluation() && !isNotificationDispatch()) {
                bool pushedOrigin = e.originFunction !is null;
                if (pushedOrigin)
                    state.pushCall(e.originFunction, "[C]", -1, false, e.originName, e.originKind);
                fiber.suspendError(e.errorObject);
                if (pushedOrigin)
                    state.popCall();
                if (callVisible) {
                    state.popCall();
                    callVisible = false;
                }
                auto signal = new CoroutineClose(e.errorObject, true);
                try {
                    closeValuesFrom(0, signal.errorObject);
                } catch (LuaException failure) {
                    signal.errorObject = failure.errorObject;
                }
                throw signal;
            }
            if (callVisible) {
                state.popCall();
                callVisible = false;
            }
            closeValuesFrom(0, e.errorObject);
            if (tail.returnErrors) {
                tail.error = e;
                return null;
            }
            throw e;
        }

        closeValuesFrom(0);
        state.debugHook("return");
        return [];
    }

    /// `executeFrame` for deep recursion. Past `inlineDepthThreshold` Lua frames, Lua → Lua calls no
    /// longer recurse natively: the caller's state is parked in a `SavedFrame` and the callee runs in
    /// the same native frame. That keeps native stack use flat and makes unwinding a 300,000-level
    /// stack overflow a loop instead of 300,000 exception hops. It is a separate function (rather
    /// than a mode of `executeFrame`) because the extra bookkeeping slowed the common shallow case.
    /// Behaviour must stay identical to `executeFrame`.
    private static LuaValue[] executeDeepFrame(LuaState state, LuaClosure entryClosure,
            LuaValue[] entryArgs, ref TailRequest tail, bool transferred, string entryName, string entryKind) {
        import core.thread : Fiber;

        // Emulate Lua's stack limits: 1,000,000 slots ("stack overflow"; the extra 200 are
        // reserved for error handling) plus a native guard for the real D stack.
        auto frameThread = state.currentThread();
        size_t nativeMarker;
        size_t sp = cast(size_t)&nativeMarker;
        enum cachedFrameLimit = 64;
        enum cachedRegisterLimit = 256;

        // State of the Lua frame being executed. Lua → Lua calls do not recurse natively: the
        // caller's state is parked in a `SavedFrame` and these variables are reloaded for the
        // callee (see OpCode.Call / OpCode.Return); `inlineBase` marks this invocation's records.
        LuaClosure closure;
        Prototype proto;
        LuaValue[] registers;
        LuaValue[] cachedBuffer;
        LuaValue[] varargs;
        UpValue openUpvalues; // head of the frame's list of open upvalues (linked by nextOpen)
        int[] toClose;
        FrameTransaction[] frameTransactions;
        bool transactionError;
        bool callVisible;
        bool frameLive;
        const(Instruction)[] code;
        const(Instruction)* codeBase;
        const(Instruction)* ip; // next instruction to execute (kept in a register)
        const(Instruction)* ipSlot; // mirror of `ip` that call records point at
        int top;
        int debugLimit;
        size_t registerDepth;
        size_t frameSlots;
        int lastHookPC = -1;
        int lastHookLine = -1;
        bool budgetPrepaid; // see executeFrame
        immutable size_t inlineBase = frameThread.inlineTop;
        auto frameCalls = &state.callStack();

        void growRegisters(size_t length) {
            registers.length = length;
            for (auto up = openUpvalues; up !is null; up = up.nextOpen)
                up.valPtr = &registers[up.stackIndex];
        }

        UpValue findOrCreateUpvalue(int regIdx) {
            for (auto up = openUpvalues; up !is null; up = up.nextOpen)
                if (up.stackIndex == regIdx)
                    return up;
            auto newUp = new UpValue(&registers[regIdx], regIdx);
            newUp.nextOpen = openUpvalues;
            openUpvalues = newUp;
            return newUp;
        }

        void closeUpvaluesFrom(int regIdx) {
            // Closing unlinks, so the list only ever holds open upvalues.
            UpValue previous;
            for (auto up = openUpvalues; up !is null;) {
                auto following = up.nextOpen;
                if (up.stackIndex >= regIdx) {
                    up.close();
                    up.nextOpen = null;
                    if (previous is null)
                        openUpvalues = following;
                    else
                        previous.nextOpen = following;
                } else
                    previous = up;
                up = following;
            }
        }

        void closeValuesFrom(int first, LuaValue error = LuaValue.init) {
            auto thread = state.currentThread();
            if (thread !is null)
                thread.closeDepth++;
            scope (exit)
                if (thread !is null)
                    thread.closeDepth--;
            LuaException closeError;
            while (toClose.length && toClose[$ - 1] >= first) {
                int slot = toClose[$ - 1];
                toClose.length--;
                auto value = registers[slot];
                auto metatable = state.getMetatable(value);
                auto method = metatable is null ? luaNil() : metatable.rawget(LuaValue("__close"));
                try {
                    callValue(state, method, [value, error], false, "close", "metamethod");
                } catch (LuaException failure) {
                    closeError = failure;
                    error = failure.errorObject;
                }
            }
            closeUpvaluesFrom(first);
            if (closeError !is null)
                throw closeError;
        }

        LuaClosure efClosure;
        LuaValue[] efArgs;
        bool efTail;
        string efName, efKind;
        int scResultBase, scWanted;
        SavedFrame* record;
        bool unwindingFailure;
        scope (exit) {
            if (unwindingFailure)
                transactionError = true;
            mixin(leaveFrameCode);
        }
        scope (failure)
            unwindingFailure = true;

        efClosure = entryClosure;
        efArgs = entryArgs;
        efTail = transferred;
        efName = entryName;
        efKind = entryKind;
        mixin(enterFrameCode);
        bool entryHookPending = true;
        LuaValue[] forcedReturn;
        bool useForcedReturn;
        Throwable pendingThrow;
        enum string reportedFailure = q{
            incoming = state.takeRaised();
            break deepInterpret;
        };

        for (;;) {
            Throwable propagate;
            Throwable incoming;
            if (pendingThrow !is null) {
                // An exception passed on by a callee that ran inline: handle it here, no re-throw.
                incoming = pendingThrow;
                pendingThrow = null;
            } else
                try {
                    if (entryHookPending) {
                        entryHookPending = false;
                        if (frameThread.hookFunction !is null)
                            state.debugHook(transferred ? "tail call" : "call", -1, registers[0 .. proto.numParams], true);
                    }
                    // Fast and instrumented variants of one loop text, as in executeFrame.
                    deepInterpret: for (;;) {
                        if (!vmAttention) {
                            enum bool instrumented = false;
                            deepFastLoop: for (;;) {
                                mixin(deepFrameLoopBody);
                                if (vmAttention)
                                    break deepFastLoop;
                            }
                        }
                        {
                            enum bool instrumented = true;
                            for (;;) {
                                if (!vmAttention)
                                    continue deepInterpret;
                                mixin(deepFrameLoopBody);
                            }
                        }
                    }
                } catch (CoroutineClose t) {
                    incoming = t;
                } catch (LuaException t) {
                    incoming = t;
                } catch (ExitRequest t) {
                    incoming = t;
                } catch (Exception t) {
                    incoming = t;
                } catch (Throwable t) {
                    incoming = t;
                }
            // Per-frame exception handling; `propagate` is what continues outwards (a close handler
            // may replace the exception). Errors that are not exceptions only unwind via cleanup.
            propagate = incoming;
            try {
                if (auto signal = cast(CoroutineClose) incoming) {
                    transactionError = true;
                    if (callVisible) {
                        state.popCall();
                        callVisible = false;
                    }
                    try {
                        closeValuesFrom(0, signal.errorObject);
                    } catch (LuaException failure) {
                        signal.errorObject = failure.errorObject;
                        signal.failed = true;
                    }
                } else if (auto e = cast(LuaException) incoming) {
                    transactionError = true;
                    if (e.culprit > 0 && cast(int)(ip - codeBase) > 0 && cast(int)(ip - codeBase) <= code.length)
                        applyVariableInfo(e, proto, cast(int)(ip - codeBase) - 1);
                    if (auto argFailure = cast(ArgError) e) {
                        if (!argFailure.formatted && cast(int)(ip - codeBase) > 0 && cast(int)(ip - codeBase) <= code
                                .length) {
                            auto site = proto.code[cast(int)(ip - codeBase) - 1];
                            string calledName, calledKind;
                            if (site.op == OpCode.Call || site.op == OpCode.TailCall)
                                calledKind = objectName(proto, cast(int)(ip - codeBase) - 1, site.a, calledName);
                            formatArgError(state, argFailure, argFailure.function_, calledName, calledKind);
                        }
                    }
                    if (cast(int)(ip - codeBase) > 0 && cast(int)(ip - codeBase) <= code.length)
                        e.locateLua(proto.sourceName, proto.code[cast(int)(ip - codeBase) - 1].line);
                    if (state.errorStopHook !is null && !e.stopOffered) {
                        // A debugger may stop here, with this frame and its callers still alive.
                        e.stopOffered = true;
                        state.errorStopHook(state, e);
                    }
                    state.dispatchError(e);
                    auto fiber = currentLuaFiber();
                    bool suspended = false;
                    if (fiber !is null && !fiber.closing && !fiber.protectedDepth &&
                            !isNoYieldScope() && !isReadOnlyEvaluation() && !isNotificationDispatch()) {
                        bool pushedOrigin = e.originFunction !is null;
                        if (pushedOrigin)
                            state.pushCall(e.originFunction, "[C]", -1, false, e.originName, e.originKind);
                        fiber.suspendError(e.errorObject);
                        if (pushedOrigin)
                            state.popCall();
                        if (callVisible) {
                            state.popCall();
                            callVisible = false;
                        }
                        auto signal = new CoroutineClose(e.errorObject, true);
                        try {
                            closeValuesFrom(0, signal.errorObject);
                        } catch (LuaException failure) {
                            signal.errorObject = failure.errorObject;
                        }
                        propagate = signal;
                        suspended = true;
                    }
                    if (!suspended) {
                        if (callVisible) {
                            state.popCall();
                            callVisible = false;
                        }
                        closeValuesFrom(0, e.errorObject);
                    }
                } else if (auto request = cast(ExitRequest) incoming) {
                    if (callVisible) {
                        state.popCall();
                        callVisible = false;
                    }
                    closeValuesFrom(0);
                } else if (cast(Exception) incoming is null) {
                    transactionError = true; // an Error: only cleanup runs
                } else if (auto other = cast(Exception) incoming) {
                    transactionError = true;
                    closeValuesFrom(0, LuaValue(other.msg));
                }
            } catch (Throwable inner) {
                propagate = inner;
            }
            // An exception reached the current frame and its handler has run. Inline callees do not
            // have a native frame of their own: leave this one, and let the caller's frame see the
            // exception exactly where a native call would have raised it.
            if (frameThread.inlineTop == inlineBase) {
                if (tail.returnErrors)
                    if (auto protectedFailure = cast(LuaException) propagate) {
                        tail.error = protectedFailure;
                        return null;
                    }
                throw propagate;
            }
            mixin(leaveFrameCode);
            mixin(restoreCallerCode);
            pendingThrow = propagate;
        }
        assert(0, "unreachable");
    }

    static LuaValue captureClosedValue(Prototype proto, LuaClosure closure, scope UpValue delegate(int) findUp, int index) {
        auto subProto = proto.subPrototypes[index];
        UpValue[] captured;
        foreach (desc; subProto.upvalues) {
            auto original = desc.inStack ? findUp(desc.index) : closure.upvalues[desc.index];
            auto copy = new UpValue(null, -1);
            copy.closedVal = original.get();
            copy.isClosed = true;
            captured ~= copy;
        }
        return luaValue(new LuaClosure(subProto, captured));
    }

    // Instruction handlers live in frames of their own: the collector scans the interpreter
    // loop's stack conservatively, and Lua values copied into its locals would be kept alive.

    pragma(inline, false)
    private static bool execGetGlobal(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers, ref const Instruction instr, int pc) {
        int c = instr.c;
        if (proto.constants[instr.b].isString) {
            auto environment = c > 0 ? &registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].ptr() : null;
            auto globals = environment is null ? state.globals : environment.isTable ? environment.asTable : null;
            if (globals !is null) {
                LuaValue* found;
                int status = lookupFieldFast(globals, proto.constants[instr.b].asString, proto.constantHashes[instr.b], proto
                        .lookupHints[pc], found);
                if (status == 1) {
                    copyValue(registers[instr.a], *found);
                    return true;
                }
                if (status == 0) {
                    registers[instr.a] = luaNil();
                    return true;
                }
            }
        }
        auto name = proto.constants[instr.b].match!((string s) => s, _ => toLuaString(proto.constants[instr.b]));
        auto environment = c > 0 ? registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].get() : LuaValue(state.globals);
        return tryGetTable(state, environment, LuaValue(name), registers[instr.a]);
    }

    pragma(inline, false)
    private static bool execSetGlobal(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers, ref const Instruction instr, int pc) {
        if (proto.constants[instr.b].isString) {
            int c = instr.c;
            auto environment = c > 0 ? &registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].ptr() : null;
            auto globals = environment is null ? state.globals : environment.isTable ? environment.asTable : null;
            auto source = instr.aIsK ? &proto.constants[instr.a] : &registers[instr.a];
            if (globals !is null && !source.isNil) {
                auto found = globals.findStringHinted(proto.constants[instr.b].asString, proto.lookupHints[pc]);
                // An existing non-nil field is overwritten directly: no __newindex applies.
                if (found !is null && !found.isNil) {
                    copyValue(*found, *source);
                    return true;
                }
            }
        }
        auto name = proto.constants[instr.b].match!((string s) => s, _ => toLuaString(proto.constants[instr.b]));
        int c = instr.c;
        auto environment = c > 0 ? registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].get() : LuaValue(state.globals);
        return trySetTable(state, environment, LuaValue(name), instr.aIsK ? proto
                .constants[instr.a] : registers[instr.a]);
    }

    pragma(inline, false)
    private static bool execGetTable(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr, int pc) {
        auto keyPtr = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
        if (registers[instr.b].isTable) {
            auto tbl = registers[instr.b].asTable;
            if (instr.cIsK && keyPtr.isString) {
                LuaValue* found;
                int status = lookupFieldFast(tbl, keyPtr.asString, proto.constantHashes[instr.c], proto
                        .lookupHints[pc], found);
                if (status == 1) {
                    copyValue(registers[instr.a], *found);
                    return true;
                }
                if (status == 0) {
                    registers[instr.a] = luaNil();
                    return true;
                }
            } else if (keyPtr.isInteger) {
                long index = keyPtr.asInteger;
                if (index >= 1 && index <= cast(long) tbl.arrayPart.length && !tbl.arrayPart[cast(
                            size_t)(index - 1)].isNil) {
                    copyValue(registers[instr.a], tbl.arrayPart[cast(size_t)(index - 1)]);
                    return true;
                }
            }
        }
        auto keyVal = *keyPtr;
        return tryGetTable(state, registers[instr.b], keyVal, registers[instr.a]);
    }

    pragma(inline, false)
    private static bool execSetTable(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr, int pc) {
        auto keyPtr = instr.bIsK ? &proto.constants[instr.b] : &registers[instr.b];
        auto valPtr = instr.cIsK ? &proto.constants[instr.c] : &registers[instr.c];
        if (instr.bIsK && keyPtr.isString && registers[instr.a].isTable && !valPtr.isNil) {
            auto tbl = registers[instr.a].asTable;
            auto found = tbl.findStringHinted(keyPtr.asString, proto.lookupHints[pc]);
            // An existing non-nil field is overwritten directly: __newindex does not apply.
            if (found !is null && !found.isNil) {
                copyValue(*found, *valPtr);
                return true;
            }
            // A new field of a table without a __newindex handler is a raw store.
            auto handler = tbl.metatable is null ? null : tbl.metatable.findStringHashed("__newindex", newindexNameHash);
            if (tbl.metatable is null || handler is null || handler.isNil) {
                tbl.rawsetStringHashed(keyPtr.asString, proto.constantHashes[instr.b], *valPtr);
                return true;
            }
        }
        if (registers[instr.a].isTable && keyPtr.isInteger) {
            auto tbl = registers[instr.a].asTable;
            long index = keyPtr.asInteger;
            if (tbl.metatable is null && index >= 1 && index <= cast(long) tbl.arrayPart.length
                    && !valPtr.isNil) {
                copyValue(tbl.arrayPart[cast(size_t)(index - 1)], *valPtr);
                return true;
            }
        }
        auto keyVal = *keyPtr;
        auto valVal = *valPtr;
        return trySetTable(state, registers[instr.a], keyVal, valVal);
    }

    pragma(inline, false)
    private static bool execSetList(LuaValue[] registers, int a, int b, int c, int top) {
        if (!isTable(registers[a]))
            return true;
        auto tbl = registers[a].match!((LuaTable t) => t, _ => null);
        int rStart = b;
        long listIdx = c;
        int endReg = (top > rStart) ? top : rStart;
        if (endReg > rStart && listIdx >= 1 && cast(size_t)(listIdx - 1) <= tbl.arrayPart.length)
            tbl.ensureArray(cast(size_t)(listIdx - 1 + endReg - rStart));
        for (int k = rStart; k < endReg; ++k) {
            tbl.rawset(LuaValue(listIdx++), registers[k]); // integer keys: never invalid
        }
        return true;
    }

    pragma(inline, false)
    private static bool execSelf(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr, int pc) {
        if (instr.cIsK && proto.constants[instr.c].isString && registers[instr.b].isTable) {
            auto tbl = registers[instr.b].asTable;
            LuaValue* found;
            int status = lookupFieldFast(tbl, proto.constants[instr.c].asString, proto.constantHashes[instr.c], proto
                    .lookupHints[pc], found);
            if (status >= 0) {
                copyValue(registers[instr.a + 1], registers[instr.b]);
                if (status == 1)
                    copyValue(registers[instr.a], *found);
                else
                    registers[instr.a] = luaNil();
                return true;
            }
        }
        // `text:method(...)`: look the method up in the string metatable's __index table with the
        // constant's cached hash, instead of the generic indexing path.
        if (instr.cIsK && proto.constants[instr.c].isString && registers[instr.b].isString && state
                .stringMetatable !is null) {
            static immutable size_t indexHash = hashOf("__index");
            auto holder = state.stringMetatable.findStringHashed("__index", indexHash);
            if (holder !is null && holder.isTable) {
                LuaValue* found;
                int status = lookupFieldFast(holder.asTable, proto.constants[instr.c].asString,
                        proto.constantHashes[instr.c], proto.lookupHints[pc], found);
                if (status == 1) {
                    copyValue(registers[instr.a + 1], registers[instr.b]);
                    copyValue(registers[instr.a], *found);
                    return true;
                }
            }
        }
        registers[instr.a + 1] = registers[instr.b];
        auto keyVal = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        return tryGetTable(state, registers[instr.b], keyVal, registers[instr.a]);
    }

    pragma(inline, false)
    private static bool execArith(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto left = instr.bIsK ? proto.constants[instr.b] : registers[instr.b];
        auto right = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        auto result = arithmeticResult(state, left, right, instr.op);
        if (state.raisedError !is null)
            return false;
        copyValue(registers[instr.a], result);
        return true;
    }

    // Return construction avoids visiting the old tag of an initialized
    // temporary before copying a trivially stored LuaValue into its register.
    pragma(inline, true)
    private static LuaValue arithmeticResult(LuaState state, LuaValue left, LuaValue right, OpCode op) {
        final switch (op) {
        case OpCode.Add:
            return opAdd(state, left, right);
        case OpCode.Sub:
            return opSub(state, left, right);
        case OpCode.Mul:
            return opMul(state, left, right);
        case OpCode.Div:
            return opDiv(state, left, right);
        case OpCode.IDiv:
            return opIDiv(state, left, right);
        case OpCode.Mod:
            return opMod(state, left, right);
        case OpCode.Pow:
            return opPow(state, left, right);
        case OpCode.BAnd:
            return opBAnd(state, left, right);
        case OpCode.BOr:
            return opBOr(state, left, right);
        case OpCode.BXor:
            return opBXor(state, left, right);
        case OpCode.Shl:
            return opShl(state, left, right);
        case OpCode.Shr:
            return opShr(state, left, right);
        case OpCode.Concat:
            return opConcat(state, left, right);
        case OpCode.Nop, OpCode.Move, OpCode.LoadNil, OpCode.LoadBool, OpCode.LoadInt, OpCode.LoadK,
            OpCode.GetGlobal, OpCode.SetGlobal, OpCode.GetUpval, OpCode.SetUpval, OpCode.GetTable,
            OpCode.SetTable, OpCode.NewTable, OpCode.SetList, OpCode.Self, OpCode.Unm, OpCode.Not,
            OpCode.Len, OpCode.BNot, OpCode.Jmp, OpCode.Eq, OpCode.Lt, OpCode.Le, OpCode.Test,
            OpCode.TestSet, OpCode.Call, OpCode.TailCall, OpCode.Return, OpCode.ForPrep, OpCode.ForLoop,
            OpCode.TForCall, OpCode.TForLoop, OpCode.Closure, OpCode.Vararg, OpCode.Close, OpCode.ToClose,
            OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.DeclRel, OpCode.AddFact, OpCode.RetractFact,
            OpCode.SetFact, OpCode.DeleteKey, OpCode.AdjustKey, OpCode.BeginTransaction,
            OpCode.EndTransaction, OpCode.Rollback, OpCode.DefineContent, OpCode.DefineDeck,
            OpCode.RegRule, OpCode.MakeQuery, OpCode.AdjustClamp, OpCode.ExitTransaction:
            return luaNil();
        }
    }

    pragma(inline, false)
    private static bool execUnary(LuaState state, LuaValue[] registers, ref const Instruction instr) {
        auto operand = registers[instr.b];
        LuaValue result;
        switch (instr.op) {
        case OpCode.Unm:
            result = opUnm(state, operand);
            break;
        case OpCode.Not:
            result = luaValue(!isTruthy(operand));
            break;
        case OpCode.Len:
            result = opLen(state, operand);
            break;
        default:
            result = opBNot(state, operand);
            break;
        }
        if (state.raisedError !is null)
            return false;
        registers[instr.a] = result;
        return true;
    }

    pragma(inline, false)
    private static bool execCompare(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto left = instr.aIsK ? proto.constants[instr.a] : registers[instr.a];
        auto right = instr.bIsK ? proto.constants[instr.b] : registers[instr.b];
        switch (instr.op) {
        case OpCode.Eq:
            return opEq(state, left, right);
        case OpCode.Lt:
            return opLt(state, left, right);
        default:
            return opLe(state, left, right);
        }
    }

    private static bool isNativeFunction(LuaValue v) {
        return v.match!((LuaFunction f) => cast(LuaNativeFunction) f !is null, _ => false);
    }

    /// Calls the function in R[a] with `numArgs` arguments, in a frame of its own. A native's
    /// error reported as a value is left in `state.raisedError`: test it before using the result.
    pragma(inline, false)
    private static LuaValue[] doCall(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
            int a, int numArgs, int callPc) {
        auto callee = registers[a];
        LuaValue[] callArgs = numArgs <= 0 ? [] : callee.isFunction && callee.asFunction.borrowsArgs ? registers[a + 1 .. a + 1 + numArgs] : registers[a + 1 .. a + 1 + numArgs]
            .dup;
        checkCallable(state, callee);
        auto previous = state.callWorldObject;
        if (proto.callSites.length != proto.code.length)
            proto.buildCallSites();
        int context = proto.callSites[callPc].world;
        auto world = context > 0 ? unwrapWorld(registers[context - 1]) : context < 0 ? unwrapWorld(
                closure.upvalues[-context - 1].get()) : state.globalWorldObject;
        state.callWorldObject = world;
        scope (exit)
            state.callWorldObject = previous;
        auto identity = proto.callSites[callPc];
        return callValue(state, callee, callArgs, false, identity.name, identity.kind, true, true);
    }

    pragma(inline, false)
    private static void execTForCall(LuaState state, LuaValue[] registers, int a, int wanted, bool noHook) {
        auto iterFn = registers[a];
        if (noHook && wanted >= 1 && iterFn.isFunction && registers[a + 1].isTable) {
            // `pairs`/`ipairs` loops: step the traversal directly, with no call, argument array
            // or result array.
            auto iterator = iterFn.asFunction;
            auto table = registers[a + 1].asTable;
            if (iterator is state.fastNext) {
                LuaValue key, value;
                int status = table.nextFast(registers[a + 2], key, value);
                if (status >= 0) {
                    if (status == 1) {
                        copyValue(registers[a + 4], key);
                        if (wanted >= 2)
                            copyValue(registers[a + 5], value);
                        for (int i = 2; i < wanted; ++i)
                            registers[a + 4 + i] = luaNil();
                    } else {
                        for (int i = 0; i < wanted; ++i)
                            registers[a + 4 + i] = luaNil();
                    }
                    return;
                }
            } else if (iterator is state.fastIpairsIter && registers[a + 2].isInteger) {
                long index = cast(long)(cast(ulong) registers[a + 2].asInteger + 1);
                auto item = table.rawgetInt(index);
                if (!item.isNil || table.metatable is null) {
                    if (item.isNil) {
                        for (int i = 0; i < wanted; ++i)
                            registers[a + 4 + i] = luaNil();
                    } else {
                        setInteger(registers[a + 4], index);
                        if (wanted >= 2)
                            copyValue(registers[a + 5], item);
                        for (int i = 2; i < wanted; ++i)
                            registers[a + 4 + i] = luaNil();
                    }
                    return;
                }
            }
        }
        if (!isFunction(iterFn)) {
            auto mt = state.getMetatable(iterFn);
            if (mt is null || isNil(mt.rawget(LuaValue("__call"))))
                throw new LuaException("attempt to call a " ~ objectTypeName(state, iterFn) ~ " value (for iterator 'for iterator')");
        }
        auto iterState = registers[a + 1];
        auto iterVar = registers[a + 2];
        LuaValue[] tResults;
        if (iterFn.isFunction && iterFn.asFunction.borrowsArgs) {
            // Natives that only read their arguments (coroutine.wrap generators) get a stack pair.
            LuaValue[2] pair = [iterState, iterVar];
            tResults = callValue(state, iterFn, pair[], false, "for iterator", "for iterator");
        } else
            tResults = callValue(state, iterFn, [iterState, iterVar], false, "for iterator", "for iterator");
        for (int i = 0; i < wanted; ++i) {
            registers[a + 4 + i] = (i < tResults.length) ? tResults[i] : luaNil();
        }
    }

    pragma(inline, false)
    private static void execClosure(LuaClosure closure, Prototype proto, LuaValue[] registers, int a, int index,
            scope UpValue delegate(int) findUp) {
        auto subProto = proto.subPrototypes[index];
        auto created = new LuaClosure(subProto, subProto.upvalues.length);
        size_t captured = 0;
        foreach (desc; subProto.upvalues) {
            if (desc.inStack) {
                created.upvalues[captured++] = findUp(desc.index);
            } else if (desc.index < closure.upvalues.length) {
                created.upvalues[captured++] = closure.upvalues[desc.index];
            }
        }
        if (captured != created.upvalues.length)
            created.upvalues = created.upvalues[0 .. captured];
        registers[a] = luaValue(created);
    }

    /// Performs a call and copies its results into the registers. Returns the new `top`, or the
    /// negated number of results when the register array has to grow first (the results are then
    /// kept in `state.stashedResults`).
    pragma(inline, false)
    private static int callAndPlace(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
            int a, int numArgs, int wanted, int callPc) {
        import varis.gc : stackHygiene, scrubDeadStack;

        if (stackHygiene)
            scrubDeadStack();
        auto results = doCall(state, closure, proto, registers, a, numArgs, callPc);
        if (state.raisedError !is null)
            return callRaised;
        if (wanted >= 0) {
            for (int i = 0; i < wanted; ++i)
                registers[a + i] = (i < results.length) ? results[i] : luaNil();
            return a + wanted;
        }
        if (a + results.length >= registers.length) {
            state.stashedResults = results;
            return -cast(int) results.length;
        }
        for (size_t i = 0; i < results.length; ++i)
            registers[a + i] = results[i];
        return a + cast(int) results.length;
    }

    /// callAndPlace's result when the callee reported an error as a value (`state.raisedError`).
    private enum int callRaised = int.min;

    pragma(inline, false)
    private static int placeStashedResults(LuaState state, LuaValue[] registers, int a) {
        auto results = state.stashedResults;
        state.stashedResults = null;
        for (size_t i = 0; i < results.length; ++i)
            registers[a + i] = results[i];
        return a + cast(int) results.length;
    }

    /// Copies call results into registers without leaving temporaries in the caller's frame.
    pragma(inline, false)
    private static void placeResults(LuaValue[] registers, int a, int count, LuaValue[] results) {
        for (int i = 0; i < count; ++i) {
            registers[a + i] = (i < results.length) ? results[i] : luaNil();
        }
    }

    /// Bitwise value copy that keeps the value out of stack temporaries (the collector scans
    /// the interpreter's frame conservatively).
    pragma(inline, true) @trusted
    private static void setInteger(ref LuaValue destination, long value) {
        auto temporary = LuaValue(value);
        copyValue(destination, temporary);
    }

    pragma(inline, true) @trusted
    private static void setBoolean(ref LuaValue destination, bool value) {
        auto temporary = LuaValue(value);
        copyValue(destination, temporary);
    }

    pragma(inline, true) @trusted
    private static void setFloat(ref LuaValue destination, double value) {
        auto temporary = LuaValue(value);
        copyValue(destination, temporary);
    }

    pragma(inline, true) @trusted
    private static void copyValue(ref LuaValue destination, ref const LuaValue source) {
        import core.stdc.string : memmove;

        memmove(cast(void*)&destination, cast(const(void)*)&source, LuaValue.sizeof);
    }

    /// Allocates in a frame of its own so that no pointer to the new table lingers in the
    /// interpreter loop's stack frame (the collector scans stacks conservatively).
    pragma(inline, false)
    private static void newTableInto(ref LuaValue slot, uint sizes) {
        slot = luaValue(new LuaTable(sizes >> 16, sizes & 0xffff));
    }

    // -------------------------------------------------------------------------
    // Helper Operations & Metamethod Dispatch
    // -------------------------------------------------------------------------

    /// Indexing for host code: an error is thrown. The interpreter uses `tryGetTable`.
    static LuaValue getTable(LuaState state, LuaValue tableVal, LuaValue keyVal, bool viaMeta = false) {
        LuaValue result;
        if (!tryGetTable(state, tableVal, keyVal, result, viaMeta))
            throw state.takeRaised();
        return result;
    }

    /// `tableVal[keyVal]` with metamethods. On an error the result is false and the error sits in
    /// `state.raisedError` (nothing is thrown by this function itself; an error escaping a Lua
    /// metamethod still arrives as an exception until the executor boundary is converted).
    static bool tryGetTable(LuaState state, LuaValue tableVal, LuaValue keyVal, out LuaValue result, bool viaMeta = false) {
        auto current = tableVal;
        for (int loop = 0; loop < 2000; ++loop) {
            LuaValue meta;
            if (current.typeOf() == LuaType.Table) {
                auto t = current.match!((LuaTable tbl) => tbl, _ => null);
                auto res = t.rawget(keyVal);
                if (!isNil(res)) {
                    result = res;
                    return true;
                }
                if (t.metatable is null)
                    return true;
                meta = t.metatable.rawget(LuaValue("__index"));
                if (isNil(meta))
                    return true;
            } else {
                meta = metaField(state, current, "__index");
                if (isNil(meta)) {
                    state.raisedError = indexError(state, current, viaMeta || loop > 0);
                    return false;
                }
            }
            if (isFunction(meta)) {
                auto resList = callValue(state, meta, [current, keyVal], false, "index", "metamethod", false, true);
                if (state.raisedError !is null)
                    return false;
                if (resList.length > 0)
                    result = resList[0];
                return true;
            }
            current = meta;
        }
        state.raisedError = new LuaException("'__index' chain too long; possible loop");
        return false;
    }

    /// Assignment for host code: an error is thrown. The interpreter uses `trySetTable`.
    static void setTable(LuaState state, LuaValue tableVal, LuaValue keyVal, LuaValue valVal, bool viaMeta = false) {
        if (!trySetTable(state, tableVal, keyVal, valVal, viaMeta))
            throw state.takeRaised();
    }

    /// `tableVal[keyVal] = valVal` with metamethods; false with the error in `state.raisedError`.
    static bool trySetTable(LuaState state, LuaValue tableVal, LuaValue keyVal, LuaValue valVal, bool viaMeta = false) {
        auto current = tableVal;
        for (int loop = 0; loop < 2000; ++loop) {
            LuaValue meta;
            if (current.typeOf() == LuaType.Table) {
                auto t = current.match!((LuaTable tbl) => tbl, _ => null);
                bool raw = t.metatable is null;
                if (!raw) {
                    raw = !isNil(t.rawget(keyVal));
                    if (!raw) {
                        meta = t.metatable.rawget(LuaValue("__newindex"));
                        raw = isNil(meta);
                    }
                }
                if (raw) {
                    if (auto problem = LuaTable.keyProblem(keyVal)) {
                        state.raisedError = new LuaException(problem);
                        return false;
                    }
                    t.rawset(keyVal, valVal);
                    return true;
                }
            } else {
                meta = metaField(state, current, "__newindex");
                if (isNil(meta)) {
                    state.raisedError = indexError(state, current, viaMeta || loop > 0);
                    return false;
                }
            }
            if (isFunction(meta)) {
                callValue(state, meta, [current, keyVal, valVal], false, "newindex", "metamethod", false, true);
                return state.raisedError is null;
            }
            current = meta;
        }
        state.raisedError = new LuaException("'__newindex' chain too long; possible loop");
        return false;
    }

    /// Raises the "attempt to call" error (with variable info) for values that cannot be called.
    private static void checkCallable(LuaState state, LuaValue callee) {
        if (isFunction(callee))
            return;
        auto mt = state.getMetatable(callee);
        if (mt !is null && !isNil(mt.rawget(LuaValue("__call"))))
            return;
        auto failure = new LuaException("attempt to call a " ~ objectTypeName(state, callee) ~ " value");
        failure.culprit = 1;
        throw failure;
    }

    private static LuaException indexError(LuaState state, LuaValue tableVal, bool viaMeta = false) {
        auto failure = new LuaException("attempt to index a " ~ objectTypeName(state, tableVal) ~ " value");
        failure.culprit = viaMeta ? 0 : 1;
        return failure;
    }

    /// With `statusReturn`, an error a native reported as a value is left in `state.raisedError`
    /// (already attributed) and null is returned; the caller must test the slot.
    static LuaValue[] callValue(LuaState state, LuaValue callee, LuaValue[] args, bool tailCall = false, string name = "", string nameKind = "", bool callSite = false,
            bool statusReturn = false) {
        // Emulate LUAI_MAXCCALLS: calls that re-enter the VM from native code or metamethods
        // nest on the C stack in C Lua (calls from Lua code do not).
        auto cThread = state is null ? null : state.currentThread();
        if (!callSite && cThread !is null) {
            ++cThread.cCalls;
            if (cThread.cCalls == 200) {
                --cThread.cCalls;
                throw new LuaException("C stack overflow");
            }
            if (cThread.cCalls >= 220) {
                --cThread.cCalls;
                auto nested = new LuaException("error in error handling");
                nested.needsLocation = false;
                throw nested;
            }
        }
        scope (exit)
            if (!callSite && cThread !is null)
                --cThread.cCalls;

        try {
            resolveCallable(state, callee, args);
        } catch (LuaException failure) {
            import std.string : startsWith;

            if (nameKind.length && failure.msg.startsWith("attempt to call")) {
                failure.errorObject = LuaValue(toLuaString(failure.errorObject) ~ " (" ~ nameKind ~ " '" ~ name ~ "')");
                failure.msg = toLuaString(failure.errorObject);
            }
            if (state !is null) {
                if (state.callStack.length)
                    failure.locate(state.callStack[$ - 1].source, state.callStack[$ - 1].line);
                state.dispatchError(failure);
            }
            throw failure;
        }
        if (isFunction(callee)) {
            auto fn = callee.match!((LuaFunction f) => f, _ => null);
            if (auto nativeFn = fn.isNativeFunction ? cast(LuaNativeFunction) cast(void*) fn : null) {
                if (state !is null)
                    state.pushCall(nativeFn, "[C]", -1, tailCall, name, nameKind);
                scope (exit) {
                    if (state !is null)
                        state.popCall();
                }
                if (state !is null) {
                    state.callStack[$ - 1].cArgs = args;
                }
                bool hooked = cThread !is null && cThread.hookFunction !is null;
                if (hooked)
                    state.debugHook("call", -1, args, true);
                // What a failing native's error needs before it leaves this call, whether it
                // arrived as a value (the state's error slot) or as an exception.
                void attribute(LuaException failure) {
                    failure.culprit = 0;
                    if (failure.originFunction is null) {
                        failure.originFunction = nativeFn;
                        failure.originName = name;
                        failure.originKind = nameKind;
                    }
                    if (auto argFailure = cast(ArgError) failure) {
                        argFailure.function_ = nativeFn;
                        // A Lua call site names the function itself (see executeFrame).
                        if (!(callSite && name.length == 0))
                            formatArgError(state, argFailure, nativeFn, name, nameKind);
                    }
                    auto frames = state.callStack;
                    if (frames.length > 1)
                        failure.locate(frames[$ - 2].source, frames[$ - 2].line);
                    else
                        failure.locate("", -1);
                    state.dispatchError(failure);
                }

                LuaException reported;
                try {
                    auto results = nativeFn.callStatus(cast(void*) state, args);
                    if (state is null || state.raisedError is null) {
                        if (hooked || (cThread !is null && cThread.hookFunction !is null))
                            state.debugHook("return", -1, results, true);
                        return results;
                    }
                    reported = state.takeRaised();
                } catch (LuaException failure) {
                    attribute(failure);
                    throw failure;
                }
                // The native returned its error as a value.
                attribute(reported);
                if (!statusReturn)
                    throw reported;
                state.raisedError = reported;
                return null;
            }
            if (auto closure = cast(LuaClosure) fn)
                return execute(state, closure, args, name, nameKind);
            return fn.call(cast(void*) state, args);
        }

        throw new LuaException(format("attempt to call a %s value", typeName(callee)));
    }

    /// luaL_argerror: names the function from its call site, else from package.loaded.
    private static void formatArgError(LuaState state, ArgError failure, LuaFunction fn, string name, string kind) {
        if (failure.formatted)
            return;
        failure.formatted = true;
        int arg = failure.arg;
        string message;
        if (kind == "method") {
            --arg;
            if (arg == 0)
                message = "calling '" ~ name ~ "' on bad self (" ~ failure.extra ~ ")";
        }
        if (message.length == 0) {
            if (name.length == 0)
                name = globalFunctionName(state, fn);
            message = "bad argument #" ~ arg.to!string ~ " to '" ~ (name.length ? name : "?") ~ "' (" ~ failure.extra ~ ")";
        }
        failure.errorObject = LuaValue(message);
        failure.msg = message;
    }

    /// pushglobalfuncname: finds "module.name" for a function in package.loaded.
    static string globalFunctionName(LuaState state, LuaFunction fn) {
        auto package_ = state.globals.rawget(LuaValue("package"));
        if (!isTable(package_))
            return "";
        auto loaded = package_.match!((LuaTable t) => t, _ => null).rawget(LuaValue("loaded"));
        if (!isTable(loaded))
            return "";
        LuaValue key, value, prevKey;
        auto loadedTable = loaded.match!((LuaTable t) => t, _ => null);
        string found;
        while (loadedTable.next(prevKey, key, value)) {
            prevKey = key;
            if (!isString(key) || !isTable(value))
                continue;
            auto module_ = value.match!((LuaTable t) => t, _ => null);
            LuaValue fk, fv, fprev;
            while (module_.next(fprev, fk, fv)) {
                fprev = fk;
                if (isString(fk) && isFunction(fv) && fv.match!((LuaFunction f) => f is fn, _ => false)) {
                    auto moduleName = toLuaString(key);
                    auto fname = toLuaString(fk);
                    if (moduleName == "_G")
                        return fname;
                    found = moduleName ~ "." ~ fname;
                }
            }
        }
        return found;
    }

    private static void resolveCallable(LuaState state, ref LuaValue callee, ref LuaValue[] args) {
        for (int depth = 0; !isFunction(callee); ++depth) {
            if (depth >= 2000)
                throw new LuaException("'__call' chain too long; possible loop");
            auto metatable = state.getMetatable(callee);
            auto method = metatable is null ? luaNil() : metatable.rawget(LuaValue("__call"));
            if (isNil(method))
                throw new LuaException(format("attempt to call a %s value", typeName(callee)));
            args = [callee] ~ args;
            callee = method;
        }
    }

    // -------------------------------------------------------------------------
    // Symbolic variable information for error messages (ldebug.c getobjname)
    // -------------------------------------------------------------------------

    private static int culpritRegister(Instruction instr, int culprit) {
        switch (instr.op) {
        case OpCode.GetTable, OpCode.Self:
            return instr.b;
        case OpCode.SetTable:
            return instr.a;
        case OpCode.Unm, OpCode.Len, OpCode.BNot:
            return instr.b;
        case OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv, OpCode.Mod, OpCode.Pow,
            OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr, OpCode.Concat:
            if (culprit == 1)
                return instr.bIsK ? -1 : instr.b;
            return instr.cIsK ? -1 : instr.c;
        case OpCode.Call, OpCode.TailCall:
            return instr.a;
        default:
            return -1;
        }
    }

    /// "(constant 'x')" for a string constant operand (C Lua loads it into a register first).
    private static string constantInfo(Prototype proto, ref const Instruction instr, int culprit) {
        switch (instr.op) {
        case OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv, OpCode.Mod, OpCode.Pow,
            OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr, OpCode.Concat:
            break;
        default:
            return "";
        }
        bool isK = culprit == 1 ? instr.bIsK : instr.cIsK;
        int index = culprit == 1 ? instr.b : instr.c;
        if (!isK || index < 0 || index >= cast(int) proto.constants.length)
            return "";
        auto k = proto.constants[index];
        if (!isString(k))
            return "";
        return "(constant '" ~ toLuaString(k) ~ "')";
    }

    private static void applyVariableInfo(LuaException e, Prototype proto, int pc) {
        int culprit = e.culprit;
        e.culprit = 0;
        int reg = culpritRegister(proto.code[pc], culprit);
        string info = reg < 0 ? constantInfo(proto, proto.code[pc], culprit) : variableInfo(proto, pc, reg);
        auto text = toLuaString(e.errorObject);
        import std.string : indexOf;

        if (text.indexOf("%s") >= 0)
            text = text.replace("%s", info.length ? " " ~ info : "");
        else if (info.length)
            text ~= " " ~ info;
        e.errorObject = LuaValue(text);
        e.msg = text;
    }

    /// Returns "(kind 'name')" for the register at the failing instruction, or "".
    static string variableInfo(Prototype proto, int pc, int reg) {
        string name;
        auto kind = objectName(proto, pc, reg, name);
        return kind.length ? "(" ~ kind ~ " '" ~ name ~ "')" : "";
    }

    private static string activeLocalName(Prototype proto, int pc, int reg) {
        foreach (local; proto.debugLocals) {
            if (local.register == reg && local.startPC <= pc && pc < local.endPC &&
                    local.name.length && local.name[0] != '(' && local.name[0] != '@')
                return local.name;
        }
        return null;
    }

    private static int findSetRegister(Prototype proto, int lastPc, int reg) {
        int setReg = -1;
        int jumpTarget = 0;
        foreach (i; 0 .. lastPc) {
            auto instr = proto.code[i];
            bool change = false;
            switch (instr.op) {
            case OpCode.LoadNil:
                change = reg >= instr.a && reg <= instr.a + instr.b;
                break;
            case OpCode.Call, OpCode.TailCall:
                change = reg >= instr.a;
                break;
            case OpCode.TForCall:
                change = reg >= instr.a + 3;
                break;
            case OpCode.Jmp, OpCode.Test, OpCode.ForPrep, OpCode.ForLoop, OpCode.TForLoop:
                int dest = i + 1 + instr.sBx;
                if (dest <= lastPc && dest > jumpTarget)
                    jumpTarget = dest;
                break;
            case OpCode.Self:
                change = reg == instr.a || reg == instr.a + 1;
                break;
            case OpCode.Vararg:
                change = reg >= instr.a;
                break;
            case OpCode.Move, OpCode.LoadBool, OpCode.LoadInt, OpCode.LoadK, OpCode.GetGlobal, OpCode.GetUpval,
                OpCode.NewTable, OpCode.GetTable, OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv,
                OpCode.Mod, OpCode.Pow, OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr,
                OpCode.Concat, OpCode.Unm, OpCode.Not, OpCode.Len, OpCode.BNot, OpCode.Closure,
                OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.MakeQuery:
                change = reg == instr.a;
                break;
            case OpCode.TestSet:
                int testDest = i + 1 + instr.sBx;
                if (testDest <= lastPc && testDest > jumpTarget)
                    jumpTarget = testDest;
                change = reg == instr.a;
                break;
            default:
                break;
            }
            if (change)
                setReg = i < jumpTarget ? -1 : i;
        }
        return setReg;
    }

    private static string constantName(Prototype proto, int index) {
        if (index < 0 || index >= proto.constants.length)
            return null;
        return proto.constants[index].match!((string s) => s.length ? s : "", _ => cast(string) null);
    }

    private static string objectName(Prototype proto, int lastPc, int reg, out string name) {
        name = activeLocalName(proto, lastPc, reg);
        if (name !is null)
            return "local";
        int pc = findSetRegister(proto, lastPc, reg);
        if (pc < 0)
            return null;
        auto instr = proto.code[pc];
        switch (instr.op) {
        case OpCode.Move:
            if (instr.b < instr.a)
                return objectName(proto, pc, instr.b, name);
            break;
        case OpCode.GetGlobal:
            name = constantName(proto, instr.b);
            return name is null ? null : "global";
        case OpCode.GetTable:
            if (instr.cIsK) {
                name = constantName(proto, instr.c);
                if (name is null) {
                    if (instr.c < proto.constants.length && isInteger(proto.constants[instr.c]))
                        name = "integer index";
                    else
                        return null;
                }
            } else {
                string keyName;
                auto keyKind = objectName(proto, pc, instr.c, keyName);
                name = keyKind == "constant" ? keyName : "?";
            }
            string tableName;
            auto tableKind = objectName(proto, pc, instr.b, tableName);
            return (tableKind == "upvalue" || tableKind == "local") && tableName == "_ENV" ? "global" : "field";
        case OpCode.GetUpval:
            if (instr.b < proto.upvalues.length) {
                name = proto.upvalues[instr.b].name;
                return "upvalue";
            }
            break;
        case OpCode.LoadK:
            name = constantName(proto, instr.b);
            return name is null ? null : "constant";
        case OpCode.Self:
            if (instr.cIsK)
                name = constantName(proto, instr.c);
            else {
                string keyName;
                name = objectName(proto, pc, instr.c, keyName) == "constant" ? keyName : "?";
            }
            return name is null ? null : "method";
        default:
            break;
        }
        return null;
    }

    static bool toCoercedNumber(LuaValue val, out LuaValue outNum) {
        if (isInteger(val) || isFloat(val)) {
            outNum = val;
            return true;
        }
        if (isString(val))
            return parseLuaNumber(val.match!((string text) => text, _ => ""), outNum);
        return false;
    }

    // Arithmetic helpers
    static LuaValue opAdd(LuaState state, LuaValue a, LuaValue b) {
        if (isInteger(a) && isInteger(b)) {
            return luaValue(a.match!((long i) => i, _ => 0L) + b.match!((long i) => i, _ => 0L));
        }
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            if (isInteger(na) && isInteger(nb)) {
                return luaValue(na.match!((long i) => i, _ => 0L) + nb.match!((long i) => i, _ => 0L));
            }
            return luaValue(toDoubleVal(na) + toDoubleVal(nb));
        }
        return invokeBinMeta(state, a, b, "__add");
    }

    static LuaValue opSub(LuaState state, LuaValue a, LuaValue b) {
        if (isInteger(a) && isInteger(b)) {
            return luaValue(a.match!((long i) => i, _ => 0L) - b.match!((long i) => i, _ => 0L));
        }
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            if (isInteger(na) && isInteger(nb)) {
                return luaValue(na.match!((long i) => i, _ => 0L) - nb.match!((long i) => i, _ => 0L));
            }
            return luaValue(toDoubleVal(na) - toDoubleVal(nb));
        }
        return invokeBinMeta(state, a, b, "__sub");
    }

    static LuaValue opMul(LuaState state, LuaValue a, LuaValue b) {
        if (isInteger(a) && isInteger(b)) {
            return luaValue(a.match!((long i) => i, _ => 0L) * b.match!((long i) => i, _ => 0L));
        }
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            if (isInteger(na) && isInteger(nb)) {
                return luaValue(na.match!((long i) => i, _ => 0L) * nb.match!((long i) => i, _ => 0L));
            }
            return luaValue(toDoubleVal(na) * toDoubleVal(nb));
        }
        return invokeBinMeta(state, a, b, "__mul");
    }

    static LuaValue opDiv(LuaState state, LuaValue a, LuaValue b) {
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            return luaValue(toDoubleVal(na) / toDoubleVal(nb));
        }
        return invokeBinMeta(state, a, b, "__div");
    }

    static LuaValue opIDiv(LuaState state, LuaValue a, LuaValue b) {
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            if (isInteger(na) && isInteger(nb)) {
                long bi = nb.match!((long i) => i, _ => 0L);
                if (bi == 0)
                    return failValue(state, new LuaException("attempt to divide by zero"));
                long ai = na.match!((long i) => i, _ => 0L);
                // Lua wraps MININTEGER / -1, and rounds division down.
                if (bi == -1)
                    return luaValue(-ai);
                long quotient = ai / bi;
                if (ai % bi != 0 && (ai < 0) != (bi < 0))
                    --quotient;
                return luaValue(quotient);
            }
            return luaValue(floor(toDoubleVal(na) / toDoubleVal(nb)));
        }
        return invokeBinMeta(state, a, b, "__idiv");
    }

    static LuaValue opMod(LuaState state, LuaValue a, LuaValue b) {
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            if (isInteger(na) && isInteger(nb)) {
                long bi = nb.match!((long i) => i, _ => 0L);
                if (bi == 0)
                    return failValue(state, new LuaException("attempt to perform 'n%0'"));
                if (bi == -1)
                    return luaValue(0L);
                long remainder = na.match!((long i) => i, _ => 0L) % bi;
                if (remainder != 0 && (remainder < 0) != (bi < 0))
                    remainder += bi;
                return luaValue(remainder);
            }
            import std.math : fmod;

            double divisor = toDoubleVal(nb);
            double remainder = fmod(toDoubleVal(na), divisor);
            if ((remainder > 0 && divisor < 0) || (remainder < 0 && divisor > 0))
                remainder += divisor;
            return luaValue(remainder);
        }
        return invokeBinMeta(state, a, b, "__mod");
    }

    static LuaValue opPow(LuaState state, LuaValue a, LuaValue b) {
        LuaValue na, nb;
        if (toCoercedNumber(a, na) && toCoercedNumber(b, nb)) {
            return luaValue(pow(toDoubleVal(na), toDoubleVal(nb)));
        }
        return invokeBinMeta(state, a, b, "__pow");
    }

    private static bool bitwiseInteger(LuaValue value, out long integer) {
        if (isInteger(value)) {
            integer = value.match!((long i) => i, _ => 0L);
            return true;
        }
        return isFloat(value) && floatToInteger(toDoubleVal(value), integer);
    }

    static LuaValue opBAnd(LuaState state, LuaValue a, LuaValue b) {
        long ai, bi;
        if (bitwiseInteger(a, ai) && bitwiseInteger(b, bi)) {
            return luaValue(ai & bi);
        }
        return invokeBinMeta(state, a, b, "__band");
    }

    static LuaValue opBOr(LuaState state, LuaValue a, LuaValue b) {
        long ai, bi;
        if (bitwiseInteger(a, ai) && bitwiseInteger(b, bi)) {
            return luaValue(ai | bi);
        }
        return invokeBinMeta(state, a, b, "__bor");
    }

    static LuaValue opBXor(LuaState state, LuaValue a, LuaValue b) {
        long ai, bi;
        if (bitwiseInteger(a, ai) && bitwiseInteger(b, bi)) {
            return luaValue(ai ^ bi);
        }
        return invokeBinMeta(state, a, b, "__bxor");
    }

    static LuaValue opShl(LuaState state, LuaValue a, LuaValue b) {
        long ai, bi;
        if (bitwiseInteger(a, ai) && bitwiseInteger(b, bi)) {
            return luaValue(shiftInteger(ai, bi));
        }
        return invokeBinMeta(state, a, b, "__shl");
    }

    static LuaValue opShr(LuaState state, LuaValue a, LuaValue b) {
        long ai, bi;
        if (bitwiseInteger(a, ai) && bitwiseInteger(b, bi)) {
            return luaValue(bi == long.min ? 0L : shiftInteger(ai, -bi));
        }
        return invokeBinMeta(state, a, b, "__shr");
    }

    private static long shiftInteger(long value, long distance) {
        if (distance >= 64 || distance <= -64)
            return 0;
        return distance < 0 ? cast(long)(cast(ulong) value >> -distance) : value << distance;
    }

    static LuaValue opConcat(LuaState state, LuaValue a, LuaValue b) {
        if ((isString(a) || isNumber(a)) && (isString(b) || isNumber(b))) {
            return luaValue(toLuaString(a) ~ toLuaString(b));
        }
        return invokeBinMeta(state, a, b, "__concat");
    }

    static LuaValue opUnm(LuaState state, LuaValue a) {
        if (isInteger(a))
            return luaValue(-a.match!((long i) => i, _ => 0L));
        if (isFloat(a))
            return luaValue(-a.match!((double d) => d, _ => 0.0));
        LuaValue number;
        if (toCoercedNumber(a, number))
            return opUnm(state, number);
        return invokeUnaryMeta(state, a, "__unm");
    }

    static LuaValue opLen(LuaState state, LuaValue a) {
        if (isTable(a)) {
            auto t = a.match!((LuaTable tbl) => tbl, _ => null);
            auto meta = t.getMetamethod("__len");
            if (!isNil(meta)) {
                auto res = callValue(state, meta, [a, a], false, "len", "metamethod", false, true);
                if (state.raisedError !is null)
                    return luaNil();
                return res.length > 0 ? res[0] : luaNil();
            }
            return luaValue(t.rawLen());
        }
        if (isString(a)) {
            return luaValue(cast(long) a.match!((string s) => s.length, _ => 0LU));
        }
        return invokeUnaryMeta(state, a, "__len");
    }

    static LuaValue opBNot(LuaState state, LuaValue a) {
        long integer;
        if (bitwiseInteger(a, integer))
            return luaValue(~integer);
        return invokeUnaryMeta(state, a, "__bnot");
    }

    /// Equality with the __eq metamethod (tables and full userdata only).
    static bool opEq(LuaState state, LuaValue a, LuaValue b) {
        if (luaRawEqual(a, b))
            return true;
        auto ta = a.typeOf();
        if (ta != b.typeOf() || (ta != LuaType.Table && ta != LuaType.UserData))
            return false;
        auto meta = metaField(state, a, "__eq");
        if (isNil(meta))
            meta = metaField(state, b, "__eq");
        if (isNil(meta))
            return false;
        auto result = callValue(state, meta, [a, b], false, "eq", "metamethod", false, true);
        return state.raisedError is null && result.length && isTruthy(result[0]);
    }

    static bool opLt(LuaState state, LuaValue a, LuaValue b) {
        if (isNumber(a) && isNumber(b)) {
            return luaNumberLess(a, b);
        }
        if (isString(a) && isString(b)) {
            return a.match!((string sa) => sa, _ => "") < b.match!((string sb) => sb, _ => "");
        }
        auto res = invokeBinMeta(state, a, b, "__lt");
        return isTruthy(res);
    }

    static bool opLe(LuaState state, LuaValue a, LuaValue b) {
        if (isNumber(a) && isNumber(b)) {
            return luaNumberLessEqual(a, b);
        }
        if (isString(a) && isString(b)) {
            return a.match!((string sa) => sa, _ => "") <= b.match!((string sb) => sb, _ => "");
        }
        auto res = invokeBinMeta(state, a, b, "__le");
        return isTruthy(res);
    }

    private static LuaValue invokeBinMeta(LuaState state, LuaValue a, LuaValue b, string event) {
        auto firstMeta = state.getMetatable(a);
        if (firstMeta !is null) {
            auto meta = firstMeta.rawget(LuaValue(event));
            if (!isNil(meta)) {
                auto res = callValue(state, meta, [a, b], false, event[2 .. $], "metamethod", false, true);
                if (state.raisedError !is null)
                    return luaNil();
                return res.length > 0 ? res[0] : luaNil();
            }
        }
        auto secondMeta = state.getMetatable(b);
        if (secondMeta !is null) {
            auto meta = secondMeta.rawget(LuaValue(event));
            if (!isNil(meta)) {
                auto res = callValue(state, meta, [a, b], false, event[2 .. $], "metamethod", false, true);
                if (state.raisedError !is null)
                    return luaNil();
                return res.length > 0 ? res[0] : luaNil();
            }
        }
        return failValue(state, binaryOperandError(state, a, b, event));
    }

    /// Builds the C-Lua-equivalent error for a binary operation without a usable metamethod.
    private static LuaException binaryOperandError(LuaState state, LuaValue a, LuaValue b, string event) {
        LuaException failure;
        if (event == "__lt" || event == "__le") {
            auto t1 = objectTypeName(state, a), t2 = objectTypeName(state, b);
            return new LuaException(t1 == t2 ? format("attempt to compare two %s values", t1) : format(
                    "attempt to compare %s with %s", t1, t2));
        }
        if (event == "__concat") {
            bool firstOk = isString(a) || isNumber(a);
            failure = new LuaException("attempt to concatenate a " ~ objectTypeName(state, firstOk ? b : a) ~ " value");
            failure.culprit = firstOk ? 2 : 1;
            return failure;
        }
        if (event == "__band" || event == "__bor" || event == "__bxor" || event == "__shl" || event == "__shr") {
            if (isString(a) || isString(b) || !(isNumber(a) && isNumber(b))) {
                bool first = !isNumber(a);
                failure = new LuaException("attempt to perform bitwise operation on a " ~ objectTypeName(state, first ? a : b) ~ " value");
                failure.culprit = first ? 1 : 2;
                return failure;
            }
            long ignored;
            bool first = !bitwiseInteger(a, ignored);
            failure = new LuaException("number%s has no integer representation");
            failure.culprit = first ? 1 : 2;
            return failure;
        }
        // Arithmetic. Strings carry arithmetic metamethods in C Lua (lstrlib.c trymt).
        if (isString(a) || isString(b)) {
            if (isString(b) || isNil(metaField(state, b, event)))
                return new LuaException(format("attempt to %s a '%s' with a '%s'", event[2 .. $], objectTypeName(state, a), objectTypeName(
                        state, b)));
        }
        bool first = !isNumber(a);
        failure = new LuaException("attempt to perform arithmetic on a " ~ objectTypeName(state, first ? a : b) ~ " value");
        failure.culprit = first ? 1 : 2;
        return failure;
    }

    private static LuaValue metaField(LuaState state, LuaValue v, string event) {
        auto mt = state.getMetatable(v);
        return mt is null ? luaNil() : mt.rawget(LuaValue(event));
    }

    /// luaT_objtypename: honors a string __name in the metatable of tables and userdata.
    static string objectTypeName(LuaState state, LuaValue v) {
        if (isTable(v) || v.typeOf() == LuaType.UserData) {
            auto mt = state.getMetatable(v);
            if (mt !is null) {
                auto name = mt.rawget(LuaValue("__name"));
                if (isString(name))
                    return toLuaString(name);
            }
        }
        return typeName(v);
    }

    private static string forError(LuaState state, LuaValue v, string what) {
        return "bad 'for' " ~ what ~ " (number expected, got " ~ objectTypeName(state, v) ~ ")";
    }

    /// Prepares a numeric for loop (lvm.c forprep). Returns 1 to skip the loop, 0 to run it, -1 after
    /// leaving the error in `state.raisedError`.
    private static int forPrepare(LuaState state, LuaValue[] r, int a) {
        if (isInteger(r[a]) && isInteger(r[a + 2])) {
            long init = r[a].match!((long i) => i, _ => 0L);
            long step = r[a + 2].match!((long i) => i, _ => 0L);
            if (step == 0)
                return failFor(state, "'for' step is zero");
            r[a + 3] = luaValue(init);
            long limit;
            LuaValue lim = r[a + 1];
            if (isString(lim)) {
                LuaValue n;
                if (toCoercedNumber(lim, n))
                    lim = n;
            }
            if (isInteger(lim))
                limit = lim.match!((long i) => i, _ => 0L);
            else if (isFloat(lim)) {
                double f = lim.match!((double d) => d, _ => 0.0);
                if (isNaN(f))
                    return 1;
                double fl = step < 0 ? ceil(f) : floor(f);
                if (fl >= -9223372036854775808.0 && fl < 9223372036854775808.0)
                    limit = cast(long) fl;
                else if (f > 0) {
                    if (step < 0)
                        return 1;
                    limit = long.max;
                } else {
                    if (step > 0)
                        return 1;
                    limit = long.min;
                }
            } else
                return failFor(state, forError(state, lim, "limit"));
            if (step > 0 ? init > limit : init < limit)
                return 1;
            ulong count;
            if (step > 0) {
                count = cast(ulong) limit - cast(ulong) init;
                if (step != 1)
                    count /= cast(ulong) step;
            } else {
                count = cast(ulong) init - cast(ulong) limit;
                count /= cast(ulong)(-(step + 1)) + 1UL;
            }
            r[a + 1] = luaValue(cast(long) count);
            return 0;
        }
        LuaValue init, limit, step;
        if (!toCoercedNumber(r[a + 1], limit))
            return failFor(state, forError(state, r[a + 1], "limit"));
        if (!toCoercedNumber(r[a + 2], step))
            return failFor(state, forError(state, r[a + 2], "step"));
        if (!toCoercedNumber(r[a], init))
            return failFor(state, forError(state, r[a], "initial value"));
        double fi = toDoubleVal(init), fl = toDoubleVal(limit), fs = toDoubleVal(step);
        if (fs == 0)
            return failFor(state, "'for' step is zero");
        if (fs > 0 ? fl < fi : fi < fl)
            return 1;
        r[a] = luaValue(fi);
        r[a + 1] = luaValue(fl);
        r[a + 2] = luaValue(fs);
        r[a + 3] = luaValue(fi);
        return 0;
    }

    private static int failFor(LuaState state, string message) {
        state.raisedError = new LuaException(message);
        return -1;
    }

    /// Steps a prepared numeric for loop. Returns true to continue looping.
    private static bool forStep(LuaValue[] r, int a) {
        if (isInteger(r[a + 2])) {
            ulong count = cast(ulong) r[a + 1].match!((long i) => i, _ => 0L);
            if (count > 0) {
                long step = r[a + 2].match!((long i) => i, _ => 0L);
                long idx = r[a].match!((long i) => i, _ => 0L) + step;
                auto remaining = luaValue(cast(long)(count - 1));
                auto index = luaValue(idx);
                copyValue(r[a + 1], remaining);
                copyValue(r[a], index);
                copyValue(r[a + 3], index);
                return true;
            }
            return false;
        }
        double step = r[a + 2].match!((double d) => d, _ => 0.0);
        double limit = r[a + 1].match!((double d) => d, _ => 0.0);
        double idx = r[a].match!((double d) => d, _ => 0.0) + step;
        if (step > 0 ? idx <= limit : limit <= idx) {
            auto index = luaValue(idx);
            copyValue(r[a], index);
            copyValue(r[a + 3], index);
            return true;
        }
        return false;
    }

    private static LuaValue invokeUnaryMeta(LuaState state, LuaValue a, string event) {
        auto metatable = state.getMetatable(a);
        if (metatable !is null) {
            auto meta = metatable.rawget(LuaValue(event));
            if (!isNil(meta)) {
                auto result = callValue(state, meta, [a, a], false, event[2 .. $], "metamethod", false, true);
                if (state.raisedError !is null)
                    return luaNil();
                return result.length ? result[0] : luaNil();
            }
        }
        LuaException failure;
        if (event == "__bnot") {
            if (isNumber(a))
                failure = new LuaException("number%s has no integer representation");
            else
                failure = new LuaException("attempt to perform bitwise operation on a " ~ objectTypeName(state, a) ~ " value");
        } else if (event == "__len") {
            failure = new LuaException("attempt to get length of a " ~ objectTypeName(state, a) ~ " value");
        } else if (isString(a)) {
            return failValue(state, new LuaException("attempt to unm a 'string' with a 'string'"));
        } else {
            failure = new LuaException("attempt to perform arithmetic on a " ~ objectTypeName(state, a) ~ " value");
        }
        failure.culprit = 1;
        return failValue(state, failure);
    }

    /// The operators report an error as a value: nil (or false) with the error in
    /// `state.raisedError`. Callers check the slot after an operation that can fail.
    private static LuaValue failValue(LuaState state, LuaException failure) {
        state.raisedError = failure;
        return luaNil();
    }

    private static double toDoubleVal(LuaValue v) {
        return v.match!(
                (long i) => cast(double) i,
                (double d) => d,
                _ => 0.0
        );
    }

    private static long toIntegerVal(LuaValue v) {
        return v.match!(
                (long i) => i,
                (double d) => cast(long) d,
                _ => 0L
        );
    }
}
