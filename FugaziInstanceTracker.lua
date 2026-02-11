----------------------------------------------------------------------
-- FugaziInstanceTracker for WoW 3.3.5a (WotLK)
-- Tracks the 5-instances-per-hour soft cap and saved lockouts.
-- Categorizes instances by expansion: Classic, TBC, WotLK.
-- Data is account-wide (5/hr limit is per account).
-- Tracks per-run stats: gold, items.
----------------------------------------------------------------------

local ADDON_NAME = "InstanceTracker"
local MAX_INSTANCES_PER_HOUR = 5
local HOUR_SECONDS = 3600
local MAX_RUN_HISTORY = 100
local SCROLL_CONTENT_WIDTH = 296  -- viewport width for scroll content (no gap left of scrollbar)

InstanceTrackerDB = InstanceTrackerDB or {}
if InstanceTrackerDB.fitMute == nil then InstanceTrackerDB.fitMute = false end

--- Print to chat; respects /fit mute.
local function AddonPrint(msg)
    if msg and msg ~= "" and not InstanceTrackerDB.fitMute then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

-- Runtime state
local frame = nil
local statsFrame = nil
local itemDetailFrame = nil
local isInInstance = false
local currentZone = ""

-- Lockout snapshot
local lockoutQueryTime = 0
local lockoutCache = {}

-- Current run tracking (runtime only, finalized on exit)
local currentRun = nil

-- Bag tracking (additive-only)
local bagBaseline = {}       -- { [itemId] = count } snapshot on enter
local itemsGained = {}       -- { [itemId] = count } only increases, never decreases
local itemLinksCache = {}    -- { [itemId] = link } runtime cache
local lastEquippedItemIds = {}  -- item IDs that were in equipment slots last diff; gains for these are from unequip, not loot

-- Gold tracking
local startingGold = 0

-- GPH session (manual, works anywhere)
local gphSession = nil   -- { startTime, startGold, items, qualityCounts }
local gphBagBaseline = {}
local gphItemsGained = {}
local gphFrame = nil

-- Global table to track pending deletes (itemId -> timestamp of first click)
local gphPendingDelete = gphPendingDelete or {}

-- Confirmation state for clear
local clearConfirmPending = false

local gphPendingQuality = gphPendingQuality or {}

--- Delete all items of a given quality from bags (GPH rarity delete).
local function DeleteAllOfQuality(quality)
    local deletedCount = 0
    local labels = { [0] = "Grey", [1] = "White", [2] = "Green", [3] = "Blue", [4] = "Epic", [5] = "Legendary" }
    local label = labels[quality] or "Unknown"

    for bag = 0, 4 do
        for slot = GetContainerNumSlots(bag), 1, -1 do  -- reverse to avoid slot shift issues
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, itemQuality = GetItemInfo(link)
                if itemQuality == quality then
                    local skip = false

                    -- For White (quality 1): skip quest items (via tooltip scan - classic 3.3.5a method) and hearthstone
                    if quality == 1 then
                        local itemId = tonumber(link:match("item:(%d+)"))
                        
                        -- Check if it's hearthstone (reliable by ID)
                        local skipThis = (itemId == 6948)
                        
                        -- If not hearthstone, do the tooltip scan for "Quest Item" text
                        if not skipThis then
                            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")  -- Hide tooltip off-screen (invisible to player)
                            GameTooltip:ClearLines()                       -- Start with a blank tooltip
                            GameTooltip:SetHyperlink(link)                 -- Load the current item into the tooltip
                            
                            for i = 1, GameTooltip:NumLines() do           -- Loop through each line of tooltip text
                                local lineText = _G["GameTooltipTextLeft" .. i]  -- Get the left-side text of line i
                                if lineText and lineText:GetText() == "Quest Item" then  -- Exact match for quest item label
                                    skipThis = true                             -- Found it! Mark for skipping
                                    break                                       -- Stop checking further lines (faster)
                                end
                            end
                            
                            GameTooltip:Hide()                             -- Close the hidden tooltip (cleanup)
                        end
                        
                        if skipThis then
                            skip = true                                        -- Final decision: don't delete this item
                        end
                        
                        -- Note: This assumes English client ("Quest Item"). If your server uses another language,
                        -- we'd need the translated text (rare on private servers, but let me know if needed!)
                    end

                    if not skip then
                        local _, stackCount = GetContainerItemInfo(bag, slot)
                        PickupContainerItem(bag, slot)
                        DeleteCursorItem()
                        deletedCount = deletedCount + (stackCount or 1)
                    end
                end
            end
        end
    end

    if deletedCount > 0 then
        AddonPrint(
            "[InstanceTracker] Deleted " .. deletedCount .. " " .. label .. " items."
        )
    end
end

-- Quality labels & colors
local QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d", label = "Poor" },
    [1] = { r = 1.00, g = 1.00, b = 1.00, hex = "ffffff", label = "Common" },
    [2] = { r = 0.12, g = 1.00, b = 0.00, hex = "1eff00", label = "Uncommon" },
    [3] = { r = 0.00, g = 0.44, b = 0.87, hex = "0070dd", label = "Rare" },
    [4] = { r = 0.64, g = 0.21, b = 0.93, hex = "a335ee", label = "Epic" },
    [5] = { r = 1.00, g = 0.50, b = 0.00, hex = "ff8000", label = "Legendary" },
}

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
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then return string.format("%dm %02ds", m, s)
    else return string.format("%ds", s) end
end

local function FormatTimeMedium(seconds)
    if seconds <= 0 then return "0s" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %dm", h, m)
    elseif m > 0 then return string.format("%dm %ds", m, s)
    else return string.format("%ds", s) end
end

local function FormatGold(copper)
    if not copper or copper <= 0 then return "|cffeda55f0c|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("|cffffd700%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, s, c)
    elseif s > 0 then return string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else return string.format("|cffeda55f%d|rc", c) end
end

local function FormatGoldPlain(copper)
    if not copper or copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then return string.format("%ds %dc", s, c)
    else return string.format("%dc", c) end
end

local function FormatDateTime(timestamp)
    if not timestamp then return "" end
    -- WoW 3.3.5a: date() function is available
    local dt = date("*t", timestamp)
    if not dt then return "" end
    -- Format: DD.M.YY - HH:MM (e.g., "11.2.26 - 14:30")
    return string.format("%d.%d.%d - %02d:%02d", dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
end

local function ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

-- Anchor tooltip just to the RIGHT of the whole window that owns this control,
-- with a small horizontal gap, so it never overlaps the scrollbar or content.
local TOOLTIP_FRAME_GAP = 5
local function AnchorTooltipRight(ownerFrame)
    if not ownerFrame then return end

    -- Walk up parents until we find the movable top-level window (stats, GPH, main, etc.)
    local host = ownerFrame
    while host and host:GetParent() and host ~= UIParent and (not host.IsMovable or not host:IsMovable()) do
        host = host:GetParent()
    end

    if not host or host == UIParent then
        -- Fallback: normal right-anchored tooltip on the control itself
        GameTooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
        return
    end

    GameTooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("LEFT", host, "RIGHT", TOOLTIP_FRAME_GAP, 0)
end

local function FormatQualityCounts(qc)
    if not qc then return "" end
    local parts = {}
    for q = 0, 5 do
        local count = qc[q]
        if count and count > 0 then
            local info = QUALITY_COLORS[q]
            if info then
                table.insert(parts, "|cff" .. info.hex .. count .. " " .. info.label .. "|r")
            end
        end
    end
    if #parts == 0 then return "|cff555555-|r" end
    return table.concat(parts, "  ")
end

--- Remove instance entries older than 1 hour from recentInstances.
local function PurgeOld()
    local now = time()
    local fresh = {}
    for _, entry in ipairs(InstanceTrackerDB.recentInstances or {}) do
        if (entry.time + HOUR_SECONDS) > now then fresh[#fresh + 1] = entry end
    end
    InstanceTrackerDB.recentInstances = fresh
end

--- Return current instance count this hour (after purging old entries).
local function GetInstanceCount()
    PurgeOld()
    return #(InstanceTrackerDB.recentInstances or {})
end

--- Remove a single entry from recentInstances by index.
local function RemoveInstance(index)
    local recent = InstanceTrackerDB.recentInstances or {}
    if index >= 1 and index <= #recent then
        table.remove(recent, index)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed entry #" .. index .. "."
        )
    end
end

--- Record entering an instance (name) and print count this hour.
local function RecordInstance(name)
    if not InstanceTrackerDB.recentInstances then InstanceTrackerDB.recentInstances = {} end
    PurgeOld()
    local now = time()
    for _, entry in ipairs(InstanceTrackerDB.recentInstances) do
        if entry.name == name and (now - entry.time) < 60 then return end
    end
    table.insert(InstanceTrackerDB.recentInstances, { name = name, time = time() })
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Entered: " .. ColorText(name, 1, 1, 0.6)
        .. " (" .. ColorText(GetInstanceCount() .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.6, 0.2)
        .. " this hour)"
    )
end

--- Delete up to amount of itemId from bags (GPH row delete).
local function DeleteGPHItem(itemId, amount)
    if not itemId or amount <= 0 then return end
    local remaining = amount
    for bag = 0, 4 do
        if remaining <= 0 then break end
        for slot = 1, GetContainerNumSlots(bag) do
            if remaining <= 0 then break end
            local currentId = GetContainerItemID(bag, slot)
            if currentId == itemId then
                local _, stackCount = GetContainerItemInfo(bag, slot)
                if stackCount and stackCount > 0 then
                    local deleteAmt = math.min(stackCount, remaining)
                    PickupContainerItem(bag, slot)
                    if deleteAmt < stackCount then
                        SplitContainerItem(bag, slot, stackCount - deleteAmt)
                    end
                    DeleteCursorItem()
                    remaining = remaining - deleteAmt
                end
            end
        end
    end
end

--- Bag scanning: returns { [itemId] = count } and fills itemLinksCache.
local function ScanBags()
    local counts = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local _, itemCount = GetContainerItemInfo(bag, slot)
                local itemId = tonumber(itemLink:match("item:(%d+)"))
                if itemId then
                    counts[itemId] = (counts[itemId] or 0) + (itemCount or 1)
                    itemLinksCache[itemId] = itemLink
                end
            end
        end
    end
    return counts
end

--- Snapshot bags as baseline when starting a run.
local function SnapshotBags()
    bagBaseline = ScanBags()
    itemsGained = {}
end

--- Build set of item IDs currently equipped (slots 1–19). Used to ignore unequip-as-loot.
local function GetEquippedItemIds()
    local ids = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if link then
            local id = tonumber(link:match("item:(%d+)"))
            if id then ids[id] = true end
        end
    end
    return ids
end

