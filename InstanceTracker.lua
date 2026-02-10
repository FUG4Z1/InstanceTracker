----------------------------------------------------------------------
-- InstanceTracker for WoW 3.3.5a (WotLK)
-- Tracks the 5-instances-per-hour soft cap and saved lockouts.
-- Categorizes instances by expansion: Classic, TBC, WotLK.
-- Data is account-wide (5/hr limit is per account).
----------------------------------------------------------------------

local ADDON_NAME = "InstanceTracker"
local MAX_INSTANCES_PER_HOUR = 5
local HOUR_SECONDS = 3600

-- Saved variable (persists between sessions, account-wide)
InstanceTrackerDB = InstanceTrackerDB or {}

-- Runtime state
local frame = nil
local isInInstance = false
local currentZone = ""

----------------------------------------------------------------------
-- Instance database: maps instance name -> expansion
----------------------------------------------------------------------
local INSTANCE_EXPANSION = {
    -- ==================== CLASSIC DUNGEONS ====================
    ["Ragefire Chasm"]              = "classic",
    ["Wailing Caverns"]             = "classic",
    ["The Deadmines"]               = "classic",
    ["Deadmines"]                   = "classic",
    ["Shadowfang Keep"]             = "classic",
    ["The Stockade"]                = "classic",
    ["Stockade"]                    = "classic",
    ["Blackfathom Deeps"]           = "classic",
    ["Gnomeregan"]                  = "classic",
    ["Razorfen Kraul"]              = "classic",
    ["The Scarlet Monastery"]       = "classic",
    ["Scarlet Monastery"]           = "classic",
    ["Razorfen Downs"]              = "classic",
    ["Uldaman"]                     = "classic",
    ["Zul'Farrak"]                  = "classic",
    ["Maraudon"]                    = "classic",
    ["Temple of Atal'Hakkar"]       = "classic",
    ["Sunken Temple"]               = "classic",
    ["Blackrock Depths"]            = "classic",
    ["Dire Maul"]                   = "classic",
    ["Dire Maul North"]             = "classic",
    ["Dire Maul East"]              = "classic",
    ["Dire Maul West"]              = "classic",
    ["Stratholme"]                  = "classic",
    ["Scholomance"]                 = "classic",
    ["Lower Blackrock Spire"]       = "classic",
    ["Upper Blackrock Spire"]       = "classic",
    ["Blackrock Spire"]             = "classic",

    -- ==================== CLASSIC RAIDS ====================
    ["Molten Core"]                 = "classic",
    ["Onyxia's Lair"]               = "classic",
    ["Blackwing Lair"]              = "classic",
    ["Zul'Gurub"]                   = "classic",
    ["Ruins of Ahn'Qiraj"]         = "classic",
    ["Temple of Ahn'Qiraj"]        = "classic",
    ["Ahn'Qiraj Temple"]           = "classic",
    ["Ahn'Qiraj"]                  = "classic",

    -- ==================== TBC DUNGEONS ====================
    ["Hellfire Ramparts"]                           = "tbc",
    ["Ramparts"]                                    = "tbc",
    ["Hellfire Citadel: Ramparts"]                  = "tbc",
    ["Hellfire Citadel: Hellfire Ramparts"]          = "tbc",
    ["The Blood Furnace"]                           = "tbc",
    ["Blood Furnace"]                               = "tbc",
    ["Hellfire Citadel: The Blood Furnace"]          = "tbc",
    ["Hellfire Citadel: Blood Furnace"]              = "tbc",
    ["The Shattered Halls"]                         = "tbc",
    ["Shattered Halls"]                             = "tbc",
    ["Hellfire Citadel: The Shattered Halls"]        = "tbc",
    ["Hellfire Citadel: Shattered Halls"]            = "tbc",
    ["The Slave Pens"]                              = "tbc",
    ["Slave Pens"]                                  = "tbc",
    ["Coilfang Reservoir: The Slave Pens"]           = "tbc",
    ["Coilfang Reservoir: Slave Pens"]               = "tbc",
    ["The Underbog"]                                = "tbc",
    ["Underbog"]                                    = "tbc",
    ["Coilfang Reservoir: The Underbog"]             = "tbc",
    ["Coilfang Reservoir: Underbog"]                 = "tbc",
    ["The Steamvault"]                              = "tbc",
    ["Steamvault"]                                  = "tbc",
    ["Coilfang Reservoir: The Steamvault"]           = "tbc",
    ["Coilfang Reservoir: Steamvault"]               = "tbc",
    ["Mana-Tombs"]                                  = "tbc",
    ["Mana Tombs"]                                  = "tbc",
    ["Auchindoun: Mana-Tombs"]                      = "tbc",
    ["Auchindoun: Mana Tombs"]                      = "tbc",
    ["Auchenai Crypts"]                             = "tbc",
    ["Auchindoun: Auchenai Crypts"]                 = "tbc",
    ["Sethekk Halls"]                               = "tbc",
    ["Auchindoun: Sethekk Halls"]                   = "tbc",
    ["Shadow Labyrinth"]                            = "tbc",
    ["Auchindoun: Shadow Labyrinth"]                = "tbc",
    ["Old Hillsbrad Foothills"]                     = "tbc",
    ["Caverns of Time: Old Hillsbrad Foothills"]    = "tbc",
    ["Old Hillsbrad"]                               = "tbc",
    ["The Escape From Durnholde"]                   = "tbc",
    ["Escape From Durnholde"]                       = "tbc",
    ["Durnholde Keep"]                              = "tbc",
    ["The Black Morass"]                            = "tbc",
    ["Black Morass"]                                = "tbc",
    ["Caverns of Time: The Black Morass"]           = "tbc",
    ["Caverns of Time: Black Morass"]               = "tbc",
    ["Opening of the Dark Portal"]                  = "tbc",
    ["The Mechanar"]                                = "tbc",
    ["Mechanar"]                                    = "tbc",
    ["Tempest Keep: The Mechanar"]                  = "tbc",
    ["Tempest Keep: Mechanar"]                      = "tbc",
    ["The Botanica"]                                = "tbc",
    ["Botanica"]                                    = "tbc",
    ["Tempest Keep: The Botanica"]                  = "tbc",
    ["Tempest Keep: Botanica"]                      = "tbc",
    ["The Arcatraz"]                                = "tbc",
    ["Arcatraz"]                                    = "tbc",
    ["Tempest Keep: The Arcatraz"]                  = "tbc",
    ["Tempest Keep: Arcatraz"]                      = "tbc",
    ["Magisters' Terrace"]                          = "tbc",
    ["Magister's Terrace"]                          = "tbc",

    -- ==================== TBC RAIDS ====================
    ["Karazhan"]                                    = "tbc",
    ["Gruul's Lair"]                                = "tbc",
    ["Magtheridon's Lair"]                          = "tbc",
    ["Serpentshrine Cavern"]                        = "tbc",
    ["Coilfang Reservoir: Serpentshrine Cavern"]    = "tbc",
    ["Tempest Keep"]                                = "tbc",
    ["The Eye"]                                     = "tbc",
    ["Tempest Keep: The Eye"]                       = "tbc",
    ["Hyjal Summit"]                                = "tbc",
    ["The Battle for Mount Hyjal"]                  = "tbc",
    ["Battle for Mount Hyjal"]                      = "tbc",
    ["Mount Hyjal"]                                 = "tbc",
    ["Caverns of Time: Hyjal Summit"]               = "tbc",
    ["Caverns of Time: Mount Hyjal"]                = "tbc",
    ["Caverns of Time: The Battle for Mount Hyjal"] = "tbc",
    ["Black Temple"]                                = "tbc",
    ["Zul'Aman"]                                    = "tbc",
    ["Sunwell Plateau"]                             = "tbc",

    -- ==================== WOTLK DUNGEONS ====================
    ["Utgarde Keep"]                                = "wotlk",
    ["Utgarde Pinnacle"]                            = "wotlk",
    ["The Nexus"]                                   = "wotlk",
    ["Nexus"]                                       = "wotlk",
    ["Azjol-Nerub"]                                 = "wotlk",
    ["Ahn'kahet: The Old Kingdom"]                  = "wotlk",
    ["Ahn'kahet"]                                   = "wotlk",
    ["Old Kingdom"]                                 = "wotlk",
    ["The Old Kingdom"]                             = "wotlk",
    ["Drak'Tharon Keep"]                            = "wotlk",
    ["The Violet Hold"]                             = "wotlk",
    ["Violet Hold"]                                 = "wotlk",
    ["Gundrak"]                                     = "wotlk",
    ["Halls of Stone"]                              = "wotlk",
    ["Halls of Lightning"]                          = "wotlk",
    ["The Culling of Stratholme"]                   = "wotlk",
    ["Culling of Stratholme"]                       = "wotlk",
    ["Caverns of Time: The Culling of Stratholme"]  = "wotlk",
    ["Caverns of Time: Culling of Stratholme"]      = "wotlk",
    ["The Oculus"]                                  = "wotlk",
    ["Oculus"]                                      = "wotlk",
    ["Trial of the Champion"]                       = "wotlk",
    ["The Forge of Souls"]                          = "wotlk",
    ["Forge of Souls"]                              = "wotlk",
    ["Pit of Saron"]                                = "wotlk",
    ["Halls of Reflection"]                         = "wotlk",

    -- ==================== WOTLK RAIDS ====================
    ["Naxxramas"]                                   = "wotlk",
    ["The Obsidian Sanctum"]                        = "wotlk",
    ["Obsidian Sanctum"]                            = "wotlk",
    ["The Eye of Eternity"]                         = "wotlk",
    ["Eye of Eternity"]                             = "wotlk",
    ["Vault of Archavon"]                           = "wotlk",
    ["Ulduar"]                                      = "wotlk",
    ["Trial of the Crusader"]                       = "wotlk",
    ["Trial of the Grand Crusader"]                 = "wotlk",
    ["Icecrown Citadel"]                            = "wotlk",
    ["The Ruby Sanctum"]                            = "wotlk",
    ["Ruby Sanctum"]                                = "wotlk",
}

