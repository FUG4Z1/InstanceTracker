--[[
  FugaziBAGS_VAR: shared helpers, vendor loop, destroy queue, session/stats, FIT run history.
]]

_G.TestAddon = _G.TestAddon or {}
local A = _G.TestAddon
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
local _gphSkinWasNil = (DB.gphSkin == nil)
DB.gphSkin = DB.gphSkin or "fugazi"
DB.fitSkin = DB.fitSkin or "fugazi"
if _gphSkinWasNil and DB.gphSkin == "fugazi" then DB._applyFugaziPresetOnLoad = true end
DB._manualUnprotected = DB._manualUnprotected or {}
if DB.gphForceGridView == nil then DB.gphForceGridView = false end


local SCROLL_CONTENT_WIDTH = 296
local MAX_RUN_HISTORY = 100


--- Realm#Char key (per-toon save key).
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end


--- Per-char set of protected item IDs (won't sell/destroy).
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


--- Per-char "only protect previously worn" item set.
local function GetGphPreviouslyWornOnlySet()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphPreviouslyWornOnlyPerChar then SV.gphPreviouslyWornOnlyPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphPreviouslyWornOnlyPerChar[key] then SV.gphPreviouslyWornOnlyPerChar[key] = {} end
    return SV.gphPreviouslyWornOnlyPerChar[key]
end


--- Per-char flags: protect whole quality (e.g. all greens).
local function GetGphProtectedRarityFlags()
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphProtectedRarityPerChar then SV.gphProtectedRarityPerChar = {} end
    local key = GetGphCharKey()
    if not SV.gphProtectedRarityPerChar[key] then SV.gphProtectedRarityPerChar[key] = {} end
    return SV.gphProtectedRarityPerChar[key]
end



--- Per-char auto-destroy list (item ID -> info); Hearthstone excluded.
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
    local list = SV.gphDestroyListPerChar[key]
    list[6948] = nil 
    return list
end



--- Soulbound-to-vendor check: item or quality protected?
local function IsItemProtectedAPI(itemId, qualityArg)
    if not itemId then return false end
    
    if itemId == 6948 then return true end

    local SV = _G.FugaziBAGSDB or {}
    local mu = SV._manualUnprotected or {}
    
    if mu[itemId] then return false end

    local set = GetGphProtectedSet and GetGphProtectedSet()
    if set and set[itemId] == true then return true end

    local flags = GetGphProtectedRarityFlags and GetGphProtectedRarityFlags()
    if not flags then return false end

    local q = qualityArg
    if q == nil and GetItemInfo then
        local _, _, qq = GetItemInfo(itemId)
        q = qq
    end
    if not q then return false end
    if flags[q] then return true end
    -- Only epic (4): "protect purple" also protects legendary/artifact/heirloom (5,6,7)
    if flags[4] and q >= 4 then return true end
    return false
end
_G.FugaziInstanceTracker_IsItemProtected = function(id) return IsItemProtectedAPI(id) end


local GOBLIN_MERCHANT_NAME = "Goblin Merchant"
local GREEDY_PET_NAME = "Greedy scavenger"

local GREEDY_PET_ID = 600135
local GOBLIN_MERCHANT_ID = 600126
local GPH_SUMMON_DELAY = 1.5
local GPH_AUTOSELL_DELAY_MIN_MS = 30
local GPH_AUTOSELL_DELAY_MAX_MS = 1500


--- Autosell delay in seconds (from ping ms setting).
local function GetGphAutosellDelaySeconds()
    local SV = _G.FugaziBAGSDB
    local ms = (SV and SV.gphAutosellPingMs ~= nil) and tonumber(SV.gphAutosellPingMs) or nil
    if not ms or ms <= 0 then ms = GPH_AUTOSELL_DELAY_MIN_MS end
    ms = math.max(GPH_AUTOSELL_DELAY_MIN_MS, math.min(GPH_AUTOSELL_DELAY_MAX_MS, ms))
    return ms / 1000
end

local gphVendorQueue = {}
local gphVendorQueueIndex = 1
local gphVendorRunning = false
local gphVendorSessionOverride = false  
local gphVendorWorker = CreateFrame("Frame")
gphVendorWorker:Hide()


--- Build queue of sellable bag slots (non-protected, vendor price > 0).
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
                        
                        if sellPrice and sellPrice > 0 and quality ~= 4 and quality ~= 5 and quality ~= 6 then
                            gphVendorQueue[#gphVendorQueue + 1] = { type = "sell", bag = bag, slot = slot, itemID = itemID }
                        end
                    end
                end
            end
        end
    end
end


--- Is companion name the Greedy scavenger pet?
local function GphCompanionNameIsGreedy(name)
    if not name or type(name) ~= "string" then return false end
    local l = name:lower()
    return l:find("greedy") and l:find("scavenger")
end
--- Is companion name the Goblin Merchant?
local function GphCompanionNameIsGoblin(name)
    if not name or type(name) ~= "string" then return false end
    local l = name:lower()
    return l:find("goblin") and l:find("merchant")
end

--- Is Greedy scavenger currently out?
local function GphIsGreedySummoned()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned and (cid == GREEDY_PET_ID or GphCompanionNameIsGreedy(cname)) then return true end
    end
    return false
end

--- Is Goblin Merchant currently out?
local function GphIsGoblinMerchantSummoned()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned and (cid == GOBLIN_MERCHANT_ID or GphCompanionNameIsGoblin(cname)) then return true end
    end
    return false
end


--- Does player have Greedy companion available (spell)?
local function GphPlayerHasGreedyCompanion()
    local num = GetNumCompanions and GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cid, cname = GetCompanionInfo("CRITTER", i)
        if cid == GREEDY_PET_ID or (cname and GphCompanionNameIsGreedy(cname)) then return true end
    end
    return false
end

--- Queue summon Greedy (delay then summon).
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

--- Summon Greedy scavenger now (use spell).
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

--- Summon Goblin Merchant now (use spell).
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


--- Dismiss current companion (Greedy or Goblin).
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

--- End vendor run: stop worker, dismiss companion, refresh UI.
local function FinishGphVendorRun()
    gphVendorRunning = false
    local wasOverride = gphVendorSessionOverride  
    gphVendorSessionOverride = false
    gphVendorWorker:Hide()
    local wantGreedy = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSummonGreedy ~= false
    if not wasOverride and wantGreedy then
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
    local delay = GetGphAutosellDelaySeconds()
    if self._t < delay then return end
    self._t = 0
    if not MerchantFrame or not MerchantFrame:IsShown() then
        gphVendorRunning = false
        self:Hide()
        return
    end
    
    if gphVendorSessionOverride then return end
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
        local neverSell = (quality == 4 or quality == 5 or quality == 6)  

        
        local count = 1
        if GetContainerItemInfo then
            local _, itemCount = GetContainerItemInfo(action.bag, action.slot)
            if itemCount and itemCount > 0 then count = itemCount end
        end
        local vendorCopper = 0
        if GetItemInfo then
            local sellPrice = select(11, GetItemInfo(link or action.itemID))
            if sellPrice and sellPrice > 0 then
                vendorCopper = sellPrice * count
            end
        end

        if not neverSell and not IsItemProtectedAPI(action.itemID, quality) then
            UseContainerItem(action.bag, action.slot)
            if _G.gphSession then
                _G.gphSession.vendoredItemCount = _G.gphSession.vendoredItemCount or {}
                _G.gphSession.vendoredItemCount[action.itemID] = (_G.gphSession.vendoredItemCount[action.itemID] or 0) + count
            end
            if _G.FugaziInstanceTracker_OnAutoVendor then
                _G.FugaziInstanceTracker_OnAutoVendor(action.itemID, count, vendorCopper)
            end
        end
    end
    gphVendorQueueIndex = gphVendorQueueIndex + 1
end)

--- Start vendor run: summon companion, then sell queue (autosell).
local function StartGphVendorRun()
    if not UnitExists("target") or UnitName("target") ~= GOBLIN_MERCHANT_NAME then return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    if gphVendorRunning then return end
    
    local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown()
    gphVendorSessionOverride = shift
    if gphVendorSessionOverride then return end
    gphVendorRunning = true
    BuildGphVendorQueue()
    if #gphVendorQueue == 0 then
        gphVendorRunning = false
        local wantGreedy = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSummonGreedy ~= false
        if UnitExists("target") and UnitName("target") == GOBLIN_MERCHANT_NAME and MerchantFrame and MerchantFrame:IsShown() and wantGreedy then
            QueueGphSummonGreedy()
        end
        return
    end
    gphVendorWorker._t = 0
    gphVendorWorker:Show()
end

local gphGreedyMuteInstalled = false
--- Chat filter: mute Greedy scavenger lines once (autosell flow).
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

--- Is a vendor (Greedy/Goblin) currently visible?
local function GphIsVendorOut()
    return (MerchantFrame and MerchantFrame:IsShown()) and (UnitExists("target") and UnitName("target") == GOBLIN_MERCHANT_NAME)
end

--- One-time hook to mute Greedy chat during vendor run.
local function InstallGphGreedyMuteOnce()
    if gphGreedyMuteInstalled then return end
    gphGreedyMuteInstalled = true
    local events = { "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_WHISPER", "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_MONSTER_PARTY", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_EMOTE", "CHAT_MSG_SYSTEM" }
    for _, ev in ipairs(events) do
        if ChatFrame_AddMessageEventFilter then ChatFrame_AddMessageEventFilter(ev, GphGreedyChatFilter) end
    end
end


local origToggleBackpack, origOpenAllBags
--- B key handler for inventory (open our frame / close bags).
local function GPHInvBagKeyHandler()
    
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
--- Hook B/OpenAllBags to our inventory.
local function InstallGPHInvHook()
    if not DB.gphInvKeybind then return end
    if not origToggleBackpack and _G.ToggleBackpack then origToggleBackpack = _G.ToggleBackpack end
    if not origOpenAllBags and _G.OpenAllBags then origOpenAllBags = _G.OpenAllBags end
    if origToggleBackpack then _G.ToggleBackpack = GPHInvBagKeyHandler end
    if origOpenAllBags then _G.OpenAllBags = GPHInvBagKeyHandler end
end
--- Restore default B/OpenAllBags.
local function RemoveGPHInvHook()
    if origToggleBackpack then _G.ToggleBackpack = origToggleBackpack end
    if origOpenAllBags then _G.OpenAllBags = origOpenAllBags end
end


if not _G.InstanceTrackerGPHToggleButton then
    local toggleBtn = CreateFrame("Button", "InstanceTrackerGPHToggleButton", UIParent)
    toggleBtn:SetSize(1, 1)
    toggleBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    toggleBtn:Hide()
    toggleBtn:SetScript("OnClick", function()
        if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
    end)
end

--- Apply B key override to a button (e.g. bag bar).
local function ApplyGPHInvKeyOverride(btn)
    
    
    
    
end


--- FIT run history (restore previous runs).
local function GetRunHistory()
    local SV = _G.FugaziBAGSDB
    if not SV then _G.FugaziBAGSDB = {}; SV = _G.FugaziBAGSDB end
    if type(SV.runHistory) ~= "table" then SV.runHistory = {} end
    return SV.runHistory
end




--- Save frame position/size to DB (for restore).
local function SaveFrameLayout(frame, shownKey, pointKey)
    if not frame then return end
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        SV[pointKey] = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
    end
    if shownKey then SV[shownKey] = frame:IsShown() end
    if pointKey == "gphPoint" and frame.GetScale then
        SV.gphScale15 = (frame:GetScale() or 1) >= 1.4
    end
end



--- Restore frame position/size from DB.
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



--- Collapse frame to title bar (like minimap collapse).
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


--- Display name for a run (zone or custom).
local function GetRunDisplayName(run)
    if not run then return "?" end
    if run.customName and run.customName:match("%S") then return run.customName end
    return run.name or "?"
end


--- Print to chat with addon prefix (like /print).
local function AddonPrint(msg)
    if msg and msg ~= "" and not DB.fitMute then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end


local frame = nil
local statsFrame = nil
local itemDetailFrame = nil
local isInInstance = false
local currentZone = ""


local lockoutQueryTime = 0
local lockoutCache = {}


local currentRun = nil
local lastExitedZoneName = nil  


local bagBaseline = {}       
local itemsGained = {}       
local itemLinksCache = {}    
local lastEquippedItemIds = {}  


local startingGold = 0


local gphSession = nil   
local gphBagBaseline = {}

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_DEAD")
    f:SetScript("OnEvent", function(_, ev)
        if ev == "PLAYER_DEAD" and gphSession then
            gphSession.deaths = (gphSession.deaths or 0) + 1
        end
    end)
end
local gphItemsGained = {}
local gphFrame = nil


local gphDeleteClickTime = gphDeleteClickTime or {}

local gphDestroyClickTime = gphDestroyClickTime or {}

local gphDestroyQueue = {}
local gphDestroyerThrottle = 0
local GPH_DESTROY_DELAY = 0.4


--- Record auto-deleted item for FIT stats (vendor value).
local function RecordAutodeleteForFIT(itemId, count, vendorCopper)
    if not itemId or not count or count <= 0 then return end
    vendorCopper = vendorCopper or 0
    if _G.gphSession then
        _G.gphSession.itemsAutodeleted = (_G.gphSession.itemsAutodeleted or 0) + count
        _G.gphSession.autodeletedItemCount = _G.gphSession.autodeletedItemCount or {}
        _G.gphSession.autodeletedItemCount[itemId] = (_G.gphSession.autodeletedItemCount[itemId] or 0) + count
    end
    if _G.FugaziInstanceTracker_OnAutoDelete then
        _G.FugaziInstanceTracker_OnAutoDelete(itemId, count, vendorCopper)
    end
end


local gphDestroyerFrame = nil
--- Create/reuse destroy worker frame (ticks destroy queue).
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
                local link = GetContainerItemLink and GetContainerItemLink(entry.bag, entry.slot)
                local itemId = entry.itemId or (link and tonumber(link:match("item:(%d+)")))
                local count = 1
                if GetContainerItemInfo then
                    local _, c = GetContainerItemInfo(entry.bag, entry.slot)
                    if c and c > 0 then count = c end
                end
                local vendorCopper = 0
                if link and GetItemInfo then
                    local v = select(11, GetItemInfo(link))
                    if v and v > 0 then vendorCopper = v * count end
                end
                PickupContainerItem(entry.bag, entry.slot)
                if CursorHasItem and CursorHasItem() then
                    RecordAutodeleteForFIT(itemId, count, vendorCopper)
                    if DeleteCursorItem then DeleteCursorItem() end
                end
            end
            if #gphDestroyQueue == 0 then self:Hide() end
        end
    end)
end

--- Add bag slots for item to destroy queue (auto-delete).
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


local clearConfirmPending = false

local gphPendingQuality = gphPendingQuality or {}


--- Delete every item of one quality from bags (e.g. all grey).
local function DeleteAllOfQuality(quality)
    local deletedCount = 0
    local labels = { [0] = "Grey", [1] = "White", [2] = "Green", [3] = "Blue", [4] = "Epic", [5] = "Legendary" }
    local label = labels[quality] or "Unknown"

    for bag = 0, 4 do
        for slot = GetContainerNumSlots(bag), 1, -1 do  
            local link = GetContainerItemLink(bag, slot)
            if link then
                local itemId = tonumber(link:match("item:(%d+)"))
                local _, _, itemQuality = GetItemInfo(link)
                if itemQuality == quality then
                    
                    local skip = (itemId and GetGphProtectedSet()[itemId]) or false

                    
                    if quality == 1 then
                        
                        
                        local skipThis = (itemId == 6948)
                        
                        
                        if not skipThis then
                            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")  
                            GameTooltip:ClearLines()                       
                            GameTooltip:SetHyperlink(link)                 
                            
                            for i = 1, GameTooltip:NumLines() do           
                                local lineText = _G["GameTooltipTextLeft" .. i]  
                                if lineText and lineText:GetText() == "Quest Item" then  
                                    skipThis = true                             
                                    break                                       
                                end
                            end
                            
                            GameTooltip:Hide()                             
                        end
                        
                        if skipThis then
                            skip = true                                        
                        end
                        
                        
                        
                    end

                    if not skip then
                        local _, stackCount = GetContainerItemInfo(bag, slot)
                        stackCount = stackCount or 1
                        local vendorCopper = 0
                        if GetItemInfo then
                            local v = select(11, GetItemInfo(link))
                            if v and v > 0 then vendorCopper = v * stackCount end
                        end
                        PickupContainerItem(bag, slot)
                        if CursorHasItem and CursorHasItem() then
                            RecordAutodeleteForFIT(itemId, stackCount, vendorCopper)
                            DeleteCursorItem()
                        end
                        deletedCount = deletedCount + stackCount
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


local QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d", label = "Trash" },
    [1] = { r = 1.00, g = 1.00, b = 1.00, hex = "ffffff", label = "White" },
    [2] = { r = 0.12, g = 1.00, b = 0.00, hex = "1eff00", label = "Green" },
    [3] = { r = 0.00, g = 0.44, b = 0.87, hex = "0070dd", label = "Blue" },
    [4] = { r = 0.64, g = 0.21, b = 0.93, hex = "a335ee", label = "Purple" },
    [5] = { r = 1.00, g = 0.50, b = 0.00, hex = "ff8000", label = "Legendary" },
    [6] = { r = 0.90, g = 0.80, b = 0.50, hex = "e6cc80", label = "Artifact" },
    [7] = { r = 0.00, g = 0.80, b = 1.00, hex = "00ccff", label = "Heirloom" },
}

