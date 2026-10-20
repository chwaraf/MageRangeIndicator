--[[==========================================================================
 MageRangeIndicator

 Shows the shortest-range Mage spell that can still reach your target: the
 "am I too close / can I still act" indicator for kiting and melee-range
 awareness.

 Clients
 -------
   * WoW: Forever      game type camelot, interface 16001, Mainline-family
                       modern API with Midnight's secret values active
   * Classic-era      Classic Era / TBC Anniversary, which still have the old
                       spellbook and talent-tree globals

 The Forever path (checked 2026-10-13 against wowforeverguides.com/addons and
 the two range addons already shipping for the beta, RangeGauge and Range Lens):

   * C_Spell.IsSpellInRange(spellID, "target") answers true / false / nil, and
     can be a secret boolean in restricted contexts. Every answer goes through
     PlainBool() before it is tested, branched on, or printed.
   * GetSpellInfo, GetSpellBookItemName and GetNumTalentTabs are gone; C_Spell,
     C_SpellBook and C_SpecializationInfo replace them. Every call here is
     capability-probed, so nothing depends on a global the client removed.
   * The in-range decision always comes from the client's own range check, so
     whatever range talents the character has are included by definition. The
     yard number on the icon comes from the spell tooltip first (talents
     included), then spell data, then this file's table - and /mri range
     overrides it by hand.
   * Self-centred and cone spells (Frost Nova, Cone of Cold, Arcane Explosion,
     Blast Wave) have no target range at all: the range check answers nil for
     them. Their reach is measured with the distance buckets below, which are
     LibRangeCheck-3.0's in-game measurements.

 Nothing here reads the combat log, writes secure attributes, or does maths on
 a secret value. SavedVariables are only touched from ADDON_LOADED.
==========================================================================]]

local addonName, ns = ...
ns = ns or {}

local ADDON_VERSION = "6.2.0"

---------------------------------------------------------------------------
-- 1. Secrets and plain-value helpers
--
-- On Forever a value can come back with its real type but be unreadable:
-- comparing it, doing maths on it, using it as a table key or printing it
-- throws. issecretvalue is the one sanctioned question to ask, and it only
-- exists on clients with the 12.x restrictions.
---------------------------------------------------------------------------

local function NeverSecret()
    return false
end

local isSecret = type(issecretvalue) == "function" and issecretvalue or NeverSecret

local function Sealed(value)
    if value == nil then return false end
    return isSecret(value)
end

-- true / false, or `fallback` when the value is secret or not a boolean.
local function PlainBool(value, fallback)
    if value == nil then return fallback end
    if Sealed(value) then return fallback end
    if type(value) ~= "boolean" then return fallback end
    return value
end

-- a number, or `fallback` when the value is secret or not a number.
local function PlainNum(value, fallback)
    if type(value) ~= "number" or Sealed(value) then return fallback end
    return value
end

-- a string, or `fallback` when the value is secret or not a string.
local function PlainText(value, fallback)
    if type(value) ~= "string" or Sealed(value) then return fallback end
    return value
end

---------------------------------------------------------------------------
-- 2. Client detection
--
-- WOW_PROJECT_ID alone is not an answer: Forever reported 1 (Mainline) on the
-- first beta build and 18 (WOW_PROJECT_CAMELOT) since. The named constant is
-- compared when the client has it, and the 16xxx-19xxx interface range - the
-- same test DetailsFramework uses - is the fallback. Feature detection below
-- is what actually decides which calls are made.
---------------------------------------------------------------------------

local client = {
    version = "?",
    build = "?",
    iface = 0,
    forever = false,
    flavor = "unknown",
    modern = false,       -- C_Spell spell lookups available
    modernBook = false,   -- C_SpellBook skill-line scanner available (Forever, Mainline)
    secrets = false,      -- issecretvalue exists
    tooltip = false,      -- C_TooltipInfo.GetSpellByID
    itemRange = false,    -- C_Item.IsItemInRange
    spellRange = false,   -- C_Spell.IsSpellInRange
    specInfo = false,     -- C_SpecializationInfo
    traits = false,       -- C_Traits group currency (Forever 3-tree points)
}

