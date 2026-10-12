-- Language is a view (localization plan §2): re-rendering a presentation in another language draws
-- no random number, issues no token, writes nothing, and falls back to the source as a whole.
relation ready(0)
relation here(room)
relation night(0)
fact ready()
fact here(:cottage)
narrative.name(:cottage, "the cottage")

storylet look(?room)
    when { ready(), here(?room) }
    title "Look around {room}"
    text [[You are in {room}.
{#if query night()}It is night.{#else}It is day.{/if}
{#variant 2}A cold wind.{#variant 1}Gulls overhead.{/variant}]]
    choice wait
        title "Wait a while"
        effect do end
    end
end
narrative.seal()

local s = narrative.new(logic.global)
s:seed(11)
local presentation = s:present()
local story = presentation.storylets[1]
assert(story.title == "Look around the cottage")
local source_text = story.text
local token = story.choices[1].token

-- A pack registers whole or not at all, and names the key and the language when it is rejected.
reject(function()
    narrative.translate("fr", { ["look.title"] = "Regarder {room}", ["look.text"] = "{#if query night()}Nuit" })
end, "fr look.text")
assert(#narrative.languages() == 0, "a rejected pack registers nothing")

narrative.translate("fr", {
    ["look.title"] = "Regarder autour de {room}",
    ["look.text"] = "Vous êtes à {room}.\n{#if query night()}Il fait nuit.{#else}Il fait jour.{/if}\n{#variant 2}Un vent froid.{#variant 1}Des mouettes.{/variant}",
    ["look.wait.title"] = "Attendre",
    ["name.cottage"] = "la chaumière",
})
assert(#narrative.languages() == 1 and narrative.languages()[1] == "fr")

local before = s:save()
local french = s:render(presentation, "fr")
assert(french.storylets[1].title == "Regarder autour de la chaumière", french.storylets[1].title)
assert(french.storylets[1].text:find("Il fait jour.", 1, true), "the captured condition is used")
assert(french.storylets[1].choices[1].title == "Attendre")
-- The same draw: option 1 of the source is option 1 of the translation.
local cold = source_text:find("A cold wind.", 1, true) ~= nil
assert((french.storylets[1].text:find("Un vent froid.", 1, true) ~= nil) == cold)
-- Nothing changed: no token, no draw, no write.
assert(s:save() == before)
assert(s:render(presentation, "").storylets[1].text == source_text)
assert(french.storylets[1].choices[1].token == token)

-- A translation that asks for a condition the source never evaluated falls back, as a whole.
narrative.translate("de", { ["look.text"] = "{#if query ready()}Bereit{/if}", ["look.title"] = "Schau {room}" })
local german = s:render(presentation, "de")
assert(german.storylets[1].text == source_text, "fallback is the whole source text")
assert(german.storylets[1].title == "Schau the cottage")

-- The language preference changes what present() renders, and nothing else.
s:set_language("fr")
assert(s:language() == "fr")
s:choose(token)
local second = s:present()
assert(second.storylets[1].title == "Regarder autour de la chaumière")
s:set_language(nil)
assert(s:language() == nil)
print("narrative_translation ok")
