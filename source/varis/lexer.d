/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lexer;

import varis.types : LuaValue;

import varis.ast : SourceLoc;
import varis.exception : LuaException, shortSourceName;
import std.ascii : isAlpha, isAlphaNum, isDigit, isHexDigit, isWhite;
import std.conv : to, parse;
import std.format : format;
import std.utf : encode;

enum TokenType {
    EOF = 0,
    Invalid, // character that starts no token (reported by the parser)

    // Keywords
    KwAnd,
    KwBreak,
    KwDo,
    KwElse,
    KwElseIf,
    KwEnd,
    KwFalse,
    KwFor,
    KwFunction,
    KwGoto,
    KwIf,
    KwIn,
    KwLocal,
    KwNil,
    KwNot,
    KwOr,
    KwRepeat,
    KwReturn,
    KwThen,
    KwTrue,
    KwUntil,
    KwWhile,

    // Operators & Punctuators
    Plus, // +
    Minus, // -
    Star, // *
    Slash, // /
    DoubleSlash, // //
    Caret, // ^
    Percent, // %
    Ampersand, // &
    Tilde, // ~
    Pipe, // |
    DoubleLess, // <<
    DoubleGreater, // >>
    DoubleDot, // ..
    TripleDot, // ...
    Equal, // =
    DoubleEqual, // ==
    TildeEqual, // ~=
    Less, // <
    LessEqual, // <=
    Greater, // >
    GreaterEqual, // >=
    Hash, // #
    Colon, // :
    DoubleColon, // ::
    RuleOp, // :-
    Question, // ?
    Semicolon, // ;
    Comma, // ,
    Dot, // .
    LParen, // (
    RParen, // )
    LBrace, // {
    RBrace, // }
    LBracket, // [
    RBracket, // ]

    // Literals
    Identifier,
    Integer,
    Float,
    String
}

struct Token {
    TokenType type;
    string text;
    long intValue;
    double floatValue;
    SourceLoc loc;
    string raw; // source text of the token (for error messages)

    string toString() const {
        import std.conv : to;

        return format("Token(%s, '%s', %s)", type.to!string, text, loc.toString());
    }
}

class Lexer {
    string source;
    string sourceName;
    size_t cursor;
    int line = 1;
    int column = 1;
    string[string] literalPool;

    string internLiteral(string s) {
        if (auto p = s in literalPool) {
            return *p;
        }
        literalPool[s] = s;
        return s;
    }

    this(string source, string sourceName = "=stdin") {
        this.source = source;
        this.sourceName = sourceName;
        this.cursor = 0;
        this.line = 1;
        this.column = 1;
    }

    private char peek(size_t offset = 0) const {
        if (cursor + offset < source.length) {
            return source[cursor + offset];
        }
        return '\0';
    }

    private char advance() {
        if (cursor < source.length) {
            char c = source[cursor++];
            if (c == '\r' || c == '\n') {
                line++;
                column = 1;
                if (cursor < source.length && (source[cursor] == '\r' || source[cursor] == '\n') && source[cursor] != c) {
                    cursor++;
                }
            } else {
                column++;
            }
            return c;
        }
        return '\0';
    }

    private bool isAtEnd() const {
        return cursor >= source.length;
    }

    private SourceLoc currentLoc() const {
        return SourceLoc(line, column);
    }

    private Token lookaheadToken;
    private bool hasLookahead = false;

    Token peekToken() {
        if (!hasLookahead) {
            lookaheadToken = scanToken();
            hasLookahead = true;
        }
        return lookaheadToken;
    }

    Token nextToken() {
        if (hasLookahead) {
            hasLookahead = false;
            return lookaheadToken;
        }
        return scanToken();
    }

    private size_t tokenStartPos;

    private Token scanToken() {
        auto token = scanTokenRaw();
        token.raw = token.type == TokenType.EOF ? "<eof>" : source[tokenStartPos .. cursor];
        return token;
    }

