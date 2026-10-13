# Embedding Varis in a D host

This page is the contract for a program that runs a Varis game itself instead of using
`varis-sdl` (the SDL3 player is itself such a host: `tools/sdl/gameplayer.d`). It describes what
exists today in `varis.services.gamehost` and `varis.services.presentation`; the unit tests
`gameHostHub`, `gameHostBack` and `embeddingContract` in `tests/unit/test_presentation.d` run
every call shown here.

## Principles

- **Statuses, not exceptions.** Every operation that can fail returns `bool` (or fills an `out`
  value) and leaves the reason in `host.error`. The adapter catches the runtime's exceptions at
  its boundary. A failed operation leaves the session as it was.
- **Drawing is inert.** `host.view` is plain data. Reading it calls no engine code and consumes
  no random numbers, so it may be read every frame. Only `refresh`, `advance`, `choose`, `back`,
  `restore`, `setLanguage` and the battle calls run engine code, once per player action.
- **The host does not build tokens.** The adapter keeps the exact presentation token; the host
  passes a position (`choose(story, choice)`) or a menu id (`advance(choice.id)`).
- **One thread.** A `LuaState` is single-threaded. Run turns off the render thread only if the
  host never touches the host object concurrently.
- **Objects live on D's collector.** Tables, worlds and sessions are ordinary D references; the
  host holds them directly (`host.state`, `host.session`).

## The loop

```d
import varis;
import varis.services.gamehost;

auto host = new GameHost;
if (!host.loadProject("path/to/project", "prologue"))   // runs the entry module, seals content
    return report(host.error);
if (!host.newGame(seed))                                  // a new session at the initial scene
    return report(host.error);

for (;;) {
    if (host.view.inScene) {                              // a scene beat is current
        auto beat = host.view.beat;                       // kind: say, narrate, menu, input, ...
        draw(beat);                                       // text, speaker, background, characters
        if (beat.kind == "menu")
            ok = host.advance(beat.choices[picked].id);
        else if (beat.kind == "input")
            ok = host.advance(LuaValue(typedText));
        else
            ok = host.advance();
    } else {                                              // the storylet hub
        draw(host.view.stories, host.view.hud);
        ok = host.choose(storyIndex, choiceIndex);        // a disabled choice is refused with its reason
    }
    if (!ok) showMessage(host.error);
    foreach (t; host.takeToasts()) showToast(t.text, t.good);
    if (host.view.over) break;
    host.idle();                                          // after the frame: collect garbage if due
}
```

`view.stories[i].choices[j]` carries `title`, `text`, `enabled` and `because` (the rendered
reason when a `require` fails). `view.hud` lists the visible qualities with labels and bounds;
`view.values` has every numeric quality by name.

## Saves, undo, profile, language

| Call | Meaning |
| --- | --- |
| `save(out bytes)` / `restore(bytes)` | The engine save (format 3 when a scene is mid-way). `restore` of invalid or mismatched bytes fails and keeps the live session. Saving twice gives identical bytes. |
| `autosaveBytes(out bytes)` | Like `save`, but during a battle the world at the battle's start (no save inside a battle). |
| `canBack()` / `back()` | Take back the last choice or beat. `undoLimit` sets the depth (0 = off). Only the session is rolled back; state a project keeps in its own Lua tables is the project's to restore. |
| `profileSave(out text)` / `profileLoad(text)` | The cross-save profile (`narrative.profile_*`), kept by the host beside its saves. Never part of a save or replay. |
| `setLanguage(tag)` | Re-renders the current boundary in another language (empty tag: the source language). A view, never saved. Translation packs are loaded by the project. |
| `display(name)` | A symbol's display name in the current language. |
| `journal()`, `achievements()`, `mapState()` | Read-only lookups the project's hooks provide, on demand. |

## Scene-only content

`SceneHost` (`varis.services.presentation`) serves a single file of `scene` and `character`
declarations over an empty world: `loadContent(source, filename, "scene")`, then `view`,
`advance`, `back`, `save`, `restore`. `GameHost.loadScenes` is the same for a `GameHost`.

## Battles

A project that declares the battle hooks drives a battle through `GameHost`: `battlePhase`,
`battleCommand`, `battleBegin`, `battleAdvance(steps)`, `battleAccept`, `battleRetry`,
`battleAbandon`. See [battle.md](battle.md). The view of a running battle reads the simulation
directly (`host.battle`) and never writes it.

## What is not provided yet

- A stable, versioned embedding package or C ABI: today a host compiles against the D modules.
- Windows and Linux builds are unverified (see PERFORMANCE_PLAN stage M).
- Full presentation parity in the standard player (milestone 36's checklist).
