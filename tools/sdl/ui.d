/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// A small retained-layout widget toolkit for the SDL3 player.
///
/// Rules the toolkit keeps, so that screens do not have to:
///
/// * **One root owns the screen.** Every widget is nested in a tree whose root is given the whole
///   window; a child is only ever laid out inside the rectangle its parent gave it.
/// * **Text is owned by a box.** A `Label` measures its own text for the width it is offered and
///   reports the size it needs. If the box it ends up in is smaller, the label's overflow policy
///   decides: `grow` (never clipped, the parent must make room), `ellipsis` (one line, cut with
///   "…" and scrolling sideways while hovered) or `scroll` (clipped, scrolling with the wheel and
///   on its own while hovered).
/// * **Measure, then arrange, then draw.** `Box` shares leftover room by `flex` weights and takes
///   missing room from shrinkable children (labels that can scroll, scroll boxes) before anything
///   else is squeezed.
/// * **Sizes are in design units** (pixels at scale 1: the 1280x720 design). `Ui.scale` multiplies
///   them by the display density and the player's text-size setting, so one number makes the whole
///   interface larger or smaller, and the size class (`compact`, `regular`, `wide`) is judged in
///   units so that a bigger text size also chooses the roomier layout rules.
/// * **Style is data.** Colours, type sizes, padding and breakpoints come from a `Theme`, which a
///   game's manifest can override.
///
/// The tree is rebuilt for every frame (it is cheap: texts are cached by content) while state that
/// must outlive a frame, such as scroll positions, lives in the `Ui` by widget id.
module tools.sdl.ui;

import tools.sdl.native;
import varis.services.json;
import std.algorithm : max, min;
import std.format : format;
import std.string : toStringz;

struct Rect {
    float x = 0, y = 0, w = 0, h = 0;

    bool contains(float px, float py) const {
        return px >= x && px < x + w && py >= y && py < y + h;
    }

    Rect inset(float l, float t, float r, float b) const {
        return Rect(x + l, y + t, max(0, w - l - r), max(0, h - t - b));
    }

    Rect inset(float amount) const {
        return inset(amount, amount, amount, amount);
    }

    Rect intersect(Rect o) const {
        auto x0 = max(x, o.x), y0 = max(y, o.y);
        auto x1 = min(x + w, o.x + o.w), y1 = min(y + h, o.y + o.h);
        return Rect(x0, y0, max(0, x1 - x0), max(0, y1 - y0));
    }
}

struct Size {
    float w = 0, h = 0;
}

enum FontRole {
    body,
    small,
    heading,
    title
}

enum SizeClass {
    compact,
    regular,
    wide
}

enum Overflow {
    grow,
    ellipsis,
    scroll
}

enum Align {
    left,
    centre,
    right
}

/// A palette, a type scale and spacing. Every field has a default; a manifest `theme` object
/// overrides any of them: `{"colors": {"accent": "#ffcc66"}, "font_size": 24, "padding": 14}`.
struct Theme {
    uint backdrop = 0x0e1424ff, panel = 0x101a2eee, panelStrong = 0x101a2efa, row = 0x1a2740ee, rowHot = 0x356b80ee,
    rowSelected = 0x2a4f66ee, accent = 0x9bdbd9ff, text = 0xffffffff, dim = 0x9aa7bbff, locked = 0x6b7587ff,
    good = 0x9fe0a0ff, bad = 0xe8847cff, gold = 0xffe08aff, barBack = 0x243049ff, scrim = 0x000000a0, border = 0x9bdbd9ff;
    float fontBody = 22, fontSmall = 17.5, fontHeading = 32, fontTitle = 54;
    float pad = 12, gap = 8, rowPad = 7, borderWidth = 1, scrollbar = 5;
    float compactWidth = 900, compactHeight = 560, wideWidth = 1500, wideHeight = 820;

    static uint colour(string text, uint fallback) {
        if (text.length < 7 || text[0] != '#')
            return fallback;
        uint value;
        foreach (c; text[1 .. $]) {
            uint digit;
            if (c >= '0' && c <= '9')
                digit = c - '0';
            else if (c >= 'a' && c <= 'f')
                digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                digit = c - 'A' + 10;
            else
                return fallback;
            value = value * 16 + digit;
        }
        return text.length == 7 ? value << 8 | 0xff : value;
    }

