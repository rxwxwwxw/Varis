/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The 2.5D battle view of the SDL3 player (TOWER_DEFENSE_PLAN.md §7, TD4-TD5): pointy-top hexes
/// drawn as flat-shaded prisms in painter's order, with terrace heights lifting the ground;
/// towers, heroes and enemies as billboards; fog; four zoom bands; a camera with zoom about the
/// cursor, pan and fit; picking (units first, then the elevated tile under the pointer).
///
/// The view only reads the simulation (`Battle`'s arrays) and the player's commands go through
/// `GameHost.battleCommand`. Nothing here is saved, and nothing here affects the digest.
module tools.sdl.battleview;

import tools.sdl.native;
import tools.sdl.ui;
import varis.game.battle;
import varis.game.fog;
import varis.game.hex : hexDistance, neighbourOffsets, regionIndex;
import varis.game.kinds;
import varis.game.route : unreachable;
import varis.game.types;
import varis.services.gamehost;
import std.algorithm : max, min;
import std.format : format;
import std.math : sqrt, floor, abs;

private enum float sq3 = 1.7320508f;
/// Screen squash of the ground plane: the 2.5D tilt.
private enum float tilt = 0.62f;
/// World units a terrace level lifts the ground.
private enum float levelLift = 0.55f;
/// World units of cliff above a wall tile's ground.
private enum float cliffLift = 0.9f;

/// Zoom bands (plan §7.3): what is drawn depends on pixels per world unit.
enum ZoomBand {
    overview,
    tactical,
    standard,
    close,
}

ZoomBand bandOf(float zoom) {
    if (zoom < 7)
        return ZoomBand.overview;
    if (zoom < 16)
        return ZoomBand.tactical;
    if (zoom < 40)
        return ZoomBand.standard;
    return ZoomBand.close;
}

/// A short-lived effect of one step: a line from a tower to what it hit, or a ring where
/// something fell.
struct Flash {
    float ax, ay, bx, by; // world positions (before projection)
    int life;
    int kind; // 0 hit, 1 death, 2 ruin, 3 ability
    uint colour;
}

/// What the view remembers between frames. The widget tree is rebuilt every frame; this is not.
final class BattleViewState {
    float camX = 0, camY = 0; // world position at the centre of the canvas (tilted ground space)
    float zoom = 14;
    bool fitted;
    int selectedId = -1; // a structure or hero id
    int placeKind = -1; // a tower kind (0-based) waiting for a tile
    bool targeting; // a hero ability waits for a tile
    int hoverQ = -1, hoverR = -1;
    string notice;
    ulong noticeAt;
    Flash[] flashes;
    double stepDebt = 0;
    ulong lastTick;
    ulong lastStepCount;
    bool panLeft, panRight, panUp, panDown;
    // a press on the map: a click if it ends where it began, a pan if it moves
    bool pressed, moved;
    float pressX, pressY, lastX, lastY;
    /// Set by the canvas when it handled a command that changed the world (autosave hooks).
    bool dirty;
    // a moment takes the camera to the character concerned, then gives it back
    bool hasSaved, easing;
    /// The first fit of a battle pulls in from the overview (the intro pan of plan §7.3).
    bool intro = true;
    float savedX, savedY, savedZoom, goalX, goalY, goalZoom;
    /// The whole map as one texture, one pixel a tile (plan §7.3): rebuilt only when the fog
    /// or the battle changes, and used for the overview band and the minimap of a large map.
    void* overview;
    int overviewWidth, overviewHeight;
    ulong overviewKey;
    int overviewBuilds;

    ~this() {
        if (overview !is null)
            v_free(overview);
    }

    void say(string text, ulong now) {
        notice = text;
        noticeAt = now;
    }

    /// Remembers the camera and eases toward a point (world, tilted ground space).
    void takeCamera(float x, float y, float zoomGoal) {
        if (!hasSaved) {
            savedX = camX;
            savedY = camY;
            savedZoom = zoom;
            hasSaved = true;
        }
        goalX = x;
        goalY = y;
        goalZoom = zoomGoal;
        easing = true;
    }

    void returnCamera() {
        if (!hasSaved)
            return;
        goalX = savedX;
        goalY = savedY;
        goalZoom = savedZoom;
        easing = true;
        hasSaved = false;
    }

    /// One frame of easing: closes a fraction of the gap to the goal.
    void ease() {
        if (!easing)
            return;
        immutable k = 0.16f;
        camX += (goalX - camX) * k;
        camY += (goalY - camY) * k;
        zoom += (goalZoom - zoom) * k;
        if (abs(goalX - camX) < 0.02f && abs(goalY - camY) < 0.02f && abs(goalZoom - zoom) < 0.05f)
            easing = false;
    }

    void reset() {
        intro = true;
        hasSaved = false;
        easing = false;
        fitted = false;
        selectedId = -1;
        placeKind = -1;
        targeting = false;
        flashes = null;
        stepDebt = 0;
        lastTick = 0;
        notice = "";
    }
}

/// World position (before tilt) of a tile centre.
private void tileWorld(int q, int r, out float wx, out float wy) {
    wx = sq3 * (q + r * 0.5f);
    wy = 1.5f * r;
}

/// The canvas: draws the battle and takes pointer input. The HUD is toolkit widgets above it.
final class BattleCanvas : Widget {
    GameHost host;
    BattleViewState state;
    /// Hero colours by hero id modulo 10 (the sample's heroes are 9001..9003).
    private enum uint[] heroColours = [0xf0a050ff, 0x5090e0ff, 0xd05080ff, 0x70c080ff, 0xc0c050ff];
    private enum uint[] towerColours = [
        0xe8c050ff, 0x6fb8e8ff, 0xa0e0e8ff, 0xc880f0ff, 0xffd870ff,
        0xe0d0b0ff, 0x80d090ff, 0xe08060ff, 0xff9040ff, 0x60b0ff, 0xffe080ff, 0xd6a050ff, 0x9a7a5aff,
        0x8aa06aff, 0xff9040ff, 0x80d090ff
    ];
    private enum uint[] enemyColours = [0xa070d8ff, 0xe06a90ff, 0x907050ff, 0x60d8d0ff, 0xe848b8ff];
    private enum uint[] levelColours = [
        0x3f5252ff, 0x587a5aff, 0x7a9b5eff, 0xa3b868ff, 0xc0c27aff, 0xd9cf91ff,
        0xefe3a8ff, 0xfff4c0ff
    ];

