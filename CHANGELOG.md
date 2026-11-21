# Changelog

## 1.1.0

### New

- **Your automaton's setup, read from the game:** frame, head, all 12 attachments, exact HP/MP and
  stats, from the data the game client already receives for the automaton menus (packet 0x044).
  `/pupt status` lists the setup.
- **Attachment-aware abilities:**
  - The Automaton tab lists only the abilities your setup can use ("Show every ability" lists the
    rest).
  - A dim "Unpowered: Provoke (Fire)" line names equipped abilities whose maneuver is not up, with
    an optional alert (off by default).
  - READY bars say what they need, e.g. "needs Fire".
  - Chat explains maneuvers an attachment used up, which the game does not show: Economizer,
    Replicator, Eraser, Flame Holder, Ice Maker, Condenser and Schurzen.
  - The Unpowered line, its alert and the chat notes each have an option on the Maneuvers tab.
- **Heatsink** is taken from the setup for the overload estimate.
- **Burden per maneuver from stats:** PupTimers works out what each maneuver should add from your
  stats and your automaton's. It uses that only after it has matched the game's own reports twice,
  and only while your gear and buffs have not changed since the game last sent your stats (gear
  swapped in right before a maneuver counts too). Otherwise it learns the value from the game's
  reports, as before.
- **Automaton HP and MP bars** (optional), with marks for where Economizer, Mana Converter and
  Replicator fire while their maneuvers are up.
- **Repair helper:**
  - The Repair bar shows the oil in your ammo slot and how many more you carry, e.g.
    "Repair (Oil+1 x5, 12 more)".
  - You are told when Repair is ready but no oil is equipped, and when Repair uses the last oil of
    the equipped stack (taking the oil off is not running out).
  - An optional reminder fires when automaton HP falls to a % you choose while Repair is ready.
- **Deactivate hint** when the automaton is at exactly full HP while Activate is cooling down.
- **Maneuver timers: Auto / Game / Flat.**
  - Auto counts 60 seconds from each maneuver.
  - If a maneuver ever lasts longer, Auto says so once and follows the game's buff timers from then
    on.
- **Profiles:**
  - Save, load and delete named profiles; they are shared by all your characters.
  - Choose a profile for each automaton frame and tick "Load the profile chosen below when the
    automaton's frame changes" to switch with the frame.
  - Copy another character's settings with `/pupt copyfrom <character>`.
  - The window position, lock, the way new bars grow and names stay with each character.
  - The profiles file and other characters' settings files are read by PupTimers' own parser, which
    only understands plain data: nothing in them is ever run.
- **Colours:**
  - Every colour can be changed, including the overload risk colours.
  - Colour-blind friendly and High contrast schemes.
- **Layout:**
  - New bars can grow up (for a window above the chat log) or down.
  - The window can hide during cutscenes.
  - Narrow windows use short names.
- **Reset:** a "Reset all settings" button and `/pupt defaults`.
- **`/pupt status`** shows the version, the maneuver timer mode, where the burden numbers come from,
  your automaton's setup and the last error.
- README section "What PupTimers reads, and what it never does", for approval reviewers.
- MIT licence and this changelog.

### Changed

- **Current server rules.** PupTimers now uses LandSandBoat's Puppetmaster rules for this era as of
  mid-2026. HorizonXI moved to LandSandBoat code in January 2026, before these rules were added
  there; its wiki has since been updated "to match server data" with some of the same values (such
  as Reactive Shield's 60 seconds), but the rest is not confirmed for HorizonXI. The burden each
  maneuver adds is only used once the game's own overload reports confirm it, and the other values
  can be changed in the settings:
  - an automaton starts at 35 burden (was 30);
  - a maneuver adds 14 to 20 burden depending on stats;
  - a Dark Maneuver adds 8 with a Valoredge or Sharpshot frame, 14 with the others;
  - Heatsink adds +1 cooling per tick (adjustable; the older "more with each Water Maneuver" rule
    can be switched on);
  - Reactive Shield's cooldown is 60 seconds (was 65).

  Settings still at the old defaults are updated automatically; values you changed yourself are
  kept.
- The Tactical Processor checkbox was removed. No server code PupTimers knows of changes the
  overload threshold for it: this era's code gives it −5, but on the automaton, and the overload
  check only reads your own threshold.
- Kenkonken also divides the burden a new automaton starts with by 3, as the server does.
- Abilities ticked "On act." also start when the server re-creates the automaton after a zone, as
  newer server code puts them on cooldown then too.
- Disruptor, Regulator, Heat Capacitor and Barrage Turbine cannot be obtained on HorizonXI, so they
  are hidden unless you choose "Show every ability".
- Barrier Module was removed.
- Overload numbers that are PupTimers' estimate are marked with "~".
- Problems are reported in one plain line, at most once a minute.
  - If reading action data or chat keeps failing, that part turns itself off and the rest keeps
    working.
  - `/pupt status` shows the last problem.
- Deploy and Retrieve bars use a 10-second recast.

### Fixed

- Turning off the overload estimate left its risk warning on.
- A line typed in chat, such as `/em uses Fire Maneuver.`, could count as a maneuver. Say, shout,
  tell, party, linkshell, emote and other conversation lines are now never read as actions.
- PupTimers kept reading game memory on other jobs. On other jobs it now only checks your job (to
  notice when you are back on Puppetmaster) and tracks nothing.
- "The timer window is unlocked" was printed at every game start, even when your window was locked.
  It now appears only the first time you are on Puppetmaster with the window unlocked.
- An error could repeat every 10 seconds for as long as it lasted.

## 1.0.0

First release:

- automaton ability cooldowns;
- maneuver icons with the shared maneuver recast;
- a per-element overload estimate;
- Puppetmaster job ability recasts;
- the `/pupt` settings window;
- support for Ashita 4.16 and 4.3.
