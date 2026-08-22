local addonName = "MageRangeIndicator"

local defaults = {
    locked = false,
    iconSize = 52,
    opacity = 1.0,
    posX = 0,
    posY = -150,
}

-- school: 1=Arcane, 2=Fire, 3=Frost
local baseSpellData = {
    { name = "Fireball",        baseRange = 35, talent = "Flame Throwing", bonusPerPoint = 3, school = 2 },
    { name = "Frostbolt",       baseRange = 30, talent = "Arctic Reach",   bonusPerPoint = 3, school = 3 },
    { name = "Arcane Blast",    baseRange = 30, school = 1 },
    { name = "Scorch",          baseRange = 30, talent = "Flame Throwing", bonusPerPoint = 3, school = 2 },
    { name = "Arcane Missiles", baseRange = 30, school = 1 },
    { name = "Fire Blast",      baseRange = 20, talent = "Flame Throwing", bonusPerPoint = 3, school = 2 },
    { name = "Cone of Cold",    baseRange = 10, talent = "Arctic Reach",   bonusPerPoint = 2, school = 3 },
    { name = "Frost Nova",      baseRange = 10, school = 3 },
}

local talentCache = {}
local sortedSpells = {}
local spellBookIndex = {}
local mainFrame, iconTex, rangeLabel, nameLabel, oorTex, glowTex, dragLabel
local updateTimer = 0
local playerIsMage = false
local initialized = false
local lastResult = ""

local treePoints = { 0, 0, 0 }
local primaryTree = 2
local treeNames = { "Arcane", "Fire", "Frost" }

