/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.compiler;

import std.conv : to;

import varis.ast;
import varis.opcode;
import varis.types;
import varis.exception : LuaException;
import varis.relterms;
import std.format : format;

class Compiler {
    Compiler parent;
    Prototype proto;

    struct LocalVar {
        string name;
        int reg;
        int depth;
        bool isConst;
        bool isClose;
        bool isCaptured;
    }

    LocalVar[] locals;
    int currentScopeDepth = 0;
    int freeReg = 0;
    int currentLine = 1;

    int[] loopBreakJumps;
    int[] loopCloseRegisters;
    int loopDepth = 0;
    int transactionDepth;
    bool[int] readOnlyRegisters;
    bool[string] groundedLogicParameters;
    bool narrativeContext;

    private struct JumpLabel {
        int pc;
        LocalVar[] locals;
        int line;
    }

    private struct PendingGoto {
        string name;
        int closePc;
        int jumpPc;
        LocalVar[] locals;
        size_t visibleLocals;
        int line;
    }

    private class LabelBlock {
        LabelBlock parent;
        JumpLabel[string] labels;
        PendingGoto[] pending;
    }

    private LabelBlock labelBlock;

    private void resolveGoto(PendingGoto jump, JumpLabel label) {
        if (label.locals.length > jump.visibleLocals) {
            throw fail("<goto " ~ jump.name ~ "> at line " ~ jump.line.to!string ~ " jumps into the scope of local '"
                    ~ label.locals[jump.visibleLocals].name ~ "'");
        }
        int first = int.max;
        foreach (local; jump.locals[label.locals.length .. $]) {
            if (local.reg < first)
                first = local.reg;
        }
        proto.code[jump.closePc].a = first;
        patchJump(jump.jumpPc, label.pc);
    }

    this(Compiler parent = null, string functionName = "") {
        this.parent = parent;
        if (parent !is null)
            groundedLogicParameters = parent.groundedLogicParameters.dup;
        this.proto = new Prototype();
        this.proto.functionName = functionName;
        this.freeReg = 0;
        this.currentScopeDepth = 0;
        this.currentLine = 1;
    }

    // -------------------------------------------------------------------------
    // Code Emission and Register Management
    // -------------------------------------------------------------------------

    int emit(OpCode op, int a = 0, int b = 0, int c = 0, int sBx = 0, int line = 0) {
        Instruction instr;
        instr.op = op;
        instr.a = a;
        instr.b = b;
        instr.c = c;
        instr.sBx = sBx;
        instr.line = (line > 0) ? line : currentLine;
        bool variableTop = ((op == OpCode.Call || op == OpCode.TailCall || op == OpCode.Return) && b == 0) || op == OpCode
            .SetList;
        proto.pushInstruction(instr, variableTop ? int.max : freeReg);
        return cast(int)(proto.code.length - 1);
    }

    int emitJump(OpCode op = OpCode.Jmp, int a = 0) {
        return emit(op, a, 0, 0, 0);
    }

    void patchJump(int jumpPc, int targetPc) {
        proto.code[jumpPc].sBx = targetPc - jumpPc - 1;
    }

    int currentPc() const {
        return cast(int) proto.code.length;
    }

    int allocReg() {
        if (freeReg + 1 >= 255)
            throw fail("function or expression needs too many registers");
        int r = freeReg++;
        if (freeReg > proto.maxStackSize) {
            proto.maxStackSize = freeReg;
        }
        return r;
    }

    void freeRegs(int count) {
        freeReg -= count;
        if (freeReg < 0)
            freeReg = 0;
    }

    private static bool sameFloatBits(LuaValue a, LuaValue b) {
        double x = a.match!((double d) => d, _ => 0.0), y = b.match!((double d) => d, _ => 0.0);
        return *cast(ulong*)&x == *cast(ulong*)&y;
    }

    private int[long] integerConstants;
    private int[ulong] floatConstants;
    private int[string] stringConstants;
    private int nilConstant = -1, trueConstant = -1, falseConstant = -1;

    int addConstant(LuaValue val) {
        int* found;
        if (isInteger(val))
            found = val.match!((long i) => i, _ => 0L) in integerConstants;
        else if (isFloat(val)) {
            double d = val.match!((double x) => x, _ => 0.0);
            found = *cast(ulong*)&d in floatConstants;
        } else if (isString(val))
            found = val.match!((string str) => str, _ => "") in stringConstants;
        else if (isNil(val)) {
            if (nilConstant >= 0)
                return nilConstant;
        } else if (val.typeOf() == LuaType.Boolean) {
            int cached = isTruthy(val) ? trueConstant : falseConstant;
            if (cached >= 0)
                return cached;
        } else {
            foreach (size_t idx, constVal; proto.constants)
                if (constVal.typeOf() == val.typeOf() && luaRawEqual(constVal, val))
                    return cast(int) idx;
        }
        if (found !is null)
            return *found;
        proto.constants ~= val;
        int index = cast(int)(proto.constants.length - 1);
        if (isInteger(val))
            integerConstants[val.match!((long i) => i, _ => 0L)] = index;
        else if (isFloat(val)) {
            double d = val.match!((double x) => x, _ => 0.0);
            floatConstants[*cast(ulong*)&d] = index;
        } else if (isString(val))
            stringConstants[val.match!((string str) => str, _ => "")] = index;
        else if (isNil(val))
            nilConstant = index;
        else if (val.typeOf() == LuaType.Boolean) {
            if (isTruthy(val))
                trueConstant = index;
            else
                falseConstant = index;
        }
        return index;
    }

    // -------------------------------------------------------------------------
    // Scopes and Variable Resolution
    // -------------------------------------------------------------------------

    void enterScope() {
        currentScopeDepth++;
    }

    void exitScope() {
        currentScopeDepth--;
        // Close captured slots before their registers can be reused by another scope.
        int firstReg = -1;
        foreach (local; locals) {
            if (local.depth > currentScopeDepth && (local.isClose || local.isCaptured) && (firstReg < 0 || local.reg < firstReg)) {
                firstReg = local.reg;
            }
        }
        if (firstReg >= 0)
            emit(OpCode.Close, firstReg);
        foreach (ref local; proto.debugLocals) {
            if (local.depth > currentScopeDepth && local.endPC == int.max)
                local.endPC = currentPc();
        }
        while (locals.length > 0 && locals[$ - 1].depth > currentScopeDepth) {
            readOnlyRegisters.remove(locals[$ - 1].reg);
            freeRegs(1);
            locals = locals[0 .. $ - 1];
        }
    }

    private string functionDescription() {
        return proto.lineDefined == 0 ? "main function" : "function at line " ~ proto.lineDefined.to!string;
    }

    int addLocal(string name) {
        if (locals.length >= 200)
            throw fail("too many local variables (limit is 200) in " ~ functionDescription());
        int reg = allocReg();
        locals ~= LocalVar(name, reg, currentScopeDepth);
        proto.debugLocals ~= DebugLocal(name, reg, currentPc(), int.max, currentScopeDepth);
        return reg;
    }

    void markReadOnly(int reg) {
        readOnlyRegisters[reg] = true;
        foreach (ref local; proto.debugLocals)
            if (local.register == reg && local.endPC == int.max)
                local.readOnly = true;
    }

    int resolveLocal(string name) {
        for (long i = cast(long) locals.length - 1; i >= 0; --i) {
            if (locals[cast(size_t) i].name == name) {
                return locals[cast(size_t) i].reg;
            }
        }
        return -1;
    }

    int resolveUpvalue(string name) {
        foreach (index, upvalue; proto.upvalues) {
            if (upvalue.name == name)
                return cast(int) index;
        }
        if (parent is null)
            return -1;

        // Check parent's locals
        int localIdx = parent.resolveLocal(name);
        if (localIdx >= 0) {
            foreach (ref local; parent.locals)
                if (local.reg == localIdx)
                    local.isCaptured = true;
            return addUpvalue(name, true, localIdx);
        }

        // Check parent's upvalues recursively
        int upvalIdx = parent.resolveUpvalue(name);
        if (upvalIdx >= 0) {
            return addUpvalue(name, false, upvalIdx);
        }

        return -1;
    }

    private int addUpvalue(string name, bool inStack, int index) {
        foreach (size_t i, up; proto.upvalues) {
            if (up.inStack == inStack && up.index == index) {
                return cast(int) i;
            }
        }
        if (proto.upvalues.length >= 255)
            throw fail("too many upvalues (limit is 255) in " ~ functionDescription());
        proto.upvalues ~= UpvalDesc(name, inStack, index);
        return cast(int)(proto.upvalues.length - 1);
    }

    // -------------------------------------------------------------------------
    // Compilation Entry Points
    // -------------------------------------------------------------------------

    Prototype compileChunk(BlockStmt block, string sourceName = "=stdin") {
        proto.sourceName = sourceName;
        proto.isVararg = true;
        addUpvalue("_ENV", false, 0);
        compileBlock(block);
        if (block.endLine > 0)
            currentLine = block.endLine;
        emit(OpCode.Return, 0, 1); // default return 0 values
        return proto;
    }

    private int environmentOperand() {
        int local = resolveLocal("_ENV");
        if (local >= 0)
            return local + 1;
        int upvalue = resolveUpvalue("_ENV");
        return upvalue >= 0 ? -upvalue - 1 : 0;
    }

    void compileBlock(BlockStmt block, bool allowEndLabels = true) {
        if (block is null)
            return;
        auto outer = labelBlock;
        auto current = new LabelBlock();
        current.parent = outer;
        labelBlock = current;
        scope (exit)
            labelBlock = outer;
        auto entryLocals = locals.dup;
        size_t endLabels = block.statements.length;
        if (allowEndLabels) {
            while (endLabels && (as!LabelStmt(block.statements[endLabels - 1])
                    || as!EmptyStmt(block.statements[endLabels - 1])))
                --endLabels;
        }
        foreach (index, stmt; block.statements) {
            if (auto label = as!LabelStmt(stmt)) {
                for (auto visible = current; visible !is null; visible = visible.parent) {
                    if (auto prior = label.label in visible.labels)
                        throw fail("label '" ~ label.label ~ "' already defined on line " ~ prior.line.to!string);
                }
                current.labels[label.label] = JumpLabel(currentPc(),
                        index >= endLabels ? entryLocals.dup : locals.dup, label.loc.line);
                continue;
            }
            compileStmt(stmt);
        }
        foreach (jump; current.pending) {
            if (auto label = jump.name in current.labels)
                resolveGoto(jump, *label);
            else if (outer !is null) {
                if (jump.visibleLocals > entryLocals.length)
                    jump.visibleLocals = entryLocals.length;
                outer.pending ~= jump;
            } else
                throw fail("no visible label '" ~ jump.name ~ "' for <goto> at line " ~ jump.line.to!string);
        }
    }