--- Update itemsGained from current bags vs baseline; updates currentRun (dungeon run). Skips gains that are from unequipping.
local function DiffBags()
    if not currentRun then return end
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()

    for itemId, curCount in pairs(current) do
        local baseCount = bagBaseline[itemId] or 0
        local delta = curCount - baseCount
        if delta > 0 and lastEquippedItemIds[itemId] then
            -- Gain from unequipping; absorb into itemsGained so we don't count it later, but don't add to run.
            itemsGained[itemId] = delta
        elseif delta > 0 then
            local prev = itemsGained[itemId] or 0
            if delta > prev then
                local diff = delta - prev
                itemsGained[itemId] = delta

                local link = itemLinksCache[itemId]
                if link then
                    local name, _, quality = GetItemInfo(link)
                    quality = quality or 0
                    name = name or "Unknown"

                    currentRun.qualityCounts[quality] = (currentRun.qualityCounts[quality] or 0) + diff
                    if quality >= 1 then
                        if not currentRun.items[itemId] then
                            currentRun.items[itemId] = {
                                link = link, quality = quality, count = 0, name = name
                            }
                        end
                        currentRun.items[itemId].count = currentRun.items[itemId].count + diff
                        currentRun.items[itemId].link = link
                    end
                end
            end
        end
    end
    lastEquippedItemIds = currentEquipped
    if currentRun then
        InstanceTrackerDB.currentRun = currentRun
        InstanceTrackerDB.bagBaseline = bagBaseline
        InstanceTrackerDB.itemsGained = itemsGained
    end
end

--- GPH session: update gphItemsGained from current bags vs gphBagBaseline. Skips gains from unequipping.
local function DiffBagsGPH()
    if not gphSession then return end
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    for itemId, curCount in pairs(current) do
        local baseCount = gphBagBaseline[itemId] or 0
        local delta = curCount - baseCount
        if delta > 0 and lastEquippedItemIds[itemId] then
            gphItemsGained[itemId] = delta  -- absorb unequip gain so we don't count it later
        elseif delta > 0 then
            local prev = gphItemsGained[itemId] or 0
            if delta > prev then
                local diff = delta - prev
                gphItemsGained[itemId] = delta
                local link = itemLinksCache[itemId]
                if link then
                    local name, _, quality = GetItemInfo(link)
                    quality = quality or 0
                    name = name or "Unknown"
                    gphSession.qualityCounts[quality] = (gphSession.qualityCounts[quality] or 0) + diff
                    if not gphSession.items[itemId] then
                        gphSession.items[itemId] = { link = link, quality = quality, count = 0, name = name }
                    end
                    gphSession.items[itemId].count = gphSession.items[itemId].count + diff
                    gphSession.items[itemId].link = link
                end
            end
        end
    end
    lastEquippedItemIds = currentEquipped
    if gphSession then
        InstanceTrackerDB.gphSession = gphSession
        InstanceTrackerDB.gphBagBaseline = gphBagBaseline
        InstanceTrackerDB.gphItemsGained = gphItemsGained
    end
end

--- Start a new GPH session (timer, gold baseline, bag baseline).
local function StartGPHSession()
    gphSession = {
        startTime = time(),
        startGold = GetMoney(),
        items = {},
        qualityCounts = {},
    }
    gphBagBaseline = ScanBags()
    gphItemsGained = {}
    -- Save state for persistence
    InstanceTrackerDB.gphSession = gphSession
    InstanceTrackerDB.gphBagBaseline = gphBagBaseline
    InstanceTrackerDB.gphItemsGained = gphItemsGained
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session started."
    )
end

--- End GPH session and optionally add to run history.
local function StopGPHSession()
    if not gphSession then return end

    local now = time()
    local dur = now - gphSession.startTime
    local gold = GetMoney() - gphSession.startGold
    if gold < 0 then gold = 0 end

    -- Convert items to sorted list (identical to dungeon runs)
    local itemList = {}
    for _, item in pairs(gphSession.items) do
        table.insert(itemList, {
            link = item.link,
            quality = item.quality,
            count = item.count,
            name = item.name,
        })
    end
    table.sort(itemList, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)

    -- NEW: Decide if this session actually gained anything
    local anythingGained = (gold > 0) or (#itemList > 0)

    if anythingGained then
        -- Original saving code – now only runs if we gained gold OR items
        local run = {
            name = "GPH" .. (FormatDateTime(gphSession.startTime) ~= "" and (" - " .. FormatDateTime(gphSession.startTime)) or ""),
            enterTime = gphSession.startTime,
            exitTime = now,
            duration = dur,
            goldCopper = gold,
            qualityCounts = gphSession.qualityCounts,
            items = itemList,
        }

        if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
        table.insert(InstanceTrackerDB.runHistory, 1, run)
        while #InstanceTrackerDB.runHistory > MAX_RUN_HISTORY do
            table.remove(InstanceTrackerDB.runHistory)
        end

        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "GPH session stopped: " .. FormatTimeMedium(dur)
            .. " | " .. FormatGoldPlain(gold)
            .. " |cff44ff44 - Saved to Run Stats history|r"
        )
    else
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "GPH session stopped: " .. FormatTimeMedium(dur)
            .. " | " .. FormatGoldPlain(gold)
            .. " |cffaaaaaa - Nothing gained, not saved|r"
        )
    end

    gphSession = nil
    -- Save state (nil session)
    InstanceTrackerDB.gphSession = nil
    InstanceTrackerDB.gphBagBaseline = nil
    InstanceTrackerDB.gphItemsGained = nil

    -- Safe refresh: only if the Stats window is already open (prevents nil error)
    if statsFrame and statsFrame:IsShown() then
        if type(RefreshStatsUI) == "function" then
            RefreshStatsUI()
        end
    end
end
----------------------------------------------------------------------
-- Stats: run tracking helpers
----------------------------------------------------------------------
local function StartRun(name)
    currentRun = {
        name = name,
        enterTime = time(),
        goldCopper = 0,
        qualityCounts = {},
        items = {},
    }
    SnapshotBags()
    startingGold = GetMoney()
    -- Save state for persistence
    InstanceTrackerDB.currentRun = currentRun
    InstanceTrackerDB.bagBaseline = bagBaseline
    InstanceTrackerDB.itemsGained = itemsGained
    InstanceTrackerDB.startingGold = startingGold
    InstanceTrackerDB.currentZone = currentZone
    InstanceTrackerDB.isInInstance = isInInstance
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Stats tracking started for " .. ColorText(name, 1, 1, 0.6) .. "."
    )
end

local function FinalizeRun()
    if not currentRun then return end
    DiffBags()

    -- Gold earned = current money - starting money
    local goldEarned = GetMoney() - startingGold
    if goldEarned < 0 then goldEarned = 0 end
    currentRun.goldCopper = goldEarned

    local now = time()

    -- Convert items table to sorted list
    local itemList = {}
    for _, item in pairs(currentRun.items) do
        table.insert(itemList, {
            link = item.link, quality = item.quality,
            count = item.count, name = item.name,
        })
    end
    table.sort(itemList, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)

    local run = {
        name = currentRun.name,
        enterTime = currentRun.enterTime,
        exitTime = now,
        duration = now - currentRun.enterTime,
        goldCopper = currentRun.goldCopper,
        qualityCounts = currentRun.qualityCounts,
        items = itemList,
    }

    if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
    table.insert(InstanceTrackerDB.runHistory, 1, run)
    while #InstanceTrackerDB.runHistory > MAX_RUN_HISTORY do
        table.remove(InstanceTrackerDB.runHistory)
    end

    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Run complete: " .. ColorText(run.name, 1, 1, 0.6)
        .. " - " .. FormatTimeMedium(run.duration)
        .. " | " .. FormatGoldPlain(run.goldCopper)
    )

    -- Refresh stats window if it's open (prevents nil error)
    if statsFrame and statsFrame:IsShown() then
        if type(RefreshStatsUI) == "function" then
            RefreshStatsUI()
        end
    end

    currentRun = nil
    -- Clear saved state
    InstanceTrackerDB.currentRun = nil
    InstanceTrackerDB.bagBaseline = nil
    InstanceTrackerDB.itemsGained = nil
    InstanceTrackerDB.startingGold = nil
end

----------------------------------------------------------------------
-- Lockout cache
----------------------------------------------------------------------
local function UpdateLockoutCache()
    lockoutQueryTime = time()
    lockoutCache = {}
    local numSaved = GetNumSavedInstances()
    for i = 1, numSaved do
        local instName, instID, instReset, instDiff, locked, extended, mostsig, isRaid = GetSavedInstanceInfo(i)
        if instName then
            table.insert(lockoutCache, {
                name = instName, id = instID, resetAtQuery = instReset,
                diff = instDiff, locked = locked, extended = extended, isRaid = isRaid,
            })
        end
    end
end

----------------------------------------------------------------------
-- Forward declarations
----------------------------------------------------------------------
local RefreshUI
local RefreshStatsUI
local ShowItemDetail
local RemoveRunEntry
local RefreshGPHUI
local RefreshItemDetailLive

----------------------------------------------------------------------
-- Helpers: build run snapshots for ShowItemDetail (must be before first use)
----------------------------------------------------------------------
local function BuildCurrentRunSnapshot()
    if not currentRun then return nil end
    local itemList = {}
    for _, item in pairs(currentRun.items) do
        table.insert(itemList, {
            link = item.link, quality = item.quality,
            count = item.count, name = item.name,
        })
    end
    table.sort(itemList, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)
    return {
        name = currentRun.name,
        qualityCounts = currentRun.qualityCounts,
        items = itemList,
    }
end

local function BuildGPHSnapshot()
    if not gphSession then return nil end
    local itemList = {}
    for _, item in pairs(gphSession.items) do
        table.insert(itemList, {
            link = item.link, quality = item.quality,
            count = item.count, name = item.name,
        })
    end
    table.sort(itemList, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)
    return {
        name = "GPH Session",
        qualityCounts = gphSession.qualityCounts,
        items = itemList,
    }
end

----------------------------------------------------------------------
-- UI: Object pools
----------------------------------------------------------------------
local ROW_POOL, ROW_POOL_USED = {}, 0
local TEXT_POOL, TEXT_POOL_USED = {}, 0
local STATS_ROW_POOL, STATS_ROW_POOL_USED = {}, 0
local STATS_TEXT_POOL, STATS_TEXT_POOL_USED = {}, 0

local function ResetPools()
    for i = 1, ROW_POOL_USED do
        if ROW_POOL[i] then
            ROW_POOL[i]:Hide()
            if ROW_POOL[i].deleteBtn then ROW_POOL[i].deleteBtn:Hide() end
        end
    end
    ROW_POOL_USED = 0
    for i = 1, TEXT_POOL_USED do if TEXT_POOL[i] then TEXT_POOL[i]:Hide() end end
    TEXT_POOL_USED = 0
end

