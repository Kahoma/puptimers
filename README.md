# PupTimers — Puppetmaster timers for HorizonXI (Ashita v4)

A small, movable, resizable timer window for Puppetmaster:

- **Automaton ability cooldowns** – a bar starts the moment your automaton uses an attachment or
  frame ability (Economizer, Mana Converter, Flashbulb, Provoke/Strobe, Shock Absorber, Shield Bash …)
  and disappears when it is ready again, with a chat (and optional sound) alert.
- **Maneuvers** – a row of coloured element icons (oldest on the left = the one a 4th maneuver
  replaces), each with its time left underneath, one shared Maneuver recast bar under the row, and
  an OVERLOADED countdown.
- **Overload estimate** – one bar for every element with an active overload chance, showing the
  chance right now and how risky the *next* maneuver of that element would be. Each bar cools down
  on its own and disappears when that element reaches 0%.
- **Your automaton's setup, read from the game** – PupTimers knows its frame, head and attachments,
  so Heatsink counts for the overload estimate on its own, it can tell you which equipped abilities
  have no maneuver to run on, and it explains maneuvers that an attachment used up.
- **Job ability recasts** – Activate, Repair and Deus Ex Automata (plus optional Deactivate,
  Ventriloquy, Role Reversal, Overdrive …), shown **only while they are on cooldown**. The Repair bar
  shows the Automaton Oil in your ammo slot.
- Optional **automaton HP and MP** bars with Puppetmaster marks (where Economizer, Mana Converter and
  Replicator fire).
- Only things that are actually running are shown; the window hides itself when nothing is.
- Everything is configurable in game with **`/pupt`**, saved per character, with **profiles** you can
  share between characters.

