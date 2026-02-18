-- __FugaziBAGS: Scope loads first. Use FugaziBAGSDB; migrate from TestDB once for existing installs.
FugaziBAGSDB = FugaziBAGSDB or {}
if TestDB and next(TestDB) then
    for k, v in pairs(TestDB) do
        if FugaziBAGSDB[k] == nil then FugaziBAGSDB[k] = v end
    end
end
local DB = FugaziBAGSDB
if DB.fitMute == nil then DB.fitMute = false end
if DB.gphInvKeybind == nil then DB.gphInvKeybind = true end
if DB.gphAutoVendor == nil then DB.gphAutoVendor = true end
if DB.gphScale15 == nil then DB.gphScale15 = false end
if DB.gphPreviouslyWornItemIds == nil then DB.gphPreviouslyWornItemIds = {} end
DB.gphProtectedItemIdsPerChar = DB.gphProtectedItemIdsPerChar or {}
DB.gphProtectedRarityPerChar = DB.gphProtectedRarityPerChar or {}
DB.gphPreviouslyWornOnlyPerChar = DB.gphPreviouslyWornOnlyPerChar or {}
DB.gphDestroyListPerChar = DB.gphDestroyListPerChar or {}
DB.gphItemTypeCache = DB.gphItemTypeCache or {}
DB.gphSkin = DB.gphSkin or "original"

-- Viewport width for scroll content (must match main file; used by GetGPHRow/GetGPHItemBtn etc.)
local SCROLL_CONTENT_WIDTH = 296

--- Realm#Character key for per-char DB.
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end

--- Use _G.FugaziBAGSDB at call time so saved/protected data persists across /reload (same pattern as SaveFrameLayout).
local function GetGphProtectedSet()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphProtectedItemIdsPerChar then SV.gphProtectedItemIdsPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphProtectedItemIdsPerChar[key] then
        SV.gphProtectedItemIdsPerChar[key] = {}
        local legacy = SV.gphPreviouslyWornItemIds or {}
        for id in pairs(legacy) do SV.gphProtectedItemIdsPerChar[key][id] = true end
    end
    return SV.gphProtectedItemIdsPerChar[key]
end

--- Returns the set of item IDs that were auto-protected because they left equipment slots (soul icon only).
local function GetGphPreviouslyWornOnlySet()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphPreviouslyWornOnlyPerChar then SV.gphPreviouslyWornOnlyPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphPreviouslyWornOnlyPerChar[key] then SV.gphPreviouslyWornOnlyPerChar[key] = {} end
    return SV.gphPreviouslyWornOnlyPerChar[key]
end

--- Get current character's rarity whitelist (quality -> true). When true, all items of that quality are protected until toggled off.
local function GetGphProtectedRarityFlags()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphProtectedRarityPerChar then SV.gphProtectedRarityPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphProtectedRarityPerChar[key] then SV.gphProtectedRarityPerChar[key] = {} end
    return SV.gphProtectedRarityPerChar[key]
end

--- Current character's auto-destroy list (itemId -> { name, texture }). Per-character; migrates from legacy account-wide gphDestroyList once.
--- Uses _G.FugaziBAGSDB at call time so the list persists across /reload (same pattern as GetGphProtectedSet).
local function GetGphDestroyList()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphDestroyListPerChar then SV.gphDestroyListPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphDestroyListPerChar[key] then
        SV.gphDestroyListPerChar[key] = {}
        local legacy = SV.gphDestroyList or {}
        for id, v in pairs(legacy) do SV.gphDestroyListPerChar[key][id] = v end
    end
    return SV.gphDestroyListPerChar[key]
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
    local t = (DB.gphSummonDelayTimers or {})
    DB.gphSummonDelayTimers = t
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
    if DB.gphSummonGreedy ~= false then
        QueueGphSummonGreedy()
    end
end