local EXPANSION_ORDER = { "classic", "tbc", "wotlk" }
local EXPANSION_LABELS = {
    classic = "|cffffcc00Classic|r",
    tbc     = "|cff1eff00The Burning Crusade|r",
    wotlk   = "|cff0070ddWrath of the Lich King|r",
}

local function GetExpansion(instanceName)
    if not instanceName then return nil end
    local direct = INSTANCE_EXPANSION[instanceName]
    if direct then return direct end

    -- Fuzzy fallback: substring matching
    for knownName, exp in pairs(INSTANCE_EXPANSION) do
        if instanceName:find(knownName, 1, true) or knownName:find(instanceName, 1, true) then
            INSTANCE_EXPANSION[instanceName] = exp
            return exp
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Utility helpers
----------------------------------------------------------------------
local function FormatTime(seconds)
    if seconds <= 0 then return "Ready" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

local function PurgeOld()
    local now = time()
    local fresh = {}
    for _, entry in ipairs(InstanceTrackerDB.recentInstances or {}) do
        if (entry.time + HOUR_SECONDS) > now then
            fresh[#fresh + 1] = entry
        end
    end
    InstanceTrackerDB.recentInstances = fresh
end

local function GetInstanceCount()
    PurgeOld()
    return #(InstanceTrackerDB.recentInstances or {})
end

local function RemoveInstance(index)
    local recent = InstanceTrackerDB.recentInstances or {}
    if index >= 1 and index <= #recent then
        table.remove(recent, index)
        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "Removed entry #" .. index .. "."
        )
    end
