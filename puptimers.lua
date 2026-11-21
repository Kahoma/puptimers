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
addon.version = '1.0.0';
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

local POLL_INTERVAL = 0.1;   -- seconds between reads of buffs / recasts / pet
local SAVE_DELAY    = 1.0;   -- seconds to wait after the last change before writing settings
local PET_GRACE     = 3.0;   -- seconds the automaton must be gone before it counts as deactivated

local pt = {
    settings = nil,
    state    = core.new_state(),
    ov       = ov.new(),           -- overload / burden estimator
    ov_last  = nil,                -- { el, time } last maneuver fed to the estimator (dedupe)
    gear     = { thresh = 0, suppress = false, items = {}, wearing = {}, checked_at = -100 },
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
};

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

-- Repairs missing / wrongly typed values (e.g. after a hand edit) without touching valid ones.
local function sanitize(cfg)
    local d = data.default_settings();
    for section, dv in pairs(d) do
        if (type(dv) == 'table' and type(rawget(cfg, section)) ~= 'table') then
            cfg[section] = dv;
        end
    end
    for _, section in ipairs({ 'hud', 'colors', 'names', 'detect', 'maneuvers', 'overload', 'alerts', 'behavior' }) do
        for k, v in pairs(d[section]) do
            if (type(cfg[section][k]) ~= type(v)) then
                cfg[section][k] = v;
            end
        end
    end
    for k, v in pairs(d.maneuvers.colors) do
        if (type(cfg.maneuvers.colors[k]) ~= 'table') then
            cfg.maneuvers.colors[k] = v;
        end
    end
    for key, dv in pairs(d.abilities) do
        local s = cfg.abilities[key];
        if (type(s) ~= 'table') then
            cfg.abilities[key] = dv;
        else
            for k, v in pairs(dv) do
                if (type(s[k]) ~= type(v)) then
                    s[k] = v;
                end
            end
        end
    end
    for key, c in pairs(cfg.custom) do
        if (type(c) ~= 'table' or type(c.name) ~= 'string' or c.name == '') then
            cfg.custom[key] = nil;
        else
            c.cooldown = tonumber(c.cooldown) or 60;
            if (type(c.enabled) ~= 'boolean') then c.enabled = true; end
            if (type(c.alert) ~= 'boolean') then c.alert = true; end
            if (type(c.on_spawn) ~= 'boolean') then c.on_spawn = false; end
            if (type(c.color) ~= 'table') then c.color = { 0.85, 0.65, 0.20, 1.0 }; end
        end
    end
    if (type(cfg.overload.gear) ~= 'table') then
        cfg.overload.gear = d.overload.gear;
    end
    for key, dv in pairs(d.overload.gear) do
        local g = cfg.overload.gear[key];
        if (type(g) ~= 'table') then
            cfg.overload.gear[key] = dv;
        else
            if (type(g.count) ~= 'boolean') then g.count = dv.count; end
            if (type(g.worn_only) ~= 'boolean') then g.worn_only = dv.worn_only; end
        end
    end
    for key, dv in pairs(d.jobabilities) do
        local s = cfg.jobabilities[key];
        if (type(s) ~= 'table') then
            cfg.jobabilities[key] = dv;
        else
            for k, v in pairs(dv) do
                if (type(s[k]) ~= type(v)) then
                    s[k] = v;
                end
            end
        end
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
pt.check_settings_switch = check_settings_switch;

function pt.mark_dirty()
    pt.dirty_at = os.clock();
end

function pt.save_now()
    pt.dirty_at = nil;
    pt.check_settings_switch();
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

-- Heatsink (Water attachment) burden decay by active Water Maneuvers (LandSandBoat 2021-2023).
local HEATSINK_DECAY = { [0] = 2, 4, 5, 6 };