    // per-frame geometry batches
    private float[] xy;
    private uint[] colours;
    private int[] indices;

    this(GameHost host, BattleViewState state) {
        this.host = host;
        this.state = state;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        // the canvas wants whatever is left: its natural height is none
        return Size(maxW, 0);
    }

    override float minHeight(Ui ui) {
        return ui.u(120);
    }

    private ref const(Battle) battle() const {
        return host.battle.battle;
    }

    // ---- camera ----------------------------------------------------------------------

    /// Tilted ground position of a tile centre at its ground level.
    private void ground(int q, int r, out float gx, out float gy) const {
        float wx, wy;
        tileWorld(q, r, wx, wy);
        gx = wx;
        gy = wy * tilt;
    }

    private int levelAt(int q, int r) const {
        return battle.map.heightAt(q, r);
    }

    private bool wallAt(int q, int r) const {
        return battle.map.isWall(q, r);
    }

    /// Screen position of a point on a tile, at `lift` world units above the ground.
    private void screen(float wx, float wy, float lift, out float sx, out float sy) const {
        sx = rect.x + rect.w * 0.5f + (wx - state.camX) * state.zoom;
        sy = rect.y + rect.h * 0.5f + (wy * tilt - state.camY - lift) * state.zoom;
    }

    private void tileScreen(int q, int r, out float sx, out float sy) const {
        float wx, wy;
        tileWorld(q, r, wx, wy);
        immutable lift = levelAt(q, r) * levelLift + (wallAt(q, r) ? cliffLift : 0);
        screen(wx, wy, lift, sx, sy);
    }

    /// More visible tiles than this are drawn from the overview texture, not as prisms (plan §9:
    /// the standard band is budgeted for 6,000 visible tiles).
    static int visibleTileCap = 8000;

    /// Builds the overview texture if the fog or the battle changed since it was made. Pixel
    /// (q + r/2, r) is the tile (q, r), so the parallelogram of the axial map is a plain image.
    void ensureOverview() {
        const b = &battle();
        ulong key = 1469598103934665603UL;
        foreach (v; [
            cast(ulong) b.width, b.height, b.setup.mapSeed, b.setup.wallThreshold,
            b.setup.terraceRows
        ])
            key = (key ^ cast(ulong) v) * 1099511628211UL;
        foreach (v; b.fogStorage)
            key = (key ^ v) * 1099511628211UL;
        if (state.overview !is null && key == state.overviewKey)
            return;
        immutable w = b.width + b.height / 2 + 1, h = b.height;
        auto pixels = new uint[w * h];
        foreach (r; 0 .. b.height)
            foreach (q; 0 .. b.width) {
                immutable t = r * b.width + q;
                uint colour;
                if (!b.revealed[t])
                    colour = ((q + r) & 1) ? 0x141a26ff : 0x121723ff;
                else if (b.wall[t])
                    colour = 0x6a6270ff;
                else {
                    colour = levelColours[min(7, levelAt(q, r))];
                    if ((q + r) & 1)
                        colour = shade(colour, 0.96f);
                }
                pixels[r * w + q + r / 2] = colour;
            }
        if (state.overview !is null)
            v_free(state.overview);
        state.overview = v_pixels(pixels.ptr, w, h);
        state.overviewWidth = w;
        state.overviewHeight = h;
        state.overviewKey = key;
        ++state.overviewBuilds;
    }

    /// Fits the revealed part of the map into the canvas.
    void fit() {
        int q0 = int.max, q1 = -1, r0 = int.max, r1 = -1;
        foreach (r; 0 .. battle.height)
            foreach (q; 0 .. battle.width)
                if (battle.revealed[r * battle.width + q]) {
                    q0 = min(q0, q);
                    q1 = max(q1, q);
                    r0 = min(r0, r);
                    r1 = max(r1, r);
                }
        if (q1 < 0)
            return;
        float ax, ay, bx, by;
        tileWorld(q0, r0, ax, ay);
        tileWorld(q1, r1, bx, by);
        // the parallelogram of the revealed rectangle: use its four corners
        float cx, cy, dx, dy;
        tileWorld(q1, r0, cx, cy);
        tileWorld(q0, r1, dx, dy);
        immutable minX = min(min(ax, bx), min(cx, dx)) - sq3;
        immutable maxX = max(max(ax, bx), max(cx, dx)) + sq3;
        immutable minY = (min(min(ay, by), min(cy, dy)) - 1.5f) * tilt - 3 * levelLift;
        immutable maxY = (max(max(ay, by), max(cy, dy)) + 1.5f) * tilt;
        immutable w = max(1.0f, maxX - minX), h = max(1.0f, maxY - minY);
        state.zoom = max(3.0f, min(rect.w / w, rect.h / h) * 0.96f);
        state.camX = (minX + maxX) * 0.5f;
        state.camY = (minY + maxY) * 0.5f;
        state.fitted = true;
    }

    void zoomAbout(float factor, float px, float py) {
        immutable cx = rect.x + rect.w * 0.5f, cy = rect.y + rect.h * 0.5f;
        immutable wx = state.camX + (px - cx) / state.zoom;
        immutable wy = state.camY + (py - cy) / state.zoom;
        auto next = state.zoom * factor;
        next = max(3.0f, min(90.0f, next));
        state.zoom = next;
        state.camX = wx - (px - cx) / next;
        state.camY = wy - (py - cy) / next;
    }