    void compileStmt(Stmt stmt) {
        if (stmt is null || as!EmptyStmt(stmt))
            return;
        if (stmt.loc.line > 0)
            currentLine = stmt.loc.line;

        if (auto jump = as!GotoStmt(stmt)) {
            int closePc = emit(OpCode.Close, int.max);
            int jumpPc = emitJump();
            labelBlock.pending ~= PendingGoto(jump.label, closePc, jumpPc, locals.dup, locals.length, jump.loc.line);
            return;
        }

        if (auto s = as!DoStmt(stmt)) {
            enterScope();
            compileBlock(s.body);
            exitScope();
            return;
        }

        if (auto s = as!LocalDeclStmt(stmt)) {
            compileLocalDecl(s);
            return;
        }

        if (auto s = as!AssignStmt(stmt)) {
            compileAssign(s);
            return;
        }

        if (auto s = as!CallStmt(stmt)) {
            compileExpr(s.call, freeReg, 0); // 0 return values; the call allocates its own base
            return;
        }

        if (auto s = as!ReturnStmt(stmt)) {
            compileReturn(s);
            return;
        }

        if (auto s = as!IfStmt(stmt)) {
            compileIf(s);
            return;
        }

        if (auto s = as!WhileStmt(stmt)) {
            compileWhile(s);
            return;
        }

        if (auto s = as!RepeatStmt(stmt)) {
            compileRepeat(s);
            return;
        }

        if (auto s = as!ForNumericStmt(stmt)) {
            compileForNumeric(s);
            return;
        }

        if (auto s = as!ForGenericStmt(stmt)) {
            compileForGeneric(s);
            return;
        }

        if (auto s = as!FunctionDeclStmt(stmt)) {
            compileFunctionDecl(s);
            return;
        }

        if (auto s = as!BreakStmt(stmt)) {
            if (loopDepth <= 0) {
                throw fail("break outside loop at line " ~ currentLine.to!string);
            }
            emit(OpCode.Close, loopCloseRegisters[$ - 1]);
            loopBreakJumps ~= emitJump();
            return;
        }

        if (auto definition = as!NarrativeDefinitionStmt(stmt)) {
            int[] registers;
            proto.contentTemplates ~= compileContent(definition, [], registers);
            emit(OpCode.DefineContent, 0, cast(int) proto.contentTemplates.length - 1);
            freeRegs(cast(int) registers.length);
            return;
        }
        if (auto deck = as!NarrativeDeckStmt(stmt)) {
            int options = allocReg();
            compileExpr(deck.options, options, 1);
            emit(OpCode.DefineDeck, options, addConstant(LuaValue(deck.name)));
            freeRegs(1);
            return;
        }

        if (auto s = as!TransactionStmt(stmt)) {
            enterScope();
            int startRegister = freeReg;
            int world = resolveLocal("@world");
            if (s.worldExpr !is null) {
                world = allocReg();
                compileExpr(s.worldExpr, world, 1);
                locals ~= LocalVar("@world", world, currentScopeDepth);
                proto.debugLocals ~= DebugLocal("@world", world, currentPc(), int.max, currentScopeDepth);
            } else if (world < 0) {
                int upvalue = resolveUpvalue("@world");
                if (upvalue >= 0) {
                    world = allocReg();
                    emit(OpCode.GetUpval, world, upvalue);
                }
            }
            int begin = emit(OpCode.BeginTransaction, world, 0, startRegister);
            transactionDepth++;
            compileBlock(s.body);
            transactionDepth--;
            exitScope();
            emit(OpCode.EndTransaction);
            proto.code[begin].b = cast(int) proto.code.length;
            return;
        }
        if (as!RollbackStmt(stmt) !is null) {
            if (transactionDepth == 0)
                throw new LuaException("rollback outside a transaction");
            emit(OpCode.Rollback);
            return;
        }
        if (auto s = as!UpdateStmt(stmt)) {
            auto args = s.args.dup;
            if (s.delta !is null)
                args ~= s.delta;
            compileFactOrRetract(s.relRef, args, true,
                    s.operation == "set" ? OpCode.SetFact
                    : s.operation == "delete" ? OpCode.DeleteKey : OpCode.AdjustKey);
            return;
        }
        if (auto s = as!FactStmt(stmt)) {
            compileFact(s);
            return;
        }

        if (auto s = as!RetractStmt(stmt)) {
            compileRetract(s);
            return;
        }

        if (auto s = as!RelationDeclStmt(stmt)) {
            compileRelationDecl(s);
            return;
        }

        if (auto s = as!LocalRelationDeclStmt(stmt)) {
            compileLocalRelationDecl(s);
            return;
        }

        if (auto s = as!RuleDeclStmt(stmt)) {
            compileRuleDecl(s);
            return;
        }

        if (auto s = as!WorldBlockStmt(stmt)) {
            compileWorldBlock(s);
            return;
        }

        throw new LuaException("unsupported statement type");
    }

    private bool isVarargOrCall(Expr expr) {
        if (expr is null)
            return false;
        if (expr.parenthesized)
            return false;
        return (as!CallExpr(expr) !is null) ||
            (as!MethodCallExpr(expr) !is null) ||
            (as!VarargExpr(expr) !is null);
    }

    /// True when compiling `e` into a reserved target register evaluates temporaries before the target is
    /// first written (so the target's stale contents must be cleared first; see compileLocalDecl).
    /// An expression whose operands are all plain constants or variables is a single instruction that
    /// writes the target itself.
    private static bool needsFreshTarget(Expr e) {
        static bool leaf(Expr x) {
            return cast(LiteralNilExpr) x || cast(LiteralBoolExpr) x || cast(LiteralIntExpr) x ||
                cast(LiteralFloatExpr) x || cast(LiteralStringExpr) x || cast(VariableExpr) x ||
                cast(SymbolLiteralExpr) x;
        }

        if (e is null)
            return false;
        if (cast(CallExpr) e || cast(MethodCallExpr) e)
            return true;
        if (auto b = cast(BinaryExpr) e)
            return !leaf(b.left) || !leaf(b.right);
        if (auto u = cast(UnaryExpr) e)
            return !leaf(u.expr);
        if (auto i = cast(IndexExpr) e)
            return !leaf(i.table) || !leaf(i.key);
        if (auto f = cast(FieldExpr) e)
            return !leaf(f.table);
        return false;
    }

    private void compileLocalDecl(LocalDeclStmt s) {
        int[] targetRegs;
        foreach (name; s.names) {
            targetRegs ~= allocReg();
        }

        // The new locals' registers are reserved before their initializers run, and an initializer that
        // evaluates subexpressions (call, concatenation chain, ...) writes its temporaries above them.
        // They would keep a stale value from earlier code alive across any collection that happens in
        // between (Lua itself evaluates into these registers first). Clear them; trivial single-
        // instruction initializers write the register immediately and need nothing.
        bool needsFresh = false;
        foreach (v; s.values)
            needsFresh = needsFresh || needsFreshTarget(v);
        if (needsFresh)
            foreach (r; targetRegs)
                emit(OpCode.LoadNil, r, 0);

        if (s.values.length == 0) {
            foreach (r; targetRegs) {
                emit(OpCode.LoadNil, r, 0);
            }
        } else {
            // Evaluate all but the last RHS expression with 1 result
            for (size_t i = 0; i + 1 < s.values.length; ++i) {
                if (i < targetRegs.length) {
                    compileExpr(s.values[i], targetRegs[i], 1);
                } else {
                    int r = allocReg();
                    compileExpr(s.values[i], r, 0);
                    freeRegs(1);
                }
            }

            // Last RHS expression: expand multiple results if more targets remain
            size_t lastIdx = s.values.length - 1;
            auto lastVal = s.values[lastIdx];
            if (lastIdx < targetRegs.length) {
                int needed = cast(int)(targetRegs.length - lastIdx);
                if (needed > 1 && isVarargOrCall(lastVal)) {
                    compileExpr(lastVal, targetRegs[lastIdx], needed);
                } else {
                    compileExpr(lastVal, targetRegs[lastIdx], 1);
                    for (size_t k = lastIdx + 1; k < targetRegs.length; ++k) {
                        emit(OpCode.LoadNil, targetRegs[k], 0);
                    }
                }
            } else {
                int r = allocReg();
                compileExpr(lastVal, r, 0);
                freeRegs(1);
            }
        }

        // Activate locals in scope ONLY AFTER evaluating RHS initializers!
        foreach (i, name; s.names) {
            bool isConst = i < s.attributes.length && s.attributes[i].length > 0;
            locals ~= LocalVar(name, targetRegs[i], currentScopeDepth, isConst,
                    i < s.attributes.length && s.attributes[i] == "close");
            proto.debugLocals ~= DebugLocal(name, targetRegs[i], currentPc(), int.max, currentScopeDepth);
            if (i < s.attributes.length && s.attributes[i] == "close")
                emit(OpCode.ToClose, targetRegs[i]);
        }
    }

    /// Builds a compile-time error located at this compiler's current line.
    LuaException fail(string message) {
        import varis.exception : shortSourceName;

        auto failure = new LuaException(
                LuaValue(shortSourceName(proto.sourceName) ~ ":" ~ currentLine.to!string ~ ": " ~ message));
        failure.needsLocation = false;
        return failure;
    }

    private void checkWritable(string name, Compiler origin = null) {
        if (origin is null)
            origin = this;
        int register = resolveLocal(name);
        if (register >= 0) {
            foreach_reverse (local; locals) {
                if (local.reg == register && local.isConst)
                    throw origin.fail("attempt to assign to const variable '" ~ name ~ "'");
            }
            if (register in readOnlyRegisters)
                throw origin.fail("cannot assign read-only narrative parameter '" ~ name ~ "'");
        } else if (parent !is null)
            parent.checkWritable(name, origin);
    }

    /// Compile a function with an implicit world and immutable parameter inputs.
    static Prototype contextPrototype(BlockStmt body, string[] names, string[] groundedNames = []) {
        auto compiler = new Compiler(null, "narrative context");
        compiler.proto.numParams = cast(int) names.length + 1;
        compiler.enterScope();
        compiler.addLocal("@world");
        foreach (name; names)
            compiler.markReadOnly(compiler.addLocal(name));
        foreach (name; groundedNames)
            compiler.groundedLogicParameters[name] = true;
        compiler.narrativeContext = true;
        compiler.compileBlock(body);
        compiler.emit(OpCode.Return, 0, 1);
        compiler.exitScope();
        return compiler.proto;
    }

