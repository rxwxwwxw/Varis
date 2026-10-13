-- Text rules for presentation layers (localization plan §4, §5): Korean particles, graphemes,
-- line-break opportunities for CJK, and ruby spans.
assert(narrative.particle("사과", "을/를") == "를" and narrative.particle("책", "을/를") == "을")
assert(narrative.particle("서울", "으로/로") == "로", "a final ㄹ takes 로")
assert(narrative.particle("집", "으로/로") == "으로" and narrative.particle("바다", "으로/로") == "로")
assert(narrative.particle("철수", "은/는") == "는" and narrative.particle("민준", "은/는") == "은")
assert(narrative.particle("3", "이/가") == "이" and narrative.particle("4", "이/가") == "가")
assert(narrative.particle("「책」", "을/를") == "을", "closing quotes are looked through")

assert(narrative.graphemes("e\u{301}x") == 2, "a combining mark stays with its base")
assert(narrative.graphemes("한국어") == 3)
assert(narrative.graphemes("🇫🇷🇯🇵") == 2, "a flag is one grapheme")
assert(narrative.graphemes("👨‍👩‍👧") == 1, "a joined emoji is one grapheme")
assert(narrative.truncate("한국어 테스트", 3) == "한국어")
assert(narrative.truncate("e\u{301}abc", 1) == "e\u{301}", "never cuts a character in half")

local function breaks(s)
    local b, out = narrative.line_breaks(s), {}
    for i = 1, #b do out[#out + 1] = b[i] end
    return out
end
local at = breaks("今日は、いい")
-- 今|日|は、|い|い : no break before the ideographic comma
assert(table.concat(at, ",") == "4,7,13,16", table.concat(at, ","))
assert(#breaks("Hello") == 0, "a Latin word is not split")
assert(table.concat(breaks("a b"), ",") == "3")
assert(#breaks("「あ」") == 0, "no break after an opening bracket or before a closing one")

local spans = narrative.ruby("｜東京《とうきょう》へ行く。漢字《かんじ》")
assert(#spans == 3 and spans[1].text == "東京" and spans[1].reading == "とうきょう")
assert(spans[2].text == "へ行く。" and spans[2].reading == nil)
assert(spans[3].text == "漢字" and spans[3].reading == "かんじ")
assert(#narrative.ruby("no marks")[1].text == 8)
print("narrative_text_rules ok")