local function ResetStatsPools()
    for i = 1, STATS_ROW_POOL_USED do
        if STATS_ROW_POOL[i] then
            STATS_ROW_POOL[i]:Hide()
            STATS_ROW_POOL[i]:EnableMouse(false)
            if STATS_ROW_POOL[i].deleteBtn then STATS_ROW_POOL[i].deleteBtn:Hide() end
        end
    end
    STATS_ROW_POOL_USED = 0
    for i = 1, STATS_TEXT_POOL_USED do if STATS_TEXT_POOL[i] then STATS_TEXT_POOL[i]:Hide() end end
    STATS_TEXT_POOL_USED = 0
end

local function GetRow(parent, showDelete)
    ROW_POOL_USED = ROW_POOL_USED + 1
    local row = ROW_POOL[ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(SCROLL_CONTENT_WIDTH)
        row:SetHeight(16)
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
            AnchorTooltipRight(self)
            GameTooltip:AddLine("Remove this entry", 1, 0.4, 0.4)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")
            GameTooltip:Hide()
        end)
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

local function GetStatsRow(parent, withDelete)
    STATS_ROW_POOL_USED = STATS_ROW_POOL_USED + 1
    local row = STATS_ROW_POOL[STATS_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(SCROLL_CONTENT_WIDTH)
        row:SetHeight(16)

        -- Delete button (created once, shown when needed)
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
            AnchorTooltipRight(self)
            GameTooltip:AddLine("Remove this run", 1, 0.4, 0.4)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")
            GameTooltip:Hide()
        end)
        row.deleteBtn = delBtn

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        left:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        left:SetJustifyH("LEFT")
        row.left = left
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        right:SetJustifyH("RIGHT")
        row.right = right
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.08)
        hl:Hide()
        row.highlight = hl
        STATS_ROW_POOL[STATS_ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    row.left:SetText("")
    row.right:SetText("")
    row.highlight:Hide()
    row:EnableMouse(false)
    row:SetScript("OnMouseUp", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)

    if withDelete then
        row.deleteBtn:Show()
        row.left:SetPoint("LEFT", row.deleteBtn, "RIGHT", 2, 0)
    else
        row.deleteBtn:Hide()
        row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    end
    return row
end

local function GetStatsText(parent)
    STATS_TEXT_POOL_USED = STATS_TEXT_POOL_USED + 1
    local fs = STATS_TEXT_POOL[STATS_TEXT_POOL_USED]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        STATS_TEXT_POOL[STATS_TEXT_POOL_USED] = fs
    end
    fs:SetParent(parent)
    fs:ClearAllPoints()
    fs:Show()
    fs:SetText("")
    return fs
end

----------------------------------------------------------------------
-- Item Detail Popup
----------------------------------------------------------------------
local ITEM_BTN_POOL, ITEM_BTN_POOL_USED = {}, 0

local function ResetItemBtnPool()
    for i = 1, ITEM_BTN_POOL_USED do if ITEM_BTN_POOL[i] then ITEM_BTN_POOL[i]:Hide() end end
    ITEM_BTN_POOL_USED = 0
end

local function GetItemBtn(parent)
    ITEM_BTN_POOL_USED = ITEM_BTN_POOL_USED + 1
    local btn = ITEM_BTN_POOL[ITEM_BTN_POOL_USED]
    if not btn then
        btn = CreateFrame("Button", nil, parent)
        btn:SetWidth(SCROLL_CONTENT_WIDTH)
        btn:SetHeight(18)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16)
        icon:SetHeight(16)
        icon:SetPoint("LEFT", btn, "LEFT", 0, 0)
        btn.icon = icon
        local nameFs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        nameFs:SetPoint("RIGHT", btn, "RIGHT", -40, 0)
        nameFs:SetJustifyH("LEFT")
        btn.nameFs = nameFs
        local countFs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countFs:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
        countFs:SetJustifyH("RIGHT")
        btn.countFs = countFs
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.1)
        ITEM_BTN_POOL[ITEM_BTN_POOL_USED] = btn
    end
    btn:SetParent(parent)
    btn:Show()
    btn.itemLink = nil
    return btn
end