PupTimers only reads data the game client already has. It never sends anything to the server and
never performs an action for you. See [What PupTimers reads](#what-puptimers-reads-and-what-it-never-does).

---

## Install

1. Download `puptimers.zip` from the [Releases page](https://github.com/Kahoma/puptimers/releases)
   and copy the `puptimers` folder inside it into your HorizonXI Ashita addons folder, e.g.
   `HorizonXI\Game\addons\puptimers\puptimers.lua`. Use the release zip: it is the version that was
   reviewed.
2. In game: `/addon load puptimers`
3. To load it automatically, add `/addon load puptimers` to your Ashita script
   (for HorizonXI usually `HorizonXI\Game\scripts\default.txt`).

## First-time setup (30 seconds)

1. The first time you are on Puppetmaster, the window is **unlocked** and shows sample bars
   (headed "Sample bars (/pupt lock)"). On another job, `/pupt unlock` opens the settings window,
   and the timer window shows while it is open.
2. Drag it where you want it. Drag its **lower-right corner** to change the width (the height
   follows the bars).
3. Type `/pupt lock`. Locked, it is click-through and only appears when something is running.
4. Type `/pupt` to open the settings window for everything else (size, colours, sounds, which
   abilities to track, cooldown values …).

## Commands

| Command | What it does |
|---|---|
| `/pupt` | Open / close the settings window |
| `/pupt show` / `hide` / `toggle` | Show or hide the timer window |
| `/pupt lock` / `/pupt unlock` | Lock in place (click-through) / allow moving and resizing |
| `/pupt test` | Sample bars + three test alerts (4, 8 and 12 seconds); real cooldowns are left alone |
| `/pupt clear` | Clear running automaton timers |
| `/pupt pet <name>` / `/pupt pet auto` | Set the automaton name by hand / back to auto-detect (`/pupt pet` alone shows it) |
| `/pupt player <name>` / `/pupt player auto` | Set your name by hand / back to auto-detect (`/pupt player` alone shows it) |
| `/pupt start <ability>` | Start a timer by hand, e.g. `/pupt start economizer` |
| `/pupt profile` | List your profiles |
| `/pupt profile <name>` | Load a profile (handy in a macro; capitals do not matter) |
| `/pupt profile save <name>` / `delete <name>` | Save the current settings as a profile / delete one |
| `/pupt copyfrom <character>` | Copy another character's PupTimers settings |
| `/pupt resetpos` | Move the timer window back on screen |
| `/pupt status` | Version, what PupTimers detects, your automaton's setup, the last error |
| `/pupt debug` | Toggle debug messages (shows every detection in chat) |
| `/pupt defaults` | Every setting back to its default |

`/puptimers` works as well as `/pupt`. Any of these can go on a key with Ashita's `/bind` command.

## Names (works for anyone)

Your character name and your automaton's name are read from the game automatically, and the
automaton name is remembered per character (so it works right after a reload even before you
call the automaton). If detection ever picks the wrong name, set it on the **General** tab or with
`/pupt pet <name>`.

## How detection works (one or two chat windows)

PupTimers does **not** read the chat windows on your screen, so a single log window (laptop) and a
split two-window log (PC) behave exactly the same:

- **Action packets (default, recommended):** the combat data the game uses to write those chat
  lines. It identifies *your* automaton by its unique id, so other players' automatons — even ones
  with the same name — are ignored, and it still works if your chat filters hide pet messages.
- **Chat text:** Ashita's incoming-text event, which sees each line once before the game decides
  which log window shows it. Needed for abilities you add yourself, and a backup for a built-in
  ability until the packets have reported it once; after that, chat lines about it are ignored
  (they add nothing and could come from another automaton with the same name). Lines in say,
  shout, tell, party, linkshell, emote and other conversation channels are never read as actions.
  Abilities you add yourself can only be read from chat, so a same-named automaton in your party
  can start those bars too.
- **Maneuvers** come from your buff bar and its timers (maneuvers have no "wears off" message), and
  **job ability recasts** come straight from the game's recast timers, so those are always exact.
- **Your automaton's setup** (frame, head, attachments, exact HP/MP and stats) comes from the data
  the game sends for the automaton menus. It arrives when you zone or log in and with each maneuver
  you use; until then `/pupt status` says it is not read yet.

## Maneuver icons

Each active maneuver is a coloured tile with its element symbol (or letters, if you prefer). The
tile drains from the top as the maneuver runs out, the time left is printed under it, and the
oldest maneuver is always on the left. Under the row, one **Next maneuver** bar shows the shared
maneuver recast. Icon size, symbols/letters and alignment are on the **Maneuvers** tab, where you
can also switch back to one bar per maneuver.

Maneuvers last 60 seconds on HorizonXI and share a 10-second recast. With **Maneuver timers: Auto**
(the default) each maneuver counts from the moment you used it, which needs no clock. Should one
ever last longer than 60 seconds (some server versions lengthen maneuvers in long fights), PupTimers
says so once and follows the game's own buff timers from then on; `/pupt status` shows which it is
doing. Maneuvers that were already up when the addon loaded always get their time from the game.

## Overload estimate

How the server works, by LandSandBoat's code for this era as of mid-2026. HorizonXI moved to
LandSandBoat code in January 2026, before these Puppetmaster rules were added there. Its wiki has
since been updated "to match server data" with some of the same values (such as Reactive Shield's
60 seconds), but the rest is not confirmed for HorizonXI. PupTimers checks the burden each maneuver
adds against the game's own reports, and the other values can be changed under "Show server
constants" on the Overload tab:

- Every element has its own **burden**. A newly activated automaton (Activate, Deus Ex Automata, or
  after zoning with it) starts at **35** in every element.
- A maneuver adds **14 to 20**: 20 if your stat for that element (Fire STR, Ice INT, Wind AGI,
  Earth VIT, Thunder DEX, Water MND, Light CHR) is below your automaton's, 19 to 16 when it is 0 to 3
  points above, 14 when it is 4 or more above. A **Dark** Maneuver adds 8 with a Valoredge or
  Sharpshot frame and 14 with the others.
- Burden **cools by 1 every 3 seconds** (Heatsink adds to that; see below).
- An overload is only possible above the **threshold**: 30, +5 for Puppetry Dastanas (+1), +5 for
  Buffoon's Collar (+1) (the HorizonXI wiki says the Collar is not active there yet). Kenkonken
  divides every burden gain by 3, the activation burden included. (This era's code also gives
  Tactical Processor −5 threshold, but puts it on the automaton, and the overload check only reads
  yours, so it changes nothing and PupTimers ignores it.)
- After every maneuver the game reports **"<you>'s Fire Maneuver overload chance is N%."** where
  N = burden − threshold + 5 (and "… <you> is overloaded!" when it overloads). An overload lasts
  burden − threshold seconds and removes all maneuvers. Condenser uses up a Water Maneuver instead
  of letting a maneuver overload.
- **Overdrive** adds 5000 to the threshold, so nothing can overload while it is up, but burden keeps
  building. During Overdrive the bars show the chance that will apply once it ends, marked
  **"after OD"**.

What PupTimers does: it reads that N from the game's action data (or the chat line) after each
maneuver, which pins that element's burden exactly, then lets every element cool at the server's
rate. Each element gets its own bar, e.g. **"Overload Fire ~12% · next ~32%"**: 12% is what the game
would report now, 32% is the chance if you used another Fire Maneuver right now. The **~** marks
numbers that are PupTimers' estimate between the game's reports. A bar shrinks as it cools and
disappears at 0%. Burden from activating the automaton shows as one "Overload all" bar for the
elements you have not used since; it goes away when their burden has cooled to 0% (about 30 seconds
at 35).

**Burden per maneuver from stats:** PupTimers reads your stats and your automaton's, works out what
each maneuver should add by the server rules above (and by the older rule from LandSandBoat code
before mid-2026: 15 or 20, Dark 10 or 15 by MP), and checks both against the game's own reports. A
rule is used only once it has matched the reports twice, and only while your gear and buffs are
unchanged since the game last sent your stats (gear swapped in right before a maneuver counts too);
otherwise PupTimers learns the value from consecutive reports, as before. `/pupt status` and the
Overload tab say which it is using.

If your automaton was already out when PupTimers loaded, its burden is unknown (it is not 0), so a
dim **"Overload unknown since load"** line sits above the bars until the game reports a chance
(after your next maneuver), a new automaton is called, or 3 minutes have passed.

Options (Overload tab): one bar per element or only the riskiest; bars that vanish at 0% or stay
until the burden has fully cooled (that style draws a white threshold line and keeps showing the
next-maneuver risk); colour by risk or by element; the % that fills a bar; a warning when the next
maneuver would be risky. Turning the estimate off stops all of it, warnings included; the
OVERLOADED countdown still works because it comes from your buff timers.

**Gear and attachments** (Overload tab): every gear item has its own checkbox, and can count **only
while worn** (read from the game every 2 seconds) or **always** — pick "always" if a macro swaps it
in just for the maneuver. **Heatsink** is taken from your automaton's setup (or ticked by hand until
it is read). It adds +1 cooling per tick on current server code; the HorizonXI wiki's tested table
differs, so the amount is adjustable, and the older "more with each Water Maneuver" rule
(+2/+4/+5/+6 per tick, LandSandBoat code until May 2025) can be switched on. The tab also shows a live table of every
element's estimated burden and chances, and the server constants (tick, threshold, activation
burden …) are editable under "Show server constants" if your server differs.

