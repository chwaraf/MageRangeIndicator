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

-- A test that raises is a failure like any other, and the rest still run: a
-- build that breaks early should still produce the whole report.
local function runTest(fn, name)
    local ok, err = pcall(fn)
    if not ok then
        failures[#failures + 1] = name .. " raised: " .. tostring(err)
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
    Stub.Install(mode)
    if setup then setup() end

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
    if not frame then return end

    local function tooltipLines()
        Stub.HoverIcon()
        return _G.GameTooltip and _G.GameTooltip.lines or {}
    end
    local function tooltipHas(fragment)
        for _, line in ipairs(tooltipLines()) do
            if type(line) == "string" and line:find(fragment, 1, true) then return true end
        end
        return false
    end
    local function chatCount() return #Stub.chat end

    local dragHint = frame.fontStrings[3]

    ---------------------------------------------------------------------
    -- Unlocked: draggable, interactive, and right-click locks it.
    ---------------------------------------------------------------------
    eq(ns.db.locked, false, "starts unlocked")
    check(Stub.IconTakesMouse(), "an unlocked icon takes the mouse")
    check(dragHint and dragHint:IsShown(), "the drag hint is shown while unlocked")
    check(tooltipHas("Right-click to lock"), "the unlocked tooltip advertises the lock option")

    -- Shift right-click is not a lock shortcut, so it is ignored.
    Stub.shift = true
    local before = chatCount()
    Stub.ClickIcon("RightButton")
    eq(ns.db.locked, false, "shift right-click does not lock")
    eq(chatCount(), before, "shift right-click says nothing")

    Stub.shift = false
    check(Stub.ClickIcon("RightButton"), "right-click reaches the icon")
    eq(ns.db.locked, true, "right-click locks the icon")
    check(Stub.ChatContains("Frame LOCKED"), "locking by mouse is confirmed in chat")

    ---------------------------------------------------------------------
    -- Locked: click-through. No mouse, no tooltip, no shortcuts at all.
    ---------------------------------------------------------------------
    eq(frame.mouse, false, "a locked icon takes no mouse at all")
    check(not Stub.IconTakesMouse(), "the icon is click-through while locked")
    check(frame.movable == false, "a locked icon cannot be dragged")
    check(not dragHint:IsShown(), "the drag hint is hidden while locked")

    before = chatCount()
    for _, button in ipairs({ "RightButton", "LeftButton" }) do
        check(not Stub.ClickIcon(button), "a click on a locked icon (" .. button .. ") is not received")
    end
    check(not Stub.HoverIcon(), "hovering a locked icon is not received either")
    eq(ns.db.locked, true, "clicks on a locked icon change nothing")
    eq(chatCount(), before, "clicks on a locked icon say nothing")

    -- The lock message has to name the way out, since no mouse shortcut exists.
    for _, line in ipairs(Stub.chat) do
        if line:find("Frame LOCKED", 1, true) then
            check(line:find("/mri lock to unlock", 1, true) ~= nil,
                "the lock message says how to unlock", line)
        end
    end

    ---------------------------------------------------------------------
    -- /mri lock is the way back.
    ---------------------------------------------------------------------
    Stub.RunSlash("lock")
    eq(ns.db.locked, false, "/mri lock unlocks the icon")
    check(Stub.ChatContains("Frame UNLOCKED"), "unlocking is confirmed in chat")
    check(Stub.IconTakesMouse(), "the icon takes the mouse again")
    check(frame.movable == true, "the unlocked icon can be dragged")
    check(dragHint:IsShown(), "the drag hint comes back when unlocked")
    check(tooltipHas("Right-click to lock"), "the lock option is advertised again")

    ---------------------------------------------------------------------
    -- And right-click locks it once more.
    ---------------------------------------------------------------------
    Stub.shift = false
    Stub.ClickIcon("RightButton")
    eq(ns.db.locked, true, "right-click locks it again after an unlock")
    eq(frame.mouse, false, "and it is click-through again")
end

local function testUpdateLoopChurn()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    Stub.distance = 25
    Update()
    eq(Display(), "Scorch", "settled into a range state before measuring churn")

    local rebuilds, scans = ns.stats.rebuilds, ns.stats.bookScans
    local before = Stub.SnapshotCalls()
    for _ = 1, 200 do Update() end
    local after = Stub.SnapshotCalls()

    local function delta(name)
        return (after[name] or 0) - (before[name] or 0)
    end

    check(delta("isSpellInRange") > 0, "the update loop does ask the range check (that is its job)")
    eq(delta("getSpellInfo"), 0, "the update loop never asks the client for spell info")
    eq(delta("getSpellBookItemInfo"), 0, "the update loop never rescans the spellbook")
    eq(delta("getSpellBookSkillLineInfo"), 0, "the update loop never reads spellbook skill lines")
    eq(delta("getSpellDescription"), 0, "the update loop never re-reads spell descriptions")
    eq(delta("requestLoadSpellData"), 0, "the update loop never requests spell data")
    eq(ns.stats.rebuilds - rebuilds, 0, "the update loop never rebuilds the spell list")
    eq(ns.stats.bookScans - scans, 0, "the update loop never rescans the book")
end

local function testEventStorms()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    check(ns.stats.rebuilds <= 2, "start-up rebuilds the spell list once", ns.stats.rebuilds)
    local requests, rebuilds, scans = ns.stats.requests, ns.stats.rebuilds, ns.stats.bookScans

    -- 200 spell-data answers from the client: ours, other addons', successes
    -- and failures, all in one burst.
    for i = 1, 200 do
        local id = (i % 5 == 0) and 133 or (900000 + i)
        Stub.FireEvent("SPELL_DATA_LOAD_RESULT", id, i % 3 ~= 0)
    end
    check(#Stub.timers <= 1, "a spell-data storm leaves at most one pending rebuild", #Stub.timers)
    Stub.FlushTimers()
    check(ns.stats.rebuilds - rebuilds <= 1, "a spell-data storm costs at most one rebuild",
        ns.stats.rebuilds - rebuilds)
    eq(ns.stats.requests - requests, 0, "a spell-data storm never re-requests spell data")
    check(ns.stats.bookScans - scans <= 1, "a spell-data storm rescans the spellbook at most once",
        ns.stats.bookScans - scans)

    -- SPELLS_CHANGED legitimately resets the request budget, but a storm of
    -- them must still cost one rebuild and one budget, not one per event.
    local budget = ns.stats.requests
    for _ = 1, 50 do Stub.FireEvent("SPELLS_CHANGED") end
    check(#Stub.timers <= 1, "a spellbook storm leaves at most one pending rebuild", #Stub.timers)
    Stub.FlushTimers()
    local spent = ns.stats.requests - budget
    check(spent <= 20, "a spellbook storm spends the request budget once", spent)

    -- And the addon still works after all that.
    Stub.distance = 15
    Update()
    eq(Display(), "Fire Blast", "still selecting spells after the storm")
end

local function testRequestBudget()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    local candidates = 0
    for _ in pairs(ns.wantedIDs or {}) do candidates = candidates + 1 end
    check(ns.stats.requests <= 32, "start-up asks for a bounded number of spells", ns.stats.requests)

    -- Requests only ever name a spell this addon's tables know, and each of
    -- those exactly once per session.
    local wanted, unexpected, repeated = 0, 0, 0
    for id, count in pairs(Stub.requestedSpellIDs) do
        wanted = wanted + 1
        if not (ns.wantedIDs and ns.wantedIDs[id]) then unexpected = unexpected + 1 end
        if count > 1 then repeated = repeated + 1 end
    end
    check(wanted > 0, "some spell data was requested at start-up")
    eq(unexpected, 0, "only spell IDs from the addon's tables are ever requested")
    eq(repeated, 0, "no spell ID is requested twice in a session")

    -- Rebuilds that are not caused by a spellbook change must not spend the
    -- budget again, however many of them happen.
    local requests = ns.stats.requests
    for _ = 1, 10 do
        Stub.RunSlash("talents")
    end
    eq(ns.stats.requests, requests, "repeated rescans never re-request spell data")
end

-- ---------------------------------------------------------------------
-- The icon widget itself: RegisterForClicks is a Button method, and a single
-- unsupported call must not leave the icon half-built. This is the bug that
-- shipped in a4e2605 and was reported from the beta.
-- ---------------------------------------------------------------------

local function testIconWiring()
    local ns = Boot(Load("forever", ForeverMage))
    if not ns then return end

    local frame = Stub.FindFrame("MRIFrame")
    check(frame ~= nil, "the icon frame exists")
    if not frame then return end

    eq(frame.kind, "Button", "the icon is a Button, because RegisterForClicks is a Button method")
    check(frame.clicks ~= nil, "the click registration was accepted")
    check(frame.scripts.OnMouseUp ~= nil, "the mouse-up script is wired")
    check(frame.scripts.OnDragStart ~= nil, "the drag-start script is wired")
    check(frame.scripts.OnDragStop ~= nil, "the drag-stop script is wired")
    check(frame.scripts.OnEnter ~= nil, "the tooltip script is wired")
    check(ns.stats.wiringFailures == 0, "nothing failed to wire on a normal client", ns.stats.wiringFailures)
end

local function testBootWhileLocked()
    -- The reported state: the saved variables say locked, and the icon is built
    -- fresh at login. The visuals have to match the saved state immediately.
    local ns = Boot(Load("forever", function()
        ForeverMage()
        MageRangeIndicatorDB = { locked = true, iconSize = 52, opacity = 1, posX = 299, posY = 84 }
    end))
    if not ns then return end

    eq(ns.db.locked, true, "the saved locked state is loaded")
    local frame = Stub.FindFrame("MRIFrame")
    check(frame ~= nil, "the icon is built for a locked character")
    if not frame then return end

    local dragHint = frame.fontStrings[3]
    check(not dragHint:IsShown(), "a locked icon does not show the drag hint at login")
    local rangeText, nameText = frame.fontStrings[1]:GetText(), frame.fontStrings[2]:GetText()
    check(type(rangeText) == "string" and rangeText ~= "", "the readout is populated (CreateUI ran to the end)", rangeText)
    check(type(nameText) == "string" and nameText ~= "", "the spell label is populated", nameText)
    check(frame.scripts.OnDragStart ~= nil, "the wiring ran past the saved locked state")
    local glow
    for _, widget in ipairs(frame.children) do
        if widget.kind == "Texture" and widget.blend == "ADD" then glow = widget end
    end
    check(glow == nil or not glow:IsShown(), "a locked icon does not show the glow at login")
    check(frame.movable == false, "a locked icon is not movable")
    eq(frame.mouse, false, "a locked icon takes no mouse at login")
    check(not Stub.HoverIcon(), "no tooltip while locked")

    -- It is still live: the range readout works while locked.
    Stub.distance = 25
    Update()
    eq(select(1, Display()), "Scorch", "a locked icon still reads the range")

    -- The way out is /mri lock, and the login message says so.
    check(Stub.ChatContains("Frame is LOCKED"), "the locked state is reported at login")
    check(Stub.ChatContains("/mri lock to move it"), "the login message says how to unlock")
    Stub.RunSlash("lock")
    eq(ns.db.locked, false, "/mri lock unlocks it from the saved locked state")
    check(Stub.IconTakesMouse(), "the icon becomes interactive again")
end

local function testWiringFailureTolerance()
    -- A client that refuses the click registration must still leave a working,
    -- correctly-styled icon - not a half-built one stuck on the fallback icon.
    local ns = Boot(Load("forever", function()
        ForeverMage()
        Stub.breakRegisterForClicks = true
    end))
    if not ns then return end

    check(ns.stats.wiringFailures > 0, "the refusal is counted", ns.stats.wiringFailures)
    Stub.RunSlash("probe")
    check(Stub.ChatContains("Wiring failures"), "probe names the wiring failure instead of staying quiet")

    local frame = Stub.FindFrame("MRIFrame")
    check(frame ~= nil, "the icon is built even when the click registration is refused")
    if frame then
        check(frame.scripts.OnDragStart ~= nil, "dragging is still wired")
        check(frame.scripts.OnEnter ~= nil, "the tooltip is still wired")
        Stub.distance = 25
        Update()
        eq(select(1, Display()), "Scorch", "the icon still works without the click registration")
    end
end

local function testIconRefused()
    -- If the client refuses to build the icon at all, the addon must say so and
    -- stay usable (commands, probing) instead of dying silently.
    local ns = Load("forever", function()
        ForeverMage()
        Stub.failCreateFrameFor = "Button"
    end)
    if not ns then return end

    local ok = pcall(function()
        Stub.FireEvent("ADDON_LOADED", "MageRangeIndicator")
        Stub.FireEvent("PLAYER_LOGIN")
        Stub.FlushTimers()
        Stub.Tick(0.5, 2)
    end)
    check(ok, "start-up survives a refused icon")
    check(Stub.ChatContains("could not be built"), "the refusal is reported in chat")
    eq(Stub.FindFrame("MRIFrame"), nil, "no half-built icon is left behind")

    local probed = pcall(Stub.RunSlash, "probe")
    check(probed, "commands still work without an icon")
    check(Stub.ChatContains("Wiring failures"), "the probe names the failure")
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

runTest(testForeverNearestSpell, "testForeverNearestSpell")
runTest(testSpecPriorityTieBreak, "testSpecPriorityTieBreak")
runTest(testForeverStates, "testForeverStates")
runTest(testSecrets, "testSecrets")
runTest(testClientNumbersWin, "testClientNumbersWin")
runTest(testAutoDiscovery, "testAutoDiscovery")
runTest(testItemBuckets, "testItemBuckets")
runTest(testItemLoading, "testItemLoading")
runTest(testUpdateLoopChurn, "testUpdateLoopChurn")
runTest(testEventStorms, "testEventStorms")
runTest(testRequestBudget, "testRequestBudget")
runTest(testMouseLock, "testMouseLock")
runTest(testIconWiring, "testIconWiring")
runTest(testBootWhileLocked, "testBootWhileLocked")
runTest(testWiringFailureTolerance, "testWiringFailureTolerance")
runTest(testIconRefused, "testIconRefused")
runTest(testLegacyTalentMaths, "testLegacyTalentMaths")
runTest(testLegacyOverride, "testLegacyOverride")
runTest(testCommands, "testCommands")
runTest(testNonMage, "testNonMage")

if #failures > 0 then
    io.write("FAILED ", #failures, " of ", passed + #failures, " checks\n")
    for _, failure in ipairs(failures) do io.write("  - ", failure, "\n") end
    error("spec failures", 0)
end

io.write("ok: ", passed, " checks passed\n")