end

local function RecordInstance(name)
    if not InstanceTrackerDB.recentInstances then
        InstanceTrackerDB.recentInstances = {}
    end
    PurgeOld()

    -- Only skip if we entered the SAME dungeon very recently (within 60s).
    -- This prevents the walk-out/walk-back-in double-count,
    -- but still allows legitimate re-runs after resetting the instance.
    local now = time()
    for _, entry in ipairs(InstanceTrackerDB.recentInstances) do
        if entry.name == name and (now - entry.time) < 60 then
            return
        end
    end

    table.insert(InstanceTrackerDB.recentInstances, {
        name = name,
        time = time(),
    })
    DEFAULT_CHAT_FRAME:AddMessage(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Entered: "
        .. ColorText(name, 1, 1, 0.6)
        .. " ("
        .. ColorText(GetInstanceCount() .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.6, 0.2)
        .. " this hour)"
    )
end

----------------------------------------------------------------------
-- Forward declaration for RefreshUI (needed by delete buttons)
----------------------------------------------------------------------
local RefreshUI

----------------------------------------------------------------------
-- UI: Object pools for reusable frames/fontstrings.
-- No new frames created after initial pool growth.
----------------------------------------------------------------------

local ROW_POOL = {}      -- pool of reusable row frames (with left, right, deleteBtn)
local ROW_POOL_USED = 0
local TEXT_POOL = {}      -- pool of reusable fontstrings
local TEXT_POOL_USED = 0