The estimate is only as good as the server matching this code; HorizonXI's own code is private, so
treat it as a strong guide rather than a guarantee. The 3-second cooling tick runs on the server's
clock, so between reports the estimate can be off by about one tick.

## Your automaton's attachments

Once the setup is read from the game:

- **Unpowered abilities:** a dim line under the maneuver icons names equipped abilities that cannot
  fire because their maneuver is not up, e.g. "Unpowered: Provoke (Fire)" (in a narrow window:
  "Needs Fire"). An optional alert (off by default) tells you when losing a maneuver leaves one
  unpowered. Both are on the Maneuvers tab.
- **READY bars** (if you keep them on screen) say what they need, e.g. "needs Fire".
- **Maneuvers an attachment used up** are explained in chat, because the game shows nothing:
  Economizer (all Dark), Replicator (all Wind), Eraser (every maneuver on current server code, Light
  ones on older code), Flame Holder (Fire, for the automaton's weapon skill), Ice Maker (Ice, for its
  elemental spell), Condenser (a Water Maneuver instead of an overload), Schurzen (an Earth Maneuver
  to survive a fatal hit). Maneuvers that were already up when PupTimers loaded are left out until
  the game has sent their timers, because PupTimers cannot tell whether they simply ran out. Flame
  Holder and Ice Maker are explained once per session, since using up those maneuvers is what they
  are for. These notes can be turned off on the Maneuvers tab.
