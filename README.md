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
- **Job ability recasts** – Activate, Repair and Deus Ex Automata (plus optional Deactivate,
  Ventriloquy, Role Reversal, Overdrive …), shown **only while they are on cooldown**.
- Only things that are actually running are shown; the window hides itself when nothing is.
- Everything is configurable in game with **`/pupt`**, saved per character.

PupTimers only reads data the game client already has. It never sends anything to the server and
never performs an action for you.
---

## Install

1. Download `puptimers.zip` from the [Releases page](https://github.com/Kahoma/puptimers/releases)
   and copy the `puptimers` folder inside it into your HorizonXI Ashita addons folder, e.g.
   `HorizonXI\Game\addons\puptimers\puptimers.lua`. (If you use GitHub's "Download ZIP"
   instead, rename the `puptimers-main` folder to `puptimers`: Ashita needs the folder name to
   match.)
2. In game: `/addon load puptimers`
3. To load it automatically, add `/addon load puptimers` to your Ashita script
   (for HorizonXI usually `HorizonXI\Game\scripts\default.txt`).

## First-time setup (30 seconds)

1. After loading, the window is **unlocked** and shows sample bars.
2. Drag it where you want it. Drag its **lower-right corner** to change the width (the height
   follows the bars).
3. Type `/pupt lock`. Locked, it is click-through and only appears when something is running.
4. Type `/pupt` to open the settings window for everything else (size, colors, sounds, which
   abilities to track, cooldown values …).

## Commands

| Command | What it does |
|---|---|
| `/pupt` | Open / close the settings window |
| `/pupt show` / `/pupt hide` | Show or hide the timer window |
| `/pupt lock` / `/pupt unlock` | Lock in place (click-through) / allow moving and resizing |
| `/pupt test` | Sample bars + three test alerts (4, 8 and 12 seconds); real cooldowns are left alone |
| `/pupt clear` | Clear running automaton timers |
| `/pupt pet <name>` / `/pupt pet auto` | Set the automaton name by hand / back to auto-detect |
| `/pupt player <name>` / `/pupt player auto` | Set your name by hand / back to auto-detect |
| `/pupt start <ability>` | Start a timer by hand, e.g. `/pupt start economizer` |
| `/pupt resetpos` | Move the timer window back on screen |
| `/pupt status` | Print what PupTimers currently detects (job, names, timers) |
| `/pupt debug` | Toggle debug messages (shows every detection in chat) |

`/puptimers` works as well as `/pupt`.

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
  (they add nothing and could come from another automaton with the same name). When the packet and
  the chat line both report the same use (the chat line can trail by a few seconds during
  animations), it is counted once. Abilities you add yourself can only be read from chat, so a
  same-named automaton in your party can start those bars too.
- **Maneuvers** come from your buff bar (maneuvers have no "wears off" message), and **job ability
  recasts** come straight from the game's recast timers, so those are always exact.

## Maneuver icons

Each active maneuver is a coloured tile with its element symbol (or letters, if you prefer). The
tile drains from the top as the maneuver runs out, the time left is printed under it, and the
oldest maneuver is always on the left. Under the row, one **Maneuver** bar shows the shared
maneuver recast. Icon size, symbols/letters and alignment are on the **Maneuvers** tab, where you
can also switch back to one bar per maneuver.

Maneuvers last a flat 60 seconds on HorizonXI and share a 10-second recast. The time left is
measured from the moment you used the maneuver, and the recast bar comes straight from the game's
recast timer. Maneuvers that were already up when the addon loaded get their real remaining time
from the game's buff timers. If you play on a server where maneuvers get longer during battle
(newer LandSandBoat code does that), tick "Use the game's buff timers for every maneuver".

## Overload estimate

How the server works (LandSandBoat 2021-2023, the code HorizonXI is built on):

- Every element has its own **burden**. A maneuver adds 15 (20 if your stat for that element is
  lower than your automaton's; Dark: 10, or 15 if your MP is lower than the automaton's).
- Burden **cools by 1 every 3 seconds** (Heatsink: 3/5/6/7 with 0/1/2/3 Water Maneuvers up).
- An overload is only possible above the **threshold**: 30, +5 for Puppetry Dastanas (+1), +5 for
  Buffoon's Collar (+1). Kenkonken divides the burden each maneuver adds by 3.
- After every maneuver the game reports **"<you>'s Fire Maneuver overload chance is N%."** where
  N = burden − threshold + 5 (and "… <you> is overloaded!" when it overloads). An overload lasts
  N − 5 seconds and removes all maneuvers.
- **Activating** the automaton (or zoning with it) starts every element at **30 burden**, so the
  first maneuver right after Activate already has roughly a 20-25% chance to overload. PupTimers
  spots a new automaton from the Activate / Deus Ex Automata recast starting as well as from the
  automaton appearing, so a quick Deactivate → Activate is caught too.
- **Overdrive** adds 5000 to the threshold, so nothing can overload while it is up, but burden keeps
  building. During Overdrive the bars show the chance that will apply once it ends, marked
  **"after OD"**.

What PupTimers does: it reads that N from the game's action data (or the chat line) after each maneuver,
which pins that element's burden exactly, then lets every element cool at the server's rate. Each
element gets its own bar, e.g. **"Overload Fire 12% · next 32%"**: 12% is what the game would report
now, 32% is the chance if you used another Fire Maneuver right now. The bar shrinks as it cools and
disappears at 0%. Burden from activating the automaton (all elements at 30) shows as one
"Overload all" bar until you start using maneuvers. It learns how much burden your maneuvers really
add from consecutive reports, so stat differences are picked up automatically.

If your automaton was already out when PupTimers loaded, its burden is unknown (it is not 0), so a
dim **"Overload unknown since load"** line sits above the bars until the game reports a chance
(after your next maneuver), a new automaton is called, or 3 minutes have passed.

Options (Overload tab): one bar per element or only the riskiest; bars that vanish at 0% or stay
until the burden has fully cooled (that style draws a white threshold line and keeps showing the
next-maneuver risk); colour by risk or by element; the % that fills a bar.

**Gear and attachments** (Overload tab): every item has its own checkbox, so you decide what
counts. Gear (Puppetry Dastanas / +1, Buffoon's Collar / +1, Kenkonken) can count **only while
worn** (read from the game every 2 seconds) or **always**. Pick "always" if a macro swaps it in
just for the maneuver. Attachments (Heatsink, Tactical Processor) can't be read by addons, so tick
the ones you use. The tab also shows a live table of every element's estimated burden and chances,
and the server constants (tick, threshold, burden per maneuver, activation burden) are editable
under "Show server constants" if your server differs.

The estimate is only as good as the server matching LandSandBoat; HorizonXI's code is private, so
treat it as a strong guide rather than a guarantee. The 3-second cooling tick runs on the server's
clock, so between reports the estimate can be off by about one tick.

## Default automaton cooldowns

Values come from the LandSandBoat server scripts (the code HorizonXI is built on). They have been
unchanged since 2020 except Reactive Shield (65s until mid-2026, 60s after). If your server
differs, change the value on the **Automaton** tab — or add any ability that is missing.

| Ability | Granted by | Maneuver | Cooldown |
|---|---|---|---|
| Provoke | Strobe / Strobe II | Fire | 30s |
| Eraser | Eraser | Light | 30s |
| Flashbulb | Flashbulb | Light | 45s |
| Reactive Shield | Reactive Shield | Fire | 65s |
| Replicator | Replicator | Wind | 60s |
| Disruptor | Disruptor | Dark | 60s |
| Regulator | Regulator | Dark | 60s |
| Heat Capacitor | Heat Capacitor / II | Fire | 90s |
| Shock Absorber | Shock Absorber / II / III | Earth | 3:00 |
| **Mana Converter** | Mana Converter | Dark | 3:00 |
| **Economizer** | Economizer | Dark | 3:00 |
| Barrage Turbine | Barrage Turbine | Wind | 3:00 |
| Shield Bash | Valoredge Frame | – | 3:00 (Barrier Module: −5/10/15s with maneuvers) |

Mana Converter and Economizer only fire while your automaton's MP is low and Dark Maneuvers are
up. Automaton weapon skills have no cooldown (they use TP), so they are not tracked.

## Settings window (`/pupt`)

- **General** – detected job/names, name overrides, lock/hide options, detection sources, test
  tools, and clearing the automaton bars when it leaves or a new one is called (the server builds a
  new automaton, with every ability ready, on Activate, Deus Ex Automata and when it follows you
  into a new zone).
- **Automaton** – turn each ability on/off, edit its cooldown and color, alert on/off, a Test
  button (a sample bar; running cooldowns are not changed), add your own abilities, and a list of
  abilities your automaton used that are not tracked yet (one click to add).
- **Maneuvers** – icons or bars, icon size / symbols / alignment, duration (60s), optional game
  buff timers, empty slots, recast bar, overload warning, "about to expire" warning, colors.
- **Overload** – one bar per element or only the riskiest, vanish at 0% or when fully cooled,
  colours, risk warning, gear and attachment checkboxes, live estimate table, server constants.
- **Recasts** – which job abilities to show and alert on.
- **Appearance** – overall size, bar height/spacing, padding, rounding, opacity, width/position,
  time format (1:05 or 65s), bars that empty or fill, sort order, section order, colors.
- **Alerts** – chat message, sound (any `.wav` you drop in `sounds\`), optional READY bars.

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
- Game memory (buffs, recasts, automaton, gear) is read 10 times a second, gear every 2 seconds.
- Settings are written to disk only after a change, at most once a second.
- Every event handler is guarded: if something unexpected happens, it is reported in chat at most
  once every 10 seconds and the game carries on.

## Troubleshooting

- **No bars at all:** `/pupt status` — PUP must be your main or support job (or turn off
  "Only show while Puppetmaster…" on the General tab). `/pupt unlock` shows sample bars.
- **Window off screen:** `/pupt resetpos`.
- **An ability never shows up:** `/pupt debug`, then watch chat when your automaton uses it.
  Abilities that are not in the list appear under "Seen from your automaton but not tracked"
  on the Automaton tab.
- **A cooldown is a few seconds off:** edit it on the Automaton tab.
- **"Could not read your settings file":** the file was broken (usually by a hand edit), so it was
  renamed to `settings.lua.bad` and the defaults are used. Your other characters are not affected.

## Files

```
puptimers/
  puptimers.lua   addon entry: events, commands, game reading
  pt_core.lua     tracking logic (no game dependencies)
  pt_overload.lua burden / overload estimator (no game dependencies)
  pt_gear.lua     gear that changes overload
  pt_data.lua     ability / maneuver / recast / gear data and default settings
  pt_ui.lua       timer window and settings window
  sounds/         ready.wav, chime.wav (add your own .wav files here)
```