    void pan(float dx, float dy) {
        state.camX += dx / state.zoom;
        state.camY += dy / state.zoom;
    }

    /// The world position, in tilted ground space, of a tile centre at its lifted height.
    void focusOn(int q, int r, float zoomGoal) {
        float wx, wy;
        tileWorld(q, r, wx, wy);
        state.takeCamera(wx, wy * tilt - (levelAt(q, r) * levelLift), zoomGoal);
    }

    /// Where the camera goes for the moment that just fired: the hero or structure the trigger
    /// names, else the Lantern.
    void focusOnMoment() {
        if (host.battle is null)
            return;
        if (!state.fitted)
            fit();
        const b = &battle();
        int tile = b.sinkTile.length ? b.sinkTile[0] : 0;
        if (b.firedMoment >= 0) {
            immutable m = b.setup.moments[b.firedMoment];
            int unit = -1;
            switch (m.trigger) {
            case Trigger.heroHpBelow:
            case Trigger.heroesNear:
                unit = m.arg;
                break;
            case Trigger.heroDowned:
                foreach (s; 0 .. b.structureCount)
                    if (b.sIsHero[s] && b.sDowned[s] && !b.sAlive[s])
                        unit = b.sId[s];
                break;
            case Trigger.structureDestroyed:
                unit = m.arg;
                break;
            default:
                break;
            }
            foreach (s; 0 .. b.structureCount)
                if (b.sId[s] == unit)
                    tile = b.sTile[s];
        }
        // the Maw (a late wave) is first seen from far above: the camera pulls out to the overview
        if (b.firedMoment >= 0 && b.setup.moments[b.firedMoment].trigger == Trigger.waveStart
                && b.setup.moments[b.firedMoment].arg >= 3) {
            float wx, wy;
            tileWorld(b.width / 2, b.height / 2, wx, wy);
            state.takeCamera(wx, wy * tilt, 5);
            return;
        }
        focusOn(tile % b.width, tile / b.width, 30);
    }

    // ---- picking ---------------------------------------------------------------------

    /// The tile under a screen point: the nearest-to-viewer tile whose top contains it.
    bool pickTile(float px, float py, out int pq, out int pr) const {
        // invert the flat projection to a row estimate, then test the rows around it from the
        // front (a lifted tile in front covers one behind it)
        immutable cx = rect.x + rect.w * 0.5f, cy = rect.y + rect.h * 0.5f;
        immutable gx = state.camX + (px - cx) / state.zoom;
        immutable gy = (state.camY + (py - cy) / state.zoom) / tilt;
        immutable rEstimate = cast(int) floor(gy / 1.5f + 0.5f);
        foreach_reverse (r; rEstimate - 2 .. rEstimate + 8) {
            if (r < 0 || r >= battle.height)
                continue;
            foreach (dq; -3 .. 4) {
                immutable q0 = cast(int) floor(gx / sq3 - r * 0.5f + 0.5f) + dq;
                if (q0 < 0 || q0 >= battle.width)
                    continue;
                float sx, sy;
                tileScreen(q0, r, sx, sy);
                // the hexagon's top, in screen space: half-width sq3/2 and half-height `tilt`
                immutable hw = sq3 * 0.5f * state.zoom, hh = tilt * state.zoom;
                immutable ax = abs(px - sx) / hw, ay = abs(py - sy) / hh;
                // |x|/hw + |y|/(2*hh)... a hexagon with pointy top: ax <= 1 and ax + ay * 0.5 <= 1
                if (ax <= 1 && ax * 0.5f + ay <= 1) {
                    pq = q0;
                    pr = r;
                    return true;
                }
            }
        }
        return false;
    }

    /// The unit (structure or hero) whose billboard contains a screen point, or -1.
    int pickUnit(float px, float py) const {
        int best = -1;
        float bestDistance = state.zoom * 0.7f;
        foreach (s; 0 .. battle.structureCount) {
            if (!battle.sAlive[s])
                continue;
            float sx, sy;
            tileScreen(battle.sTile[s] % battle.width, battle.sTile[s] / battle.width, sx, sy);
            sy -= state.zoom * 0.5f;
            immutable d = sqrt((px - sx) * (px - sx) + (py - sy) * (py - sy));
            if (d < bestDistance) {
                bestDistance = d;
                best = battle.sId[s];
            }
        }
        return best;
    }

    // ---- geometry batches ------------------------------------------------------------

    private void quad(float x0, float y0, float x1, float y1, float x2, float y2, float x3, float y3, uint c) {
        immutable base = cast(int) colours.length;
        xy ~= [x0, y0, x1, y1, x2, y2, x3, y3];
        colours ~= [c, c, c, c];
        indices ~= [base, base + 1, base + 2, base, base + 2, base + 3];
    }

    private void tri(float x0, float y0, float x1, float y1, float x2, float y2, uint c) {
        immutable base = cast(int) colours.length;
        xy ~= [x0, y0, x1, y1, x2, y2];
        colours ~= [c, c, c];
        indices ~= [base, base + 1, base + 2];
    }

    private void disc(float cx, float cy, float rx, float ry, uint c, int sides = 10) {
        immutable base = cast(int) colours.length;
        import std.math : cos, sin, PI;

        xy ~= [cx, cy];
        colours ~= c;
        foreach (i; 0 .. sides) {
            immutable a = 2 * PI * i / sides;
            xy ~= [cx + cast(float) cos(a) * rx, cy + cast(float) sin(a) * ry];
            colours ~= c;
        }
        foreach (i; 0 .. sides)
            indices ~= [base, base + 1 + i, base + 1 + (i + 1) % sides];
    }

    private static uint shade(uint c, float factor, ubyte alpha = 0) {
        immutable r = cast(uint) min(255.0f, ((c >> 24) & 255) * factor);
        immutable g = cast(uint) min(255.0f, ((c >> 16) & 255) * factor);
        immutable b = cast(uint) min(255.0f, ((c >> 8) & 255) * factor);
        return r << 24 | g << 16 | b << 8 | (alpha ? alpha : (c & 255));
    }

