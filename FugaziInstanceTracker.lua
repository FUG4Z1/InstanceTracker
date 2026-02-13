----------------------------------------------------------------------
-- Fugazi Instance Tracker — by Fugazi
-- WoW 3.3.5a (WotLK)
-- • FULL LOOT MANAGEMENT
-- • 5-instances-per-hour soft cap and countdown
-- • Saved lockouts by expansion (Classic, TBC, WotLK)
-- • Run ledger: duration, gold, items per run (current + history)
-- • Gold-Per-Hour (GPH) manual tracker: sessions, loot list, vendor/destroy
-- • Item detail popup (docks to Ledger or GPH), search, collapse
-- Data is account-wide (5/hr limit is per account).
----------------------------------------------------------------------

local ADDON_NAME = "InstanceTracker"
local MAX_INSTANCES_PER_HOUR = 5
local HOUR_SECONDS = 3600
local MAX_RUN_HISTORY = 100
-- Only restore a run from history if it ended within this many seconds (e.g. died and re-entered before instance reset).
local MAX_RESTORE_AGE_SECONDS = 5 * 60  -- 5 minutes; after that treat as a new run
local SCROLL_CONTENT_WIDTH = 296  -- viewport width for scroll content (no gap left of scrollbar)
local GPH_MAX_STACK = 49  -- server max stack size; confirm when deleting more than this via red X

InstanceTrackerDB = InstanceTrackerDB or {}
if InstanceTrackerDB.fitMute == nil then InstanceTrackerDB.fitMute = false end
if InstanceTrackerDB.gphInvKeybind == nil then InstanceTrackerDB.gphInvKeybind = false end
if InstanceTrackerDB.gphScale15 == nil then InstanceTrackerDB.gphScale15 = false end
if InstanceTrackerDB.gphDestroyList == nil then InstanceTrackerDB.gphDestroyList = {} end
if InstanceTrackerDB.gphPreviouslyWornItemIds == nil then InstanceTrackerDB.gphPreviouslyWornItemIds = {} end
-- (*) Protected items per character (survives relog/reload).
InstanceTrackerDB.gphProtectedItemIdsPerChar = InstanceTrackerDB.gphProtectedItemIdsPerChar or {}
-- Rarity whitelist per character: [charKey][quality] = true means all items of that rarity are protected (separate from per-item; toggle off releases them, per-item stays)
InstanceTrackerDB.gphProtectedRarityPerChar = InstanceTrackerDB.gphProtectedRarityPerChar or {}

--- Realm#Character key for per-char DB.
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end

--- Returns the current character's (*) protected item set (read/write). Migrates from older account-wide list on first use.
local function GetGphProtectedSet()
    if not InstanceTrackerDB.gphProtectedItemIdsPerChar then
        InstanceTrackerDB.gphProtectedItemIdsPerChar = {}
    end
    local key = GetGphCharKey()
    if not InstanceTrackerDB.gphProtectedItemIdsPerChar[key] then
        InstanceTrackerDB.gphProtectedItemIdsPerChar[key] = {}
        -- Migrate older account-wide list into this character
        local legacy = InstanceTrackerDB.gphPreviouslyWornItemIds or {}
        for id in pairs(legacy) do
            InstanceTrackerDB.gphProtectedItemIdsPerChar[key][id] = true
        end
    end
    return InstanceTrackerDB.gphProtectedItemIdsPerChar[key]
end

--- Returns the set of item IDs that were auto-protected because they left equipment slots (soul icon only; not per-item or rarity blacklist).
local function GetGphPreviouslyWornOnlySet()
    if not InstanceTrackerDB.gphPreviouslyWornOnlyPerChar then InstanceTrackerDB.gphPreviouslyWornOnlyPerChar = {} end
    local key = GetGphCharKey()
    if not InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key] then
        InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key] = {}
    end
    return InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key]
end

--- Get current character's rarity whitelist (quality -> true). When true, all items of that quality are protected until toggled off; per-item list is separate and sticky.
local function GetGphProtectedRarityFlags()
    if not InstanceTrackerDB.gphProtectedRarityPerChar then InstanceTrackerDB.gphProtectedRarityPerChar = {} end
    local key = GetGphCharKey()
    if not InstanceTrackerDB.gphProtectedRarityPerChar[key] then
        InstanceTrackerDB.gphProtectedRarityPerChar[key] = {}
    end
    return InstanceTrackerDB.gphProtectedRarityPerChar[key]
end

--- Global API: true if item is protected (per-item whitelist OR rarity whitelist for its quality). Optional qualityArg avoids nil from GetItemInfo when uncached.
local function IsItemProtectedAPI(itemId, qualityArg)
    if not itemId then return false end
    local set = GetGphProtectedSet and GetGphProtectedSet()
    if set and set[itemId] == true then return true end
    local flags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
    if not flags then return false end
    local q = qualityArg
    if q == nil and GetItemInfo then local _, _, qq = GetItemInfo(itemId) q = qq end
    return q and flags[q] == true
end
_G.FugaziInstanceTracker_IsItemProtected = function(id) return IsItemProtectedAPI(id) end

-- GPH Vendor: auto-sell at Goblin Merchant (respects (*) protected), summon Greedy Scavenger, mute Greedy. Standalone implementation.
local GOBLIN_MERCHANT_NAME = "Goblin Merchant"
local GREEDY_PET_NAME = "Greedy scavenger"
-- Companion creatureIDs from pet selection frame (what GetCompanionInfo returns for summon slot)
local GREEDY_PET_ID = 600135
local GOBLIN_MERCHANT_ID = 600126
local GPH_SUMMON_DELAY = 1.5

local gphVendorQueue = {}
local gphVendorQueueIndex = 1
local gphVendorRunning = false
local gphVendorWorker = CreateFrame("Frame")
gphVendorWorker:Hide()

local function BuildGphVendorQueue()
    wipe(gphVendorQueue)
    gphVendorQueueIndex = 1
    for bag = 0, 4 do
        local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID and GetContainerItemID(bag, slot)
            if itemID then
                local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                local _, _, quality
                if link and GetItemInfo then _, _, quality = GetItemInfo(link) end
                if quality == nil and GetItemInfo then _, _, quality = GetItemInfo(itemID) end
                if not IsItemProtectedAPI(itemID, quality) then
                    local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                    if itemCount and itemCount > 0 and not locked then
                        local sellPrice = GetItemInfo and select(11, GetItemInfo(link or itemID))
                        if sellPrice and sellPrice > 0 and not (quality == 4) then
                            gphVendorQueue[#gphVendorQueue + 1] = { type = "sell", bag = bag, slot = slot, itemID = itemID }
                        end
                    end
                end
            end
        end
    end
end

-- Name-only matching for 3.3.5 (GetCompanionInfo return order/ID can vary by client)
local function GphCompanionNameIsGreedy(name)
    if not name or type(name) ~= "string" then return false end
    local l = name:lower()
    return l:find("greedy") and l:find("scavenger")
end
local function GphCompanionNameIsGoblin(name)
    if not name or type(name) ~= "string" then return false end
    local l = name:lower()
    return l:find("goblin") and l:find("merchant")
end

local function GphIsGreedySummoned()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned and (cid == GREEDY_PET_ID or GphCompanionNameIsGreedy(cname)) then return true end
    end
    return false
end

local function GphIsGoblinMerchantSummoned()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned and (cid == GOBLIN_MERCHANT_ID or GphCompanionNameIsGoblin(cname)) then return true end
    end
    return false
end

--- True if the player has the Greedy scavenger companion (owned, not necessarily summoned).
local function GphPlayerHasGreedyCompanion()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname = GetCompanionInfo("CRITTER", i)
        if cid == GREEDY_PET_ID or (cname and GphCompanionNameIsGreedy(cname)) then return true end
    end
    return false
end

local function QueueGphSummonGreedy()
    local t = (InstanceTrackerDB.gphSummonDelayTimers or {})
    InstanceTrackerDB.gphSummonDelayTimers = t
    t[#t + 1] = { left = GPH_SUMMON_DELAY, func = function()
        local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
        for i = 1, num do
            local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
            if not isSummoned and (cid == GREEDY_PET_ID or GphCompanionNameIsGreedy(cname)) then
                CallCompanion("CRITTER", i)
                if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
                return
            end
        end
    end }
end

local function DoGphSummonGreedyNow()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if not isSummoned and (cid == GREEDY_PET_ID or GphCompanionNameIsGreedy(cname)) then
            CallCompanion("CRITTER", i)
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            return
        end
    end
end

local function DoGphSummonGoblinMerchantNow()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if not isSummoned and (cid == GOBLIN_MERCHANT_ID or GphCompanionNameIsGoblin(cname)) then
            CallCompanion("CRITTER", i)
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            return
        end
    end
end

--- Dismiss current critter companion (Greedy or Goblin Merchant). Returns true if one was dismissed.
local function GphDismissCurrentCompanion()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned and (cid == GREEDY_PET_ID or cid == GOBLIN_MERCHANT_ID or GphCompanionNameIsGreedy(cname) or GphCompanionNameIsGoblin(cname)) then
            CallCompanion("CRITTER", i)
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            return true
        end
    end
    return false
end

local function FinishGphVendorRun()
    gphVendorRunning = false
    gphVendorWorker:Hide()
    if InstanceTrackerDB.gphSummonGreedy ~= false then
        QueueGphSummonGreedy()
    end
end

local gphSummonDelayFrame = CreateFrame("Frame")
gphSummonDelayFrame:SetScript("OnUpdate", function(self, elapsed)
    local t = InstanceTrackerDB.gphSummonDelayTimers
    if not t or #t == 0 then return end
    for i = #t, 1, -1 do
        local item = t[i]
        item.left = item.left - elapsed
        if item.left <= 0 then
            table.remove(t, i)
            if type(item.func) == "function" then pcall(item.func) end
        end
    end
end)

gphVendorWorker:SetScript("OnUpdate", function(self, elapsed)
    self._t = (self._t or 0) + elapsed
    if self._t < 0.015 then return end
    self._t = 0
    if not MerchantFrame or not MerchantFrame:IsShown() then
        gphVendorRunning = false
        self:Hide()
        return
    end
    local action = gphVendorQueue[gphVendorQueueIndex]
    if not action then
        FinishGphVendorRun()
        return
    end
    if action.type == "sell" then
        local link = GetContainerItemLink and GetContainerItemLink(action.bag, action.slot)
        local _, _, quality
        if link and GetItemInfo then _, _, quality = GetItemInfo(link) end
        if quality == nil and GetItemInfo then _, _, quality = GetItemInfo(action.itemID) end
        if not IsItemProtectedAPI(action.itemID, quality) then
            UseContainerItem(action.bag, action.slot)
        end
    end
    gphVendorQueueIndex = gphVendorQueueIndex + 1
end)

local function StartGphVendorRun()
    if not UnitExists("target") or UnitName("target") ~= GOBLIN_MERCHANT_NAME then return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    if gphVendorRunning then return end
    gphVendorRunning = true
    BuildGphVendorQueue()
    if #gphVendorQueue == 0 then
        gphVendorRunning = false
        if UnitExists("target") and UnitName("target") == GOBLIN_MERCHANT_NAME and MerchantFrame and MerchantFrame:IsShown() and (InstanceTrackerDB.gphSummonGreedy ~= false) then
            QueueGphSummonGreedy()
        end
        return
    end
    gphVendorWorker._t = 0
    gphVendorWorker:Show()
end

local gphGreedyMuteInstalled = false
local function GphGreedyChatFilter(self, event, msg, author, ...)
    if type(author) ~= "string" then return false end
    local clean = author:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""):lower()
    if clean == GREEDY_PET_NAME:lower() then return true end
    if type(msg) == "string" and msg:lower():find("greedy scavenger", 1, true) then
        if msg:lower():find(" says", 1, true) or msg:lower():find(" yells", 1, true) or msg:lower():find(" whispers", 1, true) then
            return true
        end
    end
    return false
end

local function GphIsVendorOut()
    return (MerchantFrame and MerchantFrame:IsShown()) and (UnitExists("target") and UnitName("target") == GOBLIN_MERCHANT_NAME)
end