local gphSummonDelayFrame = CreateFrame("Frame")
gphSummonDelayFrame:SetScript("OnUpdate", function(self, elapsed)
    local t = DB.gphSummonDelayTimers
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
        if UnitExists("target") and UnitName("target") == GOBLIN_MERCHANT_NAME and MerchantFrame and MerchantFrame:IsShown() and (DB.gphSummonGreedy ~= false) then
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
local function GPHInvBagKeyHandler()
    -- With INV on: at vendor/NPC/mailbox never open default bags and don't close GPH; otherwise bag key toggles GPH.
    local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
    local atMailbox = _G.MailFrame and _G.MailFrame:IsShown()
    local npcTime = _G.gphNpcDialogTime
    local atNpcRecently = npcTime and (GetTime() - npcTime) < 1.5
    if atVendor or atMailbox or atNpcRecently then
        if CloseAllBags then CloseAllBags() end
        local gf = _G.TestGPHFrame or gphFrame
        if not gf and CreateGPHFrame then gf = CreateGPHFrame() end
        if gf and not gf:IsShown() then
            gphFrame = gf
            gf:Show()
            if SaveFrameLayout then SaveFrameLayout(gf, "gphShown", "gphPoint") end
            if _G.RefreshGPHUI then _G.RefreshGPHUI() end
        end
        return
    end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
    if CloseAllBags then CloseAllBags() end
end
local function InstallGPHInvHook()
    if not DB.gphInvKeybind then return end
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

-- Apply key override so bag key triggers our button (hook alone may not run on keypress in 3.3.5).
-- Prefer SecureHandlerClickTemplate button so bag key works in combat; fallback to non-secure button.
local function ApplyGPHInvKeyOverride(btn)
    if not btn or not DB.gphInvKeybind then return end
    local owner = _G.InstanceTrackerKeybindOwner
    if not owner then return end
    local btnName = (_G.InstanceTrackerGPHCombatToggleBtn and SecureHandlerSetFrameRef) and "InstanceTrackerGPHCombatToggleBtn" or "InstanceTrackerGPHToggleButton"
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
--- Uses _G.FugaziBAGSDB at call time so we always write to the table WoW persists (split VAR/main can capture DB before WoW loads saved vars).
--- For itemDetailPoint we always save absolute screen coords so docked position doesn't restore as top-right.
local function SaveFrameLayout(frame, shownKey, pointKey)
    if not frame then return end
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if pointKey == "itemDetailPoint" then
        local left, top = frame:GetLeft(), frame:GetTop()
        if left and top then
            SV[pointKey] = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
        end
    else
        local p, _, rp, x, y = frame:GetPoint(1)
        if p and rp and x and y then
            SV[pointKey] = { point = p, relativePoint = rp, x = x, y = y }
        end
    end
    if shownKey then SV[shownKey] = frame:IsShown() end
    if pointKey == "gphPoint" and frame.GetScale then
        SV.gphScale15 = (frame:GetScale() or 1) >= 1.4
    end
end

--- Restore a frame's position and optionally visibility from DB.
--- Uses _G.FugaziBAGSDB at call time so we always read the table WoW loaded.
local function RestoreFrameLayout(frame, shownKey, pointKey)
    if not frame then return end
    local SV = _G.FugaziBAGSDB
    if not SV then return end
    local pt = SV[pointKey]
    if pt and pt.point and pt.relativePoint and pt.x and pt.y then
        frame:ClearAllPoints()
        frame:SetPoint(pt.point, UIParent, pt.relativePoint, pt.x, pt.y)
    end
    if shownKey then
        if SV[shownKey] then
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
    if msg and msg ~= "" and not DB.fitMute then
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
    if _G.TestAddon then _G.TestAddon.gphDestroyerFrame = gphDestroyerFrame end
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

-- Quality labels & colors (0-4 standard; 5 = Legendary, 6 = Artifact; sort with epics, display correct color)
local QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d", label = "Trash" },
    [1] = { r = 1.00, g = 1.00, b = 1.00, hex = "ffffff", label = "White" },
    [2] = { r = 0.12, g = 1.00, b = 0.00, hex = "1eff00", label = "Green" },
    [3] = { r = 0.00, g = 0.44, b = 0.87, hex = "0070dd", label = "Blue" },
    [4] = { r = 0.64, g = 0.21, b = 0.93, hex = "a335ee", label = "Purple" },
    [5] = { r = 1.00, g = 0.50, b = 0.00, hex = "ff8000", label = "Legendary" },
    [6] = { r = 0.90, g = 0.80, b = 0.50, hex = "e6cc80", label = "Artifact" },
}
-- Rarity sort order: legendary (5) > artifact (6) > epic (4) > blue > green > white > grey
local function RaritySortOrder(q)
    if q == 5 then return 6
    elseif q == 6 then return 5
    elseif q == 4 then return 4
    else return math.min(q or 0, 3) end
end

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
        scanTooltip = CreateFrame("GameTooltip", "TestGPHScanTT", UIParent, "GameTooltipTemplate")
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
    for _, entry in ipairs(DB.recentInstances or {}) do
        if (entry.time + HOUR_SECONDS) > now then fresh[#fresh + 1] = entry end
    end
    DB.recentInstances = fresh
end

--- Return current instance count this hour (after purging old entries).
local function GetInstanceCount()
    PurgeOld()
    return #(DB.recentInstances or {})
end

--- Remove a single entry from recentInstances by index.
local function RemoveInstance(index)
    local recent = DB.recentInstances or {}
    if index >= 1 and index <= #recent then
        table.remove(recent, index)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed entry #" .. index .. "."
        )
    end
end

--- Record entering an instance (name) and print count this hour.
local function RecordInstance(name)
    if not DB.recentInstances then DB.recentInstances = {} end
    PurgeOld()
    local now = time()
    for _, entry in ipairs(DB.recentInstances) do
        if entry.name == name and (now - entry.time) < 60 then return end
    end
    table.insert(DB.recentInstances, { name = name, time = time() })
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Entered: " .. ColorText(name, 1, 1, 0.6)
        .. " (" .. ColorText(GetInstanceCount() .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.6, 0.2)
        .. " this hour)"
    )
end