    static Theme fromJson(const(JsonValue)* config) {
        Theme theme;
        if (config is null || config.kind != JsonValue.Kind.object)
            return theme;
        if (auto colors = config.get("colors")) {
            void set(string name, ref uint target) {
                if (auto v = colors.get(name))
                    if (v.kind == JsonValue.Kind.string_)
                        target = colour(v.text, target);
            }

            set("backdrop", theme.backdrop);
            set("panel", theme.panel);
            set("panel_strong", theme.panelStrong);
            set("row", theme.row);
            set("row_hot", theme.rowHot);
            set("row_selected", theme.rowSelected);
            set("accent", theme.accent);
            set("text", theme.text);
            set("dim", theme.dim);
            set("locked", theme.locked);
            set("good", theme.good);
            set("bad", theme.bad);
            set("gold", theme.gold);
            set("bar_back", theme.barBack);
            set("scrim", theme.scrim);
            set("border", theme.border);
        }
        void number(string name, ref float target) {
            if (auto v = config.get(name))
                if (v.kind == JsonValue.Kind.number && v.number > 0)
                    target = cast(float) v.number;
        }

        // `font_size` scales the whole type scale; the others set one size.
        if (auto v = config.get("font_size"))
            if (v.kind == JsonValue.Kind.number && v.number >= 8 && v.number <= 96) {
                auto ratio = cast(float) v.number / theme.fontBody;
                theme.fontBody *= ratio;
                theme.fontSmall *= ratio;
                theme.fontHeading *= ratio;
                theme.fontTitle *= ratio;
            }
        number("font_small", theme.fontSmall);
        number("font_heading", theme.fontHeading);
        number("font_title", theme.fontTitle);
        number("padding", theme.pad);
        number("gap", theme.gap);
        number("row_padding", theme.rowPad);
        number("border_width", theme.borderWidth);
        number("compact_width", theme.compactWidth);
        number("compact_height", theme.compactHeight);
        number("wide_width", theme.wideWidth);
        number("wide_height", theme.wideHeight);
        return theme;
    }
}

struct UiEvent {
    int type; // the bridge's: 2 advance, 3 backspace, 4 text, 5 click, 6 key, 7 motion, 8 wheel
    int key;
    float x = 0, y = 0;
    string text;
}

private struct WidgetState {
    float scroll = 0; // the reader's own offset
    ulong hoverSince; // when the pointer came to rest on the widget (0: not hovered)
}

/// The window, the theme, the text cache and the per-widget state.
final class Ui {
    Theme theme;
    void* fontBody, fontHeading;
    float pixelScale = 1; // pixels per point of the display
    float userScale = 1; // the player's text-size setting
    int width, height; // output pixels
    float mouseX = -10000, mouseY = -10000;
    bool mouseLive = true; // false while drawing what a modal covers
    ulong now;
    SizeClass forced; // when `isForced`, the player's layout choice
    bool isForced;

    private void*[string] textures;
    private string[string] fitted;
    private WidgetState[string] states;
    private Rect[] clips;

    /// A small or large window scales the interface a little on its own (within 0.75 to 1.25);
    /// `userScale` is the player's text-size setting on top of that.
    float autoFit = 1;

    @property float scale() const {
        return pixelScale * userScale * autoFit;
    }

    float u(float units) const {
        return units * scale;
    }

    /// The window in design units.
    @property Size units() const {
        return Size(width / scale, height / scale);
    }

    SizeClass sizeClass() const {
        if (isForced)
            return forced;
        auto s = units;
        if (s.w < theme.compactWidth || s.h < theme.compactHeight)
            return SizeClass.compact;
        if (s.w >= theme.wideWidth && s.h >= theme.wideHeight)
            return SizeClass.wide;
        return SizeClass.regular;
    }

    ref WidgetState state(string id) {
        return states.require(id, WidgetState.init);
    }

    // ---- text ----------------------------------------------------------------------

    float fontPx(FontRole role) const {
        final switch (role) {
        case FontRole.body:
            return theme.fontBody * scale;
        case FontRole.small:
            return theme.fontSmall * scale;
        case FontRole.heading:
            return theme.fontHeading * scale;
        case FontRole.title:
            return theme.fontTitle * scale;
        }
    }

    bool hasRuby(string text) {
        if (text.length < 5)
            return false;
        bool hasOpen = false;
        foreach (i; 0 .. text.length) {
            if (cast(ubyte) text[i] == 0xE3 && i + 2 < text.length && cast(ubyte) text[i + 1] == 0x80) {
                if (cast(ubyte) text[i + 2] == 0x8A)
                    hasOpen = true;
                else if (cast(ubyte) text[i + 2] == 0x8B && hasOpen)
                    return true;
            }
        }
        return false;
    }

    string wrapText(string text, FontRole role, float wrap) {
        if (wrap <= 0 || !text.length)
            return text;
        auto initial = measure(text, role, 0);
        if (initial.w <= wrap)
            return text;

        import varis.narrative.text : lineBreakOpportunities;

        auto opps = lineBreakOpportunities(text);
        if (opps.length == 0)
            return text;

        string result = "";
        size_t lineStart = 0;
        size_t lastBreak = 0;

        foreach (cut; opps) {
            string currentLine = text[lineStart .. cut];
            if (measure(currentLine, role, 0).w > wrap) {
                if (lastBreak > lineStart) {
                    result ~= text[lineStart .. lastBreak] ~ "\n";
                    lineStart = lastBreak;
                    if (lineStart < text.length && text[lineStart] == ' ')
                        lineStart++;
                } else {
                    result ~= text[lineStart .. cut] ~ "\n";
                    lineStart = cut;
                    if (lineStart < text.length && text[lineStart] == ' ')
                        lineStart++;
                }
            }
            lastBreak = cut;
        }
        if (lineStart < text.length) {
            string rem = text[lineStart .. $];
            if (measure(rem, role, 0).w > wrap && lastBreak > lineStart) {
                result ~= text[lineStart .. lastBreak] ~ "\n";
                result ~= text[lastBreak .. $];
            } else {
                result ~= rem;
            }
        }
        return result;
    }