--- Sort order for quality (legendary=1, epic=2, ... poor=7).
local function RaritySortOrder(q)
    if q == 5 then return 7
    elseif q == 7 then return 6
    elseif q == 6 then return 5
    elseif q == 4 then return 4
    else return math.min(q or 0, 3) end
end




local INSTANCE_EXPANSION = {
    
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
    
    ["Molten Core"]                 = "classic",
    ["Onyxia's Lair"]               = "classic",
    ["Blackwing Lair"]              = "classic",
    ["Zul'Gurub"]                   = "classic",
    ["Ruins of Ahn'Qiraj"]         = "classic",
    ["Temple of Ahn'Qiraj"]        = "classic",
    ["Ahn'Qiraj Temple"]           = "classic",
    ["Ahn'Qiraj"]                  = "classic",
    
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

--- Get expansion name for instance (for FIT grouping).
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





--- Format seconds as m:ss (run duration).
local function FormatTime(seconds)
    if seconds <= 0 then return "Ready" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then return string.format("%dm %02ds", m, s)
    else return string.format("%ds", s) end
end


--- Format seconds as MM:SS (longer runs).
local function FormatTimeMedium(seconds)
    if seconds <= 0 then return "0s" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %dm", h, m)
    elseif m > 0 then return string.format("%dm %ds", m, s)
    else return string.format("%ds", s) end
end


--- Format copper as gold string (e.g. "1g 23s 45c").
local function FormatGold(copper)
    if not copper or copper <= 0 then return "|cffeda55f0c|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("|cffffd700%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, s, c)
    elseif s > 0 then return string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else return string.format("|cffeda55f%d|rc", c) end