local function CreateItemDetailFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "InstanceTrackerItemDetailFrame", UIParent)
    f:SetWidth(340)
    f:SetHeight(400)
    f:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
    f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("HIGH")
    f.EXPANDED_HEIGHT = 400

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.15, 0.35, 0.6, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetTextColor(0.5, 0.8, 1, 1)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local qualLine = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qualLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -6)
    qualLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -6)
    qualLine:SetJustifyH("LEFT")
    f.qualLine = qualLine

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerItemScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", qualLine, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Collapse button (after scrollFrame/qualLine exist)
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:SetWidth(18)
    collapseBtn:SetHeight(18)
    collapseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    local collapseBg = collapseBtn:CreateTexture(nil, "BACKGROUND")
    collapseBg:SetAllPoints()
    collapseBtn.bg = collapseBg
    local collapseIcon = collapseBtn:CreateTexture(nil, "ARTWORK")
    collapseIcon:SetWidth(12)
    collapseIcon:SetHeight(12)
    collapseIcon:SetPoint("CENTER")
    collapseBtn.icon = collapseIcon
    if InstanceTrackerDB.itemDetailCollapsed == nil then InstanceTrackerDB.itemDetailCollapsed = false end
    local function UpdateItemDetailCollapse()
        if not f.scrollFrame then return end
        if InstanceTrackerDB.itemDetailCollapsed then
            collapseBg:SetTexture(0.2, 0.3, 0.15, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            f:SetHeight(150)
            f.scrollFrame:Hide()
            f.qualLine:Hide()
        else
            collapseBg:SetTexture(0.15, 0.25, 0.4, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
            f.qualLine:Show()
        end
    end
    UpdateItemDetailCollapse()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.itemDetailCollapsed = not InstanceTrackerDB.itemDetailCollapsed
        UpdateItemDetailCollapse()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.itemDetailCollapsed then self.bg:SetTexture(0.3, 0.45, 0.2, 0.8)
        else self.bg:SetTexture(0.25, 0.4, 0.6, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.itemDetailCollapsed and "Show Items" or "Hide Items", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateItemDetailCollapse(); GameTooltip:Hide() end)

    -- Live update when showing current run or GPH items (updates even when Stats/GPH window closed)
    local itemDetail_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        itemDetail_elapsed = itemDetail_elapsed + elapsed
        if itemDetail_elapsed >= 1 then
            itemDetail_elapsed = 0
            if self:IsShown() and self.liveSource then
                RefreshItemDetailLive()
            end
        end
    end)
    return f
end

ShowItemDetail = function(run, liveSource)
    if not itemDetailFrame then itemDetailFrame = CreateItemDetailFrame() end
    local f = itemDetailFrame
    f.title:SetText((run.name or "Unknown"))
    f.qualLine:SetText(FormatQualityCounts(run.qualityCounts))
    f.liveSource = liveSource or nil  -- "currentRun" or "gph" or nil
    ResetItemBtnPool()

    local items = run.items or {}
    local content = f.content
    local yOff = 4

    for _, item in ipairs(items) do
        local btn = GetItemBtn(content)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        btn.itemLink = item.link
        local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(item.link or "")
        btn.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        local qInfo = QUALITY_COLORS[item.quality] or QUALITY_COLORS[1]
        btn.nameFs:SetText("|cff" .. qInfo.hex .. (item.name or "Unknown") .. "|r")
        btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")

        btn:SetScript("OnClick", function(self)
            if IsShiftKeyDown() and self.itemLink then
                local chatBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                if not chatBox then
                    for ci = 1, NUM_CHAT_WINDOWS do
                        local eb = _G["ChatFrame" .. ci .. "EditBox"]
                        if eb and eb:IsVisible() then chatBox = eb; break end
                    end
                end
                if chatBox then chatBox:Insert(self.itemLink) end
            end
        end)
        btn:SetScript("OnEnter", function(self)
            if self.itemLink then
                AnchorTooltipRight(self)
                local lp = self.itemLink:match("|H(item:[^|]+)|h")
                if lp then GameTooltip:SetHyperlink(lp) end
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        yOff = yOff + 18
    end

    if #items == 0 then
        yOff = yOff + 4
    end

    content:SetHeight(yOff + 8)

    -- Anchor next to stats window if open, or next to GPH frame
    if statsFrame and statsFrame:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", statsFrame, "TOPRIGHT", 4, 0)
    elseif gphFrame and gphFrame:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
    end
    f:Show()
end

----------------------------------------------------------------------
-- Live refresh for item detail (called every 1s from OnUpdate)
----------------------------------------------------------------------
RefreshItemDetailLive = function()
    if not itemDetailFrame or not itemDetailFrame:IsShown() or not itemDetailFrame.liveSource then return end
    local src = itemDetailFrame.liveSource
    local snap = nil
    if src == "currentRun" then
        snap = BuildCurrentRunSnapshot()
    elseif src == "gph" and gphSession then
        snap = BuildGPHSnapshot()
    end
    if snap then
        ShowItemDetail(snap, src)
    end
end

----------------------------------------------------------------------
-- Remove a single run from history
----------------------------------------------------------------------
RemoveRunEntry = function(index)
    local history = InstanceTrackerDB.runHistory or {}
    if index >= 1 and index <= #history then
        table.remove(history, index)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed run #" .. index .. "."
        )
        RefreshStatsUI()
    end
end

----------------------------------------------------------------------
-- Confirmation dialog for clearing history
----------------------------------------------------------------------
StaticPopupDialogs["INSTANCETRACKER_CLEAR_HISTORY"] = {
    text = "Are you sure you want to clear ALL run history?\nThis cannot be undone.",
    button1 = "Yes, Clear",
    button2 = "Cancel",
    OnAccept = function()
        InstanceTrackerDB.runHistory = {}
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Run history cleared."
        )
        RefreshStatsUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- delete all quality items popup
StaticPopupDialogs["GPH_DELETE_QUALITY"] = {
    text = "Permanently delete all %d %s items?\nThis cannot be undone!",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if data and data.quality then
            DeleteAllOfQuality(data.quality)
        end
        if data and data.quality then
            gphPendingQuality[data.quality] = nil
        end
        RefreshGPHUI()
    end,
    OnCancel = function(self, data)
        if data and data.quality then
            gphPendingQuality[data.quality] = nil
        end
        RefreshGPHUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

----------------------------------------------------------------------
-- Stats Window
----------------------------------------------------------------------
local function CreateStatsFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "InstanceTrackerStatsFrame", UIParent)
    f:SetWidth(340)
    f:SetHeight(400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
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
    f:SetFrameLevel(10)
    f.EXPANDED_HEIGHT = 400

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.15, 0.35, 0.6, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("Ledger")
    title:SetTextColor(0.5, 0.8, 1, 1)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Scroll frame (must exist before collapse button)
    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerStatsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Collapse button
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:SetWidth(18)
    collapseBtn:SetHeight(18)
    collapseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    local collapseBg = collapseBtn:CreateTexture(nil, "BACKGROUND")
    collapseBg:SetAllPoints()
    collapseBtn.bg = collapseBg
    local collapseIcon = collapseBtn:CreateTexture(nil, "ARTWORK")
    collapseIcon:SetWidth(12)
    collapseIcon:SetHeight(12)
    collapseIcon:SetPoint("CENTER")
    collapseBtn.icon = collapseIcon
    if InstanceTrackerDB.statsCollapsed == nil then InstanceTrackerDB.statsCollapsed = false end
    local function UpdateStatsCollapse()
        if not f.scrollFrame then return end
        if InstanceTrackerDB.statsCollapsed then
            collapseBg:SetTexture(0.2, 0.3, 0.15, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            f:SetHeight(150)
            -- Keep scrollFrame visible, RefreshStatsUI will hide history section
            f.scrollFrame:Show()
        else
            collapseBg:SetTexture(0.15, 0.25, 0.4, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
        end
    end
    UpdateStatsCollapse()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.statsCollapsed = not InstanceTrackerDB.statsCollapsed
        UpdateStatsCollapse()
        RefreshStatsUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.statsCollapsed then self.bg:SetTexture(0.3, 0.45, 0.2, 0.8)
        else self.bg:SetTexture(0.25, 0.4, 0.6, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.statsCollapsed and "Show Run Stats" or "Hide Run Stats", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateStatsCollapse(); GameTooltip:Hide() end)

    -- Clear button with confirmation
    local clearBtn = CreateFrame("Button", nil, f)
    clearBtn:SetWidth(45)
    clearBtn:SetHeight(18)
    clearBtn:SetPoint("RIGHT", collapseBtn, "LEFT", -2, 0)
    local clearBg = clearBtn:CreateTexture(nil, "BACKGROUND")
    clearBg:SetAllPoints()
    clearBg:SetTexture(0.3, 0.15, 0.1, 0.7)
    clearBtn.bg = clearBg
    local clearText = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearText:SetPoint("CENTER")
    clearText:SetText("|cffff8844Clear|r")
    clearBtn.label = clearText
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("INSTANCETRACKER_CLEAR_HISTORY")
    end)
    clearBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
        self.label:SetText("|cffffaa66Clear|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Clear All Run History", 1, 0.6, 0.2)
        GameTooltip:AddLine("Will ask for confirmation first.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
        self.label:SetText("|cffff8844Clear|r")
        GameTooltip:Hide()
    end)

    local stats_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        stats_elapsed = stats_elapsed + elapsed
        if stats_elapsed >= 1 then
            stats_elapsed = 0
            RefreshStatsUI()
            RefreshItemDetailLive()
        end
    end)
    return f
end

----------------------------------------------------------------------
-- Refresh stats window
----------------------------------------------------------------------
RefreshStatsUI = function()
    if not statsFrame or not statsFrame:IsShown() then return end
    ResetStatsPools()

    local content = statsFrame.content
    local yOff = 0
    local now = time()

    -- Current run (live)
    local hdr = GetStatsText(content)
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)

    if currentRun then
        local dur = now - currentRun.enterTime
        local liveGold = GetMoney() - startingGold
        if liveGold < 0 then liveGold = 0 end

        hdr:SetText("|cff80c0ff--- Current: |r|cffffffcc" .. currentRun.name .. "|r |cff80c0ff---|r")
        yOff = yOff + 18

        -- Duration + time (left) and gold (right) on a single row
        local rDur = GetStatsRow(content, false)
        rDur:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        local durLabel = "|cffccccccDuration:|r |cffffffff" .. FormatTimeMedium(dur) .. "|r"
        local timeStr = "|cff666666" .. FormatDateTime(currentRun.enterTime) .. "|r"
        rDur.left:SetText(durLabel .. "  " .. timeStr)
        rDur.right:SetText(FormatGold(liveGold))
        yOff = yOff + 15

        -- Items (clickable) on its own row so quality text never overlaps gold
        local rItems = GetStatsRow(content, false)
        rItems:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        rItems.right:SetText("")

        local qcText = FormatQualityCounts(currentRun.qualityCounts)
        if qcText == "|cff555555-|r" or qcText == "" then
            qcText = "|cff888888None|r"
        end

        rItems.left:SetText("|cffccccccItems:|r " .. qcText)

        rItems.highlight:Show()
        rItems:EnableMouse(true)
        rItems:SetScript("OnMouseUp", function()
            local snap = BuildCurrentRunSnapshot()
            if snap then ShowItemDetail(snap, "currentRun") end
        end)
        rItems:SetScript("OnEnter", function(self)
            AnchorTooltipRight(self)
            GameTooltip:AddLine("Click to view items", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        rItems:SetScript("OnLeave", function() GameTooltip:Hide() end)
        yOff = yOff + 15
    else
        hdr:SetText("|cff80c0ff--- Current Run ---|r")
        yOff = yOff + 18
        local noRun = GetStatsText(content)
        noRun:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        noRun:SetText("|cff888888Not in an instance.|r")
        yOff = yOff + 14
    end

    yOff = yOff + 10

    -- If collapsed, hide history section
    if InstanceTrackerDB.statsCollapsed then
        content:SetHeight(yOff)
        return
    end

    -- Run history
    local history = InstanceTrackerDB.runHistory or {}
    local hdr2 = GetStatsText(content)
    hdr2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    hdr2:SetText("|cff80c0ff--- History (" .. #history .. "/" .. MAX_RUN_HISTORY .. ") ---|r")
    yOff = yOff + 18

    if #history == 0 then
        local noHist = GetStatsText(content)
        noHist:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        noHist:SetText("|cff888888No runs recorded yet.|r")
        yOff = yOff + 14
    else
        for i, run in ipairs(history) do
            local dur = run.duration or 0

            -- Line 1: [x] index, name, duration, date/time
            local row1 = GetStatsRow(content, true)
            row1:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            row1.left:SetText("|cff666666" .. i .. ".|r  |cffffffcc" .. (run.name or "?") .. "|r")
            local dateStr = (run.enterTime and FormatDateTime(run.enterTime) ~= "" and ("  |cff666666" .. FormatDateTime(run.enterTime) .. "|r")) or ""
            row1.right:SetText("|cffaaaaaa" .. FormatTimeMedium(dur) .. "|r" .. dateStr)
            local delIdx = i
            row1.deleteBtn:SetScript("OnClick", function() RemoveRunEntry(delIdx) end)
            yOff = yOff + 14

            -- Line 2: items quality counts + gold on right (clickable); constrain left so it doesn't overlap gold
            local row2 = GetStatsRow(content, false)
            row2:SetPoint("TOPLEFT", content, "TOPLEFT", 18, -yOff)
            row2.left:ClearAllPoints()
            row2.left:SetPoint("LEFT", row2, "LEFT", 0, 0)
            row2.left:SetPoint("RIGHT", row2, "RIGHT", -72, 0)

            local qcText = FormatQualityCounts(run.qualityCounts)
            if qcText == "|cff555555-|r" or qcText == "" then
                qcText = "|cff888888No items|r"
            end

            row2.left:SetText(qcText)
            row2.right:SetText(FormatGold(run.goldCopper))

            row2.highlight:Show()
            row2:EnableMouse(true)
            local runRef = run
            row2:SetScript("OnMouseUp", function() ShowItemDetail(runRef) end)
            row2:SetScript("OnEnter", function(self)
                AnchorTooltipRight(self)
                GameTooltip:AddLine("Click to view items", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
            row2:SetScript("OnLeave", function() GameTooltip:Hide() end)
            yOff = yOff + 16

            yOff = yOff + 4  -- small gap between runs
        end
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
end
----------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- GPH Session Window (pooled rows, item list, Use selected)
-- ---------------------------------------------------------------------------
local GPH_ROW_POOL, GPH_ROW_POOL_USED = {}, 0
local GPH_TEXT_POOL, GPH_TEXT_POOL_USED = {}, 0
local GPH_ITEM_POOL, GPH_ITEM_POOL_USED = {}, 0

local function ResetGPHPools()
    for i = 1, GPH_ROW_POOL_USED do
        if GPH_ROW_POOL[i] then
            GPH_ROW_POOL[i]:Hide()
            GPH_ROW_POOL[i]:EnableMouse(false)
            if GPH_ROW_POOL[i].deleteBtn then GPH_ROW_POOL[i].deleteBtn:Hide() end
        end
    end
    GPH_ROW_POOL_USED = 0
    for i = 1, GPH_TEXT_POOL_USED do if GPH_TEXT_POOL[i] then GPH_TEXT_POOL[i]:Hide() end end
    GPH_TEXT_POOL_USED = 0
    for i = 1, GPH_ITEM_POOL_USED do
        if GPH_ITEM_POOL[i] then
            GPH_ITEM_POOL[i]:Hide()
            if GPH_ITEM_POOL[i].deleteBtn then GPH_ITEM_POOL[i].deleteBtn:Hide() end
            if GPH_ITEM_POOL[i].clickArea then GPH_ITEM_POOL[i].clickArea:Hide() end
        end
    end
    GPH_ITEM_POOL_USED = 0
end

local function GetGPHRow(parent, withDelete)
    GPH_ROW_POOL_USED = GPH_ROW_POOL_USED + 1
    local row = GPH_ROW_POOL[GPH_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(SCROLL_CONTENT_WIDTH)
        row:SetHeight(16)

        -- Delete button (created once, shown when needed)
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
            AnchorTooltipRight(self)
            GameTooltip:AddLine("Remove this entry", 1, 0.4, 0.4)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")
            GameTooltip:Hide()
        end)
        row.deleteBtn = delBtn

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        left:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        left:SetJustifyH("LEFT")
        row.left = left
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        right:SetJustifyH("RIGHT")
        row.right = right
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.08)
        hl:Hide()
        row.highlight = hl
        GPH_ROW_POOL[GPH_ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    row.left:SetText("")
    row.right:SetText("")
    row.highlight:Hide()
    row:EnableMouse(false)
    row:SetScript("OnMouseUp", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)

    if withDelete then
        row.deleteBtn:Show()
        row.left:SetPoint("LEFT", row.deleteBtn, "RIGHT", 2, 0)
    else
        row.deleteBtn:Hide()
        row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    end
    return row
end

local function GetGPHText(parent)
    GPH_TEXT_POOL_USED = GPH_TEXT_POOL_USED + 1
    local fs = GPH_TEXT_POOL[GPH_TEXT_POOL_USED]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        GPH_TEXT_POOL[GPH_TEXT_POOL_USED] = fs
    end
    fs:SetParent(parent)
    fs:ClearAllPoints()
    fs:Show()
    fs:SetText("")
    return fs
end

local function GetGPHItemBtn(parent)
    GPH_ITEM_POOL_USED = GPH_ITEM_POOL_USED + 1
    local btn = GPH_ITEM_POOL[GPH_ITEM_POOL_USED]
    if not btn then
        btn = CreateFrame("Frame", nil, parent)
        btn:SetWidth(SCROLL_CONTENT_WIDTH)
        btn:SetHeight(18)

        -- Delete button
        local delBtn = CreateFrame("Button", nil, btn)
        delBtn:SetWidth(14)
        delBtn:SetHeight(14)
        delBtn:SetPoint("LEFT", btn, "LEFT", 0, 0)
        delBtn:SetNormalFontObject(GameFontNormalSmall)
        delBtn:SetHighlightFontObject(GameFontHighlightSmall)
        delBtn:SetText("|cffff4444x|r")
        delBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        delBtn:SetScript("OnEnter", function(self)
            self:SetText("|cffff8888x|r")  -- brighter red on hover
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")   -- normal red
        end)
        btn.deleteBtn = delBtn

        -- Clickable area for tooltip/shift-click (no Use button - secure child in ScrollFrame can hide list on this client)
        local clickArea = CreateFrame("Button", nil, btn)
        clickArea:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        clickArea:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        clickArea:SetHeight(18)
        btn.clickArea = clickArea

        -- Persistent selection highlight (independent of mouse-over)
        local sel = clickArea:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        sel:SetTexture(1, 1, 1, 0.06)
        sel:Hide()
        btn.selectedTex = sel

        local icon = clickArea:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16)
        icon:SetHeight(16)
        icon:SetPoint("LEFT", clickArea, "LEFT", 0, 0)
        btn.icon = icon
        local nameFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        nameFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
        nameFs:SetJustifyH("LEFT")
        btn.nameFs = nameFs
        local countFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
        countFs:SetJustifyH("RIGHT")
        btn.countFs = countFs
        local hl = clickArea:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.1)
        GPH_ITEM_POOL[GPH_ITEM_POOL_USED] = btn
    end
    btn:SetParent(parent)
    btn:Show()
    btn.deleteBtn:Show()
    btn.clickArea:Show()
    btn.itemLink = nil
    return btn
end

StaticPopupDialogs["INSTANCETRACKER_RESET_GPH"] = {
    text = "Are you sure you want to reset the GPH session?\nThis will clear all data and restart the timer.",
    button1 = "Yes, Reset",
    button2 = "Cancel",
    OnAccept = function()
        if gphSession then
            -- Reset clears everything and stops the session (button returns to "Start")
            gphSession = nil
            gphBagBaseline = {}
            gphItemsGained = {}
            AddonPrint(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session reset."
            )
            -- Save state (nil session)
            InstanceTrackerDB.gphSession = nil
            InstanceTrackerDB.gphBagBaseline = nil
            InstanceTrackerDB.gphItemsGained = nil
            -- Update toggle button to show "Start" (even if frame not shown)
            if gphFrame and gphFrame.updateToggle then
                gphFrame.updateToggle()
            end
            -- Refresh UI if frame is shown
            if gphFrame and gphFrame:IsShown() then
                RefreshGPHUI()
            end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

--- Create the GPH window (timer, items list, sort, Use selected button). Starts hidden.
local function CreateGPHFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "InstanceTrackerGPHFrame", UIParent)
    f:SetWidth(340)
    f:SetHeight(400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
    f:Hide()  -- start hidden so first /fit gph or first GPH button click actually shows it (toggle was hiding it immediately)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(10)
    f.EXPANDED_HEIGHT = 400

    -- ESC should only clear pending rarity deletes while one is active,
    -- then keyboard is disabled again so normal game input is not blocked.
    f:EnableKeyboard(false)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and gphPendingQuality then
            local hadPending = false
            for q in pairs(gphPendingQuality) do
                gphPendingQuality[q] = nil
                hadPending = true
            end
            if hadPending then
                RefreshGPHUI()
                self:EnableKeyboard(false)
            end
        end
    end)

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("Gold Per Hour")
    title:SetTextColor(1, 0.85, 0.4, 1)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Status text and scroll (must exist before collapse button)
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -8)
    statusText:SetJustifyH("LEFT")
    f.statusText = statusText

    -- Sort button: cycle rarity (default) -> auction value -> vendor price (right-aligned in Timer/Gold/GPH row)
    local sortBtn = CreateFrame("Button", nil, f)
    sortBtn:SetWidth(36)
    sortBtn:SetHeight(16)
    sortBtn:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -8)
    statusText:SetPoint("TOPRIGHT", sortBtn, "TOPLEFT", -4, 0)
    local sortLabel = sortBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("CENTER")
    sortBtn.label = sortLabel
    f.gphSortBtn = sortBtn
    local function UpdateGPHSortLabel()
        if InstanceTrackerDB.gphSortMode == nil then InstanceTrackerDB.gphSortMode = "rarity" end
        -- Normalize any old/unsupported value (including legacy \"auction\") to a supported mode
        if InstanceTrackerDB.gphSortMode ~= "vendor" and InstanceTrackerDB.gphSortMode ~= "rarity" then
            InstanceTrackerDB.gphSortMode = "rarity"
        end
        if InstanceTrackerDB.gphSortMode == "vendor" then
            sortLabel:SetText("|cffaaddffVendor|r")
        else
            sortLabel:SetText("|cffaaddffRarity|r")
        end
    end
    UpdateGPHSortLabel()
    sortBtn:SetScript("OnClick", function()
        -- Cycle only between Rarity and Vendor (auction sort removed: too unreliable/inconsistent)
        if InstanceTrackerDB.gphSortMode == "rarity" then
            InstanceTrackerDB.gphSortMode = "vendor"
        else
            InstanceTrackerDB.gphSortMode = "rarity"
        end
        UpdateGPHSortLabel()
        RefreshGPHUI()
    end)
    sortBtn:SetScript("OnEnter", function(self)
        AnchorTooltipRight(self)
        local mode = InstanceTrackerDB.gphSortMode or "rarity"
        if mode == "vendor" then
            GameTooltip:AddLine("Sorting by vendor price (highest first)", 0.7, 0.8, 1)
        else
            GameTooltip:AddLine("Sorting by rarity (highest first)", 0.7, 0.8, 1)
        end
        GameTooltip:AddLine("Click to cycle sort mode", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    sortBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -6)
    sep:SetPoint("TOPRIGHT", statusText, "BOTTOMRIGHT", 0, -6)
    sep:SetTexture(1, 1, 1, 0.15)
    f.gphSep = sep

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerGPHScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 28)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Bottom bar: "Use selected" secure button (outside scroll so it doesn't break the list)
    f.gphSelectedItemId = nil
    local useBar = CreateFrame("Frame", nil, f)
    useBar:SetHeight(22)
    useBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 6)
    useBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    f.gphUseBar = useBar
    local useBtnOk, useBtn = pcall(CreateFrame, "Button", nil, useBar, "SecureActionButtonTemplate")
    if useBtnOk and useBtn then
        useBtn:SetWidth(70)
        useBtn:SetHeight(18)
        useBtn:SetPoint("CENTER", useBar, "CENTER", 0, 0)
        local useBg = useBtn:CreateTexture(nil, "BACKGROUND")
        useBg:SetAllPoints()
        useBg:SetTexture(0.1, 0.3, 0.15, 0.7)
        useBtn.bg = useBg
        useBtn:SetNormalFontObject(GameFontNormalSmall)
        useBtn:SetHighlightFontObject(GameFontHighlightSmall)
        useBtn:SetText("|cff66dd88Use|r")
        useBtn:RegisterForClicks("LeftButtonUp")
        useBtn:Hide()
        f.gphUseBtn = useBtn
    end

    -- Collapse button
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:SetWidth(18)
    collapseBtn:SetHeight(18)
    collapseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    local collapseBg = collapseBtn:CreateTexture(nil, "BACKGROUND")
    collapseBg:SetAllPoints()
    collapseBtn.bg = collapseBg
    local collapseIcon = collapseBtn:CreateTexture(nil, "ARTWORK")
    collapseIcon:SetWidth(12)
    collapseIcon:SetHeight(12)
    collapseIcon:SetPoint("CENTER")
    collapseBtn.icon = collapseIcon
    if InstanceTrackerDB.gphCollapsed == nil then InstanceTrackerDB.gphCollapsed = true end
    local function UpdateGPHCollapse()
        if not f.scrollFrame then return end
        if InstanceTrackerDB.gphCollapsed then
            collapseBg:SetTexture(0.2, 0.3, 0.15, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            f:SetHeight(70)
            f.statusText:Show()
            f.gphSep:Show()
            if f.gphSortBtn then f.gphSortBtn:Hide() end
            f.scrollFrame:Hide()
            if f.gphUseBar then f.gphUseBar:Hide() end
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.statusText:Show()
            f.gphSep:Show()
            if f.gphSortBtn then f.gphSortBtn:Show() end
            f.scrollFrame:Show()
            if f.gphUseBar then f.gphUseBar:Show() end
        end
    end
    UpdateGPHCollapse()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.gphCollapsed = not InstanceTrackerDB.gphCollapsed
        UpdateGPHCollapse()
        RefreshGPHUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.gphCollapsed then self.bg:SetTexture(0.3, 0.45, 0.2, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.gphCollapsed and "Show GPH Session" or "Hide GPH Session", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateGPHCollapse(); GameTooltip:Hide() end)

    -- Start/Stop button
    local toggleBtn = CreateFrame("Button", nil, f)
    toggleBtn:SetWidth(50)
    toggleBtn:SetHeight(18)
    toggleBtn:SetPoint("RIGHT", collapseBtn, "LEFT", -2, 0)
    local toggleBg = toggleBtn:CreateTexture(nil, "BACKGROUND")
    toggleBg:SetAllPoints()
    toggleBtn.bg = toggleBg
    local toggleText = toggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggleText:SetPoint("CENTER")
    toggleBtn.label = toggleText
    f.toggleBtn = toggleBtn

    -- Reset session button
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:SetWidth(45)
    resetBtn:SetHeight(18)
    resetBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -2, 0)
    local resetBg = resetBtn:CreateTexture(nil, "BACKGROUND")
    resetBg:SetAllPoints()
    resetBg:SetTexture(0.25, 0.15, 0.1, 0.7)
    resetBtn.bg = resetBg
    local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetText:SetPoint("CENTER")
    resetText:SetText("|cffff8844Reset|r")
    resetBtn.label = resetText
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("INSTANCETRACKER_RESET_GPH")
    end)
    resetBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.4, 0.25, 0.1, 0.8)
        self.label:SetText("|cffffaa66Reset|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset Session", 1, 0.6, 0.2)
        GameTooltip:AddLine("Clears all data and restarts the timer.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Session must be active.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.25, 0.15, 0.1, 0.7)
        self.label:SetText("|cffff8844Reset|r")
        GameTooltip:Hide()
    end)

    local function UpdateToggleBtn()
        if gphSession then
            toggleBtn.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
            toggleBtn.label:SetText("|cffff8844Stop|r")
        else
            toggleBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7)
            toggleBtn.label:SetText("|cff66dd88Start|r")
        end
    end
    f.updateToggle = UpdateToggleBtn
    UpdateToggleBtn()

    toggleBtn:SetScript("OnClick", function()
        if gphSession then
            StopGPHSession()
        else
            StartGPHSession()
        end
        UpdateToggleBtn()
        RefreshGPHUI()
    end)
    toggleBtn:SetScript("OnEnter", function(self)
        if gphSession then
            self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
            self.label:SetText("|cffffaa66Stop|r")
        else
            self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
            self.label:SetText("|cff88ffaaStart|r")
        end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if gphSession then
            GameTooltip:AddLine("Stop GPH Session", 1, 0.6, 0.2)
        else
            GameTooltip:AddLine("Start GPH Session", 0.4, 0.9, 0.5)
            GameTooltip:AddLine("Tracks gold/hr and loot", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("from anywhere - not just dungeons.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    toggleBtn:SetScript("OnLeave", function() UpdateToggleBtn(); GameTooltip:Hide() end)

    local gph_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        gph_elapsed = gph_elapsed + elapsed
        if gph_elapsed >= 1 then
            gph_elapsed = 0
            RefreshGPHUI()
            RefreshItemDetailLive()
        end
    end)

    return f
end

--- Rebuild GPH window: header, item list, sort, selection highlight, Use button.
RefreshGPHUI = function()
    if not gphFrame or not gphFrame:IsShown() then return end
    local poolOk, poolErr = pcall(ResetGPHPools)
    if not poolOk then
        AddonPrint("[Fugazi] GPH ResetGPHPools error: " .. tostring(poolErr))
        return
    end

    -- Red border when 3 or fewer free bag slots
    do
        local totalSlots, usedSlots = 0, 0
        for bag = 0, 4 do
            local n = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
            totalSlots = totalSlots + n
            for slot = 1, n do
                if GetContainerItemLink(bag, slot) then usedSlots = usedSlots + 1 end
            end
        end
        local freeSlots = totalSlots - usedSlots
        if freeSlots <= 3 then
            gphFrame:SetBackdropBorderColor(1, 0.2, 0.2, 0.9)
        else
            gphFrame:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
        end
    end

    local refreshOk, refreshErr = pcall(function()
    local content = gphFrame.content
    local now = time()

    if content.headerElements then
        for _, el in ipairs(content.headerElements) do
            el:ClearAllPoints()
            el:Hide()
        end
        wipe(content.headerElements)
    end
    content.headerElements = content.headerElements or {}

    if not gphSession then
        gphFrame.statusText:SetText("|cff888888No active session. Click Start to begin.|r")
        gphFrame.updateToggle()
    else
        gphFrame.updateToggle()
        local dur = now - gphSession.startTime
        local liveGold = GetMoney() - gphSession.startGold
        if liveGold < 0 then liveGold = 0 end
        local gph = dur > 0 and (liveGold / (dur / 3600)) or 0
        gphFrame.statusText:SetText(
            "|cffdaa520Timer:|r |cffffffff" .. FormatTimeMedium(dur) .. "|r"
            .. "   |cffdaa520Gold:|r " .. FormatGold(liveGold)
            .. "   |cffdaa520GPH:|r " .. FormatGold(math.floor(gph))
        )
    end

    local yOff = 0

    local headerY = -yOff
    local xOffset = 4

    local itemsLabel = GetGPHText(content)
    itemsLabel:ClearAllPoints()
    itemsLabel:SetPoint("TOPLEFT", content, "TOPLEFT", xOffset, headerY)
    itemsLabel:SetText("|cffdaa520Items:|r ")
    itemsLabel:Show()
    table.insert(content.headerElements, itemsLabel)
    xOffset = xOffset + itemsLabel:GetStringWidth() + 15

    gphPendingQuality = gphPendingQuality or {}
    for q = 0, 5 do
        if gphPendingQuality[q] and (now - gphPendingQuality[q]) > 5 then
            gphPendingQuality[q] = nil
        end
    end

    local currentBags = ScanBags()
    local liveQualityCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
    for itemId, cnt in pairs(currentBags) do
        local link = itemLinksCache[itemId]
        if link then
            local _, _, q = GetItemInfo(link)
            q = q or 0
            liveQualityCounts[q] = liveQualityCounts[q] + cnt
        end
    end

    local hasAny = false
    local anyPendingQuality = false
    content.qualityButtons = content.qualityButtons or {}

    -- First collect which qualities we actually need to show (0–4 only)
    local shownQualities = {}
    for q = 0, 4 do
        if liveQualityCounts[q] and liveQualityCounts[q] > 0 then
            table.insert(shownQualities, q)
        end
    end

    local numShown = #shownQualities
    if numShown > 0 then
        hasAny = true
        local availableWidth = content:GetWidth() - xOffset - 8
        if availableWidth < 40 * numShown then availableWidth = 40 * numShown end
        local spacing = 10
        local slotWidth = math.floor((availableWidth - spacing * (numShown - 1)) / numShown)
        if slotWidth < 40 then slotWidth = 40 end

        local totalUsed = slotWidth * numShown + spacing * (numShown - 1)
        local extra = availableWidth - totalUsed
        if extra > 0 then
            xOffset = xOffset + math.floor(extra / 2)
        end

        for i, q in ipairs(shownQualities) do
            local count = liveQualityCounts[q] or 0
            local info = QUALITY_COLORS[q] or QUALITY_COLORS[1]
            local labelText = count .. " " .. info.label

            local qualBtn = content.qualityButtons[q]
            if not qualBtn then
                qualBtn = CreateFrame("Button", nil, content)
                qualBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                content.qualityButtons[q] = qualBtn
            end

            local fs = qualBtn.fs
            if not fs then
                fs = qualBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(false)
                qualBtn.fs = fs
            end

            if gphPendingQuality[q] then
                anyPendingQuality = true
                fs:SetText("|cffff0000Delete|r")
            else
                fs:SetText("|cff" .. info.hex .. labelText .. "|r")
            end

            qualBtn:SetWidth(slotWidth)
            qualBtn:SetHeight(16)

            qualBtn.quality = q
            qualBtn.currentCount = count  -- live count for popup
            qualBtn.label = info.label
            qualBtn:Show()

            qualBtn:SetScript("OnClick", function(self, button)
                -- Right-click: cancel any pending delete state (like pressing Escape)
                if button == "RightButton" then
                    for qKey in pairs(gphPendingQuality) do
                        gphPendingQuality[qKey] = nil
                    end
                    RefreshGPHUI()
                    return
                end

                local currentTime = time()

                -- Only allow ONE pending quality at a time to avoid any lingering/red text behind others.
        for qKey in pairs(gphPendingQuality) do
                    if qKey ~= self.quality then
                        gphPendingQuality[qKey] = nil
                    end
                end

                if gphPendingQuality[self.quality] and (currentTime - gphPendingQuality[self.quality]) <= 5 then
                    -- SECOND CLICK: show confirmation popup with live count
                    if self.currentCount > 0 then
                        StaticPopup_Show("GPH_DELETE_QUALITY", self.currentCount, self.label, {quality = self.quality})
                    end
                    gphPendingQuality[self.quality] = nil
                    RefreshGPHUI()
                else
                    -- FIRST CLICK: set this quality as the only pending one
                    gphPendingQuality[self.quality] = currentTime
                    RefreshGPHUI()
                end
            end)

            qualBtn:SetScript("OnEnter", nil)
            qualBtn:SetScript("OnLeave", nil)

            qualBtn:ClearAllPoints()
            qualBtn:SetPoint("TOPLEFT", content, "TOPLEFT", xOffset, headerY)

            table.insert(content.headerElements, qualBtn)
            xOffset = xOffset + slotWidth + spacing
        end
    end

    if gphFrame then
        gphFrame:EnableKeyboard(anyPendingQuality)
    end

    if not hasAny then
        local noneText = GetGPHText(content)
        noneText:ClearAllPoints()
        noneText:SetPoint("TOPLEFT", content, "TOPLEFT", xOffset, headerY)
        noneText:SetText("|cff888888None|r")
        noneText:Show()
        table.insert(content.headerElements, noneText)
    end

    yOff = yOff + 16
    yOff = yOff + 2
    local itemList = {}
    for itemId, cnt in pairs(currentBags) do
        local link = itemLinksCache[itemId]
        if link then
            local name, _, quality, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(link)
            quality = quality or 0
            name = name or "Unknown"
            sellPrice = sellPrice or 0
            table.insert(itemList, {
                link = link,
                quality = quality,
                count = cnt,
                name = name,
                sellPrice = sellPrice,
            })
        end
    end
    local sortMode = InstanceTrackerDB.gphSortMode or "rarity"
    if sortMode == "vendor" then
        table.sort(itemList, function(a, b)
            if a.sellPrice ~= b.sellPrice then return (a.sellPrice or 0) > (b.sellPrice or 0) end
            if a.quality ~= b.quality then return a.quality > b.quality end
            return a.name < b.name
        end)
    else
        table.sort(itemList, function(a, b)
            if a.quality ~= b.quality then return a.quality > b.quality end
            return a.name < b.name
        end)
    end

    if #itemList == 0 then
        local noItems = GetGPHText(content)
        noItems:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        noItems:SetText("|cff555555No items yet.|r")
        yOff = yOff + 14
        -- Nothing selectable, so clear selection and hide Use button.
        if gphFrame and gphFrame.gphUseBtn then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphUseBtn:Hide()
        end
    else
        local selectedStillExists = false
        for idx, item in ipairs(itemList) do
            local rowOk, rowErr = pcall(function()
            local btn = GetGPHItemBtn(content)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            btn.itemLink = item.link
            local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(item.link or "")
            btn.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            local qInfo = QUALITY_COLORS[item.quality] or QUALITY_COLORS[1]
            btn.nameFs:SetText("|cff" .. qInfo.hex .. (item.name or "Unknown") .. "|r")
            btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")

            -- Double-click [x] to delete from bags (first click = pending, second = delete, NO subtract from tracking)
            local itemId = nil
            if item.link then itemId = tonumber(item.link:match("item:(%d+)")) end
            local capturedId = itemId
            local capturedCount = item.count

            -- Selected-row highlight: keep the currently selected item visually marked
            if gphFrame and gphFrame.gphSelectedItemId and capturedId == gphFrame.gphSelectedItemId then
                selectedStillExists = true
                if btn.selectedTex then btn.selectedTex:Show() end
            else
                if btn.selectedTex then btn.selectedTex:Hide() end
            end

            -- Clean up expired pending deletes (older than 5 seconds)
            if gphPendingDelete[capturedId] and (now - (gphPendingDelete[capturedId] or 0)) > 5 then
                gphPendingDelete[capturedId] = nil
            end

            -- Set button appearance based on pending state
            if gphPendingDelete[capturedId] then
                btn.deleteBtn:SetText("|cffff0000!!|r")  -- bright red !! when pending
            else
                btn.deleteBtn:SetText("|cffff4444x|r")   -- normal red x
            end

            btn.deleteBtn:SetScript("OnClick", function()
                local currentTime = time()
                if capturedId then
                    if gphPendingDelete[capturedId] and (currentTime - gphPendingDelete[capturedId]) <= 5 then
                        -- SECOND CLICK: confirmed delete from bags ONLY (NO subtract from gphSession tracking)
                        DeleteGPHItem(capturedId, capturedCount)
                        gphPendingDelete[capturedId] = nil
                        RefreshGPHUI()
                    else
                        -- FIRST CLICK: set pending (5-second window)
                        gphPendingDelete[capturedId] = currentTime
                        RefreshGPHUI()  -- immediate visual feedback (changes to !!)
                    end
                end
            end)

            btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn.clickArea:SetScript("OnClick", function(self, button)
                -- Shift-click: open chat if needed, insert item link
                if IsShiftKeyDown() and item.link then
                    local chatBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                    if not chatBox then
                        if ChatEdit_ActivateChat and ChatFrame1EditBox then
                            ChatEdit_ActivateChat(ChatFrame1EditBox)
                            chatBox = ChatFrame1EditBox
                        else
                            for ci = 1, NUM_CHAT_WINDOWS do
                                local eb = _G["ChatFrame" .. ci .. "EditBox"]
                                if eb then chatBox = eb; break end
                            end
                        end
                    end
                    if chatBox then
                        chatBox:Insert(item.link)
                        if chatBox.SetFocus then chatBox:SetFocus() end
                    end
                    return
                end

                -- Left-click: toggle selection for "Use selected" (click to select, click again to deselect)
                if button == "LeftButton" and capturedId and gphFrame and gphFrame.gphUseBtn and not (InCombatLockdown and InCombatLockdown()) then
                    if gphFrame.gphSelectedItemId == capturedId then
                        gphFrame.gphSelectedItemId = nil
                        gphFrame.gphUseBtn:Hide()
                    else
                        gphFrame.gphSelectedItemId = capturedId
                        pcall(function()
                            local macro
                            local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(item.link or "")
                            local isEquippable = equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG"
                            if isEquippable then
                                macro = "/equip item:" .. capturedId
                            else
                                macro = "/use item:" .. capturedId
                            end
                            gphFrame.gphUseBtn:SetAttribute("type", "macro")
                            gphFrame.gphUseBtn:SetAttribute("macrotext", macro)
                            gphFrame.gphUseBtn:Show()
                        end)
                    end
                    RefreshGPHUI()
                end
            end)
            btn.clickArea:SetScript("OnEnter", function(self)
                if item.link then
                    AnchorTooltipRight(self)
                    local lp = item.link:match("|H(item:[^|]+)|h")
                    if lp then GameTooltip:SetHyperlink(lp) end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Click to select, then [Use selected] below. Click again to deselect. Shift-click to link.", 0.5, 0.5, 0.5)
                    GameTooltip:Show()
                end
            end)
            btn.clickArea:SetScript("OnLeave", function() GameTooltip:Hide() end)
            yOff = yOff + 18
            end)  -- end pcall
            if not rowOk then
                AddonPrint("[Fugazi] GPH row " .. tostring(idx) .. " error: " .. tostring(rowErr))
                yOff = yOff + 18
            end
        end
        -- If the previously selected item no longer exists in the list,
        -- clear selection and hide the Use button.
        if gphFrame and gphFrame.gphUseBtn and not selectedStillExists then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphUseBtn:Hide()
        end
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
    end)  -- pcall around refresh body
    if not refreshOk then
        AddonPrint("[Fugazi] GPH refresh error: " .. tostring(refreshErr))
    end
end

--- Show or hide GPH window; position next to main frame if shown.
local function ToggleGPHFrame()
    -- Reuse frame by global name in case it was created but not assigned (e.g. after an error)
    if _G.InstanceTrackerGPHFrame then gphFrame = _G.InstanceTrackerGPHFrame end
    if not gphFrame then gphFrame = CreateGPHFrame() end
    if gphFrame:IsShown() then
        gphFrame:Hide()
    else
        if frame and frame:IsShown() then
            gphFrame:ClearAllPoints()
            gphFrame:SetWidth(frame:GetWidth())
            gphFrame:SetPoint("TOPRIGHT", frame, "TOPLEFT", -4, 0)
        end
        gphFrame:Show()
        RefreshGPHUI()
    end
end

--- Create the main Instance Tracker window (lockouts, runs, buttons).
local function CreateMainFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
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
    f.EXPANDED_HEIGHT = 400

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.15, 0.35, 0.6, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("|cffff0000Fugazi|r Instance Tracker")
    title:SetTextColor(0.5, 0.8, 1, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Collapse button (square, +/- icon, no text)
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:SetWidth(18)
    collapseBtn:SetHeight(18)
    collapseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    local collapseBg = collapseBtn:CreateTexture(nil, "BACKGROUND")
    collapseBg:SetAllPoints()
    collapseBtn.bg = collapseBg
    local collapseIcon = collapseBtn:CreateTexture(nil, "ARTWORK")
    collapseIcon:SetWidth(12)
    collapseIcon:SetHeight(12)
    collapseIcon:SetPoint("CENTER")
    collapseBtn.icon = collapseIcon

    if InstanceTrackerDB.lockoutsCollapsed == nil then InstanceTrackerDB.lockoutsCollapsed = false end
    local function UpdateCollapseButton()
        if InstanceTrackerDB.lockoutsCollapsed then
            collapseBg:SetTexture(0.2, 0.3, 0.15, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
        else
            collapseBg:SetTexture(0.15, 0.25, 0.4, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
        end
    end
    UpdateCollapseButton()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.lockoutsCollapsed = not InstanceTrackerDB.lockoutsCollapsed
        UpdateCollapseButton(); RefreshUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.lockoutsCollapsed then self.bg:SetTexture(0.3, 0.45, 0.2, 0.8)
        else self.bg:SetTexture(0.25, 0.4, 0.6, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.lockoutsCollapsed and "Show Saved Lockouts" or "Hide Saved Lockouts", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateCollapseButton(); GameTooltip:Hide() end)

    -- Stats button
    local statsBtn = CreateFrame("Button", nil, f)
    statsBtn:SetWidth(42)
    statsBtn:SetHeight(18)
    statsBtn:SetPoint("RIGHT", collapseBtn, "LEFT", -2, 0)
    local statsBg = statsBtn:CreateTexture(nil, "BACKGROUND")
    statsBg:SetAllPoints()
    statsBg:SetTexture(0.1, 0.25, 0.15, 0.7)
    statsBtn.bg = statsBg
    local statsText = statsBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsText:SetPoint("CENTER")
    statsText:SetText("|cff66dd88Stats|r")
    statsBtn.label = statsText
    statsBtn:SetScript("OnClick", function()
        if _G.InstanceTrackerStatsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
        if not statsFrame then statsFrame = CreateStatsFrame() end
        if statsFrame:IsShown() then
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            end
            statsFrame:Show()
            RefreshStatsUI()
        end
    end)
    statsBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
        self.label:SetText("|cff88ffaaStats|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Run Stats", 0.4, 0.9, 0.5)
        GameTooltip:AddLine("View duration, gold, items.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("items, and more for each run.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    statsBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.1, 0.25, 0.15, 0.7)
        self.label:SetText("|cff66dd88Stats|r")
        GameTooltip:Hide()
    end)

    -- Reset button
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:SetWidth(45)
    resetBtn:SetHeight(18)
    resetBtn:SetPoint("RIGHT", statsBtn, "LEFT", -2, 0)
    local resetBg = resetBtn:CreateTexture(nil, "BACKGROUND")
    resetBg:SetAllPoints()
    resetBg:SetTexture(0.3, 0.15, 0.1, 0.7)
    resetBtn.bg = resetBg
    local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetText:SetPoint("CENTER")
    resetText:SetText("|cffff8844Reset ID|r")  -- ← Changed label here
    resetBtn.label = resetText
    resetBtn:SetScript("OnClick", function()
        ResetInstances()
        AddonPrint(ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Instances reset.")
    end)
    resetBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
        self.label:SetText("|cffffaa66Reset ID|r")  -- ← Hover text updated too
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset Instance ID", 1, 0.6, 0.2)
        GameTooltip:AddLine("Resets all non-saved dungeon instances.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
        self.label:SetText("|cffff8844Reset ID|r")  -- ← Normal text
        GameTooltip:Hide()
    end)

    -- GPH button
    local gphBtn = CreateFrame("Button", nil, f)
    gphBtn:SetWidth(35)
    gphBtn:SetHeight(18)
    gphBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    local gphBg = gphBtn:CreateTexture(nil, "BACKGROUND")
    gphBg:SetAllPoints()
    gphBg:SetTexture(0.25, 0.2, 0.08, 0.7)
    gphBtn.bg = gphBg
    local gphBtnText = gphBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphBtnText:SetPoint("CENTER")
    gphBtnText:SetText("|cffdaa520GPH|r")
    gphBtn.label = gphBtnText
    gphBtn:SetScript("OnClick", function() ToggleGPHFrame() end)
    gphBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.4, 0.32, 0.12, 0.8)
        self.label:SetText("|cffffe066GPH|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("GPH Session", 1, 0.85, 0.4)
        GameTooltip:AddLine("Manual gold/hr and loot tracker.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Works anywhere, not just dungeons.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    gphBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.25, 0.2, 0.08, 0.7)
        self.label:SetText("|cffdaa520GPH|r")
        GameTooltip:Hide()
    end)

    -- Hourly counter
    local hourlyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hourlyText:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -8)
    hourlyText:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -8)
    hourlyText:SetJustifyH("LEFT")
    f.hourlyText = hourlyText

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", hourlyText, "BOTTOMLEFT", 0, -6)
    sep:SetPoint("TOPRIGHT", hourlyText, "BOTTOMRIGHT", 0, -6)
    sep:SetTexture(1, 1, 1, 0.15)

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content
    return f
end

----------------------------------------------------------------------
-- Refresh main tracker window
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

    local countColor
    if remaining <= 0 then countColor = "|cffff4444"
    elseif remaining <= 2 then countColor = "|cffff8800"
    else countColor = "|cff44ff44" end

    local nextSlot = ""
    if count >= MAX_INSTANCES_PER_HOUR and recent[1] then
        nextSlot = "  |cffcccccc(next slot in " .. FormatTime(recent[1].time + HOUR_SECONDS - now) .. ")|r"
    end
    frame.hourlyText:SetText(
        "|cff80c0ffHourly Cap:|r  "
        .. countColor .. count .. "/" .. MAX_INSTANCES_PER_HOUR .. "|r"
        .. "  " .. countColor .. "(" .. remaining .. " left)|r"
        .. nextSlot
    )

    local yOff = 0
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
            local timeLeft = HOUR_SECONDS - (now - entry.time)
            local row = GetRow(content, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            local idx = i
            row.deleteBtn:SetScript("OnClick", function() RemoveInstance(idx); RefreshUI() end)
            row.left:SetText("|cff666666" .. i .. ".|r  |cffffffcc" .. (entry.name or "Unknown") .. "|r")
            row.right:SetText(timeLeft > 0 and ("|cffff8844" .. FormatTime(timeLeft) .. "|r") or "|cff44ff44Expired|r")
            yOff = yOff + 16
        end
    end

    yOff = yOff + 10

    if InstanceTrackerDB.lockoutsCollapsed then
        frame:SetHeight(150)
        content:SetHeight(1)
        return
    end

    -- Lockouts header
    local header2 = GetText(content)
    header2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header2:SetText("|cff80c0ff--- Saved Lockouts ---|r")
    yOff = yOff + 18

    -- Lockouts
    if time() - lockoutQueryTime > 5 then UpdateLockoutCache(); RequestRaidInfo() end
    local buckets = { classic = {}, tbc = {}, wotlk = {}, unknown = {} }
    for _, info in ipairs(lockoutCache) do
        local exp = GetExpansion(info.name)
        if exp then
            table.insert(buckets[exp], info)
        else
            table.insert(buckets.unknown, info)
        end
    end

    for _, exp in ipairs(EXPANSION_ORDER) do
        local bucket = buckets[exp]
        if #bucket > 0 then
            local expH = GetText(content)
            expH:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
            expH:SetText(EXPANSION_LABELS[exp])
            yOff = yOff + 16

            table.sort(bucket, function(a, b) return a.name < b.name end)
            for _, info in ipairs(bucket) do
                local row = GetRow(content, false)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -yOff)
                local diffTag = ""
                if info.isRaid then
                    if info.diff == 1 then diffTag = " |cff888888(10N)|r"
                    elseif info.diff == 2 then diffTag = " |cff888888(25N)|r"
                    elseif info.diff == 3 then diffTag = " |cff888888(10H)|r"
                    elseif info.diff == 4 then diffTag = " |cff888888(25H)|r" end
                else
                    if info.diff == 1 then diffTag = " |cff888888(Normal)|r"
                    elseif info.diff == 2 then diffTag = " |cff888888(Heroic)|r" end
                end
                local lockColor = info.locked and "|cffff4444" or "|cff44ff44"
                row.left:SetText(lockColor .. info.name .. "|r" .. diffTag)
                if not info.locked then row.right:SetText("|cff44ff44Available|r")
                else
                    local current_reset = info.resetAtQuery - (now - lockoutQueryTime)
                    if current_reset > 0 then
                        row.right:SetText("|cffff8844" .. FormatTime(current_reset) .. "|r")
                    else
                        row.right:SetText("|cff44ff44Available|r")
                    end
                end
                yOff = yOff + 16
            end
            yOff = yOff + 8
        end
    end
    if buckets.unknown and #buckets.unknown > 0 then
        local expH = GetText(content)
        expH:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
        expH:SetText("|cff999999Other|r")
        yOff = yOff + 16
        for _, info in ipairs(buckets.unknown) do
            local row = GetRow(content, false)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -yOff)
            row.left:SetText("|cffff4444" .. info.name .. "|r")
            if not info.locked then row.right:SetText("|cff44ff44Available|r")
            else
                local current_reset = info.resetAtQuery - (now - lockoutQueryTime)
                if current_reset > 0 then
                    row.right:SetText("|cffff8844" .. FormatTime(current_reset) .. "|r")
                else
                    row.right:SetText("|cff44ff44Available|r")
                end
            end
            yOff = yOff + 16
        end
        yOff = yOff + 8
    end
    yOff = yOff + 8
    content:SetHeight(yOff)
    frame:SetHeight(frame.EXPANDED_HEIGHT)
end

----------------------------------------------------------------------
-- Periodic update
----------------------------------------------------------------------
local elapsed_acc, raidinfo_acc = 0, 0
local function OnUpdate(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    raidinfo_acc = raidinfo_acc + elapsed
    if elapsed_acc >= 1 then
        elapsed_acc = 0
        RefreshUI()
        RefreshItemDetailLive()
    end
    if raidinfo_acc >= 30 then raidinfo_acc = 0; RequestRaidInfo() end
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
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("BAG_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not InstanceTrackerDB.recentInstances then InstanceTrackerDB.recentInstances = {} end
        if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
        PurgeOld()
        
        -- Restore current run state if it exists
        if InstanceTrackerDB.currentRun then
            currentRun = InstanceTrackerDB.currentRun
            bagBaseline = InstanceTrackerDB.bagBaseline or {}
            itemsGained = InstanceTrackerDB.itemsGained or {}
            startingGold = InstanceTrackerDB.startingGold or GetMoney()
            currentZone = InstanceTrackerDB.currentZone or ""
            isInInstance = InstanceTrackerDB.isInInstance or false
            -- Re-snapshot bags if we're in an instance (baseline might be stale)
            if isInInstance then
                SnapshotBags()
            end
        end
        
        -- Restore GPH session if it exists
        if InstanceTrackerDB.gphSession then
            gphSession = InstanceTrackerDB.gphSession
            gphBagBaseline = InstanceTrackerDB.gphBagBaseline or {}
            gphItemsGained = InstanceTrackerDB.gphItemsGained or {}
            -- Re-snapshot bags (baseline might be stale after reload)
            gphBagBaseline = ScanBags()
            gphItemsGained = {}
        end
        
        frame = CreateMainFrame()
        frame:Hide()
        frame:SetScript("OnUpdate", OnUpdate)
        RequestRaidInfo()
        AddonPrint(
            ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Loaded. Type " .. ColorText("/fit help", 1, 1, 0.6) .. " for all commands."
        )

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local inInstance, instanceType = IsInInstance()
        local zoneName = GetInstanceInfo and select(1, GetInstanceInfo()) or GetRealZoneText()
        if inInstance and (instanceType == "party" or instanceType == "raid") then
            if not isInInstance or currentZone ~= zoneName then
                if currentRun and currentRun.name ~= zoneName then FinalizeRun() end
                isInInstance = true
                currentZone = zoneName
                RecordInstance(zoneName)
                RequestRaidInfo()
                if not currentRun or currentRun.name ~= zoneName then StartRun(zoneName) end
            end
        else
            if isInInstance and currentRun then FinalizeRun() end
            isInInstance = false
            currentZone = ""
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if msg and msg:find("too many instances") then
            AddonPrint(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. ColorText("WARNING: ", 1, 0.2, 0.2) .. "You've hit the hourly instance cap!"
            )
            if frame and not frame:IsShown() then frame:Show(); RefreshUI() end
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        UpdateLockoutCache(); RefreshUI()

    elseif event == "BAG_UPDATE" then
        if currentRun then DiffBags() end
        if gphSession then DiffBagsGPH() end
    end
end)
----------------------------------------------------------------------
-- Slash commands (/fit and /fit <cmd>)
----------------------------------------------------------------------
SLASH_INSTANCETRACKER1 = "/fit"
SLASH_INSTANCETRACKER2 = "/fugazi"
SlashCmdList["INSTANCETRACKER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local cmd = msg:match("^([%w]+)") or ""

    if cmd == "help" or msg == "help" then
        AddonPrint(ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Commands:")
        AddonPrint("  |cffaaddff/fit|r              Toggle main window (no args)")
        AddonPrint("  |cffaaddff/fit help|r        Show this list")
        AddonPrint("  |cffaaddff/fit mute|r        Mute all addon chat output")
        AddonPrint("  |cffaaddff/fit reset|r       Clear recent instance history (this hour)")
        AddonPrint("  |cffaaddff/fit status|r      Show instances used this hour in chat")
        AddonPrint("  |cffaaddff/fit stats|r       Toggle Run Stats (Ledger) window")
        AddonPrint("  |cffaaddff/fit gph|r         Toggle Gold Per Hour window")
        return
    end

    if cmd == "mute" then
        InstanceTrackerDB.fitMute = not InstanceTrackerDB.fitMute
        -- Always show mute state (can't mute the mute confirmation)
        DEFAULT_CHAT_FRAME:AddMessage(
            ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Chat output " .. (InstanceTrackerDB.fitMute and "|cffff4444muted|r." or "|cff44ff44unmuted|r.")
        )
        return
    end

    if cmd == "reset" then
        InstanceTrackerDB.recentInstances = {}
        AddonPrint(ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Recent instance history cleared.")
        RefreshUI()
        return
    end

    if cmd == "status" then
        PurgeOld()
        local c = #(InstanceTrackerDB.recentInstances or {})
        AddonPrint(
            ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Instances this hour: " .. ColorText(c .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.8, 0.2)
            .. " (" .. ColorText((MAX_INSTANCES_PER_HOUR - c) .. " remaining", 0.4, 1, 0.4) .. ")"
        )
        return
    end

    if cmd == "stats" then
        if _G.InstanceTrackerStatsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
        if not statsFrame then statsFrame = CreateStatsFrame() end
        if statsFrame:IsShown() then statsFrame:Hide() else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            end
            statsFrame:Show()
            RefreshStatsUI()
        end
        return
    end

    if cmd == "gph" then
        ToggleGPHFrame()
        return
    end

    -- No subcommand or unknown: toggle main window
    if not frame then frame = CreateMainFrame(); frame:SetScript("OnUpdate", OnUpdate) end
    if frame:IsShown() then frame:Hide() else RequestRaidInfo(); frame:Show(); RefreshUI() end
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------
local function CreateMinimapButton()
    local minimapAngle = InstanceTrackerDB.minimapAngle or 220
    local btn = CreateFrame("Button", "InstanceTrackerMinimapBtn", Minimap)
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel(8)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(21); icon:SetHeight(21)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\Spell_Frost_Stun")
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53); border:SetHeight(53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local function UpdatePosition()
        local a = math.rad(minimapAngle)
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
    end
    UpdatePosition()
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnDragStart", function()
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
            UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function()
        btn:SetScript("OnUpdate", nil); InstanceTrackerDB.minimapAngle = minimapAngle
    end)
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and IsControlKeyDown() then
            ResetInstances()
            AddonPrint(ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Instances reset.")
        elseif button == "LeftButton" then SlashCmdList["INSTANCETRACKER"]("")
        elseif button == "RightButton" then SlashCmdList["INSTANCETRACKER"]("status") end
    end)
    btn:SetScript("OnEnter", function(self)
        PurgeOld()
        local c = #(InstanceTrackerDB.recentInstances or {})
        local r = MAX_INSTANCES_PER_HOUR - c
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Fugazi Instance Tracker", 0.5, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Instances (1h):", c .. "/" .. MAX_INSTANCES_PER_HOUR, 1,1,1, 1,0.8,0.2)
        GameTooltip:AddDoubleLine("Remaining:", r, 1,1,1, 0.4,1,0.4)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff888888Left-click: Toggle window|r")
        GameTooltip:AddLine("|cff888888Ctrl-click: Reset instances|r")
        GameTooltip:AddLine("|cff888888Right-click: Status in chat|r")
        GameTooltip:AddLine("|cff888888/fit help for commands|r")
        GameTooltip:AddLine("|cff888888Drag: Move around minimap|r")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

eventFrame:HookScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then CreateMinimapButton() end
end)