- The **Automaton** tab lists only the abilities your setup can use ("Show every ability" lists the
  rest).
- **Profiles can follow the frame:** on the Profiles tab, tick "Load the profile chosen below when
  the automaton's frame changes" and pick a profile for each frame.

## Automaton HP, MP and Repair

Optional thin **HP and MP bars** for your automaton (Automaton tab), with marks while the matching
maneuvers are up: on the MP bar where Economizer (below 50/40/30% MP with 1/2/3 Dark Maneuvers, as
tested on HorizonXI) and Mana Converter (below 40/60/65%) will fire, on the HP bar where Replicator
fires (50%, or 75% with Damage Gauge). If you use them, you can turn off the automaton part of
another addon's pet bar.

- **Repair reminder:** a chat/sound reminder when your automaton's HP falls to a % you choose while
  Repair is ready.
- **Automaton Oil:** the Repair bar shows the oil in your ammo slot and how many more you carry, e.g.
  "Repair (Oil+1 x5, 12 more)". You are told when Repair is ready with no oil equipped, and when
  Repair uses the last oil of the equipped stack (taking the oil off is not running out).
- **Deactivate hint:** while Activate cools down, a line appears when your automaton is at exactly
  full HP — deactivating it then resets the Activate recast. PupTimers uses the exact HP the game
  sends, not the HP %.

## Default automaton cooldowns

Values come from the LandSandBoat server scripts and the HorizonXI wiki. If your server differs,
change the value on the **Automaton** tab — or add any ability that is missing.

| Ability | Granted by | Maneuver | Cooldown |
|---|---|---|---|
| Provoke | Strobe | Fire | 30s |
| Eraser | Eraser (uses up your maneuvers) | Light | 30s |
| Flashbulb | Flashbulb | Light | 45s |
| Reactive Shield | Reactive Shield | Fire | 60s (65s on older server code) |
| Replicator | Replicator (uses up Wind Maneuvers) | Wind | 60s |
| Shock Absorber | Shock Absorber | Earth | 3:00 |
| **Mana Converter** | Mana Converter | Dark | 3:00 |
| **Economizer** | Economizer (uses up Dark Maneuvers) | Dark | 3:00 |
| Shield Bash | Valoredge Frame | – | 3:00 |

Mana Converter and Economizer only fire while your automaton's MP is low and Dark Maneuvers are up.
Disruptor, Regulator, Heat Capacitor and Barrage Turbine are not obtainable on HorizonXI; they are
kept for other servers and hidden unless you choose "Show every ability". Automaton weapon skills
have no cooldown (they use TP), so they are not tracked.

Newer server code puts every attachment ability on cooldown whenever the automaton is built
(Activate, Deus Ex Automata, or after zoning with it); the HorizonXI wiki says Shock Absorber can be
used right after Activate, so that is off by default. If you see it happen, tick "On act." for the
ability on the Automaton tab.

## Settings window (`/pupt`)

- **General** – detected job/names, name overrides, lock/hide options, detection sources, test
  tools, clearing the automaton bars when it leaves or a new one is called (the server builds a new
  automaton on Activate, Deus Ex Automata and when it follows you into a new zone), and "Reset all
  settings". Buttons that cannot be undone (reset, restore defaults, colour schemes, deleting a
  profile, copying settings) ask for a second click.