    private void flush() {
        if (colours.length)
            v_triangles(xy.ptr, colours.ptr, cast(int) colours.length, indices.ptr, cast(int) indices.length);
        xy.length = 0;
        colours.length = 0;
        indices.length = 0;
    }

    /// One tile as a prism: the top hexagon and (standard zoom and closer) its two front faces.
    private void tile(int q, int r, bool sides, uint topColour, float extraLift = 0) {
        float wx, wy;
        tileWorld(q, r, wx, wy);
        immutable level = levelAt(q, r);
        immutable wall = wallAt(q, r);
        immutable lift = level * levelLift + (wall ? cliffLift : 0) + extraLift;
        float cx, cy;
        screen(wx, wy, lift, cx, cy);
        immutable hw = sq3 * 0.5f * state.zoom, hh = tilt * state.zoom;
        // corners: top, upper right, lower right, bottom, lower left, upper left
        immutable float[12] corners = [
            cx, cy - 2 * hh, cx + hw, cy - hh, cx + hw, cy + hh, cx, cy + 2 * hh,
            cx - hw, cy + hh, cx - hw, cy - hh
        ];
        immutable base = cast(int) colours.length;
        xy ~= [cx, cy];
        colours ~= topColour;
        foreach (i; 0 .. 6) {
            xy ~= [corners[i * 2], corners[i * 2 + 1]];
            colours ~= topColour;
        }
        foreach (i; 0 .. 6)
            indices ~= [base, base + 1 + i, base + 1 + (i + 1) % 6];
        if (!sides)
            return;
        // front faces: down to the lower neighbour in front, or a stub of ground
        immutable southWestLevel = q > 0 && r + 1 < battle.height
            ? levelAt(q - 1, r + 1) * levelLift + (wallAt(q - 1, r + 1) ? cliffLift : 0) : lift - 0.25f;
        immutable southEastLevel = r + 1 < battle.height
            ? levelAt(q, r + 1) * levelLift + (wallAt(q, r + 1) ? cliffLift : 0) : lift - 0.25f;
        immutable leftDrop = max(0.0f, lift - southWestLevel) * state.zoom;
        immutable rightDrop = max(0.0f, lift - southEastLevel) * state.zoom;
        immutable leftColour = shade(topColour, 0.62f), rightColour = shade(topColour, 0.78f);
        if (leftDrop > 0.5f)
            quad(corners[8], corners[9], corners[6], corners[7], corners[6], corners[7] + leftDrop,
                    corners[8], corners[9] + leftDrop, leftColour);
        if (rightDrop > 0.5f)
            quad(corners[6], corners[7], corners[4], corners[5], corners[4], corners[5] + rightDrop,
                    corners[6], corners[7] + rightDrop, rightColour);
    }

    // ---- drawing ---------------------------------------------------------------------

    private bool canPlaceHere(int q, int r) const {
        if (q < 0 || r < 0 || q >= battle.width || r >= battle.height)
            return false;
        immutable t = r * battle.width + q;
        if (!battle.revealed[t] || battle.wall[t] || battle.structureAt[t] != 0)
            return false;
        foreach (s; battle.sourceTile)
            if (s == t)
                return false;
        foreach (s; battle.sinkTile)
            if (s == t)
                return false;
        return true;
    }

    /// The route of the first source to its sink, for the road's tint.
    private void markRoute(ref bool[int] onRoute) const {
        foreach (src; 0 .. cast(int) battle.sourceTile.length) {
            immutable sink = battle.setup.sources[src].sink;
            immutable base = sink * battle.tiles;
            int t = battle.sourceTile[src];
            foreach (_; 0 .. battle.tiles) {
                onRoute[t] = true;
                if (t == battle.sinkTile[sink])
                    break;
                immutable open = battle.openParent[base + t];
                immutable next = battle.openDistance[base + t] != unreachable ? open : battle.throughParent[base + t];
                if (next < 0)
                    break;
                t = next;
            }
        }
    }

    private void unitPosition(int slot, out float sx, out float sy) const {
        tileScreen(battle.sTile[slot] % battle.width, battle.sTile[slot] / battle.width, sx, sy);
    }