    private void* texture(string text, FontRole role, float wrap) {
        if (!text.length)
            return null;
        if (wrap > 0)
            text = wrapText(text, role, wrap);
        auto px = fontPx(role);
        auto key = format("%d|%d|%d|", cast(int)(px * 4), cast(int) wrap, role == FontRole.heading || role == FontRole
                .title) ~
            text;
        if (auto found = key in textures)
            return *found;
        if (textures.length > 1500) {
            foreach (t; textures)
                v_free(t);
            textures = null;
            fitted = null;
        }
        auto font = (role == FontRole.heading || role == FontRole.title) && fontHeading !is null ? fontHeading
            : fontBody;
        // Text is rendered white and tinted when drawn, so one texture serves every colour.
        auto t = v_text(font, text.toStringz, px, wrap > 0 ? cast(int) wrap : 0, 0xffffffff);
        textures[key] = t;
        return t;
    }

    Size measureRuby(string text, FontRole role, float wrap = 0) {
        import varis.narrative.text : rubySpans;

        auto spans = rubySpans(text);
        float totalW = 0;
        float baseH = fontPx(role) * 1.2f;
        float rubyH = fontPx(FontRole.small) * 1.0f;
        foreach (ref s; spans) {
            auto baseW = measure(s.text, role, 0).w;
            if (s.reading.length) {
                auto rubyW = measure(s.reading, FontRole.small, 0).w;
                totalW += max(baseW, rubyW);
            } else {
                totalW += baseW;
            }
        }
        return Size(totalW, baseH + rubyH * 0.8f);
    }

    void drawRuby(string text, FontRole role, float x, float y, float wrap, uint colour) {
        import varis.narrative.text : rubySpans;

        auto spans = rubySpans(text);
        float curX = x;
        auto rubyOffset = fontPx(FontRole.small) * 0.85f;

        foreach (ref s; spans) {
            auto baseSize = measure(s.text, role, 0);
            if (s.reading.length) {
                auto rubySize = measure(s.reading, FontRole.small, 0);
                float spanW = max(baseSize.w, rubySize.w);
                float rubyX = curX + (spanW - rubySize.w) / 2;
                float baseX = curX + (spanW - baseSize.w) / 2;
                drawText(s.reading, FontRole.small, rubyX, y, 0, colour);
                drawText(s.text, role, baseX, y + rubyOffset, 0, colour);
                curX += spanW;
            } else {
                drawText(s.text, role, curX, y + rubyOffset, 0, colour);
                curX += baseSize.w;
            }
        }
    }

    /// The size text needs: wrapped at `wrap` pixels when `wrap` > 0, else only at newlines.
    Size measure(string text, FontRole role, float wrap = 0) {
        if (hasRuby(text))
            return measureRuby(text, role, wrap);
        auto t = texture(text, role, wrap);
        if (t is null)
            return Size(0, fontPx(role) * 1.2f);
        float w, h;
        v_texture_size(t, &w, &h);
        return Size(w, h);
    }

    void drawText(string text, FontRole role, float x, float y, float wrap, uint colour) {
        if (hasRuby(text)) {
            drawRuby(text, role, x, y, wrap, colour);
            return;
        }
        auto t = texture(text, role, wrap);
        if (t !is null)
            v_draw(t, x, y, 0, 0, 2, colour);
    }

    /// `text` cut to fit `width` pixels on one line, with an ellipsis when it was cut.
    string fit(string text, FontRole role, float width) {
        if (measure(text, role).w <= width)
            return text;
        auto key = format("%d|%d|", cast(int)(fontPx(role) * 4), cast(int) width) ~ text;
        if (auto found = key in fitted)
            return *found;
        // Longest prefix, by code points, that fits with the ellipsis.
        size_t[] cuts;
        foreach (i, c; text)
            cuts ~= i;
        size_t lo, hi = cuts.length;
        while (lo < hi) {
            auto mid = (lo + hi + 1) / 2;
            if (measure(text[0 .. cuts[mid - 1] + charLength(text, cuts[mid - 1])] ~ "…", role).w <= width)
                lo = mid;
            else
                hi = mid - 1;
        }
        string result = lo == 0 ? "…" : text[0 .. cuts[lo - 1] + charLength(text, cuts[lo - 1])] ~ "…";
        fitted[key] = result;
        return result;
    }

    private static size_t charLength(string text, size_t at) {
        size_t n = 1;
        while (at + n < text.length && (text[at + n] & 0xc0) == 0x80)
            ++n;
        return n;
    }

    // ---- primitives ----------------------------------------------------------------

    void fill(Rect r, uint colour) {
        if ((colour & 0xff) && r.w > 0 && r.h > 0)
            v_rect(r.x, r.y, r.w, r.h, colour);
    }

    void outline(Rect r, uint colour) {
        if ((colour & 0xff) && r.w > 0 && r.h > 0)
            v_outline(r.x, r.y, r.w, r.h, colour);
    }

    void image(void* tex, Rect r, int fit, uint tint = 0xffffffff) {
        if (tex !is null)
            v_draw(tex, r.x, r.y, r.w, r.h, fit, tint);
    }

