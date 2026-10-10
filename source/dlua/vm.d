/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.vm;

import dlua.types;
import dlua.table;
import dlua.opcode;
import dlua.state;
import dlua.exception : LuaException, ExitRequest;
import dlua.lib.auxlib : ArgError;
import dlua.fiber : DluaFiber, CoroutineClose;
import core.thread : Fiber;
import dlua.logic.model;
import dlua.logic.world;
import dlua.logic.validate;
import dlua.logic.query;
import dlua.narrative.registry : ContentRegistry, ContentDefinition, DeckDefinition;
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

    this(LuaValue* ptr, int stackIndex) {
        this.valPtr = ptr;
        this.stackIndex = stackIndex;
        this.isClosed = false;
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

    this(Prototype proto, UpValue[] upvalues = null) {
        super(proto.functionName);
        this.proto = proto;
        this.upvalues = upvalues;
    }

    override LuaValue[] call(void* statePtr, LuaValue[] args) {
        auto state = cast(LuaState)statePtr;
        return VM.execute(state, this, args);
    }
}

enum size_t luaMaxStack = 1_000_000;

/// Set asynchronously (SIGINT handler) to stop the running Lua code with "interrupted!".
__gshared bool vmInterrupt;

/// Bytecode Virtual Machine Dispatcher
struct VM {
    private struct TailRequest {
        bool pending;
        LuaValue callee;
        LuaValue[] arguments;
        World world;
    }

    static LuaValue[] execute(LuaState state, LuaClosure closure, LuaValue[] args, string name = "", string nameKind = "") {
        import core.thread : Fiber;
        auto previous = state.callWorld;
        scope(exit) state.callWorld = previous;
        bool transferred;
        while (true) {
            TailRequest tail;
            auto results = executeFrame(state, closure, args, tail, transferred, name, nameKind);
            if (!tail.pending) return results;
            state.callWorld = tail.world;
            auto callee = tail.callee;
            args = tail.arguments;
            resolveCallable(state, callee, args);
            auto function_ = callee.match!((LuaFunction fn) => fn, _ => null);
            closure = cast(LuaClosure)function_;
            if (closure is null) return callValue(state, callee, args, true);
            transferred = true; name = ""; nameKind = "";
        }
    }