local function InstallGphGreedyMuteOnce()
    if gphGreedyMuteInstalled then return end
    gphGreedyMuteInstalled = true
    local events = { "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_WHISPER", "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_MONSTER_PARTY", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_EMOTE", "CHAT_MSG_SYSTEM" }
    for _, ev in ipairs(events) do
        if ChatFrame_AddMessageEventFilter then ChatFrame_AddMessageEventFilter(ev, GphGreedyChatFilter) end
    end
end

-- Inv toggle: when on, bag key opens GPH instead of default bags (like Bagnon/OneBag: hook ToggleBackpack/OpenAllBags)
local origToggleBackpack, origOpenAllBags
local gphNpcDialogTime  -- set on MERCHANT_SHOW / GOSSIP_SHOW / QUEST_GREETING so we don't close GPH when game auto-opens bags at NPC
local function GPHInvBagKeyHandler()
    -- With INV on: at vendor/NPC never open bags and don't close GPH; otherwise bag key toggles GPH.
    local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
    local atNpcRecently = gphNpcDialogTime and (GetTime() - gphNpcDialogTime) < 1.5
    if atVendor or atNpcRecently then
        if CloseAllBags then CloseAllBags() end
        local gf = _G.InstanceTrackerGPHFrame or gphFrame
        if not gf and CreateGPHFrame then gf = CreateGPHFrame() end
        if gf and not gf:IsShown() then
            gphFrame = gf
            gf:Show()
            if SaveFrameLayout then SaveFrameLayout(gf, "gphShown", "gphPoint") end
            if RefreshGPHUI then RefreshGPHUI() end
        end
        return
    end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
    if CloseAllBags then CloseAllBags() end
end
local function InstallGPHInvHook()
    if not InstanceTrackerDB.gphInvKeybind then return end
    if not origToggleBackpack and _G.ToggleBackpack then origToggleBackpack = _G.ToggleBackpack end
    if not origOpenAllBags and _G.OpenAllBags then origOpenAllBags = _G.OpenAllBags end
    if origToggleBackpack then _G.ToggleBackpack = GPHInvBagKeyHandler end
    if origOpenAllBags then _G.OpenAllBags = GPHInvBagKeyHandler end
end
local function RemoveGPHInvHook()
    if origToggleBackpack then _G.ToggleBackpack = origToggleBackpack end
    if origOpenAllBags then _G.OpenAllBags = origOpenAllBags end
end

-- Non-secure button so bag key can open GPH in combat (/click is allowed; /run from secure macro often is not)
if not _G.InstanceTrackerGPHToggleButton then
    local toggleBtn = CreateFrame("Button", "InstanceTrackerGPHToggleButton", UIParent)
    toggleBtn:SetSize(1, 1)
    toggleBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    toggleBtn:Hide()
    toggleBtn:SetScript("OnClick", function()
        if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
    end)
end

-- Apply key override so bag key triggers our button (hook alone may not run on keypress in 3.3.5)
local function ApplyGPHInvKeyOverride(btn)
    if not btn or not InstanceTrackerDB.gphInvKeybind then return end
    local owner = _G.InstanceTrackerKeybindOwner
    if not owner then return end
    -- Use non-secure toggle button name so /click works in combat (secure /run is often blocked)
    local btnName = "InstanceTrackerGPHToggleButton"
    if ClearOverrideBindings then ClearOverrideBindings(owner) end
    local keys = {}
    for _, action in next, { "TOGGLEBACKPACK", "OPENALLBAGS" } do
        local k = GetBindingKey and GetBindingKey(action)
        if k and k ~= "" then keys[k] = true end
    end
    if next(keys) == nil then keys["B"] = true end
    for key, _ in pairs(keys) do
        if SetOverrideBindingClick then
            SetOverrideBindingClick(owner, true, key, btnName, "LeftButton")
        elseif SetOverrideBinding then
            SetOverrideBinding(owner, true, key, "CLICK", btnName)
        end
    end
end

--- Save a frame's position to DB (for /reload restore). Stores point, relativePoint, x, y (restore uses UIParent).
--- For itemDetailPoint we always save absolute screen coords so docked position doesn't restore as top-right.
local function SaveFrameLayout(frame, shownKey, pointKey)
    if not frame then return end
    if pointKey == "itemDetailPoint" then
        local left, top = frame:GetLeft(), frame:GetTop()
        if left and top then
            InstanceTrackerDB[pointKey] = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
        end
    else
        local p, _, rp, x, y = frame:GetPoint(1)
        if p and rp and x and y then
            InstanceTrackerDB[pointKey] = { point = p, relativePoint = rp, x = x, y = y }
        end
    end
    if shownKey then InstanceTrackerDB[shownKey] = frame:IsShown() end
end

--- Restore a frame's position and optionally visibility from DB.
local function RestoreFrameLayout(frame, shownKey, pointKey)
    if not frame then return end
    local pt = InstanceTrackerDB[pointKey]
    if pt and pt.point and pt.relativePoint and pt.x and pt.y then
        frame:ClearAllPoints()
        frame:SetPoint(pt.point, UIParent, pt.relativePoint, pt.x, pt.y)
    end
    if shownKey then
        if InstanceTrackerDB[shownKey] then
            frame:Show()
            return true
        else
            frame:Hide()
        end
    end
    return false
end

--- When collapsing, keep the frame's top fixed so the title bar (and collapse button) doesn't jump.
--- If isSnappedTo(relTo) returns true for the frame's first anchor, only SetHeight; else re-anchor TOPLEFT at current position then SetHeight.
local function CollapseInPlace(frame, collapsedHeight, isSnappedTo)
    if not frame then return end
    local pt, relTo, relPt, x, y = frame:GetPoint(1)
    if pt and relTo and isSnappedTo and isSnappedTo(relTo) then
        frame:SetHeight(collapsedHeight)
        return
    end
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    frame:SetHeight(collapsedHeight)
end

--- Display name for a run (custom name or zone name).
local function GetRunDisplayName(run)
    if not run then return "?" end
    if run.customName and run.customName:match("%S") then return run.customName end
    return run.name or "?"
end

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
local lastExitedZoneName = nil  -- zone name when we last finalized; used to drop that run from history on instance reset chat

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

-- Double-click on X to delete (itemId -> GetTime() of first click, 0.5s window)
local gphDeleteClickTime = gphDeleteClickTime or {}
-- Shift+double-click on X to toggle destroy list (itemId -> GetTime() of first click)
local gphDestroyClickTime = gphDestroyClickTime or {}
-- Queue for deferred auto-destroy; processed by dedicated frame with throttle (like SimpleAutoDelete-WOTLK)
local gphDestroyQueue = {}
local gphDestroyerThrottle = 0
local GPH_DESTROY_DELAY = 0.4

-- Dedicated frame for auto-destroy (delay like SimpleAutoDelete-WOTLK so DeleteCursorItem runs in a valid context)
local gphDestroyerFrame = nil
local function EnsureGPHDestroyerFrame()
    if gphDestroyerFrame then return end
    gphDestroyerFrame = CreateFrame("Frame")
    gphDestroyerFrame:Hide()
    gphDestroyerFrame:SetScript("OnUpdate", function(self, elapsed)
        if #gphDestroyQueue == 0 then self:Hide(); return end
        gphDestroyerThrottle = gphDestroyerThrottle + elapsed
        if gphDestroyerThrottle >= GPH_DESTROY_DELAY then
            gphDestroyerThrottle = 0
            local entry = table.remove(gphDestroyQueue, 1)
            if entry and entry.bag and entry.slot then
                PickupContainerItem(entry.bag, entry.slot)
                if DeleteCursorItem then DeleteCursorItem() end
            end
            if #gphDestroyQueue == 0 then self:Hide() end
        end
    end)
end
--- When an itemId is added to the destroy list, queue all current bag slots with that item for immediate delete (stack + subsequent).
local function QueueDestroySlotsForItemId(itemId)
    if not itemId then return end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local id = GetContainerItemID and GetContainerItemID(bag, slot)
                if not id and GetContainerItemLink then
                    local link = GetContainerItemLink(bag, slot)
                    if link then id = tonumber(link:match("item:(%d+)")) end
                end
                if id == itemId then
                    gphDestroyQueue[#gphDestroyQueue + 1] = { itemId = itemId, bag = bag, slot = slot }
                end
            end
        end
    end
    if #gphDestroyQueue > 0 then
        EnsureGPHDestroyerFrame()
        if gphDestroyerFrame then gphDestroyerFrame:Show() end
    end
end

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
                local itemId = tonumber(link:match("item:(%d+)"))
                local _, _, itemQuality = GetItemInfo(link)
                if itemQuality == quality then
                    -- Never delete (*) previously worn equipment via rarity bar
                    local skip = (itemId and GetGphProtectedSet()[itemId]) or false

                    -- For White (quality 1): skip quest items (via tooltip scan - classic 3.3.5a method) and hearthstone
                    if quality == 1 then
                        -- itemId already set above
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
    [0] = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d", label = "Trash" },         
    [1] = { r = 1.00, g = 1.00, b = 1.00, hex = "ffffff", label = "White" },
    [2] = { r = 0.12, g = 1.00, b = 0.00, hex = "1eff00", label = "Green" },         -- Note: QUALITY COLOR LABELS ARE HERE! (OFF)
    [3] = { r = 0.00, g = 0.44, b = 0.87, hex = "0070dd", label = "Blue" },
    [4] = { r = 0.64, g = 0.21, b = 0.93, hex = "a335ee", label = "Purple" },
    [5] = { r = 1.00, g = 0.50, b = 0.00, hex = "ff8000", label = "Orange" },
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
-- Formatting and utility
----------------------------------------------------------------------
--- Time as "Xd Xm Xs" or "Ready".
local function FormatTime(seconds)
    if seconds <= 0 then return "Ready" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then return string.format("%dm %02ds", m, s)
    else return string.format("%ds", s) end
end

--- Shorter time string (e.g. "5m 30s").
local function FormatTimeMedium(seconds)
    if seconds <= 0 then return "0s" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %dm", h, m)
    elseif m > 0 then return string.format("%dm %ds", m, s)
    else return string.format("%ds", s) end
end

--- Copper to colored "Xg Xs Xc" string.
local function FormatGold(copper)
    if not copper or copper <= 0 then return "|cffeda55f0c|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("|cffffd700%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, s, c)
    elseif s > 0 then return string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else return string.format("|cffeda55f%d|rc", c) end
end

--- Copper to plain "Xg Xs Xc" (no color).
local function FormatGoldPlain(copper)
    if not copper or copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then return string.format("%ds %dc", s, c)
    else return string.format("%dc", c) end
end

--- Timestamp to "DD.M.YY - HH:MM".
local function FormatDateTime(timestamp)
    if not timestamp then return "" end
    local dt = date("*t", timestamp)
    if not dt then return "" end
    -- Format: DD.M.YY - HH:MM (e.g., "11.2.26 - 14:30")
    return string.format("%d.%d.%d - %02d:%02d", dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
end

--- Wrap text in color (r,g,b 0-1).
local function ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

--- Private tooltip for scanning item tooltips (never touch GameTooltip so bag hover works).
local scanTooltip = nil
local function GetScanTooltip()
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "FugaziInstanceTrackerScanTT", UIParent, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTooltip:ClearAllPoints()
        scanTooltip:SetPoint("CENTER", UIParent, "CENTER", 99999, 99999)  -- off-screen when shown
    end
    return scanTooltip
end

--- Build map itemId -> {bag, slot} (first slot per item) for GetItemCooldown.
local function GetItemIdToBagSlot()
    local out = {}
    for bag = 0, 4 do
        local n = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local itemId = tonumber(link:match("item:(%d+)"))
                if itemId and not out[itemId] then out[itemId] = { bag = bag, slot = slot } end
            end
        end
    end
    return out
end

--- True if the item is currently on cooldown (GetContainerItemCooldown; reliable, no tooltip).
local function ItemIdHasCooldown(itemId, itemIdToSlot)
    if not itemId or not itemIdToSlot then return false end
    local t = itemIdToSlot[itemId]
    if not t or not GetContainerItemCooldown then return false end
    local start, duration = GetContainerItemCooldown(t.bag, t.slot)
    if not duration or duration <= 0 then return false end
    return (start or 0) + duration > GetTime()
end

--- True if the item's tooltip contains "Cooldown remaining:" (e.g. potion on CD). Uses private tooltip.
local function ItemLinkHasCooldownRemaining(link)
    if not link or link == "" then return false end
    local st = GetScanTooltip()
    st:ClearLines()
    st:SetHyperlink(link)
    st:Show()  -- some clients need Show() before tooltip text is populated
    local found = false
    local numLines = st:NumLines() or 0
    -- Try named regions (FrameNameTextLeft1); fallback to GameTooltipTextLeft1 (some clients use shared regions)
    local name = st:GetName()
    for i = 1, numLines do
        local line = (name and _G[name .. "TextLeft" .. i]) or _G["GameTooltipTextLeft" .. i]
        if line and line.GetText then
            local text = line:GetText()
            if text and (text:find("Cooldown remaining") or text:find("Cooldown:")) then found = true; break end
        end
    end
    -- Fallback: iterate all children (FontStrings) in case template uses different naming
    if not found and st.GetNumChildren and st.GetChild then
        for i = 1, (st:GetNumChildren() or 0) do
            local child = st:GetChild(i)
            if child and child.GetText then
                local text = child:GetText()
                if text and (text:find("Cooldown remaining") or text:find("Cooldown:")) then found = true; break end
            end
        end
    end
    st:Hide()
    return found
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

--- Update itemsGained from current bags vs baseline; updates currentRun (dungeon run).
--- (*) protected items and hearthstone never count as "loot gained" for the run (lightweight: one lookup).
local function DiffBags()
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    local protected = GetGphProtectedSet()
    local previouslyWornOnly = GetGphPreviouslyWornOnlySet()
    -- Mark items that just left equipment slots as (*) protected and as "previously worn" (soul icon)
    for id in pairs(lastEquippedItemIds) do
        if not currentEquipped[id] then
            protected[id] = true
            previouslyWornOnly[id] = true
        end
    end
    lastEquippedItemIds = currentEquipped

    if not currentRun then return end
    for itemId, curCount in pairs(current) do
        local baseCount = bagBaseline[itemId] or 0
        local delta = curCount - baseCount
        if delta > 0 and (protected[itemId] or itemId == 6948) then
            -- (*) or hearthstone: absorb into itemsGained only, never count as run loot
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
    if currentRun then
        InstanceTrackerDB.currentRun = currentRun
        InstanceTrackerDB.bagBaseline = bagBaseline
        InstanceTrackerDB.itemsGained = itemsGained
    end
end

--- GPH session: update gphItemsGained from current bags vs gphBagBaseline. (*) and hearthstone never count as session gain.
local function DiffBagsGPH()
    if not gphSession then return end
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    local protected = GetGphProtectedSet()
    local previouslyWornOnly = GetGphPreviouslyWornOnlySet()
    for id in pairs(lastEquippedItemIds) do
        if not currentEquipped[id] then
            protected[id] = true
            previouslyWornOnly[id] = true
        end
    end
    lastEquippedItemIds = currentEquipped
    for itemId, curCount in pairs(current) do
        local baseCount = gphBagBaseline[itemId] or 0
        local delta = curCount - baseCount
        if delta > 0 and (protected[itemId] or itemId == 6948) then
            gphItemsGained[itemId] = delta
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
    -- Protect equipped items so they're never counted as session gain
    local protected = GetGphProtectedSet()
    for id in pairs(GetEquippedItemIds()) do
        protected[id] = true
    end
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
--- If the player re-enters the same dungeon (e.g. after dying and being teleported out),
-- restore the most recent run for that zone from history so the session continues.
-- Only restores if the run ended within MAX_RESTORE_AGE_SECONDS (5 min); after that or if instance reset, start fresh.
local function RestoreRunFromHistory(zoneName)
    local history = InstanceTrackerDB.runHistory
    if not history or #history == 0 or not zoneName or zoneName == "" then return false end
    local now = time()
    for i = 1, #history do
        local run = history[i]
        if run and run.name == zoneName then
            local exitTime = run.exitTime or run.enterTime
            if (now - exitTime) > MAX_RESTORE_AGE_SECONDS then
                return false  -- run too old, don't restore any run for this zone
            end
            table.remove(history, i)
            -- Rebuild currentRun.items as itemId -> { link, quality, count, name }
            local itemsById = {}
            for _, item in ipairs(run.items or {}) do
                local link = item.link
                if link then
                    local itemId = tonumber(link:match("item:(%d+)"))
                    if itemId then
                        itemsById[itemId] = {
                            link = link,
                            quality = item.quality or 0,
                            count = item.count or 0,
                            name = item.name or "Unknown",
                        }
                    end
                end
            end
            currentRun = {
                name = run.name,
                enterTime = run.enterTime,
                goldCopper = run.goldCopper or 0,
                qualityCounts = run.qualityCounts and (function()
                    local qc = {}
                    for k, v in pairs(run.qualityCounts) do qc[k] = v end
                    return qc
                end)() or {},
                items = itemsById,
            }
            startingGold = GetMoney() - (run.goldCopper or 0)
            bagBaseline = ScanBags()
            itemsGained = {}
            for itemId, item in pairs(itemsById) do
                itemsGained[itemId] = item.count
            end
            InstanceTrackerDB.currentRun = currentRun
            InstanceTrackerDB.bagBaseline = bagBaseline
            InstanceTrackerDB.itemsGained = itemsGained
            InstanceTrackerDB.startingGold = startingGold
            InstanceTrackerDB.currentZone = currentZone
            InstanceTrackerDB.isInInstance = isInInstance
            AddonPrint(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. "Resumed previous run: " .. ColorText(run.name, 1, 1, 0.6) .. "."
            )
            if statsFrame and statsFrame:IsShown() and type(RefreshStatsUI) == "function" then
                RefreshStatsUI()
            end
            return true
        end
    end
    return false
end

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

    lastExitedZoneName = currentRun.name
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
        delBtn:EnableMouse(true)
        delBtn:SetHitRectInsets(0, 0, 0, 0)
        delBtn:SetWidth(14)
        delBtn:SetHeight(14)
        delBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
        delBtn:SetNormalFontObject(GameFontNormalSmall)
        delBtn:SetHighlightFontObject(GameFontHighlightSmall)
        delBtn:SetText("|cffff4444x|r")
        delBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        delBtn:SetScript("OnEnter", function(self)
            self:SetText("|cffff8888x|r")
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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
        delBtn:EnableMouse(true)
        delBtn:SetHitRectInsets(0, 0, 0, 0)
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
-- Fallback icon when item is not in cache (avoids red "?" from stale/invalid stored paths)
local ITEM_ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
local function GetSafeItemTexture(linkOrId, _storedTexture)
    local id = type(linkOrId) == "number" and linkOrId or nil
    if not id and type(linkOrId) == "string" then id = tonumber((linkOrId or ""):match("item:(%d+)")) end
    local tex = nil
    if GetItemInfo then
        tex = (id and select(10, GetItemInfo(id))) or (linkOrId and select(10, GetItemInfo(linkOrId)))
    end
    -- Only use live GetItemInfo result; never use stored texture (can go stale and show red ?)
    if tex and type(tex) == "string" and tex ~= "" and tex:match("^Interface") then return tex end
    return ITEM_ICON_FALLBACK
end

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
        btn:EnableMouse(true)
        btn:SetHitRectInsets(0, 0, 0, 0)
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
    -- Don't restore position here: saved "docked" layout (TOPLEFT/TOPRIGHT 4,0) would restore as top-right. ShowItemDetail sets position when opening.
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local stats = _G.InstanceTrackerStatsFrame
        if stats and stats:IsShown() then
            local lx, rx = f:GetLeft(), stats:GetRight()
            if lx and rx and (lx - rx) >= -120 and (lx - rx) <= 120 then
                local fb, ft, sb, st = f:GetBottom(), f:GetTop(), stats:GetBottom(), stats:GetTop()
                if fb and ft and sb and st and ft > sb and fb < st then
                    f:ClearAllPoints()
                    f:SetPoint("TOPLEFT", stats, "TOPRIGHT", 4, 0)
                end
            end
        end
        SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
    end)
    f:SetScript("OnHide", function()
        SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
    end)
    -- Whenever item detail is shown and the ledger is visible, dock to the right of the ledger (ensures docking no matter how it was opened)
    f:SetScript("OnShow", function()
        local stats = _G.InstanceTrackerStatsFrame
        if stats and stats:IsShown() then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", stats, "TOPRIGHT", 4, 0)
        end
    end)
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
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetTextColor(1, 0.85, 0.4, 1)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
        f:Hide()
    end)

    local qualLine = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qualLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -6)
    qualLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -6)
    qualLine:SetJustifyH("LEFT")
    f.qualLine = qualLine

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerItemScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", qualLine, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 36)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Collapse button (after scrollFrame/qualLine exist)
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:EnableMouse(true)
    collapseBtn:SetHitRectInsets(0, 0, 0, 0)
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
    local ITEM_DETAIL_COLLAPSED_HEIGHT = 150  -- same as main frame collapsed so they line up when docked
    local function UpdateItemDetailCollapse()
        if not f.scrollFrame then return end
        if InstanceTrackerDB.itemDetailCollapsed then
            collapseBg:SetTexture(0.25, 0.22, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            local pt, relTo, relPt, x, y = f:GetPoint(1)
            if pt and relTo then
                f.collapseSavedPoint = { pt, relTo, relPt, x, y }
            end
            CollapseInPlace(f, ITEM_DETAIL_COLLAPSED_HEIGHT, function(rel)
                return rel == statsFrame or rel == gphFrame or rel == _G.InstanceTrackerStatsFrame
            end)
            f.scrollFrame:Show()
            f.qualLine:Show()
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
            f.qualLine:Show()
            -- When expanding: prefer dock to ledger/GPH if visible, then saved collapse point, then DB
            local stats = _G.InstanceTrackerStatsFrame
            if stats and stats:IsShown() then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", stats, "TOPRIGHT", 4, 0)
            elseif gphFrame and gphFrame:IsShown() then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
            elseif f.collapseSavedPoint then
                local sp = f.collapseSavedPoint
                f:ClearAllPoints()
                f:SetPoint(sp[1], sp[2], sp[3], sp[4], sp[5])
                f.collapseSavedPoint = nil
            elseif InstanceTrackerDB.itemDetailPoint and InstanceTrackerDB.itemDetailPoint.point then
                RestoreFrameLayout(f, nil, "itemDetailPoint")
            end
        end
    end
    f.UpdateItemDetailCollapse = UpdateItemDetailCollapse
    UpdateItemDetailCollapse()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.itemDetailCollapsed = not InstanceTrackerDB.itemDetailCollapsed
        UpdateItemDetailCollapse()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.itemDetailCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.itemDetailCollapsed and "Show Items" or "Hide Items", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateItemDetailCollapse(); GameTooltip:Hide() end)

    -- Bottom bar: magnifying glass (search toggle) + search editbox along the bottom
    local BOTTOM_BAR_H = 28
    local bottomBar = CreateFrame("Frame", nil, f)
    bottomBar:SetHeight(BOTTOM_BAR_H)
    bottomBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 6)
    bottomBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    bottomBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    bottomBar:SetBackdropColor(0.08, 0.12, 0.18, 0.85)
    f.bottomBar = bottomBar

    -- Search button: same style as collapse (fits frame design)
    local searchBtn = CreateFrame("Button", nil, bottomBar)
    searchBtn:EnableMouse(true)
    searchBtn:SetHitRectInsets(0, 0, 0, 0)
    searchBtn:SetSize(36, 20)
    searchBtn:SetPoint("LEFT", bottomBar, "LEFT", 4, 0)
    local searchBtnBg = searchBtn:CreateTexture(nil, "BACKGROUND")
    searchBtnBg:SetAllPoints()
    searchBtnBg:SetTexture(0.35, 0.28, 0.1, 0.7)
    searchBtn.bg = searchBtnBg
    local searchLabel = searchBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("CENTER")
    searchLabel:SetText("Search")
    searchLabel:SetTextColor(1, 0.85, 0.4, 1)
    searchBtn:SetScript("OnClick", function()
        f.searchBarVisible = not f.searchBarVisible
        if f.searchBarVisible then
            f.searchEditBox:Show()
            f.searchEditBox:SetFocus()
        else
            f.searchEditBox:Hide()
            f.searchEditBox:SetText("")
            f.searchText = ""
            if f.RefreshItemDetailList then f:RefreshItemDetailList() end
        end
    end)
    searchBtn.tooltipPending = nil  -- show tooltip only after 1.5s hover
    searchBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.4, 0.15, 0.8)
        self.tooltipPending = GetTime()
    end)
    searchBtn:SetScript("OnLeave", function(self)
        searchBtnBg:SetTexture(0.35, 0.28, 0.1, 0.7)
        self.tooltipPending = nil
        GameTooltip:Hide()
    end)
    f.searchBtn = searchBtn

    local searchEditBox = CreateFrame("EditBox", nil, bottomBar)
    searchEditBox:SetHeight(20)
    searchEditBox:SetPoint("LEFT", searchBtn, "RIGHT", 6, 0)
    searchEditBox:SetPoint("RIGHT", bottomBar, "RIGHT", -8, 0)
    searchEditBox:SetAutoFocus(false)
    searchEditBox:SetFontObject("GameFontHighlightSmall")
    searchEditBox:SetTextInsets(6, 4, 0, 0)
    searchEditBox:Hide()
    local searchBg = searchEditBox:CreateTexture(nil, "BACKGROUND")
    searchBg:SetAllPoints()
    searchBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    searchBg:SetVertexColor(0.1, 0.15, 0.22)
    searchBg:SetAlpha(0.95)
    searchEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchEditBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        f.searchText = text:match("^%s*(.-)%s*$")  -- trim
        if f.RefreshItemDetailList then f:RefreshItemDetailList() end
    end)
    f.searchEditBox = searchEditBox
    f.searchBarVisible = false
    f.searchText = ""

    -- Small "From: session name" tooltip under the mouse when hovering item rows
    local fromTooltip = CreateFrame("Frame", nil, UIParent)
    fromTooltip:SetFrameStrata("TOOLTIP")
    fromTooltip:SetFrameLevel(100)
    fromTooltip:SetWidth(1)
    fromTooltip:SetHeight(1)
    fromTooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 4, right = 4, top = 2, bottom = 2 },
    })
    fromTooltip:SetBackdropColor(0.1, 0.1, 0.15, 0.9)
    fromTooltip:Hide()
    local ftText = fromTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ftText:SetPoint("LEFT", fromTooltip, "LEFT", 6, 0)
    ftText:SetPoint("RIGHT", fromTooltip, "RIGHT", -6, 0)
    fromTooltip.text = ftText
    fromTooltip:SetWidth(200)
    fromTooltip:SetHeight(22)
    f.fromTooltip = fromTooltip

    -- Populate item list from current run or from history search (instance name, item name, or rarity)
    function f:RefreshItemDetailList()
        local run = self.currentRun
        if not run then return end
        local items = {}
        local qc = {}
        local titleText = run.name or "Unknown"
        if self.searchText and self.searchText ~= "" then
            local searchLower = self.searchText:lower()
            local history = InstanceTrackerDB.runHistory or {}
            for _, r in ipairs(history) do
                local runNameLower = r.name and r.name:lower() or ""
                local customLower = r.customName and r.customName:lower() or ""
                local runMatches = runNameLower:find(searchLower, 1, true) or (customLower ~= "" and customLower:find(searchLower, 1, true))
                local runDisp = GetRunDisplayName(r)
                for _, item in ipairs(r.items or {}) do
                    local itemNameLower = (item.name and item.name:lower()) or ""
                    local itemMatches = itemNameLower:find(searchLower, 1, true)
                    local qualityMatches = false
                    for q = 0, 5 do
                        local info = QUALITY_COLORS[q]
                        if info and info.label and info.label:lower():find(searchLower, 1, true) and item.quality == q then
                            qualityMatches = true
                            break
                        end
                    end
                    if runMatches or itemMatches or qualityMatches then
                        table.insert(items, { link = item.link, quality = item.quality, count = item.count, name = item.name, runDisplayName = runDisp })
                        qc[item.quality] = (qc[item.quality] or 0) + (item.count or 1)
                    end
                end
            end
            table.sort(items, function(a, b)
                if a.quality ~= b.quality then return a.quality > b.quality end
                return (a.name or "") < (b.name or "")
            end)
            titleText = "Search: " .. self.searchText
        else
            items = run.items or {}
            qc = run.qualityCounts or {}
        end
        self.title:SetText(titleText)
        self.qualLine:SetText(FormatQualityCounts(qc))
        ResetItemBtnPool()
        local content = self.content
        local yOff = 4
        for _, item in ipairs(items) do
            local btn = GetItemBtn(content)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            btn.itemLink = item.link
            btn.runDisplayName = item.runDisplayName or GetRunDisplayName(run)
            btn.icon:SetTexture(GetSafeItemTexture(item.link, nil))
            local qInfo = QUALITY_COLORS[item.quality] or QUALITY_COLORS[1]
            btn.nameFs:SetText("|cff" .. qInfo.hex .. (item.name or "Unknown") .. "|r")
            btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")
            btn:SetScript("OnClick", function(self, ...)
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
                    GameTooltip:AddLine("From: " .. (self.runDisplayName or "?"), 0.6, 0.8, 0.6)
                    GameTooltip:Show()
                end
                -- Second tooltip under the mouse: "From: session name"
                if itemDetailFrame and itemDetailFrame.fromTooltip then
                    local ft = itemDetailFrame.fromTooltip
                    ft.text:SetText("From: " .. (self.runDisplayName or "?"))
                    local scale = UIParent:GetEffectiveScale()
                    local x, y = GetCursorPosition()
                    ft:ClearAllPoints()
                    ft:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (x / scale) + 12, (y / scale) + 8)
                    ft:Show()
                end
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
                if itemDetailFrame and itemDetailFrame.fromTooltip then
                    itemDetailFrame.fromTooltip:Hide()
                end
            end)
            yOff = yOff + 18
        end
        if #items == 0 then yOff = yOff + 4 end
        content:SetHeight(yOff + 8)
    end

    -- Live update when showing current run or GPH items; also delayed search button tooltip (1.5s)
    local itemDetail_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        itemDetail_elapsed = itemDetail_elapsed + elapsed
        if itemDetail_elapsed >= 1 then
            itemDetail_elapsed = 0
            if self:IsShown() and self.liveSource then
                RefreshItemDetailLive()
            end
        end
        if searchBtn.tooltipPending and (GetTime() - searchBtn.tooltipPending) >= 1.5 then
            searchBtn.tooltipPending = nil
            if searchBtn:IsMouseOver() then
                GameTooltip:SetOwner(searchBtn, "ANCHOR_TOP")
                GameTooltip:AddLine("Search by instance, item name, or rarity (e.g. poor, common, rare)", 0.5, 0.8, 1)
                GameTooltip:Show()
            end
        end
    end)
    return f