    override void draw(Ui ui) {
        if (host.battle is null)
            return;
        if (!state.fitted) {
            fit();
            if (state.intro) {
                // begin from the overview band and ease in to the fitted view
                state.intro = false;
                state.goalX = state.camX;
                state.goalY = state.camY;
                state.goalZoom = state.zoom;
                state.zoom = min(state.zoom * 0.45f, 6.5f);
                state.easing = true;
            }
        }
        immutable band = bandOf(state.zoom);
        ui.pushClip(rect);
        ui.fill(rect, 0x0a0f1aff);
        const b = &battle();
        // the visible rows and columns, with a margin for the lift and the billboards
        immutable cx = rect.x + rect.w * 0.5f, cy = rect.y + rect.h * 0.5f;
        immutable gyTop = (state.camY - cy / state.zoom) / tilt, gyBottom = (
                state.camY + (rect.h - cy + rect.y) / state.zoom) / tilt;
        int r0 = cast(int) floor(gyTop / 1.5f) - 3, r1 = cast(int) floor(gyBottom / 1.5f) + 6;
        r0 = max(0, r0);
        r1 = min(b.height - 1, r1);
        bool[int] onRoute;
        markRoute(onRoute);
        immutable detail = band >= ZoomBand.standard;
        immutable visibleTiles = cast(long)(r1 - r0 + 1) * min(b.width,
                cast(int)(rect.w / (state.zoom * sq3)) + 4);
        bool useOverview;
        if (visibleTiles > visibleTileCap) {
            ensureOverview();
            useOverview = state.overview !is null;
        }
        if (useOverview) {
            // pixel (x, y) is the tile whose centre is at world (sq3 * x, 1.5 * y)
            float x0, y0, x1, y1;
            screen(-0.5f * sq3, -0.75f, 0, x0, y0);
            screen((state.overviewWidth - 0.5f) * sq3, 1.5f * state.overviewHeight - 0.75f, 0, x1, y1);
            v_draw(state.overview, x0, y0, x1 - x0, y1 - y0, 0, 0xffffffff);
            immutable dot = max(1.5f, state.zoom * 0.9f);
            foreach (t, _; onRoute) {
                float sx, sy;
                tileScreen(t % b.width, t / b.width, sx, sy);
                ui.fill(Rect(sx - dot * 0.5f, sy - dot * 0.5f, dot, dot), 0xffe9a0b0);
            }
        }
        if (!useOverview)
            foreach (r; r0 .. r1 + 1) {
                immutable gxLeft = state.camX - (cx - rect.x) / state.zoom - 2 * sq3;
                immutable gxRight = state.camX + (rect.x + rect.w - cx) / state.zoom + 2 * sq3;
                immutable qa = max(0, cast(int) floor(gxLeft / sq3 - r * 0.5f)), qb = min(b.width - 1,
                        cast(int) floor(gxRight / sq3 - r * 0.5f) + 1);
                foreach (q; qa .. qb + 1) {
                    immutable t = r * b.width + q;
                    uint colour;
                    if (!b.revealed[t])
                        colour = ((q + r) & 1) ? 0x141a26ff : 0x121723ff;
                    else if (b.wall[t])
                        colour = 0x6a6270ff;
                    else {
                        colour = levelColours[min(7, levelAt(q, r))];
                        if (onRoute.get(t, false))
                            colour = shade(colour, 1.18f) & 0xffffff00 | 0xff;
                        if ((q + r) & 1)
                            colour = shade(colour, 0.96f);
                    }
                    tile(q, r, detail && b.revealed[t], colour);
                }
            }
        flush();
        // markers: sources, sinks
        foreach (i, t; b.sourceTile) {
            float sx, sy;
            tileScreen(t % b.width, t / b.width, sx, sy);
            disc(sx, sy, state.zoom * 0.7f, state.zoom * 0.42f, 0xd04848d0, 12);
        }
        foreach (i, t; b.sinkTile) {
            float sx, sy;
            tileScreen(t % b.width, t / b.width, sx, sy);
            disc(sx, sy, state.zoom * 1.1f, state.zoom * 0.68f, 0xffe08a70, 14);
            disc(sx, sy - state.zoom * 0.5f, state.zoom * 0.35f, state.zoom * 0.35f, 0xfff0b0ff, 10);
        }
        // the hovered tile and the range of what is being placed
        if (state.hoverQ >= 0 && b.revealed.length) {
            immutable ok = state.placeKind >= 0 ? canPlaceHere(state.hoverQ, state.hoverR) : true;
            immutable ring = state.placeKind >= 0 ? b.setup.towers[state.placeKind].range : 0;
            foreach (dr; -ring .. ring + 1)
                foreach (dq; -ring .. ring + 1) {
                    if (hexDistance(0, 0, dq, dr) > ring)
                        continue;
                    immutable q = state.hoverQ + dq, r = state.hoverR + dr;
                    if (q < 0 || r < 0 || q >= b.width || r >= b.height)
                        continue;
                    tile(q, r, false, ok ? 0x80ffa028 : 0xff606028);
                }
            tile(state.hoverQ, state.hoverR, false, ok ? 0xa0ffb070 : 0xff707070);
        }
        flush();
        // units, back to front by row
        drawUnits(ui, band);
        // effects
        foreach (ref f; state.flashes) {
            float ax, ay, bx, by;
            screen(f.ax, f.ay, 0.9f, ax, ay);
            screen(f.bx, f.by, 0.6f, bx, by);
            final switch (f.kind) {
            case 0:
                v_line(ax, ay, bx, by, f.colour);
                break;
            case 1:
                disc(bx, by, state.zoom * (0.25f + 0.12f * (8 - f.life)), state.zoom * 0.15f * (1 + 8 - f.life),
                        shade(f.colour, 1, cast(ubyte)(40 + f.life * 12)), 10);
                break;
            case 2:
                disc(bx, by, state.zoom * (0.5f + 0.2f * (10 - f.life)), state.zoom * 0.3f * (1 + 10 - f.life),
                        shade(f.colour, 1, cast(ubyte)(30 + f.life * 10)), 12);
                break;
            case 3:
                disc(bx, by, state.zoom * (0.5f + 0.1f * (20 - f.life)), state.zoom * 0.3f * (1 + 0.2f * (20 - f.life)),
                        shade(f.colour, 1, cast(ubyte)(20 + f.life * 5)), 14);
                break;
            }
        }
        flush();
        ui.popClip();
    }

    private void drawUnits(Ui ui, ZoomBand band) {
        const b = &battle();
        // structures and heroes, sorted by row so nearer ones overlap farther ones
        struct Item {
            int row;
            int slot;
            bool enemy;
        }

        Item[] items;
        foreach (s; 0 .. b.structureCount)
            items ~= Item(b.sTile[s] / b.width, s, false);
        foreach (e; 0 .. b.enemyCount)
            items ~= Item(b.eTile[e] / b.width, e, true);
        import std.algorithm : sort;

        items.sort!((x, y) => x.row < y.row || (x.row == y.row && x.enemy < y.enemy));
        foreach (item; items) {
            if (item.enemy)
                drawEnemy(item.slot, band);
            else
                drawStructure(ui, item.slot, band);
        }
        flush();
        // names and levels at close zoom
        if (band == ZoomBand.close) {
            foreach (s; 0 .. b.structureCount) {
                if (!b.sAlive[s])
                    continue;
                float sx, sy;
                unitPosition(s, sx, sy);
                string label = b.sIsHero[s] ? heroLabel(b.sId[s]) : b.setup.towers[b.sKind[s]].name;
                if (!b.sIsHero[s] && b.sLevel[s] > 1)
                    label ~= format(" %d", b.sLevel[s]);
                auto size = ui.measure(label, FontRole.small);
                ui.drawText(label, FontRole.small, sx - size.w * 0.5f, sy - state.zoom * 1.45f, 0, 0xffffffff);
            }
        }
    }