local function P(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFMageRangeIndicator:|r " .. tostring(msg))
end

local function Trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

local function SplitCmd(s)
    s = Trim(s or "")
    local a, b = s:match("^(%S+)%s*(.*)")
    if not a then return "", "" end
    return a:lower(), Trim(b)
end

local function ScanTalents()
    talentCache = {}
    treePoints = { 0, 0, 0 }

    local ok, numTabs = pcall(GetNumTalentTabs)
    if not ok or not numTabs then return end

    for tab = 1, numTabs do
        local ok2, numT = pcall(GetNumTalents, tab)
        if ok2 and numT then
            for i = 1, numT do
                local ok3, tname, _, _, _, curRank = pcall(GetTalentInfo, tab, i)
                if ok3 and tname and curRank then
                    talentCache[tname] = curRank
                    if tab <= 3 then
                        treePoints[tab] = treePoints[tab] + curRank
                    end
                end
            end
        end
    end

    local maxPts = 0
    primaryTree = 2
    for i = 1, 3 do
        if treePoints[i] > maxPts then
            maxPts = treePoints[i]
            primaryTree = i
        end
    end
end

local function GetSpellPriority(school)
    if school == 1 then
        if primaryTree == 1 then
            return 0
        else
            return 2
        end
    end
    if school == primaryTree then
        return 0
    end
    return 1
end

local function BuildSpellBookIndex()
    spellBookIndex = {}
    local idx = 1
    while true do
        local ok, sname = pcall(GetSpellBookItemName, idx, BOOKTYPE_SPELL)
        if not ok or not sname then break end
        spellBookIndex[sname] = idx
        idx = idx + 1
    end
end

local function SpellKnown(spellName)
    return spellBookIndex[spellName] ~= nil
end

local function SpellIcon(spellName)
    if not spellName then return nil end
    local ok, _, _, icon = pcall(GetSpellInfo, spellName)
    if ok and icon then return icon end
    return nil
end

local function BuildSpellList()
    BuildSpellBookIndex()
    sortedSpells = {}
    for _, data in ipairs(baseSpellData) do
        if SpellKnown(data.name) then
            local r = data.baseRange
            if data.talent and talentCache[data.talent] then
                r = r + (talentCache[data.talent] * (data.bonusPerPoint or 0))
            end
            local ic = SpellIcon(data.name)
            if ic then
                table.insert(sortedSpells, {
                    name = data.name,
                    range = r,
                    texture = ic,
                    bookIdx = spellBookIndex[data.name],
                    school = data.school or 0,
                    priority = GetSpellPriority(data.school or 0),
                })
            end
        end
    end

    table.sort(sortedSpells, function(a, b)
        if a.range ~= b.range then
            return a.range > b.range
        end
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.name < b.name
    end)

    lastResult = ""
end

local function ApplySize()
    if not mainFrame then return end
    local s = MageRangeIndicatorDB.iconSize or 52
    mainFrame:SetWidth(s)
    mainFrame:SetHeight(s)
    if glowTex then
        glowTex:SetWidth(s * 1.7)
        glowTex:SetHeight(s * 1.7)
    end
end

local function ApplyOpacity()
    if not mainFrame then return end
    mainFrame:SetAlpha(MageRangeIndicatorDB.opacity or 1.0)
end

local function ApplyLock()
    if not mainFrame then return end
    if MageRangeIndicatorDB.locked then
        mainFrame:EnableMouse(false)
        mainFrame:SetMovable(false)
        if glowTex then glowTex:Hide() end
        if dragLabel then dragLabel:Hide() end
    else
        mainFrame:EnableMouse(true)
        mainFrame:SetMovable(true)
        mainFrame:RegisterForDrag("LeftButton")
        if glowTex then glowTex:Show() end
        if dragLabel then dragLabel:Show() end
    end
end

local function ShowIdle()
    if not iconTex then return end
    if sortedSpells[1] then
        iconTex:SetTexture(sortedSpells[1].texture)
        nameLabel:SetText(sortedSpells[1].name)
        rangeLabel:SetText(sortedSpells[1].range .. "yd")
        rangeLabel:SetTextColor(0.6, 0.6, 0.6, 1)
    else
        iconTex:SetTexture("Interface\\Icons\\Spell_Arcane_PortalDalaran")
        nameLabel:SetText("No Target")
        rangeLabel:SetText("")
    end
    iconTex:SetDesaturated(true)
    iconTex:SetVertexColor(0.6, 0.6, 0.6)
    nameLabel:SetTextColor(0.8, 0.8, 0.8, 1)
    oorTex:Hide()
end

local function ShowOOR()
    if not iconTex then return end
    if sortedSpells[1] then
        iconTex:SetTexture(sortedSpells[1].texture)
    end
    iconTex:SetDesaturated(true)
    iconTex:SetVertexColor(0.4, 0.4, 0.4)
    rangeLabel:SetText("OOR")
    rangeLabel:SetTextColor(1, 0, 0, 1)
    nameLabel:SetText("Out of Range")
    nameLabel:SetTextColor(1, 0.3, 0.3, 1)
    oorTex:Show()
end

local function ShowSpell(sd)
    if not iconTex then return end
    iconTex:SetTexture(sd.texture)
    iconTex:SetDesaturated(false)
    iconTex:SetVertexColor(1, 1, 1)
    nameLabel:SetText(sd.name)
    nameLabel:SetTextColor(1, 1, 0, 1)
    rangeLabel:SetText(sd.range .. "yd")
    oorTex:Hide()
    if sd.range >= 30 then
        rangeLabel:SetTextColor(0, 1, 0, 1)
    elseif sd.range >= 20 then
        rangeLabel:SetTextColor(1, 1, 0, 1)
    else
        rangeLabel:SetTextColor(1, 0.3, 0, 1)
    end
end

local function CheckRange(sd)
    if not sd or not sd.bookIdx then return nil end
    if not UnitExists("target") then return nil end
    local ok, result = pcall(IsSpellInRange, sd.bookIdx, BOOKTYPE_SPELL, "target")
    if ok and result ~= nil then
        return result == 1
    end
    local ok2, result2 = pcall(IsSpellInRange, sd.name, "target")
    if ok2 and result2 ~= nil then
        return result2 == 1
    end
    return nil
end

local function CreateUI()
    if mainFrame then return end
    local db = MageRangeIndicatorDB

    mainFrame = CreateFrame("Frame", "MRIFrame", UIParent)
    mainFrame:SetWidth(db.iconSize)
    mainFrame:SetHeight(db.iconSize)
    mainFrame:SetPoint("CENTER", UIParent, "CENTER", db.posX, db.posY)
    mainFrame:SetAlpha(db.opacity)
    mainFrame:SetFrameStrata("LOW")
    mainFrame:SetFrameLevel(120)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")

    local bg = mainFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(mainFrame)
    if bg.SetColorTexture then
        bg:SetColorTexture(0, 0, 0, 0.9)
    else
        bg:SetTexture(0, 0, 0, 0.9)
    end

    iconTex = mainFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 3, -3)
    iconTex:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -3, 3)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconTex:SetTexture("Interface\\Icons\\Spell_Arcane_PortalDalaran")

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
    glowTex:SetWidth(db.iconSize * 1.7)
    glowTex:SetHeight(db.iconSize * 1.7)
    glowTex:SetVertexColor(0, 0.7, 1, 0.5)

    dragLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dragLabel:SetPoint("TOP", mainFrame, "BOTTOM", 0, -6)
    pcall(function() dragLabel:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE") end)
    dragLabel:SetTextColor(0, 1, 0.5, 1)
    dragLabel:SetText("DRAG ME  -  /mri lock")

    local pv = 0.3
    local pd = 1
    local pulser = CreateFrame("Frame", nil, mainFrame)
    pulser:SetScript("OnUpdate", function(self, elapsed)
        if not glowTex or not glowTex:IsShown() then return end
        if MageRangeIndicatorDB.locked then return end
        pv = pv + (elapsed * 1.2 * pd)
        if pv >= 0.7 then pv = 0.7; pd = -1 end
        if pv <= 0.1 then pv = 0.1; pd = 1 end
        glowTex:SetAlpha(pv)
    end)

    mainFrame:SetScript("OnDragStart", function(self)
        if not MageRangeIndicatorDB.locked then
            self:StartMoving()
        end
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        if x and y then
            MageRangeIndicatorDB.posX = x
            MageRangeIndicatorDB.posY = y
        end
    end)

    mainFrame:SetScript("OnEnter", function(self)
        if MageRangeIndicatorDB.locked then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Mage Range Indicator", 0, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Drag to move", 1, 1, 1)
        GameTooltip:AddLine("/mri lock - Lock in place", 0, 1, 0)
        GameTooltip:AddLine("/mri size 52 - Icon size", 0, 1, 0)
        GameTooltip:AddLine("/mri opacity 0.8 - Transparency", 0, 1, 0)
        GameTooltip:AddLine("/mri help - All commands", 0, 1, 0)
        GameTooltip:Show()
    end)
    mainFrame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    ApplyLock()
    ShowIdle()