    void pushClip(Rect r) {
        auto clipped = clips.length ? clips[$ - 1].intersect(r) : r;
        clips ~= clipped;
        v_clip(cast(int) clipped.x, cast(int) clipped.y, cast(int)(clipped.w + 0.999f), cast(int)(clipped.h + 0.999f));
        if (clipped.w <= 0 || clipped.h <= 0)
            v_clip(0, 0, 1, 1);
    }

    void popClip() {
        clips.length--;
        if (clips.length) {
            auto c = clips[$ - 1];
            v_clip(cast(int) c.x, cast(int) c.y, cast(int)(c.w + 0.999f), cast(int)(c.h + 0.999f));
        } else
            v_clip(0, 0, 0, 0);
    }

    bool hover(Rect r) const {
        return mouseLive && r.contains(mouseX, mouseY);
    }

    void release() {
        foreach (t; textures)
            v_free(t);
        textures = null;
        fitted = null;
    }
}

// =============================================================================
// Widgets
// =============================================================================

abstract class Widget {
    string id;
    Rect rect;
    float flex = 0; // share of leftover room in a Box
    bool visible = true;

    /// The size wanted when offered at most `maxW` x `maxH` pixels.
    abstract Size measure(Ui ui, float maxW, float maxH);

    /// The least height this widget can be squeezed to (labels that scroll, scroll boxes).
    float minHeight(Ui ui) {
        return 0;
    }

    /// Shrinkable widgets give up room before others do.
    bool shrinkable() {
        return false;
    }

    void arrange(Ui ui, Rect r) {
        rect = r;
    }

    abstract void draw(Ui ui);

    /// Offers an event to the widget; true means it was used.
    bool event(Ui ui, ref UiEvent e) {
        return false;
    }
}

/// Lays children out in a column or a row, with an optional background and border.
class Box : Widget {
    Widget[] kids;
    bool vertical = true;
    float gap = -1; // design units; negative: the theme's
    float pad = 0; // design units
    uint background, border;
    float widthUnits = 0, heightUnits = 0; // a fixed size, in design units (0: natural)
    float heightPx = 0; // a fixed height in pixels (0: natural)
    bool fillCross = true; // children take the box's full cross size
    Align crossAlign = Align.left; // used when !fillCross

    this(bool vertical = true) {
        this.vertical = vertical;
    }

    Box add(Widget w, float flex = 0) {
        if (w is null)
            return this;
        w.flex = flex > 0 ? flex : w.flex;
        kids ~= w;
        return this;
    }

    private float gapPx(Ui ui) const {
        return ui.u(gap < 0 ? ui.theme.gap : gap);
    }

    override bool shrinkable() {
        foreach (k; kids)
            if (k.visible && k.shrinkable)
                return true;
        return false;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        auto s = measureContent(ui, maxW, maxH);
        if (widthUnits > 0)
            s.w = min(maxW, ui.u(widthUnits));
        if (heightUnits > 0)
            s.h = min(maxH, ui.u(heightUnits));
        if (heightPx > 0)
            s.h = min(maxH, heightPx);
        return s;
    }

    private Size measureContent(Ui ui, float maxW, float maxH) {
        auto p = ui.u(pad);
        auto g = gapPx(ui);
        auto innerW = max(0, maxW - 2 * p), innerH = max(0, maxH - 2 * p);
        float main = 0, cross = 0;
        size_t count;
        if (vertical) {
            foreach (k; kids) {
                if (!k.visible)
                    continue;
                auto s = k.measure(ui, innerW, innerH);
                main += s.h;
                cross = max(cross, s.w);
                ++count;
            }
            if (count > 1)
                main += g * (count - 1);
            return Size(fillCross ? maxW : min(maxW, cross + 2 * p), main + 2 * p);
        }
        float fixed, flexSum = 0;
        foreach (k; kids) {
            if (!k.visible)
                continue;
            if (k.flex > 0)
                flexSum += k.flex;
            ++count;
        }
        float gaps = count > 1 ? g * (count - 1) : 0;
        foreach (k; kids)
            if (k.visible && k.flex <= 0) {
                auto s = k.measure(ui, innerW, innerH);
                fixed += s.w;
                cross = max(cross, s.h);
            }
        auto left = max(0, innerW - fixed - gaps);
        foreach (k; kids)
            if (k.visible && k.flex > 0) {
                auto s = k.measure(ui, left * k.flex / flexSum, innerH);
                cross = max(cross, s.h);
            }
        return Size(flexSum > 0 ? maxW : min(maxW, fixed + gaps + 2 * p), cross + 2 * p);
    }

    override float minHeight(Ui ui) {
        if (heightPx > 0)
            return heightPx;
        if (heightUnits > 0)
            return ui.u(heightUnits);
        auto p = ui.u(pad);
        float total = 2 * p;
        auto g = gapPx(ui);
        bool first = true;
        if (vertical) {
            foreach (k; kids) {
                if (!k.visible)
                    continue;
                total += (first ? 0 : g) + (k.shrinkable ? k.minHeight(ui) : naturalHeight(ui, k));
                first = false;
            }
            return total;
        }
        float tallest;
        foreach (k; kids)
            if (k.visible)
                tallest = max(tallest, k.shrinkable ? k.minHeight(ui) : naturalHeight(ui, k));
        return total + tallest;
    }