end


--- Format copper as plain number (no color).
local function FormatGoldPlain(copper)
    if not copper or copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then return string.format("%ds %dc", s, c)
    else return string.format("%dc", c) end
end


--- Format timestamp for run list (date/time).
local function FormatDateTime(timestamp)
    if not timestamp then return "" end
    local dt = date("*t", timestamp)
    if not dt then return "" end
    
    return string.format("%d.%d.%d - %02d:%02d", dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
end


--- Wrap text in color codes (for chat/UI).
local function ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end


local scanTooltip = nil
--- Get hidden scan tooltip (for soulbound/level scan).
local function GetScanTooltip()
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "TestGPHScanTT", UIParent, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTooltip:ClearAllPoints()
        scanTooltip:SetPoint("CENTER", UIParent, "CENTER", 99999, 99999)  
    end
    return scanTooltip
end


local _gphIdToSlotTemp = {}
--- Map item ID -> bag,slot for cooldown lookup.
local function GetItemIdToBagSlot()
    local out = _gphIdToSlotTemp
    if out then wipe(out) end
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


--- Does this item ID have a cooldown in bags?
local function ItemIdHasCooldown(itemId, itemIdToSlot)
    if not itemId or not itemIdToSlot then return false end
    local t = itemIdToSlot[itemId]
    if not t or not GetContainerItemCooldown then return false end
    local start, duration = GetContainerItemCooldown(t.bag, t.slot)
    if not duration or duration <= 0 then return false end
    return (start or 0) + duration > GetTime()
end


--- Does this link have cooldown remaining? (scan tooltip.)
local function ItemLinkHasCooldownRemaining(link)
    if not link or link == "" then return false end
    local st = GetScanTooltip()
    st:ClearLines()
    st:SetHyperlink(link)
    st:Show()  
    local found = false
    local numLines = st:NumLines() or 0
    
    local name = st:GetName()
    for i = 1, numLines do
        local line = (name and _G[name .. "TextLeft" .. i]) or _G["GameTooltipTextLeft" .. i]
        if line and line.GetText then
            local text = line:GetText()
            if text and (text:find("Cooldown remaining") or text:find("Cooldown:")) then found = true; break end
        end
    end
    
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


--- Does item match search text? (name, type, etc.)
function A.ItemMatchesSearch(link, bag, slot, searchLower)
    if not searchLower or searchLower == "" then return true end
    if not link or link == "" then return false end
    local name, itemType, subType
    pcall(function()
        local itemId = link:match("item:(%d+)")
        itemId = itemId and tonumber(itemId)
        if GetItemInfo then
            name = select(1, GetItemInfo(itemId or link))
            itemType = select(6, GetItemInfo(itemId or link))
            subType = select(7, GetItemInfo(itemId or link))
            if not name then
                name = select(1, GetItemInfo(link))
                itemType = select(6, GetItemInfo(link))
                subType = select(7, GetItemInfo(link))
            end
        end
    end)
    if name and name:lower():find(searchLower, 1, true) then return true end
    if itemType and itemType:lower():find(searchLower, 1, true) then return true end
    if subType and subType:lower():find(searchLower, 1, true) then return true end
    local nameFromLink = link:match("%[([^%]]+)%]")
    if nameFromLink and nameFromLink:lower():find(searchLower, 1, true) then return true end
    return false
end




local TOOLTIP_FRAME_GAP = 5
local MIN_SPACE_RIGHT = 260  
local _anchorProbe  

--- Anchor tooltip to the right of frame (avoid overflow).
local function AnchorTooltipRight(ownerFrame)
    if not ownerFrame then return end

    
    local host = ownerFrame
    while host and host:GetParent() and host ~= UIParent and (not host.IsMovable or not host:IsMovable()) do
        host = host:GetParent()
    end

    if not host or host == UIParent then
        GameTooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
        return
    end

    
    if not _anchorProbe then
        _anchorProbe = CreateFrame("Frame", nil, UIParent)
        _anchorProbe:SetSize(1, 1)
        _anchorProbe:Hide()
    end
    _anchorProbe:ClearAllPoints()
    _anchorProbe:SetPoint("LEFT", host, "RIGHT", 0, 0)
    _anchorProbe:SetParent(UIParent)
    local hostRightX = _anchorProbe:GetLeft()
    local screenRight = (UIParent and UIParent.GetRight and UIParent:GetRight()) or 9999
    local spaceRight = screenRight - hostRightX - TOOLTIP_FRAME_GAP
    local useLeft = (spaceRight < MIN_SPACE_RIGHT)

    GameTooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    if useLeft then
        GameTooltip:SetPoint("RIGHT", host, "LEFT", -TOOLTIP_FRAME_GAP, 0)
    else
        GameTooltip:SetPoint("LEFT", host, "RIGHT", TOOLTIP_FRAME_GAP, 0)
    end
end

--- Format quality counts for header (e.g. "3 grey, 1 green").
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


--- Purge old run history beyond max count.
local function PurgeOld()
    local now = time()
    local fresh = {}
    for _, entry in ipairs(DB.recentInstances or {}) do
        if (entry.time + HOUR_SECONDS) > now then fresh[#fresh + 1] = entry end
    end
    DB.recentInstances = fresh
end


--- Number of instances in FIT run history.
local function GetInstanceCount()
    PurgeOld()
    return #(DB.recentInstances or {})
end


--- Remove one run from FIT history.
local function RemoveInstance(index)
    local recent = DB.recentInstances or {}
    if index >= 1 and index <= #recent then
        table.remove(recent, index)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed entry #" .. index .. "."
        )
    end
end


--- Add run to FIT history (zone name).
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


--- Delete one bag slot (pickup + delete item).
local function DeleteGPHSlot(bag, slot)
    if bag == nil or slot == nil then return end
    if not (PickupContainerItem and DeleteCursorItem) then return end
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    local itemId = link and tonumber(link:match("item:(%d+)"))
    local count = 1
    if GetContainerItemInfo then
        local _, c = GetContainerItemInfo(bag, slot)
        if c and c > 0 then count = c end
    end
    local vendorCopper = 0
    if link and GetItemInfo then
        local v = select(11, GetItemInfo(link))
        if v and v > 0 then vendorCopper = v * count end
    end
    PickupContainerItem(bag, slot)
    if CursorHasItem and CursorHasItem() then
        RecordAutodeleteForFIT(itemId, count, vendorCopper)
        DeleteCursorItem()
    end
end


--- Delete up to amount of itemId from bags.
local function DeleteGPHItem(itemId, amount)
    if not itemId or amount <= 0 then return end
    local remaining = amount
    for bag = 0, 4 do
        if remaining <= 0 then break end
        for slot = 1, GetContainerNumSlots(bag) do
            if remaining <= 0 then break end
            local currentId = GetContainerItemID(bag, slot)
            if currentId == itemId then
                local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                local _, stackCount = GetContainerItemInfo(bag, slot)
                if stackCount and stackCount > 0 then
                    local deleteAmt = math.min(stackCount, remaining)
                    local vendorCopper = 0
                    if GetItemInfo then
                        local v = select(11, GetItemInfo(link or itemId))
                        if v and v > 0 then vendorCopper = v * deleteAmt end
                    end
                    PickupContainerItem(bag, slot)
                    if deleteAmt < stackCount and SplitContainerItem then
                        SplitContainerItem(bag, slot, stackCount - deleteAmt)
                    end
                    if CursorHasItem and CursorHasItem() then
                        RecordAutodeleteForFIT(itemId, deleteAmt, vendorCopper)
                        DeleteCursorItem()
                    end
                    remaining = remaining - deleteAmt
                end
            end
        end
    end
end


local _scanCounts = {}
--- Scan all bags into flat item list (for diff/snapshot).
local function ScanBags()
    local counts = _scanCounts
    if counts then wipe(counts) end
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


--- Snapshot bag state (for session start/restore).
local function SnapshotBags()
    bagBaseline = ScanBags()
    itemsGained = {}
end


local _equippedIdTemp = {}
--- Set of equipped item IDs (for "previously worn" protect).
local function GetEquippedItemIds()
    local ids = _equippedIdTemp
    if ids then wipe(ids) end
    for slot = 1, 19 do
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if link then
            local id = tonumber(link:match("item:(%d+)"))
            if id then ids[id] = true end
        end
    end
    return ids
end



--- Diff current bags vs snapshot (gained/lost items for FIT).
local function DiffBags()
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    local protected = GetGphProtectedSet()
    local previouslyWornOnly = GetGphPreviouslyWornOnlySet()
    local SV = _G.FugaziBAGSDB or {}
    local mu = SV._manualUnprotected or {}

    
    
    for id in pairs(lastEquippedItemIds) do
        if not currentEquipped[id] and not mu[id] then
            protected[id] = true
            previouslyWornOnly[id] = true
        end
    end

    
    wipe(lastEquippedItemIds)
    for id in pairs(currentEquipped) do lastEquippedItemIds[id] = true end

    
    if SV._manualUnprotected then
        for id in pairs(currentEquipped) do
            SV._manualUnprotected[id] = nil
        end
    end

    if not currentRun then return end
    for itemId, curCount in pairs(current) do
        local baseCount = bagBaseline[itemId] or 0
        local delta = curCount - baseCount
        if delta > 0 and (protected[itemId] or itemId == 6948) then
            
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


--- Diff bags for GPH session (vendor value, counts).
local function DiffBagsGPH()
    if not gphSession then return end
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    local protected = GetGphProtectedSet()
    local previouslyWornOnly = GetGphPreviouslyWornOnlySet()
    local SV = _G.FugaziBAGSDB or {}
    local mu = SV._manualUnprotected or {}

    
    
    for id in pairs(lastEquippedItemIds) do
        if not currentEquipped[id] and not mu[id] then
            protected[id] = true
            previouslyWornOnly[id] = true
        end
    end

    wipe(lastEquippedItemIds)
    for id in pairs(currentEquipped) do lastEquippedItemIds[id] = true end

    
    if SV._manualUnprotected then
        for id in pairs(currentEquipped) do
            SV._manualUnprotected[id] = nil
        end
    end

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
    
    for itemId, data in pairs(gphSession.items or {}) do
        local cur = current[itemId] or 0
        local base = gphBagBaseline[itemId] or 0
        local net = cur - base
        if net < 0 then net = 0 end
        data.remaining = net
        if net == 0 then
            gphItemsGained[itemId] = nil
        else
            gphItemsGained[itemId] = net
        end
    end
    
    for q in pairs(gphSession.qualityCounts or {}) do gphSession.qualityCounts[q] = nil end
    for _, data in pairs(gphSession.items or {}) do
        local c = data.count or 0
        if c > 0 and data.quality then
            gphSession.qualityCounts[data.quality] = (gphSession.qualityCounts[data.quality] or 0) + c
        end
    end
    if gphSession then
        local SV = _G.FugaziBAGSDB
        if SV then
            SV.gphSession = gphSession
            SV.gphBagBaseline = gphBagBaseline
            SV.gphItemsGained = gphItemsGained
        end
    end
end


--- Start GPH session (snapshot bags, reset stats).
local function StartGPHSession()
    gphSession = {
        startTime = time(),
        startGold = GetMoney(),
        items = {},
        qualityCounts = {},
        deaths = 0,
    }
    
    local scan = ScanBags()
    gphBagBaseline = {}
    for id, cnt in pairs(scan) do gphBagBaseline[id] = cnt end
    gphItemsGained = {}
    
    local protected = GetGphProtectedSet()
    for id in pairs(GetEquippedItemIds()) do
        protected[id] = true
    end
    
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    SV.gphSession = gphSession
    SV.gphBagBaseline = gphBagBaseline
    SV.gphItemsGained = gphItemsGained
    _G.gphSession = gphSession  
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session started."
    )
