/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.opcode;

import dlua.types : LuaValue;
import std.format : format;

/// Strongly typed bytecode instructions for dlua
enum OpCode {
    Nop = 0,
    Move,       // a, b          : R[a] = R[b]
    LoadNil,    // a, b          : R[a .. a+b] = nil
    LoadBool,   // a, b, c       : R[a] = bool(b); if (c) pc++
    LoadInt,    // a, sbx        : R[a] = sbx
    LoadK,      // a, bx         : R[a] = Constants[bx]

    GetGlobal,  // a, bx         : R[a] = Globals[Constants[bx]]
    SetGlobal,  // a, bx         : Globals[Constants[bx]] = R[a]

    GetUpval,   // a, b          : R[a] = Upvalues[b]
    SetUpval,   // a, b          : Upvalues[b] = R[a]

    GetTable,   // a, b, c       : R[a] = R[b][RK[c]]
    SetTable,   // a, b, c       : R[a][RK[b]] = RK[c]
    NewTable,   // a             : R[a] = new LuaTable()
    SetList,    // a, b, c       : set list elements in R[a] starting at index c from R[b .. top-1]
    Self,       // a, b, c       : R[a+1] = R[b]; R[a] = R[b][RK[c]]

    // Binary operations: R[a] = RK[b] op RK[c]
    Add, Sub, Mul, Mod, Pow, Div, IDiv,
    BAnd, BOr, BXor, Shl, Shr,
    Concat,     // a, b, c       : R[a] = R[b] .. ... .. R[c]

    // Unary operations: R[a] = op R[b]
    Unm, Not, Len, BNot,

    // Jumps & tests
    Jmp,        // sbx           : pc += sbx
    Eq,         // a, b, c       : if ((RK[a] == RK[b]) != c) pc++
    Lt,         // a, b, c       : if ((RK[a] < RK[b]) != c) pc++
    Le,         // a, b, c       : if ((RK[a] <= RK[b]) != c) pc++
    Test,       // a, c          : if (bool(R[a]) != c) pc++
    TestSet,    // a, b, c       : if (bool(R[b]) == c) R[a] = R[b] else pc++

    // Function calls & returns
    Call,       // a, b, c       : R[a .. a+c-2] = R[a](R[a+1 .. a+b-1])
    TailCall,   // a, b          : return R[a](R[a+1 .. a+b-1])
    Return,     // a, b          : return R[a .. a+b-2]

    // Loops
    ForPrep,    // a, sbx        : initialize numeric for; pc += sbx
    ForLoop,    // a, sbx        : step numeric for; if not done pc += sbx
    TForCall,   // a, c          : call iterator: R[a+3 .. a+2+c] = R[a](R[a+1], R[a+2])
    TForLoop,   // a, sbx        : if R[a+1] ~= nil R[a] = R[a+1]; pc += sbx

    // Closures and Upvalues
    Closure,    // a, bx         : R[a] = new closure from sub-prototype bx
    Vararg,     // a, b          : R[a .. a+b-2] = varargs
    Close,      // a             : close upvalues >= R[a]
    ToClose,    // a             : register R[a] as a to-be-closed value

    // Declarative Operations (Phase 6)
    LoadSymbol, // a, bx         : R[a] = interned symbol from Constants[bx]
    NewLocalRel,// a, bx, c      : R[a] = new LocalRelation(Constants[bx], c, fallbackWorld)
    DeclRel,    // a, bx, c      : declare relation Constants[bx] with arity c in world R[a]
    AddFact,    // a, b, c, sBx  : add fact: world R[a] (or -1), rel Constants[b] (or local R[b]), args R[c .. c+sBx-1]
    RetractFact,// a, b, c, sBx  : retract fact: world R[a] (or -1), rel Constants[b] (or local R[b]), args R[c .. c+sBx-1]
    SetFact,    // same operands as AddFact: replace a complete keyed tuple
    DeleteKey,  // same operands as AddFact: remove by key-declaration order
    AdjustKey,  // key arguments followed by one numeric delta
    BeginTransaction, // a: world register (-1 global), b: end PC, c: first scoped register
    EndTransaction,   // commit innermost transaction owned by this frame
    Rollback,         // discard innermost transaction and jump to its end PC
    DefineContent, DefineDeck,
    RegRule,    // a, bx         : register rule template bx using world R[a]
    MakeQuery   // a, bx         : R[a] = create query iterator from query template bx
}

import dlua.logic.model : CompareOp, TermKind, GoalKind;

/// Template for a relational term
struct TermTemplate {
    TermKind kind;
    string varName;
    int varId = -1;
    int reg = -1; // register where constant was evaluated
    LuaValue staticVal;
    bool isStatic = false;
}

/// Template for a goal in a rule or query body
struct GoalTemplate {
    GoalKind kind;
    string relName;
    string[] worldPath;
    int worldReg = -1;
    int localRelReg = -1;
    int localRelUpval = -1;
    int arity;
    TermTemplate[] terms;

    TermTemplate leftTerm;
    CompareOp compOp;
    TermTemplate rightTerm;

    string aggregateOp;
    string resultVariable;
    GoalTemplate[] aggregateGoals;
    int aggregateExpressionProto = -1;
    string[] aggregateExpressionVariables;

    int guardSubProtoIdx = -1;
    string[] guardVarNames;
    int[] guardVarIds;
}

