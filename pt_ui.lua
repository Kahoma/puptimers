--[[
* PupTimers - ImGui drawing: the timer window (HUD) and the settings window.
*
* Written to work on both Ashita builds HorizonXI players run:
*   - Ashita 4.16 and older (ImGui 1.80)
*   - Ashita 4.3+          (ImGui 1.92)
* so it sticks to ImGui calls that exist in both and feature-detects text scaling.
--]]

local imgui = require('imgui');
local data  = require('pt_data');
local core  = require('pt_core');
local ovm   = require('pt_overload');

--[[
* Text output. Ashita 4.16 and older (ImGui 1.80) hand these strings to ImGui as printf formats, so a
* '%' in a name or ability name would be read as a format code (garbage text, or a crash). There the
* '%' is doubled; Ashita 4.3+ (ImGui 1.92) prints the text as it is. Same detection XIUI uses.
--]]
local PRINTF_TEXT = (ImGuiChildFlags_Borders == nil);

local function esc(s)
    s = tostring(s or '');
    if (PRINTF_TEXT and s:find('%', 1, true)) then
        s = s:gsub('%%', '%%%%');
    end
    return s;
end

local function Text(s) imgui.Text(esc(s)); end
local function TextColored(col, s) imgui.TextColored(col, esc(s)); end
local function TextDisabled(s) imgui.TextDisabled(esc(s)); end
local function TextWrapped(s) imgui.TextWrapped(esc(s)); end
local function SetTooltip(s) imgui.SetTooltip(esc(s)); end

local ui = {
    config_open = { false },
    hud_open    = { true },
    force_pos   = true,    -- apply the saved position on the next frame
    settle      = 2,       -- frames to wait before saving window moves
    label_cache = {},
    cache_size  = 0,
    cur_scale   = 1.0,
    buf         = {},      -- persistent text input buffers
    new_ability = { name = { '' }, cooldown = { 60 } },
    status_msg  = nil,
    status_until = 0,
};

local pt = nil;   -- the addon object (set by ui.init)

local HEAD  = { 1.00, 0.80, 0.35, 1.0 };
local DIM   = { 0.65, 0.65, 0.70, 1.0 };
local GOOD  = { 0.40, 0.90, 0.45, 1.0 };
local WARN  = { 1.00, 0.70, 0.25, 1.0 };
local BAD   = { 1.00, 0.45, 0.40, 1.0 };

local SECTION_NAMES = {
    automaton = 'Automaton HP / MP',
    maneuvers = 'Maneuvers',
    abilities = 'Automaton abilities',
    recasts   = 'Job ability recasts',
};

