--[[
* PupTimers - core tracking logic.
*
* This module has no dependency on Ashita or the game: every function takes plain values (the
* current time, chat text, packet bytes, buff counts, recast values) and updates a state table.
* puptimers.lua feeds it from the game; the test suite feeds it directly.
--]]

local data = require('pt_data');

local core = {};

----------------------------------------------------------------------------------------------------
-- Formatting
----------------------------------------------------------------------------------------------------

--[[
* Formats a number of seconds for display.
* 'mss' -> 0:09, 1:05, 1:02:03     'sec' -> 9s, 65s, 1h02m
--]]
local time_cache = { mss = {}, sec = {} };   -- whole seconds -> text (timers show the same values again and again)

function core.format_time(secs, style)
    if (secs == nil) then
        return '';
    end
    local s = math.ceil(secs - 0.0001);
    if (s <= 0) then
        s = 0;   -- (also turns -0 into 0)
    end
    local cache = (style == 'sec') and time_cache.sec or time_cache.mss;
    local v = cache[s];
    if (v ~= nil) then
        return v;
    end
    if (style == 'sec') then
        if (s >= 3600) then
            v = string.format('%dh%02dm', math.floor(s / 3600), math.floor((s % 3600) / 60));
        else
            v = string.format('%ds', s);
        end
    elseif (s >= 3600) then
        v = string.format('%d:%02d:%02d', math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60);
    else
        v = string.format('%d:%02d', math.floor(s / 60), s % 60);
    end
    if (s < 900) then
        cache[s] = v;
    end
    return v;
end

-- Compact form used under maneuver icons when the window is too narrow for 0:00: '45', '2m'.
local short_cache = {};

-- '0%' .. '100%', made once (rebuilt rows reuse these strings).
local PCT = {};
for i = 0, 100 do
    PCT[i] = i .. '%';
end
function core.format_pct(v)
    local i = math.floor((tonumber(v) or 0) + 0.5);
    if (i < 0) then
        i = 0;
    elseif (i > 100) then
        i = 100;
    end
    return PCT[i];
end

function core.format_short(secs)
    local s = math.ceil((secs or 0) - 0.0001);
    if (s <= 0) then
        s = 0;   -- (also turns -0 into 0)
    end
    if (s >= 100) then
        s = -math.floor(s / 60);   -- negative keys hold the minute forms
    end
    local v = short_cache[s];
    if (v == nil) then
        v = (s >= 0) and tostring(s) or (tostring(-s) .. 'm');
        if (s > -900) then
            short_cache[s] = v;
        end
    end
    return v;
end

----------------------------------------------------------------------------------------------------
-- Chat parsing
----------------------------------------------------------------------------------------------------

--[[
* Removes FFXI color codes, auto-translate brackets and control characters from a chat line.
--]]
function core.clean_text(s)
    if (type(s) ~= 'string') then
        return '';
    end
    s = s:gsub('[\30\31\127].', '');   -- two-byte color / special codes
    s = s:gsub('\239[\39\40]', '');     -- auto-translate open / close markers
    s = s:gsub('%c', ' ');              -- line breaks and any other control bytes
    s = s:gsub('%s+', ' ');
    s = s:gsub('^ ', '');
    s = s:gsub(' $', '');
    return s;
end

--[[
* Normalizes a character name for comparisons.
--]]
function core.normalize_name(name)
    if (type(name) ~= 'string') then
        return '';
    end
    return (core.clean_text(name):lower());
end

