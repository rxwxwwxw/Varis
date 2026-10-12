/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module tools.sdl.main;

import tools.sdl.gameplayer : runGame;
import std.stdio : stderr;

/// `varis-sdl manifest.json [--smoke screenshot.bmp]`. The manifest names a scene-only game
/// (`content` and `scene`) or a whole game (`project`); both run in the one player.
int main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: varis-sdl manifest.json [--smoke screenshot.bmp]");
        return 1;
    }
    bool smoke = args.length == 4 && args[2] == "--smoke";
    try {
        return runGame(args[1], smoke ? args[3] : "");
    } catch (Exception error) {
        stderr.writeln(error.msg);
        return 1;
    }
}
