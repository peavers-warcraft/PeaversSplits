# PeaversSplits

[![AddonSentry](https://addonsentry.io/api/public/repos/peavers-warcraft/PeaversSplits/badge.svg)](https://addonsentry.io/dashboard/peavers-warcraft/PeaversSplits)

A World of Warcraft addon that calls out how far ahead or behind the pace your Mythic+ run is, at every boss, **while the key is still running**.

## Features

<!-- peavers:features -->
- A split called out at every boss, while the key is still running -- not a verdict at the end
- A live bar that races the **next** boss's pace, so you watch a gap open instead of being told about it once the boss is down
- Compared against your exact keystone level, never a neighbouring one
- Says "inside the usual range" when a delta lands inside the middle half of the pool -- a measurement, not a verdict
- Says plainly when your level has no published pool, and names the levels that do
- Party chat by default, "only me" available; SAY and YELL deliberately not offered
- One clock and one talker: group copies agree with each other instead of contradicting each other in chat
- Recovers from a reload mid-key, and says that it has done so
<!-- /peavers:features -->

## Usage

<!-- peavers:usage -->
1. Install it and start a key -- there is nothing to configure first
2. At the start of the run it says what it is pacing you against, or that nothing is published for your level
3. Watch the bar for the next boss; the delta is written out in words as well as drawn
4. Each boss death is called out in party chat with the split and the delta
5. `/ps test` shows a test bar you can drag into place; `/ps config` opens the settings
<!-- /peavers:usage -->

<!-- peavers:custom -->
```
Pacing Murder Row +10 against the published 12.1 pool.
Kystia Manaheart down at 8:17, +0:31 vs pace, inside the usual range.
Zaen Bladesorrow down at 12:49, +0:36 vs pace, inside the usual range.
Xathuux the Annihilator down at 20:31, +1:54 vs pace.
Lithiel Cinderfury down at 28:08, +1:52 vs pace.
Key done. +1:52 at the last boss.
```

## The live bar

The chat line is the record; the bar is the instrument. It runs continuously
against the **next** boss's pace, so a gap is something you watch open rather
than something you are told about once the boss is already down.

```
Next: Zaen Bladesorrow                    +0:31 vs pace
[========|####·····|                                  ]
         ^ pace    ^ the middle half of the pool
```

The track runs from zero to a little past the pool's slow quarter, and the scale
is fixed - it does not grow to fit an overrun, because a track that rescales
keeps the fill in the same place while the numbers get worse, which is the
opposite of what an instrument is for. Past the right edge it saturates and the
text carries the number.

Ahead is the theme accent, behind is red, **and the delta is written out in
words** - a bar that only says "bad" in red says nothing at all to a reader who
cannot see the difference.

Drag to move, lockable, and it hides itself whenever there is no pace to race
(an uncovered level, or every boss already down). A bar with nothing to compare
against is just a line.

## Why splits and not the timer

A **split** is the time from the start of a run to a boss dying. The dungeon
timer is a single deadline at the very end: it is the truth, and it arrives too
late to do anything about. A split is the same truth, available at the second
boss, while the group can still choose a different route or stop chain-pulling.

## What it compares against

The published pool from [parses.gg](https://parses.gg), shipped in
[PeaversSplitsData](https://github.com/peavers-warcraft/PeaversSplitsData): for
every dungeon in the current season and every exact keystone level with enough
runs behind it, the median time to each boss, plus the middle half of the pool.

**Your exact keystone level, never a neighbouring one.** Enemy health scales per
level, so a +14 held against the +12 pool would be told it is behind a pace
nobody at +14 ever set - plausible, wrong in one direction, and with nothing
about it looking wrong. If your level has no published pool the addon says so
and names the levels that do, rather than reaching sideways:

```
No pace published for Murder Row +14 yet. Levels with data: 7, 9, 10, 11, 12.
```

Splits are still called out on an uncovered level. They are a fact about your
run and do not need anybody else to have done the dungeon.

## "inside the usual range"

The pool carries its interquartile range as well as its median. A delta of forty
seconds means very little on a boss where the middle half of the pool spans four
minutes, so a split landing inside that range says so. It is the difference
between a measurement and a verdict, and it is on by default.

## Commands

| command | what it does |
|---|---|
| `/ps` or `/ps status` | what is loaded, what is running, and what it is being paced against |
| `/ps test` | show/hide the test bar, for dragging it into place |
| `/ps config` | settings |

## Notes on the clock

The split is measured from `CHALLENGE_MODE_START` with the addon's own
stopwatch, because that is exactly the quantity the published benchmark was
built from - real elapsed seconds, with no death penalty in it. Reading the
penalised figure instead would drift the delta by five seconds per death, always
in the same direction, and read as a group that got slower.

Reloading mid-key is recovered from: the addon adopts the run in progress and
falls back to the game's own keystone timer, and says that it has done so.
<!-- /peavers:custom -->

## Configuration

<!-- peavers:configuration -->
`/ps config` (or PeaversConfig) offers: announcements on/off and the channel,
the interquartile spread, sample size, the start-of-run and end-of-run lines,
group sync, and the live bar (show, lock, position).

Party chat is the default, because a split is a fact about the group's run.
"Only me" is available. **SAY and YELL are deliberately not offered** - they
reach everyone standing nearby, none of whom installed this.

Outside a group, and whenever the channel is unavailable, the line goes to your
own chat frame instead of being dropped.
<!-- /peavers:configuration -->

## Installation

### Recommended: PeaversUpdater

Download and install [PeaversUpdater](https://github.com/peavers-warcraft/PeaversUpdater/releases/latest), the desktop updater for the whole Peavers collection. It installs PeaversSplits together with its required dependencies and delivers updates before they reach CurseForge.

### Alternative: CurseForge

1. Download from [CurseForge](https://www.curseforge.com/wow/addons/peaverssplits)
2. Ensure [PeaversSplitsData](https://www.curseforge.com/wow/addons/peaverssplitsdata) is also installed
3. Ensure [PeaversCommons](https://www.curseforge.com/wow/addons/peaverscommons) is also installed
4. Ensure [PeaversConfig](https://www.curseforge.com/wow/addons/peaversconfig) is also installed
5. Enable the addon on the character selection screen

---

*Part of the [Peavers](https://peavers.io) addon collection · [Report an issue](https://github.com/peavers-warcraft/PeaversSplits/issues) · [Support development on Patreon](https://www.patreon.com/Peavers)*
