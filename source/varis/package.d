/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis;

public import varis.types;
public import varis.table;
public import varis.exception;
public import varis.state;
public import varis.ast;
public import varis.lexer;
public import varis.parser;
public import varis.opcode;
public import varis.compiler;
public import varis.vm;
public import varis.fiber;
public import varis.pattern;
public import varis.lib;