    private float naturalHeight(Ui ui, Widget k) {
        return k.measure(ui, rect.w > 0 ? rect.w : 100000, 100000).h;
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        auto inner = r.inset(ui.u(pad));
        auto g = gapPx(ui);
        Widget[] live;
        foreach (k; kids)
            if (k.visible)
                live ~= k;
        if (!live.length)
            return;
        auto gaps = g * (live.length - 1);
        if (vertical) {
            auto heights = new float[live.length];
            float total = gaps, flexSum = 0;
            foreach (i, k; live) {
                heights[i] = k.measure(ui, inner.w, inner.h).h;
                total += heights[i];
                if (k.flex > 0)
                    flexSum += k.flex;
            }
            share(ui, live, heights, total, inner.h, flexSum, true);
            float y = inner.y;
            foreach (i, k; live) {
                k.arrange(ui, Rect(inner.x, y, inner.w, heights[i]));
                y += heights[i] + g;
            }
            return;
        }
        auto widths = new float[live.length];
        float total = gaps, flexSum = 0;
        foreach (i, k; live) {
            if (k.flex > 0) {
                flexSum += k.flex;
                continue;
            }
            widths[i] = k.measure(ui, inner.w, inner.h).w;
            total += widths[i];
        }
        auto room = max(0, inner.w - total);
        float x = inner.x;
        foreach (i, k; live) {
            if (k.flex > 0)
                widths[i] = flexSum > 0 ? room * k.flex / flexSum : 0;
            float h = inner.h;
            if (!fillCross)
                h = min(inner.h, k.measure(ui, widths[i], inner.h).h);
            k.arrange(ui, Rect(x, inner.y, widths[i], h));
            x += widths[i] + g;
        }
    }

    /// Gives flex children the room left over, or takes missing room from shrinkable children.
    private void share(Ui ui, Widget[] live, float[] sizes, float total, float available, float flexSum, bool vertical) {
        if (total < available && flexSum > 0) {
            auto extra = available - total;
            foreach (i, k; live)
                if (k.flex > 0)
                    sizes[i] += extra * k.flex / flexSum;
            return;
        }
        if (total <= available)
            return;
        auto excess = total - available;
        foreach (round; 0 .. 4) {
            float room = 0;
            auto spare = new float[live.length];
            foreach (i, k; live) {
                if (!k.shrinkable)
                    continue;
                spare[i] = max(0, sizes[i] - k.minHeight(ui));
                room += spare[i];
            }
            if (room <= 0 || excess <= 0)
                break;
            auto take = min(excess, room);
            foreach (i; 0 .. live.length)
                if (spare[i] > 0) {
                    auto cut = take * spare[i] / room;
                    sizes[i] -= cut;
                    excess -= cut;
                }
        }
        // Last resort: squeeze the flexible children, then anything.
        if (excess > 0)
            foreach_reverse (i, k; live) {
                auto cut = min(excess, max(0, sizes[i]));
                sizes[i] -= cut;
                excess -= cut;
                if (excess <= 0)
                    break;
            }
    }

    override void draw(Ui ui) {
        ui.fill(rect, background);
        foreach (k; kids)
            if (k.visible)
                k.draw(ui);
        if (border)
            ui.outline(rect, border);
    }

    override bool event(Ui ui, ref UiEvent e) {
        foreach_reverse (k; kids)
            if (k.visible && k.event(ui, e))
                return true;
        return false;
    }
}

/// Children drawn one over another, each given the whole rectangle (a root, a modal layer).
final class Stack : Widget {
    Widget[] kids;

    Stack add(Widget w) {
        if (w !is null)
            kids ~= w;
        return this;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, maxH);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        foreach (k; kids)
            if (k.visible)
                k.arrange(ui, r);
    }

    override void draw(Ui ui) {
        foreach (k; kids)
            if (k.visible)
                k.draw(ui);
    }

    override bool event(Ui ui, ref UiEvent e) {
        foreach_reverse (k; kids)
            if (k.visible && k.event(ui, e))
                return true;
        return false;
    }
}

/// Fixed or flexible empty space.
final class Spacer : Widget {
    float width = 0, height = 0; // design units

    this(float width = 0, float height = 0, float flex = 0) {
        this.width = width;
        this.height = height;
        this.flex = flex;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(min(maxW, ui.u(width)), ui.u(height));
    }

    override float minHeight(Ui ui) {
        return ui.u(height);
    }

    override void draw(Ui ui) {
    }
}

/// Text in a box. See the module comment for the overflow policies.
class Label : Widget {
    string text;
    FontRole role = FontRole.body;
    uint colour;
    bool wrap = true;
    Overflow overflow = Overflow.grow;
    Align alignment = Align.left;
    bool grabsWheel = true; // a scrolling label takes the wheel while the pointer is over it

    this(string text, FontRole role = FontRole.body, uint colour = 0) {
        this.text = text;
        this.role = role;
        this.colour = colour;
    }

    private string key() const {
        return id.length ? id : "label:" ~ text[0 .. min(text.length, 40)];
    }

    override bool shrinkable() {
        return overflow != Overflow.grow;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        auto s = ui.measure(text, role, wrap ? maxW : 0);
        if (overflow != Overflow.grow)
            s.w = min(s.w, maxW);
        return s;
    }

