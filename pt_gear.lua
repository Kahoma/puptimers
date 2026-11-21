--[[
* PupTimers - gear that changes burden / overload.
*
* Each item in data.overload_gear has two settings (Overload tab):
*   count     - include it in the estimate at all
*   worn_only - only while the game shows it equipped (untick if you swap it in just for the
*               maneuver: equipment is read every 2 seconds, so a quick swap can be missed)
* Items in the same slot never stack; the best one counts.
--]]

local data = require('pt_data');

local gear = {};

--[[
* @param ids - array of equipped item ids
* @param cfg - settings
* @return thresh, suppress, counted (array of items), wearing (key -> bool)
--]]
function gear.totals(ids, cfg)
    local worn = {};
    for _, id in ipairs(ids or {}) do
        worn[id] = true;
    end
    local opts = (cfg and cfg.overload and cfg.overload.gear) or {};
    local best = {};      -- slot -> item
    local wearing = {};
    for _, g in ipairs(data.overload_gear) do
        local on = false;
        for _, id in ipairs(g.ids) do
            if (worn[id]) then
                on = true;
            end
        end
        wearing[g.key] = on;
        local o = opts[g.key];
        if (o ~= nil and o.count and (not o.worn_only or on)) then
            local cur = best[g.slot];
            if (cur == nil or (g.thresh or 0) > (cur.thresh or 0)) then
                best[g.slot] = g;
            end
        end
    end
    local thresh, suppress, counted = 0, false, {};
    for _, g in ipairs(data.overload_gear) do
        if (best[g.slot] == g) then
            thresh = thresh + (g.thresh or 0);
            if (g.suppress) then
                suppress = true;
            end
            counted[#counted + 1] = g;
        end
    end
    return thresh, suppress, counted, wearing;
end

return gear;
