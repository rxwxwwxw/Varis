/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Text rules the engine can state without a font or a window (NARRATIVE_LOCALIZATION_PLAN §4, §5):
/// the Korean particle that follows a word, grapheme clusters, the positions at which a line may
/// break in Chinese, Japanese and Korean text, and ruby annotations as spans. A presentation layer
/// (milestone 36) draws; these decide. All functions work on UTF-8 and never split a character.
module varis.narrative.text;

/// Decodes the code point at `i` and returns its length in bytes (invalid bytes are one each).
uint decodeAt(string text, size_t i, out size_t length) {
    ubyte c = text[i];
    if (c < 0x80) {
        length = 1;
        return c;
    }
    size_t n = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : (c >= 0xC0 ? 2 : 1));
    if (n == 1 || i + n > text.length) {
        length = 1;
        return 0xFFFD;
    }
    uint code = c & (0xFF >> (n + 1));
    foreach (k; 1 .. n)
        code = (code << 6) | (text[i + k] & 0x3F);
    length = n;
    return code;
}

// --- Korean particles ----------------------------------------------------------

private bool isHangulSyllable(uint c) {
    return c >= 0xAC00 && c <= 0xD7A3;
}

/// Picks the form of a particle that follows `word`, from the sound the word ends in. `forms` is
/// `"은/는"`, `"이/가"`, `"을/를"`, `"과/와"`, `"으로/로"` or `"이/"` (the first form after a final
/// consonant, the second after a vowel). `으로/로` takes the second form also after ㄹ. A Hangul
/// syllable decides by its final consonant; a digit by how the number is read (영 일 삼 육 칠 팔
/// end in a consonant); other letters count as ending in a vowel. Trailing spaces, quotes and
/// brackets are looked through.
string koreanParticle(string word, string forms) {
    size_t slash;
    while (slash < forms.length && forms[slash] != '/')
        ++slash;
    if (slash >= forms.length)
        return forms;
    auto consonantForm = forms[0 .. slash];
    auto vowelForm = forms[slash + 1 .. $];
    // The last significant code point.
    uint last;
    size_t i;
    while (i < word.length) {
        size_t n;
        auto c = decodeAt(word, i, n);
        i += n;
        bool skip = c == ' ' || c == '"' || c == '\'' || c == ')' || c == ']' || c == '.' || c == ',' || c == '!' || c == '?'
            || c == 0x300D || c == 0x300F || c == 0x201D || c == 0x2019;
        if (!skip)
            last = c;
    }
    bool consonant;
    bool rieul;
    if (isHangulSyllable(last)) {
        auto final_ = (last - 0xAC00) % 28;
        consonant = final_ != 0;
        rieul = final_ == 8;
    } else if (last >= '0' && last <= '9')
        consonant = last == '0' || last == '1' || last == '3' || last == '6' || last == '7' || last == '8';
    if (rieul && consonantForm == "으로")
        consonant = false;
    return consonant ? consonantForm : vowelForm;
}

// --- Graphemes --------------------------------------------------------------------

private bool extendsCluster(uint c) {
    return (c >= 0x0300 && c <= 0x036F) || (c >= 0x1AB0 && c <= 0x1AFF) || (c >= 0x20D0 && c <= 0x20FF)
        || (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xFE20 && c <= 0xFE2F) || c == 0x3099 || c == 0x309A || c == 0x200D
        || (c >= 0x1F3FB && c <= 0x1F3FF) || (c >= 0xE0100 && c <= 0xE01EF) || (c >= 0x0E31 && c <= 0x0E3A && c != 0x0E32
                && c != 0x0E33) || (c >= 0x0900 && c <= 0x0903) || (c >= 0x093A && c <= 0x094F);
}

private bool isRegionalIndicator(uint c) {
    return c >= 0x1F1E6 && c <= 0x1F1FF;
}

/// Byte offsets at which each grapheme cluster starts, plus the length of the text at the end.
/// Combining marks, variation selectors, skin tones, joined emoji (ZWJ) and flag pairs stay with
/// their base; a Hangul syllable is one cluster.
size_t[] graphemeBoundaries(string text) {
    size_t[] starts;
    size_t i;
    bool afterZwj;
    int regional;
    while (i < text.length) {
        size_t n;
        auto c = decodeAt(text, i, n);
        bool joins = starts.length > 0 && (extendsCluster(c) || afterZwj);
        if (isRegionalIndicator(c)) {
            if (starts.length > 0 && regional == 1)
                joins = true;
            regional = regional == 1 ? 0 : 1;
        } else
            regional = 0;
        if (c == '\n' && i > 0 && text[i - 1] == '\r')
            joins = true;
        if (!joins)
            starts ~= i;
        afterZwj = c == 0x200D;
        i += n;
    }
    starts ~= text.length;
    return starts;
}

// --- Line breaking -------------------------------------------------------------------

private bool isWide(uint c) {
    return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF)
        || (c >= 0xFF00 && c <= 0xFFEF) || (c >= 0x20000 && c <= 0x3FFFF) || (c >= 0x1100 && c <= 0x11FF)
        || (c >= 0x3000 && c <= 0x303F);
}