local function overload_params(out)
    local o = pt.settings.overload;
    local thresh, decay, suppress = 0, 0, false;
    thresh = thresh + (pt.gear.thresh or 0);
    suppress = (pt.gear.suppress == true);
    if (o.heatsink) then
        local water = 0;
        for _, m in ipairs(pt.state.man.list) do
            if (m.el == 6) then
                water = water + 1;
            end
        end
        decay = decay + (HEATSINK_DECAY[math.min(water, 3)] or 2);
    end
    if (o.tactical_processor) then
        thresh = thresh - 5;
    end
    thresh = thresh + (tonumber(o.extra_threshold) or 0);
    decay = decay + (tonumber(o.extra_decay) or 0);
    return ov.params(pt.settings, thresh, decay, suppress, pt.state.man.overdrive == true, out);
end

-- The parameters worked out by the last poll (fresh ones if there was no poll yet).
function pt.overload_params()
    return pt.ov_params or overload_params();
end

-- One maneuver can be reported by the action packet, the chat log and the recast timer; the estimator
-- must count it once, but use the overload chance from whichever source carries it.
local function feed_overload(el, now, report, source)
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
    ov.on_maneuver(pt.ov, el, now, p, report);
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
                (pt.game.pet_id ~= 0 or not pt.game.pet_present)) then
            -- The packets already report this ability for our automaton, picked out by its id. The
            -- chat line adds nothing and may come from another automaton with the same name (always
            -- the case while ours is not out).
            return;
        end
        start_ability(ev.key, source, now);
    elseif (ev.kind == 'maneuver') then
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
            pt.ov.overload_el = last.el;
            if (last.chance ~= nil and pt.ov.overload_until == nil) then
                pt.ov.overload_until = last.time + math.max(0, last.chance - 5);
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