    private bool inNarrativeContext() {
        return narrativeContext || (parent !is null && parent.inNarrativeContext());
    }

    /// Registers upvalues referenced by an assignment target in source order
    /// (targets are written before the values are evaluated in the bytecode).
    private void touchNames(Expr e) {
        if (auto v = as!VariableExpr(e)) {
            if (resolveLocal(v.name) < 0)
                resolveUpvalue(v.name);
        } else if (auto f = as!FieldExpr(e)) {
            touchNames(f.table);
        } else if (auto i = as!IndexExpr(e)) {
            touchNames(i.table);
            touchNames(i.key);
        }
    }

    /// An operand that is either a register or a constant-pool index (RK).
    private struct RK {
        int idx;
        bool isK;
        bool temp; // a register allocated for this operand
    }

    /// `v.f1.f2...` where `v` is a plain variable and there is at least one field access.
    private static bool isFieldChainOnVariable(Expr e) {
        auto f = as!FieldExpr(e);
        if (f is null || e.parenthesized)
            return false;
        return as!VariableExpr(f.table) !is null || isFieldChainOnVariable(f.table);
    }

    private static bool isConstantExpr(Expr e) {
        return as!LiteralIntExpr(e) !is null || as!LiteralFloatExpr(e) !is null || as!LiteralStringExpr(e) !is null ||
            as!LiteralNilExpr(e) !is null || as!LiteralBoolExpr(e) !is null;
    }

    private LuaValue constantValue(Expr e) {
        if (auto i = as!LiteralIntExpr(e))
            return LuaValue(i.value);
        if (auto f = as!LiteralFloatExpr(e))
            return LuaValue(f.value);
        if (auto str = as!LiteralStringExpr(e))
            return LuaValue(str.value);
        if (auto b = as!LiteralBoolExpr(e))
            return LuaValue(b.value);
        return luaNil();
    }

    /// Compiles an operand: constants become K operands, local variables are used in place,
    /// everything else is evaluated into a fresh temporary.
    private RK compileRK(Expr e, bool allowK = true) {
        if (allowK && isConstantExpr(e))
            return RK(addConstant(constantValue(e)), true, false);
        if (auto v = as!VariableExpr(e)) {
            int reg = resolveLocal(v.name);
            if (reg >= 0)
                return RK(reg, false, false);
        }
        int r = allocReg();
        compileExpr(e, r, 1);
        return RK(r, false, true);
    }

    private void freeRK(RK rk) {
        if (rk.temp)
            freeRegs(1);
    }

    private static bool targetsAreSafeLocalDest(Expr value) {
        if (value.parenthesized)
            return false;
        if (isConstantExpr(value) || as!VariableExpr(value) !is null || as!IndexExpr(value) !is null ||
                as!FieldExpr(value) !is null || as!UnaryExpr(value) !is null || as!FunctionDefExpr(value) !is null)
            return true;
        if (auto b = as!BinaryExpr(value)) {
            if (b.op == BinaryOp.And || b.op == BinaryOp.Or)
                return false;
            // A single operation reads its operands before writing the destination.
            return cast(BinaryExpr) b.left is null || b.op == BinaryOp.Concat || b.op == BinaryOp.Pow;
        }
        return false;
    }

    private struct AssignTarget {
        enum Kind {
            local,
            upvalue,
            global,
            index
        }

        Kind kind;
        int reg; // local register / upvalue index
        int nameK; // global name constant
        RK table; // index: table register
        RK key; // index: key operand
    }

    private AssignTarget prepareTarget(Expr target, bool copyLocals) {
        AssignTarget t;
        if (auto varExpr = as!VariableExpr(target)) {
            checkWritable(varExpr.name);
            int localReg = resolveLocal(varExpr.name);
            if (localReg >= 0) {
                t.kind = AssignTarget.Kind.local;
                t.reg = localReg;
                return t;
            }
            int upval = resolveUpvalue(varExpr.name);
            if (upval >= 0) {
                t.kind = AssignTarget.Kind.upvalue;
                t.reg = upval;
                return t;
            }
            t.kind = AssignTarget.Kind.global;
            t.nameK = addConstant(LuaValue(varExpr.name));
            return t;
        }
        t.kind = AssignTarget.Kind.index;
        Expr tableExpr, keyExpr = null;
        string fieldName;
        if (auto indexExpr = as!IndexExpr(target)) {
            tableExpr = indexExpr.table;
            keyExpr = indexExpr.key;
        } else if (auto fieldExpr = as!FieldExpr(target)) {
            tableExpr = fieldExpr.table;
            fieldName = fieldExpr.field;
        } else
            throw fail("syntax error");
        t.table = compileRK(tableExpr, false);
        if (copyLocals && !t.table.temp) {
            int copy = allocReg();
            emit(OpCode.Move, copy, t.table.idx);
            t.table = RK(copy, false, true);
        }
        if (keyExpr is null)
            t.key = RK(addConstant(LuaValue(fieldName)), true, false);
        else {
            t.key = compileRK(keyExpr);
            if (copyLocals && !t.key.isK && !t.key.temp) {
                int copy = allocReg();
                emit(OpCode.Move, copy, t.key.idx);
                t.key = RK(copy, false, true);
            }
        }
        return t;
    }

    private void storeTarget(AssignTarget t, RK value) {
        final switch (t.kind) {
        case AssignTarget.Kind.local:
            if (value.isK) {
                // Constants are loaded straight into the local.
                emitLoadConstant(t.reg, value.idx);
            } else if (value.idx != t.reg)
                emit(OpCode.Move, t.reg, value.idx);
            break;
        case AssignTarget.Kind.upvalue: {
                int src = value.idx;
                bool loaded;
                if (value.isK) {
                    src = allocReg();
                    emitLoadConstant(src, value.idx);
                    loaded = true;
                }
                emit(OpCode.SetUpval, src, t.reg);
                if (loaded)
                    freeRegs(1);
                break;
            }
        case AssignTarget.Kind.global: {
                emit(OpCode.SetGlobal, value.idx, t.nameK, environmentOperand());
                proto.code[$ - 1].aIsK = value.isK;
                break;
            }
        case AssignTarget.Kind.index: {
                emit(OpCode.SetTable, t.table.idx, t.key.idx, value.idx);
                proto.code[$ - 1].bIsK = t.key.isK;
                proto.code[$ - 1].cIsK = value.isK;
                break;
            }
        }
    }

    private void emitLoadConstant(int reg, int constantIndex) {
        auto k = proto.constants[constantIndex];
        if (isNil(k))
            emit(OpCode.LoadNil, reg, 0);
        else if (k.typeOf() == LuaType.Boolean)
            emit(OpCode.LoadBool, reg, isTruthy(k) ? 1 : 0, 0);
        else if (isInteger(k) && k.match!((long i) => i, _ => 0L) >= -32768 && k.match!((long i) => i, _ => 0L) <= 32767)
            emit(OpCode.LoadInt, reg, 0, 0, cast(int) k.match!((long i) => i, _ => 0L));
        else
            emit(OpCode.LoadK, reg, constantIndex);
    }

    private void compileAssign(AssignStmt s) {
        foreach (target; s.targets)
            touchNames(target);
        int startFree = freeReg;
        scope (exit)
            freeReg = startFree;

        // Single assignment: the fast and most common case.
        if (s.targets.length == 1 && s.values.length == 1 && !isVarargOrCall(s.values[0])) {
            auto target = s.targets[0];
            auto value = s.values[0];
            auto prepared = prepareTarget(target, false);
            if (prepared.kind == AssignTarget.Kind.local && targetsAreSafeLocalDest(value)) {
                compileExpr(value, prepared.reg, 1);
                return;
            }
            RK rk = compileRK(value);
            if (value.lastTokenLine > 0)
                currentLine = value.lastTokenLine;
            storeTarget(prepared, rk);
            return;
        }

        // General case: evaluate target operands first, then all values, then store right to left
        // (the order C Lua uses).
        bool anyLocalTarget = false;
        foreach (target; s.targets)
            if (auto v = as!VariableExpr(target))
                if (resolveLocal(v.name) >= 0)
                    anyLocalTarget = true;
        AssignTarget[] prepared;
        foreach (target; s.targets)
            prepared ~= prepareTarget(target, anyLocalTarget);

        int[] valRegs;
        if (s.values.length > 0) {
            for (size_t i = 0; i + 1 < s.values.length; ++i) {
                int r = allocReg();
                compileExpr(s.values[i], r, 1);
                valRegs ~= r;
            }

            size_t lastIdx = s.values.length - 1;
            auto lastVal = s.values[lastIdx];
            if (lastIdx < s.targets.length && isVarargOrCall(lastVal)) {
                int needed = cast(int)(s.targets.length - lastIdx);
                int firstR = allocReg();
                for (int k = 1; k < needed; ++k)
                    allocReg();
                compileExpr(lastVal, firstR, needed);
                for (int k = 0; k < needed; ++k)
                    valRegs ~= (firstR + k);
            } else {
                int r = allocReg();
                compileExpr(lastVal, r, 1);
                valRegs ~= r;
            }
        }

        if (s.values.length && s.values[$ - 1].lastTokenLine > 0)
            currentLine = s.values[$ - 1].lastTokenLine;
        // Values beyond the targets were evaluated for their side effects; missing values are nil.
        foreach_reverse (i, target; prepared) {
            int rVal;
            if (i < valRegs.length)
                rVal = valRegs[i];
            else {
                rVal = allocReg();
                emit(OpCode.LoadNil, rVal, 0);
            }
            storeTarget(target, RK(rVal, false, false));
        }
    }