    override float minHeight(Ui ui) {
        return overflow == Overflow.grow ? ui.measure(text, role, wrap ? rect.w : 0).h : ui.measure("Ag", role).h;
    }

    override void draw(Ui ui) {
        if (!text.length)
            return;
        auto c = colour ? colour : ui.theme.text;
        auto size = ui.measure(text, role, wrap ? rect.w : 0);
        float x = rect.x;
        if (alignment == Align.centre)
            x += (rect.w - size.w) / 2;
        else if (alignment == Align.right)
            x += rect.w - size.w;
        bool tooTall = size.h > rect.h + 1, tooWide = size.w > rect.w + 1;
        if (!tooTall && !tooWide) {
            ui.drawText(text, role, x, rect.y, wrap ? rect.w : 0, c);
            return;
        }
        if (overflow == Overflow.grow) {
            ui.pushClip(rect);
            ui.drawText(text, role, rect.x, rect.y, wrap ? rect.w : 0, c);
            ui.popClip();
            return;
        }
        auto st = &ui.state(key());
        bool hot = ui.hover(rect);
        if (!hot)
            st.hoverSince = 0;
        else if (!st.hoverSince)
            st.hoverSince = ui.now;
        if (!wrap && tooWide) {
            // One line: cut with an ellipsis, and slid sideways while the pointer rests on it.
            if (!hot) {
                ui.drawText(ui.fit(text, role, rect.w), role, rect.x, rect.y, 0, c);
                return;
            }
            auto travel = size.w - rect.w;
            auto t = cast(float)(ui.now - st.hoverSince) / 1000.0f;
            auto phase = max(0, t - 0.4f) * ui.u(70);
            auto cycle = travel * 2 + ui.u(80);
            auto at = phase - cycle * cast(int)(phase / cycle);
            auto offset = at < travel ? at : (at < travel + ui.u(40) ? travel : (at < cycle - ui.u(40) ? cycle - ui.u(
                    40) - at : 0));
            ui.pushClip(rect);
            ui.drawText(text, role, rect.x - max(0, min(offset, travel)), rect.y, 0, c);
            ui.popClip();
            return;
        }
        // Several lines in a box too short for them: clipped, scrolled by the wheel and, resting
        // under the pointer, slowly on its own.
        auto travel = size.h - rect.h;
        auto manual = st.scroll;
        auto t = hot ? cast(float)(ui.now - st.hoverSince) / 1000.0f : 0;
        auto auto_ = hot ? max(0, t - 0.8f) * ui.u(26) : 0;
        auto offset = max(0, min(travel, manual + auto_));
        ui.pushClip(rect);
        ui.drawText(text, role, x, rect.y - offset, wrap ? rect.w : 0, c);
        ui.popClip();
        // A thin thumb shows that there is more.
        auto bar = ui.u(ui.theme.scrollbar);
        auto thumb = max(ui.u(18), rect.h * rect.h / size.h);
        auto top = rect.y + (rect.h - thumb) * (travel > 0 ? offset / travel : 0);
        ui.fill(Rect(rect.x + rect.w - bar, top, bar, thumb), (ui.theme.accent & 0xffffff00) | 0x90);
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (e.type != 8 || overflow != Overflow.scroll || !grabsWheel || !ui.hover(rect))
            return false;
        auto size = ui.measure(text, role, wrap ? rect.w : 0);
        if (size.h <= rect.h + 1)
            return false;
        auto st = &ui.state(key());
        auto step = ui.fontPx(role) * 1.5f;
        st.scroll = max(0, min(size.h - rect.h, st.scroll - e.key * step));
        st.hoverSince = ui.now; // reading by hand pauses the automatic scroll
        return true;
    }
}

/// A clickable row: an optional prefix (a number), a label that ellipsises and slides, and a
/// right-hand hint ("locked").
final class Button : Widget {
    string text, prefix, hint;
    string detail; // a second, quieter paragraph under the label (what the row means)
    FontRole role = FontRole.small;
    bool enabled = true, selected;
    bool fit; // as wide as its text needs rather than the row it is offered (a toolbar button)
    bool locked; // drawn as unavailable but still answers a click (the player is told why)
    bool wrap; // wrap onto several lines (menu answers) instead of ellipsising
    Align alignment = Align.left;
    void delegate() onClick;
    private Label label_;

    this(string text, void delegate() onClick = null) {
        this.text = text;
        this.onClick = onClick;
    }

    private float padPx(Ui ui) {
        return ui.u(ui.theme.rowPad);
    }

    private float prefixWidth(Ui ui) {
        return prefix.length ? ui.measure(prefix, role).w + ui.u(8) : 0;
    }

    private float hintWidth(Ui ui) {
        return hint.length ? ui.measure(hint, role).w + ui.u(12) : 0;
    }

    override bool shrinkable() {
        return false;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        auto inner = maxW - 2 * padPx(ui) - prefixWidth(ui) - hintWidth(ui);
        auto s = ui.measure(text.length ? text : " ", role, wrap ? inner : 0);
        auto w = fit ? min(maxW, s.w + 2 * padPx(ui) + prefixWidth(ui) + hintWidth(ui)) : maxW;
        auto extra = detail.length ? ui.measure(detail, FontRole.small, max(0, inner)).h + ui.u(3) : 0;
        return Size(w, s.h + extra + 2 * padPx(ui));
    }

