/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Read-only expressions in a paused frame. Walk the frontend AST without calling Lua,
/// metamethods or the VM: even an apparently innocent operator may otherwise run author code.
module varis.workbench.inspect;

import varis.ast;
import varis.parser : Parser;
import varis.state : LuaState, CallInfo;
import varis.types;
import varis.vm : LuaClosure;
import varis.exception : LuaException;

private struct Inspector {
    LuaState state;
    CallInfo frame;
    string error;

    LuaValue fail(string message) {
        error = message;
        return LuaValue.init;
    }

    LuaValue named(string name) {
        LuaValue found;
        bool present;
        for (long i = 1;; ++i) {
            LuaValue value;
            auto local = frame.getLocal(i, value);
            if (local is null)
                break;
            if (local == name) {
                found = value;
                present = true; // the last active local shadows earlier ones, including nil
            }
        }
        if (present)
            return found;
        auto closure = cast(LuaClosure) frame.fn;
        LuaValue environment = LuaValue(state.globals);
        foreach (i, descriptor; closure.proto.upvalues) {
            if (i >= closure.upvalues.length || closure.upvalues[i] is null)
                continue;
            auto value = *closure.upvalues[i].ptr();
            if (descriptor.name == name)
                return value;
            if (descriptor.name == "_ENV")
                environment = value;
        }
        return environment.isTable ? environment.asTable.rawget(LuaValue(name)) : LuaValue.init;
    }

    LuaValue expression(Expr node, int depth = 0) {
        if (depth > 64)
            return fail("expression is nested too deeply");
        if (cast(LiteralNilExpr) node !is null)
            return LuaValue.init;
        if (auto value = cast(LiteralBoolExpr) node)
            return LuaValue(value.value);
        if (auto value = cast(LiteralIntExpr) node)
            return LuaValue(value.value);
        if (auto value = cast(LiteralFloatExpr) node)
            return LuaValue(value.value);
        if (auto value = cast(LiteralStringExpr) node)
            return LuaValue(value.value);
        if (auto value = cast(VariableExpr) node)
            return named(value.name);
        if (auto value = cast(SymbolLiteralExpr) node)
            return state.getSymbol(value.name);
        Expr table, key;
        string field;
        if (auto value = cast(FieldExpr) node) {
            table = value.table;
            field = value.field;
        } else if (auto value = cast(IndexExpr) node) {
            table = value.table;
            key = value.key;
        }
        if (table !is null) {
            auto object = expression(table, depth + 1);
            auto index = key is null ? LuaValue(field) : expression(key, depth + 1);
            if (error.length)
                return LuaValue.init;
            if (!object.isTable)
                return fail("read-only indexing requires a table; userdata and metamethods are not evaluated");
            return object.asTable.rawget(index);
        }
        if (auto value = cast(UnaryExpr) node) {
            auto operand = expression(value.expr, depth + 1);
            if (error.length)
                return LuaValue.init;
            if (value.op == UnaryOp.Not)
                return LuaValue(!operand.isTruthy());
            if (value.op == UnaryOp.Neg) {
                if (operand.isInteger)
                    return LuaValue(cast(long)(0UL - cast(ulong) operand.asInteger));
                if (operand.isFloat)
                    return LuaValue(-operand.asFloat);
            }
            if (value.op == UnaryOp.BitNot && operand.isInteger)
                return LuaValue(~operand.asInteger);
            if (value.op == UnaryOp.Len && operand.isString)
                return LuaValue(cast(long) operand.asString.length);
            return fail("operator is not supported for this value in read-only evaluation");
        }
        if (auto value = cast(BinaryExpr) node) {
            auto left = expression(value.left, depth + 1);
            if (error.length)
                return LuaValue.init;
            if ((value.op == BinaryOp.And && !left.isTruthy()) || (value.op == BinaryOp.Or && left.isTruthy()))
                return left;
            auto right = expression(value.right, depth + 1);
            if (error.length)
                return LuaValue.init;
            if (value.op == BinaryOp.And || value.op == BinaryOp.Or)
                return right;
            if (value.op == BinaryOp.Eq || value.op == BinaryOp.Ne)
                return LuaValue(value.op == BinaryOp.Eq ? luaRawEqual(left, right) : !luaRawEqual(left, right));
            if (value.op == BinaryOp.Concat && left.isString && right.isString)
                return LuaValue(left.asString ~ right.asString);
            if (left.isInteger && right.isInteger) {
                auto a = cast(ulong) left.asInteger, b = cast(ulong) right.asInteger;
                if (value.op == BinaryOp.Add)
                    return LuaValue(cast(long)(a + b));
                if (value.op == BinaryOp.Sub)
                    return LuaValue(cast(long)(a - b));
                if (value.op == BinaryOp.Mul)
                    return LuaValue(cast(long)(a * b));
            }
            if (left.isNumber && right.isNumber) {
                switch (value.op) {
                case BinaryOp.Lt:
                    return LuaValue(luaNumberLess(left, right));
                case BinaryOp.Le:
                    return LuaValue(luaNumberLessEqual(left, right));
                case BinaryOp.Gt:
                    return LuaValue(luaNumberLess(right, left));
                case BinaryOp.Ge:
                    return LuaValue(luaNumberLessEqual(right, left));
                default:
                    break;
                }
                double a = left.isInteger ? cast(double) left.asInteger : left.asFloat;
                double b = right.isInteger ? cast(double) right.asInteger : right.asFloat;
                switch (value.op) {
                case BinaryOp.Add:
                    return LuaValue(a + b);
                case BinaryOp.Sub:
                    return LuaValue(a - b);
                case BinaryOp.Mul:
                    return LuaValue(a * b);
                case BinaryOp.Div:
                    return LuaValue(a / b);
                default:
                    break;
                }
            }
            return fail("operator is not supported in read-only evaluation");
        }
        return fail("read-only evaluation allows values and operators, not calls, queries or assignments");
    }
}

/// No code is executed. Only locals, captured upvalues and raw global/table fields are read.
bool inspectExpression(LuaState state, long frameIndex, string text, out LuaValue value, out string error) {
    auto frames = state.callStack();
    if (frameIndex < 0 || frameIndex >= frames.length || cast(LuaClosure) frames[cast(size_t) frameIndex].fn is null) {
        error = "no paused Lua frame selected";
        return false;
    }
    Expr expression;
    try {
        auto block = new Parser("return " ~ text, "=inspect").parse();
        auto returned = block.statements.length == 1 ? cast(ReturnStmt) block.statements[0] : null;
        if (returned is null || returned.values.length != 1) {
            error = "enter one expression";
            return false;
        }
        expression = returned.values[0];
    } catch (LuaException failure) {
        error = failure.errorObject.isString ? failure.errorObject.asString : "invalid expression";
        return false;
    }
    Inspector inspector;
    inspector.state = state;
    inspector.frame = frames[cast(size_t) frameIndex];
    value = inspector.expression(expression);
    error = inspector.error;
    return error.length == 0;
}