    private void compileReturn(ReturnStmt s) {
        bool canTailCall = transactionDepth == 0;
        foreach (local; locals)
            if (local.isClose)
                canTailCall = false;
        if (canTailCall && s.values.length == 1 && !s.values[0].parenthesized &&
                (as!CallExpr(s.values[0]) !is null || as!MethodCallExpr(s.values[0]) !is null)) {
            compileExpr(s.values[0], freeReg, -1);
            assert(proto.code[$ - 1].op == OpCode.Call);
            proto.code[$ - 1].op = OpCode.TailCall;
            return;
        }
        if (s.values.length == 1 && as!VariableExpr(s.values[0]) !is null && resolveLocal(
                (as!VariableExpr(s.values[0])).name) >= 0) {
            if (s.values[0].lastTokenLine > 0)
                currentLine = s.values[0].lastTokenLine;
            emit(OpCode.Return, resolveLocal((as!VariableExpr(s.values[0])).name), 2);
        } else if (s.values.length == 0) {
            emit(OpCode.Return, 0, 1); // 0 values
        } else {
            int startReg = freeReg;
            for (size_t i = 0; i + 1 < s.values.length; ++i) {
                int r = allocReg();
                compileExpr(s.values[i], r, 1);
            }

            auto lastVal = s.values[$ - 1];
            if (isVarargOrCall(lastVal)) {
                // Multi-result return
                compileExpr(lastVal, freeReg, -1);
                emit(OpCode.Return, startReg, 0); // 0 means return up to top
            } else {
                int r = allocReg();
                compileExpr(lastVal, r, 1);
                emit(OpCode.Return, startReg, cast(int) s.values.length + 1);
                freeRegs(cast(int) s.values.length);
            }
        }
    }

    /// Emits code that jumps (to be patched) when the truth value of `e` equals `jumpIf`
    /// and falls through otherwise. Returns the jumps to patch.
    private int[] condJump(Expr e, bool jumpIf) {
        if (auto u = as!UnaryExpr(e)) {
            if (u.op == UnaryOp.Not)
                return condJump(u.expr, !jumpIf);
        }
        if (auto b = as!BinaryExpr(e)) {
            if (b.op == BinaryOp.And || b.op == BinaryOp.Or) {
                bool isAnd = b.op == BinaryOp.And;
                // For "a and b" jumping when false: both operands jump when false.
                // For "a or b" jumping when true: both operands jump when true.
                if (isAnd != jumpIf) {
                    auto first = condJump(b.left, jumpIf);
                    return first ~ condJump(b.right, jumpIf);
                }
                // "a and b" jumping when true: skip over when a is false, jump when b is true.
                auto skip = condJump(b.left, !jumpIf);
                auto result = condJump(b.right, jumpIf);
                foreach (j; skip)
                    patchJump(j, currentPc());
                return result;
            }
            if (b.op == BinaryOp.Eq || b.op == BinaryOp.Ne || b.op == BinaryOp.Lt || b.op == BinaryOp.Le ||
                    b.op == BinaryOp.Gt || b.op == BinaryOp.Ge) {
                return compileComparisonJump(b, jumpIf);
            }
        }
        // Constants decide at compile time.
        if (as!LiteralNilExpr(e) !is null || as!LiteralBoolExpr(e) !is null || isConstantExpr(e)) {
            bool truthy = !(as!LiteralNilExpr(e) !is null) && !(as!LiteralBoolExpr(e) !is null && !(
                    as!LiteralBoolExpr(e)).value);
            if (truthy == jumpIf)
                return [emitJump()];
            return [];
        }
        RK rk = compileRK(e, false);
        int j = emitJump(OpCode.Test, rk.idx);
        proto.code[j].c = jumpIf ? 1 : 0;
        freeRK(rk);
        return [j];
    }

    private int[] compileComparisonJump(BinaryExpr b, bool jumpIf) {
        RK left = compileRK(b.left);
        RK right = compileRK(b.right);
        if (b.loc.line > 0)
            currentLine = b.loc.line;
        OpCode op = OpCode.Eq;
        bool swap = false;
        bool negate = false;
        switch (b.op) {
        case BinaryOp.Eq:
            op = OpCode.Eq;
            break;
        case BinaryOp.Ne:
            op = OpCode.Eq;
            negate = true;
            break;
        case BinaryOp.Lt:
            op = OpCode.Lt;
            break;
        case BinaryOp.Le:
            op = OpCode.Le;
            break;
        case BinaryOp.Gt:
            op = OpCode.Lt;
            swap = true;
            break;
        case BinaryOp.Ge:
            op = OpCode.Le;
            swap = true;
            break;
        default:
            break;
        }
        RK first = swap ? right : left;
        RK second = swap ? left : right;
        int flag = (jumpIf != negate) ? 1 : 0;
        emit(op, first.idx, second.idx, flag);
        proto.code[$ - 1].aIsK = first.isK;
        proto.code[$ - 1].bIsK = second.isK;
        int j = emitJump();
        freeRK(right);
        freeRK(left);
        return [j];
    }

    private void patchAll(int[] jumps, int target) {
        foreach (j; jumps)
            patchJump(j, target);
    }

    private void compileIf(IfStmt s) {
        int[] endJumps;

        foreach (branchIndex, branch; s.branches) {
            auto falseJumps = condJumpAt(branch.condition, branch.thenLine);

            enterScope();
            compileBlock(branch.body);
            exitScope();

            bool last = branchIndex + 1 == s.branches.length && s.elseBody is null;
            if (!last)
                endJumps ~= emitJump(OpCode.Jmp);
            patchAll(falseJumps, currentPc());
        }

        if (s.elseBody !is null) {
            enterScope();
            compileBlock(s.elseBody);
            exitScope();
        }

        int endPc = currentPc();
        foreach (j; endJumps) {
            patchJump(j, endPc);
        }
    }

    /// Condition jump whose instructions carry the line of `line` (the 'then' token).
    private int[] condJumpAt(Expr cond, int line) {
        int start = currentPc();
        auto jumps = condJump(cond, false);
        if (line > 0) {
            // Compare/test/jump instructions belong to the 'then' line; operand loads keep theirs.
            foreach (pc; start .. currentPc()) {
                auto op = proto.code[pc].op;
                if (op == OpCode.Test || op == OpCode.Jmp || op == OpCode.Eq || op == OpCode.Lt || op == OpCode.Le)
                    proto.code[pc].line = line;
            }
        }
        return jumps;
    }

    private void compileWhile(WhileStmt s) {
        loopCloseRegisters ~= freeReg;
        scope (exit)
            loopCloseRegisters.length--;
        loopDepth++;
        size_t prevBreaks = loopBreakJumps.length;

        int startPc = currentPc();
        auto exitJumps = condJump(s.condition, false);

        enterScope();
        compileBlock(s.body);
        exitScope();

        emit(OpCode.Jmp, 0, 0, 0, startPc - currentPc() - 1);
        patchAll(exitJumps, currentPc());

        // Patch breaks
        while (loopBreakJumps.length > prevBreaks) {
            patchJump(loopBreakJumps[$ - 1], currentPc());
            loopBreakJumps = loopBreakJumps[0 .. $ - 1];
        }

        loopDepth--;
    }

    private void compileRepeat(RepeatStmt s) {
        loopCloseRegisters ~= freeReg;
        scope (exit)
            loopCloseRegisters.length--;
        loopDepth++;
        size_t prevBreaks = loopBreakJumps.length;

        int startPc = currentPc();
        enterScope();
        // The condition is still inside the body's local scope.
        compileBlock(s.body, false);

        int rCond = allocReg();
        compileExpr(s.condition, rCond, 1);
        exitScope();

        // If condition is false, jump back to start
        int jmpLoop = emitJump(OpCode.Test, rCond);
        proto.code[jmpLoop].c = 0;
        patchJump(jmpLoop, startPc);
        freeRegs(1);

        // Patch breaks
        while (loopBreakJumps.length > prevBreaks) {
            patchJump(loopBreakJumps[$ - 1], currentPc());
            loopBreakJumps = loopBreakJumps[0 .. $ - 1];
        }

        loopDepth--;
    }

    private void compileForNumeric(ForNumericStmt s) {
        loopCloseRegisters ~= freeReg;
        scope (exit)
            loopCloseRegisters.length--;
        loopDepth++;
        size_t prevBreaks = loopBreakJumps.length;

        enterScope();
        // 3 internal registers for loop control: (init, limit, step)
        int rBase = allocReg();
        compileExpr(s.start, rBase, 1);
        int rLimit = allocReg();
        compileExpr(s.limit, rLimit, 1);
        int rStep = allocReg();
        if (s.step !is null) {
            compileExpr(s.step, rStep, 1);
        } else {
            emit(OpCode.LoadInt, rStep, 0, 0, 1);
        }

        foreach (reg; rBase .. rBase + 3) {
            locals ~= LocalVar("(for state)", reg, currentScopeDepth);
            proto.debugLocals ~= DebugLocal("(for state)", reg, currentPc(), int.max, currentScopeDepth);
        }
        enterScope();
        // Visible loop variable
        int rVar = addLocal(s.varName);

        if (s.loc.line > 0)
            currentLine = s.loc.line;
        int prepPc = emit(OpCode.ForPrep, rBase);
        int loopBodyPc = currentPc();
        proto.debugLocals[$ - 1].startPC = loopBodyPc;

        compileBlock(s.body);
        exitScope();

        if (s.loc.line > 0)
            currentLine = s.loc.line;
        int loopPc = emit(OpCode.ForLoop, rBase);
        patchJump(loopPc, loopBodyPc);
        patchJump(prepPc, loopPc + 1);

        exitScope();

        // Patch breaks
        while (loopBreakJumps.length > prevBreaks) {
            patchJump(loopBreakJumps[$ - 1], currentPc());
            loopBreakJumps = loopBreakJumps[0 .. $ - 1];
        }

        loopDepth--;
    }

    private void compileForGeneric(ForGenericStmt s) {
        loopCloseRegisters ~= freeReg;
        scope (exit)
            loopCloseRegisters.length--;
        loopDepth++;
        size_t prevBreaks = loopBreakJumps.length;

        enterScope();
        // Lua 5.4 iterator tuple: generator, state, control, closing value.
        int rBase = allocReg();
        allocReg();
        allocReg();
        allocReg();
        emit(OpCode.LoadNil, rBase, 3);
        foreach (i, expression; s.iterators) {
            if (i < 4) {
                int wanted = i + 1 == s.iterators.length && isVarargOrCall(expression) ? 4 - cast(int) i : 1;
                compileExpr(expression, rBase + cast(int) i, wanted);
            } else {
                int discarded = allocReg();
                compileExpr(expression, discarded, 0);
                freeRegs(1);
            }
        }
        foreach (reg; rBase .. rBase + 4) {
            locals ~= LocalVar("(for state)", reg, currentScopeDepth, false, reg == rBase + 3);
            proto.debugLocals ~= DebugLocal("(for state)", reg, currentPc(), int.max, currentScopeDepth);
        }
        emit(OpCode.ToClose, rBase + 3);
        enterScope();
        // Visible variables
        int[] varRegs;
        foreach (name; s.varNames) {
            varRegs ~= addLocal(name);
        }

        int jmpStart = emitJump(OpCode.Jmp);
        int loopBodyPc = currentPc();
        foreach (ref local; proto.debugLocals)
            if (local.depth == currentScopeDepth && local.endPC == int.max)
                local.startPC = loopBodyPc;

        compileBlock(s.body);
        exitScope();

        patchJump(jmpStart, currentPc());
        if (s.iterators.length && s.iterators[0].loc.line > 0)
            currentLine = s.iterators[0].loc.line;
        emit(OpCode.TForCall, rBase, 0, cast(int) varRegs.length);
        int tforLoopPc = emit(OpCode.TForLoop, rBase + 2);
        patchJump(tforLoopPc, loopBodyPc);

        exitScope();

        while (loopBreakJumps.length > prevBreaks) {
            patchJump(loopBreakJumps[$ - 1], currentPc());
            loopBreakJumps = loopBreakJumps[0 .. $ - 1];
        }

        loopDepth--;
    }