    override void draw(Ui ui) {
        bool hot = enabled && ui.hover(rect);
        ui.fill(rect, hot ? ui.theme.rowHot : (selected ? ui.theme.rowSelected : ui.theme.row));
        auto colour = enabled && !locked ? ui.theme.text : ui.theme.locked;
        auto pad = padPx(ui);
        auto inner = rect.inset(pad, pad, pad, pad);
        float x = inner.x;
        if (prefix.length) {
            ui.drawText(prefix, role, x, inner.y, 0, enabled && !locked ? ui.theme.dim : ui.theme.locked);
            x += prefixWidth(ui);
        }
        float right = inner.x + inner.w;
        if (hint.length) {
            auto hw = ui.measure(hint, role).w;
            ui.drawText(hint, role, right - hw, inner.y, 0, ui.theme.locked);
            right -= hintWidth(ui);
        }
        if (label_ is null)
            label_ = new Label("");
        label_.id = id.length ? id : "button:" ~ text[0 .. min(text.length, 40)];
        label_.text = text;
        label_.role = role;
        label_.colour = colour;
        label_.wrap = wrap;
        label_.overflow = wrap ? Overflow.grow : Overflow.ellipsis;
        label_.alignment = alignment;
        auto labelH = ui.measure(text.length ? text : " ", role, wrap ? max(0, right - x) : 0).h;
        label_.arrange(ui, Rect(x, inner.y, max(0, right - x), min(inner.h, labelH)));
        label_.draw(ui);
        if (detail.length)
            ui.drawText(detail, FontRole.small, x, inner.y + labelH + ui.u(3), max(0, right - x),
                    enabled && !locked ? ui.theme.dim : ui.theme.locked);
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (e.type == 5 && ui.hover(rect) && enabled && onClick !is null) {
            onClick();
            return true;
        }
        return false;
    }
}

/// A horizontal meter.
final class Bar : Widget {
    float value, low, high;
    uint colour;
    float thickness = 9; // units

    this(float value, float low, float high, uint colour = 0) {
        this.value = value;
        this.low = low;
        this.high = high;
        this.colour = colour;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, ui.u(thickness));
    }

    override float minHeight(Ui ui) {
        return ui.u(thickness);
    }

    override void draw(Ui ui) {
        ui.fill(rect, ui.theme.barBack);
        auto span = high - low;
        auto f = span > 0 ? (value - low) / span : 0;
        f = max(0, min(1, f));
        ui.fill(Rect(rect.x, rect.y, rect.w * f, rect.h), colour ? colour : ui.theme.accent);
    }
}

/// A texture in a box, with a fit: 0 stretch, 1 contain (bottom), 3 cover.
final class ImageBox : Widget {
    void* texture;
    int fit = 1;
    uint tint = 0xffffffff;
    float width, height; // wanted size in units; 0 takes what is offered

    this(void* texture, int fit = 1) {
        this.texture = texture;
        this.fit = fit;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(width > 0 ? min(maxW, ui.u(width)) : maxW, height > 0 ? min(maxH, ui.u(height)) : 0);
    }

    override float minHeight(Ui ui) {
        return 0;
    }

    override bool shrinkable() {
        return true;
    }

    override void draw(Ui ui) {
        ui.pushClip(rect);
        ui.image(texture, rect, fit, tint);
        ui.popClip();
    }
}

/// One child taller than the box, scrolled with the wheel; the thumb shows where you are.
final class ScrollBox : Widget {
    Widget child;
    Widget revealTarget; // a descendant to bring into view on the next arrange
    private float contentHeight;

    this(Widget child) {
        this.child = child;
    }

    override bool shrinkable() {
        return true;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        auto bar = ui.u(ui.theme.scrollbar) + ui.u(3);
        auto s = child.measure(ui, max(0, maxW - bar), 100000);
        return Size(maxW, s.h);
    }

    override float minHeight(Ui ui) {
        return ui.u(40);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        auto bar = ui.u(ui.theme.scrollbar) + ui.u(3);
        auto s = child.measure(ui, max(0, r.w - bar), 100000);
        contentHeight = s.h;
        auto st = &ui.state(id.length ? id : "scroll");
        auto overflow = max(0, contentHeight - r.h);
        st.scroll = max(0, min(overflow, st.scroll));
        auto content = Rect(r.x, r.y - st.scroll, max(0, r.w - (overflow > 0 ? bar : 0)), max(contentHeight, r.h));
        child.arrange(ui, content);
        if (revealTarget !is null) {
            // Where the target sits in the content now; move the view the least that shows it.
            auto top = revealTarget.rect.y - content.y, bottom = top + revealTarget.rect.h;
            auto wanted = st.scroll;
            if (top < wanted)
                wanted = top;
            else if (bottom > wanted + r.h)
                wanted = bottom - r.h;
            wanted = max(0, min(overflow, wanted));
            if (wanted != st.scroll) {
                st.scroll = wanted;
                content.y = r.y - st.scroll;
                child.arrange(ui, content);
            }
            revealTarget = null;
        }
    }