end

-- ============================================================
-- MAIN UPDATE - OPTIMIZED
-- Range checks still run every 0.1s to detect movement
-- But texture/text updates ONLY happen when result changes
-- ============================================================
local function DoUpdate(self, elapsed)
    updateTimer = updateTimer + elapsed
    if updateTimer < 0.1 then return end
    updateTimer = 0

    if not mainFrame or not mainFrame:IsShown() then return end
    if not iconTex then return end

    -- No target
    if not UnitExists("target") then
        if lastResult ~= "IDLE" then
            lastResult = "IDLE"
            ShowIdle()
        end
        return
    end

    -- Dead target
    if UnitIsDeadOrGhost("target") then
        if lastResult ~= "DEAD" then
            lastResult = "DEAD"
            if sortedSpells[1] then iconTex:SetTexture(sortedSpells[1].texture) end
            iconTex:SetDesaturated(true)
            iconTex:SetVertexColor(0.5, 0.5, 0.5)
            rangeLabel:SetText("")
            nameLabel:SetText("Dead")
            nameLabel:SetTextColor(0.6, 0.6, 0.6, 1)
            oorTex:Hide()
        end
        return
    end

    -- Friendly target
    if not UnitCanAttack("player", "target") then
        if lastResult ~= "FRIENDLY" then
            lastResult = "FRIENDLY"
            if sortedSpells[1] then iconTex:SetTexture(sortedSpells[1].texture) end
            iconTex:SetDesaturated(true)
            iconTex:SetVertexColor(0.5, 0.7, 1)
            rangeLabel:SetText("")
            nameLabel:SetText("Friendly")
            nameLabel:SetTextColor(0.3, 0.8, 1, 1)
            oorTex:Hide()
        end
        return
    end

    -- Build unique range tiers
    local tiers = {}
    local seenRange = {}
    for _, sd in ipairs(sortedSpells) do
        if not seenRange[sd.range] then
            seenRange[sd.range] = true
            table.insert(tiers, sd)
        end
    end

    -- Find shortest range spell in range
    local shortest = nil
    for _, sd in ipairs(tiers) do
        local inRange = CheckRange(sd)
        if inRange == true then
            shortest = sd
        end
    end

    -- Only update visuals if result changed
    local newResult = shortest and shortest.name or "OOR"
    if newResult == lastResult then return end
    lastResult = newResult

    if shortest then
        ShowSpell(shortest)
    else
        ShowOOR()
    end