/// Characters that may not begin a line (closing marks, small kana, the prolonged sound mark,
/// iteration marks, and sentence punctuation), after JIS X 4051 and the CLDR line-break classes.
private bool cannotStartLine(uint c) {
    switch (c) {
    case 0x3001:
    case 0x3002:
    case 0xFF0C:
    case 0xFF0E:
    case 0xFF1A:
    case 0xFF1B:
    case 0xFF01:
    case 0xFF1F:
    case 0xFF09:
    case 0xFF3D:
    case 0xFF5D:
    case 0x300D:
    case 0x300F:
    case 0x3011:
    case 0x3015:
    case 0x3009:
    case 0x300B:
    case 0x30FC:
    case 0x30FB:
    case 0x3005:
    case 0x309D:
    case 0x309E:
    case 0x30FD:
    case 0x30FE:
    case 0x3041:
    case 0x3043:
    case 0x3045:
    case 0x3047:
    case 0x3049:
    case 0x3063:
    case 0x3083:
    case 0x3085:
    case 0x3087:
    case 0x308E:
    case 0x30A1:
    case 0x30A3:
    case 0x30A5:
    case 0x30A7:
    case 0x30A9:
    case 0x30C3:
    case 0x30E3:
    case 0x30E5:
    case 0x30E7:
    case 0x30EE:
    case 0x2026:
    case 0x2025:
    case 0x2019:
    case 0x201D:
    case ')':
    case ']':
    case '}':
    case ',':
    case '.':
    case '!':
    case '?':
    case ':':
    case ';':
    case '%':
        return true;
    default:
        return false;
    }
}

/// Characters that may not end a line (opening marks).
private bool cannotEndLine(uint c) {
    switch (c) {
    case 0x300C:
    case 0x300E:
    case 0x3010:
    case 0x3014:
    case 0x3008:
    case 0x300A:
    case 0xFF08:
    case 0xFF3B:
    case 0xFF5B:
    case 0x2018:
    case 0x201C:
    case '(':
    case '[':
    case '{':
        return true;
    default:
        return false;
    }
}

/// Byte offsets where a line may break. Text with spaces breaks after them; between two wide
/// characters (Chinese, Japanese, Korean) it breaks unless the next may not start a line or the
/// previous may not end one; a Latin word is never split; a break never falls inside a grapheme.
size_t[] lineBreakOpportunities(string text) {
    size_t[] breaks;
    auto boundaries = graphemeBoundaries(text);
    uint previous;
    foreach (k; 0 .. boundaries.length - 1) {
        size_t at = boundaries[k];
        size_t n;
        auto c = decodeAt(text, at, n);
        if (k > 0) {
            bool allowed;
            if (previous == ' ' && c != ' ')
                allowed = true;
            else if (previous == '\n')
                allowed = true;
            else if (previous != ' ' && c != ' ' && (isWide(previous) || isWide(c)))
                allowed = true; // between wide characters, and between a wide one and a Latin one
            if (allowed && (cannotStartLine(c) || cannotEndLine(previous)))
                allowed = false;
            if (allowed)
                breaks ~= at;
        }
        previous = c;
    }
    return breaks;
}

// --- Ruby ------------------------------------------------------------------------------

/// One piece of annotated text: plain text, or a base with its reading.
struct Span {
    string text;
    string reading; // empty for plain text
}

private bool isIdeograph(uint c) {
    return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0xF900 && c <= 0xFAFF)
        || (c >= 0x20000 && c <= 0x2FFFF) || c == 0x3005 || c == 0x3007;
}

/// Splits text written with the Japanese ruby convention: `｜漢字《かんじ》` (explicit base) or a
/// run of ideographs directly before `《reading》`. Anything else, including a `《` with no
/// closing mark, stays plain text.
Span[] rubySpans(string text) {
    Span[] spans;
    string plain;
    void flush() {
        if (plain.length) {
            spans ~= Span(plain, null);
            plain = null;
        }
    }

    size_t i;
    while (i < text.length) {
        size_t n;
        auto c = decodeAt(text, i, n);
        // `｜` (U+FF5C) or `|` introduces an explicit base up to `《`.
        if (c == 0xFF5C || c == '|') {
            size_t j = i + n;
            size_t baseStart = j;
            bool found;
            while (j < text.length) {
                size_t m;
                auto d = decodeAt(text, j, m);
                if (d == 0x300A) {
                    found = true;
                    break;
                }
                if (d == 0xFF5C || d == '|' || d == 0x300B)
                    break;
                j += m;
            }
            if (found) {
                size_t readStart = j + 3;
                size_t k = readStart;
                bool closed;
                while (k < text.length) {
                    size_t m;
                    auto d = decodeAt(text, k, m);
                    if (d == 0x300B) {
                        closed = true;
                        break;
                    }
                    k += m;
                }
                if (closed && j > baseStart) {
                    flush();
                    spans ~= Span(text[baseStart .. j], text[readStart .. k]);
                    i = k + 3;
                    continue;
                }
            }
        }
        if (c == 0x300A && plain.length) {
            // A run of ideographs at the end of `plain` is the base.
            size_t start = plain.length;
            while (start > 0) {
                size_t back = start - 1;
                while (back > 0 && (plain[back] & 0xC0) == 0x80)
                    --back;
                size_t m;
                if (!isIdeograph(decodeAt(plain, back, m)))
                    break;
                start = back;
            }
            size_t readStart = i + n;
            size_t k = readStart;
            bool closed;
            while (k < text.length) {
                size_t m;
                auto d = decodeAt(text, k, m);
                if (d == 0x300B) {
                    closed = true;
                    break;
                }
                k += m;
            }
            if (closed && start < plain.length) {
                auto base = plain[start .. $];
                plain = plain[0 .. start];
                flush();
                spans ~= Span(base, text[readStart .. k]);
                i = k + 3;
                continue;
            }
        }
        plain ~= text[i .. i + n];
        i += n;
    }
    flush();
    return spans;
}
