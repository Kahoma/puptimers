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

-- The automaton's weapon skills (mob skill ids in its action packets, category 11): Flame Holder
-- uses up Fire Maneuvers on these. Ice Maker uses up Ice Maneuvers on elemental nukes (spell ids
-- Fire 144 to Water V 173, category 4).
data.automaton_ws = {
    [1940] = 'Chimera Ripper', [1941] = 'String Clipper', [1942] = 'Arcuballista', [1943] = 'Slapstick',
    [2065] = 'Cannibal Blade', [2066] = 'Daze', [2067] = 'Knockout', [2299] = 'Bone Crusher',
    [2300] = 'Armor Piercer', [2301] = 'Magic Mortar', [2743] = 'String Shredder', [2744] = 'Armor Shatterer',
};
data.NUKE_FIRST, data.NUKE_LAST = 144, 173;
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
--   att      : the attachment's byte in the game's setup data (packet 0x044), if it comes from one
--   frame    : the frame byte, for frame abilities (Shield Bash: Valoredge)
--   horizon  : false for abilities whose attachment is not on HorizonXI (hidden unless asked for)
--   consumes : the attachment uses up all maneuvers of its element when it fires ('all': every
--              maneuver, as Eraser does on this era's server code)
data.abilities = {
    { key = 'provoke',         name = 'Provoke',         cooldown = 30,  element = 'fire',  source = 'Strobe',                         skill_id = 1945, att = 1 },
    { key = 'eraser',          name = 'Eraser',          cooldown = 30,  element = 'light', source = 'Eraser (uses up your maneuvers: all of them on current server code, Light ones on older code)', skill_id = 2021, att = 197, consumes = 'all' },
    { key = 'flashbulb',       name = 'Flashbulb',       cooldown = 45,  element = 'light', source = 'Flashbulb',                      skill_id = 1947, att = 194 },
    { key = 'reactive_shield', name = 'Reactive Shield', cooldown = 60,  element = 'fire',  source = 'Reactive Shield (60s on current server code and the HorizonXI wiki; 65s on older code)', skill_id = 2031, att = 6 },
    { key = 'replicator',      name = 'Replicator',      cooldown = 60,  element = 'wind',  source = 'Replicator (uses up your Wind Maneuvers)', skill_id = 2132, att = 71, consumes = true },
    { key = 'shock_absorber',  name = 'Shock Absorber',  cooldown = 180, element = 'earth', source = 'Shock Absorber',                 skill_id = 1946, att = 97 },
    { key = 'mana_converter',  name = 'Mana Converter',  cooldown = 180, element = 'dark',  source = 'Mana Converter (fires at low automaton MP with Dark Maneuvers up)', skill_id = 1948, att = 226, aliases = { 'Mana-Converter', 'Mana Convertor' }, color = { 0.33, 0.45, 0.92, 1.0 } },
    { key = 'economizer',      name = 'Economizer',      cooldown = 180, element = 'dark',  source = 'Economizer (fires at low automaton MP with Dark Maneuvers up; uses them up)', skill_id = 2068, att = 230, consumes = true, aliases = { 'Economiser' }, spawn_cooldown = 60, color = { 0.68, 0.32, 0.80, 1.0 } },
    { key = 'shield_bash',     name = 'Shield Bash',     cooldown = 180, element = nil,     source = 'Valoredge Frame',                skill_id = 1944, frame = 0x21 },
    -- Not obtainable on HorizonXI (no wiki page or hidden): kept for other servers.
    { key = 'disruptor',       name = 'Disruptor',       cooldown = 60,  element = 'dark',  source = 'Disruptor (not on HorizonXI)',      skill_id = 2747, horizon = false },
    { key = 'regulator',       name = 'Regulator',       cooldown = 60,  element = 'dark',  source = 'Regulator (not on HorizonXI)',      skill_id = 3485, horizon = false },
    { key = 'heat_capacitor',  name = 'Heat Capacitor',  cooldown = 90,  element = 'fire',  source = 'Heat Capacitor (not obtainable on HorizonXI)', skill_id = 2745, horizon = false, consumes = true },
    { key = 'barrage_turbine', name = 'Barrage Turbine', cooldown = 180, element = 'wind',  source = 'Barrage Turbine (not obtainable on HorizonXI)', skill_id = 2746, horizon = false },
};

-- Automaton attachments on HorizonXI, by their byte in the setup data (item id = 0x2100 + byte).
data.attachments = {
    [1] = 'Strobe', [2] = 'Tension Spring', [3] = 'Inhibitor', [4] = 'Tension Spring II', [5] = 'Attuner',
    [6] = 'Reactive Shield', [7] = 'Flame Holder',
    [33] = 'Mana Booster', [34] = 'Loudspeaker', [35] = 'Scanner', [36] = 'Loudspeaker II',
    [37] = 'Tactical Processor', [38] = 'Tranquilizer', [39] = 'Ice Maker',
    [65] = 'Accelerator', [66] = 'Scope', [67] = 'Pattern Reader', [68] = 'Accelerator II',
    [69] = 'Drum Magazine', [70] = 'Turbo Charger', [71] = 'Replicator',
    [97] = 'Shock Absorber', [98] = 'Armor Plate', [99] = 'Analyzer', [100] = 'Armor Plate II',
    [101] = 'Equalizer', [102] = 'Schurzen', [103] = 'Hammermill',
    [129] = 'Stabilizer', [130] = 'Volt Gun', [131] = 'Heat Seeker', [132] = 'Stabilizer II',
    [133] = 'Target Marker', [134] = 'Dynamo', [135] = 'Coiler',
    [161] = 'Mana Jammer', [162] = 'Heatsink', [163] = 'Stealth Screen', [164] = 'Mana Jammer II',
    [165] = 'Mana Channeler', [166] = 'Condenser', [167] = 'Steam Jacket',
    [193] = 'Auto-Repair Kit', [194] = 'Flashbulb', [195] = 'Damage Gauge', [196] = 'Auto-Repair Kit II',
    [197] = 'Eraser', [198] = 'Optic Fiber',
    [225] = 'Mana Tank', [226] = 'Mana Converter', [227] = 'Mana Conserver', [228] = 'Mana Tank II',
    [229] = 'Smoke Screen', [230] = 'Economizer',
};
-- The attachments PupTimers acts on.
data.ATT = {
    flame_holder = 7, ice_maker = 39, replicator = 71, schurzen = 102,
    heatsink = 162, condenser = 166, damage_gauge = 195, economizer = 230,
    mana_converter = 226,
};

data.heads = {
    [1] = 'Harlequin Head', [2] = 'Valoredge Head', [3] = 'Sharpshot Head', [4] = 'Stormwaker Head',
    [5] = 'Soulsoother Head', [6] = 'Spiritreaver Head',
};

-- Automaton Oil in the ammo slot is what Repair uses (one per use).
data.oils = { [18731] = 'Oil', [18732] = 'Oil+1', [18733] = 'Oil+2', [19185] = 'Oil+3' };

data.SHIELD_BASH_COLOR = { 0.62, 0.68, 0.76, 1.0 };
data.CUSTOM_COLOR = { 0.85, 0.65, 0.20, 1.0 };   -- abilities added by hand start with this colour

-- Automaton frames (for switching settings profiles with the frame).
data.frames = {
    { key = 'harlequin',  name = 'Harlequin Frame',  byte = 0x20 },
    { key = 'valoredge',  name = 'Valoredge Frame',  byte = 0x21 },
    { key = 'sharpshot',  name = 'Sharpshot Frame',  byte = 0x22 },
    { key = 'stormwaker', name = 'Stormwaker Frame', byte = 0x23 },
};
data.frame_by_byte = {};
for _, f in ipairs(data.frames) do
    data.frame_by_byte[f.byte] = f;
end

-- Shorter names for narrow windows (used only when the full name does not fit).
data.short_names = {
    ['Reactive Shield'] = 'R. Shield', ['Replicator'] = 'Replic.', ['Disruptor'] = 'Disrupt.',
    ['Regulator'] = 'Regul.', ['Heat Capacitor'] = 'Heat Cap.', ['Shock Absorber'] = 'Shock Abs.',
    ['Mana Converter'] = 'Mana Conv.', ['Economizer'] = 'Econ.', ['Barrage Turbine'] = 'Barrage',
    ['Shield Bash'] = 'S. Bash', ['Deus Ex Automata'] = 'Deus Ex', ['Deactivate'] = 'Deact.',
    ['Role Reversal'] = 'Role Rev.', ['Ventriloquy'] = 'Ventril.', ['Tactical Switch'] = 'Tac. Switch',
    ['Maintenance'] = 'Maint.',
};

-- Automaton actions that have no cooldown of their own (TP weapon skills, ranged attacks).
-- They are never offered as "seen but not tracked" in the settings window.
data.ignored_pet_skills = { ['ranged attack'] = true };
for _, name in pairs(data.automaton_ws) do
    data.ignored_pet_skills[name:lower()] = true;
end

-- Gear and attachments that change burden / overload (LandSandBoat item data, level 75 and below).
--   thresh   : OVERLOAD_THRESH   (more burden needed before an overload can happen)
--   suppress : SUPPRESS_OVERLOAD (every burden gain divided by 3)
--   slot     : items in the same slot never stack
data.overload_gear = {
    { key = 'puppetry_dastanas',    name = 'Puppetry Dastanas',    ids = { 14930 }, slot = 'hands', thresh = 5, effect = '+5 overload threshold (PUP artifact hands)' },
    { key = 'puppetry_dastanas_p1', name = 'Puppetry Dastanas +1', ids = { 15030 }, slot = 'hands', thresh = 5, effect = '+5 overload threshold' },
    { key = 'buffoons_collar',      name = 'Buffoon\'s Collar',    ids = { 16281 }, slot = 'neck',  thresh = 5, effect = '+5 overload threshold' },
    { key = 'buffoons_collar_p1',   name = 'Buffoon\'s Collar +1', ids = { 16282 }, slot = 'neck',  thresh = 5, effect = '+5 overload threshold' },
    { key = 'kenkonken',            name = 'Kenkonken',            ids = { 19008 }, slot = 'main',  suppress = true, effect = 'every burden gain divided by 3 (maneuvers and activation)' },
};

-- Attachments that change overload. Read from the game's setup data, or ticked by hand.
-- (Tactical Processor is not here: its -5 threshold sits on the automaton on this era's server
-- code, and the overload check only reads the master's threshold.)
data.overload_attachments = {
    { key = 'heatsink',           name = 'Heatsink',           effect = 'burden cools faster (see the Heatsink setting)' },
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
    { key = 'deploy',           name = 'Deploy',           timer = 207,  recast = 10,   show = false, alert = false },
    { key = 'retrieve',         name = 'Retrieve',         timer = 209,  recast = 10,   show = false, alert = false },
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
        version = 2,

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
            hide_in_events      = true,    -- hide the timers during cutscenes and NPC conversations (they keep counting)
            grow                = 'down',  -- 'down': x/y is the top-left corner and new bars go below;
                                           -- 'up': x/y is the bottom-left corner and the window grows upward
            only_on_pup         = true,
            preview_unlocked    = true,    -- show sample bars while unlocked and idle
            show_header         = false,   -- automaton name line above the bars
            show_section_gap    = true,
            text_shadow         = true,
            fill_mode           = 'drain', -- 'drain' (bar empties) or 'fill' (bar fills up)
            time_format         = 'mss',   -- 'mss' (1:05) or 'sec' (65s)
            sort_abilities      = 'remaining', -- 'remaining' or 'name'
            order               = 'automaton,maneuvers,abilities,recasts',
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
            pet_hp        = { 0.32, 0.76, 0.42, 1.00 },
            pet_mp        = { 0.32, 0.55, 0.95, 1.00 },
        },

        automaton = {
            show_hp   = false,  -- thin automaton HP bar (off by default: other addons often show one)
            show_mp   = false,  -- thin automaton MP bar
            repair_at = 0,      -- remind to Repair when the automaton's HP falls to this % and Repair is ready (0 = off)
            deactivate_hint = true, -- while Activate cools down: say when Deactivate would reset it (automaton at full HP)
            oil       = true,   -- show the Automaton Oil in the ammo slot on the Repair bar, warn when there is none
        },

        profiles = {
            auto   = false,  -- load the profile chosen for the automaton's frame when the frame changes
            frames = { harlequin = '', valoredge = '', sharpshot = '', stormwaker = '' },
            last   = '',     -- the profile loaded last (shown in the Profiles tab)
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
            timer_mode   = 'auto',  -- 'auto': start + duration, but switch to the game's buff timers once a
                                    -- maneuver lasts longer (servers that lengthen them in battle);
                                    -- 'game': always the game's buff timers; 'flat': always start + duration.
                                    -- Maneuvers already up when the addon loads always use the game's timers.
            show_empty   = false,  -- show empty slots while the automaton is out
            show_recast  = true,   -- show the shared maneuver recast bar
            show_overload = true,
            warn_at      = 10,     -- seconds left when a maneuver bar turns orange (0 = off)
            alert_wear   = false,  -- chat/sound alert when a maneuver wears off
            show_unpowered = true, -- a line naming equipped abilities that cannot fire for lack of their maneuver
            alert_unpowered = false, -- chat/sound alert when losing a maneuver leaves such an ability unpowered
            explain_used = true,   -- a chat line when an attachment uses up maneuvers (Economizer, Replicator ...)
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
            default_burden     = 20,     -- burden per maneuver until known (14-20 by your stat against the automaton's)
            dark_burden        = 15,     -- Dark Maneuver until known (8 or 14 by frame on current server code)
            spawn_burden       = 35,     -- burden in every element when an automaton is activated / respawns after zoning
                                         -- (35 on current server code, 30 on older code)
            use_stats          = true,   -- work out each maneuver's burden from your and the automaton's stats
                                         -- (used once the game's own reports show it is right)
            heatsink_decay     = 1,      -- Heatsink: extra cooling per tick (current server code for this era: +1)
            heatsink_by_water  = false,  -- older server rule: +2/+4/+5/+6 with 0/1/2/3 Water Maneuvers instead
            attachments_auto   = true,   -- take Heatsink from the game's setup data
            -- Gear and attachments (one entry per item, filled below from data.overload_gear)
            gear               = {},     -- key -> { count = bool, worn_only = bool }
            heatsink           = false,  -- Heatsink attachment equipped (by hand, if the setup is not read)
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

--[[
* Colour schemes. 'default' is the defaults above; the others replace the window colours, the
* element colours and the automaton ability colours (abilities take their element's colour, the
* MP abilities and Shield Bash get their own).
--]]
local function rgb(hex, a)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, a or 1.0 };
end

data.palettes = {
    -- Okabe-Ito colours: told apart with every common kind of colour blindness. Risk goes from blue
    -- through yellow and orange to vermillion, never red against green.
    colorblind = {
        name = 'Colour-blind friendly',
        colors = {
            ready = rgb('56B4E9'), warn = rgb('E69F00'), recast = rgb('E69F00'), maneuver_cd = rgb('999999'),
            overload = rgb('D55E00'), overload_safe = rgb('56B4E9'), overload_low = rgb('F0E442'),
            overload_mid = rgb('E69F00'), overload_high = rgb('D55E00'), marker = rgb('FFFFFF', 0.9),
            pet_hp = rgb('009E73'), pet_mp = rgb('0072B2'),
        },
        elements = {
            fire = rgb('D55E00'), ice = rgb('56B4E9'), wind = rgb('009E73'), earth = rgb('E69F00'),
            thunder = rgb('CC79A7'), water = rgb('0072B2'), light = rgb('F0E442'), dark = rgb('8C8C8C'),
        },
        special = { mana_converter = rgb('0072B2'), economizer = rgb('CC79A7'), shield_bash = rgb('BBBBBB') },
    },
    -- Brighter, fully saturated colours on a darker, more solid bar background.
    contrast = {
        name = 'High contrast',
        colors = {
            bar_bg = { 0.02, 0.02, 0.03, 0.95 }, text = { 1, 1, 1, 1 }, header = { 1, 1, 1, 1 },
            ready = rgb('30D158'), warn = rgb('FF9F0A'), recast = rgb('FFD60A'), maneuver_cd = rgb('AEAEB2'),
            overload = rgb('FF453A'), empty = { 0.45, 0.45, 0.50, 0.75 }, overload_safe = rgb('30D158'),
            overload_low = rgb('FFD60A'), overload_mid = rgb('FF9F0A'), overload_high = rgb('FF453A'),
            marker = rgb('FFFFFF'), pet_hp = rgb('30D158'), pet_mp = rgb('0A84FF'),
        },
        elements = {
            fire = rgb('FF453A'), ice = rgb('64D2FF'), wind = rgb('30D158'), earth = rgb('D4A84B'),
            thunder = rgb('BF5AF2'), water = rgb('0A84FF'), light = rgb('FFF59D'), dark = rgb('9E9EA6'),
        },
        special = { mana_converter = rgb('0A84FF'), economizer = rgb('BF5AF2'), shield_bash = rgb('D1D1D6') },
    },
};

--[[
* The colours of a scheme as { colors = {...}, elements = {...}, abilities = {...} }, every value a
* new table. 'default' (or an unknown name) gives the default colours.
--]]
function data.palette(name)
    local d = data.default_settings();
    local out = { colors = d.colors, elements = d.maneuvers.colors, abilities = {} };
    for key, a in pairs(d.abilities) do
        out.abilities[key] = a.color;
    end
    local p = data.palettes[name];
    if (p == nil) then
        return out;
    end
    for k, v in pairs(p.colors) do
        out.colors[k] = { v[1], v[2], v[3], v[4] };
    end
    for k, v in pairs(p.elements) do
        out.elements[k] = { v[1], v[2], v[3], v[4] };
    end
    for _, a in ipairs(data.abilities) do
        local c = p.special[a.key] or (a.element ~= nil and p.elements[a.element]) or p.special.shield_bash;
        out.abilities[a.key] = { c[1], c[2], c[3], c[4] };
    end
    return out;
end

return data;