- **Automaton** – turn each ability on/off, edit its cooldown and colour, alert on/off, a Test button
  (a sample bar; running cooldowns are not changed), add your own abilities, a list of abilities
  your automaton used that are not tracked yet ("Track it" fills in the name: enter the cooldown and
  press Add), and the HP/MP and Repair options.
- **Maneuvers** – icons or bars, icon size / symbols / alignment, duration and timer mode, empty
  slots, recast bar, overload warning, "about to expire" warning, the Unpowered line and its alert,
  the used-up maneuver notes, colours.
- **Overload** – one bar per element or only the riskiest, vanish at 0% or when fully cooled,
  colours, risk warning, gear and attachments, Heatsink, burden from stats, live estimate table,
  server constants.
- **Recasts** – which job abilities to show and alert on. The times are the game's own recast
  timers. (Deus Ex Automata is on the HorizonXI wiki, but no patch note confirms it; if the server
  does not have it, its bar simply never appears.)
- **Appearance** – overall size, bar height/spacing, padding, rounding, opacity, width/position, time
  format (1:05 or 65s), bars that empty or fill, sort order, section order, grow up or down, hide
  during cutscenes, and colours (including **Colour-blind friendly** and **High contrast** schemes).
- **Alerts** – chat message, sound (any `.wav` you drop in `sounds\`), optional READY bars.
- **Profiles** – save, load and delete profiles, pick one per automaton frame, and copy another
  character's settings.

A number you type (a cooldown, the maneuver duration, a size or position, an overload constant) is
stored when you press Enter or Tab or click elsewhere; the +/- buttons store it when you let go.

## Profiles

A profile is a saved copy of your PupTimers settings: the look, alerts, tracked abilities and the
maneuver and overload options. Profiles are kept in one file shared by all your characters
(`config\addons\puptimers\profiles.lua`), so you can save one on one character and load it on
another. The window position, lock, the way new bars grow and names always stay with each
character. You can also copy another character's settings directly (Profiles tab or
`/pupt copyfrom <name>`).

Both files are read by a small parser that only understands plain data (text, numbers, true/false
and tables): nothing in them is ever run, so a damaged or edited file can only be refused.

## Compatibility

Works with both Ashita builds HorizonXI players run: **4.16 and older (ImGui 1.80)** and
**4.3+ (ImGui 1.92)**. It only uses ImGui calls available in both and detects how to scale text.
Names containing `%` are displayed safely on both builds.

## Light on resources

PupTimers is built to stay out of the way in busy fights and crowded zones:

- Drawing the timer window creates no Lua garbage, so it never makes the garbage collector work
  harder frame after frame. The list of bars is rebuilt 10 times a second, and the bars still move
  smoothly in between.
- Everyone else's actions are skipped after a 4-byte check, and other people's chat lines after a
  couple of plain text searches. Only your own and your automaton's lines are read in full.
- Game memory (buffs, recasts, automaton) is read 10 times a second; gear and the oil in your ammo
  slot every 2 seconds (the inventory is only counted again when the game says it changed).
- On any other job PupTimers only checks your job, name and status (to notice when you are back on
  Puppetmaster); it tracks nothing and reads nothing else.
- Settings are written to disk only after a change (at most once a second, or at once when you close
  the settings window with a change not yet written), when PupTimers is loaded or unloaded, and at
  login and logout (Ashita's settings library does those two).
- Every event handler (drawing, packets, chat and `/pupt` commands) is guarded: a problem is reported
  in one plain line, at most once a minute, and the game carries on. If reading action data or chat
  keeps failing, that part switches itself off and the other keeps working.

## What PupTimers reads, and what it never does

For HorizonXI staff and anyone who wants to check. Everything below is data your game client
already receives; PupTimers only looks at it.

| What | Why |
|---|---|
| Incoming action packets (0x028) | your automaton's abilities and your maneuvers (with their overload chance). Everyone else's are skipped after a 4-byte id check. |
| Incoming status timers (0x063, type 9) | the end times of your own buffs (maneuvers, Overload) |
| Incoming automaton data (0x044) | your automaton's frame, head, attachments, HP/MP and stats |
| The arrival of your stats packet (0x061) | to know when your stats in memory were last sent |
| Incoming chat lines | "<automaton> uses …" and overload lines, as a backup and for abilities you add |
| Memory: your own job, buffs, recasts, name and entity, your MP and stats, your automaton's entity and MP % | timers, recasts, names, the automaton being out, cutscenes, the HP/MP bars |
| Memory: your equipped items and the Automaton Oil in your inventory | overload gear and the Repair oil helper |
| One read-only clock signature (the same one XIUI uses) | the server time for buff end times |
| Its own settings file, through Ashita's settings library (which loads it as Lua, as for every addon that uses the library) | its settings |
| `profiles.lua`, and another character's PupTimers settings when you copy them | profiles. Read as plain data by PupTimers' own parser: nothing in them is ever run |
| The names of the folders in `config\addons\puptimers\`, and whether each has a `settings.lua` (only while the Profiles tab is open, or when you use `/pupt copyfrom`) | the "Copy from another character" list |
| Files written: its own settings (through Ashita's settings library), `profiles.lua` (written to a temporary file that then replaces it; the temporary file is deleted if that fails, and the folder is created if missing), a damaged `settings.lua` renamed to `settings.lua.bad` (replacing an older one) | saving settings and profiles |
| Sounds: `.wav` files in its own `sounds` folder, off by default | optional alerts |

Ashita's settings library, which PupTimers uses like most addons, also reads the login packets
(0x00A and 0x00B) to pick each character's settings file.

PupTimers **never** sends, blocks or changes a packet, never queues or presses a command, never
writes game memory, never uses the network, and only blocks its own `/pupt` command. Everything it
shows is a reminder; the game and the automaton's own AI decide what happens. The overload numbers
marked **~** are PupTimers' estimate; recasts and buff times are the game's.

## Troubleshooting

- **No bars at all:** `/pupt status` — PUP must be your main or support job (PupTimers tracks
  nothing on other jobs). `/pupt unlock` shows sample bars.
- **Window off screen:** `/pupt resetpos`.
- **An ability never shows up:** `/pupt debug`, then watch chat when your automaton uses it.
  Abilities that are not in the list appear under "Seen from your automaton but not tracked"
  on the Automaton tab.
- **"Automaton setup: not read yet":** it arrives when you zone and with your next maneuver.
- **A cooldown is a few seconds off:** edit it on the Automaton tab.
- **"Could not read your settings file":** the file was broken (usually by a hand edit), so it was
  renamed to `settings.lua.bad` and the defaults are used. Your other characters are not affected.
- **"The profiles file could not be read":** PupTimers leaves a damaged `profiles.lua` alone and
  saves nothing over it. Delete or fix the file to start again.
- **"Stopped reading action data (or chat lines) after repeated problems":** everything else keeps
  working; `/addon reload puptimers` tries again, and `/pupt status` shows the last error.

## Files

```
puptimers/
  puptimers.lua   addon entry: events, commands, game reading
  pt_core.lua     tracking logic (no game dependencies)
  pt_overload.lua burden / overload estimator (no game dependencies)
  pt_setup.lua    the automaton's setup from the game (packet 0x044)
  pt_profiles.lua settings profiles and copying settings between characters
  pt_gear.lua     gear that changes overload
  pt_data.lua     ability / attachment / maneuver / recast / gear data and default settings
  pt_ui.lua       timer window and settings window
  sounds/         ready.wav, chime.wav (add your own .wav files here)
  README.md, CHANGELOG.md, LICENSE
```

## Licence

MIT — see [LICENSE](LICENSE). The two sounds are simple tones generated for PupTimers.
