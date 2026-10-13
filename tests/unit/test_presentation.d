/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module tests.unit.test_presentation;
import varis.services.presentation;
import varis.services.gamehost;
import varis.narrative.scenes : nameOf, field;
import varis.types;
import tests.unit.unit_runner : UnitMain;

enum content = q"{
character mira {name="Mira", attributes={expression={:quiet,:smile}}, defaults={expression=:quiet}}
scene finish {{kind=:say, character=:mira, attributes={expression=:smile}, text="Hello {visitor}."}, {kind=:hide, character=:mira}, {kind=:ended}}
scene start {
 {kind=:background,tag=:harbour},
 {kind=:show,character=:mira,slot=:left},
 {kind=:input,["local"]="visitor",text="Name?"},
 {kind=:menu,choices={{id=:yes,text="Continue",target=:finish}}}
}
}";

@("typedSceneBoundary") unittest {
    auto host = new SceneHost;
    assert(host.loadContent(content, "host-test.lua", "start"), host.error);
    assert(host.view.kind == "background" && host.view.background == "harbour");
    string before, after;
    assert(host.save(before));
    assert(host.refresh());
    assert(host.save(after) && before == after); // Inspection is inert.
    assert(host.advance());
    assert(host.view.characters.length == 1 && host.view.characters[0].slot == "left");
    assert(nameOf(field(host.view.characters[0].attributes, "expression")) == "quiet");
    assert(host.advance() && host.view.kind == "input");
    assert(host.advance(LuaValue("Rowan")) && host.view.choices.length == 1);
    assert(host.save(before));
    assert(!host.advance(LuaValue(Symbol("invalid"))));
    assert(host.save(after) && before == after); // Invalid menu input is atomic.
    auto choice = host.view.choices[0].id;
    assert(host.advance(choice));
    assert(host.view.speaker == "Mira" && host.view.text == "Hello Rowan.");
    assert(nameOf(field(host.view.characters[0].attributes, "expression")) == "smile");
    assert(host.save(before));
    assert(host.advance() && host.view.characters.length == 0);
    assert(host.restore(before), host.error);
    assert(host.view.characters.length == 1 && host.view.text == "Hello Rowan.");
    assert(host.save(after) && before == after);
    assert(!host.restore("{}"));
    assert(host.save(after) && before == after); // Failed load retains the live session.
    assert(host.advance());
    assert(host.advance() && host.view.kind == "ended");
    assert(host.advance() && host.view.finished);
    assert(!host.advance());
}

@("hostErrorsAreStatuses") unittest {
    auto host = new SceneHost;
    string bytes;
    assert(!host.save(bytes) && !host.restore("{}") && !host.refresh() && !host.advance());
    assert(!host.loadContent("scene broken {", "broken.lua", "broken"));
    assert(host.error.length);
    assert(!host.loadContent(content, "host-test.lua", "missing"));
    assert(host.error.length);
    assert(host.loadContent(content, "host-test.lua", "start"));
    assert(host.save(bytes));
    assert(!host.loadContent(content, "host-test.lua", "missing"));
    string after;
    assert(host.save(after) && after == bytes);
}

mixin UnitMain;

@("gameHostHub") unittest {
    // The whole-game host over a project: scenes, the creation hub, the status panel, a gated
    // choice with its reason, saves, and the language switch. Run from the repository root.
    auto host = new GameHost;
    assert(host.loadProject("sample-rpg", "prologue"), host.error);
    assert(host.newGame(7), host.error);
    // Prologue: media beats, a name input, a menu, then the creation storylets.
    while (host.view.inScene) {
        auto kind = host.view.beat.kind;
        bool ok;
        if (kind == "input")
            ok = host.advance(LuaValue("Rowan"));
        else if (kind == "menu")
            ok = host.advance(host.view.beat.choices[0].id);
        else
            ok = host.advance();
        assert(ok, host.error);
    }
    import std.conv : to;

    assert(host.view.stories.length == 1 && host.view.stories[0].id == "family",
            host.view.stories.length.to!string ~ " " ~ (host.view.stories.length ? host.view.stories[0].id : "") ~ " " ~ host
            .error);
    assert(host.view.hud.length > 0 && host.view.values["strength"] == 15);
    // Inspection is inert: refreshing a scene boundary changes nothing; saving twice is stable.
    string first, second;
    assert(host.save(first) && host.save(second) && first == second);
    // Choosing: a family adds to the stats, and the toast says so.
    assert(host.choose(0, 0), host.error);
    assert(host.view.values["strength"] == 30);
    assert(host.view.stories[0].id == "temper");
    // A restored game continues from the same place.
    string saved;
    assert(host.save(saved) && host.restore(saved), host.error);
    assert(host.view.stories[0].id == "temper");
    // French changes words, not state.
    string english = host.view.stories[0].title;
    assert(host.setLanguage("fr"), host.error);
    assert(host.view.stories[0].title != english && host.view.stories[0].id == "temper");
    assert(host.setLanguage(""), host.error);
    assert(host.view.stories[0].title == english);
    assert(!host.choose(0, 99)); // No such choice: a status, not a throw.
}

@("sceneHostBack") unittest {
    auto host = new SceneHost;
    assert(host.loadContent(content, "host-test.lua", "start"), host.error);
    assert(!host.canBack() && !host.back());
    string before, after;
    assert(host.save(before));
    assert(host.advance() && host.advance() && host.view.kind == "input");
    assert(host.canBack());
    assert(host.advance(LuaValue("Rowan")) && host.view.kind == "menu");
    assert(host.back() && host.view.kind == "input");
    assert(host.advance(LuaValue("Ada")) && host.view.kind == "menu");
    assert(host.back() && host.back() && host.back());
    assert(host.view.kind == "background" && !host.canBack());
    assert(host.save(after) && before == after);
    assert(host.advance() && host.advance() && host.advance(LuaValue("Wren")));
    assert(host.advance(host.view.choices[0].id));
    assert(host.view.text == "Hello Wren.", host.view.text);
}

@("gameHostBack") unittest {
    auto host = new GameHost;
    assert(host.loadProject("sample-rpg", "prologue"), host.error);
    assert(host.newGame(7), host.error);
    assert(!host.canBack());
    while (host.view.inScene) {
        auto kind = host.view.beat.kind;
        bool ok;
        if (kind == "input")
            ok = host.advance(LuaValue("Rowan"));
        else if (kind == "menu")
            ok = host.advance(host.view.beat.choices[0].id);
        else
            ok = host.advance();
        assert(ok, host.error);
    }
    assert(host.canBack());
    auto first = host.view.stories[0].id;
    auto strength = host.view.values["strength"];
    assert(host.choose(0, 0), host.error);
    assert(host.view.stories[0].id != first || host.view.values["strength"] != strength);
    assert(host.back(), host.error);
    assert(host.view.stories[0].id == first && host.view.values["strength"] == strength);
    assert(host.choose(0, 0), host.error); // the restored token is usable again
}
