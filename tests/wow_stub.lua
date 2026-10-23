--[[==========================================================================
 tests/wow_stub.lua

 A small stand-in for the WoW client, just enough for MageRangeIndicator to
 load and run offline under Lua 5.1 (see tests/run.sh). It models the parts the
 addon touches: frames and widgets, the event system, C_Timer, the modern
 C_ namespaces (Forever / Mainline) and the legacy globals (Classic-era).

 Nothing here is loaded by the addon in game - it exists so the range logic can
 be exercised without a client, the same way the Forever beta addons test
 themselves.
==========================================================================]]

local Stub = {}
Stub.frames = {}
Stub.chat = {}
Stub.timers = {}

function Stub.Reset()
    Stub.frames = {}
    Stub.chat = {}
    Stub.timers = {}

    Stub.distance = 0
    Stub.targetExists = true
    Stub.targetAttackable = true
    Stub.targetDead = false
    Stub.inCombat = false
    Stub.interactDisabled = false

    Stub.secretEnabled = false
    Stub.secret = setmetatable({}, {
        __tostring = function() error("secret value printed") end,
        __add = function() error("secret value added") end,
    })

    Stub.calls = {}           -- client-call counters, for the churn checks
    Stub.requestedSpellIDs = {}  -- [spellID] = how many times the addon asked for it
    Stub.spells = {}          -- [id] = { name, iconID, minRange, maxRange, hasRange, description }
    Stub.idForName = {}       -- [localised name] = id
    Stub.book = {}            -- ordered spellbook entries: { name, id, iconID, isPassive }
    Stub.tooltipRanges = {}   -- [id] = a tooltip line, e.g. "41 yd range"
    Stub.itemsCached = {}     -- [itemID] = name, for the buckets
    Stub.itemRanges = {}      -- [itemID] = yards
    Stub.specPoints = { 0, 40, 0 }
    Stub.traitPoints = nil    -- Forever C_Traits group currency spent: { arc, fire, frost }
    Stub.activeSpec = 1       -- Mists / Mainline active specialization index (1..3)
    Stub.specTuple = false    -- return C_SpecializationInfo's tuple shape
    Stub.talents = {}         -- legacy: [tab] = { { name, rank }, ... }
    Stub.nativeTalentsOnly = false -- omit deprecated GetNumTalentTabs globals
    Stub.spellTabs = nil      -- optional explicit { { offset, count, offSpecID, isGuild, shouldHide }, ... }
    Stub.class = "MAGE"
    Stub.race = "Human"
    Stub.shift = false
    Stub.breakRegisterForClicks = false
    Stub.failCreateFrameFor = nil
    Stub.legacyRanges = {}    -- legacy client truth: [lower name] = yards
    Stub.pendingItemRequests = {}
    Stub.slash = {}
    Stub.MRI_OnCompartmentClick = nil
end

-- Every client call the addon makes goes through here, so a test can prove
-- that a hot path does not call anything it should have cached.
local function Count(name)
    Stub.calls[name] = (Stub.calls[name] or 0) + 1
end

function Stub.SnapshotCalls()
    local copy = {}
    for name, count in pairs(Stub.calls) do copy[name] = count end
    return copy
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = deepcopy(inner) end
    return copy
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local Widget = {}
Widget.__index = Widget

-- Button-only, exactly like the client. Stub.breakRegisterForClicks makes even
-- the Button reject it, to check that one unsupported call cannot abort the UI.
local function ButtonRegisterForClicks(self, ...)
    if Stub.breakRegisterForClicks then
        error("Button:RegisterForClicks is not available on this build")
    end
    self.clicks = { ... }
end

