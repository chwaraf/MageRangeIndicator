# Mage Range Indicator

Shows the shortest-range Mage spell that can still reach your target: one icon
with the spell that reaches from where you are standing right now, so you know
whether the mob is close enough to act on without moving.

Built for **WoW: Forever** (the *Camelot* client, interface `16001`) and still
working on the **Classic-era** clients (Classic Era / TBC) that the addon
originally targeted.

```
        [icon]           Fireball can reach 35 yd
        Scorch           ...but Scorch reaches from 30, and it is in range
        30yd
```

## Clients

| Client | Manifest | Interface | Path |
| --- | --- | --- | --- |
| WoW: Forever | `MageRangeIndicator_Camelot.toc` | 16001 | `World of Warcraft\_classic_beta_\Interface\AddOns\MageRangeIndicator\` |
| TBC Classic / Anniversary | `MageRangeIndicator.toc` | 20504 | `World of Warcraft\_classic_\Interface\AddOns\MageRangeIndicator\` |
| Classic Era | `MageRangeIndicator.toc` | 11509 (add `_Vanilla.toc` to declare it) | `World of Warcraft\_classic_era_\Interface\AddOns\MageRangeIndicator\` |

The Forever client looks for `<AddonName>_Camelot.toc` before the unsuffixed
file, so the same folder works in both installs. Only one Lua file is shared, and
every client-specific call is probed at runtime - the addon never branches on
`WOW_PROJECT_ID` alone.

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

**Locking from the icon itself.** While the frame is unlocked you can drag it,
and right-clicking the icon locks it in place. Once locked, shift right-clicking
is the way back out; a plain right-click then does nothing. Each shortcut exists
only in the state it belongs to, the mouse stays enabled while locked so the
unlock shortcut is always reachable, and the tooltip shows the shortcut that
applies right now.

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
| Right-click the icon (unlocked) | Lock the frame in place |
| Shift right-click the icon (locked) | Unlock the frame so it can be dragged |
| `/mri lock` | Toggle lock/unlock (same as the mouse shortcuts) |
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
* every optional call is guarded and counted, and `/mri probe` reports
  `Wiring failures` instead of staying quiet.


`MageRangeIndicator.lua` is one file, split into numbered sections: secrets and
plain-value helpers, client detection, spell tables, spellbook, distance
buckets, range resolution, range checks, spell list, UI, commands, events,
start-up. `ns` carries the addon namespace, and the only globals are the
SavedVariables, the slash commands and the addon-compartment callbacks named in
the TOC.

The spec runs the addon outside the game, under real Lua 5.1, against a stub of
both clients (`tests/wow_stub.lua`): a Forever client with `C_Spell`,
`C_SpellBook`, secrets and spell data, and a Classic-era client with the legacy
spellbook and talent globals.

```sh
python3 -m venv .venv && .venv/bin/pip install lupa   # once
tests/run.sh                                          # 100 checks
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
| `MageRangeIndicator_Camelot.toc` | Forever manifest (interface 16001) |
| `MageRangeIndicator.toc` | Classic-era manifest |
| `tests/wow_stub.lua` | Stub of both clients for the offline spec |
| `tests/spec.lua` | The spec itself |
| `tests/run.sh` | Runs the spec under Lua 5.1 |
