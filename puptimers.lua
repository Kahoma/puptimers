--[[
* PupTimers - Puppetmaster timers for Ashita v4 (HorizonXI).
*
*   - Cooldown bars for your automaton's attachment / frame abilities (Flashbulb, Provoke,
*     Shock Absorber, Shield Bash, ...) with a "ready" alert.
*   - Your active maneuvers (up to 3) with their remaining duration, plus the maneuver recast.
*   - Activate / Repair / Deus Ex Automata (and other PUP job abilities) while on cooldown.
*   - Movable, resizable, per-character settings window: /pupt
*
* PupTimers only reads information the game client already has. It never sends anything to
* the server and does not automate any action.
--]]

addon.name    = 'puptimers';
addon.author  = 'Kahoma';
addon.version = '1.1.1';
addon.desc    = 'Puppetmaster helper: automaton ability cooldowns, maneuvers and PUP recasts.';
addon.link    = 'https://github.com/Kahoma/puptimers';

require('common');
local chat     = require('chat');
local settings = require('settings');
local data     = require('pt_data');
local core     = require('pt_core');
local ov       = require('pt_overload');
local gear     = require('pt_gear');
local ui       = require('pt_ui');
local profiles = require('pt_profiles');
local setup    = require('pt_setup');

local POLL_INTERVAL     = 0.1;    -- seconds between reads of buffs / recasts / pet
local SAVE_DELAY        = 1.0;    -- seconds to wait after the last change before writing settings
local PET_GRACE         = 3.0;    -- seconds the automaton must be gone before it counts as deactivated
local SPAWN_DEDUPE      = 3.0;    -- signals of one activation within this many seconds are one activation
local ZONE_RESPAWN      = 10.0;   -- an automaton appearing this soon after zoning is the re-created one
local SPAWN_PENDING_FOR = 5.0;    -- how long an Activate recast waits for its automaton to appear
local GEAR_INTERVAL     = 2.0;    -- seconds between checks of gear and Automaton Oil
local PROFILES_TTL      = 2.0;    -- seconds the profiles file is not read again

local EL = data.element_index;    -- element key -> index (EL.fire = 1 ... EL.dark = 8)

local pt = {
    settings = nil,
    state    = core.new_state(),
    ov       = ov.new(),           -- overload / burden estimator
    ov_last  = nil,                -- { el, time } last maneuver fed to the estimator (dedupe)
    gear     = { thresh = 0, suppress = false, items = {}, wearing = {}, checked_at = -100 },
    setup    = setup.new(),        -- the automaton's head, frame, attachments, HP/MP and stats (packet 0x044)
    kit      = { known = false },  -- what the setup means for PupTimers (rebuilt when the setup changes)
    game     = {
        logged_in       = false,
        is_pup          = false,
        main_is_pup     = false,
        job_text        = '',
        player_name     = '',
        player_id       = 0,
        pet_present     = false,
        pet_name        = nil,
        pet_id          = 0,
        maneuver_recast = 0,
    },
    actions      = {},
    unknown_seen = {},     -- lowercase name -> { name, count }
    packet_seen  = {},     -- ability key -> true once our automaton's action packets reported it
    next_poll    = 0,
    dirty_at     = nil,
    test_until   = nil,
    chat_ctx     = nil,
    last_sound   = 0,
    sounds       = nil,
    sounds_at    = -100,
    errors_at    = {},
    error_counts = {},     -- part -> errors this session
    stopped      = {},     -- part -> true when switched off after repeated errors
    last_error   = nil,
    load_msg     = true,   -- the "window is unlocked" hint, shown once on PUP
};

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

-- Missing or wrongly typed keys of dst take def's value (one level).
local function fill(dst, def)
    for k, v in pairs(def) do
        if (type(dst[k]) ~= type(v)) then
            dst[k] = v;
        end
    end
end

-- dst maps keys to field tables shaped like def's (abilities, job abilities, overload gear).
local function fill_entries(dst, def)
    for key, dv in pairs(def) do
        if (type(dst[key]) ~= 'table') then
            dst[key] = dv;
        else
            fill(dst[key], dv);
        end
    end
end

-- Repairs missing / wrongly typed values (e.g. after a hand edit) without touching valid ones.
local function sanitize(cfg)
    local d = data.default_settings();
    for section, dv in pairs(d) do
        if (type(dv) == 'table' and type(rawget(cfg, section)) ~= 'table') then
            cfg[section] = dv;
        end
    end
    for _, section in ipairs({ 'hud', 'colors', 'names', 'detect', 'maneuvers', 'overload', 'alerts', 'behavior', 'profiles', 'automaton' }) do
        fill(cfg[section], d[section]);
    end
    local tm = cfg.maneuvers.timer_mode;
    if (tm ~= 'auto' and tm ~= 'game' and tm ~= 'flat') then
        cfg.maneuvers.timer_mode = 'auto';
    end
    if (cfg.hud.grow ~= 'down' and cfg.hud.grow ~= 'up') then
        cfg.hud.grow = 'down';
    end
    fill(cfg.profiles.frames, d.profiles.frames);
    fill(cfg.maneuvers.colors, d.maneuvers.colors);
    fill_entries(cfg.abilities, d.abilities);
    for key, c in pairs(cfg.custom) do
        if (type(c) ~= 'table' or type(c.name) ~= 'string' or c.name == '') then
            cfg.custom[key] = nil;
        else
            c.cooldown = tonumber(c.cooldown) or 60;
            if (type(c.enabled) ~= 'boolean') then c.enabled = true; end
            if (type(c.alert) ~= 'boolean') then c.alert = true; end
            if (type(c.on_spawn) ~= 'boolean') then c.on_spawn = false; end
            if (type(c.color) ~= 'table') then c.color = { unpack(data.CUSTOM_COLOR) }; end
        end
    end
    fill_entries(cfg.overload.gear, d.overload.gear);
    fill_entries(cfg.jobabilities, d.jobabilities);
end

-- One-time changes for settings saved by an older version (settings.version).
local function migrate(cfg)
    local v = tonumber(rawget(cfg, 'version')) or 1;
    if (v < 2) then
        -- 1.0 had a "use the game's buff timers for every maneuver" checkbox; 1.1 has auto / game / flat.
        local m = rawget(cfg, 'maneuvers');
        if (type(m) == 'table') then
            if (rawget(m, 'real_timers') == true) then
                m.timer_mode = 'game';
            end
            m.real_timers = nil;
        end
        -- Current server code: automatons start at 35 burden (was 30), Reactive Shield 60s (was 65).
        local o = rawget(cfg, 'overload');
        if (type(o) == 'table' and rawget(o, 'spawn_burden') == 30) then
            o.spawn_burden = 35;
        end
        local ab = rawget(cfg, 'abilities');
        local rs = (type(ab) == 'table') and rawget(ab, 'reactive_shield') or nil;
        if (type(rs) == 'table' and rs.cooldown == 65) then
            rs.cooldown = 60;
        end
        cfg.version = 2;
    end
end

--[[
* settings.load fills a section missing from the file with the defaults' own table (by reference),
* and the library keeps those defaults for every other character. Editing such a section would
* quietly change the defaults other characters start from, so each one gets its own copies.
--]]
local DEFAULTS = T(data.default_settings());

local function deep_copy(t)
    local c = {};
    for k, v in pairs(t) do
        c[k] = (type(v) == 'table') and deep_copy(v) or v;
    end
    return setmetatable(c, getmetatable(t));
end

local function unshare(cfg, defaults)
    for k, dv in pairs(defaults) do
        local v = rawget(cfg, k);
        if (type(dv) == 'table' and type(v) == 'table') then
            if (rawequal(v, dv)) then
                cfg[k] = deep_copy(dv);
            else
                unshare(v, dv);
            end
        end
    end
end

-- Keeps a settings file that cannot be read as settings.lua.bad, so the defaults can take its place.
local function keep_bad_file(folder, reason)
    local file = folder .. '\\settings.lua';
    pcall(os.remove, file .. '.bad');
    pcall(os.rename, file, file .. '.bad');
    print(chat.header('PupTimers'):append(chat.warning('Could not read your settings file, so it was renamed to settings.lua.bad and the defaults are used. (' .. tostring(reason) .. ')')));
end

local function current_settings_folder()
    local ok, path = pcall(settings.settings_path);
    return (ok and type(path) == 'string') and path or nil;
end

-- A settings file edited by hand (a value where a section belongs) makes settings.load throw. Keep
-- that file as settings.lua.bad and start from the defaults instead of failing to load.
local function load_settings()
    local ok, cfg = pcall(settings.load, DEFAULTS);
    if (ok and type(cfg) == 'table') then
        return cfg;
    end
    keep_bad_file(settings.settings_path(), cfg);
    return settings.load(DEFAULTS);
end

pt.settings = load_settings();
pt.settings_folder = current_settings_folder();   -- the folder the settings in use came from
unshare(pt.settings, DEFAULTS);
migrate(pt.settings);
sanitize(pt.settings);

--[[
* On login the settings library loads the character's own file inside its own packet handler. If
* that file is broken, the library stops with an error before handing us the new settings, and our
* next save would write the settings still in use into the character's folder. Spot that (the
* folder changed but no new settings arrived), keep the broken file and load the defaults instead.
--]]
local function check_settings_switch()
    local folder = current_settings_folder();
    if (folder == nil or folder == pt.settings_folder) then
        return;
    end
    pt.settings_folder = folder;   -- once per change, even if the recovery below fails
    keep_bad_file(folder, 'it was not loaded when you logged in');
    pcall(settings.reload);        -- loads the defaults and hands them to the callback below
end

function pt.mark_dirty()
    pt.dirty_at = os.clock();
end

function pt.save_now()
    pt.dirty_at = nil;
    check_settings_switch();
    settings.save();
end

----------------------------------------------------------------------------------------------------
-- Output helpers
----------------------------------------------------------------------------------------------------

local function msg(text)
    print(chat.header('PupTimers'):append(chat.message(text)));
end

local function debug(text)
    if (pt.settings.behavior.debug) then
        print(chat.header('PupTimers'):append(chat.color1(67, text)));
    end
end

local function sound_dir()
    local base = addon.path or '';
    if (not base:match('[\\/]$')) then
        base = base .. '\\';
    end
    return base .. 'sounds\\';
end

function pt.actions.play_sound(force)
    local now = os.clock();
    if (not force and (now - pt.last_sound) < 0.5) then
        return;
    end
    pt.last_sound = now;
    local file = pt.settings.alerts.sound_file;
    if (type(file) ~= 'string' or file == '') then
        return;
    end
    pcall(function ()
        ashita.misc.play_sound(sound_dir() .. file);
    end);
end

