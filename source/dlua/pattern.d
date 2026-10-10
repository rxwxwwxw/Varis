/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.pattern;

import dlua.types;
import dlua.exception : LuaException;
import std.ascii : isAlpha, isControl, isDigit, isGraphical, isLower, isPunctuation, isWhite, isUpper, isAlphaNum, isHexDigit, toLower;
import std.format : format;
import std.array : Appender;

enum LUA_MAXCAPTURES = 32;
enum CAP_UNFINISHED = -1;
enum CAP_POSITION = -2;

struct Capture {
    ptrdiff_t init;
    ptrdiff_t len;
}

/// Pattern match state
struct MatchState {
    string src;
    string pattern;
    ptrdiff_t matchdepth;
    int level;
    Capture[LUA_MAXCAPTURES] capture;

    this(string src, string pattern) {
        this.src = src;
        this.pattern = pattern;
        this.matchdepth = 200;
        this.level = 0;
    }
}

/// Lua pattern matching engine
struct Pattern {
    static int checkCapture(ref MatchState ms, int l) {
        l -= '1';
        if (l < 0 || l >= ms.level || ms.capture[l].len == CAP_UNFINISHED) {
            throw new LuaException(format("invalid capture index %%%d", l + 1));
        }
        return l;
    }

    static int captureToClose(ref MatchState ms) {
        for (int level = ms.level - 1; level >= 0; --level) {
            if (ms.capture[level].len == CAP_UNFINISHED) return level;
        }
        throw new LuaException("invalid pattern capture");
    }

    static size_t classend(ref MatchState ms, size_t p) {
        char c = ms.pattern[p++];
        switch (c) {
            case '%':
                if (p == ms.pattern.length) {
                    throw new LuaException("malformed pattern (ends with '%')");
                }
                return p + 1;
            case '[':
                if (p < ms.pattern.length && ms.pattern[p] == '^') p++;
                do {
                    if (p >= ms.pattern.length) {
                        throw new LuaException("malformed pattern (missing ']')");
                    }
                    if (ms.pattern[p++] == '%' && p < ms.pattern.length) {
                        p++;
                    }
                } while (p < ms.pattern.length && ms.pattern[p] != ']');
                if (p >= ms.pattern.length) throw new LuaException("malformed pattern (missing ']')");
                return p + 1;
            default:
                return p;
        }
    }

    static bool matchClass(char c, char cl) {
        bool res;
        switch (toLower(cl)) {
            case 'a': res = isAlpha(c); break;
            case 'c': res = isControl(c); break;
            case 'd': res = isDigit(c); break;
            case 'g': res = isGraphical(c); break;
            case 'l': res = isLower(c); break;
            case 'p': res = isPunctuation(c); break;
            case 's': res = isWhite(c); break;
            case 'u': res = isUpper(c); break;
            case 'w': res = isAlphaNum(c); break;
            case 'x': res = isHexDigit(c); break;
            case 'z': res = (c == '\0'); break;
            default: return (cl == c);
        }
        return isLower(cl) ? res : !res;
    }

    static bool matchBracketClass(char c, string pat, size_t p, size_t ep) {
        bool sig = true;
        if (pat[p + 1] == '^') {
            sig = false;
            p++;
        }
        while (++p < ep) {
            if (pat[p] == '%') {
                p++;
                if (matchClass(c, pat[p])) return sig;
            } else if ((p + 2 < ep) && (pat[p + 1] == '-')) {
                char p1 = pat[p];
                char p2 = pat[p + 2];
                p += 2;
                if (p1 <= c && c <= p2) return sig;
            } else if (pat[p] == c) {
                return sig;
            }
        }
        return !sig;
    }

    static bool singleMatch(ref MatchState ms, size_t s, size_t p, size_t ep) {
        if (s >= ms.src.length) return false;
        char c = ms.src[s];
        switch (ms.pattern[p]) {
            case '.': return true;
            case '%': return matchClass(c, ms.pattern[p + 1]);
            case '[': return matchBracketClass(c, ms.pattern, p, ep - 1);
            default: return (ms.pattern[p] == c);
        }
    }