    private void compileFunctionDecl(FunctionDeclStmt s) {
        if (s.isLocal) {
            int localReg = addLocal(s.localName);
            compileFunctionDef(s.def, localReg);
            proto.debugLocals[$ - 1].startPC = currentPc();
            return;
        }

        int r = allocReg();
        compileFunctionDef(s.def, r);

        if (auto varExpr = as!VariableExpr(s.target)) {
            checkWritable(varExpr.name);
            int localReg = resolveLocal(varExpr.name);
            if (localReg >= 0) {
                emit(OpCode.Move, localReg, r);
            } else {
                int upval = resolveUpvalue(varExpr.name);
                if (upval >= 0) {
                    emit(OpCode.SetUpval, r, upval);
                } else {
                    int k = addConstant(LuaValue(varExpr.name));
                    emit(OpCode.SetGlobal, r, k, environmentOperand());
                }
            }
        } else if (auto fieldExpr = as!FieldExpr(s.target)) {
            int rTable = allocReg();
            compileExpr(fieldExpr.table, rTable, 1);
            int kField = addConstant(LuaValue(fieldExpr.field));
            int rKey = allocReg();
            emit(OpCode.LoadK, rKey, kField);
            emit(OpCode.SetTable, rTable, rKey, r);
            freeRegs(2);
        }

        freeRegs(1);
    }

    // -------------------------------------------------------------------------
    // Expression Compilation
    // -------------------------------------------------------------------------

    void compileExpr(Expr expr, int targetReg, int numResults = 1) {
        if (expr is null)
            return;
        if (expr.loc.line > 0)
            currentLine = expr.loc.line;

        if (as!LiteralNilExpr(expr)) {
            emit(OpCode.LoadNil, targetReg, 0);
            return;
        }

        if (auto b = as!LiteralBoolExpr(expr)) {
            emit(OpCode.LoadBool, targetReg, b.value ? 1 : 0, 0);
            return;
        }

        if (auto i = as!LiteralIntExpr(expr)) {
            if (i.value >= -32768 && i.value <= 32767) {
                emit(OpCode.LoadInt, targetReg, 0, 0, cast(int) i.value);
            } else {
                int k = addConstant(LuaValue(i.value));
                emit(OpCode.LoadK, targetReg, k);
            }
            return;
        }

        if (auto f = as!LiteralFloatExpr(expr)) {
            int k = addConstant(LuaValue(f.value));
            emit(OpCode.LoadK, targetReg, k);
            return;
        }

        if (auto s = as!LiteralStringExpr(expr)) {
            int k = addConstant(LuaValue(s.value));
            emit(OpCode.LoadK, targetReg, k);
            return;
        }

        if (as!VarargExpr(expr)) {
            emit(OpCode.Vararg, targetReg, numResults + 1);
            return;
        }

        if (auto v = as!VariableExpr(expr)) {
            int localReg = resolveLocal(v.name);
            if (localReg >= 0) {
                emit(OpCode.Move, targetReg, localReg);
            } else {
                int upval = resolveUpvalue(v.name);
                if (upval >= 0) {
                    emit(OpCode.GetUpval, targetReg, upval);
                } else {
                    int k = addConstant(LuaValue(v.name));
                    emit(OpCode.GetGlobal, targetReg, k, environmentOperand());
                }
            }
            return;
        }

        if (auto t = as!TableConstructorExpr(expr)) {
            emit(OpCode.NewTable, targetReg);
            {
                int listItems, keyedFields;
                foreach (fi, f; t.fields) {
                    if (f.key !is null)
                        ++keyedFields;
                    else if (fi + 1 < t.fields.length || !isVarargOrCall(f.value))
                        ++listItems;
                }
                if (listItems > 0x7fff)
                    listItems = 0x7fff;
                if (keyedFields > 0xffff)
                    keyedFields = 0xffff;
                if (listItems || keyedFields)
                    proto.tableSizeHints[cast(int) proto.code.length - 1] = (listItems << 16) | keyedFields;
            }
            long listIdx = 1;
            for (size_t fi = 0; fi < t.fields.length; ++fi) {
                auto f = t.fields[fi];
                if (fi == t.fields.length - 1 && f.key is null && isVarargOrCall(f.value)) {
                    // Multi-result last list item: expands to all values into table!
                    int rStart = freeReg;
                    compileExpr(f.value, rStart, -1);
                    emit(OpCode.SetList, targetReg, rStart, cast(int) listIdx);
                } else {
                    if (f.key is null) {
                        // List item: t[listIdx] = val
                        RK value = compileRK(f.value);
                        emit(OpCode.SetTable, targetReg, addConstant(LuaValue(listIdx++)), value.idx);
                        proto.code[$ - 1].bIsK = true;
                        proto.code[$ - 1].cIsK = value.isK;
                        freeRK(value);
                    } else {
                        RK key = compileRK(f.key);
                        RK value = compileRK(f.value);
                        emit(OpCode.SetTable, targetReg, key.idx, value.idx);
                        proto.code[$ - 1].bIsK = key.isK;
                        proto.code[$ - 1].cIsK = value.isK;
                        freeRK(value);
                        freeRK(key);
                    }
                }
            }
            return;
        }

        if (auto idx = as!IndexExpr(expr)) {
            RK table = compileRK(idx.table, false);
            RK key = compileRK(idx.key);
            if (idx.lastTokenLine > 0)
                currentLine = idx.lastTokenLine;
            emit(OpCode.GetTable, targetReg, table.idx, key.idx);
            proto.code[$ - 1].cIsK = key.isK;
            freeRK(key);
            freeRK(table);
            return;
        }

        if (auto f = as!FieldExpr(expr)) {
            if (isFieldChainOnVariable(f.table)) {
                // a.b.c.d: evaluate the chain in the target register itself, like luac, instead of
                // one temporary per level.
                compileExpr(f.table, targetReg, 1);
                int kChain = addConstant(LuaValue(f.field));
                if (f.lastTokenLine > 0)
                    currentLine = f.lastTokenLine;
                emit(OpCode.GetTable, targetReg, targetReg, kChain);
                proto.code[$ - 1].cIsK = true;
                return;
            }
            RK table = compileRK(f.table, false);
            int kField = addConstant(LuaValue(f.field));
            if (f.lastTokenLine > 0)
                currentLine = f.lastTokenLine;
            emit(OpCode.GetTable, targetReg, table.idx, kField);
            proto.code[$ - 1].cIsK = true;
            freeRK(table);
            return;
        }

        if (auto call = as!CallExpr(expr)) {
            // Put callee and arguments starting at a new block of registers; a call whose
            // result goes to the top temporary can use that register as its base (like luac).
            bool reuseBase = targetReg == freeReg - 1 && numResults == 1;
            int rCall = reuseBase ? targetReg : allocReg();
            compileExpr(call.callee, rCall, 1);
            for (size_t i = 0; i + 1 < call.args.length; ++i) {
                int rArg = allocReg();
                compileExpr(call.args[i], rArg, 1);
            }
            int bArg;
            if (call.args.length > 0) {
                auto lastArg = call.args[$ - 1];
                if (isVarargOrCall(lastArg)) {
                    compileExpr(lastArg, freeReg, -1);
                    bArg = 0; // variable arguments to top of stack
                } else {
                    int rArg = allocReg();
                    compileExpr(lastArg, rArg, 1);
                    bArg = cast(int) call.args.length + 1;
                }
            } else {
                bArg = 1;
            }
            if (numResults > 0 && rCall + numResults > proto.maxStackSize) {
                proto.maxStackSize = rCall + numResults;
            }
            int cArg = (numResults < 0) ? 0 : (numResults + 1);
            if (call.loc.line > 0)
                currentLine = call.loc.line;
            emitCall(rCall, bArg, cArg, call.callee);
            if (numResults > 0) {
                for (int res = 0; res < numResults; ++res) {
                    if (targetReg + res != rCall + res) {
                        emit(OpCode.Move, targetReg + res, rCall + res);
                    }
                }
            }
            freeRegs((bArg == 0 ? cast(int) call.args.length : cast(int) call.args.length + 1) - (reuseBase ? 1 : 0));
            return;
        }

        if (auto mCall = as!MethodCallExpr(expr)) {
            bool reuseBase = targetReg == freeReg - 1 && numResults == 1;
            int rCall = reuseBase ? targetReg : allocReg();
            // The receiver lands in rCall+1 (the 'self' slot) unless it already is a local variable.
            RK receiver = compileRK(mCall.receiver, false);
            if (!receiver.temp)
                allocReg();
            int kMethod = addConstant(LuaValue(mCall.method));
            if (mCall.nameLine > 0)
                currentLine = mCall.nameLine;
            emit(OpCode.Self, rCall, receiver.idx, kMethod);
            proto.code[$ - 1].cIsK = true;

            // Self placed method in rCall, and receiver in rCall+1
            // Now evaluate arguments starting at rCall+2
            for (size_t i = 0; i + 1 < mCall.args.length; ++i) {
                int rArg = allocReg();
                compileExpr(mCall.args[i], rArg, 1);
            }
            int bArg;
            if (mCall.args.length > 0) {
                auto lastArg = mCall.args[$ - 1];
                if (isVarargOrCall(lastArg)) {
                    compileExpr(lastArg, freeReg, -1);
                    bArg = 0; // variable arguments to top of stack
                } else {
                    int rArg = allocReg();
                    compileExpr(lastArg, rArg, 1);
                    bArg = cast(int) mCall.args.length + 2;
                }
            } else {
                bArg = 2; // self only
            }
            if (numResults > 0 && rCall + numResults > proto.maxStackSize) {
                proto.maxStackSize = rCall + numResults;
            }
            int cArg = (numResults < 0) ? 0 : (numResults + 1);
            if (mCall.argsLine > 0)
                currentLine = mCall.argsLine;
            emitCall(rCall, bArg, cArg, null, mCall.method);
            if (numResults > 0) {
                for (int res = 0; res < numResults; ++res) {
                    if (targetReg + res != rCall + res) {
                        emit(OpCode.Move, targetReg + res, rCall + res);
                    }
                }
            }
            freeRegs((bArg == 0 ? cast(int) mCall.args.length + 1 : cast(int) mCall.args.length + 2) - (reuseBase ? 1
                    : 0));
            return;
        }

        if (auto b = as!BinaryExpr(expr)) {
            compileBinary(b, targetReg);
            return;
        }

        if (auto u = as!UnaryExpr(expr)) {
            compileUnary(u, targetReg);
            return;
        }

        if (auto fn = as!FunctionDefExpr(expr)) {
            compileFunctionDef(fn, targetReg);
            return;
        }

        if (auto sym = as!SymbolLiteralExpr(expr)) {
            int k = addConstant(LuaValue(sym.name));
            emit(OpCode.LoadSymbol, targetReg, k);
            return;
        }

        if (auto q = as!QueryExpr(expr)) {
            compileQuery(q, targetReg);
            return;
        }

        if (auto lv = as!LogicVarExpr(expr)) {
            if (lv.isAnonymous) {
                throw new LuaException("anonymous variable '?_' not permitted in procedural guard");
            }
            int localReg = resolveLocal(lv.name);
            if (localReg >= 0) {
                emit(OpCode.Move, targetReg, localReg);
                return;
            }
            int upvalue = resolveUpvalue(lv.name);
            if (upvalue >= 0) {
                emit(OpCode.GetUpval, targetReg, upvalue);
                return;
            }
            throw new LuaException(format("logic variable '?%s' not bound", lv.name));
        }

        throw new LuaException("unsupported expression type");
    }