end


--- Stop GPH session (finalize, save to DB).
local function StopGPHSession()
    if not gphSession then return end
    if DiffBagsGPH then DiffBagsGPH() end

    local now = time()
    local dur = now - gphSession.startTime
    local gold = GetMoney() - gphSession.startGold
    if gold < 0 then gold = 0 end

    
    local itemList = {}
    local qualityCounts = {}
    for itemId, data in pairs(gphSession.items or {}) do
        local total = data.count or 0
        if total > 0 and data.link and itemId ~= 6948 then
            local remaining = data.remaining
            if remaining == nil then remaining = total end
            local name = data.name
            if not name and GetItemInfo then name = select(1, GetItemInfo(data.link)) or "Unknown" end
            name = name or "Unknown"
            local quality = data.quality
            if quality == nil and GetItemInfo then quality = select(3, GetItemInfo(data.link)) or 0 end
            quality = quality or 0
            qualityCounts[quality] = (qualityCounts[quality] or 0) + total
            local vendored = (gphSession.vendoredItemCount and gphSession.vendoredItemCount[itemId] and gphSession.vendoredItemCount[itemId] > 0)
            local autodeleted = (gphSession.autodeletedItemCount and gphSession.autodeletedItemCount[itemId] and gphSession.autodeletedItemCount[itemId] > 0)
            table.insert(itemList, {
                link = data.link,
                quality = quality,
                count = total,
                name = name,
                remainingCount = remaining,
                soldDuringSession = vendored,
                autodeletedDuringSession = autodeleted,
            })
        end
    end
    table.sort(itemList, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return (a.name or "") < (b.name or "")
    end)

    
    local RecordToIT = _G.FugaziInstanceTracker_RecordGPHRun
    if type(RecordToIT) == "function" then
        local estimatedValueCopper = gold
        if Addon and Addon.ComputeGPHEstimatedValue and itemList then
            
            local valueList = {}
            for _, it in ipairs(itemList) do
                local cnt = (it.remainingCount ~= nil) and it.remainingCount or it.count
                if cnt and cnt > 0 then
                    valueList[#valueList + 1] = { link = it.link, quality = it.quality, count = cnt, name = it.name }
                end
            end
            estimatedValueCopper = gold + (Addon.ComputeGPHEstimatedValue(valueList) or 0)
        end
        
        local rawGPHCopper = nil
        if dur and dur > 0 then
            rawGPHCopper = math.floor(gold / (dur / 3600))
        end
        local repairCount = gphSession.repairCount or 0
        local repairCopper = gphSession.repairCopper or 0
        local vendorGoldCopper = gphSession.vendorGold or 0
        local itemsAutodeleted = gphSession.itemsAutodeleted or 0
        RecordToIT(gphSession.startTime, now, gphSession.startGold, gold, itemList, qualityCounts, estimatedValueCopper, rawGPHCopper, repairCount, repairCopper, gphSession.deaths or 0, itemsAutodeleted, vendorGoldCopper)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "GPH session stopped. " .. ColorText("Saved to Ledger", 0.6, 1, 0.6)
        )
    else
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
            .. "GPH session stopped. (Instance Tracker disabled — run not saved to Ledger.)"
        )
    end

    gphSession = nil
    _G.gphSession = nil
    local SV = _G.FugaziBAGSDB
    if SV then
        SV.gphSession = nil
        SV.gphBagBaseline = nil
        SV.gphItemsGained = nil
    end

    
    
    statsFrame = _G.InstanceTrackerStatsFrame
    if type(RefreshStatsUI) == "function" then
        if statsFrame and statsFrame:IsShown() then
            RefreshStatsUI()
        end
    end
    
    if type(_G.RefreshGPHUI) == "function" then
        _G.RefreshGPHUI()
    end