----------------------------------------------------------------------------------------------------
-- Performance notes
--
-- The timer window is drawn every frame, so the drawing path is written to create no garbage in
-- steady state (garbage makes Lua's collector run, which is what causes small hitches):
--   * draw-list calls reuse a few scratch tables instead of building {x, y} tables per call
--   * colours (imgui.GetColorU32) and text widths (imgui.CalcTextSize) are cached
--   * the list of rows is rebuilt 10 times a second, not every frame; bars still move smoothly
--     because each frame recomputes a bar's fill from its stored end time
--   * no closures are created per frame
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- Version helpers
----------------------------------------------------------------------------------------------------

local font_api = nil;        -- 'push' (ImGui 1.92 PushFont(font, size)), 'scale' (SetWindowFontScale) or 'none'
local font_base = 0;         -- ImGui 1.92 base font size, refreshed once a second
local font_checked = -100;

local function detect_font_api()
    if (font_api ~= nil) then
        return font_api;
    end
    local ok, style = pcall(imgui.GetStyle);
    if (ok and style ~= nil and type(style.FontSizeBase) == 'number') then
        font_api = 'push';
    elseif (imgui.SetWindowFontScale ~= nil) then
        font_api = 'scale';
    else
        font_api = 'none';
    end
    return font_api;
end

local function read_font_base()
    return imgui.GetStyle().FontSizeBase;
end

-- Must be called right after Begin(). Returns true if a font was pushed (pop it before End()).
local function push_text_scale(scale, now)
    local api = detect_font_api();
    if (api == 'push') then
        if ((now - font_checked) >= 1.0) then
            font_checked = now;
            local ok, base = pcall(read_font_base);
            if (ok and type(base) == 'number' and base > 0 and base ~= font_base) then
                font_base = base;
                ui.invalidate_caches();
            end
        end
        if (font_base <= 0) then
            return false;
        end
        return (pcall(imgui.PushFont, imgui.GetFont(), font_base * scale));
    elseif (api == 'scale') then
        imgui.SetWindowFontScale(scale);
    end
    return false;
end

local function pop_text_scale(pushed)
    if (pushed) then
        imgui.PopFont();
    end
end

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local bor = bit.bor;

local function clamp(v, lo, hi)
    v = tonumber(v) or lo;
    if (v < lo) then return lo; end
    if (v > hi) then return hi; end
    return v;
end

local function trim(s)
    s = tostring(s or '');
    s = s:gsub('^%s+', '');
    s = s:gsub('%s+$', '');
    return s;
end

-- Colours: GetColorU32 results cached per colour table and alpha step (33 steps).
local WHITE  = { 1, 1, 1, 1 };
local COLTMP = { 1, 1, 1, 1 };
local col_cache = {};

local function u32(c, alpha_mul)
    c = c or WHITE;
    local q = math.floor((alpha_mul or 1) * 32 + 0.5);
    local t = col_cache[c];
    if (t == nil) then
        t = {};
        col_cache[c] = t;
    end
    local v = t[q];
    if (v == nil) then
        COLTMP[1], COLTMP[2], COLTMP[3] = c[1] or 1, c[2] or 1, c[3] or 1;
        COLTMP[4] = (c[4] or 1) * q / 32;
        v = imgui.GetColorU32(COLTMP);
        t[q] = v;
    end
    return v;
end

-- Text widths, cached until the text scale changes.
local width_cache, width_count, width_scale = {}, 0, -1;

local function text_w(s)
    if (width_scale ~= ui.cur_scale) then
        width_cache, width_count, width_scale = {}, 0, ui.cur_scale;
    end
    local w = width_cache[s];
    if (w == nil) then
        w = imgui.CalcTextSize(s);
        width_count = width_count + 1;
        if (width_count > 512) then
            width_cache, width_count = {}, 0;
        end
        width_cache[s] = w;
    end
    return w;
end

-- Drops every cache and rebuilds the rows on the next frame (settings or font changed).
function ui.invalidate_caches()
    col_cache = {};
    width_cache, width_count = {}, 0;
    ui.label_cache, ui.cache_size = {}, 0;
    ui.view_next = 0;
end

local function changed()
    pt.mark_dirty();
    ui.invalidate_caches();
end

local function set_status(msg)
    ui.status_msg = msg;
    ui.status_until = os.clock() + 4;
end

-- Shortens a label with ".." so it fits in max_w pixels ('' if not even one letter fits).
local function fit_text(text, max_w)
    if (max_w <= 0) then
        return '';
    end
    if (text_w(text) <= max_w) then
        return text;
    end
    local key = text .. '\0' .. math.floor(max_w);
    local cached = ui.label_cache[key];
    if (cached ~= nil) then
        return cached;
    end
    local s, out = text, '';
    while (#s > 1) do
        s = s:sub(1, #s - 1);
        if (imgui.CalcTextSize(s .. '..') <= max_w) then
            out = s .. '..';
            break;
        end
    end
    ui.cache_size = ui.cache_size + 1;
    if (ui.cache_size > 256) then
        ui.label_cache, ui.cache_size = {}, 0;
    end
    ui.label_cache[key] = out;
    return out;
end

-- Tracked ImGui stack helpers for the settings window: if a tab fails part way, unwind_stacks()
-- pops whatever is still pushed so the window, tab bar and ID stack stay balanced.
local stk = { ids = 0, widths = 0, combo = false };

local function push_id(id)
    imgui.PushID(id);
    stk.ids = stk.ids + 1;
end

local function pop_id()
    imgui.PopID();
    stk.ids = stk.ids - 1;
end

local function push_width(w)
    imgui.PushItemWidth(w);
    stk.widths = stk.widths + 1;
end

local function pop_width()
    imgui.PopItemWidth();
    stk.widths = stk.widths - 1;
end

local function begin_combo(label, preview)
    local open = imgui.BeginCombo(label, preview);
    if (open) then
        stk.combo = true;
    end
    return open;
end

local function end_combo()
    imgui.EndCombo();
    stk.combo = false;
end

local function unwind_stacks()
    if (stk.combo) then
        end_combo();
    end
    while (stk.widths > 0) do
        pop_width();
    end
    while (stk.ids > 0) do
        pop_id();
    end
end

local function help_marker(text)
    imgui.SameLine();
    TextDisabled('(?)');
    if (imgui.IsItemHovered()) then
        SetTooltip(text);
    end
end

----------------------------------------------------------------------------------------------------
-- Draw-list primitives (reuse scratch tables: no garbage per call)
----------------------------------------------------------------------------------------------------

local P1, P2, P3 = { 0, 0 }, { 0, 0 }, { 0, 0 };

local function d_rect(dl, x1, y1, x2, y2, col, rounding)
    P1[1], P1[2], P2[1], P2[2] = x1, y1, x2, y2;
    dl:AddRectFilled(P1, P2, col, rounding);
end

local function d_text(dl, x, y, s, col)
    P1[1], P1[2] = x, y;
    dl:AddText(P1, col, s);
end

local function d_line(dl, x1, y1, x2, y2, col, thickness)
    P1[1], P1[2], P2[1], P2[2] = x1, y1, x2, y2;
    dl:AddLine(P1, P2, col, thickness);
end

local function d_circle(dl, x, y, radius, col)
    P1[1], P1[2] = x, y;
    dl:AddCircleFilled(P1, radius, col, 20);
end

-- Filled triangle, re-ordered to the clockwise winding ImGui's anti-aliasing expects.
local function d_tri(dl, ax, ay, bx, by, cx, cy, col)
    if (((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) < 0) then
        bx, by, cx, cy = cx, cy, bx, by;
    end
    P1[1], P1[2], P2[1], P2[2], P3[1], P3[2] = ax, ay, bx, by, cx, cy;
    dl:AddTriangleFilled(P1, P2, P3, col);
end

local function draw_text(dl, x, y, s, col_u32, shadow_u32)
    if (shadow_u32 ~= nil) then
        d_text(dl, x + 1, y + 1, s, shadow_u32);
    end
    d_text(dl, x, y, s, col_u32);
end

-- A bar's fill this frame: from its end time when it has one (smooth between row rebuilds).
local fill_frac = core.fill_frac;
local function live_frac(item, now)
    local e = item.dyn_end;
    if (e == nil) then
        return clamp(item.frac, 0, 1);
    end
    return fill_frac(e - now, item.dyn_total, item.dyn_mode);
end

local function pulse(now)
    return 0.55 + 0.45 * (0.5 + 0.5 * math.sin(now * 7.0));
end

----------------------------------------------------------------------------------------------------
-- HUD rows
----------------------------------------------------------------------------------------------------

local MARKER_DEFAULT = { 1, 1, 1, 0.85 };

local function draw_row(dl, x, y, w, h, row, now, cfg, text_h, shadow_u32)
    local colors = cfg.colors;
    local rounding = clamp(cfg.hud.rounding, 0, 12) * ui.cur_scale;

    local alpha = row.dim and 0.45 or 1.0;
    if (row.flash and cfg.alerts.flash) then
        alpha = alpha * pulse(now);
    end

    d_rect(dl, x, y, x + w, y + h, u32(colors.bar_bg), rounding);
    local frac = live_frac(row, now);
    if (frac > 0) then
        d_rect(dl, x, y, x + math.max(w * frac, 1), y + h, u32(row.color or colors.recast, alpha), rounding);
    end
    if (row.marker ~= nil) then
        -- e.g. the overload threshold on a burden bar
        local mx = math.floor(x + w * clamp(row.marker, 0, 1)) + 0.5;
        d_line(dl, mx, y + 1, mx, y + h - 1, u32(colors.marker or MARKER_DEFAULT), math.max(1, ui.cur_scale * 1.5));
    end
    local marks = row.marks;
    if (marks ~= nil) then
        -- e.g. where Economizer and Mana Converter fire on the automaton's MP bar
        for i = 1, #marks do
            local mx = math.floor(x + w * clamp(marks[i], 0, 1)) + 0.5;
            d_line(dl, mx, y + 1, mx, y + h - 1, u32(colors.marker or MARKER_DEFAULT), math.max(1, ui.cur_scale));
        end
    end

    local pad = math.max(3, math.floor(4 * ui.cur_scale));
    local right = row.right or '';
    local rw = (right ~= '') and text_w(right) or 0;
    local room = w - pad * 3 - rw;
    local label = row.label or '';
    if (row.short_label ~= nil and text_w(label) > room) then
        label = row.short_label;   -- e.g. 'Fire 12%' instead of 'Overload Fire 12%' in a narrow window
        if (row.right_optional and text_w(label) > room) then
            right, rw = '', 0;     -- still no room for both: the label matters more on this row
            room = w - pad * 2;
        end
    end
    label = fit_text(label, room);
    local ty = y + math.floor((h - text_h) * 0.5);
    local text_alpha = row.dim and 0.75 or 1.0;
    if (label ~= '') then
        draw_text(dl, x + pad, ty, label, u32(colors.text, text_alpha), shadow_u32);
    end
    if (right ~= '') then
        draw_text(dl, math.max(x + pad, x + w - pad - rw), ty, right, u32(row.warn and colors.warn or colors.text, text_alpha), shadow_u32);
    end
end

----------------------------------------------------------------------------------------------------
-- Maneuver icons
----------------------------------------------------------------------------------------------------

local LETTERS = { 'Fi', 'Ic', 'Wi', 'Ea', 'Th', 'Wa', 'Li', 'Da' };

-- Sun rays, precomputed once.
local RAYS = {};
for k = 0, 7 do
    local a = k * math.pi / 4;
    RAYS[#RAYS + 1] = { math.cos(a), math.sin(a) };
end

local function g_circ(dl, cx, cy, r, x, y, rr, col)
    d_circle(dl, cx + x * r, cy + y * r, rr * r, col);
end

local function g_line(dl, cx, cy, r, x1, y1, x2, y2, w, col)
    d_line(dl, cx + x1 * r, cy + y1 * r, cx + x2 * r, cy + y2 * r, col, math.max(1, r * w));
end

local function g_tri(dl, cx, cy, r, ax, ay, bx, by, qx, qy, col)
    d_tri(dl, cx + ax * r, cy + ay * r, cx + bx * r, cy + by * r, cx + qx * r, cy + qy * r, col);
end

-- Dark: a crescent = the moon disc minus a "bite" disc. Built once as two arcs between the two tips
-- (the moon's outer edge and the bite's edge) and filled with triangles, so the icon underneath
-- shows through the bite.
local MOON_N = 8;
local MOON_OUT, MOON_IN = {}, {};
do
    local TWO_PI = 2 * math.pi;
    local R1, bx, by, R2 = 0.80, 0.38, -0.26, 0.66;   -- moon at (0, 0); bite centre and radius
    local d = math.sqrt(bx * bx + by * by);
    local a = (R1 * R1 - R2 * R2 + d * d) / (2 * d);
    local h = math.sqrt(math.max(0, R1 * R1 - a * a));
    local ux, uy = bx / d, by / d;
    local t1x, t1y = ux * a - uy * h, uy * a + ux * h;   -- the two tips (where the circles cross)
    local t2x, t2y = ux * a + uy * h, uy * a - ux * h;
    -- Sweep from one angle to another, the way round that does (or does not) pass `through`.
    local function sweep(from, to, through, want)
        local sw = (to - from) % TWO_PI;
        if ((((through - from) % TWO_PI) < sw) ~= want) then
            sw = sw - TWO_PI;
        end
        return sw;
    end
    local o_from = math.atan2(t1y, t1x);
    local o_sw = sweep(o_from, math.atan2(t2y, t2x), math.atan2(by, bx), false);            -- away from the bite
    local i_from = math.atan2(t1y - by, t1x - bx);
    local i_sw = sweep(i_from, math.atan2(t2y - by, t2x - bx), math.atan2(-by, -bx), true); -- inside the moon
    for i = 0, MOON_N do
        local t = i / MOON_N;
        MOON_OUT[i] = { R1 * math.cos(o_from + o_sw * t), R1 * math.sin(o_from + o_sw * t) };
        MOON_IN[i] = { bx + R2 * math.cos(i_from + i_sw * t), by + R2 * math.sin(i_from + i_sw * t) };
    end
end

local function draw_moon(dl, cx, cy, r, col)
    for i = 0, MOON_N - 1 do
        local o1, o2, i1, i2 = MOON_OUT[i], MOON_OUT[i + 1], MOON_IN[i], MOON_IN[i + 1];
        if (i > 0) then              -- (the first and last quads are triangles: they meet at a tip)
            g_tri(dl, cx, cy, r, o1[1], o1[2], o2[1], o2[2], i1[1], i1[2], col);
        end
        if (i < MOON_N - 1) then
            g_tri(dl, cx, cy, r, o2[1], o2[2], i2[1], i2[2], i1[1], i1[2], col);
        end
    end
end

--[[
* Draws a small element symbol centred on (cx, cy) with radius r, using only AddTriangleFilled,
* AddCircleFilled and AddLine (available on both ImGui 1.80 and 1.92 Ashita builds).
--]]
local function draw_glyph(dl, el, cx, cy, r, col)
    if (el == 1) then            -- Fire: flame
        g_circ(dl, cx, cy, r, 0, 0.38, 0.52, col);
        g_tri(dl, cx, cy, r, 0.08, -1.0, 0.52, 0.32, -0.52, 0.32, col);
        g_tri(dl, cx, cy, r, -0.62, -0.30, -0.50, 0.28, -0.12, 0.10, col);
    elseif (el == 2) then        -- Ice: snowflake
        g_line(dl, cx, cy, r, 0, -1.0, 0, 1.0, 0.22, col);
        g_line(dl, cx, cy, r, -0.87, -0.5, 0.87, 0.5, 0.22, col);
        g_line(dl, cx, cy, r, -0.87, 0.5, 0.87, -0.5, 0.22, col);
        g_circ(dl, cx, cy, r, 0, 0, 0.22, col);
    elseif (el == 3) then        -- Wind: gusts
        g_line(dl, cx, cy, r, -0.90, -0.52, 0.45, -0.52, 0.24, col);
        g_line(dl, cx, cy, r, -0.55, 0.0, 0.90, 0.0, 0.24, col);
        g_line(dl, cx, cy, r, -0.90, 0.52, 0.30, 0.52, 0.24, col);
    elseif (el == 4) then        -- Earth: mountains
        g_tri(dl, cx, cy, r, -0.98, 0.78, -0.18, -0.72, 0.62, 0.78, col);
        g_tri(dl, cx, cy, r, 0.05, 0.78, 0.55, -0.08, 1.0, 0.78, col);
    elseif (el == 5) then        -- Thunder: bolt
        g_tri(dl, cx, cy, r, 0.30, -1.0, -0.58, 0.16, 0.10, 0.16, col);
        g_tri(dl, cx, cy, r, -0.10, -0.16, 0.58, -0.16, -0.30, 1.0, col);
    elseif (el == 6) then        -- Water: drop
        g_circ(dl, cx, cy, r, 0, 0.32, 0.56, col);
        g_tri(dl, cx, cy, r, 0, -1.0, 0.54, 0.16, -0.54, 0.16, col);
    elseif (el == 7) then        -- Light: sun
        g_circ(dl, cx, cy, r, 0, 0, 0.44, col);
        for i = 1, #RAYS do
            local c, s = RAYS[i][1], RAYS[i][2];
            g_line(dl, cx, cy, r, c * 0.64, s * 0.64, c * 0.98, s * 0.98, 0.18, col);
        end
    elseif (el == 8) then        -- Dark: crescent moon
        draw_moon(dl, cx, cy, r, col);
    end
end

-- Icon size, cell width (icon or time label, whichever is wider) and row height.
local function icon_metrics(cfg, text_h, count, avail_w, label_w, gap)
    local sc = ui.cur_scale;
    local size = math.floor(clamp(cfg.maneuvers.icon_size, 12, 80) * sc + 0.5);
    local text_gap = math.max(1, math.floor(2 * sc));
    local cell = math.max(size, label_w + 2);
    -- Shrink the icons to fit narrow windows; a cell never gets narrower than its time label.
    if (count > 0) then
        local fit = math.floor((avail_w - (count - 1) * gap) / count);
        if (cell > fit) then
            size = math.max(8, math.min(size, fit));
            cell = math.max(size, label_w, fit);
        end
    end
    return size, text_gap, cell, size + text_gap + math.ceil(text_h);
end

local function widest(items, field)
    local w = 0;
    for i = 1, #items do
        local s = items[i][field];
        if (s ~= nil and s ~= '') then
            local tw = text_w(s);
            if (tw > w) then
                w = tw;
            end
        end
    end
    return w;
end

local GLYPH_WHITE  = { 1, 1, 1, 0.95 };
local GLYPH_SHADOW = { 0, 0, 0, 0.75 };
local TEXT_SHADOW  = { 0, 0, 0, 0.85 };

local function draw_icon(dl, x, y, s, it, now, cfg)
    local colors = cfg.colors;
    local r = math.max(2, math.floor(s * 0.2));
    local alpha = it.dim and 0.45 or 1.0;
    if (it.flash and cfg.alerts.flash) then
        alpha = alpha * pulse(now);
    end
    local col = it.color or colors.empty;
    local b = math.max(1, math.floor(s * 0.08 + 0.5));
    local ir = math.max(1, r - b);

    d_rect(dl, x, y, x + s, y + s, u32(col, alpha), r);                           -- frame
    d_rect(dl, x + b, y + b, x + s - b, y + s - b, u32(colors.bar_bg), ir);       -- inside
    local f = live_frac(it, now);
    if (f > 0) then                                                               -- time left
        local h = math.max(1, (s - 2 * b) * f);
        d_rect(dl, x + b, y + s - b - h, x + s - b, y + s - b, u32(col, 0.80 * alpha), ir);
    end

    if (it.empty or it.el == nil) then
        return;
    end
    local cx, cy = x + s * 0.5, y + s * 0.5;
    local ga = it.dim and 0.6 or 1.0;
    if (cfg.maneuvers.icon_glyphs) then
        local gr = s * 0.30;
        draw_glyph(dl, it.el, cx + 1, cy + 1, gr, u32(GLYPH_SHADOW, ga));
        draw_glyph(dl, it.el, cx, cy, gr, u32(GLYPH_WHITE, ga));
    else
        local txt = LETTERS[it.el] or '?';
        local tw = text_w(txt);
        draw_text(dl, cx - tw * 0.5, cy - ui.text_h * 0.5, txt, u32(WHITE, ga), u32(TEXT_SHADOW));
    end
end

-- Draws a row of maneuver icons with the time left centred under each. Returns the row height.
local function draw_icon_row(dl, x, y, avail_w, row, now, cfg, text_h, shadow)
    local items = row.items;
    local n = #items;
    local gap = math.max(2, math.floor(5 * ui.cur_scale));
    -- Time labels as 0:45, or as 45 when the window is too narrow for every label to fit.
    local field = 'right';
    local label_w = widest(items, 'right');
    if (n > 0 and (n * label_w + (n - 1) * gap) > avail_w) then
        field = 'short';
        label_w = widest(items, 'short');
    end
    local size, text_gap, cell, row_h = icon_metrics(cfg, text_h, n, avail_w, label_w, gap);
    local total = n * cell + math.max(0, n - 1) * gap;
    local x0 = x;
    if (cfg.maneuvers.icon_align == 'center' and total < avail_w) then
        x0 = x + math.floor((avail_w - total) / 2);
    end
    for i = 1, n do
        local it = items[i];
        local cx = x0 + (i - 1) * (cell + gap);
        draw_icon(dl, cx + math.floor((cell - size) / 2), y, size, it, now, cfg);
        local txt = it[field] or it.right or '';
        if (txt ~= '') then
            local tcol = it.warn and cfg.colors.warn or cfg.colors.text;
            draw_text(dl, cx + math.floor((cell - text_w(txt)) / 2), y + size + text_gap, txt, u32(tcol, it.dim and 0.75 or 1.0), shadow);
        end
    end
    return row_h;
end

----------------------------------------------------------------------------------------------------
-- HUD window
----------------------------------------------------------------------------------------------------

local VIEW_INTERVAL = 0.1;   -- rows rebuilt 10 times a second (text changes at most once a second)
ui.view = nil;
ui.view_next = 0;
ui.cache_reset_at = 0;
ui.text_h = 14;
ui.hud_h = 0;                -- timer window height, measured from its content (0 until the first frame)
ui.placed_h = 0;             -- the height the window was last placed with (growing upward)
ui.anchor_up = false;        -- this frame's y is the bottom edge
ui.grow_fix = nil;           -- 'New bars appear' was switched: { grow, h = height y was converted with }
ui.grow_measured = false;    -- a frame was drawn and measured since that switch
ui.hud_bottom = nil;

local ENV = {};              -- reused argument table for core.build_view

-- During /pupt test, fill sections that have nothing real to show with sample rows.
local function merge_demo(view, demo)
    for _, sec in ipairs(view.sections) do
        local real = 0;
        for _, r in ipairs(sec.rows) do
            if (not r.note) then
                real = real + 1;
            end
        end
        if (real == 0) then
            for _, d in ipairs(demo.sections) do
                if (d.key == sec.key and d.key ~= 'abilities') then
                    for _, r in ipairs(d.rows) do
                        sec.rows[#sec.rows + 1] = r;
                        view.count = view.count + 1;
                    end
                end
            end
        end
    end
    view.header = view.header or 'PupTimers test';
end

local function build_view(now, cfg, unlocked, testing)
    local ov_rows, ov_left = pt.overload_view(now);
    ENV.pet_present        = pt.game.pet_present;
    ENV.pet_name           = pt.effective_pet_name();
    ENV.maneuver_recast    = pt.game.maneuver_recast;
    ENV.maneuver_recast_at = pt.game.maneuver_recast_at;
    ENV.overload_rows      = ov_rows;
    ENV.overload_left      = ov_left;
    ENV.pet_hpp            = pt.game.pet_hpp;
    ENV.pet_mpp            = pt.game.pet_mpp;
    ENV.pet_mp_marks       = pt.game.pet_mp_marks;
    ENV.pet_hp_marks       = pt.game.pet_hp_marks;
    ENV.deactivate_hint    = pt.game.deactivate_hint;
    ENV.repair_label       = pt.game.repair_label;
    ENV.repair_short       = pt.game.repair_short;
    ENV.man_counts         = pt.game.man_counts;
    ENV.unpowered_text     = pt.game.unpowered_text;
    ENV.unpowered_short    = pt.game.unpowered_short;
    local view = core.build_view(pt.state, cfg, now, ENV);
    if (testing) then
        merge_demo(view, core.demo_view(cfg, now));
    end
    if (view.count == 0 and unlocked and cfg.hud.preview_unlocked) then
        view = core.demo_view(cfg, now);
    end
    return view;
end

-- Reused per-frame argument tables.
local A_POS, A_SIZE, A_PAD, A_MIN, A_SPACING, A_DUMMY = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 40, 8 }, { 0, 0 }, { 0, 0 };
local A_CMIN, A_CMAX = { 60, 0 }, { 2000, 0 };
local STACK = { font = false, spacing = false };

function ui.render_hud(now)
    local cfg = pt.settings;
    local hud = cfg.hud;
    if (not hud.visible) then
        return;
    end

    local unlocked = not hud.locked;
    local testing = (pt.test_until ~= nil and now < pt.test_until);

    if (hud.hide_in_events and pt.game.in_event and not testing and not (unlocked and ui.config_open[1])) then
        return;   -- cutscene or NPC conversation: timers keep counting, the window comes back after
    end
    if (hud.only_on_pup and not pt.game.is_pup and not testing) then
        -- Still allow positioning the window from the settings screen.
        if (not (unlocked and ui.config_open[1])) then
            return;
        end
    end

    -- Cached colours / text widths are refreshed every few seconds as well, in case ImGui's style
    -- or font changes underneath (another addon, a font size change).
    if (now >= ui.cache_reset_at) then
        ui.invalidate_caches();
        ui.cache_reset_at = now + 5.0;
    end
    if (ui.view == nil or now >= ui.view_next) then
        ui.view = build_view(now, cfg, unlocked, testing);
        ui.view_next = now + VIEW_INTERVAL;
    end
    local view = ui.view;
    if (view.count == 0 and hud.hide_when_empty) then
        return;
    end

    local sc = clamp(hud.scale, 0.5, 3.0);
    local pad = math.floor(clamp(hud.padding, 0, 30) * sc + 0.5);
    local spacing = math.floor(clamp(hud.bar_spacing, 0, 30) * sc + 0.5);

    local flags = bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoSavedSettings);
    if (ImGuiWindowFlags_NoDocking ~= nil) then
        flags = bor(flags, ImGuiWindowFlags_NoDocking);
    end
    if (not unlocked) then
        flags = bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoInputs);
    end
    local bg_alpha = clamp(hud.bg_alpha, 0, 1);
    if (bg_alpha <= 0.001 and not unlocked) then
        flags = bor(flags, ImGuiWindowFlags_NoBackground);
    end

    -- 'New bars appear' was switched: y was converted at once (top edge <-> bottom edge) with the
    -- last known height, so the saved settings always make sense. If the window had been hidden, its
    -- height may differ by the time it shows: corrected once with the height it really has.
    local fix = ui.grow_fix;
    if (fix ~= nil) then
        if (fix.grow ~= hud.grow) then
            ui.grow_fix = nil;
        elseif (ui.grow_measured and ui.hud_h > 0) then
            local d = ui.hud_h - fix.h;
            if (d ~= 0) then
                hud.y = (hud.grow == 'up') and (hud.y + d) or (hud.y - d);
                ui.force_pos = true;
                pt.mark_dirty();
            end
            ui.grow_fix = nil;
        end
    end
    -- Growing upward, the saved y is the window's bottom edge: the window is placed again whenever
    -- its height changes (every frame while locked) so the bottom stays put as bars come and go.
    -- While unlocked it is only placed when the height changes, so it can still be dragged.
    local up = (hud.grow == 'up');
    ui.anchor_up = up;
    local reanchor = up and unlocked and ui.hud_h > 0 and ui.hud_h ~= ui.placed_h;
    if (ui.force_pos or (up and not unlocked) or reanchor) then
        A_POS[1], A_POS[2] = hud.x, up and (hud.y - ui.hud_h) or hud.y;
        imgui.SetNextWindowPos(A_POS, ImGuiCond_Always);
        ui.placed_h = ui.hud_h;
        if (ui.force_pos) then
            ui.force_pos = false;
            ui.settle = 2;
        end
    end
    -- Width comes from the settings (the corner grip changes it while unlocked). Height is the content
    -- height measured on the previous frame. A height of 0 would make ImGui auto-fit the window, and
    -- ImGui turns the resize grip off while auto-fitting, so 0 is only used until the first measurement.
    local h = ui.hud_h;
    A_SIZE[1], A_SIZE[2] = math.max(clamp(hud.width, 60, 2000), 60), h;
    imgui.SetNextWindowSize(A_SIZE, ImGuiCond_Always);
    if (h > 0) then
        -- Hold the height so that dragging the corner or an edge only changes the width.
        A_CMIN[2], A_CMAX[2] = h, h;
        imgui.SetNextWindowSizeConstraints(A_CMIN, A_CMAX);
    end
    imgui.SetNextWindowBgAlpha(unlocked and math.max(bg_alpha, 0.35) or bg_alpha);

    A_PAD[1], A_PAD[2] = pad, pad;
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, A_PAD);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, clamp(hud.rounding, 0, 12) * sc);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, unlocked and 1 or 0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, A_MIN);
    local visible = imgui.Begin('PupTimers##pt_hud', ui.hud_open, flags);
    imgui.PopStyleVar(4);

    -- Anything pushed inside the window is tracked so it is always popped before End(), even if
    -- drawing fails part way (an unbalanced ImGui stack is worse than a missing frame).
    STACK.font, STACK.spacing = false, false;
    local ok, err = true, nil;
    if (visible) then
        ui.cur_scale = sc;
        ok, err = pcall(ui.draw_hud_body, view, cfg, hud, now, spacing, unlocked, STACK, sc);
        if (ok and ui.hud_bottom ~= nil) then
            ui.hud_h = math.max(math.ceil(ui.hud_bottom + pad - 0.01), 8);
            ui.grow_measured = true;
        end
    end
    if (STACK.spacing) then
        imgui.PopStyleVar(1);
    end
    pop_text_scale(STACK.font);
    imgui.End();
    ui.hud_open[1] = true;
    if (not ok) then
        error(err, 0);
    end