    private static bool isComparison(BinaryOp op) {
        return op == BinaryOp.Eq || op == BinaryOp.Ne || op == BinaryOp.Lt || op == BinaryOp.Le ||
            op == BinaryOp.Gt || op == BinaryOp.Ge;
    }

    /// 1 for a constant that is always true, 0 for nil/false, -1 otherwise (luaK_goiftrue/goiffalse).
    private static int constantTruth(Expr e) {
        if (as!LiteralNilExpr(e) !is null)
            return 0;
        if (auto lb = as!LiteralBoolExpr(e))
            return lb.value ? 1 : 0;
        if (as!LiteralIntExpr(e) !is null || as!LiteralFloatExpr(e) !is null || as!LiteralStringExpr(e) !is null)
            return 1;
        return -1;
    }

    private void compileBinary(BinaryExpr b, int targetReg) {
        // As in lcode.c, `K and x` and `nil/false or x` need no test: the result is `x`.
        if ((b.op == BinaryOp.And && constantTruth(b.left) == 1) || (b.op == BinaryOp.Or && constantTruth(b.left) == 0)) {
            compileExpr(b.right, targetReg, 1);
            return;
        }
        if (b.op == BinaryOp.And) {
            compileExpr(b.left, targetReg, 1);
            int jmpFalse = emitJump(OpCode.TestSet, targetReg);
            proto.code[jmpFalse].b = targetReg;
            proto.code[jmpFalse].c = 0; // jump if false
            compileExpr(b.right, targetReg, 1);
            patchJump(jmpFalse, currentPc());
            return;
        }

        if (b.op == BinaryOp.Or) {
            compileExpr(b.left, targetReg, 1);
            int jmpTrue = emitJump(OpCode.TestSet, targetReg);
            proto.code[jmpTrue].b = targetReg;
            proto.code[jmpTrue].c = 1; // jump if true
            compileExpr(b.right, targetReg, 1);
            patchJump(jmpTrue, currentPc());
            return;
        }

        if (isComparison(b.op)) {
            // Value form of a comparison: compare, then materialize the Boolean.
            RK left = compileRK(b.left);
            RK right = compileRK(b.right);
            if (b.loc.line > 0)
                currentLine = b.loc.line;
            OpCode op = (b.op == BinaryOp.Eq || b.op == BinaryOp.Ne) ? OpCode.Eq
                : (b.op == BinaryOp.Lt || b.op == BinaryOp.Gt) ? OpCode.Lt : OpCode.Le;
            bool swap = b.op == BinaryOp.Gt || b.op == BinaryOp.Ge;
            RK first = swap ? right : left, second = swap ? left : right;
            emit(op, first.idx, second.idx, b.op == BinaryOp.Ne ? 0 : 1);
            proto.code[$ - 1].aIsK = first.isK;
            proto.code[$ - 1].bIsK = second.isK;
            emit(OpCode.Jmp, 0, 0, 0, 1);
            emit(OpCode.LoadBool, targetReg, 0, 1); // R[target] = false, skip next
            emit(OpCode.LoadBool, targetReg, 1, 0); // R[target] = true
            freeRK(right);
            freeRK(left);
            return;
        }

        // Arithmetic, bitwise and concatenation. Left-associative chains are evaluated
        // iteratively so that only the accumulator and one operand are live.
        BinaryExpr[] spine;
        Expr leftmost = b;
        while (auto inner = as!BinaryExpr(leftmost)) {
            if (inner.op == BinaryOp.And || inner.op == BinaryOp.Or || isComparison(inner.op))
                break;
            if (inner !is b && (inner.op == BinaryOp.Concat || inner.op == BinaryOp.Pow))
                break;
            spine ~= inner;
            leftmost = inner.left;
            if (inner.op == BinaryOp.Concat || inner.op == BinaryOp.Pow)
                break;
        }
        int rAcc = targetReg;
        int accStart = currentPc();
        RK left = compileRK(leftmost);
        lazyOperandLine(accStart, leftmost, spine[$ - 1].loc.line);
        bool first = true;
        foreach_reverse (node; spine) {
            int rightStart = currentPc();
            RK right = compileRK(node.right);
            lazyRightLine(rightStart, node.right);
            if (node.loc.line > 0)
                currentLine = node.loc.line;
            emitBinaryOp(node.op, rAcc, left, right);
            freeRK(right);
            if (first) {
                freeRK(left);
                first = false;
            }
            left = RK(rAcc, false, false);
        }
    }

    /// True for operands that C Lua discharges lazily (variables, indexing, constants).
    private static bool isLazyOperand(Expr e) {
        return as!VariableExpr(e) !is null || as!IndexExpr(e) !is null || as!FieldExpr(e) !is null ||
            as!LiteralIntExpr(e) !is null || as!LiteralFloatExpr(e) !is null || as!LiteralStringExpr(e) !is null ||
            as!LiteralNilExpr(e) !is null || as!LiteralBoolExpr(e) !is null;
    }

    private static bool containsCall(Expr e) {
        if (auto i = as!IndexExpr(e))
            return containsCall(i.table) || containsCall(i.key);
        if (auto f = as!FieldExpr(e))
            return containsCall(f.table);
        return as!CallExpr(e) !is null || as!MethodCallExpr(e) !is null || as!BinaryExpr(e) !is null || as!UnaryExpr(e) !is null;
    }

    /// The left operand of a binary operator is discharged after the operator token was read.
    private void lazyOperandLine(int startPc, Expr operand, int operatorLine) {
        if (operatorLine <= 0 || !isLazyOperand(operand) || containsCall(operand))
            return;
        foreach (pc; startPc .. currentPc())
            proto.code[pc].line = operatorLine;
    }

    /// Loads of the right operand carry the line of its last token.
    private void lazyRightLine(int startPc, Expr operand) {
        if (operand.lastTokenLine <= 0 || !isLazyOperand(operand) || containsCall(operand))
            return;
        foreach (pc; startPc .. currentPc())
            proto.code[pc].line = operand.lastTokenLine;
    }

    private void emitBinaryOp(BinaryOp op, int dest, RK left, RK right) {
        OpCode code;
        switch (op) {
        case BinaryOp.Add:
            code = OpCode.Add;
            break;
        case BinaryOp.Sub:
            code = OpCode.Sub;
            break;
        case BinaryOp.Mul:
            code = OpCode.Mul;
            break;
        case BinaryOp.Div:
            code = OpCode.Div;
            break;
        case BinaryOp.IDiv:
            code = OpCode.IDiv;
            break;
        case BinaryOp.Mod:
            code = OpCode.Mod;
            break;
        case BinaryOp.Pow:
            code = OpCode.Pow;
            break;
        case BinaryOp.BAnd:
            code = OpCode.BAnd;
            break;
        case BinaryOp.BOr:
            code = OpCode.BOr;
            break;
        case BinaryOp.BXor:
            code = OpCode.BXor;
            break;
        case BinaryOp.Shl:
            code = OpCode.Shl;
            break;
        case BinaryOp.Shr:
            code = OpCode.Shr;
            break;
        default:
            code = OpCode.Concat;
            break;
        }
        emit(code, dest, left.idx, right.idx);
        proto.code[$ - 1].bIsK = left.isK;
        proto.code[$ - 1].cIsK = right.isK;
    }

    private void compileUnary(UnaryExpr u, int targetReg) {
        // Negative numeric literals are constants.
        if (u.op == UnaryOp.Neg && !u.expr.parenthesized) {
            if (auto i = as!LiteralIntExpr(u.expr)) {
                emitLoadConstant(targetReg, addConstant(LuaValue(cast(long)(0UL - cast(ulong) i.value))));
                return;
            }
            if (auto f = as!LiteralFloatExpr(u.expr)) {
                emitLoadConstant(targetReg, addConstant(LuaValue(-f.value)));
                return;
            }
        }
        RK operand = compileRK(u.expr, false);
        if (u.loc.line > 0)
            currentLine = u.loc.line;
        switch (u.op) {
        case UnaryOp.Neg:
            emit(OpCode.Unm, targetReg, operand.idx);
            break;
        case UnaryOp.Not:
            emit(OpCode.Not, targetReg, operand.idx);
            break;
        case UnaryOp.Len:
            emit(OpCode.Len, targetReg, operand.idx);
            break;
        case UnaryOp.BitNot:
            emit(OpCode.BNot, targetReg, operand.idx);
            break;
        default:
            break;
        }
        freeRK(operand);
    }