end


--- Reset session (clear stats, no save).
function ResetGPHSession()
    gphSession = nil
    gphBagBaseline = {}
    gphItemsGained = {}
    _G.gphSession = nil
    local SV = _G.FugaziBAGSDB
    if SV then
        SV.gphSession = nil
        SV.gphBagBaseline = nil
        SV.gphItemsGained = nil
    end
    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session reset (not saved to Ledger)."
    )
    local gf = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame or gphFrame
    if gf and type(gf.updateToggle) == "function" then gf.updateToggle() end
    if type(_G.RefreshGPHUI) == "function" then _G.RefreshGPHUI() end
end


--- Load session from DB (after login).
local function SyncGPHSessionFromDB()
    local SV = _G.FugaziBAGSDB
    if not SV or not SV.gphSession then
        gphSession = nil
        _G.gphSession = nil
        return
    end
    gphSession = SV.gphSession
    gphBagBaseline = SV.gphBagBaseline or {}
    gphItemsGained = SV.gphItemsGained or {}
    _G.gphSession = gphSession
end







--- Restore FIT run from history (reload snapshot).
local function RestoreRunFromHistory(zoneName)
    if not zoneName or zoneName == "" then return false end
    local history = GetRunHistory()
    if #history == 0 then return false end
    local now = time()
    for i = 1, #history do
        local run = history[i]
        if run and run.name == zoneName then
            local exitTime = run.exitTime or run.enterTime
            if (now - exitTime) > MAX_RESTORE_AGE_SECONDS then
                return false  
            end
            table.remove(history, i)
            
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

--- Start FIT run (record instance, snapshot).
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

--- Finalize FIT run (save to history, purge old).
local function FinalizeRun()
    if not currentRun then return end
    DiffBags()

    
    local goldEarned = GetMoney() - startingGold
    if goldEarned < 0 then goldEarned = 0 end
    currentRun.goldCopper = goldEarned

    local now = time()

    
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

    local history = GetRunHistory()
    table.insert(history, 1, run)
    while #history > MAX_RUN_HISTORY do
        table.remove(history)
    end

    AddonPrint(
        ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Run complete: " .. ColorText(run.name, 1, 1, 0.6)
        .. " - " .. FormatTimeMedium(run.duration)
        .. " | " .. FormatGoldPlain(run.goldCopper)
    )

    
    if statsFrame and statsFrame:IsShown() then
        if type(RefreshStatsUI) == "function" then
            RefreshStatsUI()
        end
    end

    lastExitedZoneName = currentRun.name
    currentRun = nil
    
    DB.currentRun = nil
    DB.bagBaseline = nil
    DB.itemsGained = nil
    DB.startingGold = nil
end




--- Refresh instance lockout cache (for FIT).
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




local RefreshUI
local RefreshStatsUI
local ShowItemDetail
local RemoveRunEntry
local RefreshGPHUI
local RefreshItemDetailLive




local _snapshotPool = {} 