    private static string heroLabel(int id) {
        switch (id) {
        case 9001:
            return "Ilse";
        case 9002:
            return "Corvin";
        case 9003:
            return "Wren";
        default:
            return format("hero %d", id);
        }
    }

    private uint kindColour(int kind) const {
        return towerColours[kind % towerColours.length];
    }

    private void drawStructure(Ui ui, int s, ZoomBand band) {
        const b = &battle();
        float sx, sy;
        unitPosition(s, sx, sy);
        immutable z = state.zoom;
        if (!b.sAlive[s]) {
            if (b.sSold[s] || b.sIsHero[s])
                return;
            // a ruin: a low heap
            disc(sx, sy, z * 0.55f, z * 0.3f, 0x3a3236ff, 8);
            disc(sx + z * 0.1f, sy - z * 0.1f, z * 0.3f, z * 0.2f, 0x544a50ff, 7);
            return;
        }
        immutable selected = b.sId[s] == state.selectedId;
        if (band == ZoomBand.overview) {
            disc(sx, sy - z * 0.2f, max(1.5f, z * 0.45f), max(1.5f, z * 0.45f), b.sIsHero[s] ? 0xffffffff : kindColour(
                    b.sKind[s]), 6);
            return;
        }
        if (b.sIsHero[s]) {
            immutable bodyColour = heroColours[b.sId[s] % heroColours.length];
            disc(sx, sy, z * 0.6f, z * 0.3f, 0x00000060, 10); // shadow
            quad(sx - z * 0.28f, sy, sx + z * 0.28f, sy, sx + z * 0.22f, sy - z * 1.0f, sx - z * 0.22f, sy - z * 1.0f,
                    shade(bodyColour, 0.8f));
            disc(sx, sy - z * 1.15f, z * 0.3f, z * 0.3f, bodyColour, 10);
            if (selected)
                disc(sx, sy, z * 0.8f, z * 0.45f, 0xffffff40, 14);
        } else {
            immutable colour = kindColour(b.sKind[s]);
            immutable height = (0.8f + 0.18f * (b.sLevel[s] - 1)) * z;
            disc(sx, sy, z * 0.55f, z * 0.3f, 0x00000060, 10);
            // a tower: a tapered shaft and a lit head
            quad(sx - z * 0.34f, sy, sx + z * 0.34f, sy, sx + z * 0.2f, sy - height, sx - z * 0.2f, sy - height,
                    shade(colour, 0.7f));
            quad(sx, sy + z * 0.05f, sx + z * 0.34f, sy, sx + z * 0.2f, sy - height, sx, sy - height - z * 0.05f,
                    shade(colour, 0.9f));
            disc(sx, sy - height, z * 0.3f, z * 0.2f, shade(colour, 1.15f), 8);
            if (b.setup.towers[b.sKind[s]].primitive == Primitive.aura)
                disc(sx, sy, z * (b.setup.towers[b.sKind[s]].radius + 0.5f) * 1.2f,
                        z * (b.setup.towers[b.sKind[s]].radius + 0.5f) * 0.72f, 0xffe08a14, 20);
            if (selected) {
                disc(sx, sy, z * 0.85f, z * 0.5f, 0xffffff38, 14);
                immutable range = b.setup.towers[b.sKind[s]].range;
                if (range > 0)
                    disc(sx, sy, z * range * sq3 * 0.95f, z * range * sq3 * 0.95f * tilt, 0xffffff12, 28);
            }
        }
        if (band >= ZoomBand.standard && b.sHp[s] < b.sMaxHp[s]) {
            immutable w = z * 0.9f, y = sy - z * (b.sIsHero[s] ? 1.55f : 1.25f);
            immutable full = b.sMaxHp[s] > 0 ? cast(float) b.sHp[s] / b.sMaxHp[s] : 0;
            quad(sx - w / 2, y, sx + w / 2, y, sx + w / 2, y + z * 0.12f, sx - w / 2, y + z * 0.12f, 0x000000b0);
            quad(sx - w / 2, y, sx - w / 2 + w * full, y, sx - w / 2 + w * full, y + z * 0.12f, sx - w / 2, y + z * 0.12f,
                    full > 0.5f ? 0x70e070ff : full > 0.25f ? 0xe0c050ff : 0xe05050ff);
        }
        if (b.sShield[s] > 0 && band >= ZoomBand.standard)
            disc(sx, sy - z * 0.5f, z * 0.6f, z * 0.6f, 0x60b0ff30, 12);
    }