    private static LuaValue[] executeFrame(LuaState state, LuaClosure closure,
        LuaValue[] args, out TailRequest tail, bool transferred, string entryName, string entryKind) {
        import core.thread : Fiber;
        auto proto = closure.proto;
        // Emulate Lua's stack limits: 1,000,000 slots ("stack overflow"; the extra 200 are
        // reserved for error handling) plus a native guard for the real D stack.
        auto frameThread = state.currentThread();
        size_t nativeMarker;
        size_t sp = cast(size_t)&nativeMarker;
        size_t frameSlots = cast(size_t)proto.maxStackSize + 1;
        frameThread.stackSlots += frameSlots;
        scope(exit) {
            frameThread.stackSlots -= frameSlots;
            if (frameThread.stackSlots + 400 <= luaMaxStack && sp > frameThread.nativeSoftLimit + 256 * 1024)
                frameThread.overflowed = false;
        }
        bool nativeSoft = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeSoftLimit;
        bool nativeHard = frameThread.nativeStackLimit != 0 && sp < frameThread.nativeStackLimit;
        if (nativeHard || frameThread.stackSlots > luaMaxStack + 200) {
            auto nested = new LuaException("error in error handling");
            nested.needsLocation = false;
            throw nested;
        }
        if ((nativeSoft || frameThread.stackSlots > luaMaxStack) && !frameThread.overflowed) {
            frameThread.overflowed = true;
            throw new LuaException("stack overflow");
        }
        size_t stackSize = max(cast(size_t)proto.maxStackSize + 8, 32);
        LuaValue[] registers = new LuaValue[stackSize];

        // LuaValue.init is nil; new already initializes every register.

        // Pass parameters into registers R[0 .. numParams-1]
        for (int i = 0; i < proto.numParams; ++i) {
            if (i < args.length) {
                registers[i] = args[i];
            }
        }

        // Varargs
        LuaValue[] varargs;
        if (proto.isVararg && args.length > cast(size_t)proto.numParams) {
            varargs = args[cast(size_t)proto.numParams .. $].dup;
        }

        // Open upvalues tracked in this frame
        UpValue[] openUpvalues;

        void growRegisters(size_t length) {
            registers.length = length;
            foreach (up; openUpvalues) if (!up.isClosed) up.valPtr = &registers[up.stackIndex];
        }

        UpValue findOrCreateUpvalue(int regIdx) {
            foreach (up; openUpvalues) {
                if (!up.isClosed && up.stackIndex == regIdx) {
                    return up;
                }
            }
            auto newUp = new UpValue(&registers[regIdx], regIdx);
            openUpvalues ~= newUp;
            return newUp;
        }

        void closeUpvaluesFrom(int regIdx) {
            foreach (up; openUpvalues) {
                if (!up.isClosed && up.stackIndex >= regIdx) {
                    up.close();
                }
            }
        }

        int[] toClose;
        void closeValuesFrom(int first, LuaValue error = LuaValue.init) {
            auto thread = state.currentThread();
            if (thread !is null) thread.closeDepth++;
            scope(exit) if (thread !is null) thread.closeDepth--;
            LuaException closeError;
            while (toClose.length && toClose[$ - 1] >= first) {
                int slot = toClose[$ - 1];
                toClose.length--;
                auto value = registers[slot];
                auto metatable = state.getMetatable(value);
                auto method = metatable is null ? luaNil() : metatable.rawget(LuaValue("__close"));
                try { callValue(state, method, [value, error], false, "close", "metamethod"); }
                catch (LuaException failure) {
                    closeError = failure;
                    error = failure.errorObject;
                }
            }
            closeUpvaluesFrom(first);
            if (closeError !is null) throw closeError;
        }

        bool callVisible = state !is null;
        if (state !is null) {
            int initLine = proto.code.length == 0 ? 1 : proto.code[0].line > 0 ? proto.code[0].line : -1;
            state.pushCall(closure, proto.sourceName, initLine, transferred, entryName, entryKind);
        }

        struct FrameTransaction {
            Transaction transaction;
            int startPC;
            int endPC;
            int firstRegister;
        }
        FrameTransaction[] frameTransactions;
        bool transactionError;
        scope(exit) {
            while (frameTransactions.length) {
                frameTransactions[$ - 1].transaction.finish(!transactionError);
                frameTransactions.length--;
            }
        }
        scope(failure) transactionError = true;

        scope(exit) {
            closeUpvaluesFrom(0);
            if (callVisible) state.popCall();
        }

        int pc = 0;
        int top = cast(int)proto.maxStackSize;
        int codeLen = cast(int)proto.code.length;
        int debugLimit = proto.maxStackSize;
        string localSlot(long index, out int slot, out bool vararg) {
            if (index < 0) {
                if (!proto.isVararg || index < -cast(long)varargs.length) return null;
                slot = cast(int)(-index - 1); vararg = true;
                return "(vararg)";
            }
            if (index == 0) return null;
            long remaining = index;
            foreach (local; proto.debugLocals) {
                if (local.startPC <= max(pc - 1, 0) && max(pc - 1, 0) < local.endPC && (local.name.length == 0 || local.name[0] != '@')) {
                    if (--remaining == 0) { slot = local.register; return local.name; }
                }
            }
            if (index <= debugLimit) {
                slot = cast(int)index - 1;
                foreach (local; proto.debugLocals) if (local.register == slot && local.name.length && local.name[0] == '@' &&
                    local.startPC <= max(pc - 1, 0) && max(pc - 1, 0) < local.endPC) return null;
                return "(temporary)";
            }
            return null;
        }
        state.callStack[$ - 1].getLocal = (long index, out LuaValue value) {
            int slot; bool vararg;
            auto name = localSlot(index, slot, vararg);
            if (name !is null) value = vararg ? varargs[slot] : registers[slot];
            return name;
        };
        state.callStack[$ - 1].setLocal = (long index, LuaValue value) {
            int slot; bool vararg;
            auto name = localSlot(index, slot, vararg);
            if (name !is null) {
                foreach (local; proto.debugLocals) if (!vararg && local.register == slot && local.readOnly &&
                    local.startPC <= max(pc - 1, 0) && max(pc - 1, 0) < local.endPC)
                    throw new LuaException("attempt to modify read-only narrative parameter '" ~ local.name ~ "'");
                if (vararg) varargs[slot] = value; else registers[slot] = value;
            }
            return name;
        };
        state.callStack[$ - 1].clearDead = () {
            int limit = pc > 0 && pc <= proto.liveTop.length ? proto.liveTop[pc - 1] : int.max;
            if (limit == int.max) return;
            foreach (i; limit .. registers.length) registers[i] = luaNil();
        };
        int lastHookPC = -1;
        int lastHookLine = -1;

        try {
            state.debugHook(transferred ? "tail call" : "call", -1, registers[0 .. proto.numParams], true);
            while (pc < codeLen) {
            if (state.analysisBudget !is null) {
                if (!state.analysisBudget.remaining) throw new LuaException("ANALYSIS_STEP_LIMIT: VM instruction budget exhausted");
                state.analysisBudget.remaining--;
            }
            while (frameTransactions.length && (pc < frameTransactions[$ - 1].startPC || pc >= frameTransactions[$ - 1].endPC)) {
                closeValuesFrom(frameTransactions[$ - 1].firstRegister);
                frameTransactions[$ - 1].transaction.finish(true);
                frameTransactions.length--;
            }
            auto instr = proto.code[pc++];
            if (state.pendingCollect) {
                // collectgarbage requested a collection: run it here, where the native stack is
                // shallow, so stale words in dead frames cannot keep objects alive.
                state.pendingCollect = false;
                import dlua.gc : runGcCycle;
                runGcCycle(state, true);
            }
            if (vmInterrupt) {
                vmInterrupt = false;
                throw new LuaException("interrupted!");
            }
            if (instr.line > 0 && state !is null && state.callStack.length > 0) {
                state.callStack[$ - 1].currentLine = instr.line;
            }
            auto thread = state.currentThread();
            if (thread !is null && !thread.hookActive) {
                if ((thread.hookMask & 8) && --thread.hookRemaining == 0) {
                    thread.hookRemaining = thread.hookCount;
                    state.debugHook("count");
                }
                if (instr.line > 0 ? (pc - 1 <= lastHookPC || instr.line != lastHookLine) : (lastHookPC < 0 || pc - 1 <= lastHookPC))
                    state.debugHook("line", instr.line > 0 ? instr.line : -1);
                lastHookPC = pc - 1; lastHookLine = instr.line;
            }
            auto op = instr.op;
            int a = instr.a;
            int b = instr.b;
            int c = instr.c;
            int sBx = instr.sBx;

            switch (op) {
                case OpCode.Nop:
                    break;

                case OpCode.Move:
                    copyValue(registers[a], registers[b]);
                    break;

                case OpCode.LoadNil:
                    for (int i = a; i <= a + b; ++i) {
                        registers[i] = luaNil();
                    }
                    break;

                case OpCode.LoadBool:
                    registers[a] = luaValue(b != 0);
                    if (c != 0) pc++;
                    break;

                case OpCode.LoadInt:
                    registers[a] = luaValue(cast(long)instr.sBx);
                    break;

                case OpCode.LoadK:
                    copyValue(registers[a], proto.constants[b]);
                    break;

                case OpCode.GetGlobal:
                    execGetGlobal(state, closure, proto, registers, instr);
                    break;

                case OpCode.SetGlobal:
                    execSetGlobal(state, closure, proto, registers, instr);
                    break;

                case OpCode.GetUpval:
                    if (b < closure.upvalues.length) {
                        registers[a] = closure.upvalues[b].get();
                    }
                    break;

                case OpCode.SetUpval:
                    if (b < closure.upvalues.length) {
                        closure.upvalues[b].set(registers[a]);
                    }
                    break;

                case OpCode.NewTable:
                    registers[a] = luaNil();  // the old value is dead; do not keep it across a collection
                    state.allocationTick();
                    newTableInto(registers[a]);
                    break;

                case OpCode.GetTable:
                    execGetTable(state, proto, registers, instr);
                    break;

                case OpCode.SetTable:
                    execSetTable(state, proto, registers, instr);
                    break;

                case OpCode.SetList:
                    execSetList(registers, a, b, c, top);
                    break;

                case OpCode.Self:
                    execSelf(state, proto, registers, instr);
                    break;

                // Arithmetic, bitwise and concatenation operations
                case OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv, OpCode.Mod, OpCode.Pow,
                     OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr:
                    execArith(state, proto, registers, instr);
                    break;
                case OpCode.Concat:
                    if ((instr.bIsK || a != b) && (instr.cIsK || a != c)) registers[a] = luaNil();
                    state.allocationTick();
                    execArith(state, proto, registers, instr);
                    break;

                // Unary operations
                case OpCode.Unm, OpCode.Not, OpCode.Len, OpCode.BNot:
                    execUnary(state, registers, instr);
                    break;

                // Jumps & Comparisons
                case OpCode.Jmp:
                    pc += instr.sBx;
                    break;

                case OpCode.Eq, OpCode.Lt, OpCode.Le:
                    if (execCompare(state, proto, registers, instr) != (c != 0)) pc++;
                    break;

                case OpCode.Test:
                    if (isTruthy(registers[a]) == (c != 0)) {
                        pc += instr.sBx;
                    }
                    break;

                case OpCode.TestSet:
                    if (isTruthy(registers[b]) == (c != 0)) {
                        registers[a] = registers[b];
                        pc += instr.sBx;
                    }
                    break;

                // Calls and Returns
                case OpCode.TailCall:
                    checkCallable(state, registers[a]);
                    if (isNativeFunction(registers[a])) {
                        // A C function is called in place, as a regular call (lua 5.4 precallC):
                        // its errors are attributed to this frame and call site.
                        int nativeArgs = b == 0 ? top - a - 1 : b - 1;
                        debugLimit = a;
                        auto nativeResults = doCall(state, closure, proto, registers, a, nativeArgs, pc - 1);
                        debugLimit = proto.maxStackSize;
                        closeValuesFrom(0);
                        state.debugHook("return", -1, nativeResults, true);
                        return nativeResults;
                    }
                    int count = b == 0 ? top - a - 1 : b - 1;
                    int context = proto.callWorlds.get(pc - 1, 0);
                    tail.world = context > 0 ? unwrapWorld(registers[context - 1]) :
                        context < 0 ? unwrapWorld(closure.upvalues[-context - 1].get()) : state.globalWorld;
                    tail.callee = registers[a];
                    tail.arguments = count > 0 ? registers[a + 1 .. a + 1 + count].dup : [];
                    closeValuesFrom(0);
                    tail.pending = true;
                    return [];

                case OpCode.Call:
                    int numArgs = (b == 0) ? cast(int)(top - (a + 1)) : (b - 1);
                    int numWantedResults = c - 1;
                    if (numWantedResults >= 0 && a + numWantedResults >= registers.length) growRegisters(a + numWantedResults + 8);

                    debugLimit = a;
                    // The call and the placement of its results happen in one frame of their own so
                    // that no array holding result values stays referenced from this frame.
                    int resultTop = callAndPlace(state, closure, proto, registers, a, numArgs, numWantedResults, pc - 1);
                    debugLimit = proto.maxStackSize;
                    if (resultTop < 0) {
                        // Variable results did not fit: grow, then copy the stashed values.
                        growRegisters(a + (-resultTop) + 8);
                        resultTop = placeStashedResults(state, registers, a);
                    }
                    top = resultTop;
                    break;

                case OpCode.Return:
                    int numRet = b - 1;
                    LuaValue[] returned;
                    if (numRet < 0) {
                        int endReg = (top > a) ? top : a;
                        if (endReg > registers.length) endReg = cast(int)registers.length;
                        returned = (endReg > a) ? registers[a .. endReg].dup : [];
                    } else if (numRet == 0) {
                        returned = [];
                    } else {
                        returned = registers[a .. a + numRet].dup;
                    }
                    closeValuesFrom(0);
                    state.debugHook("return", -1, returned, true);
                    return returned;

                // Numeric For
                case OpCode.ForPrep:
                    if (forPrepare(state, registers, a)) pc += instr.sBx;
                    break;

                case OpCode.ForLoop:
                    if (forStep(registers, a)) pc += instr.sBx;
                    break;

                // Generic For
                case OpCode.TForCall:
                    execTForCall(state, registers, a, c);
                    break;

                case OpCode.TForLoop:
                    if (!isNil(registers[a + 2])) {
                        copyValue(registers[a], registers[a + 2]);
                        pc += instr.sBx;
                    }
                    break;

                // Closures and Upvalues
                case OpCode.Closure:
                    registers[a] = luaNil();
                    state.allocationTick();
                    execClosure(closure, proto, registers, a, b, &findOrCreateUpvalue);
                    break;

                case OpCode.Vararg:
                    int numWanted = b - 1;
                    if (numWanted >= 0) {
                        for (int i = 0; i < numWanted; ++i) {
                            if (a + i >= registers.length) growRegisters(a + i + 8);
                            registers[a + i] = (i < varargs.length) ? varargs[i] : luaNil();
                        }
                        top = a + numWanted;
                    } else {
                        if (a + varargs.length >= registers.length) {
                            growRegisters(a + varargs.length + 8);
                        }
                        for (size_t i = 0; i < varargs.length; ++i) {
                            registers[a + i] = varargs[i];
                        }
                        top = a + cast(int)varargs.length;
                    }
                    break;

                case OpCode.Close:
                    closeValuesFrom(a);
                    break;

                case OpCode.ToClose:
                    if (isNil(registers[a]) || (registers[a].typeOf() == LuaType.Boolean && !isTruthy(registers[a]))) break;
                    auto closeMetatable = state.getMetatable(registers[a]);
                    if (closeMetatable is null || isNil(closeMetatable.rawget(LuaValue("__close")))) {
                        string variable = "?";
                        foreach (local; proto.debugLocals) if (local.register == a && local.startPC <= pc - 1 && pc - 1 < local.endPC) variable = local.name;
                        throw new LuaException("variable '" ~ variable ~ "' got a non-closable value");
                    }
                    toClose ~= a;
                    break;

                case OpCode.BeginTransaction:
                    World transactionWorld = a < 0 ? state.globalWorld : unwrapWorld(registers[a]);
                    frameTransactions ~= FrameTransaction(new Transaction(transactionWorld), pc, b, c);
                    break;
                case OpCode.EndTransaction:
                    frameTransactions[$ - 1].transaction.finish(true);
                    frameTransactions.length--;
                    break;
                case OpCode.Rollback:
                    if (!frameTransactions.length) throw new LuaException("rollback outside a transaction");
                    auto rolledBack = frameTransactions[$ - 1];
                    closeValuesFrom(rolledBack.firstRegister);
                    rolledBack.transaction.finish(false);
                    pc = rolledBack.endPC;
                    frameTransactions.length--;
                    break;

                case OpCode.DefineContent, OpCode.DefineDeck, OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.DeclRel,
                     OpCode.SetFact, OpCode.DeleteKey, OpCode.AdjustKey, OpCode.AddFact, OpCode.RetractFact,
                     OpCode.RegRule, OpCode.MakeQuery:
                    declarativeOp(state, closure, proto, registers, &findOrCreateUpvalue, instr);
                    break;

                default:
                    throw new LuaException(format("unknown opcode: %s", op));
            }
        }
        } catch (CoroutineClose signal) {
            transactionError = true;
            if (callVisible) { state.popCall(); callVisible = false; }
            try { closeValuesFrom(0, signal.errorObject); }
            catch (LuaException failure) { signal.errorObject = failure.errorObject; signal.failed = true; }
            throw signal;
        } catch (LuaException e) {
            transactionError = true;
            if (e.culprit > 0 && pc > 0 && pc <= codeLen) applyVariableInfo(e, proto, pc - 1);
            if (auto argFailure = cast(ArgError)e) {
                if (!argFailure.formatted && pc > 0 && pc <= codeLen) {
                    auto site = proto.code[pc - 1];
                    string calledName, calledKind;
                    if (site.op == OpCode.Call || site.op == OpCode.TailCall) calledKind = objectName(proto, pc - 1, site.a, calledName);
                    formatArgError(state, argFailure, argFailure.function_, calledName, calledKind);
                }
            }
            if (pc > 0 && pc <= codeLen) e.locateLua(proto.sourceName, proto.code[pc - 1].line);
            state.dispatchError(e);
            auto fiber = cast(DluaFiber)Fiber.getThis();
            if (fiber !is null && !fiber.closing && !fiber.protectedDepth &&
                !isNoYieldScope() && !isReadOnlyEvaluation() && !isNotificationDispatch()) {
                bool pushedOrigin = e.originFunction !is null;
                if (pushedOrigin) state.pushCall(e.originFunction, "[C]", -1, false, e.originName, e.originKind);
                fiber.suspendError(e.errorObject);
                if (pushedOrigin) state.popCall();
                if (callVisible) { state.popCall(); callVisible = false; }
                auto signal = new CoroutineClose(e.errorObject, true);
                try { closeValuesFrom(0, signal.errorObject); }
                catch (LuaException failure) { signal.errorObject = failure.errorObject; }
                throw signal;
            }
            if (callVisible) { state.popCall(); callVisible = false; }
            closeValuesFrom(0, e.errorObject);
            throw e;
        } catch (ExitRequest request) {
            if (callVisible) { state.popCall(); callVisible = false; }
            closeValuesFrom(0);
            throw request;
        } catch (Exception e) {
            transactionError = true;
            closeValuesFrom(0, LuaValue(e.msg));
            throw e;
        }

        closeValuesFrom(0);
        state.debugHook("return");
        return [];
    }

