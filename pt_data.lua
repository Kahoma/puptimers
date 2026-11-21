--[[
* PupTimers - static game data.
*
* Cooldowns and ids come from the LandSandBoat server source, which HorizonXI is built on:
*   - automaton ability recasts:   scripts/actions/abilities/pets/automaton/*.lua  (addRecast calls)
*   - automaton ability skill ids: sql/automaton_abilities.sql / sql/mob_skills.sql
*   - Shield Bash recast:          src/map/ai/controllers/automaton_controller.cpp (3 min)
*   - job ability recast ids:      sql/abilities.sql
*
* Everything here is only a DEFAULT. Cooldowns, colors and which bars are shown can all be
* changed in-game from the settings window (/pupt), and you can add your own abilities there.
--]]

local data = {};

-- Elements in maneuver order. Index n maps to:
--   status (buff) id 299 + n   (Fire Maneuver = 300 ... Dark Maneuver = 307)
--   job ability id   140 + n   (Fire Maneuver = 141 ... Dark Maneuver = 148)
data.elements = {
    { key = 'fire',    name = 'Fire',    color = { 0.90, 0.30, 0.22, 1.0 } },
    { key = 'ice',     name = 'Ice',     color = { 0.45, 0.78, 0.96, 1.0 } },
    { key = 'wind',    name = 'Wind',    color = { 0.33, 0.80, 0.40, 1.0 } },
    { key = 'earth',   name = 'Earth',   color = { 0.80, 0.63, 0.28, 1.0 } },
    { key = 'thunder', name = 'Thunder', color = { 0.68, 0.45, 0.93, 1.0 } },
    { key = 'water',   name = 'Water',   color = { 0.25, 0.48, 0.92, 1.0 } },
    { key = 'light',   name = 'Light',   color = { 0.93, 0.89, 0.62, 1.0 } },
    { key = 'dark',    name = 'Dark',    color = { 0.50, 0.32, 0.66, 1.0 } },
};

data.element_index = {};
for i, e in ipairs(data.elements) do
    data.element_index[e.key] = i;
end

data.MANEUVER_BUFF_FIRST = 300;   -- Fire Maneuver status id (Dark Maneuver = 307)
data.MANEUVER_JA_FIRST   = 141;   -- Fire Maneuver job ability id (Dark Maneuver = 148)
data.OVERLOAD_BUFF       = 299;
data.OVERDRIVE_BUFF      = 166;
data.OVERDRIVE_THRESH    = 5000;  -- Overdrive raises the overload threshold by this much (no overload possible)
data.MANEUVER_TIMER_ID   = 210;   -- recast timer shared by all eight maneuvers
data.MAX_MANEUVERS       = 3;     -- the server keeps at most 3; a 4th replaces the oldest
data.PUP_JOB_ID          = 18;

-- Automaton abilities.
--   key      : internal id (also the settings key)
--   name     : exactly as the game prints it in the chat log
--   cooldown : seconds, from the server scripts (editable in-game)
--   element  : maneuver that powers it (used for the default bar color)
--   source   : attachment / frame that grants it (shown in the settings window)
--   skill_id : the ability id carried by the action packet (category 11)
--   aliases  : other spellings accepted by "/pupt start <name>"
--   spawn_cooldown : cooldown the server applies when the automaton is activated, if different
data.abilities = {
    { key = 'provoke',         name = 'Provoke',         cooldown = 30,  element = 'fire',  source = 'Strobe / Strobe II',             skill_id = 1945 },
    { key = 'eraser',          name = 'Eraser',          cooldown = 30,  element = 'light', source = 'Eraser',                         skill_id = 2021 },
    { key = 'flashbulb',       name = 'Flashbulb',       cooldown = 45,  element = 'light', source = 'Flashbulb',                      skill_id = 1947 },
    { key = 'reactive_shield', name = 'Reactive Shield', cooldown = 65,  element = 'fire',  source = 'Reactive Shield (65s on 2020-2026 server code; current LandSandBoat uses 60s)', skill_id = 2031 },
    { key = 'replicator',      name = 'Replicator',      cooldown = 60,  element = 'wind',  source = 'Replicator',                     skill_id = 2132 },
    { key = 'disruptor',       name = 'Disruptor',       cooldown = 60,  element = 'dark',  source = 'Disruptor',                      skill_id = 2747 },
    { key = 'regulator',       name = 'Regulator',       cooldown = 60,  element = 'dark',  source = 'Regulator',                      skill_id = 3485 },
    { key = 'heat_capacitor',  name = 'Heat Capacitor',  cooldown = 90,  element = 'fire',  source = 'Heat Capacitor / II',            skill_id = 2745 },
    { key = 'shock_absorber',  name = 'Shock Absorber',  cooldown = 180, element = 'earth', source = 'Shock Absorber / II / III',      skill_id = 1946 },
    { key = 'mana_converter',  name = 'Mana Converter',  cooldown = 180, element = 'dark',  source = 'Mana Converter (fires at low automaton MP with Dark Maneuvers up)', skill_id = 1948, aliases = { 'Mana-Converter', 'Mana Convertor' }, color = { 0.33, 0.45, 0.92, 1.0 } },
    { key = 'economizer',      name = 'Economizer',      cooldown = 180, element = 'dark',  source = 'Economizer (fires at low automaton MP with Dark Maneuvers up)',     skill_id = 2068, aliases = { 'Economiser' }, spawn_cooldown = 60, color = { 0.68, 0.32, 0.80, 1.0 } },
    { key = 'barrage_turbine', name = 'Barrage Turbine', cooldown = 180, element = 'wind',  source = 'Barrage Turbine',                skill_id = 2746 },
    { key = 'shield_bash',     name = 'Shield Bash',     cooldown = 180, element = nil,     source = 'Valoredge Frame (Barrier Module lowers it 5/10/15s)', skill_id = 1944 },
};

data.SHIELD_BASH_COLOR = { 0.62, 0.68, 0.76, 1.0 };

-- Automaton actions that have no cooldown of their own (TP weapon skills, ranged attacks).
-- They are never offered as "seen but not tracked" in the settings window.
data.ignored_pet_skills = {
    ['chimera ripper'] = true, ['string clipper'] = true, ['arcuballista'] = true, ['slapstick'] = true,
    ['cannibal blade'] = true, ['daze'] = true, ['knockout'] = true, ['bone crusher'] = true,
    ['armor piercer'] = true, ['magic mortar'] = true, ['string shredder'] = true, ['armor shatterer'] = true,
    ['ranged attack'] = true,
};

-- Gear and attachments that change burden / overload (LandSandBoat item data, level 75 and below).
--   thresh   : OVERLOAD_THRESH   (more burden needed before an overload can happen)
--   suppress : SUPPRESS_OVERLOAD (every burden gain divided by 3)
--   slot     : items in the same slot never stack
data.overload_gear = {
    { key = 'puppetry_dastanas',    name = 'Puppetry Dastanas',    ids = { 14930 }, slot = 'hands', thresh = 5, effect = '+5 overload threshold (PUP artifact hands)' },
    { key = 'puppetry_dastanas_p1', name = 'Puppetry Dastanas +1', ids = { 15030 }, slot = 'hands', thresh = 5, effect = '+5 overload threshold' },
    { key = 'buffoons_collar',      name = 'Buffoon\'s Collar',    ids = { 16281 }, slot = 'neck',  thresh = 5, effect = '+5 overload threshold' },
    { key = 'buffoons_collar_p1',   name = 'Buffoon\'s Collar +1', ids = { 16282 }, slot = 'neck',  thresh = 5, effect = '+5 overload threshold' },
    { key = 'kenkonken',            name = 'Kenkonken',            ids = { 19008 }, slot = 'main',  suppress = true, effect = 'burden from each maneuver divided by 3' },
};

-- Attachments can't be read from the game, so they are ticked by hand.
data.overload_attachments = {
    { key = 'heatsink',           name = 'Heatsink',           effect = 'burden cools 3/5/6/7 per tick with 0/1/2/3 Water Maneuvers up' },
    { key = 'tactical_processor', name = 'Tactical Processor', effect = 'threshold -5 (only on servers using the pre-2015 rule)' },
};

data.job_names = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

-- Job ability recasts read straight from the game's recast memory (shown only while on cooldown).
--   timer  : recast timer id ('sp' = the special/2-hour slot, only valid when PUP is the main job)
--   recast : normal recast in seconds; only used for the bar length when the addon is loaded while
--            the ability is already cooling down (the remaining time itself always comes from the game)
--   show / alert : defaults for the settings window
--   spawns : using it creates a new automaton (every element's burden restarts)
data.job_abilities = {
    { key = 'activate',         name = 'Activate',         timer = 205,  recast = 1200, show = true,  alert = true,  spawns = true },
    { key = 'deus_ex_automata', name = 'Deus Ex Automata', timer = 115,  recast = 60,   show = true,  alert = true,  spawns = true },
    { key = 'repair',           name = 'Repair',           timer = 206,  recast = 180,  show = true,  alert = true  },
    { key = 'deactivate',       name = 'Deactivate',       timer = 208,  recast = 60,   show = false, alert = false },
    { key = 'deploy',           name = 'Deploy',           timer = 207,  recast = 5,    show = false, alert = false },
    { key = 'retrieve',         name = 'Retrieve',         timer = 209,  recast = 5,    show = false, alert = false },
    { key = 'role_reversal',    name = 'Role Reversal',    timer = 211,  recast = 120,  show = false, alert = false },
    { key = 'ventriloquy',      name = 'Ventriloquy',      timer = 212,  recast = 60,   show = false, alert = false },
    { key = 'tactical_switch',  name = 'Tactical Switch',  timer = 213,  recast = 180,  show = false, alert = false },
    { key = 'maintenance',      name = 'Maintenance',      timer = 214,  recast = 90,   show = false, alert = false },
    { key = 'cooldown',         name = 'Cooldown',         timer = 114,  recast = 300,  show = false, alert = false },
    { key = 'overdrive',        name = 'Overdrive',        timer = 'sp', recast = 3600, show = false, alert = false, main_only = true },
};

--[[
* Builds the default settings table. A fresh table is built on every call so no caller can
* accidentally share (and mutate) nested default tables.
--]]
function data.default_settings()
    local function copy(t)
        local r = {};
        for k, v in pairs(t) do
            r[k] = (type(v) == 'table') and copy(v) or v;
        end
        return r;
    end

    local s = {
        version = 1,

        hud = {
            visible             = true,
            locked              = false,
            x                   = 120,
            y                   = 260,
            width               = 230,
            scale               = 1.0,     -- overall size multiplier (text + bars)
            bar_height          = 18,
            bar_spacing         = 3,
            padding             = 6,
            rounding            = 3,
            bg_alpha            = 0.55,
            hide_when_empty     = true,
            only_on_pup         = true,
            preview_unlocked    = true,    -- show sample bars while unlocked and idle
            show_header         = false,   -- automaton name line above the bars
            show_section_gap    = true,
            text_shadow         = true,
            fill_mode           = 'drain', -- 'drain' (bar empties) or 'fill' (bar fills up)
            time_format         = 'mss',   -- 'mss' (1:05) or 'sec' (65s)
            sort_abilities      = 'remaining', -- 'remaining' or 'name'
            order               = 'maneuvers,abilities,recasts',
        },

        colors = {
            bar_bg      = { 0.08, 0.08, 0.10, 0.85 },
            text        = { 1.00, 1.00, 1.00, 1.00 },
            header      = { 0.80, 0.80, 0.85, 0.90 },
            ready       = { 0.25, 0.85, 0.35, 1.00 },
            warn        = { 1.00, 0.55, 0.10, 1.00 },
            recast      = { 0.85, 0.65, 0.20, 1.00 },
            maneuver_cd = { 0.55, 0.55, 0.62, 1.00 },
            overload    = { 0.85, 0.12, 0.12, 1.00 },
            empty       = { 0.35, 0.35, 0.40, 0.55 },
            overload_safe = { 0.30, 0.72, 0.38, 1.00 },
            overload_low  = { 0.86, 0.78, 0.22, 1.00 },
            overload_mid  = { 0.95, 0.52, 0.12, 1.00 },
            overload_high = { 0.90, 0.16, 0.14, 1.00 },
            marker        = { 1.00, 1.00, 1.00, 0.85 },
        },

        names = {
            player   = '',   -- empty = auto-detect from the game
            pet      = '',   -- empty = auto-detect from the game
            last_pet = '',   -- remembered automatically
        },

        detect = {
            packets = true,  -- read the game's action packets (works even with chat filters on)
            chat    = true,  -- read the chat log ("<Automaton> uses <Ability>")
        },

        abilities = {},      -- filled below from data.abilities
        custom    = {},      -- user-added abilities: key -> { name, cooldown, enabled, alert, on_spawn, color }

        maneuvers = {
            enabled      = true,
            style        = 'icons', -- 'icons' (a row of element icons with timers) or 'bars'
            icon_size    = 30,
            icon_glyphs  = true,    -- draw element symbols on the icons (false = letters)
            icon_align   = 'left',  -- 'left' or 'center'
            duration     = 60,      -- maneuver duration (a flat 60s on HorizonXI)
            real_timers  = false,   -- use the game's buff timers for every maneuver (only if your server changes durations);
                                    -- maneuvers already up when the addon loads always use them
            show_empty   = false,  -- show empty slots while the automaton is out
            show_recast  = true,   -- show the shared maneuver recast bar
            show_overload = true,
            warn_at      = 10,     -- seconds left when a maneuver bar turns orange (0 = off)
            alert_wear   = false,  -- chat/sound alert when a maneuver wears off
            colors       = {},     -- element key -> color (filled below)
        },

        overload = {
            enabled            = true,
            show               = 'all',  -- 'all' (one bar per element with an active overload) or 'top' (riskiest only)
            hide_at            = 'chance', -- 'chance': bar goes away at 0%; 'burden': stays until fully cooled
            full_at            = 50,     -- chance (%) that fills a bar completely
            color_by           = 'risk', -- 'risk' (green -> red by next-maneuver chance) or 'element'
            compact            = false,  -- thinner bars
            -- Server constants (LandSandBoat). Change only if your server differs.
            tick               = 3,      -- seconds between burden decay ticks
            base_threshold     = 30,     -- burden above this can overload
            chance_offset      = 5,      -- reported chance = burden - threshold + 5
            base_decay         = 1,      -- burden lost per tick
            default_burden     = 20,     -- burden per maneuver until learned (15, or 20 when your stat is below the automaton's)
            dark_burden        = 15,     -- Dark Maneuver (10, or 15 when your MP is below the automaton's)
            spawn_burden       = 30,     -- burden in every element when an automaton is activated / respawns after zoning
            -- Gear and attachments (one entry per item, filled below from data.overload_gear)
            gear               = {},     -- key -> { count = bool, worn_only = bool }
            heatsink           = false,  -- Heatsink attachment equipped
            tactical_processor = false,  -- Tactical Processor attachment equipped
            extra_threshold    = 0,      -- manual adjustment
            extra_decay        = 0,      -- manual adjustment
            alert_risk         = 0,      -- chat/sound warning when a maneuver would be this risky (0 = off)
        },

        jobabilities = {},   -- filled below from data.job_abilities

        alerts = {
            chat        = true,
            sound       = false,
            sound_file  = 'ready.wav',
            ready_hold  = 0,       -- seconds a "READY" bar stays up after the cooldown ends (0 = remove at once)
            keep_ready  = false,   -- keep ready automaton abilities on screen until used again
            flash       = true,
        },

        behavior = {
            reset_on_despawn = true,   -- clear automaton ability timers when the automaton leaves or a new one is called
            debug            = false,
        },
    };

    for _, a in ipairs(data.abilities) do
        local col = data.SHIELD_BASH_COLOR;
        if (a.color ~= nil) then
            col = a.color;
        elseif (a.element ~= nil) then
            col = data.elements[data.element_index[a.element]].color;
        end
        s.abilities[a.key] = {
            enabled  = true,
            cooldown = a.cooldown,
            alert    = true,
            on_spawn = false,
            color    = copy(col),
        };
    end

    for _, e in ipairs(data.elements) do
        s.maneuvers.colors[e.key] = copy(e.color);
    end

    for _, j in ipairs(data.job_abilities) do
        s.jobabilities[j.key] = { show = j.show, alert = j.alert };
    end

    for _, g in ipairs(data.overload_gear) do
        s.overload.gear[g.key] = { count = true, worn_only = true };
    end

    return s;
end

return data;
