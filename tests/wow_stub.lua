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
    Stub.specTuple = false    -- return C_SpecializationInfo's tuple shape
    Stub.talents = {}         -- legacy: [tab] = { { name, rank }, ... }
    Stub.class = "MAGE"
    Stub.race = "Human"
    Stub.shift = false
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
    }, Widget)
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
function Widget:EnableMouse(value) self.mouse = value end
function Widget:RegisterForDrag(...) self.drag = { ... } end
function Widget:RegisterForClicks(...) self.clicks = { ... } end
function Widget:StartMoving() self.moving = true end
function Widget:StopMovingOrSizing() self.moving = false end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
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
function Widget:SetOwner() end
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
function Stub.ClickIcon(button)
    local frame = Stub.FindFrame("MRIFrame")
    if not frame then return false end
    if frame.scripts.OnMouseDown then frame.scripts.OnMouseDown(frame, button) end
    if frame.scripts.OnMouseUp then frame.scripts.OnMouseUp(frame, button) end
    return true
end

function Stub.HoverIcon()
    local frame = Stub.FindFrame("MRIFrame")
    if not frame then return false end
    if frame.scripts.OnEnter then frame.scripts.OnEnter(frame) end
    return true
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
        hasRange = options.hasRange,
        description = options.description,
    }
    Stub.idForName[name] = id
end

function Stub.AddBookSpell(name, id)
    Stub.book[#Stub.book + 1] = { name = name, id = id, iconID = 134400 }
end

---------------------------------------------------------------------------
-- Installing the fake client
---------------------------------------------------------------------------

local function InstallShared(env)
    env.print = env.print

    env.CreateFrame = function(kind, name, parent)
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
        IsSpellInRange = function(spell, unit)
            Count("isSpellInRange")
            if Stub.secretEnabled then return Stub.secret end
            local id = type(spell) == "number" and spell or Stub.idForName[spell]
            local info = id and Stub.spells[id]
            if not info or unit ~= "target" or not Stub.targetExists then return nil end
            if info.hasRange == false then return nil end
            return Stub.distance <= (info.maxRange or 0)
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
        GetNumSpecializations = function() return 3 end,
        GetSpecializationInfo = function(index)
            local points = Stub.specPoints[index] or 0
            if Stub.specTuple then
                return "Spec " .. index, nil, nil, nil, nil, nil, points
            end
            return { pointsSpent = points, name = "Spec " .. index }
        end,
    }
    env.GetSpecialization = function() return 1 end

    env.GetBuildInfo = function() return "1.60.1", "70338", "Oct 13 2026", 16001 end
    env.WOW_PROJECT_ID = 18
    env.WOW_PROJECT_CAMELOT = 18
    env.LE_EXPANSION_LEVEL_CURRENT = 0
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

function Stub.Install(mode)
    mode = mode or "forever"
    local env = _G
    InstallShared(env)
    if mode == "forever" then
        InstallSpellNamespaces(env)
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