--- Delete the stack in one bag slot (GPH slot-based row delete).
local function DeleteGPHSlot(bag, slot)
    if bag == nil or slot == nil then return end
    if PickupContainerItem and DeleteCursorItem then
        PickupContainerItem(bag, slot)
        DeleteCursorItem()
    end
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
        DB.currentRun = currentRun
        DB.bagBaseline = bagBaseline
        DB.itemsGained = itemsGained
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
        DB.gphSession = gphSession
        DB.gphBagBaseline = gphBagBaseline
        DB.gphItemsGained = gphItemsGained
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
    DB.gphSession = gphSession
    DB.gphBagBaseline = gphBagBaseline
    DB.gphItemsGained = gphItemsGained
    _G.gphSession = gphSession  -- main file uses global for button/timer state
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

    AddonPrint(
        ColorText("[_FugaziBAGS] ", 0.4, 0.8, 1)
        .. "GPH session stopped: " .. FormatTimeMedium(dur)
        .. " | " .. FormatGoldPlain(gold)
    )

    gphSession = nil
    DB.gphSession = nil
    DB.gphBagBaseline = nil
    DB.gphItemsGained = nil
    _G.gphSession = nil  -- main file uses global for button/timer state
end

--- Restore GPH session from TestDB (e.g. after /reload). Keeps scope and global in sync so button/timer work.
local function SyncGPHSessionFromDB()
    if not DB.gphSession then
        gphSession = nil
        _G.gphSession = nil
        return
    end
    gphSession = DB.gphSession
    gphBagBaseline = DB.gphBagBaseline or {}
    gphItemsGained = DB.gphItemsGained or {}
    _G.gphSession = gphSession
end