end

ShowItemDetail = function(run, liveSource)
    if not itemDetailFrame then itemDetailFrame = CreateItemDetailFrame() end
    local f = itemDetailFrame
    statsFrame = _G.InstanceTrackerStatsFrame
    local wasShown = f:IsShown()
    f.currentRun = run
    f.liveSource = liveSource or nil  -- "currentRun" or "gph" or nil
    if f.searchEditBox then
        f.searchText = (f.searchEditBox:GetText() or ""):match("^%s*(.-)%s*$")
    end
    f:RefreshItemDetailList()

    -- When ledger is visible: ALWAYS dock item detail to the right of the ledger (current run or history click)
    local ledger = _G.InstanceTrackerStatsFrame
    local openFromLedger = ledger and ledger:IsShown()
    -- Apply dock immediately whenever ledger is visible (so it works even when reopening or when frame was already shown)
    if openFromLedger then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", ledger, "TOPRIGHT", 4, 0)
    elseif not wasShown then
        if gphFrame and gphFrame:IsShown() then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
        elseif InstanceTrackerDB.itemDetailPoint and InstanceTrackerDB.itemDetailPoint.point then
            RestoreFrameLayout(f, nil, "itemDetailPoint")
        end
    end
    f:Show()
    -- Re-apply dock after show when ledger is visible (in case show/layout reset position)
    if openFromLedger then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", ledger, "TOPRIGHT", 4, 0)
    elseif not wasShown and gphFrame and gphFrame:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
    end
    if not wasShown and openFromLedger then
        InstanceTrackerDB.itemDetailCollapsed = (InstanceTrackerDB.statsCollapsed == true)
        if f.UpdateItemDetailCollapse then f.UpdateItemDetailCollapse() end
    end
    -- Defer one frame when opening from ledger: re-dock so it always sticks to the right of the ledger
    if openFromLedger then
        local defer = CreateFrame("Frame", nil, UIParent)
        defer:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            local stats = _G.InstanceTrackerStatsFrame
            if f and f:IsShown() and stats and stats:IsShown() then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", stats, "TOPRIGHT", 4, 0)
                InstanceTrackerDB.itemDetailCollapsed = (InstanceTrackerDB.statsCollapsed == true)
                if f.UpdateItemDetailCollapse then f.UpdateItemDetailCollapse() end
            end
        end)
    end
    SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
end