end

function ui.draw_hud_body(view, cfg, hud, now, spacing, unlocked, stack, sc)
    stack.font = push_text_scale(sc, now);
    A_SPACING[1], A_SPACING[2] = 0, spacing;
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, A_SPACING);
    stack.spacing = true;

    local avail_w = imgui.GetContentRegionAvail();
    local text_h = select(2, imgui.CalcTextSize('Ag'));
    ui.text_h = text_h;
    local bar_h = math.max(math.floor(clamp(hud.bar_height, 4, 80) * sc + 0.5), math.ceil(text_h) + 2);
    local dl = imgui.GetWindowDrawList();
    local shadow = hud.text_shadow and u32(TEXT_SHADOW) or nil;

    if (view.header ~= nil) then
        TextColored(cfg.colors.header, view.header);
    end

    local first = true;
    local sections = view.sections;
    for si = 1, #sections do
        local rows = sections[si].rows;
        if (#rows > 0) then
            if (not first and hud.show_section_gap) then
                A_DUMMY[1], A_DUMMY[2] = 1, math.max(2, spacing);
                imgui.Dummy(A_DUMMY);
            end
            first = false;
            for ri = 1, #rows do
                local row = rows[ri];
                local x, y = imgui.GetCursorScreenPos();
                local h;
                if (row.kind == 'icons') then
                    h = draw_icon_row(dl, x, y, avail_w, row, now, cfg, text_h, shadow);
                else
                    h = bar_h;
                    if (row.thin) then
                        h = math.max(math.floor(bar_h * 0.7), math.ceil(text_h));
                    end
                    draw_row(dl, x, y, avail_w, h, row, now, cfg, text_h, shadow);
                end
                A_DUMMY[1], A_DUMMY[2] = avail_w, h;
                imgui.Dummy(A_DUMMY);
            end
        end
    end
    if (view.count == 0 and (view.notes or 0) == 0) then
        TextDisabled('PupTimers');
    end
    -- Bottom of the last item, in window coordinates, for next frame's window height.
    ui.hud_bottom = imgui.GetCursorPosY() - spacing;

    imgui.PopStyleVar(1);
    stack.spacing = false;
    pop_text_scale(stack.font);
    stack.font = false;

    if (unlocked) then
        if (view.demo and imgui.IsWindowHovered()) then
            SetTooltip('PupTimers preview\nDrag to move, drag the lower-right corner to resize.\nType /pupt lock when you are done.');
        end
        if (ui.settle > 0) then
            ui.settle = ui.settle - 1;
        else
            local wx, wy = imgui.GetWindowPos();
            local ww, wh = imgui.GetWindowSize();
            if (ui.anchor_up) then
                wy = wy + (wh or 0);   -- the bottom edge is what is kept
            end
            if (math.abs(wx - hud.x) >= 1 or math.abs(wy - hud.y) >= 1) then
                hud.x = math.floor(wx);
                hud.y = math.floor(wy);
                pt.mark_dirty();
            end
            if (ww ~= nil and ww >= 60 and math.abs(ww - hud.width) >= 1) then
                hud.width = math.floor(ww);
                pt.mark_dirty();
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Settings window widgets
----------------------------------------------------------------------------------------------------

-- One scratch table per widget kind: the value is copied in, edited by ImGui, and copied back.
local W_BOOL, W_NUM, W_INT = { false }, { 0 }, { 0 };

local function checkbox(label, tbl, key, tip)
    local v = W_BOOL;
    v[1] = (tbl[key] == true);
    local c = imgui.Checkbox(label, v);
    if (c) then
        tbl[key] = v[1];
        changed();
    end
    if (tip ~= nil) then
        help_marker(tip);
    end
    return c;
end

local function slider_float(label, tbl, key, lo, hi, fmt, tip)
    local v = W_NUM;
    v[1] = clamp(tbl[key], lo, hi);
    local c = imgui.SliderFloat(label, v, lo, hi, fmt or '%.2f');
    if (c) then
        tbl[key] = clamp(v[1], lo, hi);
        changed();
    end
    if (tip ~= nil) then
        help_marker(tip);
    end
    return c;
end

local function slider_int(label, tbl, key, lo, hi, fmt, tip)
    local v = W_INT;
    v[1] = math.floor(clamp(tbl[key], lo, hi));
    local c = imgui.SliderInt(label, v, lo, hi, fmt or '%d');
    if (c) then
        tbl[key] = math.floor(clamp(v[1], lo, hi));
        changed();
    end
    if (tip ~= nil) then
        help_marker(tip);
    end
    return c;
end

-- A typed number is stored when its field is left (Enter, Tab, a click elsewhere, or letting go of
-- its +/- button), not on every keystroke: on the way to "65" the field holds "6", and that must
-- never reach the settings (a 10 s maneuver duration would rewrite the running maneuvers).
-- INT_EDITS[tbl][key] = { buf = { n }, frame = f } while that field is being edited. Each field has
-- its own, so clicking from one field straight into another stores the first. An edit whose field
-- was not drawn in the previous frame (window closed) is dropped, as ImGui drops it.
local INT_EDITS = setmetatable({}, { __mode = 'k' });
ui.frame = 0;   -- counts every frame (ui.render), drawn or not

local function input_int(label, tbl, key, lo, hi, width)
    local edits = INT_EDITS[tbl];
    local ed = edits and edits[key];
    if (ed ~= nil and ed.frame < ui.frame - 1) then
        edits[key], ed = nil, nil;
    end
    local v;
    if (ed ~= nil) then
        v = ed.buf;
    else
        v = W_INT;
        v[1] = math.floor(clamp(tbl[key], lo, hi));
    end
    local shown = v[1];
    push_width(width or 100);
    imgui.InputInt(label, v, 1, 10);
    pop_width();
    if (imgui.IsItemActive()) then
        if (ed == nil) then
            if (edits == nil) then
                edits = {};
                INT_EDITS[tbl] = edits;
            end
            ed = { buf = { v[1] } };
            edits[key] = ed;
        end
        ed.frame = ui.frame;
        return false;
    end
    if (ed ~= nil) then
        edits[key] = nil;   -- the field was left: store what was typed
    elseif (v[1] == shown) then
        return false;
    end
    local n = math.floor(clamp(v[1], lo, hi));
    if (n == tbl[key]) then
        return false;
    end
    tbl[key] = n;
    changed();
    return true;
end

local function color_edit(label, tbl, key, compact)
    local c = tbl[key];
    if (type(c) ~= 'table') then
        c = { 1, 1, 1, 1 };
        tbl[key] = c;
    end
    local flags = bor(ImGuiColorEditFlags_NoInputs, ImGuiColorEditFlags_AlphaBar);
    if (compact) then
        flags = bor(flags, ImGuiColorEditFlags_NoLabel);
    end
    if (imgui.ColorEdit4(label, c, flags)) then
        changed();
    end
end

-- options: array of { value, text }
local function combo(label, tbl, key, options, width)
    local cur = tbl[key];
    local preview = tostring(cur);
    for _, o in ipairs(options) do
        if (o[1] == cur) then
            preview = o[2];
        end
    end
    push_width(width or 160);
    if (begin_combo(label, preview)) then
        for _, o in ipairs(options) do
            if (imgui.Selectable(o[2], o[1] == cur)) then
                tbl[key] = o[1];
                changed();
            end
        end
        end_combo();
    end
    pop_width();
end

--[[
* A button for something that cannot be undone: the first click arms it (its label asks for a second
* click), a second click within 4 seconds confirms. One button is armed at a time. Returns true on
* the confirming click. id is unique per button (e.g. 'del_' .. profile name).
--]]
local CONFIRM_FOR = 4.0;
local function confirm_button(id, label, armed_label, small)
    local now = os.clock();
    local armed = (ui.armed_id == id and now < (ui.armed_until or 0));
    local text = (armed and armed_label or label) .. '##' .. id;
    local clicked;
    if (small) then
        clicked = imgui.SmallButton(text);
    else
        clicked = imgui.Button(text);
    end
    if (clicked) then
        if (armed) then
            ui.armed_id = nil;
            return true;
        end
        ui.armed_id, ui.armed_until = id, now + CONFIRM_FOR;
    end
    return false;
end

local function heading(text)
    imgui.Spacing();
    TextColored(HEAD, text);
    imgui.Separator();
end

function ui.sync_buffers()
    local cfg = pt.settings;
    ui.buf.player = { cfg.names.player or '' };
    ui.buf.pet = { cfg.names.pet or '' };
    for tbl in pairs(INT_EDITS) do
        INT_EDITS[tbl] = nil;   -- a number not stored yet never lands in the replaced settings
    end                         -- (a field still being typed in gets its text back from ImGui)
end

----------------------------------------------------------------------------------------------------
-- Settings tabs
----------------------------------------------------------------------------------------------------

-- Choices for the settings window's combo boxes (made once: the window is drawn every frame).
local OPT_STYLE = { { 'icons', 'Element icons in a row' }, { 'bars', 'One bar per maneuver' } };
local OPT_ALIGN = { { 'left', 'Left' }, { 'center', 'Centered' } };
local OPT_TIMER_MODE = { { 'auto', 'Auto (recommended)' }, { 'game', 'Always the game\'s buff timers' }, { 'flat', 'Always the duration above' } };
local OPT_OV_SHOW = { { 'all', 'One bar per element' }, { 'top', 'Only the riskiest element' } };
local OPT_OV_HIDE = { { 'chance', 'its overload chance reaches 0%' }, { 'burden', 'its burden has fully cooled' } };
local OPT_OV_COLOR = { { 'risk', 'By risk of the next maneuver' }, { 'element', 'By element' } };
local OPT_TIME = { { 'mss', '1:05 (minutes:seconds)' }, { 'sec', '65s (seconds)' } };
local OPT_FILL = { { 'drain', 'Empty as time passes' }, { 'fill', 'Fill up until ready' } };
local OPT_SORT = { { 'remaining', 'Soonest ready first' }, { 'name', 'By name' } };
local OPT_GROW = { { 'down', 'Below (the window grows down)' }, { 'up', 'Above (the bottom edge stays put)' } };
local CFG_SIZE, CFG_MIN, CFG_MAX = { 600, 580 }, { 460, 300 }, { FLT_MAX or 100000, FLT_MAX or 100000 };
local LOCK_TIP = 'Locked, clicks go through the window. Unlock it (or /pupt unlock) to move or resize it.';
local LOCK_TIP_HIDES = 'Locked, clicks go through the window and it only shows while something is running. Unlock it (or /pupt unlock) to move or resize it.';
local COLOR_ENTRIES = {
        { 'bar_bg', 'Bar background' }, { 'text', 'Text' }, { 'header', 'Automaton name' },
        { 'ready', 'READY bars' }, { 'warn', 'Expiring maneuver text' }, { 'recast', 'Job ability bars' },
        { 'maneuver_cd', 'Maneuver recast bar' }, { 'overload', 'OVERLOADED countdown' }, { 'empty', 'Empty maneuver slot' },
        { 'overload_safe', 'Overload: no risk' }, { 'overload_low', 'Overload: low risk' },
        { 'overload_mid', 'Overload: medium risk' }, { 'overload_high', 'Overload: high risk' },
        { 'marker', 'Overload threshold line' }, { 'pet_hp', 'Automaton HP' }, { 'pet_mp', 'Automaton MP' },
};
local HELP_CMDS = {
        { '/pupt', 'Open or close this window' },
        { '/pupt show | hide | toggle', 'Show or hide the timer window' },
        { '/pupt lock | unlock', 'Lock the timer window in place / allow moving and resizing' },
        { '/pupt test', 'Show sample bars and fire test alerts' },
        { '/pupt clear', 'Clear all running automaton timers' },
        { '/pupt pet <name> | auto', 'Set the automaton name by hand, or go back to auto-detect' },
        { '/pupt player <name> | auto', 'Set your name by hand, or go back to auto-detect' },
        { '/pupt start <ability>', 'Start an ability timer by hand (e.g. /pupt start flashbulb)' },
        { '/pupt profile [name]', 'List profiles, or load one (handy in a macro)' },
        { '/pupt profile save <name>', 'Save the current settings as a profile' },
        { '/pupt profile delete <name>', 'Delete a profile' },
        { '/pupt copyfrom <character>', 'Copy another character\'s PupTimers settings' },
        { '/pupt resetpos', 'Move the timer window back on screen' },
        { '/pupt status', 'Version, what PupTimers detects, the automaton setup, the last error' },
        { '/pupt debug', 'Toggle debug messages' },
        { '/pupt defaults', 'Every setting back to its default' },
};

-- A name override: a text field and an Auto button that clears it (key: 'player' or 'pet').
local NAME_IDS = { player = { '##pt_player', 'Auto##player' }, pet = { '##pt_pet', 'Auto##pet' } };
local function name_row(label, key)
    local cfg, ids = pt.settings, NAME_IDS[key];
    Text(label);
    imgui.SameLine(130);
    push_width(170);
    if (imgui.InputText(ids[1], ui.buf[key], 32)) then
        cfg.names[key] = trim(ui.buf[key][1]);
        pt.names_changed();
        changed();
    end
    pop_width();
    imgui.SameLine();
    if (imgui.SmallButton(ids[2])) then
        cfg.names[key] = '';
        ui.buf[key][1] = '';
        pt.names_changed();
        changed();
    end
end

local function tab_general()
    local cfg = pt.settings;
    local g = pt.game;

    heading('Status');
    local job = 'Not logged in';
    if (g.logged_in) then
        job = g.job_text or '?';
        if (not g.is_pup) then
            job = job .. '  (not Puppetmaster - timers are hidden)';
        end
    end
    Text('Job:');
    imgui.SameLine(110);
    TextColored(g.is_pup and GOOD or DIM, job);

    Text('Player:');
    imgui.SameLine(110);
    Text(pt.effective_player_name() ~= '' and pt.effective_player_name() or '(unknown)');
    imgui.SameLine();
    TextDisabled((cfg.names.player ~= '') and '[set manually]' or '[auto-detected]');

    Text('Automaton:');
    imgui.SameLine(110);
    local pet = pt.effective_pet_name();
    Text(pet ~= '' and pet or '(none detected yet - call your automaton)');
    imgui.SameLine();
    if (cfg.names.pet ~= '') then
        TextDisabled('[set manually]');
    else
        TextColored(g.pet_present and GOOD or DIM, g.pet_present and '[active]' or '[not out]');
    end

    heading('Names');
    TextWrapped('Leave these blank and PupTimers reads your name and your automaton\'s name from the game. Fill them in only if detection picks the wrong name.');
    name_row('Player name', 'player');
    name_row('Automaton name', 'pet');

    heading('Timer window');
    checkbox('Show timer window', cfg.hud, 'visible');
    if (checkbox('Lock position and size (clicks pass through)', cfg.hud, 'locked', cfg.hud.hide_when_empty and LOCK_TIP_HIDES or LOCK_TIP)) then
        ui.force_pos = true;
    end
    checkbox('Hide when nothing is running', cfg.hud, 'hide_when_empty');
    checkbox('Only show while Puppetmaster is my main or support job', cfg.hud, 'only_on_pup', 'PupTimers tracks nothing on other jobs. Turned off, the window can still be shown there while unlocked (with sample bars), to place it.');
    checkbox('Show preview bars while unlocked', cfg.hud, 'preview_unlocked', 'While the window is unlocked and idle it shows sample bars so you can place and size it.');

    heading('Detection');
    TextWrapped('Works the same with one chat window or a split two-window log: PupTimers reads the game data behind the log, not the windows on screen.');
    checkbox('Read the game\'s combat data (recommended)', cfg.detect, 'packets', 'Sees your automaton\'s abilities and your maneuvers directly from the game\'s combat data. Works even if your chat filters hide those messages.');
    checkbox('Read the chat log', cfg.detect, 'chat', 'Watches for "<Automaton> uses <Ability>" lines, whichever log window shows them. Needed for abilities you add yourself, and a backup for the others until the packets report them.');
    checkbox('Clear automaton timers when it leaves or a new one is called', cfg.behavior, 'reset_on_despawn', 'The server builds a new automaton each time you use Activate or Deus Ex Automata and when it follows you into a new zone. (Newer server code puts its abilities on cooldown then: tick "On act." for them on the Automaton tab.)');
    checkbox('Debug messages in chat', cfg.behavior, 'debug', 'Prints what PupTimers detects. Useful for checking that names are detected correctly.');

    heading('Tools');
    if (imgui.Button('Test (15s demo)')) then
        pt.actions.test();
    end
    imgui.SameLine();
    if (imgui.Button('Clear running timers')) then
        pt.actions.clear();
        set_status('Timers cleared.');
    end
    imgui.SameLine();
    if (imgui.Button('Reset window position')) then
        pt.actions.reset_position();
        set_status('Timer window moved to the top-left area.');
    end
    imgui.SameLine();
    if (confirm_button('rst', 'Reset all settings', 'Click again to reset everything')) then
        pt.actions.reset_all();
        set_status('All settings are back to their defaults. The timer window is unlocked: place it, then /pupt lock.');
    end
    if (imgui.IsItemHovered()) then
        SetTooltip('Every PupTimers setting back to its default, for this character. Click twice to confirm. Same as /pupt defaults.');
    end
end

-- Automaton tab: column positions and one row per ability, drawn straight from the data and the
-- settings (nothing is built per frame).
local C_NAME, C_CD, C_COLOR, C_ALERT, C_SPAWN, C_BTN = 36, 190, 300, 340, 395, 450;

local function ability_row(key, name, source, store, custom)
    push_id(key);
    checkbox('##en', store, 'enabled');
    imgui.SameLine(C_NAME);
    Text(name);
    if (imgui.IsItemHovered()) then
        local def = core.ability_def[key];
        SetTooltip(('From: %s%s'):format(source or '?', def and ('\nDefault cooldown: %ds'):format(def.cooldown) or ''));
    end
    imgui.SameLine(C_CD);
    input_int('##cd', store, 'cooldown', 0, 7200, 95);
    imgui.SameLine(C_COLOR);
    color_edit('##col', store, 'color', true);
    imgui.SameLine(C_ALERT);
    checkbox('##al', store, 'alert');
    imgui.SameLine(C_SPAWN);
    checkbox('##sp', store, 'on_spawn');
    imgui.SameLine(C_BTN);
    if (imgui.SmallButton('Test')) then
        pt.actions.test_ability(key);
    end
    if (imgui.IsItemHovered()) then
        SetTooltip('Shows a sample bar with this cooldown and colour. Running cooldowns are not changed.');
    end
    if (custom) then
        imgui.SameLine();
        if (imgui.SmallButton('Remove')) then
            pt.actions.remove_custom(key);
        end
    end
    pop_id();
end

local function tab_automaton()
    local cfg = pt.settings;

    TextWrapped('A bar starts the moment your automaton uses one of these abilities and counts down to when it can use it again. Default cooldowns come from the server scripts; change them if your server differs.');
    local kit = pt.kit;
    if (kit ~= nil and kit.known) then
        TextDisabled(('Listed: what your automaton can use now (%s, %d attachments).'):format(kit.frame_name or '?', #kit.attachment_names));
    else
        TextDisabled('Your automaton\'s setup is not read yet (it arrives with zoning or your next maneuver), so every ability is listed.');
    end
    imgui.Checkbox('Show every ability##pt_ab_all', ui.ab_all);
    if (imgui.IsItemHovered()) then
        SetTooltip('Also list abilities your automaton\'s setup cannot use right now, and abilities from attachments that are not on HorizonXI.');
    end
    imgui.Spacing();

    TextColored(DIM, 'On');
    imgui.SameLine(C_NAME);  TextColored(DIM, 'Ability');
    imgui.SameLine(C_CD);    TextColored(DIM, 'Cooldown (s)');
    imgui.SameLine(C_COLOR); TextColored(DIM, 'Colour');
    imgui.SameLine(C_ALERT); TextColored(DIM, 'Alert');
    imgui.SameLine(C_SPAWN); TextColored(DIM, 'On act.');
    if (imgui.IsItemHovered()) then
        SetTooltip('Start this timer when your automaton is activated.\nOnly LandSandBoat builds from mid-2026 on put attachment abilities on cooldown at activation;\nthe HorizonXI wiki says Shock Absorber can be used right after Activate, so leave this off unless you see it happen.');
    end
    imgui.Separator();

    local all = ui.ab_all[1];
    for _, a in ipairs(data.abilities) do
        local store = cfg.abilities[a.key];
        local listed = all or (a.horizon ~= false and not (kit ~= nil and kit.known and kit.abilities[a.key] == false));
        if (store ~= nil and listed) then
            ability_row(a.key, a.name, a.source, store, false);
        end
    end
    if (next(cfg.custom) ~= nil) then
        local keys = {};
        for key, c in pairs(cfg.custom) do
            if (type(c.name) == 'string' and c.name ~= '') then
                keys[#keys + 1] = key;
            end
        end
        table.sort(keys);
        for _, key in ipairs(keys) do
            local c = cfg.custom[key];
            if (c ~= nil) then   -- (a Remove click above may have just deleted it)
                ability_row(key, c.name, 'Custom', c, true);
            end
        end
    end

    heading('Add your own ability');
    TextWrapped('Type the ability name exactly as the chat log shows it after "<Automaton> uses". Custom abilities are detected from the chat log.');
    if (not cfg.detect.chat) then
        TextColored(WARN, 'Reading the chat log is off (General tab), so abilities added here are never detected.');
    end
    push_width(170);
    imgui.InputText('Name##pt_newab', ui.new_ability.name, 32);
    pop_width();
    imgui.SameLine();
    push_width(100);
    imgui.InputInt('Cooldown (s)##pt_newcd', ui.new_ability.cooldown, 1, 10);
    pop_width();
    imgui.SameLine();
    if (imgui.Button('Add')) then
        local ok, msg = pt.actions.add_custom(ui.new_ability.name[1], ui.new_ability.cooldown[1]);
        set_status(msg);
        if (ok) then
            ui.new_ability.name[1] = '';
        end
    end

    local unknown = pt.unknown_seen;
    if (next(unknown) ~= nil) then
        heading('Seen from your automaton but not tracked');
        for lname, u in pairs(unknown) do
            push_id('unk_' .. lname);
            Text(('%s  (x%d)'):format(u.name, u.count));
            imgui.SameLine(C_CD);
            if (imgui.SmallButton('Track it')) then
                ui.new_ability.name[1] = u.name;
                set_status(('Enter a cooldown for %s and press Add.'):format(u.name));
            end
            imgui.SameLine();
            if (imgui.SmallButton('Dismiss')) then
                unknown[lname] = nil;
            end
            pop_id();
        end
    end

    imgui.Spacing();
    imgui.Separator();
    if (confirm_button('rdc', 'Restore default cooldowns and colours', 'Click again to restore the defaults')) then
        pt.actions.restore_ability_defaults();
        set_status('Default cooldowns and colours restored.');
    end

    heading('Automaton HP and MP');
    local ac = cfg.automaton;
    TextWrapped('Thin HP and MP bars for your automaton, with Puppetmaster marks. If you use them, you can turn off the automaton part of another addon\'s pet bar.');
    checkbox('Show the automaton\'s HP', ac, 'show_hp');
    checkbox('Show the automaton\'s MP', ac, 'show_mp');
    slider_int('Remind me to Repair at HP % (0 = off)', ac, 'repair_at', 0, 90, '%d', 'A chat/sound reminder when your automaton\'s HP falls to this and Repair is ready. A white line marks it on the HP bar.');
    checkbox('Show the Automaton Oil on the Repair bar', ac, 'oil', 'For example "Repair (Oil+1 x5, 12 more)". Repair uses one oil from your ammo slot; you are told when Repair is ready with no oil equipped, and when the equipped stack runs out.');
    checkbox('Say when Deactivate would reset Activate', ac, 'deactivate_hint', 'While Activate is cooling down, a line appears when your automaton is at exactly full HP: deactivating it then resets the Activate recast. PupTimers uses the exact HP the game sends, not the HP %.');
    TextDisabled('With the setup read from the game, the MP bar marks where Economizer and Mana Converter will fire for the Dark Maneuvers you have up, and the HP bar where Replicator fires.');
end

local function tab_maneuvers()
    local cfg = pt.settings;
    local m = cfg.maneuvers;

    TextWrapped('Maneuvers are read from your buff bar, so the list is always correct. Up to 3 can be active; using a 4th replaces the oldest one (shown first).');
    heading('Maneuvers');
    checkbox('Show maneuvers', m, 'enabled');
    combo('Display', m, 'style', OPT_STYLE, 220);
    if (m.style ~= 'bars') then
        slider_int('Icon size', m, 'icon_size', 16, 64);
        checkbox('Element symbols on icons (off = letters)', m, 'icon_glyphs');
        combo('Icon alignment', m, 'icon_align', OPT_ALIGN, 220);
    end
    -- A typed value, not a slider: one stray click on a slider would set a wrong duration.
    input_int('Maneuver duration (seconds)', m, 'duration', 10, 300, 120);
    help_marker('Maneuvers last a flat 60 seconds on HorizonXI. Time left = when you used it + this.');
    combo('Maneuver timers', m, 'timer_mode', OPT_TIMER_MODE, 260);
    if (imgui.IsItemHovered()) then
        SetTooltip('Auto counts each maneuver from when you used it, which is exact. If one ever lasts longer than the duration above (some servers lengthen maneuvers in long fights), it switches to the game\'s own buff timers. Maneuvers that were already up when PupTimers loaded always use the game\'s timers.');
    end
    if (pt.long_maneuvers) then
        TextDisabled(('Following the game\'s timers: a maneuver lasted %ds.'):format(math.floor((pt.long_seen or 0) + 0.5)));
    end
    checkbox('Show empty slots while the automaton is out', m, 'show_empty');
    checkbox('Show the shared maneuver recast', m, 'show_recast');
    checkbox('Show an OVERLOADED warning', m, 'show_overload');
    slider_int('Warn when a maneuver has less than (seconds, 0 = off)', m, 'warn_at', 0, 30, '%d', 'The time turns orange and the bar pulses when a maneuver is about to wear off.');
    checkbox('Alert when a maneuver wears off', m, 'alert_wear', 'Uses the chat/sound options from the Alerts tab. Maneuvers replaced by a new maneuver are not announced.');

    heading('Your automaton\'s attachments');
    TextDisabled('These need the automaton\'s setup, which the game sends when you zone and with each maneuver.');
    checkbox('Show abilities left without their maneuver', m, 'show_unpowered', 'A dim line under the maneuvers, e.g. "Unpowered: Provoke (Fire)", while your automaton is out.');
    checkbox('Alert when losing a maneuver leaves an ability unpowered', m, 'alert_unpowered', 'Uses the chat/sound options from the Alerts tab.');
    checkbox('Say in chat when an attachment uses up maneuvers', m, 'explain_used', 'The game shows nothing when, for example, Economizer uses up your Dark Maneuvers.');

    heading('Element colours');
    for i, e in ipairs(data.elements) do
        push_id('mc_' .. e.key);
        color_edit(e.name, m.colors, e.key, false);
        pop_id();
        if (i % 4 ~= 0) then
            imgui.SameLine(120 * (i % 4));
        end
    end
end

local function tab_overload()
    local cfg = pt.settings;
    local o = cfg.overload;

    TextWrapped('After each maneuver the game reports your automaton\'s overload chance for that element. PupTimers pins the burden from that number, lets it cool down at the server\'s rate, and shows how risky the NEXT maneuver of that element would be. With bars that stay until the burden has fully cooled, a white line marks the overload threshold.');
    heading('Overload bar');
    checkbox('Show the overload estimate', o, 'enabled');
    if (not o.enabled) then
        TextWrapped('The estimate is off: PupTimers tracks no burden and gives no overload risk warnings. The OVERLOADED countdown still works, because it comes from your buff timers.');
        return;
    end
    combo('Bars', o, 'show', OPT_OV_SHOW, 240);
    combo('A bar goes away when', o, 'hide_at', OPT_OV_HIDE, 240);
    if (o.hide_at ~= 'burden') then
        slider_int('Bar is full at (percent)', o, 'full_at', 10, 100);
    end
    combo('Bar colour', o, 'color_by', OPT_OV_COLOR, 240);
    checkbox('Thin bars', o, 'compact');
    slider_int('Warn me at (% next-maneuver chance, 0 = off)', o, 'alert_risk', 0, 60, '%d', 'Chat/sound alert after a maneuver if another one of the same element would have at least this chance to overload.');

    heading('Gear and attachments');
    TextWrapped('Tick what should count toward the overload estimate. Gear can count only while you are wearing it (read from the game every 2 seconds), or always - use "always" if a macro swaps it in just for the maneuver.');
    TextColored(DIM, 'Count');
    imgui.SameLine(60);
    TextColored(DIM, 'Gear');
    imgui.SameLine(250);
    TextColored(DIM, 'Only while worn');
    local wearing = pt.gear.wearing or {};
    for _, g in ipairs(data.overload_gear) do
        local opt = o.gear[g.key];
        if (opt ~= nil) then
            push_id('gear_' .. g.key);
            if (checkbox('##count', opt, 'count')) then
                pt.gear.checked_at = -100;   -- re-read gear on the next poll
            end
            imgui.SameLine(60);
            Text(g.name);
            if (imgui.IsItemHovered()) then
                SetTooltip(g.effect);
            end
            imgui.SameLine(250);
            if (checkbox('##worn', opt, 'worn_only')) then
                pt.gear.checked_at = -100;
            end
            imgui.SameLine();
            if (wearing[g.key]) then
                TextColored(GOOD, 'wearing now');
            else
                TextDisabled(opt.worn_only and 'not worn' or 'counts always');
            end
            pop_id();
        end
    end
    imgui.Spacing();
    local kit = pt.kit;
    checkbox('Take attachments from the game', o, 'attachments_auto', 'PupTimers reads your automaton\'s attachments from the game (they arrive with zoning and with each maneuver). Turn this off to tick them by hand.');
    if (o.attachments_auto and kit ~= nil and kit.known) then
        for _, a in ipairs(data.overload_attachments) do
            if (kit[a.key]) then
                TextColored(GOOD, ('  %s: equipped (%s)'):format(a.name, a.effect));
            else
                TextDisabled(('  %s: not equipped'):format(a.name));
            end
        end
    else
        TextColored(DIM, (o.attachments_auto and 'Not read from the game yet; until then these count:' or 'Tick the attachments you use:'));
        for _, a in ipairs(data.overload_attachments) do
            push_id('att_' .. a.key);
            checkbox(a.name, o, a.key, a.effect);
            pop_id();
        end
    end
    slider_int('Heatsink: extra cooling per tick', o, 'heatsink_decay', 0, 6, '%d', 'Current server code for this era: +1 per 3 seconds on every element. The HorizonXI wiki\'s tested table differs, so adjust this if your estimate cools too slowly or too fast.');
    checkbox('Heatsink cools more with Water Maneuvers up (older server rule)', o, 'heatsink_by_water', '+2/+4/+5/+6 per tick with 0/1/2/3 Water Maneuvers (LandSandBoat code until May 2025; its January 2026 code used +1/+3/+4/+5), instead of the setting above.');
    checkbox('Work out each maneuver\'s burden from stats', o, 'use_stats', 'The server adds 14-20 burden per maneuver depending on your stat for that element against the automaton\'s (Dark: by frame). PupTimers reads both, tries the known server rules, and uses one only once the game\'s own overload reports confirm it. Your stats are only trusted while your gear and buffs are unchanged since the game last sent them.');
    local rules = pt.ov.rules;
    if (pt.burden_rule ~= nil) then
        TextColored(GOOD, ('  Burden per maneuver: from stats (matched the game %d times).'):format(rules[pt.burden_rule].n));
        if (not pt.stats_fresh()) then
            TextDisabled('  Your gear or buffs changed since the game last sent your stats: until it sends them again, the values learned from its reports are used (Dark Maneuvers excepted).');
        end
    elseif (rules ~= nil) then
        TextDisabled(('  Burden per maneuver: learned from the game\'s reports (%d so far).'):format(rules.learned.n));
    end
    local items = pt.gear.items or {};
    if (#items > 0) then
        local names = {};
        for _, g in ipairs(items) do
            names[#names + 1] = g.name;
        end
        TextColored(GOOD, 'Counting: ' .. table.concat(names, ', '));
    end

    local p = ovm.after_overdrive(pt.overload_params());
    TextDisabled(('Now using: threshold %d, burden -%s every %ss, chance = burden - %d + %d%s'):format(
        p.T, tostring(p.decay), tostring(p.tick), p.T, p.offset, p.suppress and ', Kenkonken (gains / 3)' or ''));
    if (pt.state.man.overdrive) then
        TextColored(WARN, 'Overdrive is up: nothing can overload until it ends. Bars show the chances for after it ends.');
    end

    heading('Live estimate');
    TextDisabled('Chances are in percent. "Next" = chance if you used that maneuver right now.');
    if ((pt.ov.reports or 0) > 0) then
        TextColored(GOOD, ('Overload reports received from the game: %d'):format(pt.ov.reports));
    else
        TextColored(DIM, 'No overload reports received yet - until one arrives the estimate uses the model only.');
    end
    local now = os.clock();
    if (pt.ov.unknown_since ~= nil and (now - pt.ov.unknown_since) < ovm.UNKNOWN_FOR) then
        TextColored(WARN, 'PupTimers was loaded while your automaton was out, so its burden is unknown until the game reports an overload chance.');
    end
    local any = false;
    for e = 1, 8 do
        local s = pt.ov.el[e];
        if (s ~= nil and s.used) then
            any = true;
            local bur = ovm.burden(pt.ov, e, now, p);
            local risk = ovm.next_risk(pt.ov, e, now, p);
            Text(('%-8s burden %5.1f   chance now %3d   next %3d   per maneuver %s%s'):format(
                data.elements[e].name, bur, math.floor(ovm.chance_of(bur, p) + 0.5), math.floor(risk + 0.5),
                s.pred and ('%d (stats)'):format(s.pred) or (s.b and ('%.0f'):format(s.b)) or ('~' .. ovm.base_burden(e, p)),
                s.exact and '' or '  (estimate)'));
        end
    end
    if (not any) then
        TextDisabled('Use a maneuver to start tracking.');
    end
    if (confirm_button('rse', 'Reset estimate', 'Click again to reset', true)) then
        pt.ov = ovm.new();
        pt.ov_last = nil;
    end

    imgui.Spacing();
    local adv = W_BOOL;
    adv[1] = (ui.show_advanced == true);
    if (imgui.Checkbox('Show server constants (advanced)', adv)) then
        ui.show_advanced = adv[1];
    end
    if (ui.show_advanced) then
        TextWrapped('Defaults follow LandSandBoat\'s code for this era as of mid-2026; HorizonXI\'s own values are not confirmed. Only change these if you know your server differs.');
        input_int('Seconds per decay tick', o, 'tick', 1, 10, 120);
        input_int('Base threshold', o, 'base_threshold', 0, 100, 120);
        input_int('Chance offset', o, 'chance_offset', 0, 20, 120);
        input_int('Burden lost per tick', o, 'base_decay', 0, 10, 120);
        input_int('Default burden per maneuver', o, 'default_burden', 1, 40, 120);
        input_int('Dark Maneuver burden', o, 'dark_burden', 1, 40, 120);
        input_int('Burden added on activation', o, 'spawn_burden', 0, 100, 120);
        TextDisabled('For gear PupTimers does not know: added to the threshold / to the burden lost per tick.');
        input_int('Extra threshold##ovth', o, 'extra_threshold', -50, 50, 120);
        imgui.SameLine();
        input_int('Extra decay##ovdc', o, 'extra_decay', -5, 10, 120);
        if (confirm_button('rod', 'Restore overload defaults', 'Click again to restore the defaults')) then
            local d = data.default_settings().overload;
            for _, k in ipairs({ 'tick', 'base_threshold', 'chance_offset', 'base_decay', 'default_burden', 'dark_burden', 'spawn_burden',
                                 'extra_threshold', 'extra_decay', 'heatsink_decay', 'heatsink_by_water' }) do
                o[k] = d[k];
            end
            changed();
        end
    end
end

local function tab_recasts()
    local cfg = pt.settings;
    TextWrapped('These come straight from the game\'s own recast timers and only appear while the ability is cooling down.');
    heading('Job abilities');
    TextColored(DIM, 'Show');
    imgui.SameLine(60);
    TextColored(DIM, 'Alert');
    imgui.SameLine(120);
    TextColored(DIM, 'Ability');
    for _, def in ipairs(data.job_abilities) do
        local opt = cfg.jobabilities[def.key];
        if (opt ~= nil) then
            push_id('ja_' .. def.key);
            checkbox('##show', opt, 'show');
            imgui.SameLine(60);
            checkbox('##alert', opt, 'alert');
            imgui.SameLine(120);
            Text(def.name);
            if (def.key == 'overdrive') then
                imgui.SameLine();
                TextDisabled('(2-hour, main job only)');
            end
            pop_id();
        end
    end
    imgui.Spacing();
    TextDisabled('The maneuver recast is configured on the Maneuvers tab.');
end

local function tab_appearance()
    local cfg = pt.settings;
    local hud = cfg.hud;

    heading('Size');
    slider_float('Overall size', hud, 'scale', 0.5, 3.0, '%.2fx', 'Scales text and bars together.');
    slider_int('Bar height', hud, 'bar_height', 6, 60);
    slider_int('Bar spacing', hud, 'bar_spacing', 0, 20);
    slider_int('Window padding', hud, 'padding', 0, 20);
    slider_int('Corner rounding', hud, 'rounding', 0, 12);
    slider_float('Background opacity', hud, 'bg_alpha', 0.0, 1.0, '%.2f');
    if (input_int('Width', hud, 'width', 60, 2000, 120)) then
        ui.force_pos = true;
    end
    imgui.SameLine();
    TextDisabled('(or drag the window corner while unlocked)');
    if (input_int('X##hudx', hud, 'x', -4000, 8000, 120)) then
        ui.force_pos = true;
    end
    imgui.SameLine();
    if (input_int('Y##hudy', hud, 'y', -4000, 8000, 120)) then
        ui.force_pos = true;
    end

    heading('Layout');
    combo('Time format', hud, 'time_format', OPT_TIME, 220);
    combo('Cooldown bars', hud, 'fill_mode', OPT_FILL, 220);
    combo('Sort abilities', hud, 'sort_abilities', OPT_SORT, 220);
    local grow_before = hud.grow;
    combo('New bars appear', hud, 'grow', OPT_GROW, 260);
    if (imgui.IsItemHovered()) then
        SetTooltip('Above: park the window just above your chat log, and new bars push its top edge up instead of spilling over the log or off the screen.');
    end
    if (hud.grow ~= grow_before) then
        -- Keep the window where it is: the saved y switches between its top and its bottom edge
        -- (corrected once the window is drawn, if its height changed meanwhile; see ui.render_hud).
        local h = ui.hud_h or 0;
        hud.y = (hud.grow == 'up') and (hud.y + h) or (hud.y - h);
        ui.grow_fix = { grow = hud.grow, h = h };
        ui.grow_measured = false;
        ui.force_pos = true;
    end
    checkbox('Hide during cutscenes and NPC conversations', hud, 'hide_in_events', 'The timers keep counting while hidden.');
    checkbox('Show automaton name above the bars', hud, 'show_header');
    checkbox('Gap between sections', hud, 'show_section_gap');
    checkbox('Text shadow', hud, 'text_shadow');

    Text('Section order:');
    local order = core.section_order(hud.order);
    for i, key in ipairs(order) do
        push_id('ord_' .. i);
        Text(('  %d. %s'):format(i, SECTION_NAMES[key]));
        imgui.SameLine(260);
        local up = imgui.SmallButton('Up');
        imgui.SameLine();
        local down = imgui.SmallButton('Down');
        if (up and i > 1) then
            order[i], order[i - 1] = order[i - 1], order[i];
            hud.order = table.concat(order, ',');
            changed();
        elseif (down and i < #order) then
            order[i], order[i + 1] = order[i + 1], order[i];
            hud.order = table.concat(order, ',');
            changed();
        end
        pop_id();
    end

    heading('Colours');
    if (confirm_button('pal_def', 'Default colours', 'Click again: default colours')) then
        pt.actions.apply_palette('default');
        set_status('Default colours restored.');
    end
    if (imgui.IsItemHovered()) then
        SetTooltip('Every colour back to its default: the window, the elements and the automaton abilities.');
    end
    imgui.SameLine();
    if (confirm_button('pal_cb', 'Colour-blind friendly', 'Click again: colour-blind')) then
        pt.actions.apply_palette('colorblind');
        set_status('Colour-blind friendly colours applied.');
    end
    if (imgui.IsItemHovered()) then
        SetTooltip('Colours that stay distinct with the common kinds of colour blindness (the Okabe-Ito set). Overload risk runs blue, yellow, orange, vermillion instead of green to red.');
    end
    imgui.SameLine();
    if (confirm_button('pal_hc', 'High contrast', 'Click again: high contrast')) then
        pt.actions.apply_palette('contrast');
        set_status('High contrast colours applied.');
    end
    if (imgui.IsItemHovered()) then
        SetTooltip('Brighter colours on darker, more solid bars.');
    end
    local c = cfg.colors;
    for i, e in ipairs(COLOR_ENTRIES) do
        push_id('col_' .. e[1]);
        color_edit(e[2], c, e[1], false);
        pop_id();
        if (i % 2 == 1) then
            imgui.SameLine(260);
        end
    end
    imgui.NewLine();
    TextDisabled('Automaton ability colours are on the Automaton tab, element colours on the Maneuvers tab.');
end

local function tab_alerts()
    local cfg = pt.settings;
    local a = cfg.alerts;

    TextWrapped('These apply to every PupTimers alert: abilities coming off cooldown and the warnings you turn on in other tabs (overload risk, no Automaton Oil, Repair reminder ...). To quiet one ability, untick its Alert box on the Automaton or Recasts tab instead.');
    heading('When something is ready');
    checkbox('Print a message in the chat log', a, 'chat');
    checkbox('Play a sound', a, 'sound');
    local sounds = pt.list_sounds();
    local opts = {};
    for _, f in ipairs(sounds) do
        opts[#opts + 1] = { f, f };
    end
    if (#opts > 0) then
        combo('Sound file', a, 'sound_file', opts, 220);
        imgui.SameLine();
        if (imgui.Button('Play')) then
            pt.actions.play_sound(true);
        end
        TextDisabled('Add your own .wav files to the addon\'s sounds folder.');
    else
        TextColored(BAD, 'No .wav files found in the addon\'s sounds folder.');
    end
    heading('READY bars');
    TextWrapped('By default a bar disappears the moment its cooldown ends, so the window only ever shows what is cooling down. Turn these on if you also want a READY bar.');
    slider_int('Show a READY bar for (seconds, 0 = off)', a, 'ready_hold', 0, 30);
    checkbox('Keep ready automaton abilities on screen until used again', a, 'keep_ready');
    checkbox('Flash READY bars', a, 'flash');
end

local function tab_help()
    TextColored(HEAD, 'Commands');
    imgui.Separator();
    for _, c in ipairs(HELP_CMDS) do
        TextColored(GOOD, c[1]);
        imgui.SameLine(210);
        Text(c[2]);
    end
    imgui.Spacing();
    TextColored(HEAD, 'Tips');
    imgui.Separator();
    TextWrapped('- Unlock the window, drag it where you want it, drag the lower-right corner to change the width, then /pupt lock.');
    TextWrapped('- "Overall size" on the Appearance tab makes everything bigger or smaller.');
    TextWrapped('- Settings are saved per character automatically.');
    TextWrapped('- If a cooldown looks wrong for your server, change it on the Automaton tab.');
    TextWrapped('- Any of these commands can go on a key with Ashita\'s /bind command, for example to open this window or hide the timers.');
    TextWrapped('- PupTimers only reads what your game client already receives. It never sends anything to the server and never acts for you.');
end

----------------------------------------------------------------------------------------------------
-- Settings window
----------------------------------------------------------------------------------------------------

function ui.render_config(now)
    if (not ui.config_open[1]) then
        return;
    end

    imgui.SetNextWindowSize(CFG_SIZE, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints(CFG_MIN, CFG_MAX);
    local ok, err = true, nil;
    if (imgui.Begin(('PupTimers v%s##pt_config'):format(addon.version), ui.config_open, ImGuiWindowFlags_NoCollapse)) then
        ok, err = pcall(ui.config_body, now);
    end
    imgui.End();

    if (not ok) then
        -- Close the window so a broken frame is not repeated every frame.
        ui.config_open[1] = false;
        error(err, 0);
    end
    if (not ui.config_open[1] and pt.dirty_at ~= nil) then
        pt.save_now();   -- closed with a change not written yet: write it now
    end
end

-- Profiles tab: profile names sorted once per read of the profiles file.
ui.prof_name = { '' };
ui.ab_all = { false };      -- Automaton tab: list every ability, not only the setup's
local PROF_NAMES, PROF_SRC = {}, nil;
local function profile_names(t)
    if (PROF_SRC ~= t) then
        PROF_SRC = t;
        PROF_NAMES = {};
        for name in pairs(t.list) do
            PROF_NAMES[#PROF_NAMES + 1] = name;
        end
        table.sort(PROF_NAMES);
    end
    return PROF_NAMES;
end

local function tab_profiles()
    local cfg = pt.settings;
    local pc = cfg.profiles;
    TextWrapped('A profile is a saved copy of your PupTimers settings: the look, alerts, tracked abilities and the maneuver and overload options. Profiles are shared by all your characters, so you can save one here and load it on another character. The window position, lock, the way new bars grow, and names always stay with each character.');

    heading('Save');
    push_width(200);
    imgui.InputText('##pt_prof_name', ui.prof_name, 32);
    pop_width();
    imgui.SameLine();
    if (imgui.Button('Save current settings as this profile')) then
        local _, text = pt.actions.profile_save(ui.prof_name[1]);
        set_status(text);
    end

    heading('Saved profiles');
    local t = pt.profiles_read(false);
    if (pt.profiles_error ~= nil) then
        TextColored(WARN, 'The profiles file could not be read (' .. pt.profiles_error .. '). It is left as it is.');
    end
    local names = profile_names(t);
    if (#names == 0) then
        TextDisabled('No profiles yet.');
    end
    for i, name in ipairs(names) do
        push_id('prof_' .. i);
        Text(name .. ((name == pc.last) and '   (loaded last)' or ''));
        imgui.SameLine(300);
        if (imgui.SmallButton('Load')) then
            local _, text = pt.actions.profile_load(name);
            set_status(text);
        end
        imgui.SameLine();
        if (confirm_button('del_' .. name, 'Delete', 'Click again to delete', true)) then
            local _, text = pt.actions.profile_delete(name);
            set_status(text);
        end
        pop_id();
    end

    heading('Switch with the automaton\'s frame');
    checkbox('Load the profile chosen below when the automaton\'s frame changes', pc, 'auto', 'PupTimers reads the frame from the game, so switching frames switches your PupTimers setup with it.');
    if (not pc.auto) then
        TextDisabled('Tick the box above to use these.');
    end
    for _, f in ipairs(data.frames) do
        push_id('pf_' .. f.key);
        local cur = pc.frames[f.key] or '';
        push_width(220);
        if (begin_combo(f.name, (cur == '') and '(none)' or cur)) then
            if (imgui.Selectable('(none)', cur == '')) then
                pc.frames[f.key] = '';
                changed();
            end
            for _, name in ipairs(names) do
                if (imgui.Selectable(name, cur == name)) then
                    pc.frames[f.key] = name;
                    changed();
                end
            end
            end_combo();
        end
        pop_width();
        pop_id();
    end
    if (pt.kit ~= nil and pt.kit.frame_name ~= nil) then
        TextDisabled('Your automaton\'s frame now: ' .. pt.kit.frame_name);
    end
    TextDisabled('Commands: /pupt profile lists them, /pupt profile <name> loads one (handy in a macro).');

    heading('Copy from another character');
    local others = pt.other_characters();
    if (#others == 0) then
        TextDisabled('No other characters with PupTimers settings found.');
    else
        local pick = ui.copy_pick;
        if (pick == nil or others[pick] == nil) then
            pick = 1;
            ui.copy_pick = 1;
        end
        push_width(200);
        if (begin_combo('##pt_copy_from', others[pick].name)) then
            for i, c in ipairs(others) do
                push_id('cf_' .. i);
                if (imgui.Selectable(c.name, i == pick)) then
                    ui.copy_pick = i;
                end
                pop_id();
            end
            end_combo();
        end
        pop_width();
        imgui.SameLine();
        if (confirm_button('cpy', 'Copy their settings', 'Click again to copy')) then
            local _, text = pt.actions.copy_from(others[pick].name);
            set_status(text);
        end
        if (imgui.IsItemHovered()) then
            SetTooltip('Replaces this character\'s PupTimers settings with theirs (look, alerts, abilities, maneuvers, overload). Window position and names stay. Click twice to confirm.');
        end
    end
end

local TABS = {
    { 'General', tab_general },
    { 'Automaton', tab_automaton },
    { 'Maneuvers', tab_maneuvers },
    { 'Overload', tab_overload },
    { 'Recasts', tab_recasts },
    { 'Appearance', tab_appearance },
    { 'Alerts', tab_alerts },
    { 'Profiles', tab_profiles },
    { 'Help', tab_help },
};

function ui.config_body(now)
    do
        local first_err = nil;
        if (imgui.BeginTabBar('##pt_tabs')) then
            for _, t in ipairs(TABS) do
                if (imgui.BeginTabItem(t[1])) then
                    -- Each tab is protected: on an error, unwind what it pushed and still close the tab.
                    local ok, err = pcall(t[2]);
                    unwind_stacks();
                    imgui.EndTabItem();
                    if (not ok and first_err == nil) then
                        first_err = ('%s tab: %s'):format(t[1], tostring(err));
                    end
                end
            end
            imgui.EndTabBar();
        end
        if (first_err ~= nil) then
            error(first_err, 0);
        end

        imgui.Spacing();
        imgui.Separator();
        if (ui.status_msg ~= nil and now < ui.status_until) then
            TextColored(GOOD, ui.status_msg);
        else
            TextDisabled('Settings save automatically for this character.');
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------------------------------

function ui.init(app)
    pt = app;
    ui.sync_buffers();
    ui.invalidate_caches();
end

function ui.toggle_config(state)
    if (state == nil) then
        ui.config_open[1] = not ui.config_open[1];
    else
        ui.config_open[1] = state;
    end
    if (ui.config_open[1]) then
        ui.sync_buffers();
    end
end

function ui.render(now)
    ui.frame = ui.frame + 1;
    -- The timer window and the settings window are independent: a failure in one must not hide the other.
    local ok1, err1 = pcall(ui.render_hud, now);
    local ok2, err2 = pcall(ui.render_config, now);
    if (not ok1) then
        error(err1, 0);
    end
    if (not ok2) then
        error(err2, 0);
    end
end

return ui;