local function NewWidget(kind, parent)
    local widget = setmetatable({
        kind = kind,
        parent = parent,
        scripts = {},
        events = {},
        children = {},
        fontStrings = {},
        shown = true,
        width = 0,
        height = 0,
        -- A Button takes the mouse by default, a plain Frame does not. Motion
        -- and click are separate flags, exactly as they are on the client.
        mouse = (kind == "Button"),
        motion = (kind == "Button"),
        click = (kind == "Button"),
    }, Widget)
    if kind == "Button" then widget.RegisterForClicks = ButtonRegisterForClicks end
    Stub.frames[#Stub.frames + 1] = widget
    if parent and parent.children then parent.children[#parent.children + 1] = widget end
    return widget
end

Stub.NewWidget = NewWidget

function Widget:SetSize(width, height) self.width, self.height = width, height end
function Widget:SetWidth(width) self.width = width end
function Widget:SetHeight(height) self.height = height end
function Widget:GetSize() return self.width, self.height end
function Widget:SetPoint(...) self.point = { ... } end
function Widget:ClearAllPoints() self.point = nil end
function Widget:GetPoint()
    local point = self.point or { "CENTER", nil, "CENTER", 0, 0 }
    return point[1], point[2], point[3], point[4], point[5]
end
function Widget:SetAlpha(alpha) self.alpha = alpha end
function Widget:GetAlpha() return self.alpha or 1 end
function Widget:SetFrameStrata(strata) self.strata = strata end
function Widget:SetFrameLevel(level) self.level = level end
function Widget:SetClampedToScreen(value) self.clamped = value end
function Widget:SetMovable(value) self.movable = value end
function Widget:EnableMouse(value)
    self.mouse = value
    self.motion = value
    self.click = value
end
function Widget:EnableMouseMotion(value) self.motion = value end
function Widget:EnableMouseWheel(value) self.wheel = value end
function Widget:SetMouseMotionEnabled(value) self.motion = value end
function Widget:SetMouseClickEnabled(value) self.click = value end
function Widget:IsMouseEnabled() return self.mouse == true end
function Widget:IsMouseMotionEnabled() return self.motion == true end
function Widget:IsMouseClickEnabled() return self.click == true end
function Widget:IsMouseWheelEnabled() return self.wheel == true end
function Widget:IsMouseOver() return self.hovered == true end
function Widget:RegisterForDrag(...) self.drag = { ... } end
function Widget:StartMoving() self.moving = true end
function Widget:StopMovingOrSizing() self.moving = false end
local CLICK_SCRIPTS = {
    OnMouseDown = true,
    OnMouseUp = true,
    OnClick = true,
    PreClick = true,
    PostClick = true,
    OnDoubleClick = true,
}

local MOTION_SCRIPTS = {
    OnEnter = true,
    OnLeave = true,
}

function Widget:SetScript(name, fn)
    self.scripts[name] = fn
    -- On every modern-engine WoW client (10.0+ CSimpleScriptRegion::SetScript:
    -- WoW: Forever 1.60.1, Classic Era 1.15.9, TBC 2.5.6, Wrath 3.80.2,
    -- Mists 5.5.4, Retail 12.1.5), binding a non-nil click/mouse script
    -- implicitly calls SetMouseClickEnabled(true), and binding OnEnter/OnLeave
    -- implicitly calls SetMouseMotionEnabled(true).
    if fn ~= nil and Stub.mode ~= "tbc" then
        if CLICK_SCRIPTS[name] then
            self.click = true
            self.mouse = true
        elseif MOTION_SCRIPTS[name] then
            self.motion = true
            self.mouse = true
        end
    end
end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:RegisterEvent(event) self.events[event] = true end
function Widget:UnregisterEvent(event) self.events[event] = nil end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown ~= false end
function Widget:IsVisible() return self:IsShown() end
function Widget:SetTexture(texture) self.texture = texture end
function Widget:GetTexture() return self.texture end
function Widget:SetColorTexture(...) self.color = { ... } end
function Widget:SetTexCoord(...) self.texCoord = { ... } end
function Widget:SetDesaturated(value) self.desaturated = value end
function Widget:SetVertexColor(...) self.vertex = { ... } end
function Widget:SetBlendMode(mode) self.blend = mode end
function Widget:SetAllPoints() self.allPoints = true end
function Widget:SetFont(...) self.font = { ... } end
function Widget:SetFontObject() end
function Widget:SetText(text) self.text = text end
function Widget:GetText() return self.text end
function Widget:SetTextColor(...) self.textColor = { ... } end
function Widget:SetShadowColor() end
function Widget:SetShadowOffset() end
function Widget:SetOwner(owner) self.owner = owner end
function Widget:GetOwner() return self.owner end
function Widget:ClearLines() self.lines = {} end
function Widget:AddLine(text) self.lines = self.lines or {}; self.lines[#self.lines + 1] = text end
function Widget:SetSpellByID(id) self.spellID = id end
function Widget:CreateTexture() return NewWidget("Texture", self) end
function Widget:CreateFontString()
    local fontString = NewWidget("FontString", self)
    self.fontStrings[#self.fontStrings + 1] = fontString
    return fontString
end

function Stub.FindFrame(name)
    for _, frame in ipairs(Stub.frames) do
        if frame.name == name then return frame end
    end
end

function Stub.FindWidgetByText(text)
    for _, frame in ipairs(Stub.frames) do
        if frame.text == text then return frame end
    end
end

---------------------------------------------------------------------------
-- Driving the UI from a test
---------------------------------------------------------------------------

function Stub.FireEvent(event, ...)
    for _, frame in ipairs(Stub.frames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

function Stub.Tick(seconds, steps)
    steps = steps or 1
    for _ = 1, steps do
        for _, frame in ipairs(Stub.frames) do
            if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, seconds) end
        end
    end
end

function Stub.FlushTimers()
    local pending = Stub.timers
    Stub.timers = {}
    for _, fn in ipairs(pending) do fn() end
end

-- Press and release a mouse button on the icon, the way the client would.
-- A frame with clicks disabled never receives it - that is the whole point of
-- going click-through while locked, so the stub has to model it.
function Stub.ClickIcon(button)
    local frame = Stub.FindFrame("MRIFrame")
    if not frame or frame.click == false then return false end
    if frame.scripts.OnMouseDown then frame.scripts.OnMouseDown(frame, button) end
    if frame.scripts.OnMouseUp then frame.scripts.OnMouseUp(frame, button) end
    return true
end

-- Hovering is a mouse event too, and it is motion that drives OnEnter: a frame
-- with motion disabled gets no tooltip, even if it still took clicks.
function Stub.HoverIcon()
    local frame = Stub.FindFrame("MRIFrame")
    if not frame or frame.motion == false then return false end
    frame.hovered = true
    if frame.scripts.OnEnter then frame.scripts.OnEnter(frame) end
    return true
end

function Stub.UnhoverIcon()
    local frame = Stub.FindFrame("MRIFrame")
    if not frame then return false end
    frame.hovered = false
    if frame.scripts.OnLeave then frame.scripts.OnLeave(frame) end
    return true
end

-- Fire a script directly, whatever the mouse state: the way to test what the
-- addon does if the client dispatches an event it should not have.
function Stub.FireIconScript(name)
    local frame = Stub.FindFrame("MRIFrame")
    if not frame or not frame.scripts[name] then return false end
    frame.scripts[name](frame)
    return true
end

function Stub.TooltipShown()
    return _G.GameTooltip ~= nil and _G.GameTooltip.shown == true
end

function Stub.IconTakesMouse()
    local frame = Stub.FindFrame("MRIFrame")
    return frame ~= nil and frame.mouse ~= false
end

function Stub.RunSlash(command)
    if Stub.slash.MRI then Stub.slash.MRI(command) end
end

function Stub.LastChat()
    return Stub.chat[#Stub.chat]
end

function Stub.ChatContains(fragment)
    for _, line in ipairs(Stub.chat) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Spell book helpers
---------------------------------------------------------------------------

-- Shorthand for tests: Stub.AddSpell("Fireball", 133, 35)
function Stub.AddSpell(name, id, maxRange, options)
    options = options or {}
    Stub.spells[id] = {
        name = name,
        iconID = options.iconID or 134400,
        minRange = options.minRange or 0,
        maxRange = maxRange,
        effectiveRange = options.effectiveRange,
        hasRange = options.hasRange,
        description = options.description,
    }
    Stub.idForName[name] = id
end

function Stub.AddBookSpell(name, id, options)
    options = options or {}
    local info = id and Stub.spells[id]
    Stub.book[#Stub.book + 1] = {
        name = name,
        id = id,
        iconID = options.iconID or (info and info.iconID) or 134400,
        slotType = options.slotType or "SPELL",
        lowRank = options.lowRank == true,
        isPassive = options.isPassive == true,
    }
end

---------------------------------------------------------------------------
-- Installing the fake client
---------------------------------------------------------------------------

local function InstallShared(env)
    env.print = env.print

    -- Reset any client-specific globals from a previous test mode so nothing
    -- leaks across modes.
    env.GetSpellInfo = nil
    env.GetSpellTexture = nil
    env.GetSpellBookItemName = nil
    env.GetSpellBookItemInfo = nil
    env.GetNumSpellTabs = nil
    env.GetSpellTabInfo = nil
    env.IsSpellHidden = nil
    env.IsPassiveSpell = nil
    env.IsSpellInRange = nil
    env.IsItemInRange = nil
    env.GetNumTalentTabs = nil
    env.GetNumTalents = nil
    env.GetTalentInfo = nil
    env.GetSpecialization = nil
    env.C_Traits = nil
    env.C_ClassTalents = nil
    env.C_GameRules = nil
    env.WOW_PROJECT_MAINLINE = nil
    env.WOW_PROJECT_CLASSIC = nil
    env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = nil
    env.WOW_PROJECT_WRATH_CLASSIC = nil
    env.WOW_PROJECT_CATACLYSM_CLASSIC = nil
    env.WOW_PROJECT_MISTS_CLASSIC = nil
    env.WOW_PROJECT_CAMELOT = nil

    env.CreateFrame = function(kind, name, parent)
        if Stub.failCreateFrameFor and (kind or "Frame") == Stub.failCreateFrameFor then
            error("CreateFrame(" .. tostring(kind) .. ") is refused on this build")
        end
        local frame = NewWidget(kind or "Frame", parent)
        frame.name = name
        if name then _G[name] = frame end
        return frame
    end
    env.UIParent = NewWidget("Frame")

    env.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message) Stub.chat[#Stub.chat + 1] = message end,
    }
    env.SlashCmdList = setmetatable({}, {
        __newindex = function(t, key, value)
            rawset(t, key, value)
            Stub.slash[key] = value
        end,
    })

    env.C_Timer = {
        After = function(_, fn) Stub.timers[#Stub.timers + 1] = fn end,
        NewTimer = function(_, fn) Stub.timers[#Stub.timers + 1] = fn; return { Cancel = function() end } end,
    }

    env.Enum = {
        SpellBookSpellBank = { Player = 0 },
        SpellBookItemType = { Spell = 1 },
    }
    env.BOOKTYPE_SPELL = "spell"

    env.InCombatLockdown = function() return Stub.inCombat end
    env.IsShiftKeyDown = function() return Stub.shift == true end
    env.UnitClass = function() return "Mage", Stub.class end
    env.UnitRace = function() return nil, Stub.race end
    env.UnitExists = function(unit)
        Count("unitExists")
        if Stub.secretEnabled and unit == "target" then return Stub.secret end
        return unit == "target" and Stub.targetExists or false
    end
    env.UnitCanAttack = function()
        Count("unitCanAttack")
        if Stub.secretEnabled then return Stub.secret end
        return Stub.targetAttackable
    end
    env.UnitFactionGroup = function(unit)
        if unit == "player" then return "Alliance" end
        return Stub.targetFaction or "Horde"
    end
    env.UnitIsDeadOrGhost = function() return Stub.targetDead end
    env.UnitIsUnit = function(a, b) return a == b end

    env.CheckInteractDistance = function(_, index)
        Count("checkInteractDistance")
        if Stub.interactDisabled then return nil end
        if Stub.secretEnabled then return Stub.secret end
        local yards = ({ [1] = 28, [2] = 9, [3] = 8, [4] = 28 })[index]
        if not yards then return nil end
        return Stub.distance <= yards
    end

    env.GameTooltip = NewWidget("Frame")
    env.GameTooltip.lines = {}
    -- The client's tooltip starts hidden; only an owner can show it.
    env.GameTooltip:Hide()

    env.issecretvalue = function(value)
        return Stub.secretEnabled and value == Stub.secret or false
    end

    env.GetTime = function() return os.clock() end
end

local function InstallSpellNamespaces(env)
    env.C_Spell = {
        GetSpellInfo = function(spell)
            Count("getSpellInfo")
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            if not info then return nil end
            return {
                name = info.name,
                spellID = id,
                iconID = info.iconID,
                minRange = info.minRange,
                maxRange = info.maxRange,
                castTime = 0,
            }
        end,
        GetSpellTexture = function(spell)
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            return info and info.iconID or nil
        end,
        IsSpellInRange = function(spell, unit)
            Count("isSpellInRange")
            if Stub.secretEnabled then return Stub.secret end
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            if not info or unit ~= "target" or not Stub.targetExists then return nil end
            if info.hasRange == false then return nil end
            local reach = info.effectiveRange or info.maxRange or 0
            return Stub.distance <= reach
        end,
        SpellHasRange = function(spell)
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            if not info then return nil end
            return info.hasRange ~= false
        end,
        GetSpellDescription = function(spell)
            Count("getSpellDescription")
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            return info and info.description or nil
        end,
        GetSpellCooldownDuration = function() return 0 end,
        RequestLoadSpellData = function(id)
            Count("requestLoadSpellData")
            Stub.requestedSpellIDs[id] = (Stub.requestedSpellIDs[id] or 0) + 1
        end,
    }

    env.C_SpellBook = {
        GetNumSpellBookSkillLines = function() return 1 end,
        GetSpellBookSkillLineInfo = function()
            Count("getSpellBookSkillLineInfo")
            return { itemIndexOffset = 0, numSpellBookItems = #Stub.book, shouldHide = false, isGuild = false }
        end,
        GetSpellBookItemInfo = function(index)
            Count("getSpellBookItemInfo")
            local entry = Stub.book[index]
            if not entry then return nil end
            return {
                name = entry.name,
                spellID = entry.id,
                iconID = entry.iconID,
                isPassive = entry.isPassive or false,
                isOffSpec = false,
                itemType = env.Enum.SpellBookItemType.Spell,
            }
        end,
        IsSpellBookItemLowRank = function(index)
            local entry = Stub.book[index]
            return entry ~= nil and entry.lowRank == true
        end,
    }

    env.C_TooltipInfo = {
        GetSpellByID = function(id)
            local line = Stub.tooltipRanges[id]
            if not line then return { lines = {} } end
            return { lines = { { leftText = line } } }
        end,
    }

    env.C_Item = {
        GetItemInfo = function(id) return Stub.itemsCached[id] end,
        IsItemDataCachedByID = function(id) return Stub.itemsCached[id] ~= nil end,
        RequestLoadItemDataByID = function(id) Stub.pendingItemRequests[#Stub.pendingItemRequests + 1] = id end,
        IsItemInRange = function(item, unit)
            Count("isItemInRange")
            if Stub.secretEnabled then return Stub.secret end
            local yards = Stub.itemRanges[item]
            if not yards or unit ~= "target" then return nil end
            return Stub.distance <= yards
        end,
    }

    env.C_SpecializationInfo = {
        GetActiveSpecGroup = function() return 1 end,
        GetCombatConfigIDForSpecGroup = function() return 101 end,
        GetSpecialization = function() return Stub.activeSpec end,
        GetNumSpecializations = function() return 3 end,
        GetSpecializationInfo = function(index)
            local points = Stub.specPoints[index] or 0
            if Stub.specTuple then
                return "Spec " .. index, nil, nil, nil, nil, nil, points
            end
            return { pointsSpent = points, name = "Spec " .. index }
        end,
    }
    env.GetSpecialization = function() return Stub.activeSpec end

    env.C_Traits = {
        GetConfigInfo = function(configID)
            if not Stub.traitPoints or configID ~= 101 then return nil end
            return { ID = 101, treeIDs = { 1482 } }
        end,
        GetGroupDisplayInfoByTreeID = function(treeID)
            if not Stub.traitPoints or treeID ~= 1482 then return {} end
            return {
                { groupID = 11, displayName = "Arcane" },
                { groupID = 12, displayName = "Fire" },
                { groupID = 13, displayName = "Frost" },
            }
        end,
        GetGroupCurrencyInfo = function(configID)
            if not Stub.traitPoints or configID ~= 101 then return {} end
            return {
                { traitNodeGroupID = 11, currencyInfos = { { spent = Stub.traitPoints[1] or 0 } } },
                { traitNodeGroupID = 12, currencyInfos = { { spent = Stub.traitPoints[2] or 0 } } },
                { traitNodeGroupID = 13, currencyInfos = { { spent = Stub.traitPoints[3] or 0 } } },
            }
        end,
    }

    env.GetBuildInfo = function() return "1.60.1", "70450", "Oct 20 2026", 16001 end
    env.WOW_PROJECT_ID = 18
    env.WOW_PROJECT_CAMELOT = 18
    env.LE_EXPANSION_LEVEL_CURRENT = 0
end

-- Exact shape of modern-engine Classic clients (Classic Era 1.15.9, TBC
-- Anniversary 2.5.6, Wrath 3.80.2, Mists 5.5.4), verified against
-- Gethe/wow-ui-source:
--   * C_Spell, C_TooltipInfo, C_Item and C_SpecializationInfo ARE present
--   * global GetSpellInfo is GONE (nil)
--   * C_SpellBook has ONLY the 7 Classic helper functions - NOT
--     GetNumSpellBookSkillLines / GetSpellBookItemInfo
--   * the spellbook itself uses GetNumSpellTabs + GetSpellTabInfo +
--     GetSpellBookItemInfo + GetSpellBookItemName + GetSpellTexture
local function InstallModernClassicClient(env, flavor)
    InstallSpellNamespaces(env)

    env.C_Traits = nil
    env.GetSpellInfo = nil

    -- Only the 7 C_SpellBook functions present in Classic Era / TBC / Mists.
    env.C_SpellBook = {
        FindBaseSpellByID = function(id) return id end,
        FindFlyoutSlotBySpellID = function() return nil end,
        FindSpellOverrideByID = function(id) return id end,
        HasPetSpells = function() return nil end,
        IsSpellInSpellBook = function(id)
            for _, entry in ipairs(Stub.book) do
                if entry.id == id and entry.slotType == "SPELL" then return true end
            end
            return false
        end,
        IsSpellKnown = function(id)
            for _, entry in ipairs(Stub.book) do
                if entry.id == id and entry.slotType == "SPELL" then return true end
            end
            return false
        end,
        IsSpellKnownOrInSpellBook = function(id)
            for _, entry in ipairs(Stub.book) do
                if entry.id == id and entry.slotType == "SPELL" then return true end
            end
            return false
        end,
    }

    env.GetNumSpellTabs = function()
        if Stub.spellTabs then return #Stub.spellTabs end
        return 1
    end
    env.GetSpellTabInfo = function(tab)
        if Stub.spellTabs then
            local info = Stub.spellTabs[tab]
            if not info then return nil end
            return info.name or ("Tab " .. tab), 134400, info.offset or 0, info.count or 0,
                info.isGuild == true, info.offSpecID or 0, info.shouldHide == true
        end
        if tab ~= 1 then return nil end
        return "General", 134400, 0, #Stub.book, false, 0, false
    end
    env.GetSpellBookItemInfo = function(slot)
        local entry = Stub.book[slot]
        if not entry then return nil end
        return entry.slotType or "SPELL", entry.id
    end
    env.GetSpellBookItemName = function(slot)
        local entry = Stub.book[slot]
        if not entry then return nil end
        return entry.name, entry.subName or "", entry.id
    end
    env.GetSpellTexture = function(slotOrName)
        if type(slotOrName) == "number" then
            local entry = Stub.book[slotOrName]
            return entry and entry.iconID or nil
        end
        local id = Stub.idForName[slotOrName]
        local info = id and Stub.spells[id]
        return info and info.iconID or nil
    end
    env.IsPassiveSpell = function(slot)
        local entry = Stub.book[slot]
        return entry ~= nil and entry.isPassive == true
    end
    env.IsSpellInRange = function(spell, second, third)
        local unit = third or second
        if unit ~= "target" or not Stub.targetExists then return nil end
        local name
        if type(spell) == "number" then
            local entry = Stub.book[spell]
            name = entry and entry.name:lower() or nil
        elseif type(spell) == "string" then
            name = spell:lower()
        end
        local yards = name and Stub.legacyRanges[name]
        if not yards then return nil end
        return Stub.distance <= yards and 1 or 0
    end

    env.C_SpecializationInfo.GetTalentInfo = function(query)
        if type(query) ~= "table" then return nil end
        local tab = query.specializationIndex
        local idx = query.talentIndex
        local talent = tab and idx and (Stub.talents[tab] or {})[idx]
        if not talent then return nil end
        return {
            name = talent.name,
            icon = 134400,
            tier = 1,
            column = 1,
            rank = talent.rank or 0,
            maxRank = talent.max or 2,
            talentID = tab * 100 + idx,
        }
    end
    env.C_SpecializationInfo.GetSpecializationInfo = function(index)
        local pts = 0
        if flavor ~= "mists" then
            for _, t in ipairs(Stub.talents[index] or {}) do
                pts = pts + (t.rank or 0)
            end
            if pts == 0 then pts = Stub.specPoints[index] or 0 end
        end
        return index, "Tree " .. index, "", 134400, "DAMAGER", 4, pts, "", 0, true
    end

    if flavor ~= "mists" and not Stub.nativeTalentsOnly then
        env.GetNumTalentTabs = function() return 3 end
        env.GetNumTalents = function(tab) return #(Stub.talents[tab] or {}) end
        env.GetTalentInfo = function(tab, index)
            local talent = (Stub.talents[tab] or {})[index]
            if not talent then return nil end
            return talent.name, 134400, 1, 1, talent.rank or 0, talent.max or 2
        end
    end

    env.WOW_PROJECT_CAMELOT = nil
    if flavor == "era" then
        env.GetBuildInfo = function() return "1.15.9", "70003", "Oct 10 2026", 11509 end
        env.WOW_PROJECT_CLASSIC = 2
        env.WOW_PROJECT_ID = 2
    elseif flavor == "tbc_modern" then
        env.GetBuildInfo = function() return "2.5.6", "70006", "Oct 10 2026", 20506 end
        env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
        env.WOW_PROJECT_ID = 5
    elseif flavor == "wrath" then
        env.GetBuildInfo = function() return "3.80.2", "70372", "Oct 15 2026", 38002 end
        env.WOW_PROJECT_WRATH_CLASSIC = 11
        env.WOW_PROJECT_ID = 11
    elseif flavor == "mists" then
        env.GetBuildInfo = function() return "5.5.4", "70469", "Oct 18 2026", 50504 end
        env.WOW_PROJECT_MISTS_CLASSIC = 19
        env.WOW_PROJECT_ID = 19
    end
end

local function InstallLegacyClient(env)
    env.C_Spell = nil
    env.C_SpellBook = nil
    env.C_TooltipInfo = nil
    env.C_Item = nil
    env.C_SpecializationInfo = nil

    env.GetBuildInfo = function() return "2.5.5", "63000", "Jan 13 2026", 20505 end
    env.WOW_PROJECT_ID = 5
    env.WOW_PROJECT_CAMELOT = nil

    env.GetSpellInfo = function(spell)
        local id = type(spell) == "number" and spell or Stub.idForName[spell]
        local info = id and Stub.spells[id]
        if not info then return nil end
        return info.name, nil, info.iconID, nil, info.minRange, info.maxRange, id
    end
    env.GetSpellBookItemName = function(index)
        local entry = Stub.book[index]
        return entry and entry.name or nil
    end
    env.IsSpellInRange = function(spell, unit)
        if type(spell) == "number" and type(unit) == "string" then return nil end
        local name = type(spell) == "string" and spell:lower() or nil
        local yards = name and Stub.legacyRanges[name]
        if not yards or unit ~= "target" or not Stub.targetExists then return nil end
        return Stub.distance <= yards and 1 or 0
    end
    env.IsItemInRange = nil

    env.GetNumTalentTabs = function() return 3 end
    env.GetNumTalents = function(tab) return #(Stub.talents[tab] or {}) end
    env.GetTalentInfo = function(tab, index)
        local talent = (Stub.talents[tab] or {})[index]
        if not talent then return nil end
        return talent.name, 134400, 1, 1, talent.rank or 0, talent.max or 2
    end
end

-- A CreateFrame that fails for one kind, to check the addon survives it.
Stub.failCreateFrameFor = nil

function Stub.Install(mode)
    mode = mode or "forever"
    local env = _G
    InstallShared(env)
    if mode == "forever" then
        InstallSpellNamespaces(env)
    elseif mode == "mainline" then
        InstallSpellNamespaces(env)
        env.C_Traits = nil
        env.WOW_PROJECT_CAMELOT = nil
        env.WOW_PROJECT_MAINLINE = 1
        env.WOW_PROJECT_ID = 1
        env.GetBuildInfo = function() return "12.1.5", "70448", "Oct 19 2026", 120105 end
    elseif mode == "era" or mode == "tbc_modern" or mode == "wrath" or mode == "mists" then
        InstallModernClassicClient(env, mode)
    elseif mode == "tbc" then
        InstallLegacyClient(env)
    else
        error("unknown stub mode: " .. tostring(mode))
    end
    env.MageRangeIndicatorDB = nil
    Stub.mode = mode
    return env
end

return Stub