/// Compiled immutable rule template attached to Prototype
class RuleTemplate {
    string headRelName;
    string[] headRelWorldPath;
    int headWorldReg = -1;
    int headLocalRelReg = -1;
    int headLocalRelUpval = -1;
    int headArity;
    TermTemplate[] headTerms;
    GoalTemplate[] bodyGoals;
    int numVariables;
    string[] variableNames;
}

/// Compiled immutable query template attached to Prototype
class QueryTemplate {
    GoalTemplate[] goals;
    string[] returnedVarNames;
    bool isBraced;
}

/// An instruction struct with register addresses and constant flags
struct Instruction {
    OpCode op;
    int a = 0;
    int b = 0;
    int c = 0;
    int sBx = 0;
    int line = 0;

    // Bit flags to indicate if a, b or c is a constant index (RK[a], RK[b], RK[c])
    bool aIsK = false;
    bool bIsK = false;
    bool cIsK = false;
    private ubyte[4] padding;   // keeps instructions at 32 bytes so indexing is a shift

    string toString() const {
        return format("Instruction(%s, a=%d, b=%d%s, c=%d%s, sBx=%d, line=%d)",
            op, a, b, bIsK ? "(K)" : "", c, cIsK ? "(K)" : "", sBx, line);
    }
}

/// Description of an upvalue captured by a function prototype
struct UpvalDesc {
    string name;
    bool inStack; // true if in enclosing function's stack, false if outer upvalue
    int index;    // stack register index or outer upvalue index
}

/// Registration descriptors reference evaluated fields and compiled closures.
class ContentTemplate {
    string kind;
    string id;
    string[] parameters;
    string[] incomingParameters;
    string[] groundedParameters;
    string[] optionNames;
    int[] optionRegisters;
    int availabilityRegister = -1;
    int effectRegister = -1;
    ContentTemplate[] choices;
}

/// Immutable named-schema metadata stored in a compiled prototype.
struct RelationSchemaTemplate {
    string[] columns;
    string[] keys;
}

/// Authored local's live instruction range (end is exclusive).
struct DebugLocal {
    string name;
    int register;
    int startPC;
    int endPC = int.max;
    int depth;
    bool readOnly;
}

struct CallName { string name; string kind; }

/// A compiled Lua function prototype
class Prototype {
    RelationSchemaTemplate[] relationSchemas;
    ContentTemplate[] contentTemplates;
    Instruction[] code;
    int[] liveTop;  // per instruction: registers >= liveTop[pc] hold no live values (int.max = unknown)
    private Instruction[] codeBuffer;   // spare capacity behind `code` while it is being compiled
    private int[] liveBuffer;

    /// Appends an instruction and its live-register bound. Slice appends cost a runtime block-info
    /// lookup each; the compiler emits one instruction at a time, so capacity is managed here.
    void pushInstruction(ref const Instruction instr, int live) {
        size_t used = code.length;
        if (used == codeBuffer.length || codeBuffer.ptr !is code.ptr) {
            size_t capacity = used < 8 ? 16 : used * 2;
            auto grown = new Instruction[capacity];
            grown[0 .. used] = code[];
            codeBuffer = grown;
            auto liveGrown = new int[capacity];
            liveGrown[0 .. liveTop.length] = liveTop[];
            liveBuffer = liveGrown;
        }
        codeBuffer[used] = instr;
        liveBuffer[used] = live;
        code = codeBuffer[0 .. used + 1];
        liveTop = liveBuffer[0 .. used + 1];
    }
    DebugLocal[] debugLocals;
    // Call PC -> lexical world: register+1, -(upvalue+1), or 0 for global.
    int[int] callWorlds;
    CallName[int] callNames;
    int[] lookupHints;                  // per-pc inline-cache node hints (see LuaTable.findStringHinted)

    /// Dense per-pc view of `callNames` and `callWorlds`, built once before first execution.
    struct CallSite {
        string name;
        string kind;
        int world;          // register+1, -(upvalue+1), or 0 for the global world
    }
    CallSite[] callSites;
    /// Table-constructor sizes by NewTable pc: (array items << 16) | keyed fields, both capped. Kept out
    /// of the instruction operands so code fingerprints and dumps are unaffected.
    int[int] tableSizeHints;
    uint[] newTableSizes;     // dense per-pc copy, built before first execution
    size_t[] constantHashes;  // hashOf of string constants (0 otherwise), for hashed table lookups
    Instruction[] execCode;   // `code` plus a guaranteed final Return, run by the interpreter loop
    bool prepared;      // sentinel Return appended and callSites built (see VM.prepareForExecution)

    void buildCallSites() {
        auto table = new CallSite[code.length];
        foreach (pc, identity; callNames)
            if (pc >= 0 && pc < table.length) { table[pc].name = identity.name; table[pc].kind = identity.kind; }
        foreach (pc, world; callWorlds)
            if (pc >= 0 && pc < table.length) table[pc].world = world;
        callSites = table;
    }
    LuaValue[] constants;
    Prototype[] subPrototypes;
    UpvalDesc[] upvalues;

    RuleTemplate[] ruleTemplates;
    QueryTemplate[] queryTemplates;

    int numParams = 0;
    bool isVararg = false;
    int maxStackSize = 2;
    string sourceName = "";
    string functionName = "";
    int lineDefined;
    int lastLineDefined;

    this() {}
}