--- Build current FIT run snapshot (for restore).
local function BuildCurrentRunSnapshot()
    local run = currentRun
    if not run then return nil end
    local itemList = Addon.GetRecycledAggTable() 
    wipe(itemList)
    for _, item in pairs(run.items) do
        local itm = Addon.GetRecycledItemTable()
        itm.link = item.link
        itm.quality = item.quality
        itm.count = item.count
        itm.name = item.name
        table.insert(itemList, itm)
    end
    table.sort(itemList, function(a, b)
        if (a and a.quality) ~= (b and b.quality) then return (a.quality or 0) > (b.quality or 0) end
        return (a.name or "") < (b.name or "")
    end)
    wipe(_snapshotPool)
    _snapshotPool.name = run.name
    _snapshotPool.qualityCounts = run.qualityCounts
    _snapshotPool.items = itemList
    return _snapshotPool
end

--- Build GPH session snapshot (item list for UI).
local function BuildGPHSnapshot()
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




local ROW_POOL, ROW_POOL_USED = {}, 0
local TEXT_POOL, TEXT_POOL_USED = {}, 0
local STATS_ROW_POOL, STATS_ROW_POOL_USED = {}, 0
local STATS_TEXT_POOL, STATS_TEXT_POOL_USED = {}, 0

--- Return all FIT row/text pools (reuse).
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

--- Return all FIT stats row/text pools.
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

--- Get or create FIT run list row (with optional delete btn).
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

--- Get or create FIT font string (pooled).
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

--- Get or create FIT stats row (run stats line).
local function GetStatsRow(parent, withDelete)
    STATS_ROW_POOL_USED = STATS_ROW_POOL_USED + 1
    local row = STATS_ROW_POOL[STATS_ROW_POOL_USED]
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

--- Get or create FIT stats font string (pooled).
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





local ITEM_ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
--- Get item texture (link or ID), fallback to question mark.
local function GetSafeItemTexture(linkOrId, _storedTexture)
    local id = type(linkOrId) == "number" and linkOrId or nil
    if not id and type(linkOrId) == "string" then id = tonumber((linkOrId or ""):match("item:(%d+)")) end
    local tex = nil
    if GetItemInfo then
        tex = (id and select(10, GetItemInfo(id))) or (linkOrId and select(10, GetItemInfo(linkOrId)))
    end
    
    if tex and type(tex) == "string" and tex ~= "" and tex:match("^Interface") then return tex end
    return ITEM_ICON_FALLBACK
end

local ITEM_BTN_POOL, ITEM_BTN_POOL_USED = {}, 0

--- Return all item buttons to pool (FIT detail frame).
local function ResetItemBtnPool()
    for i = 1, ITEM_BTN_POOL_USED do if ITEM_BTN_POOL[i] then ITEM_BTN_POOL[i]:Hide() end end
    ITEM_BTN_POOL_USED = 0
end

--- Get or create item button (icon+count) for detail list.
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

--- Build item detail frame (run loot list, scroll, rows).
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
    local ITEM_DETAIL_COLLAPSED_HEIGHT = 150  
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
    searchBtn.tooltipPending = nil  
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
        f.searchText = text:match("^%s*(.-)%s*$")  
        if f.RefreshItemDetailList then f:RefreshItemDetailList() end
    end)
    f.searchEditBox = searchEditBox
    f.searchBarVisible = false
    f.searchText = ""

    
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

    
    function f:RefreshItemDetailList()
        local run = self.currentRun
        if not run then return end
        local items = {}
        local qc = {}
        local titleText = run.name or "Unknown"
        if self.searchText and self.searchText ~= "" then
            local searchLower = self.searchText:lower()
            local history = GetRunHistory()
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
    f.liveSource = liveSource or nil  
    if f.searchEditBox then
        f.searchText = (f.searchEditBox:GetText() or ""):match("^%s*(.-)%s*$")
    end
    f:RefreshItemDetailList()

    
    local ledger = _G.InstanceTrackerStatsFrame
    local openFromLedger = ledger and ledger:IsShown()
    
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




RefreshItemDetailLive = function()
    if not itemDetailFrame or not itemDetailFrame:IsShown() or not itemDetailFrame.liveSource then return end
    if itemDetailFrame.searchText and itemDetailFrame.searchText ~= "" then return end  
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




RemoveRunEntry = function(index)
    local history = GetRunHistory()
    if index >= 1 and index <= #history then
        table.remove(history, index)
        AddonPrint(
            ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed run #" .. index .. "."
        )
        RefreshStatsUI()
    end