--[[
* If the (lowercase) line is "<actor> uses ..." (optionally prefixed with "the "), returns the text
* after "uses ". Matching is anchored at the start of the line so party chat such as
* "(Bob) Sharpshot uses Flashbulb" never matches.
--]]
local function after_actor_uses(lower, actor)
    if (actor == nil or actor == '') then
        return nil;
    end
    local pos = 1;
    if (lower:sub(1, 4) == 'the ') then
        pos = 5;
    end
    local needle = actor .. ' uses ';
    if (lower:sub(pos, pos + #needle - 1) == needle) then
        return lower:sub(pos + #needle);
    end
    return nil;
end

local function is_word_end(rest, n)
    local c = rest:sub(n + 1, n + 1);
    return c == '' or c:match('[%w\']') == nil;
end

--[[
* Builds the matching context used by core.parse_chat.
*
* @param pet_name      - automaton name (any case)
* @param player_name   - player name (any case)
* @param ability_list  - array of { key = ..., name = ... } that should be recognized
--]]
function core.make_chat_context(pet_name, player_name, ability_list)
    local ctx = {
        pet       = core.normalize_name(pet_name),
        player    = core.normalize_name(player_name),
        abilities = {},
    };
    for _, a in ipairs(ability_list or {}) do
        local lname = core.normalize_name(a.name);
        if (lname ~= '') then
            ctx.abilities[#ctx.abilities + 1] = { key = a.key, lname = lname };
        end
    end
    -- Longest names first so "Shock Absorber II" style names win over shorter prefixes.
    table.sort(ctx.abilities, function (a, b)
        if (#a.lname ~= #b.lname) then
            return #a.lname > #b.lname;
        end
        return a.lname < b.lname;
    end);
    return ctx;
end

--[[
* Parses one chat line.
*
* @return nil, or one of:
*   { kind = 'pet_ability', key = <ability key> }
*   { kind = 'pet_unknown', text = <clean line> }      -- pet used something not in the list
*   { kind = 'maneuver',    element = <1..8> }         -- player used a maneuver
--]]
function core.parse_chat(line, ctx)
    if (ctx == nil) then
        return nil;
    end
    local text = core.clean_text(line);
    if (text == '') then
        return nil;
    end
    local lower = text:lower();

    local rest = after_actor_uses(lower, ctx.pet);
    if (rest ~= nil) then
        for _, a in ipairs(ctx.abilities) do
            if (rest:sub(1, #a.lname) == a.lname and is_word_end(rest, #a.lname)) then
                return { kind = 'pet_ability', key = a.key };
            end
        end
        -- Not a tracked ability: pull the ability name out of the original text so the settings
        -- window can offer to track it ("Sharpshot uses Arcuballista." -> "Arcuballista").
        local orig = text:sub(#text - #rest + 1);
        local name = orig:match('^(.-)[%.,!]') or orig;
        name = name:gsub('%s+[Oo][Nn]%s.*$', '');
        name = name:gsub('%s+$', '');
        if (#name > 32) then
            name = name:sub(1, 32);
        end
        return { kind = 'pet_unknown', text = text, name = name };
    end

    -- Client text of message 798 / 799 (from the game's own message data):
    --   798: "<player>'s <Element> Maneuver overload chance is <n>%."
    --   799: "<player>'s <Element> Maneuver overload chance is <n>%.<line break><player> is overloaded!"
    local oc = lower:match('overload chance is (%d+)%%');
    local overloaded = (oc ~= nil and lower:find('overloaded', 1, true) ~= nil);
    local body = lower;
    if (body:sub(1, 4) == 'the ') then
        body = body:sub(5);
    end

    if (ctx.player ~= nil and ctx.player ~= '') then
        local own = ctx.player .. "'s ";
        if (oc ~= nil and body:sub(1, #own) == own) then
            local el = body:sub(#own + 1):match('^(%a+) maneuver overload chance');
            if (el ~= nil and data.element_index[el] ~= nil) then
                return { kind = 'maneuver', element = data.element_index[el], overload_chance = tonumber(oc), overloaded = overloaded };
            end
        end
        -- The 799 line break can arrive as its own line: "<player> is overloaded!"
        local tail = ctx.player .. ' is overloaded';
        if (body:sub(1, #tail) == tail) then
            return { kind = 'overloaded' };
        end
    end

    rest = after_actor_uses(lower, ctx.player);
    if (rest ~= nil) then
        local el = rest:match('^(%a+) maneuver');
        if (el ~= nil and data.element_index[el] ~= nil) then
            local ev = { kind = 'maneuver', element = data.element_index[el] };
            if (oc ~= nil) then
                ev.overload_chance = tonumber(oc);
                ev.overloaded = overloaded;
            end
            return ev;
        end
    end

    -- Fallback wording some server builds describe in comments: "<automaton>'s overload chance is 23%."
    if (oc ~= nil and ctx.pet ~= nil and ctx.pet ~= '') then
        if (body:sub(1, #ctx.pet + 2) == ctx.pet .. "'s") then
            return { kind = 'overload_report', chance = tonumber(oc), overloaded = overloaded };
        end
    end

    return nil;
end

----------------------------------------------------------------------------------------------------
-- Action packet (0x028) parsing
----------------------------------------------------------------------------------------------------

--[[
* Reads an unsigned little-endian, LSB-first bit field from a byte string (the same packing the
* server uses: packBitsBE in LandSandBoat). pos is the absolute bit offset from the packet start.
--]]
function core.read_bits(bytes, pos, n)
    local first = math.floor(pos / 8);
    local shift = pos % 8;
    local count = math.ceil((shift + n) / 8);
    local v, mul = 0, 1;
    for i = 0, count - 1 do
        local b = bytes:byte(first + i + 1);
        if (b == nil) then
            return nil;
        end
        v = v + b * mul;
        mul = mul * 256;
    end
    v = math.floor(v / (2 ^ shift));
    return v % (2 ^ n);
end

--[[
* Parses the header of an action packet (incoming 0x028).
* Layout (bits from the start of the packet, header included):
*   40: actor id (32)  72: target count (6)  78: result count (4)  82: category (4)  86: param (32)
--]]
function core.parse_action(bytes)
    if (type(bytes) ~= 'string' or #bytes < 15) then
        return nil;
    end
    local act = {
        actor    = core.read_bits(bytes, 40, 32),
        targets  = core.read_bits(bytes, 72, 6),
        category = core.read_bits(bytes, 82, 4),
        param    = core.read_bits(bytes, 86, 32),
    };
    -- First target / first result (header is 150 bits; target id 32 + result count 4; then the
    -- result: miss 3, kind 2, sub_kind 12, info 5, scale 5, value 17, message 10, ...).
    -- For a maneuver the value is the overload chance and the message is 798 (or 799 = overloaded).
    if (act.targets ~= nil and act.targets >= 1 and #bytes >= 30) then
        act.target1  = core.read_bits(bytes, 150, 32);
        act.results1 = core.read_bits(bytes, 182, 4);
        if (act.results1 ~= nil and act.results1 >= 1) then
            act.value1   = core.read_bits(bytes, 213, 17);
            act.message1 = core.read_bits(bytes, 230, 10);
        end
    end
    return act;
end

core.MSG_OVERLOAD_CHANCE = 798;   -- "<pet>'s overload chance is <n>%."
core.MSG_OVERLOADED      = 799;   -- "... overload chance is <n>%. <pet> is overloaded!"

----------------------------------------------------------------------------------------------------
-- Status timers (incoming 0x063, type 9): the player's buffs with their real end times.
-- Same layout XIUI reads on HorizonXI: type byte at 0x04, 32 x uint16 status ids at 0x08,
-- 32 x uint32 end times at 0x48 (1/60 s since the Vana'diel epoch, wrapping at 2^32).
----------------------------------------------------------------------------------------------------

local function u16(b, off)
    local x, y = b:byte(off + 1, off + 2);
    if (y == nil) then
        return nil;
    end
    return x + y * 256;
end

local function u32(b, off)
    local x, y, z, w = b:byte(off + 1, off + 4);
    if (w == nil) then
        return nil;
    end
    return x + y * 256 + z * 65536 + w * 16777216;
end

core.VANA_BASE      = 0x3C307D70;   -- 2002-01-01 00:00 JST as a Unix time
core.STATUS_FOREVER = 0x7FFFFFFF;
-- The server sends end times as (whole seconds now + whole seconds left), so they read 0-2 s early
-- (1 s on average, about 0.5 s after our own whole-second clock); this centres the error.
core.STATUS_ROUNDING = 0.5;

function core.parse_status_timers(bytes)
    if (type(bytes) ~= 'string' or #bytes < 0xC8 or bytes:byte(5) ~= 9) then
        return nil;
    end
    local list = {};
    for i = 0, 31 do
        local id = u16(bytes, 0x08 + i * 2);
        if (id ~= nil and id ~= 0 and id ~= 0xFF and id ~= 0xFFFF) then
            list[#list + 1] = { id = id, raw = u32(bytes, 0x48 + i * 4) };
        end
    end
    return list;
end

-- Seconds left for a raw end time, given the server's current Unix time (stamp). -1 = no expiry.
function core.status_seconds(raw, stamp)
    if (raw == nil or stamp == nil) then
        return nil;
    end
    if (raw == core.STATUS_FOREVER) then
        return -1;
    end
    local remaining = raw - ((stamp - core.VANA_BASE) * 60);
    while (remaining < -2147483648) do
        remaining = remaining + 4294967296;
    end
    if (remaining < 0) then
        return 0;
    end
    return remaining / 60;
end

--[[
* Converts a parsed status list into end times on our clock, for maneuvers (300-307) and Overload.
* Returns nil if any maneuver time is implausible (e.g. the clock is off), so callers fall back.
*
* @return { [element] = { end, end, ... } sorted, overload = end | nil }
--]]
function core.buff_end_times(list, stamp, now)
    if (list == nil) then
        return nil;
    end
    local out = { overload = nil };
    for e = 1, 8 do
        out[e] = {};
    end
    for _, b in ipairs(list) do
        local el = b.id - data.MANEUVER_BUFF_FIRST + 1;
        if ((el >= 1 and el <= 8) or b.id == data.OVERLOAD_BUFF) then
            local secs = core.status_seconds(b.raw, stamp);
            if (secs == nil or secs < 0 or secs > 330) then
                return nil;   -- not a believable maneuver / overload time: do not trust this packet
            end
            secs = secs + core.STATUS_ROUNDING;
            if (b.id == data.OVERLOAD_BUFF) then
                out.overload = now + secs;
            else
                local t = out[el];
                t[#t + 1] = now + secs;
            end
        end
    end
    for e = 1, 8 do
        table.sort(out[e]);
    end
    return out;
end

--[[
* Gives each tracked maneuver its real end time: the oldest maneuver of an element gets the
* soonest end time of that element. Ends that do not fit a known use time are ignored.
*
* @param unknown_only - true (default on HorizonXI, where maneuvers last a flat 60s): only maneuvers
*                       that were already up when the addon loaded take the game's end time; the
*                       rest use start + duration, which is exact and needs no clock.
* @param duration     - the configured maneuver duration (caps believable times in unknown_only mode)
--]]
local TAKEN = {};   -- reused by heal_stale

--[[
* Flat-duration model only: a maneuver whose time ran out more than 3 s ago while its buff is still
* up was refreshed without us seeing it (or lasts longer on this server). Such a maneuver takes the
* game's end time: its start moves so that start + duration = that end. End times already explained
* by the element's other maneuvers are left to them.
* @return true if a start time was moved
--]]
local function heal_stale(entries, el, ends, now, duration)
    local stale = false;
    for _, e in ipairs(entries) do
        if (e.el == el and not e.unknown and (e.start + duration) < now - 3) then
            stale = true;
            break;
        end
    end
    if (not stale) then
        return false;
    end
    local n = #ends;
    for k = 1, n do
        TAKEN[k] = false;
    end
    for _, e in ipairs(entries) do
        if (e.el == el) then
            local want = nil;
            if (e.unknown) then
                want = e.ends;
            elseif ((e.start + duration) >= now - 3) then
                want = e.start + duration;
            end
            if (want ~= nil) then
                local best, bd = nil, 2.5;
                for k = 1, n do
                    local d = math.abs(ends[k] - want);
                    if (not TAKEN[k] and d <= bd) then
                        best, bd = k, d;
                    end
                end
                if (best ~= nil) then
                    TAKEN[best] = true;
                end
            end
        end
    end
    local healed = false;
    local k = 1;
    for _, e in ipairs(entries) do
        if (e.el == el and not e.unknown and (e.start + duration) < now - 3) then
            while (k <= n and (TAKEN[k] or ends[k] <= now or (ends[k] - now) > duration + 5)) do
                k = k + 1;
            end
            if (k <= n) then
                TAKEN[k] = true;
                e.start = ends[k] - duration;
                healed = true;
                k = k + 1;
            end
        end
    end
    return healed;
end

function core.apply_buff_ends(state, ends, now, unknown_only, duration)
    for _, e in ipairs(state.man.list) do
        e.ends = nil;
    end
    if (ends == nil) then
        return;
    end
    duration = tonumber(duration) or 60;
    local healed = false;
    for el = 1, 8 do
        local list = ends[el];
        if (list ~= nil and #list > 0) then
            local i = 1;
            for _, e in ipairs(state.man.list) do
                if (e.el == el and list[i] ~= nil) then
                    local ok;
                    if (e.unknown) then
                        ok = (not unknown_only) or (list[i] - now <= duration + 5);
                    elseif (unknown_only) then
                        ok = false;
                    else
                        local dur = list[i] - e.start;
                        ok = (dur >= 50 and dur <= 310);
                    end
                    -- Kept a few seconds past the end: the server's times can read up to 2 s early
                    -- and the buff only disappears when it really ends.
                    if (ok and list[i] >= now - 3) then
                        e.ends = list[i];
                    end
                    i = i + 1;
                end
            end
            if (unknown_only and heal_stale(state.man.list, el, list, now, duration)) then
                healed = true;
            end
        end
    end

    -- Maneuvers that were already up at load were added in element order. Once their end times are
    -- known, order them by end time (soonest = oldest), so the oldest is on the left and a refresh
    -- replaces the right one. They are always older than anything used since, so they stay first.
    local list = state.man.list;
    local n = 0;
    while (n < #list and list[n + 1].unknown) do
        n = n + 1;
    end
    for i = 2, n do
        local e = list[i];
        local key = e.ends or math.huge;
        local j = i - 1;
        while (j >= 1 and (list[j].ends or math.huge) > key) do
            list[j + 1] = list[j];
            j = j - 1;
        end
        list[j + 1] = e;
    end
    -- A start time moved by heal_stale: keep the maneuvers used since load in order of use.
    if (healed) then
        for i = n + 2, #list do
            local e = list[i];
            local j = i - 1;
            while (j > n and list[j].start > e.start) do
                list[j + 1] = list[j];
                j = j - 1;
            end
            list[j + 1] = e;
        end
    end
end

--[[
* How long the maneuver just used really lasts, from the game's buff timer: the newest maneuver of
* an element that was used in the last 3 seconds, against the latest end time of that element.
* Returns nil when there is no such maneuver or the buff timers are older than its use.
--]]
function core.fresh_maneuver_length(state, ends, ends_at, now)
    if (ends == nil or ends_at == nil) then
        return nil;
    end
    local list = state.man.list;
    for i = #list, 1, -1 do
        local e = list[i];
        if ((now - e.start) > 3.0) then
            break;   -- the list is in order of use: everything before this is older
        end
        local el_ends = ends[e.el];
        if (not e.unknown and el_ends ~= nil and #el_ends > 0 and ends_at >= e.start - 1.0) then
            local newest = true;
            for j = i + 1, #list do
                if (list[j].el == e.el) then
                    newest = false;
                end
            end
            if (newest) then
                return el_ends[#el_ends] - e.start;
            end
        end
    end
    return nil;
end

core.CATEGORY_JOB_ABILITY = 6;
core.CATEGORY_MOB_SKILL   = 11;   -- automaton abilities on LandSandBoat
core.CATEGORY_PET_SKILL   = 13;   -- accepted too, in case a server build reports them as pet skills

-- skill id -> ability key
core.skill_index = {};
for _, a in ipairs(data.abilities) do
    core.skill_index[a.skill_id] = a.key;
end

--[[
* Interprets an action packet for our player / automaton.
*
* @return nil, or { kind = 'pet_ability', key = ... } / { kind = 'maneuver', element = 1..8 }
--]]
function core.interpret_action(act, player_id, pet_id)
    if (act == nil) then
        return nil;
    end
    if (pet_id ~= nil and pet_id ~= 0 and act.actor == pet_id and
        (act.category == core.CATEGORY_MOB_SKILL or act.category == core.CATEGORY_PET_SKILL)) then
        local key = core.skill_index[act.param];
        if (key ~= nil) then
            return { kind = 'pet_ability', key = key };
        end
        return nil;
    end
    if (player_id ~= nil and player_id ~= 0 and act.actor == player_id and act.category == core.CATEGORY_JOB_ABILITY) then
        local el = act.param - data.MANEUVER_JA_FIRST + 1;
        if (el >= 1 and el <= 8) then
            local ev = { kind = 'maneuver', element = el };
            if (act.message1 == core.MSG_OVERLOAD_CHANCE or act.message1 == core.MSG_OVERLOADED) then
                ev.overload_chance = act.value1;
                ev.overloaded = (act.message1 == core.MSG_OVERLOADED);
            end
            return ev;
        end
    end
    return nil;
end

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

function core.new_state()
    return {
        timers = {},    -- automaton ability timers: key -> timer
        man = {         -- maneuvers
            list        = {},   -- oldest first: { el = 1..8, start = t, unknown = bool, from_sync = bool }
            pending     = nil,  -- { time = t, el = 1..8 | nil } a use we saw but have not matched to a buff yet
            initialized = false,
            recast_prev = 0,
            overload    = false,
        },
        ja = {},        -- job ability recasts: key -> { active, remaining, total, ready_since }
        pet = {
            present      = false,
            name         = nil,
            id           = 0,
            absent_since = nil,
            initialized  = false,
        },
    };
end

----------------------------------------------------------------------------------------------------
-- Automaton ability timers
----------------------------------------------------------------------------------------------------

--[[
* Starts (or restarts) a cooldown timer.
* A second report of the same ability within `dedupe` seconds is ignored (the packet and the chat
* line for one use both arrive, and they must not restart the bar twice).
*
* @return true if a timer was started.
--]]
function core.start_timer(state, key, name, cooldown, now, dedupe)
    dedupe = dedupe or 2.0;
    local t = state.timers[key];
    if (t ~= nil and (now - t.start) < dedupe) then
        return false;
    end
    cooldown = tonumber(cooldown) or 0;
    if (cooldown < 0) then
        cooldown = 0;
    end
    state.timers[key] = {
        key         = key,
        name        = name,
        start       = now,
        duration    = cooldown,
        ready_at    = now + cooldown,
        ready       = false,
        ready_since = nil,
    };
    return true;
end

--[[
* Advances timers. Returns an array of timers that became ready this tick (or nil).
--]]
function core.update_timers(state, now, hold, keep_ready)
    local fired = nil;
    for key, t in pairs(state.timers) do
        if (not t.ready and now >= t.ready_at) then
            t.ready = true;
            t.ready_since = now;
            fired = fired or {};
            fired[#fired + 1] = t;
        end
        if (t.ready and (t.test or not keep_ready) and (now - t.ready_since) >= (hold or 0)) then
            state.timers[key] = nil;
        end
    end
    return fired;
end

function core.clear_timers(state)
    state.timers = {};
end

----------------------------------------------------------------------------------------------------
-- Maneuvers
--
-- The player's buff list is the source of truth for WHICH maneuvers are up (maneuvers have no
-- wear-off chat message). Use events (action packet, chat line, or the shared maneuver recast
-- jumping up) tell us WHEN one was used, which matters when a 4th maneuver of the same element
-- replaces the oldest one: the buff counts do not change at all in that case.
----------------------------------------------------------------------------------------------------

local USE_WINDOW = 3.0;   -- seconds a use event waits for the matching buff

-- One use is reported by up to three sources (action packet, chat line, recast timer), and the chat
-- line can trail the packet by a few seconds while the game plays animations. All maneuvers share
-- a 10 second recast, so reports closer together than this are the same use.
core.DUP_WINDOW = 7.0;

--[[
* Records that a maneuver was used. el may be nil when the element is unknown (recast jump).
* @return true for a new use, false for another report of a use already recorded.
--]]
function core.maneuver_use(state, el, now)
    local m = state.man;
    local window = core.DUP_WINDOW;

    -- Same use as the one still waiting for its buff.
    if (m.pending ~= nil and (now - m.pending.time) < window) then
        if (m.pending.el == nil and el ~= nil) then
            m.pending.el = el;
        end
        return false;
    end

    -- The buff may already have shown up before the use event (packet order is not guaranteed).
    for i = #m.list, 1, -1 do
        local e = m.list[i];
        if (e.from_sync and (now - e.start) < window and (el == nil or e.el == el)) then
            e.from_sync = false;
            e.claimed_at = now;
            return true;
        end
    end

    -- Already matched to a buff (reported first by another source).
    for i = #m.list, 1, -1 do
        local e = m.list[i];
        if (e.claimed_at ~= nil and (now - e.claimed_at) < window) then
            return false;
        end
    end

    m.pending = { time = now, el = el };
    return true;
end

-- For a full set whose counts did not change after a use of element el, while list[1] is of
-- another element: maneuvers that were already up at load are in unknown order, so the one that
-- was really replaced is the soonest-ending loaded maneuver of that element.
local function replaced_loaded_index(list, el)
    if (not list[1].unknown) then
        return nil;
    end
    local best = nil;
    for i = 1, #list do
        local e = list[i];
        if (not e.unknown) then
            break;
        end
        if (e.el == el and (best == nil or (e.ends or math.huge) < (list[best].ends or math.huge))) then
            best = i;
        end
    end
    return best;
end

--[[
* Reconciles tracked maneuvers with the real buff counts.
*
* @param counts    - array [1..8] of active maneuver buffs per element
* @param max_count - maximum simultaneous maneuvers (3)
* @param duration  - maneuver duration in the flat model (60 on HorizonXI)
* @return array of removed entries ({ el, replaced = bool, unknown, start, ends }) or nil
--]]
local TRACKED = { 0, 0, 0, 0, 0, 0, 0, 0 };   -- reused: maneuver_sync runs 10 times a second

function core.maneuver_sync(state, counts, now, max_count, duration, game_ends)
    local m = state.man;
    max_count = max_count or data.MAX_MANEUVERS;
    duration = tonumber(duration) or 60;
    local removed = nil;
    local was_full = (#m.list >= max_count);
    local pending_recent = (m.pending ~= nil and (now - m.pending.time) < USE_WINDOW);
    local oldest = m.list[1];   -- the one a new maneuver pushes out

    -- 1) Remove entries whose buff is gone (oldest of that element first).
    local tracked = TRACKED;
    for el = 1, 8 do
        tracked[el] = 0;
    end
    for _, e in ipairs(m.list) do
        tracked[e.el] = tracked[e.el] + 1;
    end
    -- Which one goes, when an element has fewer maneuvers than tracked: normally the oldest of that
    -- element (it runs out first, and a new maneuver pushes out the oldest overall). One used up
    -- early by an attachment that takes a single maneuver (Condenser: Water, Schurzen: Earth) is the
    -- newest of that element on the server. When the game's own buff timers (game_ends, only passed
    -- when the server clock is known) already show the new state, they settle it.
    local adding = 0;
    for el = 1, 8 do
        adding = adding + math.max((counts[el] or 0) - (tracked[el] or 0), 0);
    end
    local pushing = was_full and (adding > 0 or pending_recent);
    for el = 1, 8 do
        local extra = (tracked[el] or 0) - (counts[el] or 0);
        while (extra > 0) do
            local first, last = nil, nil;
            for i, e in ipairs(m.list) do
                if (e.el == el) then
                    first = first or i;
                    last = i;
                end
            end
            local idx = first;
            if (last ~= first) then
                local fe = m.list[first];
                local fends = fe.ends or ((not fe.unknown) and (fe.start + duration) or nil);
                if (fends ~= nil and now < fends - 3 and not (pushing and fe == oldest)) then
                    idx = last;
                end
                local gl = game_ends and game_ends[el];
                if (gl ~= nil and #gl > 0 and #gl == (counts[el] or 0)) then
                    -- The one whose end matches none of the game's timers is the one that went.
                    local worst, worst_d = nil, -1;
                    for i, e in ipairs(m.list) do
                        if (e.el == el) then
                            local exp = e.ends or ((not e.unknown) and (e.start + duration) or nil);
                            if (exp == nil) then
                                worst = nil;
                                break;
                            end
                            local d = math.huge;
                            for _, g in ipairs(gl) do
                                d = math.min(d, math.abs(g - exp));
                            end
                            if (d > worst_d) then
                                worst, worst_d = i, d;
                            end
                        end
                    end
                    if (worst ~= nil and worst_d > 5) then
                        idx = worst;
                    end
                end
            end
            local e = table.remove(m.list, idx);
            removed = removed or {};
            removed[#removed + 1] = { el = el, replaced = false, unknown = e.unknown, start = e.start, ends = e.ends, oldest = (e == oldest) };
            extra = extra - 1;
            tracked[el] = tracked[el] - 1;
        end
    end

    -- 2) Add entries for buffs we are not tracking yet.
    local added = 0;
    for el = 1, 8 do
        local missing = (counts[el] or 0) - (tracked[el] or 0);
        added = added + math.max(missing, 0);
        while (missing > 0) do
            local entry = { el = el, start = now };
            if (not m.initialized) then
                entry.unknown = true;   -- was already up when the addon started; real age unknown
            else
                local p = m.pending;
                if (p ~= nil and (now - p.time) < USE_WINDOW and (p.el == nil or p.el == el)) then
                    entry.start = p.time;
                    entry.claimed_at = now;   -- later reports of this use are duplicates
                    m.pending = nil;
                else
                    entry.from_sync = true;
                end
            end
            m.list[#m.list + 1] = entry;
            missing = missing - 1;
        end
    end

    -- A full set losing its oldest maneuver in the same update that one is gained (or right as one
    -- is used) means it was pushed out by the new maneuver, not that it wore off. Only the oldest:
    -- anything else that went at the same time was used up (e.g. Condenser taking a Water Maneuver
    -- to stop an overload, which leaves room for the new one). Maneuvers that were already up when
    -- PupTimers loaded have no known order, so while the oldest is one of them, so is any of them.
    if (removed ~= nil and was_full and (added > 0 or pending_recent)) then
        for _, r in ipairs(removed) do
            if (r.oldest or (oldest ~= nil and oldest.unknown and r.unknown)) then
                r.replaced = true;
            end
        end
    end

    -- 3) A use that changed no buff counts while the set was full = the oldest maneuver was replaced
    --    by one of the same element. Refresh it.
    local p = m.pending;
    if (p ~= nil) then
        local age = now - p.time;
        if (#m.list >= max_count and m.list[1] ~= nil) then
            local idx = nil;
            if (p.el ~= nil and p.el == m.list[1].el) then
                idx = 1;
            elseif (p.el ~= nil and age >= 1.0) then
                -- Only after a second: until the buff list updates, a use that will push out
                -- list[1] (another element) also looks like "no counts changed".
                idx = replaced_loaded_index(m.list, p.el);
            elseif (p.el == nil and age >= 1.5) then
                idx = 1;   -- element never reported: assume the oldest
            end
            if (idx ~= nil) then
                local old = table.remove(m.list, idx);
                m.list[#m.list + 1] = { el = old.el, start = p.time, claimed_at = now };
                m.pending = nil;
            end
        end
        -- Counts still unchanged a second after a use, with a maneuver of that element whose time
        -- has run out: it ran out in the same server update as the new one landed (common when
        -- re-using a maneuver right at 0:00). It was replaced, not added: refresh it.
        if (m.pending ~= nil and p.el ~= nil and age >= 1.0) then
            local idx, soonest = nil, nil;
            for i, e in ipairs(m.list) do
                if (e.el == p.el) then
                    local ends = e.ends or ((not e.unknown) and (e.start + duration) or nil);
                    if (ends ~= nil and ends <= now + 0.5 and (soonest == nil or ends < soonest)) then
                        idx, soonest = i, ends;
                    end
                end
            end
            if (idx ~= nil) then
                table.remove(m.list, idx);
                m.list[#m.list + 1] = { el = p.el, start = p.time, claimed_at = now };
                m.pending = nil;
            end
        end
        if (m.pending ~= nil and age > USE_WINDOW) then
            m.pending = nil;
        end
    end

    m.initialized = true;
    return removed;
end

--[[
* Feeds the shared maneuver recast (seconds remaining). A jump upward means a maneuver was used.
--]]
function core.maneuver_recast(state, remaining, now)
    local m = state.man;
    remaining = remaining or 0;
    if (not m.recast_seen) then
        -- First reading after load: a recast already running is not a new use.
        m.recast_seen = true;
        m.recast_prev = remaining;
        if (remaining > 0) then
            state.ja_maneuver_total = math.max(remaining, 10);
        end
        return;
    end
    if (remaining > m.recast_prev + 1.0) then
        state.ja_maneuver_total = remaining;
        core.maneuver_use(state, nil, now);
    end
    m.recast_prev = remaining;
end

--[[
* Converts a buff id array (as returned by the game) into per-element maneuver counts.
* Works whether the array is 0- or 1-based.
*
* @param out - optional table to fill (reused by the caller to avoid garbage)
* @return counts, overloaded, overdrive
--]]
function core.count_maneuvers(buffs, out)
    local counts = out or {};
    for el = 1, 8 do
        counts[el] = 0;
    end
    local overload, overdrive = false, false;
    local print = 0;   -- fingerprint of the other buffs (they can change your stats)
    if (buffs == nil) then
        return counts, overload, overdrive, print;
    end
    for i = 0, 32 do
        local id = buffs[i];
        if (type(id) == 'number') then
            local el = id - data.MANEUVER_BUFF_FIRST + 1;
            if (el >= 1 and el <= 8) then
                counts[el] = counts[el] + 1;
            elseif (id == data.OVERLOAD_BUFF) then
                overload = true;
            else
                if (id == data.OVERDRIVE_BUFF) then
                    overdrive = true;
                end
                if (id > 0 and id < 255) then
                    print = print + id * id + 1;
                end
            end
        end
    end
    return counts, overload, overdrive, print;
end

----------------------------------------------------------------------------------------------------
-- Job ability recasts
----------------------------------------------------------------------------------------------------

--[[
* Updates job ability recast state from the game's recast list.
*
* @param defs        - data.job_abilities (array)
* @param recasts     - map timer id (or 'sp') -> seconds remaining
* @param main_is_pup - true when PUP is the main job (the 'sp' slot is Overdrive only then)
* @return array of defs that just came off cooldown naturally (or nil),
*         array of defs that were just used (their recast started) (or nil)
--]]
function core.update_job_abilities(state, defs, recasts, now, main_is_pup)
    local fired, started = nil, nil;
    for _, def in ipairs(defs) do
        local s = state.ja[def.key];
        if (s == nil) then
            s = { active = false, remaining = 0, total = 0, ready_since = nil };
            state.ja[def.key] = s;
        end
        local r = recasts[def.timer] or 0;
        if (def.main_only and not main_is_pup) then
            r = 0;
        end
        if (r > 0) then
            if (not s.active or r > s.remaining + 1.0) then
                if (s.seen) then
                    s.total = r;   -- just went on cooldown (or was used again)
                    started = started or {};
                    started[#started + 1] = def;
                else
                    -- Already cooling down when the addon loaded: use the normal recast as the bar length.
                    s.total = math.max(r, def.recast or 0);
                end
            end
            if (r > s.total) then
                s.total = r;
            end
            s.active = true;
            s.remaining = r;
            s.ends = now + r;
            s.ready_since = nil;
        else
            if (s.active) then
                s.active = false;
                -- Only a timer that ran down counts as "ready"; a sudden drop (zone, job change,
                -- recast reset) is not announced.
                if (s.remaining <= 3.0) then
                    s.ready_since = now;
                    fired = fired or {};
                    fired[#fired + 1] = def;
                end
            end
            s.remaining = 0;
        end
        s.seen = true;
    end
    return fired, started;
end

----------------------------------------------------------------------------------------------------
-- Automaton presence
----------------------------------------------------------------------------------------------------

--[[
* @param info  - { name = ..., id = server id } when the automaton is out, nil otherwise
* @param grace - seconds the automaton must be missing before it counts as gone
* @return 'spawn', 'despawn' or nil
--]]
function core.update_pet(state, info, now, grace)
    local p = state.pet;
    grace = grace or 3.0;
    if (info ~= nil) then
        local event = nil;
        if (not p.present and p.initialized) then
            event = 'spawn';
        elseif (p.present and p.id ~= nil and p.id ~= 0 and info.id ~= nil and info.id ~= 0 and info.id ~= p.id) then
            event = 'spawn';   -- a different automaton (re-activated faster than the grace period)
        end
        p.present = true;
        p.name = info.name;
        p.id = info.id or 0;
        p.absent_since = nil;
        p.initialized = true;
        return event;
    end
    if (not p.initialized) then
        p.initialized = true;
        return nil;
    end
    if (p.present) then
        p.absent_since = p.absent_since or now;
        if ((now - p.absent_since) >= grace) then
            p.present = false;
            p.id = 0;
            p.absent_since = nil;
            return 'despawn';
        end
    end
    return nil;
end

----------------------------------------------------------------------------------------------------
-- View model (what the HUD draws)
----------------------------------------------------------------------------------------------------

local function fill_frac(remaining, total, mode)
    if (total == nil or total <= 0) then
        return (mode == 'fill') and 1 or 0;
    end
    local f = remaining / total;
    if (f < 0) then f = 0; end
    if (f > 1) then f = 1; end
    if (mode == 'fill') then
        return 1 - f;
    end
    return f;
end

--[[
* Returns the display definition (name, color, enabled...) for an ability key, merging the static
* data with the user's settings. Custom abilities live in cfg.custom.
--]]
-- ability key -> static definition
core.ability_def = {};
for _, a in ipairs(data.abilities) do
    core.ability_def[a.key] = a;
end

function core.ability_info(cfg, key)
    local s = cfg.abilities[key];
    local a = core.ability_def[key];
    if (s ~= nil and a ~= nil) then
        local spawn_cd = s.cooldown;
        if (a.spawn_cooldown ~= nil and tonumber(s.cooldown) == a.cooldown) then
            spawn_cd = a.spawn_cooldown;   -- server applies a different cooldown at activation
        end
        return { key = key, name = a.name, cooldown = s.cooldown, enabled = s.enabled, alert = s.alert, color = s.color, on_spawn = s.on_spawn, source = a.source, aliases = a.aliases, spawn_cooldown = spawn_cd };
    end
    local c = cfg.custom and cfg.custom[key];
    if (c ~= nil) then
        return { key = key, name = c.name, cooldown = c.cooldown, enabled = c.enabled, alert = c.alert, color = c.color, on_spawn = c.on_spawn, source = 'Custom', custom = true };
    end
    return nil;
end

--[[
* Lists every known ability (built-in first, then custom) merged with settings.
--]]
function core.all_abilities(cfg)
    local list = {};
    for _, a in ipairs(data.abilities) do
        local info = core.ability_info(cfg, a.key);
        if (info ~= nil) then
            list[#list + 1] = info;
        end
    end
    local customs = {};
    for key, _ in pairs(cfg.custom or {}) do
        customs[#customs + 1] = key;
    end
    table.sort(customs);
    for _, key in ipairs(customs) do
        local info = core.ability_info(cfg, key);
        if (info ~= nil and type(info.name) == 'string' and info.name ~= '') then
            list[#list + 1] = info;
        end
    end
    return list;
end

-- Name, colour and on/off for a running timer, without building a table (the view is rebuilt
-- 10 times a second).
--[[
* A shorter name for narrow windows: a known abbreviation, the name itself if it is short, or the
* first word with the start of the second ('Arc Generator' -> 'Arc Gene.'). Cached by name.
--]]
local SHORT_CACHE = {};
local short_count = 0;
function core.short_name(name)
    local s = SHORT_CACHE[name];
    if (s ~= nil) then
        return s;
    end
    s = data.short_names[name];
    if (s == nil) then
        if (#name <= 9) then
            s = name;
        else
            local first, rest = name:match('^(%S+)%s+(.+)$');
            if (first ~= nil and #first >= 3 and #first <= 8) then
                s = first .. ' ' .. rest:sub(1, 4) .. '.';
            else
                s = name:sub(1, 8) .. '.';
            end
        end
    end
    if (short_count > 256) then
        SHORT_CACHE, short_count = {}, 0;
    end
    SHORT_CACHE[name] = s;
    short_count = short_count + 1;
    return s;
end

-- 'needs Fire' etc., for READY bars of abilities whose maneuver is not up.
local NEEDS = {};
for _, e in ipairs(data.elements) do
    NEEDS[e.key] = 'needs ' .. e.name;
end

local function timer_display(cfg, key, t, colors)
    local a = core.ability_def[key];
    local s = cfg.abilities[key];
    if (a ~= nil and s ~= nil) then
        return a.name, s.color or colors.recast, s.enabled ~= false;
    end
    local c = cfg.custom and cfg.custom[key];
    if (c ~= nil) then
        return c.name, c.color or colors.recast, c.enabled ~= false;
    end
    return t.name or key, t.color or colors.recast, true;
end

-- Rows are sorted directly on their own fields (no wrapper tables).
local function by_label(a, b)
    return a.label < b.label;
end

local function by_sortv(a, b)
    if (a.sortv ~= b.sortv) then
        return a.sortv < b.sortv;
    end
    return a.label < b.label;
end

local SECTION_KEYS = { 'automaton', 'maneuvers', 'abilities', 'recasts' };
local order_text, order_list = nil, nil;   -- cfg.hud.order parsed once per change

local function order_sections(view, cfg, by_key)
    local text = tostring(cfg.hud.order or '');
    if (text ~= order_text) then
        local list, seen = {}, {};
        for key in text:gmatch('[%a_]+') do
            if (by_key[key] ~= nil and not seen[key]) then
                seen[key] = true;
                list[#list + 1] = key;
            end
        end
        for _, key in ipairs(SECTION_KEYS) do
            if (not seen[key]) then
                list[#list + 1] = key;
            end
        end
        order_text, order_list = text, list;
    end
    for i = 1, #order_list do
        view.sections[i] = by_key[order_list[i]];
    end
end

--[[
* Builds the rows the HUD should draw.
*
* @param env - { pet_present, pet_name, maneuver_recast, maneuver_recast_at, overload_rows, overload_left }
* @return { header = string|nil, sections = { { key, rows = {...} }, ... }, count = number of rows }
*
* Row fields: label, right, frac (0..1), color, flash, warn, dim, thin.
* Timed rows also carry dyn_end / dyn_total / dyn_mode so the window can move the bar smoothly every
* frame between rebuilds (frac is the same value at build time).
--]]
function core.build_view(state, cfg, now, env)
    local view = { header = nil, sections = {}, count = 0, notes = 0 };
    local fmt = cfg.hud.time_format;
    local mode = cfg.hud.fill_mode;
    local colors = cfg.colors;
    local hold = cfg.alerts.ready_hold or 0;

    -- Maneuvers ---------------------------------------------------------------------------------
    local sec_man = { key = 'maneuvers', rows = {} };
    local man_rows = sec_man.rows;
    if (cfg.maneuvers.enabled) then
        local m = state.man;
        if (m.overload and cfg.maneuvers.show_overload) then
            local left = env.overload_left;
            man_rows[#man_rows + 1] = {
                label = 'OVERLOADED',
                right = (left ~= nil and left > 0) and core.format_time(left, fmt) or '',
                frac  = 1,
                color = colors.overload,
                flash = true,
            };
        end
        local duration = tonumber(cfg.maneuvers.duration) or 60;
        if (duration <= 0) then duration = 60; end
        local warn_at = tonumber(cfg.maneuvers.warn_at) or 0;
        local as_icons = (cfg.maneuvers.style ~= 'bars');
        local icons = as_icons and {} or man_rows;
        for _, e in ipairs(m.list) do
            local el = data.elements[e.el];
            local col = cfg.maneuvers.colors[el.key] or el.color;
            local item;
            if (e.unknown and e.ends == nil) then
                item = { el = e.el, label = el.name, right = '?', short = '?', frac = 1, color = col, dim = true, unknown = true };
            else
                -- Real end time from the game's buff timers when known, else start + configured duration.
                local ends, total;
                if (e.ends ~= nil) then
                    ends = e.ends;
                    total = e.unknown and math.max(duration, ends - now) or math.max(ends - e.start, 1);
                else
                    ends = e.start + duration;
                    total = duration;
                end
                local remaining = ends - now;
                if (remaining < 0) then remaining = 0; end
                local warn = (warn_at > 0 and remaining <= warn_at);
                item = {
                    el        = e.el,
                    label     = el.name,
                    right     = core.format_time(remaining, fmt),
                    short     = core.format_short(remaining),
                    frac      = fill_frac(remaining, total, 'drain'),
                    dyn_end   = ends,
                    dyn_total = total,
                    dyn_mode  = 'drain',
                    color     = col,
                    warn      = warn,
                    flash     = warn and remaining <= 5,
                };
            end
            icons[#icons + 1] = item;
        end
        if (cfg.maneuvers.show_empty and env.pet_present) then
            for _ = #m.list + 1, data.MAX_MANEUVERS do
                icons[#icons + 1] = { label = 'Empty', right = '', short = '', frac = 0, color = colors.empty, dim = true, empty = true };
            end
        end
        if (as_icons and #icons > 0) then
            -- One row of element icons (oldest on the left) with each maneuver's time left under it.
            man_rows[#man_rows + 1] = { kind = 'icons', items = icons };
        end
        local mr = env.maneuver_recast or 0;
        if (env.maneuver_recast_at ~= nil) then
            mr = env.maneuver_recast_at - now;   -- (stays right between polls and while zoning)
        end
        if (cfg.maneuvers.show_recast and mr > 0) then
            local total = (state.ja_maneuver_total ~= nil and state.ja_maneuver_total > 0) and state.ja_maneuver_total or 10;
            if (mr > total) then total = mr; end
            man_rows[#man_rows + 1] = {
                label     = as_icons and 'Maneuver' or 'Next maneuver',
                right     = core.format_time(mr, fmt),
                frac      = fill_frac(mr, total, mode),
                dyn_end   = env.maneuver_recast_at or (now + mr),
                dyn_total = total,
                dyn_mode  = mode,
                color     = colors.maneuver_cd,
                thin      = true,
            };
        end
        local ov_rows = env.overload_rows;
        if (ov_rows ~= nil) then
            for i = 1, #ov_rows do
                man_rows[#man_rows + 1] = ov_rows[i];
            end
        end
        if (env.unpowered_text ~= nil) then
            man_rows[#man_rows + 1] = {
                label = env.unpowered_text, short_label = env.unpowered_short, right = '', frac = 0,
                color = colors.warn, dim = true, thin = true, note = true,
            };
        end
    end

    -- Automaton abilities ------------------------------------------------------------------------
    local sec_ab = { key = 'abilities', rows = {} };
    local ab_rows = sec_ab.rows;
    -- By default only abilities that are actually cooling down are shown; READY bars appear only
    -- when the user asks for them (Alerts tab: READY bar time / keep ready abilities).
    local show_ready = (hold > 0) or (cfg.alerts.keep_ready == true);
    for key, t in pairs(state.timers) do
        local name, color, enabled = timer_display(cfg, key, t, colors);
        if (enabled) then
            local remaining = t.ready_at - now;
            if (remaining < 0) then remaining = 0; end
            if (t.ready) then
                if (show_ready) then
                    local right = 'READY';
                    local a = core.ability_def[key];
                    local counts = env.man_counts;
                    if (a ~= nil and a.element ~= nil and counts ~= nil and counts[data.element_index[a.element]] == 0) then
                        right = NEEDS[a.element];   -- ready, but it cannot fire without its maneuver
                    end
                    ab_rows[#ab_rows + 1] = {
                        label = name or '',
                        short_label = core.short_name(name or ''),
                        right = right,
                        frac  = 1,
                        color = colors.ready,
                        flash = cfg.alerts.flash and (now - (t.ready_since or now)) < math.max(hold, 3),
                        sortv = 0,
                    };
                end
            elseif (remaining > 0) then
                ab_rows[#ab_rows + 1] = {
                    label     = name or '',
                    short_label = core.short_name(name or ''),
                    right     = core.format_time(remaining, fmt),
                    frac      = fill_frac(remaining, t.duration, mode),
                    dyn_end   = t.ready_at,
                    dyn_total = t.duration,
                    dyn_mode  = mode,
                    color     = color,
                    sortv     = remaining,
                };
            end
        end
    end
    table.sort(ab_rows, (cfg.hud.sort_abilities == 'name') and by_label or by_sortv);

    -- Job ability recasts ------------------------------------------------------------------------
    local sec_ja = { key = 'recasts', rows = {} };
    local ja_rows = sec_ja.rows;
    for _, def in ipairs(data.job_abilities) do
        local opt = cfg.jobabilities[def.key];
        local s = state.ja[def.key];
        if (opt ~= nil and opt.show and s ~= nil) then
            local rem = (s.ends ~= nil) and (s.ends - now) or s.remaining;   -- (right while zoning too)
            if (s.active and rem > 0) then
                ja_rows[#ja_rows + 1] = {
                    label     = (def.key == 'repair' and env.repair_label) or def.name,
                    short_label = core.short_name(def.name),
                    right     = core.format_time(rem, fmt),
                    frac      = fill_frac(rem, s.total, mode),
                    dyn_end   = s.ends,
                    dyn_total = s.total,
                    dyn_mode  = mode,
                    color     = colors.recast,
                    sortv     = rem,
                };
            elseif (not s.active and s.ready_since ~= nil and (now - s.ready_since) < hold) then
                ja_rows[#ja_rows + 1] = { label = def.name, short_label = core.short_name(def.name), right = 'READY', frac = 1, color = colors.ready, flash = cfg.alerts.flash, sortv = -1 };
            end
        end
    end
    table.sort(ja_rows, by_sortv);
    if (env.deactivate_hint) then
        ja_rows[#ja_rows + 1] = {
            label = 'Full HP: Deactivate now resets Activate', short_label = 'Deact. resets Activate',
            right = '', frac = 0, color = colors.ready, dim = true, thin = true, note = true,
        };
    end

    -- Order sections ------------------------------------------------------------------------------
    -- Automaton HP / MP -------------------------------------------------------------------------
    local sec_pet = { key = 'automaton', rows = {} };
    local ac = cfg.automaton;
    if (ac ~= nil and env.pet_present) then
        if (ac.show_hp and env.pet_hpp ~= nil) then
            local hp = env.pet_hpp;
            local mark = tonumber(ac.repair_at) or 0;
            sec_pet.rows[#sec_pet.rows + 1] = {
                label = 'Automaton HP', short_label = 'HP', right = core.format_pct(hp),
                frac = hp / 100, color = colors.pet_hp, thin = true,
                marker = (mark > 0) and (mark / 100) or nil, marks = env.pet_hp_marks,
                flash = (mark > 0 and hp <= mark),
            };
        end
        if (ac.show_mp and env.pet_mpp ~= nil) then
            local mp = env.pet_mpp;
            sec_pet.rows[#sec_pet.rows + 1] = {
                label = 'Automaton MP', short_label = 'MP', right = core.format_pct(mp),
                frac = mp / 100, color = colors.pet_mp, thin = true, marks = env.pet_mp_marks,
            };
        end
    end

    order_sections(view, cfg, { automaton = sec_pet, maneuvers = sec_man, abilities = sec_ab, recasts = sec_ja });
    -- count = rows with something running. Notes ("Overload unknown since load") are counted apart, so
    -- on their own they neither keep a "hide when empty" window up nor replace the preview bars.
    for _, sec in ipairs(view.sections) do
        local rows = sec.rows;
        for i = 1, #rows do
            if (rows[i].note) then
                view.notes = view.notes + 1;
            else
                view.count = view.count + 1;
            end
        end
    end

    if (cfg.hud.show_header) then
        local name = env.pet_name;
        if (name ~= nil and name ~= '') then
            view.header = env.pet_present and name or (name .. ' (inactive)');
        end
    end

    return view;
end

--[[
* Sample rows used while positioning the window (unlocked + nothing running) and for /pupt test.
--]]
function core.demo_view(cfg, now)
    local fmt = cfg.hud.time_format;
    local mode = cfg.hud.fill_mode;
    local colors = cfg.colors;
    local cycle = now % 60;
    local function el(key)
        return cfg.maneuvers.colors[key] or data.elements[data.element_index[key]].color;
    end
    local function ab(key)
        local s = cfg.abilities[key];
        return (s and s.color) or colors.recast;
    end
    local man_items = {
        { el = 1, label = 'Fire',  right = core.format_time(52 - cycle * 0.5, fmt), short = core.format_short(52 - cycle * 0.5), frac = (52 - cycle * 0.5) / 60, color = el('fire') },
        { el = 7, label = 'Light', right = core.format_time(38 - cycle * 0.5, fmt), short = core.format_short(38 - cycle * 0.5), frac = (38 - cycle * 0.5) / 60, color = el('light') },
        { el = 3, label = 'Wind',  right = core.format_time(9, fmt), short = core.format_short(9), frac = 9 / 60, color = el('wind'), warn = true },
    };
    local man_rows;
    if (cfg.maneuvers.style ~= 'bars') then
        man_rows = { { kind = 'icons', items = man_items } };
    else
        man_rows = man_items;
    end
    man_rows[#man_rows + 1] = { label = (cfg.maneuvers.style ~= 'bars') and 'Maneuver' or 'Next maneuver', right = core.format_time(4, fmt), frac = fill_frac(4, 10, mode), color = colors.maneuver_cd, thin = true };
    if (cfg.overload ~= nil and cfg.overload.enabled) then
        man_rows[#man_rows + 1] = { label = 'Overload Fire ~12%', right = 'next ~32%', frac = 12 / 50, color = colors.overload_mid or colors.warn };
        man_rows[#man_rows + 1] = { label = 'Overload Light ~4%', right = 'next ~24%', frac = 4 / 50, color = colors.overload_mid or colors.warn };
    end
    local man = { key = 'maneuvers', rows = man_rows };
    local abil = { key = 'abilities', rows = {
        { label = 'Provoke',        right = core.format_time(12, fmt), frac = fill_frac(12, 30, mode), color = ab('provoke') },
        { label = 'Flashbulb',      right = core.format_time(23, fmt), frac = fill_frac(23, 45, mode), color = ab('flashbulb') },
        { label = 'Economizer',     right = core.format_time(131, fmt), frac = fill_frac(131, 180, mode), color = ab('economizer') },
    } };
    local rec = { key = 'recasts', rows = {
        { label = 'Repair', right = core.format_time(74, fmt), frac = fill_frac(74, 180, mode), color = colors.recast },
    } };
    local pet = { key = 'automaton', rows = {} };
    if (cfg.automaton ~= nil and cfg.automaton.show_hp) then
        pet.rows[#pet.rows + 1] = { label = 'Automaton HP', right = '86%', frac = 0.86, color = colors.pet_hp, thin = true };
    end
    if (cfg.automaton ~= nil and cfg.automaton.show_mp) then
        pet.rows[#pet.rows + 1] = { label = 'Automaton MP', right = '41%', frac = 0.41, color = colors.pet_mp, thin = true };
    end
    local view = { header = cfg.hud.show_header and 'Automaton (preview)' or nil, sections = {}, count = 0, demo = true };
    order_sections(view, cfg, { automaton = pet, maneuvers = man, abilities = abil, recasts = rec });
    for _, sec in ipairs(view.sections) do
        view.count = view.count + #sec.rows;
    end
    return view;
end

return core;