end

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_MRI1 = "/mri"
SLASH_MRI2 = "/magerange"
SlashCmdList["MRI"] = function(msg)
    local cmd, arg1 = SplitCmd(msg)

    if cmd == "" or cmd == "help" then
        P("/mri lock - Toggle lock/unlock")
        P("/mri size <16-128> - Set icon size")
        P("/mri opacity <0.0-1.0> - Set opacity")
        P("/mri reset - Reset all settings")
        P("/mri show - Show indicator")
        P("/mri hide - Hide indicator")
        P("/mri status - Show settings and spells")
        P("/mri talents - Rescan talents")
        P("/mri debug - Show live range data")
    elseif cmd == "lock" then
        MageRangeIndicatorDB.locked = not MageRangeIndicatorDB.locked
        ApplyLock()
        if MageRangeIndicatorDB.locked then
            P("Frame LOCKED. /mri lock to unlock.")
        else
            P("Frame UNLOCKED. Drag to move.")
        end
    elseif cmd == "size" then
        local n = tonumber(arg1)
        if not n then
            P("Usage: /mri size <16-128> (current: " .. tostring(MageRangeIndicatorDB.iconSize) .. ")")
        else
            if n < 16 then n = 16 end
            if n > 128 then n = 128 end
            MageRangeIndicatorDB.iconSize = n
            ApplySize()
            P("Size: " .. n)
        end
    elseif cmd == "opacity" or cmd == "alpha" then
        local n = tonumber(arg1)
        if not n then
            P("Usage: /mri opacity <0.0-1.0> (current: " .. tostring(MageRangeIndicatorDB.opacity) .. ")")
        else
            if n < 0 then n = 0 end
            if n > 1 then n = 1 end
            MageRangeIndicatorDB.opacity = n
            ApplyOpacity()
            P("Opacity: " .. n)
        end
    elseif cmd == "reset" then
        for k, v in pairs(defaults) do
            MageRangeIndicatorDB[k] = v
        end
        if mainFrame then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("CENTER", UIParent, "CENTER", defaults.posX, defaults.posY)
            ApplySize()
            ApplyOpacity()
            mainFrame:Show()
        end
        ApplyLock()
        lastResult = ""
        P("Reset to defaults.")
    elseif cmd == "show" then
        if mainFrame then mainFrame:Show() end
        lastResult = ""
        P("Shown.")
    elseif cmd == "hide" then
        if mainFrame then mainFrame:Hide() end
        P("Hidden. /mri show to restore.")
    elseif cmd == "status" then
        P("Locked: " .. tostring(MageRangeIndicatorDB.locked))
        P("Size: " .. tostring(MageRangeIndicatorDB.iconSize))
        P("Opacity: " .. tostring(MageRangeIndicatorDB.opacity))
        P("Primary tree: " .. treeNames[primaryTree] .. " (" .. treePoints[primaryTree] .. "pts)")
        P("Points: Arc=" .. treePoints[1] .. " Fire=" .. treePoints[2] .. " Frost=" .. treePoints[3])
        P("Arcane Blast: " .. (primaryTree == 1 and "preferred (Arcane is #1)" or "not preferred (Scorch wins)"))
        if #sortedSpells > 0 then
            P("Spells (longest first):")
            local seenRange = {}
            for i, s in ipairs(sortedSpells) do
                local tn = treeNames[s.school] or "?"
                local tier = ""
                if not seenRange[s.range] then
                    seenRange[s.range] = true
                    tier = " << SHOWN"
                end
                P("  " .. i .. ". " .. s.name .. " " .. s.range .. "yd [" .. tn .. "] p=" .. s.priority .. tier)
            end
        end
    elseif cmd == "talents" then
        ScanTalents()
        BuildSpellList()
        P("Talents rescanned. Primary: " .. treeNames[primaryTree])
        P("Arcane Blast: " .. (primaryTree == 1 and "preferred" or "Scorch preferred"))
        local seenRange = {}
        for i, s in ipairs(sortedSpells) do
            local tier = ""
            if not seenRange[s.range] then
                seenRange[s.range] = true
                tier = " << SHOWN"
            end
            P("  " .. i .. ". " .. s.name .. " " .. s.range .. "yd p=" .. s.priority .. tier)
        end
    elseif cmd == "debug" then
        P("--- Debug ---")
        P("Target: " .. tostring(UnitExists("target")))
        if UnitExists("target") then
            P("Attackable: " .. tostring(UnitCanAttack("player", "target")))
            P("Dead: " .. tostring(UnitIsDeadOrGhost("target")))
        end
        P("Primary: " .. treeNames[primaryTree])
        P("Last result: " .. lastResult)
        local seenRange = {}
        for _, sd in ipairs(sortedSpells) do
            local isTier = not seenRange[sd.range]
            seenRange[sd.range] = true
            local inRange = CheckRange(sd)
            local tag = ""
            if isTier then tag = " [TIER]" end
            P("  " .. sd.name .. " " .. sd.range .. "yd p=" .. sd.priority .. " inRange=" .. tostring(inRange) .. tag)
        end
    else
        P("Unknown: " .. cmd .. " - /mri help")
    end
