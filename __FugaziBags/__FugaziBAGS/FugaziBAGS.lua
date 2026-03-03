    ----------------------------------------------------------------------
-- __FugaziBAGS: Your bags and bank, GPH (Gold Per Hour) tracking.
-- WoW 3.3.5a (WotLK). Works with FugaziBAGS_VAR.lua and FugaziInstanceTracker.
----------------------------------------------------------------------

local ADDON_NAME = "InstanceTracker"
local Addon = _G.TestAddon or {}
_G.TestAddon = Addon

--- Limits and timings (think of these as "addon rules")
local MAX_INSTANCES_PER_HOUR = 5       -- Max dungeon runs counted per hour for lockout logic
local HOUR_SECONDS = 3600
local MAX_RUN_HISTORY = 100            -- How many runs the Ledger remembers (like quest log cap)
local MAX_RESTORE_AGE_SECONDS = 5 * 60 -- If you leave a dungeon and re-enter within 5 min, we "resume" the same run
local SCROLL_CONTENT_WIDTH = 296       -- Width of the scroll area (item list) in pixels
local GPH_MAX_STACK = 49               -- WoW stack limit; used when confirming "delete whole stack" via red X

-- Cached WoW API (faster than calling _G every time)
local GetContainerItemInfo = _G.GetContainerItemInfo
local GetContainerItemLink = _G.GetContainerItemLink
local GetItemInfo = _G.GetItemInfo
local GetContainerNumSlots = _G.GetContainerNumSlots
local GetContainerItemCooldown = _G.GetContainerItemCooldown
local tonumber = _G.tonumber
local ipairs = _G.ipairs
local pairs = _G.pairs
local table_insert = _G.table and _G.table.insert or table.insert
local table_remove = _G.table and _G.table.remove or table.remove
local math_min = _G.math and _G.math.min or math.min
local math_max = _G.math and _G.math.max or math.max
local type = _G.type

----------------------------------------------------------------------
-- Saved settings (DB = your saved preferences; survives /reload and relog)
----------------------------------------------------------------------
FugaziBAGSDB = FugaziBAGSDB or {}
if TestDB and next(TestDB) then
    for k, v in pairs(TestDB) do
        if FugaziBAGSDB[k] == nil then FugaziBAGSDB[k] = v end
    end
end
local DB = FugaziBAGSDB

-- GPH / inventory window
if DB.fitMute == nil then DB.fitMute = false end
if DB.gphInvKeybind == nil then DB.gphInvKeybind = true end   -- true = B key opens our bags (not Blizzard's)
if DB.gphAutoVendor == nil then DB.gphAutoVendor = true end   -- auto-sell greys at vendor (like "sell junk" always on)
if DB.gphScale15 == nil then DB.gphScale15 = false end         -- "compact" scale for GPH frame (smaller window)
if DB.gphFrameScale == nil then DB.gphFrameScale = 1 end       -- 1 = 100%; bigger = larger inventory window
if DB.gphFrameAlpha == nil then DB.gphFrameAlpha = 1 end       -- 1 = opaque; lower = more transparent
if DB.gphPreviouslyWornItemIds == nil then DB.gphPreviouslyWornItemIds = {} end
DB.gphProtectedItemIdsPerChar = DB.gphProtectedItemIdsPerChar or {}   -- Items you Alt+clicked to "lock" (never auto-delete)
DB.gphProtectedRarityPerChar = DB.gphProtectedRarityPerChar or {}      -- Rarity levels you chose to protect (e.g. all blues)
DB.gphPreviouslyWornOnlyPerChar = DB.gphPreviouslyWornOnlyPerChar or {} -- "Soulbound" style: only protect items you had equipped
DB.gphDestroyListPerChar = DB.gphDestroyListPerChar or {}     -- "Autodelete list": item IDs to destroy when you click red X
DB.gphItemTypeCache = DB.gphItemTypeCache or {}
DB.gphSkin = DB.gphSkin or "original"   -- Look of inventory (original, elvui, pimp_purple, etc.)
DB.gphSkinOverrides = DB.gphSkinOverrides or {}  -- Per-key color overrides on current skin (e.g. titleTextColor = {r,g,b,a}); set in Skins panel.
DB.fitSkin = DB.fitSkin or "original"  -- Look of Instance Tracker / fit window
if DB.gphForceGridView == nil then DB.gphForceGridView = false end    -- true = always show bag slots (grid); false = list in city, grid in combat
if DB.gphBankForceGridView == nil then DB.gphBankForceGridView = false end
if DB.gphGridMode == nil then DB.gphGridMode = false end       -- Current view: list (false) or grid (true)
if DB.gphBankGridMode == nil then DB.gphBankGridMode = false end
if DB.gridConfirmAutoDel == nil then DB.gridConfirmAutoDel = true end  -- Ask "are you sure?" before deleting from autodelete list
if DB.gridProtectedKeyAlpha == nil then DB.gridProtectedKeyAlpha = 0.2 end   -- Protected key overlay visibility when not at vendor (0.1–0.5)
if DB.gphHideTopButtons == nil then DB.gphHideTopButtons = true end    -- Hide some title-bar buttons to save space
if DB.gphBankHideTopButtons == nil then DB.gphBankHideTopButtons = true end
if DB.gphHideDestroyBtn == nil then DB.gphHideDestroyBtn = false end   -- Hide Disenchant/Prospect button
if DB.gphClickSound == nil then DB.gphClickSound = true end   -- "Play sounds": click (list/buttons), hover (rarity/bag/search), trash (delete X / CTRL+RMB). Escape menu.
if DB.gphCategoryHeaderFontCustom == nil then DB.gphCategoryHeaderFontCustom = false end  -- Use custom font/size for list category headers (Scale Settings)
if DB.gphCategoryHeaderFont == nil then DB.gphCategoryHeaderFont = "Fonts\\ARIALN.TTF" end
if DB.gphCategoryHeaderFontSize == nil then DB.gphCategoryHeaderFontSize = 11 end
if DB.gphItemDetailsCustom == nil then DB.gphItemDetailsCustom = false end  -- Customize list row item text/icon (font, rarity color, icon color, alpha, icon size)
if DB.gphHideIconsInList == nil then DB.gphHideIconsInList = false end  -- In list view (inventory and bank), hide item icons for text-only list
DB.gphPerChar = DB.gphPerChar or {}   -- Per-character: gphForceGridView, gphGridMode, gphBankGridMode, gphBankForceGridView, gphHideDestroyBtn

--- Realm#Character key for per-char settings.
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end
--- Get current character's value for key; migrates from global DB on first read.
--- Uses _G.FugaziBAGSDB at call time so it works after SavedVariables load (same pattern as VAR).
local function GetPerChar(key, default)
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphPerChar then SV.gphPerChar = {} end
    local k = GetGphCharKey()
    if not SV.gphPerChar[k] then SV.gphPerChar[k] = {} end
    if SV.gphPerChar[k][key] == nil then
        local g = SV[key]
        SV.gphPerChar[k][key] = (g ~= nil) and g or default
    end
    return SV.gphPerChar[k][key]
end
--- Set current character's value for key.
local function SetPerChar(key, value)
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphPerChar then SV.gphPerChar = {} end
    local k = GetGphCharKey()
    if not SV.gphPerChar[k] then SV.gphPerChar[k] = {} end
    SV.gphPerChar[k][key] = value
end
--- Category header font path and size (list/bank dividers). From Scale Settings when custom enabled, else default ARIALN 11.
local function GetCategoryHeaderFontAndSize()
    local SV = _G.FugaziBAGSDB
    if not SV or not SV.gphCategoryHeaderFontCustom then
        return "Fonts\\ARIALN.TTF", 11
    end
    local path = (SV.gphCategoryHeaderFont and SV.gphCategoryHeaderFont ~= "") and SV.gphCategoryHeaderFont or "Fonts\\ARIALN.TTF"
    local size = tonumber(SV.gphCategoryHeaderFontSize)
    if not size or size < 6 or size > 20 then size = 11 end
    return path, size
end

-- Invisible "secure" button per row so right-click works in combat (WoW blocks normal clicks in combat)
local _secBtnCounter = 0
Addon._gphSelectionDeferFrame = CreateFrame("Frame", nil, UIParent)
Addon._gphSelectionDeferFrame:Hide()

--- Creates or reuses the hidden "secure" button for one bag row so right-click (use item) works.
-- WoW only allows certain secure frames to use items; this attaches one per row.
local function EnsureSecureRowBtn(clickArea, bag, slot)
    if clickArea._fugaziSecBtn then
        -- Reuse: just update bag/slot IDs
        clickArea._fugaziSecPar:SetID(bag)
        clickArea._fugaziSecBtn:SetID(slot)
        clickArea._fugaziSecPar:Show()
        clickArea._fugaziSecBtn:Show()
        return
    end
    _secBtnCounter = _secBtnCounter + 1
    local par = CreateFrame("Frame", "FugaziSecPar" .. _secBtnCounter, clickArea)
    par:SetID(bag)
    par:SetAllPoints(clickArea)
    par:SetFrameLevel((clickArea:GetFrameLevel() or 1) + 1)
    local btn = CreateFrame("Button", "FugaziSecBtn" .. _secBtnCounter, par, "ContainerFrameItemButtonTemplate")
    btn:SetID(slot)
    btn:SetAlpha(0)
    btn:SetAllPoints(par)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if ContainerFrameItemButton_OnLoad then ContainerFrameItemButton_OnLoad(btn) end
    btn:SetScript("OnEnter", function(self)
        local onEnter = clickArea:GetScript("OnEnter")
        if onEnter then onEnter(clickArea) end
    end)
    btn:SetScript("OnLeave", function(self)
        local onLeave = clickArea:GetScript("OnLeave")
        if onLeave then onLeave(clickArea) end
    end)
    btn:HookScript("OnMouseDown", function(self)
        if Addon.TriggerRowPulse then Addon.TriggerRowPulse(self:GetParent():GetParent():GetParent()) end
    end)
    -- Handle modifier clicks: Alt+LMB for protection toggle
    -- Overlay that blocks right-click (sell) when at vendor and item is protected; show/hide set in FillGPHRow.
    -- Parent it to the same frame as the secure button so it always sits on top of the clickable area.
    local vendorProtectOverlay = CreateFrame("Button", nil, par)
    vendorProtectOverlay:SetAllPoints(par)
    vendorProtectOverlay:SetFrameStrata(par:GetFrameStrata() or "MEDIUM")
    vendorProtectOverlay:SetFrameLevel((par:GetFrameLevel() or 1) + 5)
    vendorProtectOverlay:EnableMouse(true)
    vendorProtectOverlay:RegisterForClicks("RightButtonUp")
    vendorProtectOverlay:SetScript("OnClick", function() end)
    vendorProtectOverlay:Hide()
    clickArea._fugaziVendorProtectOverlay = vendorProtectOverlay

    btn:HookScript("OnClick", function(self, button)
        local b, s = self:GetParent():GetID(), self:GetID()
        -- Shift+RMB: link to chat
        if button == "RightButton" and IsShiftKeyDown() then
            local link = GetContainerItemLink and GetContainerItemLink(b, s)
            if link then
                if StackSplitFrame and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
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
                    chatBox:Insert(link)
                    if chatBox.SetFocus then chatBox:SetFocus() end
                end
            end
            return
        end

        local altDown = IsAltKeyDown and IsAltKeyDown()
        if button == "LeftButton" and altDown then
            -- Blizzard template picked up item; put it back
            if ClearCursor then ClearCursor() end
            -- Toggle protection
            local link = GetContainerItemLink and GetContainerItemLink(b, s)
            if link then
                local itemId = tonumber(link:match("item:(%d+)"))
                local Addon = _G.TestAddon
                if itemId and Addon and Addon.GetGphProtectedSet then
                    local set = Addon.GetGphProtectedSet()
                    if set then
                        if set[itemId] then
                            set[itemId] = nil
                            -- Alt override: also clear previously-worn
                            if altDown then
                                local SV = _G.FugaziBAGSDB
                                if SV and SV.gphPreviouslyWornItemIds then SV.gphPreviouslyWornItemIds[itemId] = nil end
                                if not SV._manualUnprotected then SV._manualUnprotected = {} end
                                SV._manualUnprotected[itemId] = true
                            end
                        else
                            set[itemId] = true
                            if altDown then
                                local SV = _G.FugaziBAGSDB
                                if SV and SV._manualUnprotected then SV._manualUnprotected[itemId] = nil end
                            end
                        end
                    end
                end
            end
            if RefreshGPHUI then RefreshGPHUI() end
            if RefreshBankUI then RefreshBankUI() end
        end
        -- RMB: refresh after secure UseContainerItem
        if button == "RightButton" then
            -- Defer one frame so BAG_UPDATE has applied, then rebuild list/bank once.
            if not Addon._gphRmbDefer then Addon._gphRmbDefer = CreateFrame("Frame") end
            local d = Addon._gphRmbDefer
            d:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                local gf = _G.FugaziBAGS_GPHFrame
                if gf then gf._refreshImmediate = true end
                if RefreshGPHUI then RefreshGPHUI() end
                local bf = _G.TestBankFrame
                if bf and bf:IsShown() and RefreshBankUI then RefreshBankUI() end
            end)
        end
    end)
    clickArea._fugaziSecBtn = btn
    clickArea._fugaziSecPar = par
end
_G.FugaziBAGS_EnsureSecureRowBtn = EnsureSecureRowBtn

--- Brief highlight effect on a row (e.g. after you use an item) so you see which one was used.
local function TriggerRowPulse(rowBtn)
    if not rowBtn or not rowBtn.pulseTex then return end
    rowBtn.pulseTex:SetAlpha(1)
    rowBtn.pulseTex:Show()
    if not rowBtn._pulseAnimFrame then
        rowBtn._pulseAnimFrame = CreateFrame("Frame")
    end
    rowBtn._pulseAnimFrame._t = 0
    rowBtn._pulseAnimFrame:SetScript("OnUpdate", function(f, el)
        f._t = f._t + el
        if f._t > 0.25 then rowBtn.pulseTex:Hide(); f:SetScript("OnUpdate", nil)
        else rowBtn.pulseTex:SetAlpha(1 - (f._t / 0.25)) end
    end)
end
Addon.TriggerRowPulse = TriggerRowPulse

--- Sort: empty slots go to the bottom of the list (like "bag space at the end").
local function GPH_EmptyLast(a, b)
    local aEmpty = not a.link
    local bEmpty = not b.link
    if aEmpty ~= bEmpty then return not aEmpty end
    return false
end

--- Sort by item quality (grey → white → green → blue → purple), then by name.
local function GPH_Sort_Rarity(a, b)
    if GPH_EmptyLast(a, b) then return true end
    if GPH_EmptyLast(b, a) then return false end
    if (a and a.isProtected) and not (b and b.isProtected) then return true end
    if (b and b.isProtected) and not (a and a.isProtected) then return false end
    local ao, bo = Addon.RaritySortOrder(a and a.quality), Addon.RaritySortOrder(b and b.quality)
    if type(ao) == "number" and type(bo) == "number" and ao ~= bo then return ao > bo end
    local an = (a and type(a.name) == "string" and a.name) or ""
    local bn = (b and type(b.name) == "string" and b.name) or ""
    return an < bn
end

--- Sort by vendor price (highest gold value first — find the expensive stuff at the top).
local function GPH_Sort_Vendor(a, b)
    if GPH_EmptyLast(a, b) then return true end
    if GPH_EmptyLast(b, a) then return false end
    if (a and a.isProtected) and not (b and b.isProtected) then return true end
    if (b and b.isProtected) and not (a and a.isProtected) then return false end
    if a and b and a.sellPrice ~= b.sellPrice then return (a.sellPrice or 0) > (b.sellPrice or 0) end
    local ao, bo = Addon.RaritySortOrder(a and a.quality), Addon.RaritySortOrder(b and b.quality)
    if type(ao) == "number" and type(bo) == "number" and ao ~= bo then return ao > bo end
    local an = (a and type(a.name) == "string" and a.name) or ""
    local bn = (b and type(b.name) == "string" and b.name) or ""
    return an < bn
end

--- Sort by item level (higher ilvl first — good for gear).
local function GPH_Sort_ItemLevel(a, b)
    if GPH_EmptyLast(a, b) then return true end
    if GPH_EmptyLast(b, a) then return false end
    if (a and a.isProtected) and not (b and b.isProtected) then return true end
    if (b and b.isProtected) and not (a and a.isProtected) then return false end
    if a and b and (a.itemLevel or 0) ~= (b.itemLevel or 0) then return (a.itemLevel or 0) > (b.itemLevel or 0) end
    local ao, bo = Addon.RaritySortOrder(a and a.quality), Addon.RaritySortOrder(b and b.quality)
    if type(ao) == "number" and type(bo) == "number" and ao ~= bo then return ao > bo end
    local an = (a and type(a.name) == "string" and a.name) or ""
    local bn = (b and type(b.name) == "string" and b.name) or ""
    return an < bn
end

--- Sort by category (Consumable, Weapon, Armor, etc.) — like grouping by "type" in your bags.
local function GPH_Sort_CategoryGroup(a, b)
    -- If both are in DELETE category, sort by addedTime (last added at top)
    if (a and a.isDestroy) and (b and b.isDestroy) then
        local at, bt = a.addedTime or 0, b.addedTime or 0
        if at ~= bt then return at > bt end
        return (a.name or "") < (b.name or "")
    end
    if (a and a.isProtected) and not (b and b.isProtected) then return true end
    if (b and b.isProtected) and not (a and a.isProtected) then return false end
    local ao, bo = Addon.RaritySortOrder(a and a.quality), Addon.RaritySortOrder(b and b.quality)
    if type(ao) == "number" and type(bo) == "number" and ao ~= bo then return ao > bo end
    local an = (a and type(a.name) == "string" and a.name) or ""
    local bn = (b and type(b.name) == "string" and b.name) or ""
    return an < bn
end

-- Shared constant table to prevent churn in sort functions and UI refresh
local GPH_CATEGORY_ORDER = { "HIDDEN_FIRST", "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }
local GPH_BAG_PROTECTED_CATEGORY_ORDER = { "BAG_PROTECTED", "HIDDEN_FIRST", "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }

--- Second pass: within same category, sort by quality then name.
local function GPH_Sort_CategoryPass(a, b)
    if GPH_EmptyLast(a, b) then return true end
    if GPH_EmptyLast(b, a) then return false end
    local at = (a and a.itemType) or "Other"
    local bt = (b and b.itemType) or "Other"
    local ao, bo = 999, 999
    for i, c in ipairs(GPH_CATEGORY_ORDER) do if c == at then ao = i; break end end
    for i, c in ipairs(GPH_CATEGORY_ORDER) do if c == bt then bo = i; break end end
    if ao ~= bo then return ao < bo end
    if a and b and (a.quality or 0) ~= (b.quality or 0) then return (a.quality or 0) > (b.quality or 0) end
    local an = (a and type(a.name) == "string" and a.name) or ""
    local bn = (b and type(b.name) == "string" and b.name) or ""
    return an < bn
end

--- Stops a pending "delete by rarity" (e.g. you cancelled "delete all grey items").
local function GPH_CancelRarityDel(q)
    Addon.gphRarityDelStage = Addon.gphRarityDelStage or {}
    Addon.gphPendingQuality = Addon.gphPendingQuality or {}
    Addon.gphRarityDelStage[q] = nil
    Addon.gphPendingQuality[q] = nil
    if gphFrame and gphFrame.gphEscCatcher then
        gphFrame.gphEscCatcher:ClearFocus()
        gphFrame.gphEscCatcher:Hide()
    end
end

--- Sets one rarity's protection flag and refreshes (used by click and by drag-paint).
local function GPH_SetRarityProtection(q, value)
    if not Addon.GetGphProtectedRarityFlags then return end
    local flags = Addon.GetGphProtectedRarityFlags()
    if flags[q] == value then return end
    flags[q] = value
    if value then
        local SV = _G.FugaziBAGSDB
        if SV and SV._manualUnprotected then SV._manualUnprotected = {} end
    end
    if gphFrame then gphFrame._refreshImmediate = true end
    if RefreshGPHUI then RefreshGPHUI() end
end

--- Starts the "clear drag paint when LMB released" watcher (one frame, no per-button cost).
local function GPH_StartRarityDragPaintClear()
    local f = Addon._gphRarityDragPaintClearFrame
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetScript("OnUpdate", function(self)
            if not (Addon.gphRarityDragPaint and Addon.gphRarityDragPaint.active) then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                return
            end
            local down = (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) or false
            if not down then
                Addon.gphRarityDragPaint.active = false
                self:SetScript("OnUpdate", nil)
                self:Hide()
            end
        end)
        Addon._gphRarityDragPaintClearFrame = f
    end
    f:Show()
    f:SetScript("OnUpdate", f:GetScript("OnUpdate"))
end

--- Handles clicks on the rarity bar (grey / white / green / blue / purple buttons).
-- Left = select rarity; Ctrl+click = toggle list/grid; Right = context menu (Start Session, etc.).
local function GPHQualBtn_OnClick(self, button)
    if Addon.PlayClickSound then Addon.PlayClickSound() end
    if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
    local ctrl  = IsControlKeyDown and IsControlKeyDown()
    local alt   = IsAltKeyDown and IsAltKeyDown()
    local shift = IsShiftKeyDown and IsShiftKeyDown()

    local activeTable = Addon.gphContinuousDelActive or {}
    local hasActive = false
    for k, v in pairs(activeTable) do if v then hasActive = true; break end end
    if hasActive and not (ctrl or alt or shift) then
        wipe(Addon.gphContinuousDelActive)
        if Addon.ContinuousDeleteWorker then Addon.ContinuousDeleteWorker:Hide() end
        if gphFrame then gphFrame._refreshImmediate = true end
        RefreshGPHUI()
        return
    end

    if ctrl and button == "LeftButton" then
        local now = (GetTime and GetTime()) or time()
        local q = self.quality
        Addon.gphContinuousDelStage = Addon.gphContinuousDelStage or {}
        local stage = Addon.gphContinuousDelStage[q]
        if not stage or (now - stage.time) > 4 then
            Addon.gphContinuousDelStage[q] = { clicks = 1, time = now }
        else
            stage.clicks = stage.clicks + 1
            stage.time = now
            if stage.clicks >= 3 then
                Addon.gphContinuousDelStage[q] = nil
                local SV = _G.FugaziBAGSDB or {}
                if SV.gridConfirmAutoDel == false then
                    Addon.StartContinuousDelete(q)
                else
                    StaticPopup_Show("GPH_CONTINUOUS_DELETE", self.label, nil, { quality = q })
                end
            end
        end
        if gphFrame then gphFrame._refreshImmediate = true end
        RefreshGPHUI()
        return
    end

    if shift and button == "RightButton" and (self.currentCount or 0) > 0 then
        local bf = _G.TestBankFrame
        local mf = _G.MailFrame
        if bf and bf:IsShown() then
            Addon.RarityMoveJob = { mode = "bags_to_bank", rarity = self.quality }
            if Addon.RarityMoveWorker then Addon.RarityMoveWorker._t = 0; Addon.RarityMoveWorker:Show() end
        elseif mf and mf:IsShown() then
            local recipient = _G.SendMailNameEditBox and _G.SendMailNameEditBox:GetText()
            if not recipient or recipient:match("^%s*$") then
                print("|cffff0000[FugaziBAGS]|r Please enter a recipient first.")
            else
                StaticPopup_Show("GPH_CONFIRM_MAIL_RARITY", self.label, recipient, { rarity = self.quality })
            end
        end
        return
    end

    if alt and button == "LeftButton" and Addon.GetGphProtectedRarityFlags then
        -- If we started a drag-paint on MouseDown, the toggle already happened; don't toggle again on Click.
        if Addon.gphRarityDragPaint and Addon.gphRarityDragPaint.active then
            return
        end
        local flags = Addon.GetGphProtectedRarityFlags()
        GPH_SetRarityProtection(self.quality, not flags[self.quality])
        return
    end

    if ctrl and button == "RightButton" and (self.currentCount or 0) > 0 then
        Addon.gphPendingQuality = Addon.gphPendingQuality or {}
        Addon.gphRarityDelStage = Addon.gphRarityDelStage or {}
        local now = (GetTime and GetTime()) or time()
        local q = self.quality
        local stage = Addon.gphRarityDelStage[q]
        if not stage then
            Addon.gphRarityDelStage[q] = { stage = 1, time = now }
            if gphFrame and gphFrame.gphEscCatcher then
                gphFrame.gphEscCatcher:Show()
                gphFrame.gphEscCatcher:SetFocus()
            end
        elseif stage.stage == 1 then
            if (now - stage.time) > 4 then GPH_CancelRarityDel(q)
            else Addon.gphRarityDelStage[q] = { stage = 2, time = now }; Addon.gphPendingQuality[q] = now end
        elseif stage.stage == 2 then
            if (now - stage.time) > 4 then GPH_CancelRarityDel(q)
            else
                GPH_CancelRarityDel(q)
                local SV = _G.FugaziBAGSDB or {}
            if SV.gridConfirmAutoDel == false then
                Addon.DeleteAllOfQuality(q)
            else
                StaticPopup_Show("GPH_DELETE_QUALITY", self.currentCount, self.label, { quality = q })
            end
            end
        end
        if gphFrame then gphFrame._refreshImmediate = true end
        RefreshGPHUI()
        return
    end

    if button == "LeftButton" then
        if gphFrame then
            if gphFrame.gphFilterQuality == self.quality then gphFrame.gphFilterQuality = nil
            else gphFrame.gphFilterQuality = self.quality end
            for qKey in pairs(Addon.gphPendingQuality or {}) do Addon.gphPendingQuality[qKey] = nil end
            if gphFrame.gphEscCatcher then gphFrame.gphEscCatcher:Hide(); gphFrame.gphEscCatcher:ClearFocus() end
            gphFrame._refreshImmediate = true
            gphFrame.gphScrollToDefaultOnNextRefresh = true
        end
        RefreshGPHUI()
        return
    end

    if button == "RightButton" then
        if gphFrame then
            gphFrame.gphFilterQuality = nil
            gphFrame._refreshImmediate = true
        end
        for qKey in pairs(Addon.gphPendingQuality or {}) do Addon.gphPendingQuality[qKey] = nil end
        RefreshGPHUI()
        return
    end
end

--- Mouse down: start Alt+LMB drag-paint so we can drag across buttons to set/clear protection.
local function GPHQualBtn_OnMouseDown(self, mouseButton)
    if mouseButton ~= "LeftButton" or not (IsAltKeyDown and IsAltKeyDown()) or not Addon.GetGphProtectedRarityFlags then return end
    local flags = Addon.GetGphProtectedRarityFlags()
    local newVal = not flags[self.quality]
    GPH_SetRarityProtection(self.quality, newVal)
    Addon.gphRarityDragPaint = Addon.gphRarityDragPaint or {}
    Addon.gphRarityDragPaint.active = true
    Addon.gphRarityDragPaint.value = newVal
    GPH_StartRarityDragPaintClear()
end

--- Tooltip when you hover a rarity button: explains LMB, Ctrl+click, Shift+RMB, etc.
local function GPHQualBtn_OnEnter(self)
    -- Drag-paint: while Alt+LMB is held, applying the same protect/unprotect to each rarity we drag over.
    if Addon.gphRarityDragPaint and Addon.gphRarityDragPaint.active and Addon.GetGphProtectedRarityFlags then
        local down = (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) and (IsAltKeyDown and IsAltKeyDown())
        if down then
            GPH_SetRarityProtection(self.quality, Addon.gphRarityDragPaint.value)
        end
    end
    if not self.label then return end
    if Addon.PlayHoverSound then Addon.PlayHoverSound() end
    Addon.AnchorTooltipRight(self)
    GameTooltip:SetText(self.label or "Rarity")
    GameTooltip:AddLine("LMB: Filter", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Ctrl+RMB x3: Delete All", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Ctrl+LMB x3: Continuous Delete", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Alt+LMB: Protect whole Rarity", 0.6, 0.6, 0.6)
    local isMailOpen = _G.MailFrame and _G.MailFrame:IsShown()
    GameTooltip:AddLine("Shift+RMB: " .. (isMailOpen and "Send Rarity to Mailbox" or "Send Rarity to Bank"), 0.6, 0.6, 0.6)
    GameTooltip:Show()
    if self.fs and (not Addon.gphPendingQuality or not Addon.gphPendingQuality[self.quality]) then
        self.fs:SetAlpha(1)
    end
end

--- Hides tooltip and dims the rarity button when mouse leaves.
local function GPHQualBtn_OnLeave(self)
    GameTooltip:Hide()
    if self.fs and (not Addon.gphPendingQuality or not Addon.gphPendingQuality[self.quality]) and (not Addon.gphContinuousDelActive or not Addon.gphContinuousDelActive[self.quality]) then
        self.fs:SetAlpha(0)
    end
end

--- Pulsing glow on rarity button when "continuous delete" is active for that quality.
local function GPHQualBtn_OnUpdate(self, elapsed)
    if Addon.gphContinuousDelActive and Addon.gphContinuousDelActive[self.quality] then
        local t = GetTime() or 0
        local pulse = (math.sin(t * 4) + 1) / 2
        if self.fs then self.fs:SetAlpha(0.3 + pulse * 0.7) end
    elseif self.fs and (GetMouseFocus() == self) then
        if self.fs:GetAlpha() < 1 then self.fs:SetAlpha(1) end
    elseif self.fs and Addon.GetGphProtectedRarityFlags then
        -- For protected rarities (Alt+click) give both the number and the rarity fill a soft pulse on all skins.
        local flags = Addon.GetGphProtectedRarityFlags()
        if flags and flags[self.quality] then
            local t = (GetTime and GetTime()) and GetTime() or time()
            local pulse = (math.sin(t * 3.5) + 1) / 2
            local aNum = 0.4 + pulse * 0.6
            local aFill = 0.6 + pulse * 0.4
            self.fs:SetAlpha(aNum)
            if self.bg and self.bg.GetVertexColor and self.bg.SetVertexColor then
                local r, g, b, a = self.bg:GetVertexColor()
                self.bg:SetVertexColor(r or 1, g or 1, b or 1, aFill)
            end
            return
        end
    elseif self.fs and self.fs:GetAlpha() > 0 and (not Addon.gphPendingQuality or not Addon.gphPendingQuality[self.quality]) then
        self.fs:SetAlpha(0)
    end
end




if not _G._FugaziBAGS_LoadLogged then
    _G._FugaziBAGS_LoadLogged = true
    print("|cff00aaff[__FugaziBAGS]|r Loaded. Press B to open inventory.")
end

-- Register for PLAYER_LOGIN immediately so we run even if the rest of the file errors. Init runs when we assign _FugaziBAGS_DoLogin later.
local eventFrame = CreateFrame("Frame")
_G._FugaziBAGS_DoLogin = function() end
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then _G._FugaziBAGS_DoLogin() end
end)

-- Source character key for "copy auto-destroy list from" dropdown.
local gphDestroyCopySourceKey

-- Skins loaded from skins.lua (__FugaziBAGS_Skins).
local Skins = _G.__FugaziBAGS_Skins or {}
local SKIN = Skins.SKIN or {}
local ApplyGPHFrameSkin = Skins.ApplyGPHFrameSkin or function() end
local ApplyBankFrameSkin = Skins.ApplyBankFrameSkin or function() end
local ApplyGphInventoryTitle = Skins.ApplyGphInventoryTitle or function() end

--- Applies frame opacity: chrome (and backdrop) use frameAlpha; bag items (scroll/grid) use itemAlpha (0.8–1) so they stay readable.
local function ApplyFrameAlpha(f)
    if not f then return end
    local SV = _G.FugaziBAGSDB
    local fa = (SV and SV.gphFrameAlpha) or 1
    if fa > 0.99 then
        if f._gphAlphaBg and f._gphAlphaBg:GetBackdrop() then
            f:SetBackdrop(f._gphAlphaBg:GetBackdrop())
            local r, g, b, a = f._gphAlphaBg:GetBackdropColor()
            f:SetBackdropColor(r or 0.08, g or 0.08, b or 0.12, a or 1)
            local br, bg_, bb, ba = f._gphAlphaBg:GetBackdropBorderColor()
            f:SetBackdropBorderColor(br or 0.6, bg_ or 0.5, bb or 0.2, ba or 0.8)
        end
        f:SetAlpha(1)
        if f.scrollFrame then f.scrollFrame:SetAlpha(1) end
        if f.gphGridContent then f.gphGridContent:SetAlpha(1) end
        local chrome = { f.gphTitleBar, f.gphSep, f.gphHeader, f.gphBottomBar }
        for _, r in ipairs(chrome) do if r then r:SetAlpha(1) end end
        if f._gphAlphaBg then f._gphAlphaBg:Hide() end
        return
    end
    if not f._gphAlphaBg then
        local bg = CreateFrame("Frame", nil, f)
        bg:SetAllPoints(f)
        bg:SetFrameLevel(0)
        bg:SetFrameStrata(f:GetFrameStrata() or "DIALOG")
        bg:EnableMouse(false)
        f._gphAlphaBg = bg
    end
    local bd = f:GetBackdrop()
    if bd then
        f._gphAlphaBg:SetBackdrop(bd)
        local r, g, b, a = f:GetBackdropColor()
        f._gphAlphaBg:SetBackdropColor(r or 0.08, g or 0.08, b or 0.12, 1)
        local br, bg_, bb, ba = f:GetBackdropBorderColor()
        f._gphAlphaBg:SetBackdropBorderColor(br or 0.6, bg_ or 0.5, bb or 0.2, ba or 0.8)
        f:SetBackdrop(nil)
    end
    f._gphAlphaBg:SetAlpha(fa)
    f._gphAlphaBg:Show()
    f:SetAlpha(1)
    local itemAlpha = 0.8 + (fa - 0.1) * (0.2 / 0.9)
    if fa < 0.1 then itemAlpha = 0.8 end
    if f.scrollFrame then f.scrollFrame:SetAlpha(itemAlpha) end
    if f.gphGridContent then f.gphGridContent:SetAlpha(itemAlpha) end
    local chrome = { f.gphTitleBar, f.gphSep, f.gphHeader, f.gphBottomBar }
    for _, r in ipairs(chrome) do if r then r:SetAlpha(fa) end end
end

--- Returns the border color for the current skin (so the inventory frame border matches the theme).
local function GetActiveSkinBorderColor()
    local SV = _G.FugaziBAGSDB
    local val = SV and SV.gphSkin or "original"
    local s = SKIN[val] or SKIN.original
    if s and s.mainBorder then
        return unpack(s.mainBorder)
    end
    -- Fallback: original gold border.
    return 0.6, 0.5, 0.2, 0.8
end

--- Applies custom font/color to title, bag space, search when "Customize" is on (title +1 size, bag/search fixed size 10; same font and headerTextColor).
local function ApplyCustomizeToFrame(f)
    if not f then return end
    local SV = _G.FugaziBAGSDB
    local custom = SV and SV.gphCategoryHeaderFontCustom
    local path, fontSize = GetCategoryHeaderFontAndSize()
    local headerColor = (SV and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor) and SV.gphSkinOverrides.headerTextColor or nil
    local FIXED_HEADER_SIZE = 10

    if f.gphTitle then
        if custom then
            f.gphTitle:SetFont(path, math.min(20, fontSize + 1), "")
            if headerColor and #headerColor >= 4 then f.gphTitle:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4]) end
        else
            -- Reset to default skin font/color
            f.gphTitle:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
            if f.gphAccentTextColor then f.gphTitle:SetTextColor(unpack(f.gphAccentTextColor)) end
        end
    end
    if f.gphBagSpaceBtn and f.gphBagSpaceBtn.fs then
        if custom then
            f.gphBagSpaceBtn.fs:SetFont(path, FIXED_HEADER_SIZE, "")
            if headerColor and #headerColor >= 4 then f.gphBagSpaceBtn.fs:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4]) end
        else
            f.gphBagSpaceBtn.fs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            if f.gphAccentTextColor then f.gphBagSpaceBtn.fs:SetTextColor(unpack(f.gphAccentTextColor)) else f.gphBagSpaceBtn.fs:SetTextColor(1, 0.85, 0.4, 1) end
        end
    end
    if f.gphSearchLabel then
        if custom then
            f.gphSearchLabel:SetFont(path, FIXED_HEADER_SIZE, "")
            if headerColor and #headerColor >= 4 then f.gphSearchLabel:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4]) end
        else
            f.gphSearchLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            if f.gphAccentTextColor then f.gphSearchLabel:SetTextColor(unpack(f.gphAccentTextColor)) else f.gphSearchLabel:SetTextColor(0.92, 0.82, 0.55, 1) end
        end
    end
    -- When row formatting is enabled, reuse its font settings for the Gold/Timer/GPH status text as well
    -- so the running session bar matches the list style.
    if f.statusText then
        local SV = _G.FugaziBAGSDB
        local useRowFont = SV and SV.gphItemDetailsCustom
        local size = 10  -- keep original size for Gold/Timer/GPH text
        if useRowFont then
            local rowPath = (SV.gphItemDetailsFont and SV.gphItemDetailsFont ~= "") and SV.gphItemDetailsFont or "Fonts\\FRIZQT__.TTF"
            f.statusText:SetFont(rowPath, size, "")
        else
            f.statusText:SetFont("Fonts\\FRIZQT__.TTF", size, "")
        end
    end
    if f.bankTitleText then
        if custom then
            f.bankTitleText:SetFont(path, math.min(20, fontSize + 1), "")
            if headerColor and #headerColor >= 4 then f.bankTitleText:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4]) end
        else
            f.bankTitleText:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
            if f.bankSpaceTextColor then f.bankTitleText:SetTextColor(unpack(f.bankSpaceTextColor)) else f.bankTitleText:SetTextColor(1, 0.85, 0.4, 1) end
        end
    end
    if f.bankSpaceBtn and f.bankSpaceBtn.fs then
        if custom then
            f.bankSpaceBtn.fs:SetFont(path, FIXED_HEADER_SIZE, "")
            if headerColor and #headerColor >= 4 then f.bankSpaceBtn.fs:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4]) end
        else
            f.bankSpaceBtn.fs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            if f.bankSpaceTextColor then f.bankSpaceBtn.fs:SetTextColor(unpack(f.bankSpaceTextColor)) else f.bankSpaceBtn.fs:SetTextColor(1, 0.85, 0.4, 1) end
        end
    end
end

--- Applies "Item details" customizations to a list row (font, size, per-rarity color, icon color, alpha, icon size). Only when gphItemDetailsCustom is on.
--- itemDetailsRarityColors[quality] = { r, g, b } overrides that rarity's name color; if nil we keep the row's existing color.
local function ApplyItemDetailsToRow(row, item)
    if not row or not row.nameFs then return end
    local SV = _G.FugaziBAGSDB
    if not SV or not SV.gphItemDetailsCustom then
        -- Reset to defaults if disabled
        row.nameFs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.nameFs:SetAlpha(1)
        if row.icon then
            row.icon:SetAlpha(1)
            row.icon:SetSize(16, 16)
            row.icon:SetVertexColor(1, 1, 1)
        end
        return
    end
    local path = (SV.gphItemDetailsFont and SV.gphItemDetailsFont ~= "") and SV.gphItemDetailsFont or "Fonts\\FRIZQT__.TTF"
    local fontSize = (SV.gphItemDetailsFontSize and SV.gphItemDetailsFontSize >= 8 and SV.gphItemDetailsFontSize <= 16) and SV.gphItemDetailsFontSize or 11
    -- Row opacity: allow a smooth 0.1–1.0 range, clamped so the row never fully disappears
    local alpha = 1
    if type(SV.gphItemDetailsAlpha) == "number" then
        if SV.gphItemDetailsAlpha < 0.1 then alpha = 0.1
        elseif SV.gphItemDetailsAlpha > 1 then alpha = 1
        else alpha = SV.gphItemDetailsAlpha end
    end
    -- Icon size: respect slider directly within a safe 12–28px range
    local iconSize = (SV.gphItemDetailsIconSize and SV.gphItemDetailsIconSize >= 12 and SV.gphItemDetailsIconSize <= 28) and SV.gphItemDetailsIconSize or 16
    local rarityColors = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsRarityColors
    local legacyOne = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsRarityColor
    if not rarityColors and legacyOne and #legacyOne >= 3 then
        rarityColors = { [1] = legacyOne }
    end
    local quality = (item and item.quality ~= nil) and item.quality or 0
    local rarityColor = (rarityColors and rarityColors[quality] and #rarityColors[quality] >= 3) and rarityColors[quality] or nil
    local iconColor = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsIconColor
    row.nameFs:SetFont(path, fontSize, "")
    row.nameFs:SetAlpha(alpha)
    if rarityColor then
        local hex = string.format("%02x%02x%02x", math.floor(rarityColor[1] * 255), math.floor(rarityColor[2] * 255), math.floor(rarityColor[3] * 255))
        row.nameFs:SetText("|cff" .. hex .. (item and (item.name or "Unknown") or "Unknown") .. "|r")
    end
    if row.icon and not (SV.gphHideIconsInList) then
        row.icon:SetSize(iconSize, iconSize)
        row.icon:SetAlpha(alpha)
        if iconColor and #iconColor >= 3 then
            row.icon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3])
        end
    end
end

-- Shared helper: computes the row height for item-detail rows (inventory + bank)
-- so that the "Row Icon Size" slider always maps to the same vertical spacing.
local function ComputeItemDetailsRowHeight(baseHeight)
    local SVh = _G.FugaziBAGSDB
    local rowStep = baseHeight or 18
    if SVh and SVh.gphItemDetailsCustom and type(SVh.gphItemDetailsIconSize) == "number" then
        rowStep = math.max(baseHeight or 18, math.min(32, SVh.gphItemDetailsIconSize + 4))
    end
    return rowStep
end

--- Applies the chosen skin to the inventory and bank windows (called when you change skin in options).
function ApplyTestSkin()
    if _G.TestGPHFrame and _G.TestGPHFrame.ApplySkin then _G.TestGPHFrame.ApplySkin() end
    if _G.TestBankFrame and _G.TestBankFrame.ApplySkin then _G.TestBankFrame.ApplySkin() end
    ApplyCustomizeToFrame(_G.TestGPHFrame)
    ApplyCustomizeToFrame(_G.TestBankFrame)
    if _G.TestAddon and _G.TestAddon.ApplyStackSplitSkin then _G.TestAddon.ApplyStackSplitSkin() end
    -- Instance Tracker uses its own skin (fitSkin) and Escape menu; not tied to BAGS skin.
end

----------------------------------------------------------------------
-- Loader: keybind, bag hook, options panel (runs on ADDON_LOADED)
----------------------------------------------------------------------
local keybindOwner
-- Old secure-macro bag key override (FugaziBAGSBagKeyButton) has been retired.
-- in combat. The bag key is now handled by the InstanceTracker-style helpers
-- in FugaziBAGS_VAR.lua (GPHInvBagKeyHandler + InstanceTrackerGPHToggleButton).
--- Legacy: no longer overrides the bag key; kept so old code that calls this doesn't error.
local function ApplyBagKeyOverride()
    -- Intentionally left empty; kept only so older code paths that still call
    -- this function do nothing instead of erroring.
end

--- When you press B (or your bag key): close default bags and open our inventory window instead.
local function BagKeyHandler()
    if CloseAllBags then CloseAllBags() end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
end
local origToggleBackpack, origOpenAllBags
--- Replaces WoW's default "B" key so it opens our bags instead of Blizzard's.
local function InstallBagHook()
    if not origToggleBackpack and ToggleBackpack then
        origToggleBackpack = ToggleBackpack
        _G.TestOriginalToggleBackpack = ToggleBackpack
    end
    if not origOpenAllBags and OpenAllBags then
        origOpenAllBags = OpenAllBags
        _G.TestOriginalOpenAllBags = OpenAllBags
    end
    if origToggleBackpack then ToggleBackpack = BagKeyHandler end
    if origOpenAllBags then OpenAllBags = BagKeyHandler end
end

--- Builds the Escape → Interface → AddOns → _FugaziBAGS options panel (checkboxes, sliders, skin list).
local function CreateOptionsPanel()
    if _G.FugaziBAGSOptionsPanel then return end
    local panel = CreateFrame("Frame", "FugaziBAGSOptionsPanel", UIParent)
    panel.name = "_FugaziBAGS"
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end
    panel.refresh = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("_FugaziBAGS")

    -- Skin selector and font/color options moved to Escape → Interface → _FugaziBAGS → Skins.

    -- Confirm auto-delete: applies to grid/list delete shortcuts and destroy list.
    local confirmCb = CreateFrame("CheckButton", "FugaziBAGSConfirmDelCheck", panel, "OptionsCheckButtonTemplate")
    confirmCb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    _G["FugaziBAGSConfirmDelCheckText"]:SetText("Confirm Auto Delete")
    confirmCb:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gridConfirmAutoDel = (self:GetChecked() == 1 or self:GetChecked() == true) end
    end)

    -- Play sounds: click (list/buttons), hover (rarity/bag/search), trash (delete X / CTRL+RMB).
    local clickSoundCb = CreateFrame("CheckButton", "FugaziBAGSClickSoundCheck", panel, "OptionsCheckButtonTemplate")
    clickSoundCb:SetPoint("TOPLEFT", confirmCb, "BOTTOMLEFT", 0, -8)
    _G["FugaziBAGSClickSoundCheckText"]:SetText("Play sounds")
    clickSoundCb:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphClickSound = (self:GetChecked() == 1 or self:GetChecked() == true) end
    end)

    -- Copy auto-destroy list from another character (per-character destroy list).
    local copyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    copyLabel:SetPoint("TOPLEFT", clickSoundCb, "BOTTOMLEFT", 0, -16)
    copyLabel:SetText("Copy auto-destroy list from character:")

    local destroyDropdown = CreateFrame("Frame", "FugaziBAGSOptionsDestroyDropdown", panel, "UIDropDownMenuTemplate")
    destroyDropdown:SetPoint("TOPLEFT", copyLabel, "BOTTOMLEFT", -16, -8)
    destroyDropdown:SetScale(1)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(destroyDropdown, 220) end

    -- Helper: build Realm#Character key for current player (used only for copy UI).
    local function GetCopyCharKey()
        local r = (GetRealmName and GetRealmName()) or ""
        local c = (UnitName and UnitName("player")) or ""
        return (r or "") .. "#" .. (c or "")
    end

    local function DestroyMenu_Initialize(_, level)
        local SV = _G.FugaziBAGSDB
        if not SV or not SV.gphDestroyListPerChar then return end
        for key, list in pairs(SV.gphDestroyListPerChar) do
            if list and next(list) ~= nil then
                local realm, char = key:match("^(.-)#(.*)$")
                local text = (char and char ~= "" and char) or key
                local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
                if info then
                    info.text = text
                    info.value = key
                    info.func = function()
                        gphDestroyCopySourceKey = key
                        if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(destroyDropdown, key) end
                        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(destroyDropdown, text) end
                    end
                    UIDropDownMenu_AddButton(info, level or 1)
                end
            end
        end
    end

    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(destroyDropdown, DestroyMenu_Initialize) end

    local copyBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    copyBtn:SetSize(110, 22)
    copyBtn:SetPoint("LEFT", destroyDropdown, "RIGHT", 0, 2)
    copyBtn:SetText("Copy")
    copyBtn:SetScript("OnClick", function()
        -- Debug trace to ensure the button is wired and clicked.
        print("|cff00aaff[__FugaziBAGS]|r Copy button clicked.")

        local SV = _G.FugaziBAGSDB
        if not SV then
            print("|cff00aaff[__FugaziBAGS]|r No FugaziBAGSDB found; cannot copy auto-destroy list.")
            return
        end
        if not SV.gphDestroyListPerChar then
            print("|cff00aaff[__FugaziBAGS]|r No gphDestroyListPerChar table; nothing to copy from.")
            return
        end
        if not gphDestroyCopySourceKey then
            print("|cff00aaff[__FugaziBAGS]|r No source character selected in dropdown.")
            return
        end
        local src = SV.gphDestroyListPerChar[gphDestroyCopySourceKey]
        if not src or next(src) == nil then
            print("|cff00aaff[__FugaziBAGS]|r Selected source has an empty auto-destroy list.")
            return
        end
        -- Resolve / create the *current character's* destroy list table directly in SV, independent of Addon internals.
        if not SV.gphDestroyListPerChar then SV.gphDestroyListPerChar = {} end
        local curKey = GetCopyCharKey()
        if not curKey or curKey == "" then
            print("|cff00aaff[__FugaziBAGS]|r Could not resolve current character key; aborting copy.")
            return
        end
        local dst = SV.gphDestroyListPerChar[curKey]
        if not dst then
            dst = {}
            SV.gphDestroyListPerChar[curKey] = dst
        end

        -- Overwrite current character's auto-destroy list with a deep copy of source.
        if wipe then wipe(dst) else for k in pairs(dst) do dst[k] = nil end end
        local count = 0
        for id, v in pairs(src) do
            dst[id] = { name = v.name, texture = v.texture, addedTime = v.addedTime }
            count = count + 1
        end

        -- Warm the current character's destroy list cache and refresh UI so the list appears immediately.
        if _G.TestAddon and _G.TestAddon.GetGphDestroyList then
            _G.TestAddon.GetGphDestroyList()
        end
        if RefreshGPHUI then
            RefreshGPHUI()
        end
        print("|cff00aaff[__FugaziBAGS]|r Copied |cffffff00" .. tostring(count) .. "|r auto-destroy entries from |cffffff00" .. tostring(gphDestroyCopySourceKey) .. "|r to this character.")
    end)

    -- Auto-delete list: scrollable list of all items on the destroy list with remove buttons
    local delListLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    delListLabel:SetPoint("TOPLEFT", destroyDropdown, "BOTTOMLEFT", 16, -12)
    delListLabel:SetText("Auto-delete list (current character):")

    local RefreshDelListPanel  -- forward declaration
    
    local delListScroll = CreateFrame("ScrollFrame", "FugaziBAGSDelListScroll", panel, "UIPanelScrollFrameTemplate")
    delListScroll:SetPoint("TOPLEFT", delListLabel, "BOTTOMLEFT", 0, -12)
    delListScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -36, 36)
    delListScroll:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    delListScroll:SetBackdropColor(0, 0, 0, 0)
    delListScroll:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.4)

    local delListContent = CreateFrame("Frame", nil, delListScroll)
    delListContent:SetWidth(340) -- Fixed width
    delListContent:SetHeight(1)
    delListScroll:SetScrollChild(delListContent)

    local delListRows = {}
    RefreshDelListPanel = function()
        -- Use pairs to ensure all rows are hidden (in case of holes)
        for _, r in pairs(delListRows) do r:Hide() end
        local A = _G.TestAddon
        local list = (A and A.GetGphDestroyList) and A.GetGphDestroyList() or {}
        local sorted = {}
        
        -- Get search text and trim it
        local searchEdit = _G.FugaziBAGSDelListSearch
        local rawText = (searchEdit and searchEdit:GetText() or "")
        local searchText = rawText:lower():gsub("^%s*(.-)%s*$", "%1")
        
        for id, info in pairs(list) do
            local name = type(info) == "table" and info.name or (GetItemInfo and GetItemInfo(id))
            if not name or name == "" then name = "Item " .. tostring(id) end
            
            local match = true
            if searchText ~= "" then
                if not name:lower():find(searchText, 1, true) then
                    match = false
                end
            end
            
            if match then
                local tex = type(info) == "table" and info.texture or (GetItemInfo and select(10, GetItemInfo(id)))
                local at = (type(info) == "table" and info.addedTime) or 0
                table.insert(sorted, { id = id, name = name, texture = tex, addedTime = at })
            end
        end
        
        -- Sort: strictly newest items (highest addedTime) first
        table.sort(sorted, function(a, b)
            local atA = a.addedTime or 0
            local atB = b.addedTime or 0
            if atA ~= atB then return atA > atB end
            return (a.name or "") < (b.name or "")
        end)
        
        local yOff = 0
        for i, entry in ipairs(sorted) do
            local row = delListRows[i]
            if not row then
                row = CreateFrame("Frame", nil, delListContent)
                row:SetHeight(18)
                local ico = row:CreateTexture(nil, "ARTWORK")
                ico:SetSize(14, 14)
                ico:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.icon = ico
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("LEFT", ico, "RIGHT", 4, 0)
                fs:SetPoint("RIGHT", row, "RIGHT", -22, 0)
                fs:SetJustifyH("LEFT")
                row.nameFs = fs
                local rmBtn = CreateFrame("Button", nil, row)
                rmBtn:SetSize(14, 14)
                rmBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
                rmBtn:SetNormalFontObject(GameFontNormalSmall)
                rmBtn:SetHighlightFontObject(GameFontHighlightSmall)
                rmBtn:SetText("|cffff4444x|r")
                rmBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
                row.rmBtn = rmBtn
                delListRows[i] = row
            end
            row:SetParent(delListContent)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", delListContent, "TOPLEFT", 0, -yOff)
            row:SetPoint("TOPRIGHT", delListContent, "TOPRIGHT", 0, -yOff)
            if row.icon then row.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark") end
            row.nameFs:SetText(entry.name)
            row.rmBtn:SetScript("OnClick", function()
                local A2 = _G.TestAddon
                local dlist = (A2 and A2.GetGphDestroyList) and A2.GetGphDestroyList()
                if dlist then dlist[entry.id] = nil end
                RefreshDelListPanel()
                if RefreshGPHUI then RefreshGPHUI() end
            end)
            row:Show()
            yOff = yOff + 18
        end
        delListContent:SetHeight(math.max(1, yOff))
        if #sorted == 0 then
            if not delListContent.emptyFs then
                local efs = delListContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                efs:SetPoint("TOPLEFT", delListContent, "TOPLEFT", 4, -4)
                efs:SetText("(no matches)")
                delListContent.emptyFs = efs
            end
            delListContent.emptyFs:Show()
            if searchText == "" then delListContent.emptyFs:SetText("(empty)") else delListContent.emptyFs:SetText("(no matches)") end
        elseif delListContent.emptyFs then
            delListContent.emptyFs:Hide()
        end
    end

    -- Search editbox for auto-delete list (created AFTER function definition)
    local delListSearch = CreateFrame("EditBox", "FugaziBAGSDelListSearch", panel, "InputBoxTemplate")
    delListSearch:SetSize(140, 20)
    delListSearch:SetPoint("LEFT", delListLabel, "RIGHT", 12, 0)
    delListSearch:SetAutoFocus(false)
    delListSearch:EnableMouse(true)
    delListSearch:SetFrameLevel(panel:GetFrameLevel() + 10)
    delListSearch:SetScript("OnTextChanged", function(self)
        RefreshDelListPanel()
    end)
    delListSearch:SetScript("OnKeyUp", function(self, key)
        if key == "ENTER" then self:ClearFocus() end
        RefreshDelListPanel()
    end)
    delListSearch:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    panel.refresh = function()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        confirmCb:SetChecked(SV.gridConfirmAutoDel ~= false)
        if clickSoundCb then clickSoundCb:SetChecked(SV.gphClickSound ~= false) end
        if FugaziBAGSDelListSearch then FugaziBAGSDelListSearch:SetText("") end
        RefreshDelListPanel()
    end



    panel.okay = function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
    end

    panel:SetScript("OnShow", function()
        RefreshDelListPanel()
    end)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

--- Builds the Escape → Interface → AddOns → _Fugazi Instance Tracker panel (skin for Ledger / lockouts).
local function CreateInstanceTrackerOptionsPanel()
    if _G.FugaziInstanceTrackerOptionsPanel then return end
    local panel = CreateFrame("Frame", "FugaziInstanceTrackerOptionsPanel", UIParent)
    panel.name = "_Fugazi Instance Tracker"
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end
    panel.refresh = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("_Fugazi Instance Tracker")

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    sub:SetText("Skin for lockouts and ledger windows:")

    local dropdown = CreateFrame("Frame", "FugaziInstanceTrackerOptionsSkinDropdown", panel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -8)
    dropdown:SetScale(1)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dropdown, 180) end

    local function FitSkinMenu_Initialize(_, level)
        local list = {
            { value = "original",    text = "Original" },
            { value = "elvui",       text = "Elvui (Ebonhold)" },
            { value = "elvui_real",  text = "ElvUI" },
            { value = "pimp_purple", text = "Pimp Purple" },
        }
        for _, opt in ipairs(list) do
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
            if info then
                info.text = opt.text
                info.value = opt.value
                info.checked = ((_G.InstanceTrackerDB and _G.InstanceTrackerDB.fitSkin) or (_G.FugaziBAGSDB and _G.FugaziBAGSDB.fitSkin) or "original") == opt.value
                info.func = function()
                    local val = opt.value
                    local SV = _G.FugaziBAGSDB
                    if SV then SV.fitSkin = val end
                    if _G.InstanceTrackerDB then _G.InstanceTrackerDB.fitSkin = val end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, val) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, opt.text) end
                    -- Use FIT's apply function so Instance Tracker windows actually change (same as /fit skin).
                    if _G.ApplyFITSkinToAllFrames then
                        _G.ApplyFITSkinToAllFrames(val)
                    end
                end
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end

    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(dropdown, FitSkinMenu_Initialize) end

    panel.refresh = function()
        local val = (_G.InstanceTrackerDB and _G.InstanceTrackerDB.fitSkin) or (_G.FugaziBAGSDB and _G.FugaziBAGSDB.fitSkin) or "original"
        if val ~= "original" and val ~= "elvui" and val ~= "elvui_real" and val ~= "pimp_purple" then
            val = "original"
        end
        local text
        if val == "elvui" then text = "Elvui (Ebonhold)"
        elseif val == "elvui_real" then text = "ElvUI"
        elseif val == "pimp_purple" then text = "Pimp Purple"
        else text = "Original" end
        if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, val) end
        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, text) end
        if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(dropdown, nil, 1) end
    end

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

--- Builds the grid-view options panel (columns, slot size, spacing, scale, force grid, etc.).
local function CreateGridviewOptionsPanel()
    if _G.FugaziGridviewOptionsPanel then return end
    local panel = CreateFrame("Frame", "FugaziGridviewOptionsPanel", UIParent)
    panel.name = "Scale Settings"
    panel.parent = "_FugaziBAGS"
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Scale Settings")

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("Ctrl+Click the sort button in inventory to toggle grid view.")

    local function MakeSlider(sName, label, lo, hi, step, key, default, anchor, xOff, yOff)
        local s = CreateFrame("Slider", sName, panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOff or 0, yOff)
        s:SetWidth(150)
        s:SetMinMaxValues(lo, hi)
        s:SetValueStep(step)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        _G[sName .. "Text"]:SetText(label)
        _G[sName .. "Low"]:SetText(tostring(lo))
        _G[sName .. "High"]:SetText(tostring(hi))
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("TOP", s, "BOTTOM", 0, -2)
        s._valText = val
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            self._valText:SetText(tostring(v))
            local SV = _G.FugaziBAGSDB
            if SV then SV[key] = v end
            local cg = _G.FugaziBAGS_CombatGrid
            if cg and cg.IsShown and cg.IsShown() then
                if cg.LayoutGrid then cg.LayoutGrid() end
                local gf = _G.FugaziBAGS_GPHFrame
                if gf then gf._refreshImmediate = true end
                if RefreshGPHUI then RefreshGPHUI() end
            end
            -- Also refresh bank grid if open
            if cg and cg.IsBankShown and cg.IsBankShown() then
                if cg.BankLayoutGrid then cg.BankLayoutGrid() end
                if RefreshBankUI then RefreshBankUI() end
            end
        end)
        local SV = _G.FugaziBAGSDB
        local init = (SV and SV[key]) or default
        s:SetValue(init)
        s._valText:SetText(tostring(init))
        s._key = key
        s._default = default
        return s
    end

    local function MakeSliderF(sName, label, lo, hi, step, key, default, anchor, xOff, yOff)
        local s = CreateFrame("Slider", sName, panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOff or 0, yOff)
        s:SetWidth(150)
        s:SetMinMaxValues(lo * 100, hi * 100)
        s:SetValueStep(step * 100)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        _G[sName .. "Text"]:SetText(label)
        _G[sName .. "Low"]:SetText(tostring(lo))
        _G[sName .. "High"]:SetText(tostring(hi))
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("TOP", s, "BOTTOM", 0, -2)
        s._valText = val
        -- Lightweight update while dragging: just update the stored value + label.
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5) / 100
            self._valText:SetText(("%.2f"):format(v))
            local SV = _G.FugaziBAGSDB
            if SV then SV[key] = v end
        end)

        -- Heavier work (scale, alpha, grid layout) runs only when the mouse button is released.
        s:SetScript("OnMouseUp", function(self)
            local SV = _G.FugaziBAGSDB
            if not SV then return end
            local v = SV[key] or default

            -- Apply frame scale / alpha immediately when those sliders change.
            local gphFrame = _G.FugaziBAGS_GPHFrame
            if gphFrame and SV then
                if key == "gphFrameScale" then
                    local base = SV.gphScale15 and 1.5 or 1
                    local extra = SV.gphFrameScale or 1
                    local totalScale = base * extra
                    gphFrame:SetScale(totalScale)
                    if gphFrame.gphDestroyBtn then gphFrame.gphDestroyBtn:SetScale(totalScale) end
                    local bf = _G.TestBankFrame
                    if bf and bf:IsShown() then
                        bf:SetScale(bf:GetParent() == gphFrame and 1 or gphFrame:GetScale())
                    end
                elseif key == "gphFrameAlpha" then
                    ApplyFrameAlpha(gphFrame)
                end
            end

            local cg = _G.FugaziBAGS_CombatGrid
            if cg then
                -- For layout-affecting sliders (cols/size/spacing/border), re-layout both grids.
                if key == "gridCols" or key == "gridSlotSize" or key == "gridSpacing" or key == "gridBorderSize" then
                    if cg.IsShown and cg.IsShown() then
                        if cg.LayoutGrid then cg.LayoutGrid() end
                        if RefreshGPHUI then RefreshGPHUI() end
                    end
                    if cg.IsBankShown and cg.IsBankShown() then
                        if cg.BankLayoutGrid then cg.BankLayoutGrid() end
                        if RefreshBankUI then RefreshBankUI() end
                    end
                end

                -- For purely visual sliders (glow, protected desat, protected key alpha), just refresh slot visuals.
                if key == "gridGlowAlpha" or key == "gridProtDesat" or key == "gridProtectedKeyAlpha" then
                    if cg.IsShown and cg.IsShown() and cg.RefreshSlots then cg.RefreshSlots() end
                    if cg.IsBankShown and cg.IsBankShown() and cg.BankRefreshSlots then cg.BankRefreshSlots() end
                end
            end
        end)
        local SV = _G.FugaziBAGSDB
        local init = (SV and SV[key]) or default
        s:SetValue(init * 100)
        s._valText:SetText(("%.2f"):format(init))
        s._key = key
        s._default = default
        return s
    end

    -- Two-column slider layout for better spacing.
    local colGap = 200
    local rowGap = -26

    local s1 = MakeSlider("FugaziGridCols", "Slots per Row", 6, 16, 1, "gridCols", 10, desc, 0, -30)
    local s2 = MakeSlider("FugaziGridSlotSize", "Slot Size", 20, 45, 1, "gridSlotSize", 30, desc, colGap, -30)

    local s3 = MakeSlider("FugaziGridSpacing", "Slot Spacing", 1, 10, 1, "gridSpacing", 4, s1, 0, rowGap)
    -- Border Thickness: only 0,1,2 (actual 2,3,4px); 0 and 1px are buggy with 9-slice so removed.
    local s4 = CreateFrame("Slider", "FugaziGridBorderSize", panel, "OptionsSliderTemplate")
    s4:SetPoint("TOPLEFT", s2, "BOTTOMLEFT", 0, rowGap)
    s4:SetWidth(150)
    s4:SetMinMaxValues(0, 2)
    s4:SetValueStep(1)
    if s4.SetObeyStepOnDrag then s4:SetObeyStepOnDrag(true) end
    _G["FugaziGridBorderSizeText"]:SetText("Border Thickness")
    _G["FugaziGridBorderSizeLow"]:SetText("0")
    _G["FugaziGridBorderSizeHigh"]:SetText("2")
    local s4val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s4val:SetPoint("TOP", s4, "BOTTOM", 0, -2)
    s4._valText = s4val
    s4:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gridBorderSize = v + 2 end
        local cg = _G.FugaziBAGS_CombatGrid
        if cg and cg.IsShown and cg.IsShown() then
            if cg.LayoutGrid then cg.LayoutGrid() end
            local gf = _G.FugaziBAGS_GPHFrame
            if gf then gf._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
        end
        if cg and cg.IsBankShown and cg.IsBankShown() then
            if cg.BankLayoutGrid then cg.BankLayoutGrid() end
            if RefreshBankUI then RefreshBankUI() end
        end
    end)

    ------------------------------------------------------------------
    -- Instructions button: opens a small help window with shortcuts
    ------------------------------------------------------------------
    local instrBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    instrBtn:SetSize(140, 22)
    instrBtn:SetPoint("TOPLEFT", copyLabel, "BOTTOMLEFT", 0, -60)
    instrBtn:SetText("Open Instructions")

    -- Lazy-create instructions frame on first use
    local function EnsureInstructionsFrame()
        if _G.FugaziBAGSInstructionsFrame then return _G.FugaziBAGSInstructionsFrame end

        local f = CreateFrame("Frame", "FugaziBAGSInstructionsFrame", UIParent, "BackdropTemplate")
        f:SetSize(520, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            f:SetBackdropColor(0, 0, 0, 0.85)
        end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetText("_FugaziBAGS Instructions")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)

        local scrollFrame = CreateFrame("ScrollFrame", "FugaziBAGSInstructionsScroll", f, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -40)
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 16)

        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetSize(1, 1)
        scrollFrame:SetScrollChild(content)

        local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", 0, 0)
        text:SetWidth(460)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")

        text:SetText(table.concat({
            "Bags and frames:",
            " - B key: Open/close FugaziBAGS instead of Blizzard bags.",
            " - Ctrl+Click sort button: Toggle list / grid view.",
            " - Frame opacity slider: Fade frame chrome more than item icons.",
            "",
            "Item protection:",
            " - Alt+Left-Click item (list or grid): Toggle Protected.",
            "   Protected items are skipped by: autosell, mass-mail, mass-disenchant, and auto-destroy.",
            " - Protected items show a key overlay and special rarity glow.",
            "",
            "Auto-delete (destroy list):",
            " - Ctrl+Right-Click item: Toggle that item on the auto-destroy list.",
            " - Auto-destroy only runs when you trigger it from the menu.",
            " - The 'Confirm Auto Delete' option controls whether you see a popup first.",
            "",
            "Rarity buttons:",
            " - Click: Filter items by that quality.",
            " - Alt+Click: Protect all items of that quality for this character.",
            "   Protected rarities pulse softly so you recognise them.",
            "",
            "GPH timer:",
            " - Start timer button: Begin a gold-per-hour session.",
            " - While running, the top bar shows: Gold earned, Timer, and GPH.",
            " - Session items and value ignore soulbound + 'previously worn' gear.",
            "",
            "Previously worn gear:",
            " - Items you wore earlier in this character's life are remembered.",
            " - Tooltips show 'Previously worn gear' in green and treat them as protected by default.",
        }, "\n"))

        -- Resize content to fit text height
        local h = text:GetStringHeight() or 0
        content:SetHeight(h)

        f:Hide()
        return f
    end

    instrBtn:SetScript("OnClick", function()
        local f = EnsureInstructionsFrame()
        if f:IsShown() then
            f:Hide()
        else
            f:Show()
        end
    end)
    local SV4 = _G.FugaziBAGSDB
    local init4 = (SV4 and SV4.gridBorderSize) or 2
    if init4 < 2 then init4 = 2 end
    if init4 > 4 then init4 = 4 end
    s4:SetValue(init4 - 2)
    s4._valText:SetText(tostring(init4 - 2))

    local s5 = MakeSliderF("FugaziGridGlowAlpha", "Glow Intensity", 0.0, 1.0, 0.05, "gridGlowAlpha", 0.35, s3, 0, rowGap)
    local s6 = MakeSliderF("FugaziGridProtDesat", "Protected Desaturation", 0.0, 1.0, 0.05, "gridProtDesat", 0.80, s4, 0, rowGap)
    local s6b = MakeSliderF("FugaziGridProtectedKeyAlpha", "Protected overlay visibility (non-vendor)", 0.10, 0.50, 0.05, "gridProtectedKeyAlpha", 0.20, s6, 0, rowGap)

    local s7 = MakeSliderF("FugaziGridFrameScale", "Frame Scale", 0.75, 1.25, 0.05, "gphFrameScale", 1.00, s5, 0, rowGap)
    local s8 = MakeSliderF("FugaziGridFrameAlpha", "Frame Opacity", 0.10, 1.00, 0.05, "gphFrameAlpha", 1.00, s6b, 0, rowGap)

    -- Force grid mode checkbox
    local cb = CreateFrame("CheckButton", "FugaziGridForceCheck", panel, "OptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", s8, "BOTTOMLEFT", 0, -8)
    _G["FugaziGridForceCheckText"]:SetText("Force Inventory Grid View (always on)")
    local SV0 = _G.FugaziBAGSDB
    cb:SetChecked(GetPerChar("gphForceGridView", false))
    cb:SetScript("OnClick", function(self)
        local val = self:GetChecked() == 1 or self:GetChecked() == true
        SetPerChar("gphForceGridView", val)
        local cg = _G.FugaziBAGS_CombatGrid
        local gf = _G.FugaziBAGS_GPHFrame
        if not gf then return end
        if val then
            if cg and cg.ShowInFrame then cg.ShowInFrame(gf) end
            gf.gphGridMode = true
        else
            if cg and cg.HideInFrame then cg.HideInFrame(gf) end
            gf.gphGridMode = GetPerChar("gphGridMode", false)
        end
    end)
    
    local cbBank = CreateFrame("CheckButton", "FugaziGridForceBankCheck", panel, "OptionsCheckButtonTemplate")
    cbBank:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -5)
    _G["FugaziGridForceBankCheckText"]:SetText("Force Bank Grid View (always on)")
    cbBank:SetChecked(GetPerChar("gphBankForceGridView", false))
    cbBank:SetScript("OnClick", function(self)
        local val = self:GetChecked() == 1 or self:GetChecked() == true
        SetPerChar("gphBankForceGridView", val)
        local cg = _G.FugaziBAGS_CombatGrid
        local bf = _G.TestBankFrame
        if not bf then return end
        if val then
            if cg and cg.ShowInBankFrame then cg.ShowInBankFrame(bf) end
            bf.gphGridMode = true
        else
            if cg and cg.HideInBankFrame then cg.HideInBankFrame(bf) end
            bf.gphGridMode = GetPerChar("gphBankGridMode", false)
        end
    end)

    -- Category header font and skin options moved to Escape → Interface → _FugaziBAGS → Skins.

    panel.refresh = function()
        local SV = _G.FugaziBAGSDB or {}
        s1:SetValue(SV.gridCols or 10)
        s2:SetValue(SV.gridSlotSize or 30)
        s3:SetValue(SV.gridSpacing or 4)
        local bv = (SV.gridBorderSize or 2)
        if bv < 2 then bv = 2 elseif bv > 4 then bv = 4 end
        s4:SetValue(bv - 2)
        s4._valText:SetText(tostring(bv - 2))
        s5:SetValue((SV.gridGlowAlpha or 0.35) * 100)
        s6:SetValue((SV.gridProtDesat or 0.80) * 100)
        if s6b then s6b:SetValue((SV.gridProtectedKeyAlpha or 0.20) * 100) end
        s7:SetValue((SV.gphFrameScale or 1.00) * 100)
        s8:SetValue((SV.gphFrameAlpha or 1.00) * 100)
        cb:SetChecked(GetPerChar("gphForceGridView", false))
        cbBank:SetChecked(GetPerChar("gphBankForceGridView", false))
    end

    if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel)     end
end

--- Skins submenu: window skin, category header font, and color overrides (saved on top of current skin).
--- Content is in a scrollable child so more options (e.g. Item details) can be added without crowding.
local function CreateSkinsPanel()
    if _G.FugaziBAGSSkinsPanel then return end
    local panel = CreateFrame("Frame", "FugaziBAGSSkinsPanel", UIParent)
    panel.name = "Skins"
    panel.parent = "_FugaziBAGS"
    panel.okay = function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
    end
    panel.cancel = function() end
    panel.default = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Skins")

    -- Scroll frame so we can add more options; scroll child holds all content
    local scroll = CreateFrame("ScrollFrame", "FugaziBAGSSkinsScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 8)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetWidth(400)
    scrollChild:SetHeight(750)
    scrollChild:SetScale(0.95)
    scroll:SetScrollChild(scrollChild)
    panel:SetScript("OnShow", function()
        local sh = scroll:GetHeight()
        if sh and sh > 0 and scrollChild:GetHeight() <= sh then
            scrollChild:SetHeight(sh + 500)
        end
    end)

    local LEFT_X, ROW, GAP = 16, 26, 32
    local curY = 10

    local ITEM_DETAILS_FONTS = {
        { value = "Fonts\\ARIALN.TTF",   text = "ARIALN" },
        { value = "Fonts\\FRIZQT__.TTF", text = "FRIZQT" },
        { value = "Fonts\\MORPHEUS.TTF", text = "MORPHEUS" },
        { value = "Fonts\\skurri.ttf",   text = "Skurri" },
        -- Custom fonts shipped with the addon (media/Fonts)
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\TinyIslanders.ttf",        text = "Tiny Islanders" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\OldSchoolAdventures.ttf",  text = "Old School Adventures" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\BreatheFire.ttf",          text = "Breathe Fire" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\EightBitDragon.ttf",       text = "Eight Bit Dragon" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\AncientModernTales.ttf",   text = "Ancient Modern Tales" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\Dragnel.ttf",              text = "Dragnel" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\TheWildBreathOfZelda.ttf", text = "Wild Breath of Zelda" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\ModernSignature.ttf",      text = "Modern Signature" },
    }
    local RARITY_OPTIONS = {
        { q = 0, label = "|cff9d9d9dPoor|r" },
        { q = 1, label = "|cffffffffCommon|r" },
        { q = 2, label = "|cff1eff00Uncommon|r" },
        { q = 3, label = "|cff0070ddRare|r" },
        { q = 4, label = "|cffa335eeEpic|r" },
        { q = 5, label = "|cffff8000Legendary|r" },
    }

    -- === LEFT COLUMN: Skin & Headers ===
    local skinLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    skinLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    skinLabel:SetText("Window skin:")

    local skinDropdown = CreateFrame("Frame", "FugaziBAGSSkinsSkinDropdown", scrollChild, "UIDropDownMenuTemplate")
    skinDropdown:SetPoint("TOPLEFT", skinLabel, "BOTTOMLEFT", -16, -4)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(skinDropdown, 180) end
    local function SkinMenu_Init(_, level)
        local list = {
            { value = "original",    text = "Original" },
            { value = "elvui",       text = "Elvui (Ebonhold)" },
            { value = "elvui_real",  text = "ElvUI" },
            { value = "pimp_purple", text = "Pimp Purple" },
        }
        for _, opt in ipairs(list) do
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
            if info then
                info.text = opt.text
                info.value = opt.value
                info.checked = ((_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original") == opt.value
                info.func = function()
                    local SV = _G.FugaziBAGSDB
                    if SV then
                        SV.gphSkin = opt.value
                        SV.gphCategoryHeaderFontCustom = false
                        SV.gphItemDetailsCustom = false
                        SV.gphSkinOverrides = {}
                    end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(skinDropdown, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(skinDropdown, opt.text) end
                    if _G.ApplyTestSkin then _G.ApplyTestSkin() end
                    if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
                    -- Also refresh live frames so rarity buttons and other visuals immediately match the new skin
                    if RefreshGPHUI then RefreshGPHUI() end
                    if RefreshBankUI then RefreshBankUI() end
                end
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end
    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(skinDropdown, SkinMenu_Init) end
    curY = curY + 45

    local fontLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fontLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    fontLabel:SetText("Header & Category Appearance:")

    local cbCatFont = CreateFrame("CheckButton", "FugaziBAGSSkinsCategoryFontCheck", scrollChild, "OptionsCheckButtonTemplate")
    cbCatFont:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -4)
    _G["FugaziBAGSSkinsCategoryFontCheckText"]:SetText("Enable Header Customization")
    cbCatFont:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphCategoryHeaderFontCustom = (self:GetChecked() == 1 or self:GetChecked() == true) end
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 32

    local CAT_HEADER_FONTS = {
        { value = "Fonts\\ARIALN.TTF",   text = "ARIALN" },
        { value = "Fonts\\FRIZQT__.TTF", text = "FRIZQT" },
        { value = "Fonts\\MORPHEUS.TTF", text = "MORPHEUS" },
        { value = "Fonts\\skurri.ttf",   text = "Skurri" },
        -- Custom fonts shipped with the addon (media/Fonts)
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\TinyIslanders.ttf",        text = "Tiny Islanders" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\OldSchoolAdventures.ttf",  text = "Old School Adventures" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\BreatheFire.ttf",          text = "Breathe Fire" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\EightBitDragon.ttf",       text = "Eight Bit Dragon" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\AncientModernTales.ttf",   text = "Ancient Modern Tales" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\Dragnel.ttf",              text = "Dragnel" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\TheWildBreathOfZelda.ttf", text = "Wild Breath of Zelda" },
        { value = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\ModernSignature.ttf",      text = "Modern Signature" },
    }
    local catFontDropdown = CreateFrame("Frame", "FugaziBAGSSkinsCategoryFontDropdown", scrollChild, "UIDropDownMenuTemplate")
    catFontDropdown:SetPoint("TOPLEFT", cbCatFont, "BOTTOMLEFT", 16, -4)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(catFontDropdown, 160) end
    local function CatFontMenu_Init(frame, level)
        for _, opt in ipairs(CAT_HEADER_FONTS) do
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
            if info then
                info.text = opt.text
                info.func = function()
                    local SV = _G.FugaziBAGSDB
                    if SV then SV.gphCategoryHeaderFont = opt.value end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(frame, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(frame, opt.text) end
                    if _G.ApplyTestSkin then _G.ApplyTestSkin() end
                    if RefreshGPHUI then RefreshGPHUI() end
                    if RefreshBankUI then RefreshBankUI() end
                end
                info.checked = (frame.selectedValue == opt.value)
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end
    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(catFontDropdown, CatFontMenu_Init) end
    curY = curY + 40

    local catFontSizeSlider = CreateFrame("Slider", "FugaziBAGSSkinsCategoryFontSize", scrollChild, "OptionsSliderTemplate")
    catFontSizeSlider:SetPoint("TOPLEFT", catFontDropdown, "BOTTOMLEFT", 10, -12)
    catFontSizeSlider:SetWidth(180)
    catFontSizeSlider:SetMinMaxValues(6, 18)
    catFontSizeSlider:SetValueStep(1)
    if catFontSizeSlider.SetObeyStepOnDrag then catFontSizeSlider:SetObeyStepOnDrag(true) end
    _G["FugaziBAGSSkinsCategoryFontSizeText"]:SetText("Header Font Size")
    _G["FugaziBAGSSkinsCategoryFontSizeLow"]:SetText("6")
    _G["FugaziBAGSSkinsCategoryFontSizeHigh"]:SetText("18")
    local catSizeVal = catFontSizeSlider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    catSizeVal:SetPoint("TOP", catFontSizeSlider, "BOTTOM", 0, -2)
    catFontSizeSlider._valText = catSizeVal
    -- Lightweight while dragging: just update value text + SavedVariable.
    catFontSizeSlider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphCategoryHeaderFontSize = v end
    end)
    -- Heavier work (reskin + full refresh) only when mouse is released.
    catFontSizeSlider:SetScript("OnMouseUp", function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 60 + GAP

    local colorLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    colorLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    colorLabel:SetText("Custom Colors (Requires Customize enabled):")

    local COLOR_OVERRIDES = {
        { key = "headerTextColor",   label = "Header & category text" },
        { key = "mainBg",            label = "Frame background" },
    }
    local function GetSkinDefaultColor(skinName, key)
        local sk = _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SKIN and _G.__FugaziBAGS_Skins.SKIN[skinName or "original"]
        if sk and sk[key] then return unpack(sk[key]) end
        if key == "mainBg" then return 0.08, 0.08, 0.12, 0.92 end
        if key == "headerTextColor" and sk and sk.titleTextColor then return unpack(sk.titleTextColor) end
        return 1, 0.85, 0.4, 1
    end
    local function OpenColorPicker(overrideKey, labelText)
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        if not SV.gphSkinOverrides then SV.gphSkinOverrides = {} end
        local cur = SV.gphSkinOverrides[overrideKey]
        local skinName = SV.gphSkin or "original"
        local r, g, b, a
        if cur and #cur >= 4 then
            r, g, b, a = cur[1], cur[2], cur[3], cur[4]
            -- Sanity: if a past bug stored a nearly-zero alpha for the frame background, restore it.
            if overrideKey == "mainBg" and (not a or a < 0.2) then
                local dr, dg, db, da = GetSkinDefaultColor(skinName, overrideKey)
                a = da or 1
                SV.gphSkinOverrides[overrideKey][4] = a
            end
        else
            r, g, b, a = GetSkinDefaultColor(skinName, overrideKey)
            a = a or 1
        end
        if not _G.ColorPickerFrame then return end
        _G.ColorPickerFrame.previousValues = { r, g, b, a }
        _G.ColorPickerFrame.func = function()
            local nr, ng, nb = _G.ColorPickerFrame:GetColorRGB()
            local SV2 = _G.FugaziBAGSDB
            if not SV2.gphSkinOverrides then SV2.gphSkinOverrides = {} end
            local skinNameNow = SV2.gphSkin or "original"
            -- For frame background we never let the picker control alpha; that is owned by the Frame Opacity slider.
            local na
            if overrideKey == "mainBg" then
                local dr, dg, db, da = GetSkinDefaultColor(skinNameNow, overrideKey)
                na = da or 1
            else
                na = 1
            end
            SV2.gphSkinOverrides[overrideKey] = { nr, ng, nb, na }
            -- Keep the live skin definition in sync so ApplySkin uses the same base color.
            local Skins = _G.__FugaziBAGS_Skins
            if Skins and Skins.SKIN and Skins.SKIN[skinNameNow] and Skins.SKIN[skinNameNow][overrideKey] then
                Skins.SKIN[skinNameNow][overrideKey] = { nr, ng, nb, na }
            end
            if _G.ApplyTestSkin then _G.ApplyTestSkin() end
            if RefreshGPHUI then RefreshGPHUI() end
            if RefreshBankUI then RefreshBankUI() end
            if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
        end
        _G.ColorPickerFrame:SetColorRGB(r, g, b)
        -- Do not expose opacity here; frame transparency is controlled by the Frame Opacity slider, not this picker.
        _G.ColorPickerFrame.hasOpacity = false
        _G.ColorPickerFrame.opacity = a
        if _G.OpacitySliderFrame then
            if _G.OpacitySliderFrame.SetValue then _G.OpacitySliderFrame:SetValue(a) end
            _G.OpacitySliderFrame:Hide()
        end
        if _G.ColorPickerFrame.SetOpacity then _G.ColorPickerFrame:SetOpacity(a) end
        _G.ColorPickerFrame:Show()
    end

    local function OpenRarityColorPicker()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        -- Dropdown is created later in this function; fetch it by its global name so this works even though
        -- the local 'raritySelectDropdown' isn't in scope yet when we define this helper.
        local dd = _G.FugaziBAGSSkinsRaritySelectDropdown
        local rq = (dd and dd.selectedQuality) or 1
        if not SV.gphSkinOverrides then SV.gphSkinOverrides = {} end
        if not SV.gphSkinOverrides.itemDetailsRarityColors then SV.gphSkinOverrides.itemDetailsRarityColors = {} end
        local curr = SV.gphSkinOverrides.itemDetailsRarityColors[rq]
        if not curr then
            local def = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[rq]) or { r = 1, g = 1, b = 1 }
            curr = { def.r or 1, def.g or 1, def.b or 1 }
        end
        if not _G.ColorPickerFrame then return end
        _G.ColorPickerFrame.func = function()
            local nr, ng, nb = _G.ColorPickerFrame:GetColorRGB()
            local SV2 = _G.FugaziBAGSDB
            if not SV2.gphSkinOverrides then SV2.gphSkinOverrides = {} end
            if not SV2.gphSkinOverrides.itemDetailsRarityColors then SV2.gphSkinOverrides.itemDetailsRarityColors = {} end
            SV2.gphSkinOverrides.itemDetailsRarityColors[rq] = { nr, ng, nb }
            if RefreshGPHUI then RefreshGPHUI() end
            if RefreshBankUI then RefreshBankUI() end
            if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
        end
        _G.ColorPickerFrame:SetColorRGB(unpack(curr))
        _G.ColorPickerFrame.hasOpacity = false
        _G.ColorPickerFrame:Show()
    end

    local colorBtns = {}
    for i, row in ipairs(COLOR_OVERRIDES) do
        local btn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
        btn:SetSize(180, 22)
        btn:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -6 - ((i-1)*28))
        btn:SetText(row.label)
        local swatch = btn:CreateTexture(nil, "OVERLAY")
        swatch:SetSize(16, 16)
        swatch:SetPoint("LEFT", btn, "RIGHT", 6, 0)
        swatch:SetTexture(1, 1, 1, 1)
        btn._swatch = swatch
        btn._key = row.key
        btn:SetScript("OnClick", function(self) OpenColorPicker(self._key, row.label) end)
        colorBtns[row.key] = btn
        curY = curY + 28
    end
    curY = curY + 10 + GAP

    -- === Item Details (Now in the same vertical column) ===
    local itemDetailsLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemDetailsLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    itemDetailsLabel:SetText("Inventory List Row Details:")

    local cbItemDetails = CreateFrame("CheckButton", "FugaziBAGSSkinsItemDetailsCheck", scrollChild, "OptionsCheckButtonTemplate")
    cbItemDetails:SetPoint("TOPLEFT", itemDetailsLabel, "BOTTOMLEFT", 0, -4)
    _G["FugaziBAGSSkinsItemDetailsCheckText"]:SetText("Enable Row Formatting")
    cbItemDetails:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphItemDetailsCustom = (self:GetChecked() == 1 or self:GetChecked() == true) end
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 32

    local cbHideIcons = CreateFrame("CheckButton", "FugaziBAGSSkinsHideIconsCheck", scrollChild, "OptionsCheckButtonTemplate")
    cbHideIcons:SetPoint("TOPLEFT", cbItemDetails, "BOTTOMLEFT", 0, -4)
    _G["FugaziBAGSSkinsHideIconsCheckText"]:SetText("Hide Category Icons")
    cbHideIcons:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphHideIconsInList = (self:GetChecked() == 1 or self:GetChecked() == true) end
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 32

    local itemDetailsFontDropdown = CreateFrame("Frame", "FugaziBAGSSkinsItemDetailsFontDropdown", scrollChild, "UIDropDownMenuTemplate")
    itemDetailsFontDropdown:SetPoint("TOPLEFT", cbHideIcons, "BOTTOMLEFT", 16, -4)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(itemDetailsFontDropdown, 160) end
    local function ItemDetailsFontMenu_Init(frame, level)
        for _, opt in ipairs(ITEM_DETAILS_FONTS) do
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
            if info then
                info.text = opt.text
                info.func = function()
                    local SV = _G.FugaziBAGSDB
                    if SV then SV.gphItemDetailsFont = opt.value end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(frame, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(frame, opt.text) end
                    if RefreshGPHUI then RefreshGPHUI() end
                    if RefreshBankUI then RefreshBankUI() end
                end
                info.checked = (frame.selectedValue == opt.value)
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end
    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(itemDetailsFontDropdown, ItemDetailsFontMenu_Init) end
    curY = curY + 40

    local itemDetailsFontSizeSlider = CreateFrame("Slider", "FugaziBAGSSkinsItemDetailsFontSize", scrollChild, "OptionsSliderTemplate")
    itemDetailsFontSizeSlider:SetPoint("TOPLEFT", itemDetailsFontDropdown, "BOTTOMLEFT", 10, -12)
    itemDetailsFontSizeSlider:SetWidth(180)
    itemDetailsFontSizeSlider:SetMinMaxValues(8, 16)
    itemDetailsFontSizeSlider:SetValueStep(1)
    if itemDetailsFontSizeSlider.SetObeyStepOnDrag then itemDetailsFontSizeSlider:SetObeyStepOnDrag(true) end
    _G["FugaziBAGSSkinsItemDetailsFontSizeText"]:SetText("Row Font Size")
    _G["FugaziBAGSSkinsItemDetailsFontSizeLow"]:SetText("8")
    _G["FugaziBAGSSkinsItemDetailsFontSizeHigh"]:SetText("16")
    local itemDetailsSizeVal = itemDetailsFontSizeSlider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemDetailsSizeVal:SetPoint("TOP", itemDetailsFontSizeSlider, "BOTTOM", 0, -2)
    itemDetailsFontSizeSlider._valText = itemDetailsSizeVal
    -- While dragging: just update value + label.
    itemDetailsFontSizeSlider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphItemDetailsFontSize = v end
    end)
    -- On mouse release: apply to live frames once.
    itemDetailsFontSizeSlider:SetScript("OnMouseUp", function(self)
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 60

    local itemDetailsIconSizeSlider = CreateFrame("Slider", "FugaziBAGSSkinsItemDetailsIconSize", scrollChild, "OptionsSliderTemplate")
    itemDetailsIconSizeSlider:SetPoint("TOPLEFT", itemDetailsFontSizeSlider, "BOTTOMLEFT", 0, -32)
    itemDetailsIconSizeSlider:SetWidth(180)
    itemDetailsIconSizeSlider:SetMinMaxValues(12, 28)
    itemDetailsIconSizeSlider:SetValueStep(1)
    if itemDetailsIconSizeSlider.SetObeyStepOnDrag then itemDetailsIconSizeSlider:SetObeyStepOnDrag(true) end
    _G["FugaziBAGSSkinsItemDetailsIconSizeText"]:SetText("Row Icon Size")
    _G["FugaziBAGSSkinsItemDetailsIconSizeLow"]:SetText("12")
    _G["FugaziBAGSSkinsItemDetailsIconSizeHigh"]:SetText("28")
    local itemDetailsIconSizeVal = itemDetailsIconSizeSlider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemDetailsIconSizeVal:SetPoint("TOP", itemDetailsIconSizeSlider, "BOTTOM", 0, -2)
    itemDetailsIconSizeSlider._valText = itemDetailsIconSizeVal
    itemDetailsIconSizeSlider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphItemDetailsIconSize = v end
    end)
    itemDetailsIconSizeSlider:SetScript("OnMouseUp", function(self)
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 60

    local itemDetailsAlphaSlider = CreateFrame("Slider", "FugaziBAGSSkinsItemDetailsAlpha", scrollChild, "OptionsSliderTemplate")
    itemDetailsAlphaSlider:SetPoint("TOPLEFT", itemDetailsIconSizeSlider, "BOTTOMLEFT", 0, -32)
    itemDetailsAlphaSlider:SetWidth(180)
    -- 0 = fully transparent rows, 1 = fully opaque
    itemDetailsAlphaSlider:SetMinMaxValues(0.0, 1.0)
    itemDetailsAlphaSlider:SetValueStep(0.05)
    if itemDetailsAlphaSlider.SetObeyStepOnDrag then itemDetailsAlphaSlider:SetObeyStepOnDrag(true) end
    _G["FugaziBAGSSkinsItemDetailsAlphaText"]:SetText("Row Opacity")
    _G["FugaziBAGSSkinsItemDetailsAlphaLow"]:SetText("0%")
    _G["FugaziBAGSSkinsItemDetailsAlphaHigh"]:SetText("100%")
    local itemDetailsAlphaVal = itemDetailsAlphaSlider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemDetailsAlphaVal:SetPoint("TOP", itemDetailsAlphaSlider, "BOTTOM", 0, -2)
    itemDetailsAlphaSlider._valText = itemDetailsAlphaVal
    itemDetailsAlphaSlider:SetScript("OnValueChanged", function(self, v)
        -- Clamp and store 0.0–1.0, display as percentage
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphItemDetailsAlpha = v end
        self._valText:SetText(string.format("%.0f%%", v * 100))
    end)
    itemDetailsAlphaSlider:SetScript("OnMouseUp", function(self)
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
    end)
    curY = curY + 60 + GAP

    local rarityColorLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rarityColorLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    rarityColorLabel:SetText("Custom Row Colors by Quality:")

    local raritySelectDropdown = CreateFrame("Frame", "FugaziBAGSSkinsRaritySelectDropdown", scrollChild, "UIDropDownMenuTemplate")
    raritySelectDropdown:SetPoint("TOPLEFT", rarityColorLabel, "BOTTOMLEFT", -16, -4)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(raritySelectDropdown, 160) end
    raritySelectDropdown.selectedQuality = 1
    local function RaritySelectMenu_Init(frame, level)
        for _, opt in ipairs(RARITY_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo()
            if info then
                info.text = opt.label
                info.func = function()
                    frame.selectedQuality = opt.q
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(frame, opt.q) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(frame, opt.label) end
                    if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(frame, nil, 1) end
                    if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
                end
                info.checked = (frame.selectedQuality == opt.q)
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end
    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(raritySelectDropdown, RaritySelectMenu_Init) end

    local rarityColorBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    rarityColorBtn:SetSize(180, 22)
    rarityColorBtn:SetPoint("TOPLEFT", raritySelectDropdown, "BOTTOMLEFT", 16, -6)
    rarityColorBtn:SetText("Set Color for Quality")
    local rs0 = rarityColorBtn:CreateTexture(nil, "OVERLAY")
    rs0:SetSize(16, 16)
    rs0:SetPoint("LEFT", rarityColorBtn, "RIGHT", 6, 0)
    rs0:SetTexture(1, 1, 1, 1)
    rarityColorBtn._swatch = rs0
    rarityColorBtn:SetScript("OnClick", OpenRarityColorPicker)
    curY = curY + 80

    local iconColorBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    iconColorBtn:SetSize(180, 22)
    iconColorBtn:SetPoint("TOPLEFT", rarityColorBtn, "BOTTOMLEFT", 0, -12)
    iconColorBtn:SetText("Row Icon Global Tint")
    local is0 = iconColorBtn:CreateTexture(nil, "OVERLAY")
    is0:SetSize(16, 16)
    is0:SetPoint("LEFT", iconColorBtn, "RIGHT", 6, 0)
    is0:SetTexture(1, 1, 1, 1)
    iconColorBtn._swatch = is0
    curY = curY + 60
    scrollChild:SetHeight(curY + 100)
    is0:SetTexture(1, 1, 1, 1)
    iconColorBtn._swatch = is0
    iconColorBtn:SetScript("OnClick", function()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        if not SV.gphSkinOverrides then SV.gphSkinOverrides = {} end
        local curr = SV.gphSkinOverrides.itemDetailsIconColor or {1, 1, 1}
        if not _G.ColorPickerFrame then return end
        _G.ColorPickerFrame.func = function()
            local nr, ng, nb = _G.ColorPickerFrame:GetColorRGB()
            local SV2 = _G.FugaziBAGSDB
            if not SV2.gphSkinOverrides then SV2.gphSkinOverrides = {} end
            SV2.gphSkinOverrides.itemDetailsIconColor = { nr, ng, nb }
            if RefreshGPHUI then RefreshGPHUI() end
            if RefreshBankUI then RefreshBankUI() end
            if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
        end
        _G.ColorPickerFrame:SetColorRGB(unpack(curr))
        _G.ColorPickerFrame.hasOpacity = false
        _G.ColorPickerFrame:Show()
    end)

    panel.refresh = function()
        local SV = _G.FugaziBAGSDB or {}
        local sk = SV.gphSkin or "original"
        local skText = (sk == "elvui" and "Elvui (Ebonhold)") or (sk == "elvui_real" and "ElvUI") or (sk == "pimp_purple" and "Pimp Purple") or "Original"
        UIDropDownMenu_SetSelectedValue(skinDropdown, sk)
        UIDropDownMenu_SetText(skinDropdown, skText)

        cbCatFont:SetChecked(SV.gphCategoryHeaderFontCustom)
        local hFont = SV.gphCategoryHeaderFont or "Fonts\\ARIALN.TTF"
        UIDropDownMenu_SetSelectedValue(catFontDropdown, hFont)
        for _, o in ipairs(CAT_HEADER_FONTS) do if o.value == hFont then UIDropDownMenu_SetText(catFontDropdown, o.text) break end end
        catFontSizeSlider:SetValue(SV.gphCategoryHeaderFontSize or 11)

        -- Header/Bg Swatches
        for key, btn in pairs(colorBtns) do
            local r, g, b = GetSkinDefaultColor(sk, key)
            local cur = SV.gphSkinOverrides and SV.gphSkinOverrides[key]
            if cur then r, g, b = unpack(cur) end
            btn._swatch:SetVertexColor(r, g, b)
        end

        cbItemDetails:SetChecked(SV.gphItemDetailsCustom)
        cbHideIcons:SetChecked(SV.gphHideIconsInList)
        local iFont = SV.gphItemDetailsFont or "Fonts\\FRIZQT__.TTF"
        UIDropDownMenu_SetSelectedValue(itemDetailsFontDropdown, iFont)
        for _, o in ipairs(ITEM_DETAILS_FONTS) do if o.value == iFont then UIDropDownMenu_SetText(itemDetailsFontDropdown, o.text) break end end
        itemDetailsFontSizeSlider:SetValue(SV.gphItemDetailsFontSize or 11)
        itemDetailsIconSizeSlider:SetValue(SV.gphItemDetailsIconSize or 16)
        itemDetailsAlphaSlider:SetValue(SV.gphItemDetailsAlpha or 1.0)

        -- Rarity swatch
        local rq = raritySelectDropdown.selectedQuality or 1
        UIDropDownMenu_SetSelectedValue(raritySelectDropdown, rq)
        for _, o in ipairs(RARITY_OPTIONS) do if o.q == rq then UIDropDownMenu_SetText(raritySelectDropdown, o.label) break end end
        local rCol = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsRarityColors and SV.gphSkinOverrides.itemDetailsRarityColors[rq]
        if rCol then rarityColorBtn._swatch:SetVertexColor(unpack(rCol))
        else
            local def = Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[rq]
            rarityColorBtn._swatch:SetVertexColor(def and def.r or 1, def and def.g or 1, def and def.b or 1)
        end
        -- Icon tint swatch
        local iCol = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsIconColor or {1, 1, 1}
        iconColorBtn._swatch:SetVertexColor(unpack(iCol))
    end

    if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel) end
end

--- Builds the Instructions panel under _FugaziBAGS. Shows concise shortcuts / behaviour.
local function CreateInstructionsPanel()
    if _G.FugaziBAGSInstructionsOptionsPanel then return end

    local panel = CreateFrame("Frame", "FugaziBAGSInstructionsOptionsPanel", UIParent)
    panel.name = "Instructions"
    panel.parent = "_FugaziBAGS"
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end
    panel.refresh = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff40c040_FugaziBAGS Instructions|r")

    local scrollFrame = CreateFrame("ScrollFrame", "FugaziBAGSInstructionsOptionsScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 16)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 0, 0)
    -- Slightly narrower so long lines don't sit under the scrollbar.
    text:SetWidth(380)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetTextColor(1, 1, 1)

    text:SetText(table.concat({
        "|cffffe070Bags and frames:|r",
        " - |cff40c0ffB key|r: Open/close |cff40c0ffFugaziBAGS|r instead of Blizzard bags.",
        " - |cff40c0ffRight-Click the Inventory Header|r to open the |cff40c0ffFugaziBAGS|r menu.",
        " - unless |cff40c0ffForce Gridview|r is enabled, out of combat it switches to |cff40c0fflist view|r and the |cff40c0ffgrid view|r is used in combat.",
        " - The |cffff6060Autodeleted list|r is per character. You can copy it from another toon in the FugaziBAGS options.",
        " - Items can be removed from the |cffff6060autodelete list|r via |cff40c0fflist view| in inventory or the Escape Menu.",
        "",
        "|cffffe070Item protection:|r",
        " - |cff40c0ffAlt+Left-Click|r an item (list or grid): Toggle |cff40c0ffProtected|r status on that item.",
        "   Protected items are skipped by: vendor, autosell, mass-mail, mass-disenchant, and |cffff6060auto-destroy|r.",
        "",
        "|cffffe070Auto-delete (destroy list):|r",
        " - |cffff6060Ctrl+Right-Click|r an item: Toggle that exact item ID on the |cffff6060auto-destroy list|r.",
        " - The |cffff6060'Confirm Auto Delete'|r option decides if you see a warning popup first.",
        "",
        "|cffffe070Mailing:|r",
        " - |cff40c0ffGet All Mail|r: Pulls attachments and gold from your mailbox, stopping when 1 free bag slot remains.",
        " - |cff40c0ffSend All Items|r (Send tab): Sends all unprotected, non-quest items in your bags to the current recipient.",
        "",
        "|cffffe070Rarity buttons (top of the frame):|r",
        " - |cff40c0ffLeft-Click|r: Filter your bags by that item quality.",
        " - |cff40c0ffAlt+Left-Click|r: Protect all items of that quality for this character.",
        "",
        " - You can |cff40c0ffhold Alt|r and drag across the rarity buttons to quickly protect multiple qualities. Manually unprotecting single items in your bags overrides the rarity protection for those items.",
        " - |cff40c0ffCtrl+Left-Click|r a rarity button multiple times: cycle |cffff6060continuous auto-delete mode|r for that quality.",
        " - In continuous mode, all new unprotected items of that quality are automatically |cffff6060deleted|r as they enter your bags.",
        "",
        "|cffffe070GPH timer (Gold per hour):|r",
        " - |cff40c0ff'Start timer' button|r in Inventory Menu: Begin a |cff40c0ffGPH session|r.",
        " - |cffffe050While running|r, the top bar shows: |cffffe050Gold earned, Timer, and GPH|r values.",
        "   |cffffe050GPH|r treats your run as if you vendor all poor (grey) drops and sell all non-soulbound common+ drops at 85% of their auction value. if you vendor them instead, then the vendor value is used instead.",
        " - Soulbound items and '|cff40c0ff'Previously worn gear'|r' are ignored in the GPH value because you cannot realistically tell apart your equipment vs what you would want to sell.",
        "",
        "|cffffe070Previously worn gear:|r",
        " - Items you have worn earlier on this character are remembered.",
        " - Their tooltip shows |cff40c0ff'Previously worn gear'|r and they behave as Protected by default.",
    }, "\n"))

    local h = text:GetStringHeight() or 0
    content:SetHeight(h)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local addonLoaderDone = false
--- Runs once at login: creates all options panels and prints "Press B to open inventory".
local function RunAddonLoader()
    if addonLoaderDone then return end
    addonLoaderDone = true
    CreateOptionsPanel()
    CreateInstanceTrackerOptionsPanel()
    CreateGridviewOptionsPanel()
    CreateSkinsPanel()
    CreateInstructionsPanel()
    -- Sync the local DB upvalue to the correctly loaded global SavedVariable
    DB = _G.FugaziBAGSDB or DB

    -- On first ever load, gently show the Instructions panel once.
    if DB and DB.seenInstructions ~= true then
        DB.seenInstructions = true

        -- Open instructions options panel.
        if InterfaceOptionsFrame_OpenToCategory then
            local instrPanel = _G.FugaziBAGSInstructionsOptionsPanel
            if instrPanel then
                InterfaceOptionsFrame_OpenToCategory(instrPanel)
                InterfaceOptionsFrame_OpenToCategory(instrPanel) -- twice to work around Blizzard quirk
            else
                InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
                InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
            end
        end

    end

    print("|cff00aaff[__FugaziBAGS]|r Loaded. Bag key (B) opens inventory.")

end

--- GPH bag sort (stack consolidate + reorder). Port of ElvUI bag sort logic; player bags or bank.
local GPH_BagSort_Run
do
	local playerBags = {}
	for i = 0, (NUM_BAG_SLOTS or 4) do playerBags[i + 1] = i end
	local bankBags = {}
	if BANK_CONTAINER ~= nil then
		bankBags[#bankBags + 1] = BANK_CONTAINER
		for i = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6) do bankBags[#bankBags + 1] = i end
	end

	local bagIDs, bagStacks, bagMaxStacks, bagQualities = {}, {}, {}, {}
	local moves, moveTracker = {}, {}
	local bagSorted, initialOrder, bagLocked = {}, {}, {}
	local lastItemID, lockStop, lastDestination, lastMove
	local moveRetries = 0
	local WAIT_TIME = 0.05
	local MAX_MOVE_TIME = 1.25
	local itemTypes, itemSubTypes = {}, {}
	local targetItems, targetSlots, sourceUsed = {}, {}, {}

	local function Encode(bag, slot) return (bag * 100) + slot end
	local function Decode(int) return math.floor(int / 100), int % 100 end
	local function EncodeMove(src, tgt) return (src * 10000) + tgt end
	local function DecodeMove(move)
		local s = math.floor(move / 10000)
		local t = move % 10000
		s = (t > 9000) and (s + 1) or s
		t = (t > 9000) and (t - 10000) or t
		return s, t
	end

	local function GetNumSlots(bag)
		if not GetContainerNumSlots then return 0 end
		return GetContainerNumSlots(bag) or 0
	end

	local function UpdateLocation(from, to)
		if (bagIDs[from] == bagIDs[to]) and (bagStacks[to] and bagMaxStacks[to]) and (bagStacks[to] < bagMaxStacks[to]) then
			local stackSize = bagMaxStacks[to]
			if (bagStacks[to] + (bagStacks[from] or 0)) > stackSize then
				bagStacks[from] = (bagStacks[from] or 0) - (stackSize - bagStacks[to])
				bagStacks[to] = stackSize
			else
				bagStacks[to] = (bagStacks[to] or 0) + (bagStacks[from] or 0)
				bagStacks[from] = nil
				bagIDs[from] = nil
				bagQualities[from] = nil
				bagMaxStacks[from] = nil
			end
		else
			bagIDs[from], bagIDs[to] = bagIDs[to], bagIDs[from]
			bagQualities[from], bagQualities[to] = bagQualities[to], bagQualities[from]
			bagStacks[from], bagStacks[to] = bagStacks[to], bagStacks[from]
			bagMaxStacks[from], bagMaxStacks[to] = bagMaxStacks[to], bagMaxStacks[from]
		end
	end

	local function AddMove(source, destination)
		UpdateLocation(source, destination)
		table.insert(moves, 1, EncodeMove(source, destination))
	end

	-- Iterate player bags: (index, bag, slot). Forward or reverse. Generic for protocol: iter(state, prev) -> next, bag, slot.
	local function IterFwd(bagList, prev)
		prev = prev + 1
		local step = 0
		for _, bag in ipairs(bagList) do
			local slots = GetNumSlots(bag)
			for slot = 1, slots do
				step = step + 1
				if step == prev then return prev, bag, slot end
			end
		end
		return nil, nil, nil
	end
	local function IterRev(bagList, prev)
		prev = prev + 1
		local total = 0
		for _, bag in ipairs(bagList) do total = total + GetNumSlots(bag) end
		if prev > total then return nil, nil, nil end
		local idx = 0
		for bi = #bagList, 1, -1 do
			local bag = bagList[bi]
			local slots = GetNumSlots(bag)
			for slot = slots, 1, -1 do
				idx = idx + 1
				if idx == prev then return prev, bag, slot end
			end
		end
		return nil, nil, nil
	end
	local function IterateBags(bagList, reverse)
		local bags = bagList or playerBags
		return reverse and IterRev or IterFwd, bags, 0
	end

	-- Build cache: bagSlot -> itemID, stack, maxStack, quality. Uses currentBagList (set by Run).
	local currentBagList = playerBags
	local function GPH_BagSort_ScanBags()
		table.wipe(bagIDs)
		table.wipe(bagStacks)
		table.wipe(bagMaxStacks)
		table.wipe(bagQualities)
		for _, bag, slot in IterateBags(currentBagList, false) do
			local bagSlot = Encode(bag, slot)
			local itemID = GetContainerItemID and GetContainerItemID(bag, slot)
			if not itemID then
				local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
				if link then itemID = tonumber((link):match("item:(%d+)")) end
			end
			if itemID then
				local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemID)
				bagMaxStacks[bagSlot] = (maxStack and maxStack > 0) and maxStack or 1
				bagIDs[bagSlot] = itemID
				local _, count = GetContainerItemInfo(bag, slot)
				bagStacks[bagSlot] = count or 1
				local _, _, quality = GetItemInfo(itemID)
			end
		end
	end

	-- Stack: consolidate partial stacks of same item (ElvUI B.Stack logic)
	local function Stack()
		for _, bag, slot in IterateBags(currentBagList, false) do
			local bagSlot = Encode(bag, slot)
			local itemID = bagIDs[bagSlot]
			if itemID and (bagStacks[bagSlot] or 0) ~= (bagMaxStacks[bagSlot] or 1) then
				targetItems[itemID] = (targetItems[itemID] or 0) + 1
				table.insert(targetSlots, bagSlot)
			end
		end
		for _, bag, slot in IterateBags(currentBagList, true) do
			local sourceSlot = Encode(bag, slot)
			local itemID = bagIDs[sourceSlot]
			if itemID and targetItems[itemID] then
				for i = #targetSlots, 1, -1 do
					local targetedSlot = targetSlots[i]
					if bagIDs[sourceSlot] and bagIDs[targetedSlot] == itemID and targetedSlot ~= sourceSlot
						and (bagStacks[targetedSlot] or 0) ~= (bagMaxStacks[targetedSlot] or 1) and not sourceUsed[targetedSlot] then
						AddMove(sourceSlot, targetedSlot)
						sourceUsed[sourceSlot] = true
						if (bagStacks[targetedSlot] or 0) == (bagMaxStacks[targetedSlot] or 1) then
							targetItems[itemID] = (targetItems[itemID] or 1) > 1 and (targetItems[itemID] - 1) or nil
						end
						if (bagStacks[sourceSlot] or 0) == 0 then
							targetItems[itemID] = (targetItems[itemID] or 1) > 1 and (targetItems[itemID] - 1) or nil
							break
						end
						if not targetItems[itemID] then break end
					end
				end
			end
		end
		table.wipe(targetItems)
		table.wipe(targetSlots)
		table.wipe(sourceUsed)
	end

	-- Sort order for categories (GetAuctionItemClasses if present)
	local function BuildSortOrder()
		if GetAuctionItemClasses and GetAuctionItemSubClasses then
			local list = {GetAuctionItemClasses()}
			for i, iType in ipairs(list) do
				itemTypes[iType] = i
				itemSubTypes[iType] = {}
				local subList = {GetAuctionItemSubClasses(i)}
				for ii, isType in ipairs(subList) do
					itemSubTypes[iType][isType] = ii
				end
			end
		end
	end

	local function NameTiebreak(a, b)
		local aName = GetItemInfo(bagIDs[a])
		local bName = GetItemInfo(bagIDs[b])
		if aName and bName and aName ~= bName then return aName < bName end
		return (initialOrder[a] or 0) < (initialOrder[b] or 0)
	end

	-- Special-cases for bag ordering:
	-- - Hearthstone (6948) should always come first.
	-- - Protected items (per-item or rarity whitelist) should be pushed to the end.
	local HEARTHSTONE_ID = 6948
	local function IsProtectedForSort(itemId, quality)
		local Addon = _G.TestAddon
		if not (Addon and Addon.IsItemProtectedAPI) then return false end
		return Addon.IsItemProtectedAPI(itemId, quality)
	end

	local function DefaultSort(a, b)
		local aID, bID = bagIDs[a], bagIDs[b]
		if (not aID) or (not bID) then return aID ~= nil end
		if aID == bID then
			local ac, bc = bagStacks[a] or 0, bagStacks[b] or 0
			if ac == bc then return (initialOrder[a] or 0) < (initialOrder[b] or 0) end
			return ac > bc
		end

		-- Hearthstone always first, regardless of other rules.
		if aID == HEARTHSTONE_ID and bID ~= HEARTHSTONE_ID then return true end
		if bID == HEARTHSTONE_ID and aID ~= HEARTHSTONE_ID then return false end

		local DB = _G.FugaziBAGSDB
		local mode = DB and DB.gphSortMode or "rarity"
		local aRarity, bRarity = bagQualities[a] or 0, bagQualities[b] or 0

		-- Protected items should come right after Hearthstone; non-protected after them.
		local aProt = IsProtectedForSort(aID, aRarity)
		local bProt = IsProtectedForSort(bID, bRarity)
		if aProt ~= bProt then return aProt end

		local aName, _, _, aLvl, _, aType, aSubType, _, _, _, aPrice = GetItemInfo(aID)
		local bName, _, _, bLvl, _, bType, bSubType, _, _, _, bPrice = GetItemInfo(bID)
		if mode == "vendor" then
			aPrice = aPrice or 0; bPrice = bPrice or 0
			if aPrice ~= bPrice then return aPrice > bPrice end
			if aRarity ~= bRarity then return aRarity > bRarity end
			return NameTiebreak(a, b)
		elseif mode == "itemlevel" then
			aLvl = aLvl or 0; bLvl = bLvl or 0
			if aLvl ~= bLvl then return aLvl > bLvl end
			if aRarity ~= bRarity then return aRarity > bRarity end
			return NameTiebreak(a, b)
		elseif mode == "category" then
			local at = itemTypes[aType] or 99
			local bt = itemTypes[bType] or 99
			if at ~= bt then return at < bt end
			local as = (itemSubTypes[aType] and itemSubTypes[aType][aSubType]) or 99
			local bs = (itemSubTypes[bType] and itemSubTypes[bType][bSubType]) or 99
			if as ~= bs then return as < bs end
			if aRarity ~= bRarity then return aRarity > bRarity end
			return NameTiebreak(a, b)
		end
		-- "rarity" (default)
		if aRarity ~= bRarity then return aRarity > bRarity end
		local at = itemTypes[aType] or 99
		local bt = itemTypes[bType] or 99
		if at ~= bt then return at < bt end
		local as = (itemSubTypes[aType] and itemSubTypes[aType][aSubType]) or 99
		local bs = (itemSubTypes[bType] and itemSubTypes[bType][bSubType]) or 99
		if as ~= bs then return as < bs end
		aLvl = aLvl or 0; bLvl = bLvl or 0
		if aLvl ~= bLvl then return aLvl > bLvl end
		return NameTiebreak(a, b)
	end

	local function ShouldMove(source, destination)
		if destination == source then return false end
		if not bagIDs[source] then return false end
		if bagIDs[source] == bagIDs[destination] and bagStacks[source] == bagStacks[destination] then return false end
		return true
	end

	local function UpdateSorted(source, destination)
		for i, bs in pairs(bagSorted) do
			if bs == source then bagSorted[i] = destination
			elseif bs == destination then bagSorted[i] = source end
		end
	end

	-- Sort: desired order then generate moves, compacting items to front slots
	local function Sort()
		BuildSortOrder()
		table.wipe(initialOrder)
		table.wipe(bagSorted)
		local idx = 0
		for _, bag, slot in IterateBags(currentBagList, false) do
			local bagSlot = Encode(bag, slot)
			if bagIDs[bagSlot] then
				idx = idx + 1
				initialOrder[bagSlot] = idx
				table.insert(bagSorted, bagSlot)
			end
		end
		table.sort(bagSorted, DefaultSort)
		local allSlots = {}
		for _, bag, slot in IterateBags(currentBagList, false) do
			table.insert(allSlots, Encode(bag, slot))
		end
		local passNeeded = true
		while passNeeded do
			passNeeded = false
			for i, source in ipairs(bagSorted) do
				local destination = allSlots[i]
				if destination and source ~= destination then
					if bagIDs[source] then
						if not (bagLocked[source] or bagLocked[destination]) then
							AddMove(source, destination)
							UpdateSorted(source, destination)
							bagLocked[source] = true
							bagLocked[destination] = true
						else
							passNeeded = true
						end
					end
				end
			end
			table.wipe(bagLocked)
		end
		table.wipe(bagSorted)
		table.wipe(initialOrder)
	end

	local function DoMove(move)
		if GetCursorInfo and GetCursorInfo() == "item" then return false, "cursorhasitem" end
		local source, target = DecodeMove(move)
		local sourceBag, sourceSlot = Decode(source)
		local targetBag, targetSlot = Decode(target)
		local _, sourceCount, sourceLocked = GetContainerItemInfo(sourceBag, sourceSlot)
		local _, targetCount, targetLocked = GetContainerItemInfo(targetBag, targetSlot)
		sourceCount = sourceCount or 0
		targetCount = targetCount or 0
		if sourceLocked or targetLocked then return false, "locked" end
		local sourceItemID = GetContainerItemID and GetContainerItemID(sourceBag, sourceSlot)
		if not sourceItemID then
			local link = GetContainerItemLink and GetContainerItemLink(sourceBag, sourceSlot)
			if link then sourceItemID = tonumber((link):match("item:(%d+)")) end
		end
		if not sourceItemID then return false, "noitem" end
		local stackSize = select(8, GetItemInfo(sourceItemID)) or 1
		local targetItemID = GetContainerItemID and GetContainerItemID(targetBag, targetSlot)
		if not targetItemID and GetContainerItemLink then
			local link = GetContainerItemLink(targetBag, targetSlot)
			if link then targetItemID = tonumber((link):match("item:(%d+)")) end
		end
		if (sourceItemID == targetItemID) and targetCount and targetCount < stackSize and (targetCount + sourceCount) > stackSize then
			SplitContainerItem(sourceBag, sourceSlot, stackSize - targetCount)
		else
			PickupContainerItem(sourceBag, sourceSlot)
		end
		if GetCursorInfo and GetCursorInfo() == "item" then
			PickupContainerItem(targetBag, targetSlot)
		end
		return true, sourceItemID, source, targetItemID, target
	end

	local onDoneCallback
	local timerFrame = CreateFrame("Frame")
	timerFrame:Hide()
	timerFrame:SetScript("OnUpdate", function(_, elapsed)
		timerFrame._t = (timerFrame._t or 0) + (elapsed or 0.01)
		if timerFrame._t < WAIT_TIME then return end
		timerFrame._t = 0

		if InCombatLockdown and InCombatLockdown() then
			timerFrame:Hide()
			table.wipe(moves)
			table.wipe(moveTracker)
			if onDoneCallback then onDoneCallback() end
			return
		end

		local cursorType, cursorItemID = GetCursorInfo and GetCursorInfo()
		if cursorType == "item" and cursorItemID then
			if lastItemID ~= cursorItemID then
				timerFrame:Hide()
				table.wipe(moves)
				table.wipe(moveTracker)
				if onDoneCallback then onDoneCallback() end
				return
			end
			if moveRetries < 100 then
				local targetBag, targetSlot = Decode(lastDestination)
				local _, _, targetLocked = GetContainerItemInfo(targetBag, targetSlot)
				if not targetLocked then
					PickupContainerItem(targetBag, targetSlot)
					moveRetries = moveRetries + 1
					return
				end
			end
		end

		if lockStop then
			for slot, itemID in pairs(moveTracker) do
				local sb, ss = Decode(slot)
				local actualID = GetContainerItemID and GetContainerItemID(sb, ss)
				if not actualID and GetContainerItemLink then
					local link = GetContainerItemLink(sb, ss)
					if link then actualID = tonumber((link):match("item:(%d+)")) end
				end
				if actualID ~= itemID then
					if (GetTime() - lockStop) > MAX_MOVE_TIME and lastMove and moveRetries < 100 then
						local ok, moveID, moveSource, targetID, moveTarget = DoMove(lastMove)
						if not ok then
							moveRetries = moveRetries + 1
							return
						end
						moveTracker[moveSource] = targetID
						moveTracker[moveTarget] = moveID
						lastDestination = moveTarget
						lastItemID = moveID
						return
					end
					timerFrame:Hide()
					table.wipe(moves)
					table.wipe(moveTracker)
					lastItemID, lockStop, lastDestination, lastMove = nil, nil, nil, nil
					moveRetries = 0
					if onDoneCallback then onDoneCallback() end
					return
				end
				moveTracker[slot] = nil
			end
		end

		lastItemID, lockStop, lastDestination, lastMove = nil, nil, nil, nil
		table.wipe(moveTracker)

		if #moves > 0 then
			local success, moveID, moveSource, targetID, moveTarget
			local i = #moves
			success, moveID, moveSource, targetID, moveTarget = DoMove(moves[i])
			if not success then
				lockStop = GetTime()
				return
			end
			lastMove = moves[i]
			table.remove(moves, i)
			moveTracker[moveSource] = targetID
			moveTracker[moveTarget] = moveID
			lastDestination = moveTarget
			lastItemID = moveID
			return
		end

		timerFrame:Hide()
		moveRetries = 0
		if onDoneCallback then onDoneCallback() end
	end)

	GPH_BagSort_Run = function(callback, bagGroup, optionalBagList)
		if timerFrame:IsShown() then return end
		if bagGroup == "bank" and optionalBagList and #optionalBagList > 0 then
			currentBagList = optionalBagList
		elseif bagGroup == "bank" and #bankBags > 0 then
			currentBagList = bankBags
		else
			currentBagList = playerBags
		end
		onDoneCallback = callback
		GPH_BagSort_ScanBags()
		Stack()
		Sort()
		lastItemID, lockStop, lastDestination, lastMove = nil, nil, nil, nil
		moveRetries = 0
		table.wipe(moveTracker)
		if #moves > 0 then
			timerFrame._t = 0
			timerFrame:Show()
		else
			if onDoneCallback then onDoneCallback() end
		end
	end
end

--- Returns the current character's (*) protected item set (read/write). Migrates from older account-wide list on first use.

local Addon = _G.TestAddon

-- Throttled rarity move worker (bags <-> bank) using live scans each tick.
Addon.RarityMoveJob = Addon.RarityMoveJob or nil
local rarityMoveWorker = Addon.RarityMoveWorker or CreateFrame("Frame")
Addon.RarityMoveWorker = rarityMoveWorker
rarityMoveWorker:Hide()

local function RarityIsProtected(itemId, quality)
    if not itemId then return true end
    if itemId == 6948 then return true end  -- Always protect Hearthstone
    
    local name, _, _, _, _, itemType = GetItemInfo(itemId)
    if itemType == "Quest" then return true end -- Always protect Quest items
    
    local protectedSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}
    
    if protectedSet[itemId] then return true end
    if rarityFlags[quality or 0] then return true end
    if Addon.GetGphPreviouslyWornOnlySet then
        local prevOnly = Addon.GetGphPreviouslyWornOnlySet()
        if prevOnly and prevOnly[itemId] then return true end
    end
    
    -- Also respect manual unprotected items
    local SV = _G.FugaziBAGSDB
    if SV and SV._manualUnprotected and SV._manualUnprotected[itemId] then
        return false
    end
    
    return false
end

--- Finds the next bag slot that has an item of the given rarity and isn't protected (for "send to bank" / move jobs).
local function FindNextFromBags(rarity)
    for bag = 0, 4 do
        local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local _, _, locked = GetContainerItemInfo(bag, slot)
            local itemId = GetContainerItemID and GetContainerItemID(bag, slot)
            if itemId and not locked then
                local _, _, q = GetItemInfo(itemId)
                q = q or 0
                if q == rarity and not RarityIsProtected(itemId, q) then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
end

--- Finds the next bank slot that has an item of the given rarity and isn't protected (for "send to bags" move jobs).
local function FindNextFromBank(rarity)
    -- Scan all known bank containers for the next non-protected item of this rarity.
    local function scanBag(bagID)
        if not bagID then return nil, nil end
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
        if not numSlots or numSlots <= 0 then return nil, nil end
        for slot = 1, numSlots do
            local _, _, locked = GetContainerItemInfo(bagID, slot)
            local itemId = GetContainerItemID and GetContainerItemID(bagID, slot)
            if itemId and not locked then
                local _, _, q = GetItemInfo(itemId)
                q = q or 0
                if q == rarity and not RarityIsProtected(itemId, q) then
                    return bagID, slot
                end
            end
        end
        return nil, nil
    end

    -- 1) Try explicit main bank IDs.
    local mainCandidates = {}
    if BANK_CONTAINER ~= nil then
        table.insert(mainCandidates, BANK_CONTAINER)
    end
    table.insert(mainCandidates, -1)  -- classic/WotLK main bank
    table.insert(mainCandidates, 5)   -- some servers/use-cases

    for _, bagID in ipairs(mainCandidates) do
        local bag, slot = scanBag(bagID)
        if bag then return bag, slot end
    end

    -- 2) Then scan all bank bags (NUM_BANKBAGSLOTS or fallback).
    local numBankBags = (NUM_BANKBAGSLOTS or NUM_BANK_BAGS or 6)
    local base = (NUM_BAG_SLOTS or 4)
    for i = 1, numBankBags do
        local bagID = base + i
        local bag, slot = scanBag(bagID)
        if bag then return bag, slot end
    end

    return nil, nil
end

rarityMoveWorker:SetScript("OnUpdate", function(self, elapsed)
    local job = Addon.RarityMoveJob
    if not job then
        self._t = nil
        self:Hide()
        return
    end
    self._t = (self._t or 0) + elapsed
    if self._t < 0.1 then return end
    self._t = 0

    local bankFrame = _G.TestBankFrame
    -- Require bank window to be open: do nothing and cancel job if bank is closed (avoids stuck cursor / loop).
    if not bankFrame or not bankFrame:IsShown() or not bankFrame.GetFirstFreeBankSlot or not bankFrame.GetFirstFreeBagSlot then
        Addon.RarityMoveJob = nil
        ClearCursor()
        self:Hide()
        return
    end

    local srcBag, srcSlot
    if job.mode == "bags_to_bank" then
        srcBag, srcSlot = FindNextFromBags(job.rarity)
    else
        srcBag, srcSlot = FindNextFromBank(job.rarity)
    end
    if not srcBag or not srcSlot then
        self._emptyTicks = (self._emptyTicks or 0) + 1
        if self._emptyTicks > 10 then
            Addon.RarityMoveJob = nil
            self._emptyTicks = 0
            self:Hide()
        end
        return
    end
    self._emptyTicks = 0

    local destBag, destSlot
    if job.mode == "bags_to_bank" then
        destBag, destSlot = bankFrame.GetFirstFreeBankSlot()
    else
        destBag, destSlot = bankFrame.GetFirstFreeBagSlot()
    end
    if not destBag or not destSlot then
        Addon.RarityMoveJob = nil
        self:Hide()
        return
    end

    ClearCursor()
    if PickupContainerItem then
        PickupContainerItem(srcBag, srcSlot)
        PickupContainerItem(destBag, destSlot)
    end

    if RefreshBankUI then RefreshBankUI() end
    if RefreshGPHUI then RefreshGPHUI() end
end)

-- Postal-style event-driven bulk mailer for rarity buttons
local mailRarityWorker = CreateFrame("Frame")
mailRarityWorker:Hide()
Addon.MailRarityQueue = {}
Addon.MailRarityIndex = 0
Addon.MailRarityActive = false

--- Sends the next batch of items from the "send rarity to mailbox" queue (one item at a time to avoid WoW throttling).
local function SendNextRarityBatch()
    if not Addon.MailRarityActive then return end
    
    local recipient = SendMailNameEditBox:GetText()
    if not recipient or recipient == "" then
        print("|cffff0000[FugaziBAGS]|r Please enter a recipient first.")
        Addon.MailRarityActive = false
        mailRarityWorker:UnregisterEvent("MAIL_SEND_SUCCESS")
        mailRarityWorker:UnregisterEvent("MAIL_FAILED")
        return
    end

    if Addon.MailRarityIndex >= #Addon.MailRarityQueue then
        print("|cff00ff00[FugaziBAGS]|r Finished sending items.")
        Addon.MailRarityActive = false
        mailRarityWorker:UnregisterEvent("MAIL_SEND_SUCCESS")
        mailRarityWorker:UnregisterEvent("MAIL_FAILED")
        return
    end

    -- Clear existing attachments just in case
    for i = 1, 12 do
        if GetSendMailItem(i) then
            ClickSendMailItemButton(i, true)
        end
    end

    -- Attach up to 12 items
    local attached = 0
    local targetRarity = Addon.MailRarityJobQuality -- Record the rarity we are sending

    while Addon.MailRarityIndex < #Addon.MailRarityQueue and attached < 12 do
        Addon.MailRarityIndex = Addon.MailRarityIndex + 1
        local item = Addon.MailRarityQueue[Addon.MailRarityIndex]
        
        local link = GetContainerItemLink(item.bag, item.slot)
        if link then
            local _, _, locked = GetContainerItemInfo(item.bag, item.slot)
            local itemId = tonumber(link:match("item:(%d+)"))
            local _, _, q = GetItemInfo(link)
            q = q or 0
            
            -- If quality is -1, it's a "Send All" job, so we match any quality.
            local qualityMatch = (Addon.MailRarityJobQuality == -1) or (q == targetRarity)

            if not locked and qualityMatch and not RarityIsProtected(itemId, q) then
                PickupContainerItem(item.bag, item.slot)
                ClickSendMailItemButton(attached + 1)
                attached = attached + 1
            end
        end
    end

    if attached > 0 then
        if SendMailSubjectEditBox:GetText() == "" then
            SendMailSubjectEditBox:SetText("Bulk Send (" .. Addon.MailRarityIndex .. ")")
        end
        SendMailFrame_SendMail()
    elseif Addon.MailRarityIndex < #Addon.MailRarityQueue then
        -- We looked at items but they were all locked or protected. 
        -- If items remain, wait 0.5s and try the next chunk of the queue.
        Addon._gphMailDeferFrame = Addon._gphMailDeferFrame or CreateFrame("Frame")
        local df = Addon._gphMailDeferFrame
        df._t = 0
        df:Show()
        df:SetScript("OnUpdate", function(self, elapsed)
            self._t = (self._t or 0) + elapsed
            if self._t > 0.5 then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                SendNextRarityBatch()
            end
        end)
    else
        print("|cff00ff00[FugaziBAGS]|r Mailing finished (No more matches).")
        Addon.MailRarityActive = false
        Addon.MailRarityJobQuality = nil
        mailRarityWorker:UnregisterAllEvents()
        mailRarityWorker:SetScript("OnUpdate", nil)
    end
end

--- Timeout watchdog for "send rarity to mailbox": stops if no mail event for 1.5 seconds (avoids stuck state).
local function mailRarityOnUpdate(self, elapsed)
    if not Addon.MailRarityActive then 
        self:SetScript("OnUpdate", nil)
        return 
    end
    
    self._timeoutTimer = (self._timeoutTimer or 0) + elapsed
    if self._timeoutTimer >= 1.5 then
        -- TIMEOUT: 1.5 seconds of inactivity. Stop for safety.
        print("|cffff0000[FugaziBAGS]|r Mailing timed out (Inactivity). Stopping.")
        Addon.MailRarityActive = false
        Addon.MailRarityJobQuality = nil
        self:UnregisterAllEvents()
        self:SetScript("OnUpdate", nil)
    end
end
mailRarityWorker._onUpdateFunc = mailRarityOnUpdate
mailRarityWorker:SetScript("OnUpdate", mailRarityOnUpdate)

mailRarityWorker:SetScript("OnEvent", function(self, event)
    -- Reset timeout timer whenever we get a server response
    self._timeoutTimer = 0

    if event == "MAIL_SEND_SUCCESS" then
        -- Small delay before next batch (Postal style)
        local f = CreateFrame("Frame")
        local elapsed = 0
        f:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= 0.5 then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                SendNextRarityBatch()
            end
        end)
    elseif event == "MAIL_FAILED" or event == "MAIL_CLOSED" then
        print("|cffff0000[FugaziBAGS]|r Mailing cancelled or failed.")
        Addon.MailRarityActive = false
        Addon.MailRarityJobQuality = nil
        self:UnregisterAllEvents()
        self:SetScript("OnUpdate", nil)
    end
end)

--- Starts the "send all items of this rarity to mailbox" job (from Shift+RMB on rarity bar when mail is open).
function Addon.StartSendRarityMail(rarity)
    local recipient = SendMailNameEditBox:GetText()
    if not recipient or recipient == "" then
        print("|cffff0000[FugaziBAGS]|r Please enter a recipient first.")
        return
    end

    wipe(Addon.MailRarityQueue)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local itemId = tonumber(link:match("item:(%d+)"))
                local _, _, q = GetItemInfo(link)
                q = q or 0
                -- If rarity is -1, it's a "Send All" job
                local match = (rarity == -1) or (q == rarity)
                if match and not RarityIsProtected(itemId, q) then
                    table.insert(Addon.MailRarityQueue, { bag = bag, slot = slot })
                end
            end
        end
    end

    if #Addon.MailRarityQueue == 0 then
        local msg = (rarity == -1) and "No unprotected items found." or "No unprotected items of this rarity found."
        print("|cffff0000[FugaziBAGS]|r " .. msg)
        return
    end

    local label = (rarity == -1) and "ALL items" or (#Addon.MailRarityQueue .. " items")
    print("|cff00ff00[FugaziBAGS]|r Sending " .. label .. " to " .. recipient)

    Addon.MailRarityActive = true
    Addon.MailRarityIndex = 0
    Addon.MailRarityJobQuality = rarity
    mailRarityWorker._timeoutTimer = 0 -- Reset timer
    mailRarityWorker:RegisterEvent("MAIL_SEND_SUCCESS")
    mailRarityWorker:RegisterEvent("MAIL_FAILED")
    mailRarityWorker:RegisterEvent("MAIL_CLOSED")
    if mailRarityWorker._onUpdateFunc then
        mailRarityWorker:SetScript("OnUpdate", mailRarityWorker._onUpdateFunc)
    end
    SendNextRarityBatch()
end

--[[
  Inventory value and GPH use TSM or Auctionator API only (no tooltip parsing).
  GPH formula (no double-count: you vendor OR auction an item, not both):
  - With addon: For each session item, poor (grey, quality 0) counts vendor value only; common and up (quality 1+) count 85% auction value only.
    totalValue = raw gold + (vendor of poor, non‑soulbound) + 85% of (auction value of common+, non‑soulbound). / hrs
  - Without addon: GPH = raw gold / hours.
  Soulbound items excluded from inventory value and session value.
]]
--- True if TSM or Auctionator is loaded; when false, GPH shows raw gold per hour only.
local function AuctionAddonLoaded()
    return (_G.TSMAPI and _G.TSMAPI.GetItemPrices) or _G.Atr_GetAuctionPrice
end

--- Returns auction price in copper from TSM (DBMinBuyout/DBMarket) or Auctionator; 0 if neither loaded or no price.
--- link = item link (e.g. from GetContainerItemLink). Used for gold bar tooltip and GPH session value.
local function GetAuctionPriceFromAPI(link)
    if not link then return 0 end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return 0 end
    if _G.TSMAPI and _G.TSMAPI.GetItemPrices then
        local ok, prices = pcall(_G.TSMAPI.GetItemPrices, _G.TSMAPI, link)
        if ok and prices then
            local v = prices.DBMinBuyout or prices.DBMarket or 0
            return (type(v) == "number" and v > 0) and v or 0
        end
    end
    if _G.Atr_GetAuctionPrice then
        local ok, v = pcall(_G.Atr_GetAuctionPrice, itemId)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return 0
end

local gphSoulboundScanTooltip
local gphSoulboundCache = {}
local function GetSoulboundScanTooltip()
    if not gphSoulboundScanTooltip then
        gphSoulboundScanTooltip = CreateFrame("GameTooltip", "TestGPHSoulboundScanTT", UIParent, "GameTooltipTemplate")
        gphSoulboundScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        gphSoulboundScanTooltip:ClearAllPoints()
        gphSoulboundScanTooltip:SetPoint("CENTER", UIParent, "CENTER", 99999, 99999) -- effectively off-screen
    end
    return gphSoulboundScanTooltip
end

--- True if the item is soulbound (or similar). Scans tooltip for "Soul Bound", "Binds when picked up", etc.
--- Used for GPH session items (we only have the link, not bag/slot).
local function IsLinkSoulbound(link)
    if not link then return true end
    if gphSoulboundCache[link] ~= nil then
        return gphSoulboundCache[link]
    end
    local gt = GetSoulboundScanTooltip()
    if not gt or not gt.SetHyperlink then return false end
    gt:ClearLines()
    gt:SetOwner(UIParent, "ANCHOR_NONE")
    gt:SetHyperlink(link)
    gt:Show()
    local n = (gt.NumLines and gt:NumLines()) or 0
    for i = 1, n do
        local line = _G["TestGPHSoulboundScanTTTextLeft" .. i]
        if line and line.GetText then
            local t = (line:GetText() or ""):lower()
            if t:find("soul bound") or t:find("soulbound") or t:find("binds when picked up") or t:find("binds when equipped") or t:find("account bound") then
                gt:ClearLines()
                gt:Hide()
                return true
            end
        end
    end
    gt:ClearLines()
    gt:Hide()
    return false
end

--- True if the item in this bag slot is soulbound. Uses SetBagItem so we see actual bind state (not just "Binds when picked up").
--- Used to exclude soulbound items from the gold bar "bag value" tooltip.
local function IsBagItemSoulbound(bag, slot)
    local gt = GetSoulboundScanTooltip()
    if not gt or not gt.SetBagItem then return false end
    gt:ClearLines()
    gt:SetOwner(UIParent, "ANCHOR_NONE")
    gt:SetBagItem(bag, slot)
    gt:Show()
    local n = (gt.NumLines and gt:NumLines()) or 0
    for i = 1, n do
        local line = _G["GameTooltipTextLeft" .. i]
        if line and line.GetText then
            local t = (line:GetText() or ""):lower()
            if t:find("soul bound") or t:find("soulbound") or t:find("binds when picked up") or t:find("binds when equipped") or t:find("account bound") then
                gt:ClearLines()
                gt:Hide()
                return true
            end
        end
    end
    gt:ClearLines()
    gt:Hide()
    return false
end

--- Sums vendor and auction value of all bag items (API only). Excludes soulbound and "previously worn" items.
--- vendorCopper = sum of (vendor sell price * count) per item. auctionCopper = sum of (TSM/Auctionator price * count) per item.
--- Called when you hover the gold bar; result is shown in the tooltip.
local function ComputeVendorAuctionTotalsSync()
    local previouslyWorn = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}
    local vendorCopper = 0   -- running total: vendor sell value in copper
    local auctionCopper = 0  -- running total: auction value in copper (from TSM or Auctionator)
    local itemCounts = {}    -- itemId -> { count = total stack count, link = one link for API lookup }
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
            if link and not IsBagItemSoulbound(bag, slot) then
                local _, count = GetContainerItemInfo(bag, slot)
                count = count or 1
                local itemId = tonumber(link:match("item:(%d+)"))
                if not previouslyWorn[itemId] then
                    local _, _, _, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(link)
                    vendorCopper = vendorCopper + (vendorPrice or 0) * count
                end
                if itemId then
                    if not itemCounts[itemId] then itemCounts[itemId] = { count = 0, link = link } end
                    itemCounts[itemId].count = itemCounts[itemId].count + count
                end
            end
        end
    end
    for _, entry in pairs(itemCounts) do
        auctionCopper = auctionCopper + GetAuctionPriceFromAPI(entry.link) * entry.count
    end
    return vendorCopper, auctionCopper
end

--- Estimated value (copper) of session items only: vendor for poor (quality 0), 85%% auction for common+. Excludes soulbound. Used for Ledger.
--- itemList = array of { link, quality, count, name }. Returns copper (no raw gold; caller adds that).
local function ComputeGPHEstimatedValue(itemList)
    if not itemList then return 0 end
    local vendor = 0
    local auction = 0
    for _, data in ipairs(itemList) do
        local link = data and data.link
        local count = (data and data.count) or 0
        local quality = (data and data.quality) or 0
        if link and count > 0 and not IsLinkSoulbound(link) then
            if quality == 0 then
                local _, _, _, _, _, _, _, _, _, _, vp = GetItemInfo(link)
                vendor = vendor + (vp or 0) * count
            else
                auction = auction + GetAuctionPriceFromAPI(link) * count
            end
        end
    end
    return vendor + math.floor(auction * 0.85)
end
Addon.ComputeGPHEstimatedValue = ComputeGPHEstimatedValue

--- Single place for GPH total value: raw gold + (vendor for poor, non-soulbound session items) + 85% of (auction for common+, non-soulbound).
--- Returns totalValue in copper. Used by OnUpdate and RefreshGPHUI so the formula never drifts.
--- session = gphSession table with .items (array of { link, count, quality }); liveGold = current session gold in copper.
local function ComputeGPHTotalValue(session, liveGold)
    if not session then return liveGold or 0 end
    local total = liveGold or 0
    if not AuctionAddonLoaded() or not session.items then return total end
    local sessionVendor = 0
    local sessionAuction = 0
    for _, data in pairs(session.items) do
        local link = data and data.link
        local count = (data and data.count) or 0
        local quality = (data and data.quality) or 0
        if link and count > 0 and not IsLinkSoulbound(link) then
            if quality == 0 then
                local _, _, _, _, _, _, _, _, _, _, vp = GetItemInfo(link)
                sessionVendor = sessionVendor + (vp or 0) * count
            else
                sessionAuction = sessionAuction + GetAuctionPriceFromAPI(link) * count
            end
        end
    end
    return total + sessionVendor + math.floor(sessionAuction * 0.85)
end

--- Plays media/click.ogg if "Play sounds" is on (list/buttons only; not grid slots). Throttled 0.25s.
function Addon.PlayClickSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    local last = Addon._gphClickSoundLast or 0
    if now - last < 0.25 then return end
    Addon._gphClickSoundLast = now
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg")
end

--- Plays media/hover.ogg (rarity, bag space, search). Instant; skips only if click just played (stops double hover when button "pops" on click).
function Addon.PlayHoverSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    if (Addon._gphClickSoundLast or 0) > 0 and (now - Addon._gphClickSoundLast) < 0.15 then return end
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\hover.ogg")
end

--- Plays media/trash.ogg when deleting or adding to autodelete (X button, CTRL+RMB grid). Throttled 0.25s.
function Addon.PlayTrashSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    local last = Addon._gphTrashSoundLast or 0
    if now - last < 0.25 then return end
    Addon._gphTrashSoundLast = now
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\trash.ogg")
end

--- Creates the main inventory window: title bar, sort button, item list or grid, GPH timer. Starts hidden.
local function CreateGPHFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 2, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "FugaziBAGS_GPHFrame", UIParent)
    if _G.UISpecialFrames then
        table.insert(_G.UISpecialFrames, "FugaziBAGS_GPHFrame")
    end
    local cg = _G.FugaziBAGS_CombatGrid
    local initW, initH = 340, 400
    if cg and cg.ComputeFrameSize then
        initW, initH = cg.ComputeFrameSize()
    end
    f:SetWidth(initW)
    f:SetHeight(initH)
    f.gphGridFrameW = initW
    f.gphGridFrameH = initH
    -- New-player default: use the position you picked in-game (RIGHT of UIParent).
    f:SetPoint("RIGHT", UIParent, "RIGHT", -444, -4)
    f:Hide()
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        -- Do not start moving while Alt is held; this lets Alt+click/drag on rarity
        -- buttons "paint" safely without accidentally dragging the whole window.
        if IsAltKeyDown and IsAltKeyDown() then return end
        if f._isDragging then return end -- title bar may have started drag; only one handler runs
        -- Clear selection when drag starts so overlay is off row; prevents list sticking when window is moved.
        if f.gphSelectedItemId then
            f.gphSelectedItemId = nil
            f.gphSelectedIndex = nil
            f.gphSelectedRowBtn = nil
            f.gphSelectedItemLink = nil
            if f.HideGPHUseOverlay then f.HideGPHUseOverlay(f) end
        end
        f._isDragging = true
        f:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        if not f._isDragging then return end
        f._isDragging = nil
        f:StopMovingOrSizing()
        if f.NegotiateSizes then f:NegotiateSizes() end
        DB.gphDockedToMain = false
        Addon.SaveFrameLayout(f, "gphShown", "gphPoint")
        -- Re-anchor scroll content so the item list stays with the frame after move (fixes list stuck on screen when moving in combat).
        local sf = f.scrollFrame
        local c = sf and sf:GetScrollChild()
        if c and sf then
            local v = f.gphScrollOffset or 0
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, v)
            c:SetWidth(SCROLL_CONTENT_WIDTH)
            if c.SetHeight then c:SetHeight(c:GetHeight() or 1) end
        end
    end)
    f:SetScript("OnHide", function()
        if f.gphProxyFrame then f.gphProxyFrame:Hide() end
        Addon.SaveFrameLayout(f, "gphShown", "gphPoint")
    end)
    f._gphSkinAppliedOnFirstShow = nil  -- apply skin once on first Show after /reload so saved skin is used
    f:SetScript("OnShow", function()
        if f.gphProxyFrame then f.gphProxyFrame:Show() end
        if not f._gphSkinAppliedOnFirstShow and f.ApplySkin then
            f._gphSkinAppliedOnFirstShow = true
            f.ApplySkin()
        end
        if ApplyCustomizeToFrame then ApplyCustomizeToFrame(f) end
        if f.gphTitle then ApplyGphInventoryTitle(f.gphTitle) end
        if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
        f.gphScrollToDefaultOnNextRefresh = true
        if Addon._gphSelectionDeferFrame then
            local df = Addon._gphSelectionDeferFrame
            df:Show()
            df:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                self:Hide()
                if RefreshGPHUI then RefreshGPHUI() end
            end)
        end
    end)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(10)
    f.EXPANDED_HEIGHT = 400

    -- ESC clears pending rarity DEL state. Use a hidden EditBox so ESC is reliably caught in 3.3.5.
    -- While DEL state is active this EditBox has focus, so ESC fires here first (not closing inventory).
    local gphEscCatcher = CreateFrame("EditBox", nil, f)
    gphEscCatcher:SetAutoFocus(false)
    gphEscCatcher:SetSize(1, 1)
    gphEscCatcher:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -1000, 0)
    gphEscCatcher:SetAlpha(0)
    gphEscCatcher:EnableMouse(false)
    gphEscCatcher:Hide()
    gphEscCatcher:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:Hide()
        local hadPending = false
        if Addon.gphPendingQuality then
            for q in pairs(Addon.gphPendingQuality) do
                Addon.gphPendingQuality[q] = nil
                hadPending = true
            end
        end
        if Addon.gphRarityDelStage then
            for q in pairs(Addon.gphRarityDelStage) do
                Addon.gphRarityDelStage[q] = nil
                hadPending = true
            end
        end
        if hadPending and RefreshGPHUI then RefreshGPHUI() end
        -- Do NOT close inventory; let user press ESC again to do that
    end)
    f.gphEscCatcher = gphEscCatcher

    -- 3-second inactivity timeout: if DEL stage is set but user didn't click within 3s, cancel
    f._delTimeoutAccum = 0
    local gphDelTimeoutFrame = CreateFrame("Frame", nil, f)
    gphDelTimeoutFrame:SetScript("OnUpdate", function(self, elapsed)
        if not (Addon.gphRarityDelStage and next(Addon.gphRarityDelStage)) then
            self._accum = 0
            return
        end
        self._accum = (self._accum or 0) + elapsed
        if self._accum < 0.5 then return end
        self._accum = 0
        local now = GetTime and GetTime() or time()
        local changed = false
        for q, st in pairs(Addon.gphRarityDelStage) do
            if (now - (st.time or 0)) > 3 then
                Addon.gphRarityDelStage[q] = nil
                if Addon.gphPendingQuality then Addon.gphPendingQuality[q] = nil end
                if f.gphEscCatcher then f.gphEscCatcher:ClearFocus(); f.gphEscCatcher:Hide() end
                changed = true
            end
        end
        if changed and RefreshGPHUI then
            if f then f._refreshImmediate = true end
            RefreshGPHUI()
        end
    end)

    -- Dropdown menu for title right-click
    local gphMenu = CreateFrame("Frame", "FugaziBAGS_GPHMenu", f, "UIDropDownMenuTemplate")
    local function GPHTitleMenu_Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        local SV = _G.FugaziBAGSDB
        if not level or level == 1 then
            -- Close button as requested (red "Close" at top)
            info = UIDropDownMenu_CreateInfo()
            info.text = "|cffff4444Close Inventory|r"
            info.func = function()
                if ToggleGPHFrame then ToggleGPHFrame() end
                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo()
            info.text = "|cff888888Settings|r"
            info.func = function()
                if InterfaceOptionsFrame_OpenToCategory then
                    InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
                    InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
                end

                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Instance Tracker"
            info.func = function()
                if SlashCmdList["INSTANCETRACKER"] then SlashCmdList["INSTANCETRACKER"]("") end
                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)

            -- 2. Session Status & Controls
            if _G.gphSession then
                info = UIDropDownMenu_CreateInfo()
                info.text = "|cff00ff00Session Active|r"
                info.isTitle = true
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
            end

            info = UIDropDownMenu_CreateInfo()
            info.text = _G.gphSession and "Stop Session" or "Start Session"
            info.func = function()
                if _G.gphSession then
                    -- Trigger Stop Logic Directly
                    if Addon.StopGPHSession then Addon.StopGPHSession() end
                else
                    -- Trigger Start Logic Directly
                    if Addon.StartGPHSession then Addon.StartGPHSession() end
                    if RefreshGPHUI and (gphFrame or _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame) then
                        if not gphFrame then gphFrame = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame end
                        gphFrame._refreshImmediate = true
                        RefreshGPHUI()
                    end
                end
                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            if _G.gphSession then
                info = UIDropDownMenu_CreateInfo()
                info.text = "Reset Session"
                info.func = function()
                    if Addon and type(Addon.ResetGPHSession) == "function" then
                        Addon.ResetGPHSession()
                    end
                    CloseDropDownMenus()
                end
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
            end

            info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)

            -- 2. Behavior & Automations
            info = UIDropDownMenu_CreateInfo()
            info.text = "Autoselling"
            info.isNotRadio = true
            info.checked = (SV.gphAutoVendor == true)
            info.func = function()
                if not SV.gphAutoVendor then
                    StaticPopup_Show("GPH_AUTOSELL_CONFIRM")
                else
                    SV.gphAutoVendor = false
                    -- No invBtn to update, autosell state is managed by SV.gphAutoVendor
                end
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Autosummon Greedy scavenger"
            info.isNotRadio = true
            info.checked = (SV.gphSummonGreedy ~= false)
            info.func = function()
                SV.gphSummonGreedy = not SV.gphSummonGreedy
                -- No gphSummonBtn to update, autosummon state is managed by SV.gphSummonGreedy
            end
            UIDropDownMenu_AddButton(info)

            -- 3. Summons
            info = UIDropDownMenu_CreateInfo()
            info.text = "Summon Greedy scavenger"
            info.func = function() Addon.DoGphSummonGreedyNow() end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Summon Goblin Merchant"
            info.func = function() Addon.DoGphSummonGoblinMerchantNow() end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)

            -- 4. Tools (Destroy only if this character has Enchanting or Jewelcrafting)
            local hasDE = Addon.IsSpellKnownByName and Addon.IsSpellKnownByName("Disenchant")
            local hasProspect = Addon.IsSpellKnownByName and Addon.IsSpellKnownByName("Prospecting")
            if hasDE or hasProspect then
                info = UIDropDownMenu_CreateInfo()
                info.text = "Destroy"
                info.isNotRadio = true
                info.checked = not GetPerChar("gphHideDestroyBtn", false)
                info.func = function()
                    SetPerChar("gphHideDestroyBtn", not GetPerChar("gphHideDestroyBtn", false))
                    if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
                end
                UIDropDownMenu_AddButton(info)
            end

            if MailFrame and MailFrame:IsShown() and f.gphMailBtn then
                info = UIDropDownMenu_CreateInfo()
                info.text = "Get All Mail"
                info.func = function()
                    if f.gphMailBtn and f.gphMailBtn:GetScript("OnClick") then
                        f.gphMailBtn:GetScript("OnClick")(f.gphMailBtn)
                    end
                    CloseDropDownMenus()
                end
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
            end

            -- Sort only in list view (grid has no sort); Clean up Inventory in both views
            if not f.gphGridMode then
                info = UIDropDownMenu_CreateInfo()
                info.text = "Sort"
                info.hasArrow = true
                info.value = "SORT"
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
            end
            info = UIDropDownMenu_CreateInfo()
            info.text = "Clean up Inventory"
            info.func = function()
                if GPH_BagSort_Run then GPH_BagSort_Run(RefreshGPHUI) end
                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

            -- 5. View Modes (only if Force Grid is off; when forced, list is not an option)
            local forceGrid = GetPerChar("gphForceGridView", false)
            local inCombat = InCombatLockdown and InCombatLockdown()
            if not forceGrid then
                info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)
                local gridMode = GetPerChar("gphGridMode", false)
                info = UIDropDownMenu_CreateInfo()
                -- In combat, list mode is not allowed; show it greyed out.
                if inCombat then
                    info.text = "List View (in combat: grid only)"
                    info.disabled = true
                else
                    info.text = (not gridMode) and "|cff00ff00List View|r" or "List View"
                end
                info.checked = not gridMode
                info.func = function()
                    if InCombatLockdown and InCombatLockdown() then return end
                    SetPerChar("gphGridMode", false)
                    f.gphGridMode = false
                    local cg = _G.FugaziBAGS_CombatGrid
                    if cg and cg.HideInFrame then cg.HideInFrame(f) end
                    if RefreshGPHUI then f._refreshImmediate = true; RefreshGPHUI() end
                    if f.UpdateGPHCollapse then f:UpdateGPHCollapse() end
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info)

                info = UIDropDownMenu_CreateInfo()
                info.text = gridMode and "|cff00ff00Grid View|r" or "Grid View"
                info.checked = gridMode
                info.func = function()
                    SetPerChar("gphGridMode", true)
                    f.gphGridMode = true
                    local cg = _G.FugaziBAGS_CombatGrid
                    if cg and cg.ShowInFrame then cg.ShowInFrame(f) end
                    if RefreshGPHUI then RefreshGPHUI() end
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info)
            end

        elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "SORT" then
            local modes = {
                { val = "rarity", text = "Rarity" },
                { val = "vendor", text = "Vendorprice" },
                { val = "itemlevel", text = "ItemLvl" },
                { val = "category", text = "Category" },
            }
            for _, m in ipairs(modes) do
                info = UIDropDownMenu_CreateInfo()
                info.text = m.text
                info.checked = (SV.gphSortMode == m.val)
                info.func = function()
                    SV.gphSortMode = m.val
                    if f.UpdateGPHSortIcon then f:UpdateGPHSortIcon() end
                    if RefreshGPHUI then f._refreshImmediate = true; RefreshGPHUI() end
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end

    local titleBar = CreateFrame("Button", nil, f)
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)

    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
    titleBar:RegisterForClicks("RightButtonUp")
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        if f._isDragging then return end -- frame may have started drag; only one handler runs
        f._isDragging = true
        f:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        if not f._isDragging then return end
        f._isDragging = nil
        f:StopMovingOrSizing()
        Addon.SaveFrameLayout(f, "gphShown", "gphPoint")
    end)
    titleBar:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            UIDropDownMenu_Initialize(gphMenu, GPHTitleMenu_Initialize, "MENU")
            ToggleDropDownMenu(1, nil, gphMenu, "cursor", 0, 0)
        end
    end)
    f.gphTitleBar = titleBar

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    ApplyGphInventoryTitle(title)
    f.gphTitle = title

    local GPH_BTN_W, GPH_BTN_H = 36, 18
    local GPH_BTN_GAP = 2

    -- (Bank opens via right-click banker; no title-bar Bank button — user opens bank at NPC, we show our frame on BANKFRAME_OPENED)

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

    -- Inventory container: secure keybind toggles this; OnShow shows either GPH (out of combat) or combat grid (in combat).
    -- Parent to keybindOwner so SecureHandlerSetFrameRef gets a valid handle (same hierarchy as secure button).
    local container = CreateFrame("Frame", "FugaziBAGS_InventoryContainer", keybindOwner)
    container:SetSize(1, 1)
    container:SetPoint("BOTTOMLEFT", keybindOwner, "BOTTOMLEFT", -10000, -10000)
    container:Hide()
    container:SetScript("OnShow", function()
        local forceGrid = GetPerChar("gphForceGridView", false)
        local wantGrid = GetPerChar("gphGridMode", false)
        local cg = _G.FugaziBAGS_CombatGrid
        local inCombat = InCombatLockdown and InCombatLockdown()
        if not inCombat then f:Show() end
        f.gphGridMode = (inCombat or forceGrid or wantGrid)
        if f.gphGridMode and cg and cg.ShowInFrame then
            cg.ShowInFrame(f)
        else
            if cg and cg.HideInFrame then cg.HideInFrame(f) end
        end
    end)
    container:SetScript("OnHide", function()
        local cg = _G.FugaziBAGS_CombatGrid
        if cg and cg.HideInFrame then cg.HideInFrame(f) end
        local inCombat = InCombatLockdown and InCombatLockdown()
        -- In combat the SecureHandler already hid f; skip insecure f:Hide().
        if not inCombat then f:Hide() end
    end)
    _G.FugaziBAGS_InventoryContainer = container
    f.gphInventoryContainer = container

    -- Proxy frame: syncs visibility with container for non-secure open (e.g. /gph).
    local proxy = CreateFrame("Frame", nil, UIParent)
    proxy:SetSize(1, 1)
    proxy:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    proxy:Hide()
    proxy:SetScript("OnShow", function() container:Show() end)
    proxy:SetScript("OnHide", function() container:Hide() end)
    f.gphProxyFrame = proxy

    -- Secure bag toggle: SecureHandlerClickTemplate runs its _onclick snippet in
    -- secure (restricted) Lua, so it can Show/Hide f even though f has protected
    -- children (ContainerFrameItemButtonTemplate grid buttons).  The bag keybind
    -- is redirected here via SetOverrideBindingClick so it works in combat.
    -- Only f is toggled from restricted Lua; the container is synced from f's
    -- OnShow/OnHide hooks (insecure but container is non-protected).
    local secureToggle = CreateFrame("Button", "FugaziBAGS_SecureBagToggle", UIParent, "SecureHandlerClickTemplate")
    secureToggle:SetSize(1, 1)
    secureToggle:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    secureToggle:RegisterForClicks("AnyUp")
    secureToggle:Show()
    SecureHandlerSetFrameRef(secureToggle, "gphframe", f)
    secureToggle:SetAttribute("_onclick", [[
        local f = self:GetFrameRef("gphframe")
        if not f then return end
        if f:IsShown() then
            f:Hide()
        else
            f:Show()
        end
    ]])
    f.gphSecureToggle = secureToggle

    -- Sync container visibility from f's OnShow/OnHide (insecure context, non-protected container).
    local _syncingVisibility = false
    f:HookScript("OnShow", function()
        if _syncingVisibility then return end
        _syncingVisibility = true
        if container and not container:IsShown() then container:Show() end
        _syncingVisibility = false
    end)
    f:HookScript("OnHide", function()
        if _syncingVisibility then return end
        _syncingVisibility = true
        if container and container:IsShown() then container:Hide() end
        _syncingVisibility = false
    end)

    local function ApplyBagKeyOverrides()
        if InCombatLockdown and InCombatLockdown() then return end
        ClearOverrideBindings(secureToggle)
        local key1, key2 = GetBindingKey("TOGGLEBACKPACK")
        if key1 then SetOverrideBindingClick(secureToggle, false, key1, "FugaziBAGS_SecureBagToggle") end
        if key2 then SetOverrideBindingClick(secureToggle, false, key2, "FugaziBAGS_SecureBagToggle") end
        local ok1, ok2 = GetBindingKey("OPENALLBAGS")
        if ok1 then SetOverrideBindingClick(secureToggle, false, ok1, "FugaziBAGS_SecureBagToggle") end
        if ok2 then SetOverrideBindingClick(secureToggle, false, ok2, "FugaziBAGS_SecureBagToggle") end
    end
    f.ApplyBagKeyOverrides = ApplyBagKeyOverrides
    ApplyBagKeyOverrides()

    -- Close (rightmost): LMB = close. Order left-to-right: ... sort, toggle, close. (Collapse removed.)
    local function UpdateGPHCollapse()
        if not f.scrollFrame then return end
        local inCombat = InCombatLockdown and InCombatLockdown()
        if not inCombat and not f.gphGridMode then
            local wantW = f.gphGridFrameW or f:GetWidth() or 340
            local wantH = f.gphGridFrameH or f.EXPANDED_HEIGHT or 400
            f.gphForceHeight = wantH
            f.gphForceHeightFrames = 8
            local p = f:GetParent()
            local r, t = f:GetRight(), f:GetTop()
            f:ClearAllPoints()
            f:SetPoint("TOPRIGHT", p, "BOTTOMLEFT", r, t)
            f:SetSize(wantW, wantH)
        end
        f.statusText:Show()
        f.gphSep:Show()
        if f.gphSearchBtn then f.gphSearchBtn:Show() end
        if f.gphSearchEditBox then
            if f.gphSearchBarVisible then f.gphSearchEditBox:Show() else f.gphSearchEditBox:Hide() end
        end
        if f.gphHeader then f.gphHeader:Show() end
        if f.gphGridMode and f.gphGridContent then
            f.scrollFrame:Hide()
            if f.gphScrollBar then f.gphScrollBar:Hide() end
            f.gphGridContent:Show()
            local cg = _G.FugaziBAGS_CombatGrid
            if cg and cg.LayoutGrid then cg.LayoutGrid() end
        else
            f.scrollFrame:Show()
        end
        if f.gphBottomBar then
            f.gphBottomBar:ClearAllPoints()
            f.gphBottomBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
            f.gphBottomBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        end
        if f.gphCloseBtn then f.gphCloseBtn:Show() end
        if f.UpdateGPHButtonVisibility then f:UpdateGPHButtonVisibility() end
    end
    f.UpdateGPHCollapse = UpdateGPHCollapse
    -- UpdateGPHCollapse() -- Moved to end of function after button creation


    -- UTILITY BUTTONS REMOVED PER USER REQUEST. ONLY DESTROY/MAIL REMAIN.
    local function UpdateGPHButtonVisibility()
        if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
    end
    f.UpdateGPHButtonVisibility = UpdateGPHButtonVisibility


    -- One-click destroy: SecureActionButton macro; PreClick sets macrotext to /cast Spell + /use bag slot.
    if DB.gphDestroyPreferProspect == nil then DB.gphDestroyPreferProspect = false end

    -- Parent to titleBar so it anchors relative to the top area correctly.
    local destroyBtn = CreateFrame("Button", nil, titleBar, "SecureActionButtonTemplate")
    destroyBtn:SetSize(22, 22) --DESTROY BUTTON SIZE

    destroyBtn:SetPoint("LEFT", titleBar, "LEFT", 0, 0)

    destroyBtn:SetFrameStrata("DIALOG")
    destroyBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    destroyBtn:EnableMouse(true)
    destroyBtn:SetHitRectInsets(0, 0, 0, 0)
    destroyBtn:RegisterForClicks("AnyUp")
    destroyBtn:SetAttribute("type1", "macro")
    destroyBtn:SetAttribute("macrotext1", "")
    local destroyBg = destroyBtn:CreateTexture(nil, "BACKGROUND")
    destroyBg:SetAllPoints()
    destroyBg:SetTexture(0, 0, 0, 0) -- No background box
    destroyBtn.bg = destroyBg
    local destroyIcon = destroyBtn:CreateTexture(nil, "OVERLAY", nil, 7)
    destroyIcon:SetAllPoints(destroyBtn)
    destroyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Crop borders to unify size
    destroyIcon:SetAlpha(1.0)
    destroyBtn.icon = destroyIcon

    local function UpdateDestroyButtonAppearance()
        local hasDE = Addon.IsSpellKnownByName("Disenchant")
        local hasProspect = Addon.IsSpellKnownByName("Prospecting")
        
        local preferProspect = DB.gphDestroyPreferProspect and hasProspect and hasDE
        local iconPath
        
        if (hasProspect and not hasDE) or preferProspect then
            -- Prospecting: Specific texture requested by user
            iconPath = "Interface\\Icons\\inv_misc_gem_bloodgem_01"
        else
            -- Disenchant / Rod: Specific texture requested by user
            iconPath = "Interface\\Icons\\Inv_rod_enchantedfelsteel"
        end

        if iconPath then
            destroyIcon:SetTexture(iconPath)
            destroyIcon:Show()
            destroyBtn:Show()
            destroyBtn:SetAlpha(0.6)
            -- If we don't actually know the profession, desaturate to indicate 'utility' vs 'action'
            if not hasDE and not hasProspect then
                destroyIcon:SetDesaturated(true)
                destroyIcon:SetVertexColor(0.8, 0.8, 0.8, 0.8)
            else
                destroyIcon:SetDesaturated(false)
                destroyIcon:SetVertexColor(1, 1, 1, 1)
            end
        else
            destroyIcon:Hide()
            destroyBtn:Hide()
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
        local preferProspect = DB.gphDestroyPreferProspect
        local bag, slot, spellName = Addon.GetFirstDestroyableInBags(preferProspect)
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
        GameTooltip:AddLine("Destroy", 0.9, 0.8, 0.5)
        GameTooltip:Show()
    end
    destroyBtn:SetScript("OnEnter", function()
        local SV = _G.FugaziBAGSDB
        local skin = SV and SV.gphSkin or "original"
        if skin ~= "pimp_purple" then
            if f.gphTitleBarBtnHover then destroyBtn.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else destroyBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.9) end
        else
            destroyBtn.bg:SetTexture(nil)
        end
        destroyIcon:SetAlpha(1)
        ShowDestroyTooltip()
    end)
    destroyBtn:SetScript("OnLeave", function()
        local SV = _G.FugaziBAGSDB
        local skin = SV and SV.gphSkin or "original"
        if skin ~= "pimp_purple" then
            if f.gphTitleBarBtnNormal then destroyBtn.bg:SetTexture(unpack(f.gphTitleBarBtnNormal)) else destroyBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7) end
        else
            destroyBtn.bg:SetTexture(nil)
        end
        destroyIcon:SetAlpha(0.8)
        GameTooltip:Hide()
    end)
    destroyBtn:SetScript("PostClick", function()
        if Addon.PlayClickSound then Addon.PlayClickSound() end
    end)
    f.gphDestroyBtn = destroyBtn
    f.UpdateDestroyButtonAppearance = UpdateDestroyButtonAppearance
    f.UpdateDestroyMacro = function() end

    -- One-click Get All Mail: Loots mailbox until 1 slot remains.
    local mailBtn = CreateFrame("Button", nil, titleBar)
    mailBtn:SetSize(22, 22) --MAIL BUTTON SIZE

    mailBtn:SetFrameStrata("DIALOG")
    mailBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    mailBtn:EnableMouse(true)
    mailBtn:RegisterForClicks("LeftButtonUp")
    local mailBg = mailBtn:CreateTexture(nil, "BACKGROUND")
    mailBg:SetAllPoints()
    mailBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    mailBtn.bg = mailBg
    local mailIcon = mailBtn:CreateTexture(nil, "ARTWORK")
    mailIcon:SetAllPoints(mailBtn)
    mailIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Crop borders to unify size
    mailIcon:SetTexture("Interface\\Icons\\inv_letter_09")
    mailBtn.icon = mailIcon

    -- Force update icon when switching mail tabs
    if MailFrameTab1 then
        hooksecurefunc("PanelTemplates_SetTab", function(frame, id)
            if frame == MailFrame and f.UpdateGPHProfessionButtons then
                f:UpdateGPHProfessionButtons()
            end
        end)
    end


    local isLootingMail = false
    local lastMailLootTime = 0
    local mailLootWorker = CreateFrame("Frame", nil, f)
    mailLootWorker:SetScript("OnUpdate", function(self, elapsed)
        if not isLootingMail then return end
        lastMailLootTime = (lastMailLootTime or 0) + elapsed
        if lastMailLootTime < 0.1 then return end
        lastMailLootTime = 0

        -- Check total free slots in bags 0-4
        local free = 0
        for bag = 0, 4 do
            free = free + (GetContainerNumFreeSlots(bag) or 0)
        end
        if free <= 1 then
            print("|cffff0000[FugaziBAGS]|r Mail looting stopped: 1 slot remaining.")
            isLootingMail = false
            return
        end

        local num = GetInboxNumItems()
        for i = 1, num do
            local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
            if (cod or 0) <= 0 then
                if hasItem then
                    -- Worst-case attachment count: assume each attachment could take a new slot.
                    local attachments = 0
                    local maxAtt = (_G.ATTACHMENTS_MAX_RECEIVE or 12)
                    for ai = 1, maxAtt do
                        local name = GetInboxItem(i, ai)
                        if name then attachments = attachments + 1 end
                    end
                    local needed = attachments
                    if free - needed >= 1 then
                        AutoLootMailItem(i)
                        return
                    end
                    -- Not enough room to safely take this mail and still leave 1 free slot; skip it and look at others.
                elseif money > 0 then
                    -- Money doesn't use bag slots; always safe to take while we're running.
                    TakeInboxMoney(i)
                    return
                end
            end
        end
        print("|cff00ff00[FugaziBAGS]|r Finished looting mail.")
        isLootingMail = false
    end)

    mailBtn:SetScript("OnClick", function()
        local isSendTab = (MailFrame.selectedTab == 2)
        if isSendTab then
            local recipient = SendMailNameEditBox:GetText()
            if not recipient or recipient == "" then
                print("|cffff0000[FugaziBAGS]|r Please enter a recipient first.")
                return
            end
            StaticPopup_Show("GPH_CONFIRM_MAIL_ALL", recipient)
        else
            if isLootingMail then
                isLootingMail = false
                print("|cffff0000[FugaziBAGS]|r Mail looting cancelled.")
            else
                isLootingMail = true
                lastMailLootTime = 0
                print("|cff00ff00[FugaziBAGS]|r Starting mail loot...")
            end
        end
    end)
    mailBtn:SetScript("OnEnter", function()
        local isSendTab = (MailFrame.selectedTab == 2)
        GameTooltip:SetOwner(mailBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        if isSendTab then
            GameTooltip:AddLine("Send All Items", 0.9, 0.8, 0.4)
            GameTooltip:AddLine("Sends every item in your bags to current recipient.", 0.6, 0.6, 0.6, true)
            GameTooltip:AddLine("Skips Hearthstone, Quest, and Protected items.", 1, 0.2, 0.2, true)
        else
            GameTooltip:AddLine("Get All Mail", 0.9, 0.8, 0.4)
            GameTooltip:AddLine("Quickly loots attachments and money.", 0.6, 0.6, 0.6, true)
            GameTooltip:AddLine("Stops when only 1 bag slot remains.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
        if f.gphTitleBarBtnHover then mailBtn.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else mailBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
    end)
    mailBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        if f.gphTitleBarBtnNormal then mailBtn.bg:SetTexture(unpack(f.gphTitleBarBtnNormal)) else mailBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.4) end
        mailIcon:SetAlpha(0.6)
        GameTooltip:Hide()
    end)
    f.gphMailBtn = mailBtn

    -- Initial state: controlled by UpdateGPHProfessionButtons
    mailBtn:Hide()
    destroyBtn:Hide()

    local function UpdateGPHProfessionButtons()
        local hideAll = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphHideTopButtons
        local hideDestroy = GetPerChar("gphHideDestroyBtn", false)
        local hasProspect = Addon.IsSpellKnownByName("Prospecting")
        local hasDE = Addon.IsSpellKnownByName("Disenchant")
        local isAtMail = (MailFrame and MailFrame:IsShown())
        local canDestroy = (hasDE or hasProspect)

        local lastBtn = nil
        local anchorToLeft = true

        -- Only show Destroy button if this character has Enchanting or Jewelcrafting, and user has not hidden it.
        if not hideDestroy and canDestroy then
            f.gphDestroyBtn:SetSize(22, 22)
            f.gphDestroyBtn:ClearAllPoints()
            f.gphDestroyBtn:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
            f.gphDestroyBtn:Show()
            f.gphDestroyBtn:SetAlpha(1)
            lastBtn = f.gphDestroyBtn
            anchorToLeft = false
            UpdateDestroyButtonAppearance()
            if f.UpdateDestroyMacro then f.UpdateDestroyMacro() end
        else
            f.gphDestroyBtn:Hide()
            lastBtn = nil
            anchorToLeft = true
        end

        
        -- Reset anchor for mail button
        if f.gphMailBtn then
            if isAtMail then
                local isSendTab = (MailFrame.selectedTab == 2)
                if isSendTab then
                    f.gphMailBtn.icon:SetTexture("Interface\\Icons\\inv_letter_19", true)
                else
                    f.gphMailBtn.icon:SetTexture("Interface\\Icons\\inv_letter_09", true)
                end

                
                f.gphMailBtn:SetSize(22, 22) -- Force size every update
                f.gphMailBtn:ClearAllPoints()
                if anchorToLeft then
                    f.gphMailBtn:SetPoint("LEFT", titleBar, "LEFT", 4, 0) -- Vertically centered
                else
                    f.gphMailBtn:SetPoint("LEFT", lastBtn, "RIGHT", 4, 0) -- 4px gap
                end

                f.gphMailBtn:Show()
                f.gphMailBtn:SetAlpha(0.6)
                f.gphMailBtn:EnableMouse(true)
                lastBtn = f.gphMailBtn

            else
                f.gphMailBtn:Hide()
                f.gphMailBtn:SetAlpha(0)
                f.gphMailBtn:EnableMouse(false)
            end
        end
    end
    f.UpdateGPHProfessionButtons = UpdateGPHProfessionButtons
    -- Moved to end of CreateGPHFrame
    -- UpdateGPHProfessionButtons()


    -- Top bar: when session active, timer/gold/gph on the right (Gold / Timer / GPH)
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetJustifyH("RIGHT")
    f.statusText = statusText
    statusText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -25, -45)

    -- GPH Search: same style as frame (gold/amber), filter items in current session
    local gphSearchBtn = CreateFrame("Button", nil, f)
    gphSearchBtn:EnableMouse(true)
    gphSearchBtn:SetHitRectInsets(0, 0, 0, 0)
    gphSearchBtn:SetSize(36, 20)
    gphSearchBtn:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 3, -8)




    local gphSearchBtnBg = gphSearchBtn:CreateTexture(nil, "BACKGROUND")
    gphSearchBtnBg:SetAllPoints()
    gphSearchBtnBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    gphSearchBtn.bg = gphSearchBtnBg
    local gphSearchLabel = gphSearchBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gphSearchLabel:SetPoint("CENTER")
    gphSearchLabel:SetText("Search")
    gphSearchLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
    gphSearchLabel:SetTextColor(0.92, 0.82, 0.55, 1)
    f.gphSearchBtn = gphSearchBtn
    f.gphSearchLabel = gphSearchLabel
    gphSearchBtn:SetScript("OnClick", function()
        if Addon.PlayClickSound then Addon.PlayClickSound() end
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
    gphSearchBtn:SetScript("OnEnter", function(self)
        if Addon.PlayHoverSound then Addon.PlayHoverSound() end
        local parent = self:GetParent()
        if parent.gphSearchBtnHover then
            if parent._gphHeaderBgFile and self.bg then
                self.bg:SetTexture(parent._gphHeaderBgFile)
                self.bg:SetVertexColor(unpack(parent.gphSearchBtnHover))
            else
                self.bg:SetTexture(unpack(parent.gphSearchBtnHover))
            end
        else
            self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
        end
    end)
    gphSearchBtn:SetScript("OnLeave", function(self)
        local parent = self:GetParent()
        if parent.gphSearchBtnNormal then
            if parent._gphHeaderBgFile and self.bg then
                self.bg:SetTexture(parent._gphHeaderBgFile)
                self.bg:SetVertexColor(unpack(parent.gphSearchBtnNormal))
            else
                self.bg:SetTexture(unpack(parent.gphSearchBtnNormal))
            end
        else
            self.bg:SetTexture(0.1, 0.3, 0.15, 0.7)
        end
    end)

    local gphSearchEditBox = CreateFrame("EditBox", nil, f)
    gphSearchEditBox:SetHeight(20)
    gphSearchEditBox:SetPoint("LEFT", gphSearchBtn, "RIGHT", 6, 0)
    gphSearchEditBox:SetPoint("RIGHT", f, "TOPRIGHT", -8, 0) -- Vertical anchoring is via LEFT anyway if height is same

    gphSearchEditBox:SetAutoFocus(false)
    gphSearchEditBox:SetFontObject("GameFontHighlightSmall")
    gphSearchEditBox:SetTextInsets(6, 4, 0, 0)
    gphSearchEditBox:Hide()
    local gphSearchBg = gphSearchEditBox:CreateTexture(nil, "BACKGROUND")
    gphSearchBg:SetAllPoints()
    gphSearchBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    gphSearchBg:SetVertexColor(0.12, 0.1, 0.06)
    gphSearchBg:SetAlpha(0.95)
    gphSearchEditBox:SetScript("OnEnter", function() if Addon.PlayHoverSound then Addon.PlayHoverSound() end end)
    gphSearchEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
        f.gphSearchText = ""
        f.gphSearchBarVisible = false
        self:Hide()
        RefreshGPHUI()
    end)
    -- Typing feedback: per-keystroke sounds
    gphSearchEditBox:SetScript("OnChar", function()
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphClickSound ~= false and PlaySoundFile then
            PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg")
        end
    end)
    -- Backspace detection via text length (more reliable than key name across clients).
    gphSearchEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphClickSound ~= false and PlaySoundFile then
            PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg") --can change with new .ogg files just rename here if needed
        end
    end)
    gphSearchEditBox:SetScript("OnTextChanged", function(self)
        local old = f.gphSearchText or ""
        f.gphSearchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        -- If text shrank, treat as delete/backspace and play hover sound.
        if #f.gphSearchText < #old then
            local SV = _G.FugaziBAGSDB
            if SV and SV.gphClickSound ~= false and PlaySoundFile then
                PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\hover.ogg")
            end
        end
        if f.gphGridMode and _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.ApplySearch then
            _G.FugaziBAGS_CombatGrid.ApplySearch(f.gphSearchText)
        end
        RefreshGPHUI()
        if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then RefreshBankUI() end
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

    -- Fixed header (bag + rarity row); matches Search horizontally (align with its container/separator)
    local gphHeader = CreateFrame("Frame", nil, f)
    gphHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    gphHeader:SetPoint("TOPRIGHT", sep, "TOPRIGHT", 0, -4)
    gphHeader:SetHeight(14)
    f.gphHeader = gphHeader

    -- Bag space display (used/total); also a drop target for "first free slot" when holding an item
    local gphBagSpaceBtn = CreateFrame("Button", nil, gphHeader)
    gphBagSpaceBtn:SetSize(36, 14)
    gphBagSpaceBtn:EnableMouse(true)
    gphBagSpaceBtn:RegisterForDrag("LeftButton")
    gphBagSpaceBtn:SetFrameLevel(gphHeader:GetFrameLevel() + 20)  -- on top of other header elements so drop is received
    gphBagSpaceBtn:SetHitRectInsets(0, 0, 0, 0)
    local bagSpaceBg = gphBagSpaceBtn:CreateTexture(nil, "BACKGROUND")
    bagSpaceBg:SetAllPoints()
    bagSpaceBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    gphBagSpaceBtn.bg = bagSpaceBg
    local bagSpaceFs = gphBagSpaceBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bagSpaceFs:SetPoint("CENTER")
    bagSpaceFs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
    bagSpaceFs:SetTextColor(0.92, 0.82, 0.55, 1)
    gphBagSpaceBtn.fs = bagSpaceFs
    -- Glow when cursor has item (drop target highlight)
    local bagSpaceGlow = gphBagSpaceBtn:CreateTexture(nil, "OVERLAY")
    bagSpaceGlow:SetAllPoints()
    bagSpaceGlow:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    bagSpaceGlow:SetVertexColor(1, 0.85, 0.2, 0.5)
    bagSpaceGlow:SetBlendMode("ADD")
    bagSpaceGlow:Hide()
    gphBagSpaceBtn.glow = bagSpaceGlow
    local function placeCursorInFirstFreeSlot()
        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                if not (GetContainerItemLink and GetContainerItemLink(bag, slot)) then
                    if PickupContainerItem then PickupContainerItem(bag, slot) end
                    f._refreshImmediate = true
                    if RefreshGPHUI then RefreshGPHUI() end
                    return true
                end
            end
        end
        return false
    end
    gphBagSpaceBtn:SetScript("OnReceiveDrag", function(self)
        placeCursorInFirstFreeSlot()
    end)
    -- Fallback: some clients don't deliver OnReceiveDrag when dropping from our list; handle LeftButtonUp with item on cursor
    gphBagSpaceBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    gphBagSpaceBtn:SetScript("OnClick", function(self, button)
        if IsControlKeyDown() and button == "LeftButton" then
            if not f.gphGridMode then
                SetPerChar("gphGridMode", true)
                SetPerChar("gphBankGridMode", true)
                local cg = _G.FugaziBAGS_CombatGrid
                if cg and cg.ShowInFrame then cg.ShowInFrame(f) end
            else
                if _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.ToggleBagBar then
                    _G.FugaziBAGS_CombatGrid.ToggleBagBar()
                end
            end
            if RefreshGPHUI then RefreshGPHUI() end
            return
        end

        if button ~= "LeftButton" then return end
        if Addon.PlayClickSound then Addon.PlayClickSound() end
        if GetCursorInfo and GetCursorInfo() == "item" then
            placeCursorInFirstFreeSlot()
        end
    end)
    gphBagSpaceBtn:SetScript("OnEnter", function(self)
        if Addon.PlayHoverSound then Addon.PlayHoverSound() end
        if GetCursorInfo and GetCursorInfo() == "item" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Drop to place in first free Bag Slot")
            GameTooltip:Show()
        else
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Drop Space", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Ctrl+LMB: Manage Bags & Keys (Grid Mode).", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end
    end)
    gphBagSpaceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.gphBagSpaceBtn = gphBagSpaceBtn

    function f:ToggleKeyringFrame()
        self._keyringForcedShown = not (self._keyringForcedShown == true)
        -- print("|cff00aaff[__FugaziBAGS]|r Keyring toggle:", self._keyringForcedShown)
        
        if self.LayoutGrid then 
            self:LayoutGrid() 
        elseif _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.LayoutGrid then
            _G.FugaziBAGS_CombatGrid.LayoutGrid()
        end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end

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
    gphBottomRight:SetText(GetMoney and Addon.FormatGold(GetMoney()) or "")

    gphBottomBar:EnableMouse(true)
    gphBottomBar:SetScript("OnEnter", function(self)
        local ok, v, a = pcall(ComputeVendorAuctionTotalsSync)
        if not ok then v, a = 0, 0 end
        v = v or 0
        a = a or 0
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Inventory Value", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("Vendor: " .. (Addon.FormatGold and Addon.FormatGold(v) or tostring(v)), 0.6, 0.9, 0.6)
        GameTooltip:AddLine("Auction: " .. (Addon.FormatGold and Addon.FormatGold(a) or tostring(a)), 0.6, 0.9, 0.6)
        GameTooltip:Show()
    end)
    gphBottomBar:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerGPHScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", gphHeader, "BOTTOMLEFT", 0, -14) -- Pushed down from -6
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 20)
    f.scrollFrame = scrollFrame
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end
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
        if f.HideGPHUseOverlay then f.HideGPHUseOverlay(f) end
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

    -- Negotiation Engine: ensure inventory and bank match sizes based on contents.
    -- Moved out of OnUpdate to prevent movement lag.
    f.NegotiateSizes = function(self)
        if not DB then return end
        local bW, bH, iW, iH
        
        local cg = _G.FugaziBAGS_CombatGrid
        -- GRID MODE sizes for Inventory
        if self.gphGridMode then
            iW = self.gphGridFrameW or self:GetWidth()
            iH = self.gphGridFrameH or self:GetHeight()
        elseif cg and cg.ComputeFrameSize then
            iW, iH = cg.ComputeFrameSize(false)
        else
            iW = 340
            iH = self.EXPANDED_HEIGHT or 400
        end
        
        local finalW, finalH = iW, iH
        
        local bank = _G.TestBankFrame
        if bank and bank:IsShown() then
            if bank.gphGridMode then
                bW = bank.gphGridFrameW or bank:GetWidth()
                bH = bank.gphGridFrameH or bank:GetHeight()
            elseif cg and cg.ComputeFrameSize then
                bW, bH = cg.ComputeFrameSize(true)
            else
                bW = 340
                bH = 400
            end
            finalW = math_max(bW or 0, iW or 0)
            finalH = math_max(bH or 0, iH or 0)
            
            if bank:GetWidth() ~= finalW then bank:SetWidth(finalW) end
            if bank:GetHeight() ~= finalH then bank:SetHeight(finalH) end
        end
        
        if self:GetWidth() ~= finalW then self:SetWidth(finalW) end
        if self:GetHeight() ~= finalH then self:SetHeight(finalH) end
    end

    f.gphSelectedItemId = nil
    f.gphSelectedItemLink = nil
    local gph_elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        if self._combatExitTime and not (InCombatLockdown and InCombatLockdown()) then
            if (GetTime() - self._combatExitTime) >= 90 then
                self._combatExitTime = nil
                local container = _G.FugaziBAGS_InventoryContainer
                local cg = _G.FugaziBAGS_CombatGrid
                if container and container:IsShown() and self.gphGridMode and not GetPerChar("gphForceGridView", false) and not GetPerChar("gphGridMode", false) then
                local oldRight = self:GetRight()
                local oldTop = self:GetTop()
                self.gphGridMode = false
                if cg and cg.HideInFrame then cg.HideInFrame(self) end
                self._refreshImmediate = true
                if RefreshGPHUI then RefreshGPHUI() end
                if self.UpdateGPHCollapse then self.UpdateGPHCollapse() end
                if oldRight and oldTop then
                    self:ClearAllPoints()
                    self:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", oldRight, oldTop)
                end
            end
            if self.ApplyBagKeyOverrides then self.ApplyBagKeyOverrides() end
        end
    end

    if self._gridNeedsHeaderRefresh then
            self._gridNeedsHeaderRefresh = nil
            if self.gphGridMode and RefreshGPHUI then self._refreshImmediate = true; RefreshGPHUI() end
        end
        if not self._isDragging then
            self._throttleT = (self._throttleT or 0) + elapsed
            if self._throttleT >= 0.1 then
                self._throttleT = 0
                self:NegotiateSizes()
                
                -- Bag space as drop target: glow + numbers turn white when cursor has an item
                if self.gphBagSpaceBtn then
                    local hasItem = (GetCursorInfo and GetCursorInfo() == "item")
                    if self.gphBagSpaceBtn.glow then
                        if hasItem then self.gphBagSpaceBtn.glow:Show() else self.gphBagSpaceBtn.glow:Hide() end
                    end
                    if self.gphBagSpaceBtn.fs then
                        if hasItem then self.gphBagSpaceBtn.fs:SetTextColor(1, 1, 1, 1)
                        elseif self.gphAccentTextColor then self.gphBagSpaceBtn.fs:SetTextColor(unpack(self.gphAccentTextColor))
                        else self.gphBagSpaceBtn.fs:SetTextColor(1, 0.85, 0.4, 1) end
                    end
                end

                -- Throttle content position sync: keep content position in sync with our scroll offset
                local sf = self.scrollFrame
                local c = sf and sf:GetScrollChild()
                if c and sf then
                    local v = self.gphScrollOffset or 0
                    local maxScroll = math_max(0, (c:GetHeight() or 0) - sf:GetHeight())
                    if v > maxScroll then v = maxScroll; self.gphScrollOffset = v end
                    c:ClearAllPoints()
                    c:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, v)
                    c:SetWidth(SCROLL_CONTENT_WIDTH)
                end
            end
        end
        gph_elapsed = gph_elapsed + elapsed
        if gph_elapsed >= 0.5 then
            gph_elapsed = 0
            local now = time()
            -- Clear selection after 10s without second right-click; hide overlay so it doesn't stick
            if self.gphSelectedItemId and (now - (self.gphSelectedTime or 0) > 10) then
                self.gphSelectedItemId = nil
                self.gphSelectedIndex = nil
                self.gphSelectedRowBtn = nil
                self.gphSelectedItemLink = nil
                if self.HideGPHUseOverlay then self.HideGPHUseOverlay(self) end
            end
            -- In combat, BAG_UPDATE is often delayed until combat ends; poll every 1s so new loot shows up
            if InCombatLockdown and InCombatLockdown() then
                self.gphCombatRefreshElapsed = (self.gphCombatRefreshElapsed or 0) + elapsed
                if self.gphCombatRefreshElapsed >= 1 then
                    self.gphCombatRefreshElapsed = 0
                    if RefreshGPHUI then RefreshGPHUI() end
                end
            else
                self.gphCombatRefreshElapsed = 0
            end
            -- Tick timer/gold/GPH. Formula in ComputeGPHTotalValue (raw gold + vendor poor + 85%% auction common+).
            local gphSession = _G.gphSession
            if gphSession and self.statusText then
                self.statusText:Show()
                local dur = now - gphSession.startTime
                local liveGold = (GetMoney and GetMoney()) and (GetMoney() - gphSession.startGold) or 0
                if liveGold < 0 then liveGold = 0 end
                local totalValue = ComputeGPHTotalValue(gphSession, liveGold)
                local gph = dur > 0 and (totalValue / (dur / 3600)) or 0
                if (self._lastDur ~= dur or self._lastGold ~= liveGold or self._lastGPH ~= gph) then
                    self._lastDur = dur; self._lastGold = liveGold; self._lastGPH = gph
                    local goldStr = Addon.FormatGold(liveGold)
                    local timerStr = Addon.FormatTimeMedium(dur)
                    local gphStr = Addon.FormatGold(math.floor(gph))
                    self.statusText:SetText(
                        "|cffdaa520Gold:|r " .. goldStr
                        .. "   |cffdaa520Timer:|r |cffffffff" .. timerStr .. "|r"
                        .. "   |cffdaa520GPH:|r " .. gphStr
                    )
                end
            end
            Addon.RefreshItemDetailLive()
            -- Bottom bar: FPS left, time center, gold right (latency/ms removed - not reliable on this client)
            if self.gphBottomLeft and self.gphBottomCenter and self.gphBottomRight then
                local fps = (GetFramerate and GetFramerate()) or 0
                self.gphBottomLeft:SetText(("%.0f FPS"):format(fps))
                if date then self.gphBottomCenter:SetText(date("%H:%M")) end
                self.gphBottomRight:SetText(GetMoney and Addon.FormatGold(GetMoney()) or "")
            end
        end
    end)

    ApplyGPHFrameSkin(f)
    f.ApplySkin = function() ApplyGPHFrameSkin(f) end
    
    f:HookScript("OnHide", function()
        if f.gphSearchEditBox then
            f.gphSearchEditBox:SetText("")
            f.gphSearchText = ""
            f.gphSearchBarVisible = false
            f.gphSearchEditBox:Hide()
            if _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.ApplySearch then
                _G.FugaziBAGS_CombatGrid.ApplySearch("")
            end
        end
    end)
    
    -- Final visibility and layout pass after all buttons created
    UpdateGPHButtonVisibility()
    UpdateGPHCollapse()
    if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
    
    return f
end


----------------------------------------------------------------------
-- Bank window: ElvUI-style (grid of slots, close).
----------------------------------------------------------------------
--- Figures out which "bag ID" is the main bank (varies by WoW version: BANK_CONTAINER, -1, 5, etc.).
local function GetBankMainContainer()
	if BANK_CONTAINER ~= nil then
		local n = GetContainerNumSlots and GetContainerNumSlots(BANK_CONTAINER)
		if n and n > 0 then return BANK_CONTAINER end
	end
	for _, id in ipairs({ -1, -2, 5 }) do
		local n = GetContainerNumSlots and GetContainerNumSlots(id)
		if n and n > 0 then return id end
	end
	if _G.TestBankFrame and _G.TestBankFrame:IsShown() then
		return (BANK_CONTAINER ~= nil) and BANK_CONTAINER or 5
	end
	return nil
end

-- Bank layout: main bank has 28 slots (7 columns x 4 rows in default UI); we list them in one column.
local MAIN_BANK_SLOTS = 28
local NUM_BANK_BAGS = NUM_BANKBAGSLOTS or 6  -- Purchased bank bag slots (e.g. 6 extra bags)
local BANK_ROW_HEIGHT = 18   -- Height of one row in the bank list (icon + name + count)
local BANK_LIST_WIDTH = 296  -- Width of the scroll area (matches inventory list)
local BANK_HEADER_HEIGHT = 18  -- Match inventory bag space row height (36x18) so bank looks identical
local BANK_DEBUG = false  -- Set true to print bank debug lines to chat.
--- Prints a bank debug message to chat only if BANK_DEBUG is true (for troubleshooting).
local function BankDebug(msg) if BANK_DEBUG and Addon.AddonPrint then Addon.AddonPrint("[Bank] " .. msg) end end

--- Destroy one bank slot (for delete X double-click). No destroy list.
local function DeleteBankSlot(bagID, slotID)
	if bagID == nil or slotID == nil then return end
	if PickupContainerItem and DeleteCursorItem then
		PickupContainerItem(bagID, slotID)
		DeleteCursorItem()
	end
end

-- Row pool for bank list (one row per slot: icon + name + count, like inventory)
local BANK_ROW_POOL, BANK_ROW_POOL_USED = {}, 0
--- Hides all bank rows and resets the pool so the next refresh reuses them (no new frames created).
local function ResetBankRowPool()
	for i = 1, BANK_ROW_POOL_USED do
		if BANK_ROW_POOL[i] then BANK_ROW_POOL[i]:Hide() end
	end
	BANK_ROW_POOL_USED = 0
end

-- Data table recycling for bank to prevent memory leaks (similar to GPH inventory)
local BANK_AGG_POOL, BANK_AGG_POOL_USED = {}, 0
local BANK_ITEM_POOL, BANK_ITEM_POOL_USED = {}, 0

--- Gets a recycled table for aggregated bank data (itemId -> count); prevents garbage from repeated scans.
local function GetBankAggTable()
    BANK_AGG_POOL_USED = BANK_AGG_POOL_USED + 1
    local t = BANK_AGG_POOL[BANK_AGG_POOL_USED]
    if not t then t = {}; BANK_AGG_POOL[BANK_AGG_POOL_USED] = t end
    wipe(t)
    return t
end

--- Gets a recycled table for one bank item's data (link, count, etc.); prevents garbage.
local function GetBankItemTable()
    BANK_ITEM_POOL_USED = BANK_ITEM_POOL_USED + 1
    local t = BANK_ITEM_POOL[BANK_ITEM_POOL_USED]
    if not t then t = {}; BANK_ITEM_POOL[BANK_ITEM_POOL_USED] = t end
    wipe(t)
    return t
end

--- Resets the bank agg/item table pools so the next scan reuses them (called at start of each bank refresh).
local function ResetBankDataPools()
    BANK_AGG_POOL_USED = 0
    BANK_ITEM_POOL_USED = 0
end
local BANK_DELETE_X_WIDTH = 16
--- Gets or creates one bank list row (icon, name, count, red X); rows are pooled to avoid creating hundreds of frames.
local function GetBankRow(parent)
	BANK_ROW_POOL_USED = BANK_ROW_POOL_USED + 1
	local row = BANK_ROW_POOL[BANK_ROW_POOL_USED]
	if not row then
		row = CreateFrame("Frame", nil, parent)
		row:SetWidth(BANK_LIST_WIDTH)
		row:SetHeight(BANK_ROW_HEIGHT)
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self) if self.deleteBtn then self.deleteBtn:Show() end end)
		row:SetScript("OnLeave", function(self)
			if not self:IsMouseOver() and self.deleteBtn then
				self.deleteBtn:Hide()
			end
		end)
		local delBtn = CreateFrame("Button", nil, row)
		delBtn:SetSize(14, 14)
		delBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
		delBtn:EnableMouse(true)
		delBtn:SetHitRectInsets(0, 0, 0, 0)
		delBtn:SetNormalFontObject(GameFontNormalSmall)
		delBtn:SetHighlightFontObject(GameFontHighlightSmall)
		delBtn:SetText("|cffff4444x|r")
		if delBtn.GetFontString then
			local fs = delBtn:GetFontString()
			if fs and fs.SetFont then fs:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE") end
		end
		row.deleteBtn = delBtn
		local clickArea = CreateFrame("Button", nil, row)
		clickArea:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
		clickArea:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		clickArea:SetHeight(BANK_ROW_HEIGHT)
		clickArea:EnableMouse(true)
		clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		clickArea:RegisterForDrag("LeftButton")
		clickArea:SetHitRectInsets(0, 0, 0, 0)
		clickArea:SetText("")
		row.clickArea = clickArea
		local icon = clickArea:CreateTexture(nil, "ARTWORK")
		icon:SetSize(16, 16)
		icon:SetPoint("LEFT", clickArea, "LEFT", 0, 0)
		row.icon = icon
		-- Full-row dark overlay used to visually mark protected bank items (same idea as inventory list).
		local protectedOverlay = clickArea:CreateTexture(nil, "OVERLAY")
		protectedOverlay:SetAllPoints(clickArea)
		protectedOverlay:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		protectedOverlay:SetVertexColor(0, 0, 0, 0.38)
		protectedOverlay:Hide()
		row.protectedOverlay = protectedOverlay
		local countFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		countFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
		countFs:SetJustifyH("RIGHT")
		row.countFs = countFs
		local nameFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		nameFs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
		nameFs:SetPoint("RIGHT", clickArea, "RIGHT", -40, 0)
		nameFs:SetJustifyH("LEFT")
		row.nameFs = nameFs
		local hl = clickArea:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		hl:SetVertexColor(1, 1, 1, 0.1)
		row.hl = hl

		local pulse = clickArea:CreateTexture(nil, "OVERLAY", nil, 7)
		pulse:SetAllPoints()
		pulse:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		pulse:SetVertexColor(1, 1, 1, 0.45)
		pulse:Hide()
		row.pulseTex = pulse

		BANK_ROW_POOL[BANK_ROW_POOL_USED] = row
	end
	row:SetParent(parent)
	-- Update row width to match current bank frame width
	local bf = _G.TestBankFrame
	if bf and bf._bankListW then row:SetWidth(bf._bankListW) end
	row:Show()
	row.clickArea:Show()
	if row.deleteBtn then row.deleteBtn:Show() end
	if row.pulseTex then row.pulseTex:Hide() end
	return row
end

--- Creates the bank window (list of bank slots, same style as inventory). Shown when you open the bank NPC.
function CreateBankFrame(invFrame)
	local existing = _G.TestBankFrame
	if existing and existing.content then
		return existing
	end
	_G.TestBankFrame = nil

	local backdrop = {
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile     = true, tileSize = 32, edgeSize = 24,
		insets   = { left = 2, right = 6, top = 6, bottom = 6 },
	}
	-- Do NOT use name "TestBankFrame" here: WoW would set _G.TestBankFrame = f immediately,
	-- so RefreshBankUI could run (from another event) before we set f.content and see nil.
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetWidth(340)
	f:SetHeight(400)
	f:Hide()
	f:SetBackdrop(backdrop)
	f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
	f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function()
		if f._isDragging then return end
		f._isDragging = true
		f:StartMoving()
	end)
	f:SetScript("OnDragStop", function()
		if not f._isDragging then return end
		f._isDragging = nil
		f:StopMovingOrSizing()
		local inv = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
		if inv and inv.NegotiateSizes then inv:NegotiateSizes() end
	end)
	f:SetFrameStrata("DIALOG")
	f:SetFrameLevel(10)
    
    -- NOTE: size sync with inventory is merged into the main OnUpdate below (search bankSpaceBtn)

	local function placeCursorInFirstFreeBankSlot()
		local mainBank = (GetBankMainContainer and GetBankMainContainer()) or -1
		if mainBank == nil then return false end
		for slot = 1, (GetContainerNumSlots(mainBank) or 28) do
			if not (GetContainerItemLink and GetContainerItemLink(mainBank, slot)) then
				if PickupContainerItem then PickupContainerItem(mainBank, slot) end
				if RefreshBankUI then RefreshBankUI() end
				return true
			end
		end
		for i = 1, (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6) do
			local bagID = (NUM_BAG_SLOTS or 4) + i
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
			for slot = 1, numSlots do
				if not (GetContainerItemLink and GetContainerItemLink(bagID, slot)) then
					if PickupContainerItem then PickupContainerItem(bagID, slot) end
					if RefreshBankUI then RefreshBankUI() end
					return true
				end
			end
		end
		return false
	end

	-- Dropdown menu for bank title right-click
	local bankMenu = CreateFrame("Frame", "FugaziBAGS_BankMenu", f, "UIDropDownMenuTemplate")
	local function BankTitleMenu_Initialize(self, level)
		local info = UIDropDownMenu_CreateInfo()
		local SV = _G.FugaziBAGSDB
		if not level or level == 1 then
            -- Close button as requested (red "Close" at top)
            info = UIDropDownMenu_CreateInfo()
            info.text = "|cffff4444Close Bank|r"
            info.func = function()
                if _G.TestBankFrame and _G.TestBankFrame:IsShown() then
                    _G.TestBankFrame:Hide()
                    if CloseBank then CloseBank() end
                end
                CloseDropDownMenus()
            end
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)

			info = UIDropDownMenu_CreateInfo()
			info.text = "Sort"
			info.hasArrow = true
			info.value = "SORT_BANK"
			info.notCheckable = true
			UIDropDownMenu_AddButton(info)

			-- 2. Consolidate
			info = UIDropDownMenu_CreateInfo()
			-- Consolidate
			info = UIDropDownMenu_CreateInfo()
			info.text = "Clean up Bank"
			info.func = function()
				if GPH_BagSort_Run and GetBankMainContainer then
					local mainBank = GetBankMainContainer()
					local list = { mainBank }
					for i = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6) do 
                        list[#list + 1] = i 
                    end
					GPH_BagSort_Run(function()
						if RefreshBankUI then RefreshBankUI() end
						local cg = _G.FugaziBAGS_CombatGrid
						if cg and cg.BankLayoutGrid then cg.BankLayoutGrid() end
					end, "bank", list)
				end
				CloseDropDownMenus()
			end
			info.notCheckable = true
			UIDropDownMenu_AddButton(info)

            -- View modes for bank (only if Force Bank Grid is off)
            local bankForceGrid = GetPerChar("gphBankForceGridView", false)
            local inCombat = InCombatLockdown and InCombatLockdown()
            if not bankForceGrid then
                info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)
                local bankGridMode = GetPerChar("gphBankGridMode", false)
                info = UIDropDownMenu_CreateInfo()
                if inCombat then
                    info.text = "List View (in combat: grid only)"
                    info.disabled = true
                else
                    info.text = (not f.gphGridMode) and "|cff00ff00List View|r" or "List View"
                end
                info.checked = not f.gphGridMode
                info.func = function()
                    if InCombatLockdown and InCombatLockdown() then return end
                    SetPerChar("gphBankGridMode", false)
                    f.gphGridMode = false
                    local cg = _G.FugaziBAGS_CombatGrid
                    if cg and cg.HideInBankFrame then cg.HideInBankFrame(f) end
                    if RefreshBankUI then RefreshBankUI() end
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info)

                info = UIDropDownMenu_CreateInfo()
                info.text = f.gphGridMode and "|cff00ff00Grid View|r" or "Grid View"
                info.checked = f.gphGridMode
                info.func = function()
                    SetPerChar("gphBankGridMode", true)
                    f.gphGridMode = true
                    local cg = _G.FugaziBAGS_CombatGrid
                    if cg and cg.ShowInBankFrame then cg.ShowInBankFrame(f) end
                    if RefreshBankUI then RefreshBankUI() end
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info)
            end

		elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "SORT_BANK" then
			local modes = {
				{ val = "rarity", text = "Rarity" },
				{ val = "vendor", text = "Vendorprice" },
				{ val = "itemlevel", text = "ItemLvl" },
				{ val = "category", text = "Category" },
			}
			for _, m in ipairs(modes) do
				info = UIDropDownMenu_CreateInfo()
				info.text = m.text
				info.checked = (SV.gphSortMode == m.val)
				info.func = function()
					SV.gphSortMode = m.val
					if f.UpdateBankSortIcon then f:UpdateBankSortIcon() end
					if RefreshBankUI then RefreshBankUI() end
					CloseDropDownMenus()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
	end

	-- Title bar (same style as GPH)
	local titleBar = CreateFrame("Button", nil, f)
	titleBar:SetHeight(30)
	titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
	titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
	titleBar:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	titleBar:SetBackdropColor(0.35, 0.28, 0.1, 0.7)
	titleBar:RegisterForClicks("RightButtonUp")
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function()
        if f._isDragging then return end
        f._isDragging = true
        f:StartMoving()
    end)
	titleBar:SetScript("OnDragStop", function()
        if not f._isDragging then return end
        f._isDragging = nil
		f:StopMovingOrSizing()
		local inv = _G.FugaziBAGS_GPHFrame or _G.TestGPHFrame
		if inv and inv.NegotiateSizes then inv:NegotiateSizes() end
		Addon.SaveFrameLayout(f, "frameShown", "framePoint")
	end)
	titleBar:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			UIDropDownMenu_Initialize(bankMenu, BankTitleMenu_Initialize, "MENU")
			ToggleDropDownMenu(1, nil, bankMenu, "cursor", 0, 0)
		end
	end)
	f.titleBar = titleBar
	local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
	title:SetText((UnitName and UnitName("target")) or "Bank")
	title:SetTextColor(1, 0.85, 0.4, 1)
	f.bankTitleText = title

	-- Utility buttons (Close, Purchase, Sort) have been COMPLETELY deleted per user request.
	local titleFrameLevel = f:GetFrameLevel() + 25

	local sep = f:CreateTexture(nil, "ARTWORK")
	sep:SetHeight(1)
	sep:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 10, -6)
	sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
	sep:SetTexture(1, 1, 1, 0.15)
	f.sep = sep


	-- Bank bag row (6 small buttons) — below separator; draw above scroll so list doesn’t overlap
	local bagRow = CreateFrame("Frame", nil, f)
	bagRow:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 6, -6)
	bagRow:SetPoint("TOPRIGHT", sep, "TOPRIGHT", -6, -6)
	bagRow:SetHeight(0)
	bagRow:SetFrameLevel(f:GetFrameLevel() + 30)
	bagRow:EnableMouse(false)  -- let child buttons receive clicks
	f.bagRow = bagRow
	f.bagRowVisible = false
	bagRow:SetAlpha(0)
	bagRow:Hide()
	f.bagSlots = {}
	for i = 1, NUM_BANK_BAGS do
		local bagID = (NUM_BAG_SLOTS or 4) + i
		local btn = CreateFrame("Button", ("TestBankBag%d"):format(i), bagRow)
		btn:SetSize(20, 20)
		-- No SetNormalTexture: it can render as a solid grey box in 3.3.5. Use our own slot bg so icon stays on top (ElvUI-style).
		btn:SetNormalTexture("")
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
		local slotBg = btn:CreateTexture(nil, "BACKGROUND")
		slotBg:SetAllPoints()
		local currentSkin = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original"
		if currentSkin == "original" then
			slotBg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
		else
			slotBg:SetTexture(nil)
		end
		slotBg:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		if slotBg.SetDesaturated then slotBg:SetDesaturated(1) end
		slotBg:SetVertexColor(0.5, 0.5, 0.55, 0.1)
		local icon = btn:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		btn.icon = icon
		btn.bagID = bagID
		btn:SetPoint("LEFT", bagRow, "LEFT", (i - 1) * 24, 0)
		btn:EnableMouse(true)
		btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		btn:RegisterForDrag("LeftButton")
		btn:SetScript("OnClick", function(self, button)
			if Addon.PlayClickSound then Addon.PlayClickSound() end
			local cursorType = GetCursorInfo and GetCursorInfo()
			if cursorType == "item" and PutItemInBag and ContainerIDToInventoryID and self.bagID then
				local invID = ContainerIDToInventoryID(self.bagID)
				if invID and invID > 0 then PutItemInBag(invID) end
			elseif not cursorType or cursorType == "" then
				-- Empty cursor: pick up bag from this bank bag slot (like default UI)
				local invID = self.bagID and ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
				if invID and invID > 0 and PickupInventoryItem then
					PickupInventoryItem(invID)
				end
			end
			if RefreshBankUI then RefreshBankUI() end
		end)
		btn:SetScript("OnDragStart", function(self)
			local cursorType = GetCursorInfo and GetCursorInfo()
			if not cursorType or cursorType == "" then
				local invID = self.bagID and ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
				if invID and invID > 0 and PickupInventoryItem then
					PickupInventoryItem(invID)
				end
			end
		end)
		btn:SetScript("OnEnter", function(self)
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(self.bagID) or 0
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Bank bag " .. i .. (numSlots > 0 and (" (" .. numSlots .. " slots)") or " (not purchased)"))
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.bagSlots[i] = btn
	end

	-- Bank header (bag space + rarity): anchored to sep with FIXED offset so list/rarity never move when bag bar toggles
	-- Reserve space for bag row: gap 6 + bar 20 + gap 4 = 30 below sep
	f.bankRarityFilter = nil
	local BANK_HEADER_Y_OFF = -(6 + 20 + 4)  -- fixed; bag row sits in this space when visible
	local bankHeader = CreateFrame("Frame", nil, f)
	bankHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 6, BANK_HEADER_Y_OFF)
	bankHeader:SetPoint("TOPRIGHT", sep, "TOPRIGHT", -6, BANK_HEADER_Y_OFF)
	bankHeader:SetHeight(BANK_HEADER_HEIGHT)
	f.bankHeader = bankHeader
	local bankSpaceBtn = CreateFrame("Button", nil, bankHeader)
	bankSpaceBtn._bankFrame = f
	bankSpaceBtn:SetSize(36, BANK_HEADER_HEIGHT)
	bankSpaceBtn:SetPoint("LEFT", bankHeader, "LEFT", 0, 0)
	bankSpaceBtn:EnableMouse(true)
	bankSpaceBtn:RegisterForDrag("LeftButton")
	bankSpaceBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	bankSpaceBtn:SetFrameLevel(bankHeader:GetFrameLevel() + 20)
	bankSpaceBtn:SetHitRectInsets(0, 0, 0, 0)
    local bankSpaceBg = bankSpaceBtn:CreateTexture(nil, "BACKGROUND")
    bankSpaceBg:SetAllPoints()
    -- Match inventory green instead of gold
    bankSpaceBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    bankSpaceBtn.bg = bankSpaceBg
    
    bankSpaceBtn:SetScript("OnClick", function(self, button)
		if button ~= "LeftButton" then return end
		if Addon.PlayClickSound then Addon.PlayClickSound() end
		-- Ctrl+LMB toggles the bag bar
		if IsControlKeyDown() then
			if f.bagRow then
				f.bagRowVisible = not f.bagRowVisible
				local BANK_BAG_ROW_H = 20
				if f.bagRowVisible then
					f.bagRow:SetHeight(BANK_BAG_ROW_H)
					f.bagRow:SetAlpha(1)
					f.bagRow:Show()
				else
					f.bagRow:SetHeight(0)
					f.bagRow:SetAlpha(0)
					f.bagRow:Hide()
				end
				if RefreshBankUI then RefreshBankUI() end
			end
			return
		end

		-- Plain LMB drops item on cursor into first free slot
		if GetCursorInfo and GetCursorInfo() == "item" then
			placeCursorInFirstFreeBankSlot()
			return
		end
	end)
	bankSpaceBtn:SetScript("OnEnter", function(self)
        if Addon.PlayHoverSound then Addon.PlayHoverSound() end
        local bf = self._bankFrame
        if self.bg then
            if bf and bf.bankSpaceBtnNormalFile and bf.bankSpaceBtnHover then
                self.bg:SetTexture(bf.bankSpaceBtnNormalFile)
                self.bg:SetVertexColor(unpack(bf.bankSpaceBtnHover))
            else
                self.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
            end
        end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if GetCursorInfo and GetCursorInfo() == "item" then
			GameTooltip:SetText("Drop to place in first free Bank Slot")
		else
			GameTooltip:SetText("Bank space / Dropspace")
			GameTooltip:AddLine("Ctrl+LMB: Toggle bank bags", 0.6, 0.6, 0.6)
			GameTooltip:AddLine("LMB: Place item in first free slot", 0.6, 0.6, 0.6)
		end
		GameTooltip:Show()
	end)
	bankSpaceBtn:SetScript("OnLeave", function(self)
        local bf = self._bankFrame
        if self.bg then
            if bf and bf.bankSpaceBtnNormalFile and bf.bankSpaceBtnNormal then
                self.bg:SetTexture(bf.bankSpaceBtnNormalFile)
                self.bg:SetVertexColor(unpack(bf.bankSpaceBtnNormal))
            else
                self.bg:SetTexture(0.1, 0.3, 0.15, 0.7)
            end
        end
		GameTooltip:Hide()
	end)
	local bankSpaceFs = bankSpaceBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bankSpaceFs:SetPoint("CENTER")
	bankSpaceFs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
	bankSpaceFs:SetTextColor(1, 0.85, 0.4, 1)
	bankSpaceBtn.fs = bankSpaceFs
	-- Gold glow when cursor has item (drop target)
    local bankSpaceGlow = bankSpaceBtn:CreateTexture(nil, "OVERLAY")
    bankSpaceGlow:SetAllPoints()
    bankSpaceGlow:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    -- Default gold glow; ApplyBankFrameSkin will override for ElvUI skins.
    bankSpaceGlow:SetVertexColor(1, 0.85, 0.2, 0.5)
	bankSpaceGlow:SetBlendMode("ADD")
	bankSpaceGlow:Hide()
	bankSpaceBtn.glow = bankSpaceGlow
	-- helper moved up to ensure it is in scope for the button script

	-- Return (bankBagId, bankSlotId) for first free slot, or (nil, nil). Used for Postal-style multi-stack move in one go.
	local function getFirstFreeBankSlot()
		local mainBank = GetBankMainContainer()
		if not mainBank then return nil, nil end
		for slot = 1, MAIN_BANK_SLOTS do
			local _, _, locked = GetContainerItemInfo(mainBank, slot)
			if not (GetContainerItemLink and GetContainerItemLink(mainBank, slot)) and not locked then
				return mainBank, slot
			end
		end
		for i = 1, NUM_BANK_BAGS do
			local bagID = (NUM_BAG_SLOTS or 4) + i
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
			for slot = 1, numSlots do
				local _, _, locked = GetContainerItemInfo(bagID, slot)
				if not (GetContainerItemLink and GetContainerItemLink(bagID, slot)) and not locked then
					return bagID, slot
				end
			end
		end
		return nil, nil
	end
	-- First free slot in player bags 0-4 (for bank→bags move)
	local function getFirstFreeBagSlot()
		for bag = 0, 4 do
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
			if numSlots then
				for slot = 1, numSlots do
					local _, _, locked = GetContainerItemInfo(bag, slot)
					if not (GetContainerItemLink and GetContainerItemLink(bag, slot)) and not locked then
						return bag, slot
					end
				end
			end
		end
		return nil, nil
	end
	-- All bank slots containing itemId (main bank + bank bags), optional known slot first
	local function getAllBankSlotsForItem(itemId, knownBankBag, knownBankSlot)
		itemId = tonumber(itemId) or itemId
		if not itemId then return {} end
		local list = {}
		local function addSlot(bagID, slotID, count)
			list[#list + 1] = { bag = bagID, slot = slotID, count = (count and count > 0) and count or 1 }
		end
		local function getCount(bagID, slotID)
			if not GetContainerItemInfo then return 1 end
			local t1, t2, t3, t4, t5 = GetContainerItemInfo(bagID, slotID)
			if type(t2) == "number" and t2 > 0 then return t2 end
			if type(t3) == "number" and t3 > 0 then return t3 end
			if type(t4) == "number" and t4 > 0 then return t4 end
			if type(t5) == "number" and t5 > 0 then return t5 end
			return 1
		end
		if knownBankBag ~= nil and knownBankSlot ~= nil then
			local tex = GetContainerItemInfo and select(1, GetContainerItemInfo(knownBankBag, knownBankSlot))
			if tex then addSlot(knownBankBag, knownBankSlot, getCount(knownBankBag, knownBankSlot)) end
		end
		local mainBank = GetBankMainContainer()
		if mainBank then
			for slot = 1, MAIN_BANK_SLOTS do
				if knownBankBag == mainBank and knownBankSlot == slot then else
					local tex = GetContainerItemInfo and select(1, GetContainerItemInfo(mainBank, slot))
					if tex then
						local id = (GetContainerItemID and GetContainerItemID(mainBank, slot)) or nil
						if not id and GetContainerItemLink then
							local link = GetContainerItemLink(mainBank, slot)
							if link then id = tonumber(link:match("item:(%d+)")) end
						end
						if id and tonumber(id) == tonumber(itemId) then addSlot(mainBank, slot, getCount(mainBank, slot)) end
					end
				end
			end
		end
		for i = 1, NUM_BANK_BAGS do
			local bagID = (NUM_BAG_SLOTS or 4) + i
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
			for slot = 1, numSlots do
				if knownBankBag == bagID and knownBankSlot == slot then else
					local tex = GetContainerItemInfo and select(1, GetContainerItemInfo(bagID, slot))
					if tex then
						local id = (GetContainerItemID and GetContainerItemID(bagID, slot)) or nil
						if not id and GetContainerItemLink then
							local link = GetContainerItemLink(bagID, slot)
							if link then id = tonumber(link:match("item:(%d+)")) end
						end
						if id and tonumber(id) == tonumber(itemId) then addSlot(bagID, slot, getCount(bagID, slot)) end
					end
				end
			end
		end
		return list
	end
	f.PlaceCursorInFirstFreeBankSlot = placeCursorInFirstFreeBankSlot
	f.GetFirstFreeBankSlot = getFirstFreeBankSlot
	f.GetFirstFreeBagSlot = getFirstFreeBagSlot
	f.GetAllBankSlotsForItem = getAllBankSlotsForItem
	bankSpaceBtn:SetScript("OnReceiveDrag", function() placeCursorInFirstFreeBankSlot() end)
	f.bankSpaceFs = bankSpaceFs
	f.bankSpaceBtn = bankSpaceBtn
	-- Bank space as drop target: glow + numbers turn white when cursor has an item
	f:SetScript("OnUpdate", function(self)
		if not self:IsShown() then return end
		-- Cursor glow (drop target highlight)
		if self.bankSpaceBtn then
			local hasItem = (GetCursorInfo and GetCursorInfo() == "item")
			if self.bankSpaceBtn.glow then
				if hasItem then self.bankSpaceBtn.glow:Show() else self.bankSpaceBtn.glow:Hide() end
			end
			if self.bankSpaceBtn.fs then
				if hasItem then
					self.bankSpaceBtn.fs:SetTextColor(1, 1, 1, 1)
				else
					local c = self.bankSpaceTextColor or { 1, 0.85, 0.4, 1 }
					self.bankSpaceBtn.fs:SetTextColor(c[1], c[2], c[3], c[4])
				end
			end
		end
	end)
	-- Same layout as GPH: bag 36, gap 12, rarity buttons min width 24, spacing 4
	local leftPad, bagW, bagGap, spacing, numRarityBtns = 0, 36, 12, 4, 5
	local headerW = (f:GetWidth() or 340) - 14
	local qualityRight = headerW - 14
	local startX = leftPad + bagW + bagGap
	local rarityTotalW = qualityRight - startX
	local slotW = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
	if slotW < 24 then slotW = 24 end
	-- Filter selected = brighter bg only (no white border; that's for "lock rarity" in inventory)
	local function UpdateBankQualBtnVisual(bf, btn, q)
		if not btn or not btn.bg then return end
		local info = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]) or { r = 0.5, g = 0.5, b = 0.5 }
		local r, g, b = info.r or 0.5, info.g or 0.5, info.b or 0.5
		local alpha = 0.35
		if bf.bankRarityFilter == q then
			r = math.min(1, r * 2.2)
			g = math.min(1, g * 2.2)
			b = math.min(1, b * 2.2)
			alpha = 0.95
		end
		-- Thick-border rarity style only when the bank frame is actually using the Original skin
		-- (never for ElvUI / Pimp Purple, and not controlled by header customization).
		local Skins = _G.__FugaziBAGS_Skins
		local useOriginalRarity = bf and bf._useOriginalRarityStyle and bf._originalMainBorder and bf._originalTitleBg and Skins and Skins.AddRarityBorder
		if btn.SetBackdrop then btn:SetBackdrop(nil) end
		if btn._rarityBorderFrame then btn._rarityBorderFrame:Hide(); btn._rarityBorderFrame:SetBackdrop(nil) end
		if btn._rarityBorderTop then btn._rarityBorderTop:Hide() end
		if btn._rarityBorderBottom then btn._rarityBorderBottom:Hide() end
		if btn._rarityBorderLeft then btn._rarityBorderLeft:Hide() end
		if btn._rarityBorderRight then btn._rarityBorderRight:Hide() end
		if btn._borderTop then btn._borderTop:Hide() end
		if btn._borderBottom then btn._borderBottom:Hide() end
		if btn._borderLeft then btn._borderLeft:Hide() end
		if btn._borderRight then btn._borderRight:Hide() end
		if useOriginalRarity then
			local tb = bf._originalTitleBg
			local br = math.min(1, (tb[1] or 0.35) * 0.6 + r * 0.4)
			local bg = math.min(1, (tb[2] or 0.28) * 0.6 + g * 0.4)
			local bb = math.min(1, (tb[3] or 0.1) * 0.6 + b * 0.4)
			-- Stronger fill when this rarity is the active bank filter so it's clearly visible.
			local isSelectedFilter = (bf.bankRarityFilter == q)
			local fillAlpha = isSelectedFilter and 0.95 or 0.72
			if isSelectedFilter then
				br = math.min(1, br * 1.5)
				bg = math.min(1, bg * 1.5)
				bb = math.min(1, bb * 1.5)
			end
			-- Inset the colored fill slightly so it never bleeds under the textured border.
			btn.bg:ClearAllPoints()
			btn.bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
			btn.bg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
			btn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
			btn.bg:SetVertexColor(br, bg, bb, fillAlpha)
			Skins.AddRarityBorder(btn, bf._originalMainBorder, bf._originalEdgeFile, bf._originalEdgeSize)
			if btn.hl then btn.hl:SetVertexColor(1, 1, 1, 0.12) end
		else
			-- Non-original skins: flat fill that matches the full button size.
			btn.bg:ClearAllPoints()
			btn.bg:SetAllPoints()
			btn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
			btn.bg:SetVertexColor(r, g, b, alpha)
			if btn.hl then btn.hl:SetVertexColor(1, 1, 1, 0.30) end
		end
	end
	f.UpdateBankQualBtnVisual = UpdateBankQualBtnVisual

	f.bankQualityButtons = {}
	local rarityLabels = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
	for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
		local qualBtn = CreateFrame("Button", nil, bankHeader)
		qualBtn:SetSize(slotW, BANK_HEADER_HEIGHT)
		qualBtn:SetPoint("LEFT", bankHeader, "LEFT", startX + (i - 1) * (slotW + spacing), 0)
		qualBtn:EnableMouse(true)
		qualBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		qualBtn:SetHitRectInsets(0, 0, 0, 0)
		qualBtn.quality = q
		local bg = qualBtn:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		qualBtn.bg = bg
		qualBtn:SetScript("OnClick", function(self, button)
			if Addon.PlayClickSound then Addon.PlayClickSound() end
			local alt  = IsAltKeyDown and IsAltKeyDown()
			local ctrl = IsControlKeyDown and IsControlKeyDown()
			local shift = IsShiftKeyDown and IsShiftKeyDown()

			-- Shift+RMB: move all items of this rarity from bank to bags
			if shift and button == "RightButton" then
				Addon.RarityMoveJob = { mode = "bank_to_bags", rarity = self.quality }
				if Addon.RarityMoveWorker then
					Addon.RarityMoveWorker._t = 0
					Addon.RarityMoveWorker:Show()
				end
				return
			end

			-- No modifiers: LMB toggles filter, RMB clears (matching inventory behavior)
			if button == "LeftButton" and not ctrl and not alt then
				if f.bankRarityFilter == self.quality then
					f.bankRarityFilter = nil
					f.gphFilterQuality = nil
				else
					f.bankRarityFilter = self.quality
					f.gphFilterQuality = self.quality
				end
				-- Refresh the appropriate view
				if f.gphGridMode then
					local cg = _G.FugaziBAGS_CombatGrid
					if cg and cg.BankLayoutGrid then cg.BankLayoutGrid() end
				end
				if RefreshBankUI then RefreshBankUI() end
				return
			end
			if button == "RightButton" and not ctrl and not shift then
				f.bankRarityFilter = nil
				f.gphFilterQuality = nil
				if f.gphGridMode then
					local cg = _G.FugaziBAGS_CombatGrid
					if cg and cg.BankLayoutGrid then cg.BankLayoutGrid() end
				end
				if RefreshBankUI then RefreshBankUI() end
				return
			end
		end)
		qualBtn:SetScript("OnEnter", function(self)
			if Addon.PlayHoverSound then Addon.PlayHoverSound() end
			local info2 = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[self.quality]) or { r = 0.5, g = 0.5, b = 0.5 }
			local r, g, b = (info2.r or 0.5) * 1.2, (info2.g or 0.5) * 1.2, (info2.b or 0.5) * 1.2
			self.bg:SetVertexColor(r, g, b, 0.55)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(rarityLabels[self.quality] or "Rarity")
			GameTooltip:AddLine("LMB: Filter", 0.6, 0.6, 0.6)
			GameTooltip:AddLine("Shift+RMB: Send Rarity to Inventory", 0.6, 0.6, 0.6)
			GameTooltip:Show()
			local bfs = self:GetFontString()
			if bfs then bfs:SetAlpha(1) end
		end)
		qualBtn:SetScript("OnLeave", function(self)
			UpdateBankQualBtnVisual(f, self, self.quality)
			GameTooltip:Hide()
			local bfs = self:GetFontString()
			if bfs then bfs:SetAlpha(0) end
		end)
        local info = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]) or { r = 0.5, g = 0.5, b = 0.5, hex = "888888" }
		bg:SetVertexColor(info.r or 0.5, info.g or 0.5, info.b or 0.5, 0.35)
		qualBtn:SetText("")
		local bfs = qualBtn:GetFontString()
		if bfs then
			bfs:SetAllPoints()
			bfs:SetJustifyH("CENTER")
			bfs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
			bfs:SetAlpha(0)
		end
		
		local hl = qualBtn:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		hl:SetVertexColor(1, 1, 1, 0.30)
		qualBtn.hl = hl
		
		f.bankQualityButtons[q] = qualBtn
	end

	-- Re-layout rarity buttons based on current frame width (called on RefreshBankUI or OnSizeChanged)
	f.LayoutBankQualityButtons = function(self)
		local leftPad2, bagW2, bagGap2, spacing2, numBtns = 0, 36, 12, 4, 5
		local frameW = self:GetWidth() or 340
		-- Symmetry: Frame edge to BagSpace is 18px.
		-- To finish at 18px from right edge: (FrameW - 18).
		-- Since header starts at 18px, target X inside header is: (FrameW - 18) - 18 = FrameW - 36.
		local qualityRight2 = frameW - 36
		local startX2 = leftPad2 + bagW2 + bagGap2
		local rarityTotalW2 = qualityRight2 - startX2
		local slotW2 = math.floor((rarityTotalW2 - spacing2 * (numBtns - 1)) / numBtns)
		if slotW2 < 10 then slotW2 = 10 end
		for i, q2 in ipairs({ 0, 1, 2, 3, 4 }) do
			local qb = self.bankQualityButtons and self.bankQualityButtons[q2]
			if qb then
				qb:SetSize(slotW2, BANK_HEADER_HEIGHT)
				qb:ClearAllPoints()
				qb:SetPoint("LEFT", bankHeader, "LEFT", startX2 + (i - 1) * (slotW2 + spacing2), 0)
			end
		end
	end
    if not bankHeader._fugaziBankLayoutHooked then
        bankHeader._fugaziBankLayoutHooked = true
        bankHeader:HookScript("OnSizeChanged", function() f:LayoutBankQualityButtons() end)
    end

	-- Scrollable list: use same template as GPH (UIPanelScrollFrameTemplate) so scrolling works; we drive offset + content position manually
	f.bankScrollOffset = 0
	local scroll = CreateFrame("ScrollFrame", "TestBankScrollFrame", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", bankHeader, "BOTTOMLEFT", 0, -14) -- Pushed down from -6
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 6)
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scroll)
    end
	local scrollBar = scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"] or nil

	if scrollBar then
		scrollBar:SetScript("OnValueChanged", function(_, value)
			f.bankScrollOffset = value
			local content = scroll:GetScrollChild()
			if content then
				content:ClearAllPoints()
				content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, value)
				content:SetWidth(BANK_LIST_WIDTH)
				content:SetHeight(content:GetHeight() or 1)
			end
		end)
	end
	local content = CreateFrame("Frame", nil, scroll)
	content:SetWidth(BANK_LIST_WIDTH)
	content:SetHeight(1)
	scroll:SetScrollChild(content)
	content:ClearAllPoints()
	content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
	f.content = content
	f.scrollFrame = scroll
	f.scrollBar = scrollBar
	if scrollBar then
		hooksecurefunc(content, "SetHeight", function()
			local viewH = scroll:GetHeight()
			local contentH = content:GetHeight()
			scrollBar:SetMinMaxValues(0, math.max(0, contentH - viewH))
		end)
	end
	local function doScrollWheel(delta)
		local viewH = scroll:GetHeight()
		local contentH = content:GetHeight() or 0
		local maxScroll = math.max(0, contentH - viewH)
		if maxScroll <= 0 then return end
		local cur = f.bankScrollOffset or 0
		local step = 20
		local newScroll = (delta < 0) and math.min(maxScroll, cur + step) or math.max(0, cur - step)
		f.bankScrollOffset = newScroll
		if scrollBar then
			scrollBar:SetMinMaxValues(0, maxScroll)
			scrollBar:SetValue(newScroll)
		end
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, newScroll)
		content:SetWidth(BANK_LIST_WIDTH)
		content:SetHeight(contentH)
	end
	content:SetScript("OnMouseWheel", function(self, delta) doScrollWheel(delta) end)
	scroll:SetScript("OnMouseWheel", function(self, delta) doScrollWheel(delta) end)
	scroll.BankOnMouseWheel = function(delta) doScrollWheel(delta) end
	BankDebug("CreateBankFrame: scroll/content created (UIPanelScrollFrameTemplate)")

	_G.TestBankFrame = f
	ApplyBankFrameSkin(f)
	f.ApplySkin = function() ApplyBankFrameSkin(f) end
	BankDebug("CreateBankFrame: about to RETURN f, f.content=" .. tostring(f.content) .. " _G.TestBankFrame==f? " .. tostring(_G.TestBankFrame == f))
	return f
end

----------------------------------------------------------------------
-- Bank list row: red X (double-click to destroy), click (select/drag), tooltip.
----------------------------------------------------------------------
local function BankRow_deleteBtn_OnClick(self)
    local row = self:GetParent()
				local r = row
				if not r.bagID or not r.slotID then return end
				local now = GetTime and GetTime() or 0
				local key = r.bagID .. "_" .. r.slotID
				if _G.TestBankFrame._bankDeleteClickTime[key] and (now - _G.TestBankFrame._bankDeleteClickTime[key]) <= 0.5 then
					_G.TestBankFrame._bankDeleteClickTime[key] = nil
					if Addon.PlayTrashSound then Addon.PlayTrashSound() end
					DeleteBankSlot(r.bagID, r.slotID)
					if RefreshBankUI then RefreshBankUI() end
				else
					_G.TestBankFrame._bankDeleteClickTime[key] = now
				end
end
local function BankRow_deleteBtn_OnEnter(self)
    local row = self:GetParent()
				self:SetText("|cffff8888x|r")
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText("Double-click to destroy this item")
				GameTooltip:Show()
end
local function BankRow_deleteBtn_OnLeave(self)
    local row = self:GetParent()
    if not row:IsMouseOver() then
        if row.deleteBtn then row.deleteBtn:Hide() end
    end
    self:SetText("|cffff4444x|r")
    GameTooltip:Hide()
end
local function BankRow_deleteBtn_OnMouseWheel(self,  delta)
    local row = self:GetParent()
				if _G.TestBankFrame.scrollFrame and _G.TestBankFrame.scrollFrame.BankOnMouseWheel then _G.TestBankFrame.scrollFrame.BankOnMouseWheel(delta) end
end
local function BankRow_clickArea_OnMouseDown(self, mouseButton)
    local row = self:GetParent()
    if Addon.TriggerRowPulse then Addon.TriggerRowPulse(row) end
    local r = self:GetParent()
			if not r.bagID or not r.slotID then return end
			if mouseButton == "LeftButton" and IsShiftKeyDown() then
				local link = GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
				local totalCount = r.totalCount or (GetContainerItemInfo and select(2, GetContainerItemInfo(r.bagID, r.slotID))) or 1
				if link and totalCount and totalCount > 1 and Addon.ShowGPHStackSplit then
					local itemId = tonumber(link:match("item:(%d+)"))
					if itemId then Addon.ShowGPHStackSplit(r.bagID, r.slotID, totalCount, self, itemId, true) end
					return
				end
			end
end
local function BankRow_clickArea_OnClick(self, button)
    if Addon.PlayClickSound then Addon.PlayClickSound() end
    local r = self:GetParent()
    if not r.bagID or not r.slotID then return end

    -- Shift+RMB: link bank item in chat
    if button == "RightButton" and IsShiftKeyDown() then
        local link = GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
        if link then
            if StackSplitFrame and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
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
                chatBox:Insert(link)
                if chatBox.SetFocus then chatBox:SetFocus() end
            end
        end
        return
    elseif button == "RightButton" and not IsShiftKeyDown() then
        if r.bagID ~= nil and r.slotID ~= nil and UseContainerItem then
            UseContainerItem(r.bagID, r.slotID)
            if RefreshBankUI then RefreshBankUI() end
            if RefreshGPHUI then RefreshGPHUI() end
        end
        if r.pulseTex then
            r.pulseTex:SetVertexColor(1, 1, 1, 0.65)
            r.pulseTex:Show()
            if not r._pulseAnimFrame then
                r._pulseAnimFrame = CreateFrame("Frame")
            end
            r._pulseAnimFrame._t = 0
            r._pulseAnimFrame:SetScript("OnUpdate", function(f, el)
                f._t = f._t + el
                if f._t > 0.3 then r.pulseTex:Hide(); f:SetScript("OnUpdate", nil)
                else r.pulseTex:SetAlpha(0.65 * (1 - f._t/0.3)) end
            end)
        end
        return
    elseif button == "LeftButton" and IsAltKeyDown() then
        if r.bagID ~= nil and r.slotID ~= nil then
            local link = GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
            if link then
                local itemId = tonumber(link:match("item:(%d+)"))
                if itemId and Addon.GetGphProtectedSet then
                    local set = Addon.GetGphProtectedSet()
                    set[itemId] = not set[itemId]
                    if RefreshBankUI then RefreshBankUI() end
                    if RefreshGPHUI then RefreshGPHUI() end
                end
            end
        end
        return
    end
end
local function BankRow_clickArea_OnReceiveDrag(self)
    local r = self:GetParent()
    if GetCursorInfo and GetCursorInfo() == "item" and PickupContainerItem and r.bagID and r.slotID then
        PickupContainerItem(r.bagID, r.slotID)
    end
end
local function BankRow_clickArea_OnMouseUp(self, button)
    if button ~= "LeftButton" then return end
    local r = self:GetParent()
    if not r.bagID or not r.slotID or not PickupContainerItem then return end
    if GetCursorInfo and GetCursorInfo() == "item" then
        PickupContainerItem(r.bagID, r.slotID)
    end
end
local function BankRow_clickArea_OnEnter(self)
    local r = self:GetParent()
    if r.deleteBtn then r.deleteBtn:Show() end
			local b, s = r.bagID, r.slotID
			local link = b and s and GetContainerItemLink and GetContainerItemLink(b, s)
			-- Anchor tooltip to the right of inventory frame (same as inventory tooltips)
			if gphFrame and gphFrame:IsShown() then
				GameTooltip:SetOwner(self, "ANCHOR_NONE")
				GameTooltip:ClearAllPoints()
				GameTooltip:SetPoint("LEFT", gphFrame, "RIGHT", 4, 0)
			else
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			end
			if link then
				if b == -1 then
					local invSlot = (BankButtonIDToInvSlotID and BankButtonIDToInvSlotID(s)) or (38 + s)
					GameTooltip:SetInventoryItem("player", invSlot)
				else
					GameTooltip:SetBagItem(b, s)
				end
				GameTooltip:AddLine(" ")
				local itemId = tonumber(link:match("item:(%d+)"))
				if itemId and Addon.GetGphProtectedSet and Addon.GetGphProtectedSet()[itemId] then
					GameTooltip:AddLine("Protected", 0.4, 0.8, 0.4)
					GameTooltip:AddLine(" ")
				end
				GameTooltip:AddLine("LMB: Pickup  |  RMB: Move to Inventory", 0.6, 0.6, 0.6)
				GameTooltip:AddLine("Alt+LMB: Protect Item", 0.6, 0.6, 0.6)
			else
				GameTooltip:SetText("Empty slot")
			end
			GameTooltip:Show()
end
local function BankRow_clickArea_OnLeave(self)
    local r = self:GetParent()
    if not r:IsMouseOver() then
        if r.deleteBtn then r.deleteBtn:Hide() end
    end
    GameTooltip:Hide()
end
local function BankRow_clickArea_OnMouseWheel(self,  delta)
    if _G.TestBankFrame and _G.TestBankFrame.scrollFrame and _G.TestBankFrame.scrollFrame.BankOnMouseWheel then
        _G.TestBankFrame.scrollFrame.BankOnMouseWheel(delta)
    end
end
RefreshBankUI = function()
	local bf = _G.TestBankFrame
	if not bf then return end
	if not bf:IsShown() then return end
    
    local inv = _G.TestGPHFrame
    if inv and inv.NegotiateSizes then inv:NegotiateSizes() end
	-- Re-layout rarity buttons to match current frame width
	if bf.LayoutBankQualityButtons then bf:LayoutBankQualityButtons() end
	-- Sync bank sort button icon with current display sort mode (same icons as inventory)
	if bf.bankSortBtn and bf.bankSortBtn.icon then
        if bf.gphGridMode then
            bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01")
        else
            local mode = DB.gphSortMode or "rarity"
            if mode == "vendor" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
            elseif mode == "itemlevel" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
            elseif mode == "category" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Chest_Chain_04")
            else bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01") end
        end
	end
	if not bf.content then
		return
	end
	local mainBank = GetBankMainContainer()
	if not mainBank then
		return
	end

	-- Always perform a full bank refresh when asked; BAG_UPDATE/PLAYERBANKSLOTS_CHANGED
	-- are already coalesced at the event layer, so we don't drop the last change.
	local now = (GetTime and GetTime()) or (time and time()) or 0
    -- Debounce: don't refresh more than ~12 times a second unless immediate flag is set
    if not bf._refreshImmediate and bf._lastRefreshBankUI and (now - bf._lastRefreshBankUI) < 0.08 then
        return
    end
	bf._lastRefreshBankUI = now
	bf._refreshImmediate = nil

	ResetBankRowPool()
    ResetBankDataPools()
	-- Compute dynamic row width from scroll frame (not hardcoded BANK_LIST_WIDTH)
	local bankListW = BANK_LIST_WIDTH
	if bf.scrollFrame then
		local sw = bf.scrollFrame:GetWidth()
		if sw and sw > 50 then bankListW = sw - 4 end  -- small padding
	end
	bf._bankListW = bankListW
	local content = bf.content
	if content then content:SetWidth(bankListW) end
	
    local prevWornSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
    local previouslyWornOnlySet = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}

    Addon._bankSlotList = Addon._bankSlotList or {}
    wipe(Addon._bankSlotList)
	local slotList = Addon._bankSlotList
    
	local totalBankSlots, usedBankSlots = 0, 0
    
    Addon._bankQCounts = Addon._bankQCounts or { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
    wipe(Addon._bankQCounts)
    for i=0,4 do Addon._bankQCounts[i]=0 end
	local qCounts = Addon._bankQCounts
    
	-- Aggregate by item type (one row per item, total count), like inventory; first slot used for interaction
    Addon._bankAggregated = Addon._bankAggregated or {}
    wipe(Addon._bankAggregated)
	local aggregated = Addon._bankAggregated
    
	local function scanBankSlot(bagID, slotID)
		totalBankSlots = totalBankSlots + 1
		local link = GetContainerItemLink and GetContainerItemLink(bagID, slotID)
		local texture, stackCount = nil, 0
		if GetContainerItemInfo then
			local t1, t2, t3, t4, t5 = GetContainerItemInfo(bagID, slotID)
			texture = t1
			-- Item count is usually 2nd return; some 3.3.5 clients use different order for bank
			if type(t2) == "number" and t2 > 0 then stackCount = t2
			elseif type(t3) == "number" and t3 > 0 then stackCount = t3
			elseif type(t4) == "number" and t4 > 0 then stackCount = t4
			elseif type(t5) == "number" and t5 > 0 then stackCount = t5
			end
		end
		-- Only default to 1 if we are sure it's valid, but sometimes bank returns nil temporarily
		if link and (stackCount == 0 or not stackCount) then
			-- For Vanilla/TBC/WotLK bank item counts usually need 1 if nil but we will pull max stack if we can later
			-- Actually let's just use what it gave us to ensure it's not permanently stuck as 1
			stackCount = (GetContainerItemInfo and select(2, GetContainerItemInfo(bagID, slotID))) or 1
		end
		stackCount = stackCount or 0
		if not link then
			return
		end
		usedBankSlots = usedBankSlots + 1
		local name, quality, iLevel, tex, sell, itemType = "Unknown", 0, 0, nil, 0, "Other"
		if GetItemInfo then
			name, _, quality, iLevel, _, itemType, _, _, _, tex, sell = GetItemInfo(link)
			name = name or "Unknown"
			quality = (quality and quality >= 0 and quality <= 7) and quality or 0
			itemType = (itemType and itemType ~= "" and itemType) or "Other"
		end
		texture = tex or texture
		local itemId = tonumber(link:match("item:(%d+)"))
		if not itemId then return end

		local isProtected = itemId and (prevWornSet[itemId] or (rarityFlags and quality and rarityFlags[quality]))

		if itemId == 6948 then
			itemType = "HIDDEN_FIRST"
		elseif isProtected then
			itemType = "BAG_PROTECTED"
		else
			local typeCache = DB.gphItemTypeCache
			if type(typeCache) ~= "table" then typeCache = {} DB.gphItemTypeCache = typeCache end
			if not typeCache[itemId] then
				if (not itemType or itemType == "Other") and GetItemInfo then
					local _, _, _, _, _, giType = GetItemInfo(itemId)
					itemType = (giType and giType ~= "" and giType) or "Other"
				end
				typeCache[itemId] = itemType
			end
			itemType = typeCache[itemId]
		end
		if not aggregated[itemId] then
			aggregated[itemId] = GetBankAggTable()
            local a = aggregated[itemId]
            a.firstBagID = bagID
            a.firstSlotID = slotID
            a.totalCount = 0
            a.link = link
            a.name = name
            a.quality = quality
            a.sellPrice = sell or 0
            a.itemLevel = iLevel or 0
            a.texture = texture
            a.itemType = itemType
            a.itemId = itemId
		end
		aggregated[itemId].totalCount = aggregated[itemId].totalCount + stackCount
	end
	for slot = 1, MAIN_BANK_SLOTS do scanBankSlot(mainBank, slot) end
	for i = 1, NUM_BANK_BAGS do
		local bagID = (NUM_BAG_SLOTS or 4) + i
		local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
		for slot = 1, numSlots do scanBankSlot(bagID, slot) end
	end
    
	for _, agg in pairs(aggregated) do
        local isProtected = agg.itemId and (prevWornSet[agg.itemId] or (rarityFlags and agg.quality and rarityFlags[agg.quality]))
        local previouslyWorn = agg.itemId and previouslyWornOnlySet[agg.itemId]
        
        local entry = GetBankItemTable()
        entry.bagID = agg.firstBagID
        entry.slotID = agg.firstSlotID
        entry.link = agg.link
        entry.name = agg.name
        entry.quality = agg.quality
        entry.sellPrice = agg.sellPrice
        entry.itemLevel = agg.itemLevel
        entry.count = agg.totalCount
        entry.texture = agg.texture
        entry.itemType = agg.itemType or "Other"
        entry.isProtected = isProtected and true or nil
        entry.previouslyWorn = previouslyWorn and true or nil
		slotList[#slotList + 1] = entry
	end
	-- Do not add empty slots to the list so they are never shown (user asked to hide them)
	-- for _, es in ipairs(emptySlots) do slotList[#slotList + 1] = es end
	-- Rarity button counts: 5 buttons (0-4); legendary (5) and artifact (6) count as epic (4)
	for q = 0, 4 do qCounts[q] = 0 end
	for _, agg in pairs(aggregated) do
		local q = (agg.quality and agg.quality >= 0 and agg.quality <= 7) and agg.quality or 0
		local btnQ = (q >= 5 and q <= 7) and 4 or q
		qCounts[btnQ] = (qCounts[btnQ] or 0) + (agg.totalCount or 0)
	end
	if bf.bankSpaceFs then bf.bankSpaceFs:SetText(usedBankSlots .. "/" .. totalBankSlots) end
	bf._bankUsedSlots = usedBankSlots
	if ApplyCustomizeToFrame then ApplyCustomizeToFrame(bf) end
	-- Display sort: same as inventory (rarity / vendor / itemlevel / category)
	local sortMode = DB.gphSortMode or "rarity"
	if sortMode == "vendor" then
		table.sort(slotList, GPH_Sort_Vendor)
	elseif sortMode == "itemlevel" then
		table.sort(slotList, GPH_Sort_ItemLevel)
	elseif sortMode == "category" then
		table.sort(slotList, GPH_Sort_CategoryPass)
	else
		table.sort(slotList, GPH_Sort_Rarity)
	end
	-- Rarity filter: epic (4) shows 4, 5, 6; other filters show that quality only
	local filterQ = bf.bankRarityFilter
	if filterQ ~= nil then
		if not Addon._bankFilteredList then Addon._bankFilteredList = {} end
        wipe(Addon._bankFilteredList)
		local filtered = Addon._bankFilteredList
		for _, info in ipairs(slotList) do
			local q = info.quality or 0
			if q == filterQ or (filterQ == 4 and (q == 5 or q == 6 or q == 7)) then filtered[#filtered + 1] = info end
		end
		slotList = filtered
	end
	-- Search filter (same as inventory): when bank is open, use GPH frame search text to filter bank list too
	local inv = gphFrame or _G.TestGPHFrame
	if inv and inv.gphSearchText and inv.gphSearchText ~= "" then
		local searchLower = inv.gphSearchText:lower():match("^%s*(.-)%s*$")
		local exactQuality = nil
		for q = 0, 7 do
			local info = Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]
			if info and info.label and info.label:lower() == searchLower then exactQuality = q; break end
		end
		if not Addon._bankSearchList then Addon._bankSearchList = {} end
        wipe(Addon._bankSearchList)
		local filtered = Addon._bankSearchList
		for _, item in ipairs(slotList) do
			if exactQuality ~= nil then
				if (item.quality or 0) == exactQuality then filtered[#filtered + 1] = item end
			else
				local itemMatches = (item.name and item.name:lower():find(searchLower, 1, true))
				local qualityMatches = false
				for q = 0, 7 do
					local info = Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]
					if info and info.label and info.label:lower():find(searchLower, 1, true) and (item.quality or 0) == q then qualityMatches = true; break end
				end
				if itemMatches or qualityMatches then filtered[#filtered + 1] = item end
			end
		end
		slotList = filtered
	end
	-- When category sort: build draw list with collapsible dividers (same as inventory)
	local bankCategoryDrawList = nil
	if sortMode == "category" and #slotList > 0 then
		if not Addon._bankGroups then Addon._bankGroups = {} end
        wipe(Addon._bankGroups)
		local groups = Addon._bankGroups
		for i, info in ipairs(slotList) do
			local t = info.itemType or "Other"
			if not groups[t] then groups[t] = GetBankItemTable() end
			table.insert(groups[t], info)
		end

		for _, items in pairs(groups) do
			table.sort(items, GPH_Sort_CategoryGroup)
		end
		if not bf.bankCategoryCollapsed then bf.bankCategoryCollapsed = {} end
		if not Addon._bankCategoryDrawList then Addon._bankCategoryDrawList = {} end
        wipe(Addon._bankCategoryDrawList)
		bankCategoryDrawList = Addon._bankCategoryDrawList
		for _, catName in ipairs(GPH_BAG_PROTECTED_CATEGORY_ORDER) do
			if groups[catName] and #groups[catName] > 0 then
				local collapsed = bf.bankCategoryCollapsed[catName]
                local divEntry = GetBankItemTable()
                divEntry.divider = catName
                divEntry.collapsed = collapsed
                
                -- Only add the divider if it's not a "Headerless" special category
                local isHeaderless = (catName == "BAG_PROTECTED" or catName == "HIDDEN_FIRST")
                if not isHeaderless then
    				table.insert(bankCategoryDrawList, divEntry)
                end

				if not collapsed or isHeaderless then
					for _, info in ipairs(groups[catName]) do table.insert(bankCategoryDrawList, info) end
				end
			end
		end
		for catName, items in pairs(groups) do
			local found = false
			for _, c in ipairs(GPH_BAG_PROTECTED_CATEGORY_ORDER) do if c == catName then found = true break end end
			if not found then
				local collapsed = bf.bankCategoryCollapsed[catName]
                local divEntry = GetBankItemTable()
                divEntry.divider = catName
                divEntry.collapsed = collapsed
				table.insert(bankCategoryDrawList, divEntry)
				if not collapsed then
					for _, info in ipairs(items) do table.insert(bankCategoryDrawList, info) end
				end
			end
		end
	end
	-- Update bank rarity buttons: use button's native SetText (reliable in 3.3.5)
	local bankQualityButtons = bf.bankQualityButtons
	if bankQualityButtons and bf.UpdateBankQualBtnVisual then
		for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
			local count = qCounts[q] or 0
			local info = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]) or Addon.QUALITY_COLORS[1] or { hex = "888888" }
			local qualBtn = bankQualityButtons[q]
			if qualBtn then
				bf.UpdateBankQualBtnVisual(bf, qualBtn, q)
				local displayedCount = (count and count > 0) and tostring(count) or ""
				qualBtn:SetText(displayedCount == "" and "" or ("|cff" .. (info.hex or "888888") .. displayedCount .. "|r"))
				local bfs = qualBtn:GetFontString()
				if bfs then
					bfs:SetAllPoints()
					bfs:SetJustifyH("CENTER")
					bfs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
					-- Mouseover logic: alpha handled by OnEnter/OnLeave scripts established in CreateBankFrame
					local isHovered = (GetMouseFocus and GetMouseFocus() == qualBtn)
					bfs:SetAlpha(isHovered and 1 or 0)
				end
			end
		end
	end
	BankDebug("Step 4: slotList count=" .. tostring(#slotList))

	local bankDeleteClickTime = bf._bankDeleteClickTime or {}
	bf._bankDeleteClickTime = bankDeleteClickTime
	bf.bankDefaultScrollY = nil
	-- Re-apply home base scroll on every list refresh (open, rarity filter, sort, collapse) so it stays consistent.
	if not bf.gphGridMode then
		bf.gphScrollToDefaultOnNextRefresh = true
	end
	local yOff = 0
	local listToUse = (sortMode == "category" and bankCategoryDrawList) or slotList
	local bankDividerIndex = 0
	if bf.bankCategoryDividerPool then for _, d in ipairs(bf.bankCategoryDividerPool) do d:Hide() end end
	for idx, entry in ipairs(listToUse) do
		if entry.divider and entry.divider ~= "HIDDEN_FIRST" then
			-- Collapsible category header (same look and behavior as inventory)
			bankDividerIndex = bankDividerIndex + 1
			if not bf.bankCategoryDividerPool then bf.bankCategoryDividerPool = {} end
			local pool = bf.bankCategoryDividerPool
			local div = pool[bankDividerIndex]
			if not div then
				-- Visual header frame (not clickable itself)
				div = CreateFrame("Button", nil, content)
				div:EnableMouse(true)
				local tex = div:CreateTexture(nil, "ARTWORK")
				tex:SetTexture(0.4, 0.35, 0.2, 0.7)
				tex:SetPoint("TOPLEFT", div, "TOPLEFT", 0, 0)
				tex:SetPoint("TOPRIGHT", div, "TOPRIGHT", 0, 0)
				tex:SetHeight(1)
				div.tex = tex
				local label = div:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				label:SetJustifyH("LEFT")
				label:SetFont("Fonts\\ARIALN.TTF", 11, "")
				div.label = label
				-- Small collapse indicator on the LEFT (icon), label to the right
				local toggle = CreateFrame("Frame", nil, div)
				toggle:SetSize(14, 12)
				toggle:SetPoint("BOTTOMLEFT", div, "BOTTOMLEFT", 0, 0)
				local tfs = toggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				tfs:SetPoint("CENTER")
				tfs:SetFont("Fonts\\ARIALN.TTF", 10, "")
				toggle.text = tfs
				-- Icon overlay (uses media/collapse.blp)
				local ti = toggle:CreateTexture(nil, "ARTWORK")
				ti:SetAllPoints()
				ti:SetTexture("Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
				toggle.icon = ti
				div.toggleBtn = toggle
				-- Label just right of toggle; both sit below the line with a gap
				label:ClearAllPoints()
				label:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
				div:SetScript("OnClick", function(self)
					if not bf.bankCategoryCollapsed then bf.bankCategoryCollapsed = {} end
					local cat = self.categoryName
					local isCollapsed = (cat == "DELETE") and (bf.bankCategoryCollapsed["DELETE"] ~= false) or bf.bankCategoryCollapsed[cat]
					bf.bankCategoryCollapsed[cat] = not isCollapsed
					if RefreshBankUI then RefreshBankUI() end
				end)
				div:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetText("Click to collapse/expand")
					GameTooltip:Show()
					if self.categoryName == "DELETE" then
						if self.label then self.label:SetAlpha(0.7) end
						if self.toggleBtn and self.toggleBtn.text then self.toggleBtn.text:SetAlpha(0.7) end
						if self.toggleBtn and self.toggleBtn.icon then self.toggleBtn.icon:SetAlpha(0.7) end
					end
				end)
				div:SetScript("OnLeave", function(self)
					GameTooltip:Hide()
					if self.categoryName == "DELETE" then
						if self.label then self.label:SetAlpha(0.4) end
						if self.toggleBtn and self.toggleBtn.text then self.toggleBtn.text:SetAlpha(0.4) end
						if self.toggleBtn and self.toggleBtn.icon then self.toggleBtn.icon:SetAlpha(0.4) end
					end
				end)
				table.insert(pool, div)
			end
			local catName = entry.divider or ""
			local collapsed = entry.collapsed
			yOff = yOff + 4  -- gap above colored line
			div:SetParent(content)
			div:ClearAllPoints()
			div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
			div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
			div:SetHeight(16)  -- 1px line + 4px gap + 11px text row
			-- Label: category name; DELETE shows "Autodelete" italic, alpha 0.4 (0.7 on hover). Font/size from Scale Settings when custom.
			local isBankDelete = (catName == "DELETE")
			local fontPath, fontSize = GetCategoryHeaderFontAndSize()
			if isBankDelete then
				div.label:SetText("|cff9a7070Autodelete|r")
				div.label:SetFont(fontPath, fontSize, "ITALIC")
				div.label:SetAlpha(0.4)
			else
				div.label:SetText("|cff8a9a9a" .. catName .. "|r")
				div.label:SetFont(fontPath, fontSize, "")
				div.label:SetAlpha(1)
			end
			local SV = _G.FugaziBAGSDB
			local headerColor = (SV and SV.gphCategoryHeaderFontCustom and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor) and SV.gphSkinOverrides.headerTextColor
            local useHeaderColor = headerColor and #headerColor >= 4
			if useHeaderColor then
				div.label:SetText(isBankDelete and "Autodelete" or catName)
				div.label:SetTextColor(headerColor[1], headerColor[2], headerColor[3], headerColor[4])
			end
            -- Scale the icon frame in proportion to header font size so icon stays visually matched.
            if div.toggleBtn and fontSize then
                local base = math.max(10, fontSize)
                if isBankDelete then
                    div.toggleBtn:SetSize(base - 2, base - 4)
                else
                    div.toggleBtn:SetSize(base, base)
                end
            end
			div.label:Show()
			div.categoryName = catName
			-- Indicator icon: collapse/expand graphic; tint matches header colour if custom, otherwise white
			if div.toggleBtn then
				if div.toggleBtn.text then
					-- Hide legacy [+]/[-] text; icon handles state.
					div.toggleBtn.text:SetText("")
				end
				if div.toggleBtn.icon then
                    local r, g, b = 1, 1, 1
                    if useHeaderColor then
                        r, g, b = headerColor[1], headerColor[2], headerColor[3]
                    end
                    -- When collapsed we show the "expand" icon; when expanded, the "collapse" icon.
					if isBankDelete then
                        div.toggleBtn.icon:SetTexture(collapsed
                            and "Interface\\AddOns\\__FugaziBAGS\\media\\expand.blp"
                            or  "Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
						div.toggleBtn.icon:SetAlpha(collapsed and 0.7 or 0.4)
						div.toggleBtn.icon:SetVertexColor(r, g, b, 1)
					else
                        div.toggleBtn.icon:SetTexture(collapsed
                            and "Interface\\AddOns\\__FugaziBAGS\\media\\expand.blp"
                            or  "Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
						div.toggleBtn.icon:SetAlpha(collapsed and 1.0 or 0.7)
						div.toggleBtn.icon:SetVertexColor(r, g, b, 1)
					end
				end
				div.toggleBtn:Show()
			end
			div:Show()
			-- Defer: if DELETE row and mouse not over it, force dim alpha (avoids looking "on" from spurious OnEnter when frame is shown)
			if isBankDelete then
				local defer = CreateFrame("Frame")
				defer:SetScript("OnUpdate", function(self)
					self:SetScript("OnUpdate", nil)
					if div.categoryName == "DELETE" and div:IsVisible() and not div:IsMouseOver() then
						if div.label then div.label:SetAlpha(0.4) end
						if div.toggleBtn and div.toggleBtn.text then div.toggleBtn.text:SetAlpha(0.4) end
					end
				end)
			end
			yOff = yOff + 16 + 4  -- row height (line+gap+text) + gap below line
		elseif entry.divider and entry.divider == "HIDDEN_FIRST" then
			-- No header for the Hearthstone group, just continue to items
			yOff = yOff + 0
		else
			local row = GetBankRow(content)
			if firstRow == nil then firstRow = row end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
			local info = entry
			local bagID, slotID = info.bagID, info.slotID

			if not info.isProtected and bf.bankDefaultScrollY == nil then
				bf.bankDefaultScrollY = yOff
			end

			-- Row height for the bank list should follow the same dynamic rules
			-- as the main inventory list so the Row Icon Size slider always feels identical.
			local rowStep = ComputeItemDetailsRowHeight(BANK_ROW_HEIGHT)

			yOff = yOff + rowStep
			row:SetHeight(rowStep)
			if row.clickArea and row.clickArea.SetHeight then
				row.clickArea:SetHeight(rowStep)
			end
			row.bagID = bagID
			row.slotID = slotID

            if not row._scriptsBound then
                row._scriptsBound = true
                row.deleteBtn:SetScript("OnClick", BankRow_deleteBtn_OnClick)
                row.deleteBtn:SetScript("OnEnter", BankRow_deleteBtn_OnEnter)
                row.deleteBtn:SetScript("OnLeave", BankRow_deleteBtn_OnLeave)
                row.deleteBtn:SetScript("OnMouseWheel", BankRow_deleteBtn_OnMouseWheel)

                row.clickArea:SetScript("OnMouseDown", BankRow_clickArea_OnMouseDown)
                row.clickArea:SetScript("OnClick", BankRow_clickArea_OnClick)
                row.clickArea:SetScript("OnReceiveDrag", BankRow_clickArea_OnReceiveDrag)
                row.clickArea:SetScript("OnMouseUp", BankRow_clickArea_OnMouseUp)
                row.clickArea:SetScript("OnEnter", BankRow_clickArea_OnEnter)
                row.clickArea:SetScript("OnLeave", BankRow_clickArea_OnLeave)
                row.clickArea:SetScript("OnMouseWheel", BankRow_clickArea_OnMouseWheel)
            end

			local link = info.link or (GetContainerItemLink and GetContainerItemLink(bagID, slotID))
			if idx == 1 and BANK_DEBUG then
				BankDebug("Step 5: first row parent=" .. tostring(row:GetParent()) .. " content=" .. tostring(content) .. " row:IsShown()=" .. tostring(row:IsShown()) .. " content:GetParent()=" .. tostring(content:GetParent()))
			end
			local name = info.name or "Empty"
			local quality = info.quality or 0
			local count = info.count or 0
			local hideIconsBank = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphHideIconsInList
			if hideIconsBank then
				row.icon:Hide()
				row.protectedOverlay:Hide()
				row.nameFs:ClearAllPoints()
				row.nameFs:SetPoint("LEFT", row.clickArea, "LEFT", 4, 0)
				row.nameFs:SetPoint("RIGHT", row.clickArea, "RIGHT", -40, 0)
			else
				row.icon:Show()
				local texture = info.texture or (GetContainerItemInfo and GetContainerItemInfo(bagID, slotID))
				if texture then
					row.icon:SetTexture(texture)
				else
					row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
				end
				row.nameFs:ClearAllPoints()
				row.nameFs:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
				row.nameFs:SetPoint("RIGHT", row.clickArea, "RIGHT", -40, 0)
			end
			-- Apply visual state based on protection and previously worn just like inventory
			if not hideIconsBank then
				if info.isProtected then
					if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
					row.icon:SetVertexColor(0.65, 0.65, 0.65)
				else
					if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
					row.icon:SetVertexColor(1, 1, 1)
				end
			end
			if info.isProtected then
				local QUALITY_COLORS = Addon.QUALITY_COLORS or {}
				local qInfo = QUALITY_COLORS[quality] or { r = 0.8, g = 0.8, b = 0.8, hex = "cccccc" }
				local mix, grey = 0.28, 0.48
				local r = (qInfo.r or 0.5) * mix + grey * (1 - mix)
				local g = (qInfo.g or 0.5) * mix + grey * (1 - mix)
				local b = (qInfo.b or 0.5) * mix + grey * (1 - mix)
				local nameHex = string.format("%02x%02x%02x", 
					math.floor(math.max(0, math.min(1, r)) * 255), 
					math.floor(math.max(0, math.min(1, g)) * 255), 
					math.floor(math.max(0, math.min(1, b)) * 255)
				)
				row.nameFs:SetText("|cff" .. nameHex .. (name or "Unknown") .. "|r")
			else
				local QUALITY_COLORS = Addon.QUALITY_COLORS or {}
				local info2 = QUALITY_COLORS[quality] or { r = 0.8, g = 0.8, b = 0.8, hex = "cccccc" }
				row.nameFs:SetText("|cff" .. (info2.hex or "cccccc") .. (name or "Unknown") .. "|r")
			end

			-- Darken the entire row for protected items (and also keep it for previously worn), 
			-- similar to the inventory list's protected overlay.
			if info.isProtected or info.previouslyWorn then
				if row.protectedOverlay then row.protectedOverlay:Show() end
			else
				if row.protectedOverlay then row.protectedOverlay:Hide() end
			end

			local showCount = (count and count > 1) and ("|cffaaaaaa x" .. tostring(count) .. "|r") or ""
			row.countFs:SetText(showCount)
			row.totalCount = count

			if ApplyItemDetailsToRow then ApplyItemDetailsToRow(row, { name = name, quality = quality, isProtected = info.isProtected }) end

		-- Attach secure button for taint-free RMB item use
		if row.clickArea and bagID ~= nil and slotID ~= nil and _G.FugaziBAGS_EnsureSecureRowBtn then
			_G.FugaziBAGS_EnsureSecureRowBtn(row.clickArea, bagID, slotID)
		end

			if row.deleteBtn then
			if link and row:IsMouseOver() then row.deleteBtn:Show() else row.deleteBtn:Hide() end
		end
	end
end

	content:SetHeight(math.max(yOff, 1))
	-- If we had slots but no items, client may not have sent bank data yet; refresh again next frame
	local aggN = 0
	for _ in pairs(aggregated) do aggN = aggN + 1 end
	if aggN == 0 and totalBankSlots > 0 and not bf._bankDeferRefresh then
		bf._bankDeferRefresh = true
		local defer = CreateFrame("Frame")
		defer:SetScript("OnUpdate", function(self)
			self:SetScript("OnUpdate", nil)
			if bf:IsShown() and RefreshBankUI then RefreshBankUI() end
		end)
	end
	BankDebug("Step 6: yOff=" .. tostring(yOff) .. " content:GetHeight()=" .. tostring(content:GetHeight()) .. " content:GetParent()=" .. tostring(content:GetParent()) .. " content:IsShown()=" .. tostring(content:IsShown()))
	local scroll = bf.scrollFrame
	local scrollBar = bf.scrollBar
	BankDebug("Step 7: scroll=" .. tostring(scroll) .. " scrollBar=" .. tostring(scrollBar))
	if scroll then
		BankDebug("Step 7b: scroll:GetWidth()=" .. tostring(scroll:GetWidth()) .. " scroll:GetHeight()=" .. tostring(scroll:GetHeight()) .. " scroll:GetParent()=" .. tostring(scroll:GetParent()))
	end
	if scroll and scrollBar then
		local viewH = scroll:GetHeight()
		local maxScroll = math.max(0, yOff - viewH)
		scrollBar:SetMinMaxValues(0, maxScroll)
		local offset = bf.bankScrollOffset or 0
		
		-- Handle Auto-Scroll to "Home Base" (First non-protected item). Defer re-apply so it sticks after rarity filter etc.
		if bf.gphScrollToDefaultOnNextRefresh then
			if bf.bankDefaultScrollY and maxScroll > 0 then
				offset = math.min(bf.bankDefaultScrollY, maxScroll)
				bf.gphScrollToDefaultOnNextRefresh = nil
				bf._pendingBankScrollY = offset
			elseif maxScroll == 0 then
				offset = 0
				bf._pendingBankScrollY = nil
			else
				offset = 0
				bf.gphScrollToDefaultOnNextRefresh = nil
				bf._pendingBankScrollY = nil
			end
		end

		offset = math.min(offset, maxScroll)
		bf.bankScrollOffset = offset
		scrollBar:SetValue(offset)
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, offset)
		BankDebug("Step 8: viewH=" .. tostring(viewH) .. " maxScroll=" .. tostring(maxScroll) .. " offset=" .. tostring(offset))
	end

	-- One-frame defer: re-apply bank home base scroll so it sticks when toggling rarity (scroll bar can reset position).
	if bf._pendingBankScrollY ~= nil and scroll and scrollBar and content and not bf.gphGridMode then
		local wantOffset = bf._pendingBankScrollY
		local df = Addon._bankScrollToDefaultDeferFrame
		if not df then
			df = CreateFrame("Frame")
			Addon._bankScrollToDefaultDeferFrame = df
		end
		local runCount = 0
		df:SetScript("OnUpdate", function(self)
			runCount = runCount + 1
			if runCount > 2 then
				self:SetScript("OnUpdate", nil)
				self:Hide()
				if bf._pendingBankScrollY then bf._pendingBankScrollY = nil end
				return
			end
			local b = _G.TestBankFrame
			if not b or not b:IsShown() or b.gphGridMode or b.scrollFrame ~= scroll then return end
			local vh = scroll:GetHeight()
			local ch = content:GetHeight() or 0
			local maxS = math.max(0, ch - vh)
			local cur = math.min(wantOffset, maxS)
			b.bankScrollOffset = cur
			if b.scrollBar then
				b.scrollBar:SetMinMaxValues(0, maxS)
				b.scrollBar:SetValue(cur)
			end
			content:ClearAllPoints()
			content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, cur)
		end)
		df:Show()
		bf._pendingBankScrollY = nil
	end
	if BANK_DEBUG and content.GetNumChildren then
		BankDebug("Step 9: content:GetNumChildren()=" .. tostring(content:GetNumChildren()))
	end

	-- Update bank bag row: show bag-slot look (generic bag or locked), not first item in bag
	for i = 1, NUM_BANK_BAGS do
		local btn = bf.bagSlots and bf.bagSlots[i]
		if btn then
			local bagID = (NUM_BAG_SLOTS or 4) + i
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
			if numSlots > 0 then
				btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
				if btn.icon.SetDesaturated then btn.icon:SetDesaturated(false) end
			else
				btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
				if btn.icon.SetDesaturated then btn.icon:SetDesaturated(true) else btn.icon:SetVertexColor(0.5, 0.5, 0.5) end
			end
			btn.icon:Show()
			btn:Show()
		end
	end
end

--- Tooltip when you hover the red X on an inventory row (double-click to delete, or add to autodelete list).
local function GPHBtn_deleteBtn_OnEnter(self)
    local btn = self:GetParent()
    local item, capturedId, deleteKey, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedDeleteKey, btn.cachedItemIdx
    if not item then return end
                self:SetText("|cffff8888x|r")
                self:SetWidth(16)
                self:SetHeight(16)
                Addon.AnchorTooltipRight(self)
                if item.isDestroy then
                    GameTooltip:AddLine("LMB: Remove Entry", 0.85, 0.75, 0.5)
                else
                    GameTooltip:AddLine("DoubleClick: Delete Item", 0.85, 0.75, 0.5)
                    GameTooltip:AddLine("Shift-Click: AutoDelete", 0.85, 0.75, 0.5)
                end
                GameTooltip:Show()
end
local function GPHBtn_deleteBtn_OnLeave(self)
    local btn = self:GetParent()
    if not btn:IsMouseOver() then
        if btn.deleteBtn then btn.deleteBtn:Hide() end
    end
    self:SetText("|cffff4444x|r")
    self:SetWidth(14)
    self:SetHeight(14)
    GameTooltip:Hide()
end
local function GPHBtn_deleteBtn_OnMouseWheel(self, delta)
    local btn = self:GetParent()
    local item, capturedId, deleteKey, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedDeleteKey, btn.cachedItemIdx
    if not item then return end
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
end
local function GPHBtn_deleteBtn_OnClick(self)
    if Addon.PlayTrashSound then Addon.PlayTrashSound() end
    local btn = self:GetParent()
    local item, capturedId, deleteKey, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedDeleteKey, btn.cachedItemIdx
    if not item then return end
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                if not capturedId then return end
                -- No throttle on X button so double-click always registers (row throttle was dropping X clicks)
                local now = GetTime and GetTime() or time()
                -- LMB remove if on list, OR Shift-click to toggle/add
                local list = Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
                local onList = list[capturedId]
                if IsShiftKeyDown() or onList then
                    if onList then
                        list[capturedId] = nil
                    else
                        local SV = _G.FugaziBAGSDB or {}
                        if SV.gridConfirmAutoDel == false then
                            local name = item.name or (GetItemInfo and GetItemInfo(capturedId))
                            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(item.link or capturedId)
                            list[capturedId] = { name = name, texture = tex, addedTime = time() }
                            Addon.QueueDestroySlotsForItemId(capturedId)
                        else
                            if item.previouslyWorn then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DESTROY_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId })
                            elseif item.quality and item.quality >= 4 then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DESTROY_EPIC", nil, nil, { itemId = capturedId })
                            else
                                local name = item.name or (GetItemInfo and GetItemInfo(capturedId))
                                local _, _, _, _, _, _, _, _, _, tex = GetItemInfo and GetItemInfo(item.link or capturedId)
                                list[capturedId] = { name = name, texture = tex, addedTime = time() }
                                Addon.QueueDestroySlotsForItemId(capturedId)
                            end
                        end
                    end
                    if gphFrame then gphFrame._refreshImmediate = true end
                    RefreshGPHUI()
                    return
                end
                Addon.gphDestroyClickTime[capturedId] = nil
                -- Double-click X within 0.5s to delete (keyed by slot so same row must be clicked twice)
                if Addon.gphDeleteClickTime[deleteKey] and (now - Addon.gphDeleteClickTime[deleteKey]) <= 0.5 then
                    Addon.gphDeleteClickTime[deleteKey] = nil
                    local count = item.count or 0
                    local SV = _G.FugaziBAGSDB or {}
                    if item.bag ~= nil and item.slot ~= nil then
                        if SV.gridConfirmAutoDel == false then
                            Addon.DeleteGPHSlot(item.bag, item.slot)
                            RefreshGPHUI()
                        else
                            if item.previouslyWorn then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId, count = count, bag = item.bag, slot = item.slot })
                            elseif count > 1 then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_STACK", count, nil, { itemId = capturedId, count = count, bag = item.bag, slot = item.slot })
                            else
                                Addon.DeleteGPHSlot(item.bag, item.slot)
                                RefreshGPHUI()
                            end
                        end
                    else
                        if SV.gridConfirmAutoDel == false then
                            Addon.DeleteGPHItem(capturedId, count)
                            RefreshGPHUI()
                        else
                            if item.previouslyWorn then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId, count = count })
                            elseif count > 1 then
                                StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_STACK", count, nil, { itemId = capturedId, count = count })
                            else
                                Addon.DeleteGPHItem(capturedId, count)
                                RefreshGPHUI()
                            end
                        end
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                else
                    Addon.gphDeleteClickTime[deleteKey] = now
                end
end
local function GPHBtn_clickArea_OnReceiveDrag(self)
    local btn = self:GetParent()
    local item = btn.cachedItem
    if not item then return end
    if item.bag ~= nil and item.slot ~= nil and PickupContainerItem then
        PickupContainerItem(item.bag, item.slot)
        -- Defer refresh so bag state has updated and list shows new positions
        local defer = Addon.gphBagUpdateDeferFrame
        if not defer then
            defer = CreateFrame("Frame")
            Addon.gphBagUpdateDeferFrame = defer
        end
        defer:SetScript("OnUpdate", function(ds)
            ds:SetScript("OnUpdate", nil)
            if gphFrame then gphFrame._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
        end)
    end
end
local function GPHBtn_clickArea_OnMouseWheel(self, delta)
    local btn = self:GetParent()
    local item, capturedId, deleteKey, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedDeleteKey, btn.cachedItemIdx
    if not item then return end
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
end
local function GPHBtn_clickArea_OnEnter(self)
    local btn = self:GetParent()
    if btn.deleteBtn then btn.deleteBtn:Show() end
    local item = btn.cachedItem
    if not item or not item.link then return end
    Addon.AnchorTooltipRight(self)
    if item.bag ~= nil and item.slot ~= nil and GameTooltip.SetBagItem then
        GameTooltip:SetBagItem(item.bag, item.slot)
    else
        local lp = item.link:match("|H(item:[^|]+)|h")
        if lp then GameTooltip:SetHyperlink(lp) end
    end

    local isProt = item.isProtected and true or false
    local isPrev = false
    if Addon and Addon.GetGphPreviouslyWornOnlySet then
        local prevOnly = Addon.GetGphPreviouslyWornOnlySet()
        local itemId = tonumber(item.link:match("item:(%d+)"))
        if itemId and prevOnly and prevOnly[itemId] then
            isPrev = true
        end
    end

    if isPrev then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Previously worn gear", 0.40, 0.80, 0.40)
        GameTooltip:AddLine("Alt+LMB: Unprotect", 0.80, 0.80, 0.80)
    else
        GameTooltip:AddLine(" ")
        if isProt then
            GameTooltip:AddLine("Protected", 0.40, 0.80, 0.40)
            GameTooltip:AddLine("Alt+LMB: Unprotect", 0.80, 0.80, 0.80)
        else
            GameTooltip:AddLine("Unprotected", 1.00, 0.25, 0.25)
            GameTooltip:AddLine("Alt+LMB: Protect", 0.80, 0.80, 0.80)
        end
    end
    GameTooltip:AddLine("Ctrl+RMB: Autodelete", 0.90, 0.60, 0.60)

    if item.bag ~= nil then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("LMB: Pickup  |  RMB: Use", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Shift+LMB: Splitstack  |  Shift+RMB: Link to Chat", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Ctrl+LMB: Inspect", 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end
local function GPHBtn_clickArea_OnLeave(self)
    local btn = self:GetParent()
    if not btn:IsMouseOver() then
        if btn.deleteBtn then btn.deleteBtn:Hide() end
    end
    GameTooltip:Hide()
end
local function GPHBtn_clickArea_OnClick(self, button)
    if Addon.PlayClickSound then Addon.PlayClickSound() end
    local btn = self:GetParent()
    local item, capturedId, deleteKey, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedDeleteKey, btn.cachedItemIdx
    if not item then return end
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                -- Throttle row actions to ~4/sec so fast macros don't highlight/mark everything
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                -- Shift+RMB: link to chat
                if button == "RightButton" and IsShiftKeyDown() then
                    if item.link then
                        if StackSplitFrame and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
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
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- RMB (no shift): item use is handled by secure overlay button on hover.
                -- No addon code calls UseContainerItem; Blizzard's template handler does it.
                if button == "RightButton" and not IsShiftKeyDown() then
                    -- Feedback pulse
                    if btn.pulseTex then
                        btn.pulseTex:SetVertexColor(1, 1, 1, 0.65)
                        btn.pulseTex:Show()
                        local fade = CreateFrame("Frame")
                        fade:SetScript("OnUpdate", function(f, el)
                            f._t = (f._t or 0) + el
                            if f._t > 0.3 then btn.pulseTex:Hide(); f:SetScript("OnUpdate", nil)
                            else btn.pulseTex:SetAlpha(0.65 * (1 - f._t/0.3)) end
                        end)
                    end
                    -- Refresh after secure button fires (deferred)
                    if gphFrame then gphFrame._refreshImmediate = true; gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- CTRL+LMB: toggle protect (blue). When unsaving, also remove from previously-worn so item can be disenchanted/sold.
                if IsControlKeyDown() and button == "LeftButton" and capturedId and Addon.GetGphProtectedSet then
                    local set = Addon.GetGphProtectedSet()
                    if set[capturedId] then
                        set[capturedId] = nil
                        local prevWorn = Addon.GetGphPreviouslyWornOnlySet()
                        if prevWorn and prevWorn[capturedId] then prevWorn[capturedId] = nil end
                    else
                        set[capturedId] = true
                    end
                    if gphFrame then gphFrame._refreshImmediate = true end
                    if RefreshGPHUI then RefreshGPHUI() end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- Shift+LMB: if split dialog is open, do nothing (user is choosing amount); else pick up
                if IsShiftKeyDown() and button == "LeftButton" and item.bag ~= nil and item.slot ~= nil then
                    if gphStackSplitFrame and gphStackSplitFrame:IsShown() then
                        return
                    end
                    PickupContainerItem(item.bag, item.slot)
                    if gphFrame then gphFrame._refreshImmediate = true end
                    RefreshGPHUI()
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end

                -- LMB (no modifier): pick up / place (real inventory, like default bags) or select (destroy ghost)
                if button == "LeftButton" and gphFrame then
                    if item.bag ~= nil and item.slot ~= nil and PickupContainerItem then
                        PickupContainerItem(item.bag, item.slot)
                        if gphFrame then gphFrame._refreshImmediate = true end
                        RefreshGPHUI()
                    else
                        gphFrame.gphSelectedItemId = capturedId
                        gphFrame.gphSelectedBag = nil
                        gphFrame.gphSelectedSlot = nil
                        gphFrame.gphSelectedIndex = itemIdx
                        gphFrame.gphSelectedItemLink = item.link
                        gphFrame.gphSelectedTime = time()
                        gphFrame._refreshImmediate = true
                        RefreshGPHUI()
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end

local function GPHBtn_clickArea_OnMouseDown(self,  mouseButton)
    if Addon.TriggerRowPulse then Addon.TriggerRowPulse(self:GetParent()) end
    local btn = self:GetParent()
    local item, capturedId = btn.cachedItem, btn.cachedItemId
    if not item then return end
    if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
    if (mouseButton ~= "LeftButton" and mouseButton ~= "RightButton") or not gphFrame then return end
    if IsControlKeyDown() then return end  -- CTRL+click = protect in OnClick
    -- LeftButton down on real slot: pick up, or shift+click = open split-stack dialog (like Blizzard bags)
    if mouseButton == "LeftButton" and item.bag ~= nil and item.slot ~= nil and PickupContainerItem then
        if IsShiftKeyDown() then
            local bag, slot, count = item.bag, item.slot, item.count
            if count and count > 1 and Addon.ShowGPHStackSplit then
                Addon.ShowGPHStackSplit(bag, slot, count, btn, capturedId)
            else
                PickupContainerItem(item.bag, item.slot)
                if not Addon._gphPickupDefer then Addon._gphPickupDefer = CreateFrame("Frame") end
                Addon._gphPickupDefer:SetScript("OnUpdate", function(ds) ds:SetScript("OnUpdate", nil); if gphFrame then gphFrame._refreshImmediate = true end; if RefreshGPHUI then RefreshGPHUI() end end)
            end
        else
            PickupContainerItem(item.bag, item.slot)
            -- Defer refresh so list shows slot as empty after pickup
            if not Addon._gphPickupDefer then Addon._gphPickupDefer = CreateFrame("Frame") end
            Addon._gphPickupDefer:SetScript("OnUpdate", function(ds)
                ds:SetScript("OnUpdate", nil)
                if gphFrame then gphFrame._refreshImmediate = true end
                if RefreshGPHUI then RefreshGPHUI() end
            end)
        end
    end
end
    return f
end

--- Shows or hides the cooldown overlay on a row (e.g. potion on CD = greyed clock).
local function GPH_CheckRowCooldown(btn, item, idToSlot)
    if not btn or not btn.cooldownOverlay then return false end
    local capturedId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
    local onCooldown = false
    if item.bag ~= nil and item.slot ~= nil and GetContainerItemCooldown then
        local cStart, cDur = GetContainerItemCooldown(item.bag, item.slot)
        onCooldown = cDur and cDur > 0 and (cStart or 0) + cDur > GetTime()
    else
        onCooldown = Addon.ItemIdHasCooldown(capturedId, idToSlot)
    end
    if onCooldown then btn.cooldownOverlay:Show() else btn.cooldownOverlay:Hide() end
    return onCooldown
end

--- Every 0.5s checks if the row's item is still on cooldown; stops when cooldown ends (saves CPU).
local function GPHRow_OnUpdateCooldown(self, elapsed)
    self._cdTimer = (self._cdTimer or 0) + elapsed
    if self.cachedItem and self._cdTimer > 0.5 then
        self._cdTimer = 0
        local map = Addon._gphIdToSlotTempCached
        if not GPH_CheckRowCooldown(self, self.cachedItem, map) then
            self:SetScript("OnUpdate", nil)
        end
    end
end

--- Fills one inventory list row: icon, name, count, protection lock, red X, cooldown overlay, click/drag handlers.
local function UpdateGPHRowVisuals(btn, item, itemIdx, yOff, rowBelowDivider, destroyList, gphFrame, idToSlot)
    local dynW = gphFrame.gphDynContentWidth
    if dynW and dynW > 50 then btn:SetWidth(dynW - 8) end
    btn:SetPoint("TOPLEFT", btn:GetParent(), "TOPLEFT", 4, -yOff)

    -- Row height follows the Item Details icon size so bigger icons get more vertical space.
    local rowStep = ComputeItemDetailsRowHeight(18)
    if btn.SetHeight then btn:SetHeight(rowStep) end
    if btn.clickArea and btn.clickArea.SetHeight then btn.clickArea:SetHeight(rowStep) end

    if rowBelowDivider then
        btn:SetHitRectInsets(0, 0, -4, 0)
        if btn.clickArea then btn.clickArea:SetHitRectInsets(0, 0, -4, 0) end
    else
        btn:SetHitRectInsets(0, 0, 0, 0)
        if btn.clickArea then btn.clickArea:SetHitRectInsets(0, 0, 0, 0) end
    end

    btn.itemLink = item.link
    local rowItemId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
    local isOnDestroyList = rowItemId and destroyList[rowItemId]
    local hideIcons = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphHideIconsInList
    if hideIcons then
        if btn.icon then btn.icon:Hide() end
        if btn.prevWornIcon then btn.prevWornIcon:Hide() end
    else
        if btn.icon then
            btn.icon:Show()
            btn.icon:SetTexture(Addon.GetSafeItemTexture(item.link or item.itemId, item.texture))
            if isOnDestroyList then
                if btn.icon.SetDesaturated then btn.icon:SetDesaturated(true) end
                btn.icon:SetVertexColor(0.55, 0.55, 0.55)
            elseif item.isProtected then
                if btn.icon.SetDesaturated then btn.icon:SetDesaturated(false) end
                btn.icon:SetVertexColor(0.65, 0.65, 0.65)
            else
                if btn.icon.SetDesaturated then btn.icon:SetDesaturated(false) end
                btn.icon:SetVertexColor(1, 1, 1)
            end
        end
    end

    local qInfo = Addon.QUALITY_COLORS[item.quality] or Addon.QUALITY_COLORS[1]
    local leftOfName = btn.icon
    local gap = 4

    if not hideIcons and btn.prevWornIcon then
        if item.previouslyWorn then
            btn.prevWornIcon:SetTexture("Interface\\Icons\\INV_Shield_06")
            btn.prevWornIcon:ClearAllPoints()
            btn.prevWornIcon:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
            if isOnDestroyList then
                btn.prevWornIcon:SetVertexColor(0.55, 0.55, 0.55)
            elseif item.isProtected then
                btn.prevWornIcon:SetVertexColor(0.65, 0.65, 0.65)
            else
                btn.prevWornIcon:SetVertexColor(1, 1, 1)
            end
            btn.prevWornIcon:Show()
            leftOfName = btn.prevWornIcon
            gap = 2
        else
            btn.prevWornIcon:Hide()
        end
    end

    btn.nameFs:ClearAllPoints()
    if hideIcons and btn.clickArea then
        btn.nameFs:SetPoint("LEFT", btn.clickArea, "LEFT", 4, 0)
    else
        btn.nameFs:SetPoint("LEFT", leftOfName, "RIGHT", gap, 0)
    end
    btn.nameFs:SetPoint("RIGHT", btn.clickArea, "RIGHT", -2, 0)

    local nameHex
    if isOnDestroyList then
        nameHex = "888888"
    elseif item.isProtected then
        local mix, grey = 0.28, 0.48
        local r = (qInfo.r or 0.5) * mix + grey * (1 - mix)
        local g = (qInfo.g or 0.5) * mix + grey * (1 - mix)
        local b = (qInfo.b or 0.5) * mix + grey * (1 - mix)
        r = math.max(0, math.min(1, r))
        g = math.max(0, math.min(1, g))
        b = math.max(0, math.min(1, b))
        nameHex = string.format("%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
    else
        nameHex = qInfo.hex
    end

    btn.nameFs:SetText("|cff" .. nameHex .. (item.name or "Unknown") .. "|r")
    btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")

    if ApplyItemDetailsToRow then ApplyItemDetailsToRow(btn, item) end

    local capturedId = rowItemId
    local deleteKey = (item.bag ~= nil and item.slot ~= nil) and ("b"..item.bag.."s"..item.slot) or ("i"..tostring(capturedId))
    
    local isSelected = gphFrame and (
        (item.bag ~= nil and item.slot ~= nil and gphFrame.gphSelectedBag == item.bag and gphFrame.gphSelectedSlot == item.slot)
        or (item.bag == nil and gphFrame.gphSelectedItemId and capturedId == gphFrame.gphSelectedItemId)
        or (gphFrame.gphSelectedIndex and gphFrame.gphSelectedIndex == itemIdx)
    )
    if isSelected and btn.selectedTex then
        btn.selectedTex:Show()
    elseif btn.selectedTex then
        btn.selectedTex:Hide()
    end

    if btn.cooldownOverlay then
        if GPH_CheckRowCooldown(btn, item, idToSlot) then
            btn:SetScript("OnUpdate", GPHRow_OnUpdateCooldown)
        else
            btn:SetScript("OnUpdate", nil)
        end
    end

    if btn.destroyOverlay then
        if (Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {})[capturedId] then
            btn.destroyOverlay:SetVertexColor(0.28, 0.12, 0.12)
            btn.destroyOverlay:SetAlpha(0.72)
            btn.destroyOverlay:Show()
        else
            btn.destroyOverlay:Hide()
        end
    end

    if btn.protectedOverlay then
        -- Hearthstone is always protected logically, but we don't want its row visually dimmed by default.
        -- However, if the player manually protects it via Alt-click (per-item set), we do still want the overlay.
        local hearthId = 6948
        local isHearth = (item.itemId == hearthId or capturedId == hearthId)
        local protectedSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
        local isManuallyProtected = (item.itemId and protectedSet[item.itemId]) or (capturedId and protectedSet[capturedId])
        local isPrevWorn = item.previouslyWorn

        if (item.isProtected and not isHearth) or isManuallyProtected then
            btn.protectedOverlay:Show()
            if btn.protectedKeyIcon then
                -- Previously worn items already have the shield marker; skip the key overlay to reduce clutter.
                if isPrevWorn then
                    btn.protectedKeyIcon:Hide()
                else
                    btn.protectedKeyIcon:Show()
                    local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
                    if atVendor then
                        btn.protectedKeyIcon:SetAlpha(0.75)
                        if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(0) end
                    else
                        local SV = _G.FugaziBAGSDB
                        btn.protectedKeyIcon:SetAlpha((SV and SV.gridProtectedKeyAlpha) or 0.2)
                        if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(1) end
                    end
                end
            end
        else
            btn.protectedOverlay:Hide()
            if btn.protectedKeyIcon then btn.protectedKeyIcon:Hide() end
        end
    end

    if btn.deleteBtn then
        if item.link and btn:IsMouseOver() then btn.deleteBtn:Show() else btn.deleteBtn:Hide() end
    end

    if Addon.gphDeleteClickTime and Addon.gphDeleteClickTime[deleteKey] and (GetTime() - (Addon.gphDeleteClickTime[deleteKey] or 0)) > 0.5 then
        Addon.gphDeleteClickTime[deleteKey] = nil
    end

    btn.cachedItem = item
    btn.cachedItemId = capturedId
    btn.cachedDeleteKey = deleteKey
    btn.cachedItemIdx = itemIdx

    btn.deleteBtn:SetText("|cffff4444x|r")
    
    if not btn._scriptsBound then
        btn._scriptsBound = true
        btn.deleteBtn:SetScript("OnEnter", GPHBtn_deleteBtn_OnEnter)
        btn.deleteBtn:SetScript("OnLeave", GPHBtn_deleteBtn_OnLeave)
        btn.deleteBtn:SetScript("OnMouseWheel", GPHBtn_deleteBtn_OnMouseWheel)
        btn.deleteBtn:SetScript("OnClick", GPHBtn_deleteBtn_OnClick)

        btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn.clickArea:RegisterForDrag("LeftButton")
        btn.clickArea:SetScript("OnReceiveDrag", GPHBtn_clickArea_OnReceiveDrag)
        btn.clickArea:SetScript("OnMouseWheel", GPHBtn_clickArea_OnMouseWheel)
        btn.clickArea:SetScript("OnClick", GPHBtn_clickArea_OnClick)
        btn.clickArea:SetScript("OnMouseDown", GPHBtn_clickArea_OnMouseDown)
        btn.clickArea:SetScript("OnEnter", GPHBtn_clickArea_OnEnter)
        btn.clickArea:SetScript("OnLeave", GPHBtn_clickArea_OnLeave)
    end

    if item.bag ~= nil and item.slot ~= nil and _G.FugaziBAGS_EnsureSecureRowBtn then
        _G.FugaziBAGS_EnsureSecureRowBtn(btn.clickArea, item.bag, item.slot)
    end
    -- At vendor, block right-click sell for protected items until user unprotects (Alt+click or unprotect rarity).
    local overlay = btn.clickArea and btn.clickArea._fugaziVendorProtectOverlay
    if overlay then
        local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
        -- Start from the row's own protection flag (what you see visually in the list)
        local protected = item.isProtected and true or false
        if capturedId and item.quality ~= nil then
            -- Also consult the shared protection API when available so grid/list stay in sync.
            local Addon = _G.TestAddon
            if Addon and Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(capturedId, item.quality) then
                protected = true
            elseif RarityIsProtected(capturedId, item.quality) then
                protected = true
            end
        end
        if atVendor and protected then overlay:Show() else overlay:Hide() end
    end
end

RefreshGPHUI = function()
    if not gphFrame then gphFrame = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame end
    if not gphFrame then return end
    local gphSession = _G.gphSession
    -- Debounce: avoid multiple refreshes per click (OnMouseDown + OnClick both call this), unless selection just changed (snappy highlight)
    local now = GetTime and GetTime() or time()
    local skipDebounce = gphFrame._refreshImmediate
    if skipDebounce then gphFrame._refreshImmediate = nil end
    if not skipDebounce and gphFrame._lastRefreshGPHUI and (now - gphFrame._lastRefreshGPHUI) < 0.25 then
        return
    end
    gphFrame._lastRefreshGPHUI = now
    if gphFrame.NegotiateSizes then gphFrame:NegotiateSizes() end
    -- Grid mode: also refresh grid slot visuals (rarity filter, search highlight).
    if gphFrame.gphGridMode and _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.RefreshSlots then
        _G.FugaziBAGS_CombatGrid.RefreshSlots()
    end
    -- Re-apply player name, font object, and color so class color sticks
    if gphFrame.gphTitle then ApplyGphInventoryTitle(gphFrame.gphTitle) end
    if gphFrame.UpdateGphTitleBarButtonLayout then gphFrame:UpdateGphTitleBarButtonLayout() end
    if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
    if gphFrame.UpdateGPHButtonVisibility then gphFrame:UpdateGPHButtonVisibility() end
    if ApplyGPHFrameSkin then ApplyGPHFrameSkin(gphFrame) end
    if ApplyCustomizeToFrame then ApplyCustomizeToFrame(gphFrame) end
    if _G.UpdateSortIcon then _G.UpdateSortIcon() end
    -- Only reset visual list-ROW pools when actually in list mode; grid mode skips row creation.
    if not gphFrame.gphGridMode then
        local poolOk, poolErr = pcall(Addon.ResetGPHPools)
        if not poolOk then
            Addon.AddonPrint("[Fugazi] GPH ResetGPHPools error: " .. tostring(poolErr))
            return
        end
    end
    -- ALWAYS reset data pools (item arrays etc.) otherwise _gphItemListPool expands indefinitely when grid mode receives bag updates!
    Addon.ResetGPHDataPools()

    -- Red border and slot counts are set inside the single bag loop below (no extra scan)

    local refreshOk, refreshErr = pcall(function()
    local content = gphFrame.content
    local sf = gphFrame.scrollFrame
    if sf and content then
        local sfW = sf:GetWidth()
        if not sfW or sfW < 50 then sfW = 340 end
        content:SetWidth(sfW)
        gphFrame.gphDynContentWidth = sfW
    end

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
        if gphFrame.gphSearchEditBox and gphFrame.gphSearchEditBox:IsShown() then
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        end
    else
        -- Session active: show Gold / Timer / GPH. Formula in ComputeGPHTotalValue.
        local dur = now - gphSession.startTime
        local liveGold = GetMoney() - gphSession.startGold
        if liveGold < 0 then liveGold = 0 end
        local totalValue = ComputeGPHTotalValue(gphSession, liveGold)
        local gph = dur > 0 and (totalValue / (dur / 3600)) or 0
        gphFrame.statusText:Show()
        gphFrame.statusText:SetText(
            "|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold)
            .. "   |cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r"
            .. "   |cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph))
        )
        if gphFrame.gphSearchEditBox and gphFrame.gphSearchEditBox:IsShown() then
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        end
    end

    -- Fixed header (bag space + Use + rarity bar) — only item list scrolls below; xOffset 4 so bag aligns with search row (search at 6 from titleBar)
    local header = gphFrame.gphHeader
    local headerY = 0
    local xOffset = 0
    local headerParent = header or content

    Addon.gphPendingQuality = Addon.gphPendingQuality or {}
    for q = 0, 5 do
        if Addon.gphPendingQuality[q] and (nowGph - Addon.gphPendingQuality[q]) > 5 then
            Addon.gphPendingQuality[q] = nil
        end
    end

    if Addon.ScanBags then Addon.ScanBags() end
	Addon.gphLiveQualityCounts = Addon.gphLiveQualityCounts or { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
	wipe(Addon.gphLiveQualityCounts)
	for i=0,4 do Addon.gphLiveQualityCounts[i]=0 end
    local liveQualityCounts = Addon.gphLiveQualityCounts
	
    -- Single bag pass: count total/used slots (for red border + bag button) and build aggregated list; GetItemInfo only once per itemId
    Addon.gphItemList = Addon.gphItemList or {}
	wipe(Addon.gphItemList)
	local itemList = Addon.gphItemList
	
	Addon.gphAggregated = Addon.gphAggregated or {}
	wipe(Addon.gphAggregated)
    local aggregated = Addon.gphAggregated
	
    local prevWornSet = Addon.GetGphProtectedSet()
    local previouslyWornOnlySet = Addon.GetGphPreviouslyWornOnlySet()
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags()
    local typeCache = DB.gphItemTypeCache or {}
    DB.gphItemTypeCache = typeCache
    local totalSlots, usedSlots = 0, 0
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        totalSlots = totalSlots + numSlots
        for slot = 1, numSlots do
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
            local texture, count, locked = GetContainerItemInfo(bag, slot)
            count = count or 0
            if link then
                usedSlots = usedSlots + 1
                local itemId = tonumber(link:match("item:(%d+)"))
                if itemId and not aggregated[itemId] then
                    local name, _, quality, iLevel, _, itemType, _, _, _, tex, sellPrice = GetItemInfo(link)
                    quality = quality or 0
                    name = name or "Unknown"
                    sellPrice = sellPrice or 0
                    iLevel = iLevel or 0
                    texture = tex or texture
                    if itemId then typeCache[itemId] = (itemType and itemType ~= "" and itemType) or "Other" end
                    
                    local agg = Addon.GetRecycledAggTable()
                    agg.totalCount = 0
                    agg.firstBag = bag
                    agg.firstSlot = slot
                    agg.link = link
                    agg.texture = texture
                    agg.name = name
                    agg.quality = quality
                    agg.itemId = itemId
                    agg.sellPrice = sellPrice or 0
                    agg.itemLevel = iLevel or 0
                    agg.itemType = typeCache[itemId] or "Other"
                    aggregated[itemId] = agg
                end
                if itemId then aggregated[itemId].totalCount = aggregated[itemId].totalCount + count end
            end
        end
    end
    -- Red border when 3 or fewer free bag slots; otherwise use the active skin's normal border color.
    do
        local freeSlots = totalSlots - usedSlots
        if freeSlots <= 3 then
            gphFrame:SetBackdropBorderColor(1, 0.2, 0.2, 0.9)
        else
            gphFrame:SetBackdropBorderColor(GetActiveSkinBorderColor())
        end
    end
    for _, agg in pairs(aggregated) do
        local q = (agg.quality ~= nil and agg.quality >= 0 and agg.quality <= 7) and agg.quality or 0
        local btnQ = (q >= 5 and q <= 7) and 4 or math.min(q, 4)
        liveQualityCounts[btnQ] = (liveQualityCounts[btnQ] or 0) + agg.totalCount
        local isProtected = agg.itemId and (prevWornSet[agg.itemId] or (rarityFlags and agg.quality and rarityFlags[agg.quality]))
        local previouslyWorn = agg.itemId and previouslyWornOnlySet[agg.itemId]
        
        local itemRecord = Addon.GetRecycledItemTable()
        itemRecord.bag = agg.firstBag
        itemRecord.slot = agg.firstSlot
        itemRecord.link = agg.link
        itemRecord.texture = agg.texture
        itemRecord.count = agg.totalCount
        itemRecord.name = agg.name
        itemRecord.quality = agg.quality
        itemRecord.itemId = agg.itemId
        itemRecord.sellPrice = agg.sellPrice
        itemRecord.itemLevel = agg.itemLevel
        itemRecord.itemType = agg.itemType
        itemRecord.isProtected = isProtected and true or nil
        itemRecord.previouslyWorn = previouslyWorn and true or nil
        
        table.insert(itemList, itemRecord)
    end
    -- Do not add empty slots to the list so they are never shown (user asked to hide them)
    -- for _, es in ipairs(emptySlots) do
    --     table.insert(itemList, { bag = es.bag, slot = es.slot, link = nil, ... })
    -- end

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
    local ROW_H = 18 -- Increased to match search weight
    local bagW, bagH = 36, 18

    -- Rarity buttons: fill from after bag to 4px before frame
    local startX = leftPad + bagW + bagGap
    local rarityTotalW = qualityRight - startX
    local slotWidth = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
    if slotWidth < 10 then slotWidth = 10 end

    -- Bag space: below Search, same size as Search (36x20); drop target, keep on top of header
    if gphFrame.gphBagSpaceBtn and gphFrame.gphBagSpaceBtn.fs then
        local bagText = usedSlots .. "/" .. totalSlots
        gphFrame.gphBagSpaceBtn.fs:SetText(bagText)
        -- Use custom font when Customize is on, else default (so layout refresh doesn't overwrite ApplyCustomizeToFrame)
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphCategoryHeaderFontCustom then
            local path = GetCategoryHeaderFontAndSize()
            gphFrame.gphBagSpaceBtn.fs:SetFont(path, 10, "")
        else
            gphFrame.gphBagSpaceBtn.fs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
        end
        gphFrame.gphBagSpaceBtn:SetSize(bagW, bagH)
        gphFrame.gphBagSpaceBtn:ClearAllPoints()
        -- Perfectly flush with "Search" above it (Reverted to 0 offset found in step 10934)
        gphFrame.gphBagSpaceBtn:SetPoint("TOPLEFT", headerParent, "TOPLEFT", 0, headerY)
        -- Horizontal separator alignment
        if gphFrame.gphSep then
            gphFrame.gphSep:SetPoint("TOPLEFT", gphFrame.gphSearchBtn, "BOTTOMLEFT", 0, -6)
            gphFrame.gphSep:SetPoint("TOPRIGHT", gphFrame, "TOPRIGHT", -8, -6)
        end







        if headerParent and headerParent.GetFrameLevel then
            gphFrame.gphBagSpaceBtn:SetFrameLevel(headerParent:GetFrameLevel() + 20)
        end
        gphFrame.gphBagSpaceBtn:Show()
        table.insert(header and header.headerElements or content.headerElements, gphFrame.gphBagSpaceBtn)
    end

    if not Addon.StartContinuousDelete then
        Addon.StartContinuousDelete = function(q)
            Addon.gphContinuousDelActive = Addon.gphContinuousDelActive or {}
            Addon.gphContinuousDelActive[q] = true
            if not Addon.ContinuousDeleteWorker then
                local w = CreateFrame("Frame")
                w:Hide()
                w._t = 0
                w:SetScript("OnUpdate", function(self, elapsed)
                    self._t = self._t + elapsed
                    if self._t >= 0.5 then
                        self._t = 0
                        local activeTable = Addon.gphContinuousDelActive or {}
                        local hasActive = false
                        for k, v in pairs(activeTable) do if v then hasActive = true; break end end
                        if not hasActive then self:Hide(); return end
                        
                        local deletedOne = false
                        for bag = 0, 4 do
                            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                                local link = GetContainerItemLink(bag, slot)
                                if link then
                                    local _, _, itemQ = GetItemInfo(link)
                                    local match = false
                                    for qTarget, isActive in pairs(activeTable) do
                                        if isActive and ((qTarget == 4 and itemQ and itemQ >= 4) or (itemQ == qTarget)) then
                                            match = true
                                            break
                                        end
                                    end
                                    if match then
                                        local itemId = tonumber(link:match("item:(%d+)"))
                                        if itemId then
                                            local isProtected = RarityIsProtected(itemId, itemQ)
                                            if not isProtected then
                                                PickupContainerItem(bag, slot)
                                                if CursorHasItem() then DeleteCursorItem(); deletedOne = true; break end
                                            end
                                        end
                                    end
                                end
                            end
                            if deletedOne then break end
                        end
                    end
                end)
                Addon.ContinuousDeleteWorker = w
            end
            Addon.ContinuousDeleteWorker._t = 0
            Addon.ContinuousDeleteWorker:Show()
            local inv = _G.TestGPHFrame or _G.gphFrame
            if inv then inv._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
        end
    end

    for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
        local count = liveQualityCounts[q] or 0
        local info = Addon.QUALITY_COLORS[q] or Addon.QUALITY_COLORS[1]
        local labelText = (count > 0) and tostring(count) or ""

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
            
            local hl = qualBtn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            hl:SetVertexColor(1, 1, 1, 0.30)
            qualBtn.hl = hl

            qualityButtons[q] = qualBtn
        end
        qualBtn.quality = q
        qualBtn.currentCount = count
        qualBtn.label = info.label
        qualBtn:Show()

        if not qualBtn._scriptsBound then
            qualBtn._scriptsBound = true
            qualBtn:SetScript("OnMouseDown", GPHQualBtn_OnMouseDown)
            qualBtn:SetScript("OnClick", GPHQualBtn_OnClick)
            qualBtn:SetScript("OnEnter", GPHQualBtn_OnEnter)
            qualBtn:SetScript("OnLeave", GPHQualBtn_OnLeave)
            qualBtn:SetScript("OnUpdate", GPHQualBtn_OnUpdate)
        end

        -- Rarity button style depends only on the skin actually applied to this frame.
        -- For the Original skin we rely on fields set by ApplyGPHFrameSkin (via f.ApplySkin).
        local Skins = _G.__FugaziBAGS_Skins
        local useOriginalRarity = gphFrame and gphFrame._useOriginalRarityStyle and gphFrame._originalMainBorder and gphFrame._originalTitleBg and Skins and Skins.AddRarityBorder
        -- When header customization is OFF and the Original skin is active, make sure the
        -- base skin has been applied to this frame before we read its rarity style fields.
        -- This is a no-op for other skins and does not allocate new textures for Original.
        if useOriginalRarity and gphFrame.ApplySkin then
            local SVskin = _G.FugaziBAGSDB
            if not (SVskin and SVskin.gphCategoryHeaderFontCustom) then
                gphFrame:ApplySkin()
                -- Re-evaluate in case skin settings changed.
                useOriginalRarity = gphFrame and gphFrame._useOriginalRarityStyle and gphFrame._originalMainBorder and gphFrame._originalTitleBg and Skins and Skins.AddRarityBorder
            end
        end

        if qualBtn.rarityBorderTop then
            if useOriginalRarity then
                -- Original skin uses the thick textured border; hide the 1px white "lock" frame entirely.
                qualBtn.rarityBorderTop:Hide()
                qualBtn.rarityBorderBottom:Hide()
                qualBtn.rarityBorderLeft:Hide()
                qualBtn.rarityBorderRight:Hide()
            elseif rarityFlags and rarityFlags[q] then
                -- Non-Original skins: show a softer, washed-out lock border when rarity protection is on.
                local a = 0.45
                qualBtn.rarityBorderTop:Show()
                qualBtn.rarityBorderBottom:Show()
                qualBtn.rarityBorderLeft:Show()
                qualBtn.rarityBorderRight:Show()
                qualBtn.rarityBorderTop:SetVertexColor(1, 1, 1, a)
                qualBtn.rarityBorderBottom:SetVertexColor(1, 1, 1, a)
                qualBtn.rarityBorderLeft:SetVertexColor(1, 1, 1, a)
                qualBtn.rarityBorderRight:SetVertexColor(1, 1, 1, a)
            else
                qualBtn.rarityBorderTop:Hide()
                qualBtn.rarityBorderBottom:Hide()
                qualBtn.rarityBorderLeft:Hide()
                qualBtn.rarityBorderRight:Hide()
            end
        end
        local r, g, b = (info.r or 0.5), (info.g or 0.5), (info.b or 0.5)
        local alpha = 0.35
        
        local delStage = Addon.gphRarityDelStage and Addon.gphRarityDelStage[q]
        if delStage and delStage.stage == 1 then
            -- Stage 1 visual feedback: distinct highlight (yellowish)
            r, g, b = 0.85, 0.85, 0.1
            alpha = 0.75
        elseif Addon.gphPendingQuality[q] and count > 0 then
            r, g, b = 0.9, 0.2, 0.2
            alpha = 0.85
        end
        
        local isSelectedFilter = gphFrame and gphFrame.gphFilterQuality == q and not (delStage or Addon.gphPendingQuality[q])
        local isProtectedRarity = rarityFlags and rarityFlags[q]

        if isSelectedFilter then
            r = math.min(1, r * 2.2)
            g = math.min(1, g * 2.2)
            b = math.min(1, b * 2.2)
            alpha = 0.95
        elseif gphFrame and gphFrame.gphFilterQuality ~= nil and gphFrame.gphFilterQuality ~= q then
            -- Desaturate non-selected rarity buttons when a filter is active
            r = (r + 0.5) * 0.5
            g = (g + 0.5) * 0.5
            b = (b + 0.5) * 0.5
            alpha = 0.22
        end
        -- Clear all border/backdrop state so style is never "stuck" from a previous toggle (e.g. Item details)
        if qualBtn.SetBackdrop then qualBtn:SetBackdrop(nil) end
        if qualBtn._rarityBorderFrame then qualBtn._rarityBorderFrame:Hide(); qualBtn._rarityBorderFrame:SetBackdrop(nil) end
        if qualBtn._rarityBorderTop then qualBtn._rarityBorderTop:Hide() end
        if qualBtn._rarityBorderBottom then qualBtn._rarityBorderBottom:Hide() end
        if qualBtn._rarityBorderLeft then qualBtn._rarityBorderLeft:Hide() end
        if qualBtn._rarityBorderRight then qualBtn._rarityBorderRight:Hide() end
        if qualBtn._borderTop then qualBtn._borderTop:Hide() end
        if qualBtn._borderBottom then qualBtn._borderBottom:Hide() end
        if qualBtn._borderLeft then qualBtn._borderLeft:Hide() end
        if qualBtn._borderRight then qualBtn._borderRight:Hide() end
        if useOriginalRarity then
            local tb = gphFrame._originalTitleBg
            local br = math.min(1, (tb[1] or 0.35) * 0.6 + r * 0.4)
            local bg = math.min(1, (tb[2] or 0.28) * 0.6 + g * 0.4)
            local bb = math.min(1, (tb[3] or 0.1) * 0.6 + b * 0.4)
            -- If this rarity is selected or protected, punch the fill brighter and less transparent
            -- so it's clearly stronger than simple hover or unselected states.
            local isBright = isSelectedFilter or isProtectedRarity
            local fillAlpha = isBright and 0.95 or 0.72
            if isBright then
                br = math.min(1, br * 1.5)
                bg = math.min(1, bg * 1.5)
                bb = math.min(1, bb * 1.5)
            end
            -- Inset the colored fill slightly so it never bleeds under the textured border.
            qualBtn.bg:ClearAllPoints()
            qualBtn.bg:SetPoint("TOPLEFT", qualBtn, "TOPLEFT", 1, -1)
            qualBtn.bg:SetPoint("BOTTOMRIGHT", qualBtn, "BOTTOMRIGHT", -1, 1)
            qualBtn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            qualBtn.bg:SetVertexColor(br, bg, bb, fillAlpha)
            Skins.AddRarityBorder(qualBtn, gphFrame._originalMainBorder, gphFrame._originalEdgeFile, gphFrame._originalEdgeSize)
            if qualBtn.hl then qualBtn.hl:SetVertexColor(1, 1, 1, 0.12) end
        else
            -- Non-original skins: flat fill that matches the full button size.
            qualBtn.bg:ClearAllPoints()
            qualBtn.bg:SetAllPoints()
            qualBtn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            qualBtn.bg:SetVertexColor(r, g, b, alpha)
            if qualBtn.hl then qualBtn.hl:SetVertexColor(1, 1, 1, 0.30) end
        end

        local fs = qualBtn.fs
        if not fs then
            fs = qualBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetAllPoints()
            fs:SetJustifyH("CENTER")
            fs:SetWordWrap(false)
            qualBtn.fs = fs
        end
        if Addon.gphPendingQuality[q] and count > 0 then
            fs:SetText("|cffff0000DEL|r")
            fs:SetAlpha(1)
        elseif Addon.gphContinuousDelActive and Addon.gphContinuousDelActive[q] then
            fs:SetText("|cffff0000DEL|r")
        else
            -- When this button is the active filter, use a light tint of the rarity color so the number stands out from the bright background
            local textHex = info.hex or "888888"
            if gphFrame and gphFrame.gphFilterQuality == q and not (delStage or Addon.gphPendingQuality[q]) then
                local ir, ig, ib = info.r or 0.5, info.g or 0.5, info.b or 0.5
                local lr = math.floor(math.min(1, ir * 0.35 + 0.82) * 255)
                local lg = math.floor(math.min(1, ig * 0.35 + 0.82) * 255)
                local lb = math.floor(math.min(1, ib * 0.35 + 0.82) * 255)
                textHex = ("%02x%02x%02x"):format(lr, lg, lb)
            end
            fs:SetText(labelText ~= "" and ("|cff" .. textHex .. labelText .. "|r") or "")
            -- Only show if hovered or in DEL state (OnUpdate/OnEnter/OnLeave handle the alpha transition)
            local isHovered = (GetMouseFocus and GetMouseFocus() == qualBtn)
            fs:SetAlpha(isHovered and 1 or 0)
        end
        table.insert(header and header.headerElements or content.headerElements, qualBtn)
    end

    if headerParent.LayoutGPHQualityButtons then
        headerParent:LayoutGPHQualityButtons()
    end

    if headerParent and not headerParent._fugaziLayoutHooked then
        headerParent._fugaziLayoutHooked = true
        headerParent.LayoutGPHQualityButtons = function(self)
            local qbTable = self.qualityButtons
            if not qbTable then return end
            -- Symmetry (Header is inset 32px total from frame; stopping 4px inside header = 18px border gap).
            local w = self:GetWidth() or 300
            local rw = w - 4 -- rightEdgeGap
            local sw = math.floor((rw - 48 - 16) / 5) -- startX is 48, spacing is 4*4
            if sw < 8 then sw = 8 end
            for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
                local btn = qbTable[q]
                if btn then
                    btn:SetSize(sw, 14) -- ROW_H
                    btn:ClearAllPoints()
                    btn:SetPoint("LEFT", self, "LEFT", 48 + (i - 1) * (sw + 4), 0) -- Vertical center alignment to match bank
                end
            end
        end
        headerParent:HookScript("OnSizeChanged", function() headerParent:LayoutGPHQualityButtons() end)
        headerParent:LayoutGPHQualityButtons()
    end

    -- Per-item protected set is not auto-cleaned: it persists until the user explicitly unprotects (Ctrl+click or unmark dialog).
    -- (Previously we removed ids not in bags/equipped here, which wiped the set after reload when ScanBags was still incomplete.)

    -- Grid mode: header/rarity buttons are set up above; skip list-row creation.
    if gphFrame.gphGridMode then return end

    local yOff = 0  -- item list starts at top of scroll content (header is fixed above)
    local sortMode = DB.gphSortMode or "rarity"

    if sortMode == "vendor" then
        table.sort(itemList, GPH_Sort_Vendor)
    elseif sortMode == "itemlevel" then
        table.sort(itemList, GPH_Sort_ItemLevel)
    else
        table.sort(itemList, GPH_Sort_Rarity)
    end

    -- Order: (*) protected first (above divider), then hearthstone (6948), then rest.
    do
        local protectedSet = Addon.GetGphProtectedSet()
        local rFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags()
        if not Addon._gphAboveHearthPool then Addon._gphAboveHearthPool = {} end
        if not Addon._gphHearthPool then Addon._gphHearthPool = {} end
        if not Addon._gphRestPool then Addon._gphRestPool = {} end
        wipe(Addon._gphAboveHearthPool); wipe(Addon._gphHearthPool); wipe(Addon._gphRestPool)
        local aboveHearth = Addon._gphAboveHearthPool
        local hearth = Addon._gphHearthPool
        local rest = Addon._gphRestPool
        for _, item in ipairs(itemList) do
            if item.itemId == 6948 then
                table.insert(hearth, item)
            elseif item.isProtected or (item.itemId and protectedSet[item.itemId]) or (rFlags and item.quality and rFlags[item.quality]) then
                item.isProtected = true
                table.insert(aboveHearth, item)
            else
                table.insert(rest, item)
            end
        end
        wipe(Addon.gphItemList)
        itemList = Addon.gphItemList
        for _, item in ipairs(aboveHearth) do table.insert(itemList, item) end
        for _, item in ipairs(hearth) do table.insert(itemList, item) end
        for _, item in ipairs(rest) do table.insert(itemList, item) end
    end

    -- Filter by selected rarity; epic (4) shows epic + legendary + artifact (4, 5, 6)
    if gphFrame.gphFilterQuality ~= nil then
        local q = gphFrame.gphFilterQuality
        if not Addon._gphFilterPool1 then Addon._gphFilterPool1 = {} end
        wipe(Addon._gphFilterPool1)
        local filtered = Addon._gphFilterPool1
        for _, item in ipairs(itemList) do
            local iq = item.quality or 0
            if iq == q or (q == 4 and (iq == 5 or iq == 6 or iq == 7)) then table.insert(filtered, item) end
        end
        itemList = filtered
    end

    -- Filter by GPH search (item name or rarity); exact quality label so "common" only white, "uncomm" only green
    if gphFrame.gphSearchText and gphFrame.gphSearchText ~= "" then
        local searchLower = gphFrame.gphSearchText:lower():match("^%s*(.-)%s*$")
        local exactQuality = nil
        for q = 0, 7 do
            local info = Addon.QUALITY_COLORS[q]
            if info and info.label and info.label:lower() == searchLower then
                exactQuality = q
                break
            end
        end
        if not Addon._gphSearchPool then Addon._gphSearchPool = {} end
        wipe(Addon._gphSearchPool)
        local filtered = Addon._gphSearchPool
        for _, item in ipairs(itemList) do
            if exactQuality ~= nil then
                if item.quality == exactQuality then table.insert(filtered, item) end
            else
                local itemMatches = (item.name and item.name:lower():find(searchLower, 1, true))
                local qualityMatches = false
                for q = 0, 7 do
                    local info = Addon.QUALITY_COLORS[q]
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
    local destroyList = Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
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
                    destroyList[did] = { name = n, texture = t, addedTime = time() }
                    storedName, storedTex = n, t
                end
            end
            local name = storedName or (GetItemInfo and GetItemInfo(did)) or ("Item " .. tostring(did))
            local prevWornSet = Addon.GetGphProtectedSet()
            local previouslyWornOnlySet = Addon.GetGphPreviouslyWornOnlySet()
            local _, _, q = GetItemInfo and GetItemInfo(did)
            q = q or 0
            local rFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags()
            local isProtected = prevWornSet[did] or (rFlags and q and rFlags[q])
            local itm = Addon.GetRecycledItemTable()
            itm.itemId = did
            itm.link = "item:" .. did
            itm.name = name
            itm.texture = storedTex or (GetItemInfo and select(10, GetItemInfo(did)))
            itm.count = 0
            itm.quality = q or 0
            itm.sellPrice = 0
            itm.itemLevel = (GetItemInfo and select(4, GetItemInfo(did))) or 0
            itm.isProtected = isProtected and true or nil
            itm.previouslyWorn = (did and previouslyWornOnlySet[did]) and true or nil
            itm.isDestroy = true
            itm.addedTime = (type(info) == "table" and info.addedTime) or 0
            itm.bag = nil
            itm.slot = nil
            table.insert(itemList, itm)
        end
    end
    -- Push destroy-list items to the very bottom (preserve order). Build itemList as new table so we don't mutate normal (needed for non-category draw list).
    -- Push destroy-list items to the very bottom (preserve order). Recycle list tables.
    local normal = Addon._gphNormalPool
    local destroyed = Addon._gphDestroyedPool
    wipe(normal); wipe(destroyed)
    for _, item in ipairs(itemList) do
        if item.itemId and destroyList[item.itemId] then
            item.isDestroy = true
            local info = destroyList[item.itemId]
            item.addedTime = (type(info) == "table" and info.addedTime) or 0
            table.insert(destroyed, item)
        else
            table.insert(normal, item)
        end
    end
    -- Sort destroyed pool by last added item (newest first)
    table.sort(destroyed, function(a, b)
        local atA = a.addedTime or 0
        local atB = b.addedTime or 0
        if atA ~= atB then return atA > atB end
        return (a.name or "") < (b.name or "")
    end)
    wipe(itemList)
    for _, item in ipairs(normal) do table.insert(itemList, item) end
    for _, item in ipairs(destroyed) do table.insert(itemList, item) end

    -- Use file-scoped GPH_BAG_PROTECTED_CATEGORY_ORDER
    gphFrame.gphCategoryGroups = nil
    gphFrame.gphCategoryItemList = nil
    if sortMode == "category" and #itemList > 0 and GetItemInfo then
        local typeCache = DB.gphItemTypeCache
        if type(typeCache) ~= "table" then
            typeCache = {}
            DB.gphItemTypeCache = typeCache
        end
        for _, item in ipairs(itemList) do
            local itemId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
            local itemType
            if itemId == 6948 then
                itemType = "HIDDEN_FIRST"
            elseif item.isProtected then
                itemType = "BAG_PROTECTED"
            else
                itemType = itemId and typeCache[itemId]
                if not itemType then
                    local giName, _, _, _, _, giType = GetItemInfo(item.link or item.itemId)
                    if giName == nil and item.itemId then
                        itemType = "UNKNOWN"
                    else
                        itemType = (giType and giType ~= "" and giType) or "Other"
                        if itemId then typeCache[itemId] = itemType end
                    end
                end
            end
            item.itemType = itemType
        end
        if not Addon._gphGroups then Addon._gphGroups = {} end
        wipe(Addon._gphGroups)
        local groups = Addon._gphGroups
        for _, item in ipairs(itemList) do
            local t = (item.itemId and destroyList[item.itemId]) and "DELETE" or (item.itemType or "Other")
            if not groups[t] then groups[t] = Addon.GetRecycledItemTable() end
            table.insert(groups[t], item)
        end
        for _, items in pairs(groups) do
            table.sort(items, function(a, b)
                if a.isDestroy and b.isDestroy then
                    local atA = a.addedTime or 0
                    local atB = b.addedTime or 0
                    if atA ~= atB then return atA > atB end
                    return (a.name or "") < (b.name or "")
                end
                return GPH_Sort_CategoryGroup(a, b)
            end)
        end
        if not Addon._gphOrderedGroups then Addon._gphOrderedGroups = {} end
        wipe(Addon._gphOrderedGroups)
        local orderedGroups = Addon._gphOrderedGroups
        for _, catName in ipairs(GPH_BAG_PROTECTED_CATEGORY_ORDER) do
            if groups[catName] and #groups[catName] > 0 then
                local grpEntry = Addon.GetRecycledItemTable()
                grpEntry.name = catName
                grpEntry.items = groups[catName]
                table.insert(orderedGroups, grpEntry)
            end
        end
        for catName, items in pairs(groups) do
            if catName ~= "DELETE" then
                local found = false
                for _, c in ipairs(GPH_BAG_PROTECTED_CATEGORY_ORDER) do if c == catName then found = true break end end
                if not found then 
                    local grpEntry = Addon.GetRecycledItemTable()
                    grpEntry.name = catName
                    grpEntry.items = items
                    table.insert(orderedGroups, grpEntry)
                end
            end
        end
        -- DELETE header at bottom: all autodelete items in one collapsible section
        if groups["DELETE"] and #groups["DELETE"] > 0 then
            local grpEntry = Addon.GetRecycledItemTable()
            grpEntry.name = "DELETE"
            grpEntry.items = groups["DELETE"]
            table.insert(orderedGroups, grpEntry)
        end
        gphFrame.gphCategoryGroups = orderedGroups
        if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
        local flat = Addon._gphFlatPool
        local drawList = Addon._gphDrawListPool
        wipe(flat); wipe(drawList)
        for _, grp in ipairs(orderedGroups) do
            local collapsed = (grp.name == "DELETE") and (gphFrame.gphCategoryCollapsed["DELETE"] ~= false) or gphFrame.gphCategoryCollapsed[grp.name]
            local divEntry = Addon.GetRecycledItemTable()
            divEntry.divider = grp.name
            divEntry.collapsed = collapsed
            table.insert(drawList, divEntry)
            if not collapsed then
                for _, item in ipairs(grp.items) do
                    table.insert(drawList, item)
                    table.insert(flat, item)
                end
            end
        end
        gphFrame.gphCategoryItemList = flat
        gphFrame.gphCategoryDrawList = drawList
        -- Item types can load async; schedule one short delayed refresh IF needed (only if some items were unknown-category)
        local needsAsyncRefresh = false
        for _, item in ipairs(itemList) do if item.itemType == "UNKNOWN" then needsAsyncRefresh = true; break end end
        if needsAsyncRefresh and not (Addon.gphCategoryRefreshFrame and Addon.gphCategoryRefreshFrame._categoryScheduled) then
            if not Addon.gphCategoryRefreshFrame then Addon.gphCategoryRefreshFrame = CreateFrame("Frame") end
            local cf = Addon.gphCategoryRefreshFrame
            cf._categoryScheduled = true
            cf._categoryAccum = 0
            cf:SetScript("OnUpdate", function(self, elapsed)
                self._categoryAccum = (self._categoryAccum or 0) + elapsed
                if self._categoryAccum >= 2.0 then -- Further increase delay and add safety
                    self:SetScript("OnUpdate", nil)
                    self._categoryScheduled = nil
                    -- Only retry 3 times per second max globally via gphFrame check
                    local now = GetTime()
                    if gphFrame and gphFrame:IsShown() and DB and DB.gphSortMode == "category" and RefreshGPHUI then
                        if not gphFrame._lastCategoryRetry or (now - gphFrame._lastCategoryRetry) > 5 then
                            gphFrame._lastCategoryRetry = now
                            RefreshGPHUI()
                        end
                    end
                end
            end)
        end
    else
        gphFrame.gphCategoryGroups = nil
        gphFrame.gphCategoryItemList = nil
        -- For rarity/vendor/itemlevel: DELETE section at bottom; main list has ONLY normal items (no destroy-list items there = no duplication)
        if #destroyed > 0 then
            if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
            local deleteCollapsed = (gphFrame.gphCategoryCollapsed["DELETE"] ~= false)
            local drawList = Addon._gphDrawListPool
            wipe(drawList)
            for _, item in ipairs(normal) do table.insert(drawList, item) end
            local delDiv = Addon.GetRecycledItemTable()
            delDiv.divider = "DELETE"
            delDiv.collapsed = deleteCollapsed
            table.insert(drawList, delDiv)
            if not deleteCollapsed then
                for _, item in ipairs(destroyed) do table.insert(drawList, item) end
            end
            local flat = Addon._gphFlatPool
            wipe(flat)
            for _, item in ipairs(normal) do table.insert(flat, item) end
            if not deleteCollapsed then for _, item in ipairs(destroyed) do table.insert(flat, item) end end
            gphFrame.gphCategoryDrawList = drawList
            gphFrame.gphCategoryItemList = flat
        else
            gphFrame.gphCategoryDrawList = nil
        end
    end

    if #itemList == 0 then
        local noItems = Addon.GetGPHText(content)
        noItems:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        noItems:SetText("")
        -- Nothing selectable, so clear selection.
        if gphFrame then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedBag = nil
            gphFrame.gphSelectedSlot = nil
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
        local itemIdToSlot = Addon.GetItemIdToBagSlot()
        Addon._gphIdToSlotTempCached = itemIdToSlot -- Cache for the rows to see without re-scanning
        local listToUse = gphFrame.gphCategoryDrawList or itemList
        local listForAdvance = gphFrame.gphCategoryItemList or itemList
        local itemIdx = 0
        local dividerIndex = 0
        if gphFrame.gphCategoryDividerPool then for _, d in ipairs(gphFrame.gphCategoryDividerPool) do d:Hide() end end
        for idx, entry in ipairs(listToUse) do
            if entry.divider and entry.divider ~= "HIDDEN_FIRST" and entry.divider ~= "BAG_PROTECTED" then
                dividerIndex = dividerIndex + 1
                if not gphFrame.gphCategoryDividerPool then gphFrame.gphCategoryDividerPool = {} end
                local pool = gphFrame.gphCategoryDividerPool
                local div = pool[dividerIndex]
                if not div then
                    -- Visual header frame (not clickable itself)
                    div = CreateFrame("Button", nil, content)
                    div:EnableMouse(true)
                    div:SetScript("OnClick", function(self)
                        if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
                        local cat = self.categoryName
                        local isCollapsed = (cat == "DELETE") and (gphFrame.gphCategoryCollapsed["DELETE"] ~= false) or gphFrame.gphCategoryCollapsed[cat]
                        gphFrame.gphCategoryCollapsed[cat] = not isCollapsed
                        if RefreshGPHUI then RefreshGPHUI() end
                    end)
                    local tex = div:CreateTexture(nil, "ARTWORK")
                    tex:SetTexture(0.4, 0.35, 0.2, 0.7)
                    tex:SetPoint("TOPLEFT", div, "TOPLEFT", 0, 0)
                    tex:SetPoint("TOPRIGHT", div, "TOPRIGHT", 0, 0)
                    tex:SetHeight(1)
                    div.tex = tex
                    local label = div:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    label:SetPoint("LEFT", div, "LEFT", 4, 0)
                    label:SetJustifyH("LEFT")
                    label:SetFont("Fonts\\ARIALN.TTF", 11, "")
                    div.label = label
                    -- Small collapse indicator on the LEFT (icon), label to the right
                    local toggle = CreateFrame("Frame", nil, div)
                    toggle:SetSize(14, 12)
                    toggle:SetPoint("BOTTOMLEFT", div, "BOTTOMLEFT", 0, 0)
                    local tfs = toggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    tfs:SetPoint("CENTER")
                    tfs:SetFont("Fonts\\ARIALN.TTF", 10, "")
                    toggle.text = tfs
                    local ti = toggle:CreateTexture(nil, "ARTWORK")
                    ti:SetAllPoints()
                    ti:SetTexture("Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
                    toggle.icon = ti
                    div.toggleBtn = toggle
                    -- Label just right of toggle; both sit below the line with a gap
                    div.label:ClearAllPoints()
                    div.label:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
                    div:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Click to collapse/expand")
                        GameTooltip:Show()
                        if self.categoryName == "DELETE" then
                            if self.label then self.label:SetAlpha(0.7) end
                            if self.toggleBtn and self.toggleBtn.text then self.toggleBtn.text:SetAlpha(0.7) end
                            if self.toggleBtn and self.toggleBtn.icon then self.toggleBtn.icon:SetAlpha(0.7) end
                        end
                    end)
                    div:SetScript("OnLeave", function(self)
                        GameTooltip:Hide()
                        if self.categoryName == "DELETE" then
                            if self.label then self.label:SetAlpha(0.4) end
                            if self.toggleBtn and self.toggleBtn.text then self.toggleBtn.text:SetAlpha(0.4) end
                            if self.toggleBtn and self.toggleBtn.icon then self.toggleBtn.icon:SetAlpha(0.4) end
                        end
                    end)
                    table.insert(pool, div)
                end
                local catName = entry.divider or ""
                local collapsed = entry.collapsed
                local isDelete = (catName == "DELETE")
                yOff = yOff + 4  -- gap above colored line
                div:SetParent(content)
                div:ClearAllPoints()
                div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
                div:SetHeight(16)  -- 1px line + 4px gap + 11px text row
                if div.tex then
                    if isDelete then div.tex:SetTexture(0.32, 0.14, 0.14, 0.65) else div.tex:SetTexture(0.1, 0.3, 0.15, 0.7) end
                end
                -- Label: category text; DELETE shows "Autodelete" italic, alpha 0.4 (0.7 on hover). Font/size from Scale Settings when custom.
                local fontPath, fontSize = GetCategoryHeaderFontAndSize()
                if isDelete then
                    div.label:SetText("|cff9a7070Autodelete|r")
                    div.label:SetFont(fontPath, fontSize, "ITALIC")
                    div.label:SetAlpha(0.4)
                else
                    div.label:SetText("|cff8a9a9a" .. catName .. "|r")
                    div.label:SetFont(fontPath, fontSize, "")
                    div.label:SetAlpha(1)
                end
                local SVinv = _G.FugaziBAGSDB
                local headerColorInv = (SVinv and SVinv.gphCategoryHeaderFontCustom and SVinv.gphSkinOverrides and SVinv.gphSkinOverrides.headerTextColor) and SVinv.gphSkinOverrides.headerTextColor
                local useHeaderColorInv = headerColorInv and #headerColorInv >= 4
                if useHeaderColorInv then
                    div.label:SetText(isDelete and "Autodelete" or catName)
                    div.label:SetTextColor(headerColorInv[1], headerColorInv[2], headerColorInv[3], headerColorInv[4])
                end
                -- Scale the icon frame in proportion to header font size so icon stays visually matched.
                if div.toggleBtn and fontSize then
                    local base = math.max(10, fontSize)
                    if isDelete then
                        div.toggleBtn:SetSize(base - 2, base - 4)
                    else
                        div.toggleBtn:SetSize(base, base)
                    end
                end
                div.label:Show()
                div.categoryName = catName
                -- Toggle button: only this small area is clickable to collapse/expand; icon tint/alpha indicates state
                if div.toggleBtn then
                    if div.toggleBtn.text then
                        -- Hide legacy [+]/[−] text.
                        div.toggleBtn.text:SetText("")
                    end
                    if div.toggleBtn.icon then
                        local r, g, b = 1, 1, 1
                        if useHeaderColorInv then
                            r, g, b = headerColorInv[1], headerColorInv[2], headerColorInv[3]
                        end
                        if isDelete then
                            div.toggleBtn.icon:SetTexture(collapsed
                                and "Interface\\AddOns\\__FugaziBAGS\\media\\expand.blp"
                                or  "Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
                            div.toggleBtn.icon:SetAlpha(collapsed and 0.7 or 0.4)
                            div.toggleBtn.icon:SetVertexColor(r, g, b, 1)
                        else
                            div.toggleBtn.icon:SetTexture(collapsed
                                and "Interface\\AddOns\\__FugaziBAGS\\media\\expand.blp"
                                or  "Interface\\AddOns\\__FugaziBAGS\\media\\collapse.blp")
                            div.toggleBtn.icon:SetAlpha(collapsed and 1.0 or 0.7)
                            div.toggleBtn.icon:SetVertexColor(r, g, b, 1)
                        end
                    end
                    div.toggleBtn:Show()
                end
                div:Show()
                -- Defer: if DELETE row and mouse not over it, force dim alpha (avoids looking "on" from spurious OnEnter when frame is shown)
                if isDelete then
                    local defer = CreateFrame("Frame")
                    defer:SetScript("OnUpdate", function(self)
                        self:SetScript("OnUpdate", nil)
                        if div.categoryName == "DELETE" and div:IsVisible() and not div:IsMouseOver() then
                            if div.label then div.label:SetAlpha(0.4) end
                            if div.toggleBtn and div.toggleBtn.text then div.toggleBtn.text:SetAlpha(0.4) end
                        end
                    end)
                end
                yOff = yOff + 16 + 4  -- row height (line+gap+text) + gap below line
            elseif entry.divider and (entry.divider == "HIDDEN_FIRST" or entry.divider == "BAG_PROTECTED") then
                -- No header, just continue
            else
                itemIdx = (gphFrame.gphCategoryDrawList and (itemIdx + 1)) or idx
                local item = entry
                if gphFrame then
                    gphFrame.gphItemIndexToY = gphFrame.gphItemIndexToY or {}
                    gphFrame.gphItemIndexToY[itemIdx] = yOff
                end
            -- Divider line: draw above hearthstone so hearthstone is always the first row under the spacer
            local curHearth = item.itemId == 6948 or (item.link and item.link:match("item:6948"))
            local rowBelowDivider = false
            if curHearth then
                if not gphFrame.gphHearthSpacerFrame then
                    local frame = CreateFrame("Frame", nil, content)
                    frame:EnableMouse(false)
                    local tex = frame:CreateTexture(nil, "ARTWORK")
                    tex:SetTexture(0.5, 0.42, 0.18, 0.75)
                    tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -4)
                    tex:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -4)
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
                spacer:SetHeight(10)
                spacer:Show()
                if spacer.tex then spacer.tex:SetHeight(1); spacer.tex:Show() end
                yOff = yOff + 10
                if gphFrame.gphDefaultScrollY == nil then
                    gphFrame.gphDefaultScrollY = yOff  -- top of hearthstone row (first row under divider)
                end
                rowBelowDivider = true
            end
            local btn = Addon.GetGPHItemBtn(content)
            local rowOk, rowErr = pcall(UpdateGPHRowVisuals, btn, item, itemIdx, yOff, rowBelowDivider, destroyList, gphFrame, itemIdToSlot)
            if rowOk then
                local rowItemId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
                local capturedId = item.itemId or rowItemId
                local isSelected = gphFrame and (
                    (item.bag ~= nil and item.slot ~= nil and gphFrame.gphSelectedBag == item.bag and gphFrame.gphSelectedSlot == item.slot)
                    or (item.bag == nil and gphFrame.gphSelectedItemId and capturedId == gphFrame.gphSelectedItemId)
                    or (gphFrame.gphSelectedIndex and gphFrame.gphSelectedIndex == itemIdx)
                )
                if isSelected then
                    selectedStillExists = true
                    selectedRowBtn = btn
                    gphFrame.gphSelectedIndex = itemIdx
                    gphFrame.gphSelectedRowY = yOff
                    gphFrame.gphSelectedBag = item.bag
                    gphFrame.gphSelectedSlot = item.slot
                end
            else
                Addon.AddonPrint("[Fugazi] GPH row " .. tostring(itemIdx) .. " error: " .. tostring(rowErr))
            end
            -- Advance by the same dynamic row height used in UpdateGPHRowVisuals so bigger icons get more vertical space.
            local rowStep = ComputeItemDetailsRowHeight(18)
            yOff = yOff + rowStep
            end
        end
        -- If the previously selected item no longer exists (e.g. used/consumed), advance to next row; do NOT pick first item when there was no selection (stops blink after reload)
        if gphFrame and not selectedStillExists and hadSelectedItemId then
            local nextIdx = gphFrame.gphSelectedIndex and math.min(gphFrame.gphSelectedIndex, #listForAdvance) or 1
            local nextItem = listForAdvance[nextIdx]
            if nextItem and nextItem.link then
                local nextId = tonumber(nextItem.link:match("item:(%d+)"))
                if nextId then
                    gphFrame.gphSelectedItemId = nextId
                    gphFrame.gphSelectedIndex = nextIdx
                    gphFrame.gphSelectedRowBtn = nil  -- overlay would be on stale row after scroll; next refresh will set correct row
                    -- Keep next row under the mouse: scroll so its Y matches the old selected row's position.
                    -- Skip or cap when used item was at top (oldRowY small) or scroll delta is huge (intermediate BAG_UPDATE before unequip in bags).
                    local oldRowY = gphFrame.gphSelectedRowY
                    local idxToY = gphFrame.gphItemIndexToY
                    local oldScroll = gphFrame.gphScrollOffset or 0
                    if oldRowY and idxToY and idxToY[nextIdx] then
                        local newRowY = idxToY[nextIdx]
                        local wantScroll = newRowY - oldRowY + oldScroll
                        -- Used row was near top (e.g. first 2 rows): next item is at top, keep scroll 0.
                        if oldRowY <= 40 then
                            gphFrame.gphScrollToRowYOnLayout = 0
                        -- Huge jump suggests wrong list state (e.g. equip: first BAG_UPDATE has no unequipped item yet). Cap delta to ~4 rows.
                        elseif math.abs(wantScroll - oldScroll) > 80 then
                            gphFrame.gphScrollToRowYOnLayout = nil  -- don't change scroll
                        else
                            gphFrame.gphScrollToRowYOnLayout = wantScroll
                        end
                    end
                    -- Reused selection defer frame: Reuse existing one to prevent frame churn
                    local df = Addon._gphSelectionDeferFrame
					if df then
						df:Show()
						df:SetScript("OnUpdate", function(self)
							self:SetScript("OnUpdate", nil)
							self:Hide()
							if RefreshGPHUI then RefreshGPHUI() end
						end)
					end
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
        if gphFrame and selectedRowBtn and gphFrame.gphSelectedItemId then
            gphFrame.gphSelectedRowBtn = selectedRowBtn
        end
    end

    yOff = yOff + 8
    -- Invisible bottom spacer so we can always scroll to "hearthstone at top" even with many protected items above
    local viewHeight = gphFrame.scrollFrame and gphFrame.scrollFrame:GetHeight() or 0
    local fillerHeight = 0
    if gphFrame.gphDefaultScrollY and viewHeight > 0 then
        fillerHeight = math.max(0, gphFrame.gphDefaultScrollY + viewHeight - yOff)
    end
    if fillerHeight > 0 then
        if not gphFrame.gphBottomSpacer then
            local spacer = CreateFrame("Frame", nil, content)
            spacer:EnableMouse(false)
            spacer:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            gphFrame.gphBottomSpacer = spacer
        end
        local spacer = gphFrame.gphBottomSpacer
        spacer:SetParent(content)
        spacer:ClearAllPoints()
        spacer:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
        spacer:SetSize(SCROLL_CONTENT_WIDTH or 296, fillerHeight)
        spacer:Show()
    elseif gphFrame.gphBottomSpacer then
        gphFrame.gphBottomSpacer:Hide()
    end
    content:SetHeight(yOff + fillerHeight)
    -- Do NOT call UpdateScrollChildRect here: on some clients it resets the scroll child position and locks the list.
        if gphFrame.gphScrollBar then
            viewHeight = gphFrame.scrollFrame:GetHeight()
            local contentHeight = content:GetHeight()
            local maxScroll = math.max(0, contentHeight - viewHeight)
            local cur = gphFrame.gphScrollOffset or 0
            -- When opening GPH: category sort = start at top (Weapon etc.); other sorts = hearthstone at top (saved items above).
            -- Center on "Home Base" (Hearthstone) for all modes. Defer re-apply by one frame so layout has settled (fixes B-open not showing hearthstone at top).
            if gphFrame.gphScrollToDefaultOnNextRefresh then
                if gphFrame.gphDefaultScrollY and maxScroll > 0 then
                    cur = math.min(gphFrame.gphDefaultScrollY, maxScroll)
                    gphFrame.gphScrollToDefaultOnNextRefresh = nil
                    gphFrame._pendingScrollToDefault = cur
                elseif maxScroll == 0 then
                    -- List isn't fully built or scrollable yet; don't consume the flag yet
                    cur = 0
                else
                    cur = 0
                    gphFrame.gphScrollToDefaultOnNextRefresh = nil
                end
            end
            -- After advance-on-use: scroll so the next row stays under the mouse (same visual position).
            if gphFrame.gphScrollToRowYOnLayout then
                cur = math.max(0, math.min(maxScroll, gphFrame.gphScrollToRowYOnLayout))
                gphFrame.gphScrollToRowYOnLayout = nil
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
        Addon.AddonPrint("[Fugazi] GPH refresh error: " .. tostring(refreshErr))
    end
    -- One-frame defer: re-apply "scroll to hearthstone at top" after layout has settled (fixes B-open homebase not showing).
    -- Apply twice (frame N+1 and N+2) so it sticks even if layout or scroll bar resets position after first apply.
    if refreshOk and gphFrame and gphFrame._pendingScrollToDefault ~= nil then
        local wantCur = gphFrame._pendingScrollToDefault
        local f = gphFrame
        local df = Addon._gphScrollToDefaultDeferFrame
        if not df then
            df = CreateFrame("Frame")
            Addon._gphScrollToDefaultDeferFrame = df
        end
        local function applyHomebaseScroll()
            if not (f and f.gphScrollBar and f.scrollFrame) then return end
            if f.gphGridMode then return end
            local content = f.scrollFrame:GetScrollChild()
            local viewHeight = f.scrollFrame:GetHeight()
            local contentHeight = content and content:GetHeight() or 0
            local maxScroll = math.max(0, contentHeight - viewHeight)
            local cur = math.min(wantCur, maxScroll)
            f.gphScrollOffset = cur
            f.gphScrollBar:SetMinMaxValues(0, maxScroll)
            f.gphScrollBar:SetValue(cur)
            if content then
                content:ClearAllPoints()
                content:SetPoint("TOPLEFT", f.scrollFrame, "TOPLEFT", 0, cur)
                content:SetWidth(SCROLL_CONTENT_WIDTH)
            end
        end
        local runCount = 0
        df:SetScript("OnUpdate", function(self, elapsed)
            runCount = runCount + 1
            if runCount == 1 then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                f._pendingScrollToDefault = nil
                applyHomebaseScroll()
                -- Second apply next frame in case layout overwrote the scroll
                if f and f.scrollFrame and not f.gphGridMode then
                    local df2 = Addon._gphScrollToDefaultDeferFrame2
                    if not df2 then df2 = CreateFrame("Frame"); Addon._gphScrollToDefaultDeferFrame2 = df2 end
                    df2:SetScript("OnUpdate", function(self2)
                        self2:SetScript("OnUpdate", nil)
                        self2:Hide()
                        applyHomebaseScroll()
                    end)
                    df2:Show()
                end
            end
        end)
        df:Show()
    end
end

--- Show or hide inventory (container: list out of combat, combat grid in combat).
local function ToggleGPHFrame()
    if _G.TestGPHFrame then gphFrame = _G.TestGPHFrame end
    if not gphFrame then gphFrame = CreateGPHFrame() end
    local container = _G.FugaziBAGS_InventoryContainer or (gphFrame and gphFrame.gphInventoryContainer)
    if container then
        if container:IsShown() then
            if gphFrame:IsShown() then Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint") end
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedItemLink = nil
            container:Hide()
        else
            local SV = _G.FugaziBAGSDB
            if not (SV and SV.gphPoint and SV.gphPoint.point) then
                gphFrame:ClearAllPoints()
                -- Default matches your chosen layout: RIGHT of screen with offsets -444, -4.
                gphFrame:SetPoint("RIGHT", UIParent, "RIGHT", -444, -4)
            end
            local base = (SV and SV.gphScale15) and 1.5 or 1
            local extra = (SV and SV.gphFrameScale) or 1
            gphFrame:SetScale(base * extra)
            if gphFrame.gphDestroyBtn then gphFrame.gphDestroyBtn:SetScale(base * extra) end
            ApplyFrameAlpha(gphFrame)
            if gphFrame.ApplySkin then gphFrame.ApplySkin() end
            if ApplyCustomizeToFrame then ApplyCustomizeToFrame(gphFrame) end
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            gphFrame.gphScrollToDefaultOnNextRefresh = true
            container:Show()
            if gphFrame then gphFrame._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
            if gphFrame and gphFrame.UpdateGPHCollapse and not gphFrame.gphGridMode then gphFrame:UpdateGPHCollapse() end
            if gphFrame:IsShown() then Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint") end
        end
    else
        if gphFrame:IsShown() then
            Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
            gphFrame:Hide()
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedItemLink = nil
        else
            local SV = _G.FugaziBAGSDB
            if not (SV and SV.gphPoint and SV.gphPoint.point) then
                gphFrame:ClearAllPoints()
                gphFrame:SetPoint("RIGHT", UIParent, "RIGHT", -444, -4)
            end
            local base = (SV and SV.gphScale15) and 1.5 or 1
            local extra = (SV and SV.gphFrameScale) or 1
            gphFrame:SetScale(base * extra)
            if gphFrame.gphDestroyBtn then gphFrame.gphDestroyBtn:SetScale(base * extra) end
            ApplyFrameAlpha(gphFrame)
            if gphFrame.ApplySkin then gphFrame.ApplySkin() end
            if ApplyCustomizeToFrame then ApplyCustomizeToFrame(gphFrame) end
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            gphFrame:Show()
            if gphFrame then gphFrame._refreshImmediate = true end 
            if RefreshGPHUI then RefreshGPHUI() end
            Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
        end
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
        Addon.SaveFrameLayout(f, "frameShown", "framePoint")
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
    f.titleBar = titleBar
    f.fitTitle = title

    -- Close button: stay closed until user opens via /fit or minimap (no auto-show)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        Addon.SaveFrameLayout(f, "frameShown", "framePoint")
        DB.mainFrameUserClosed = true
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

    if DB.lockoutsCollapsed == nil then DB.lockoutsCollapsed = false end
    local function UpdateCollapseButton()
        if DB.lockoutsCollapsed then
            collapseBg:SetTexture(0.25, 0.22, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
        end
    end
    UpdateCollapseButton()
    collapseBtn:SetScript("OnClick", function()
        DB.lockoutsCollapsed = not DB.lockoutsCollapsed
        UpdateCollapseButton(); RefreshUI()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if DB.lockoutsCollapsed then self.bg:SetTexture(0.35, 0.3, 0.15, 0.8)
        else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(DB.lockoutsCollapsed and "Show Saved Lockouts" or "Hide Saved Lockouts", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function() UpdateCollapseButton(); GameTooltip:Hide() end)
    f.collapseBtn = collapseBtn

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
        if not statsFrame then statsFrame = Addon.CreateStatsFrame() end
        if statsFrame:IsShown() then
            Addon.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
                DB.statsCollapsed = DB.lockoutsCollapsed
                if statsFrame.UpdateStatsCollapse then statsFrame.UpdateStatsCollapse() end
            end
            statsFrame:Show()
            Addon.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
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
    f.statsBtn = statsBtn

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
        Addon.AddonPrint(Addon.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Instances reset.")
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
    f.resetBtn = resetBtn

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
    f.gphBtn = gphBtn

    -- Hourly counter
    local hourlyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hourlyText:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -8)
    hourlyText:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -8)
    hourlyText:SetJustifyH("LEFT")
    f.hourlyText = hourlyText

    local sep = f:CreateTexture(nil, "ARTWORK")
    f.sep = sep
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

    f.ApplySkin = function()
        if _G.__FugaziInstanceTracker_Skins and _G.__FugaziInstanceTracker_Skins.ApplyMain then
            _G.__FugaziInstanceTracker_Skins.ApplyMain(f)
        end
    end
    f:ApplySkin()
    return f
end

----------------------------------------------------------------------
-- Refresh main tracker window
----------------------------------------------------------------------
RefreshUI = function()
    if not frame or not frame:IsShown() then return end
    Addon.PurgeOld()
    Addon.ResetPools()

    local now = time()
    local recent = DB.recentInstances or {}
    local count = #recent
    local remaining = MAX_INSTANCES_PER_HOUR - count
    local content = frame.content

    local countColor
    if remaining <= 0 then countColor = "|cffff4444"
    elseif remaining <= 2 then countColor = "|cffff8800"
    else countColor = "|cff44ff44" end

    local nextSlot = ""
    if count >= MAX_INSTANCES_PER_HOUR and recent[1] then
        nextSlot = "  |cffcccccc(next slot in " .. Addon.FormatTime(recent[1].time + HOUR_SECONDS - now) .. ")|r"
    end
    frame.hourlyText:SetText(
        "|cff80c0ffHourly Cap:|r  "
        .. countColor .. count .. "/" .. MAX_INSTANCES_PER_HOUR .. "|r"
        .. "  " .. countColor .. "(" .. remaining .. " left)|r"
        .. nextSlot
    )

    local yOff = 0
    local header1 = Addon.GetText(content)
    header1:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header1:SetText("|cff80c0ff--- Recent Instances ---|r")
    yOff = yOff + 18

    if #recent == 0 then
        local none = Addon.GetText(content)
        none:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -yOff)
        none:SetText("|cff888888No recent instances.|r")
        yOff = yOff + 16
    else
        for i, entry in ipairs(recent) do
            local timeLeft = HOUR_SECONDS - (now - entry.time)
            local row = Addon.GetRow(content, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            local idx = i
            row.deleteBtn:SetScript("OnClick", function() Addon.RemoveInstance(idx); RefreshUI() end)
            row.left:SetText("|cff666666" .. i .. ".|r  |cffffffcc" .. (entry.name or "Unknown") .. "|r")
            row.right:SetText(timeLeft > 0 and ("|cffff8844" .. Addon.FormatTime(timeLeft) .. "|r") or "|cff44ff44Expired|r")
            yOff = yOff + 16
        end
    end

    yOff = yOff + 10

    if DB.lockoutsCollapsed then
        Addon.CollapseInPlace(frame, 150, function() return false end)
        content:SetHeight(1)
        return
    end

    -- Lockouts header
    local header2 = Addon.GetText(content)
    header2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header2:SetText("|cff80c0ff--- Saved Lockouts ---|r")
    yOff = yOff + 18

    -- Lockouts
    if time() - lockoutQueryTime > 5 then Addon.UpdateLockoutCache(); RequestRaidInfo() end
    local buckets = { classic = {}, tbc = {}, wotlk = {}, unknown = {} }
    for _, info in ipairs(lockoutCache) do
        local exp = Addon.GetExpansion(info.name)
        if exp then
            table.insert(buckets[exp], info)
        else
            table.insert(buckets.unknown, info)
        end
    end

    for _, exp in ipairs(EXPANSION_ORDER) do
        local bucket = buckets[exp]
        if #bucket > 0 then
            local expH = Addon.GetText(content)
            expH:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
            expH:SetText(EXPANSION_LABELS[exp])
            yOff = yOff + 16

            table.sort(bucket, function(a, b) return a.name < b.name end)
            for _, info in ipairs(bucket) do
                local row = Addon.GetRow(content, false)
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
                        row.right:SetText("|cffff8844" .. Addon.FormatTime(current_reset) .. "|r")
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
        local expH = Addon.GetText(content)
        expH:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -yOff)
        expH:SetText("|cff999999Other|r")
        yOff = yOff + 16
        for _, info in ipairs(buckets.unknown) do
            local row = Addon.GetRow(content, false)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -yOff)
            row.left:SetText("|cffff4444" .. info.name .. "|r")
            if not info.locked then row.right:SetText("|cff44ff44Available|r")
            else
                local current_reset = info.resetAtQuery - (now - lockoutQueryTime)
                if current_reset > 0 then
                    row.right:SetText("|cffff8844" .. Addon.FormatTime(current_reset) .. "|r")
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
-- Periodic update (runs every frame; we throttle so we don't refresh every millisecond)
----------------------------------------------------------------------
local elapsed_acc, raidinfo_acc = 0, 0
--- Throttled refresh: once per second updates the main Instance Tracker window and item detail; every 30s requests raid info.
local function OnUpdate(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    raidinfo_acc = raidinfo_acc + elapsed
    if elapsed_acc >= 1 then
        elapsed_acc = 0
        RefreshUI()
        Addon.RefreshItemDetailLive()
    end
    if raidinfo_acc >= 30 then raidinfo_acc = 0; RequestRaidInfo() end
end

----------------------------------------------------------------------
-- Event handling (eventFrame created at top of file so PLAYER_LOGIN runs even if file errors later)
----------------------------------------------------------------------
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("BANKFRAME_CLOSED")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("GOSSIP_SHOW")
eventFrame:RegisterEvent("QUEST_GREETING")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- ElvUI bag/bank frames use OnHide -> CloseBankFrame(), so we must NOT call :Hide() or the bank closes.
-- "Stealth hide": move off-screen, alpha 0, no mouse — frame stays "shown" so OnHide doesn't run.
--- Hides ElvUI's bag/bank frames off-screen so our bags take over, without triggering ElvUI's close logic.
local function StealthHideElvUIBank()
    local E = _G.ElvUI and _G.ElvUI[1]
    if E and E.GetModule then
        local B = E:GetModule("Bags")
        if B then
            -- Stealth-hide ElvUI bank frame
            if B.BankFrame then
                local f = B.BankFrame
                f:ClearAllPoints()
                f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
                f:SetAlpha(0)
                f:EnableMouse(false)
                if not f._TestStealthHook and hooksecurefunc then
                    f._TestStealthHook = true
                    hooksecurefunc(f, "Show", function()
                        if f and f.ClearAllPoints then
                            f:ClearAllPoints()
                            f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
                            f:SetAlpha(0)
                            f:EnableMouse(false)
                        end
                    end)
                end
            end
            -- Stealth-hide ElvUI bag frame (inventory) so only our bags show
            if B.BagFrame then
                local bf = B.BagFrame
                bf:ClearAllPoints()
                bf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
                bf:SetAlpha(0)
                bf:EnableMouse(false)
                if not bf._TestStealthHook and hooksecurefunc then
                    bf._TestStealthHook = true
                    hooksecurefunc(bf, "Show", function()
                        if bf and bf.ClearAllPoints then
                            bf:ClearAllPoints()
                            bf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
                            bf:SetAlpha(0)
                            bf:EnableMouse(false)
                        end
                    end)
                end
            end
        end
    end
    local evBank = _G.ElvUI_BankContainerFrame
    if evBank and evBank.ClearAllPoints then
        evBank:ClearAllPoints()
        evBank:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
        evBank:SetAlpha(0)
        evBank:EnableMouse(false)
    end
    local evBags = _G.ElvUI_ContainerFrame
    if evBags and evBags.ClearAllPoints then
        evBags:ClearAllPoints()
        evBags:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
        evBags:SetAlpha(0)
        evBags:EnableMouse(false)
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = (select(1, ...)) or ""
        if addonName:lower():find("fugazibags") then
            DB = _G.FugaziBAGSDB or DB
            RunAddonLoader()
        end
    elseif event == "PLAYER_LOGIN" then
        RunAddonLoader()
        -- GPH-only init (no main frame, no instance tracking)
        if not _G.InstanceTrackerKeybindOwner then
            _G.InstanceTrackerKeybindOwner = CreateFrame("Frame", "InstanceTrackerKeybindOwner", UIParent)
        end
        -- Restore GPH session if it exists (survives /reload); scope and global stay in sync for button/timer
        if DB.gphSession then
            Addon.SyncGPHSessionFromDB()
        end
        -- Always create our own frame and claim the global. When InstanceTracker is loaded it may have set TestGPHFrame to its (old) frame; reusing that breaks the autosell button (no UpdateInvBtn).
        gphFrame = CreateGPHFrame()
        _G.TestGPHFrame = gphFrame
        -- Pre-reparent gridContent to gphFrame now (out of combat) so ShowInFrame
        -- never needs to call SetParent in combat (blocked on frames with protected children).
        local gc = _G.FugaziBAGS_GridContent
        if gc and gc:GetParent() ~= gphFrame then
            gc:SetParent(gphFrame)
            gc:ClearAllPoints()
            gc:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
            gc:Hide()
        end
        -- ToggleGPHFrame already toggles container (GPH or combat grid); keep global.
        if not _G.ToggleGPHFrame then _G.ToggleGPHFrame = ToggleGPHFrame end
        if Addon.InstallGPHInvHook then Addon.InstallGPHInvHook() end
        Addon.RestoreFrameLayout(gphFrame, nil, "gphPoint")
        local container = _G.FugaziBAGS_InventoryContainer
        -- Show bags on login if we have a container and saved state was open (or never set).
        if container and (DB.gphShown == nil or DB.gphShown) then
            container:Show()
        else
            Addon.RestoreFrameLayout(gphFrame, "gphShown", "gphPoint")
        end
        local SV = _G.FugaziBAGSDB
        if not (SV and SV.gphPoint and SV.gphPoint.point) then
            gphFrame:ClearAllPoints()
            -- When docking with the bank and we have no saved bank layout, start from the same base anchor.
            gphFrame:SetPoint("RIGHT", UIParent, "RIGHT", -444, -4)
        end
        local base = (SV and SV.gphScale15) and 1.5 or 1
        local extra = (SV and SV.gphFrameScale) or 1
        local alpha = (SV and SV.gphFrameAlpha) or 1
        gphFrame:SetScale(base * extra)
        if gphFrame.gphDestroyBtn then gphFrame.gphDestroyBtn:SetScale(base * extra) end
        gphFrame:SetAlpha(alpha)
        if gphFrame.ApplySkin then gphFrame.ApplySkin() end
        if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
        if gphFrame:IsShown() then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            gphFrame.gphScrollToDefaultOnNextRefresh = true
            RefreshGPHUI()
        end

        -- Apply preferred or forced grid view on login (per-character)
        local cg = _G.FugaziBAGS_CombatGrid
        if cg then
            local forceGrid = GetPerChar("gphForceGridView", false)
            local wantGrid = GetPerChar("gphGridMode", false)
            if (forceGrid or wantGrid) and cg.ShowInFrame then
                cg.ShowInFrame(gphFrame)
                gphFrame.gphGridMode = true
            else
                gphFrame.gphGridMode = false
            end
            local bf = _G.TestBankFrame
            if bf and cg.ShowInBankFrame then
                local bankForce = GetPerChar("gphBankForceGridView", false)
                local bankGrid = GetPerChar("gphBankGridMode", false)
                if bankForce or bankGrid then
                    cg.ShowInBankFrame(bf)
                    bf.gphGridMode = true
                else
                    bf.gphGridMode = false
                end
            end
        end
        -- When default bank opens: move it off-screen, hide Blizzard bags, and show our bank window (ElvUI-style).
        -- Hook BankFrame.Show if it exists now; also install hook later in case BankFrame is created when bank first opens.
        local function doShowFugaziBank()
            if not Addon or not Addon.HideBlizzardBags then return end
            Addon.HideBlizzardBags(true)
            if _G.BankFrame then
                _G.BankFrame:ClearAllPoints()
                _G.BankFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -5000, -5000)
                _G.BankFrame:SetAlpha(0)
                _G.BankFrame:EnableMouse(false)
            end
            local inv = gphFrame or _G.TestGPHFrame
            local bf = _G.TestBankFrame
            if not bf and CreateBankFrame then
                local ok, result = pcall(CreateBankFrame, inv)
                if ok and result then bf = result
                elseif not ok and Addon.AddonPrint then Addon.AddonPrint("[Bank] CreateBankFrame error: " .. tostring(result)) end
            end
            if bf then
                _G.TestBankFrame = bf
                bf._refreshImmediate = true
                bf.gphScrollToDefaultOnNextRefresh = true
                if inv then
                    bf:SetParent(inv)
                    bf:SetScale(1)
                    inv:Show()
                    if not inv.gphGridMode then inv.gphScrollToDefaultOnNextRefresh = true end
                    if RefreshGPHUI then RefreshGPHUI() end
                    do
                        local p, r, rp, x, y = inv:GetPoint(1)
                        if p and rp and x and y then
                            -- Only save if we are not already at the bank-centered position
                            if not (p == "TOPLEFT" and rp == "TOP" and x == 2 and y == -80) then
                                Addon.SaveFrameLayout(inv, nil, "gphPreBankPoint")
                                Addon.SaveFrameLayout(inv, "gphShown", "gphPoint")
                            end
                        end
                    end
                    inv:ClearAllPoints()
                    inv:SetPoint("TOPLEFT", UIParent, "TOP", 2, -80)
                else
                    bf:SetParent(UIParent)
                    bf:SetScale(1)
                end
                bf:ClearAllPoints()
                if inv then bf:SetPoint("TOPRIGHT", inv, "TOPLEFT", -4, 0)
                else bf:SetPoint("TOP", UIParent, "CENTER", 200, -100) end
                bf:Show()
                if ApplyCustomizeToFrame then ApplyCustomizeToFrame(bf) end
                if bf.bankTitleText then
                    bf.bankTitleText:SetText((UnitName and UnitName("target")) or "Bank")
                end
                if RefreshBankUI then 
                    RefreshBankUI() 
                    -- Retry mechanism: if bank scan found 0 items, retry a few times (helps with server latency on first open)
                    local retryCount = 0
                    local retryFrame = CreateFrame("Frame")
                    retryFrame:SetScript("OnUpdate", function(self, elapsed)
                        self._t = (self._t or 0) + elapsed
                        if self._t < 0.2 then return end
                        self._t = 0
                        retryCount = retryCount + 1
                        if RefreshBankUI then RefreshBankUI() end
                        -- Stop if we found items OR after 5 attempts (~1s)
                        local used = _G.TestBankFrame and _G.TestBankFrame._bankUsedSlots or 0
                        if used > 0 or retryCount >= 5 then
                            self:SetScript("OnUpdate", nil)
                            self:Hide()
                        end
                    end)
                end
                
                -- Restore saved bank view (list vs grid). Per-character: gphBankGridMode; Force overrides to always grid.
                local cg = _G.FugaziBAGS_CombatGrid
                if cg then
                    local forceBankGrid = GetPerChar and GetPerChar("gphBankForceGridView", false)
                    if forceBankGrid then
                        if cg.ShowInBankFrame then cg.ShowInBankFrame(bf) end
                        bf.gphGridMode = true
                    else
                        local wantBankGrid = GetPerChar and GetPerChar("gphBankGridMode", false)
                        bf.gphGridMode = wantBankGrid
                        if wantBankGrid then
                            if cg.ShowInBankFrame then cg.ShowInBankFrame(bf) end
                        else
                            if cg.HideInBankFrame then cg.HideInBankFrame(bf) end
                        end
                    end
                end
                local d = CreateFrame("Frame")
                d._count = 0
                d:SetScript("OnUpdate", function(self)
                    Addon.HideBlizzardBags(true)
                    self._count = (self._count or 0) + 1
                    if self._count == 1 then StealthHideElvUIBank() end
                    if self._count >= 8 then self:SetScript("OnUpdate", nil) end
                end)
            end
        end
        if BankFrame and BankFrame.Show then
            local origShow = BankFrame.Show
            BankFrame.Show = function(self)
                origShow(self)
                doShowFugaziBank()
            end
        end
        -- BankFrame may not exist at login on some clients; hook it when it appears.
        if hooksecurefunc then
            local bankHookInstaller = CreateFrame("Frame")
            bankHookInstaller._t = 0
            bankHookInstaller:SetScript("OnUpdate", function(self, elapsed)
                self._t = self._t + elapsed
                if self._t > 5 then
                    self:SetScript("OnUpdate", nil)
                    return
                end
                if _G.BankFrame and _G.BankFrame.Show and not _G.FugaziBAGS_BankShowHooked then
                    _G.FugaziBAGS_BankShowHooked = true
                    hooksecurefunc(_G.BankFrame, "Show", doShowFugaziBank)
                    self:SetScript("OnUpdate", nil)
                end
            end)
        end
        _G.FugaziBAGS_DoShowBank = doShowFugaziBank
        Addon.HideBlizzardBags()
        local defer = CreateFrame("Frame")
        defer:SetScript("OnUpdate", function(self, elapsed)
            self._t = (self._t or 0) + elapsed
            if self._t > 0.5 then
                self:SetScript("OnUpdate", nil)
                Addon.HideBlizzardBags()
            end
        end)
        Addon.AddonPrint(
            Addon.ColorText("[__FugaziBAGS] ", 0.4, 0.8, 1)
            .. "Loaded. Press B to open inventory."
        )

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- (no instance tracking in Test)

    elseif event == "CHAT_MSG_SYSTEM" then
        -- (no instance tracking in Test)

    elseif event == "UPDATE_INSTANCE_INFO" then
        -- (no instance tracking in Test)

    elseif event == "BANKFRAME_OPENED" then
        if _G.FugaziBAGS_DoShowBank then _G.FugaziBAGS_DoShowBank() end
        do
            local d2 = CreateFrame("Frame")
            d2:SetScript("OnUpdate", function(self, elapsed)
                self._t = (self._t or 0) + elapsed
                if not self._doneFirst then
                    self._doneFirst = true
                    StealthHideElvUIBank()
                end
                if Addon and Addon.HideBlizzardBags then Addon.HideBlizzardBags(true) end
                if self._t >= 0.05 then
                    StealthHideElvUIBank()
                    if Addon and Addon.HideBlizzardBags then Addon.HideBlizzardBags(true) end
                end
                if self._t >= 0.15 and Addon and Addon.HideBlizzardBags then Addon.HideBlizzardBags(true) end
                if self._t >= 0.4 then
                    if Addon and Addon.HideBlizzardBags then Addon.HideBlizzardBags(true) end
                    self:SetScript("OnUpdate", nil)
                end
            end)
        end
    elseif event == "BANKFRAME_CLOSED" then
        if _G.TestBankFrame then
            _G.TestBankFrame:Hide()
            _G.TestBankFrame._bankDeferRefresh = nil
            _G.TestBankFrame._bankCountDebugDone = nil
        end
        local inv = gphFrame or _G.TestGPHFrame
        if inv and Addon.RestoreFrameLayout then
            Addon.RestoreFrameLayout(inv, nil, "gphPreBankPoint")
        end
    elseif event == "MERCHANT_SHOW" or event == "GOSSIP_SHOW" or event == "QUEST_GREETING" or event == "MAIL_SHOW" then
        gphNpcDialogTime = GetTime()
        -- Only hide default bags here; do NOT auto-show GPH (inventory opens only via B key or when banker opens bank).
        do
            local defer = CreateFrame("Frame")
            defer:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                if Addon.HideBlizzardBags then Addon.HideBlizzardBags() end
            end)
        end
        if event == "MERCHANT_SHOW" then
            Addon.InstallGphGreedyMuteOnce()
            if _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphAutoVendor then
                -- Defer one frame so "hold Shift while opening" is reliably captured (IsShiftKeyDown stable after vendor UI is up).
                local defer = CreateFrame("Frame")
                defer:SetScript("OnUpdate", function(self)
                    self:SetScript("OnUpdate", nil)
                    if Addon.StartGphVendorRun then Addon.StartGphVendorRun() end
                end)
            end
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            -- Refresh list so vendor-protect overlays show (block right-click sell on protected items).
            if RefreshGPHUI then
                local d = CreateFrame("Frame")
                d:SetScript("OnUpdate", function(self) self:SetScript("OnUpdate", nil); RefreshGPHUI() end)
            end
        end
        if event == "MAIL_SHOW" or event == "MAIL_CLOSED" or event == "MAIL_INBOX_UPDATE" then
            if gphFrame and gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
        end
    elseif event == "MAIL_CLOSED" or event == "MAIL_INBOX_UPDATE" then
        if gphFrame and gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
    elseif event == "MERCHANT_CLOSED" then
        gphNpcDialogTime = nil
        if Addon.FinishGphVendorRun then Addon.FinishGphVendorRun() end
        if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
        -- Refresh list so vendor-protect overlays hide (right-click use item again).
        if RefreshGPHUI then RefreshGPHUI() end
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        -- Coalesce bank refreshes the same way we do for GPH bags: any burst of
        -- PLAYERBANKSLOTS_CHANGED events (and matching BAG_UPDATEs) triggers
        -- exactly one RefreshBankUI on the next frame.
        if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then
            if not Addon.bankUpdateDeferFrame then Addon.bankUpdateDeferFrame = CreateFrame("Frame") end
            local defer = Addon.bankUpdateDeferFrame
            if not defer._bankScheduled then
                defer._bankScheduled = true
                defer:SetScript("OnUpdate", function(self)
                    self:SetScript("OnUpdate", nil)
                    self._bankScheduled = nil
                    if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then
                        RefreshBankUI()
                    end
                end)
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat: force grid mode if inventory is open
        local container = _G.FugaziBAGS_InventoryContainer
        local cg = _G.FugaziBAGS_CombatGrid
        if container and container:IsShown() and gphFrame and not gphFrame.gphGridMode then
            local oldRight = gphFrame:GetRight()
            local oldTop = gphFrame:GetTop()
            if cg and cg.ShowInFrame then cg.ShowInFrame(gphFrame) end
            if gphFrame.UpdateGPHCollapse then gphFrame.UpdateGPHCollapse() end
            if oldRight and oldTop then
                gphFrame:ClearAllPoints()
                gphFrame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", oldRight, oldTop)
            end
        end
        if gphFrame then gphFrame._combatExitTime = nil end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Mark the time we left combat. The OnUpdate loop will wait 90 seconds
        -- before switching the inventory back from Grid Mode to List Mode.
        if gphFrame then gphFrame._combatExitTime = GetTime() end

    elseif event == "BAG_UPDATE" then
        Addon.DiffBags()

        local gphSession = _G.gphSession
        if gphSession then Addon.DiffBagsGPH() end
        -- Coalesce: defer RefreshGPHUI with a 0.2s minimum interval to prevent high-speed memory churn from rapid events.
        if gphFrame and gphFrame:IsShown() then
            if not Addon.gphBagUpdateDeferFrame then Addon.gphBagUpdateDeferFrame = CreateFrame("Frame") end
            local defer = Addon.gphBagUpdateDeferFrame
            if not defer._gphScheduled then
                    defer._gphScheduled = true
                    defer._accum = 0
                    defer:SetScript("OnUpdate", function(self, elapsed)
                        self._accum = (self._accum or 0) + elapsed
                        if self._accum < 0.2 then return end
                        self:SetScript("OnUpdate", nil)
                        self._gphScheduled = nil
                        if RefreshGPHUI then RefreshGPHUI() end
                        local cg = _G.FugaziBAGS_CombatGrid
                        if cg and gphFrame and gphFrame.gphGridMode then
                            if cg.RefreshSlots then cg.RefreshSlots() end
                        end
                end)
            end
        end
        if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then
            if not Addon.bankUpdateDeferFrame then Addon.bankUpdateDeferFrame = CreateFrame("Frame") end
            local defer = Addon.bankUpdateDeferFrame
            if not defer._bankScheduled then
                defer._bankScheduled = true
                defer._accum = 0
                defer:SetScript("OnUpdate", function(self, elapsed)
                    self._accum = (self._accum or 0) + elapsed
                    if self._accum < 0.2 then return end
                    self:SetScript("OnUpdate", nil)
                    self._bankScheduled = nil
                    if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then
                        RefreshBankUI()
                    end
                end)
            end
        end
        if gphFrame and gphFrame.UpdateDestroyMacro then gphFrame.UpdateDestroyMacro() end
        -- Rebuild destroy queue: every slot that has a destroy-list item (full stack delete per slot, like double-click X)
        local list = Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
        if list then
            wipe(Addon.gphDestroyQueue)
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
                            Addon.gphDestroyQueue[#Addon.gphDestroyQueue + 1] = { itemId = id, bag = bag, slot = slot }
                        end
                    end
                end
            end
            if #Addon.gphDestroyQueue > 0 then
                Addon.EnsureGPHDestroyerFrame()
                if Addon.gphDestroyerFrame then Addon.gphDestroyerFrame:Show() end
            end
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

--- Debug: prints a tree of frames under the inventory container and which are protected/forbidden (for taint troubleshooting).
local function DebugProtectedChildren()
    local c = _G.FugaziBAGS_InventoryContainer
    if not c then
        print("[FugaziBAGS] No FugaziBAGS_InventoryContainer yet.")
        return
    end

    print("[FugaziBAGS] Protected children under FugaziBAGS_InventoryContainer:")
    local function scan(frame, depth)
        depth = depth or 0
        local indent = string.rep("  ", depth)
        local name = frame:GetName() or "<unnamed>"
        local prot = (frame.IsProtected and frame:IsProtected()) and "P" or "-"
        local forb = (frame.IsForbidden and frame:IsForbidden()) and "F" or "-"
        print(indent .. prot .. forb, name, frame:GetObjectType())

        local num = frame.GetNumChildren and frame:GetNumChildren() or 0
        if num > 0 then
            local children = { frame:GetChildren() }
            for i = 1, #children do
                scan(children[i], depth + 1)
            end
        end
    end

    scan(c, 0)
end

SLASH_FUGAZIDEBUGPROT1 = "/fugaziprot"
SlashCmdList["FUGAZIDEBUGPROT"] = function()
    DebugProtectedChildren()
end

SlashCmdList["INSTANCETRACKER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local cmd = msg:match("^([%w]+)") or ""

    if cmd == "help" or msg == "help" then
        Addon.AddonPrint(Addon.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Commands:")
        Addon.AddonPrint("  |cffaaddff/fit|r              Toggle main window (no args)")
        Addon.AddonPrint("  |cffaaddff/fit help|r        Show this list")
        Addon.AddonPrint("  |cffaaddff/fit mute|r        Mute all addon chat output")
        Addon.AddonPrint("  |cffaaddff/fit reset|r       Clear recent instance history (this hour)")
        Addon.AddonPrint("  |cffaaddff/fit status|r      Show instances used this hour in chat")
        Addon.AddonPrint("  |cffaaddff/fit stats|r       Toggle Run Stats (Ledger) window")
        Addon.AddonPrint("  |cffaaddff/fit gph|r or |cffaaddff/fit inv|r or |cffaaddff/gph|r  Toggle Gold Per Hour window")
        Addon.AddonPrint("  (Bind your bag key to |cffffcc00/fit gph|r or |cffffcc00/gph|r when Inv is on)")
        Addon.AddonPrint("  |cffaaddff/fit vp|r  Show Summon Greedy toggle state")
        return
    end

    if cmd == "mute" then
        DB.fitMute = not DB.fitMute
        -- Always show mute state (can't mute the mute confirmation)
        DEFAULT_CHAT_FRAME:AddMessage(
            Addon.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Chat output " .. (DB.fitMute and "|cffff4444muted|r." or "|cff44ff44unmuted|r.")
        )
        return
    end

    if cmd == "vendorprotect" or cmd == "vp" then
        Addon.AddonPrint(Addon.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Summon Greedy after vendor: " .. (DB.gphSummonGreedy ~= false and "|cff44ff44on|r (1.5s)" or "|cffff4444off|r"))
        return
    end

    if cmd == "reset" then
        DB.recentInstances = {}
        Addon.AddonPrint(Addon.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Recent instance history cleared.")
        RefreshUI()
        return
    end

    if cmd == "status" then
        Addon.PurgeOld()
        local c = #(DB.recentInstances or {})
        Addon.AddonPrint(
            Addon.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Instances this hour: " .. Addon.ColorText(c .. "/" .. MAX_INSTANCES_PER_HOUR, 1, 0.8, 0.2)
            .. " (" .. Addon.ColorText((MAX_INSTANCES_PER_HOUR - c) .. " remaining", 0.4, 1, 0.4) .. ")"
        )
        return
    end

    if cmd == "stats" then
        if _G.InstanceTrackerStatsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
        if not statsFrame then statsFrame = Addon.CreateStatsFrame() end
        if statsFrame:IsShown() then
            Addon.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            end
            statsFrame:Show()
            Addon.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
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
        Addon.SaveFrameLayout(frame, "frameShown", "framePoint")
        DB.mainFrameUserClosed = true
    else
        DB.mainFrameUserClosed = false
        RequestRaidInfo()
        frame:Show()
        Addon.SaveFrameLayout(frame, "frameShown", "framePoint")
        RefreshUI()
    end
end
