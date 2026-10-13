--[[==========================================================================
 tests/spec.lua

 Offline spec for MageRangeIndicator, run by tests/run.sh under real Lua 5.1.
 It loads the addon twice - once against a stub of the WoW: Forever client
 (interface 16001, C_Spell / C_SpellBook, secret values) and once against a
 stub of a Classic-era client (legacy spellbook and talent globals) - and
 checks what the indicator decides and shows.
==========================================================================]]

local REPO = assert(REPO_ROOT, "run via tests/run.sh")

local Stub = assert(loadfile(REPO .. "/tests/wow_stub.lua"))()

local passed, failures = 0, {}

local function check(condition, label, detail)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = label .. (detail and ("  [" .. tostring(detail) .. "]") or "")
    end
end

local function eq(actual, expected, label)
    check(actual == expected, label, "got " .. tostring(actual) .. ", want " .. tostring(expected))
end

---------------------------------------------------------------------------
-- Harness
---------------------------------------------------------------------------

local function Load(mode, setup)
    Stub.Reset()
    setup()
    Stub.Install(mode)

    local chunk, loadError = loadfile(REPO .. "/MageRangeIndicator.lua")
    check(chunk ~= nil, "addon file compiles", loadError)
    if not chunk then return nil end

    local ns = {}
    local ok, runError = pcall(chunk, "MageRangeIndicator", ns)
    check(ok, "addon file executes at load time", runError)
    return ns
end

local function Boot(ns)
    local ok, bootError = pcall(function()
        Stub.FireEvent("ADDON_LOADED", "MageRangeIndicator")
        Stub.FireEvent("PLAYER_LOGIN")
        Stub.FlushTimers()          -- QueueInit's C_Timer.After
        Stub.Tick(0.5, 3)           -- the 0.1s update throttle
    end)
    check(ok, "start-up and first update without errors", bootError)
    return ns
end

local function Display()
    local frame = Stub.FindFrame("MRIFrame")
    if not frame then return "<no frame>", "<no frame>" end
    local rangeLabel = frame.fontStrings[1]
    local nameLabel = frame.fontStrings[2]
    return nameLabel and nameLabel.text or "", rangeLabel and rangeLabel.text or ""
end

local function Update(seconds)
    Stub.Tick(seconds or 0.5, 1)
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------

-- A mage on the Forever client: four damage spells, two 30-yard ones, plus the
-- self-centred spells that have no target range.
local function ForeverMage()
    Stub.specPoints = { 0, 40, 0 }   -- Fire primary

    Stub.AddSpell("Fireball", 133, 35)
    Stub.AddSpell("Frostbolt", 116, 30)
    Stub.AddSpell("Scorch", 2948, 30)
    Stub.AddSpell("Arcane Missiles", 5143, 30)
    Stub.AddSpell("Fire Blast", 2136, 20)
    Stub.AddSpell("Arcane Blast", 30451, 30)   -- known to the client, not in the book
    Stub.AddSpell("Frost Nova", 122, 0, { hasRange = false, description = "Freezes all enemies within 10 yards for up to 8 sec." })
    Stub.AddSpell("Cone of Cold", 120, 0, { hasRange = false, description = "Targets within 10 yards in a cone." })
    Stub.AddSpell("Arcane Explosion", 1449, 0, { hasRange = false, description = "Causes an explosion within 10 yards." })
    Stub.AddSpell("Blast Wave", 11113, 0, { hasRange = false, description = "Targets within 10 yards are knocked back." })

    for _, entry in ipairs({
        { "Fireball", 133 }, { "Frostbolt", 116 }, { "Scorch", 2948 }, { "Arcane Missiles", 5143 },
        { "Fire Blast", 2136 }, { "Frost Nova", 122 }, { "Cone of Cold", 120 },
        { "Arcane Explosion", 1449 }, { "Blast Wave", 11113 },
    }) do
        Stub.AddBookSpell(entry[1], entry[2])
    end

    for id, line in pairs({
        [133] = "35 yd range", [116] = "30 yd range", [2948] = "30 yd range", [5143] = "30 yd range",
        [2136] = "20 yd range",
    }) do
        Stub.tooltipRanges[id] = line
    end

    Stub.itemsCached[9606] = "A Known 10 Yard Item"
    Stub.itemRanges[9606] = 10
