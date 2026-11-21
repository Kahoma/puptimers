--[[
* PupTimers - overload (burden) estimator.
*
* Server model (LandSandBoat, which HorizonXI is built on):
*   - every element has its own BURDEN value on your automaton
*   - a maneuver adds burden to its element (about 14-20, depends on your stats vs. the automaton's)
*   - every tick each element loses (1 + burden-decay gear/attachments) burden
*   - overload is only possible once burden > threshold (30 + threshold gear/attachments)
*   - the chance the game reports after a maneuver is  burden - threshold + 5  (shown as 0 when lower)
*   - an overload lasts (burden - threshold) seconds and removes all maneuvers
*
* After each maneuver the server tells us the overload chance for that element (action packet result
* or the "<player>'s Fire Maneuver overload chance is N%" chat line). When that number is above 0 it pins the
* element's burden exactly; in between we let it decay at the known rate. The burden a maneuver adds
* is learned from consecutive reports, so stat differences and gear are picked up automatically.
*
* Pure Lua, no game dependencies (see the tests).
--]]

local data = require('pt_data');

local ov = {};

--[[
* Builds the parameter table from settings + detected gear.
*   thresh_mod / decay_mod: totals from gear and attachments (positive decay = faster cooling)
*   suppress  : Kenkonken (burden gains divided by 3)
*   overdrive : Overdrive is up (the server adds 5000 to the threshold, so nothing can overload)
*   out       : optional table to fill instead of creating one
--]]
function ov.params(cfg, thresh_mod, decay_mod, suppress, overdrive, out)
    local o = cfg.overload;
    local p = out or {};
    p.T_after        = (tonumber(o.base_threshold) or 30) + (tonumber(thresh_mod) or 0);   -- threshold without Overdrive
    p.overdrive      = (overdrive == true);
    p.T              = p.T_after + (p.overdrive and data.OVERDRIVE_THRESH or 0);
    p.offset         = tonumber(o.chance_offset) or 5;
    p.decay          = math.max(1, (tonumber(o.base_decay) or 1) + (tonumber(decay_mod) or 0));
    p.tick           = math.max(0.5, tonumber(o.tick) or 3);
    p.default_burden = tonumber(o.default_burden) or 20;
    p.dark_burden    = tonumber(o.dark_burden) or 15;
    p.spawn_burden   = tonumber(o.spawn_burden) or 0;
    p.suppress       = (suppress == true);
    if (p.suppress) then
        -- Kenkonken: every burden gain is divided by 3 (rounded down) on the server, the burden
        -- a new automaton starts with included.
        p.default_burden = math.floor(p.default_burden / 3);
        p.dark_burden = math.floor(p.dark_burden / 3);
        p.spawn_burden = math.floor(p.spawn_burden / 3);
    end
    return p;
end

--[[
* Call when the decay rate is about to change (Heatsink maneuvers, settings): fixes the current
* burden values with the old rate so the new rate only applies from now on.
--]]
function ov.rebase(st, now, old_p)
    for e = 1, 8 do
        local s = st.el[e];
        if (s.burden > 0) then
            s.burden = ov.burden(st, e, now, old_p);
            s.t = now;
        end
    end
end

-- Kenkonken on/off changes how much a maneuver adds: forget what was learned.
function ov.set_suppress(st, suppress)
    if (st.suppress ~= suppress) then
        st.suppress = suppress;
        for e = 1, 8 do
            st.el[e].b = nil;
        end
    end
end

function ov.new()
    local st = { el = {}, overload_el = nil, overload_until = nil, reports = 0, unknown_since = nil };
    for e = 1, 8 do
        st.el[e] = {
            burden = 0,       -- burden at time t
            t      = 0,
            exact  = false,   -- true when pinned by a report above 0%
            b      = nil,     -- learned burden per maneuver for this element
            pred   = nil,     -- burden the next maneuver adds, worked out from stats (set from outside)
            used   = false,   -- seen at least one maneuver of this element
        };
    end
    -- How well each way of predicting the burden of a maneuver matched the game's reports:
    -- 'era' and 'classic' are the two server rules worked out from stats, 'learned' is the learned value.
    st.rules = {
        era     = { err = 0, n = 0 },
        classic = { err = 0, n = 0 },
        learned = { err = 0, n = 0 },
    };
    return st;
end

-- One more comparison of a prediction with what the game's reports showed. Off by one is not held
-- against it: the server's 3-second cooling tick can fall either side of a report.
local function score(r, pred, obs)
    local err = math.max(0, math.abs(pred - obs) - 1);
    r.err = (r.n == 0) and err or (r.err * 0.7 + err * 0.3);
    r.n = r.n + 1;
end

--[[
* The stat rule that predicts the burden of a maneuver best, or nil: it must have matched the game's
* reports at least twice, within a tick, and at least as well as the learned values.
--]]
function ov.best_rule(st)
    local best, best_r = nil, nil;
    for _, k in ipairs({ 'era', 'classic' }) do
        local r = st.rules[k];
        if (r.n >= 2 and r.err <= 0.5 and (best_r == nil or r.err < best_r.err)) then
            best, best_r = k, r;
        end
    end
    local l = st.rules.learned;
    if (best_r ~= nil and l.n >= 2 and l.err < best_r.err) then
        return nil;
    end
    return best;
end

-- How long an "unknown since load" estimate is flagged: by then any usual burden has cooled a lot.
ov.UNKNOWN_FOR = 180;

--[[
* The automaton was already out when PupTimers loaded, so its burden is unknown (it is not 0). The
* rows say so until the game reports a chance, a new automaton appears, or UNKNOWN_FOR passes.
--]]
function ov.mark_unknown(st, now)
    st.unknown_since = now;
end

-- Burden of element e at time now (decays continuously at decay/tick per second).
function ov.burden(st, e, now, p)
    local s = st.el[e];
    if (s == nil or s.burden <= 0) then
        return 0;
    end
    local dt = now - s.t;
    if (dt <= 0) then
        return s.burden;
    end
    local v = s.burden - p.decay * (dt / p.tick);
    if (v < 0) then
        v = 0;
    end
    return v;
end

local function per_maneuver(s, e, p)
    if (s.pred ~= nil) then
        return s.pred;
    end
    if (s.b ~= nil) then
        return s.b;
    end
    if (e == 8) then
        return p.dark_burden;
    end
    return p.default_burden;
end

-- Chance the game would report for a burden value (0 when not above threshold - offset).
function ov.chance_of(burden, p)
    local c = burden - p.T + p.offset;
    if (c < 0) then
        return 0;
    end
    return c;
end

-- Overload chance if a maneuver of element e were used now.
function ov.next_risk(st, e, now, p)
    local s = st.el[e];
    local nb = ov.burden(st, e, now, p) + per_maneuver(s, e, p);
    if (nb <= p.T) then
        return 0, nb;
    end
    return nb - p.T + p.offset, nb;
end

--[[
* A maneuver of element e was used.
* @param report - { chance = n, overloaded = bool } from the server, or nil if none was seen
--]]
--[[
* era / classic: the burden this maneuver adds by the two server rules, worked out from stats at the
* moment it was used (nil when not known); they are scored against the game's reports.
--]]
function ov.on_maneuver(st, e, now, p, report, era, classic)
    local s = st.el[e];
    if (s == nil) then
        return;
    end
    local before = ov.burden(st, e, now, p);
    -- Remember the state before this maneuver so a report arriving a moment later can be matched.
    s.pending = { time = now, before = before, was_exact = s.exact, was_used = s.used,
                  learned = (s.b ~= nil) and s.b or ((e == 8) and p.dark_burden or p.default_burden),
                  era = era, classic = classic };
    s.burden = math.min(255, before + per_maneuver(s, e, p));
    s.t = now;
    s.exact = false;
    s.used = true;
    s.touched = true;
    if (report ~= nil and type(report.chance) == 'number') then
        ov.on_report(st, e, now, p, report.chance, report.overloaded);
    end
end

--[[
* The server reported the overload chance for element e (right after a maneuver of that element).
* Above 0% it pins the burden exactly; at 0% it only caps it.
--]]
function ov.on_report(st, e, now, p, chance, overloaded)
    local s = st.el[e];
    if (s == nil or type(chance) ~= 'number') then
        return;
    end
    st.reports = st.reports + 1;
    st.unknown_since = nil;
    local pend = s.pending;
    if (pend ~= nil and (now - pend.time) > 3.0) then
        pend = nil;
    end
    -- Overdrive's +5000 threshold makes any chance above 0% impossible, so a positive report was
    -- worked out without it: Overdrive can wear off in the same server tick as a maneuver, before
    -- its buff is gone on our side. Burden is a byte on the server (0-255).
    local T = p.T_after or p.T;
    if (chance > 0) then
        local new = math.min(255, chance + T - p.offset);
        -- Learn how much burden one maneuver of this element adds, from two pinned values in a row.
        if (pend ~= nil and pend.was_exact and pend.was_used) then
            local b_obs = new - pend.before;
            if (b_obs >= 1 and b_obs <= 60) then
                score(st.rules.learned, pend.learned, b_obs);
                if (pend.era ~= nil) then
                    score(st.rules.era, pend.era, b_obs);
                end
                if (pend.classic ~= nil) then
                    score(st.rules.classic, pend.classic, b_obs);
                end
                s.b = (s.b == nil) and b_obs or (s.b * 0.5 + b_obs * 0.5);
            end
        end
        s.burden = new;
        s.exact = true;
    else
        -- 0% means burden <= threshold - offset; keep our estimate but never above that.
        local cur = ov.burden(st, e, now, p);
        s.burden = math.max(0, math.min(cur, p.T - p.offset));
        s.exact = false;
    end
    s.t = now;
    s.used = true;
    s.touched = true;
    s.pending = nil;
    if (overloaded) then
        st.overload_el = e;
        st.overload_until = now + math.max(0, s.burden - T);   -- no overload is possible during Overdrive
    end
end

--[[
* A new automaton entity was created (Activate, Deus Ex Automata, or the respawn after zoning).
* The server builds a fresh automaton, so burden restarts at the spawn value in every element
* (30 on 2022-23 LandSandBoat code, 35 on 2026+ code); nothing carries over from before.
--]]
function ov.on_spawn(st, now, p)
    local v = math.max(0, math.min(255, p.spawn_burden or 0));
    for e = 1, 8 do
        local s = st.el[e];
        s.burden = v;
        s.t = now;
        s.exact = false;
        s.pending = nil;
        s.used = (v > 0);
        s.touched = false;
    end
    st.overload_el = nil;
    st.overload_until = nil;
    st.unknown_since = nil;
end

-- Automaton deactivated / gone: its burden is discarded with it.
function ov.on_despawn(st, now)
    st.unknown_since = nil;
    for e = 1, 8 do
        local s = st.el[e];
        s.burden = 0;
        s.t = now;
        s.exact = false;
        s.pending = nil;
        s.touched = false;
    end
end

function ov.overload_left(st, now)
    if (st.overload_until == nil) then
        return nil;
    end
    local left = st.overload_until - now;
    if (left <= 0) then
        return 0;
    end
    return left;
end

--[[
* Rows for the timer window.
*   show    'all' (default): one bar for every element whose overload is active; 'top': only the riskiest
*   hide_at 'chance' (default): an element's bar disappears when its overload chance reaches 0%
*           'burden': it stays until the burden has fully cooled (so the next-maneuver risk stays visible)
*   fill    chance mode: chance / full_at (default 50%), so the bar empties exactly as it disappears
*           burden mode: burden / (threshold + 20), with a white marker at the threshold
*   colour  'risk' (default): by the chance of the next maneuver of that element; 'element': element colour
* Burden that only comes from activating the automaton (every element at 30) is shown once as "all".
* During Overdrive nothing can overload, so the bars show the chances that apply once it ends
* ("after OD").
--]]
local function by_risk(a, b)
    if (a.risk ~= b.risk) then
        return a.risk > b.risk;
    end
    if (a.burden ~= b.burden) then
        return a.burden > b.burden;
    end
    return a.e < b.e;
end

local AFTER_OD = {};   -- reused: the parameters as they will be once Overdrive ends

-- p itself, or (during Overdrive) the parameters that will apply once it ends.
function ov.after_overdrive(p)
    if (not p.overdrive) then
        return p;
    end
    for k, v in pairs(p) do
        AFTER_OD[k] = v;
    end
    AFTER_OD.T = p.T_after;
    AFTER_OD.overdrive = false;
    return AFTER_OD;
end

function ov.rows(st, now, p, cfg)
    local o = cfg.overload;
    local od = (p.overdrive == true);
    p = ov.after_overdrive(p);
    local colors = cfg.colors;
    local by_chance = (o.hide_at ~= 'burden');
    local list = {};
    local untouched = nil;
    for e = 1, 8 do
        local bur = ov.burden(st, e, now, p);
        local chance = ov.chance_of(bur, p);
        if ((by_chance and chance >= 0.5) or (not by_chance and bur >= 0.5)) then
            local risk = ov.next_risk(st, e, now, p);
            local it = { e = e, burden = bur, chance = chance, risk = risk };
            if (st.el[e].touched) then
                list[#list + 1] = it;
            elseif (untouched == nil or it.risk > untouched.risk) then
                untouched = it;
            end
        end
    end
    local only_top = (o.show == 'top');
    if (untouched ~= nil) then
        local hottest = 0;
        for _, it in ipairs(list) do
            hottest = math.max(hottest, it.risk);
        end
        if (#list == 0 or not only_top or untouched.risk > hottest) then
            untouched.all = true;
            list[#list + 1] = untouched;
        end
    end
    local rows = {};
    if (st.unknown_since ~= nil and (now - st.unknown_since) < ov.UNKNOWN_FOR) then
        rows[1] = {
            label = 'Overload unknown since load',
            short_label = 'Overload ?',
            right = '',
            frac  = 0,
            color = colors.overload_low,
            dim   = true,
            thin  = (o.compact == true),
            note  = true,   -- information, not a timer: does not keep the window up on its own
        };
    end
    if (#list == 0) then
        return rows;
    end
    table.sort(list, by_risk);

    local full = math.max(5, tonumber(o.full_at) or 50);
    local scale = p.T + 20;
    local limit = only_top and 1 or #list;
    for i = 1, math.min(limit, #list) do
        local it = list[i];
        local col;
        if (o.color_by == 'element' and not it.all) then
            local el = data.elements[it.e];
            col = (cfg.maneuvers and cfg.maneuvers.colors and cfg.maneuvers.colors[el.key]) or el.color;
        elseif (it.risk <= 0) then
            col = colors.overload_safe;
        elseif (it.risk < 20) then
            col = colors.overload_low;
        elseif (it.risk < 40) then
            col = colors.overload_mid;
        else
            col = colors.overload_high;
        end
        local name = it.all and 'all' or data.elements[it.e].name;
        local pct = math.floor(it.chance + 0.5);
        rows[#rows + 1] = {
            -- '~': estimates between the game's reports, not numbers the game printed.
            label  = ('Overload %s ~%d%%'):format(name, pct),
            short_label = ('%s ~%d%%'):format(it.all and 'All' or name, pct),  -- for narrow windows
            right_optional = true,                                             -- dropped first when space runs out
            right  = od and 'after OD' or ('next ~%d%%'):format(math.floor(it.risk + 0.5)),
            frac   = by_chance and math.min(1, it.chance / full) or math.min(1, it.burden / scale),
            marker = (not by_chance) and math.min(1, p.T / scale) or nil,
            color  = col,
            flash  = (not od) and it.risk >= 40,
            thin   = (o.compact == true),
        };
    end
    return rows;
end

return ov;