local function ResetPools()
    for i = 1, ROW_POOL_USED do
        if ROW_POOL[i] then
            ROW_POOL[i]:Hide()
            if ROW_POOL[i].deleteBtn then
                ROW_POOL[i].deleteBtn:Hide()
            end
        end
    end
    ROW_POOL_USED = 0
    for i = 1, TEXT_POOL_USED do
        if TEXT_POOL[i] then TEXT_POOL[i]:Hide() end
    end
    TEXT_POOL_USED = 0
end

local function GetRow(parent, showDelete)
    ROW_POOL_USED = ROW_POOL_USED + 1
    local row = ROW_POOL[ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(280)
        row:SetHeight(16)

        -- [x] delete button (created once, shown only when needed)
        local delBtn = CreateFrame("Button", nil, row)
        delBtn:SetWidth(14)
        delBtn:SetHeight(14)
        delBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
        delBtn:SetNormalFontObject(GameFontNormalSmall)
        delBtn:SetHighlightFontObject(GameFontHighlightSmall)
        delBtn:SetText("|cffff4444x|r")
        delBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        delBtn:SetScript("OnEnter", function(self)
            self:SetText("|cffff8888x|r")
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Remove this entry", 1, 0.4, 0.4)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")
            GameTooltip:Hide()
        end)
        delBtn.deleteIndex = nil
        row.deleteBtn = delBtn

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        left:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        left:SetJustifyH("LEFT")
        row.left = left

        local right = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        right:SetJustifyH("RIGHT")
        row.right = right

        ROW_POOL[ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    row.left:SetText("")
    row.right:SetText("")

    -- Show or hide the delete button
    if showDelete then
        row.deleteBtn:Show()
        row.left:SetPoint("LEFT", row.deleteBtn, "RIGHT", 2, 0)
    else
        row.deleteBtn:Hide()
        row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    end

    return row
end

local function GetText(parent)
    TEXT_POOL_USED = TEXT_POOL_USED + 1
    local fs = TEXT_POOL[TEXT_POOL_USED]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        TEXT_POOL[TEXT_POOL_USED] = fs
    end
    fs:SetParent(parent)
    fs:ClearAllPoints()
    fs:Show()
    fs:SetText("")
    return fs
end

----------------------------------------------------------------------
-- Main UI Frame
----------------------------------------------------------------------
local function CreateMainFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    }

    local f = CreateFrame("Frame", "InstanceTrackerFrame", UIParent)
    f:SetWidth(340)
    f:SetHeight(400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("MEDIUM")

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil,
        tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.15, 0.35, 0.6, 0.7)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("Instance Tracker")
    title:SetTextColor(0.5, 0.8, 1, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Reset Instances button (small, next to close)
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:SetWidth(50)
    resetBtn:SetHeight(18)
    resetBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)

    local resetBtnBg = resetBtn:CreateTexture(nil, "BACKGROUND")
    resetBtnBg:SetAllPoints()
    resetBtnBg:SetTexture(0.3, 0.15, 0.1, 0.7)
    resetBtn.bg = resetBtnBg

    local resetBtnText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetBtnText:SetPoint("CENTER", resetBtn, "CENTER", 0, 0)
    resetBtnText:SetText("|cffff8844Reset|r")
    resetBtn.label = resetBtnText

    resetBtn:SetScript("OnClick", function()
        ResetInstances()
        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "Instances reset."
        )
    end)
    resetBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
        self.label:SetText("|cffffaa66Reset|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset Instances", 1, 0.6, 0.2)
        GameTooltip:AddLine("Resets all non-saved dungeon instances.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Same as typing /reset or right-clicking", 0.5, 0.5, 0.5, true)
        GameTooltip:AddLine("your portrait and selecting Reset.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
        self.label:SetText("|cffff8844Reset|r")
        GameTooltip:Hide()
    end)

    -- Hourly counter text
    local hourlyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hourlyText:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -8)
    hourlyText:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -8)
    hourlyText:SetJustifyH("LEFT")
    hourlyText:SetText("")
    f.hourlyText = hourlyText

    -- Separator line
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", hourlyText, "BOTTOMLEFT", 0, -6)
    sep:SetPoint("TOPRIGHT", hourlyText, "BOTTOMRIGHT", 0, -6)
    sep:SetTexture(1, 1, 1, 0.15)

    -- Scroll frame for content
    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(280)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content
    f.scrollFrame = scrollFrame

    -- Resize handle
    local resizeGrip = CreateFrame("Frame", nil, f)
    resizeGrip:SetWidth(16)
    resizeGrip:SetHeight(16)
    resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    resizeGrip:EnableMouse(true)
    resizeGrip:SetScript("OnMouseDown", function()
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
    end)
    f:SetResizable(true)
    f:SetMinResize(300, 200)
    f:SetMaxResize(500, 700)

    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

    return f
