-- Plural and select branches (localization plan §3.3), named variants, and translations that use
-- the plural rules of their own language over the same captured presentation.
relation ready(0)
relation owner(who)
relation count(n)
fact ready()
fact owner(:keeper)
fact count(3)

-- Source templates: plural with the required `other`, select with the required `default`.
local w = logic.world()
local function t(text, bindings, selection) return narrative.template(text, bindings, w, selection) end
assert(t("{#plural n}{#one}one coin{#other}{n} coins{/plural}", {n = 1}) == "one coin")
assert(t("{#plural n}{#one}one coin{#other}{n} coins{/plural}", {n = 0}) == "0 coins")
assert(t("{#plural n}{#one}one coin{#other}{n} coins{/plural}", {n = 2.5}) == "2.5 coins")
assert(t("{#select who}{#case keeper}He{#case maid}She{#default}They{/select} waved", {who = :maid}) == "She waved")
assert(t("{#select who}{#case keeper}He{#case maid}She{#default}They{/select} waved", {who = :cat}) == "They waved")
assert(t("{#select who}{#case keeper}He{#default}They{/select}", {who = "keeper"}) == "He")
reject(function() t("{#plural n}{#one}x{/plural}", {n = 1}) end, "requires {#other}")
reject(function() t("{#select v}{#case a}x{/select}", {v = 1}) end, "requires {#default}")
reject(function() t("{#plural n}{#one}x{#one}y{#other}z{/plural}", {n = 1}) end, "appears twice")
reject(function() t("{#plural nope}{#other}x{/plural}", {n = 1}) end, "unknown narrative template placeholder")
-- A plural may sit inside a condition, and a placeholder inside a branch.
assert(t("{#if query ready()}{#plural n}{#one}a{#other}{n}b{/plural}{/if}", {n = 4}) == "4b")

-- Named variants: the name is what the replay log and translations call an alternative.
assert(t("{#variant 3 wind}Wind.{#variant 1 gulls}Gulls.{/variant}", {}, 1) == "Gulls.")
reject(function() t("{#variant weight=abc}x{/variant}", {}) end, "variant weight must be numeric")

storylet coins(?n)
    when { ready(), count(?n) }
    title "{#plural n}{#one}A coin{#other}{n} coins{/plural}"
    text "{#select n}{#case 3}Three{#default}Some{/select} counted. {#variant 1 wind}Wind.{#variant 1 gulls}Gulls.{/variant}"
    choice go
        title "Go"
        effect do end
    end
end

narrative.seal()

local s = narrative.new(logic.global)
s:seed(5)
local presentation = s:present()
local story = presentation.storylets[1]
assert(story.title == "3 coins", story.title)

-- Translations count in their own language, over the same presentation.
local ok = pcall(narrative.translate, "ru", {
    ["coins.title"] = "{#plural n}{#one}{n} монета{#few}{n} монеты{#many}{n} монет{#other}{n} монеты{/plural}",
    ["coins.text"] = "Сосчитано. {#variant gulls}Чайки.{#variant wind}Ветер.{/variant}",
})
assert(ok)
narrative.translate("fr", { ["coins.title"] = "{#plural n}{#one}{n} pièce{#other}{n} pièces{/plural}" })
narrative.translate("ja", { ["coins.title"] = "{#plural n}{#other}{n}枚{/plural}" })
assert(s:render(presentation, "ru").storylets[1].title == "3 монеты")
assert(s:render(presentation, "fr").storylets[1].title == "3 pièces")
assert(s:render(presentation, "ja").storylets[1].title == "3枚")
-- Named alternatives may be reordered by a translation: the drawn one is found by name.
local source = story.text
local wind = source:find("Wind.", 1, true) ~= nil
local russian = s:render(presentation, "ru").storylets[1].text
assert((russian:find("Ветер.", 1, true) ~= nil) == wind, russian)
-- A translation that renames an alternative falls back as a whole.
narrative.translate("de", { ["coins.text"] = "{#variant calm}Ruhe.{#variant storm}Sturm.{/variant}" })
assert(s:render(presentation, "de").storylets[1].text == source)
-- The replay log names the drawn alternative.
local log = s:replay_log()
local found = false
for i = 1, #log.inputs do
    local record = log.inputs[i]
    if record.kind == :variants then
        local entry = record.value[1]
        assert(entry.names ~= nil and (entry.names[1] == "wind" or entry.names[1] == "gulls"), "variant names are logged")
        found = true
    end
end
assert(found, "a variants record")
print("narrative_plural_select ok")