end

-- ============================================================
-- EVENTS
-- ============================================================
local ef = CreateFrame("Frame")
local safeEvents = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "CHARACTER_POINTS_CHANGED",
    "PLAYER_TALENT_UPDATE",
    "SPELLS_CHANGED",
    "PLAYER_TARGET_CHANGED",
}
for _, ev in ipairs(safeEvents) do
    pcall(function() ef:RegisterEvent(ev) end)
end

local initTimer = nil
local function StartInit()
    if initTimer then return end
    local el = 0
    initTimer = CreateFrame("Frame")
    initTimer:SetScript("OnUpdate", function(self, dt)
        el = el + dt
        if el < 2.0 then return end
        self:SetScript("OnUpdate", nil)

        local _, cls = UnitClass("player")
        if cls ~= "MAGE" then
            playerIsMage = false
            return
        end
        playerIsMage = true
        ScanTalents()
        BuildSpellList()
        CreateUI()
        mainFrame:Show()

        local updater = CreateFrame("Frame")
        updater:SetScript("OnUpdate", DoUpdate)
        initialized = true

        --P("Loaded! Spec: " .. treeNames[primaryTree])
        --P("Arcane Blast " .. (primaryTree == 1 and "preferred (Arcane spec)" or "not preferred (Scorch shown instead)"))
        if not MageRangeIndicatorDB.locked then
            P("Frame UNLOCKED. Drag it, then /mri lock")
        end
        P("/mri help for commands.")
    end)
end

local talentTimer = nil
local function DelayTalentScan()
    if talentTimer then return end
    local el = 0
    talentTimer = CreateFrame("Frame")
    talentTimer:SetScript("OnUpdate", function(self, dt)
        el = el + dt
        if el < 0.5 then return end
        self:SetScript("OnUpdate", nil)
        talentTimer = nil
        ScanTalents()
        BuildSpellList()
        P("Talents updated. Primary: " .. treeNames[primaryTree])
    end)
end

ef:SetScript("OnEvent", function(self, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= addonName then return end
        if type(MageRangeIndicatorDB) ~= "table" then
            MageRangeIndicatorDB = {}
        end
        for k, v in pairs(defaults) do
            if MageRangeIndicatorDB[k] == nil then
                MageRangeIndicatorDB[k] = v
            end
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        StartInit()
    elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        if playerIsMage then DelayTalentScan() end
    elseif event == "SPELLS_CHANGED" then
        if playerIsMage and initialized then BuildSpellList() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        updateTimer = 999
        lastResult = ""
    end
end)