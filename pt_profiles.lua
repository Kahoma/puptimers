--[[
* PupTimers - settings profiles.
*
* A profile is a named copy of the settings (look, alerts, tracked abilities, maneuver and overload
* options) kept in one file shared by all characters, so a setup can be saved on one character and
* loaded on another, or switched automatically with the automaton's frame. What belongs to the
* character and the screen is never part of a profile: names, window position, lock and visibility.
*
* The file is plain data written by PupTimers itself. It is read back by a small parser that only
* understands that data (strings, numbers, true/false and tables): nothing in the file is ever run,
* so a damaged or edited file can only be refused. Other characters' settings files are read the
* same way.
--]]

local profiles = {};

-- Keys that stay with the character (top-level sections, or keys inside the hud section).
local KEEP_SECTIONS = { names = true, version = true, profiles = true };
-- grow stays too: it decides whether hud.y is the window's top or bottom edge.
local KEEP_HUD = { x = true, y = true, grow = true, locked = true, visible = true };

profiles.MAX_PROFILES = 40;
profiles.MAX_NAME = 32;
profiles.MAX_FILE = 1500000;       -- bytes; a bigger profiles.lua is not read (40 large profiles: ~0.9 MB)
profiles.MAX_SETTINGS = 262144;    -- bytes; a bigger settings.lua is not read (one character: ~20-40 KB)

local function copy_plain(v, depth)
    local tv = type(v);
    if (tv == 'number' or tv == 'string' or tv == 'boolean') then
        if (tv == 'number' and (v ~= v or v == math.huge or v == -math.huge)) then
            return nil;   -- NaN / infinity: not plain data
        end
        return v;
    end
    if (tv ~= 'table' or depth > 6) then
        return nil;
    end
    local out = {};
    for k, x in pairs(v) do
        local tk = type(k);
        if (tk == 'string' or tk == 'number') then
            local c = copy_plain(x, depth + 1);
            if (c ~= nil) then
                out[k] = c;
            end
        end
    end
    return out;
end

-- The part of the settings a profile holds (a new table).
function profiles.snapshot(cfg)
    local out = {};
    for section, v in pairs(cfg) do
        if (type(section) == 'string' and not KEEP_SECTIONS[section]) then
            local c = copy_plain(v, 1);
            if (c ~= nil) then
                if (section == 'hud' and type(c) == 'table') then
                    for k in pairs(KEEP_HUD) do
                        c[k] = nil;
                    end
                end
                out[section] = c;
            end
        end
    end
    return out;
end

