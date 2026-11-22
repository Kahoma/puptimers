--[[
* PupTimers - the automaton's setup as the game reports it.
*
* The server sends packet 0x044 ("job extra") with the automaton's head, frame, 12 attachment slots,
* exact HP / MP and stats. The client needs it for the automaton menus, so it arrives on its own:
* at zone-in and login, whenever your buffs change (every maneuver), and on most automaton updates
* in a fight (a few times a second at most). PupTimers only reads it.
*
* Layout (bytes from the start of the packet, header included; Lua index = offset + 1):
*   0x04 job (18 = PUP)   0x05 1 on the support-job copy
*   0x08 head (1-6)       0x09 frame (0x20-0x23)    0x0A-0x15 attachment slots (0 = empty)
*   0x68 HP  0x6A max HP  0x6C MP  0x6E max MP      (u16; HP is sent as max HP while it is 0)
*   0x80 + 4i base stat, 0x82 + 4i stat bonus (signed), i = STR DEX VIT AGI INT MND CHR
--]]

local setup = {};

setup.PUP_JOB = 18;
setup.MIN_SIZE = 0x9C;   -- everything read below lies before this

local function u16(s, i)
    local a, b = s:byte(i, i + 1);
    return a + b * 256;
end

local function s16(s, i)
    local v = u16(s, i);
    return (v >= 32768) and (v - 65536) or v;
end

function setup.new()
    return {
        known      = false,  -- a PUP 0x044 was read
        head       = 0,
        frame      = 0,
        slots      = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        hp = 0, max_hp = 0, mp = 0, max_mp = 0,
        stat_base  = { 0, 0, 0, 0, 0, 0, 0 },
        stat_bonus = { 0, 0, 0, 0, 0, 0, 0 },
    };
end

--[[
* Reads a 0x044 packet into st (no tables or strings are made unless the setup itself changed).
* @return true if it carried PUP data, and whether head/frame/attachments changed.
--]]
function setup.parse(st, data)
    if (type(data) ~= 'string' or #data < setup.MIN_SIZE) then
        return false, false;
    end
    if (data:byte(5) ~= setup.PUP_JOB) then
        return false, false;
    end
    local changed = (not st.known);
    local head, frame = data:byte(9, 10);
    if (head ~= st.head or frame ~= st.frame) then
        changed = true;
    end
    st.head, st.frame = head, frame;
    local slots = st.slots;
    for i = 1, 12 do
        local b = data:byte(10 + i);
        if (slots[i] ~= b) then
            slots[i] = b;
            changed = true;
        end
    end
    st.hp, st.max_hp = u16(data, 105), u16(data, 107);
    st.mp, st.max_mp = u16(data, 109), u16(data, 111);
    local base, bonus = st.stat_base, st.stat_bonus;
    for i = 0, 6 do
        base[i + 1] = u16(data, 129 + 4 * i);
        bonus[i + 1] = s16(data, 131 + 4 * i);
    end
    st.known = true;
    return true, changed;
end

-- The automaton's total for stat i (1 STR, 2 DEX, 3 VIT, 4 AGI, 5 INT, 6 MND, 7 CHR).
function setup.stat(st, i)
    return (st.stat_base[i] or 0) + (st.stat_bonus[i] or 0);
end

-- True when an attachment (by its 0x044 byte) is in one of the 12 slots.
function setup.has(st, byte)
    if (not st.known or byte == nil) then
        return false;
    end
    local slots = st.slots;
    for i = 1, 12 do
        if (slots[i] == byte) then
            return true;
        end
    end
    return false;
end

return setup;