do
    local version, build, _, toc = GetBuildInfo()
    client.version = tostring(version or "?")
    client.build = tostring(build or "?")
    client.iface = tonumber(toc) or 0

    client.secrets = type(issecretvalue) == "function"
    client.modern = C_Spell ~= nil and type(C_Spell.GetSpellInfo) == "function"
    client.modernBook = C_SpellBook ~= nil
        and type(C_SpellBook.GetNumSpellBookSkillLines) == "function"
        and type(C_SpellBook.GetSpellBookSkillLineInfo) == "function"
        and type(C_SpellBook.GetSpellBookItemInfo) == "function"
    client.spellRange = C_Spell ~= nil and type(C_Spell.IsSpellInRange) == "function"
    client.tooltip = C_TooltipInfo ~= nil and type(C_TooltipInfo.GetSpellByID) == "function"
    client.itemRange = C_Item ~= nil and type(C_Item.IsItemInRange) == "function"
    client.specInfo = C_SpecializationInfo ~= nil and type(C_SpecializationInfo.GetSpecializationInfo) == "function"
    client.traits = C_Traits ~= nil
        and type(C_Traits.GetGroupDisplayInfoByTreeID) == "function"
        and type(C_Traits.GetGroupCurrencyInfo) == "function"

    local namedCamelot = type(WOW_PROJECT_CAMELOT) == "number"
    local foreverProbe = C_GameRules ~= nil and type(C_GameRules.GetForeverExperiencePreset) == "function"
    client.forever = (namedCamelot and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
        or foreverProbe
        or (client.iface >= 16000 and client.iface < 20000)

    if client.forever then
        client.flavor = "WoW: Forever (camelot)"
    elseif (type(WOW_PROJECT_CLASSIC) == "number" and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC)
        or (client.iface >= 11300 and client.iface < 16000) then
        client.flavor = "Classic Era"
    elseif (type(WOW_PROJECT_BURNING_CRUSADE_CLASSIC) == "number" and WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)
        or (client.iface >= 20000 and client.iface < 30000) then
        client.flavor = "TBC Classic"
    elseif (type(WOW_PROJECT_WRATH_CLASSIC) == "number" and WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC)
        or (client.iface >= 30000 and client.iface < 40000) then
        client.flavor = "Wrath Classic"
    elseif (type(WOW_PROJECT_CATACLYSM_CLASSIC) == "number" and WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC)
        or (client.iface >= 40000 and client.iface < 50000) then
        client.flavor = "Cataclysm Classic"
    elseif (type(WOW_PROJECT_MISTS_CLASSIC) == "number" and WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC)
        or (client.iface >= 50000 and client.iface < 60000) then
        client.flavor = "Mists Classic"
    elseif (type(WOW_PROJECT_MAINLINE) == "number" and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
        or client.iface >= 100000 then
        client.flavor = "Mainline (Midnight)"
    else
        client.flavor = "unknown (interface " .. client.iface .. ")"
    end
end

ns.client = client
ns.version = ADDON_VERSION

---------------------------------------------------------------------------
-- 3. Saved variables and state
---------------------------------------------------------------------------

local defaults = {
    locked = false,
    iconSize = 52,
    opacity = 1.0,
    posX = 0,
    posY = -150,
    autoSpells = true,    -- pick up short-range spells the tables do not list
    rangeOverride = {},   -- [spell name] = yards, set with /mri range
}

local db    -- MageRangeIndicatorDB; filled at ADDON_LOADED, never at file scope

-- Counters for /mri probe. They exist so a build can be checked for churn
-- (rebuilds, spellbook scans, spell-data requests) without a profiler.
local stats = { rebuilds = 0, bookScans = 0, requests = 0, tooltipReads = 0,
                rebuildDelay = 0.75, lastRebuildAt = 0, wiringFailures = 0 }

-- This client is a beta that moves quickly, and one unsupported call must not
-- cost the whole icon. Anything optional is wired through here, with failures
-- counted so /mri probe can name them instead of staying quiet.
local function TryCall(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        stats.wiringFailures = stats.wiringFailures + 1
        ns.lastWiringError = name .. ": " .. tostring(err)
    end
    return ok
end

local function SafeScript(widget, event, handler)
    if type(widget) ~= "table" or type(widget.SetScript) ~= "function" then return false end
    return TryCall("SetScript(" .. event .. ")", widget.SetScript, widget, event, handler)
end

-- There are fewer wanted spell IDs than this; the cap is a seatbelt on the
-- request path, so no future bug can turn it into a machine gun.
local MAX_SPELL_REQUESTS = 64
ns.stats = stats

local SCHOOL_ARCANE, SCHOOL_FIRE, SCHOOL_FROST = 1, 2, 3
local STATE_IN, STATE_OUT, STATE_UNKNOWN = "IN", "OUT", "UNKNOWN"
local COLOR_DEAD     = { 0.6, 0.6, 0.6 }
local COLOR_FRIENDLY = { 0.3, 0.8, 1 }
local COLOR_UNKNOWN  = { 0.8, 0.6, 1 }
local COLOR_OOR      = { 1, 0.3, 0.3 }
local treeNames = { "Arcane", "Fire", "Frost" }
local treePoints = { 0, 0, 0 }
local primaryTree = SCHOOL_FIRE

local spells = {}          -- resolved, sorted nearest reach first
local spellsByName = {}    -- [lower name] = entry
local skipped = {}         -- known-but-unresolved, reported by /mri status
local lastState = ""
local updateElapsed = 0
local initialized = false
local isMage = false
local classChecked = false
ns.talentCache = {}

local mainFrame, iconTex, rangeLabel, nameLabel, oorTex, glowTex, dragLabel

local function Print(msg)
    if msg == nil or Sealed(msg) then return end
    local kind = type(msg)
    local text
    if kind == "string" or kind == "number" or kind == "boolean" then
        text = tostring(msg)
    end
    if not text then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFMageRangeIndicator:|r " .. text)
end

local function Trim(value)
    if not value then return "" end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function SplitCommand(input)
    local command, rest = Trim(input or ""):match("^(%S+)%s*(.*)$")
    if not command then return "", "" end
    return command:lower(), Trim(rest)
end

---------------------------------------------------------------------------
-- 4. Spell tables
--
-- `range` is the base maximum range in yards and is only used when neither the
-- tooltip nor the spell data can answer. `minRange` is the dead zone, shown in
-- the label only. `talent` / `bonusPerPoint` (flat yards per rank) and
-- `bonusPctPerPoint` (percent of base per rank) reproduce the old Classic
-- talent maths for the Classic-era clients, which do not fold talent range into
-- spell data. On modern clients the client's own number always wins.
---------------------------------------------------------------------------

local SPELL_DATA = {
    { name = "Fireball",        id = 133,   icon = 135812, range = 35, school = SCHOOL_FIRE,   talent = "Flame Throwing",   bonusPerPoint = 3 },
    { name = "Frostbolt",       id = 116,   icon = 135846, range = 30, school = SCHOOL_FROST,  talent = "Arctic Reach",     bonusPctPerPoint = 10 },
    { name = "Scorch",          id = 2948,  icon = 135827, range = 30, school = SCHOOL_FIRE,   talent = "Flame Throwing",   bonusPerPoint = 3 },
    { name = "Arcane Missiles", id = 5143,  icon = 136096, range = 30, school = SCHOOL_ARCANE, talent = "Magic Attunement", bonusPerPoint = 3 },
    { name = "Fire Blast",      id = 2136,  icon = 135807, range = 20, school = SCHOOL_FIRE,   talent = "Flame Throwing",   bonusPerPoint = 3 },
    { name = "Arcane Blast",    id = 30451, icon = 135735, range = 30, school = SCHOOL_ARCANE, talent = "Magic Attunement", bonusPerPoint = 3 },
    { name = "Ice Lance",       id = 30455, icon = 135844, range = 30, school = SCHOOL_FROST,  talent = "Arctic Reach",     bonusPctPerPoint = 10 },
    { name = "Pyroblast",       id = 11366, icon = 135808, range = 35, school = SCHOOL_FIRE,   talent = "Flame Throwing",   bonusPerPoint = 3 },
    { name = "Arcane Barrage",  id = 44425, icon = 236205, range = 30, school = SCHOOL_ARCANE, talent = "Magic Attunement", bonusPerPoint = 3 },
    { name = "Blizzard",        id = 10,    icon = 135857, range = 30, school = SCHOOL_FROST,  talent = "Arctic Reach",     bonusPctPerPoint = 10 },
    { name = "Flamestrike",     id = 2120,  icon = 135826, range = 30, school = SCHOOL_FIRE,   talent = "Flame Throwing",   bonusPerPoint = 3 },
    { name = "Polymorph",       id = 118,   icon = 136071, range = 30, school = SCHOOL_ARCANE },
    { name = "Counterspell",    id = 2139,  icon = 135856, range = 30, school = SCHOOL_ARCANE, talent = "Magic Attunement", bonusPerPoint = 3 },
}

-- Spells centred on the caster, or in a cone in front of it, have no target
-- range, so the client's range check cannot answer for them and their reach is
-- the radius. Radius figures are the client's own spell data for Forever build
-- 1.60.1.70009, `adjust` is the measured shortfall seen in game on the beta
-- (Frost Nova's freeze lands past 9 yards but not at 10; Arcane Explosion
-- reaches about 9.5 standing still). Under-claiming is deliberate: the icon
-- lights only when the spell will really land.
local AOE_DATA = {
    { name = "Frost Nova",       id = 122,   icon = 135848, radius = 10, adjust = -1, shape = "around", school = SCHOOL_FROST,  talent = "Arctic Reach", bonusPctPerPoint = 10, range = 10 },
    { name = "Cone of Cold",     id = 120,   icon = 135852, radius = 10, adjust = -1, shape = "cone",   school = SCHOOL_FROST,  talent = "Arctic Reach", bonusPctPerPoint = 10, range = 10 },
    { name = "Arcane Explosion", id = 1449,  icon = 136116, radius = 10, adjust = -1, shape = "around", school = SCHOOL_ARCANE, range = 10 },
    { name = "Blast Wave",       id = 11113, icon = 135903, radius = 10, adjust = -1, shape = "around", school = SCHOOL_FIRE,   range = 10 },
    { name = "Dragon's Breath",  id = 31661, icon = 134153, radius = 10, adjust = -1, shape = "cone",   school = SCHOOL_FIRE,   range = 10 },
}

-- The spell IDs the tables above name. Only these are ever asked of the
-- client, and never twice: an addon that re-requests data it will never get,
-- once per rebuild, is an addon that eats memory a megabyte at a time.
local wantedIDs = {}
for _, data in ipairs(SPELL_DATA) do wantedIDs[data.id] = true end
for _, data in ipairs(AOE_DATA) do wantedIDs[data.id] = true end
ns.wantedIDs = wantedIDs

---------------------------------------------------------------------------
-- 5. Spellbook
--
-- Modern clients (Forever, Mainline): C_SpellBook skill lines, one entry per
-- known spell with its current rank's ID and icon. The player's rank ID is what
-- the range check and the cooldown APIs want, so everything is resolved through
-- the book by name, with the name itself coming from C_Spell.GetSpellInfo(id)
-- so that non-English clients resolve their own localised spell name.
--
-- Classic-era clients: the old flat spellbook (GetSpellBookItemName).
---------------------------------------------------------------------------

local book       -- { byName = { [lower] = entry }, byID = { [id] = entry } }

local function SpellInfoTable(spell)
    if not (client.modern and C_Spell and C_Spell.GetSpellInfo) then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, spell)
    if not ok or type(info) ~= "table" then return nil end
    return info
end

-- Spell data is read once per ID and kept as plain fields: the client answers
-- C_Spell.GetSpellInfo with a fresh table every call, and this runs for every
-- candidate on every rebuild. A miss is remembered as `false` so the rebuild
-- that follows a refused lookup stays free.
local spellInfoCache = {}     -- [spellID] = { name, iconID, minRange, maxRange } or false
local requestedSpells = {}    -- [spellID] = true once the client has been asked to load it

local function SpellInfo(spellID)
    if not spellID then return nil end
    local cached = spellInfoCache[spellID]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local info = SpellInfoTable(spellID)
    if info then
        local name = PlainText(info.name, nil)
        if name then
            cached = {
                name = name,
                iconID = PlainNum(info.iconID, nil),
                minRange = PlainNum(info.minRange, 0) or 0,
                maxRange = PlainNum(info.maxRange, 0) or 0,
            }
            spellInfoCache[spellID] = cached
            return cached
        end
    end

    -- No record. Ask the client once per session, and only for a spell this
    -- addon's tables care about. Never request from the rebuild path again:
    -- each request would answer with SPELL_DATA_LOAD_RESULT, whose handler
    -- rebuilds, which would request - a loop that allocates forever.
    spellInfoCache[spellID] = false
    if wantedIDs[spellID] and not requestedSpells[spellID] and stats.requests < MAX_SPELL_REQUESTS then
        requestedSpells[spellID] = true
        stats.requests = stats.requests + 1
        if client.modern and C_Spell and type(C_Spell.RequestLoadSpellData) == "function" then
            pcall(C_Spell.RequestLoadSpellData, spellID)
        end
    end
    return nil
end

local function LocalizedName(spellID)
    local info = SpellInfo(spellID)
    return info and info.name or nil
end

local function PlainAsset(value)
    return PlainNum(value, nil) or PlainText(value, nil)
end

local function SpellIcon(spellID, fallbackName, fallbackIcon)
    local info = SpellInfo(spellID)
    if info and info.iconID then return info.iconID end
    if spellID and C_Spell and type(C_Spell.GetSpellTexture) == "function" then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
        if ok then
            tex = PlainAsset(tex)
            if tex then return tex end
        end
    end
    if fallbackName and type(GetSpellTexture) == "function" then
        local ok, tex = pcall(GetSpellTexture, fallbackName)
        if ok then
            tex = PlainAsset(tex)
            if tex then return tex end
        end
    end
    if fallbackName and type(GetSpellInfo) == "function" then
        local ok, _, _, icon = pcall(GetSpellInfo, fallbackName)
        if ok then
            icon = PlainAsset(icon)
            if icon then return icon end
        end
    end
    return fallbackIcon
end

-- Data range for a spell ID: maxRange / minRange as the client has them.
-- On Classic-era clients C_Spell does not exist, so this answers nil and the
-- table (plus talent maths) is used instead.
local function DataRange(spellID)
    local info = SpellInfo(spellID)
    if not info then return nil, nil end
    return info.maxRange > 0 and info.maxRange or nil, info.minRange > 0 and info.minRange or nil
end

-- Does the client consider this spell one with a target range? Self-centred
-- and cone spells answer false, which is what sends them down the radius path.
local function SpellHasTargetRange(spellID)
    if not spellID then return nil end
    if client.modern and C_Spell and type(C_Spell.SpellHasRange) == "function" then
        local ok, value = pcall(C_Spell.SpellHasRange, spellID)
        if ok then return PlainBool(value, nil) end
    end
    if type(SpellHasRange) == "function" then
        local ok, value = pcall(SpellHasRange, spellID)
        if ok then return PlainBool(value, nil) end
    end
    return nil
end

-- Multi-rank spellbooks (Classic Era, TBC, Wrath, and Forever with all ranks
-- shown) list every rank of a spell. `byName` holds the highest learned rank,
-- and any lower rank's ID (such as Rank 1 Fireball = 133 in SPELL_DATA) is
-- promoted to that highest rank entry so lookups by base ID resolve the rank
-- the character actually casts.
local function PromoteHighestRanks(byName, byID)
    for id, item in pairs(byID) do
        if item.name then
            local highest = byName[item.name:lower()]
            if highest then byID[id] = highest end
        end
    end
end

local function ScanModernBook()
    local byName, byID = {}, {}
    if not client.modernBook then
        return byName, byID
    end

    local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local hasLowRank = type(C_SpellBook.IsSpellBookItemLowRank) == "function"

    pcall(function()
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if type(lineInfo) == "table" and lineInfo.shouldHide ~= true
                and lineInfo.isGuild ~= true and lineInfo.offSpecID == nil then
                local offset = PlainNum(lineInfo.itemIndexOffset, 0) or 0
                local count = PlainNum(lineInfo.numSpellBookItems, 0) or 0
                for index = offset + 1, offset + count do
                    local item = C_SpellBook.GetSpellBookItemInfo(index, bank)
                    if type(item) == "table" and item.spellID and (not spellType or item.itemType == spellType) then
                        local lowRank = false
                        if hasLowRank then
                            local okLow, low = pcall(C_SpellBook.IsSpellBookItemLowRank, index, bank)
                            if okLow then lowRank = PlainBool(low, false) end
                        end
                        local entry = {
                            name = PlainText(item.name, nil),
                            spellID = PlainNum(item.spellID, nil),
                            icon = PlainNum(item.iconID, nil),
                            isPassive = PlainBool(item.isPassive, false),
                            isOffSpec = PlainBool(item.isOffSpec, false),
                            lowRank = lowRank,
                        }
                        if entry.name then
                            local key = entry.name:lower()
                            local prev = byName[key]
                            if not prev or prev.lowRank or not entry.lowRank then
                                byName[key] = entry
                            end
                        end
                        if entry.spellID and not byID[entry.spellID] then byID[entry.spellID] = entry end
                    end
                end
            end
        end
    end)

    PromoteHighestRanks(byName, byID)
    return byName, byID
end

local function ScanLegacyBook()
    local byName, byID = {}, {}
    if type(GetSpellBookItemName) ~= "function" then return byName, byID end
    local bookType = BOOKTYPE_SPELL or "spell"
    local hasItemInfo = type(GetSpellBookItemInfo) == "function"
    local hasHidden = type(IsSpellHidden) == "function"
    local hasTexture = type(GetSpellTexture) == "function"
    local hasPassive = type(IsPassiveSpell) == "function"

    local function RecordSlot(slot)
        local slotType, slotID
        if hasItemInfo then
            local okInfo, kind, id = pcall(GetSpellBookItemInfo, slot, bookType)
            if okInfo and type(kind) == "string" then
                slotType, slotID = kind, id
                if kind ~= "SPELL" then return true end
            end
        end
        if hasHidden then
            local okHidden, hidden = pcall(IsSpellHidden, slot, bookType)
            if okHidden and PlainBool(hidden, false) then return true end
        end

        local ok, name, _, nameSpellID = pcall(GetSpellBookItemName, slot, bookType)
        name = ok and PlainText(name, nil) or nil
        if not name then return false end

        local icon
        if hasTexture then
            local okTex, tex = pcall(GetSpellTexture, slot, bookType)
            if okTex then icon = PlainAsset(tex) end
        end

        local passive = false
        if hasPassive then
            local okPas, pas = pcall(IsPassiveSpell, slot, bookType)
            if okPas then passive = PlainBool(pas, false) end
        end

        local spellID = PlainNum(nameSpellID, nil) or PlainNum(slotID, nil)
        local entry = {
            name = name,
            index = slot,
            spellID = spellID,
            icon = icon,
            isPassive = passive,
        }
        -- Overwrite earlier ranks: Classic spellbooks list Rank 1 .. Rank N in
        -- slot order, so the latest slot is the highest learned rank.
        byName[name:lower()] = entry
        if spellID then byID[spellID] = entry end
        return true
    end

    -- Classic Era, TBC, Wrath, Cata and Mists expose spell tabs (including
    -- inactive Dual Spec tabs marked with offSpecID ~= 0, which must be
    -- skipped so off-spec talent spells do not appear known).
    if type(GetNumSpellTabs) == "function" and type(GetSpellTabInfo) == "function" then
        local okTabs, numTabs = pcall(GetNumSpellTabs)
        numTabs = okTabs and PlainNum(numTabs, nil) or nil
        if numTabs and numTabs > 0 then
            for tab = 1, numTabs do
                local okTab, _, _, offset, numSlots, isGuild, offSpecID, shouldHide = pcall(GetSpellTabInfo, tab)
                if okTab then
                    offset = PlainNum(offset, 0) or 0
                    numSlots = PlainNum(numSlots, 0) or 0
                    offSpecID = PlainNum(offSpecID, 0) or 0
                    if shouldHide ~= true and isGuild ~= true and offSpecID == 0 then
                        for slot = offset + 1, offset + numSlots do
                            RecordSlot(slot)
                        end
                    end
                end
            end
            PromoteHighestRanks(byName, byID)
            return byName, byID
        end
    end

    local index = 1
    while RecordSlot(index) do
        index = index + 1
    end
    PromoteHighestRanks(byName, byID)
    return byName, byID
end

local bookDirty = true

local function Book()
    if not book or bookDirty then
        local byName, byID
        stats.bookScans = stats.bookScans + 1
        if client.modernBook then
            byName, byID = ScanModernBook()
        end
        -- Classic Era, TBC Anniversary, Wrath, Cata and Mists all have C_Spell
        -- (modern engine) while keeping the classic spellbook globals instead
        -- of C_SpellBook skill lines: always fall through to ScanLegacyBook
        -- whenever the modern skill-line API is absent or empty.
        if not byName or next(byName) == nil then
            local legName, legID = ScanLegacyBook()
            if next(legName) ~= nil or not byName then
                byName, byID = legName, legID
            end
        end
        book = { byName = byName, byID = byID }
        bookDirty = false
    end
    return book
end

-- The spellbook only needs rescanning when the client says it changed, not on
-- every range or talent refresh.
local function InvalidateBook()
    bookDirty = true
end

-- The player's own entry for a spell: exact ID first, then the localised name
-- (which finds whatever rank the character actually has).
local function BookEntryFor(spell)
    local b = Book()
    if spell.id and b.byID[spell.id] then return b.byID[spell.id] end
    local name = spell.id and LocalizedName(spell.id) or spell.name
    name = name or spell.name
    if name then
        local entry = b.byName[name:lower()]
        if entry then return entry end
    end
    return nil
end

---------------------------------------------------------------------------
-- 6. Distance buckets
--
-- Only needed for spells with no target range (see AOE_DATA) and for the
-- distance line in /mri debug. Item IDs by use range and the interact-distance
-- values are LibRangeCheck-3.0's in-game measurements (mitch0 and the WoWUIDev
-- community, MIT); the conservative values Range Lens ships for Forever are
-- used where they differ, so a spell only lights when it really reaches.
---------------------------------------------------------------------------

local ITEM_BUCKETS = {
    [5]  = { 8149, 15826, 16308, 17117, 22259, 22432, 206466, 208760, 208855, 209027, 209057, 213036, 221199, 225943 },
    [10] = { 9606, 9618, 9619, 9620, 9621, 10699, 17626, 17689, 226472 },
    [15] = { 4559 },
}

-- CheckInteractDistance indices: 3 duel, 2 trade, 1 inspect or 4 follow.
local INTERACT_BUCKETS = {
    { index = 3, yards = 8 },
    { index = 2, yards = 9 },
    { index = 1, yards = 28 },
}
local FOLLOW_INDEX, FOLLOW_YARDS = 4, 28

local inCombatLockdown = false   -- kept by PLAYER_REGEN_DISABLED / _ENABLED

local itemFor = {}          -- [yards] = an item of that use range whose data is loaded
local itemPending = {}      -- [itemID] = yards, while its data loads
local bucketCache           -- sorted, nearest first
local tradeBroken = false
local interactBlocked = false

local function ItemReady(itemID)
    if not (client.modern and C_Item and type(C_Item.GetItemInfo) == "function") then return false end
    if type(C_Item.IsItemDataCachedByID) == "function" then
        local ok, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
        if ok and not cached then return false end
    end
    local ok, name = pcall(C_Item.GetItemInfo, itemID)
    return ok and PlainText(name, nil) ~= nil
end

local function EnsureItems()
    if not (client.modern and C_Item and C_Item.IsItemInRange) then return end
    for yards, list in pairs(ITEM_BUCKETS) do
        if not itemFor[yards] then
            for _, itemID in ipairs(list) do
                if ItemReady(itemID) then
                    itemFor[yards] = itemID
                    bucketCache = nil
                    break
                end
                if not itemPending[itemID] then
                    itemPending[itemID] = yards
                    if type(C_Item.RequestLoadItemDataByID) == "function" then
                        pcall(C_Item.RequestLoadItemDataByID, itemID)
                    end
                end
            end
        end
    end
end

local function OnItemLoaded(itemID, success)
    local yards = itemPending[itemID]
    if not yards then return end
    itemPending[itemID] = nil
    if success ~= false and not itemFor[yards] and ItemReady(itemID) then
        itemFor[yards] = itemID
        bucketCache = nil
    end
end

local function SetRaceDistances()
    local ok, _, race = pcall(UnitRace, "player")
    if not ok or race == nil then return end
    local tables = {
        Tauren = { [3] = 6, [2] = 7, [1] = 25, [4] = 25 },
        Scourge = { [3] = 7, [2] = 8, [1] = 27, [4] = 27 },
    }
    local override = tables[race]
    if not override then return end
    local rebuilt = {}
    for _, bucket in ipairs(INTERACT_BUCKETS) do
        rebuilt[#rebuilt + 1] = { index = bucket.index, yards = override[bucket.index] or bucket.yards }
    end
    INTERACT_BUCKETS = rebuilt
    bucketCache = nil
end

local function Buckets()
    if bucketCache then return bucketCache end
    EnsureItems()
    local list = {}
    for yards, itemID in pairs(itemFor) do
        list[#list + 1] = { yards = yards, item = itemID }
    end
    if type(CheckInteractDistance) == "function" and not interactBlocked then
        for _, bucket in ipairs(INTERACT_BUCKETS) do
            if not (bucket.index == 2 and tradeBroken) then
                list[#list + 1] = { yards = bucket.yards, interact = bucket.index }
            end
        end
        list[#list + 1] = { yards = FOLLOW_YARDS, interact = FOLLOW_INDEX }
    end
    table.sort(list, function(a, b) return a.yards < b.yards end)
    bucketCache = list
    return list
end

-- Asked once per update pass and remembered: several checks in one pass need
-- the same answer, and each ask is a protected call.
local attackableKnown, attackableValue = false, false

local function ResetAttackable()
    attackableKnown = false
end

local function AttackablePlain(unit)
    if unit == "target" and attackableKnown then return attackableValue end

    local result = false
    if type(UnitCanAttack) == "function" then
        local ok, value = pcall(UnitCanAttack, "player", unit)
        if ok then
            local plain = PlainBool(value, nil)
            if plain ~= nil then
                result = plain
            elseif type(UnitFactionGroup) == "function" then
                -- Secret boolean: fall back to the faction test the Forever
                -- guides recommend, which never carries a restriction.
                local okMine, mine = pcall(UnitFactionGroup, "player")
                local okTheirs, theirs = pcall(UnitFactionGroup, unit)
                mine, theirs = PlainText(mine, nil), PlainText(theirs, nil)
                if okMine and okTheirs and mine and theirs then result = mine ~= theirs end
            end
        end
    end

    if unit == "target" then
        attackableKnown, attackableValue = true, result
    end
    return result
end

-- true / false / nil (nil = the client refused the check or answered secretly).
local function RunBucket(bucket, unit)
    if not bucket then return nil end
    if bucket.item then
        if client.modern then
            if not (C_Item and type(C_Item.IsItemInRange) == "function") then return nil end
            local ok, result = pcall(C_Item.IsItemInRange, bucket.item, unit)
            if not ok then return nil end
            return PlainBool(result, nil)
        end
        if type(IsItemInRange) ~= "function" then return nil end
        local ok, result = pcall(IsItemInRange, bucket.item, unit)
        if not ok then return nil end
        return PlainBool(result, nil)
    end

    if type(CheckInteractDistance) ~= "function" then return nil end
    -- Friendly units are refused these checks while you are in combat; the
    -- flag is kept by the regen events rather than asked for every tick.
    if inCombatLockdown and not AttackablePlain(unit) then return nil end
    local ok, result = pcall(CheckInteractDistance, unit, bucket.interact)
    if not ok then
        interactBlocked = true
        bucketCache = nil
        return nil
    end
    local plain = PlainBool(result, nil)
    -- A trade check that fails inside duel range is not working for this unit;
    -- stop using it for the session (Range Lens's guard).
    if plain == false and bucket.interact == 2 and not tradeBroken then
        local okDuel, duel = pcall(CheckInteractDistance, unit, 3)
        if okDuel and PlainBool(duel, nil) == true then
            tradeBroken = true
            bucketCache = nil
            return true
        end
    end
    return plain
end

-- Measure a reach with the buckets that do not go past it: the largest one
-- first, so a pass means the spell really covers the target. A check the client
-- refuses (friendly unit in combat, missing item data, a secret answer) is
-- stepped over rather than ending the measurement - the next smaller check is
-- stricter, so its pass still proves the reach.
local function MeasureReach(reach, unit)
    if not reach then return nil end
    local list = Buckets()
    for index = #list, 1, -1 do
        local bucket = list[index]
        if bucket.yards <= reach then
            local result = RunBucket(bucket, unit)
            if result ~= nil then return result end
        end
    end
    return nil
end

-- Coarse distance readout for /mri debug: between the last failing bucket and
-- the first passing one.
local function DistanceText(unit)
    local low = 0
    for _, bucket in ipairs(Buckets()) do
        local result = RunBucket(bucket, unit)
        if result == true then
            if low > 0 then return "between " .. low .. " and " .. bucket.yards .. " yd" end
            return "under " .. bucket.yards .. " yd"
        elseif result == false then
            low = bucket.yards
        end
    end
    if low > 0 then return "over " .. low .. " yd" end
    return "unknown"
end

---------------------------------------------------------------------------
-- 7. Ranges: tooltip, then spell data, then the table (+ Classic talents)
---------------------------------------------------------------------------

local rangeCache = {}       -- [spellID] = { reach = n, minRange = n, source = "..." }
local radiusCache = {}      -- [spellID] = radius or false

-- The radius a self-centred spell states in its description, read once.
local function DescriptionRadius(spellID)
    if not spellID then return nil end
    local cached = radiusCache[spellID]
    if cached ~= nil then return cached or nil end
    local radius = false
    if client.modern and C_Spell and type(C_Spell.GetSpellDescription) == "function" then
        local ok, text = pcall(C_Spell.GetSpellDescription, spellID)
        if ok then
            text = PlainText(text, nil)
            if text then
                local found = tonumber(text:match("within (%d+) yards") or text:match("(%d+) yard radius"))
                if found then radius = found end
            end
        end
    end
    radiusCache[spellID] = radius
    return radius or nil
end
local tooltipPath           -- "C_TooltipInfo" / "GameTooltip" / false

local function RangeFromText(text)
    text = PlainText(text, nil)
    if not text then return nil end
    local yards = text:match("(%d+)%s*yd range") or text:match("(%d+)%s*yard range")
    return yards and tonumber(yards) or nil
end

local function RangeFromLines(lines)
    if type(lines) ~= "table" then return nil end
    local best
    for _, line in pairs(lines) do
        if type(line) == "string" then
            local yards = RangeFromText(line)
            if yards and (not best or yards > best) then best = yards end
        elseif type(line) == "table" then
            for _, field in ipairs({ "leftText", "rightText" }) do
                local yards = RangeFromText(line[field])
                if yards and (not best or yards > best) then best = yards end
            end
        end
    end
    return best
end

-- The tooltip shows the range the character actually has, talents included.
-- C_TooltipInfo first (no frame involved), GameTooltip as the older fallback.
local function TooltipRange(spellID)
    if not spellID or tooltipPath == false then return nil end

    if tooltipPath == nil or tooltipPath == "C_TooltipInfo" then
        if client.tooltip then
            stats.tooltipReads = stats.tooltipReads + 1
            local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellID)
            if ok and type(data) == "table" then
                tooltipPath = "C_TooltipInfo"
                local yards = RangeFromLines(data.lines)
                if yards then return yards end
            end
        end
    end

    if tooltipPath == nil or tooltipPath == "GameTooltip" then
        if type(GameTooltip) == "table" and type(GameTooltip.SetSpellByID) == "function" then
            local ok = pcall(function()
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:SetSpellByID(spellID)
            end)
            if ok then
                local best
                for i = 1, 30 do
                    local line = _G["GameTooltipTextLeft" .. i]
                    if type(line) == "table" and type(line.GetText) == "function" then
                        local yards = RangeFromText(line:GetText())
                        if yards and (not best or yards > best) then best = yards end
                    end
                end
                pcall(function() GameTooltip:Hide() end)
                tooltipPath = "GameTooltip"
                if best then return best end
            end
        end
    end

    if tooltipPath == nil then tooltipPath = false end
    return nil
end

local function TalentRank(talentName)
    if not talentName or not ns.talentCache then return 0 end
    return ns.talentCache[talentName] or 0
end

-- Classic-era talent maths, applied only when the spellbook scan found talent
-- points at all (modern clients fold talents into the numbers above instead).
local function TableRange(entry)
    local base = entry.range
    if not base then return nil end
    local rank = TalentRank(entry.talent)
    if rank > 0 then
        if entry.bonusPctPerPoint then
            base = math.floor(base * (1 + (entry.bonusPctPerPoint * rank) / 100) + 0.5)
        else
            base = base + ((entry.bonusPerPoint or 0) * rank)
        end
    end
    return base
end

local function Override(name)
    if not (db and db.rangeOverride) or not name then return nil end
    return tonumber(db.rangeOverride[name])
end

local function ResolveRange(entry)
    if not rangeCache[entry.spellID or entry.name] then
        local reach, minRange, source
        local override = Override(entry.name)
        if override then
            reach, source = override, "set"
        elseif entry.kind == "aoe" then
            local radius = entry.radius
            if radius and entry.talent then
                local rank = TalentRank(entry.talent)
                if rank > 0 and entry.bonusPctPerPoint then
                    radius = math.floor(radius * (1 + (entry.bonusPctPerPoint * rank) / 100) + 0.5)
                end
            end
            if not radius and entry.spellID then
                radius = DescriptionRadius(entry.spellID)
            end
            if radius then
                reach = math.max(1, radius + (entry.adjust or 0))
                source = "radius"
            end
        else
            local tooltip = TooltipRange(entry.spellID)
            local dataMax, dataMin = DataRange(entry.spellID)
            local tableMax = TableRange(entry)
            if tooltip then
                reach, minRange, source = tooltip, dataMin, "tooltip"
            elseif entry.talent and TalentRank(entry.talent) > 0 and tableMax and tableMax > (dataMax or 0) then
                -- Classic Era / TBC / Wrath DB2 `C_Spell.GetSpellInfo` holds the
                -- untalented base range (e.g. 35 yd for Fireball). When tooltip
                -- text is unparsed (e.g. non-English locale) and talent ranks
                -- are known, apply the talent bonus instead of clamping to base.
                reach, minRange, source = tableMax, dataMin, "table"
            elseif dataMax and dataMax > 0 then
                reach, minRange, source = dataMax, dataMin, "data"
            else
                reach, source = tableMax, "table"
            end
        end
        rangeCache[entry.spellID or entry.name] = { reach = reach, minRange = minRange, source = source }
    end

    local cached = rangeCache[entry.spellID or entry.name]
    entry.reach, entry.minRange, entry.source = cached.reach, cached.minRange, cached.source
    if entry.reach then
        if entry.kind == "aoe" then
            entry.rangeText = tostring(math.floor(entry.reach + 0.5))
        else
            local text = tostring(math.floor(entry.reach + 0.5))
            if entry.minRange and entry.minRange > 0 and entry.minRange < entry.reach then
                text = math.floor(entry.minRange + 0.5) .. "-" .. text
            end
            entry.rangeText = text
        end
    end
end

local function InvalidateRanges()
    rangeCache = {}
    tooltipPath = nil
end

---------------------------------------------------------------------------
-- 8. Range checks
---------------------------------------------------------------------------

local function ParseLegacyRangeResult(result)
    if result == nil or Sealed(result) then return nil end
    local number = PlainNum(result, nil)
    if number ~= nil then return number == 1 end
    return PlainBool(result, nil)
end

-- true / false / nil for a spell with a target range.
local function TargetReach(entry, unit)
    if client.spellRange and entry.spellID then
        local ok, result = pcall(C_Spell.IsSpellInRange, entry.spellID, unit)
        if ok then
            if Sealed(result) then return nil end
            local plain = PlainBool(result, nil)
            if plain ~= nil then return plain end
        end
    end

    -- Classic-era fallback: index form first, then by name, with zero table
    -- allocations on the hot path.
    if type(IsSpellInRange) == "function" then
        if entry.bookIndex then
            local ok, result = pcall(IsSpellInRange, entry.bookIndex, BOOKTYPE_SPELL or "spell", unit)
            if ok then
                local parsed = ParseLegacyRangeResult(result)
                if parsed ~= nil then return parsed end
            end
        end
        if entry.name then
            local ok, result = pcall(IsSpellInRange, entry.name, unit)
            if ok then
                local parsed = ParseLegacyRangeResult(result)
                if parsed ~= nil then return parsed end
            end
        end
    end
    return nil
end

-- Spells that share a reach share a measurement: the buckets only depend on
-- the reach and the unit. The table is reused between passes and only its few
-- keys are cleared, so repeated checks allocate nothing.
local reachResults = {}

local function ClearReachResults()
    for key in pairs(reachResults) do reachResults[key] = nil end
end

-- true / false / nil for a self-centred or cone spell, from the buckets.
local function AreaReach(entry, unit)
    local reach = entry.reach
    if not reach then return nil end
    local cached = reachResults[reach]
    if cached ~= nil then return cached end
    reachResults[reach] = MeasureReach(reach, unit)
    return reachResults[reach]
end

local function SpellReaches(entry, unit)
    if entry.kind == "aoe" then return AreaReach(entry, unit) end
    return TargetReach(entry, unit)
end

---------------------------------------------------------------------------
-- 9. Spell list
---------------------------------------------------------------------------

local function SpellPriority(school)
    if school == SCHOOL_ARCANE then
        return primaryTree == SCHOOL_ARCANE and 0 or 2
    end
    if school == primaryTree then return 0 end
    return 1
end

-- Short-range spells the tables do not list, picked up from the spellbook so a
-- new Forever ability shows up on its own. Only spells whose reach can be read
-- (a target range, or a radius in the description) are added.
local function DiscoverShortSpells(knownIDs)
    local found = {}
    if not (client.modern and db and db.autoSpells) then return found end
    local byName = Book().byName
    for _, known in pairs(byName) do
        if known.spellID and not known.isOffSpec and not known.isPassive and not knownIDs[known.spellID] then
            local maxRange = DataRange(known.spellID)
            local hasTargetRange = SpellHasTargetRange(known.spellID)
            if hasTargetRange ~= false and maxRange and maxRange > 0 and maxRange <= 15 then
                found[#found + 1] = { name = known.name, id = known.spellID, kind = "target", range = maxRange, auto = true, icon = known.icon }
            elseif hasTargetRange == false then
                local radius = DescriptionRadius(known.spellID)
                if radius and radius <= 15 then
                    found[#found + 1] = { name = known.name, id = known.spellID, kind = "aoe", radius = radius, auto = true, icon = known.icon, shape = "around" }
                end
            end
        end
    end
    return found
end

local function BuildSpellList()
    stats.rebuilds = stats.rebuilds + 1
    skipped = {}
    spells, spellsByName = {}, {}

    local candidates, knownIDs = {}, {}
    local order = 0
    local function Add(entry)
        order = order + 1
        entry.order = order
        candidates[#candidates + 1] = entry
    end

    for _, data in ipairs(SPELL_DATA) do
        Add({ name = data.name, baseName = data.name, id = data.id, defaultIcon = data.icon,
              kind = "target", range = data.range, school = data.school,
              talent = data.talent, bonusPerPoint = data.bonusPerPoint, bonusPctPerPoint = data.bonusPctPerPoint })
    end
    for _, data in ipairs(AOE_DATA) do
        Add({ name = data.name, baseName = data.name, id = data.id, defaultIcon = data.icon,
              kind = "aoe", radius = data.radius, adjust = data.adjust,
              shape = data.shape, range = data.range, school = data.school,
              talent = data.talent, bonusPctPerPoint = data.bonusPctPerPoint })
    end

    -- Resolve each candidate against the character's own spellbook.
    local resolved = {}
    for _, entry in ipairs(candidates) do
        local known = BookEntryFor(entry)
        if known then
            entry.bookIndex = known.index
            entry.spellID = known.spellID or entry.id
            entry.name = known.name or entry.name
            entry.icon = known.icon or SpellIcon(entry.spellID, entry.name, entry.defaultIcon)
            if entry.spellID then knownIDs[entry.spellID] = true end
            ResolveRange(entry)
            if entry.reach then
                entry.priority = SpellPriority(entry.school)
                resolved[#resolved + 1] = entry
            else
                skipped[#skipped + 1] = { name = entry.name, id = entry.spellID, why = "no range known" }
            end
        else
            skipped[#skipped + 1] = { name = entry.name, id = entry.id, why = "not in spellbook" }
        end
    end

    for _, entry in ipairs(DiscoverShortSpells(knownIDs)) do
        local resolvedEntry = entry
        order = order + 1
        resolvedEntry.order = order
        if not resolvedEntry.icon then resolvedEntry.icon = SpellIcon(entry.id, entry.name, entry.defaultIcon) end
        ResolveRange(resolvedEntry)
        if resolvedEntry.reach then
            resolvedEntry.priority = SpellPriority(resolvedEntry.school)
            resolved[#resolved + 1] = resolvedEntry
        end
    end

    table.sort(resolved, function(a, b)
        if a.reach ~= b.reach then return a.reach < b.reach end
        if a.priority ~= b.priority then return a.priority < b.priority end
        return (a.order or 0) < (b.order or 0)
    end)

    for _, entry in ipairs(resolved) do
        entry.stateKey = "IN:" .. (entry.name or "?")
        entry.label = (entry.rangeText or "?") .. "yd"
    end

    spells = resolved
    for _, entry in ipairs(spells) do
        if entry.name then spellsByName[entry.name:lower()] = entry end
        if entry.baseName then spellsByName[entry.baseName:lower()] = entry end
    end
    ns.spells, ns.spellsByName = spells, spellsByName
    lastState = ""
end

---------------------------------------------------------------------------
-- 10. Selecting what to show
--
-- `spells` is sorted nearest reach first, so the first spell that reaches the
-- target is the answer and the loop stops there. A spell that answers nil
-- (secret, refused, or not usable right now) is remembered separately: if
-- nothing reaches and nothing answered plainly, the indicator says so instead
-- of claiming "out of range".
---------------------------------------------------------------------------

local function PickSpell(unit)
    ClearReachResults()
    local answered = false
    for _, entry in ipairs(spells) do
        local reaches = SpellReaches(entry, unit)
        if reaches == true then return entry, STATE_IN end
        if reaches ~= nil then answered = true end
    end
    if answered then return nil, STATE_OUT end
    return nil, STATE_UNKNOWN
end

-- `spells` is sorted (reach ASC, priority ASC, order ASC), so within the
-- highest reach tier the FIRST entry is the character's primary-spec spell
-- (Fireball for Fire, Frostbolt for Frost, Arcane Blast / Missiles for
-- Arcane), whereas `spells[#spells]` would be the lowest-priority tie.
local function LongestReachSpell()
    local last = spells[#spells]
    if not last then return nil end
    for i = 1, #spells do
        if spells[i].reach == last.reach then return spells[i] end
    end
    return last
end

local function HasTarget()
    if type(UnitExists) ~= "function" then return false end
    local ok, exists = pcall(UnitExists, "target")
    if not ok then return false end
    if Sealed(exists) then
        -- Unreadable: assume there is one and let the range answers decide,
        -- rather than hiding the indicator on a client that hides the flag.
        return true
    end
    return exists and true or false
end

---------------------------------------------------------------------------
-- 11. Client specialisation tree
---------------------------------------------------------------------------

local function ReadSpecializationPoints(index)
    local points
    pcall(function()
        local info = C_SpecializationInfo.GetSpecializationInfo(index)
        if type(info) == "table" then
            points = PlainNum(info.pointsSpent, nil) or PlainNum(info.points, nil)
        elseif type(info) == "number" then
            -- tuple shape: the seventh return is points spent
            local ok, value = pcall(function()
                return select(7, C_SpecializationInfo.GetSpecializationInfo(index))
            end)
            if ok then points = PlainNum(value, nil) end
        end
    end)
    return points
end

local function ReadTraitTreePoints()
    if not (client.traits and C_Traits) then return false end
    local found = false
    pcall(function()
        local activeGroup = 1
        if C_SpecializationInfo and type(C_SpecializationInfo.GetActiveSpecGroup) == "function" then
            activeGroup = PlainNum(C_SpecializationInfo.GetActiveSpecGroup(), 1) or 1
        end
        local configID
        if C_SpecializationInfo and type(C_SpecializationInfo.GetCombatConfigIDForSpecGroup) == "function" then
            configID = PlainNum(C_SpecializationInfo.GetCombatConfigIDForSpecGroup(activeGroup), nil)
        end
        if not configID and C_ClassTalents and type(C_ClassTalents.GetActiveConfigID) == "function" then
            configID = PlainNum(C_ClassTalents.GetActiveConfigID(), nil)
        end
        if not configID or type(C_Traits.GetConfigInfo) ~= "function" then return end

        local configInfo = C_Traits.GetConfigInfo(configID)
        local treeID = type(configInfo) == "table" and type(configInfo.treeIDs) == "table"
            and PlainNum(configInfo.treeIDs[1], nil) or nil
        if not treeID then return end

        local displayInfos = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
        if type(displayInfos) ~= "table" or #displayInfos == 0 then return end

        local groupIDs = {}
        for i, info in ipairs(displayInfos) do
            if type(info) == "table" and info.groupID then
                groupIDs[#groupIDs + 1] = info.groupID
            end
        end
        if #groupIDs == 0 then return end

        local groupInfos = C_Traits.GetGroupCurrencyInfo(configID, groupIDs)
        if type(groupInfos) ~= "table" then return end

        local byGroupID = {}
        for _, gInfo in ipairs(groupInfos) do
            if type(gInfo) == "table" and gInfo.traitNodeGroupID then
                byGroupID[gInfo.traitNodeGroupID] = gInfo
            end
        end
        for i = 1, math.min(3, #displayInfos) do
            local gInfo = byGroupID[displayInfos[i].groupID]
            local currencies = gInfo and gInfo.currencyInfos
            local spent = type(currencies) == "table" and type(currencies[1]) == "table"
                and PlainNum(currencies[1].spent, 0) or 0
            treePoints[i] = spent
            found = true
        end
    end)
    return found
end

local function ApplyBestTree()
    local best, bestPoints = nil, 0
    for i = 1, 3 do
        if treePoints[i] > bestPoints then best, bestPoints = i, treePoints[i] end
    end
    if best then
        primaryTree = best
        return true
    end
    return false
end

local function DetectPrimaryTree()
    ns.talentCache = {}
    treePoints = { 0, 0, 0 }
    primaryTree = SCHOOL_FIRE

    -- 1. Classic talent globals (Classic Era, TBC, Wrath, Cata when loaded).
    if type(GetNumTalentTabs) == "function" and type(GetNumTalents) == "function" and type(GetTalentInfo) == "function" then
        local ok, numTabs = pcall(GetNumTalentTabs)
        if ok and type(numTabs) == "number" and numTabs > 0 then
            local sawTalent = false
            for tab = 1, numTabs do
                local okTalents, numTalents = pcall(GetNumTalents, tab)
                if okTalents and type(numTalents) == "number" then
                    for i = 1, numTalents do
                        local okInfo, name, _, _, _, rank = pcall(GetTalentInfo, tab, i)
                        if okInfo and type(name) == "string" then
                            sawTalent = true
                            local pts = PlainNum(rank, 0) or 0
                            ns.talentCache[name] = pts
                            if tab <= 3 then treePoints[tab] = treePoints[tab] + pts end
                        end
                    end
                end
            end
            if sawTalent then
                ApplyBestTree()
                return
            end
        end
    end

    -- 2. Native C_SpecializationInfo.GetTalentInfo query table (Classic Era
    -- 1.15.x, TBC Anniversary 2.5.x, Wrath 3.80.x and Cata, even when
    -- Blizzard_DeprecatedSpecialization fallbacks are turned off).
    if C_SpecializationInfo and type(C_SpecializationInfo.GetTalentInfo) == "function" then
        local sawNative = false
        for tab = 1, 3 do
            for i = 1, 40 do
                local okInfo, info = pcall(C_SpecializationInfo.GetTalentInfo, {
                    specializationIndex = tab,
                    talentIndex = i,
                })
                if not okInfo or type(info) ~= "table" or info.rank == nil then break end
                local name = PlainText(info.name, nil)
                if not name then break end
                sawNative = true
                local pts = PlainNum(info.rank, 0) or 0
                ns.talentCache[name] = pts
                treePoints[tab] = treePoints[tab] + pts
            end
        end
        if sawNative then
            ApplyBestTree()
            return
        end
    end

    -- 3. WoW: Forever (Camelot) 3-tree trait group currency spent.
    if ReadTraitTreePoints() and ApplyBestTree() then
        return
    end

    -- 4. C_SpecializationInfo points spent per tree, then active spec index
    -- (Mists Classic and Mainline / Midnight select spec 1..3 directly).
    if client.specInfo then
        local count = 3
        if type(C_SpecializationInfo.GetNumSpecializations) == "function" then
            local okCount, value = pcall(C_SpecializationInfo.GetNumSpecializations)
            value = PlainNum(value, nil)
            if value and value > 0 then count = value end
        end
        for i = 1, math.min(3, count) do
            local points = ReadSpecializationPoints(i)
            if points then treePoints[i] = points end
        end
        if ApplyBestTree() then return end

        local specFn = (type(C_SpecializationInfo.GetSpecialization) == "function" and C_SpecializationInfo.GetSpecialization)
            or (type(GetSpecialization) == "function" and GetSpecialization)
        if specFn then
            local okSpec, index = pcall(specFn)
            index = okSpec and PlainNum(index, nil) or nil
            if index and index >= 1 and index <= 3 then
                primaryTree = index
                return
            end
        end
    elseif type(GetSpecialization) == "function" then
        local okSpec, index = pcall(GetSpecialization)
        index = okSpec and PlainNum(index, nil) or nil
        if index and index >= 1 and index <= 3 then primaryTree = index end
    end
end

---------------------------------------------------------------------------
-- 12. UI
---------------------------------------------------------------------------

local function ApplySize()
    if not mainFrame or not db then return end
    local size = db.iconSize or defaults.iconSize
    mainFrame:SetSize(size, size)
    if glowTex then glowTex:SetSize(size * 1.7, size * 1.7) end
end

local function ApplyOpacity()
    if not mainFrame or not db then return end
    mainFrame:SetAlpha(db.opacity or 1.0)
end

-- Mouse input has two halves - clicks and motion - and this icon is a Button,
-- which takes both by default. EnableMouse(false) is not enough on its own to
-- stop hover events reaching a Button, so both flags are set explicitly: a
-- locked icon must be genuinely click-through, tooltip included.
local function SetMouseEnabled(enabled)
    if not mainFrame then return end
    mainFrame:EnableMouse(enabled)
    if type(mainFrame.SetMouseMotionEnabled) == "function" then
        TryCall("SetMouseMotionEnabled", mainFrame.SetMouseMotionEnabled, mainFrame, enabled)
    end
    if type(mainFrame.SetMouseClickEnabled) == "function" then
        TryCall("SetMouseClickEnabled", mainFrame.SetMouseClickEnabled, mainFrame, enabled)
    end
end

-- A tooltip that is up when the icon is locked can never be hidden by OnLeave,
-- because a click-through frame no longer receives mouse events. Clear it at
-- the moment of locking, and only when it is ours - never stomp another
-- addon's tooltip.
local function HideOwnedTooltip()
    if type(GameTooltip) ~= "table" or type(GameTooltip.Hide) ~= "function" then return end
    if type(GameTooltip.GetOwner) == "function" then
        local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
        if ok and owner ~= mainFrame then return end
    elseif type(mainFrame.IsMouseOver) == "function" then
        local ok, over = pcall(mainFrame.IsMouseOver, mainFrame)
        if not ok or over ~= true then return end
    end
    pcall(GameTooltip.Hide, GameTooltip)
end

local function ApplyLock()
    if not mainFrame or not db then return end
    mainFrame:SetMovable(not db.locked)
    if db.locked then
        -- Non-interactive while locked: the icon stops taking the mouse
        -- altogether, so clicks pass through to whatever is behind it. That
        -- also means no tooltip and no mouse shortcut; the way back is
        -- /mri lock, which the lock message and the login message both say.
        SetMouseEnabled(false)
        HideOwnedTooltip()
        if glowTex then glowTex:Hide() end
        if dragLabel then dragLabel:Hide() end
    else
        SetMouseEnabled(true)
        mainFrame:RegisterForDrag("LeftButton")
        if glowTex then glowTex:Show() end
        if dragLabel then dragLabel:Show() end
    end
end

local function ShiftHeld()
    if type(IsShiftKeyDown) ~= "function" then return false end
    local ok, down = pcall(IsShiftKeyDown)
    if not ok or Sealed(down) then return false end
    return down == true
end

-- The one place the lock state changes, so the slash command and the mouse
-- shortcuts always behave and report the same way.
local function SetLocked(locked)
    if not db or db.locked == locked then return end
    db.locked = locked
    ApplyLock()
    if locked then
        Print("Frame LOCKED - it no longer takes the mouse. /mri lock to unlock.")
    else
        Print("Frame UNLOCKED. Right-click the icon to lock it, drag to move.")
    end
end

local function IconFor(entry)
    if entry and entry.icon then return entry.icon end
    return "Interface\\Icons\\Spell_Arcane_PortalDalaran"
end

local function ShowIdle()
    if not iconTex then return end
    local entry = LongestReachSpell()
    iconTex:SetTexture(IconFor(entry))
    iconTex:SetDesaturated(true)
    iconTex:SetVertexColor(0.6, 0.6, 0.6)
    nameLabel:SetText("No Target")
    nameLabel:SetTextColor(0.8, 0.8, 0.8, 1)
    rangeLabel:SetText(entry and entry.label or "")
    rangeLabel:SetTextColor(0.6, 0.6, 0.6, 1)
    oorTex:Hide()
end

local function ShowState(text, label, color, iconEntry)
    if not iconTex then return end
    iconTex:SetTexture(IconFor(iconEntry))
    iconTex:SetDesaturated(true)
    iconTex:SetVertexColor(color[1], color[2], color[3])
    nameLabel:SetText(label)
    nameLabel:SetTextColor(color[1], color[2], color[3], 1)
    rangeLabel:SetText(text or "")
    rangeLabel:SetTextColor(color[1], color[2], color[3], 1)
    oorTex:Hide()
end

local function ShowSpell(entry)
    if not iconTex then return end
    iconTex:SetTexture(IconFor(entry))
    iconTex:SetDesaturated(false)
    iconTex:SetVertexColor(1, 1, 1)
    nameLabel:SetText(entry.name or "?")
    nameLabel:SetTextColor(1, 1, 0, 1)
    rangeLabel:SetText(entry.label or "?yd")
    if entry.reach >= 30 then
        rangeLabel:SetTextColor(0, 1, 0, 1)
    elseif entry.reach >= 20 then
        rangeLabel:SetTextColor(1, 1, 0, 1)
    else
        rangeLabel:SetTextColor(1, 0.3, 0, 1)
    end
    oorTex:Hide()
end

local function CreateUI()
    if mainFrame or not db then return end

    -- A Button, not a Frame: RegisterForClicks is a Button method, and the
    -- plain Frame version of this line threw "attempt to call a nil value"
    -- (Lua 5.1 does not name the method), which aborted this whole function -
    -- leaving the icon on its fallback texture, with the drag hint showing
    -- while the saved state said locked, and no mouse wiring at all.
    mainFrame = CreateFrame("Button", "MRIFrame", UIParent)
    mainFrame:SetSize(db.iconSize, db.iconSize)
    mainFrame:SetPoint("CENTER", UIParent, "CENTER", db.posX, db.posY)
    mainFrame:SetAlpha(db.opacity)
    mainFrame:SetFrameStrata("LOW")
    mainFrame:SetFrameLevel(120)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")

    local background = mainFrame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(mainFrame)
    if background.SetColorTexture then
        background:SetColorTexture(0, 0, 0, 0.9)
    else
        background:SetTexture(0, 0, 0, 0.9)
    end

    iconTex = mainFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 3, -3)
    iconTex:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -3, 3)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconTex:SetTexture(IconFor(nil))

    oorTex = mainFrame:CreateTexture(nil, "ARTWORK", nil, 1)
    oorTex:SetAllPoints(iconTex)
    if oorTex.SetColorTexture then
        oorTex:SetColorTexture(0.8, 0, 0, 0.35)
    else
        oorTex:SetTexture(0.8, 0, 0, 0.35)
    end
    oorTex:Hide()

    rangeLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rangeLabel:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 5)
    pcall(function() rangeLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE") end)
    rangeLabel:SetTextColor(1, 1, 1, 1)

    nameLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOP", mainFrame, "TOP", 0, -3)
    pcall(function() nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE") end)
    nameLabel:SetTextColor(1, 1, 0, 1)

    glowTex = mainFrame:CreateTexture(nil, "OVERLAY")
    glowTex:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glowTex:SetBlendMode("ADD")
    glowTex:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)
    glowTex:SetSize(db.iconSize * 1.7, db.iconSize * 1.7)
    glowTex:SetVertexColor(0, 0.7, 1, 0.5)

    dragLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dragLabel:SetPoint("TOP", mainFrame, "BOTTOM", 0, -6)
    pcall(function() dragLabel:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE") end)
    dragLabel:SetTextColor(0, 1, 0.5, 1)
    dragLabel:SetText("DRAG ME  -  R-CLICK TO LOCK")

    local pulse, direction = 0.3, 1
    local pulser = CreateFrame("Frame", nil, mainFrame)
    pulser:SetScript("OnUpdate", function(_, elapsed)
        if not glowTex or not glowTex:IsShown() or not db or db.locked then return end
        pulse = pulse + (elapsed * 1.2 * direction)
        if pulse >= 0.7 then pulse, direction = 0.7, -1 end
        if pulse <= 0.1 then pulse, direction = 0.1, 1 end
        glowTex:SetAlpha(pulse)
    end)

    -- The visuals and the saved state come first, so a wiring failure below
    -- can never leave the icon showing the wrong thing again.
    ApplyLock()
    ShowIdle()

    -- Right-click locks the icon. There is no mouse shortcut for unlocking:
    -- a locked icon is click-through and takes no mouse at all, so /mri lock is
    -- the way back.
    if type(mainFrame.RegisterForClicks) == "function" then
        TryCall("RegisterForClicks", mainFrame.RegisterForClicks, mainFrame, "AnyUp")
    end
    SafeScript(mainFrame, "OnMouseUp", function(_, button)
        if button ~= "RightButton" or not db or db.locked then return end
        if ShiftHeld() then return end
        SetLocked(true)
    end)

    SafeScript(mainFrame, "OnDragStart", function(self)
        if db and not db.locked then self:StartMoving() end
    end)
    SafeScript(mainFrame, "OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        x, y = PlainNum(x, nil), PlainNum(y, nil)
        if x and y then
            db.posX, db.posY = x, y
        end
    end)

    SafeScript(mainFrame, "OnEnter", function(self)
        -- Belt and braces: whatever the client decides to dispatch, a locked
        -- icon shows nothing.
        if db and db.locked then return end
        if type(GameTooltip) ~= "table" then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Mage Range Indicator", 0, 0.8, 1)
        GameTooltip:AddLine(client.flavor .. "  |cFF808080interface " .. client.iface .. "|r", 0.7, 0.7, 0.7)
        if #spells == 0 then
            GameTooltip:AddLine("No spells resolved yet.", 1, 0.5, 0.5)
        else
            GameTooltip:AddLine(" ")
            for i = #spells, math.max(1, #spells - 5), -1 do
                local entry = spells[i]
                local shape = entry.shape == "cone" and " (cone)" or (entry.kind == "aoe" and " (around you)" or "")
                GameTooltip:AddLine(entry.rangeText .. "yd  " .. (entry.name or "?") .. shape, 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to lock (the icon then takes no mouse)", 0, 1, 0.5)
        GameTooltip:AddLine("Drag to move  |  /mri lock to unlock", 0, 1, 0)
        GameTooltip:AddLine("/mri help  /mri status  /mri probe", 0, 1, 0)
        GameTooltip:Show()
    end)
    SafeScript(mainFrame, "OnLeave", function()
        if type(GameTooltip) == "table" then GameTooltip:Hide() end
    end)
end

---------------------------------------------------------------------------
-- 13. Main update
--
-- Range is not an event on any of these clients: the target's distance only
-- changes by movement, so a short throttled tick is the only way to notice.
-- Textures and text are only rewritten when the state actually changes.
---------------------------------------------------------------------------

local function DoUpdate(_, elapsed)
    updateElapsed = updateElapsed + elapsed
    if updateElapsed < 0.1 then return end
    updateElapsed = 0

    if not mainFrame or not mainFrame:IsShown() or not iconTex then return end

    -- One pass, one set of answers.
    ResetAttackable()

    if not HasTarget() then
        if lastState ~= "IDLE" then
            lastState = "IDLE"
            ShowIdle()
        end
        return
    end

    if type(UnitIsDeadOrGhost) == "function" then
        local ok, dead = pcall(UnitIsDeadOrGhost, "target")
        if ok and PlainBool(dead, false) then
            if lastState ~= "DEAD" then
                lastState = "DEAD"
                ShowState("", "Dead", COLOR_DEAD, LongestReachSpell())
            end
            return
        end
    end

    if not AttackablePlain("target") then
        if lastState ~= "FRIENDLY" then
            lastState = "FRIENDLY"
            ShowState("", "Friendly", { 0.3, 0.8, 1 }, LongestReachSpell())
        end
        return
    end

    local entry, state = PickSpell("target")
    local key = state == STATE_IN and entry.stateKey or state
    if key == lastState then return end
    lastState = key

    if state == STATE_IN then
        ShowSpell(entry)
    elseif state == STATE_UNKNOWN then
        ShowState("?", "Unknown", COLOR_UNKNOWN, LongestReachSpell())
    else
        ShowState("OOR", "Out of Range", COLOR_OOR, LongestReachSpell())
    end
end

---------------------------------------------------------------------------
-- 14. Slash commands
---------------------------------------------------------------------------

local function SpellByName(query)
    local key = Trim(query or ""):lower()
    if key == "" then return nil end
    local entry = spellsByName[key]
    if entry then return entry end
    local id = tonumber(key)
    if id then
        for _, candidate in ipairs(spells) do
            if candidate.spellID == id or candidate.id == id then return candidate end
        end
    end
    for name, candidate in pairs(spellsByName) do
        if name:find(key, 1, true) then return candidate end
    end
    return nil
end

local function ReportProbe()
    Print("--- Probe ---")
    Print("Client: " .. client.flavor .. "  client " .. client.version .. " build " .. client.build)
    Print("Interface: " .. client.iface .. "   secret guard: " .. tostring(client.secrets))
    Print("API: C_Spell " .. tostring(client.modern)
        .. "  C_Spell.IsSpellInRange " .. tostring(client.spellRange)
        .. "  C_SpellBook(skillLines) " .. tostring(client.modernBook)
        .. "  C_TooltipInfo " .. tostring(client.tooltip)
        .. "  C_Item.IsItemInRange " .. tostring(client.itemRange)
        .. "  C_SpecializationInfo " .. tostring(client.specInfo)
        .. "  C_Traits " .. tostring(client.traits))
    Print("Legacy globals: GetSpellInfo " .. tostring(type(GetSpellInfo) == "function")
        .. "  GetSpellBookItemName " .. tostring(type(GetSpellBookItemName) == "function")
        .. "  GetNumSpellTabs " .. tostring(type(GetNumSpellTabs) == "function")
        .. "  GetNumTalentTabs " .. tostring(type(GetNumTalentTabs) == "function"))
    Print("Spell list: " .. #spells .. " resolved, " .. #skipped .. " skipped")
    local heap = 0
    if type(collectgarbage) == "function" then
        local ok, kilobytes = pcall(collectgarbage, "count")
        if ok then heap = math.floor(tonumber(kilobytes) or 0) end
    end
    Print("Rebuild delay: " .. stats.rebuildDelay .. "s")
    Print("Lua heap: " .. heap .. " KB   rebuilds: " .. stats.rebuilds
        .. "   spellbook scans: " .. stats.bookScans
        .. "   spell-data requests: " .. stats.requests
        .. "   tooltip reads: " .. stats.tooltipReads)
    Print("(heap and rebuilds should stay put while you stand still; if rebuilds keep climbing, something is firing events)")
    local sources = { tooltip = 0, data = 0, table = 0, radius = 0, set = 0 }
    for _, entry in ipairs(spells) do
        if entry.source and sources[entry.source] then sources[entry.source] = sources[entry.source] + 1 end
    end
    Print("Ranges from: tooltip " .. sources.tooltip .. "  data " .. sources.data
        .. "  radius " .. sources.radius .. "  table " .. sources.table .. "  hand-set " .. sources.set)
    local buckets = {}
    for _, bucket in ipairs(Buckets()) do
        buckets[#buckets + 1] = bucket.yards .. (bucket.item and "*" or "")
    end
    Print("Distance buckets: " .. (#buckets > 0 and table.concat(buckets, " ") or "none") .. "   (* item check)")
    if stats.wiringFailures > 0 then
        Print("Wiring failures: " .. stats.wiringFailures .. "  last: " .. tostring(ns.lastWiringError))
    end
    for _, entry in ipairs(skipped) do
        Print("  skipped: " .. entry.name .. " (id " .. tostring(entry.id) .. ") - " .. entry.why)
    end
end

local function ReportStatus()
    Print("Client: " .. client.flavor .. "  interface " .. client.iface
        .. "  client " .. client.version .. " build " .. client.build)
    Print("Locked: " .. tostring(db and db.locked)
        .. "  size: " .. tostring(db and db.iconSize)
        .. "  opacity: " .. tostring(db and db.opacity)
        .. "  auto-detect: " .. tostring(db and db.autoSpells))
    Print("Primary tree: " .. treeNames[primaryTree] .. " (" .. treePoints[primaryTree] .. "pts)"
        .. "   points Arc=" .. treePoints[1] .. " Fire=" .. treePoints[2] .. " Frost=" .. treePoints[3])
    if #spells > 0 then
        Print("Spells, nearest reach first (the first one that reaches is shown):")
        for i, entry in ipairs(spells) do
            local shape = entry.shape == "cone" and " cone" or (entry.kind == "aoe" and " around you" or "")
            if entry.kind == "aoe" and entry.radius and entry.radius ~= entry.reach then
                shape = shape .. " (data radius " .. entry.radius .. ")"
            end
            Print("  " .. i .. ". " .. entry.rangeText .. "yd " .. (entry.name or "?")
                .. "  [" .. (treeNames[entry.school or 0] or "?") .. "]"
                .. "  priority " .. tostring(entry.priority)
                .. "  from " .. tostring(entry.source)
                .. (entry.auto and "  (auto)" or "")
                .. shape)
        end
    else
        Print("No spells resolved. /mri probe for what the client answered.")
    end
    for _, entry in ipairs(skipped) do
        Print("  skipped: " .. entry.name .. " - " .. entry.why)
    end
end

local function ReportDebug()
    Print("--- Debug ---")
    Print("Client: " .. client.flavor .. "  interface " .. client.iface .. "  build " .. client.build)
    ResetAttackable()
    local hasTarget = HasTarget()
    Print("Target exists: " .. tostring(hasTarget)
        .. "  attackable: " .. tostring(hasTarget and AttackablePlain("target")))
    if hasTarget then Print("Distance buckets say: " .. DistanceText("target")) end
    ResetAttackable()
    Print("Primary tree: " .. treeNames[primaryTree])
    Print("Last state: " .. lastState)
    for _, entry in ipairs(spells) do
        local reaches = SpellReaches(entry, "target")
        Print("  " .. entry.rangeText .. "yd " .. (entry.name or "?")
            .. " (id " .. tostring(entry.spellID) .. ", " .. tostring(entry.source) .. ")"
            .. "  reaches=" .. tostring(reaches))
    end
end

local function HandleCommand(message)
    if not db then
        Print("Still loading - try again in a moment.")
        return
    end
    local command, argument = SplitCommand(message)

    if command == "" or command == "help" then
        Print("/mri lock - toggle lock/unlock")
        Print("Right-click the icon to lock it (click-through), /mri lock to unlock")
        Print("/mri size <16-128> - icon size")
        Print("/mri opacity <0.0-1.0> - transparency")
        Print("/mri reset - settings back to defaults")
        Print("/mri show | hide - show or hide the indicator")
        Print("/mri status - client, spells and ranges")
        Print("/mri probe - what this client actually supports")
        Print("/mri debug - live per-spell range answers")
        Print("/mri talents - rescan the spellbook and talents")
        Print("/mri range <spell> <yards|auto> - correct a range by hand")
        Print("/mri auto on|off - pick up unlisted short-range spells")
    elseif command == "lock" then
        SetLocked(not db.locked)
    elseif command == "size" then
        local size = tonumber(argument)
        if not size then
            Print("Usage: /mri size <16-128> (current: " .. tostring(db.iconSize) .. ")")
        else
            db.iconSize = math.max(16, math.min(128, math.floor(size)))
            ApplySize()
            Print("Size: " .. db.iconSize)
        end
    elseif command == "opacity" or command == "alpha" then
        local opacity = tonumber(argument)
        if not opacity then
            Print("Usage: /mri opacity <0.0-1.0> (current: " .. tostring(db.opacity) .. ")")
        else
            db.opacity = math.max(0, math.min(1, opacity))
            ApplyOpacity()
            Print("Opacity: " .. db.opacity)
        end
    elseif command == "reset" then
        for key, value in pairs(defaults) do
            if type(value) == "table" then
                local copy = {}
                for innerKey, innerValue in pairs(value) do copy[innerKey] = innerValue end
                db[key] = copy
            else
                db[key] = value
            end
        end
        if mainFrame then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("CENTER", UIParent, "CENTER", defaults.posX, defaults.posY)
            mainFrame:Show()
        end
        ApplySize()
        ApplyOpacity()
        ApplyLock()
        InvalidateRanges()
        BuildSpellList()
        lastState = ""
        Print("Reset to defaults.")
    elseif command == "show" then
        if mainFrame then mainFrame:Show() end
        lastState = ""
        Print("Shown.")
    elseif command == "hide" then
        if mainFrame then mainFrame:Hide() end
        Print("Hidden. /mri show to restore.")
    elseif command == "status" then
        ReportStatus()
    elseif command == "probe" then
        ReportProbe()
    elseif command == "debug" then
        ReportDebug()
    elseif command == "talents" then
        DetectPrimaryTree()
        InvalidateRanges()
        BuildSpellList()
        Print("Rescanned. Primary tree: " .. treeNames[primaryTree]
            .. "  spells: " .. #spells)
    elseif command == "auto" then
        argument = argument:lower()
        if argument == "on" or argument == "off" then
            db.autoSpells = (argument == "on")
            InvalidateRanges()
            BuildSpellList()
            Print("Auto-detect short-range spells: " .. argument)
        else
            Print("Usage: /mri auto on|off (currently " .. tostring(db.autoSpells) .. ")")
        end
    elseif command == "range" then
        local key, value = argument:match("^(%S+)%s*(.*)$")
        local entry = SpellByName(key)
        if not entry then
            Print("Usage: /mri range <spell> <yards|auto>. Known spells: " .. (#spells > 0 and spells[1].name or "none"))
            return
        end
        value = Trim(value):lower()
        if value == "auto" or value == "" then
            db.rangeOverride[entry.name] = nil
            Print(entry.name .. ": range back to the client's own value.")
        else
            local yards = tonumber(value)
            if not yards or yards < 1 or yards > 60 then
                Print("Usage: /mri range " .. entry.name .. " <1-60|auto>")
                return
            end
            db.rangeOverride[entry.name] = math.floor(yards + 0.5)
            Print(entry.name .. ": range set to " .. db.rangeOverride[entry.name] .. " yd.")
        end
        InvalidateRanges()
        BuildSpellList()
    else
        Print("Unknown command: " .. command .. " - /mri help")
    end
end

-- Addon compartment entry (Forever and Midnight only; named by the TOC).
function MRI_OnCompartmentClick()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    elseif mainFrame then
        mainFrame:Show()
    end
end

function MRI_OnCompartmentEnter(first, second)
    local button = type(first) == "table" and first or second
    if type(GameTooltip) ~= "table" or type(button) ~= "table" then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Mage Range Indicator", 0, 0.8, 1)
    GameTooltip:AddLine("Click to show or hide the indicator", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function MRI_OnCompartmentLeave()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

SLASH_MRI1 = "/mri"
SLASH_MRI2 = "/magerange"
SlashCmdList["MRI"] = function(message)
    local ok, err = pcall(HandleCommand, message)
    if not ok then Print("Command failed: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- 15. Events
--
-- One frame, one handler table (Forever guide, rule 6). Nothing here registers
-- COMBAT_LOG_EVENT_UNFILTERED, which throws on Midnight and is unavailable on
-- Forever. Registering an event an unknown client does not have can throw as
-- well, so every registration is guarded.
---------------------------------------------------------------------------

local events = {}

function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    if type(MageRangeIndicatorDB) ~= "table" then MageRangeIndicatorDB = {} end
    db = MageRangeIndicatorDB
    for key, value in pairs(defaults) do
        if db[key] == nil then
            if type(value) == "table" then
                local copy = {}
                for innerKey, innerValue in pairs(value) do copy[innerKey] = innerValue end
                db[key] = copy
            else
                db[key] = value
            end
        end
    end
    ns.db = db
end

function events:PLAYER_LOGIN()
    ns.QueueInit()
end

function events:PLAYER_ENTERING_WORLD()
    ns.QueueInit()
end

function events:PLAYER_TARGET_CHANGED()
    updateElapsed = 999
    lastState = ""
end

function events:SPELLS_CHANGED()
    if not initialized then return end
    -- The spellbook itself changed, so it has to be rescanned, and every cached
    -- spell record is suspect. One session-wide request budget is spent only
    -- once, which is what keeps this from becoming a request/rebuild loop.
    InvalidateBook()
    spellInfoCache, requestedSpells, radiusCache = {}, {}, {}
    ns.MarkDirty("spells")
end

function events:SPELL_DATA_LOAD_RESULT(spellID, success)
    if not initialized then return end
    if type(spellID) ~= "number" then return end
    -- The client announces every spell it loads, including ones this addon has
    -- no interest in. Only ours may cost a rebuild.
    local ours = wantedIDs[spellID]
    if not ours and book then
        ours = book.byID and book.byID[spellID] ~= nil
    end
    if not ours then return end
    spellInfoCache[spellID] = nil
    radiusCache[spellID] = nil
    ns.MarkDirty("spell data")
end

function events:GET_ITEM_INFO_RECEIVED(id, success)
    OnItemLoaded(id, success)
end

function events:CHARACTER_POINTS_CHANGED()
    if initialized then ns.QueueRebuild() end
end

function events:PLAYER_TALENT_UPDATE()
    if initialized then ns.QueueRebuild() end
end

function events:PLAYER_SPECIALIZATION_CHANGED()
    if initialized then ns.QueueRebuild() end
end

function events:TRAIT_CONFIG_UPDATED()
    if initialized then ns.QueueRebuild() end
end

function events:PLAYER_REGEN_DISABLED()
    inCombatLockdown = true
    updateElapsed = 999
    lastState = ""
end

function events:PLAYER_REGEN_ENABLED()
    inCombatLockdown = false
    updateElapsed = 999
    lastState = ""
end

local eventFrame = CreateFrame("Frame")
for event in pairs(events) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = events[event]
    if handler then handler(events, ...) end
end)

---------------------------------------------------------------------------
-- 16. Start-up
---------------------------------------------------------------------------

-- One place that refreshes everything derived from the spellbook and talents.
local function RebuildNow(reason)
    DetectPrimaryTree()
    InvalidateRanges()
    BuildSpellList()
    lastState = ""
end

local function InitOnce()
    if initialized or classChecked then return end
    classChecked = true
    local _, class = UnitClass("player")
    if class ~= "MAGE" then
        isMage = false
        Print("This addon is for Mages - it will stay dormant on this character.")
        return
    end
    isMage = true
    initialized = true

    if type(InCombatLockdown) == "function" then
        local ok, locked = pcall(InCombatLockdown)
        inCombatLockdown = ok and locked == true or false
    end
    SetRaceDistances()
    EnsureItems()
    DetectPrimaryTree()
    InvalidateRanges()
    BuildSpellList()
    -- Nothing below may be allowed to die quietly on a beta client: if the
    -- icon cannot be built, say so and keep the commands working.
    TryCall("CreateUI", CreateUI)
    if not mainFrame then
        Print("The icon could not be built on this client. /mri probe for details.")
        return
    end
    mainFrame:Show()

    local updater = CreateFrame("Frame")
    updater:SetScript("OnUpdate", DoUpdate)

    -- One line at login, and only the part of it you might act on. The client,
    -- the build and the spell list all live in /mri status and /mri probe for
    -- when they are wanted.
    if db.locked then
        Print("v" .. ADDON_VERSION .. " ready - icon LOCKED (click-through), /mri lock to move it.")
    else
        Print("v" .. ADDON_VERSION .. " ready - drag the icon, right-click to lock it. /mri help")
    end
end

ns.QueueInit = function()
    if initialized or classChecked then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, InitOnce)
    else
        local elapsed = 0
        local wait = CreateFrame("Frame")
        wait:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if elapsed < 0.5 then return end
            self:SetScript("OnUpdate", nil)
            InitOnce()
        end)
    end
end

-- Anything that invalidates the spell list goes through here. Events arrive in
-- storms on a fresh login (SPELLS_CHANGED, spell data, traits) and each one
-- used to schedule its own rebuild: a full spellbook scan and a few hundred
-- allocations per event, forever, whenever the client kept answering. One
-- pending rebuild bounds that to at most one per second.
local rebuildQueued = false
local REBUILD_DELAY_MIN, REBUILD_DELAY_MAX = 0.75, 5

ns.MarkDirty = function(reason)
    if not initialized or rebuildQueued then return end
    rebuildQueued = true
    local function run()
        rebuildQueued = false
        if not initialized then return end

        -- Back off while events keep coming: a client that fires something
        -- every frame must not turn into a rebuild every 0.75s forever.
        if type(GetTime) == "function" then
            local now = GetTime()
            local last = stats.lastRebuildAt
            if last > 0 and (now - last) < 1 then
                stats.rebuildDelay = math.min(REBUILD_DELAY_MAX, stats.rebuildDelay * 2)
            elseif last > 0 and (now - last) > 10 then
                stats.rebuildDelay = REBUILD_DELAY_MIN
            end
            stats.lastRebuildAt = now
        end

        RebuildNow(reason)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(stats.rebuildDelay, run)
    else
        run()
    end
end

ns.QueueRebuild = ns.MarkDirty

ns.events = events
ns.spells = spells
ns.rebuild = ns.QueueRebuild
ns.PickSpell = PickSpell
ns.Init = InitOnce
ns.HandleCommand = HandleCommand