--[[
* Puts a profile into the settings in place (the settings library keeps saving the same table).
* Only keys the current settings already have are taken, with the same type, so an old or edited
* profile cannot add junk or break a setting; whatever it lacks keeps its current value.
--]]
local function merge(dst, src)
    for k, sv in pairs(src) do
        local dv = dst[k];
        if (type(dv) == 'table' and type(sv) == 'table') then
            if (#dv > 0 and type(dv[1]) == 'number') then
                -- a colour { r, g, b, a }: taken whole when it is four numbers
                if (#sv == 4 and type(sv[1]) == 'number' and type(sv[2]) == 'number' and type(sv[3]) == 'number' and type(sv[4]) == 'number') then
                    dst[k] = { sv[1], sv[2], sv[3], sv[4] };
                end
            else
                merge(dv, sv);
            end
        elseif (dv ~= nil and type(dv) == type(sv)) then
            dst[k] = sv;
        end
    end
end

function profiles.apply(cfg, snap)
    for section, sv in pairs(snap) do
        if (type(section) == 'string' and not KEEP_SECTIONS[section] and type(cfg[section]) == 'table' and type(sv) == 'table') then
            if (section == 'custom') then
                -- Added abilities are taken as a set: the profile's list replaces the current one.
                local list = {};
                for key, c in pairs(sv) do
                    if (type(key) == 'string' and type(c) == 'table' and type(c.name) == 'string' and c.name ~= '') then
                        list[key] = copy_plain(c, 1);
                    end
                end
                cfg.custom = list;
            elseif (section == 'hud') then
                local keep = {};
                for k in pairs(KEEP_HUD) do
                    keep[k] = cfg.hud[k];
                end
                merge(cfg.hud, sv);
                for k, v in pairs(keep) do
                    cfg.hud[k] = v;
                end
            else
                merge(cfg[section], sv);
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- File format: "return { ... }" with sorted keys, so the file stays readable and stable.
----------------------------------------------------------------------------------------------------

-- Lua keywords cannot be written as bare keys (a profile called "end" would break the file).
local KEYWORDS = {};
for w in ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while'):gmatch('%a+') do
    KEYWORDS[w] = true;
end

-- A number as text that reads back as exactly the same number (short when possible). Settings
-- never hold numbers beyond +-1e30 or closer to 0 than 1e-30; such values are written as the
-- nearest of 0 and +-1e30, so the file always stays readable (read_number refuses larger exponents).
local function num_text(v)
    local a = math.abs(v);
    if (a < 1e-30) then
        return '0';
    elseif (a > 1e30) then
        return (v < 0) and '-1e+30' or '1e+30';
    end
    if (v == math.floor(v) and a < 1e15) then
        return ('%d'):format(v);
    end
    local short = ('%.15g'):format(v);
    return (tonumber(short) == v) and short or ('%.17g'):format(v);
end

local function ser(v, indent, out)
    local tv = type(v);
    if (tv == 'string') then
        out[#out + 1] = ('%q'):format(v);
    elseif (tv == 'number') then
        out[#out + 1] = num_text(v);
    elseif (tv == 'boolean') then
        out[#out + 1] = v and 'true' or 'false';
    elseif (tv == 'table') then
        local keys = {};
        for k in pairs(v) do
            if (type(k) == 'string' or type(k) == 'number') then
                keys[#keys + 1] = k;
            end
        end
        table.sort(keys, function (a, b)
            if (type(a) == type(b)) then
                return a < b;
            end
            return type(a) == 'number';
        end);
        out[#out + 1] = '{\n';
        local pad = ('    '):rep(indent + 1);
        for _, k in ipairs(keys) do
            out[#out + 1] = pad;
            if (type(k) == 'number') then
                out[#out + 1] = '[' .. num_text(k) .. '] = ';
            elseif (k:match('^[%a_][%w_]*$') and not KEYWORDS[k]) then
                out[#out + 1] = k .. ' = ';
            else
                out[#out + 1] = ('[%q] = '):format(k);
            end
            ser(v[k], indent + 1, out);
            out[#out + 1] = ',\n';
        end
        out[#out + 1] = ('    '):rep(indent) .. '}';
    else
        out[#out + 1] = 'nil';
    end
end

function profiles.serialize(t)
    local out = { '-- PupTimers profiles (shared by all characters). Written by PupTimers.\nreturn ' };
    ser(t, 0, out);
    out[#out + 1] = '\n';
    return table.concat(out);
end

----------------------------------------------------------------------------------------------------
-- Reading files without running them. Ashita's 'common' library gives every string and function
-- metamethods for the whole Lua state, so running a file, even with no globals, could still call
-- library functions. These parsers only build plain tables from literals.
----------------------------------------------------------------------------------------------------

local ESCAPES = { [97] = '\a', [98] = '\b', [102] = '\f', [110] = '\n', [114] = '\r', [116] = '\t', [118] = '\v',
                  [92] = '\\', [34] = '"', [39] = "'" };
local STOP = { [34] = '["\\\n]', [39] = "['\\\n]" };

-- A quoted string starting at text[i]: its value and the index after it, or nil.
local function read_string(text, i)
    local stop = STOP[text:byte(i)];
    if (stop == nil) then
        return nil;
    end
    local quote = text:byte(i);
    local parts, n, j = nil, 0, i + 1;
    while (true) do
        local k = text:find(stop, j);
        if (k == nil) then
            return nil;
        end
        local c = text:byte(k);
        if (c == quote) then
            if (parts == nil) then
                return text:sub(j, k - 1), k + 1;
            end
            parts[n + 1] = text:sub(j, k - 1);
            return table.concat(parts), k + 1;
        end
        if (c == 10) then
            return nil;   -- a line break inside a string must be escaped
        end
        parts = parts or {};                      -- a backslash escape
        n = n + 1;
        parts[n] = text:sub(j, k - 1);
        local e = text:byte(k + 1);
        n = n + 1;
        if (ESCAPES[e] ~= nil) then
            parts[n] = ESCAPES[e];
            j = k + 2;
        elseif (e == 10 or e == 13) then
            parts[n] = '\n';                      -- backslash + line break (also \r\n or \n\r)
            j = k + 2;
            local e2 = text:byte(j);
            if ((e2 == 10 or e2 == 13) and e2 ~= e) then
                j = j + 1;
            end
        else
            local d = text:match('^%d%d?%d?', k + 1);
            local b = tonumber(d or '');
            if (b == nil or b > 255) then
                return nil;
            end
            parts[n] = string.char(b);
            j = k + 1 + #d;
        end
    end
end

-- A number at text[i] as PupTimers and the settings library write them (-12, 0.35, 1.5e-07).
-- Settings never need more than 17 digits or exponents beyond +-30; refusing those also keeps the
-- conversion fast (very large exponents take LuaJIT's slow exact path).
local function read_number(text, i)
    local s, e = text:find('^%-?%d+%.?%d*', i);
    if (s == nil) then
        s, e = text:find('^%-?%.%d+', i);
        if (s == nil) then
            return nil;
        end
    end
    local _, e2, ex = text:find('^[eE]([%-+]?%d+)', e + 1);
    if (ex ~= nil and (#ex > 4 or math.abs(tonumber(ex)) > 30)) then
        return nil;
    end
    e = e2 or e;
    if (e - s + 1 > 32 or text:find('^[%w_%.]', e + 1)) then
        return nil;
    end
    local v = tonumber(text:sub(s, e));
    if (v == nil or v ~= v or v == math.huge or v == -math.huge) then
        return nil;
    end
    return v, e + 1;
end

local function line_of(text, i)
    local _, lines = text:sub(1, i):gsub('\n', '');
    return lines + 1;
end

-- Real profiles nest 5 levels below the top (list > profile > section > ability > colour) and a
-- large file has about 5,000 tables: anything far beyond that is refused, not built.
local MAX_DEPTH = 6;
local MAX_TABLES = 20000;

--[[
* The profiles file: "return" and one table of strings, numbers, true/false and tables, with keys
* written as [string], [number] or a bare name, and -- line comments. Returns the table, or nil and
* a reason.
--]]
local function read_literal(text)
    local i = 1;
    local tables = 0;
    local function skip()
        while (true) do
            local _, e = text:find('^[ \t\r\n\f\v]+', i);
            if (e ~= nil) then
                i = e + 1;
            end
            if (not text:find('^%-%-', i)) then
                return;
            end
            local nl = text:find('\n', i, true);
            i = (nl or #text) + 1;
        end
    end
    local read_value;
    local function read_table(depth)
        tables = tables + 1;
        if (depth > MAX_DEPTH or tables > MAX_TABLES) then
            return nil;
        end
        i = i + 1;   -- past '{'
        local t, pos = {}, 0;
        while (true) do
            skip();
            local c = text:byte(i);
            if (c == 125) then   -- '}'
                i = i + 1;
                return t;
            end
            local key = nil;
            if (c == 91) then    -- '[' key ']'
                i = i + 1;
                skip();
                local k, ni;
                if (STOP[text:byte(i)] ~= nil) then
                    k, ni = read_string(text, i);
                else
                    k, ni = read_number(text, i);
                end
                if (k == nil) then
                    return nil;
                end
                i = ni;
                skip();
                if (text:byte(i) ~= 93) then
                    return nil;
                end
                i = i + 1;
                key = k;
            else
                -- A bare name followed by '=' is a key (any name, so old files with keys such as
                -- "end" can still be read); otherwise only true / false may stand here.
                local w = text:match('^[%a_][%w_]*', i);
                if (w ~= nil and text:find('^[ \t\r\n\f\v]*=[^=]', i + #w)) then
                    key = w;
                    i = i + #w;
                end
            end
            if (key ~= nil) then
                skip();
                if (text:byte(i) ~= 61) then   -- '='
                    return nil;
                end
                i = i + 1;
                skip();
            end
            local v = read_value(depth);
            if (v == nil) then
                return nil;
            end
            if (key == nil) then
                pos = pos + 1;
                key = pos;
            end
            t[key] = v;
            skip();
            c = text:byte(i);
            if (c == 44 or c == 59) then   -- ',' or ';'
                i = i + 1;
            elseif (c ~= 125) then
                return nil;
            end
        end
    end
    read_value = function (depth)
        local c = text:byte(i);
        if (c == nil) then
            return nil;
        end
        if (STOP[c] ~= nil) then
            local v, ni = read_string(text, i);
            if (v ~= nil) then
                i = ni;
            end
            return v;
        end
        if (c == 123) then   -- '{'
            return read_table(depth + 1);
        end
        local w = text:match('^[%a_][%w_]*', i);
        if (w ~= nil) then
            if (w == 'true' or w == 'false') then
                i = i + #w;
                return w == 'true';
            end
            return nil;
        end
        local v, ni = read_number(text, i);
        if (v ~= nil) then
            i = ni;
        end
        return v;
    end

    skip();
    if (not text:find('^return', i) or text:find('^[%w_]', i + 6)) then
        return nil, 'not plain data';
    end
    i = i + 6;
    skip();
    if (text:byte(i) ~= 123) then
        return nil, 'not plain data';
    end
    local t = read_table(0);
    if (t ~= nil) then
        skip();
        if (i > #text) then
            return t;
        end
    end
    return nil, ('not plain data (line %d)'):format(line_of(text, math.min(i, #text)));
end

--[[
* Reads the profiles file text (nothing in it is run). Returns the table, or nil and a reason.
--]]
function profiles.parse(text)
    if (type(text) ~= 'string' or text == '') then
        return nil, 'empty';
    end
    if (#text > profiles.MAX_FILE) then
        return nil, 'too large';
    end
    local t, why = read_literal(text);
    if (t == nil) then
        return nil, why;
    end
    local clean = copy_plain(t, 0);
    if (type(clean.list) ~= 'table') then
        clean.list = {};
    end
    for name, p in pairs(clean.list) do
        if (type(name) ~= 'string' or name == '' or #name > profiles.MAX_NAME or type(p) ~= 'table') then
            clean.list[name] = nil;
        end
    end
    return clean;
end

-- One key of a settings line: a quoted string, true / false, or a number.
local function settings_key(line, i)
    local c = line:byte(i);
    if (STOP[c] ~= nil) then
        return read_string(line, i);
    end
    local w = line:match('^[%a_][%w_]*', i);
    if (w == 'true' or w == 'false') then
        return (w == 'true'), i + #w;
    end
    return read_number(line, i);
end

local function settings_line(root, line)
    if (not line:find('^settings%[')) then
        return false;
    end
    local i = 9;   -- at the first '['
    local t, key = root, nil;
    while (line:byte(i) == 91) do
        if (key ~= nil) then
            t = t[key];
            if (type(t) ~= 'table') then
                return false;   -- a table the file never created
            end
        end
        local k, ni = settings_key(line, i + 1);
        if (k == nil or line:byte(ni) ~= 93) then
            return false;
        end
        key, i = k, ni + 1;
    end
    if (key == nil) then
        return false;
    end
    local v = line:match('^ = (.*);[ \t]*$', i);
    if (v == nil) then
        return false;
    end
    if (v == 'T{ }') then
        t[key] = {};
    elseif (v == 'true' or v == 'false') then
        t[key] = (v == 'true');
    elseif (v == '1/0' or v == '-1/0' or v == '0/0') then
        -- infinity / not-a-number: not usable, left out (the default fills in)
    else
        local x, ni;
        if (STOP[v:byte(1)] ~= nil) then
            x, ni = read_string(v, 1);
        else
            x, ni = read_number(v, 1);
        end
        if (x == nil or ni ~= #v + 1) then
            return false;
        end
        t[key] = x;
    end
    return true;
end

--[[
* Reads another character's settings.lua, as the Ashita settings library writes it, without running
* anything from it. Every line must be one the library writes:
*   require('common');  /  local settings = T{ };  /  return settings;
*   settings[k1][k2]... = <string, number, true/false, 1/0, -1/0, 0/0 or T{ }>;
* and the file must end with 'return settings;' (one caught while it is being written is refused).
* Returns the settings table, or nil and a reason.
--]]
function profiles.read_settings_text(text)
    if (type(text) ~= 'string' or text == '' or #text > profiles.MAX_SETTINGS) then
        return nil, 'empty or too large';
    end
    local root, done = nil, false;
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '');
        if (line ~= '') then
            if (done) then
                return nil, 'not a settings file';   -- nothing may follow 'return settings;'
            elseif (line == 'local settings = T{ };') then
                root = {};
            elseif (line == 'return settings;') then
                done = true;
            elseif (line ~= "require('common');") then
                if (root == nil or not settings_line(root, line)) then
                    return nil, 'not a settings file';
                end
            end
        end
    end
    -- A file caught while the other game window was writing it has no 'return settings;' yet.
    if (root == nil or not done) then
        return nil, 'not a complete settings file';
    end
    return copy_plain(root, 0);
end

-- A profile name as typed, tidied: trimmed, at most MAX_NAME characters, nil if empty.
function profiles.clean_name(name)
    name = tostring(name or ''):gsub('[%c#]', ''):gsub('^%s+', ''):gsub('%s+$', '');
    if (name == '') then
        return nil;
    end
    return name:sub(1, profiles.MAX_NAME);
end

return profiles;