    private static LuaValue captureClosedValue(Prototype proto, LuaClosure closure, scope UpValue delegate(int) findUp, int index) {
            auto subProto = proto.subPrototypes[index];
            UpValue[] captured;
            foreach (desc; subProto.upvalues) {
                auto original = desc.inStack ? findUp(desc.index) : closure.upvalues[desc.index];
                auto copy = new UpValue(null, -1);
                copy.closedVal = original.get(); copy.isClosed = true;
                captured ~= copy;
            }
            return luaValue(new LuaClosure(subProto, captured));
        }

    private static Goal[] instantiateGoalsStatic(LuaState state, Prototype proto, LuaClosure closure, LuaValue[] registers, scope UpValue delegate(int) findUp, GoalTemplate[] templates, RuleRegistration registration, ref Relation[size_t] closureRels) {
            Goal[] goals;
                    foreach (gt; templates) {
                        if (gt.kind == GoalKind.Aggregate) {
                            auto goal = new Goal(GoalKind.Aggregate);
                            goal.aggregateOp = gt.aggregateOp;
                            goal.resultVariable = gt.resultVariable;
                            goal.aggregateGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, gt.aggregateGoals, registration, closureRels);
                            goal.aggregateExpressionVariables = gt.aggregateExpressionVariables.dup;
                            if (gt.aggregateExpressionProto >= 0) goal.aggregateExpression = captureClosedValue(proto, closure, findUp, gt.aggregateExpressionProto);
                            goals ~= goal;
                        } else if (gt.kind == GoalKind.PositiveAtom || gt.kind == GoalKind.NegatedAtom) {
                            Term[] terms;
                            foreach (tt; gt.terms) {
                                if (tt.kind == TermKind.Variable) {
                                    terms ~= Term.makeVariable(tt.varName, tt.varId);
                                } else if (tt.kind == TermKind.Constant) {
                                    auto val = registers[tt.reg];
                                    if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                                        throw new LuaException("NaN is prohibited as a relational constant");
                                    }
                                    terms ~= Term.makeConstant(val);
                                } else {
                                    terms ~= Term.makeAnonymous();
                                }
                            }
                            RelationRef gRef;
                            if (gt.localRelReg >= 0) {
                                auto lr = unwrapLocalRelation(registers[gt.localRelReg]);
                                if (lr is null) throw new LuaException("expected local relation");
                                if (lr.arity != terms.length) {
                                    throw new LuaException(format("relation '%s' expects arity %d, got %d", lr.name, lr.arity, terms.length));
                                }
                                gRef = new RelationRef(lr.name, lr.arity, "", lr.id, true);
                                closureRels[lr.id] = lr.relation;
                                gRef.resolvedRelation = lr.relation;
                            } else {
                                World gw = (gt.worldReg == -1) ? state.globalWorld : unwrapWorld(registers[gt.worldReg]);
                                auto rel = registration !is null ? registration.resolve(gw, gt.relName, gt.arity) : gw.getRelation(gt.relName);
                                if (rel is null) {
                                    throw new LuaException(format("query references unknown relation '%s'", gt.relName));
                                }
                                if (rel.arity != terms.length) {
                                    throw new LuaException(format("relation '%s' expects arity %d, got %d", rel.name, rel.arity, terms.length));
                                }
                                gRef = new RelationRef(rel.name, rel.arity, gw.id.to!string, rel.id, false);
                                closureRels[rel.id] = rel;
                                gRef.resolvedRelation = rel;
                            }
                            goals ~= (gt.kind == GoalKind.PositiveAtom)
                                ? Goal.makePositiveAtom(gRef, terms)
                                : Goal.makeNegatedAtom(gRef, terms);
                        } else if (gt.kind == GoalKind.Comparison) {
                            Term lTerm = (gt.leftTerm.kind == TermKind.Variable)
                                ? Term.makeVariable(gt.leftTerm.varName, gt.leftTerm.varId)
                                : Term.makeConstant(registers[gt.leftTerm.reg]);
                            Term rTerm = (gt.rightTerm.kind == TermKind.Variable)
                                ? Term.makeVariable(gt.rightTerm.varName, gt.rightTerm.varId)
                                : Term.makeConstant(registers[gt.rightTerm.reg]);
                            goals ~= Goal.makeComparison(lTerm, gt.compOp, rTerm);
                        } else if (gt.kind == GoalKind.Guard) {
                            auto guardValue = captureClosedValue(proto, closure, findUp, gt.guardSubProtoIdx);
                            goals ~= Goal.makeGuard(guardValue, gt.guardVarNames.dup, gt.guardVarIds.dup);
                        }
                    }

            return goals;
        }


    // Instruction handlers live in frames of their own: the collector scans the interpreter
    // loop's stack conservatively, and Lua values copied into its locals would be kept alive.

    pragma(inline, false)
    private static void execGetGlobal(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto name = proto.constants[instr.b].match!((string s) => s, _ => toLuaString(proto.constants[instr.b]));
        int c = instr.c;
        auto environment = c > 0 ? registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].get() : LuaValue(state.globals);
        registers[instr.a] = getTable(state, environment, LuaValue(name));
    }

    pragma(inline, false)
    private static void execSetGlobal(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto name = proto.constants[instr.b].match!((string s) => s, _ => toLuaString(proto.constants[instr.b]));
        int c = instr.c;
        auto environment = c > 0 ? registers[c - 1] : c < 0 ? closure.upvalues[-c - 1].get() : LuaValue(state.globals);
        setTable(state, environment, LuaValue(name), instr.aIsK ? proto.constants[instr.a] : registers[instr.a]);
    }

    pragma(inline, false)
    private static void execGetTable(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto keyVal = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        registers[instr.a] = getTable(state, registers[instr.b], keyVal);
    }

    pragma(inline, false)
    private static void execSetTable(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto keyVal = instr.bIsK ? proto.constants[instr.b] : registers[instr.b];
        auto valVal = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        setTable(state, registers[instr.a], keyVal, valVal);
    }

    pragma(inline, false)
    private static void execSetList(LuaValue[] registers, int a, int b, int c, int top) {
        if (!isTable(registers[a])) return;
        auto tbl = registers[a].match!((LuaTable t) => t, _ => null);
        int rStart = b;
        long listIdx = c;
        int endReg = (top > rStart) ? top : rStart;
        if (endReg > rStart && listIdx >= 1 && cast(size_t)(listIdx - 1) <= tbl.arrayPart.length)
            tbl.ensureArray(cast(size_t)(listIdx - 1 + endReg - rStart));
        for (int k = rStart; k < endReg; ++k) {
            tbl.rawset(LuaValue(listIdx++), registers[k]);
        }
    }

    pragma(inline, false)
    private static void execSelf(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        registers[instr.a + 1] = registers[instr.b];
        auto keyVal = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        registers[instr.a] = getTable(state, registers[instr.b], keyVal);
    }

    pragma(inline, false)
    private static void execArith(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto left = instr.bIsK ? proto.constants[instr.b] : registers[instr.b];
        auto right = instr.cIsK ? proto.constants[instr.c] : registers[instr.c];
        LuaValue result;
        final switch (instr.op) {
            case OpCode.Add: result = opAdd(state, left, right); break;
            case OpCode.Sub: result = opSub(state, left, right); break;
            case OpCode.Mul: result = opMul(state, left, right); break;
            case OpCode.Div: result = opDiv(state, left, right); break;
            case OpCode.IDiv: result = opIDiv(state, left, right); break;
            case OpCode.Mod: result = opMod(state, left, right); break;
            case OpCode.Pow: result = opPow(state, left, right); break;
            case OpCode.BAnd: result = opBAnd(state, left, right); break;
            case OpCode.BOr: result = opBOr(state, left, right); break;
            case OpCode.BXor: result = opBXor(state, left, right); break;
            case OpCode.Shl: result = opShl(state, left, right); break;
            case OpCode.Shr: result = opShr(state, left, right); break;
            case OpCode.Concat: result = opConcat(state, left, right); break;
            case OpCode.Nop, OpCode.Move, OpCode.LoadNil, OpCode.LoadBool, OpCode.LoadInt, OpCode.LoadK,
                 OpCode.GetGlobal, OpCode.SetGlobal, OpCode.GetUpval, OpCode.SetUpval, OpCode.GetTable,
                 OpCode.SetTable, OpCode.NewTable, OpCode.SetList, OpCode.Self, OpCode.Unm, OpCode.Not,
                 OpCode.Len, OpCode.BNot, OpCode.Jmp, OpCode.Eq, OpCode.Lt, OpCode.Le, OpCode.Test,
                 OpCode.TestSet, OpCode.Call, OpCode.TailCall, OpCode.Return, OpCode.ForPrep, OpCode.ForLoop,
                 OpCode.TForCall, OpCode.TForLoop, OpCode.Closure, OpCode.Vararg, OpCode.Close, OpCode.ToClose,
                 OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.DeclRel, OpCode.AddFact, OpCode.RetractFact,
                 OpCode.SetFact, OpCode.DeleteKey, OpCode.AdjustKey, OpCode.BeginTransaction,
                 OpCode.EndTransaction, OpCode.Rollback, OpCode.DefineContent, OpCode.DefineDeck,
                 OpCode.RegRule, OpCode.MakeQuery:
                break;
        }
        registers[instr.a] = result;
    }

    pragma(inline, false)
    private static void execUnary(LuaState state, LuaValue[] registers, ref const Instruction instr) {
        auto operand = registers[instr.b];
        LuaValue result;
        switch (instr.op) {
            case OpCode.Unm: result = opUnm(state, operand); break;
            case OpCode.Not: result = luaValue(!isTruthy(operand)); break;
            case OpCode.Len: result = opLen(state, operand); break;
            default: result = opBNot(state, operand); break;
        }
        registers[instr.a] = result;
    }

    pragma(inline, false)
    private static bool execCompare(LuaState state, Prototype proto, LuaValue[] registers, ref const Instruction instr) {
        auto left = instr.aIsK ? proto.constants[instr.a] : registers[instr.a];
        auto right = instr.bIsK ? proto.constants[instr.b] : registers[instr.b];
        switch (instr.op) {
            case OpCode.Eq: return opEq(state, left, right);
            case OpCode.Lt: return opLt(state, left, right);
            default: return opLe(state, left, right);
        }
    }

    private static bool isNativeFunction(LuaValue v) {
        return v.match!((LuaFunction f) => cast(LuaNativeFunction)f !is null, _ => false);
    }

    /// Calls the function in R[a] with `numArgs` arguments, in a frame of its own.
    pragma(inline, false)
    private static LuaValue[] doCall(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        int a, int numArgs, int callPc) {
        LuaValue[] callArgs = (numArgs > 0) ? registers[a + 1 .. a + 1 + numArgs].dup : [];
        auto callee = registers[a];
        checkCallable(state, callee);
        auto previous = state.callWorld;
        int context = proto.callWorlds.get(callPc, 0);
        auto world = context > 0 ? unwrapWorld(registers[context - 1]) :
            context < 0 ? unwrapWorld(closure.upvalues[-context - 1].get()) : state.globalWorld;
        state.callWorld = world;
        scope(exit) state.callWorld = previous;
        auto identity = proto.callNames.get(callPc, CallName.init);
        return callValue(state, callee, callArgs, false, identity.name, identity.kind, true);
    }

    pragma(inline, false)
    private static void execTForCall(LuaState state, LuaValue[] registers, int a, int wanted) {
        auto iterFn = registers[a];
        if (!isFunction(iterFn)) {
            auto mt = state.getMetatable(iterFn);
            if (mt is null || isNil(mt.rawget(LuaValue("__call"))))
                throw new LuaException("attempt to call a " ~ objectTypeName(state, iterFn) ~ " value (for iterator 'for iterator')");
        }
        auto iterState = registers[a + 1];
        auto iterVar = registers[a + 2];
        auto tResults = callValue(state, iterFn, [iterState, iterVar], false, "for iterator", "for iterator");
        for (int i = 0; i < wanted; ++i) {
            registers[a + 4 + i] = (i < tResults.length) ? tResults[i] : luaNil();
        }
    }

    pragma(inline, false)
    private static void execClosure(LuaClosure closure, Prototype proto, LuaValue[] registers, int a, int index,
        scope UpValue delegate(int) findUp) {
        auto subProto = proto.subPrototypes[index];
        UpValue[] capturedUpvalues;
        foreach (desc; subProto.upvalues) {
            if (desc.inStack) {
                capturedUpvalues ~= findUp(desc.index);
            } else {
                if (desc.index < closure.upvalues.length) {
                    capturedUpvalues ~= closure.upvalues[desc.index];
                }
            }
        }
        registers[a] = luaValue(new LuaClosure(subProto, capturedUpvalues));
    }

    /// Performs a call and copies its results into the registers. Returns the new `top`, or the
    /// negated number of results when the register array has to grow first (the results are then
    /// kept in `state.stashedResults`).
    pragma(inline, false)
    private static int callAndPlace(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        int a, int numArgs, int wanted, int callPc) {
        import dlua.gc : stackHygiene, scrubDeadStack;
        if (stackHygiene) scrubDeadStack();
        auto results = doCall(state, closure, proto, registers, a, numArgs, callPc);
        if (wanted >= 0) {
            for (int i = 0; i < wanted; ++i) registers[a + i] = (i < results.length) ? results[i] : luaNil();
            return a + wanted;
        }
        if (a + results.length >= registers.length) {
            state.stashedResults = results;
            return -cast(int)results.length;
        }
        for (size_t i = 0; i < results.length; ++i) registers[a + i] = results[i];
        return a + cast(int)results.length;
    }

    pragma(inline, false)
    private static int placeStashedResults(LuaState state, LuaValue[] registers, int a) {
        auto results = state.stashedResults;
        state.stashedResults = null;
        for (size_t i = 0; i < results.length; ++i) registers[a + i] = results[i];
        return a + cast(int)results.length;
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
    private static void copyValue(ref LuaValue destination, ref const LuaValue source) {
        import core.stdc.string : memmove;
        memmove(cast(void*)&destination, cast(const(void)*)&source, LuaValue.sizeof);
    }

    /// Allocates in a frame of its own so that no pointer to the new table lingers in the
    /// interpreter loop's stack frame (the collector scans stacks conservatively).
    pragma(inline, false)
    private static void newTableInto(ref LuaValue slot) {
        slot = luaValue(new LuaTable());
    }

    /// Declarative and narrative instructions, kept out of the main loop so that
    /// frames of ordinary Lua calls stay small.
    private static void declarativeOp(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        scope UpValue delegate(int) findUp, Instruction instr) {
        auto op = instr.op;
        int a = instr.a;
        int b = instr.b;
        int c = instr.c;
        int sBx = instr.sBx;
        switch (op) {
                case OpCode.DefineContent:
                    if (state.narrativeRegistry is null) state.narrativeRegistry = new ContentRegistry(state);
                    ContentDefinition instantiateContent(ContentTemplate template_) {
                        auto content = new ContentDefinition();
                        content.kind = template_.kind; content.id = template_.id;
                        content.parameters = template_.parameters.dup;
                        content.incomingParameters = template_.incomingParameters.dup;
                        content.groundedParameters = template_.groundedParameters.dup;
                        foreach (index, name; template_.optionNames) content.options[name] = registers[template_.optionRegisters[index]];
                        if (template_.availabilityRegister >= 0) content.availability = registers[template_.availabilityRegister];
                        if (template_.effectRegister >= 0) content.effect = registers[template_.effectRegister];
                        foreach (choice; template_.choices) content.choices ~= instantiateContent(choice);
                        import dlua.narrative.fingerprint : contentFingerprint;
                        content.fingerprint = contentFingerprint(content);
                        return content;
                    }
                    state.narrativeRegistry.registerContent(instantiateContent(proto.contentTemplates[b]));
                    break;
                case OpCode.DefineDeck:
                    if (state.narrativeRegistry is null) state.narrativeRegistry = new ContentRegistry(state);
                    auto configuration = registers[a].match!((LuaTable table) => table, _ => null);
                    if (configuration is null) throw new LuaException("deck configuration must be a table");
                    LuaValue previousOption, optionKey, optionValue;
                    while (configuration.next(previousOption, optionKey, optionValue)) {
                        previousOption = optionKey;
                        if (!luaRawEqual(optionKey, LuaValue("draw")) && !luaRawEqual(optionKey, LuaValue("replacement")))
                            throw new LuaException("unknown deck option");
                    }
                    auto draw = configuration.rawget(LuaValue("draw"));
                    if (isNil(draw)) draw = LuaValue(1L);
                    if (!isInteger(draw)) throw new LuaException("deck draw must be a positive integer");
                    auto replacement = configuration.rawget(LuaValue("replacement"));
                    if (isNil(replacement)) replacement = LuaValue(true);
                    if (!isBoolean(replacement)) throw new LuaException("deck replacement must be Boolean");
                    string deckName = proto.constants[b].match!((string name) => name, _ => "");
                    state.narrativeRegistry.registerDeck(deckName, DeckDefinition(draw.match!((long n) => n, _ => 1L), replacement.match!((bool yes) => yes, _ => true)));
                    break;

                case OpCode.LoadSymbol:
                    string symName = proto.constants[b].match!((string s) => s, _ => "");
                    registers[a] = state.getSymbol(symName);
                    break;

                case OpCode.NewLocalRel:
                    string lrName = proto.constants[b].match!((string s) => s, _ => "");
                    World fallbackWorld = (sBx == -1) ? state.globalWorld : unwrapWorld(registers[sBx]);
                    auto lr = new LocalRelation(lrName, c, fallbackWorld);
                    registers[a] = wrapLocalRelation(lr);
                    break;

                case OpCode.DeclRel:
                    World declWorld = (a == -1) ? state.globalWorld : unwrapWorld(registers[a]);
                    string relName = proto.constants[b].match!((string s) => s, _ => "");
                    if (sBx > 0) {
                        auto schema = proto.relationSchemas[sBx - 1];
                        declWorld.declareNamedRelation(relName, schema.columns, schema.keys);
                    } else declWorld.declareRelation(relName, c);
                    break;

                case OpCode.SetFact:
                case OpCode.DeleteKey:
                case OpCode.AdjustKey:
                case OpCode.AddFact:
                case OpCode.RetractFact:
                    bool isAdd = (op == OpCode.AddFact);
                    LuaValue[] tupleVals;
                    for (int i = 0; i < sBx; ++i) {
                        auto val = registers[c + i];
                        if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                            throw new LuaException("NaN is prohibited in relational tuples");
                        }
                        tupleVals ~= val;
                    }
                    LuaValue delta;
                    if (op == OpCode.AdjustKey) { delta = tupleVals[$ - 1]; tupleVals = tupleVals[0 .. $ - 1]; }
                    auto tuple = RelTuple(tupleVals);

                    if (a == -2) {
                        auto localRel = unwrapLocalRelation(registers[b]);
                        if (localRel is null) throw new LuaException("expected local relation");
                        if (op == OpCode.SetFact || op == OpCode.DeleteKey || op == OpCode.AdjustKey)
                            throw new LuaException("keyed updates require a named world relation");
                        if (isAdd) {
                            localRel.addFact(tuple);
                        } else {
                            localRel.retractFact(tuple);
                        }
                    } else {
                        World factWorld = (a == -1) ? state.globalWorld : unwrapWorld(registers[a]);
                        string factRelName = proto.constants[b].match!((string s) => s, _ => "");
                        if (op == OpCode.SetFact || op == OpCode.DeleteKey || op == OpCode.AdjustKey) {
                            factWorld.updateFact(factRelName, tuple, op == OpCode.SetFact ? "set" : op == OpCode.DeleteKey ? "delete" : "adjust", delta);
                        } else if (isAdd) {
                            factWorld.addFact(factRelName, tuple);
                        } else {
                            factWorld.retractFact(factRelName, tuple);
                        }
                    }
                    break;

                case OpCode.RegRule:
                    auto rTemp = proto.ruleTemplates[b];
                    auto registration = new RuleRegistration();
                    // Build head terms
                    Term[] headTerms;
                    foreach (tt; rTemp.headTerms) {
                        if (tt.kind == TermKind.Variable) {
                            headTerms ~= Term.makeVariable(tt.varName, tt.varId);
                        } else if (tt.kind == TermKind.Constant) {
                            auto val = registers[tt.reg];
                            if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                                throw new LuaException("NaN is prohibited as a relational constant");
                            }
                            headTerms ~= Term.makeConstant(val);
                        } else {
                            headTerms ~= Term.makeAnonymous();
                        }
                    }

                    Relation[size_t] bodyRelations;
                    Goal[] bodyGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, rTemp.bodyGoals, registration, bodyRelations);

                    // Resolve head relation
                    RelationRef headRef;
                    World targetWorld;
                    LocalRelation targetLocalRel = null;
                    bool isLocalContext = false;
                    if (rTemp.headLocalRelReg >= 0) {
                        targetLocalRel = unwrapLocalRelation(registers[rTemp.headLocalRelReg]);
                        if (targetLocalRel is null) throw new LuaException("expected local relation");
                        if (targetLocalRel.arity != rTemp.headArity) {
                            throw new LuaException(format("relation '%s' expects arity %d, got %d", targetLocalRel.name, targetLocalRel.arity, rTemp.headArity));
                        }
                        headRef = new RelationRef(targetLocalRel.name, targetLocalRel.arity, "", targetLocalRel.id, true);
                        headRef.resolvedRelation = targetLocalRel.relation;
                        targetWorld = targetLocalRel.fallbackWorld ? targetLocalRel.fallbackWorld : state.globalWorld;
                        isLocalContext = true;
                    } else {
                        targetWorld = (rTemp.headWorldReg == -1) ? state.globalWorld : unwrapWorld(registers[rTemp.headWorldReg]);
                        auto hRel = registration.resolve(targetWorld, rTemp.headRelName, rTemp.headArity);
                        headRef = new RelationRef(hRel.name, hRel.arity, targetWorld.id.to!string, hRel.id, false);
                        headRef.resolvedRelation = hRel;
                        isLocalContext = false;
                    }

                    auto concreteRule = new Rule(headRef, headTerms, bodyGoals, getNextRuleId());
                    concreteRule.numVariables = rTemp.numVariables;
                    concreteRule.variableNames = rTemp.variableNames.dup;

                    // Validation
                    validateRuleSafety(concreteRule);
                    validateRuleOwnership(concreteRule, targetWorld, isLocalContext);

                    // Stratification check
                    Relation[size_t] relMap;
                    Rule[] allRules = targetWorld.rules ~ concreteRule;
                    foreach (name, rel; targetWorld.relations) {
                        relMap[rel.id] = rel;
                    }
                    if (isLocalContext) {
                        collectRuleDependencies(targetLocalRel.relation, relMap, allRules);
                        foreach (goal; flattenGoals(bodyGoals)) {
                            if (goal.relRef !is null) {
                                collectRuleDependencies(goal.relRef.resolvedRelation, relMap, allRules);
                            }
                        }
                    }
                    foreach (world, declarations; registration.pending) {
                        foreach (name, relation; declarations) relMap[relation.id] = relation;
                    }
                    computeStratification(relMap, allRules);

                    // Publish
                    registration.commit();
                    if (isLocalContext) {
                        targetLocalRel.registerRule(concreteRule);
                    } else {
                        targetWorld.registerRule(concreteRule);
                    }
                    break;

                case OpCode.MakeQuery:
                    auto qTemp = proto.queryTemplates[b];
                    Goal[] concreteGoals;
                    Relation[size_t] closureRels;
                    Rule[] closureRules;

                    concreteGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, qTemp.goals, null, closureRels);

                    validateQuerySafety(concreteGoals);
                    auto qIter = new QueryIterator(state, concreteGoals, qTemp.returnedVarNames, closureRels, closureRules);
                    registers[a] = createCallableQueryIterator(state, qIter);
                    break;

            default:
                throw new LuaException(format("unknown opcode: %s", op));
        }
    }

    // -------------------------------------------------------------------------
    // Helper Operations & Metamethod Dispatch
    // -------------------------------------------------------------------------

    static LuaValue getTable(LuaState state, LuaValue tableVal, LuaValue keyVal, bool viaMeta = false) {
        auto current = tableVal;
        for (int loop = 0; loop < 2000; ++loop) {
            LuaValue meta;
            if (current.typeOf() == LuaType.Table) {
                auto t = current.match!((LuaTable tbl) => tbl, _ => null);
                auto res = t.rawget(keyVal);
                if (!isNil(res)) return res;
                if (t.metatable is null) return luaNil();
                meta = t.metatable.rawget(LuaValue("__index"));
                if (isNil(meta)) return luaNil();
            } else {
                meta = metaField(state, current, "__index");
                if (isNil(meta)) throw indexError(state, current, viaMeta || loop > 0);
            }
            if (isFunction(meta)) {
                auto resList = callValue(state, meta, [current, keyVal], false, "index", "metamethod");
                return resList.length > 0 ? resList[0] : luaNil();
            }
            current = meta;
        }
        throw new LuaException("'__index' chain too long; possible loop");
    }

    static void setTable(LuaState state, LuaValue tableVal, LuaValue keyVal, LuaValue valVal, bool viaMeta = false) {
        auto current = tableVal;
        for (int loop = 0; loop < 2000; ++loop) {
            LuaValue meta;
            if (current.typeOf() == LuaType.Table) {
                auto t = current.match!((LuaTable tbl) => tbl, _ => null);
                if (t.metatable is null) { t.rawset(keyVal, valVal); return; }
                auto existing = t.rawget(keyVal);
                if (!isNil(existing)) { t.rawset(keyVal, valVal); return; }
                meta = t.metatable.rawget(LuaValue("__newindex"));
                if (isNil(meta)) { t.rawset(keyVal, valVal); return; }
            } else {
                meta = metaField(state, current, "__newindex");
                if (isNil(meta)) throw indexError(state, current, viaMeta || loop > 0);
            }
            if (isFunction(meta)) {
                callValue(state, meta, [current, keyVal, valVal], false, "newindex", "metamethod");
                return;
            }
            current = meta;
        }
        throw new LuaException("'__newindex' chain too long; possible loop");
    }

    /// Raises the "attempt to call" error (with variable info) for values that cannot be called.
    private static void checkCallable(LuaState state, LuaValue callee) {
        if (isFunction(callee)) return;
        auto mt = state.getMetatable(callee);
        if (mt !is null && !isNil(mt.rawget(LuaValue("__call")))) return;
        auto failure = new LuaException("attempt to call a " ~ objectTypeName(state, callee) ~ " value");
        failure.culprit = 1;
        throw failure;
    }

    private static LuaException indexError(LuaState state, LuaValue tableVal, bool viaMeta = false) {
        auto failure = new LuaException("attempt to index a " ~ objectTypeName(state, tableVal) ~ " value");
        failure.culprit = viaMeta ? 0 : 1;
        return failure;
    }

    static LuaValue[] callValue(LuaState state, LuaValue callee, LuaValue[] args, bool tailCall = false, string name = "", string nameKind = "", bool callSite = false) {
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
        scope(exit) if (!callSite && cThread !is null) --cThread.cCalls;

        try { resolveCallable(state, callee, args); }
        catch (LuaException failure) {
            import std.string : startsWith;
            if (nameKind.length && failure.msg.startsWith("attempt to call")) {
                failure.errorObject = LuaValue(toLuaString(failure.errorObject) ~ " (" ~ nameKind ~ " '" ~ name ~ "')");
                failure.msg = toLuaString(failure.errorObject);
            }
            if (state !is null) {
                if (state.callStack.length) failure.locate(state.callStack[$ - 1].source, state.callStack[$ - 1].currentLine);
                state.dispatchError(failure);
            }
            throw failure;
        }
        if (isFunction(callee)) {
            auto fn = callee.match!((LuaFunction f) => f, _ => null);
            if (auto nativeFn = cast(LuaNativeFunction)fn) {
                if (state !is null) state.pushCall(nativeFn, "[C]", -1, tailCall, name, nameKind);
                scope(exit) {
                    if (state !is null) state.popCall();
                }
                if (state !is null) {
                    state.callStack[$ - 1].getLocal = (long index, out LuaValue value) {
                        if (index <= 0 || index > args.length) return cast(string)null;
                        value = args[index - 1]; return "(C temporary)";
                    };
                    state.callStack[$ - 1].setLocal = (long index, LuaValue value) {
                        if (index <= 0 || index > args.length) return cast(string)null;
                        args[index - 1] = value; return "(C temporary)";
                    };
                }
                state.debugHook("call", -1, args, true);
                try {
                    auto results = nativeFn.call(cast(void*)state, args);
                    state.debugHook("return", -1, results, true);
                    return results;
                } catch (LuaException failure) {
                    failure.culprit = 0;
                    if (failure.originFunction is null) {
                        failure.originFunction = nativeFn; failure.originName = name; failure.originKind = nameKind;
                    }
                    if (auto argFailure = cast(ArgError)failure) {
                        argFailure.function_ = nativeFn;
                        // A Lua call site names the function itself (see executeFrame).
                        if (!(callSite && name.length == 0)) formatArgError(state, argFailure, nativeFn, name, nameKind);
                    }
                    auto frames = state.callStack;
                    if (frames.length > 1) failure.locate(frames[$ - 2].source, frames[$ - 2].currentLine);
                    else failure.locate("", -1);
                    state.dispatchError(failure);
                    throw failure;
                }
            }
            if (auto closure = cast(LuaClosure)fn) return execute(state, closure, args, name, nameKind);
            return fn.call(cast(void*)state, args);
        }

        throw new LuaException(format("attempt to call a %s value", typeName(callee)));
    }

    /// luaL_argerror: names the function from its call site, else from package.loaded.
    private static void formatArgError(LuaState state, ArgError failure, LuaFunction fn, string name, string kind) {
        if (failure.formatted) return;
        failure.formatted = true;
        int arg = failure.arg;
        string message;
        if (kind == "method") {
            --arg;
            if (arg == 0) message = "calling '" ~ name ~ "' on bad self (" ~ failure.extra ~ ")";
        }
        if (message.length == 0) {
            if (name.length == 0) name = globalFunctionName(state, fn);
            message = "bad argument #" ~ arg.to!string ~ " to '" ~ (name.length ? name : "?") ~ "' (" ~ failure.extra ~ ")";
        }
        failure.errorObject = LuaValue(message);
        failure.msg = message;
    }

    /// pushglobalfuncname: finds "module.name" for a function in package.loaded.
    static string globalFunctionName(LuaState state, LuaFunction fn) {
        auto package_ = state.globals.rawget(LuaValue("package"));
        if (!isTable(package_)) return "";
        auto loaded = package_.match!((LuaTable t) => t, _ => null).rawget(LuaValue("loaded"));
        if (!isTable(loaded)) return "";
        LuaValue key, value, prevKey;
        auto loadedTable = loaded.match!((LuaTable t) => t, _ => null);
        string found;
        while (loadedTable.next(prevKey, key, value)) {
            prevKey = key;
            if (!isString(key) || !isTable(value)) continue;
            auto module_ = value.match!((LuaTable t) => t, _ => null);
            LuaValue fk, fv, fprev;
            while (module_.next(fprev, fk, fv)) {
                fprev = fk;
                if (isString(fk) && isFunction(fv) && fv.match!((LuaFunction f) => f is fn, _ => false)) {
                    auto moduleName = toLuaString(key);
                    auto fname = toLuaString(fk);
                    if (moduleName == "_G") return fname;
                    found = moduleName ~ "." ~ fname;
                }
            }
        }
        return found;
    }

    private static void resolveCallable(LuaState state, ref LuaValue callee, ref LuaValue[] args) {
        for (int depth = 0; !isFunction(callee); ++depth) {
            if (depth >= 2000) throw new LuaException("'__call' chain too long; possible loop");
            auto metatable = state.getMetatable(callee);
            auto method = metatable is null ? luaNil() : metatable.rawget(LuaValue("__call"));
            if (isNil(method)) throw new LuaException(format("attempt to call a %s value", typeName(callee)));
            args = [callee] ~ args;
            callee = method;
        }
    }

    // -------------------------------------------------------------------------
    // Symbolic variable information for error messages (ldebug.c getobjname)
    // -------------------------------------------------------------------------

    private static int culpritRegister(Instruction instr, int culprit) {
        switch (instr.op) {
            case OpCode.GetTable, OpCode.Self: return instr.b;
            case OpCode.SetTable: return instr.a;
            case OpCode.Unm, OpCode.Len, OpCode.BNot: return instr.b;
            case OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv, OpCode.Mod, OpCode.Pow,
                 OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr, OpCode.Concat:
                if (culprit == 1) return instr.bIsK ? -1 : instr.b;
                return instr.cIsK ? -1 : instr.c;
            case OpCode.Call, OpCode.TailCall: return instr.a;
            default: return -1;
        }
    }

    /// "(constant 'x')" for a string constant operand (C Lua loads it into a register first).
    private static string constantInfo(Prototype proto, ref const Instruction instr, int culprit) {
        switch (instr.op) {
            case OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv, OpCode.Mod, OpCode.Pow,
                 OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr, OpCode.Concat: break;
            default: return "";
        }
        bool isK = culprit == 1 ? instr.bIsK : instr.cIsK;
        int index = culprit == 1 ? instr.b : instr.c;
        if (!isK || index < 0 || index >= cast(int)proto.constants.length) return "";
        auto k = proto.constants[index];
        if (!isString(k)) return "";
        return "(constant '" ~ toLuaString(k) ~ "')";
    }

    private static void applyVariableInfo(LuaException e, Prototype proto, int pc) {
        int culprit = e.culprit;
        e.culprit = 0;
        int reg = culpritRegister(proto.code[pc], culprit);
        string info = reg < 0 ? constantInfo(proto, proto.code[pc], culprit) : variableInfo(proto, pc, reg);
        auto text = toLuaString(e.errorObject);
        import std.string : indexOf;
        if (text.indexOf("%s") >= 0) text = text.replace("%s", info.length ? " " ~ info : "");
        else if (info.length) text ~= " " ~ info;
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
                local.name.length && local.name[0] != '(' && local.name[0] != '@') return local.name;
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
                case OpCode.LoadNil: change = reg >= instr.a && reg <= instr.a + instr.b; break;
                case OpCode.Call, OpCode.TailCall: change = reg >= instr.a; break;
                case OpCode.TForCall: change = reg >= instr.a + 3; break;
                case OpCode.Jmp, OpCode.Test, OpCode.ForPrep, OpCode.ForLoop, OpCode.TForLoop:
                    int dest = i + 1 + instr.sBx;
                    if (dest <= lastPc && dest > jumpTarget) jumpTarget = dest;
                    break;
                case OpCode.Self: change = reg == instr.a || reg == instr.a + 1; break;
                case OpCode.Vararg: change = reg >= instr.a; break;
                case OpCode.Move, OpCode.LoadBool, OpCode.LoadInt, OpCode.LoadK, OpCode.GetGlobal, OpCode.GetUpval,
                     OpCode.NewTable, OpCode.GetTable, OpCode.Add, OpCode.Sub, OpCode.Mul, OpCode.Div, OpCode.IDiv,
                     OpCode.Mod, OpCode.Pow, OpCode.BAnd, OpCode.BOr, OpCode.BXor, OpCode.Shl, OpCode.Shr,
                     OpCode.Concat, OpCode.Unm, OpCode.Not, OpCode.Len, OpCode.BNot, OpCode.Closure,
                     OpCode.LoadSymbol, OpCode.NewLocalRel, OpCode.MakeQuery:
                    change = reg == instr.a; break;
                case OpCode.TestSet:
                    int testDest = i + 1 + instr.sBx;
                    if (testDest <= lastPc && testDest > jumpTarget) jumpTarget = testDest;
                    change = reg == instr.a; break;
                default: break;
            }
            if (change) setReg = i < jumpTarget ? -1 : i;
        }
        return setReg;
    }

    private static string constantName(Prototype proto, int index) {
        if (index < 0 || index >= proto.constants.length) return null;
        return proto.constants[index].match!((string s) => s.length ? s : "", _ => cast(string)null);
    }

    private static string objectName(Prototype proto, int lastPc, int reg, out string name) {
        name = activeLocalName(proto, lastPc, reg);
        if (name !is null) return "local";
        int pc = findSetRegister(proto, lastPc, reg);
        if (pc < 0) return null;
        auto instr = proto.code[pc];
        switch (instr.op) {
            case OpCode.Move:
                if (instr.b < instr.a) return objectName(proto, pc, instr.b, name);
                break;
            case OpCode.GetGlobal:
                name = constantName(proto, instr.b);
                return name is null ? null : "global";
            case OpCode.GetTable:
                if (instr.cIsK) {
                    name = constantName(proto, instr.c);
                    if (name is null) {
                        if (instr.c < proto.constants.length && isInteger(proto.constants[instr.c])) name = "integer index";
                        else return null;
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
                if (instr.b < proto.upvalues.length) { name = proto.upvalues[instr.b].name; return "upvalue"; }
                break;
            case OpCode.LoadK:
                name = constantName(proto, instr.b);
                return name is null ? null : "constant";
            case OpCode.Self:
                if (instr.cIsK) name = constantName(proto, instr.c);
                else { string keyName; name = objectName(proto, pc, instr.c, keyName) == "constant" ? keyName : "?"; }
                return name is null ? null : "method";
            default: break;
        }
        return null;
    }

    static bool toCoercedNumber(LuaValue val, out LuaValue outNum) {
        if (isInteger(val) || isFloat(val)) {
            outNum = val;
            return true;
        }
        if (isString(val)) return parseLuaNumber(val.match!((string text) => text, _ => ""), outNum);
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
                if (bi == 0) throw new LuaException("attempt to divide by zero");
                long ai = na.match!((long i) => i, _ => 0L);
                // Lua wraps MININTEGER / -1, and rounds division down.
                if (bi == -1) return luaValue(-ai);
                long quotient = ai / bi;
                if (ai % bi != 0 && (ai < 0) != (bi < 0)) --quotient;
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
                if (bi == 0) throw new LuaException("attempt to perform 'n%0'");
                if (bi == -1) return luaValue(0L);
                long remainder = na.match!((long i) => i, _ => 0L) % bi;
                if (remainder != 0 && (remainder < 0) != (bi < 0)) remainder += bi;
                return luaValue(remainder);
            }
            import std.math : fmod;
            double divisor = toDoubleVal(nb);
            double remainder = fmod(toDoubleVal(na), divisor);
            if ((remainder > 0 && divisor < 0) || (remainder < 0 && divisor > 0)) remainder += divisor;
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
        if (distance >= 64 || distance <= -64) return 0;
        return distance < 0 ? cast(long)(cast(ulong)value >> -distance) : value << distance;
    }

    static LuaValue opConcat(LuaState state, LuaValue a, LuaValue b) {
        if ((isString(a) || isNumber(a)) && (isString(b) || isNumber(b))) {
            return luaValue(toLuaString(a) ~ toLuaString(b));
        }
        return invokeBinMeta(state, a, b, "__concat");
    }

    static LuaValue opUnm(LuaState state, LuaValue a) {
        if (isInteger(a)) return luaValue(-a.match!((long i) => i, _ => 0L));
        if (isFloat(a)) return luaValue(-a.match!((double d) => d, _ => 0.0));
        LuaValue number;
        if (toCoercedNumber(a, number)) return opUnm(state, number);
        return invokeUnaryMeta(state, a, "__unm");
    }

    static LuaValue opLen(LuaState state, LuaValue a) {
        if (isTable(a)) {
            auto t = a.match!((LuaTable tbl) => tbl, _ => null);
            auto meta = t.getMetamethod("__len");
            if (!isNil(meta)) {
                auto res = callValue(state, meta, [a, a], false, "len", "metamethod");
                return res.length > 0 ? res[0] : luaNil();
            }
            return luaValue(t.rawLen());
        }
        if (isString(a)) {
            return luaValue(cast(long)a.match!((string s) => s.length, _ => 0LU));
        }
        return invokeUnaryMeta(state, a, "__len");
    }

    static LuaValue opBNot(LuaState state, LuaValue a) {
        long integer;
        if (bitwiseInteger(a, integer)) return luaValue(~integer);
        return invokeUnaryMeta(state, a, "__bnot");
    }

    /// Equality with the __eq metamethod (tables and full userdata only).
    static bool opEq(LuaState state, LuaValue a, LuaValue b) {
        if (luaRawEqual(a, b)) return true;
        auto ta = a.typeOf();
        if (ta != b.typeOf() || (ta != LuaType.Table && ta != LuaType.UserData)) return false;
        auto meta = metaField(state, a, "__eq");
        if (isNil(meta)) meta = metaField(state, b, "__eq");
        if (isNil(meta)) return false;
        auto result = callValue(state, meta, [a, b], false, "eq", "metamethod");
        return result.length && isTruthy(result[0]);
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
                auto res = callValue(state, meta, [a, b], false, event[2 .. $], "metamethod");
                return res.length > 0 ? res[0] : luaNil();
            }
        }
        auto secondMeta = state.getMetatable(b);
        if (secondMeta !is null) {
            auto meta = secondMeta.rawget(LuaValue(event));
            if (!isNil(meta)) {
                auto res = callValue(state, meta, [a, b], false, event[2 .. $], "metamethod");
                return res.length > 0 ? res[0] : luaNil();
            }
        }
        throw binaryOperandError(state, a, b, event);
    }

    /// Builds the C-Lua-equivalent error for a binary operation without a usable metamethod.
    private static LuaException binaryOperandError(LuaState state, LuaValue a, LuaValue b, string event) {
        LuaException failure;
        if (event == "__lt" || event == "__le") {
            auto t1 = objectTypeName(state, a), t2 = objectTypeName(state, b);
            return new LuaException(t1 == t2 ? format("attempt to compare two %s values", t1) : format("attempt to compare %s with %s", t1, t2));
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
                return new LuaException(format("attempt to %s a '%s' with a '%s'", event[2 .. $], objectTypeName(state, a), objectTypeName(state, b)));
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
                if (isString(name)) return toLuaString(name);
            }
        }
        return typeName(v);
    }

    private static string forError(LuaState state, LuaValue v, string what) {
        return "bad 'for' " ~ what ~ " (number expected, got " ~ objectTypeName(state, v) ~ ")";
    }

    /// Prepares a numeric for loop (lvm.c forprep). Returns true to skip the loop.
    private static bool forPrepare(LuaState state, LuaValue[] r, int a) {
        if (isInteger(r[a]) && isInteger(r[a + 2])) {
            long init = r[a].match!((long i) => i, _ => 0L);
            long step = r[a + 2].match!((long i) => i, _ => 0L);
            if (step == 0) throw new LuaException("'for' step is zero");
            r[a + 3] = luaValue(init);
            long limit;
            LuaValue lim = r[a + 1];
            if (isString(lim)) { LuaValue n; if (toCoercedNumber(lim, n)) lim = n; }
            if (isInteger(lim)) limit = lim.match!((long i) => i, _ => 0L);
            else if (isFloat(lim)) {
                double f = lim.match!((double d) => d, _ => 0.0);
                if (isNaN(f)) return true;
                double fl = step < 0 ? ceil(f) : floor(f);
                if (fl >= -9223372036854775808.0 && fl < 9223372036854775808.0) limit = cast(long)fl;
                else if (f > 0) { if (step < 0) return true; limit = long.max; }
                else { if (step > 0) return true; limit = long.min; }
            } else throw new LuaException(forError(state, lim, "limit"));
            if (step > 0 ? init > limit : init < limit) return true;
            ulong count;
            if (step > 0) {
                count = cast(ulong)limit - cast(ulong)init;
                if (step != 1) count /= cast(ulong)step;
            } else {
                count = cast(ulong)init - cast(ulong)limit;
                count /= cast(ulong)(-(step + 1)) + 1UL;
            }
            r[a + 1] = luaValue(cast(long)count);
            return false;
        }
        LuaValue init, limit, step;
        if (!toCoercedNumber(r[a + 1], limit)) throw new LuaException(forError(state, r[a + 1], "limit"));
        if (!toCoercedNumber(r[a + 2], step)) throw new LuaException(forError(state, r[a + 2], "step"));
        if (!toCoercedNumber(r[a], init)) throw new LuaException(forError(state, r[a], "initial value"));
        double fi = toDoubleVal(init), fl = toDoubleVal(limit), fs = toDoubleVal(step);
        if (fs == 0) throw new LuaException("'for' step is zero");
        if (fs > 0 ? fl < fi : fi < fl) return true;
        r[a] = luaValue(fi); r[a + 1] = luaValue(fl); r[a + 2] = luaValue(fs); r[a + 3] = luaValue(fi);
        return false;
    }

    /// Steps a prepared numeric for loop. Returns true to continue looping.
    private static bool forStep(LuaValue[] r, int a) {
        if (isInteger(r[a + 2])) {
            ulong count = cast(ulong)r[a + 1].match!((long i) => i, _ => 0L);
            if (count > 0) {
                long step = r[a + 2].match!((long i) => i, _ => 0L);
                long idx = r[a].match!((long i) => i, _ => 0L) + step;
                r[a + 1] = luaValue(cast(long)(count - 1));
                r[a] = luaValue(idx);
                r[a + 3] = luaValue(idx);
                return true;
            }
            return false;
        }
        double step = r[a + 2].match!((double d) => d, _ => 0.0);
        double limit = r[a + 1].match!((double d) => d, _ => 0.0);
        double idx = r[a].match!((double d) => d, _ => 0.0) + step;
        if (step > 0 ? idx <= limit : limit <= idx) {
            r[a] = luaValue(idx); r[a + 3] = luaValue(idx);
            return true;
        }
        return false;
    }

    private static LuaValue invokeUnaryMeta(LuaState state, LuaValue a, string event) {
        auto metatable = state.getMetatable(a);
        if (metatable !is null) {
            auto meta = metatable.rawget(LuaValue(event));
            if (!isNil(meta)) {
                auto result = callValue(state, meta, [a, a], false, event[2 .. $], "metamethod");
                return result.length ? result[0] : luaNil();
            }
        }
        LuaException failure;
        if (event == "__bnot") {
            if (isNumber(a)) failure = new LuaException("number%s has no integer representation");
            else failure = new LuaException("attempt to perform bitwise operation on a " ~ objectTypeName(state, a) ~ " value");
        } else if (event == "__len") {
            failure = new LuaException("attempt to get length of a " ~ objectTypeName(state, a) ~ " value");
        } else if (isString(a)) {
            return throw_(new LuaException(format("attempt to unm a 'string' with a 'string'")));
        } else {
            failure = new LuaException("attempt to perform arithmetic on a " ~ objectTypeName(state, a) ~ " value");
        }
        failure.culprit = 1;
        throw failure;
    }

    private static LuaValue throw_(LuaException e) { throw e; }

    private static double toDoubleVal(LuaValue v) {
        return v.match!(
            (long i) => cast(double)i,
            (double d) => d,
            _ => 0.0
        );
    }

    private static long toIntegerVal(LuaValue v) {
        return v.match!(
            (long i) => i,
            (double d) => cast(long)d,
            _ => 0L
        );
    }
}