----------------------------------------------------------------------
-- Live refresh for item detail (called every 1s from OnUpdate)
----------------------------------------------------------------------
RefreshItemDetailLive = function()
    if not itemDetailFrame or not itemDetailFrame:IsShown() or not itemDetailFrame.liveSource then return end
    if itemDetailFrame.searchText and itemDetailFrame.searchText ~= "" then return end  -- don't overwrite search results
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
-- Rename run (ledger history entry); run.customName is saved in runHistory
StaticPopupDialogs["INSTANCETRACKER_RENAME_RUN"] = {
    text = "Rename this run:",
    button1 = "OK",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 80,
    editBoxWidth = 260,
    OnShow = function(self)
        if self.data and (self.data.customName or self.data.name) then
            self.editBox:SetText(self.data.customName or self.data.name or "")
            self.editBox:SetFocus()
        end
    end,
    OnAccept = function(self)
        local run = self.data
        if run then
            run.customName = self.editBox:GetText():match("^%s*(.-)%s*$")
            if run.customName == "" then run.customName = nil end
            if statsFrame and statsFrame:IsShown() then RefreshStatsUI() end
            if itemDetailFrame and itemDetailFrame:IsShown() and itemDetailFrame.RefreshItemDetailList then
                itemDetailFrame:RefreshItemDetailList()
            end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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

-- confirm delete when removing more than one stack (50) via GPH red X
StaticPopupDialogs["INSTANCETRACKER_GPH_DELETE_STACK"] = {
    text = "Delete %d items from your bags?\n(More than one stack.)",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self)
        local d = self.data
        if d and d.itemId and d.count then
            DeleteGPHItem(d.itemId, d.count)
            if gphDeleteClickTime then gphDeleteClickTime[d.itemId] = nil end
            RefreshGPHUI()
        end
    end,
    OnCancel = function(self)
        local d = self.data
        if d and d.itemId then
            if gphDeleteClickTime then gphDeleteClickTime[d.itemId] = nil end
            RefreshGPHUI()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Split stack: double-click row in GPH list; type amount, OK puts that many on cursor
StaticPopupDialogs["INSTANCETRACKER_GPH_SPLIT_STACK"] = {
    text = "Split how many? (max %d)",
    button1 = "Split",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 6,
    editBoxWidth = 100,
    OnShow = function(self)
        self.editBox:SetText("1")
        self.editBox:SetFocus()
        pcall(function() self.editBox:SetNumeric(true) end)
    end,
    OnAccept = function(self)
        local d = self.data
        if not d or not d.itemId then return end
        local num = tonumber(self.editBox:GetText())
        if not num or num < 1 then return end
        num = math.floor(num)
        local bag, slot, stackCount = GetBagSlotWithAtLeast(d.itemId, num)
        if not bag or not slot then return end
        num = math.min(num, stackCount)
        if num >= stackCount then return end -- must leave at least 1
        if SplitContainerItem then
            SplitContainerItem(bag, slot, num)
        end
        -- Track cursor stack so list can show "x25" row until user places it
        if gphFrame then
            gphFrame.gphCursorItemId = d.itemId
            gphFrame.gphCursorCount = num
        end
        if RefreshGPHUI then RefreshGPHUI() end
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
    -- Anchor by TOP so expanding grows downward (toward mouse), not upward
    f:SetPoint("TOP", UIParent, "CENTER", 0, 400)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local mainF = _G.InstanceTrackerFrame
        if mainF and mainF:IsShown() then
            local sx, mx = f:GetLeft(), mainF:GetRight()
            if sx and mx and (sx - mx) >= -120 and (sx - mx) <= 120 then
                local sb, st, mb, mt = f:GetBottom(), f:GetTop(), mainF:GetBottom(), mainF:GetTop()
                if sb and st and mb and mt and st > mb and sb < mt then
                    f:ClearAllPoints()
                    f:SetPoint("TOPLEFT", mainF, "TOPRIGHT", 4, 0)
                end
            end
        end
        SaveFrameLayout(f, "statsShown", "statsPoint")
    end)
    f:SetScript("OnHide", function()
        SaveFrameLayout(f, "statsShown", "statsPoint")
    end)
    f:SetFrameStrata("DIALOG")
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
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("Ledger")
    title:SetTextColor(1, 0.85, 0.4, 1)

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
    collapseBtn:EnableMouse(true)
    collapseBtn:SetHitRectInsets(0, 0, 0, 0)
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
            collapseBg:SetTexture(0.25, 0.22, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            CollapseInPlace(f, 150, function(rel)
                return rel == frame or rel == _G.InstanceTrackerFrame
            end)
            f.scrollFrame:Show()
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
        end
    end
    f.UpdateStatsCollapse = UpdateStatsCollapse
    UpdateStatsCollapse()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.statsCollapsed = not InstanceTrackerDB.statsCollapsed
        UpdateStatsCollapse()
        RefreshStatsUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.statsCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.statsCollapsed and "Show Run Stats" or "Hide Run Stats", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateStatsCollapse(); GameTooltip:Hide() end)

    -- Clear button with confirmation
    local clearBtn = CreateFrame("Button", nil, f)
    clearBtn:EnableMouse(true)
    clearBtn:SetHitRectInsets(0, 0, 0, 0)
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
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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

    -- If collapsed, hide history section (content height + return so no history elements are added; pool was reset so old ones are hidden)
    if InstanceTrackerDB.statsCollapsed then
        content:SetHeight(math.max(1, yOff))
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

            -- Line 1: [x] index, name (clickable to rename), duration, date/time
            local row1 = GetStatsRow(content, true)
            row1:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            row1.runRef = run
            row1.left:SetText("|cff666666" .. i .. ".|r  |cffffffcc" .. GetRunDisplayName(run) .. "|r")
            local dateStr = (run.enterTime and FormatDateTime(run.enterTime) ~= "" and ("  |cff666666" .. FormatDateTime(run.enterTime) .. "|r")) or ""
            row1.right:SetText("|cffaaaaaa" .. FormatTimeMedium(dur) .. "|r" .. dateStr)
            local delIdx = i
            row1.deleteBtn:SetScript("OnClick", function() RemoveRunEntry(delIdx) end)
            row1:EnableMouse(true)
            row1:SetScript("OnMouseUp", function(self, button)
                if button ~= "LeftButton" then return end
                if self.deleteBtn and self.deleteBtn:IsMouseOver() then return end
                StaticPopup_Show("INSTANCETRACKER_RENAME_RUN", nil, nil, self.runRef)
            end)
            row1:SetScript("OnEnter", function(self)
                if self.deleteBtn and self.deleteBtn:IsMouseOver() then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:AddLine("Click to rename", 0.5, 0.8, 1)
                GameTooltip:Show()
            end)
            row1:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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
        delBtn:EnableMouse(true)
        delBtn:SetHitRectInsets(0, 0, 0, 0)
        delBtn:SetWidth(14)
        delBtn:SetHeight(14)
        delBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
        delBtn:SetNormalFontObject(GameFontNormalSmall)
        delBtn:SetHighlightFontObject(GameFontHighlightSmall)
        delBtn:SetText("|cffff4444x|r")
        delBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        delBtn:SetScript("OnEnter", function(self)
            self:SetText("|cffff8888x|r")
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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
        delBtn:EnableMouse(true)
        delBtn:SetHitRectInsets(0, 0, 0, 0)
        delBtn:SetWidth(14)
        delBtn:SetHeight(14)
        delBtn:SetPoint("LEFT", btn, "LEFT", 0, 0)
        delBtn:SetNormalFontObject(GameFontNormalSmall)
        delBtn:SetHighlightFontObject(GameFontHighlightSmall)
        delBtn:SetText("|cffff4444x|r")
        delBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        -- OnEnter/OnLeave (hover visual + item tooltip) set per row in refresh
        btn.deleteBtn = delBtn

        -- Clickable area for tooltip/shift-click/select (no secure child - it hides the list on this client)
        local clickArea = CreateFrame("Button", nil, btn)
        clickArea:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        clickArea:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        clickArea:SetHeight(18)
        clickArea:EnableMouse(true)
        clickArea:SetHitRectInsets(0, 0, 0, 0)
        clickArea:SetFrameLevel(btn:GetFrameLevel() + 2)
        btn.clickArea = clickArea

        -- Persistent selection highlight (same gold as GPH text, brighter for visibility) — 3.3.5: use path + SetVertexColor
        local sel = clickArea:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        sel:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        sel:SetVertexColor(0.92, 0.75, 0.25, 0.32)
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
        hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        hl:SetVertexColor(1, 1, 1, 0.1)
        -- Dark overlay for items with "Cooldown remaining:" (created last so it draws ON TOP of icon/text) — 3.3.5: path + SetVertexColor
        local cooldownOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        cooldownOverlay:SetAllPoints()
        cooldownOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        cooldownOverlay:SetVertexColor(0.08, 0.06, 0.12, 0.92)
        cooldownOverlay:Hide()
        btn.cooldownOverlay = cooldownOverlay
        -- Red overlay for "mark for auto-destroy" (Shift+double-click X)
        local destroyOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        destroyOverlay:SetAllPoints()
        destroyOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        destroyOverlay:SetVertexColor(0.5, 0.05, 0.05)
        destroyOverlay:SetAlpha(0.85)
        destroyOverlay:Hide()
        btn.destroyOverlay = destroyOverlay
        -- Black tint for protected/saved items (drawn on top so it's visible; row stays clickable)
        local protectedOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        protectedOverlay:SetAllPoints()
        protectedOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        protectedOverlay:SetVertexColor(0, 0, 0)
        protectedOverlay:SetAlpha(0.85)
        protectedOverlay:Hide()
        btn.protectedOverlay = protectedOverlay
        -- Previously worn indicator (created last so it draws above the black overlay)
        local prevWornIcon = clickArea:CreateTexture(nil, "OVERLAY")
        prevWornIcon:SetWidth(14)
        prevWornIcon:SetHeight(14)
        prevWornIcon:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        prevWornIcon:Hide()
        btn.prevWornIcon = prevWornIcon
        GPH_ITEM_POOL[GPH_ITEM_POOL_USED] = btn
    end
    btn:SetParent(parent)
    btn:Show()
    btn.deleteBtn:Show()
    btn.clickArea:Show()
    btn.itemLink = nil
    if btn.cooldownOverlay then btn.cooldownOverlay:Hide() end
    if btn.destroyOverlay then btn.destroyOverlay:Hide() end
    if btn.protectedOverlay then btn.protectedOverlay:Hide() end
    if btn.prevWornIcon then btn.prevWornIcon:Hide() end
    return btn
end

--- Spell IDs for profession abilities (WotLK 3.3.5) as fallback when spell book scan fails.
local GPH_SPELL_IDS = { Disenchant = 13262, Prospecting = 31252 }

--- True if the player has a spell whose name contains spellName (e.g. "Disenchant" matches "Disenchant (Rank 1)").
local function IsSpellKnownByName(spellName)
    if not spellName or spellName == "" then return false end
    local sid = GPH_SPELL_IDS[spellName]
    if sid and IsSpellKnown and IsSpellKnown(sid) then return true end
    local bookType = BOOKTYPE_SPELL or "spell"
    local n = (GetNumSpellBookItems and GetNumSpellBookItems(bookType)) or (GetNumSpellBookItems and GetNumSpellBookItems()) or 0
    if n <= 0 then n = 300 end
    for i = 1, math.min(n, 300) do
        local name = (GetSpellBookItemName and GetSpellBookItemName(i, bookType)) or (GetSpellBookItemName and GetSpellBookItemName(i, "spell")) or (GetSpellBookItemName and GetSpellBookItemName(i))
        if name and name:find(spellName, 1, true) then return true end
    end
    return false
end

--- Returns spell name (Disenchant/Prospecting) if bag/slot is destroyable, else nil.
--- DE: Armor/Weapon quality 2-4; Prospect: tooltip ITEM_PROSPECTABLE’s
local gphDestroyScanTooltip
local function EnsureGphDestroyScanTooltip()
    if not gphDestroyScanTooltip then
        gphDestroyScanTooltip = CreateFrame("GameTooltip", "FugaziGPHDestroyScanTooltip", UIParent, "GameTooltipTemplate")
        gphDestroyScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
end

--- Extracts Requires Level and Item Level from the item tooltip (WotLK 3.3.5a).
local function GetRequiredAndItemLevelForDestroy(bag, slot)
    EnsureGphDestroyScanTooltip()
    gphDestroyScanTooltip:ClearLines()
    gphDestroyScanTooltip:SetBagItem(bag, slot)
    local reqLevel, itemLevel = 0, 0
    local n = gphDestroyScanTooltip:NumLines() or 0
    for i = 1, n do
        local left = _G["FugaziGPHDestroyScanTooltipTextLeft" .. i]
        local text = left and left:GetText()
        if text then
            local r = text:match("Requires Level%s+(%d+)")
            if r then reqLevel = tonumber(r) or reqLevel end
            local l = text:match("Item Level%s+(%d+)")
            if l then itemLevel = tonumber(l) or itemLevel end
        end
    end
    return reqLevel, itemLevel
end

--- Returns spell name (Disenchant/Prospecting) if bag/slot is destroyable, else nil.
local function GPHIsDestroyable(bag, slot, link)
    if not link then return nil end
    local itemId = tonumber(link:match("item:(%d+)"))
    if itemId == 6948 then return nil end  -- hearthstone

    local hasDE = IsSpellKnownByName("Disenchant")
    local hasProspect = IsSpellKnownByName("Prospecting")

    EnsureGphDestroyScanTooltip()
    gphDestroyScanTooltip:ClearLines()
    gphDestroyScanTooltip:SetBagItem(bag, slot)

    -- Disenchant: only Armor/Weapon and quality 2+ (Uncommon/Rare/Epic). No Poor (0) or Common (1).
    if hasDE and bag and slot then
        local _, _, quality, _, _, itemType = GetItemInfo(link)
        if (itemType == "Armor" or itemType == "Weapon") and quality and quality >= 2 and quality <= 4 then
            local ttRecipe, ttProspect = false, false
            for i = 1, gphDestroyScanTooltip:NumLines() do
                local left = _G["FugaziGPHDestroyScanTooltipTextLeft" .. i]
                local text = left and left:GetText()
                if text then
                    local t = text:lower()
                    if t:find("recipe", 1, true) or t:find("teaches", 1, true) then ttRecipe = true end
                    if text == (ITEM_PROSPECTABLE or "Can be prospected") or t:find("prospect", 1, true) then ttProspect = true end
                end
            end
            if not ttRecipe and not ttProspect then
                return GetSpellInfo(GPH_SPELL_IDS.Disenchant) or "Disenchant"
            end
        end
    end

    -- Prospect: tooltip must show ITEM_PROSPECTABLE (same as before - this is why prospect works).
    if hasProspect and bag and slot then
        for i = 1, gphDestroyScanTooltip:NumLines() do
            local left = _G["FugaziGPHDestroyScanTooltipTextLeft" .. i]
            local text = left and left:GetText()
            if text and (text == (ITEM_PROSPECTABLE or "Can be prospected") or text:find("Prospect", 1, true)) then
                return GetSpellInfo(GPH_SPELL_IDS.Prospecting) or "Prospecting"
            end
        end
    end
    return nil
end

--- First destroyable item in bags: bag, slot, spellName, link. Order: prefer Prospect if preferProspect else DE; sort by quality then iLevel.
local function GetFirstDestroyableInBags(preferProspect)
    local hasDE = IsSpellKnownByName("Disenchant")
    local hasProspect = IsSpellKnownByName("Prospecting")
    local list = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                if link then
                    local spell = GPHIsDestroyable(bag, slot, link)
                    if spell then
                        local _, _, quality = GetItemInfo(link)
                        quality = quality or 0
                        -- Use tooltip for reqLevel/iLevel (same source as "Requires Level 21" / "Item Level 26") so sort is correct even when GetItemInfo is uncached.
                        local reqLevel, itemLevel = GetRequiredAndItemLevelForDestroy(bag, slot)
                        table.insert(list, {
                            bag = bag,
                            slot = slot,
                            spell = spell,
                            isDE = spell:find("Disenchant", 1, true),
                            quality = quality,
                            reqLevel = reqLevel or 0,
                            iLevel = itemLevel or 0,
                            link = link,
                        })
                    end
                end
            end
        end
    end
    if #list == 0 then return nil end
    -- Sort for DE/prospect: safest/junk-first order:
    --   1) lowest required level first
    --   2) then lowest item level
    table.sort(list, function(a, b)
        local ar, br = a.reqLevel or 0, b.reqLevel or 0
        if ar ~= br then return ar < br end
        local ai, bi = a.iLevel or 0, b.iLevel or 0
        return ai < bi
    end)
    local function pick(deFirst)
        for i = 1, #list do
            local e = list[i]
            if deFirst and e.isDE then return e.bag, e.slot, e.spell, e.link end
            if not deFirst and not e.isDE then return e.bag, e.slot, e.spell, e.link end
        end
        return nil
    end
    if preferProspect and hasProspect then
        local b, s, sp, link = pick(false)
        if b then return b, s, sp, link end
    end
    if hasDE then
        local b, s, sp, link = pick(true)
        if b then return b, s, sp, link end
    end
    if hasProspect and not preferProspect then
        local b, s, sp, link = pick(false)
        if b then return b, s, sp, link end
    end
    return nil
end

--- Return bag, slot for the first stack of itemId in bags, or nil.
local function GetBagSlotForItemId(itemId)
    if not itemId then return nil end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                if link then
                    local id = tonumber(link:match("item:(%d+)"))
                    if id == itemId then return bag, slot end
                end
            end
        end
    end
    return nil
end

--- Return bag, slot, stackCount for first stack of itemId with at least minCount (for split). Returns nil if none.
--- 3.3.5: use GetContainerItemID when available; itemCount = select(2, GetContainerItemInfo(bag, slot)).
local function GetBagSlotWithAtLeast(itemId, minCount)
    if not itemId or not minCount or minCount < 1 then return nil end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local id = GetContainerItemID and GetContainerItemID(bag, slot)
                if not id and GetContainerItemLink then
                    local link = GetContainerItemLink(bag, slot)
                    if link then id = tonumber(link:match("item:(%d+)")) end
                end
                if id == itemId then
                    local stackCount = GetContainerItemInfo and select(2, GetContainerItemInfo(bag, slot))
                    stackCount = (stackCount and stackCount > 0) and stackCount or 1
                    if stackCount >= minCount then
                        return bag, slot, stackCount
                    end
                end
            end
        end
    end
    return nil
end

StaticPopupDialogs["INSTANCETRACKER_GPH_DISENCHANT_EPIC"] = {
    text = "Disenchant Epic/Legendary item?",
    button1 = "Disenchant",
    button2 = "Cancel",
    OnAccept = function(self)
        local bag, slot = self.data and self.data.bag, self.data and self.data.slot
        if bag and slot then
            CastSpellByName("Disenchant")
            if SpellTargetItem then SpellTargetItem(bag, slot) end
            if gphFrame and RefreshGPHUI then RefreshGPHUI() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN"] = {
    text = "This is equipment you were previously wearing. Delete from bags?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self)
        local d = self.data
        if d and d.itemId then
            if GetGphProtectedSet then GetGphProtectedSet()[d.itemId] = nil end
            DeleteGPHItem(d.itemId, d.count or 1)
            if gphDeleteClickTime then gphDeleteClickTime[d.itemId] = nil end
            RefreshGPHUI()
        end
    end,
    OnCancel = function(self)
        local d = self.data
        if d and d.itemId and gphDeleteClickTime then gphDeleteClickTime[d.itemId] = nil end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["INSTANCETRACKER_GPH_DESTROY_PREVIOUSLY_WORN"] = {
    text = "This is equipment you were previously wearing. Add to auto-destroy list?",
    button1 = "Add to list",
    button2 = "Cancel",
    OnAccept = function(self)
        local itemId = self.data and self.data.itemId
        if itemId then
            InstanceTrackerDB.gphDestroyList = InstanceTrackerDB.gphDestroyList or {}
            local name = GetItemInfo and GetItemInfo(itemId)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(itemId)
            InstanceTrackerDB.gphDestroyList[itemId] = { name = name, texture = tex }
            QueueDestroySlotsForItemId(itemId)
            if gphFrame and RefreshGPHUI then RefreshGPHUI() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["INSTANCETRACKER_GPH_DESTROY_EPIC"] = {
    text = "Mark this Epic/Legendary for auto-destroy? It will be deleted from bags while marked.",
    button1 = "Mark",
    button2 = "Cancel",
    OnAccept = function(self)
        local itemId = self.data and self.data.itemId
        if itemId then
            InstanceTrackerDB.gphDestroyList = InstanceTrackerDB.gphDestroyList or {}
            local name = GetItemInfo and GetItemInfo(itemId)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(itemId)
            InstanceTrackerDB.gphDestroyList[itemId] = { name = name, texture = tex }
            QueueDestroySlotsForItemId(itemId)
            if gphFrame and RefreshGPHUI then RefreshGPHUI() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["INSTANCETRACKER_GPH_UNMARK_PROTECTED"] = {
    text = "Remove (*) protection from this item?\nIt will no longer be protected from auto-sell or auto-destroy.",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self)
        local id = (self.data and self.data.itemId) or (gphFrame and gphFrame.gphUnmarkItemId)
        if gphFrame then gphFrame.gphUnmarkItemId = nil end
        if id and GetGphProtectedSet then
            GetGphProtectedSet()[id] = nil
            if gphFrame and RefreshGPHUI then RefreshGPHUI() end
        end
    end,
    OnCancel = function(self)
        if gphFrame then gphFrame.gphUnmarkItemId = nil end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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

--- Create the GPH window (timer, items list, sort). Starts hidden.
local function CreateGPHFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 2, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "InstanceTrackerGPHFrame", UIParent)
    f:SetWidth(340)
    f:SetHeight(400)
    f:SetPoint("TOP", UIParent, "CENTER", 0, -100)
    f:Hide()  -- start hidden so first /fit gph or first GPH button click actually shows it (toggle was hiding it immediately)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        -- Clear selection when drag starts so overlay is off row — prevents list sticking when window is moved (can't drag and select at same time).
        if f.gphSelectedItemId then
            f.gphSelectedItemId = nil
            f.gphSelectedIndex = nil
            f.gphSelectedRowBtn = nil
            f.gphSelectedItemLink = nil
            if f.gphRightClickUseOverlay and f.scrollFrame then
                f.gphRightClickUseOverlay:SetParent(f.scrollFrame)
                f.gphRightClickUseOverlay:ClearAllPoints()
                f.gphRightClickUseOverlay:SetPoint("BOTTOMLEFT", f.scrollFrame, "BOTTOMLEFT", -9999, -9999)
                f.gphRightClickUseOverlay:SetSize(0, 0)
                f.gphRightClickUseOverlay:Hide()
            end
        end
        f:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        InstanceTrackerDB.gphDockedToMain = false
        SaveFrameLayout(f, "gphShown", "gphPoint")
    end)
    f:SetScript("OnHide", function()
        SaveFrameLayout(f, "gphShown", "gphPoint")
    end)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(10)
    f.EXPANDED_HEIGHT = 400

    -- ESC clears pending rarity DEL state (same as right-click on rarity bar). Use a hidden EditBox so ESC is reliably caught in 3.3.5.
    local gphEscCatcher = CreateFrame("EditBox", nil, f)
    gphEscCatcher:SetAutoFocus(false)
    gphEscCatcher:SetSize(1, 1)
    gphEscCatcher:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -1000, 0)
    gphEscCatcher:Hide()
    gphEscCatcher:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:Hide()
        if not gphPendingQuality then return end
        local hadPending = false
        for q in pairs(gphPendingQuality) do
            gphPendingQuality[q] = nil
            hadPending = true
        end
        if hadPending and RefreshGPHUI then RefreshGPHUI() end
    end)
    f.gphEscCatcher = gphEscCatcher

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -6)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    f.gphTitleBar = titleBar
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText("GPH")
    title:SetTextColor(1, 0.85, 0.4, 1)
    f.gphTitle = title

    local GPH_BTN_W, GPH_BTN_H = 36, 18
    local GPH_BTN_GAP = 2

    -- Order left-to-right: pet, magnifier, bag, (enchant when has profession). Anchors set after sum/scale exist below.
    local invBtn = CreateFrame("Button", nil, titleBar)
    invBtn:EnableMouse(true)
    invBtn:SetHitRectInsets(0, 0, 0, 0)
    invBtn:SetSize(22, GPH_BTN_H)
    invBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    local invBg = invBtn:CreateTexture(nil, "BACKGROUND")
    invBg:SetAllPoints()
    invBtn.bg = invBg
    local GPH_ICON_SZ = 16  -- 1–2px smaller than button height (18)
    local invIcon = invBtn:CreateTexture(nil, "ARTWORK")
    invIcon:SetWidth(GPH_ICON_SZ)
    invIcon:SetHeight(GPH_ICON_SZ)
    invIcon:SetPoint("CENTER")
    invIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
    invBtn.icon = invIcon
    f.gphInvBtn = invBtn
    local function UpdateInvBtn()
        if InstanceTrackerDB.gphInvKeybind then
            invBtn.bg:SetTexture(0.4, 0.35, 0.2, 0.8)
        else
            invBtn.bg:SetTexture(0.45, 0.12, 0.1, 0.8)
        end
    end
    local function ShowInvTooltip()
        GameTooltip:SetOwner(invBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(InstanceTrackerDB.gphInvKeybind and "Inventory key opens GPH (on)" or "Inventory key opens GPH (off)", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("When on: bag key toggles GPH instead of default bags (like Bagnon)", 0.6, 0.6, 0.5)
        GameTooltip:AddLine("Click to toggle", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end
    invBtn:SetScript("OnClick", function()
        InstanceTrackerDB.gphInvKeybind = not InstanceTrackerDB.gphInvKeybind
        if InstanceTrackerDB.gphInvKeybind then
            InstallGPHInvHook()
            if f.gphInvKeybindBtn then
                f.gphInvKeybindBtn:Show()
                f.gphInvKeybindBtn:SetAlpha(1)
                ApplyGPHInvKeyOverride(f.gphInvKeybindBtn)
            end
        else
            RemoveGPHInvHook()
            if f.gphInvKeybindBtn then
                f.gphInvKeybindBtn:SetAlpha(0)
                f.gphInvKeybindBtn:Hide()
            end
            if _G.InstanceTrackerKeybindOwner and ClearOverrideBindings then ClearOverrideBindings(_G.InstanceTrackerKeybindOwner) end
        end
        UpdateInvBtn()
        if GameTooltip:GetOwner() == invBtn then ShowInvTooltip() end
    end)
    invBtn:SetScript("OnEnter", function()
        if InstanceTrackerDB.gphInvKeybind then invBtn.bg:SetTexture(0.5, 0.45, 0.2, 0.9)
        else invBtn.bg:SetTexture(0.55, 0.2, 0.15, 0.9) end
        ShowInvTooltip()
    end)
    invBtn:SetScript("OnLeave", function() UpdateInvBtn(); GameTooltip:Hide() end)
    UpdateInvBtn()

    -- Button for keybind override (inventory key -> open GPH); parent to owner so override can trigger it
    local keybindOwner = _G.InstanceTrackerKeybindOwner or CreateFrame("Frame", "InstanceTrackerKeybindOwner", UIParent)
    _G.InstanceTrackerKeybindOwner = keybindOwner
    local invKeybindBtn = CreateFrame("Button", "InstanceTrackerGPHInvKeybindBtn", keybindOwner, "SecureActionButtonTemplate")
    invKeybindBtn:SetAttribute("type", "macro")
    invKeybindBtn:SetAttribute("macrotext", "/run ToggleGPHFrame()")
    invKeybindBtn:SetSize(1, 1)
    invKeybindBtn:SetPoint("BOTTOMLEFT", keybindOwner, "BOTTOMLEFT", -10000, -10000)
    invKeybindBtn:SetAlpha(0)
    invKeybindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    invKeybindBtn:Hide()
    f.gphInvKeybindBtn = invKeybindBtn

    -- Close (rightmost)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Collapse (hide) — direct child of f; next to close so order left-to-right: ... sort, collapse, close
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:EnableMouse(true)
    collapseBtn:SetHitRectInsets(0, 0, 0, 0)
    collapseBtn:SetSize(22, GPH_BTN_H)
    collapseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -GPH_BTN_GAP, 0)
    collapseBtn:SetFrameLevel(f:GetFrameLevel() + 50)
    f.gphCollapseBtn = collapseBtn
    local collapseBg = collapseBtn:CreateTexture(nil, "BACKGROUND")
    collapseBg:SetAllPoints()
    collapseBtn.bg = collapseBg
    local collapseIcon = collapseBtn:CreateTexture(nil, "ARTWORK")
    collapseIcon:SetWidth(GPH_ICON_SZ)
    collapseIcon:SetHeight(GPH_ICON_SZ)
    collapseIcon:SetPoint("CENTER")
    collapseBtn.icon = collapseIcon
    if InstanceTrackerDB.gphCollapsed == nil then InstanceTrackerDB.gphCollapsed = false end
    -- Set textures immediately so button is visible before scrollFrame exists (UpdateGPHCollapse returns early until then)
    if InstanceTrackerDB.gphCollapsed then
        collapseBg:SetTexture(0.4, 0.35, 0.2, 0.8)
        collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
    else
        collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
        collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
    end
    local function UpdateGPHCollapse()
        if not f.scrollFrame then return end
        if f.gphCollapseBtn then f.gphCollapseBtn:Show(); f.gphCollapseBtn:SetFrameLevel(f:GetFrameLevel() + 50) end
        if InstanceTrackerDB.gphCollapsed then
            collapseBg:SetTexture(0.4, 0.35, 0.2, 0.8)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            local collH = InstanceTrackerDB.gphDockedToMain and 150 or 70
            CollapseInPlace(f, collH, function(rel)
                return rel == frame or rel == _G.InstanceTrackerFrame
            end)
            f.statusText:Show()
            f.gphSep:Show()
            if f.gphSearchBtn then f.gphSearchBtn:Hide() end
            if f.gphSearchEditBox then f.gphSearchEditBox:Hide() end
            if f.gphSortBtn then f.gphSortBtn:Hide() end
            if f.toggleBtn then
                f.toggleBtn:ClearAllPoints()
                f.toggleBtn:SetPoint("RIGHT", f.gphCollapseBtn, "LEFT", -GPH_BTN_GAP, 0)
            end
            if f.gphHeader then f.gphHeader:Hide() end
            f.scrollFrame:Hide()
            if f.gphBottomBar then
                f.gphBottomBar:ClearAllPoints()
                f.gphBottomBar:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, 0)
                f.gphBottomBar:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, 0)
            end
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            if f.gphStatusLeft then f.gphStatusLeft:Hide() end
            if f.gphStatusCenter then f.gphStatusCenter:Hide() end
            if f.gphStatusRight then f.gphStatusRight:Hide() end
            f.statusText:Show()
            f.gphSep:Show()
            if f.gphSearchBtn then f.gphSearchBtn:Show() end
            if f.gphSearchEditBox then
                if f.gphSearchBarVisible then f.gphSearchEditBox:Show() else f.gphSearchEditBox:Hide() end
            end
            if f.gphSortBtn then f.gphSortBtn:Show() end
            if f.toggleBtn then
                f.toggleBtn:ClearAllPoints()
                f.toggleBtn:SetPoint("RIGHT", f.gphSortBtn, "LEFT", -GPH_BTN_GAP, 0)
            end
            if f.gphHeader then f.gphHeader:Show() end
            f.scrollFrame:Show()
            if f.gphBottomBar then
                f.gphBottomBar:ClearAllPoints()
                f.gphBottomBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
                f.gphBottomBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
            end
        end
    end
    UpdateGPHCollapse()
    local function ShowCollapseTooltip()
        GameTooltip:SetOwner(collapseBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(InstanceTrackerDB.gphCollapsed and "Expand" or "Collapse", 0.5, 0.8, 1)
        GameTooltip:Show()
    end
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.gphCollapsed = not InstanceTrackerDB.gphCollapsed
        UpdateGPHCollapse()
        f._refreshImmediate = true
        RefreshGPHUI()
        if GameTooltip:GetOwner() == collapseBtn then ShowCollapseTooltip() end
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.4, 0.15, 0.8)
        ShowCollapseTooltip()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateGPHCollapse(); GameTooltip:Hide() end)

    -- Rarity/Vendor toggle (sort): left of collapse; icon toggle (coin = vendor, epic gem = rarity)
    local sortBtn = CreateFrame("Button", nil, f)
    sortBtn:EnableMouse(true)
    sortBtn:SetHitRectInsets(0, 0, 0, 0)
    sortBtn:SetSize(22, GPH_BTN_H)
    sortBtn:SetPoint("RIGHT", collapseBtn, "LEFT", -GPH_BTN_GAP, 0)
    local sortBtnBg = sortBtn:CreateTexture(nil, "BACKGROUND")
    sortBtnBg:SetAllPoints()
    sortBtnBg:SetTexture(0.35, 0.28, 0.1, 0.7)
    sortBtn.bg = sortBtnBg
    local sortIcon = sortBtn:CreateTexture(nil, "ARTWORK")
    sortIcon:SetPoint("CENTER")
    sortIcon:SetSize(GPH_ICON_SZ, GPH_ICON_SZ)
    sortBtn.icon = sortIcon
    f.gphSortBtn = sortBtn
    local function UpdateGPHSortIcon()
        if InstanceTrackerDB.gphSortMode == nil then InstanceTrackerDB.gphSortMode = "rarity" end
        if InstanceTrackerDB.gphSortMode ~= "vendor" and InstanceTrackerDB.gphSortMode ~= "rarity" and InstanceTrackerDB.gphSortMode ~= "itemlevel" then
            InstanceTrackerDB.gphSortMode = "rarity"
        end
        if InstanceTrackerDB.gphSortMode == "vendor" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        elseif InstanceTrackerDB.gphSortMode == "itemlevel" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
        else
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01")
        end
    end
    UpdateGPHSortIcon()
    local function ShowSortTooltip(btn)
        btn = btn or sortBtn
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        local mode = InstanceTrackerDB.gphSortMode or "rarity"
        if mode == "vendor" then
            GameTooltip:AddLine("Vendorprice", 0.7, 0.8, 1)
        elseif mode == "itemlevel" then
            GameTooltip:AddLine("ItemLvl", 0.7, 0.8, 1)
        else
            GameTooltip:AddLine("Rarity", 0.7, 0.8, 1)
        end
        GameTooltip:Show()
    end
    sortBtn:SetScript("OnClick", function()
        local mode = InstanceTrackerDB.gphSortMode or "rarity"
        if mode == "rarity" then
            InstanceTrackerDB.gphSortMode = "vendor"
        elseif mode == "vendor" then
            InstanceTrackerDB.gphSortMode = "itemlevel"
        else
            InstanceTrackerDB.gphSortMode = "rarity"
        end
        UpdateGPHSortIcon()
        RefreshGPHUI()
        if GameTooltip:GetOwner() == sortBtn then ShowSortTooltip(sortBtn) end
    end)
    sortBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.4, 0.15, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        ShowSortTooltip(self)
    end)
    sortBtn:SetScript("OnLeave", function()
        UpdateGPHSortIcon()
        sortBtn.bg:SetTexture(0.35, 0.28, 0.1, 0.7)
        GameTooltip:Hide()
    end)

    -- Scale ×1.5: between pet and bag; magnifying glass icon; reposition frame so button stays under cursor when toggling
    local scaleBtn = CreateFrame("Button", nil, titleBar)
    scaleBtn:EnableMouse(true)
    scaleBtn:SetHitRectInsets(0, 0, 0, 0)
    scaleBtn:SetSize(22, GPH_BTN_H)
    scaleBtn:SetPoint("LEFT", invBtn, "RIGHT", GPH_BTN_GAP, 0)
    local scaleBg = scaleBtn:CreateTexture(nil, "BACKGROUND")
    scaleBg:SetAllPoints()
    scaleBtn.bg = scaleBg
    local scaleIcon = scaleBtn:CreateTexture(nil, "ARTWORK")
    scaleIcon:SetWidth(GPH_ICON_SZ)
    scaleIcon:SetHeight(GPH_ICON_SZ)
    scaleIcon:SetPoint("CENTER")
    scaleIcon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_01")
    scaleBtn.icon = scaleIcon
    f.gphScaleBtn = scaleBtn
    local function UpdateScaleBtn()
        if InstanceTrackerDB.gphScale15 then
            scaleBtn.bg:SetTexture(0.4, 0.35, 0.2, 0.8)
            f:SetScale(1.5)
        else
            scaleBtn.bg:SetTexture(0.28, 0.22, 0.12, 0.7)
            f:SetScale(1)
        end
    end
    local function ShowScaleTooltip()
        GameTooltip:SetOwner(scaleBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(InstanceTrackerDB.gphScale15 and "Scale 1.5× (on)" or "Scale 1.5× (off)", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("Click to toggle", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end
    scaleBtn:SetScript("OnClick", function()
        InstanceTrackerDB.gphScale15 = not InstanceTrackerDB.gphScale15
        UpdateScaleBtn()
        if GameTooltip:GetOwner() == scaleBtn then ShowScaleTooltip() end
    end)
    scaleBtn:SetScript("OnEnter", function()
        scaleBtn.bg:SetTexture(0.5, 0.4, 0.15, 0.8)
        ShowScaleTooltip()
    end)
    scaleBtn:SetScript("OnLeave", function() UpdateScaleBtn(); GameTooltip:Hide() end)
    UpdateScaleBtn()

    -- GPH Vendor (pet): leftmost of the four; order will be pet, magnifier, bag, enchant.
    if InstanceTrackerDB.gphSummonGreedy == nil then InstanceTrackerDB.gphSummonGreedy = true end
    local sumBtn = CreateFrame("Button", nil, titleBar)
    sumBtn:EnableMouse(true)
    sumBtn:SetHitRectInsets(0, 0, 0, 0)
    sumBtn:SetSize(22, GPH_BTN_H)
    sumBtn:SetPoint("LEFT", scaleBtn, "RIGHT", GPH_BTN_GAP, 0)
    local sumBg = sumBtn:CreateTexture(nil, "BACKGROUND")
    sumBg:SetAllPoints()
    sumBtn.bg = sumBg
    local sumIcon = sumBtn:CreateTexture(nil, "ARTWORK")
    sumIcon:SetPoint("CENTER")
    sumIcon:SetSize(GPH_ICON_SZ, GPH_ICON_SZ)
    sumBtn.icon = sumIcon
    f.gphSummonBtn = sumBtn
    local function UpdateGphSummonBtn()
        local on = InstanceTrackerDB.gphSummonGreedy ~= false
        if on then
            sumBg:SetTexture(0.25, 0.4, 0.2, 0.85)
            sumIcon:SetVertexColor(1, 1, 1)
            if GphIsGoblinMerchantSummoned() then
                sumIcon:SetTexture("Interface\\Icons\\achievement_goblinhead")
            else
                sumIcon:SetTexture("Interface\\Icons\\inv_harvestgolempet")
            end
        else
            sumBg:SetTexture(0.4, 0.12, 0.1, 0.85)
            sumIcon:SetVertexColor(1, 0.85, 0.85)
            sumIcon:SetTexture("Interface\\Icons\\inv_harvestgolempet")
        end
    end
    sumBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    sumBtn:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            -- Always resummon Greedy: if already out, dismiss then summon so spamming RMB resummons (pet catches up when it lags)
            if GphIsGreedySummoned() then
                GphDismissCurrentCompanion()
            end
            DoGphSummonGreedyNow()
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            return
        end
        -- LeftButton: toggle auto-summon
        InstanceTrackerDB.gphSummonGreedy = InstanceTrackerDB.gphSummonGreedy == false
        UpdateGphSummonBtn()
        if InstanceTrackerDB.gphSummonGreedy ~= false and not GphIsGreedySummoned() then
            DoGphSummonGreedyNow()
        end
    end)
    local function ShowGphSummonTooltip()
        GameTooltip:SetOwner(sumBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("LMB: AutoSummon " .. (InstanceTrackerDB.gphSummonGreedy ~= false and "(on)" or "(off)"), 0.9, 0.8, 0.5)
        GameTooltip:AddLine("RMB: Summon Pet", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    sumBtn:SetScript("OnEnter", function()
        sumBg:SetTexture(0.4, 0.35, 0.2, 0.9)
        ShowGphSummonTooltip()
    end)
    sumBtn:SetScript("OnLeave", function() UpdateGphSummonBtn(); GameTooltip:Hide() end)
    sumBtn:SetScript("OnUpdate", function(self)
        if GameTooltip:GetOwner() == self then ShowGphSummonTooltip() end
    end)
    f.UpdateGphSummonBtn = UpdateGphSummonBtn
    UpdateGphSummonBtn()

    -- Left-to-right: pet (if owned), magnifier, bag, (enchant when has DE/Prospect). Hide pet button and shift others left when player doesn't have Greedy.
    local function UpdateGphTitleBarButtonLayout()
        local hasGreedy = GphPlayerHasGreedyCompanion()
        if hasGreedy then
            sumBtn:Show()
            sumBtn:ClearAllPoints()
            sumBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
            scaleBtn:ClearAllPoints()
            scaleBtn:SetPoint("LEFT", sumBtn, "RIGHT", GPH_BTN_GAP, 0)
        else
            sumBtn:Hide()
            scaleBtn:ClearAllPoints()
            scaleBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
        end
        invBtn:ClearAllPoints()
        invBtn:SetPoint("LEFT", scaleBtn, "RIGHT", GPH_BTN_GAP, 0)
    end
    f.UpdateGphTitleBarButtonLayout = UpdateGphTitleBarButtonLayout
    UpdateGphTitleBarButtonLayout()

    -- Start/Stop: same textures as Blizzard stopwatch (Interface\TimeManager, Interface\Buttons)
    local toggleBtn = CreateFrame("Button", nil, f)
    toggleBtn:EnableMouse(true)
    toggleBtn:SetHitRectInsets(0, 0, 0, 0)
    toggleBtn:SetSize(22, GPH_BTN_H)
    toggleBtn:SetPoint("RIGHT", sortBtn, "LEFT", -GPH_BTN_GAP, 0)
    local toggleBg = toggleBtn:CreateTexture(nil, "BACKGROUND")
    toggleBg:SetAllPoints()
    toggleBtn.bg = toggleBg
    local toggleIcon = toggleBtn:CreateTexture(nil, "ARTWORK")
    toggleIcon:SetWidth(GPH_ICON_SZ)
    toggleIcon:SetHeight(GPH_ICON_SZ)
    toggleIcon:SetPoint("CENTER")
    toggleBtn.icon = toggleIcon
    f.toggleBtn = toggleBtn

    -- Reset (same texture as Blizzard stopwatch: Interface\TimeManager\ResetButton)
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:EnableMouse(true)
    resetBtn:SetHitRectInsets(0, 0, 0, 0)
    resetBtn:SetSize(22, GPH_BTN_H)
    resetBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -GPH_BTN_GAP, 0)
    local resetBg = resetBtn:CreateTexture(nil, "BACKGROUND")
    resetBg:SetAllPoints()
    resetBg:SetTexture(0.25, 0.15, 0.1, 0.7)
    resetBtn.bg = resetBg
    local resetIcon = resetBtn:CreateTexture(nil, "ARTWORK")
    resetIcon:SetWidth(GPH_ICON_SZ)
    resetIcon:SetHeight(GPH_ICON_SZ)
    resetIcon:SetPoint("CENTER")
    resetIcon:SetTexture("Interface\\TimeManager\\ResetButton")
    resetBtn.icon = resetIcon
    resetBtn:SetScript("OnClick", function() StaticPopup_Show("INSTANCETRACKER_RESET_GPH") end)
    resetBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.4, 0.25, 0.1, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset Session", 1, 0.6, 0.2)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.25, 0.15, 0.1, 0.7)
        GameTooltip:Hide()
    end)
    f.gphResetBtn = resetBtn

    -- Play = spellbook next-page arrow; Stop = TimeManager pause (same as in-game stopwatch)
    local GPH_PLAY_TEXTURE  = "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"
    local GPH_STOP_TEXTURE = "Interface\\TimeManager\\PauseButton"
    local function UpdateToggleBtn()
        if gphSession then
            toggleBtn.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
            toggleBtn.icon:SetTexture(GPH_STOP_TEXTURE)
            resetBtn:Show()
        else
            toggleBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7)
            toggleBtn.icon:SetTexture(GPH_PLAY_TEXTURE)
            resetBtn:Hide()
        end
    end
    f.updateToggle = UpdateToggleBtn
    UpdateToggleBtn()
    toggleBtn:SetScript("OnClick", function()
        if gphSession then StopGPHSession() else StartGPHSession() end
        UpdateToggleBtn()
        RefreshGPHUI()
    end)
    local function ShowToggleTooltip()
        GameTooltip:SetOwner(toggleBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        if gphSession then
            GameTooltip:AddLine("Stop GPH Session", 1, 0.6, 0.2)
        else
            GameTooltip:AddLine("Start GPH Session", 0.4, 0.9, 0.5)
            GameTooltip:AddLine("Tracks gold/hr and loot", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end
    toggleBtn:SetScript("OnEnter", function(self)
        if gphSession then
            self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
        else
            self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
        end
        ShowToggleTooltip()
    end)
    toggleBtn:SetScript("OnLeave", function() UpdateToggleBtn(); GameTooltip:Hide() end)
    toggleBtn:SetScript("OnUpdate", function(self)
        if GameTooltip:GetOwner() ~= self then return end
        local t = GetTime()
        if t - (self.gphToggleTooltipTime or 0) < 0.2 then return end
        self.gphToggleTooltipTime = t
        ShowToggleTooltip()
    end)

    -- One-click destroy: SecureActionButton macro; PreClick sets macrotext to /cast Spell + /use bag slot.
    if InstanceTrackerDB.gphDestroyPreferProspect == nil then InstanceTrackerDB.gphDestroyPreferProspect = false end

    local destroyBtn = CreateFrame("Button", nil, f, "SecureActionButtonTemplate")
    destroyBtn:SetSize(22, GPH_BTN_H)
    destroyBtn:SetPoint("LEFT", invBtn, "RIGHT", GPH_BTN_GAP, 0)
    destroyBtn:SetFrameLevel((f:GetFrameLevel() or 0) + 20)
    destroyBtn:EnableMouse(true)
    destroyBtn:SetHitRectInsets(0, 0, 0, 0)
    destroyBtn:RegisterForClicks("AnyUp")
    destroyBtn:SetAttribute("type1", "macro")
    destroyBtn:SetAttribute("macrotext1", "")
    local destroyBg = destroyBtn:CreateTexture(nil, "BACKGROUND")
    destroyBg:SetAllPoints()
    destroyBg:SetTexture(0.4, 0.35, 0.2, 0.8)
    destroyBtn.bg = destroyBg
    local destroyIcon = destroyBtn:CreateTexture(nil, "ARTWORK")
    destroyIcon:SetWidth(GPH_ICON_SZ - 1)
    destroyIcon:SetHeight(GPH_ICON_SZ - 1)
    destroyIcon:SetPoint("CENTER")
    destroyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    destroyIcon:SetAlpha(0.9)
    destroyBtn.icon = destroyIcon
    local function UpdateDestroyButtonAppearance()
        local hasDE = IsSpellKnownByName("Disenchant")
        local hasProspect = IsSpellKnownByName("Prospecting")
        local preferProspect = InstanceTrackerDB.gphDestroyPreferProspect and hasProspect and hasDE
        local iconPath
        if preferProspect or (hasProspect and not hasDE) then
            local _, _, icon = GetSpellInfo(GPH_SPELL_IDS.Prospecting)
            iconPath = icon
        elseif hasDE then
            local _, _, icon = GetSpellInfo(GPH_SPELL_IDS.Disenchant)
            iconPath = icon
        end
        if iconPath then
            destroyIcon:SetTexture(iconPath)
            destroyIcon:Show()
        else
            destroyIcon:Hide()
        end
    end
    destroyBtn:SetScript("PreClick", function(self, button, down)
        -- Set macrotext immediately before click (secure button requires it at click time)
        if button ~= "LeftButton" then
            self:SetAttribute("macrotext1", "")
            return
        end
        -- If we're already casting (e.g. Disenchant in progress), ignore this click so we don't /use (equip) the next item.
        if UnitCastingInfo and UnitCastingInfo("player") then
            self:SetAttribute("macrotext1", "")
            return
        end
        if IsShiftKeyDown() then
            -- Shift currently does nothing for this button (we avoid writing saved vars from secure code)
            self:SetAttribute("macrotext1", "")
            return
        end
        local preferProspect = InstanceTrackerDB.gphDestroyPreferProspect
        local bag, slot, spellName = GetFirstDestroyableInBags(preferProspect)
        if not spellName or not bag or not slot then
            self:SetAttribute("macrotext1", "")
            return
        end
        self:SetAttribute("macrotext1", ("/cast %s;\n/use %d %d"):format(spellName, bag, slot))
        self:Disable()
        if f.gphDestroyEnableFrame then f.gphDestroyEnableFrame:SetScript("OnUpdate", nil) end
        local frame = CreateFrame("Frame", nil, f)
        f.gphDestroyEnableFrame = frame
        frame:SetScript("OnUpdate", function(_, elapsed)
            -- Re-enable as soon as you're no longer casting (you can spam the button between casts).
            if not UnitCastingInfo or not UnitCastingInfo("player") then
                frame:SetScript("OnUpdate", nil)
                destroyBtn:Enable()
            end
        end)
    end)
    local function ShowDestroyTooltip()
        GameTooltip:SetOwner(destroyBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Destroy Next (Disenchant / Prospect)", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("One click: cast on next valid item (green+ first).", 0.7, 0.6, 1)
        GameTooltip:Show()
    end
    destroyBtn:SetScript("OnEnter", function()
        destroyBtn.bg:SetTexture(0.5, 0.45, 0.2, 0.9)
        destroyIcon:SetAlpha(1)
        ShowDestroyTooltip()
    end)
    destroyBtn:SetScript("OnLeave", function()
        destroyBtn.bg:SetTexture(0.4, 0.35, 0.2, 0.8)
        destroyIcon:SetAlpha(0.9)
        GameTooltip:Hide()
    end)
    f.gphDestroyBtn = destroyBtn
    f.UpdateDestroyButtonAppearance = UpdateDestroyButtonAppearance
    f.UpdateDestroyMacro = function() end

    local function UpdateGPHProfessionButtons()
        local hasProspect = IsSpellKnownByName("Prospecting")
        local hasDE = IsSpellKnownByName("Disenchant")
        if hasProspect or hasDE then
            f.gphDestroyBtn:Show()
            f.gphDestroyBtn:SetPoint("LEFT", f.gphInvBtn, "RIGHT", GPH_BTN_GAP, 0)
            UpdateDestroyButtonAppearance()
            if f.UpdateDestroyMacro then f.UpdateDestroyMacro() end
        else
            f.gphDestroyBtn:Hide()
        end
    end
    f.UpdateGPHProfessionButtons = UpdateGPHProfessionButtons
    UpdateGPHProfessionButtons()

    -- Top bar: when session active, timer/gold/gph on the right (Gold / Timer / GPH)
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetJustifyH("RIGHT")
    f.statusText = statusText
    statusText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -25, -45)

    -- Collapsed only: gold left, timer center, GPH right (plain FontStrings, no secure frames)
    local gphStatusLeft = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gphStatusLeft:SetJustifyH("LEFT")
    gphStatusLeft:SetPoint("LEFT", f, "TOPLEFT", 10, -48)
    f.gphStatusLeft = gphStatusLeft
    local gphStatusCenter = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gphStatusCenter:SetJustifyH("CENTER")
    gphStatusCenter:SetPoint("CENTER", f, "TOP", 0, -48)
    f.gphStatusCenter = gphStatusCenter
    local gphStatusRight = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gphStatusRight:SetJustifyH("RIGHT")
    gphStatusRight:SetPoint("RIGHT", f, "TOPRIGHT", -10, -48)
    f.gphStatusRight = gphStatusRight
    gphStatusLeft:Hide()
    gphStatusCenter:Hide()
    gphStatusRight:Hide()

    -- GPH Search: same style as frame (gold/amber), filter items in current session
    local gphSearchBtn = CreateFrame("Button", nil, f)
    gphSearchBtn:EnableMouse(true)
    gphSearchBtn:SetHitRectInsets(0, 0, 0, 0)
    gphSearchBtn:SetSize(36, 20)
    gphSearchBtn:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 10, -8)
    local gphSearchBtnBg = gphSearchBtn:CreateTexture(nil, "BACKGROUND")
    gphSearchBtnBg:SetAllPoints()
    gphSearchBtnBg:SetTexture(0.35, 0.28, 0.1, 0.7)
    gphSearchBtn.bg = gphSearchBtnBg
    local gphSearchLabel = gphSearchBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphSearchLabel:SetPoint("CENTER")
    gphSearchLabel:SetText("Search")
    gphSearchLabel:SetTextColor(1, 0.85, 0.4, 1)
    f.gphSearchBtn = gphSearchBtn
    gphSearchBtn:SetScript("OnClick", function()
        f.gphSearchBarVisible = not f.gphSearchBarVisible
        if f.gphSearchEditBox then
            if f.gphSearchBarVisible then
                f.gphSearchEditBox:Show()
                f.gphSearchEditBox:SetFocus()
            else
                f.gphSearchEditBox:Hide()
                f.gphSearchEditBox:SetText("")
                f.gphSearchText = ""
            end
            RefreshGPHUI()
        end
    end)
    gphSearchBtn:SetScript("OnEnter", function(self) self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end)
    gphSearchBtn:SetScript("OnLeave", function(self) self.bg:SetTexture(0.35, 0.28, 0.1, 0.7) end)

    local gphSearchEditBox = CreateFrame("EditBox", nil, f)
    gphSearchEditBox:SetHeight(20)
    gphSearchEditBox:SetPoint("LEFT", gphSearchBtn, "RIGHT", 6, 0)
    gphSearchEditBox:SetPoint("RIGHT", f, "TOPRIGHT", -8, -38)
    gphSearchEditBox:SetAutoFocus(false)
    gphSearchEditBox:SetFontObject("GameFontHighlightSmall")
    gphSearchEditBox:SetTextInsets(6, 4, 0, 0)
    gphSearchEditBox:Hide()
    local gphSearchBg = gphSearchEditBox:CreateTexture(nil, "BACKGROUND")
    gphSearchBg:SetAllPoints()
    gphSearchBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    gphSearchBg:SetVertexColor(0.12, 0.1, 0.06)
    gphSearchBg:SetAlpha(0.95)
    gphSearchEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    gphSearchEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    gphSearchEditBox:SetScript("OnTextChanged", function(self)
        f.gphSearchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        RefreshGPHUI()
    end)
    f.gphSearchEditBox = gphSearchEditBox
    f.gphSearchBarVisible = false
    f.gphSearchText = ""

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", gphSearchBtn, "BOTTOMLEFT", 0, -6)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    sep:SetTexture(1, 1, 1, 0.15)
    f.gphSep = sep

    -- Fixed header (bag + rarity row); same horizontal bounds as sep (left and right anchored to sep).
    local gphHeader = CreateFrame("Frame", nil, f)
    gphHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    gphHeader:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT", 0, -4)
    gphHeader:SetHeight(14)
    f.gphHeader = gphHeader

    -- Bag space display (used/total), same style as Search; row height 14
    local gphBagSpaceBtn = CreateFrame("Frame", nil, gphHeader)
    gphBagSpaceBtn:SetSize(36, 14)
    local bagSpaceBg = gphBagSpaceBtn:CreateTexture(nil, "BACKGROUND")
    bagSpaceBg:SetAllPoints()
    bagSpaceBg:SetTexture(0.35, 0.28, 0.1, 0.7)
    gphBagSpaceBtn.bg = bagSpaceBg
    local bagSpaceFs = gphBagSpaceBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bagSpaceFs:SetPoint("CENTER")
    bagSpaceFs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
    bagSpaceFs:SetTextColor(1, 0.85, 0.4, 1)
    gphBagSpaceBtn.fs = bagSpaceFs
    f.gphBagSpaceBtn = gphBagSpaceBtn

    -- Bottom bar: FPS/latency left, time center, gold right (replaces empty black strip)
    local gphBottomBar = CreateFrame("Frame", nil, f)
    gphBottomBar:SetHeight(20)
    gphBottomBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    gphBottomBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    gphBottomBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    gphBottomBar:SetBackdropColor(0.08, 0.06, 0.04, 0.9)
    gphBottomBar:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.6)
    local gphBottomLeft = gphBottomBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphBottomLeft:SetPoint("LEFT", gphBottomBar, "LEFT", 6, 0)
    gphBottomLeft:SetJustifyH("LEFT")
    gphBottomLeft:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    local gphBottomCenter = gphBottomBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphBottomCenter:SetPoint("CENTER", gphBottomBar, "CENTER", 0, 0)
    gphBottomCenter:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    local gphBottomRight = gphBottomBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphBottomRight:SetPoint("RIGHT", gphBottomBar, "RIGHT", -6, 0)
    gphBottomRight:SetJustifyH("RIGHT")
    gphBottomRight:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    f.gphBottomBar = gphBottomBar
    f.gphBottomLeft = gphBottomLeft
    f.gphBottomCenter = gphBottomCenter
    f.gphBottomRight = gphBottomRight
    gphBottomLeft:SetText("-- FPS")
    if date then gphBottomCenter:SetText(date("%H:%M")) end
    gphBottomRight:SetText(GetMoney and FormatGold(GetMoney()) or "")

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerGPHScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", gphHeader, "BOTTOMLEFT", 0, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 20)
    f.scrollFrame = scrollFrame
    f.gphScrollBar = scrollFrame:GetName() and _G[scrollFrame:GetName() .. "ScrollBar"] or nil
    f.gphScrollOffset = 0  -- we own this; bar/template may not persist value on some clients
    local scrollBar = f.gphScrollBar
    -- Clear selection when user scrolls so overlay is off the row before content moves — prevents list from ever sticking.
    local function ClearGPHSelectionOnScroll()
        if not f.gphSelectedItemId then return end
        f.gphSelectedItemId = nil
        f.gphSelectedIndex = nil
        f.gphSelectedRowBtn = nil
        f.gphSelectedItemLink = nil
        if f.gphRightClickUseOverlay then
            f.gphRightClickUseOverlay:SetParent(f.scrollFrame)
            f.gphRightClickUseOverlay:ClearAllPoints()
            f.gphRightClickUseOverlay:SetPoint("BOTTOMLEFT", f.scrollFrame, "BOTTOMLEFT", -9999, -9999)
            f.gphRightClickUseOverlay:SetSize(0, 0)
            f.gphRightClickUseOverlay:Hide()
        end
    end
    -- Bar OnValueChanged: only sync our offset and content position. Do NOT call SetVerticalScroll here
    -- or the template's OnVerticalScroll will call SetValue again and cause a C stack overflow.
    if scrollBar then
        scrollBar:SetScript("OnValueChanged", function(self, value)
            local content = scrollFrame:GetScrollChild()
            local maxScroll = 0
            if content then
                maxScroll = math.max(0, (content:GetHeight() or 0) - scrollFrame:GetHeight())
            end
            local offset = (maxScroll > 0) and math.min(maxScroll, math.max(0, value)) or 0
            local prevOffset = f.gphScrollOffset or 0
            if math.abs(offset - prevOffset) > 0.5 then
                ClearGPHSelectionOnScroll()
            end
            f.gphScrollOffset = offset
            if content then
                local h = content:GetHeight()
                content:ClearAllPoints()
                content:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, offset)
                content:SetWidth(SCROLL_CONTENT_WIDTH)
                content:SetHeight(h)
            end
        end)
    end
    -- Do not call SetVerticalScroll: the template's reaction to it can reposition the scroll child and fight our manual position. We own bar value + content position only.
    local function gphDoScroll(sf, delta)
        ClearGPHSelectionOnScroll()
        local c = sf:GetScrollChild()
        if not c then return end
        local cur = f.gphScrollOffset or 0
        local viewHeight = sf:GetHeight()
        local contentHeight = c:GetHeight()
        local maxScroll = math.max(0, contentHeight - viewHeight)
        local step = 20
        -- Wheel: delta < 0 = wheel down = increase offset (content moves up, see lower items).
        local newScroll = (delta < 0) and math.min(maxScroll, cur + step) or math.max(0, cur - step)
        f.gphScrollOffset = newScroll
        if scrollBar then
            scrollBar:SetMinMaxValues(0, maxScroll)
            scrollBar:SetValue(newScroll)
        end
        local h = c:GetHeight()
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, newScroll)
        c:SetWidth(SCROLL_CONTENT_WIDTH)
        c:SetHeight(h)
    end
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        gphDoScroll(self, delta)
    end)
    -- Rows sit on top of content, so the wheel goes to the row (clickArea) not content/scrollFrame.
    -- Store a callback so each row can forward the wheel and the list actually scrolls.
    scrollFrame.GPHOnMouseWheel = function(delta)
        gphDoScroll(scrollFrame, delta)
    end
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content
    content:SetScript("OnMouseWheel", function(self, delta)
        gphDoScroll(self:GetParent(), delta)
    end)

    -- Right-click use overlay: parent to scrollFrame, position by coords over selected row only. Keep frame level low and only show when position/size valid so other rows stay clickable.
    local overlayOk, overlayBtn = pcall(CreateFrame, "Button", nil, scrollFrame, "SecureActionButtonTemplate")
    if overlayOk and overlayBtn then
        overlayBtn:SetFrameStrata("DIALOG")
        overlayBtn:SetFrameLevel(scrollFrame:GetFrameLevel() + 500)
        overlayBtn:RegisterForClicks("RightButtonUp")
        overlayBtn:EnableMouse(true)
        overlayBtn:SetSize(0, 0)
        overlayBtn:ClearAllPoints()
        overlayBtn:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMLEFT", -9999, -9999)
        overlayBtn:SetScript("OnMouseWheel", function(self, delta)
            if scrollFrame.GPHOnMouseWheel then scrollFrame.GPHOnMouseWheel(delta) end
        end)
        overlayBtn:SetScript("OnEnter", function(self)
            local link = f.gphSelectedItemLink
            if link then
                AnchorTooltipRight(self)
                local lp = link:match("|H(item:[^|]+)|h") or link
                if lp then GameTooltip:SetHyperlink(lp) end
                GameTooltip:AddLine(" ")
                local id = tonumber(link:match("item:(%d+)"))
                if id and GetGphProtectedSet and GetGphProtectedSet()[id] then
                    GameTooltip:AddLine("Protected — won't be auto-sold", 0.4, 0.8, 0.4)
                    GameTooltip:AddLine(" ")
                end
                GameTooltip:AddLine("LMB: Select", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("RMB: Use", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Shift+LMB: Pick up", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Shift+RMB: Link to Chat", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("CTRL+LMB: Protect Item", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        overlayBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        overlayBtn:Hide()
        f.gphRightClickUseOverlay = overlayBtn
    end
    f.gphSelectedTime = 0  -- time() when selected; second right-click within 10s fires use/equip, else reset

    f.gphSelectedItemId = nil
    f.gphSelectedItemLink = nil
    local gph_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        -- Every frame: keep content position in sync with our scroll offset (template/engine may reset it).
        local sf = self.scrollFrame
        local c = sf and sf:GetScrollChild()
        if c and sf then
            local v = self.gphScrollOffset or 0
            local maxScroll = math.max(0, (c:GetHeight() or 0) - sf:GetHeight())
            if v > maxScroll then v = maxScroll; self.gphScrollOffset = v end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, v)
            c:SetWidth(SCROLL_CONTENT_WIDTH)
        end
        local now = time()
        -- Clear selection after 10s without second right-click; hide overlay so it doesn't stick
        if self.gphSelectedItemId and (now - (self.gphSelectedTime or 0) > 10) then
            self.gphSelectedItemId = nil
            self.gphSelectedIndex = nil
            self.gphSelectedRowBtn = nil
            self.gphSelectedItemLink = nil
            if self.gphRightClickUseOverlay and self.scrollFrame then
                local ov = self.gphRightClickUseOverlay
                ov:SetParent(self.scrollFrame)
                ov:ClearAllPoints()
                ov:SetPoint("BOTTOMLEFT", self.scrollFrame, "BOTTOMLEFT", -9999, -9999)
                ov:SetSize(0, 0)
                ov:Hide()
            end
        end
        gph_elapsed = gph_elapsed + elapsed
        if gph_elapsed >= 0.5 then
            gph_elapsed = 0
            if self.UpdateGphSummonBtn then self.UpdateGphSummonBtn() end
            -- No periodic RefreshGPHUI: list updates on BAG_UPDATE and user actions (avoids choppy equipping)
            RefreshItemDetailLive()
            -- Bottom bar: FPS left, time center, gold right (latency/ms removed - not reliable on this client)
            if self.gphBottomLeft and self.gphBottomCenter and self.gphBottomRight then
                local fps = (GetFramerate and GetFramerate()) or 0
                self.gphBottomLeft:SetText(("%.0f FPS"):format(fps))
                if date then self.gphBottomCenter:SetText(date("%H:%M")) end
                self.gphBottomRight:SetText(GetMoney and FormatGold(GetMoney()) or "")
            end
        end
    end)

    return f
end

--- Rebuild GPH window: header, item list, sort, selection highlight.
RefreshGPHUI = function()
    if not gphFrame or not gphFrame:IsShown() then return end
    if gphFrame.gphCollapseBtn then gphFrame.gphCollapseBtn:Show(); gphFrame.gphCollapseBtn:SetFrameLevel(gphFrame:GetFrameLevel() + 50) end
    -- Debounce: avoid multiple refreshes per click (OnMouseDown + OnClick both call this), unless selection just changed (snappy highlight)
    local now = GetTime and GetTime() or time()
    local skipDebounce = gphFrame._refreshImmediate
    if skipDebounce then gphFrame._refreshImmediate = nil end
    if not skipDebounce and gphFrame._lastRefreshGPHUI and (now - gphFrame._lastRefreshGPHUI) < 0.08 then
        return
    end
    gphFrame._lastRefreshGPHUI = now
    if gphFrame.UpdateGphTitleBarButtonLayout then gphFrame:UpdateGphTitleBarButtonLayout() end
    if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
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
    local header = gphFrame.gphHeader
    local now = time()
    local nowGph = GetTime and GetTime() or time()  -- same as gphPendingQuality timestamps for 5s timeout

    if header and header.headerElements then
        for _, el in ipairs(header.headerElements) do
            el:ClearAllPoints()
            el:Hide()
        end
        wipe(header.headerElements)
    end
    if header then header.headerElements = header.headerElements or {} end

    if content.headerElements then
        for _, el in ipairs(content.headerElements) do
            el:ClearAllPoints()
            el:Hide()
        end
        wipe(content.headerElements)
    end
    content.headerElements = content.headerElements or {}

    -- Search bar visibility and status (timer/gold when session active)
    if gphFrame.gphSearchEditBox then
        if gphFrame.gphSearchBarVisible then
            gphFrame.gphSearchEditBox:Show()
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        else
            gphFrame.gphSearchEditBox:Hide()
        end
    end
    if not gphSession then
        gphFrame.statusText:Hide()
        gphFrame.statusText:SetText("")
        if gphFrame.gphStatusLeft then gphFrame.gphStatusLeft:Hide() end
        if gphFrame.gphStatusCenter then gphFrame.gphStatusCenter:Hide() end
        if gphFrame.gphStatusRight then gphFrame.gphStatusRight:Hide() end
        if gphFrame.gphSearchEditBox and gphFrame.gphSearchEditBox:IsShown() then
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        end
        gphFrame.updateToggle()
    else
        gphFrame.updateToggle()
        local dur = now - gphSession.startTime
        local liveGold = GetMoney() - gphSession.startGold
        if liveGold < 0 then liveGold = 0 end
        local gph = dur > 0 and (liveGold / (dur / 3600)) or 0
        local collapsed = InstanceTrackerDB.gphCollapsed
        if collapsed and gphFrame.gphStatusLeft and gphFrame.gphStatusCenter and gphFrame.gphStatusRight then
            gphFrame.statusText:Hide()
            gphFrame.statusText:SetText("")
            gphFrame.gphStatusLeft:SetText("|cffdaa520Gold:|r " .. FormatGold(liveGold))
            gphFrame.gphStatusLeft:Show()
            gphFrame.gphStatusCenter:SetText("|cffdaa520Timer:|r |cffffffff" .. FormatTimeMedium(dur) .. "|r")
            gphFrame.gphStatusCenter:Show()
            gphFrame.gphStatusRight:SetText("|cffdaa520GPH:|r " .. FormatGold(math.floor(gph)))
            gphFrame.gphStatusRight:Show()
        else
            if gphFrame.gphStatusLeft then gphFrame.gphStatusLeft:Hide() end
            if gphFrame.gphStatusCenter then gphFrame.gphStatusCenter:Hide() end
            if gphFrame.gphStatusRight then gphFrame.gphStatusRight:Hide() end
            gphFrame.statusText:Show()
            gphFrame.statusText:SetText(
                "|cffdaa520Gold:|r " .. FormatGold(liveGold)
                .. "   |cffdaa520Timer:|r |cffffffff" .. FormatTimeMedium(dur) .. "|r"
                .. "   |cffdaa520GPH:|r " .. FormatGold(math.floor(gph))
            )
        end
        if gphFrame.gphSearchEditBox and gphFrame.gphSearchEditBox:IsShown() then
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        end
    end

    -- Fixed header (bag space + Use + rarity bar) — only item list scrolls below; xOffset 4 so bag aligns with search row (search at 6 from titleBar)
    local header = gphFrame.gphHeader
    local headerY = 0
    local xOffset = 0
    local headerParent = header or content

    local totalSlots, usedSlots = 0, 0
    for bag = 0, 4 do
        local n = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        totalSlots = totalSlots + n
        for slot = 1, n do
            if GetContainerItemLink and GetContainerItemLink(bag, slot) then usedSlots = usedSlots + 1 end
        end
    end
    gphPendingQuality = gphPendingQuality or {}
    for q = 0, 5 do
        if gphPendingQuality[q] and (nowGph - gphPendingQuality[q]) > 5 then
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

    local qualityButtons = (header and header.qualityButtons) or content.qualityButtons
    if not qualityButtons then
        if header then header.qualityButtons = {} else content.qualityButtons = {} end
        qualityButtons = header and header.qualityButtons or content.qualityButtons
    end

    -- One row: bag space (same size as Search, below it) + 5 rarity buttons filling the rest, same height as Search/Bag (20).
    local headerW = headerParent and headerParent:GetWidth() or content:GetWidth() or 300
    local rightEdgeGap = 4  -- rarity row ends 4px before the window frame
    local qualityRight = headerW - rightEdgeGap
    local leftPad = 0  -- whole bar flush with Search (header is already aligned to sep which aligns to Search)
    local bagGap = 12  -- gap between bag and first rarity button
    local spacing = 4  -- gap between each rarity button
    local numRarityBtns = 5
    local ROW_H = 14
    local bagW, bagH = 36, 14
    -- Rarity buttons: fill from after bag to 4px before frame
    local startX = leftPad + bagW + bagGap
    local rarityTotalW = qualityRight - startX
    local slotWidth = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
    if slotWidth < 24 then slotWidth = 24 end

    -- Bag space: below Search, same size as Search (36x20), non-clickable
    if gphFrame.gphBagSpaceBtn and gphFrame.gphBagSpaceBtn.fs then
        local bagText = usedSlots .. "/" .. totalSlots
        gphFrame.gphBagSpaceBtn.fs:SetText(bagText)
        -- If text would overflow (e.g. 123/123), use smaller font so it stays inside the button
        local fs = gphFrame.gphBagSpaceBtn.fs
        local maxW = gphFrame.gphBagSpaceBtn:GetWidth() - 4
        if fs.GetStringWidth and fs:GetStringWidth() > maxW and maxW > 0 then
            fs:SetFont("Fonts\\FRIZQT__.TTF", 6, "")
        else
            fs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
        end
        gphFrame.gphBagSpaceBtn:SetSize(bagW, bagH)
        gphFrame.gphBagSpaceBtn:ClearAllPoints()
        gphFrame.gphBagSpaceBtn:SetPoint("TOPLEFT", headerParent, "TOPLEFT", leftPad, headerY)
        gphFrame.gphBagSpaceBtn:Show()
        table.insert(header and header.headerElements or content.headerElements, gphFrame.gphBagSpaceBtn)
    end

    for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
        local count = liveQualityCounts[q] or 0
        local info = QUALITY_COLORS[q] or QUALITY_COLORS[1]
        local labelText = tostring(count)

        local qualBtn = qualityButtons[q]
        if not qualBtn then
            qualBtn = CreateFrame("Button", nil, headerParent)
            qualBtn:EnableMouse(true)
            qualBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            qualBtn:SetHitRectInsets(0, 0, 0, 0)
            local bg = qualBtn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            qualBtn.bg = bg
            -- 1px white frame when rarity whitelist is on (inset so it never gets clipped by adjacent buttons)
            local inset = 1
            local t = qualBtn:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            t:SetVertexColor(1, 1, 1, 0.95)
            t:SetPoint("TOPLEFT", qualBtn, "TOPLEFT", inset, -inset)
            t:SetPoint("BOTTOMRIGHT", qualBtn, "TOPRIGHT", -inset, -inset - 1)
            qualBtn.rarityBorderTop = t
            t = qualBtn:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            t:SetVertexColor(1, 1, 1, 0.95)
            t:SetPoint("TOPLEFT", qualBtn, "BOTTOMLEFT", inset, inset + 1)
            t:SetPoint("BOTTOMRIGHT", qualBtn, "BOTTOMRIGHT", -inset, inset)
            qualBtn.rarityBorderBottom = t
            t = qualBtn:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            t:SetVertexColor(1, 1, 1, 0.95)
            t:SetPoint("TOPLEFT", qualBtn, "TOPLEFT", inset, -inset)
            t:SetPoint("BOTTOMRIGHT", qualBtn, "BOTTOMLEFT", inset + 1, inset)
            qualBtn.rarityBorderLeft = t
            t = qualBtn:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            t:SetVertexColor(1, 1, 1, 0.95)
            t:SetPoint("TOPLEFT", qualBtn, "TOPRIGHT", -inset - 1, -inset)
            t:SetPoint("BOTTOMRIGHT", qualBtn, "BOTTOMRIGHT", -inset, inset)
            qualBtn.rarityBorderRight = t
            qualityButtons[q] = qualBtn
        end
        local rarityFlags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
        if qualBtn.rarityBorderTop then
            if rarityFlags and rarityFlags[q] then
                qualBtn.rarityBorderTop:Show()
                qualBtn.rarityBorderBottom:Show()
                qualBtn.rarityBorderLeft:Show()
                qualBtn.rarityBorderRight:Show()
            else
                qualBtn.rarityBorderTop:Hide()
                qualBtn.rarityBorderBottom:Hide()
                qualBtn.rarityBorderLeft:Hide()
                qualBtn.rarityBorderRight:Hide()
            end
        end
        local r, g, b = (info.r or 0.5), (info.g or 0.5), (info.b or 0.5)
        if gphPendingQuality[q] then
            r, g, b = 0.9, 0.2, 0.2
        end
        local alpha = 0.35
        -- Brighten when this quality is the active filter (1st-click selected, items filtered)
        if gphFrame and gphFrame.gphFilterQuality == q and not gphPendingQuality[q] then
            r = math.min(1, r * 1.7)
            g = math.min(1, g * 1.7)
            b = math.min(1, b * 1.7)
            alpha = 0.75
        end
        qualBtn.bg:SetVertexColor(r, g, b, alpha)

        local fs = qualBtn.fs
        if not fs then
            fs = qualBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetAllPoints()
            fs:SetJustifyH("CENTER")
            fs:SetWordWrap(false)
            qualBtn.fs = fs
        end

        if gphPendingQuality[q] then
            fs:SetText("|cffff0000DEL|r")
        else
            fs:SetText("|cff" .. info.hex .. labelText .. "|r")
        end

        qualBtn:SetWidth(slotWidth)
        qualBtn:SetHeight(ROW_H)
        qualBtn.quality = q
        qualBtn.currentCount = count
        qualBtn.label = info.label
        qualBtn:Show()

        qualBtn:SetScript("OnClick", function(self, button)
            if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
            -- Ctrl+Left: toggle protect all items of this rarity (separate from per-item whitelist; deselecting clears only rarity protection)
            if IsControlKeyDown() and button == "LeftButton" and GetGphProtectedRarityFlags then
                local flags = GetGphProtectedRarityFlags()
                flags[self.quality] = not flags[self.quality]
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
                return
            end
            if button == "RightButton" then
                if gphFrame then gphFrame.gphFilterQuality = nil end
                for qKey in pairs(gphPendingQuality) do gphPendingQuality[qKey] = nil end
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
                return
            end
            -- 1st click: filter by this quality (sort by color). 2nd: red/DEL. 3rd: delete confirmation. RMB clears.
            if gphFrame and gphFrame.gphFilterQuality == self.quality then
                if gphPendingQuality[self.quality] then
                    -- 3rd click: show delete confirmation
                    if self.currentCount > 0 then
                        StaticPopup_Show("GPH_DELETE_QUALITY", self.currentCount, self.label, {quality = self.quality})
                    end
                else
                    -- 2nd click: set pending (red/DEL); focus hidden edit box so ESC cancels (same as right-click)
                    gphPendingQuality[self.quality] = GetTime and GetTime() or time()
                    if gphFrame and gphFrame.gphEscCatcher then
                        gphFrame.gphEscCatcher:Show()
                        gphFrame.gphEscCatcher:SetFocus()
                    end
                end
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
            else
                -- 1st click: filter by this quality only
                if gphFrame then gphFrame.gphFilterQuality = self.quality end
                for qKey in pairs(gphPendingQuality) do gphPendingQuality[qKey] = nil end
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
            end
        end)
        qualBtn:SetScript("OnEnter", function(self)
            if not self.label then return end
            AnchorTooltipRight(self)
            GameTooltip:SetText(self.label or "Rarity")
            GameTooltip:AddLine("LMB: Filter by rarity.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("RMB: Clear.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Double+LMB: Delete whole rarity.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Ctrl+LMB: Protect all items of this rarity.", 0.5, 0.9, 0.5)
            GameTooltip:Show()
        end)
        qualBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        qualBtn:ClearAllPoints()
        qualBtn:SetPoint("TOPLEFT", headerParent, "TOPLEFT", startX + (i - 1) * (slotWidth + spacing), headerY)
        table.insert(header and header.headerElements or content.headerElements, qualBtn)
    end

    -- Per-item protected set is not auto-cleaned: it persists until the user explicitly unprotects (Ctrl+click or unmark dialog).
    -- (Previously we removed ids not in bags/equipped here, which wiped the set after reload when ScanBags was still incomplete.)

    local yOff = 0  -- item list starts at top of scroll content (header is fixed above)
    local itemList = {}
    local prevWornSet = GetGphProtectedSet()
    local previouslyWornOnlySet = GetGphPreviouslyWornOnlySet()
    local rarityFlags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
    for itemId, cnt in pairs(currentBags) do
        local link = itemLinksCache[itemId]
        if link then
            local name, _, quality, iLevel, _, _, _, _, _, texture, sellPrice = GetItemInfo(link)
            quality = quality or 0
            name = name or "Unknown"
            sellPrice = sellPrice or 0
            iLevel = iLevel or 0
            local itemId = link and tonumber(link:match("item:(%d+)"))
            -- Protected = per-item whitelist OR rarity whitelist; previouslyWorn = soul icon only (items that left equipment slots)
            local isProtected = prevWornSet[itemId] or (rarityFlags and quality and rarityFlags[quality])
            table.insert(itemList, {
                link = link,
                quality = quality,
                count = cnt,
                name = name,
                sellPrice = sellPrice,
                itemId = itemId,
                itemLevel = iLevel,
                isProtected = isProtected and true or nil,
                previouslyWorn = (itemId and previouslyWornOnlySet[itemId]) and true or nil,
            })
        end
    end
    -- Show split-off stack on cursor as separate row (e.g. "Runecloth x25" below "Runecloth x175")
    if gphFrame and gphFrame.gphCursorItemId and gphFrame.gphCursorCount and gphFrame.gphCursorCount > 0 then
        local cType, cItemId = GetCursorInfo and GetCursorInfo()
        if cType == "item" and cItemId == gphFrame.gphCursorItemId then
            local link = itemLinksCache[gphFrame.gphCursorItemId] or ("item:" .. gphFrame.gphCursorItemId)
            local name, _, quality, iLevel, _, _, _, _, _, texture, sellPrice = GetItemInfo(link)
            quality = quality or 0
            name = name or "Unknown"
            sellPrice = sellPrice or 0
            iLevel = iLevel or 0
            local isProtected = prevWornSet[gphFrame.gphCursorItemId] or (rarityFlags and quality and rarityFlags[quality])
            table.insert(itemList, {
                link = link,
                quality = quality,
                count = gphFrame.gphCursorCount,
                name = name,
                sellPrice = sellPrice,
                itemId = gphFrame.gphCursorItemId,
                itemLevel = iLevel,
                isProtected = isProtected and true or nil,
                previouslyWorn = (gphFrame.gphCursorItemId and previouslyWornOnlySet[gphFrame.gphCursorItemId]) and true or nil,
                fromCursor = true,
            })
        else
            gphFrame.gphCursorItemId = nil
            gphFrame.gphCursorCount = nil
        end
    end
    local sortMode = InstanceTrackerDB.gphSortMode or "rarity"
    if sortMode == "vendor" then
        table.sort(itemList, function(a, b)
            if a.sellPrice ~= b.sellPrice then return (a.sellPrice or 0) > (b.sellPrice or 0) end
            if a.quality ~= b.quality then return a.quality > b.quality end
            if a.name ~= b.name then return a.name < b.name end
            return (a.fromCursor and 1 or 0) < (b.fromCursor and 1 or 0)
        end)
    elseif sortMode == "itemlevel" then
        table.sort(itemList, function(a, b)
            if (a.itemLevel or 0) ~= (b.itemLevel or 0) then return (a.itemLevel or 0) > (b.itemLevel or 0) end
            if a.quality ~= b.quality then return a.quality > b.quality end
            if a.name ~= b.name then return a.name < b.name end
            return (a.fromCursor and 1 or 0) < (b.fromCursor and 1 or 0)
        end)
    else
        table.sort(itemList, function(a, b)
            if a.quality ~= b.quality then return a.quality > b.quality end
            if a.name ~= b.name then return a.name < b.name end
            return (a.fromCursor and 1 or 0) < (b.fromCursor and 1 or 0)
        end)
    end

    -- Order: (*) protected first (above divider), then hearthstone (6948), then rest.
    do
        local protectedSet = GetGphProtectedSet()
        local rFlags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
        local aboveHearth, hearth, rest = {}, {}, {}
        for _, item in ipairs(itemList) do
            if item.itemId == 6948 then
                table.insert(hearth, item)
            elseif item.isProtected or (item.itemId and protectedSet[item.itemId]) or (rFlags and item.quality and rFlags[item.quality]) then
                table.insert(aboveHearth, item)
            else
                table.insert(rest, item)
            end
        end
        itemList = {}
        for _, item in ipairs(aboveHearth) do table.insert(itemList, item) end
        for _, item in ipairs(hearth) do table.insert(itemList, item) end
        for _, item in ipairs(rest) do table.insert(itemList, item) end
    end

    -- Filter by selected rarity (1 left click on rarity bar = show only that quality)
    if gphFrame.gphFilterQuality ~= nil then
        local q = gphFrame.gphFilterQuality
        local filtered = {}
        for _, item in ipairs(itemList) do
            if (item.quality or 0) == q then table.insert(filtered, item) end
        end
        itemList = filtered
    end

    -- Filter by GPH search (item name or rarity); exact quality label so "common" only white, "uncomm" only green
    if gphFrame.gphSearchText and gphFrame.gphSearchText ~= "" then
        local searchLower = gphFrame.gphSearchText:lower():match("^%s*(.-)%s*$")
        local exactQuality = nil
        for q = 0, 5 do
            local info = QUALITY_COLORS[q]
            if info and info.label and info.label:lower() == searchLower then
                exactQuality = q
                break
            end
        end
        local filtered = {}
        for _, item in ipairs(itemList) do
            if exactQuality ~= nil then
                if item.quality == exactQuality then table.insert(filtered, item) end
            else
                local itemMatches = (item.name and item.name:lower():find(searchLower, 1, true))
                local qualityMatches = false
                for q = 0, 5 do
                    local info = QUALITY_COLORS[q]
                    if info and info.label and info.label:lower():find(searchLower, 1, true) and item.quality == q then
                        qualityMatches = true
                        break
                    end
                end
                if itemMatches or qualityMatches then table.insert(filtered, item) end
            end
        end
        itemList = filtered
    end

    -- Keep destroy-list items in the list even when deleted from bags (so user can unmark)
    local destroyList = InstanceTrackerDB.gphDestroyList or {}
    for did in pairs(destroyList) do
        local inList = false
        for _, it in ipairs(itemList) do
            if it.itemId == did then inList = true; break end
        end
        if not inList then
            local info = destroyList[did]
            local storedName = type(info) == "table" and info.name
            local storedTex = type(info) == "table" and info.texture
            -- Migrate old format (true) to { name, texture } when cache allows
            if info == true and GetItemInfo then
                local n = GetItemInfo(did)
                local t = n and select(10, GetItemInfo(did))
                if n or t then
                    destroyList[did] = { name = n, texture = t }
                    storedName, storedTex = n, t
                end
            end
            local name = storedName or (GetItemInfo and GetItemInfo(did)) or ("Item " .. tostring(did))
            local prevWornSet = GetGphProtectedSet()
            local previouslyWornOnlySet = GetGphPreviouslyWornOnlySet()
            local _, _, q = GetItemInfo and GetItemInfo(did)
            q = q or 0
            local rFlags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
            local isProtected = prevWornSet[did] or (rFlags and q and rFlags[q])
            table.insert(itemList, {
                itemId = did,
                link = "item:" .. did,
                name = name,
                texture = storedTex or (GetItemInfo and select(10, GetItemInfo(did))),
                count = 0,
                quality = q or 0,
                sellPrice = 0,
                itemLevel = (GetItemInfo and select(4, GetItemInfo(did))) or 0,
                isProtected = isProtected and true or nil,
                previouslyWorn = (did and previouslyWornOnlySet[did]) and true or nil,
            })
        end
    end
    -- Push destroy-list items to the very bottom (preserve order)
    local normal, destroyed = {}, {}
    for _, item in ipairs(itemList) do
        if item.itemId and destroyList[item.itemId] then
            table.insert(destroyed, item)
        else
            table.insert(normal, item)
        end
    end
    itemList = normal
    for _, item in ipairs(destroyed) do table.insert(itemList, item) end

    if #itemList == 0 then
        local noItems = GetGPHText(content)
        noItems:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        noItems:SetText("|cff555555No items yet.|r")
        yOff = yOff + 14
        -- Nothing selectable, so clear selection.
        if gphFrame then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
        end
    else
        if gphFrame.gphHearthSpacerTex then gphFrame.gphHearthSpacerTex:Hide() end
        if gphFrame.gphHearthSpacerFrame then gphFrame.gphHearthSpacerFrame:Hide() end
        gphFrame.gphDefaultScrollY = nil  -- set when we draw the first row below hearthstone (default scroll position)
        local selectedStillExists = false
        local selectedRowBtn = nil  -- row (btn) that shows the selected item; overlay is positioned over it for right-click = Use
        local hadSelectedItemId = gphFrame and gphFrame.gphSelectedItemId ~= nil
        local itemIdToSlot = GetItemIdToBagSlot()
        for idx, item in ipairs(itemList) do
            -- Divider line: draw above hearthstone so hearthstone is always the first row under the spacer
            local curHearth = item.itemId == 6948 or (item.link and item.link:match("item:6948"))
            local rowBelowDivider = false
            if curHearth then
                if gphFrame.gphDefaultScrollY == nil then
                    gphFrame.gphDefaultScrollY = yOff + 4  -- top of hearthstone row (first row under divider)
                end
                if not gphFrame.gphHearthSpacerFrame then
                    local frame = CreateFrame("Frame", nil, content)
                    frame:EnableMouse(false)
                    local tex = frame:CreateTexture(nil, "ARTWORK")
                    tex:SetTexture(0.5, 0.42, 0.18, 0.75)
                    tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                    tex:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
                    tex:SetHeight(1)
                    tex:Show()
                    frame.tex = tex
                    gphFrame.gphHearthSpacerFrame = frame
                    gphFrame.gphHearthSpacerTex = tex
                end
                local spacer = gphFrame.gphHearthSpacerFrame
                spacer:SetParent(content)
                spacer:ClearAllPoints()
                spacer:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                spacer:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
                spacer:SetHeight(4)
                spacer:Show()
                if spacer.tex then spacer.tex:SetHeight(1); spacer.tex:Show() end
                yOff = yOff + 4
                rowBelowDivider = true
            end
            local rowOk, rowErr = pcall(function()
            local btn = GetGPHItemBtn(content)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                if rowBelowDivider then
                    btn:SetHitRectInsets(0, 0, -4, 0)
                    if btn.clickArea then btn.clickArea:SetHitRectInsets(0, 0, -4, 0) end
                else
                btn:SetHitRectInsets(0, 0, 0, 0)
                if btn.clickArea then btn.clickArea:SetHitRectInsets(0, 0, 0, 0) end
            end
            btn.itemLink = item.link
            btn.icon:SetTexture(GetSafeItemTexture(item.link or item.itemId, item.texture))
            local qInfo = QUALITY_COLORS[item.quality] or QUALITY_COLORS[1]
            -- Previously worn indicator icon (next to name); use WotLK-safe icon (soul gem)
            if btn.prevWornIcon then
                if item.previouslyWorn then
                    btn.prevWornIcon:SetTexture("Interface\\Icons\\Spell_Shadow_SoulGem")
                    btn.prevWornIcon:Show()
                    btn.nameFs:ClearAllPoints()
                    btn.nameFs:SetPoint("LEFT", btn.prevWornIcon, "RIGHT", 2, 0)
                    btn.nameFs:SetPoint("RIGHT", btn.clickArea, "RIGHT", -2, 0)
                else
                    btn.prevWornIcon:Hide()
                    btn.nameFs:ClearAllPoints()
                    btn.nameFs:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
                    btn.nameFs:SetPoint("RIGHT", btn.clickArea, "RIGHT", -2, 0)
                end
            end
            -- Name only (blue bar below row shows blacklist/protected; no (*) in name)
            btn.nameFs:SetText("|cff" .. qInfo.hex .. (item.name or "Unknown") .. "|r")
            btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")

            -- Double-click [x] to delete from bags (first click = pending, second = delete, NO subtract from tracking)
            local itemId = nil
            if item.link then itemId = tonumber(item.link:match("item:(%d+)")) end
            local capturedId = itemId
            local capturedCount = item.count

            -- Selected-row highlight: keep the currently selected item visually marked; remember index for advance-on-use
            if gphFrame and gphFrame.gphSelectedItemId and capturedId == gphFrame.gphSelectedItemId then
                selectedStillExists = true
                selectedRowBtn = btn
                gphFrame.gphSelectedIndex = idx
                if btn.selectedTex then btn.selectedTex:Show() end
            else
                if btn.selectedTex then btn.selectedTex:Hide() end
            end

            -- Dark overlay for items on cooldown (GetContainerItemCooldown; reliable)
            if btn.cooldownOverlay then
                if ItemIdHasCooldown(capturedId, itemIdToSlot) then
                    btn.cooldownOverlay:Show()
                else
                    btn.cooldownOverlay:Hide()
                end
            end

            -- Red overlay for "mark for auto-destroy" (Shift+double-click X)
            if btn.destroyOverlay then
                if (InstanceTrackerDB.gphDestroyList or {})[capturedId] then
                    btn.destroyOverlay:Show()
                else
                    btn.destroyOverlay:Hide()
                end
            end
            -- Light background for protected (per-item or rarity whitelist); item won't be vendored
            if btn.protectedOverlay then
                if item.isProtected then
                    btn.protectedOverlay:Show()
                else
                    btn.protectedOverlay:Hide()
                end
            end

            -- Clear stale double-click state (older than 0.5s)
            if gphDeleteClickTime[capturedId] and (now - (gphDeleteClickTime[capturedId] or 0)) > 0.5 then
                gphDeleteClickTime[capturedId] = nil
            end

            btn.deleteBtn:SetText("|cffff4444x|r")
            btn.deleteBtn:SetScript("OnEnter", function(self)
                self:SetText("|cffff8888x|r")
                self:SetWidth(16)
                self:SetHeight(16)
                AnchorTooltipRight(self)
                GameTooltip:AddLine("DoubleClick:           Delete Item", 0.85, 0.75, 0.5)
                GameTooltip:AddLine("Shift+DoubleClick:     AutoDelete", 0.85, 0.75, 0.5)
                GameTooltip:Show()
            end)
            btn.deleteBtn:SetScript("OnLeave", function(self)
                self:SetText("|cffff4444x|r")
                self:SetWidth(14)
                self:SetHeight(14)
                GameTooltip:Hide()
            end)
            btn.deleteBtn:SetScript("OnMouseWheel", function(self, delta)
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
            end)
            btn.deleteBtn:SetScript("OnClick", function()
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                if not capturedId then return end
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                local now = GetTime and GetTime() or time()
                -- Shift+double-click X: toggle mark for auto-destroy (no "Inv" required)
                if IsShiftKeyDown() then
                    if gphDestroyClickTime[capturedId] and (now - gphDestroyClickTime[capturedId]) <= 0.5 then
                        gphDestroyClickTime[capturedId] = nil
                        InstanceTrackerDB.gphDestroyList = InstanceTrackerDB.gphDestroyList or {}
                        local list = InstanceTrackerDB.gphDestroyList
                        if list[capturedId] then
                            list[capturedId] = nil
                        else
                            if item.previouslyWorn then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DESTROY_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId })
                            elseif item.quality and item.quality >= 4 then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DESTROY_EPIC", nil, nil, { itemId = capturedId })
                            else
                                local name = item.name or (GetItemInfo and GetItemInfo(capturedId))
                                local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(item.link or capturedId)
                                list[capturedId] = { name = name, texture = tex }
                                QueueDestroySlotsForItemId(capturedId)
                            end
                        end
                        RefreshGPHUI()
                        if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    else
                        gphDestroyClickTime[capturedId] = now
                    end
                    return
                end
                gphDestroyClickTime[capturedId] = nil
                -- Double-click X within 0.5s to delete (same feel as Alt double-click protect / Shift+X destroy)
                if gphDeleteClickTime[capturedId] and (now - gphDeleteClickTime[capturedId]) <= 0.5 then
                    gphDeleteClickTime[capturedId] = nil
                    if item.previouslyWorn then
                        StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId, count = capturedCount })
                    elseif capturedCount > GPH_MAX_STACK then
                        StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_STACK", capturedCount, nil, { itemId = capturedId, count = capturedCount })
                    else
                        DeleteGPHItem(capturedId, capturedCount)
                        RefreshGPHUI()
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                else
                    gphDeleteClickTime[capturedId] = now
                end
            end)

            btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn.clickArea:SetScript("OnMouseWheel", function(self, delta)
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
            end)
            btn.clickArea:SetScript("OnClick", function(self, button)
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                -- Throttle row actions to ~4/sec so fast macros don't highlight/mark everything
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                -- Shift+RMB: link to chat only
                if IsShiftKeyDown() and button == "RightButton" and item.link then
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
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- CTRL+LMB: toggle protect (blue)
                if IsControlKeyDown() and button == "LeftButton" and capturedId and GetGphProtectedSet then
                    local set = GetGphProtectedSet()
                    if set[capturedId] then
                        set[capturedId] = nil
                    else
                        set[capturedId] = true
                    end
                    if gphFrame then gphFrame._refreshImmediate = true end
                    if RefreshGPHUI then RefreshGPHUI() end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- Shift+LMB: pick up item onto cursor (bag or equipped), like normal inventory. No split (avoids needing bags open).
                if IsShiftKeyDown() and button == "LeftButton" and item.link and capturedId then
                    local bag, slot = GetBagSlotForItemId(capturedId)
                    local invSlot
                    if not bag then
                        for s = 1, 19 do
                            local link = GetInventoryItemLink and GetInventoryItemLink("player", s)
                            if link then
                                local id = tonumber(link:match("item:(%d+)"))
                                if id == capturedId then invSlot = s break end
                            end
                        end
                    end
                    local b, s, eq = bag, slot, invSlot
                    local defer = CreateFrame("Frame", nil, UIParent)
                    defer:SetScript("OnUpdate", function(self, elapsed)
                        self:SetScript("OnUpdate", nil)
                        if b and s and PickupContainerItem then
                            pcall(PickupContainerItem, b, s)
                        elseif eq and PickupInventoryItem then
                            pcall(PickupInventoryItem, eq)
                        end
                        if gphFrame then gphFrame._refreshImmediate = true end
                        if RefreshGPHUI then RefreshGPHUI() end
                    end)
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end

                -- LMB: select. RMB: use/equip (handled by overlay from OnMouseDown)
                if button == "LeftButton" and capturedId and gphFrame then
                    gphFrame.gphSelectedItemId = capturedId
                    gphFrame.gphSelectedIndex = idx
                    gphFrame.gphSelectedItemLink = item.link
                    gphFrame.gphSelectedTime = time()
                    gphFrame._refreshImmediate = true
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    RefreshGPHUI()
                end
            end)
            btn.clickArea:SetScript("OnMouseDown", function(_, mouseButton)
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                if (mouseButton ~= "LeftButton" and mouseButton ~= "RightButton") or not capturedId or not gphFrame then return end
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                if IsControlKeyDown() then return end  -- CTRL+click = protect in OnClick
                if IsShiftKeyDown() then return end    -- Shift+click = split/select or link in OnClick
                if mouseButton == "RightButton" then
                    -- Set selection and position overlay on this row so the upcoming RightMouseUp hits overlay = use/equip
                    gphFrame.gphSelectedItemId = capturedId
                    gphFrame.gphSelectedIndex = idx
                    gphFrame.gphSelectedRowBtn = btn
                    gphFrame.gphSelectedItemLink = item.link
                    gphFrame.gphSelectedTime = time()
                    if gphFrame.gphRightClickUseOverlay then
                        local map = GetItemIdToBagSlot()
                        local t = map and map[capturedId]
                        if t and btn then
                            local overlay = gphFrame.gphRightClickUseOverlay
                            pcall(function()
                                overlay:SetAttribute("type", "macro")
                                overlay:SetAttribute("macrotext", "/use " .. t.bag .. " " .. t.slot)
                            end)
                            overlay:SetParent(btn)
                            overlay:ClearAllPoints()
                            overlay:SetAllPoints(btn)
                            local rowTop = btn.clickArea and btn.clickArea:GetFrameLevel() or btn:GetFrameLevel()
                            overlay:SetFrameLevel(rowTop + 50)
                            overlay:Show()
                        end
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- LeftButton: select
                gphFrame.gphSelectedItemId = capturedId
                gphFrame.gphSelectedIndex = idx
                gphFrame.gphSelectedItemLink = item.link
                gphFrame.gphSelectedTime = time()
                gphFrame._refreshImmediate = true
                if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                RefreshGPHUI()
            end)
            btn.clickArea:SetScript("OnEnter", function(self)
                if item.link then
                    AnchorTooltipRight(self)
                    local lp = item.link:match("|H(item:[^|]+)|h")
                    if lp then GameTooltip:SetHyperlink(lp) end
                    GameTooltip:AddLine(" ")
                    if item.isProtected then
                        GameTooltip:AddLine("Protected — won't be auto-sold", 0.4, 0.8, 0.4)
                        GameTooltip:AddLine(" ")
                    end
                    GameTooltip:AddLine("LMB: Select", 0.6, 0.6, 0.6)
                    GameTooltip:AddLine("RMB: Use", 0.6, 0.6, 0.6)
                    GameTooltip:AddLine("Shift+LMB: Pick up", 0.6, 0.6, 0.6)
                    GameTooltip:AddLine("Shift+RMB: Link to Chat", 0.6, 0.6, 0.6)
                    GameTooltip:AddLine("CTRL+LMB: Protect Item", 0.6, 0.6, 0.6)
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
        -- If the previously selected item no longer exists (e.g. used/consumed), advance to next row; do NOT pick first item when there was no selection (stops blink after reload)
        if gphFrame and not selectedStillExists and hadSelectedItemId then
            local nextIdx = gphFrame.gphSelectedIndex and math.min(gphFrame.gphSelectedIndex, #itemList) or 1
            local nextItem = itemList[nextIdx]
            if nextItem and nextItem.link then
                local nextId = tonumber(nextItem.link:match("item:(%d+)"))
                if nextId then
                    gphFrame.gphSelectedItemId = nextId
                    gphFrame.gphSelectedIndex = nextIdx
                else
                    gphFrame.gphSelectedItemId = nil
                    gphFrame.gphSelectedIndex = nil
                    gphFrame.gphSelectedItemLink = nil
                end
            else
                gphFrame.gphSelectedItemId = nil
                gphFrame.gphSelectedIndex = nil
                gphFrame.gphSelectedItemLink = nil
            end
        end
        -- Keep selected row ref and put right-click use overlay on it so RMB use works; overlay stays on selected row (revert for clickable list).
        if gphFrame and selectedRowBtn and gphFrame.gphSelectedItemId then
            gphFrame.gphSelectedRowBtn = selectedRowBtn
        end
    end

    local function HideOverlaySafe(ov)
        if not ov then return end
        ov:SetParent(gphFrame.scrollFrame)
        ov:ClearAllPoints()
        ov:SetPoint("BOTTOMLEFT", gphFrame.scrollFrame, "BOTTOMLEFT", -9999, -9999)
        ov:SetSize(0, 0)
        ov:Hide()
    end
    if gphFrame.gphRightClickUseOverlay then
        local ov = gphFrame.gphRightClickUseOverlay
        local row = gphFrame.gphSelectedRowBtn
        local id = gphFrame.gphSelectedItemId
        if row and id then
            local map = GetItemIdToBagSlot and GetItemIdToBagSlot()
            local t = map and map[id]
            if t then
                pcall(function()
                    ov:SetAttribute("type", "macro")
                    ov:SetAttribute("macrotext", "/use " .. t.bag .. " " .. t.slot)
                end)
                ov:SetParent(row)
                ov:ClearAllPoints()
                ov:SetAllPoints(row)
                local rowTop = row.clickArea and row.clickArea:GetFrameLevel() or row:GetFrameLevel()
                ov:SetFrameLevel(rowTop + 50)
                ov:Show()
            else
                HideOverlaySafe(ov)
            end
        else
            HideOverlaySafe(ov)
        end
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
    -- Do NOT call UpdateScrollChildRect here: on some clients it resets the scroll child position and locks the list.
    if gphFrame.gphScrollBar then
        local viewHeight = gphFrame.scrollFrame:GetHeight()
        local contentHeight = content:GetHeight()
        local maxScroll = math.max(0, contentHeight - viewHeight)
        local cur = gphFrame.gphScrollOffset or 0
        -- When opening GPH, default scroll so the first visible row is the line below hearthstone (whitelisted items above require scrolling up).
        if gphFrame.gphScrollToDefaultOnNextRefresh and gphFrame.gphDefaultScrollY then
            cur = math.min(gphFrame.gphDefaultScrollY, maxScroll)
            gphFrame.gphScrollToDefaultOnNextRefresh = nil
        end
        if cur > maxScroll then cur = maxScroll end
        gphFrame.gphScrollOffset = cur
        gphFrame.gphScrollBar:SetMinMaxValues(0, maxScroll)
        gphFrame.gphScrollBar:SetValue(cur)
    end
    -- Re-anchor scroll content so it never gets stuck after using an item (overlay reparenting can leave list detached in 3.3.5)
    local sf = gphFrame.scrollFrame
    local scrollChild = sf and sf:GetScrollChild()
    if scrollChild and scrollChild == content then
        scrollChild:ClearAllPoints()
        scrollChild:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, gphFrame.gphScrollOffset or 0)
        scrollChild:SetWidth(SCROLL_CONTENT_WIDTH)
    end
    end)  -- pcall around refresh body
    if not refreshOk then
        AddonPrint("[Fugazi] GPH refresh error: " .. tostring(refreshErr))
    end
    -- Force collapse button level after refresh so it stays on top of close/sort
    if gphFrame.gphCollapseBtn then
        gphFrame.gphCollapseBtn:Show()
        gphFrame.gphCollapseBtn:SetFrameLevel(gphFrame:GetFrameLevel() + 50)
    end
