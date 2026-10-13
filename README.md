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

**No minimap button needed.** On Forever the addon registers in the addon
compartment through the TOC (`AddonCompartmentFunc`) and the click toggles the
indicator.

## Commands

| Command | What it does |
| --- | --- |
| `/mri` or `/mri help` | List the commands |
| `/mri lock` | Lock or unlock the frame (unlocked shows the drag hint and glow) |
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
item loading, and the probe/status commands.

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