    static ptrdiff_t matchBalance(ref MatchState ms, size_t s, size_t p) {
        if (p >= ms.pattern.length - 1) {
            throw new LuaException("malformed pattern (missing arguments to '%b')");
        }
        if (s >= ms.src.length || ms.src[s] != ms.pattern[p]) return -1;
        char b = ms.pattern[p];
        char e = ms.pattern[p + 1];
        int cont = 1;
        while (++s < ms.src.length) {
            if (ms.src[s] == e) {
                if (--cont == 0) return cast(ptrdiff_t)(s + 1);
            } else if (ms.src[s] == b) {
                cont++;
            }
        }
        return -1;
    }

    static ptrdiff_t maxExpand(ref MatchState ms, size_t s, size_t p, size_t ep) {
        ptrdiff_t i = 0;
        while (singleMatch(ms, s + i, p, ep)) {
            i++;
        }
        while (i >= 0) {
            ptrdiff_t res = matchLoop(ms, s + i, ep + 1);
            if (res != -1) return res;
            i--;
        }
        return -1;
    }

    static ptrdiff_t minExpand(ref MatchState ms, size_t s, size_t p, size_t ep) {
        while (true) {
            ptrdiff_t res = matchLoop(ms, s, ep + 1);
            if (res != -1) return res;
            if (singleMatch(ms, s, p, ep)) {
                s++;
            } else {
                return -1;
            }
        }
    }

    static ptrdiff_t startCapture(ref MatchState ms, size_t s, size_t p, ptrdiff_t what) {
        int level = ms.level;
        if (level >= LUA_MAXCAPTURES) throw new LuaException("too many captures");
        ms.capture[level].init = cast(ptrdiff_t)s;
        ms.capture[level].len = what;
        ms.level = level + 1;
        ptrdiff_t res = matchLoop(ms, s, p);
        if (res == -1) ms.level--;
        return res;
    }

    static ptrdiff_t endCapture(ref MatchState ms, size_t s, size_t p) {
        int l = captureToClose(ms);
        ms.capture[l].len = cast(ptrdiff_t)s - ms.capture[l].init;
        ptrdiff_t res = matchLoop(ms, s, p);
        if (res == -1) ms.capture[l].len = CAP_UNFINISHED;
        return res;
    }

    static ptrdiff_t matchCapture(ref MatchState ms, size_t s, int l) {
        l = checkCapture(ms, l);
        size_t len = cast(size_t)ms.capture[l].len;
        if (ms.src.length - s >= len &&
            ms.src[s .. s + len] == ms.src[ms.capture[l].init .. ms.capture[l].init + len]) {
            return cast(ptrdiff_t)(s + len);
        }
        return -1;
    }

    static ptrdiff_t matchLoop(ref MatchState ms, size_t s, size_t p) {
        if (--ms.matchdepth == 0) throw new LuaException("pattern too complex");
        scope(exit) ++ms.matchdepth;

        while (p < ms.pattern.length) {
            switch (ms.pattern[p]) {
                case '(':
                    if (p + 1 < ms.pattern.length && ms.pattern[p + 1] == ')') {
                        return startCapture(ms, s, p + 2, CAP_POSITION);
                    } else {
                        return startCapture(ms, s, p + 1, CAP_UNFINISHED);
                    }
                case ')':
                    return endCapture(ms, s, p + 1);
                case '$':
                    if (p + 1 == ms.pattern.length) {
                        return (s == ms.src.length) ? cast(ptrdiff_t)s : -1;
                    }
                    goto default;
                case '%':
                    if (p + 1 < ms.pattern.length) {
                        char nextC = ms.pattern[p + 1];
                        if (nextC == 'b') {
                            ptrdiff_t endBal = matchBalance(ms, s, p + 2);
                            if (endBal != -1) {
                                s = cast(size_t)endBal;
                                p += 4;
                                continue;
                            }
                            return -1;
                        } else if (nextC == 'f') {
                            p += 2;
                            if (p >= ms.pattern.length || ms.pattern[p] != '[') {
                                throw new LuaException("missing '[' after '%f' in pattern");
                            }
                            size_t ep = classend(ms, p);
                            char previous = (s == 0) ? '\0' : ms.src[s - 1];
                            char current = (s == ms.src.length) ? '\0' : ms.src[s];
                            if (!matchBracketClass(previous, ms.pattern, p, ep - 1) &&
                                 matchBracketClass(current, ms.pattern, p, ep - 1)) {
                                p = ep;
                                continue;
                            }
                            return -1;
                        } else if (nextC >= '0' && nextC <= '9') {
                            ptrdiff_t endCap = matchCapture(ms, s, nextC);
                            if (endCap != -1) {
                                s = cast(size_t)endCap;
                                p += 2;
                                continue;
                            }
                            return -1;
                        }
                    }
                    goto default;
                default:
                    size_t ep = classend(ms, p);
                    char suffix = (ep < ms.pattern.length) ? ms.pattern[ep] : '\0';
                    bool m = singleMatch(ms, s, p, ep);

                    if (!m) {
                        if (suffix == '*' || suffix == '?' || suffix == '-') {
                            p = ep + 1;
                            continue;
                        }
                        return -1;
                    }

                    switch (suffix) {
                        case '?':
                            ptrdiff_t res = matchLoop(ms, s + 1, ep + 1);
                            if (res != -1) return res;
                            p = ep + 1;
                            continue;
                        case '+':
                            return maxExpand(ms, s + 1, p, ep);
                        case '*':
                            return maxExpand(ms, s, p, ep);
                        case '-':
                            return minExpand(ms, s, p, ep);
                        default:
                            s++;
                            p = ep;
                            continue;
                    }
            }
        }
        return cast(ptrdiff_t)s;
    }