    private void drawEnemy(int e, ZoomBand band) {
        const b = &battle();
        immutable tileIndex = b.eTile[e];
        immutable q = tileIndex % b.width, r = tileIndex / b.width;
        float sx, sy;
        tileScreen(q, r, sx, sy);
        // interpolate toward the next tile of its route by the progress made
        immutable at = b.eSink[e] * b.tiles + tileIndex;
        immutable next = b.openDistance[at] != unreachable ? b.openParent[at] : b.throughParent[at];
        if (next >= 0 && b.eAttack[e] < 0) {
            float nx, ny;
            tileScreen(next % b.width, next / b.width, nx, ny);
            immutable t = b.eProgress[e] / cast(float) tileProgress;
            sx += (nx - sx) * t;
            sy += (ny - sy) * t;
        }
        immutable z = state.zoom;
        immutable kind = b.eKind[e];
        immutable colour = enemyColours[kind % enemyColours.length];
        if (band == ZoomBand.overview) {
            immutable s = max(1.5f, z * (kind == 4 ? 1.2f : 0.35f));
            quad(sx - s, sy - s, sx + s, sy - s, sx + s, sy + s, sx - s, sy + s, colour);
            return;
        }
        immutable size = (kind == 4 ? 1.2f : kind == 2 ? 0.42f : kind == 3 ? 0.36f : kind == 1 ? 0.24f : 0.28f) * z;
        disc(sx, sy + size * 0.2f, size * 1.0f, size * 0.5f, 0x00000050, 8);
        disc(sx, sy - size * 0.6f, size, size * 1.1f, colour, 8);
        if (b.eBurn[e] > 0)
            disc(sx, sy - size * 0.6f, size * 1.25f, size * 1.35f, 0xff902050, 8);
        if (b.eShield[e] > 0)
            disc(sx, sy - size * 0.6f, size * 1.3f, size * 1.4f, 0x60b0ff40, 10);
        if (b.eSlow[e] > 0)
            disc(sx, sy - size * 0.1f, size * 0.9f, size * 0.4f, 0x90e0ff70, 8);
        if (band >= ZoomBand.standard) {
            immutable max = cast(float) b.setup.enemies[kind].hp;
            immutable full = max > 0 ? min(1.0f, b.eHp[e] / max) : 0;
            if (full < 1) {
                immutable w = size * 2;
                immutable y = sy - size * 2.0f;
                quad(sx - w / 2, y, sx + w / 2, y, sx + w / 2, y + z * 0.09f, sx - w / 2, y + z * 0.09f, 0x000000b0);
                quad(sx - w / 2, y, sx - w / 2 + w * full, y, sx - w / 2 + w * full, y + z * 0.09f, sx - w / 2, y + z * 0.09f,
                        0xe06060ff);
            }
        }
    }

    // ---- effects from the simulation -------------------------------------------------

    /// Turns the cues of the last step into short effects, and ages the old ones.
    void collect() {
        if (host.battle is null)
            return;
        const b = &battle();
        foreach (cue; b.lastCues()) {
            final switch (cue.kind) {
            case CueKind.hit:
                if (state.flashes.length < 160) {
                    int ts = -1;
                    foreach (s; 0 .. b.structureCount)
                        if (b.sId[s] == cue.a)
                            ts = s;
                    int te = -1;
                    foreach (e; 0 .. b.enemyCount)
                        if (b.eId[e] == cue.b)
                            te = e;
                    if (ts >= 0 && te >= 0) {
                        float ax, ay, bx, by;
                        tileWorld(b.sTile[ts] % b.width, b.sTile[ts] / b.width, ax, ay);
                        tileWorld(b.eTile[te] % b.width, b.eTile[te] / b.width, bx, by);
                        state.flashes ~= Flash(ax, ay, bx, by, 3, 0, 0xfff0a0ff);
                    }
                }
                break;
            case CueKind.ruin:
            case CueKind.down:
                foreach (s; 0 .. b.structureCount)
                    if (b.sId[s] == cue.a) {
                        float ax, ay;
                        tileWorld(b.sTile[s] % b.width, b.sTile[s] / b.width, ax, ay);
                        state.flashes ~= Flash(ax, ay, ax, ay, 10, 2, 0xff8040ff);
                    }
                break;
            case CueKind.burned:
            case CueKind.taunted:
            case CueKind.repaired:
            case CueKind.shielded:
            case CueKind.healed:
            case CueKind.flare:
            case CueKind.reinforced:
                foreach (s; 0 .. b.structureCount)
                    if (b.sId[s] == cue.a || b.sId[s] == cue.b) {
                        float ax, ay;
                        tileWorld(b.sTile[s] % b.width, b.sTile[s] / b.width, ax, ay);
                        state.flashes ~= Flash(ax, ay, ax, ay, 20, 3, 0x80d0ffff);
                        break;
                    }
                break;
            case CueKind.death:
            case CueKind.leak:
            case CueKind.build:
            case CueKind.sell:
            case CueKind.upgrade:
            case CueKind.disobey:
            case CueKind.summoned:
                break;
            }
        }
    }

    void age() {
        Flash[] alive;
        foreach (f; state.flashes) {
            auto next = f;
            --next.life;
            if (next.life > 0)
                alive ~= next;
        }
        state.flashes = alive;
    }

    // ---- input -----------------------------------------------------------------------

    override bool event(Ui ui, ref UiEvent e) {
        if (host.battle is null)
            return false;
        if (e.type == 9) {
            // right click: let go of whatever is selected or being placed
            if (rect.contains(e.x, e.y)) {
                state.placeKind = -1;
                state.targeting = false;
                state.selectedId = -1;
                return true;
            }
            return false;
        }
        if (e.type == 10) {
            immutable wasPressed = state.pressed;
            immutable wasMoved = state.moved;
            state.pressed = state.moved = false;
            if (wasPressed && !wasMoved && rect.contains(e.x, e.y)) {
                click(ui, e.x, e.y);
                return true;
            }
            return wasPressed;
        }
        if (e.type == 7) {
            if (state.pressed) {
                if (!state.moved && (abs(e.x - state.pressX) > 4 || abs(e.y - state.pressY) > 4))
                    state.moved = true;
                // with nothing selected, dragging the map pans the camera
                if (state.moved && state.placeKind < 0 && !state.targeting && state.selectedId < 0) {
                    pan(state.lastX - e.x, state.lastY - e.y);
                    state.easing = false;
                }
                state.lastX = e.x;
                state.lastY = e.y;
                return true;
            }
            if (rect.contains(e.x, e.y)) {
                int q, r;
                if (pickTile(e.x, e.y, q, r)) {
                    state.hoverQ = q;
                    state.hoverR = r;
                } else {
                    state.hoverQ = state.hoverR = -1;
                }
            }
            return false;
        }
        if (!rect.contains(e.x, e.y))
            return false;
        if (e.type == 8) {
            zoomAbout(e.key > 0 ? 1.18f : 1 / 1.18f, e.x, e.y);
            return true;
        }
        if (e.type == 5) {
            // acted on at release, so that a drag can pan instead
            state.pressed = true;
            state.moved = false;
            state.pressX = state.lastX = e.x;
            state.pressY = state.lastY = e.y;
            return true;
        }
        return false;
    }