end

----------------------------------------------------------------------
-- Refresh / render the tracker window
-- Uses pooled rows — no new frames or fontstrings created after init.
----------------------------------------------------------------------
RefreshUI = function()
    if not frame or not frame:IsShown() then return end

    PurgeOld()
    ResetPools()

    local now = time()
    local recent = InstanceTrackerDB.recentInstances or {}
    local count = #recent
    local remaining = MAX_INSTANCES_PER_HOUR - count
    local content = frame.content

    -- Colour the count
    local countColor
    if remaining <= 0 then
        countColor = "|cffff4444"
    elseif remaining <= 2 then
        countColor = "|cffff8800"
    else
        countColor = "|cff44ff44"
    end

    -- Next available slot timer
    local nextSlot = ""
    if count >= MAX_INSTANCES_PER_HOUR and recent[1] then
        local expires = recent[1].time + HOUR_SECONDS - now
        nextSlot = "  |cffcccccc(next slot in " .. FormatTime(expires) .. ")|r"
    end

    frame.hourlyText:SetText(
        "|cff80c0ffHourly Cap:|r  "
        .. countColor .. count .. "/" .. MAX_INSTANCES_PER_HOUR .. "|r"
        .. "  " .. countColor .. "(" .. remaining .. " left)|r"
        .. nextSlot
    )

    local yOff = 0

    ------------------------------------------------------------------
    -- Section: Recent instances (hourly tracker)
    ------------------------------------------------------------------
    local header1 = GetText(content)
    header1:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header1:SetText("|cff80c0ff--- Recent Instances (1h window) ---|r")
    yOff = yOff + 18

    if #recent == 0 then
        local none = GetText(content)
        none:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        none:SetText("|cff888888No recent instances.|r")
        yOff = yOff + 16
    else
        for i, entry in ipairs(recent) do
            local elapsed = now - entry.time
            local timeLeft = HOUR_SECONDS - elapsed

            local row = GetRow(content, true) -- true = show [x] button
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)

            -- Wire up the delete button for this specific index
            local idx = i
            row.deleteBtn.deleteIndex = idx
            row.deleteBtn:SetScript("OnClick", function()
                RemoveInstance(idx)
                RefreshUI()
            end)

            row.left:SetText("|cff666666" .. i .. ".|r  |cffffffcc" .. (entry.name or "Unknown") .. "|r")

            if timeLeft > 0 then
                row.right:SetText("|cffff8844" .. FormatTime(timeLeft) .. "|r")
            else
                row.right:SetText("|cff44ff44Expired|r")
            end

            yOff = yOff + 16
        end
    end

    yOff = yOff + 12

    ------------------------------------------------------------------
    -- Section: Saved lockouts grouped by expansion
    ------------------------------------------------------------------
    local header2 = GetText(content)
    header2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header2:SetText("|cff80c0ff--- Saved Lockouts ---|r")
    yOff = yOff + 18

    local numSaved = GetNumSavedInstances()

    -- Gather saved instances into buckets
    local buckets = { classic = {}, tbc = {}, wotlk = {}, unknown = {} }

    for i = 1, numSaved do
        local instName, instID, instReset, instDiff, locked, extended, mostsig, isRaid, maxPlayers, diffName = GetSavedInstanceInfo(i)
        if instName then
            local exp = GetExpansion(instName) or "unknown"
            table.insert(buckets[exp], {
                name = instName,
                reset = instReset,
                diff = instDiff,
                locked = locked,
                isRaid = isRaid,
            })
        end
    end

    -- Render each expansion: Classic -> TBC -> WotLK
    for _, expKey in ipairs(EXPANSION_ORDER) do
        local list = buckets[expKey]

        -- Expansion header
        local expHeader = GetText(content)
        expHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
        expHeader:SetText(EXPANSION_LABELS[expKey])
        yOff = yOff + 16

        if list and #list > 0 then
            for _, info in ipairs(list) do
                local row = GetRow(content, false) -- no [x] for lockouts
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -yOff)

                -- Difficulty tag
                local diffTag = ""
                if info.isRaid then
                    if info.diff == 1 then diffTag = " |cff888888(10N)|r"
                    elseif info.diff == 2 then diffTag = " |cff888888(25N)|r"
                    elseif info.diff == 3 then diffTag = " |cff888888(10H)|r"
                    elseif info.diff == 4 then diffTag = " |cff888888(25H)|r"
                    end
                else
                    if info.diff == 1 then diffTag = " |cff888888(Normal)|r"
                    elseif info.diff == 2 then diffTag = " |cff888888(Heroic)|r"
                    end
                end

                local lockColor = info.locked and "|cffff4444" or "|cff44ff44"
                row.left:SetText(lockColor .. info.name .. "|r" .. diffTag)

                if info.reset and info.reset > 0 then
                    row.right:SetText("|cffff8844" .. FormatTime(info.reset) .. "|r")
                else
                    row.right:SetText("|cff44ff44Available|r")
                end

                yOff = yOff + 16
            end
        else
            local noneExp = GetText(content)
            noneExp:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -yOff)
            noneExp:SetText("|cff555555No lockouts|r")
            yOff = yOff + 14
        end
        yOff = yOff + 8
    end

    -- Unknown expansion (only if any exist)
    if buckets.unknown and #buckets.unknown > 0 then
        local expHeader = GetText(content)
        expHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
        expHeader:SetText("|cff999999Other|r")
        yOff = yOff + 16

        for _, info in ipairs(buckets.unknown) do
            local row = GetRow(content, false)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -yOff)
            row.left:SetText("|cffff4444" .. info.name .. "|r")
            if info.reset and info.reset > 0 then
                row.right:SetText("|cffff8844" .. FormatTime(info.reset) .. "|r")
            else
                row.right:SetText("|cff44ff44Available|r")
            end
            yOff = yOff + 16
        end
        yOff = yOff + 8
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
end