end

--- Show or hide GPH window; position next to main frame if shown.
local function ToggleGPHFrame()
    -- Reuse frame by global name in case it was created but not assigned (e.g. after an error)
    if _G.InstanceTrackerGPHFrame then gphFrame = _G.InstanceTrackerGPHFrame end
    if not gphFrame then gphFrame = CreateGPHFrame() end
        if gphFrame:IsShown() then
            SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
            gphFrame:Hide()
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedItemLink = nil
        else
            if not InstanceTrackerDB.gphPoint or not InstanceTrackerDB.gphPoint.point then
                gphFrame:ClearAllPoints()
                gphFrame:SetPoint("TOP", UIParent, "CENTER", 0, -100)
            end
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            gphFrame.gphScrollToDefaultOnNextRefresh = true  -- scroll so first visible row is below hearthstone
            gphFrame:Show()
            SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
            RefreshGPHUI()
        end
end
_G.ToggleGPHFrame = ToggleGPHFrame  -- for inventory keybind macro

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
    f:SetPoint("TOP", UIParent, "CENTER", 0, 200)
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SaveFrameLayout(f, "frameShown", "framePoint")
    end)
    f:SetFrameStrata("DIALOG")
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
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("|cffff0000Fugazi|r Instance Tracker")
    title:SetTextColor(1, 0.85, 0.4, 1)

    -- Close button: stay closed until user opens via /fit or minimap (no auto-show)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        SaveFrameLayout(f, "frameShown", "framePoint")
        InstanceTrackerDB.mainFrameUserClosed = true
    end)

    -- Collapse button (square, +/- icon, no text)
    local collapseBtn = CreateFrame("Button", nil, f)
    collapseBtn:EnableMouse(true)
    collapseBtn:SetHitRectInsets(0, 0, 0, 0)
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
            collapseBg:SetTexture(0.25, 0.22, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
        end
    end
    UpdateCollapseButton()
    collapseBtn:SetScript("OnClick", function()
        InstanceTrackerDB.lockoutsCollapsed = not InstanceTrackerDB.lockoutsCollapsed
        UpdateCollapseButton(); RefreshUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if InstanceTrackerDB.lockoutsCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(InstanceTrackerDB.lockoutsCollapsed and "Show Saved Lockouts" or "Hide Saved Lockouts", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateCollapseButton(); GameTooltip:Hide() end)

    -- Stats button
    local statsBtn = CreateFrame("Button", nil, f)
    statsBtn:EnableMouse(true)
    statsBtn:SetHitRectInsets(0, 0, 0, 0)
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
            SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
                InstanceTrackerDB.statsCollapsed = InstanceTrackerDB.lockoutsCollapsed
                if statsFrame.UpdateStatsCollapse then statsFrame.UpdateStatsCollapse() end
            end
            statsFrame:Show()
            SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            RefreshStatsUI()
        end
    end)
    statsBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
        self.label:SetText("|cff88ffaaStats|r")
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("View Ledger", 0.4, 0.9, 0.5)
        GameTooltip:Show()
    end)
    statsBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.1, 0.25, 0.15, 0.7)
        self.label:SetText("|cff66dd88Stats|r")
        GameTooltip:Hide()
    end)

    -- Reset button
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:EnableMouse(true)
    resetBtn:SetHitRectInsets(0, 0, 0, 0)
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
    gphBtn:EnableMouse(true)
    gphBtn:SetHitRectInsets(0, 0, 0, 0)
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
        GameTooltip:AddLine("Manual Gold Per Hour Loot Tracker and full Loot management.", 0.9, 0.8, 0.5)
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
    header1:SetText("|cff80c0ff--- Recent Instances ---|r")
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
        CollapseInPlace(frame, 150, function() return false end)
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
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("GOSSIP_SHOW")
eventFrame:RegisterEvent("QUEST_GREETING")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not InstanceTrackerDB.recentInstances then InstanceTrackerDB.recentInstances = {} end
        if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
        PurgeOld()
        if not _G.InstanceTrackerKeybindOwner then
            _G.InstanceTrackerKeybindOwner = CreateFrame("Frame", "InstanceTrackerKeybindOwner", UIParent)
        end
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
        
        -- Default layout on reload: lockouts/stats collapsed, GPH expanded so item list is visible
        InstanceTrackerDB.lockoutsCollapsed = true
        InstanceTrackerDB.statsCollapsed = true
        InstanceTrackerDB.gphCollapsed = false
        frame = CreateMainFrame()
        RestoreFrameLayout(frame, "frameShown", "framePoint")
        if not (InstanceTrackerDB.framePoint and InstanceTrackerDB.framePoint.point) then
            frame:ClearAllPoints()
            frame:SetPoint("TOP", UIParent, "CENTER", 0, 200)
        end
        frame:SetScript("OnUpdate", OnUpdate)
        RequestRaidInfo()
        if frame:IsShown() then RefreshUI() end
        InstanceTrackerDB.gphDockedToMain = false
        if _G.InstanceTrackerGPHFrame then gphFrame = _G.InstanceTrackerGPHFrame end
        if not gphFrame then gphFrame = CreateGPHFrame() end
        RestoreFrameLayout(gphFrame, "gphShown", "gphPoint")
        if gphFrame:IsShown() then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            RefreshGPHUI()
        end
        if InstanceTrackerDB.gphInvKeybind then
            InstallGPHInvHook()
            if gphFrame and gphFrame.gphInvKeybindBtn then
                gphFrame.gphInvKeybindBtn:Show()
                gphFrame.gphInvKeybindBtn:SetAlpha(1)
                ApplyGPHInvKeyOverride(gphFrame.gphInvKeybindBtn)
            end
        end
        if InstanceTrackerDB.statsShown then
            if not statsFrame then statsFrame = CreateStatsFrame() end
            statsFrame:ClearAllPoints()
            statsFrame:SetWidth(frame:GetWidth())
            statsFrame:SetHeight(frame:GetHeight())
            statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            statsFrame:Show()
            RefreshStatsUI()
        end
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
                if not currentRun or currentRun.name ~= zoneName then
                    RestoreRunFromHistory(zoneName)
                end
                if not currentRun or currentRun.name ~= zoneName then StartRun(zoneName) end
            end
        else
            if isInInstance and currentRun then FinalizeRun() end
            isInInstance = false
            currentZone = ""
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if not msg then return end
        local lower = msg:lower()
        if msg:find("too many instances") then
            AddonPrint(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. ColorText("WARNING: ", 1, 0.2, 0.2) .. "You've hit the hourly instance cap!"
            )
            if not InstanceTrackerDB.mainFrameUserClosed and frame and not frame:IsShown() then frame:Show(); SaveFrameLayout(frame, "frameShown", "framePoint"); RefreshUI() end
        elseif lastExitedZoneName and lower:find("has been reset") then
            -- Instance/dungeon reset was printed (e.g. "Dungeon has been reset."); don't restore the run we just left.
            local history = InstanceTrackerDB.runHistory
            if history then
                for i = 1, #history do
                    if history[i] and history[i].name == lastExitedZoneName then
                        table.remove(history, i)
                        break
                    end
                end
            end
            lastExitedZoneName = nil
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        UpdateLockoutCache(); RefreshUI()

    elseif event == "MERCHANT_SHOW" or event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then
        gphNpcDialogTime = GetTime()
        if event == "MERCHANT_SHOW" then
            InstallGphGreedyMuteOnce()
            StartGphVendorRun()
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
        end
    elseif event == "MERCHANT_CLOSED" then
        gphNpcDialogTime = nil
        gphVendorRunning = false
        gphVendorWorker:Hide()
        if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
    elseif event == "BAG_UPDATE" then
        if currentRun then DiffBags() end
        if gphSession then DiffBagsGPH() end
        if gphFrame and gphFrame:IsShown() then
            gphFrame._refreshImmediate = true
            if RefreshGPHUI then RefreshGPHUI() end
        end
        if gphFrame and gphFrame.UpdateDestroyMacro then gphFrame.UpdateDestroyMacro() end
        -- Rebuild destroy queue: every slot that has a destroy-list item (full stack delete per slot, like double-click X)
        local list = InstanceTrackerDB.gphDestroyList
        if list then
            wipe(gphDestroyQueue)
            for bag = 0, 4 do
                local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
                if numSlots then
                    for slot = 1, numSlots do
                        local id = GetContainerItemID and GetContainerItemID(bag, slot)
                        if not id and GetContainerItemLink then
                            local link = GetContainerItemLink(bag, slot)
                            if link then id = tonumber(link:match("item:(%d+)")) end
                        end
                        if id and list[id] then
                            gphDestroyQueue[#gphDestroyQueue + 1] = { itemId = id, bag = bag, slot = slot }
                        end
                    end
                end
            end
            if #gphDestroyQueue > 0 then
                EnsureGPHDestroyerFrame()
                if gphDestroyerFrame then gphDestroyerFrame:Show() end
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Reparent GPH right-click overlay out of the GPH frame so the window can move in combat (secure child locks the list).
        if gphFrame and gphFrame.gphRightClickUseOverlay then
            local ov = gphFrame.gphRightClickUseOverlay
            ov:SetParent(UIParent)
            ov:ClearAllPoints()
            ov:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -9999, -9999)
            ov:SetSize(0, 0)
            ov:Hide()
        end
    end