    /// Extract captured values into LuaValue[]
    static LuaValue[] getCaptures(ref MatchState ms, size_t matchStart, size_t matchEnd) {
        if (ms.level == 0) {
            return [LuaValue(ms.src[matchStart .. matchEnd])];
        }

        LuaValue[] result;
        for (int i = 0; i < ms.level; ++i) {
            if (ms.capture[i].len == CAP_UNFINISHED) throw new LuaException("unfinished capture");
            if (ms.capture[i].len == CAP_POSITION) {
                result ~= LuaValue(cast(long)(ms.capture[i].init + 1));
            } else {
                size_t cInit = cast(size_t)ms.capture[i].init;
                size_t cLen = cast(size_t)ms.capture[i].len;
                result ~= LuaValue(ms.src[cInit .. cInit + cLen]);
            }
        }
        return result;
    }

    /// Find pattern in string (1-based Lua indexing)
    static struct FindResult {
        bool matched;
        size_t startIdx; // 1-based
        size_t endIdx;   // 1-based
        LuaValue[] captures;
    }

    static FindResult find(string s, string pattern, size_t init = 1, bool plain = false, bool anchorCaret = true) {
        if (init < 1) init = 1;
        size_t sIdx = init - 1;
        if (sIdx > s.length) return FindResult(false);

        if (plain) {
            import std.string : indexOf;
            ptrdiff_t found = s[sIdx .. $].indexOf(pattern);
            if (found != -1) {
                size_t start = sIdx + cast(size_t)found + 1;
                size_t end = start + pattern.length - 1;
                return FindResult(true, start, end, []);
            }
            return FindResult(false);
        }

        bool anchor = anchorCaret && (pattern.length > 0 && pattern[0] == '^');
        size_t pOffset = anchor ? 1 : 0;

        do {
            MatchState ms = MatchState(s, pattern[pOffset .. $]);
            ptrdiff_t res = matchLoop(ms, sIdx, 0);
            if (res != -1) {
                auto caps = getCaptures(ms, sIdx, cast(size_t)res);
                return FindResult(true, sIdx + 1, cast(size_t)res, ms.level > 0 ? caps : []);
            }
            if (anchor) break;
            sIdx++;
        } while (sIdx <= s.length);

        return FindResult(false);
    }

    /// Match pattern in string, returning captures or whole match
    static LuaValue[] match(string s, string pattern, size_t init = 1) {
        auto fr = find(s, pattern, init, false);
        if (!fr.matched) return [];
        if (fr.captures.length > 0) return fr.captures;
        return [LuaValue(s[fr.startIdx - 1 .. fr.endIdx])];
    }
}
