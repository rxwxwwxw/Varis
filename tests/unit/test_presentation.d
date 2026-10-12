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