    private Token scanTokenRaw() {
        while (!isAtEnd()) {
            char c = peek();
            tokenStartPos = cursor;

            // Whitespace
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f') {
                advance();
                continue;
            }

            // Comments or minus
            if (c == '-') {
                if (peek(1) == '-') {
                    advance(); // '-'
                    advance(); // '-'
                    skipComment();
                    continue;
                }
            }

            // Long bracket string [[ ... ]] or [=[ ... ]=]
            if (c == '[') {
                int sep = checkLongBracketOpen();
                if (sep >= 0) {
                    return readLongString(sep);
                }
            }

            // Identifiers and keywords
            if (isAlpha(c) || c == '_') {
                return readIdentifierOrKeyword();
            }

            // Numbers
            if (isDigit(c) || (c == '.' && isDigit(peek(1)))) {
                return readNumber();
            }

            // Strings
            if (c == '"' || c == '\'') {
                return readShortString(c);
            }

            // Operators and punctuation
            auto loc = currentLoc();
            advance();

            switch (c) {
            case '+':
                return Token(TokenType.Plus, "+", 0, 0, loc);
            case '-':
                return Token(TokenType.Minus, "-", 0, 0, loc);
            case '*':
                return Token(TokenType.Star, "*", 0, 0, loc);
            case '/':
                if (peek() == '/') {
                    advance();
                    return Token(TokenType.DoubleSlash, "//", 0, 0, loc);
                }
                return Token(TokenType.Slash, "/", 0, 0, loc);
            case '^':
                return Token(TokenType.Caret, "^", 0, 0, loc);
            case '%':
                return Token(TokenType.Percent, "%", 0, 0, loc);
            case '&':
                return Token(TokenType.Ampersand, "&", 0, 0, loc);
            case '|':
                return Token(TokenType.Pipe, "|", 0, 0, loc);
            case '#':
                return Token(TokenType.Hash, "#", 0, 0, loc);
            case '(':
                return Token(TokenType.LParen, "(", 0, 0, loc);
            case ')':
                return Token(TokenType.RParen, ")", 0, 0, loc);
            case '{':
                return Token(TokenType.LBrace, "{", 0, 0, loc);
            case '}':
                return Token(TokenType.RBrace, "}", 0, 0, loc);
            case '[':
                return Token(TokenType.LBracket, "[", 0, 0, loc);
            case ']':
                return Token(TokenType.RBracket, "]", 0, 0, loc);
            case ';':
                return Token(TokenType.Semicolon, ";", 0, 0, loc);
            case ',':
                return Token(TokenType.Comma, ",", 0, 0, loc);

            case '~':
                if (peek() == '=') {
                    advance();
                    return Token(TokenType.TildeEqual, "~=", 0, 0, loc);
                }
                return Token(TokenType.Tilde, "~", 0, 0, loc);

            case '=':
                if (peek() == '=') {
                    advance();
                    return Token(TokenType.DoubleEqual, "==", 0, 0, loc);
                }
                return Token(TokenType.Equal, "=", 0, 0, loc);

            case '<':
                if (peek() == '=') {
                    advance();
                    return Token(TokenType.LessEqual, "<=", 0, 0, loc);
                } else if (peek() == '<') {
                    advance();
                    return Token(TokenType.DoubleLess, "<<", 0, 0, loc);
                }
                return Token(TokenType.Less, "<", 0, 0, loc);

            case '>':
                if (peek() == '=') {
                    advance();
                    return Token(TokenType.GreaterEqual, ">=", 0, 0, loc);
                } else if (peek() == '>') {
                    advance();
                    return Token(TokenType.DoubleGreater, ">>", 0, 0, loc);
                }
                return Token(TokenType.Greater, ">", 0, 0, loc);

            case ':':
                if (peek() == ':') {
                    advance();
                    return Token(TokenType.DoubleColon, "::", 0, 0, loc);
                } else if (peek() == '-') {
                    advance();
                    return Token(TokenType.RuleOp, ":-", 0, 0, loc);
                }
                return Token(TokenType.Colon, ":", 0, 0, loc);

            case '?':
                return Token(TokenType.Question, "?", 0, 0, loc);

            case '.':
                if (peek() == '.') {
                    advance();
                    if (peek() == '.') {
                        advance();
                        return Token(TokenType.TripleDot, "...", 0, 0, loc);
                    }
                    return Token(TokenType.DoubleDot, "..", 0, 0, loc);
                }
                return Token(TokenType.Dot, ".", 0, 0, loc);

            default:
                return Token(TokenType.Invalid, [c].idup, 0, 0, loc);
            }
        }