end





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
        
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphAutoVendor = true end
        
        local f = _G.FugaziBAGS_GPHFrame or _G.TestGPHFrame
        if f and f.UpdateInvBtn then
            local defer = CreateFrame("Frame")
            defer:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                if f and f.UpdateInvBtn then f.UpdateInvBtn() end
            end)
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
        local h = GetRunHistory()
        while #h > 0 do table.remove(h) end
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
        local bag, slot, stackCount = GPHBagSlot.GetBagSlotWithAtLeast(d.itemId, num)
        if not bag or not slot then return end
        num = math.min(num, stackCount)
        if num >= stackCount then return end 
        if SplitContainerItem then
            SplitContainerItem(bag, slot, num)
        end
        
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
            if A.gphRarityDelStage then A.gphRarityDelStage[data.quality] = nil end
        end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end,
    OnCancel = function(self, data)
        if data and data.quality then
            gphPendingQuality[data.quality] = nil
            if A.gphRarityDelStage then A.gphRarityDelStage[data.quality] = nil end
        end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["GPH_CONTINUOUS_DELETE"] = {
    text = "Enable continuous deletion of unprotected %s items?\nThis will automatically destroy matching items every 0.5s while active.",
    button1 = "Enable",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if data and data.quality then
            local Addon = _G.TestAddon
            if Addon and Addon.StartContinuousDelete then
                Addon.StartContinuousDelete(data.quality)
            end
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["GPH_CONFIRM_MAIL_RARITY"] = {
    text = "Are you sure you want to mail all unprotected %s items to %s?",
    button1 = "Accept",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if _G.TestAddon and _G.TestAddon.StartSendRarityMail then
            _G.TestAddon.StartSendRarityMail(data.rarity)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["GPH_CONFIRM_MAIL_ALL"] = {
    text = "Are you sure you want to mail ALL unprotected items to %s?\n\n(Skips Hearthstone, Quest items, and Protected gear)",
    button1 = "Accept",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if _G.TestAddon and _G.TestAddon.StartSendRarityMail then
            _G.TestAddon.StartSendRarityMail(-1)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}




--- Build FIT stats frame (run list, restore, gold, time).
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
    f.titleBar = titleBar
    f.fitTitle = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    
    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerStatsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    
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
    f.collapseBtn = collapseBtn
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
    f.clearBtn = clearBtn

    f.ApplySkin = function()
        if _G.__FugaziInstanceTracker_Skins and _G.__FugaziInstanceTracker_Skins.ApplyStats then
            _G.__FugaziInstanceTracker_Skins.ApplyStats(f)
        end
    end
    f:ApplySkin()

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




RefreshStatsUI = function()
    statsFrame = statsFrame or _G.InstanceTrackerStatsFrame
    if not statsFrame or not statsFrame:IsShown() then return end
    ResetStatsPools()

    local content = statsFrame.content
    local yOff = 0
    local now = time()

    
    local hdr = GetStatsText(content)
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)

    if currentRun then
        local dur = now - currentRun.enterTime
        local liveGold = GetMoney() - startingGold
        if liveGold < 0 then liveGold = 0 end

        hdr:SetText("|cff80c0ff--- Current: |r|cffffffcc" .. currentRun.name .. "|r |cff80c0ff---|r")
        yOff = yOff + 18

        
        local rDur = GetStatsRow(content, false)
        rDur:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        local durLabel = "|cffccccccDuration:|r |cffffffff" .. FormatTimeMedium(dur) .. "|r"
        local timeStr = "|cff666666" .. FormatDateTime(currentRun.enterTime) .. "|r"
        rDur.left:SetText(durLabel .. "  " .. timeStr)
        rDur.right:SetText(FormatGold(liveGold))
        yOff = yOff + 15

        
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

    
    if DB.statsCollapsed then
        content:SetHeight(math.max(1, yOff))
        return
    end

    
    local history = GetRunHistory()
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

            yOff = yOff + 4  
        end
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
end




local GPH_ROW_POOL, GPH_ROW_POOL_USED = {}, 0
local GPH_TEXT_POOL, GPH_TEXT_POOL_USED = {}, 0
local GPH_ITEM_POOL, GPH_ITEM_POOL_USED = {}, 0

--- Return all GPH row/text/btn pools (inventory list).
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

local _gphAggregatedPool = {}
local _gphAggregatedPoolUsed = 0
--- Get recycled agg table (stacked items) for GPH.
local function GetRecycledAggTable()
    _gphAggregatedPoolUsed = _gphAggregatedPoolUsed + 1
    local t = _gphAggregatedPool[_gphAggregatedPoolUsed]
    if not t then t = {}; _gphAggregatedPool[_gphAggregatedPoolUsed] = t end
    wipe(t)
    return t
end

local _gphItemListPool = {}
local _gphItemListPoolUsed = 0
--- Get recycled flat item table for GPH.
local function GetRecycledItemTable()
    _gphItemListPoolUsed = _gphItemListPoolUsed + 1
    local t = _gphItemListPool[_gphItemListPoolUsed]
    if not t then t = {}; _gphItemListPool[_gphItemListPoolUsed] = t end
    wipe(t)
    return t
end

--- Return agg/item tables to pool (GPH refresh).
local function ResetGPHDataPools()
    _gphAggregatedPoolUsed = 0
    _gphItemListPoolUsed = 0
    if A._gphNormalPool then wipe(A._gphNormalPool) end
    if A._gphDestroyedPool then wipe(A._gphDestroyedPool) end
    if A._gphDrawListPool then wipe(A._gphDrawListPool) end
    if A._gphFlatPool then wipe(A._gphFlatPool) end
end

A._gphNormalPool = {}
A._gphDestroyedPool = {}
A._gphDrawListPool = {}
A._gphFlatPool = {}
A._gphCategoryGroupsPool = {}

--- Get or create GPH inventory list row (icon, name, count).
local function GetGPHRow(parent, withDelete)
    GPH_ROW_POOL_USED = GPH_ROW_POOL_USED + 1
    local row = GPH_ROW_POOL[GPH_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        GPH_ROW_POOL[GPH_ROW_POOL_USED] = row
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

--- Get or create GPH font string (pooled).
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

--- Get or create GPH item button (row icon/count).
local function GetGPHItemBtn(parent)
    GPH_ITEM_POOL_USED = GPH_ITEM_POOL_USED + 1
    local btn = GPH_ITEM_POOL[GPH_ITEM_POOL_USED]
    if not btn then
        btn = CreateFrame("Frame", nil, parent)
        GPH_ITEM_POOL[GPH_ITEM_POOL_USED] = btn
        btn:SetWidth(SCROLL_CONTENT_WIDTH)
        btn:SetHeight(18)
        btn:EnableMouse(true)
        
        btn.deleteBtn = nil

        
        local clickArea = CreateFrame("Button", nil, btn)
        clickArea:SetPoint("LEFT", btn, "LEFT", 0, 0)
        clickArea:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        clickArea:SetHeight(18)
        clickArea:EnableMouse(true)
        clickArea:SetHitRectInsets(0, 0, 0, 0)
        clickArea:SetFrameLevel(btn:GetFrameLevel() + 2)
        btn.clickArea = clickArea

        
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
        local countFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
        countFs:SetJustifyH("RIGHT")
        btn.countFs = countFs
        local nameFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        nameFs:SetPoint("RIGHT", clickArea, "RIGHT", -40, 0)
        nameFs:SetJustifyH("LEFT")
        btn.nameFs = nameFs
        local hl = clickArea:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        hl:SetVertexColor(1, 1, 1, 0.1)
        
        local cooldownOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        cooldownOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        cooldownOverlay:SetPoint("TOPLEFT", clickArea, "TOPLEFT", 0, 0)
        cooldownOverlay:SetPoint("BOTTOMLEFT", clickArea, "BOTTOMLEFT", 0, 0)
        cooldownOverlay:SetWidth(0.01)
        cooldownOverlay:Hide()
        btn.cooldownOverlay = cooldownOverlay
        
        local destroyOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        destroyOverlay:SetAllPoints()
        destroyOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        destroyOverlay:SetVertexColor(0.5, 0.05, 0.05)
        destroyOverlay:SetAlpha(0.85)
        destroyOverlay:Hide()
        btn.destroyOverlay = destroyOverlay
        
        local protectedOverlay = clickArea:CreateTexture(nil, "OVERLAY")
        protectedOverlay:SetAllPoints()
        protectedOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        protectedOverlay:SetVertexColor(0, 0, 0)
        protectedOverlay:SetAlpha(0.85)
        protectedOverlay:Hide()
        btn.protectedOverlay = protectedOverlay
        
        local protectedKeyIcon = clickArea:CreateTexture(nil, "OVERLAY")
        protectedKeyIcon:SetSize(14, 14)
        protectedKeyIcon:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
        protectedKeyIcon:SetTexture("Interface\\Icons\\INV_Misc_Key_13")
        protectedKeyIcon:Hide()
        btn.protectedKeyIcon = protectedKeyIcon
        
        local prevWornIcon = clickArea:CreateTexture(nil, "OVERLAY")
        prevWornIcon:SetWidth(14)
        prevWornIcon:SetHeight(14)
        prevWornIcon:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        prevWornIcon:Hide()
        btn.prevWornIcon = prevWornIcon

        local pulse = clickArea:CreateTexture(nil, "OVERLAY", nil, 7)
        pulse:SetAllPoints()
        pulse:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        pulse:SetVertexColor(1, 1, 1, 0.45)
        pulse:Hide()
        btn.pulseTex = pulse

        GPH_ITEM_POOL[GPH_ITEM_POOL_USED] = btn
    end
    btn:SetParent(parent)
    btn:Show()
    if btn.deleteBtn then btn.deleteBtn:Show() end
    btn.clickArea:Show()
    btn.clickArea:EnableMouse(true)
    btn.itemLink = nil
    if btn.pulseTex then btn.pulseTex:Hide() end
    if btn.cooldownOverlay then btn.cooldownOverlay:Hide() end
    if btn.destroyOverlay then btn.destroyOverlay:Hide() end
    if btn.protectedOverlay then btn.protectedOverlay:Hide() end
    if btn.protectedKeyIcon then btn.protectedKeyIcon:Hide() end
    if btn.prevWornIcon then btn.prevWornIcon:Hide() end
    return btn
end


local GPH_SPELL_IDS = { Disenchant = 13262, Prospecting = 31252 }


--- Is spell known by name? (Greedy/Goblin summon.)
local function IsSpellKnownByName(spellName)
    if not spellName or spellName == "" then return false end
    
    
    local localizedName = spellName
    local sid = GPH_SPELL_IDS[spellName]
    if sid and GetSpellInfo then
        local n = GetSpellInfo(sid)
        if n then localizedName = n end
    end

    local bookType = BOOKTYPE_SPELL or "spell"
    local getNumTabs = GetNumSpellTabs or function() return 0 end
    local getTabInfo = GetSpellTabInfo or function() return nil, nil, 0, 0 end
    local getSpellName = GetSpellBookItemName or GetSpellName

    if not getSpellName then return false end

    local numTabs = getNumTabs()
    for i = 1, numTabs do
        local _, _, offset, numSpells = getTabInfo(i)
        if offset and numSpells then
            for j = 1, numSpells do
                local name = getSpellName(offset + j, bookType)
                if name and (name == localizedName or name:find(localizedName, 1, true)) then return true end
            end
        end
    end
    return false
end





local gphDestroyScanTooltip
--- Create/reuse scan tooltip for destroy level check.
local function EnsureGphDestroyScanTooltip()
    if not gphDestroyScanTooltip then
        gphDestroyScanTooltip = CreateFrame("GameTooltip", "TestGPHDestroyScanTooltip", UIParent, "GameTooltipTemplate")
        gphDestroyScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
end

--- API: get destroy scan tooltip (for level/required check).
function A.GetGphDestroyScanTooltip()
    EnsureGphDestroyScanTooltip()
    return gphDestroyScanTooltip
end


--- Get required level + item level for destroy check (tooltip scan).
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


--- Can we destroy this slot? (level, soulbound, protected, no cooldown.)
local function GPHIsDestroyable(bag, slot, link)
    if not link then return nil end
    local itemId = tonumber(link:match("item:(%d+)"))
    if itemId == 6948 then return nil end  

    local hasDE = IsSpellKnownByName("Disenchant")
    local hasProspect = IsSpellKnownByName("Prospecting")

    EnsureGphDestroyScanTooltip()
    gphDestroyScanTooltip:ClearLines()
    gphDestroyScanTooltip:SetBagItem(bag, slot)

    
    
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


--- First destroyable item in bags (for continuous delete; optional prospect priority).
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
                            
                        else
                            
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


local GPHBagSlot
do
    local DEBUG_SPLIT_MOVE = false
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
                        if stackCount >= minCount then return bag, slot, stackCount end
                    end
                end
            end
        end
        return nil
    end
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
    
    if knownBag ~= nil and knownSlot ~= nil then
        local texture = GetContainerItemInfo and select(1, GetContainerItemInfo(knownBag, knownSlot))
        if texture then addSlot(knownBag, knownSlot, getCount(knownBag, knownSlot)) end
    end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                if knownBag == bag and knownSlot == slot then
                    
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
    
    if DEBUG_SPLIT_MOVE and AddonPrint then
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
    GPHBagSlot = {
        GetBagSlotForItemId = GetBagSlotForItemId,
        GetBagSlotWithAtLeast = GetBagSlotWithAtLeast,
        GetAllBagSlotsForItem = GetAllBagSlotsForItem,
        DEBUG_SPLIT_MOVE = DEBUG_SPLIT_MOVE,
    }
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
            list[itemId] = { name = name, texture = tex, addedTime = time() }
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
            list[itemId] = { name = name, texture = tex, addedTime = time() }
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
    text = "Reset this session? Current data will be discarded and nothing will be saved to the Ledger. You can start a new session afterward.",
    button1 = "Yes, Reset",
    button2 = "Cancel",
    OnAccept = function()
        if _G.TestAddon and type(_G.TestAddon.ResetGPHSession) == "function" then
            _G.TestAddon.ResetGPHSession()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}





local BlizzardBagAPI
do
    local function Hide(noCloseAllBags)
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
    local function Show()
        local n = _G.NUM_CONTAINER_FRAMES or 13
        for i = 1, n do
            local frame = _G["ContainerFrame" .. i]
            if frame then frame:SetScript("OnShow", nil) end
        end
        local openBackpack = _G.TestOriginalToggleBackpack or ToggleBackpack
        if openBackpack then openBackpack() end
    end
    BlizzardBagAPI = { Hide = Hide, Show = Show }
end





local gphStackSplitFrame
local ApplyStackSplitSkin, HideEditBoxTemplateTextures
do
    local ELVUI_SPLIT_BACKDROP_FLAT = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    }
    local function HideEdit(edit)
        if not edit then return end
        for i = 1, edit:GetNumRegions() do
            local r = select(i, edit:GetRegions())
            if r and r.SetTexture and r.Hide then r:Hide() end
        end
        if edit.Left then edit.Left:Hide() end
        if edit.Middle then edit.Middle:Hide() end
        if edit.Right then edit.Right:Hide() end
    end
    local function ApplySkin(f)
        if not f then return end
        local db = _G.FugaziBAGSDB
        local skinName = (db and db.gphSkin == "elvui") and "elvui" or "original"
        if skinName == "elvui" then
            f:SetBackdrop(ELVUI_SPLIT_BACKDROP_FLAT)
            f:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
            if f.label then f.label:SetTextColor(0.9, 0.9, 0.9, 1) end
            if f.maxLabel then f.maxLabel:SetTextColor(0.9, 0.9, 0.9, 1) end
            if f.edit then
                HideEdit(f.edit)
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
    HideEditBoxTemplateTextures = HideEdit
    ApplyStackSplitSkin = ApplySkin