local function on_pet_spawn(now)
    local started = {};
    for _, info in ipairs(core.all_abilities(pt.settings)) do
        if (info.on_spawn and info.enabled ~= false) then
            if (core.start_timer(pt.state, info.key, info.name, info.spawn_cooldown or info.cooldown, now, 0)) then
                started[#started + 1] = info.name;
            end
        end
    end
    debug(('Automaton activated: %s.%s'):format(pt.game.pet_name or '?', (#started > 0) and (' Started: ' .. table.concat(started, ', ')) or ''));
end

--[[
* A new automaton exists: Activate / Deus Ex Automata (activated = true), or the one the server
* re-creates after zoning. Its burden starts from scratch in every element. Several signals can
* report the same activation (the automaton appearing, a new entity id, the Activate recast
* starting), so an activation is handled once per 3 seconds.
--]]
local function automaton_spawned(now, activated)
    if (activated and pt.spawned_at ~= nil and (now - pt.spawned_at) < 3.0) then
        pt.spawn_pending = nil;   -- another signal for the activation already handled
        return;
    end
    pt.spawned_at = now;
    pt.spawn_pending = nil;
    -- The server builds a brand-new automaton every time (Activate, Deus Ex Automata, zoning), with
    -- every ability ready, so the old automaton's cooldown bars no longer apply.
    if (pt.settings.behavior.reset_on_despawn) then
        core.clear_timers(pt.state);
    end
    if (activated) then
        on_pet_spawn(now);
    else
        debug('Zoned: overload estimate and ability timers reset for the re-created automaton.');
    end
    ov.on_spawn(pt.ov, now, pt.overload_params());
end

-- Zoning (or logged out). Remember whether an automaton was out: only then does the server
-- re-create one after the zone.
local function mark_zoning()
    if (not pt.zoned) then
        pt.zoned = true;
        pt.zone_had_pet = (pt.state.pet.present == true);
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

    -- Automaton --------------------------------------------------------------------------------
    local info = nil;
    if (g.is_pup) then
        local idx = ent.PetTargetIndex;
        if (idx ~= nil and idx ~= 0) then
            local pet = GetEntity(idx);
            if (pet ~= nil) then
                local name = pet.Name;
                if (type(name) == 'string' and name ~= '') then
                    PETINFO.name = name;
                    PETINFO.id = pet.ServerId or 0;
                    info = PETINFO;
                end
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
    if (info ~= nil and info.name ~= pt.settings.names.last_pet) then
        pt.settings.names.last_pet = info.name;
        pt.chat_ctx = nil;
        pt.mark_dirty();
    end
    local after_zone = (pt.zone_end ~= nil and pt.zone_had_pet and (now - pt.zone_end) < 10.0);
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
    if (pt.zone_end ~= nil and (now - pt.zone_end) >= 10.0) then
        pt.zone_end = nil;
    end
    if (pt.spawn_pending ~= nil and (now - pt.spawn_pending) > 5.0) then
        pt.spawn_pending = nil;
    end

    -- Gear that changes burden / overload (checked every 2 seconds) ---------------------------
    if ((now - pt.gear.checked_at) >= 2.0) then
        pt.gear.checked_at = now;
        local ids = pt.read_equipped_ids();
        local thresh, suppress, counted, wearing = gear.totals(ids, pt.settings);
        pt.gear.thresh, pt.gear.suppress, pt.gear.items, pt.gear.wearing = thresh, suppress, counted, wearing;
        ov.set_suppress(pt.ov, suppress);
    end

    -- Recasts ----------------------------------------------------------------------------------
    local recasts = read_recasts(mm:GetRecast(), RECASTS);
    local mr = recasts[data.MANEUVER_TIMER_ID] or 0;
    g.maneuver_recast = mr;
    g.maneuver_recast_at = (mr > 0) and (now + mr) or nil;
    core.maneuver_recast(pt.state, mr, now);

    -- Maneuvers (buff bar is the source of truth) ----------------------------------------------
    local counts, overload, overdrive = core.count_maneuvers(player:GetBuffs(), COUNTS);
    if (overload and not pt.state.man.overload) then
        debug('Overloaded!');
    elseif (not overload and pt.state.man.overload) then
        pt.ov.overload_until = nil;
    end
    pt.state.man.overload = overload;
    pt.state.man.overdrive = overdrive;
    local duration = tonumber(pt.settings.maneuvers.duration) or 60;
    local removed = core.maneuver_sync(pt.state, counts, now, data.MAX_MANEUVERS, duration);
    core.apply_buff_ends(pt.state, pt.buff_ends, now, not pt.settings.maneuvers.real_timers, pt.settings.maneuvers.duration);
    if (overload and pt.buff_ends ~= nil and pt.buff_ends.overload ~= nil) then
        pt.ov.overload_until = pt.buff_ends.overload;   -- exact, from the game's buff timer
    end
    if (removed ~= nil and pt.settings.maneuvers.enabled and pt.settings.maneuvers.alert_wear and not overload) then
        for _, r in ipairs(removed) do
            -- Only maneuvers that ran out: not ones a new maneuver pushed out, and not ones that
            -- zoning, a KO or a job change took away early.
            local ends = r.ends or ((not r.unknown) and (r.start + duration) or nil);
            if (not r.replaced and ends ~= nil and now >= ends - 3) then
                alert(('%s Maneuver wore off.'):format(data.elements[r.el].name), true);
            end
        end
    end

    -- Overload parameters for this poll (Heatsink depends on the Water maneuvers just counted).
    -- When the cooling rate changes, the burden so far is fixed at the old rate first.
    local prev = pt.ov_params;
    local p_now = overload_params((prev == PARAMS[1]) and PARAMS[2] or PARAMS[1]);
    if (prev ~= nil and prev.decay ~= p_now.decay) then
        ov.rebase(pt.ov, now, prev);
    end
    pt.ov_params = p_now;

    -- Job abilities ----------------------------------------------------------------------------
    local fired, started = core.update_job_abilities(pt.state, data.job_abilities, recasts, now, g.main_is_pup);
    if (fired ~= nil) then
        for _, def in ipairs(fired) do
            local opt = pt.settings.jobabilities[def.key];
            if (opt ~= nil and opt.alert and g.is_pup) then
                alert(('%s is ready.'):format(def.name), true);
            end
        end
    end
    if (started ~= nil and g.is_pup) then
        for _, def in ipairs(started) do
            -- Confirmed on a later poll once an automaton is out, unless the automaton that just
            -- appeared already accounted for this activation.
            if (def.spawns and (pt.spawned_at == nil or (now - pt.spawned_at) >= 3.0)) then
                pt.spawn_pending = now;
            end
        end
    end
end

local function update_timers(now)
    local a = pt.settings.alerts;
    local fired = core.update_timers(pt.state, now, a.ready_hold, a.keep_ready);
    if (fired ~= nil) then
        for _, t in ipairs(fired) do
            local info = core.ability_info(pt.settings, t.of or t.key);
            if (info == nil or info.alert ~= false) then
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
            local p = ashita.memory.find('FFXiMain.dll', 0, CLOCK_PATTERN, 2, 0);
            if (p ~= nil and p ~= 0) then
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
            return v;
        end
    end
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
            local eq = inv:GetEquippedItem(slot);
            local packed = eq and eq.Index or 0;
            if (packed ~= nil and packed ~= 0) then
                local container = bit.rshift(bit.band(packed, 0xFF00), 8);
                local index = bit.band(packed, 0x00FF);
                local item = inv:GetContainerItem(container, index);
                if (item ~= nil and item.Id ~= nil and item.Id ~= 0 and item.Id ~= -1 and item.Id ~= 65535) then
                    ids[#ids + 1] = item.Id;
                end
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

function pt.actions.start_ability(key, source)
    return start_ability(key, source or 'manual', os.clock());
end

function pt.actions.clear()
    core.clear_timers(pt.state);
    pt.test_until = nil;
end

function pt.actions.reset_position()
    pt.settings.hud.x = 120;
    pt.settings.hud.y = 260;
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
    msg('Test running for 15 seconds: three sample abilities will become ready in 4, 8 and 12 seconds.');
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
    pt.settings.custom[key] = { name = name, cooldown = cooldown, enabled = true, alert = true, on_spawn = false, color = { 0.85, 0.65, 0.20, 1.0 } };
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
    msg(('Job: %s%s'):format(g.logged_in and g.job_text or 'not logged in', g.is_pup and '' or ' (not PUP: timers hidden)'));
    msg(('Player: %s %s'):format(pt.effective_player_name() ~= '' and pt.effective_player_name() or '?', cfg.names.player ~= '' and '(manual)' or '(auto)'));
    msg(('Automaton: %s %s, %s'):format(pt.effective_pet_name() ~= '' and pt.effective_pet_name() or '?', cfg.names.pet ~= '' and '(manual)' or '(auto)', g.pet_present and 'active' or 'not out'));
    msg(('Detection: packets %s, chat %s'):format(cfg.detect.packets and 'on' or 'off', cfg.detect.chat and 'on' or 'off'));
    local n = 0;
    for _ in pairs(pt.state.timers) do n = n + 1; end
    msg(('Running ability timers: %d, active maneuvers: %d'):format(n, #pt.state.man.list));
end

local function print_help()
    msg('Commands: /pupt (settings window), /pupt show|hide, /pupt lock|unlock, /pupt test, /pupt clear,');
    msg('  /pupt pet <name|auto>, /pupt player <name|auto>, /pupt start <ability>, /pupt resetpos, /pupt status, /pupt debug');
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
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    local rest = table.concat(args, ' ', 3);

    if (sub == '' or sub == 'config' or sub == 'settings' or sub == 'menu' or sub == 'gui') then
        ui.toggle_config();
    elseif (sub == 'show') then
        pt.settings.hud.visible = true;
        pt.mark_dirty();
    elseif (sub == 'hide') then
        pt.settings.hud.visible = false;
        pt.mark_dirty();
    elseif (sub == 'toggle') then
        pt.settings.hud.visible = not pt.settings.hud.visible;
        pt.mark_dirty();
    elseif (sub == 'lock') then
        pt.settings.hud.locked = true;
        ui.force_pos = true;
        pt.mark_dirty();
        msg('Timer window locked.');
    elseif (sub == 'unlock') then
        pt.settings.hud.locked = false;
        pt.settings.hud.visible = true;
        ui.force_pos = true;
        pt.mark_dirty();
        msg('Timer window unlocked: drag it to move it, drag its lower-right corner to resize. /pupt lock when done.');
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
        if (rest == '' or rest:lower() == 'auto') then
            pt.settings.names[key] = '';
        else
            pt.settings.names[key] = rest;
        end
        pt.names_changed();
        ui.sync_buffers();
        pt.mark_dirty();
        msg(('%s name: %s'):format((key == 'pet') and 'Automaton' or 'Player', (pt.settings.names[key] ~= '') and pt.settings.names[key] or 'auto-detect'));
    elseif (sub == 'start') then
        local info = find_ability(rest);
        if (info == nil) then
            msg(('Unknown ability: %s'):format(rest));
        else
            pt.state.timers[info.key] = nil;
            start_ability(info.key, 'manual', os.clock());
        end
    elseif (sub == 'status') then
        print_status();
    elseif (sub == 'debug') then
        pt.settings.behavior.debug = not pt.settings.behavior.debug;
        pt.mark_dirty();
        msg(('Debug messages %s.'):format(pt.settings.behavior.debug and 'on' or 'off'));
    else
        print_help();
    end
end);

----------------------------------------------------------------------------------------------------
-- Game events
----------------------------------------------------------------------------------------------------

-- Runs fn, reporting errors at most once every 10 seconds per event instead of every frame.
local function guarded(name, fn, ...)
    local ok, err = pcall(fn, ...);
    if (not ok) then
        local now = os.clock();
        if ((now - (pt.errors_at[name] or -100)) > 10) then
            pt.errors_at[name] = now;
            print(chat.header('PupTimers'):append(chat.error(('%s error: %s'):format(name, tostring(err)))));
        end
    end
end

-- Status timers (0x063): the real end time of every buff, including maneuvers and Overload.
local function on_status_packet(e)
    local list = core.parse_status_timers(e.data_modified or e.data);
    if (list == nil) then
        return;
    end
    local ends = core.buff_end_times(list, pt.server_time(), os.clock());
    pt.buff_ends = ends;
    if (ends == nil) then
        pt.buff_ends_rejected = (pt.buff_ends_rejected or 0) + 1;
    end
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
    local ev = core.interpret_action(core.parse_action(bytes), g.player_id, g.pet_id);
    if (ev ~= nil) then
        handle_event(ev, 'packet', os.clock());
    end
end

ashita.events.register('packet_in', 'puptimers_packet_in', function (e)
    local id = e.id;
    if (id == 0x0028) then
        guarded('packet', on_action_packet, e);
    elseif (id == 0x0063) then
        guarded('packet', on_status_packet, e);
    end
end);

-- Chat lines. Every line of every chat mode arrives here; cheap plain-text checks discard almost
-- all of them before anything is parsed.
local function on_text(e)
    if (not pt.game.is_pup or not pt.settings.detect.chat) then
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
    sanitize(pt.settings);
    pt.state = core.new_state();
    pt.buff_ends = nil;
    pt.ov = ov.new();
    pt.ov_last = nil;
    pt.ov_params = nil;
    pt.spawned_at = nil;
    pt.spawn_pending = nil;
    pt.zone_end = nil;
    pt.zone_had_pet = nil;
    pt.unknown_seen = {};
    pt.chat_ctx = nil;
    pt.test_until = nil;
    ui.force_pos = true;
    ui.sync_buffers();
    settings.save();
end);

ashita.events.register('load', 'puptimers_load', function ()
    if (not pt.settings.hud.locked) then
        msg('Loaded. The timer window is unlocked: drag it into place, resize it from the corner, then type /pupt lock. /pupt opens settings.');
    end
end);

ashita.events.register('unload', 'puptimers_unload', function ()
    pcall(check_settings_switch);
    settings.save();
end);