end)
----------------------------------------------------------------------
-- Slash commands (/fit and /fit <cmd>)
----------------------------------------------------------------------
SLASH_INSTANCETRACKER1 = "/fit"
SLASH_INSTANCETRACKER2 = "/fugazi"
SLASH_FUGAZIGPH1 = "/gph"
SlashCmdList["FUGAZIGPH"] = function() ToggleGPHFrame() end
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
        AddonPrint("  |cffaaddff/fit gph|r or |cffaaddff/fit inv|r or |cffaaddff/gph|r  Toggle Gold Per Hour window")
        AddonPrint("  (Bind your bag key to |cffffcc00/fit gph|r or |cffffcc00/gph|r when Inv is on)")
        AddonPrint("  |cffaaddff/fit vp|r  Show Summon Greedy toggle state")
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

    if cmd == "vendorprotect" or cmd == "vp" then
        AddonPrint(ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Summon Greedy after vendor: " .. (InstanceTrackerDB.gphSummonGreedy ~= false and "|cff44ff44on|r (1.5s)" or "|cffff4444off|r"))
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
        if statsFrame:IsShown() then
            SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            end
            statsFrame:Show()
            SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            RefreshStatsUI()
        end
        return
    end

    if cmd == "gph" or cmd == "inv" then
        ToggleGPHFrame()
        return
    end

    -- No subcommand or unknown: toggle main window
    if not frame then frame = CreateMainFrame(); frame:SetScript("OnUpdate", OnUpdate) end
    if frame:IsShown() then
        frame:Hide()
        SaveFrameLayout(frame, "frameShown", "framePoint")
        InstanceTrackerDB.mainFrameUserClosed = true
    else
        InstanceTrackerDB.mainFrameUserClosed = false
        RequestRaidInfo()
        frame:Show()
        SaveFrameLayout(frame, "frameShown", "framePoint")
        RefreshUI()
    end
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------
local function CreateMinimapButton()
    local minimapAngle = InstanceTrackerDB.minimapAngle or 220
    local btn = CreateFrame("Button", "InstanceTrackerMinimapBtn", Minimap)
    btn:EnableMouse(true)
    btn:SetHitRectInsets(0, 0, 0, 0)
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
