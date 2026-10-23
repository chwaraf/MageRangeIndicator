# Mage Range Indicator

Shows the shortest-range Mage spell that can still reach your target: one icon
with the spell that reaches from where you are standing right now, so you know
whether the mob is close enough to act on without moving.

Built first for **WoW: Forever** (the *Camelot* client, interface `16001`) with
first-class support across **Classic Era**, **TBC Classic / Anniversary**,
**Wrath / Cataclysm / Mists Classic**, and **Mainline (Midnight)** from one
shared codebase.

```
        [icon]           Fireball can reach 35 yd
        Scorch           ...but Scorch reaches from 30, and it is in range
        30yd
```

## Clients

| Client | Manifest | Interface | Path |
| --- | --- | --- | --- |
| WoW: Forever (Camelot) | `MageRangeIndicator_Camelot.toc` | `16001` | `_classic_beta_\Interface\AddOns\MageRangeIndicator\` |
| Classic Era | `MageRangeIndicator_Vanilla.toc` | `11509, 11508, 11507` | `_classic_era_\Interface\AddOns\MageRangeIndicator\` |
| TBC Classic / Anniversary | `MageRangeIndicator_TBC.toc` | `20506, 20505, 20504` | `_anniversary_\` or `_classic_\Interface\AddOns\MageRangeIndicator\` |
| Wrath / Titan Reforged | `MageRangeIndicator_Wrath.toc` | `38002, 30405, 30404` | `_classic_titan_\Interface\AddOns\MageRangeIndicator\` |
| Cataclysm Classic | `MageRangeIndicator_Cata.toc` | `40402, 40401` | `_classic_\Interface\AddOns\MageRangeIndicator\` |
| Mists of Pandaria Classic | `MageRangeIndicator_Mists.toc` | `50504, 50503` | `_classic_\Interface\AddOns\MageRangeIndicator\` |
| Retail / Midnight | `MageRangeIndicator_Mainline.toc` | `120105, 120100, 120001` | `_retail_\Interface\AddOns\MageRangeIndicator\` |
| Fallback (all clients) | `MageRangeIndicator.toc` | `16001, 11509, ..., 120105` | any client without a suffix match |

Each WoW client automatically loads its matching `<AddonName>_<Flavor>.toc`
before `MageRangeIndicator.toc`, so one addon folder works out of the box across
all installs without marking the addon out of date.

Every subsystem is probed independently at runtime instead of assuming one `"modern"` vs `"legacy"` client split:

* **Spell info & range checks**: `C_Spell.GetSpellInfo` / `C_Spell.IsSpellInRange` when available (Forever, Retail, AND modern-engine Classic Era / TBC / Wrath / Mists), with fallback to `GetSpellInfo` / `IsSpellInRange`.
* **Spellbook scanning**: `C_SpellBook.GetNumSpellBookSkillLines` when present (Forever, Retail), automatically promoting the highest non-low-rank spell via `IsSpellBookItemLowRank`; falls through to tabbed `GetNumSpellTabs` + `GetSpellTabInfo` + `GetSpellBookItemInfo` + `GetSpellBookItemName` on Classic Era / TBC / Wrath / Cata / Mists (skipping `FUTURESPELL` slots and inactive Dual Spec tabs while promoting every spell to its highest learned rank).
* **Primary spec & talents**: Classic 3-tree talent scan (`GetTalentInfo` and native `C_SpecializationInfo.GetTalentInfo`), Forever `C_Traits` group currencies (`GetGroupDisplayInfoByTreeID` + `GetGroupCurrencyInfo`), `C_SpecializationInfo.GetSpecializationInfo`, and active spec (`GetSpecialization`) on Mists / Retail.

Restart the client if a new addon folder does not show up in the AddOns list.

## How it works

**The client's own range check decides.** For every spell that has a target
range, the addon asks `C_Spell.IsSpellInRange(spellID, "target")` (Forever) or
the old `IsSpellInRange` global (Classic-era). Whatever range talents the
character has are therefore included by definition - the addon does not have to
model them, and cannot get them wrong.

**The yard number on the icon** comes from the spell tooltip first (the number
the character actually has, from `C_TooltipInfo.GetSpellByID`), then the client's
spell data, then the table in the Lua file. `/mri range <spell> <yards|auto>`
overrides any of them by hand if a beta build reports something odd.

**Self-centred and cone spells have no target range.** Frost Nova, Cone of Cold,
Arcane Explosion and Blast Wave answer `nil` to a range check, so their reach is
measured with the distance buckets from LibRangeCheck-3.0 (item use ranges and
`CheckInteractDistance`). Their radius comes from the client's spell data for
Forever build 1.60.1.70009, minus the shortfall measured in game on the beta
(Frost Nova's freeze lands past 9 yards but not at 10), so an icon only lights
when the spell will really land. The listed reach is the measured one; `/mri
status` also prints the data radius.

**Secret values are drawn, not solved.** Range answers can come back as secret
booleans under the 12.x restrictions. Every answer goes through an
`issecretvalue` guard before it is compared, branched on or printed; a secret or
refused answer makes the indicator say `?` (unknown) rather than claiming
something it cannot know. No combat-log reads, no secure attributes, no maths on
health or names.

**Nothing runs when nothing changes.** The update loop asks the client only for
range answers, reuses its cache tables instead of rebuilding them, and rewrites
the icon's text and texture only when the state actually changes. Spell data is
read once per spell and kept as plain fields (the client returns a fresh table
per call), and every event that invalidates the spell list goes through one
coalesced rebuild rather than scheduling its own.

**No minimap button needed.** On Forever the addon registers in the addon
compartment through the TOC (`AddonCompartmentFunc`) and the click toggles the
indicator.

**A locked icon is genuinely click-through across every client.** On WoW 10.0+
engines (including **WoW: Forever**, **Classic Era**, **TBC**, **Wrath**,
**Cata**, **Mists** and **Mainline**), calling `SetScript("OnMouseUp", fn)` or
`SetScript("OnEnter", fn)` implicitly re-enables `MouseClickEnabled` /
`MouseMotionEnabled` in C++ even if `EnableMouse(false)` was called beforehand.
`CreateUI()` therefore wires all scripts first and runs `ApplyLock()` **last**,
explicitly clearing drag/click registrations (`RegisterForDrag()`,
`RegisterForClicks()`), turning off `EnableMouse`, `EnableMouseMotion`,
`SetMouseMotionEnabled`, `SetMouseClickEnabled` and `EnableMouseWheel` on both
`MRIFrame` and child frames, and re-enforcing `ApplyLock()` across loading
screens and combat transitions. `/mri probe` prints the live C++ mouse flags.

**One line at login, and nothing else.** The client, the build and the spell
list moved into `/mri status` and `/mri probe`, which print when asked:

```
MageRangeIndicator: v6.2.1 ready - drag the icon, right-click to lock it. /mri help
MageRangeIndicator: v6.2.1 ready - icon LOCKED (click-through), /mri lock to move it.
```

**Locking from the icon itself.** While the frame is unlocked you can drag it,
and right-clicking the icon locks it in place. A locked icon is
**click-through**: it takes no mouse at all, so clicks pass to whatever is
behind it and the icon never gets in the way in combat. Unlocking is done from
the chat command, `/mri lock`, which the lock message, the login message and the
tooltip all name.

## Memory

A build of this addon leaked about 3 MB a second and then appeared to reset
whenever the garbage collector caught up. That sawtooth was allocation churn
from a request/rebuild loop: every rebuild asked the client to load the spell
data it was missing, each answer fired `SPELL_DATA_LOAD_RESULT`, whose handler
rebuilt the whole list - full spellbook scan, a few hundred tables and strings -
and asked again.

What keeps it flat now:

* **Spell data is read once per spell, not once per rebuild**, and a miss is
  remembered as a miss. Requests are budgeted per session (and capped), only for
  the spell IDs in the tables, and cleared only when the spellbook itself
  changes.
* **`SPELL_DATA_LOAD_RESULT` is filtered**: the client announces every spell it
  loads, including ones this addon has no interest in. Only ours may cost a
  rebuild.
* **Rebuilds are coalesced.** Any number of events cost one deferred rebuild,
  and repeated bursts back the delay off from 0.75s towards 5s.
* **The hot path allocates nothing**: no string concatenation per tick, shared
  reaches share one measurement, the attackable check is answered once per pass,
  and the combat state comes from the regen events instead of a protected call
  per check.

`/mri probe` prints the Lua heap and the counters that show where any remaining
growth comes from:

```
Lua heap: 412 KB   rebuilds: 1   spellbook scans: 1   spell-data requests: 6   tooltip reads: 5
Rebuild delay: 0.75s
```

Stand next to a target and run it twice a minute apart: the heap moves with
garbage collection, but `rebuilds`, `spellbook scans` and `spell-data requests`
must not climb. If `rebuilds` does climb, an event is firing on your build and
the counters say which path it took.

## Commands

| Command | What it does |
| --- | --- |
| `/mri` or `/mri help` | List the commands |
| Right-click the icon (unlocked) | Lock the frame in place, and make it click-through |
| `/mri lock` | Unlock it again (or lock it from chat) |
| `/mri size <16-128>` | Icon size |
| `/mri opacity <0.0-1.0>` | Transparency |
| `/mri show` / `/mri hide` | Show or hide the indicator |
| `/mri status` | Client, primary tree, every spell with its range and where the range came from |
| `/mri probe` | What this client actually supports: namespaces, legacy globals, range sources, distance buckets |
| `/mri debug` | Live per-spell answers, plus the bucket distance to the current target |
| `/mri talents` | Rescan the spellbook, talents and ranges |
| `/mri range <spell> <1-60\|auto>` | Set a spell's range by hand, or hand it back to the client |
| `/mri auto on\|off` | Pick up unlisted short-range spells from the spellbook |

## What is verified, and what to retest on your build

Checked 2026-10-13 against the WoW Forever addon guides
(wowforeverguides.com/addons), the Warcraft Wiki TOC format page, and the two
range addons already shipping for the beta (RangeGauge, Range Lens).

Verified for the beta line:

* `C_Spell.IsSpellInRange(spellID, unit)` answers plain `true/false/nil` against
  a hostile target (`CheckInteractDistance` too) - this is what the whole addon
  rests on. Secret answers are possible in restricted contexts and are guarded.
* `C_Spell.GetSpellInfo` returns a table (`name`, `iconID`, `minRange`,
  `maxRange`); `C_SpellBook` skill lines give the player's current rank and icon;
  `C_TooltipInfo`, `C_Item` and `C_SpecializationInfo` are present.
* `GetSpellInfo`, `GetSpellBookItemName`, `GetNumTalentTabs` and the combat log
  are gone on Forever; nothing here calls them without a probe.

Retest on your build, in the order that matters:

1. `/mri probe` - if the range check or the spellbook lines move, this says so
   before anything else looks broken.
2. Whether the tooltip line carries `N yd range` on your build (the probe counts
   how many ranges came from the tooltip). If it does not, spell data takes over
   and the numbers are the unmodified ones.
3. Whether the addon compartment entry appears (the beta client has the
   feature; an entry on a live Forever screen was unconfirmed when this was
   written).
4. The interface number at launch: if it moves off 16001, update
   `MageRangeIndicator_Camelot.toc` and nothing else.

## Development

**The icon is a `Button`, not a `Frame`.** `RegisterForClicks` is a Button
method; on a plain Frame it is nil, and the call threw `attempt to call a nil
value` (Lua 5.1 does not name the method in the message the client shows). That
throw aborted the whole UI build, leaving the icon on its fallback texture with
the drag hint showing while the saved state said locked, and no mouse wiring at
all. Two rules came out of it, and the spec enforces both:

* the state (`ApplyLock`, `ShowIdle`) is applied *before* the optional script
  wiring, so a failure can never leave a half-styled icon;
* the spec's stub models the mouse the way the client does, so a click-through
  frame really does receive no clicks or hovers in the tests;
* every optional call is guarded and counted, and `/mri probe` reports
  `Wiring failures` instead of staying quiet.


`MageRangeIndicator.lua` is one file, split into numbered sections: secrets and
plain-value helpers, client detection, spell tables, spellbook, distance
buckets, range resolution, range checks, spell list, UI, commands, events,
start-up. `ns` carries the addon namespace, and the only globals are the
SavedVariables, the slash commands and the addon-compartment callbacks named in
the TOC.

The spec runs the addon outside the game, under real Lua 5.1, against stubs for
WoW: Forever, Classic Era, TBC Classic, Wrath Classic, Mists Classic, Mainline,
and pure legacy clients (`tests/wow_stub.lua`).

```sh
python3 -m venv .venv && .venv/bin/pip install lupa   # once
tests/run.sh                                          # 984 checks
```

It covers the selection logic on both clients (nearest reaching spell, spec
priority tie-breaks, out of range, no target, dead, friendly), the secret-value
paths, tooltip-before-data range resolution, the Classic talent maths
(Flame Throwing, Arctic Reach), hand-set ranges, the distance buckets and their
item loading, the mouse lock/unlock shortcuts, and the probe/status commands.

Churn is pinned down by counters on every client call: 200 update ticks may ask
the range checks and nothing else (no spell lookups, no spellbook scan, no
rebuild), a storm of 200 spell-data events costs at most one rebuild and zero
new requests, and repeated rescans never re-request data.

## Credits and sources

* Distance-bucket item lists and the interact-distance values are
  **LibRangeCheck-3.0**'s in-game measurements (mitch0 and the WoWUIDev
  community, MIT).
* The Forever spell-radius figures and the measured Frost Nova / Arcane
  Explosion shortfall follow **Range Lens**'s client-data read of build
  1.60.1.70009 and its in-game notes (MIT).
* The plain-value range-check conclusion comes from **RangeGauge**, which ships
  for the beta and asks the API directly for the same reason.
* Client facts (interface 16001, secrets, removed globals, compartment, TOC
  suffixes) from wowforeverguides.com/addons and the Warcraft Wiki `TOC format`
  page.

## Files

| File | Purpose |
| --- | --- |
| `MageRangeIndicator.lua` | The addon |
| `MageRangeIndicator_Camelot.toc` | WoW: Forever manifest (interface 16001) |
| `MageRangeIndicator_Vanilla.toc` | Classic Era manifest (interface 11509) |
| `MageRangeIndicator_TBC.toc` | TBC Classic / Anniversary manifest (interface 20506) |
| `MageRangeIndicator_Wrath.toc` / `_Cata.toc` / `_Mists.toc` | Wrath, Cataclysm and Mists Classic manifests |
| `MageRangeIndicator_Mainline.toc` | Retail / Midnight manifest (interface 120105) |
| `MageRangeIndicator.toc` | Multi-interface fallback manifest |
| `tests/wow_stub.lua` | Multi-client WoW API stub for the offline spec |
| `tests/spec.lua` | Offline spec (984 checks) |
| `tests/run.sh` | Runs the spec under Lua 5.1 |