    private void compileFunctionDef(FunctionDefExpr fn, int targetReg) {
        auto subCompiler = new Compiler(this, "anonymous");
        subCompiler.proto.sourceName = proto.sourceName;
        subCompiler.proto.lineDefined = fn.loc.line;
        subCompiler.proto.lastLineDefined = fn.endLine;
        subCompiler.proto.numParams = cast(int) fn.params.length;
        subCompiler.proto.isVararg = fn.isVararg;

        subCompiler.enterScope();
        foreach (p; fn.params) {
            subCompiler.addLocal(p);
        }
        subCompiler.compileBlock(fn.body);
        subCompiler.currentLine = fn.endLine;
        subCompiler.emit(OpCode.Return, 0, 1); // default return
        subCompiler.exitScope();

        if (fn.endLine > 0)
            currentLine = fn.endLine;
        proto.subPrototypes ~= subCompiler.proto;
        int subIdx = cast(int)(proto.subPrototypes.length - 1);
        emit(OpCode.Closure, targetReg, subIdx);
    }

    // -------------------------------------------------------------------------
    // Declarative Extensions Compilation Helpers
    // -------------------------------------------------------------------------

    private void compileWorldPath(string[] worldPath, int targetReg) {
        if (worldPath.length == 0)
            return;
        string first = worldPath[0];
        int locReg = resolveLocal(first);
        if (locReg >= 0) {
            emit(OpCode.Move, targetReg, locReg);
        } else {
            int upval = resolveUpvalue(first);
            if (upval >= 0) {
                emit(OpCode.GetUpval, targetReg, upval);
            } else {
                int k = addConstant(LuaValue(first));
                emit(OpCode.GetGlobal, targetReg, k, environmentOperand());
            }
        }

        for (size_t i = 1; i < worldPath.length; ++i) {
            int kField = addConstant(LuaValue(worldPath[i]));
            int rKey = allocReg();
            emit(OpCode.LoadK, rKey, kField);
            emit(OpCode.GetTable, targetReg, targetReg, rKey);
            freeRegs(1);
        }
    }

    private ContentTemplate compileContent(NarrativeDefinitionStmt definition, string[] incoming, ref int[] registers) {
        auto template_ = new ContentTemplate();
        template_.kind = definition.kind;
        template_.id = definition.name;
        template_.parameters = definition.parameters.dup;
        template_.incomingParameters = incoming.dup;
        foreach (goal; definition.goals) {
            if (auto atom = as!AstRelAtomGoal(goal)) {
                if (!atom.isNegated)
                    foreach (term; atom.terms)
                        if (auto variable = as!LogicVarExpr(term))
                            template_.groundedParameters ~= variable.name;
            } else if (auto aggregate = as!AstAggregateGoal(goal))
                template_.groundedParameters ~= aggregate.resultVariable;
        }
        foreach (i, field; definition.fieldNames) {
            int register = allocReg();
            registers ~= register;
            compileExpr(definition.fieldValues[i], register, 1);
            template_.optionNames ~= field;
            template_.optionRegisters ~= register;
        }
        void compileContext(BlockStmt body, string[] names, string[] correlated, ref int destination) {
            auto compiler = new Compiler(this, definition.kind ~ ":" ~ definition.name);
            compiler.narrativeContext = true;
            compiler.groundedLogicParameters = null;
            foreach (name; correlated)
                compiler.groundedLogicParameters[name] = true;
            compiler.proto.numParams = cast(int) names.length + 1;
            compiler.enterScope();
            compiler.addLocal("@world");
            foreach (name; names)
                compiler.markReadOnly(compiler.addLocal(name));
            compiler.compileBlock(body);
            compiler.emit(OpCode.Return, 0, 1);
            compiler.exitScope();
            proto.subPrototypes ~= compiler.proto;
            destination = allocReg();
            registers ~= destination;
            emit(OpCode.Closure, destination, cast(int) proto.subPrototypes.length - 1);
        }

        if (definition.goals.length) {
            auto query = new QueryExpr(definition.goals, true, definition.loc);
            auto body = new BlockStmt([cast(Stmt) new ReturnStmt([cast(Expr) query], definition.loc)], definition.loc);
            compileContext(body, incoming, incoming, template_.availabilityRegister);
        }
        if (definition.effect !is null)
            compileContext(definition.effect, incoming ~ definition.parameters, [], template_.effectRegister);
        foreach (choice; definition.choices)
            template_.choices ~= compileContent(choice, definition.parameters, registers);
        return template_;
    }

    private void compileFact(FactStmt s) {
        compileFactOrRetract(s.relRef, s.args, true);
    }

    private void compileRetract(RetractStmt s) {
        compileFactOrRetract(s.relRef, s.args, false);
    }

    private void compileFactOrRetract(AstRelRef relRef, Expr[] args, bool isAdd, OpCode overrideOp = OpCode.Nop) {
        OpCode op = overrideOp == OpCode.Nop ? (isAdd ? OpCode.AddFact : OpCode.RetractFact) : overrideOp;
        int[] argRegs;
        foreach (arg; args) {
            int r = allocReg();
            compileExpr(arg, r, 1);
            argRegs ~= r;
        }
        int rFirstArg = (argRegs.length > 0) ? argRegs[0] : 0;
        int numArgs = cast(int) argRegs.length;

        if (relRef.worldPath.length > 0) {
            int rWorld = allocReg();
            compileWorldPath(relRef.worldPath, rWorld);
            int kName = addConstant(LuaValue(relRef.name));
            emit(op, rWorld, kName, rFirstArg, numArgs);
            freeRegs(1);
        } else {
            int localRelReg = inNarrativeContext() ? -1 : resolveLocal("@rel:" ~ relRef.name);
            if (localRelReg >= 0) {
                emit(op, -2, localRelReg, rFirstArg, numArgs);
            } else {
                int upvalIdx = inNarrativeContext() ? -1 : resolveUpvalue("@rel:" ~ relRef.name);
                if (upvalIdx >= 0) {
                    int rTemp = allocReg();
                    emit(OpCode.GetUpval, rTemp, upvalIdx);
                    emit(op, -2, rTemp, rFirstArg, numArgs);
                    freeRegs(1);
                } else {
                    int kName = addConstant(LuaValue(relRef.name));
                    int wReg = resolveLocal("@world");
                    if (wReg >= 0) {
                        emit(op, wReg, kName, rFirstArg, numArgs);
                    } else {
                        int wUpval = resolveUpvalue("@world");
                        if (wUpval >= 0) {
                            int rW = allocReg();
                            emit(OpCode.GetUpval, rW, wUpval);
                            emit(op, rW, kName, rFirstArg, numArgs);
                            freeRegs(1);
                        } else {
                            emit(op, -1, kName, rFirstArg, numArgs);
                        }
                    }
                }
            }
        }

        freeRegs(numArgs);
    }

    private void emitCall(int callee, int arguments, int results, Expr expression = null, string method = "") {
        CallName identity;
        if (method.length)
            identity = CallName(method, "method");
        else if (auto variable = as!VariableExpr(expression)) {
            identity = CallName(variable.name, resolveLocal(variable.name) >= 0 ? "local" : resolveUpvalue(
                    variable.name) >= 0 ? "upvalue" : "global");
        } else if (auto field = as!FieldExpr(expression))
            identity = CallName(field.field, "field");
        else if (auto index = as!IndexExpr(expression)) {
            auto key = as!LiteralStringExpr(index.key);
            identity = CallName(key is null ? "?" : key.value, "field");
        }
        if (identity.kind.length)
            proto.callNames[currentPc()] = identity;
        int world = resolveLocal("@world");
        int context;
        if (world >= 0)
            context = world + 1;
        else {
            int upvalue = resolveUpvalue("@world");
            if (upvalue >= 0)
                context = -(upvalue + 1);
        }
        proto.callWorlds[cast(int) proto.code.length] = context;
        emit(OpCode.Call, callee, arguments, results);
    }

    private void compileRelationDecl(RelationDeclStmt s) {
        if (s.arity < 0)
            throw new LuaException("relation arity must be nonnegative");
        int kName = addConstant(LuaValue(s.name));
        int schemaIndex;
        if (s.named) {
            proto.relationSchemas ~= RelationSchemaTemplate(s.columns.dup, s.keys.dup);
            schemaIndex = cast(int) proto.relationSchemas.length;
        }
        int wReg = resolveLocal("@world");
        if (wReg >= 0) {
            emit(OpCode.DeclRel, wReg, kName, s.arity, schemaIndex);
        } else {
            int wUpval = resolveUpvalue("@world");
            if (wUpval >= 0) {
                int rW = allocReg();
                emit(OpCode.GetUpval, rW, wUpval);
                emit(OpCode.DeclRel, rW, kName, s.arity, schemaIndex);
                freeRegs(1);
            } else {
                emit(OpCode.DeclRel, -1, kName, s.arity, schemaIndex);
            }
        }
    }

    private void compileLocalRelationDecl(LocalRelationDeclStmt s) {
        if (s.arity < 0)
            throw new LuaException("relation arity must be nonnegative");
        int rRel = allocReg();
        int kName = addConstant(LuaValue(s.name));
        int wReg = resolveLocal("@world");
        int worldArg = -1;
        if (wReg >= 0) {
            worldArg = wReg;
        } else {
            int wUpval = resolveUpvalue("@world");
            if (wUpval >= 0) {
                int rW = allocReg();
                emit(OpCode.GetUpval, rW, wUpval);
                worldArg = rW;
            }
        }
        emit(OpCode.NewLocalRel, rRel, kName, s.arity, worldArg);
        if (worldArg >= 0 && worldArg != wReg) {
            freeRegs(1);
        }
        locals ~= LocalVar("@rel:" ~ s.name, rRel, currentScopeDepth);
        proto.debugLocals ~= DebugLocal("@rel:" ~ s.name, rRel, currentPc(), int.max, currentScopeDepth);
    }

    private void compileWorldBlock(WorldBlockStmt s) {
        enterScope();
        int rWorld = allocReg();
        compileExpr(s.worldExpr, rWorld, 1);
        locals ~= LocalVar("@world", rWorld, currentScopeDepth);
        proto.debugLocals ~= DebugLocal("@world", rWorld, currentPc(), int.max, currentScopeDepth);
        compileBlock(s.body);
        exitScope();
    }