        return Token(TokenType.EOF, "<eof>", 0, 0, currentLoc());
    }

    private void skipComment() {
        if (peek() == '[') {
            int sep = checkLongBracketOpen();
            if (sep >= 0) {
                skipLongBracket(sep);
                return;
            }
        }
        // Short single-line comment: skip until newline
        while (!isAtEnd() && peek() != '\n' && peek() != '\r') {
            advance();
        }
    }

    private int checkLongBracketOpen() {
        // [=*[
        if (peek() != '[')
            return -1;
        size_t i = 1;
        while (peek(i) == '=') {
            i++;
        }
        if (peek(i) == '[') {
            int numEquals = cast(int)(i - 1);
            // Advance over [=*[
            for (size_t k = 0; k <= i; ++k) {
                advance();
            }
            return numEquals;
        }
        return -1;
    }

    private void skipLongBracket(int numEquals) {
        int startLine = line;
        // Skip opening newline if present
        if (peek() == '\n' || peek() == '\r') {
            advance();
        }

        while (!isAtEnd()) {
            if (peek() == ']') {
                advance();
                size_t eqCount = 0;
                while (peek() == '=') {
                    advance();
                    eqCount++;
                }
                if (peek() == ']' && eqCount == cast(size_t) numEquals) {
                    advance();
                    return;
                }
            } else {
                advance();
            }
        }
        lexError("unfinished long comment (starting at line " ~ startLine.to!string ~ ")", "<eof>");
    }

    private Token readLongString(int numEquals) {
        auto loc = currentLoc();
        int startLine = line;
        // Skip first newline if present
        if (peek() == '\n' || peek() == '\r') {
            advance();
        }

        string result;
        while (!isAtEnd()) {
            if (peek() == ']') {
                size_t startCur = cursor;
                advance();
                size_t eqCount = 0;
                while (peek() == '=') {
                    advance();
                    eqCount++;
                }
                if (peek() == ']' && eqCount == cast(size_t) numEquals) {
                    advance();
                    return Token(TokenType.String, internLiteral(result), 0, 0, loc);
                } else {
                    // Backtrack content that wasn't the closing delimiter
                    result ~= source[startCur .. cursor];
                }
            } else if (peek() == '\r' || peek() == '\n') {
                advance();
                result ~= '\n';
            } else {
                result ~= advance();
            }
        }
        lexError("unfinished long string (starting at line " ~ startLine.to!string ~ ")", "<eof>");
        assert(0);
    }

    private string formatSourceName() const {
        return shortSourceName(sourceName);
    }

    private void lexError(string msg, string nearToken = "") {
        string src = formatSourceName();
        string nearText;
        if (nearToken.length == 0 || nearToken == "<eof>") {
            nearText = "<eof>";
        } else {
            nearText = "'" ~ nearToken ~ "'";
        }
        throw new LuaException(LuaValue(format("%s:%d: %s near %s", src, line, msg, nearText)));
    }

    private void esccheck(bool condition, string msg, size_t tokenStart) {
        if (!condition) {
            if (!isAtEnd())
                advance();
            lexError(msg, source[tokenStart .. cursor]);
        }
    }

    private Token readShortString(char quote) {
        auto loc = currentLoc();
        size_t tokenStart = cursor;
        advance(); // consume opening quote

        char[] buf;
        while (!isAtEnd() && peek() != quote) {
            char c = peek();
            if (c == '\n' || c == '\r') {
                lexError("unfinished string", source[tokenStart .. cursor]);
            }
            if (c == '\\') {
                advance();
                if (isAtEnd())
                    lexError("unfinished string", "<eof>");
                char esc = peek();
                switch (esc) {
                case 'a':
                    buf ~= '\a';
                    advance();
                    break;
                case 'b':
                    buf ~= '\b';
                    advance();
                    break;
                case 'f':
                    buf ~= '\f';
                    advance();
                    break;
                case 'n':
                    buf ~= '\n';
                    advance();
                    break;
                case 'r':
                    buf ~= '\r';
                    advance();
                    break;
                case 't':
                    buf ~= '\t';
                    advance();
                    break;
                case 'v':
                    buf ~= '\v';
                    advance();
                    break;
                case '\\':
                    buf ~= '\\';
                    advance();
                    break;
                case '"':
                    buf ~= '"';
                    advance();
                    break;
                case '\'':
                    buf ~= '\'';
                    advance();
                    break;
                case '\n':
                case '\r': {
                        buf ~= '\n';
                        char first = advance();
                        if (!isAtEnd() && (peek() == '\n' || peek() == '\r') && peek() != first)
                            advance();
                        break;
                    }
                case 'z': // zap whitespace
                    advance();
                    while (!isAtEnd() && (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r' || peek() == '\v' || peek() == '\f')) {
                        advance();
                    }
                    break;
                case 'x': // \xXX hexadecimal byte
                    advance();
                    esccheck(isHexDigit(peek()), "hexadecimal digit expected", tokenStart);
                    char h1 = advance();
                    esccheck(isHexDigit(peek()), "hexadecimal digit expected", tokenStart);
                    char h2 = advance();
                    int bVal = (hexVal(h1) << 4) | hexVal(h2);
                    buf ~= cast(char) bVal;
                    break;
                case 'u': // \u{XXX} UTF-8 codepoint
                    advance();
                    esccheck(peek() == '{', "missing '{'", tokenStart);
                    advance(); // consume '{'
                    esccheck(isHexDigit(peek()), "hexadecimal digit expected", tokenStart);
                    ulong cp = 0;
                    while (!isAtEnd() && peek() != '}') {
                        esccheck(isHexDigit(peek()), "hexadecimal digit expected", tokenStart);
                        char hc = advance();
                        if (cp > (0x7FFFFFFFu >> 4)) {
                            lexError("UTF-8 value too large", source[tokenStart .. cursor]);
                        }
                        cp = (cp << 4) | hexVal(hc);
                    }
                    esccheck(peek() == '}', "missing '}'", tokenStart);
                    advance(); // consume '}'
                    if (cp < 0x80) {
                        buf ~= cast(char) cp;
                    } else {
                        char[8] temp;
                        int n = 1;
                        uint mfb = 0x3f;
                        do {
                            temp[8 - (n++)] = cast(char)(0x80 | (cp & 0x3f));
                            cp >>= 6;
                            mfb >>= 1;
                        }
                        while (cp > mfb);
                        temp[8 - n] = cast(char)((~mfb << 1) | cp);
                        buf ~= temp[8 - n .. 8];
                    }
                    break;
                default:
                    if (isDigit(esc)) {
                        // \ddd (up to 3 decimal digits)
                        int dVal = 0;
                        int count = 0;
                        while (count < 3 && isDigit(peek())) {
                            dVal = dVal * 10 + (advance() - '0');
                            count++;
                        }
                        esccheck(dVal <= 255, "decimal escape too large", tokenStart);
                        buf ~= cast(char) dVal;
                    } else {
                        if (!isAtEnd())
                            advance();
                        lexError("invalid escape sequence", source[tokenStart .. cursor]);
                    }
                    break;
                }
            } else {
                buf ~= advance();
            }
        }

        if (isAtEnd()) {
            lexError("unfinished string", "<eof>");
        }

        advance(); // consume closing quote
        return Token(TokenType.String, internLiteral(cast(string) buf), 0, 0, loc);
    }

    private static int hexVal(char c) {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return 0;
    }

    private Token readIdentifierOrKeyword() {
        auto loc = currentLoc();
        size_t start = cursor;
        while (!isAtEnd() && (isAlphaNum(peek()) || peek() == '_')) {
            advance();
        }
        string text = source[start .. cursor];

        switch (text) {
        case "and":
            return Token(TokenType.KwAnd, text, 0, 0, loc);
        case "break":
            return Token(TokenType.KwBreak, text, 0, 0, loc);
        case "do":
            return Token(TokenType.KwDo, text, 0, 0, loc);
        case "else":
            return Token(TokenType.KwElse, text, 0, 0, loc);
        case "elseif":
            return Token(TokenType.KwElseIf, text, 0, 0, loc);
        case "end":
            return Token(TokenType.KwEnd, text, 0, 0, loc);
        case "false":
            return Token(TokenType.KwFalse, text, 0, 0, loc);
        case "for":
            return Token(TokenType.KwFor, text, 0, 0, loc);
        case "function":
            return Token(TokenType.KwFunction, text, 0, 0, loc);
        case "goto":
            return Token(TokenType.KwGoto, text, 0, 0, loc);
        case "if":
            return Token(TokenType.KwIf, text, 0, 0, loc);
        case "in":
            return Token(TokenType.KwIn, text, 0, 0, loc);
        case "local":
            return Token(TokenType.KwLocal, text, 0, 0, loc);
        case "nil":
            return Token(TokenType.KwNil, text, 0, 0, loc);
        case "not":
            return Token(TokenType.KwNot, text, 0, 0, loc);
        case "or":
            return Token(TokenType.KwOr, text, 0, 0, loc);
        case "repeat":
            return Token(TokenType.KwRepeat, text, 0, 0, loc);
        case "return":
            return Token(TokenType.KwReturn, text, 0, 0, loc);
        case "then":
            return Token(TokenType.KwThen, text, 0, 0, loc);
        case "true":
            return Token(TokenType.KwTrue, text, 0, 0, loc);
        case "until":
            return Token(TokenType.KwUntil, text, 0, 0, loc);
        case "while":
            return Token(TokenType.KwWhile, text, 0, 0, loc);
        default:
            return Token(TokenType.Identifier, text, 0, 0, loc);
        }
    }

    private Token readNumber() {
        auto loc = currentLoc();
        size_t start = cursor;
        char first = peek();
        advance();

        string expo = "Ee";
        bool isHex = false;
        if (first == '0' && (peek() == 'x' || peek() == 'X')) {
            isHex = true;
            expo = "Pp";
            advance();
        }

        while (!isAtEnd()) {
            char ch = peek();
            if (ch == expo[0] || ch == expo[1]) {
                advance();
                if (peek() == '+' || peek() == '-') {
                    advance();
                }
            } else if (isHexDigit(ch) || ch == '.') {
                advance();
            } else {
                break;
            }
        }

        if (isAlpha(peek()) || peek() == '_') {
            advance(); // touching a letter -> force an error
        }

        string numStr = source[start .. cursor];

        import core.stdc.stdlib : strtod;
        import core.stdc.locale : localeconv;
        import std.string : toStringz, indexOf;
        import std.array : replace;
        import std.math : isNaN, isInfinity;

        // Try integer first if no '.' and no exponent
        if (numStr.indexOf('.') == -1 && numStr.indexOf(expo[0]) == -1 && numStr.indexOf(expo[1]) == -1) {
            if (isHex) {
                // Hex integers in Lua 5.4: 0x followed by hex digits, wrap around 64-bit unsigned
                if (numStr.length > 2) {
                    ulong a = 0;
                    bool ok = true;
                    for (size_t i = 2; i < numStr.length; ++i) {
                        char h = numStr[i];
                        if (h >= '0' && h <= '9')
                            a = (a << 4) | (h - '0');
                        else if (h >= 'a' && h <= 'f')
                            a = (a << 4) | (h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F')
                            a = (a << 4) | (h - 'A' + 10);
                        else {
                            ok = false;
                            break;
                        }
                    }
                    if (ok) {
                        long iVal = cast(long) a;
                        return Token(TokenType.Integer, numStr, iVal, cast(double) iVal, loc);
                    }
                }
            } else {
                // Decimal integer: check if it fits in long without overflow
                ulong a = 0;
                bool ok = true;
                bool overflow = false;
                for (size_t i = 0; i < numStr.length; ++i) {
                    char d = numStr[i];
                    if (d >= '0' && d <= '9') {
                        ulong prev = a;
                        a = a * 10 + (d - '0');
                        if (a < prev || a > cast(ulong) long.max) {
                            overflow = true;
                        }
                    } else {
                        ok = false;
                        break;
                    }
                }
                if (ok && !overflow && numStr.length > 0) {
                    long iVal = cast(long) a;
                    return Token(TokenType.Integer, numStr, iVal, cast(double) iVal, loc);
                }
            }
        }

        // Try float
        immutable(char)* endptr = null;
        auto cstr = numStr.toStringz;
        double fVal = strtod(cstr, &endptr);
        if (endptr == cstr || *endptr != '\0') {
            char dec = localeconv().decimal_point[0];
            if (dec != '.' && numStr.indexOf('.') != -1) {
                string sLoc = numStr.replace(".", [dec]);
                cstr = sLoc.toStringz;
                endptr = null;
                fVal = strtod(cstr, &endptr);
            }
        }

        if (endptr != cstr && *endptr == '\0') {
            return Token(TokenType.Float, numStr, 0, fVal, loc);
        }

        lexError("malformed number", numStr);
        return Token(TokenType.Float, numStr, 0, 0.0, loc);
    }
}