    private void click(Ui ui, float x, float y) {
        auto phase = host.battlePhase;
        if (phase != BattlePhase.build && phase != BattlePhase.night)
            return;
        int q, r;
        immutable hit = pickTile(x, y, q, r);
        immutable unit = pickUnit(x, y);
        string reason;
        if (state.placeKind >= 0) {
            if (!hit) {
                return;
            }
            Command c;
            c.action = CommandKind.place;
            c.towerKind = state.placeKind;
            c.q = q;
            c.r = r;
            if (host.battleCommand(c, reason))
                state.dirty = true;
            else
                state.say(reason, ui.now);
            return;
        }
        if (state.targeting && state.selectedId >= 0) {
            Command c;
            c.action = CommandKind.useAbility;
            c.target = state.selectedId;
            c.q = hit ? q : -1;
            c.r = hit ? r : -1;
            if (!host.battleCommand(c, reason))
                state.say(reason, ui.now);
            state.targeting = false;
            return;
        }
        if (unit >= 0) {
            state.selectedId = unit;
            return;
        }
        // a hero is selected: a click on open ground is an order to walk there
        if (hit && state.selectedId >= 0 && isHero(state.selectedId)) {
            Command c;
            c.action = CommandKind.moveHero;
            c.target = state.selectedId;
            c.q = q;
            c.r = r;
            if (!host.battleCommand(c, reason))
                state.say(reason, ui.now);
            return;
        }
        state.selectedId = -1;
    }

    bool isHero(int id) const {
        foreach (s; 0 .. battle.structureCount)
            if (battle.sId[s] == id)
                return battle.sIsHero[s];
        return false;
    }
}

/// A small map of the revealed ground: walls, the road, units as dots, and the camera's view.
final class MiniMap : Widget {
    GameHost host;
    BattleViewState state;
    BattleCanvas canvas;

    this(GameHost host, BattleViewState state, BattleCanvas canvas) {
        this.host = host;
        this.state = state;
        this.canvas = canvas;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        immutable w = maxW;
        const b = &host.battle.battle;
        immutable aspect = b.width > 0 ? cast(float)(b.height) / b.width : 0.5f;
        return Size(w, min(min(maxH, ui.u(120)), w * aspect * 0.8f + 4));
    }

    override void draw(Ui ui) {
        if (host.battle is null)
            return;
        const b = &host.battle.battle;
        ui.fill(rect, 0x05080fff);
        // each tile is a dot placed where the canvas would put it, scaled to the rectangle
        immutable spanX = sq3 * (b.width + b.height * 0.5f) + 1;
        immutable spanY = 1.5f * b.height + 1;
        immutable scale = min((rect.w - 4) / spanX, (rect.h - 4) / spanY);
        immutable ox = rect.x + 2, oy = rect.y + 2;
        immutable dot = max(1.0f, scale * 1.2f);
        // a large map is one texture (the canvas builds it), not a dot a tile
        immutable fromTexture = cast(long) b.width * b.height > 4096;
        if (fromTexture) {
            canvas.ensureOverview();
            if (state.overview !is null)
                v_draw(state.overview, ox - 0.5f * sq3 * scale, oy - 0.75f * scale,
                        state.overviewWidth * sq3 * scale, state.overviewHeight * 1.5f * scale, 0, 0xffffffff);
        }
        if (!fromTexture)
            foreach (r; 0 .. b.height)
                foreach (q; 0 .. b.width) {
                    immutable t = r * b.width + q;
                    if (!b.revealed[t])
                        continue;
                    immutable x = ox + sq3 * (q + r * 0.5f) * scale, y = oy + 1.5f * r * scale;
                    ui.fill(Rect(x, y, dot, dot), b.wall[t] ? 0x6a6270ff : 0x587a5aff);
                }
        foreach (s; 0 .. b.structureCount) {
            if (!b.sAlive[s])
                continue;
            immutable q = b.sTile[s] % b.width, r = b.sTile[s] / b.width;
            immutable x = ox + sq3 * (q + r * 0.5f) * scale, y = oy + 1.5f * r * scale;
            ui.fill(Rect(x - 1, y - 1, dot + 2, dot + 2), b.sIsHero[s] ? 0xffffffff : 0xffd870ff);
        }
        foreach (e; 0 .. b.enemyCount) {
            immutable q = b.eTile[e] % b.width, r = b.eTile[e] / b.width;
            immutable x = ox + sq3 * (q + r * 0.5f) * scale, y = oy + 1.5f * r * scale;
            ui.fill(Rect(x, y, dot + 1, dot + 1), 0xe06a90ff);
        }
        // the camera's window
        immutable halfW = canvas.rect.w / state.zoom * 0.5f, halfH = canvas.rect.h / state.zoom * 0.5f / tilt;
        immutable cxw = state.camX, cyw = state.camY / tilt;
        ui.pushClip(rect);
        ui.outline(Rect(ox + (cxw - halfW) * scale, oy + (cyw - halfH) * scale, halfW * 2 * scale, halfH * 2 * scale),
                0xffffffff);
        ui.popClip();
        ui.outline(rect, 0x9bdbd9ff);
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (e.type != 5 || !rect.contains(e.x, e.y) || host.battle is null)
            return false;
        const b = &host.battle.battle;
        immutable spanX = sq3 * (b.width + b.height * 0.5f) + 1;
        immutable spanY = 1.5f * b.height + 1;
        immutable scale = min((rect.w - 4) / spanX, (rect.h - 4) / spanY);
        state.camX = (e.x - rect.x - 2) / scale;
        state.camY = (e.y - rect.y - 2) / scale * tilt;
        state.easing = false;
        return true;
    }
}