end
--- Show stack split popup (like default split bag stack).
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
            
            if parent._splitItemId and not parent._splitFromBank and bf and bf:IsShown() and bf.GetFirstFreeBankSlot and GPHBagSlot and GPHBagSlot.GetAllBagSlotsForItem and PickupContainerItem then
                parent:Hide()
                local itemId = tonumber(parent._splitItemId) or parent._splitItemId
                local firstBag, firstSlot = parent._splitBag, parent._splitSlot
                local queue = GPHBagSlot.GetAllBagSlotsForItem(itemId, firstBag, firstSlot)
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
A.HideBlizzardBags = BlizzardBagAPI.Hide
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
A.ResetGPHSession = ResetGPHSession
_G.ResetGPHSession = ResetGPHSession  
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
A.ResetGPHDataPools = ResetGPHDataPools
A.GetRecycledAggTable = GetRecycledAggTable
A.GetRecycledItemTable = GetRecycledItemTable
A.GetGPHRow = GetGPHRow
A.GetGPHText = GetGPHText
A.GetGPHItemBtn = GetGPHItemBtn
A.IsSpellKnownByName = IsSpellKnownByName
A.GetRequiredAndItemLevelForDestroy = GetRequiredAndItemLevelForDestroy
A.GPHIsDestroyable = GPHIsDestroyable
A.GetFirstDestroyableInBags = GetFirstDestroyableInBags
A.GetBagSlotForItemId = GPHBagSlot.GetBagSlotForItemId
A.GetBagSlotWithAtLeast = GPHBagSlot.GetBagSlotWithAtLeast
A.GetAllBagSlotsForItem = GPHBagSlot.GetAllBagSlotsForItem
A.ShowBlizzardBags = BlizzardBagAPI.Show
A.ShowGPHStackSplit = ShowGPHStackSplit
A.ApplyStackSplitSkin = function() if gphStackSplitFrame then ApplyStackSplitSkin(gphStackSplitFrame) end end
A.GPH_SPELL_IDS = GPH_SPELL_IDS
A.RefreshItemDetailLive = RefreshItemDetailLive
A.gphDestroyQueue = gphDestroyQueue
A.gphDeleteClickTime = gphDeleteClickTime
A.gphDestroyClickTime = gphDestroyClickTime
A.gphPendingQuality = gphPendingQuality