----------------------------------------------------------------------
-- Periodic update (every 1 second when visible)
----------------------------------------------------------------------
local elapsed_acc = 0
local function OnUpdate(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    if elapsed_acc >= 1 then
        elapsed_acc = 0
        RefreshUI()
    end
end

----------------------------------------------------------------------
-- Event handling
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not InstanceTrackerDB.recentInstances then
            InstanceTrackerDB.recentInstances = {}
        end
        PurgeOld()

        frame = CreateMainFrame()
        frame:Hide()
        frame:SetScript("OnUpdate", OnUpdate)

        RequestRaidInfo()

        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "Loaded. Type "
            .. ColorText("/it", 1, 1, 0.6)
            .. " or "
            .. ColorText("/itracker", 1, 1, 0.6)
            .. " to toggle the window."
        )

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local inInstance, instanceType = IsInInstance()
        local zoneName = GetInstanceInfo and select(1, GetInstanceInfo()) or GetRealZoneText()

        if inInstance and (instanceType == "party" or instanceType == "raid") then
            if not isInInstance or currentZone ~= zoneName then
                isInInstance = true
                currentZone = zoneName
                RecordInstance(zoneName)
                RequestRaidInfo()
            end
        else
            isInInstance = false
            currentZone = ""
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if msg and msg:find("too many instances") then
            DEFAULT_CHAT_FRAME:AddMessage(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. ColorText("WARNING: ", 1, 0.2, 0.2)
                .. "You've hit the hourly instance cap!"
            )
            if frame and not frame:IsShown() then
                frame:Show()
                RefreshUI()
            end
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        RefreshUI()
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_INSTANCETRACKER1 = "/it"
SLASH_INSTANCETRACKER2 = "/itracker"
SLASH_INSTANCETRACKER3 = "/instancetracker"
SlashCmdList["INSTANCETRACKER"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "reset" then
        InstanceTrackerDB.recentInstances = {}
        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "Recent instance history cleared."
        )
        RefreshUI()
        return
    elseif msg == "status" then
        PurgeOld()
        local count = #(InstanceTrackerDB.recentInstances or {})
        local remaining = MAX_INSTANCES_PER_HOUR - count
        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "Instances this hour: "
            .. ColorText(count .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.8, 0.2)
            .. " ("
            .. ColorText(remaining .. " remaining", 0.4, 1, 0.4)
            .. ")"
        )
        return
    end

    if not frame then
        frame = CreateMainFrame()
        frame:SetScript("OnUpdate", OnUpdate)
    end

    if frame:IsShown() then
        frame:Hide()
    else
        RequestRaidInfo()
        frame:Show()
        RefreshUI()
    end