    override void draw(Ui ui) {
        ui.pushClip(rect);
        child.draw(ui);
        ui.popClip();
        auto st = &ui.state(id.length ? id : "scroll");
        auto overflow = contentHeight - rect.h;
        if (overflow > 0) {
            auto bar = ui.u(ui.theme.scrollbar);
            auto thumb = max(ui.u(24), rect.h * rect.h / contentHeight);
            auto top = rect.y + (rect.h - thumb) * (st.scroll / overflow);
            ui.fill(Rect(rect.x + rect.w - bar, rect.y, bar, rect.h), ui.theme.barBack);
            ui.fill(Rect(rect.x + rect.w - bar, top, bar, thumb), ui.theme.accent);
        }
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (e.type == 8 && ui.hover(rect)) {
            // A scrolling label under the pointer takes the wheel first.
            if (child.event(ui, e))
                return true;
            auto st = &ui.state(id.length ? id : "scroll");
            st.scroll = max(0, min(max(0, contentHeight - rect.h), st.scroll - e.key * ui.fontPx(FontRole.body) * 2));
            return true;
        }
        return child.event(ui, e);
    }
}

/// A modal: dims what is below, and shows one panel (title, body, close hint) centred in the
/// window at up to `maxW` x `maxH` units. A click outside it calls `onClose`.
final class Modal : Widget {
    Widget body;
    string title;
    float maxW = 900, maxH = 600; // units
    void delegate() onClose;
    private Rect panelRect;
    private Label titleLabel;

    this(string title, Widget body, float maxW = 900, float maxH = 600) {
        this.title = title;
        this.body = body;
        this.maxW = maxW;
        this.maxH = maxH;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, maxH);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        auto w = min(ui.u(maxW), r.w - ui.u(24));
        auto pad = ui.u(ui.theme.pad);
        if (titleLabel is null) {
            titleLabel = new Label(title, FontRole.heading);
            titleLabel.wrap = false;
            titleLabel.overflow = Overflow.ellipsis;
        }
        titleLabel.text = title;
        titleLabel.colour = ui.theme.accent;
        auto titleH = ui.measure(title.length ? title : " ", FontRole.heading).h;
        auto bodyWanted = body.measure(ui, w - 2 * pad, 100000).h;
        auto h = min(min(ui.u(maxH), r.h - ui.u(24)), titleH + bodyWanted + 3 * pad);
        panelRect = Rect(r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h);
        titleLabel.arrange(ui, Rect(panelRect.x + pad, panelRect.y + pad, w - 2 * pad, titleH));
        body.arrange(ui, Rect(panelRect.x + pad, panelRect.y + 2 * pad + titleH, w - 2 * pad, h - titleH - 3 * pad));
    }

    override void draw(Ui ui) {
        ui.fill(rect, ui.theme.scrim);
        ui.fill(panelRect, ui.theme.panelStrong);
        ui.outline(panelRect, ui.theme.border);
        titleLabel.draw(ui);
        body.draw(ui);
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (body.event(ui, e))
            return true;
        if (e.type == 5 && !panelRect.contains(e.x, e.y) && onClose !is null)
            onClose();
        return true; // a modal takes every event: nothing below it can be clicked
    }
}

/// A panel that slides in from the left edge over a dimmed screen: what a small window hides.
final class Drawer : Widget {
    Widget body;
    float widthUnits = 330;
    void delegate() onClose;
    private Rect panelRect;

    this(Widget body) {
        this.body = body;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, maxH);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        auto w = min(ui.u(widthUnits), r.w * 0.86f);
        panelRect = Rect(r.x, r.y, w, r.h);
        body.arrange(ui, panelRect.inset(ui.u(ui.theme.pad)));
    }

    override void draw(Ui ui) {
        ui.fill(rect, ui.theme.scrim);
        ui.fill(panelRect, ui.theme.panelStrong);
        ui.fill(Rect(panelRect.x + panelRect.w - 1, panelRect.y, 1, panelRect.h), ui.theme.border);
        body.draw(ui);
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (body.event(ui, e))
            return true;
        if (e.type == 5 && !panelRect.contains(e.x, e.y) && onClose !is null)
            onClose();
        return true;
    }
}

/// Fills its rectangle with a background (a colour, an image or both), then draws a child.
final class Backdrop : Widget {
    void* texture;
    uint colour;
    uint overlay; // a tint over the picture (the time of day)

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, maxH);
    }

    override void draw(Ui ui) {
        ui.fill(rect, colour);
        ui.image(texture, rect, 3);
        ui.fill(rect, overlay);
    }
}

/// Draws a widget under the same arrangement while the pointer is hidden from it: what is
/// below a modal still draws, but does not light up.
final class Dimmed : Widget {
    Widget inner;

    this(Widget inner) {
        this.inner = inner;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return inner.measure(ui, maxW, maxH);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        inner.arrange(ui, r);
    }

    override void draw(Ui ui) {
        auto live = ui.mouseLive;
        ui.mouseLive = false;
        inner.draw(ui);
        ui.mouseLive = live;
    }

    override bool event(Ui ui, ref UiEvent e) {
        return false;
    }
}

/// Runs one frame of layout for a tree: the root owns the whole window.
void layout(Ui ui, Widget root) {
    root.arrange(ui, Rect(0, 0, ui.width, ui.height));
}
