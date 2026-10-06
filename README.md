# Run Logger

A stats tracker for *The Binding of Isaac: Repentance*. It logs every run and shows aggregated stats in an in-game window: which items you pick up and how they do, what damages you, how deep you get, and which transformations you reach, with filters by character and mode.

> Unofficial fan-made mod. It is not affiliated with or endorsed by the creators or publisher of *The Binding of Isaac*.

**Steam Workshop:** [(https://steamcommunity.com/sharedfiles/filedetails/?id=3812241982)]

<img width="1142" height="704" alt="Screenshot 2026-10-05 220909" src="https://github.com/user-attachments/assets/b47de6f4-580d-4abc-8f6c-e078e8a334c5" />
<img width="977" height="701" alt="Screenshot 2026-10-05 220920" src="https://github.com/user-attachments/assets/a0924b35-73c5-4b44-8af6-9b583a1bf258" />
<img width="995" height="700" alt="Screenshot 2026-10-05 221000" src="https://github.com/user-attachments/assets/dd67f146-2330-4755-9e89-2435aa2b361d" />
<img width="974" height="703" alt="Screenshot 2026-10-05 220935" src="https://github.com/user-attachments/assets/4bb8d5e0-9f82-46cd-a154-3ccf31e199d5" />
<img width="981" height="704" alt="Screenshot 2026-10-05 220948" src="https://github.com/user-attachments/assets/10cac5f7-f2d3-45f0-a7a9-2a7f26c623a2" />

## Features

- **Summary:** total runs, win rate, average floor reached, average hits taken, average hits per minute.
- **Items:** times picked up, times seen, encounter rate, pick rate, average floor found, average floor reached, win rate, and hits per minute after pickup. Sortable, ascending or descending.
- **Damage sources:** every source that has hit you (enemies, projectiles, spikes, doors, machines), credited to the enemy behind it where the game says who spawned it.
- **Hits by floor:** average hits per run on each floor, with Caves, Catacombs, Mines and Ashpit kept separate.
- **Transformations:** times obtained, rate, average floor obtained, win rate, and hits per minute after obtaining.
- **Recent runs:** your 50 most recent runs, with what killed you.
- **Filters:** character, mode (Normal, Hard, Greed, Challenges), and a search box for items and sources.
- **Settings:** log size limits and how abandoned runs are handled, stored per save slot.

## Requirements

- *The Binding of Isaac: Repentance*
- [REPENTOGON](https://repentogon.com) (tested with version [1.1.3]). Subscribing to this mod does not install it.

Without REPENTOGON the mod disables itself and writes one line to `log.txt`.

## Install

**Workshop:** subscribe on the Steam Workshop page.

**Manual:** copy this folder into the game's `mods` folder. It needs `main.lua`, `metadata.xml` and, optionally, `entity_names.lua`.

## Using it

Open the console with `~` in a run and type:

| Command | What it does |
|---|---|
| `runlogger ui` | Opens the stats window. Close it with its X; the command opens it again. |
| `runlogger toggletestmode` | Stops logging for this session (for example while attempting The Forgotten unlock). Also a checkbox in the Settings tab. |
| `runlogger status` | Shows whether test mode is on. |
| `runlogger rebuildstats` | Rebuilds the stats from the stored runs. You rarely need this; stats rebuild on their own after an update that changes how they are computed. |
| `runlogger` | Lists the commands. |

Runs are logged automatically once the mod is enabled. The window is empty until you finish a run.

## What the numbers mean

**Items**

| Column | Meaning |
|---|---|
| pickedUp | Times picked up (repeat pickups count). |
| seen | Times the item appeared on a pedestal in a room you entered. |
| encounterRate | Share of runs where it appeared at least once. |
| pickRate | pickedUp / seen, ignoring pedestals seen under Curse of the Blind. |
| avgFloorFound | Mean floor at pickup (standard runs only). |
| avgFloorReached | Mean deepest floor in completed standard runs that held it. |
| winRate | Share of completed runs holding it that were wins. |
| hits/min | Real hits per minute of play after first picking it up (needs 2+ minutes of exposure). |

`--` means there is no data. Pickups can exceed sightings: starting items and items that never sat on a pedestal count as picked up but not seen.

**These are descriptive statistics, not causal ones.** Deeper runs hold more items, so win rate "with an item" says little about the item. Hits per minute depends on when you find the item, since late items are measured in harder rooms.

**How hits are counted**

- An event is a *real hit* if it deals damage and lands after the previous hit's invulnerability window has ended, so fire and creep that tick several times can count as several hits, as the game treats them.
- **Damage you chose to take is not a hit.** Curse-room doors, the Mausoleum door, devil beggars and blood donation machines still appear in the Damage Sources tab, but are left out of every hit figure (average hits, hits per floor, hits per minute). An event is a toll if the game flags it "no penalties", if its source is on a short list (`TOLL_SOURCES` in `main.lua`), or if it is environmental damage logged before damage flags were recorded. Sacrifice-room spikes use the ordinary spikes source, so they still count.
- Greed, Greedier and challenge runs are left out of floor calculations (different structure), but count for other metrics. Filter them out with the Mode dropdown.
- Abandoned runs (quit, restart, Save & Quit) count toward totals but are never wins or losses.

**Damage attribution.** Tears, bombs, lasers, projectiles and effects (creep, fire jets) are credited to whatever spawned them. Labels you may see:

- `Self-inflicted: ...`: spawned by you.
- `... (spawner unknown)`: the game reported no usable spawner.
- `... (legacy)`: logged before spawner tracking existed. Should not occur in current version. 

## Your data

Everything stays on your machine; the mod has no network access.

- Each save slot has its own file, `saveN.dat`, in the game's `data` folder under the mod's folder name ("path\to\The Binding of Isaac Rebirth\data\isaacrunlogger\saveN.dat"). Slots are never merged.
- To back up, copy the file. To reset, delete it. Disabling the mod leaves it in place.
- The file contains your run seeds and timestamps.
- Defaults (Settings tab, per slot): keep 300 runs or 1500 KB of log, whichever comes first; log abandoned runs of at least 60 seconds. Totals keep counting after old runs are trimmed, but a stats rebuild only sees the runs still stored.
- If a slot's file cannot be read, the window shows a warning and the mod will not overwrite it.

**File format.** One file per slot: a small JSON header (`RLOG2 {...}`), the aggregate stats as plain text lines, a `--LOG--` separator, then one JSON run record per line. Stats are plain text because the game's `json.decode` is far too slow on large input: decoding a 225 KB stats object took about 6 seconds, so only small JSON is ever decoded.

## Known limitations

- **Continued runs.** Save & Quit logs the run as abandoned, and Continue starts a new entry with the same seed that holds only what happens afterwards.
- **Co-op is untested.** Hits and pickups from all players are recorded together, and the end-of-run inventory is player 1's.
- **Modded items.** They are logged and shown by name while their mod is installed, but ids can shift if your mod list changes, which can misattribute their stats. Modded characters count under "All characters" but cannot be selected in the filter.
- **Long runs.** A maximum of 300 damage events are kept per run.
- **A couple of damage sources are unidentified** (for example type 0, variant 10000).
- Small samples: with ~700 items, you need very many runs before item-level comparisons mean much.

## Analysis in R

`analysis/runlogger_reader.R` reads a save file into data frames (one row per run, plus nested tables for items, damage events and more).

```r
source("analysis/runlogger_reader.R")
x    <- read_runlogger("save1.dat")
runs <- runs_table(x)
ev   <- unnest_field(x, "damage_events")
```
