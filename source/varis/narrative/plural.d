/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Plural categories per language, for `{#plural n}` in message templates. A small generated table
/// for the shipped languages (NARRATIVE_LOCALIZATION_PLAN §4), not a Unicode library. The rules are
/// those of CLDR for integers; a number with a fractional part is `other` in every language here.
module varis.narrative.plural;

/// The language of a tag: `zh-Hant-TW` is `zh`, `pt_BR` is `pt`.
string languageOf(string tag) {
    size_t end;
    while (end < tag.length && tag[end] != '-' && tag[end] != '_')
        ++end;
    char[] result;
    foreach (char c; tag[0 .. end])
        result ~= (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return cast(string) result;
}

private enum Family {
    other, // no plural forms: Chinese, Japanese, Korean, Vietnamese, Thai, Indonesian
    oneOther, // one: 1
    frenchLike, // one: 0 and 1
    eastSlavic, // Russian, Ukrainian, Belarusian
    polish,
    czechLike // Czech, Slovak
}

private Family familyOf(string language) {
    switch (language) {
    case "zh":
    case "ja":
    case "ko":
    case "vi":
    case "th":
    case "id":
    case "ms":
        return Family.other;
    case "fr":
    case "pt":
        return Family.frenchLike;
    case "ru":
    case "uk":
    case "be":
        return Family.eastSlavic;
    case "pl":
        return Family.polish;
    case "cs":
    case "sk":
        return Family.czechLike;
    default:
        return Family.oneOther;
    }
}

/// The category of a number in a language: `zero`, `one`, `two`, `few`, `many` or `other`.
string pluralCategory(string tag, double value) {
    auto family = familyOf(languageOf(tag));
    if (family == Family.other)
        return "other";
    // Integers only; a negative number is its absolute value, a fraction is `other`.
    if (value < 0)
        value = -value;
    bool integral = value == cast(double)(cast(long) value) && value < 1.0e15;
    long i = cast(long) value;
    final switch (family) {
    case Family.other:
        return "other";
    case Family.oneOther:
        return integral && i == 1 ? "one" : "other";
    case Family.frenchLike:
        return value >= 0 && value < 2 ? "one" : "other";
    case Family.eastSlavic:
        if (!integral)
            return "other";
        if (i % 10 == 1 && i % 100 != 11)
            return "one";
        if (i % 10 >= 2 && i % 10 <= 4 && !(i % 100 >= 12 && i % 100 <= 14))
            return "few";
        return "many";
    case Family.polish:
        if (!integral)
            return "other";
        if (i == 1)
            return "one";
        if (i % 10 >= 2 && i % 10 <= 4 && !(i % 100 >= 12 && i % 100 <= 14))
            return "few";
        return "many";
    case Family.czechLike:
        if (!integral)
            return "many";
        if (i == 1)
            return "one";
        if (i >= 2 && i <= 4)
            return "few";
        return "other";
    }
}

/// The categories a message in this language needs a branch for (besides the required `other`).
string[] requiredPluralCategories(string tag) {
    final switch (familyOf(languageOf(tag))) {
    case Family.other:
        return ["other"];
    case Family.oneOther:
    case Family.frenchLike:
        return ["one", "other"];
    case Family.eastSlavic:
    case Family.polish:
    case Family.czechLike:
        return ["one", "few", "many", "other"];
    }
}

/// Is `category` a name a template may use at all? (Any of the six; a language that has no use
/// for one is told by the checker.)
bool isPluralCategory(string category) {
    return category == "zero" || category == "one" || category == "two" || category == "few" || category == "many"
        || category == "other";
}

/// May a message in this language have a branch for `category`? French also has `many` (millions).
bool pluralCategoryAllowed(string tag, string category) {
    foreach (name; requiredPluralCategories(tag))
        if (name == category)
            return true;
    return languageOf(tag) == "fr" && category == "many" || languageOf(tag) == "pt" && category == "many";
}