    private TermTemplate compileTermTemplate(Expr expr, ref int[string] varMap, ref string[] varNames, ref int[] constRegs) {
        TermTemplate tt;
        if (auto lv = as!LogicVarExpr(expr)) {
            if (lv.name in groundedLogicParameters) {
                int register = allocReg();
                constRegs ~= register;
                compileExpr(new VariableExpr(lv.name, lv.loc), register, 1);
                tt.kind = TermKind.Constant;
                tt.reg = register;
                return tt;
            }
            if (lv.isAnonymous) {
                tt.kind = TermKind.Anonymous;
            } else {
                tt.kind = TermKind.Variable;
                tt.varName = lv.name;
                if (lv.name !in varMap) {
                    varMap[lv.name] = cast(int) varNames.length;
                    varNames ~= lv.name;
                }
                tt.varId = varMap[lv.name];
            }
        } else {
            int r = allocReg();
            constRegs ~= r;
            compileExpr(expr, r, 1);
            tt.kind = TermKind.Constant;
            tt.reg = r;
        }
        return tt;
    }

    private void collectGuardVars(Expr expr, ref string[] varNames) {
        if (expr is null)
            return;
        if (auto lv = as!LogicVarExpr(expr)) {
            if (lv.name in groundedLogicParameters)
                return;
            if (lv.isAnonymous) {
                throw new LuaException("anonymous variable '?_' not permitted in procedural guard");
            }
            import std.algorithm : canFind;

            if (!varNames.canFind(lv.name)) {
                varNames ~= lv.name;
            }
            return;
        }
        if (auto u = as!UnaryExpr(expr)) {
            collectGuardVars(u.expr, varNames);
            return;
        }
        if (auto b = as!BinaryExpr(expr)) {
            collectGuardVars(b.left, varNames);
            collectGuardVars(b.right, varNames);
            return;
        }
        if (auto call = as!CallExpr(expr)) {
            collectGuardVars(call.callee, varNames);
            foreach (arg; call.args)
                collectGuardVars(arg, varNames);
            return;
        }
        if (auto mcall = as!MethodCallExpr(expr)) {
            collectGuardVars(mcall.receiver, varNames);
            foreach (arg; mcall.args)
                collectGuardVars(arg, varNames);
            return;
        }
        if (auto idx = as!IndexExpr(expr)) {
            collectGuardVars(idx.table, varNames);
            collectGuardVars(idx.key, varNames);
            return;
        }
        if (auto f = as!FieldExpr(expr)) {
            collectGuardVars(f.table, varNames);
            return;
        }
        if (auto tc = as!TableConstructorExpr(expr)) {
            foreach (field; tc.fields) {
                if (field.key !is null)
                    collectGuardVars(field.key, varNames);
                collectGuardVars(field.value, varNames);
            }
            return;
        }
    }

    private void resolveGoalRel(AstRelRef relRef, ref GoalTemplate gt, ref int[] constRegs, int defaultWorldReg = -1) {
        if (relRef.worldPath.length > 0) {
            int rWorld = allocReg();
            constRegs ~= rWorld;
            compileWorldPath(relRef.worldPath, rWorld);
            gt.worldReg = rWorld;
        } else {
            int localRel = inNarrativeContext() ? -1 : resolveLocal("@rel:" ~ relRef.name);
            if (localRel >= 0) {
                gt.localRelReg = localRel;
            } else {
                int upval = inNarrativeContext() ? -1 : resolveUpvalue("@rel:" ~ relRef.name);
                if (upval >= 0) {
                    int rTempReg = allocReg();
                    constRegs ~= rTempReg;
                    emit(OpCode.GetUpval, rTempReg, upval);
                    gt.localRelReg = rTempReg;
                } else {
                    if (defaultWorldReg >= 0) {
                        gt.worldReg = defaultWorldReg;
                    } else {
                        int wReg = resolveLocal("@world");
                        if (wReg >= 0) {
                            gt.worldReg = wReg;
                        } else {
                            int wUpval = resolveUpvalue("@world");
                            if (wUpval >= 0) {
                                int rW = allocReg();
                                constRegs ~= rW;
                                emit(OpCode.GetUpval, rW, wUpval);
                                gt.worldReg = rW;
                            } else {
                                gt.worldReg = -1;
                            }
                        }
                    }
                }
            }
        }
    }

    private void compileRuleDecl(RuleDeclStmt s) {
        auto rTemp = new RuleTemplate();
        int[] constRegs;
        int[string] varMap;
        string[] varNames;

        // Head terms
        rTemp.headRelName = s.headRel.name;
        rTemp.headRelWorldPath = s.headRel.worldPath;
        rTemp.headArity = cast(int) s.headArgs.length;
        foreach (arg; s.headArgs) {
            rTemp.headTerms ~= compileTermTemplate(arg, varMap, varNames, constRegs);
        }

        // Head relation resolution
        if (s.headRel.worldPath.length > 0) {
            int rWorld = allocReg();
            constRegs ~= rWorld;
            compileWorldPath(s.headRel.worldPath, rWorld);
            rTemp.headWorldReg = rWorld;
        } else {
            int localRel = resolveLocal("@rel:" ~ s.headRel.name);
            if (localRel >= 0) {
                rTemp.headLocalRelReg = localRel;
            } else {
                int upval = resolveUpvalue("@rel:" ~ s.headRel.name);
                if (upval >= 0) {
                    int rTempReg = allocReg();
                    constRegs ~= rTempReg;
                    emit(OpCode.GetUpval, rTempReg, upval);
                    rTemp.headLocalRelReg = rTempReg;
                } else {
                    int wReg = resolveLocal("@world");
                    if (wReg >= 0) {
                        rTemp.headWorldReg = wReg;
                    } else {
                        int wUpval = resolveUpvalue("@world");
                        if (wUpval >= 0) {
                            int rW = allocReg();
                            constRegs ~= rW;
                            emit(OpCode.GetUpval, rW, wUpval);
                            rTemp.headWorldReg = rW;
                        } else {
                            rTemp.headWorldReg = -1;
                        }
                    }
                }
            }
        }

        int defaultWorldReg = (s.headRel.worldPath.length > 0) ? rTemp.headWorldReg : -1;
        rTemp.bodyGoals = compileGoals(s.goals, varMap, varNames, constRegs, defaultWorldReg);

        rTemp.variableNames = varNames;
        rTemp.numVariables = cast(int) varNames.length;

        proto.ruleTemplates ~= rTemp;
        int templateIdx = cast(int)(proto.ruleTemplates.length - 1);
        emit(OpCode.RegRule, 0, templateIdx);
        freeRegs(cast(int) constRegs.length);
    }

    private GoalTemplate[] compileGoals(AstGoal[] goals, ref int[string] varMap,
            ref string[] varNames, ref int[] constRegs, int defaultWorldReg) {
        GoalTemplate[] templates;
        foreach (g; goals) {
            if (auto aggregate = as!AstAggregateGoal(g)) {
                GoalTemplate gt;
                gt.kind = GoalKind.Aggregate;
                gt.aggregateOp = aggregate.operation;
                gt.resultVariable = aggregate.resultVariable;
                if (aggregate.resultVariable !in varMap) {
                    varMap[aggregate.resultVariable] = cast(int) varNames.length;
                    varNames ~= aggregate.resultVariable;
                }
                auto innerMap = varMap.dup;
                auto innerNames = varNames.dup;
                gt.aggregateGoals = compileGoals(aggregate.goals, innerMap, innerNames, constRegs, defaultWorldReg);
                if (aggregate.expression !is null) {
                    collectGuardVars(aggregate.expression, gt.aggregateExpressionVariables);
                    auto subCompiler = new Compiler(this, "aggregate expression");
                    subCompiler.proto.numParams = cast(int) gt.aggregateExpressionVariables.length;
                    subCompiler.enterScope();
                    foreach (name; gt.aggregateExpressionVariables)
                        subCompiler.addLocal(name);
                    subCompiler.compileReturn(new ReturnStmt([aggregate.expression]));
                    subCompiler.exitScope();
                    proto.subPrototypes ~= subCompiler.proto;
                    gt.aggregateExpressionProto = cast(int) proto.subPrototypes.length - 1;
                }
                templates ~= gt;
            } else if (auto relAtom = as!AstRelAtomGoal(g)) {
                GoalTemplate gt;
                gt.kind = relAtom.isNegated ? GoalKind.NegatedAtom : GoalKind.PositiveAtom;
                gt.relName = relAtom.relRef.name;
                gt.worldPath = relAtom.relRef.worldPath;
                gt.arity = cast(int) relAtom.terms.length;
                foreach (term; relAtom.terms) {
                    gt.terms ~= compileTermTemplate(term, varMap, varNames, constRegs);
                }
                resolveGoalRel(relAtom.relRef, gt, constRegs, defaultWorldReg);
                templates ~= gt;
            } else if (auto comp = as!AstComparisonGoal(g)) {
                GoalTemplate gt;
                gt.kind = GoalKind.Comparison;
                gt.compOp = comp.op;
                gt.leftTerm = compileTermTemplate(comp.left, varMap, varNames, constRegs);
                gt.rightTerm = compileTermTemplate(comp.right, varMap, varNames, constRegs);
                templates ~= gt;
            } else if (auto guard = as!AstGuardGoal(g)) {
                GoalTemplate gt;
                gt.kind = GoalKind.Guard;
                string[] guardVars;
                collectGuardVars(guard.expr, guardVars);
                gt.guardVarNames = guardVars;

                auto subCompiler = new Compiler(this, "guard");
                subCompiler.proto.numParams = cast(int) guardVars.length;
                subCompiler.enterScope();
                foreach (p; guardVars) {
                    subCompiler.addLocal(p);
                }
                subCompiler.compileReturn(new ReturnStmt([guard.expr]));
                subCompiler.exitScope();
                proto.subPrototypes ~= subCompiler.proto;
                gt.guardSubProtoIdx = cast(int)(proto.subPrototypes.length - 1);
                templates ~= gt;
            }
        }

        return templates;
    }

    private void compileQuery(QueryExpr q, int targetReg) {
        auto qTemp = new QueryTemplate();
        qTemp.isBraced = q.isBraced;
        int[] constRegs;
        int[string] varMap;
        string[] varNames;

        qTemp.goals = compileGoals(q.goals, varMap, varNames, constRegs, -1);

        qTemp.returnedVarNames = varNames;

        proto.queryTemplates ~= qTemp;
        int qIdx = cast(int)(proto.queryTemplates.length - 1);
        emit(OpCode.MakeQuery, targetReg, qIdx);
        freeRegs(cast(int) constRegs.length);
    }
}