end

----------------------------------------------------------------------
-- Minimap button (orbits the minimap edge properly)
----------------------------------------------------------------------
local function CreateMinimapButton()
    -- Load saved angle or default to 220 degrees
    local minimapAngle = InstanceTrackerDB.minimapAngle or 220

    local btn = CreateFrame("Button", "InstanceTrackerMinimapBtn", Minimap)
    btn:SetWidth(31)
    btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Icon texture (the actual addon icon)
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(21)
    icon:SetHeight(21)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\Spell_Frost_Stun")

    -- Circular border overlay
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Position the button on the minimap edge at the given angle
    local function UpdatePosition()
        local angle = math.rad(minimapAngle)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    UpdatePosition()

    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    btn:SetScript("OnDragStart", function()
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePosition()
        end)
    end)

    btn:SetScript("OnDragStop", function()
        btn:SetScript("OnUpdate", nil)
        InstanceTrackerDB.minimapAngle = minimapAngle
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and IsControlKeyDown() then
            -- Ctrl+Click = Reset instances
            ResetInstances()
            DEFAULT_CHAT_FRAME:AddMessage(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. "Instances reset."
            )
        elseif button == "LeftButton" then
            SlashCmdList["INSTANCETRACKER"]("")
        elseif button == "RightButton" then
            SlashCmdList["INSTANCETRACKER"]("status")
        end
    end)

    btn:SetScript("OnEnter", function(self)
        PurgeOld()
        local count = #(InstanceTrackerDB.recentInstances or {})
        local remaining = MAX_INSTANCES_PER_HOUR - count
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Instance Tracker", 0.5, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Instances (1h):", count .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 1, 1, 1, 0.8, 0.2)
        GameTooltip:AddDoubleLine("Remaining:", remaining, 1, 1, 1, 0.4, 1, 0.4)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff888888Left-click: Toggle window|r")
        GameTooltip:AddLine("|cff888888Ctrl-click: Reset instances|r")
        GameTooltip:AddLine("|cff888888Right-click: Status in chat|r")
        GameTooltip:AddLine("|cff888888Drag: Move around minimap|r")
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

eventFrame:HookScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        CreateMinimapButton()
    end
end)