function pt.list_sounds()
    local now = os.clock();
    if (pt.sounds ~= nil and (now - pt.sounds_at) < 5) then
        return pt.sounds;
    end
    local list = {};
    local ok, files = pcall(function ()
        local fn = ashita.fs.get_dir or ashita.fs.get_directory;
        return fn(sound_dir(), '.*.wav', true);
    end);
    if (ok and type(files) == 'table') then
        for _, f in pairs(files) do
            if (type(f) == 'string' and f:lower():match('%.wav$')) then
                list[#list + 1] = f;
            end
        end
    end
    table.sort(list);
    pt.sounds = list;
    pt.sounds_at = now;
    return list;
end

local function alert(text, play_sound)
    local a = pt.settings.alerts;
    if (a.chat) then
        print(chat.header('PupTimers'):append(chat.success(text)));
    end
    if (play_sound and a.sound) then
        pt.actions.play_sound(false);
    end
end

----------------------------------------------------------------------------------------------------
-- Names
----------------------------------------------------------------------------------------------------

function pt.effective_player_name()
    local o = pt.settings.names.player;
    if (o ~= nil and o ~= '') then
        return o;
    end
    return pt.game.player_name or '';
end

function pt.effective_pet_name()
    local o = pt.settings.names.pet;
    if (o ~= nil and o ~= '') then
        return o;
    end
    if (pt.game.pet_present and pt.game.pet_name ~= nil and pt.game.pet_name ~= '') then
        return pt.game.pet_name;
    end
    return pt.settings.names.last_pet or '';
end

function pt.names_changed()
    pt.chat_ctx = nil;
end

-- A Lua pattern matching name in any letter case ("Sharpshot" -> "[Ss][Hh][Aa]..."), or nil.
-- Every other character is escaped first ('%' + a non-alphanumeric), so the letter pass never
-- touches an escape and names typed with '[', '%' or '.' cannot break the pattern.
local function name_pattern(name)
    if (type(name) ~= 'string' or name == '') then
        return nil;
    end
    return (name:gsub('%W', '%%%0'):gsub('%a', function (c) return '[' .. c:upper() .. c:lower() .. ']'; end));
end

-- Rebuilt only when a name or the ability list changes (string comparisons, no garbage).
local function chat_context()
    local pet = pt.effective_pet_name();
    local player = pt.effective_player_name();
    local ctx = pt.chat_ctx;
    if (ctx == nil or ctx.src_pet ~= pet or ctx.src_player ~= player) then
        local list = {};
        for _, info in ipairs(core.all_abilities(pt.settings)) do
            list[#list + 1] = { key = info.key, name = info.name };
        end
        ctx = core.make_chat_context(pet, player, list);
        ctx.src_pet, ctx.src_player = pet, player;
        ctx.pet_pattern = name_pattern(pet);
        ctx.player_pattern = name_pattern(player);
        pt.chat_ctx = ctx;
    end
    return ctx;
end

----------------------------------------------------------------------------------------------------
-- Detection events
----------------------------------------------------------------------------------------------------

local function start_ability(key, source, now)
    local info = core.ability_info(pt.settings, key);
    if (info == nil) then
        return false;
    end
    if (source == 'packet' or source == 'chat') then
        -- For explaining maneuvers it used up, even when its bar is turned off.
        pt.last_pet_ability, pt.last_pet_ability_at = key, now;
    end
    if (info.enabled == false) then
        debug(('%s seen (%s) but it is turned off in settings.'):format(info.name, source));
        return false;
    end
    -- The chat line of a use can trail its action packet by a couple of seconds (animations), so a
    -- second report within DUP_WINDOW is the same use (never more than half a short custom cooldown).
    local cd = tonumber(info.cooldown) or 0;
    local dedupe = math.max(0.5, math.min(core.DUP_WINDOW, cd / 2));
    local t = pt.state.timers[key];
    if (source == 'packet' and t ~= nil and t.src == 'chat') then
        -- The client writes our automaton's chat line from its action packet, so that line never
        -- comes first: a bar started from chat before our packet was another automaton's use.
        dedupe = 0;
    end
    local started = core.start_timer(pt.state, key, info.name, info.cooldown, now, dedupe);
    if (started) then
        pt.state.timers[key].src = source;
        debug(('%s used %s [%s] - %ds cooldown.'):format(pt.effective_pet_name(), info.name, source, tonumber(info.cooldown) or 0));
    end
    return started;
end

----------------------------------------------------------------------------------------------------
-- Overload estimator plumbing
----------------------------------------------------------------------------------------------------

-- Heatsink extra burden decay by active Water Maneuvers on older server code (the "by Water" option).
local HEATSINK_DECAY = { [0] = 2, 4, 5, 6 };

local function overload_params(out)
    local o = pt.settings.overload;
    local thresh, decay, suppress = 0, 0, false;
    thresh = thresh + (pt.gear.thresh or 0);
    suppress = (pt.gear.suppress == true);
    local heatsink = o.heatsink;
    if (o.attachments_auto and pt.kit.known) then
        heatsink = pt.kit.heatsink;   -- as the game reports it
    end
    if (heatsink) then
        if (o.heatsink_by_water) then
            local water = 0;
            for _, m in ipairs(pt.state.man.list) do
                if (m.el == EL.water) then
                    water = water + 1;
                end
            end
            decay = decay + (HEATSINK_DECAY[math.min(water, 3)] or 2);
        else
            decay = decay + (tonumber(o.heatsink_decay) or 1);
        end
    end
    -- Tactical Processor: this era's server code gives it -5 overload threshold, but on the
    -- automaton, and the overload check only reads your own threshold, so it changes nothing.
    thresh = thresh + (tonumber(o.extra_threshold) or 0);
    decay = decay + (tonumber(o.extra_decay) or 0);
    return ov.params(pt.settings, thresh, decay, suppress, pt.state.man.overdrive == true, out);
end

-- The parameters worked out by the last poll (fresh ones if there was no poll yet).
function pt.overload_params()
    return pt.ov_params or overload_params();
end

----------------------------------------------------------------------------------------------------
-- Burden of a maneuver from stats
--
-- The server works out how much burden a maneuver adds from your stat for that element against
-- the automaton's (Dark: from the frame, or your MP against its MP, depending on the server code).
-- The automaton's stats come with every setup packet; yours sit in memory from packet 0x061, which
-- the server does not send again when your gear or buffs change, so they are only used while
-- neither has changed since. Both server rules are tried, and one is used only once it has matched
-- the game's own overload reports (ov.best_rule).
----------------------------------------------------------------------------------------------------

local STAT_OF = { 1, 5, 4, 3, 2, 6, 7 };   -- element -> stat (1 STR 2 DEX 3 VIT 4 AGI 5 INT 6 MND 7 CHR)

-- The item in equipment slot 0-15 and the container / index it sits in (nil when the slot is empty).
local function equipped_item(inv, slot)
    local eq = inv:GetEquippedItem(slot);
    local packed = eq and eq.Index or 0;
    if (packed == nil or packed == 0) then
        return nil;
    end
    local container, index = bit.rshift(bit.band(packed, 0xFF00), 8), bit.band(packed, 0xFF);
    return inv:GetContainerItem(container, index), container, index;
end

local function gear_print()
    local h = 0;
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then
        return 0;
    end
    for slot = 0, 15 do
        local item = equipped_item(inv, slot);
        local id = (item ~= nil and tonumber(item.Id)) or 0;
        h = (h * 31 + id + slot) % 2147483647;
    end
    return h;
end

-- Packet 0x061: your stats as the server sends them. Remember what you wore and which buffs were up.
local COUNTS_61 = {};
local function on_stats_packet(e)
    if (not pt.game.is_pup) then
        return;
    end
    pt.stats_at = os.clock();
    pt.stats_gear = gear_print();
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local _, _, _, bp = core.count_maneuvers(player and player:GetBuffs() or nil, COUNTS_61);
    pt.stats_buffs = bp;
end

-- True while your stats in memory still match what you wear and your buffs.
local function stats_fresh(gear_now)
    return pt.stats_at ~= nil and pt.buffs_print == pt.stats_buffs and (gear_now or pt.gear_print) == pt.stats_gear;
end

function pt.stats_fresh()
    return stats_fresh();
end

-- The burden a maneuver of element e would add now, by the two server rules (nil if not known).
local function predict_burden(e, p, fresh)
    local st = pt.setup;
    if (not pt.settings.overload.use_stats or not st.known) then
        return nil, nil;
    end
    local era, classic;
    if (e == EL.dark) then
        local f = data.frame_by_byte[st.frame];
        era = (f ~= nil and (f.key == 'valoredge' or f.key == 'sharpshot')) and 8 or 14;
        local ok, mp = pcall(function () return AshitaCore:GetMemoryManager():GetParty():GetMemberMP(0); end);
        if (ok and type(mp) == 'number') then
            classic = (mp < st.mp) and 15 or 10;
        end
    else
        if (not fresh) then
            return nil, nil;
        end
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local i = STAT_OF[e];
        local mine = (tonumber(player:GetStat(i - 1)) or 0) + (tonumber(player:GetStatModifier(i - 1)) or 0);
        local diff = mine - setup.stat(st, i);
        era = (diff >= 4) and 14 or ((diff >= 0) and (19 - diff) or 20);
        classic = (diff < 0) and 20 or 15;
    end
    if (p.suppress) then
        era = era and math.floor(era / 3);              -- Kenkonken
        classic = classic and math.floor(classic / 3);
    end
    return era, classic;
end

-- One maneuver can be reported by the action packet, the chat log and the recast timer; the estimator
-- must count it once, but use the overload chance from whichever source carries it.
local function feed_overload(el, now, report, source)
    if (not pt.settings.overload.enabled) then
        return;   -- estimate switched off: no burden tracking and no risk warnings
    end
    local p = pt.overload_params();
    if (report ~= nil and type(report.chance) == 'number' and report.chance > 0) then
        p = ov.after_overdrive(p);   -- a chance above 0% means Overdrive is over (see ov.on_report)
    end
    local last = pt.ov_last;
    if (last ~= nil and last.el == el and (now - last.time) < core.DUP_WINDOW) then
        if (report ~= nil and not last.reported) then
            ov.on_report(pt.ov, el, now, p, report.chance, report.overloaded);
            last.reported = true;
            last.chance = report.chance;
            debug(('Overload chance %s: %d%% [%s]'):format(data.elements[el].name, report.chance, source));
        end
        return;
    end
    pt.ov_last = { el = el, time = now, reported = (report ~= nil), chance = report and report.chance or nil };
    local era, classic = predict_burden(el, p, stats_fresh(gear_print()));
    if (pt.burden_rule ~= nil) then
        -- The burden this maneuver adds comes from the stats as worn right now (the per-second
        -- prediction may predate a gear swap made for this maneuver); nil = use the learned value.
        pt.ov.el[el].pred = (pt.burden_rule == 'era') and era or classic;
    end
    ov.on_maneuver(pt.ov, el, now, p, report, era, classic);
    if (report ~= nil) then
        debug(('Overload chance %s: %d%%%s [%s]'):format(data.elements[el].name, report.chance, report.overloaded and ' (OVERLOADED)' or '', source));
    end
    local warn = tonumber(pt.settings.overload.alert_risk) or 0;
    if (warn > 0 and not (report and report.overloaded)) then
        local risk = ov.next_risk(pt.ov, el, now, p);
        if (risk >= warn) then
            alert(('Another %s Maneuver now has about a %d%% overload chance.'):format(data.elements[el].name, math.floor(risk + 0.5)), true);
        end
    end
end

local function handle_event(ev, source, now)
    if (ev == nil) then
        return;
    end
    if (ev.kind == 'pet_ability') then
        if (source == 'packet') then
            pt.packet_seen[ev.key] = true;
        elseif (source == 'chat' and pt.packet_seen[ev.key] and pt.settings.detect.packets and
                not pt.stopped.actions and (pt.game.pet_id ~= 0 or not pt.game.pet_present)) then
            -- The packets already report this ability for our automaton, picked out by its id. The
            -- chat line adds nothing and may come from another automaton with the same name (always
            -- the case while ours is not out).
            return;
        end
        start_ability(ev.key, source, now);
    elseif (ev.kind == 'maneuver') then
        pt.man_used_at = now;
        if (core.maneuver_use(pt.state, ev.element, now)) then
            debug(('%s Maneuver used [%s].'):format(data.elements[ev.element].name, source));
        end
        local report = nil;
        if (ev.overload_chance ~= nil) then
            report = { chance = ev.overload_chance, overloaded = ev.overloaded == true };
        end
        feed_overload(ev.element, now, report, source);
    elseif (ev.kind == 'overload_report') then
        -- "<automaton>'s overload chance is N%." on its own line: belongs to the maneuver just used.
        local last = pt.ov_last;
        local el = ev.element or ((last ~= nil and (now - last.time) < core.DUP_WINDOW) and last.el or nil);
        if (el ~= nil) then
            feed_overload(el, now, { chance = ev.chance, overloaded = ev.overloaded == true }, source);
        end
    elseif (ev.kind == 'overloaded') then
        -- "<player> is overloaded!" arrived as its own line: the maneuver just reported overloaded,
        -- which lasts (reported chance - 5) seconds.
        local last = pt.ov_last;
        if (last ~= nil and (now - last.time) < core.DUP_WINDOW) then
            if (last.chance ~= nil and pt.ov.overload_until == nil) then
                pt.ov.overload_until = last.time + math.max(0, last.chance - pt.overload_params().offset);
            end
            debug(('Overloaded on %s Maneuver [%s].'):format(data.elements[last.el].name, source));
        end
    elseif (ev.kind == 'pet_unknown') then
        local name = ev.name or '';
        local lname = name:lower();
        if (lname ~= '' and not data.ignored_pet_skills[lname]) then
            local u = pt.unknown_seen[lname];
            if (u == nil) then
                u = { name = name, count = 0 };
                pt.unknown_seen[lname] = u;
                debug(('Automaton used "%s", which is not in the ability list. Add it in /pupt -> Automaton if it has a cooldown.'):format(name));
            end
            u.count = u.count + 1;
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Game polling
----------------------------------------------------------------------------------------------------

local function job_text(main, main_lvl, sub, sub_lvl)
    local m = data.job_names[main] or '?';
    local s = data.job_names[sub];
    if (s == nil) then
        return ('%s%d'):format(m, main_lvl or 0);
    end
    return ('%s%d/%s%d'):format(m, main_lvl or 0, s, sub_lvl or 0);
end

-- Reused every poll (10 times a second) so polling creates no garbage.
local RECASTS = {};
local PETINFO = { name = '', id = 0 };
local COUNTS  = { 0, 0, 0, 0, 0, 0, 0, 0 };
local PARAMS  = { {}, {} };       -- overload parameters of this poll and of the previous one
local zoning_fn = nil;            -- player.GetIsZoning if this Ashita build has it (false = it does not)

local function read_recasts(rc, out)
    for k in pairs(out) do
        out[k] = nil;
    end
    if (rc == nil) then
        return out;
    end
    for x = 0, 31 do
        local t = rc:GetAbilityTimer(x);
        if (t ~= nil and t > 0) then
            if (x == 0) then
                out.sp = t / 60;    -- recast values are in 1/60 second units
            else
                local id = rc:GetAbilityTimerId(x);
                if (id ~= nil and id ~= 0) then
                    out[id] = t / 60;
                end
            end
        end
    end
    return out;
end

local function on_pet_spawn(now, activated)
    local started = {};
    for _, info in ipairs(core.all_abilities(pt.settings)) do
        if (info.on_spawn and info.enabled ~= false) then
            if (core.start_timer(pt.state, info.key, info.name, info.spawn_cooldown or info.cooldown, now, 0)) then
                started[#started + 1] = info.name;
            end
        end
    end
    debug(('%s: %s.%s'):format(activated and 'Automaton activated' or 'Automaton re-created after zoning', pt.game.pet_name or '?',
        (#started > 0) and (' Started: ' .. table.concat(started, ', ')) or ''));
end

--[[
* A new automaton exists: Activate / Deus Ex Automata (activated = true), or the one the server
* re-creates after zoning. Its burden starts from scratch in every element. Several signals can
* report the same activation (the automaton appearing, a new entity id, the Activate recast
* starting), so an activation is handled once per 3 seconds.
--]]
local function automaton_spawned(now, activated)
    if (activated and pt.spawned_at ~= nil and (now - pt.spawned_at) < SPAWN_DEDUPE) then
        pt.spawn_pending = nil;   -- another signal for the activation already handled
        return;
    end
    pt.spawned_at = now;
    pt.spawn_pending = nil;
    -- The server builds a brand-new automaton every time (Activate, Deus Ex Automata, zoning), so
    -- the old automaton's cooldown bars no longer apply. Newer server code puts its abilities on
    -- cooldown as it is built, zoning included: the abilities ticked "On act." start here.
    if (pt.settings.behavior.reset_on_despawn) then
        core.clear_timers(pt.state);
    end
    if (not activated) then
        debug('Zoned: overload estimate and ability timers reset for the re-created automaton.');
    end
    on_pet_spawn(now, activated);
    if (pt.settings.overload.enabled) then
        ov.on_spawn(pt.ov, now, pt.overload_params());
    end
end

-- Zoning (or logged out). Remember whether an automaton was out: only then does the server
-- re-create one after the zone.
local function mark_zoning()
    if (not pt.zoned) then
        pt.zoned = true;
        pt.zone_had_pet = (pt.state.pet.present == true);
    end
end

--[[
* Maneuvers that went before their time without a new one replacing them: an attachment used them
* up (the game shows no message for that). Says which one when the cause is clear.
--]]
local USED_N = {};
-- 'a' or 'an' for an element name (an Earth Maneuver, an Ice Maneuver).
local function article(word)
    return word:find('^[AEIOU]') and 'an' or 'a';
end

-- "a Fire Maneuver, an Earth Maneuver and 2 Light Maneuvers"
local function join_and(parts)
    if (#parts <= 1) then
        return parts[1] or '';
    end
    return table.concat(parts, ', ', 1, #parts - 1) .. ' and ' .. parts[#parts];
end

local function used_text(e)
    local n, el = USED_N[e], data.elements[e].name;
    return (n == 1) and ('%s %s Maneuver'):format(article(el), el) or ('%d %s Maneuvers'):format(n, el);
end

-- Flame Holder takes its Fire Maneuvers when the weapon skill's animation ends (up to 3.5 s after
-- its action packet); Ice Maker takes Ice Maneuvers as the spell lands.
local WS_WINDOW, NUKE_WINDOW = 5.0, 5.0;

-- A removed maneuver: true if it went more than 3 s before its end (used up), false if it ran out,
-- nil if a new maneuver pushed it out or its end is not known.
local function went_early(r, now, duration)
    local ends = core.maneuver_end(r, duration);
    if (r.replaced or ends == nil) then
        return nil;
    end
    return now < ends - 3;
end

local function explain_used_up(removed, now, duration, pet_alive)
    for e = 1, 8 do
        USED_N[e] = 0;
    end
    local total = 0;
    for _, r in ipairs(removed) do
        -- Only maneuvers known to have gone early. One that was already up when PupTimers loaded has
        -- no known end until the game sends its timer, so it cannot be told apart from running out.
        if (went_early(r, now, duration) == true) then
            USED_N[r.el] = USED_N[r.el] + 1;
            total = total + 1;
        end
    end
    if (total == 0) then
        return;
    end
    local a = nil;
    if ((now - (pt.last_pet_ability_at or -100)) <= 3) then
        a = core.ability_def[pt.last_pet_ability or ''];
    end
    -- Eraser uses up every maneuver on this era's server code (older code: only Light ones), so
    -- whatever went right after it is its doing.
    if (a ~= nil and a.consumes == 'all') then
        local parts = {};
        for e = 1, 8 do
            if (USED_N[e] > 0) then
                parts[#parts + 1] = used_text(e);
            end
        end
        msg(('%s used up %s.'):format(a.name, join_and(parts)));
        return;
    end
    local kit = pt.kit;
    -- Flame Holder fires on the automaton's weapon skills, Ice Maker on its elemental nukes.
    local weapon_skill = (now - (pt.pet_ws_at or -100)) <= WS_WINDOW;
    local nuke = (now - (pt.pet_nuke_at or -100)) <= NUKE_WINDOW;
    local alive = pet_alive and kit.known;
    for e = 1, 8 do
        if (USED_N[e] > 0) then
            local what = used_text(e);
            local text = nil;
            if (a ~= nil and a.consumes and a.element == data.elements[e].key) then
                text = ('%s used up %s.'):format(a.name, what);
            elseif (alive and e == EL.fire and kit.flame_holder and weapon_skill) then
                -- Said once per session: using up Fire Maneuvers on weapon skills is what it is for.
                text = ('Flame Holder used %s for the automaton\'s weapon skill.'):format(what);
                if (pt.told_flame) then
                    debug(text);
                    text = false;
                end
                pt.told_flame = true;
            elseif (alive and e == EL.ice and kit.ice_maker and nuke) then
                text = ('Ice Maker used %s for the automaton\'s spell.'):format(what);
                if (pt.told_ice) then
                    debug(text);
                    text = false;
                end
                pt.told_ice = true;
            elseif (alive and #pt.state.man.list > 0) then
                -- Not everything went (so not a KO, Deactivate or overload).
                if (e == EL.water and kit.condenser and (now - (pt.man_used_at or -100)) <= 3) then
                    text = ('Condenser used %s to stop an overload.'):format(what);
                elseif (e == EL.earth and kit.schurzen) then
                    text = ('Schurzen used %s to save your automaton from a fatal hit.'):format(what);
                end
            end
            if (text) then
                msg(text);
            elseif (text == nil) then
                debug(('%s went early (no maneuver replaced it).'):format(what));
            end
        end
    end
end

--[[
* Equipped automaton abilities that cannot fire because no maneuver of their element is up (and that
* are not cooling down anyway). The text is rebuilt only when that set changes.
--]]
local function update_unpowered(counts, lost_maneuver, pet_alive)
    local g = pt.game;
    local cfg = pt.settings;
    local show, warn = cfg.maneuvers.show_unpowered == true, cfg.maneuvers.alert_unpowered == true;
    local key = 0;
    -- Only while the automaton is really there and alive: Deactivate, a KO and zoning take every
    -- maneuver at once, and that is not "an ability left unpowered".
    if (pt.kit.known and pet_alive and (show or warn)) then
        for i, a in ipairs(data.abilities) do
            if (a.element ~= nil and pt.kit.abilities[a.key]) then
                local s = cfg.abilities[a.key];
                local t = pt.state.timers[a.key];
                if (s ~= nil and s.enabled ~= false and counts[data.element_index[a.element]] == 0 and (t == nil or t.ready)) then
                    key = key + 2 ^ (i - 1);
                end
            end
        end
    end
    if (key == pt.unpowered_key and show == pt.unpowered_show) then
        return;
    end
    local before = pt.unpowered_key or 0;
    pt.unpowered_key, pt.unpowered_show = key, show;
    g.unpowered_text, g.unpowered_short = nil, nil;
    if (key == 0) then
        return;
    end
    local parts, newly, need = {}, {}, {};
    for i, a in ipairs(data.abilities) do
        local bit_i = 2 ^ (i - 1);
        if (key % (2 * bit_i) >= bit_i) then
            local el = data.elements[data.element_index[a.element]].name;
            parts[#parts + 1] = ('%s (%s)'):format(a.name, el);
            if (need[el] == nil) then
                need[el] = true;
                need[#need + 1] = el;
            end
            if (before % (2 * bit_i) < bit_i) then
                newly[#newly + 1] = ('%s needs %s %s Maneuver'):format(a.name, article(el), el);
            end
        end
    end
    if (show) then
        g.unpowered_text = 'Unpowered: ' .. table.concat(parts, ', ');
        g.unpowered_short = 'Needs ' .. table.concat(need, ', ');   -- narrow windows
    end
    if (lost_maneuver and warn and #newly > 0) then
        alert(table.concat(newly, '; ') .. '.', true);
    end
end

--[[
* Automaton Oil: the stack in the ammo slot (what Repair uses, one per use) and how many more the
* inventory holds. The inventory is only scanned again when the game says it changed.
--]]
local OIL = { id = nil, count = 0, more = 0, counter = false, ec = nil, es = nil };

-- Forgets the oil seen (another character, or PUP left): nothing to compare the next reading with.
local function reset_oil()
    OIL.id, OIL.count, OIL.more, OIL.counter, OIL.label, OIL.short, OIL.ec, OIL.es = nil, 0, 0, false, nil, nil, nil, nil;
end

-- Forgets what was tracked about the automaton, its maneuvers and its burden (Puppetmaster left,
-- or another character's settings arrived).
local function reset_tracking()
    pt.state = core.new_state();
    pt.ov, pt.ov_last = ov.new(), nil;
    pt.buff_ends, pt.buff_ends_at = nil, nil;
    pt.spawned_at, pt.spawn_pending = nil, nil;
    pt.setup, pt.kit, pt.kit_frame = setup.new(), { known = false }, nil;
    pt.stats_at = nil;
    reset_oil();
end

local function read_oil()
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then
        return;
    end
    local id, count = nil, 0;
    local item, ec, es = equipped_item(inv, 3);   -- ammo slot
    ec, es = ec or -1, es or -1;
    if (item ~= nil and data.oils[item.Id] ~= nil) then
        id, count = item.Id, tonumber(item.Count) or 0;
    end
    local okc, counter = pcall(function () return inv:GetContainerUpdateCounter(); end);
    if (not okc) then
        counter = nil;
    end
    local more_before = OIL.more;
    if (counter == nil or counter ~= OIL.counter or id ~= OIL.id) then
        OIL.counter = counter;
        local more = 0;
        local max = math.min(tonumber(inv:GetContainerCountMax(0)) or 80, 80);
        for slot = 1, max do
            if (not (ec == 0 and es == slot)) then
                local it = inv:GetContainerItem(0, slot);
                if (it ~= nil and data.oils[it.Id] ~= nil) then
                    more = more + (tonumber(it.Count) or 0);
                end
            end
        end
        OIL.more = more;
    end
    local was = OIL.count;
    -- Oil equipped from a container other than the inventory (a wardrobe) stays there when taken off.
    local kept = false;
    if (was > 0 and id == nil and OIL.ec ~= nil and OIL.ec ~= 0) then
        local it = inv:GetContainerItem(OIL.ec, OIL.es);
        kept = (it ~= nil and data.oils[it.Id] ~= nil);
    end
    local changed = (id ~= OIL.id or count ~= OIL.count or OIL.more ~= more_before or OIL.label == nil);
    OIL.id, OIL.count = id, count;
    if (id ~= nil) then
        OIL.ec, OIL.es = ec, es;
    end
    if (changed) then
        local more = (OIL.more > 0) and (', %d more'):format(OIL.more) or '';
        OIL.label = (id ~= nil) and ('Repair (%s x%d%s)'):format(data.oils[id], count, more) or 'Repair (no oil equipped)';
        OIL.short = (id ~= nil) and ('Repair (%s x%d)'):format(data.oils[id], count) or 'Repair (no oil)';
        -- Used up, not taken off: an unequipped stack is back among the inventory's oil.
        if (was > 0 and id == nil and not kept and OIL.more < more_before + was and pt.settings.automaton.oil) then
            alert(('Out of Automaton Oil in your ammo slot%s.'):format((OIL.more > 0) and (' (%d more in your inventory)'):format(OIL.more) or ''), true);
        end
    end
    pt.game.repair_label = pt.settings.automaton.oil and OIL.label or nil;
    pt.game.repair_short = pt.settings.automaton.oil and OIL.short or nil;
    pt.game.oil_ready = (id ~= nil);
end

-- The automaton: whether it is out, its HP / MP, and new automatons (activation, zoning).
local function poll_pet(now, g, ent, player)
    -- Automaton --------------------------------------------------------------------------------
    local info = nil;
    local idx = ent.PetTargetIndex;
    if (idx ~= nil and idx ~= 0) then
        local pet = GetEntity(idx);
        if (pet ~= nil) then
            local name = pet.Name;
            if (type(name) == 'string' and name ~= '') then
                PETINFO.name = name;
                PETINFO.id = pet.ServerId or 0;
                PETINFO.hpp = pet.HPPercent;
                info = PETINFO;
            end
        end
    end
    local first_look = not pt.state.pet.initialized;
    local pet_event = core.update_pet(pt.state, info, now, PET_GRACE);
    if (first_look and info ~= nil) then
        ov.mark_unknown(pt.ov, now);   -- already out when PupTimers loaded: its burden is not known
    end
    g.pet_present = pt.state.pet.present;
    g.pet_name = pt.state.pet.name;
    g.pet_id = g.pet_present and (pt.state.pet.id or 0) or 0;
    if (info ~= nil) then
        g.pet_hpp = tonumber(info.hpp);
        local okm, mpp = pcall(player.GetPetMPPercent, player);
        g.pet_mpp = okm and tonumber(mpp) or nil;
    else
        g.pet_hpp, g.pet_mpp = nil, nil;
    end
    if (info ~= nil and info.name ~= pt.settings.names.last_pet) then
        pt.settings.names.last_pet = info.name;
        pt.chat_ctx = nil;
        pt.mark_dirty();
    end
    local after_zone = (pt.zone_end ~= nil and pt.zone_had_pet and (now - pt.zone_end) < ZONE_RESPAWN);
    if (pet_event == 'despawn') then
        debug('Automaton is no longer out.');
        ov.on_despawn(pt.ov, now);
        if (pt.settings.behavior.reset_on_despawn) then
            core.clear_timers(pt.state);
        end
    elseif (info ~= nil and after_zone) then
        -- Zoned with the automaton out: the server re-creates it in the new zone. (Only once it is
        -- actually there: in a town it is not re-created at all.) Without one out before the zone,
        -- an automaton that appears is a normal activation (next branch).
        pt.zone_end = nil;
        automaton_spawned(now, false);
    elseif (pet_event == 'spawn' or (info ~= nil and pt.spawn_pending ~= nil)) then
        -- A new automaton. The pending case: Activate / Deus Ex Automata was used and an automaton
        -- is out, even if it came back faster than the despawn grace period.
        automaton_spawned(now, true);
    end
    if (pt.zone_end ~= nil and (now - pt.zone_end) >= ZONE_RESPAWN) then
        pt.zone_end = nil;
    end
    if (pt.spawn_pending ~= nil and (now - pt.spawn_pending) > SPAWN_PENDING_FOR) then
        pt.spawn_pending = nil;
    end
    return info;
end

-- Gear that changes overload, and the Automaton Oil, every few seconds.
local function poll_gear(now)
    -- Gear that changes burden / overload (checked every 2 seconds) ---------------------------
    if ((now - pt.gear.checked_at) >= GEAR_INTERVAL) then
        pt.gear.checked_at = now;
        local ids = pt.read_equipped_ids();
        local thresh, suppress, counted, wearing = gear.totals(ids, pt.settings);
        pt.gear.thresh, pt.gear.suppress, pt.gear.items, pt.gear.wearing = thresh, suppress, counted, wearing;
        ov.set_suppress(pt.ov, suppress);
        pcall(read_oil);
        pt.gear_print = gear_print();
    end
end

-- Maneuvers from the buff bar; returns the count of each element.
local function poll_maneuvers(now, g, player, info)
    -- Maneuvers (buff bar is the source of truth) ----------------------------------------------
    local counts, overload, overdrive, bprint = core.count_maneuvers(player:GetBuffs(), COUNTS);
    pt.buffs_print = bprint;
    if (overload and not pt.state.man.overload) then
        debug('Overloaded!');
    elseif (not overload and pt.state.man.overload) then
        pt.ov.overload_until = nil;
    end
    pt.state.man.overload = overload;
    pt.state.man.overdrive = overdrive;
    local duration = tonumber(pt.settings.maneuvers.duration) or 60;
    local removed = core.maneuver_sync(pt.state, counts, now, data.MAX_MANEUVERS, duration, pt.clock_game and pt.buff_ends or nil);
    -- Auto: maneuvers count from their use (exact, no clock needed) until one turns out to last
    -- longer than the set duration (servers that lengthen them in long fights); from then on the
    -- game's buff timers are used. With only the PC clock to go by, a maneuver that matched the
    -- duration must have been seen first, so a PC clock that is off cannot fake a longer one.
    local mode = pt.settings.maneuvers.timer_mode;
    local seen = core.fresh_maneuver_length(pt.state, pt.buff_ends, pt.buff_ends_at, now);
    if (seen ~= nil) then
        if (math.abs(seen - duration) <= 3) then
            pt.flat_seen = true;
        elseif (seen > duration + 5 and seen <= 330) then
            pt.long_seen = math.max(pt.long_seen or 0, seen);
            if (mode == 'auto' and not pt.long_maneuvers and (pt.clock_game or pt.flat_seen)) then
                pt.long_maneuvers = true;
                msg(('A maneuver just got %ds instead of %ds, so maneuvers last longer in battle on this server: following the game\'s buff timers from now on.'):format(math.floor(seen + 0.5), duration));
            end
        end
    end
    local use_game = (mode == 'game') or (mode == 'auto' and pt.long_maneuvers == true);
    core.apply_buff_ends(pt.state, pt.buff_ends, now, not use_game, duration);
    if (overload and pt.buff_ends ~= nil and pt.buff_ends.overload ~= nil) then
        pt.ov.overload_until = pt.buff_ends.overload;   -- exact, from the game's buff timer
    end
    g.man_counts = counts;
    local pet_alive = (info ~= nil and (g.pet_hpp or 0) > 0);
    if (removed ~= nil and pt.settings.maneuvers.explain_used and not overload) then
        explain_used_up(removed, now, duration, pet_alive);
    end
    -- An overload takes every maneuver at once: not "an ability left unpowered" either.
    update_unpowered(counts, removed ~= nil and not overload, pet_alive);
    if (removed ~= nil and pt.settings.maneuvers.enabled and pt.settings.maneuvers.alert_wear and not overload) then
        for _, r in ipairs(removed) do
            -- Only maneuvers that ran out: not ones a new maneuver pushed out, and not ones that
            -- zoning, a KO or a job change took away early.
            if (went_early(r, now, duration) == false) then
                alert(('%s Maneuver wore off.'):format(data.elements[r.el].name), true);
            end
        end
    end
    return counts;
end

-- The overload estimate's parameters and the burden predictions from stats.
local function poll_overload(now, g)
    -- Overload parameters for this poll (Heatsink depends on the Water maneuvers just counted).
    -- When the cooling rate changes, the burden so far is fixed at the old rate first.
    local prev = pt.ov_params;
    local p_now = overload_params((prev == PARAMS[1]) and PARAMS[2] or PARAMS[1]);
    local ov_on = pt.settings.overload.enabled;
    if (ov_on and pt.ov_off) then
        -- Switched back on: nothing was tracked meanwhile, so the burden is unknown again.
        pt.ov = ov.new();
        if (g.pet_present) then
            ov.mark_unknown(pt.ov, now);
        end
    elseif (ov_on and prev ~= nil and prev.decay ~= p_now.decay) then
        ov.rebase(pt.ov, now, prev);
    end
    pt.ov_off = not ov_on;
    pt.ov_params = p_now;
    -- The burden each element's next maneuver would add, by the stat rule the game has confirmed.
    if (now >= (pt.pred_next or 0)) then
        pt.pred_next = now + 1.0;
        local rule = (ov_on and pt.settings.overload.use_stats) and ov.best_rule(pt.ov) or nil;
        local fresh = stats_fresh();
        for e = 1, 8 do
            local pred = nil;
            if (rule ~= nil) then
                local era, classic = predict_burden(e, p_now, fresh);
                pred = (rule == 'era') and era or classic;
            end
            pt.ov.el[e].pred = pred;
        end
        pt.burden_rule = rule;
    end
end

-- Job ability recasts: ready alerts, and activations (Activate, Deus Ex Automata).
local function poll_job_abilities(now, g, recasts)
    -- Job abilities ----------------------------------------------------------------------------
    local fired, started = core.update_job_abilities(pt.state, data.job_abilities, recasts, now, g.main_is_pup);
    if (fired ~= nil) then
        for _, def in ipairs(fired) do
            local opt = pt.settings.jobabilities[def.key];
            if (opt ~= nil and opt.alert) then
                if (def.key == 'repair' and pt.settings.automaton.oil and not g.oil_ready) then
                    alert('Repair is ready, but there is no Automaton Oil in your ammo slot.', true);
                else
                    alert(('%s is ready.'):format(def.name), true);
                end
            end
        end
    end
    if (started ~= nil) then
        for _, def in ipairs(started) do
            -- Confirmed on a later poll once an automaton is out, unless the automaton that just
            -- appeared already accounted for this activation.
            if (def.spawns and (pt.spawned_at == nil or (now - pt.spawned_at) >= SPAWN_DEDUPE)) then
                pt.spawn_pending = now;
            end
        end
    end
end

-- HP / MP marks, the Deactivate hint and the Repair reminder.
local function update_marks_and_hints(g, counts)
    -- Puppetmaster marks on the HP / MP bars, rebuilt only when what they depend on changes:
    -- where Economizer and Mana Converter fire for the Dark Maneuvers up, where Replicator fires.
    local kit = pt.kit;
    local dark, wind = counts[EL.dark], counts[EL.wind];
    local mk, hk = 0, 0;
    if (kit.known and g.pet_present) then
        mk = ((kit.economizer and dark >= 1) and 1 or 0) + ((kit.mana_converter and dark >= 1) and 2 or 0) + dark * 4;
        hk = ((kit.replicator and wind >= 1) and 1 or 0) + (kit.damage_gauge and 2 or 0);
    end
    if (mk ~= pt.mp_marks_key) then
        pt.mp_marks_key = mk;
        local marks = nil;
        if (mk % 4 ~= 0) then
            marks = {};
            if (mk % 2 == 1) then
                marks[#marks + 1] = (60 - 10 * dark) / 100;             -- Economizer: below 50/40/30%
            end
            if (mk % 4 >= 2) then
                marks[#marks + 1] = ({ 40, 60, 65 })[math.min(dark, 3)] / 100;   -- Mana Converter
            end
        end
        g.pet_mp_marks = marks;
    end
    if (hk ~= pt.hp_marks_key) then
        pt.hp_marks_key = hk;
        g.pet_hp_marks = (hk % 2 == 1) and { (hk >= 2) and 0.75 or 0.50 } or nil;   -- Replicator
    end
    -- Deactivate at exactly full HP resets the Activate recast: say so while Activate cools down.
    local act = pt.state.ja.activate;
    local st = pt.setup;
    g.deactivate_hint = (pt.settings.automaton.deactivate_hint and kit.known and g.pet_present and
        act ~= nil and act.active and st.max_hp > 0 and st.hp >= st.max_hp and (g.pet_hpp or 0) > 0) or nil;

    -- Repair reminder: once each time the automaton's HP falls to the set % while Repair is ready.
    local ra = tonumber(pt.settings.automaton.repair_at) or 0;
    if (ra > 0 and g.pet_present and g.pet_hpp ~= nil and g.pet_hpp > 0) then
        if (g.pet_hpp <= ra) then
            local rep = pt.state.ja.repair;
            if ((rep == nil or not rep.active) and not pt.repair_nudged) then
                pt.repair_nudged = true;
                if (pt.settings.automaton.oil and not g.oil_ready) then
                    alert(('Automaton HP %d%%: Repair is ready, but there is no Automaton Oil in your ammo slot.'):format(g.pet_hpp), true);
                else
                    alert(('Automaton HP %d%%: Repair is ready.'):format(g.pet_hpp), true);
                end
            end
        elseif (g.pet_hpp >= ra + 10) then
            pt.repair_nudged = nil;
        end
    end
end

local function poll(now)
    local g = pt.game;
    local mm = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    local ent = GetPlayerEntity();

    if (player == nil or ent == nil) then
        g.logged_in = false;
        g.is_pup = false;
        mark_zoning();
        return;
    end
    -- GetIsZoning is looked up once: not every Ashita build may have it.
    if (zoning_fn == nil) then
        local ok, fn = pcall(function () return player.GetIsZoning; end);
        zoning_fn = (ok and fn ~= nil) and fn or false;
    end
    if (zoning_fn) then
        local zok, zoning = pcall(zoning_fn, player);
        if (zok and zoning ~= nil and zoning ~= 0 and zoning ~= false) then
            mark_zoning();
            return;
        end
    end

    g.logged_in = true;
    if (pt.zoned) then
        -- Just finished zoning (or logging in): an automaton that was out is re-created by the
        -- server within a few seconds. The despawn grace starts again from here, so the loading
        -- screen itself never counts as the automaton being gone.
        pt.zoned = false;
        pt.zone_end = now;
        pt.state.pet.absent_since = nil;
    end
    local main, sub = player:GetMainJob(), player:GetSubJob();
    local main_lvl, sub_lvl = player:GetMainJobLevel(), player:GetSubJobLevel();
    if (main ~= g.main or sub ~= g.sub or main_lvl ~= g.main_lvl or sub_lvl ~= g.sub_lvl) then
        g.main, g.sub, g.main_lvl, g.sub_lvl = main, sub, main_lvl, sub_lvl;
        g.job_text = job_text(main, main_lvl, sub, sub_lvl);
    end
    g.main_is_pup = (main == data.PUP_JOB_ID);
    g.is_pup = g.main_is_pup or (sub == data.PUP_JOB_ID);

    local pname = ent.Name or '';
    if (pname ~= g.player_name) then
        g.player_name = pname;
        pt.chat_ctx = nil;
    end
    g.player_id = ent.ServerId or 0;
    -- Status 4 is "in an event" (cutscene, talking to an NPC); the stock cleancs addon uses the same.
    g.in_event = (ent.StatusServer == 4 or ent.Status == 4);

    if (not g.is_pup) then
        -- Not on Puppetmaster: forget what was tracked and read nothing more until PUP is back.
        if (pt.was_pup) then
            pt.was_pup = false;
            reset_tracking();
            g.pet_present, g.pet_id, g.pet_name = false, 0, nil;
            g.maneuver_recast, g.maneuver_recast_at = 0, nil;
        end
        return;
    end
    pt.was_pup = true;
    if (pt.load_msg) then
        pt.load_msg = nil;
        if (not pt.settings.hud.locked and pt.settings.hud.visible) then
            msg('The timer window is unlocked and shows sample bars: drag it into place, resize it from the lower-right corner, then type /pupt lock. /pupt opens settings.');
        end
    end

    local info = poll_pet(now, g, ent, player);
    poll_gear(now);

    -- Recasts ----------------------------------------------------------------------------------
    local recasts = read_recasts(mm:GetRecast(), RECASTS);
    local mr = recasts[data.MANEUVER_TIMER_ID] or 0;
    g.maneuver_recast = mr;
    g.maneuver_recast_at = (mr > 0) and (now + mr) or nil;
    core.maneuver_recast(pt.state, mr, now);

    local counts = poll_maneuvers(now, g, player, info);
    poll_overload(now, g);
    poll_job_abilities(now, g, recasts);
    update_marks_and_hints(g, counts);
end

local function update_timers(now)
    local a = pt.settings.alerts;
    local fired = core.update_timers(pt.state, now, a.ready_hold, a.keep_ready);
    if (fired ~= nil) then
        for _, t in ipairs(fired) do
            local info = core.ability_info(pt.settings, t.of or t.key);
            -- Not for an ability turned off while its bar was running (test bars still alert).
            if (info == nil or (info.alert ~= false and (t.test or info.enabled ~= false))) then
                alert(('%s is ready!'):format(t.name or t.key), true);
            end
        end
    end
end

--[[
* The server's current Unix time as the client knows it, used to turn buff end times into seconds.
* Uses the same client clock XIUI reads on HorizonXI, checked against the PC clock; falls back to
* the PC clock (os.time) if it cannot be found or looks wrong.
--]]
local CLOCK_PATTERN = '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3';
local clock_ptr = nil;   -- nil = not searched yet, false = not available

function pt.server_time()
    local sys = os.time();
    if (clock_ptr == nil) then
        clock_ptr = false;
        pcall(function ()
            -- Ashita 4.16 takes the module name; 4.3 takes (0, 0) for the game module (as XIUI does).
            local ok, p = pcall(ashita.memory.find, 'FFXiMain.dll', 0, CLOCK_PATTERN, 2, 0);
            if (not ok or p == nil or p == 0) then
                ok, p = pcall(ashita.memory.find, 0, 0, CLOCK_PATTERN, 2, 0);
            end
            if (ok and p ~= nil and p ~= 0) then
                local a = ashita.memory.read_uint32(p);
                if (a ~= nil and a ~= 0) then
                    local b = ashita.memory.read_uint32(a);
                    if (b ~= nil and b ~= 0) then
                        clock_ptr = b;
                    end
                end
            end
        end);
    end
    if (clock_ptr) then
        local ok, v = pcall(ashita.memory.read_uint32, clock_ptr + 0x0C);
        if (ok and type(v) == 'number' and math.abs(v - sys) < 86400) then
            pt.clock_game = true;
            return v;
        end
    end
    pt.clock_game = false;
    return sys;
end

--[[
* Equipped item ids (for overload gear). Guarded: returns {} if the inventory API is unavailable.
--]]
function pt.read_equipped_ids()
    local ids = {};
    pcall(function ()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if (inv == nil) then
            return;
        end
        for slot = 0, 15 do
            local item = equipped_item(inv, slot);
            if (item ~= nil and item.Id ~= nil and item.Id ~= 0 and item.Id ~= -1 and item.Id ~= 65535) then
                ids[#ids + 1] = item.Id;
            end
        end
    end);
    return ids;
end

-- Rows + overload time left for the timer window.
function pt.overload_view(now)
    local o = pt.settings.overload;
    local left = ov.overload_left(pt.ov, now);   -- the OVERLOADED countdown works even with the bars off
    if (not o.enabled or not pt.game.is_pup) then
        return nil, left;
    end
    return ov.rows(pt.ov, now, pt.overload_params(), pt.settings), left;
end

----------------------------------------------------------------------------------------------------
-- Actions (used by commands and the settings window)
----------------------------------------------------------------------------------------------------

function pt.actions.clear()
    core.clear_timers(pt.state);
    pt.test_until = nil;
end

function pt.actions.reset_position()
    pt.settings.hud.x = DEFAULTS.hud.x;
    -- Growing upward, y is the bottom edge: put the top of the window where it would normally be.
    pt.settings.hud.y = DEFAULTS.hud.y + ((pt.settings.hud.grow == 'up') and math.max(ui.hud_h or 0, 120) or 0);
    pt.settings.hud.visible = true;
    ui.force_pos = true;
    pt.mark_dirty();
end

-- A sample bar for an ability, under its own key so a real cooldown that is running is left alone.
-- Test bars are dropped once their READY time has passed, even with "keep ready" on.
local function start_test_timer(key, cooldown, now, follow_alert)
    local info = core.ability_info(pt.settings, key);
    if (info == nil) then
        return false;
    end
    local k = 'test_' .. key;
    pt.state.timers[k] = nil;
    core.start_timer(pt.state, k, info.name .. ' (test)', cooldown, now, 0);
    local t = pt.state.timers[k];
    t.color = info.color;
    t.test = true;
    if (follow_alert) then
        t.of = key;   -- its ready alert follows this ability's Alert checkbox (read when it fires)
    end
    return true;
end

function pt.actions.test()
    local now = os.clock();
    pt.test_until = now + 15;
    -- Sample timers with short cooldowns so the ready alert can be seen and heard.
    start_test_timer('provoke', 4, now);
    start_test_timer('flashbulb', 8, now);
    start_test_timer('shock_absorber', 12, now);
    msg('Test running for 15 seconds: three sample abilities will become ready in 4, 8 and 12 seconds.' ..
        (pt.settings.hud.visible and '' or ' The timer window is hidden: /pupt show.'));
end

-- Test button on an ability's row: a sample bar with that ability's cooldown and colour.
function pt.actions.test_ability(key)
    local info = core.ability_info(pt.settings, key);
    return info ~= nil and start_test_timer(key, info.cooldown, os.clock(), true);
end

function pt.actions.add_custom(name, cooldown)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '');
    cooldown = math.floor(tonumber(cooldown) or 0);
    if (name == '') then
        return false, 'Enter the ability name first.';
    end
    if (cooldown <= 0) then
        return false, 'Enter a cooldown in seconds (greater than 0).';
    end
    local lname = name:lower();
    for _, info in ipairs(core.all_abilities(pt.settings)) do
        if (info.name:lower() == lname) then
            return false, ('%s is already in the list.'):format(info.name);
        end
    end
    local key = 'custom_' .. lname:gsub('[^%w]+', '_');
    pt.settings.custom[key] = { name = name, cooldown = cooldown, enabled = true, alert = true, on_spawn = false, color = { unpack(data.CUSTOM_COLOR) } };
    pt.unknown_seen[lname] = nil;
    pt.chat_ctx = nil;
    pt.mark_dirty();
    return true, ('Added %s (%ds).'):format(name, cooldown);
end

function pt.actions.remove_custom(key)
    if (pt.settings.custom[key] ~= nil) then
        pt.settings.custom[key] = nil;
        pt.state.timers[key] = nil;
        pt.state.timers['test_' .. key] = nil;
        pt.chat_ctx = nil;
        pt.mark_dirty();
    end
end

-- Every setting back to its default (the remembered automaton name is kept). The table is changed
-- in place, so the settings library keeps saving the same table.
-- After the settings were replaced or merged from elsewhere (reset, copy, profile): repair them and
-- refresh everything that caches them.
local function settings_replaced()
    sanitize(pt.settings);
    pt.chat_ctx = nil;
    ui.sync_buffers();
    ui.invalidate_caches();
    pt.mark_dirty();
end

function pt.actions.reset_all()
    local cfg = pt.settings;
    local last_pet = cfg.names and cfg.names.last_pet or '';
    local fresh = data.default_settings();
    fresh.names.last_pet = last_pet;
    for k in pairs(cfg) do
        cfg[k] = nil;
    end
    for k, v in pairs(fresh) do
        cfg[k] = v;
    end
    pt.load_msg = nil;
    ui.grow_fix = nil;
    ui.force_pos = true;
    settings_replaced();
end

----------------------------------------------------------------------------------------------------
-- Profiles: one file shared by every character (config\addons\puptimers\profiles.lua)
----------------------------------------------------------------------------------------------------

-- A whole file as text, or nil and a reason ('missing' or 'too large'); bigger files are not read.
local function read_file(path, limit)
    local f = io.open(path, 'rb');
    if (f == nil) then
        return nil, 'missing';
    end
    local size = f:seek('end');
    if (size == nil or size > limit) then
        f:close();
        return nil, 'too large';
    end
    f:seek('set', 0);
    local text = f:read('*a');
    f:close();
    return text or '';
end

local function profiles_folder()
    local base = tostring(AshitaCore:GetInstallPath() or ''):gsub('[\\/]+$', '');
    return ('%s\\config\\addons\\%s\\'):format(base, addon.name);
end

--[[
* The saved profiles, read from disk at most every 2 seconds (the settings window asks every frame;
* other game windows may change the file). An unchanged file is not parsed again. force: always a
* fresh table, for changing and writing back.
--]]
function pt.profiles_read(force)
    local now = os.clock();
    if (not force and pt.profiles_cache ~= nil and now < (pt.profiles_at or 0)) then
        return pt.profiles_cache;
    end
    pt.profiles_at = now + PROFILES_TTL;
    local text, why = read_file(profiles_folder() .. 'profiles.lua', profiles.MAX_FILE);
    if (not force and text ~= nil and text == pt.profiles_text and pt.profiles_cache ~= nil) then
        return pt.profiles_cache;
    end
    local t = { list = {} };
    pt.profiles_error = nil;
    if (text ~= nil) then
        local parsed, perr = profiles.parse(text);
        if (parsed ~= nil) then
            t = parsed;
        else
            pt.profiles_error = perr;
        end
    elseif (why ~= 'missing') then
        pt.profiles_error = why;
    end
    pt.profiles_text = text;
    pt.profiles_cache = t;
    return t;
end

--[[
* Written to a temporary file of this character's own (two game windows never share one), then moved
* over profiles.lua in one step (ashita.fs.rename replaces the old file). If anything fails, the old
* file is left as it was.
--]]
local function profiles_write(t)
    local folder = profiles_folder();
    pcall(ashita.fs.create_dir, folder);
    local path = folder .. 'profiles.lua';
    local tag = tostring(pt.game.player_name or ''):gsub('%W', '');
    local tmp = ('%s.%s.tmp'):format(path, (tag ~= '') and tag or 'pt');
    -- Whatever happens next, the cached copy may no longer match the file: read it again next time.
    pt.profiles_text, pt.profiles_cache = nil, nil;
    local f = io.open(tmp, 'wb');
    if (f == nil) then
        return false;
    end
    local text = profiles.serialize(t);
    local ok = (f:write(text) ~= nil);
    ok = (f:close() and ok) and true or false;
    if (not ok) then
        os.remove(tmp);
        return false;
    end
    local rok, moved = pcall(ashita.fs.rename, tmp, path);
    if (not (rok and moved)) then
        os.remove(tmp);
        return false;
    end
    pt.profiles_text, pt.profiles_cache = text, t;
    pt.profiles_at = os.clock() + PROFILES_TTL;
    return true;
end

-- Other characters with PupTimers settings: { name, file }, looked up at most every 5 seconds.
function pt.other_characters()
    local now = os.clock();
    if (pt.others_cache ~= nil and now < (pt.others_at or 0)) then
        return pt.others_cache;
    end
    pt.others_at = now + 5.0;
    local out = {};
    local root = profiles_folder();
    local ok, dirs = pcall(ashita.fs.get_directory, root);
    if (ok and type(dirs) == 'table') then
        local mine = tostring(pt.settings_folder or ''):lower():match('([^\\/]+)[\\/]*$');
        for _, d in ipairs(dirs) do
            d = tostring(d);
            local name = d:match('^(%a+)_%d+$');
            local file = root .. d .. '\\settings.lua';
            if (name ~= nil and d:lower() ~= mine and ashita.fs.exists(file)) then
                out[#out + 1] = { name = name, file = file };
            end
        end
        table.sort(out, function (a, b) return a.name < b.name; end);
    end
    pt.others_cache = out;
    return out;
end

-- Copies another character's settings (everything a profile holds) into this character's.
function pt.actions.copy_from(name)
    local want = tostring(name or ''):lower();
    pt.others_at = 0;
    for _, c in ipairs(pt.other_characters()) do
        if (c.name:lower() == want) then
            local text, ferr = read_file(c.file, profiles.MAX_SETTINGS);
            if (text == nil) then
                return false, ('Could not open the settings of %s (%s).'):format(c.name, ferr);
            end
            local t, why = profiles.read_settings_text(text);
            if (t == nil) then
                return false, ('Could not read the settings of %s (%s). If that character is logged in on another window, try again in a moment.'):format(c.name, tostring(why));
            end
            migrate(t);
            profiles.apply(pt.settings, profiles.snapshot(t));
            settings_replaced();
            return true, ('Copied the settings of %s (window position, the way new bars grow, and names stay as they are).'):format(c.name);
        end
    end
    return false, ('No PupTimers settings found for %s.'):format(tostring(name));
end

function pt.profiles_error_text()
    return ('The profiles file could not be read (%s), so it is left as it is. Fix or delete config\\addons\\puptimers\\profiles.lua to start again.'):format(tostring(pt.profiles_error));
end

-- The profiles, freshly read for changing and writing back; nil and why if the file is unreadable.
local function profiles_for_change()
    local t = pt.profiles_read(true);
    if (pt.profiles_error ~= nil) then
        return nil, pt.profiles_error_text();
    end
    return t;
end

-- The saved name meant by name: the exact one, or the only one that differs just in capitals.
local function profile_key(list, name)
    if (list[name] ~= nil) then
        return name;
    end
    local want, found = tostring(name or ''):lower(), nil;
    for k in pairs(list) do
        if (k:lower() == want) then
            if (found ~= nil) then
                return nil;   -- more than one: say there is no such profile
            end
            found = k;
        end
    end
    return found;
end

function pt.actions.profile_save(name)
    name = profiles.clean_name(name);
    if (name == nil) then
        return false, 'Type a name for the profile first.';
    end
    local t, why = profiles_for_change();
    if (t == nil) then
        return false, why;
    end
    name = profile_key(t.list, name) or name;   -- "tank" updates a saved "Tank" instead of adding a second
    local n = 0;
    for _ in pairs(t.list) do
        n = n + 1;
    end
    if (t.list[name] == nil and n >= profiles.MAX_PROFILES) then
        return false, 'Too many profiles: delete one first.';
    end
    t.list[name] = profiles.snapshot(pt.settings);
    if (not profiles_write(t)) then
        return false, 'Could not write the profiles file.';
    end
    pt.settings.profiles.last = name;
    pt.mark_dirty();
    return true, ('Saved profile "%s".'):format(name);
end

function pt.actions.profile_load(name)
    local t, why = profiles_for_change();
    if (t == nil) then
        return false, why;
    end
    local key = profile_key(t.list, name);
    if (key == nil) then
        return false, ('There is no profile "%s".'):format(tostring(name));
    end
    profiles.apply(pt.settings, t.list[key]);
    pt.settings.profiles.last = key;
    settings_replaced();
    return true, ('Loaded profile "%s".'):format(key);
end

-- Returns true and a message, or false and why not.
function pt.actions.profile_delete(name)
    local t, why = profiles_for_change();
    if (t == nil) then
        return false, why;
    end
    local key = profile_key(t.list, name);
    if (key == nil) then
        return false, ('There is no profile "%s".'):format(tostring(name));
    end
    name = key;
    t.list[name] = nil;
    if (not profiles_write(t)) then
        return false, 'Could not write the profiles file, so the profile was not deleted.';
    end
    -- Frames linked to it load nothing from now on (only once it is really gone).
    for k, v in pairs(pt.settings.profiles.frames) do
        if (v == name) then
            pt.settings.profiles.frames[k] = '';
        end
    end
    pt.mark_dirty();
    return true, ('Deleted profile "%s".'):format(name);
end

-- A colour scheme for the window, the elements and the automaton abilities (added abilities keep
-- their own colours).
function pt.actions.apply_palette(name)
    local p = data.palette(name);
    local cfg = pt.settings;
    for k, v in pairs(p.colors) do
        cfg.colors[k] = v;
    end
    for k, v in pairs(p.elements) do
        cfg.maneuvers.colors[k] = v;
    end
    for k, v in pairs(p.abilities) do
        if (cfg.abilities[k] ~= nil) then
            cfg.abilities[k].color = v;
        end
    end
    ui.invalidate_caches();
    pt.mark_dirty();
end

function pt.actions.restore_ability_defaults()
    local d = data.default_settings();
    for key, dv in pairs(d.abilities) do
        local s = pt.settings.abilities[key];
        if (s ~= nil) then
            s.cooldown = dv.cooldown;
            s.color = dv.color;
        end
    end
    pt.mark_dirty();
end

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

local function find_ability(text)
    local q = tostring(text or ''):lower():gsub('[^%w]', '');
    if (q == '') then
        return nil;
    end
    for _, info in ipairs(core.all_abilities(pt.settings)) do
        local n = info.name:lower():gsub('[^%w]', '');
        local k = info.key:lower():gsub('[^%w]', '');
        if (n == q or k == q) then
            return info;
        end
        for _, alias in ipairs(info.aliases or {}) do
            if (alias:lower():gsub('[^%w]', '') == q) then
                return info;
            end
        end
    end
    for _, info in ipairs(core.all_abilities(pt.settings)) do
        local n = info.name:lower():gsub('[^%w]', '');
        if (n:sub(1, #q) == q) then
            return info;
        end
    end
    return nil;
end

local function print_status()
    local g = pt.game;
    local cfg = pt.settings;
    msg(('PupTimers %s'):format(addon.version));
    msg(('Job: %s%s'):format(g.logged_in and g.job_text or 'not logged in', g.is_pup and '' or ' (not PUP: timers hidden)'));
    msg(('Player: %s %s'):format(pt.effective_player_name() ~= '' and pt.effective_player_name() or '?', cfg.names.player ~= '' and '(manual)' or '(auto)'));
    msg(('Automaton: %s %s, %s'):format(pt.effective_pet_name() ~= '' and pt.effective_pet_name() or '?', cfg.names.pet ~= '' and '(manual)' or '(auto)', g.pet_present and 'active' or 'not out'));
    msg(('Timer window: %s, %s.'):format(cfg.hud.visible and 'shown' or 'hidden (/pupt show)', cfg.hud.locked and 'locked' or 'unlocked (/pupt lock)'));
    msg(('Detection: packets %s, chat %s'):format(cfg.detect.packets and 'on' or 'off', cfg.detect.chat and 'on' or 'off'));
    local n = 0;
    for _ in pairs(pt.state.timers) do n = n + 1; end
    msg(('Running ability timers: %d, active maneuvers: %d'):format(n, #pt.state.man.list));
    local tm = cfg.maneuvers.timer_mode;
    local how;
    if (tm == 'game') then
        how = 'the game\'s buff timers';
    elseif (tm == 'flat') then
        how = ('a flat %ds'):format(tonumber(cfg.maneuvers.duration) or 60);
    elseif (pt.long_maneuvers) then
        how = ('auto: following the game\'s buff timers (a maneuver lasted %ds)'):format(math.floor((pt.long_seen or 0) + 0.5));
    else
        how = ('auto: a flat %ds so far'):format(tonumber(cfg.maneuvers.duration) or 60);
    end
    msg('Maneuver timers: ' .. how);
    local r = pt.ov.rules;
    if (pt.burden_rule ~= nil) then
        msg(('Burden per maneuver: from stats (%s server rule, matched the game %d times).%s'):format(pt.burden_rule == 'era' and 'current' or 'older', r[pt.burden_rule].n,
            stats_fresh() and '' or ' Your gear or buffs changed since the game last sent your stats, so until it sends them again the values learned from its reports are used (Dark Maneuvers excepted).'));
    else
        msg(('Burden per maneuver: learned from the game\'s reports (%d so far).'):format(r.learned.n));
    end
    if (pt.kit.known) then
        msg(('Automaton setup: %s, %s; attachments: %s.'):format(pt.kit.frame_name or '?', pt.kit.head_name or '?',
            (#pt.kit.attachment_names > 0) and table.concat(pt.kit.attachment_names, ', ') or 'none'));
    else
        msg('Automaton setup: not read yet (it arrives with zoning or your next maneuver).');
    end
    for part in pairs(pt.stopped) do
        msg(('Switched off after repeated errors: %s'):format(part));
    end
    if (pt.last_error ~= nil) then
        msg('Last error: ' .. pt.last_error);
    end
end

local function print_help()
    msg('Commands: /pupt (settings window), /pupt show|hide|toggle, /pupt lock|unlock, /pupt test, /pupt clear,');
    msg('  /pupt pet <name|auto>, /pupt player <name|auto>, /pupt start <ability>, /pupt resetpos,');
    msg('  /pupt profile [name | save <name> | delete <name>], /pupt copyfrom <character>,');
    msg('  /pupt status, /pupt debug,');
    msg('  /pupt defaults (every setting back to its default)');
end

-- What each guarded part does, for the error line players see.
local PART_NAMES = {
    actions = 'reading action data', status = 'reading buff timers', chat = 'reading chat lines',
    setup = 'reading the automaton setup', stats = 'reading your stats',
    poll = 'reading the game', timers = 'updating timers', render = 'drawing its windows',
    settings = 'checking settings', save = 'saving settings', frame = 'running',
    command = 'running a /pupt command',
};
-- Parts that are switched off after repeated errors: each has a backup (action data <-> chat).
local STOPPABLE = { actions = true, chat = true };

--[[
* Runs fn. An error is reported in one plain line, then at most once a minute per part (every 10 s
* with /pupt debug on, with the full text); the last one is kept for /pupt status.
--]]
local function guarded(name, fn, ...)
    if (pt.stopped[name]) then
        return;
    end
    local ok, err = pcall(fn, ...);
    if (not ok) then
        local now = os.clock();
        local n = (pt.error_counts[name] or 0) + 1;
        pt.error_counts[name] = n;
        pt.last_error = ('%s: %s'):format(name, tostring(err));
        local what = PART_NAMES[name] or name;
        if (STOPPABLE[name] and n >= 20) then
            pt.stopped[name] = true;
            print(chat.header('PupTimers'):append(chat.error(('Stopped %s after repeated problems; everything else keeps working. Reload PupTimers to try again: /addon reload puptimers (/pupt status shows the last error).'):format(what))));
            return;
        end
        local dbg = pt.settings ~= nil and pt.settings.behavior.debug;
        if ((now - (pt.errors_at[name] or -100)) > (dbg and 10 or 60)) then
            pt.errors_at[name] = now;
            local text = tostring(err);
            if (not dbg) then
                text = text:match('[^\n]*'):sub(1, 120);
            end
            print(chat.header('PupTimers'):append(chat.error(('A problem %s (%s). PupTimers keeps running.'):format(what, text))));
        end
    end
end

-- /pupt <sub> <rest>
local function run_command(sub, rest)
    if (sub == '' or sub == 'config' or sub == 'settings' or sub == 'menu' or sub == 'gui') then
        ui.toggle_config();
    elseif (sub == 'show' or sub == 'hide' or sub == 'toggle') then
        local hud = pt.settings.hud;
        if (sub == 'toggle') then
            hud.visible = not hud.visible;
        else
            hud.visible = (sub == 'show');
        end
        pt.mark_dirty();
        if (not hud.visible) then
            msg('Timer window hidden. /pupt show brings it back.');
        elseif (hud.only_on_pup and not pt.game.is_pup) then
            msg('Timer window shown on Puppetmaster. On other jobs it shows only while unlocked with the settings window open (/pupt unlock).');
        else
            msg((hud.locked and hud.hide_when_empty) and 'Timer window shown (it appears while something is running).' or 'Timer window shown.');
        end
    elseif (sub == 'lock') then
        local hud = pt.settings.hud;
        hud.locked = true;
        ui.force_pos = true;
        pt.mark_dirty();
        msg((not hud.visible) and 'Timer window locked. It is hidden: /pupt show brings it back.'
            or hud.hide_when_empty and 'Timer window locked: it now shows only while something is running. /pupt unlock to move it again.'
            or 'Timer window locked. /pupt unlock to move it again.');
    elseif (sub == 'unlock') then
        pt.settings.hud.locked = false;
        pt.settings.hud.visible = true;
        ui.force_pos = true;
        pt.mark_dirty();
        if (not pt.game.is_pup and pt.settings.hud.only_on_pup) then
            -- On other jobs the window only shows while the settings window is open: open it.
            ui.toggle_config(true);
            msg('Timer window unlocked. You are not on Puppetmaster, so it only shows while the settings window is open (opened for you). /pupt lock when done.');
        else
            msg('Timer window unlocked: drag it to move it, drag its lower-right corner to resize. /pupt lock when done.');
        end
    elseif (sub == 'test' or sub == 'demo') then
        pt.actions.test();
    elseif (sub == 'clear' or sub == 'reset') then
        pt.actions.clear();
        msg('Timers cleared.');
    elseif (sub == 'resetpos') then
        pt.actions.reset_position();
        msg('Timer window moved back on screen.');
    elseif (sub == 'pet' or sub == 'player') then
        local key = (sub == 'pet') and 'pet' or 'player';
        local what = (key == 'pet') and 'Automaton' or 'Player';
        if (rest == '') then
            local name = (key == 'pet') and pt.effective_pet_name() or pt.effective_player_name();
            msg(('%s name: %s (%s). /pupt %s <name> sets it, /pupt %s auto detects it.'):format(what, (name ~= '') and name or '?',
                (pt.settings.names[key] ~= '') and 'set by hand' or 'auto-detect', key, key));
        else
            pt.settings.names[key] = (rest:lower() == 'auto') and '' or rest;
            pt.names_changed();
            ui.sync_buffers();
            pt.mark_dirty();
            msg(('%s name: %s'):format(what, (pt.settings.names[key] ~= '') and pt.settings.names[key] or 'auto-detect'));
        end
    elseif (sub == 'start') then
        local info = find_ability(rest);
        if (rest == '') then
            msg('Usage: /pupt start <ability>, for example /pupt start economizer');
        elseif (info == nil) then
            msg(('Unknown ability: %s. The names are on the Automaton tab (/pupt).'):format(rest));
        elseif (info.enabled == false) then
            msg(('%s is turned off on the Automaton tab (/pupt).'):format(info.name));
        else
            pt.state.timers[info.key] = nil;
            start_ability(info.key, 'manual', os.clock());
        end
    elseif (sub == 'status') then
        print_status();
    elseif (sub == 'profile') then
        if (rest == '') then
            local names = {};
            for name in pairs(pt.profiles_read(true).list) do
                names[#names + 1] = name;
            end
            table.sort(names);
            if (pt.profiles_error ~= nil) then
                msg(pt.profiles_error_text());
            else
                msg((#names > 0) and ('Profiles: ' .. table.concat(names, ', ') .. '. /pupt profile <name> loads one.') or 'No profiles saved yet: /pupt opens settings -> Profiles.');
            end
        else
            local verb, name = rest:match('^(%S+)%s+(.+)$');
            verb = verb and verb:lower();
            if (rest:lower() == 'save' or rest:lower() == 'delete') then
                msg(('Type a name: /pupt profile %s <name>'):format(rest:lower()));
            elseif (verb == 'save') then
                local _, text = pt.actions.profile_save(name);
                msg(text);
            elseif (verb == 'delete') then
                local _, text = pt.actions.profile_delete(name);
                msg(text);
            else
                local _, text = pt.actions.profile_load(rest);
                msg(text);
            end
        end
    elseif (sub == 'copyfrom') then
        if (rest == '') then
            msg('Usage: /pupt copyfrom <character name>');
        else
            local _, text = pt.actions.copy_from(rest);
            msg(text);
        end
    elseif (sub == 'defaults') then
        pt.actions.reset_all();
        msg('All settings are back to their defaults. The timer window is unlocked: drag it into place, then /pupt lock.');
    elseif (sub == 'debug') then
        pt.settings.behavior.debug = not pt.settings.behavior.debug;
        pt.mark_dirty();
        msg(('Debug messages %s.'):format(pt.settings.behavior.debug and 'on' or 'off'));
    else
        print_help();
    end
end

ashita.events.register('command', 'puptimers_command', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end
    local c = args[1]:lower();
    if (c ~= '/pupt' and c ~= '/puptimers') then
        return;
    end
    e.blocked = true;   -- only PupTimers' own command is ever blocked
    guarded('command', run_command, (args[2] or ''):lower(), table.concat(args, ' ', 3));
end);

----------------------------------------------------------------------------------------------------
-- Game events
----------------------------------------------------------------------------------------------------

-- Status timers (0x063): the real end time of every buff, including maneuvers and Overload.
local function on_status_packet(e)
    if (not pt.game.is_pup) then
        return;
    end
    local list = core.parse_status_timers(e.data_modified or e.data);
    if (list == nil) then
        return;
    end
    local now = os.clock();
    local ends = core.buff_end_times(list, pt.server_time(), now);
    pt.buff_ends = ends;
    pt.buff_ends_at = (ends ~= nil) and now or nil;
end

-- Action packets (0x028). Every action of every player and monster nearby arrives here, so the
-- actor id (bytes 5-8) is checked first and only our own and our automaton's actions are parsed.
local function on_action_packet(e)
    local g = pt.game;
    if (not g.is_pup or not pt.settings.detect.packets) then
        return;
    end
    local bytes = e.data_modified or e.data;
    if (type(bytes) ~= 'string') then
        return;
    end
    local b1, b2, b3, b4 = bytes:byte(6, 9);
    if (b4 == nil) then
        return;
    end
    local actor = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216;
    if (actor == 0 or (actor ~= g.player_id and actor ~= g.pet_id)) then
        return;
    end
    local act = core.parse_action(bytes);
    if (act ~= nil and actor == g.pet_id) then
        -- For the used-up notes: Flame Holder fires on weapon skills, Ice Maker on elemental nukes.
        local c, prm = act.category, act.param or 0;
        if (c == 11 and data.automaton_ws[prm] ~= nil) then
            pt.pet_ws_at = os.clock();
        elseif (c == 4 and prm >= data.NUKE_FIRST and prm <= data.NUKE_LAST) then
            pt.pet_nuke_at = os.clock();
        end
    end
    local ev = core.interpret_action(act, g.player_id, g.pet_id);
    if (ev ~= nil) then
        handle_event(ev, 'packet', os.clock());
    end
end

--[[
* What the automaton's setup means for PupTimers: frame, attachments that matter, and which of the
* automaton abilities it can use. Rebuilt only when the head, frame or attachments change.
--]]
local function rebuild_kit()
    local st = pt.setup;
    local kit = { known = true, abilities = {}, attachment_names = {} };
    local f = data.frame_by_byte[st.frame];
    kit.frame_key = f and f.key or nil;
    kit.frame_name = f and f.name or nil;
    kit.head_name = data.heads[st.head];
    for name, byte in pairs(data.ATT) do
        kit[name] = setup.has(st, byte);
    end
    for _, a in ipairs(data.abilities) do
        if (a.att ~= nil) then
            kit.abilities[a.key] = setup.has(st, a.att);
        elseif (a.frame ~= nil) then
            kit.abilities[a.key] = (st.frame == a.frame);
        end
    end
    for i = 1, 12 do
        local b = st.slots[i];
        if (b ~= 0) then
            kit.attachment_names[#kit.attachment_names + 1] = data.attachments[b] or ('#' .. b);
        end
    end
    pt.kit = kit;
    pt.unpowered_key = nil;
    debug(('Automaton setup: %s, %s; %s.'):format(kit.frame_name or '?', kit.head_name or '?',
        (#kit.attachment_names > 0) and table.concat(kit.attachment_names, ', ') or 'no attachments'));
    -- Profiles that follow the frame.
    if (kit.frame_key ~= nil and kit.frame_key ~= pt.kit_frame) then
        local first = (pt.kit_frame == nil);
        pt.kit_frame = kit.frame_key;
        local pc = pt.settings.profiles;
        local name = pc.frames[kit.frame_key];
        if (pc.auto and type(name) == 'string' and name ~= '' and not (first and name == pc.last)) then
            local ok, text = pt.actions.profile_load(name);
            msg(ok and ('%s: loaded profile "%s".'):format(kit.frame_name, name) or text);
        end
    end
end

-- Packet 0x044: the automaton's setup, HP/MP and stats (see pt_setup.lua).
local function on_setup_packet(e)
    local g = pt.game;
    if (not g.is_pup) then
        return;
    end
    local d = e.data_modified or e.data;
    if (type(d) ~= 'string' or #d < setup.MIN_SIZE or d:byte(5) ~= setup.PUP_JOB) then
        return;
    end
    -- PUP as the main job: the main-job copy; PUP as the support job: the support-job copy.
    if ((d:byte(6) == 1) == g.main_is_pup) then
        return;
    end
    local ok, changed = setup.parse(pt.setup, d);
    if (ok and changed) then
        rebuild_kit();
    end
end

ashita.events.register('packet_in', 'puptimers_packet_in', function (e)
    local id = e.id;
    if (id == 0x0028) then
        guarded('actions', on_action_packet, e);
    elseif (id == 0x0063) then
        guarded('status', on_status_packet, e);
    elseif (id == 0x0044) then
        guarded('setup', on_setup_packet, e);
    elseif (id == 0x0061) then
        guarded('stats', on_stats_packet, e);
    end
end);

-- Chat lines. Every line of every chat mode arrives here; cheap plain-text checks discard almost
-- all of them before anything is parsed.
-- Conversation channels, incoming and your own echo (say 9/1, shout 10/2, yell 11/3, tell 12/4,
-- party 13/5, linkshell 14/6, emote 15/7, linkshell 2 214/213, unity 212/211, assist 220/219 and
-- 222/221, party/alliance 215). Whatever a line there says (an /em, a joke in party chat), it is not
-- a maneuver or an automaton ability. Anything else is read, so an unknown battle-log mode is never lost.
local TALK = {
    [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true,
    [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
    [211] = true, [212] = true, [213] = true, [214] = true, [215] = true,
    [219] = true, [220] = true, [221] = true, [222] = true,
};

local function on_text(e)
    if (not pt.game.is_pup or not pt.settings.detect.chat) then
        return;
    end
    local mode = tonumber(e.mode);
    if (mode ~= nil and TALK[bit.band(mode, 0xFF)]) then
        return;
    end
    local line = e.message;
    if (type(line) ~= 'string') then
        line = e.message_modified;
        if (type(line) ~= 'string') then
            return;
        end
    end
    if (not (line:find('uses', 1, true) or line:find('overload', 1, true))) then
        return;
    end
    local ctx = chat_context();
    -- Must mention our automaton or us.
    if (not ((ctx.pet_pattern ~= nil and line:find(ctx.pet_pattern)) or
             (ctx.player_pattern ~= nil and line:find(ctx.player_pattern)))) then
        return;
    end
    local ev = core.parse_chat(line, ctx);
    if (ev ~= nil) then
        handle_event(ev, 'chat', os.clock());
    end
end

ashita.events.register('text_in', 'puptimers_text_in', function (e)
    if (e.injected == true) then
        return;
    end
    guarded('chat', on_text, e);
end);

-- Each part has its own guard, so a problem reading the game cannot hide the windows (and the
-- settings window stays usable to turn things off).
local function on_present()
    local now = os.clock();
    if (now >= (pt.settings_check_at or 0)) then
        pt.settings_check_at = now + 2.0;
        guarded('settings', check_settings_switch);
    end
    if (now >= pt.next_poll) then
        pt.next_poll = now + POLL_INTERVAL;
        guarded('poll', poll, now);
        guarded('timers', update_timers, now);
    end
    if (pt.test_until ~= nil and now >= pt.test_until) then
        pt.test_until = nil;
    end
    guarded('render', ui.render, now);
    if (pt.dirty_at ~= nil and (now - pt.dirty_at) >= SAVE_DELAY) then
        guarded('save', pt.save_now);
    end
end

ashita.events.register('d3d_present', 'puptimers_present', function ()
    guarded('frame', on_present);
end);

ui.init(pt);

settings.register('settings', 'puptimers_settings_update', function (s)
    if (s ~= nil) then
        pt.settings = s;
    end
    pt.settings_folder = current_settings_folder();
    unshare(pt.settings, DEFAULTS);
    migrate(pt.settings);
    sanitize(pt.settings);
    reset_tracking();
    pt.ov_params = nil;
    pt.zone_end = nil;
    pt.zone_had_pet = nil;
    pt.unknown_seen = {};
    pt.chat_ctx = nil;
    pt.test_until = nil;
    pt.load_msg = true;   -- this character's first time on PUP this session: the unlocked hint again
    ui.grow_fix = nil;
    ui.force_pos = true;
    ui.sync_buffers();
    settings.save();
end);


ashita.events.register('unload', 'puptimers_unload', function ()
    pcall(check_settings_switch);
    pcall(settings.save);
end);