end

local function testForeverNearestSpell()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    check(#(ns.spells or {}) >= 8, "spell list resolves the known spells", #(ns.spells or {}))

    -- 25 yards: the 30-yard tier is the nearest that reaches, and Fire's
    -- Scorch wins that tier on spec priority.
    Stub.distance = 25
    Update()
    local name, range = Display()
    eq(name, "Scorch", "25 yd -> nearest reaching spell is Scorch")
    eq(range, "30yd", "25 yd -> Scorch shows its 30 yard range")

    -- 15 yards: Fire Blast (20) is now the nearest.
    Stub.distance = 15
    Update()
    name, range = Display()
    eq(name, "Fire Blast", "15 yd -> Fire Blast is the nearest")
    eq(range, "20yd", "15 yd -> Fire Blast shows 20 yards")

    -- 7 yards: only the self-centred 10-yard spells reach. Their reach is
    -- measured at 9 (10 yard radius minus the shortfall seen in game), and the
    -- 8-yard duel bucket passes. The three of them tie, so the Fire-primary
    -- spec breaks the tie towards Fire.
    Stub.distance = 7
    Update()
    name, range = Display()
    eq(name, "Blast Wave", "7 yd -> Fire spec breaks the 9-yard tie towards Blast Wave")
    eq(range, "9yd", "7 yd -> the label shows the measured reach, not the 10 yard radius")

    -- 40 yards: nothing reaches.
    Stub.distance = 40
    Update()
    name, range = Display()
    eq(name, "Out of Range", "40 yd -> out of range")
    eq(range, "OOR", "40 yd -> OOR label")
end

local function testSpecPriorityTieBreak()
    local ns = Boot(Load("forever", function()
        ForeverMage()
        Stub.specPoints = { 0, 0, 40 }   -- Frost primary
    end))
    if not ns then return end

    Stub.distance = 7
    Update()
    local name = Display()
    eq(name, "Frost Nova", "Frost spec breaks the tie towards the first-listed Frost spell")
end

local function testForeverStates()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    Stub.targetExists = false
    Update()
    local name = Display()
    eq(name, "No Target", "no target -> idle")

    Stub.targetExists = true
    Stub.targetDead = true
    Update()
    name = Display()
    eq(name, "Dead", "dead target -> dead")

    Stub.targetDead = false
    Stub.targetAttackable = false
    Update()
    name = Display()
    eq(name, "Friendly", "friendly target -> friendly")

    Stub.targetAttackable = true
    Stub.distance = 25
    Update()
    name = Display()
    eq(name, "Scorch", "hostile target again -> back to the range readout")
end

local function testSecrets()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    Stub.secretEnabled = true
    Stub.distance = 25
    Update()
    local name, range = Display()
    eq(name, "Unknown", "secret range answers -> unknown state, never a wrong claim")
    eq(range, "?", "secret range answers -> question mark")

    -- The probe and status reports must survive secret values too.
    local ok = pcall(Stub.RunSlash, "probe")
    check(ok, "probe runs with secret values present")
    ok = pcall(Stub.RunSlash, "debug")
    check(ok, "debug runs with secret values present")
    check(not Stub.ChatContains("Command failed"), "no command raised with secrets present")

    Stub.secretEnabled = false
    Update()
    eq(Display(), "Scorch", "plain answers come back after secrets stop")
end

local function testClientNumbersWin()
    local ns = Boot(Load("forever", function()
        ForeverMage()
        -- The client's own numbers already include the range talent: spell data
        -- and the tooltip say 41, the table says 35.
        Stub.spells[133].maxRange = 41
        Stub.tooltipRanges[133] = "41 yd range"
    end))
    if not ns then return end

    local fireball
    for _, entry in ipairs(ns.spells) do
        if entry.name == "Fireball" then fireball = entry end
    end
    check(fireball ~= nil, "Fireball resolved from the spellbook")
    if fireball then
        eq(fireball.rangeText, "41", "tooltip range wins over the table")
        eq(fireball.source, "tooltip", "range source is the tooltip")
    end

    Stub.distance = 38
    Update()
    local name, range = Display()
    eq(name, "Fireball", "38 yd -> the talent-widened Fireball reaches")
    eq(range, "41yd", "38 yd -> 41 yards shown")

    -- Without a tooltip line, spell data is next in line.
    local ns2 = Boot(Load("forever", function()
        ForeverMage()
        Stub.spells[133].maxRange = 41
        Stub.tooltipRanges[133] = nil
    end))
    if ns2 then
        local entry
        for _, candidate in ipairs(ns2.spells) do
            if candidate.name == "Fireball" then entry = candidate end
        end
        if entry then
            eq(entry.rangeText, "41", "spell data is used when the tooltip says nothing")
            eq(entry.source, "data", "range source is the data")
        end
    end
end

local function testAutoDiscovery()
    local ns = Boot(Load("forever", function()
        ForeverMage()
        -- A short-range ability the tables know nothing about.
        Stub.AddSpell("Molten Blast", 425339, 0, { hasRange = false, description = "Targets within 10 yards burn." })
        Stub.AddBookSpell("Molten Blast", 425339)
    end))
    if not ns then return end

    local auto = ns.spellsByName and ns.spellsByName["molten blast"]
    check(auto ~= nil, "unlisted short-range spell is picked up from the spellbook")
    if auto then
        eq(auto.reach, 10, "auto spell reach comes from its description radius")
    end

    Stub.RunSlash("auto off")
    check(ns.spellsByName["molten blast"] == nil, "auto off stops picking unlisted spells up")
    Stub.RunSlash("auto on")
    check(ns.spellsByName["molten blast"] ~= nil, "auto on picks them up again")
end

local function testItemBuckets()
    local ns = Boot(Load("forever", function()
        ForeverMage()
        Stub.specPoints = { 0, 0, 40 }    -- Frost, so Frost Nova wins the 9 yard tie
        Stub.interactDisabled = true      -- no CheckInteractDistance on this build
        Stub.itemsCached[9606] = "A Known 10 Yard Item"
        Stub.itemRanges[9606] = 10
        Stub.itemsCached[8149] = "A Known 5 Yard Item"
        Stub.itemRanges[8149] = 5
    end))
    if not ns then return end

    Stub.distance = 4
    Update()
    local name = Display()
    eq(name, "Frost Nova", "item buckets measure a self-centred spell when interact checks are refused")

    -- With no item data and no interact checks, the answer is unknown, not a
    -- wrong "in range".
    local ns2 = Boot(Load("forever", function()
        ForeverMage()
        Stub.interactDisabled = true
        Stub.itemsCached = {}
    end))
    if ns2 then
        Stub.distance = 4
        Update()
        eq(Display(), "Fire Blast",
            "with no bucket data the self-centred spells stay unresolved and the nearest known spell is shown")
        check(#Stub.pendingItemRequests > 0, "missing range items are requested from the client")
    end
end

local function testItemLoading()
    local ns = Boot(Load("forever", function()
        ForeverMage()
        Stub.specPoints = { 0, 0, 40 }
        Stub.interactDisabled = true
        Stub.itemsCached = {}
    end))
    if not ns then return end

    local requested = {}
    for _, id in ipairs(Stub.pendingItemRequests) do requested[#requested + 1] = id end
    check(#requested > 0, "the addon asks the client to load the range items")

    -- The client answers for them a moment later, and the self-centred spell
    -- becomes measurable without a rebuild.
    for _, id in ipairs(requested) do
        Stub.itemsCached[id] = "Loaded Range Item"
        Stub.itemRanges[id] = 5
        Stub.FireEvent("GET_ITEM_INFO_RECEIVED", id, true)
    end

    Stub.distance = 4
    Update()
    eq(Display(), "Frost Nova", "a range item arriving makes the self-centred spell measurable")
end

local function testLegacyTalentMaths()
    local ns = Boot(Load("tbc", function()
        Stub.specPoints = { 0, 0, 0 }
        Stub.class = "MAGE"

        Stub.AddSpell("Fireball", 133, 35)
        Stub.AddSpell("Frostbolt", 116, 30)
        Stub.AddSpell("Scorch", 2948, 30)
        Stub.AddSpell("Fire Blast", 2136, 20)
        Stub.AddSpell("Frost Nova", 122, 0)
        for _, entry in ipairs({
            { "Fireball", 133 }, { "Frostbolt", 116 }, { "Scorch", 2948 },
            { "Fire Blast", 2136 }, { "Frost Nova", 122 },
        }) do
            Stub.AddBookSpell(entry[1], entry[2])
        end

        Stub.talents = {
            [1] = { { name = "Arcane Focus", rank = 0, max = 5 } },
            [2] = { { name = "Flame Throwing", rank = 2, max = 2 } },
            [3] = { { name = "Arctic Reach", rank = 2, max = 2 } },
        }
        -- The client's own answers, with the talents already folded in.
        Stub.legacyRanges = {
            fireball = 41, frostbolt = 36, scorch = 41, ["fire blast"] = 26, ["frost nova"] = 9,
        }
    end))
    if not ns then return end

    local byName = {}
    for _, entry in ipairs(ns.spells) do byName[entry.name] = entry end

    check(byName["Fireball"] ~= nil and byName["Frostbolt"] ~= nil, "legacy spellbook resolves by name")
    if byName["Fireball"] then eq(byName["Fireball"].rangeText, "41", "Flame Throwing 2/2 -> Fireball 41 yd") end
    if byName["Frostbolt"] then eq(byName["Frostbolt"].rangeText, "36", "Arctic Reach 2/2 -> Frostbolt 36 yd (+20%)") end
    if byName["Frost Nova"] then eq(byName["Frost Nova"].rangeText, "11", "Arctic Reach widens Frost Nova's measured reach to 11") end

    Stub.distance = 25
    Update()
    local name, range = Display()
    eq(name, "Fire Blast", "legacy 25 yd -> the 26 yard Fire Blast is nearest")
    eq(range, "26yd", "legacy 25 yd -> 26 yards shown")
end

local function testLegacyOverride()
    local ns = Boot(Load("tbc", function()
        Stub.AddSpell("Fireball", 133, 35)
        Stub.AddSpell("Frostbolt", 116, 30)
        Stub.AddBookSpell("Fireball", 133)
        Stub.AddBookSpell("Frostbolt", 116)
        Stub.talents = { [1] = {}, [2] = {}, [3] = { { name = "Arctic Reach", rank = 2, max = 2 } } }
        Stub.legacyRanges = { fireball = 35, frostbolt = 36 }
    end))
    if not ns then return end

    Stub.RunSlash("range frostbolt 30")
    check(Stub.ChatContains("range set to 30"), "override command confirms")
    local entry = ns.spellsByName and ns.spellsByName["frostbolt"]
    if entry then
        eq(entry.rangeText, "30", "override replaces the computed range")
        eq(entry.source, "set", "override marks the range as hand-set")
    end

    Stub.RunSlash("range frostbolt auto")
    entry = ns.spellsByName and ns.spellsByName["frostbolt"]
    if entry then eq(entry.rangeText, "36", "auto hands the range back to the client") end
end

local function testMouseLock()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    local frame = Stub.FindFrame("MRIFrame")
    check(frame ~= nil, "the icon exists for the mouse shortcuts")

    -- Right-click locks it.
    Stub.shift = false
    check(Stub.ClickIcon("RightButton"), "right-click reaches the icon")
    eq(ns.db.locked, true, "right-click locks the icon")
    check(Stub.ChatContains("Frame LOCKED"), "locking by mouse is confirmed in chat")
    check(frame.mouse ~= false, "the mouse stays enabled while locked so it can be unlocked again")
    check(frame.movable == false, "the locked icon cannot be dragged")

    -- Right-click again while locked changes nothing.
    Stub.ClickIcon("RightButton")
    eq(ns.db.locked, true, "right-click while already locked is a no-op")

    -- Shift right-click unlocks it.
    Stub.shift = true
    Stub.ClickIcon("RightButton")
    eq(ns.db.locked, false, "shift right-click unlocks the icon")
    check(Stub.ChatContains("Frame UNLOCKED"), "unlocking by mouse is confirmed in chat")
    check(frame.movable == true, "the unlocked icon can be dragged again")

    -- Plain right-click after unlocking locks it again (not a toggle hijacked
    -- by a stuck shift key).
    Stub.shift = false
    Stub.ClickIcon("RightButton")
    eq(ns.db.locked, true, "right-click still locks after an unlock")

    -- The tooltip says how to get out of each state.
    Stub.HoverIcon()
    check(Stub.ChatContains ~= nil, "tooltip hover runs")
    local tooltip = _G.GameTooltip
    check(tooltip ~= nil and tooltip.lines ~= nil, "the tooltip was filled")
    local lockedHint = false
    for _, line in ipairs(tooltip.lines or {}) do
        if type(line) == "string" and line:find("shift right-click to unlock", 1, true) then lockedHint = true end
    end
    check(lockedHint, "the locked tooltip explains the unlock shortcut")

    Stub.shift = true
    Stub.ClickIcon("RightButton")
    Stub.HoverIcon()
    local unlockedHint = false
    for _, line in ipairs(tooltip.lines or {}) do
        if type(line) == "string" and line:find("Right-click to lock", 1, true) then unlockedHint = true end
    end
    check(unlockedHint, "the unlocked tooltip explains the lock shortcut")

    -- Left-drag still only moves while unlocked.
    eq(frame.movable, true, "unlocked again at the end of the mouse checks")
end

local function testCommands()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    Stub.RunSlash("help")
    check(Stub.ChatContains("/mri probe"), "help lists the commands")

    Stub.RunSlash("probe")
    check(Stub.ChatContains("Client: WoW: Forever"), "probe names the client")
    check(Stub.ChatContains("Arcane Blast"), "probe reports the spell the character does not know")

    Stub.RunSlash("status")
    check(Stub.ChatContains("Primary tree: Fire"), "status reports the primary tree")
    check(Stub.ChatContains("30yd Scorch"), "status lists ranges and spells")

    Stub.RunSlash("debug")
    check(Stub.ChatContains("Distance buckets say"), "debug reports the distance buckets")

    Stub.RunSlash("size 64")
    eq(ns.db.iconSize, 64, "size command applies")
    Stub.RunSlash("opacity 0.5")
    eq(ns.db.opacity, 0.5, "opacity command applies")
    Stub.RunSlash("lock")
    eq(ns.db.locked, true, "lock command toggles")
    Stub.RunSlash("lock")

    Stub.RunSlash("nonsense")
    check(Stub.ChatContains("Unknown command"), "unknown commands are reported")
end

local function testNonMage()
    local ns = Load("forever", function()
        ForeverMage()
        Stub.class = "WARRIOR"
    end)
    if not ns then return end

    local ok = pcall(function()
        Stub.FireEvent("ADDON_LOADED", "MageRangeIndicator")
        Stub.FireEvent("PLAYER_LOGIN")
        Stub.FireEvent("PLAYER_ENTERING_WORLD")
        Stub.FlushTimers()
        Stub.Tick(1.0, 2)
    end)
    check(ok, "non-mage load is quiet and safe")
    check(Stub.FindFrame("MRIFrame") == nil, "no frame is built for a non-mage")
    check(Stub.ChatContains("for Mages"), "non-mages are told once")
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------

testForeverNearestSpell()
testSpecPriorityTieBreak()
testForeverStates()
testSecrets()
testClientNumbersWin()
testAutoDiscovery()
testItemBuckets()
testItemLoading()
testMouseLock()
testLegacyTalentMaths()
testLegacyOverride()
testCommands()
testNonMage()

if #failures > 0 then
    io.write("FAILED ", #failures, " of ", passed + #failures, " checks\n")
    for _, failure in ipairs(failures) do io.write("  - ", failure, "\n") end
    error("spec failures", 0)
end

io.write("ok: ", passed, " checks passed\n")