----------------------------------------------------------------------
-- Stats: run tracking helpers
----------------------------------------------------------------------
--- If the player re-enters the same dungeon (e.g. after dying and being teleported out),
-- restore the most recent run for that zone from history so the session continues.
-- Only restores if the run ended within MAX_RESTORE_AGE_SECONDS (5 min); after that or if instance reset, start fresh.
local function RestoreRunFromHistory(zoneName)
    local history = DB.runHistory
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
            DB.currentRun = currentRun
            DB.bagBaseline = bagBaseline
            DB.itemsGained = itemsGained
            DB.startingGold = startingGold
            DB.currentZone = currentZone
            DB.isInInstance = isInInstance
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
    DB.currentRun = currentRun
    DB.bagBaseline = bagBaseline
    DB.itemsGained = itemsGained
    DB.startingGold = startingGold
    DB.currentZone = currentZone
    DB.isInInstance = isInInstance
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

    if not DB.runHistory then DB.runHistory = {} end
    table.insert(DB.runHistory, 1, run)
    while #DB.runHistory > MAX_RUN_HISTORY do
        table.remove(DB.runHistory)
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
    DB.currentRun = nil
    DB.bagBaseline = nil
    DB.itemsGained = nil
    DB.startingGold = nil
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
    if DB.itemDetailCollapsed == nil then DB.itemDetailCollapsed = false end
    local ITEM_DETAIL_COLLAPSED_HEIGHT = 150  -- same as main frame collapsed so they line up when docked
    local function UpdateItemDetailCollapse()
        if not f.scrollFrame then return end
        if DB.itemDetailCollapsed then
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
            elseif DB.itemDetailPoint and DB.itemDetailPoint.point then
                RestoreFrameLayout(f, nil, "itemDetailPoint")
            end
        end
    end
    f.UpdateItemDetailCollapse = UpdateItemDetailCollapse
    UpdateItemDetailCollapse()
    collapseBtn:SetScript("OnClick", function()
        DB.itemDetailCollapsed = not DB.itemDetailCollapsed
        UpdateItemDetailCollapse()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if DB.itemDetailCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(DB.itemDetailCollapsed and "Show Items" or "Hide Items", 1, 0.85, 0.4)
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
            local history = DB.runHistory or {}
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
        elseif DB.itemDetailPoint and DB.itemDetailPoint.point then
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
        DB.itemDetailCollapsed = (DB.statsCollapsed == true)
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
                DB.itemDetailCollapsed = (DB.statsCollapsed == true)
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
    local history = DB.runHistory or {}
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

StaticPopupDialogs["GPH_AUTOSELL_CONFIRM"] = {
    text = "Enable autoselling at the Goblin Merchant?\nUnprotected items will be sold automatically when you open the merchant.",
    button1 = "Yes, enable",
    button2 = "Cancel",
    OnAccept = function()
        DB.gphAutoVendor = true
        local f = _G.TestGPHFrame or gphFrame
        if f and f.gphInvBtn then
            local inv = f.gphInvBtn
            if inv.icon then inv.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01") end
            if inv.bg then inv.bg:SetTexture(0.2, 0.5, 0.2, 0.8) end
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
        DB.runHistory = {}
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
        if not d then return end
        if d.bag ~= nil and d.slot ~= nil then
            DeleteGPHSlot(d.bag, d.slot)
        elseif d.itemId and d.count then
            DeleteGPHItem(d.itemId, d.count)
        end
        if gphDeleteClickTime and d.itemId then gphDeleteClickTime[d.itemId] = nil end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end,
    OnCancel = function(self)
        local d = self.data
        if d and d.itemId then
            if gphDeleteClickTime then gphDeleteClickTime[d.itemId] = nil end
            if _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end,
    OnCancel = function(self, data)
        if data and data.quality then
            gphPendingQuality[data.quality] = nil
        end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
    if DB.statsCollapsed == nil then DB.statsCollapsed = false end
    local function UpdateStatsCollapse()
        if not f.scrollFrame then return end
        if DB.statsCollapsed then
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
        DB.statsCollapsed = not DB.statsCollapsed
        UpdateStatsCollapse()
        RefreshStatsUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if DB.statsCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(DB.statsCollapsed and "Show Run Stats" or "Hide Run Stats", 1, 0.85, 0.4)
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
    if DB.statsCollapsed then
        content:SetHeight(math.max(1, yOff))
        return
    end

    -- Run history
    local history = DB.runHistory or {}
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

        -- Persistent selection highlight (same green as bag space / search bar so it's clearly visible)
        local sel = clickArea:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        sel:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        sel:SetVertexColor(0.1, 0.3, 0.15, 0.7)
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
        -- Previously worn indicator (shield) only
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
    btn.clickArea:EnableMouse(true)
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
        gphDestroyScanTooltip = CreateFrame("GameTooltip", "TestGPHDestroyScanTooltip", UIParent, "GameTooltipTemplate")
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
        local left = _G["TestGPHDestroyScanTooltipTextLeft" .. i]
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
    -- When GetItemInfo is nil (uncached), use tooltip "Disenchantable" so newly looted items still DE.
    if hasDE and bag and slot then
        local _, _, quality, _, _, itemType = GetItemInfo(link)
        local okByAPI = (itemType == "Armor" or itemType == "Weapon") and quality and quality >= 2 and quality <= 4
        local ttDisenchant, ttRecipe, ttProspect = false, false, false
        for i = 1, gphDestroyScanTooltip:NumLines() do
            local left = _G["TestGPHDestroyScanTooltipTextLeft" .. i]
            local text = left and left:GetText()
            if text then
                local t = text:lower()
                if t:find("disenchant", 1, true) then ttDisenchant = true end
                if t:find("recipe", 1, true) or t:find("teaches", 1, true) then ttRecipe = true end
                if text == (ITEM_PROSPECTABLE or "Can be prospected") then ttProspect = true end
            end
        end
        if (okByAPI or ttDisenchant) and not ttRecipe and not ttProspect then
            return GetSpellInfo(GPH_SPELL_IDS.Disenchant) or "Disenchant"
        end
    end

    -- Prospect: tooltip must show ITEM_PROSPECTABLE (same as before - this is why prospect works).
    if hasProspect and bag and slot then
        for i = 1, gphDestroyScanTooltip:NumLines() do
            local left = _G["TestGPHDestroyScanTooltipTextLeft" .. i]
            local text = left and left:GetText()
            if text and (text == (ITEM_PROSPECTABLE or "Can be prospected") or text:find("Prospect", 1, true)) then
                return GetSpellInfo(GPH_SPELL_IDS.Prospecting) or "Prospecting"
            end
        end
    end
    return nil
end

--- First destroyable item in bags: bag, slot, spellName, link. Order: prefer Prospect if preferProspect else DE; sort by quality then iLevel. Skips (*) protected items.
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
                        local itemId = tonumber(link:match("item:(%d+)"))
                        local _, _, quality = GetItemInfo(link)
                        quality = quality or 0
                        if itemId and IsItemProtectedAPI and IsItemProtectedAPI(itemId, quality) then
                            -- (*) protected: skip so Disenchant/Prospect button never targets this item
                        else
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

-- Set true to print why we find 1 vs N stacks when you OK the split-to-bank popup (chat output).
local GPH_DEBUG_SPLIT_MOVE = false

--- Return list of {bag, slot, count} for every stack of itemId in bags 0-4.
-- Optional knownBag, knownSlot: always include this slot first (row's first stack) so we have at least one.
local function GetAllBagSlotsForItem(itemId, knownBag, knownSlot)
    itemId = tonumber(itemId) or itemId
    if not itemId then return {} end
    local list = {}
    local function addSlot(bag, slot, count)
        if not count or count < 1 then count = 1 end
        list[#list + 1] = { bag = bag, slot = slot, count = count }
    end
    local function getCount(bag, slot)
        if not GetContainerItemInfo then return 1 end
        local count = select(2, GetContainerItemInfo(bag, slot))
        if type(count) == "number" and count > 0 then return count end
        return 1
    end
    -- Include known slot first (from the row we shift-clicked) so we always have at least one stack
    if knownBag ~= nil and knownSlot ~= nil then
        local texture = GetContainerItemInfo and select(1, GetContainerItemInfo(knownBag, knownSlot))
        if texture then addSlot(knownBag, knownSlot, getCount(knownBag, knownSlot)) end
    end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                if knownBag == bag and knownSlot == slot then
                    -- already added above
                else
                    local texture = GetContainerItemInfo and select(1, GetContainerItemInfo(bag, slot))
                    if texture then
                        local id = nil
                        if GetContainerItemID then id = GetContainerItemID(bag, slot) end
                        if not id and GetContainerItemLink then
                            local link = GetContainerItemLink(bag, slot)
                            if link then id = tonumber(link:match("item:(%d+)")) end
                        end
                        if id and tonumber(id) == tonumber(itemId) then
                            addSlot(bag, slot, getCount(bag, slot))
                        end
                    end
                end
            end
        end
    end
    -- Debug: why 1 vs N slots? (Postal uses GetContainerItemInfo only – no itemId – so it sees every slot.)
    if GPH_DEBUG_SPLIT_MOVE and AddonPrint then
        AddonPrint("[GPH split] target itemId=" .. tostring(itemId) .. " | list size=" .. #list)
        local seen = 0
        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local tex = GetContainerItemInfo and select(1, GetContainerItemInfo(bag, slot))
                if tex then
                    seen = seen + 1
                    local id = (GetContainerItemID and GetContainerItemID(bag, slot)) or "nil"
                    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                    local linkId = link and tonumber(link:match("item:(%d+)")) or "nil"
                    local match = (id == itemId or linkId == itemId) and "YES" or "no"
                    AddonPrint(string.format("  bag%d slot%d: GetContainerItemID=%s linkId=%s match=%s", bag, slot, tostring(id), tostring(linkId), match))
                end
            end
        end
        AddonPrint("[GPH split] slots with item (texture): " .. seen .. " | list has " .. #list .. " stacks for itemId")
    end
    return list
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
            if gphFrame and _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
        if not d then return end
        if d.bag ~= nil and d.slot ~= nil then
            if GetGphProtectedSet then GetGphProtectedSet()[d.itemId] = nil end
            DeleteGPHSlot(d.bag, d.slot)
        elseif d.itemId then
            if GetGphProtectedSet then GetGphProtectedSet()[d.itemId] = nil end
            DeleteGPHItem(d.itemId, d.count or 1)
        end
        if gphDeleteClickTime and d.itemId then gphDeleteClickTime[d.itemId] = nil end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
            local list = GetGphDestroyList()
            local name = GetItemInfo and GetItemInfo(itemId)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(itemId)
            list[itemId] = { name = name, texture = tex }
            QueueDestroySlotsForItemId(itemId)
            if gphFrame and _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
            local list = GetGphDestroyList()
            local name = GetItemInfo and GetItemInfo(itemId)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(itemId)
            list[itemId] = { name = name, texture = tex }
            QueueDestroySlotsForItemId(itemId)
            if gphFrame and _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
            if gphFrame and _G.RefreshGPHUI then _G.RefreshGPHUI() end
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
            _G.gphSession = nil  -- main file uses global for button/timer state
            AddonPrint(
                ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session reset."
            )
            -- Save state (nil session)
            DB.gphSession = nil
            DB.gphBagBaseline = nil
            DB.gphItemsGained = nil
            -- Update toggle button (scope's gphFrame may be nil; main sets TestGPHFrame)
            local gf = _G.TestGPHFrame or gphFrame
            if gf and gf.updateToggle then gf.updateToggle() end
            -- Always refresh so timer/gold/GPH hide (main reads _G.gphSession in RefreshGPHUI)
            if _G.RefreshGPHUI then _G.RefreshGPHUI() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

----------------------------------------------------------------------
-- Blizzard bag visibility (hide so GPH is sole inventory, or show alongside GPH).
-- 3.3.5 has NUM_CONTAINER_FRAMES = 13; hide all so bank open doesn't show default bags.
-- noCloseAllBags: when true, do NOT call CloseAllBags (use when bank is opening - CloseAllBags would close the bank).
local function HideBlizzardBags(noCloseAllBags)
    local n = _G.NUM_CONTAINER_FRAMES or 13
    for i = 1, n do
        local frame = _G["ContainerFrame" .. i]
        if frame then
            frame:SetScript("OnShow", function(self) self:Hide() end)
            frame:Hide()
        end
    end
    if not noCloseAllBags and CloseAllBags then CloseAllBags() end
end

local function ShowBlizzardBags()
    local n = _G.NUM_CONTAINER_FRAMES or 13
    for i = 1, n do
        local frame = _G["ContainerFrame" .. i]
        if frame then
            frame:SetScript("OnShow", nil)
        end
    end
    -- Call original Blizzard toggle (Test.lua replaces ToggleBackpack with GPH handler)
    local openBackpack = _G.TestOriginalToggleBackpack or ToggleBackpack
    if openBackpack then openBackpack() end
end

----------------------------------------------------------------------
-- Custom stack-split dialog (like Blizzard's little "split" window).
-- When DB.gphSkin == "elvui", frame/edit/buttons are skinned flat and borderless like ElvUI.
local gphStackSplitFrame
-- ElvUI: flat panel, no border (borderless like main frame's title bar).
local ELVUI_SPLIT_BACKDROP_FLAT = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}
local function HideEditBoxTemplateTextures(edit)
    if not edit then return end
    for i = 1, edit:GetNumRegions() do
        local r = select(i, edit:GetRegions())
        if r and r.SetTexture and r.Hide then r:Hide() end
    end
    if edit.Left then edit.Left:Hide() end
    if edit.Middle then edit.Middle:Hide() end
    if edit.Right then edit.Right:Hide() end
end
local function ApplyStackSplitSkin(f)
    if not f then return end
    local db = _G.FugaziBAGSDB
    local skinName = (db and db.gphSkin == "elvui") and "elvui" or "original"
    if skinName == "elvui" then
        f:SetBackdrop(ELVUI_SPLIT_BACKDROP_FLAT)
        f:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        if f.label then f.label:SetTextColor(0.9, 0.9, 0.9, 1) end
        if f.maxLabel then f.maxLabel:SetTextColor(0.9, 0.9, 0.9, 1) end
        if f.edit then
            HideEditBoxTemplateTextures(f.edit)
            pcall(function()
                f.edit:SetBackdrop(ELVUI_SPLIT_BACKDROP_FLAT)
                f.edit:SetBackdropColor(0.2, 0.2, 0.2, 0.95)
            end)
            f.edit:SetTextColor(1, 1, 1, 1)
        end
        for _, btn in ipairs({ f.ok, f.cancel }) do
            if btn then
                pcall(function()
                    btn:SetNormalTexture("")
                    btn:SetPushedTexture("")
                    btn:SetHighlightTexture("")
                    btn:SetBackdrop(ELVUI_SPLIT_BACKDROP_FLAT)
                    btn:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
                end)
                local fs = btn:GetFontString()
                if fs then fs:SetTextColor(0.9, 0.9, 0.9, 1) end
            end
        end
    else
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(0, 0, 0, 0.9)
        if f.label then f.label:SetTextColor(1, 0.82, 0, 1) end
        if f.maxLabel then f.maxLabel:SetTextColor(1, 1, 1, 1) end
        if f.edit then
            pcall(function() f.edit:SetBackdrop(nil) end)
            for i = 1, (f.edit.GetNumRegions and f.edit:GetNumRegions() or 0) do
                local r = select(i, f.edit:GetRegions())
                if r and r.Show then r:Show() end
            end
            if f.edit.Left then f.edit.Left:Show() end
            if f.edit.Middle then f.edit.Middle:Show() end
            if f.edit.Right then f.edit.Right:Show() end
            f.edit:SetTextColor(1, 1, 1, 1)
        end
        for _, btn in ipairs({ f.ok, f.cancel }) do
            if btn then
                pcall(function()
                    btn:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
                    btn:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
                    btn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
                    btn:SetBackdrop(nil)
                end)
                local fs = btn:GetFontString()
                if fs then fs:SetTextColor(1, 0.82, 0, 1) end
            end
        end
    end
end
local function ShowGPHStackSplit(bag, slot, maxCount, anchorTo, itemId, fromBank)
    if not bag or not slot or not maxCount or maxCount < 2 then return end
    if not gphStackSplitFrame then
        local f = CreateFrame("Frame", "GPHStackSplitFrame", UIParent)
        f:SetFrameStrata("DIALOG")
        f:SetFrameLevel(100)
        f:SetWidth(140)
        f:SetHeight(70)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(0, 0, 0, 0.9)
        f:EnableMouse(true)
        f:SetMovable(false)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", f, "TOP", 0, -10)
        label:SetText("Split stack:")
        f.label = label
        local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        edit:SetWidth(60)
        edit:SetHeight(20)
        edit:SetPoint("TOP", label, "BOTTOM", 0, -6)
        edit:SetAutoFocus(false)
        edit:SetNumeric(true)
        edit:SetMaxLetters(5)
        f.edit = edit
        local maxLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        maxLabel:SetPoint("LEFT", edit, "RIGHT", 4, 0)
        f.maxLabel = maxLabel
        local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        ok:SetWidth(50)
        ok:SetHeight(22)
        ok:SetPoint("BOTTOMLEFT", f, "BOTTOM", -55, 8)
        ok:SetText("OK")
        local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancel:SetWidth(50)
        cancel:SetHeight(22)
        cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 55, 8)
        cancel:SetText("Cancel")
        f.ok = ok
        f.cancel = cancel
        f:SetScript("OnHide", function(self)
            if self.edit then self.edit:ClearFocus() end
        end)
        ok:SetScript("OnClick", function(self)
            local parent = self:GetParent()
            local num = tonumber(parent.edit:GetText()) or 1
            if num < 1 then num = 1 end
                        local bf = _G.TestBankFrame
            -- Bank → bags: move N items from bank into bags. Queue sorted largest-first to avoid small stacks filling slots.
            if parent._splitFromBank and parent._splitItemId and bf and bf:IsShown() and bf.GetFirstFreeBagSlot and bf.GetAllBankSlotsForItem and PickupContainerItem then
                parent:Hide()
                local itemId = tonumber(parent._splitItemId) or parent._splitItemId
                local firstBag, firstSlot = parent._splitBag, parent._splitSlot
                local queue = bf.GetAllBankSlotsForItem(itemId, firstBag, firstSlot)
                table.sort(queue, function(a, b) return (a.count or 0) > (b.count or 0) end)
                local totalInQueue = 0
                for _, e in ipairs(queue) do totalInQueue = totalInQueue + (e.count or 0) end
                num = math.min(num, totalInQueue, parent._splitTotalCount or num)
                if num < 1 then if gphFrame then gphFrame._refreshImmediate = true end if _G.RefreshGPHUI then _G.RefreshGPHUI() end return end
                local remaining = num
                local nextMoveAt = 0
                local runner = CreateFrame("Frame", nil, UIParent)
                runner:Show()
                runner:SetScript("OnUpdate", function(self)
                    if remaining <= 0 or not queue or #queue == 0 then
                        self:SetScript("OnUpdate", nil)
                        if gphFrame then gphFrame._refreshImmediate = true end
                        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
                        if RefreshBankUI then RefreshBankUI() end
                        return
                    end
                    local now = GetTime()
                    if now < nextMoveAt then return end
                    if GetCursorInfo and GetCursorInfo() == "item" then return end
                    local s = queue[1]
                    local take = math.floor(math.min(s.count or 1, remaining))
                    if take < 1 then table.remove(queue, 1); return end
                    local bagBag, bagSlot = bf.GetFirstFreeBagSlot()
                    if not bagBag or not bagSlot then self:SetScript("OnUpdate", nil); return end
                    if SplitContainerItem then SplitContainerItem(s.bag, s.slot, take) end
                    PickupContainerItem(bagBag, bagSlot)
                    remaining = remaining - take
                    nextMoveAt = GetTime() + 0.25
                    if take >= (s.count or 1) then table.remove(queue, 1) else s.count = (s.count or 1) - take end
                end)
                return
            end
            -- Bags → bank: move N items from bags into bank. Queue sorted largest-first to avoid small stacks filling slots.
            if parent._splitItemId and not parent._splitFromBank and bf and bf:IsShown() and bf.GetFirstFreeBankSlot and GetAllBagSlotsForItem and PickupContainerItem then
                parent:Hide()
                local itemId = tonumber(parent._splitItemId) or parent._splitItemId
                local firstBag, firstSlot = parent._splitBag, parent._splitSlot
                local queue = GetAllBagSlotsForItem(itemId, firstBag, firstSlot)
                table.sort(queue, function(a, b) return (a.count or 0) > (b.count or 0) end)
                local totalInQueue = 0
                for _, e in ipairs(queue) do totalInQueue = totalInQueue + (e.count or 0) end
                num = math.min(num, totalInQueue, parent._splitTotalCount or num)
                if num < 1 then if gphFrame then gphFrame._refreshImmediate = true end if _G.RefreshGPHUI then _G.RefreshGPHUI() end return end
                local remaining = num
                local nextMoveAt = 0
                local runner = CreateFrame("Frame", nil, UIParent)
                runner:Show()
                runner:SetScript("OnUpdate", function(self)
                    if remaining <= 0 or not queue or #queue == 0 then
                        self:SetScript("OnUpdate", nil)
                        if gphFrame then gphFrame._refreshImmediate = true end
                        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
                        if RefreshBankUI then RefreshBankUI() end
                        return
                    end
                    local now = GetTime()
                    if now < nextMoveAt then return end
                    if GetCursorInfo and GetCursorInfo() == "item" then return end
                    local s = queue[1]
                    local take = math.floor(math.min(s.count or 1, remaining))
                    if take < 1 then
                        table.remove(queue, 1)
                        return
                    end
                    local bankBag, bankSlot = bf.GetFirstFreeBankSlot()
                    if not bankBag or not bankSlot then
                        self:SetScript("OnUpdate", nil)
                        return
                    end
                    if SplitContainerItem then SplitContainerItem(s.bag, s.slot, take) end
                    PickupContainerItem(bankBag, bankSlot)
                    remaining = remaining - take
                    nextMoveAt = GetTime() + 0.25
                    if take >= (s.count or 1) then
                        table.remove(queue, 1)
                    else
                        s.count = (s.count or 1) - take
                    end
                end)
                return
            end
            local bagId, slotId = parent._splitBag, parent._splitSlot
            local _, maxStack = GetContainerItemInfo(bagId, slotId)
            if maxStack and num > maxStack then num = maxStack end
            if SplitContainerItem and bagId and slotId then
                SplitContainerItem(bagId, slotId, num)
            end
            parent:Hide()
            if gphFrame then gphFrame._refreshImmediate = true end
            if _G.RefreshGPHUI then _G.RefreshGPHUI() end
        end)
        cancel:SetScript("OnClick", function(self) self:GetParent():Hide() end)
        edit:SetScript("OnEnterPressed", function(self) ok:Click() end)
        edit:SetScript("OnEscapePressed", function(self) self:GetParent():Hide() end)
        ApplyStackSplitSkin(f)
        gphStackSplitFrame = f
    end
    local f = gphStackSplitFrame
    ApplyStackSplitSkin(f)
    f._splitBag = bag
    f._splitSlot = slot
    f._splitItemId = itemId
    f._splitTotalCount = maxCount
    f._splitFromBank = fromBank
    f.maxLabel:SetText("/ " .. maxCount)
    f.edit:SetText("1")
    f:ClearAllPoints()
    local x, y = GetCursorPosition()
    local scale = UIParent and UIParent:GetEffectiveScale() or 1
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale - 10)
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText(0, 999)
    f.edit:SetCursorPosition(0)
end


-- Export scope to _G.TestAddon for main file
_G.TestAddon = _G.TestAddon or {}
local A = _G.TestAddon
A.GetGphCharKey = GetGphCharKey
A.GetGphProtectedSet = GetGphProtectedSet
A.GetGphPreviouslyWornOnlySet = GetGphPreviouslyWornOnlySet
A.GetGphProtectedRarityFlags = GetGphProtectedRarityFlags
A.GetGphDestroyList = GetGphDestroyList
A.IsItemProtectedAPI = IsItemProtectedAPI
A.BuildGphVendorQueue = BuildGphVendorQueue
A.GphCompanionNameIsGreedy = GphCompanionNameIsGreedy
A.GphCompanionNameIsGoblin = GphCompanionNameIsGoblin
A.GphIsGreedySummoned = GphIsGreedySummoned
A.GphIsGoblinMerchantSummoned = GphIsGoblinMerchantSummoned
A.GphPlayerHasGreedyCompanion = GphPlayerHasGreedyCompanion
A.QueueGphSummonGreedy = QueueGphSummonGreedy
A.DoGphSummonGreedyNow = DoGphSummonGreedyNow
A.DoGphSummonGoblinMerchantNow = DoGphSummonGoblinMerchantNow
A.GphDismissCurrentCompanion = GphDismissCurrentCompanion
A.FinishGphVendorRun = FinishGphVendorRun
A.StartGphVendorRun = StartGphVendorRun
A.GphGreedyChatFilter = GphGreedyChatFilter
A.GphIsVendorOut = GphIsVendorOut
A.InstallGphGreedyMuteOnce = InstallGphGreedyMuteOnce
A.ApplyGPHInvKeyOverride = ApplyGPHInvKeyOverride
A.InstallGPHInvHook = InstallGPHInvHook
A.SaveFrameLayout = SaveFrameLayout
A.RestoreFrameLayout = RestoreFrameLayout
A.CollapseInPlace = CollapseInPlace
A.AddonPrint = AddonPrint
A.GetExpansion = GetExpansion
A.ColorText = ColorText
A.QUALITY_COLORS = QUALITY_COLORS
A.INSTANCE_EXPANSION = INSTANCE_EXPANSION
A.ScanBags = ScanBags
A.HideBlizzardBags = HideBlizzardBags
A.EnsureGphDestroyScanTooltip = EnsureGphDestroyScanTooltip
A.GetRunDisplayName = GetRunDisplayName
A.EnsureGPHDestroyerFrame = EnsureGPHDestroyerFrame
A.QueueDestroySlotsForItemId = QueueDestroySlotsForItemId
A.DeleteAllOfQuality = DeleteAllOfQuality
A.RaritySortOrder = RaritySortOrder
A.FormatTime = FormatTime
A.FormatTimeMedium = FormatTimeMedium
A.FormatGold = FormatGold
A.FormatGoldPlain = FormatGoldPlain
A.FormatDateTime = FormatDateTime
A.GetScanTooltip = GetScanTooltip
A.GetItemIdToBagSlot = GetItemIdToBagSlot
A.ItemIdHasCooldown = ItemIdHasCooldown
A.ItemLinkHasCooldownRemaining = ItemLinkHasCooldownRemaining
A.AnchorTooltipRight = AnchorTooltipRight
A.FormatQualityCounts = FormatQualityCounts
A.PurgeOld = PurgeOld
A.GetInstanceCount = GetInstanceCount
A.RemoveInstance = RemoveInstance
A.RecordInstance = RecordInstance
A.DeleteGPHSlot = DeleteGPHSlot
A.DeleteGPHItem = DeleteGPHItem
A.SnapshotBags = SnapshotBags
A.GetEquippedItemIds = GetEquippedItemIds
A.DiffBags = DiffBags
A.DiffBagsGPH = DiffBagsGPH
A.StartGPHSession = StartGPHSession
A.StopGPHSession = StopGPHSession
A.SyncGPHSessionFromDB = SyncGPHSessionFromDB
A.RestoreRunFromHistory = RestoreRunFromHistory
A.StartRun = StartRun
A.FinalizeRun = FinalizeRun
A.UpdateLockoutCache = UpdateLockoutCache
A.BuildCurrentRunSnapshot = BuildCurrentRunSnapshot
A.BuildGPHSnapshot = BuildGPHSnapshot
A.ResetPools = ResetPools
A.ResetStatsPools = ResetStatsPools
A.GetRow = GetRow
A.GetText = GetText
A.GetStatsRow = GetStatsRow
A.GetStatsText = GetStatsText
A.GetSafeItemTexture = GetSafeItemTexture
A.ResetItemBtnPool = ResetItemBtnPool
A.GetItemBtn = GetItemBtn
A.CreateItemDetailFrame = CreateItemDetailFrame
A.CreateStatsFrame = CreateStatsFrame
A.ResetGPHPools = ResetGPHPools
A.GetGPHRow = GetGPHRow
A.GetGPHText = GetGPHText
A.GetGPHItemBtn = GetGPHItemBtn
A.IsSpellKnownByName = IsSpellKnownByName
A.GetRequiredAndItemLevelForDestroy = GetRequiredAndItemLevelForDestroy
A.GPHIsDestroyable = GPHIsDestroyable
A.GetFirstDestroyableInBags = GetFirstDestroyableInBags
A.GetBagSlotForItemId = GetBagSlotForItemId
A.GetBagSlotWithAtLeast = GetBagSlotWithAtLeast
A.GetAllBagSlotsForItem = GetAllBagSlotsForItem
A.ShowBlizzardBags = ShowBlizzardBags
A.ShowGPHStackSplit = ShowGPHStackSplit
A.ApplyStackSplitSkin = function() if gphStackSplitFrame then ApplyStackSplitSkin(gphStackSplitFrame) end end
A.GPH_SPELL_IDS = GPH_SPELL_IDS
A.RefreshItemDetailLive = RefreshItemDetailLive
A.gphDestroyQueue = gphDestroyQueue
A.gphDeleteClickTime = gphDeleteClickTime
A.gphDestroyClickTime = gphDestroyClickTime
A.gphPendingQuality = gphPendingQuality