--[[
  FugaziBAGS main: inventory + bank UI.
  B = open our bags (replaces default). Categories, sort, protect, vendor, destroy, mail-by-rarity.
]]

local ADDON_NAME = "InstanceTracker"
local Addon = _G.TestAddon or {}
_G.TestAddon = Addon


local MAX_INSTANCES_PER_HOUR = 5       
local HOUR_SECONDS = 3600
local MAX_RUN_HISTORY = 100            
local MAX_RESTORE_AGE_SECONDS = 5 * 60 
local SCROLL_CONTENT_WIDTH = 296       
local GPH_MAX_STACK = 49               


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
if DB.gphFrameScale == nil then DB.gphFrameScale = 1 end       
if DB.gphFrameAlpha == nil then DB.gphFrameAlpha = 1 end       
if DB.gphPreviouslyWornItemIds == nil then DB.gphPreviouslyWornItemIds = {} end
DB.gphProtectedItemIdsPerChar = DB.gphProtectedItemIdsPerChar or {}   
DB.gphProtectedRarityPerChar = DB.gphProtectedRarityPerChar or {}      
DB.gphPreviouslyWornOnlyPerChar = DB.gphPreviouslyWornOnlyPerChar or {} 
DB.gphDestroyListPerChar = DB.gphDestroyListPerChar or {}     
DB.gphItemTypeCache = DB.gphItemTypeCache or {}
DB.gphSkin = DB.gphSkin or "fugazi"   
DB.gphSkinOverrides = DB.gphSkinOverrides or {}  
DB.fitSkin = DB.fitSkin or "fugazi"   
DB.gphSortMode = DB.gphSortMode or "category"   

if DB._applyFugaziPresetOnLoad and _G.ApplyFugaziPreset then _G.ApplyFugaziPreset(); DB._applyFugaziPresetOnLoad = nil end
if DB.gphForceGridView == nil then DB.gphForceGridView = false end    
if DB.gphBankForceGridView == nil then DB.gphBankForceGridView = false end
if DB.gphGridMode == nil then DB.gphGridMode = false end       
if DB.gphBankGridMode == nil then DB.gphBankGridMode = false end
if DB.gridConfirmAutoDel == nil then DB.gridConfirmAutoDel = true end  
if DB.gridProtectedKeyAlpha == nil then DB.gridProtectedKeyAlpha = 0.2 end   
if DB.gphHideTopButtons == nil then DB.gphHideTopButtons = true end    
if DB.gphBankHideTopButtons == nil then DB.gphBankHideTopButtons = true end
if DB.gphHideDestroyBtn == nil then DB.gphHideDestroyBtn = false end   
if DB.gphClickSound == nil then DB.gphClickSound = true end   
if DB.gphCategoryHeaderFontCustom == nil then DB.gphCategoryHeaderFontCustom = false end  
if DB.gphCategoryHeaderFont == nil then DB.gphCategoryHeaderFont = "Fonts\\ARIALN.TTF" end
if DB.gphCategoryHeaderFontSize == nil then DB.gphCategoryHeaderFontSize = 11 end
if DB.gphItemDetailsCustom == nil then DB.gphItemDetailsCustom = false end  
if DB.gphHideIconsInList == nil then DB.gphHideIconsInList = false end  
DB.gphPerChar = DB.gphPerChar or {}   



--- Like /dump but only when debugClicks is on.
local function DebugClick(msg)
    local SV = _G.FugaziBAGSDB
    if not (SV and SV.debugClicks) then return end
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFugaziBAGS:|r " .. tostring(msg))
    end
end




--- Soulbound-to-vendor check: won't sell/destroy this item.
function Addon.IsItemProtectedAPI(itemId, quality)
    if not itemId then return false end
    
    if itemId == 6948 then return true end

    local SV = _G.FugaziBAGSDB or {}
    local mu = SV._manualUnprotected or {}
    
    
    if mu[itemId] then return false end

    local protectedSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}
    local prevOnly    = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}

    if protectedSet[itemId] then return true end
    local q = quality or 0
    if rarityFlags[q] then return true end
    -- Only epic (4): "protect purple" also protects legendary/artifact/heirloom (5,6,7)
    if rarityFlags[4] and q >= 4 then return true end
    if prevOnly[itemId] then return true end
    return false
end


--- Realm#Char key (your toon's save-key).
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end


--- Get saved setting for this character (per-toon).
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

--- Save setting for this character.
local function SetPerChar(key, value)
    local SV = _G.FugaziBAGSDB
    if not SV then SV = {}; _G.FugaziBAGSDB = SV end
    if not SV.gphPerChar then SV.gphPerChar = {} end
    local k = GetGphCharKey()
    if not SV.gphPerChar[k] then SV.gphPerChar[k] = {} end
    SV.gphPerChar[k][key] = value
end

--- Font path + size for category headers (Weapon, Armor, etc).
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


local _secBtnCounter = 0
Addon._gphSelectionDeferFrame = CreateFrame("Frame", nil, UIParent)
Addon._gphSelectionDeferFrame:Hide()



--- Secure bag-slot button (works in combat, Alt/Ctrl clicks).
local function EnsureSecureRowBtn(clickArea, bag, slot)
    
    local oldParToOrphan 
    if clickArea._fugaziSecBtn then
        local par = clickArea._fugaziSecPar
        local curBag, curSlot = par and par:GetID(), clickArea._fugaziSecBtn:GetID()
        if curBag == bag and curSlot == slot then
            par:Show()
            clickArea._fugaziSecBtn:Show()
            return
        end
        
        oldParToOrphan = par
        clickArea._fugaziSecBtn = nil
        clickArea._fugaziSecPar = nil
        clickArea._fugaziVendorProtectOverlay = nil
        clickArea._fugaziModifierOverlay = nil
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
    
    btn:SetFrameLevel((par:GetFrameLevel() or 1) + 1)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if ContainerFrameItemButton_OnLoad then ContainerFrameItemButton_OnLoad(btn) end
    btn:HookScript("OnClick", function(self, button)
        DebugClick(string.format("SECURE BTN %s bag=%s slot=%s", tostring(button), tostring(par:GetID()), tostring(self:GetID())))
    end)
    
    local function deferSecureNextFrame(scriptName)
        if not clickArea:GetScript(scriptName) then return end
        Addon._gphSecureDeferQueue = Addon._gphSecureDeferQueue or {}
        table.insert(Addon._gphSecureDeferQueue, { clickArea = clickArea, scriptName = scriptName })
        if not Addon._gphSecureDeferFrame then Addon._gphSecureDeferFrame = CreateFrame("Frame") end
        local d = Addon._gphSecureDeferFrame
        d:SetScript("OnUpdate", function(self)
            local q = Addon._gphSecureDeferQueue
            if not q or #q == 0 then self:SetScript("OnUpdate", nil); self:Hide(); return end
            for i = 1, #q do
                local e = q[i]
                if e and e.clickArea and e.scriptName then
                    local f = e.clickArea:GetScript(e.scriptName)
                    if f then f(e.clickArea) end
                end
            end
            wipe(q)
            self:SetScript("OnUpdate", nil)
            self:Hide()
        end)
        d:Show()
    end
    btn:SetScript("OnEnter", function(self) deferSecureNextFrame("OnEnter") end)
    btn:SetScript("OnLeave", function(self) deferSecureNextFrame("OnLeave") end)
    btn:SetScript("OnMouseDown", function(self)
        if Addon.TriggerRowPulse then
            local rowBtn = self:GetParent():GetParent():GetParent()
            if not Addon._gphSecurePulseDefer then Addon._gphSecurePulseDefer = CreateFrame("Frame") end
            local pd = Addon._gphSecurePulseDefer
            pd._rowBtn = rowBtn
            pd:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                if Addon.TriggerRowPulse and self._rowBtn then Addon.TriggerRowPulse(self._rowBtn) end
                self._rowBtn = nil
            end)
            pd:Show()
        end
    end)
    local function forwardMouseWheel(_, delta)
        local bf = _G.TestBankFrame
        local gph = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
        if bf and bf:IsShown() and bf.scrollFrame and bf.scrollFrame.BankOnMouseWheel then
            bf.scrollFrame.BankOnMouseWheel(delta)
        elseif gph and gph.scrollFrame and gph.scrollFrame.GPHOnMouseWheel then
            gph.scrollFrame.GPHOnMouseWheel(delta)
        end
    end
    btn:SetScript("OnMouseWheel", forwardMouseWheel)
    
    
    
    local vendorProtectOverlay = CreateFrame("Button", nil, par)
    vendorProtectOverlay:SetAllPoints(par)
    vendorProtectOverlay:SetFrameStrata(par:GetFrameStrata() or "MEDIUM")
    vendorProtectOverlay:SetFrameLevel((par:GetFrameLevel() or 1) + 5)
    vendorProtectOverlay:EnableMouse(true)
    vendorProtectOverlay:RegisterForClicks("RightButtonUp")
    vendorProtectOverlay:SetScript("OnClick", function() end)
    vendorProtectOverlay:Hide()
    clickArea._fugaziVendorProtectOverlay = vendorProtectOverlay

    
    local modOverlay = CreateFrame("Button", nil, par)
    modOverlay:SetAllPoints(par)
    modOverlay:SetFrameStrata(par:GetFrameStrata() or "MEDIUM")
    modOverlay:SetFrameLevel((par:GetFrameLevel() or 1) + 6)
    modOverlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    modOverlay:EnableMouse(false)
    modOverlay:Hide()
    modOverlay._clickArea = clickArea
    modOverlay:SetScript("OnMouseWheel", forwardMouseWheel)
    
    modOverlay:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton == "LeftButton" and (IsAltKeyDown and IsAltKeyDown()) then
            
        end
    end)
    modOverlay:SetScript("OnEnter", function(self)
        local ca = self._clickArea
        if ca and ca.GetScript then
            local f = ca:GetScript("OnEnter")
            if f then f(ca) end
        end
    end)
    modOverlay:SetScript("OnLeave", function(self)
        local ca = self._clickArea
        if ca and ca.GetScript then
            local f = ca:GetScript("OnLeave")
            if f then f(ca) end
        end
    end)
    modOverlay:SetScript("OnClick", function(self, button)
        local b, s = self:GetParent():GetID(), (self._clickArea._fugaziSecBtn and self._clickArea._fugaziSecBtn:GetID()) or nil
        local Addon = _G.TestAddon
        if Addon and Addon.PlayClickSound then Addon.PlayClickSound() end
        local link = GetContainerItemLink and GetContainerItemLink(b, s)
        if not link then return end
        local itemId = tonumber(link:match("item:(%d+)"))
        if not itemId then return end
        local altDown = IsAltKeyDown and IsAltKeyDown()
        local ctrlDown = IsControlKeyDown and IsControlKeyDown()

        if altDown and button == "LeftButton" then
            if Addon then
                local _, _, q = GetItemInfo(link)
                q = q or 0
                local protNow = Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(itemId, q) or false

                local SV = _G.FugaziBAGSDB or {}
                SV._manualUnprotected = SV._manualUnprotected or {}
                local set = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
                local prevOnly = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}

                
                set[itemId] = nil
                prevOnly[itemId] = nil
                if SV.gphPreviouslyWornItemIds then SV.gphPreviouslyWornItemIds[itemId] = nil end

                if protNow then
                    
                    SV._manualUnprotected[itemId] = true
                else
                    
                    SV._manualUnprotected[itemId] = nil
                    set[itemId] = true
                end

                local row = self._clickArea and self._clickArea:GetParent()
                if row and Addon.TriggerRowPulse and protNow then Addon.TriggerRowPulse(row) end
            end
            local row = self._clickArea:GetParent()
            local bf = _G.TestBankFrame
            if row and row.bagID and bf and bf:IsShown() and row.entryIndex and row._bankRowY then
                bf._bankLastClickedIndex = row.entryIndex
                bf._bankLastClickedRowY = row._bankRowY
                bf._bankScrollOffsetAtClick = bf.bankScrollOffset or 0
            end
            local gf = gphFrame or _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
            if gf then gf._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
            
            if _G.FugaziBAGS_ScheduleRefreshBankUI then _G.FugaziBAGS_ScheduleRefreshBankUI() end
            return
        end

        
        if ctrlDown and button == "LeftButton" then
            if HandleModifiedItemClick and link then
                HandleModifiedItemClick(link)
            end
            return
        end

        if ctrlDown and button == "RightButton" then
            
            if b == -1 or (b and b >= 5 and b <= 11) then return end
            
            if itemId == 6948 then return end
            if IsItemProtected and IsItemProtected(b, s) then return end
            if not (Addon and Addon.GetGphDestroyList) then return end
            local list = Addon.GetGphDestroyList()
            if not list or list[itemId] then return end
            Addon.gphGridDestroyClickTime = Addon.gphGridDestroyClickTime or {}
            local clicks = Addon.gphGridDestroyClickTime
            local now = (GetTime and GetTime()) or time()
            local prev = clicks[itemId]
            if prev and (now - prev) <= 1.0 then
                clicks[itemId] = nil
                local row = self._clickArea and self._clickArea:GetParent()
                if row and Addon.StopRowDeletePulse then Addon.StopRowDeletePulse(row) end
                if Addon.PlayTrashSound then Addon.PlayTrashSound() end
                local function addAndQueue()
                    local name, _, _, _, _, _, _, _, _, texture = GetItemInfo and GetItemInfo(itemId) or nil
                    if not name and GetItemInfo then name = GetItemInfo(link) end
                    list[itemId] = { name = name or ("Item "..tostring(itemId)), texture = texture, addedTime = time() }
                    if Addon.QueueDestroySlotsForItemId then Addon.QueueDestroySlotsForItemId(itemId) end
                    if RefreshGPHUI then RefreshGPHUI() end
                end
                local SV = _G.FugaziBAGSDB
                local needConfirm = SV and SV.gridConfirmAutoDel ~= false
                if needConfirm and StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"] then
                    local itemName = GetItemInfo and GetItemInfo(itemId) or (link or "this item")
                    StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"].OnAccept = function() addAndQueue() end
                    StaticPopup_Show("FUGAZIGRID_DESTROY_CONFIRM", itemName)
                else
                    addAndQueue()
                end
            else
                
                clicks[itemId] = now
                local row = self._clickArea and self._clickArea:GetParent()
                if row and Addon.MarkRowDeletePulse then Addon.MarkRowDeletePulse(row) end
            end
        end
    end)
    clickArea._fugaziModifierOverlay = modOverlay

    clickArea._fugaziSecBtn = btn
    clickArea._fugaziSecPar = par
    
    if oldParToOrphan then
        oldParToOrphan:SetParent(nil)
        oldParToOrphan:Hide()
    end
    
    par:Show()
    btn:Show()
end
_G.FugaziBAGS_EnsureSecureRowBtn = EnsureSecureRowBtn


--- Brief highlight when you protect an item (like a buff flash).
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

--- Red flash: row marked for destroy (double Ctrl+RMB to confirm).
local function MarkRowDeletePulse(rowBtn)
    if not rowBtn or not rowBtn.nameFs then return end
    local fs = rowBtn.nameFs
    
    local plainName = rowBtn._plainName or (fs:GetText() and fs:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or ""
    if plainName == "" then return end
    rowBtn._normalNameText = rowBtn._normalNameText or fs:GetText()
    
    local r1, g1, b1 = 1, 1, 1
    fs:SetText(plainName)
    fs:SetTextColor(1, 0, 0)
    if not rowBtn._delPulseFrame then
        rowBtn._delPulseFrame = CreateFrame("Frame")
    end
    rowBtn._delPulseElapsed = 0
    rowBtn._delPulseFrame:SetScript("OnUpdate", function(f, el)
        local elapsed = (rowBtn._delPulseElapsed or 0) + el
        rowBtn._delPulseElapsed = elapsed
        local duration = 1.0
        local t = elapsed / duration
        if t >= 1.0 then
            fs:SetText(rowBtn._normalNameText or plainName)
            f:SetScript("OnUpdate", nil)
        else
            local r = 1 * (1 - t) + r1 * t
            local g = 0 * (1 - t) + g1 * t
            local b = 0 * (1 - t) + b1 * t
            fs:SetText(plainName)
            fs:SetTextColor(r, g, b)
        end
    end)
end
Addon.MarkRowDeletePulse = MarkRowDeletePulse


--- Clear the "marked for destroy" red flash.
local function StopRowDeletePulse(rowBtn)
    if not rowBtn or not rowBtn.nameFs then return end
    if rowBtn._delPulseFrame then
        rowBtn._delPulseFrame:SetScript("OnUpdate", nil)
    end
    local fs = rowBtn.nameFs
    if rowBtn._normalNameText then
        fs:SetText(rowBtn._normalNameText)
    end
end
Addon.StopRowDeletePulse = StopRowDeletePulse


--- Sort: empty slots to bottom (like default bag sort).
local function GPH_EmptyLast(a, b)
    local aEmpty = not a.link
    local bEmpty = not b.link
    if aEmpty ~= bEmpty then return not aEmpty end
    return false
end


--- Sort by quality (legendary > epic > rare > …).
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


--- Sort by vendor price (most gold first).
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


--- Sort by item level (higher ilvl first).
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


--- Sort by category group (destroy list, then protected, then rarity).
local function GPH_Sort_CategoryGroup(a, b)
    
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


local GPH_CATEGORY_ORDER = { "HIDDEN_FIRST", "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }
local GPH_BAG_PROTECTED_CATEGORY_ORDER = { "BAG_PROTECTED", "HIDDEN_FIRST", "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }


--- Sort by item type (Weapon, Armor, Consumable, …).
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


--- Cancel "delete all of this quality" flow (like Esc).
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


--- Protect or unprotect a whole quality (e.g. all greens).
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


--- Clear rarity drag-paint when mouse button released.
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
                local gf = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
                if gf then gf.gphScrollToDefaultOnNextRefresh = true; gf._refreshImmediate = true end
                if RefreshGPHUI then RefreshGPHUI() end
                self:SetScript("OnUpdate", nil)
                self:Hide()
            end
        end)
        Addon._gphRarityDragPaintClearFrame = f
    end
    f:Show()
    f:SetScript("OnUpdate", f:GetScript("OnUpdate"))
end



--- Rarity bar button: filter, protect, delete all, mail to bank.
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
        
        if Addon.gphRarityDragPaint and Addon.gphRarityDragPaint.active then
            return
        end
        local flags = Addon.GetGphProtectedRarityFlags()
        GPH_SetRarityProtection(self.quality, not flags[self.quality])
        if gphFrame then gphFrame.gphScrollToDefaultOnNextRefresh = true; gphFrame._refreshImmediate = true end
        if RefreshGPHUI then RefreshGPHUI() end
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


--- Rarity button Alt+drag: paint protect on other quality bars.
local function GPHQualBtn_OnMouseDown(self, mouseButton)
    if mouseButton ~= "LeftButton" or not (IsAltKeyDown and IsAltKeyDown()) or not Addon.GetGphProtectedRarityFlags then return end
    local flags = Addon.GetGphProtectedRarityFlags()
    local newVal = not flags[self.quality]
    GPH_SetRarityProtection(self.quality, newVal)
    if gphFrame then gphFrame.gphScrollToDefaultOnNextRefresh = true end
    Addon.gphRarityDragPaint = Addon.gphRarityDragPaint or {}
    Addon.gphRarityDragPaint.active = true
    Addon.gphRarityDragPaint.value = newVal
    GPH_StartRarityDragPaintClear()
end


--- Rarity button tooltip + drag-paint apply on enter.
local function GPHQualBtn_OnEnter(self)
    
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


--- Hide tooltip when leaving rarity button.
local function GPHQualBtn_OnLeave(self)
    GameTooltip:Hide()
    if self.fs and (not Addon.gphPendingQuality or not Addon.gphPendingQuality[self.quality]) and (not Addon.gphContinuousDelActive or not Addon.gphContinuousDelActive[self.quality]) then
        self.fs:SetAlpha(0)
    end
end


--- Rarity button: pulse when protected, flash when continuous delete active.
local function GPHQualBtn_OnUpdate(self, elapsed)
    if Addon.gphContinuousDelActive and Addon.gphContinuousDelActive[self.quality] then
        local t = GetTime() or 0
        local pulse = (math.sin(t * 4) + 1) / 2
        if self.fs then self.fs:SetAlpha(0.3 + pulse * 0.7) end
    elseif self.fs and (GetMouseFocus() == self) then
        if self.fs:GetAlpha() < 1 then self.fs:SetAlpha(1) end
    elseif self.fs and Addon.GetGphProtectedRarityFlags then
        
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


local eventFrame = CreateFrame("Frame")
_G._FugaziBAGS_DoLogin = function() end
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then _G._FugaziBAGS_DoLogin() end
end)


local gphDestroyCopySourceKey


local Skins = _G.__FugaziBAGS_Skins or {}
local SKIN = Skins.SKIN or {}
local ApplyGPHFrameSkin = Skins.ApplyGPHFrameSkin or function() end
local ApplyBankFrameSkin = Skins.ApplyBankFrameSkin or function() end
local ApplyGphInventoryTitle = Skins.ApplyGphInventoryTitle or function() end


--- Apply frame transparency (like UI opacity slider).
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


--- Current skin's border color (for frames).
local function GetActiveSkinBorderColor()
    local SV = _G.FugaziBAGSDB
    local val = SV and SV.gphSkin or "original"
    local s = SKIN[val] or SKIN.original
    if s and s.mainBorder then
        return unpack(s.mainBorder)
    end
    
    return 0.6, 0.5, 0.2, 0.8
end


--- Apply fonts/colors to frame (title, headers, search).
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
    
    
    if f.statusText then
        local SV = _G.FugaziBAGSDB
        local useRowFont = SV and SV.gphItemDetailsCustom
        local size = 10  
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



--- Apply font/rarity color/icon to one item row.
local function ApplyItemDetailsToRow(row, item)
    if not row or not row.nameFs then return end
    local SV = _G.FugaziBAGSDB
    if not SV or not SV.gphItemDetailsCustom then
        
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
    
    local alpha = 1
    if type(SV.gphItemDetailsAlpha) == "number" then
        if SV.gphItemDetailsAlpha < 0.1 then alpha = 0.1
        elseif SV.gphItemDetailsAlpha > 1 then alpha = 1
        else alpha = SV.gphItemDetailsAlpha end
    end
    
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
    local isHearth = item and item.name and item.name:find("Hearthstone", 1, true)
    if isHearth then
        
        local name = item and (item.name or "Unknown") or "Unknown"
        row.nameFs:SetText(name)
        row.nameFs:SetTextColor(0.85, 0.92, 1.0, alpha)
    elseif rarityColor then
        local rC, gC, bC = rarityColor[1], rarityColor[2], rarityColor[3]
        local hex = string.format("%02x%02x%02x", math.floor(rC * 255), math.floor(gC * 255), math.floor(bC * 255))
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



--- Row height for item list (from icon size / settings).
local function ComputeItemDetailsRowHeight(baseHeight)
    local SVh = _G.FugaziBAGSDB
    local rowStep = baseHeight or 18
    if SVh and SVh.gphItemDetailsCustom and type(SVh.gphItemDetailsIconSize) == "number" then
        rowStep = math.max(baseHeight or 18, math.min(32, SVh.gphItemDetailsIconSize + 4))
    end
    return rowStep
end


--- Refresh skin on inventory + bank frames (reapply theme).
function ApplyTestSkin()
    if _G.TestGPHFrame and _G.TestGPHFrame.ApplySkin then _G.TestGPHFrame.ApplySkin() end
    if _G.TestBankFrame and _G.TestBankFrame.ApplySkin then _G.TestBankFrame.ApplySkin() end
    ApplyCustomizeToFrame(_G.TestGPHFrame)
    ApplyCustomizeToFrame(_G.TestBankFrame)
    if _G.TestAddon and _G.TestAddon.ApplyStackSplitSkin then _G.TestAddon.ApplyStackSplitSkin() end
    
end




local keybindOwner




local function ApplyBagKeyOverride()
    
    
end

--- B key: close default bags, open our inventory (replaces ToggleBackpack).
local function BagKeyHandler()
    if CloseAllBags then CloseAllBags() end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
end
local origToggleBackpack, origOpenAllBags

--- Hook B / OpenAllBags to open our frame instead of default bags.
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


--- Build Interface > AddOns > _FugaziBAGS options panel.
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

    

    
    local confirmCb = CreateFrame("CheckButton", "FugaziBAGSConfirmDelCheck", panel, "OptionsCheckButtonTemplate")
    confirmCb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    _G["FugaziBAGSConfirmDelCheckText"]:SetText("Confirm Auto Delete")
    confirmCb:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gridConfirmAutoDel = (self:GetChecked() == 1 or self:GetChecked() == true) end
    end)

    
    local clickSoundCb = CreateFrame("CheckButton", "FugaziBAGSClickSoundCheck", panel, "OptionsCheckButtonTemplate")
    clickSoundCb:SetPoint("TOPLEFT", confirmCb, "BOTTOMLEFT", 0, -8)
    _G["FugaziBAGSClickSoundCheckText"]:SetText("Play sounds")
    clickSoundCb:SetScript("OnClick", function(self)
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphClickSound = (self:GetChecked() == 1 or self:GetChecked() == true) end
    end)

    
    local autosellPingLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    autosellPingLabel:SetPoint("TOPLEFT", clickSoundCb, "BOTTOMLEFT", 0, -8)
    autosellPingLabel:SetText("Autosell delay (estimated ping ms):")
    local autosellPingEdit = CreateFrame("EditBox", "FugaziBAGSAutosellPingEdit", panel, "InputBoxTemplate")
    autosellPingEdit:SetAutoFocus(false)
    autosellPingEdit:SetWidth(80)
    autosellPingEdit:SetHeight(20)
    autosellPingEdit:SetMaxLetters(5)
    autosellPingEdit:SetNumeric(true)
    autosellPingEdit:SetPoint("LEFT", autosellPingLabel, "RIGHT", 8, 0)
    autosellPingEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local autosellPingOk = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    autosellPingOk:SetSize(40, 22)
    autosellPingOk:SetPoint("LEFT", autosellPingEdit, "RIGHT", 6, 0)
    autosellPingOk:SetText("OK")
    local autosellPingCheck = autosellPingOk:CreateTexture(nil, "OVERLAY")
    autosellPingCheck:SetPoint("LEFT", autosellPingOk, "RIGHT", 6, 0)
    autosellPingCheck:SetSize(16, 16)
    autosellPingCheck:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    autosellPingCheck:SetVertexColor(0, 1, 0)  
    autosellPingCheck:Hide()
    autosellPingOk:SetScript("OnClick", function()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        local raw = autosellPingEdit:GetText() and autosellPingEdit:GetText():match("^%s*(.-)%s*$")
        local num = (raw == "" or raw == nil) and nil or tonumber(raw)
        if num ~= nil then
            num = math.floor(math.max(0, math.min(9999, num)))
        end
        SV.gphAutosellPingMs = num
        autosellPingEdit:ClearFocus()
        autosellPingCheck:Show()
        local t = 0
        autosellPingOk._checkHideFrame = autosellPingOk._checkHideFrame or CreateFrame("Frame")
        local f = autosellPingOk._checkHideFrame
        f:SetScript("OnUpdate", function(_, elapsed)
            t = t + elapsed
            if t >= 2 then
                f:SetScript("OnUpdate", nil)
                if autosellPingCheck then autosellPingCheck:Hide() end
            end
        end)
        f:Show()
    end)

    
    local copyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    copyLabel:SetPoint("TOPLEFT", autosellPingLabel, "BOTTOMLEFT", 0, -16)
    copyLabel:SetText("Copy auto-destroy list from character:")

    local destroyDropdown = CreateFrame("Frame", "FugaziBAGSOptionsDestroyDropdown", panel, "UIDropDownMenuTemplate")
    destroyDropdown:SetPoint("TOPLEFT", copyLabel, "BOTTOMLEFT", -16, -8)
    destroyDropdown:SetScale(1)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(destroyDropdown, 220) end

    
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

        
        if wipe then wipe(dst) else for k in pairs(dst) do dst[k] = nil end end
        local count = 0
        for id, v in pairs(src) do
            dst[id] = { name = v.name, texture = v.texture, addedTime = v.addedTime }
            count = count + 1
        end

        
        if _G.TestAddon and _G.TestAddon.GetGphDestroyList then
            _G.TestAddon.GetGphDestroyList()
        end
        if RefreshGPHUI then
            RefreshGPHUI()
        end
        print("|cff00aaff[__FugaziBAGS]|r Copied |cffffff00" .. tostring(count) .. "|r auto-destroy entries from |cffffff00" .. tostring(gphDestroyCopySourceKey) .. "|r to this character.")
    end)

    
    local delListLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    delListLabel:SetPoint("TOPLEFT", destroyDropdown, "BOTTOMLEFT", 16, -12)
    delListLabel:SetText("Auto-delete list (current character):")

    local RefreshDelListPanel  
    
    local delListScroll = CreateFrame("ScrollFrame", "FugaziBAGSDelListScroll", panel, "UIPanelScrollFrameTemplate")
    delListScroll:SetPoint("TOPLEFT", delListLabel, "BOTTOMLEFT", 0, -12)
    delListScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -36, 36)
    delListScroll:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    delListScroll:SetBackdropColor(0, 0, 0, 0)
    delListScroll:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.4)

    local delListContent = CreateFrame("Frame", nil, delListScroll)
    delListContent:SetWidth(340) 
    delListContent:SetHeight(1)
    delListScroll:SetScrollChild(delListContent)

    local delListRows = {}
    RefreshDelListPanel = function()
        
        for _, r in pairs(delListRows) do r:Hide() end
        local A = _G.TestAddon
        local list = (A and A.GetGphDestroyList) and A.GetGphDestroyList() or {}
        local sorted = {}
        
        
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
        if autosellPingEdit then
            if SV.gphAutosellPingMs ~= nil and SV.gphAutosellPingMs ~= "" then
                autosellPingEdit:SetText(tostring(SV.gphAutosellPingMs))
            else
                autosellPingEdit:SetText("")
            end
        end
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


--- Instance tracker options sub-panel.
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
            { value = "fugazi",      text = "FUGAZI" },
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
        if val ~= "original" and val ~= "elvui" and val ~= "elvui_real" and val ~= "pimp_purple" and val ~= "fugazi" then
            val = "original"
        end
        local text
        if val == "elvui" then text = "Elvui (Ebonhold)"
        elseif val == "elvui_real" then text = "ElvUI"
        elseif val == "pimp_purple" then text = "Pimp Purple"
        elseif val == "fugazi" then text = "FUGAZI"
        else text = "Original" end
        if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, val) end
        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, text) end
        if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(dropdown, nil, 1) end
    end

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end


--- Grid view / list view options sub-panel.
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
        
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5) / 100
            self._valText:SetText(("%.2f"):format(v))
            local SV = _G.FugaziBAGSDB
            if SV then SV[key] = v end
        end)

        
        s:SetScript("OnMouseUp", function(self)
            local SV = _G.FugaziBAGSDB
            if not SV then return end
            local v = SV[key] or default

            
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
                    if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
                end
            end

            local cg = _G.FugaziBAGS_CombatGrid
            if cg then
                
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

    
    local colGap = 200
    local rowGap = -26

    local s1 = MakeSlider("FugaziGridCols", "Slots per Row", 6, 16, 1, "gridCols", 10, desc, 0, -30)
    local s2 = MakeSlider("FugaziGridSlotSize", "Slot Size", 20, 45, 1, "gridSlotSize", 30, desc, colGap, -30)

    local s3 = MakeSlider("FugaziGridSpacing", "Slot Spacing", 1, 10, 1, "gridSpacing", 4, s1, 0, rowGap)
    
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



--- Skin picker panel (themes for inventory/bank).
local function CreateSkinsPanel()
    if _G.FugaziBAGSSkinsPanel then return end
    local panel = CreateFrame("Frame", "FugaziBAGSSkinsPanel", UIParent)
    panel.name = "Skins"
    panel.parent = "_FugaziBAGS"
    panel.okay = function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
    end
    panel.cancel = function() end
    panel.default = function() end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Skins")

    
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
            { value = "fugazi",      text = "FUGAZI" },
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
                        if opt.value == "fugazi" and _G.ApplyFugaziPreset then
                            _G.ApplyFugaziPreset()
                        else
                            SV.gphCategoryHeaderFontCustom = false
                            SV.gphItemDetailsCustom = false
                            SV.gphSkinOverrides = {}
                        end
                    end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(skinDropdown, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(skinDropdown, opt.text) end
                    if _G.ApplyTestSkin then _G.ApplyTestSkin() end
                    if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
                    
                    if RefreshGPHUI then RefreshGPHUI() end
                    if RefreshBankUI then RefreshBankUI() end
                    if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
    end)
    curY = curY + 32

    local CAT_HEADER_FONTS = {
        { value = "Fonts\\ARIALN.TTF",   text = "ARIALN" },
        { value = "Fonts\\FRIZQT__.TTF", text = "FRIZQT" },
        { value = "Fonts\\MORPHEUS.TTF", text = "MORPHEUS" },
        { value = "Fonts\\skurri.ttf",   text = "Skurri" },
        
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
                    if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
    
    catFontSizeSlider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphCategoryHeaderFontSize = v end
    end)
    
    catFontSizeSlider:SetScript("OnMouseUp", function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
    end)
    curY = curY + 60 + GAP

    local colorLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    colorLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LEFT_X, -curY)
    curY = curY + ROW
    colorLabel:SetText("Custom Colors (Requires Customize enabled):")

    local COLOR_OVERRIDES = {
        { key = "headerTextColor",   label = "Header & category text" },
        { key = "mainBg",            label = "Frame background" },
        
        { key = "fitRowColor",       label = "FIT row label text" },
    }
    local function GetSkinDefaultColor(skinName, key)
        local sk = _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SKIN and _G.__FugaziBAGS_Skins.SKIN[skinName or "original"]
        if sk and sk[key] then return unpack(sk[key]) end
        if key == "mainBg" then return 0.08, 0.08, 0.12, 0.92 end
        if key == "headerTextColor" and sk and sk.titleTextColor then return unpack(sk.titleTextColor) end
        if key == "fitRowColor" then return 0.5, 0.8, 1.0, 1 end 
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
            
            local na
            if overrideKey == "mainBg" then
                local dr, dg, db, da = GetSkinDefaultColor(skinNameNow, overrideKey)
                na = da or 1
            else
                na = 1
            end
            SV2.gphSkinOverrides[overrideKey] = { nr, ng, nb, na }
            
            local Skins = _G.__FugaziBAGS_Skins
            if Skins and Skins.SKIN and Skins.SKIN[skinNameNow] and Skins.SKIN[skinNameNow][overrideKey] then
                Skins.SKIN[skinNameNow][overrideKey] = { nr, ng, nb, na }
            end
            if _G.ApplyTestSkin then _G.ApplyTestSkin() end
            if RefreshGPHUI then RefreshGPHUI() end
            if RefreshBankUI then RefreshBankUI() end
            if FugaziBAGSSkinsPanel and FugaziBAGSSkinsPanel.refresh then FugaziBAGSSkinsPanel.refresh() end
            if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
        end
        _G.ColorPickerFrame:SetColorRGB(r, g, b)
        
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
            if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
                    if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
    
    itemDetailsFontSizeSlider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        self._valText:SetText(tostring(v))
        local SV = _G.FugaziBAGSDB
        if SV then SV.gphItemDetailsFontSize = v end
    end)
    
    itemDetailsFontSizeSlider:SetScript("OnMouseUp", function(self)
        if RefreshGPHUI then RefreshGPHUI() end
        if RefreshBankUI then RefreshBankUI() end
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
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
        if _G.FugaziInstanceTracker_RefreshSkinFromBAGS then _G.FugaziInstanceTracker_RefreshSkinFromBAGS() end
    end)
    curY = curY + 60

    local itemDetailsAlphaSlider = CreateFrame("Slider", "FugaziBAGSSkinsItemDetailsAlpha", scrollChild, "OptionsSliderTemplate")
    itemDetailsAlphaSlider:SetPoint("TOPLEFT", itemDetailsIconSizeSlider, "BOTTOMLEFT", 0, -32)
    itemDetailsAlphaSlider:SetWidth(180)
    
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
        local skText = (sk == "elvui" and "Elvui (Ebonhold)") or (sk == "elvui_real" and "ElvUI") or (sk == "pimp_purple" and "Pimp Purple") or (sk == "fugazi" and "FUGAZI") or "Original"
        UIDropDownMenu_SetSelectedValue(skinDropdown, sk)
        UIDropDownMenu_SetText(skinDropdown, skText)

        cbCatFont:SetChecked(SV.gphCategoryHeaderFontCustom)
        local hFont = SV.gphCategoryHeaderFont or "Fonts\\ARIALN.TTF"
        UIDropDownMenu_SetSelectedValue(catFontDropdown, hFont)
        for _, o in ipairs(CAT_HEADER_FONTS) do if o.value == hFont then UIDropDownMenu_SetText(catFontDropdown, o.text) break end end
        catFontSizeSlider:SetValue(SV.gphCategoryHeaderFontSize or 11)

        
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

        
        local rq = raritySelectDropdown.selectedQuality or 1
        UIDropDownMenu_SetSelectedValue(raritySelectDropdown, rq)
        for _, o in ipairs(RARITY_OPTIONS) do if o.q == rq then UIDropDownMenu_SetText(raritySelectDropdown, o.label) break end end
        local rCol = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsRarityColors and SV.gphSkinOverrides.itemDetailsRarityColors[rq]
        if rCol then rarityColorBtn._swatch:SetVertexColor(unpack(rCol))
        else
            local def = Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[rq]
            rarityColorBtn._swatch:SetVertexColor(def and def.r or 1, def and def.g or 1, def and def.b or 1)
        end
        
        local iCol = SV.gphSkinOverrides and SV.gphSkinOverrides.itemDetailsIconColor or {1, 1, 1}
        iconColorBtn._swatch:SetVertexColor(unpack(iCol))
    end

    if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel) end
end


--- Instructions / help panel in options.
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
    
    text:SetWidth(380)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetTextColor(1, 1, 1)

    text:SetText(table.concat({
        "|cffffe070Bags and frames:|r",
        " - |cff40c0ffB key|r: Open/close |cff40c0ffFugaziBAGS|r instead of Blizzard bags.",
        " - |cff40c0ffRight-Click the Inventory Header|r to open the |cff40c0ffFugaziBAGS|r menu.",
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

--- Load addon UI after PLAYER_LOGIN (create frames, hooks).
local function RunAddonLoader()
    if addonLoaderDone then return end
    addonLoaderDone = true
    CreateOptionsPanel()
    
    
    CreateGridviewOptionsPanel()
    CreateSkinsPanel()
    CreateInstructionsPanel()
    
    DB = _G.FugaziBAGSDB or DB

    
    if DB and DB.seenInstructions ~= true then
        DB.seenInstructions = true

        
        if InterfaceOptionsFrame_OpenToCategory then
            local instrPanel = _G.FugaziBAGSInstructionsOptionsPanel
            if instrPanel then
                InterfaceOptionsFrame_OpenToCategory(instrPanel)
                InterfaceOptionsFrame_OpenToCategory(instrPanel) 
            else
                InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
                InterfaceOptionsFrame_OpenToCategory("_FugaziBAGS")
            end
        end

    end

    print("|cff00aaff[__FugaziBAGS]|r Loaded. Bag key (B) opens inventory.")

end


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

		
		if aID == HEARTHSTONE_ID and bID ~= HEARTHSTONE_ID then return true end
		if bID == HEARTHSTONE_ID and aID ~= HEARTHSTONE_ID then return false end

		local DB = _G.FugaziBAGSDB
		local mode = DB and DB.gphSortMode or "rarity"
		local aRarity, bRarity = bagQualities[a] or 0, bagQualities[b] or 0

		
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



local Addon = _G.TestAddon


Addon.RarityMoveJob = Addon.RarityMoveJob or nil
local rarityMoveWorker = Addon.RarityMoveWorker or CreateFrame("Frame")
Addon.RarityMoveWorker = rarityMoveWorker
rarityMoveWorker:Hide()


--- Is this item/quality protected (soulbound-to-vendor)?
local function RarityIsProtected(itemId, quality)
    if Addon.IsItemProtectedAPI then
        return Addon.IsItemProtectedAPI(itemId, quality)
    end
    return false
end


--- Next item of given quality in bags (for mail-to-alt).
local function FindNextFromBags(rarity)
    local function qualityMatches(r, q)
        if q == r then return true end
        if r == 4 and q >= 4 then return true end
        return false
    end
    for bag = 0, 4 do
        local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local _, _, locked = GetContainerItemInfo(bag, slot)
            local itemId = GetContainerItemID and GetContainerItemID(bag, slot)
            if itemId and not locked then
                local _, _, q = GetItemInfo(itemId)
                q = q or 0
                if qualityMatches(rarity, q) and not RarityIsProtected(itemId, q) then
                    return bag, slot
                end
            end
        end
    end
    return nil, nil
end


--- Next item of given quality in bank.
local function FindNextFromBank(rarity)
    local function qualityMatches(r, q)
        if q == r then return true end
        if r == 4 and q >= 4 then return true end
        return false
    end
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
                if qualityMatches(rarity, q) and not RarityIsProtected(itemId, q) then
                    return bagID, slot
                end
            end
        end
        return nil, nil
    end

    
    local mainCandidates = {}
    if BANK_CONTAINER ~= nil then
        table.insert(mainCandidates, BANK_CONTAINER)
    end
    table.insert(mainCandidates, -1)  
    table.insert(mainCandidates, 5)   

    for _, bagID in ipairs(mainCandidates) do
        local bag, slot = scanBag(bagID)
        if bag then return bag, slot end
    end

    
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


local mailRarityWorker = CreateFrame("Frame")
mailRarityWorker:Hide()
Addon.MailRarityQueue = {}
Addon.MailRarityIndex = 0
Addon.MailRarityActive = false


--- Send next batch of items (by quality) in mail.
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

    
    for i = 1, 12 do
        if GetSendMailItem(i) then
            ClickSendMailItemButton(i, true)
        end
    end

    
    local attached = 0
    local targetRarity = Addon.MailRarityJobQuality 

    while Addon.MailRarityIndex < #Addon.MailRarityQueue and attached < 12 do
        Addon.MailRarityIndex = Addon.MailRarityIndex + 1
        local item = Addon.MailRarityQueue[Addon.MailRarityIndex]
        
        local link = GetContainerItemLink(item.bag, item.slot)
        if link then
            local _, _, locked = GetContainerItemInfo(item.bag, item.slot)
            local itemId = tonumber(link:match("item:(%d+)"))
            local _, _, q = GetItemInfo(link)
            q = q or 0
            
            
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


--- Mail progress tick: fill next slot, send when full.
local function mailRarityOnUpdate(self, elapsed)
    if not Addon.MailRarityActive then 
        self:SetScript("OnUpdate", nil)
        return 
    end
    
    self._timeoutTimer = (self._timeoutTimer or 0) + elapsed
    if self._timeoutTimer >= 1.5 then
        
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
    
    self._timeoutTimer = 0

    if event == "MAIL_SEND_SUCCESS" then
        
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


--- Start mailing all items of one quality (e.g. all greys to alt).
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
    mailRarityWorker._timeoutTimer = 0 
    mailRarityWorker:RegisterEvent("MAIL_SEND_SUCCESS")
    mailRarityWorker:RegisterEvent("MAIL_FAILED")
    mailRarityWorker:RegisterEvent("MAIL_CLOSED")
    if mailRarityWorker._onUpdateFunc then
        mailRarityWorker:SetScript("OnUpdate", mailRarityWorker._onUpdateFunc)
    end
    SendNextRarityBatch()
end











--- Check if AH addon (TSM etc) is loaded for price tooltips.
local function AuctionAddonLoaded()
    return (_G.TSMAPI and _G.TSMAPI.GetItemPrices) or _G.Atr_GetAuctionPrice
end



--- Get AH price for link (TSM/Appraiser style).
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
--- Scan tooltip for "Soulbound" text (to detect binding).
local function GetSoulboundScanTooltip()
    if not gphSoulboundScanTooltip then
        gphSoulboundScanTooltip = CreateFrame("GameTooltip", "TestGPHSoulboundScanTT", UIParent, "GameTooltipTemplate")
        gphSoulboundScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        gphSoulboundScanTooltip:ClearAllPoints()
        gphSoulboundScanTooltip:SetPoint("CENTER", UIParent, "CENTER", 99999, 99999) 
    end
    return gphSoulboundScanTooltip
end



--- Is this item link soulbound? (tooltip scan.)
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



--- Is bag slot item soulbound?
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




--- Sum vendor + AH value for visible items (sync).
local function ComputeVendorAuctionTotalsSync()
    local previouslyWorn = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}
    local vendorCopper = 0   
    local auctionCopper = 0  
    local itemCounts = {}    
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



--- Estimated total value (vendor + AH) for a list of items.
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




--- Total session value (vendor + AH + gold).
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


--- Play click sound (bag slot / button).
function Addon.PlayClickSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    local last = Addon._gphClickSoundLast or 0
    if now - last < 0.25 then return end
    Addon._gphClickSoundLast = now
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg")
end


--- Play hover sound (rarity bar etc).
function Addon.PlayHoverSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    if (Addon._gphClickSoundLast or 0) > 0 and (now - Addon._gphClickSoundLast) < 0.15 then return end
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\hover.ogg")
end


--- Play trash/destroy sound.
function Addon.PlayTrashSound()
    local SV = _G.FugaziBAGSDB
    if not SV or SV.gphClickSound == false then return end
    local now = GetTime and GetTime() or 0
    local last = Addon._gphTrashSoundLast or 0
    if now - last < 0.25 then return end
    Addon._gphTrashSoundLast = now
    PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\trash.ogg")
end


--- Build main inventory frame (the bag window with categories, sort, rarity bars).
local function CreateGPHFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 2, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "FugaziBAGS_GPHFrame", UIParent)
    local cg = _G.FugaziBAGS_CombatGrid
    local initW, initH = 340, 400
    if cg and cg.ComputeFrameSize then
        initW, initH = cg.ComputeFrameSize()
    end
    f:SetWidth(initW)
    f:SetHeight(initH)
    f.gphGridFrameW = initW
    f.gphGridFrameH = initH
    
    f:SetPoint("RIGHT", UIParent, "RIGHT", -444, -4)
    f:Hide()
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    
    local function GPHOnDragStart()
        if f._isDragging then return end
        if IsAltKeyDown and IsAltKeyDown() then return end
        f._isDragging = true
        if f.gphSelectedItemId then
            f.gphSelectedItemId = nil
            f.gphSelectedIndex = nil
            f.gphSelectedRowBtn = nil
            f.gphSelectedItemLink = nil
            if f.HideGPHUseOverlay then f.HideGPHUseOverlay(f) end
        end
        f:StartMoving()
    end
    local function GPHOnDragStop()
        if not f._isDragging then return end
        f._isDragging = nil
        f:StopMovingOrSizing()
        if f.NegotiateSizes then f:NegotiateSizes() end
        DB.gphDockedToMain = false
        Addon.SaveFrameLayout(f, "gphShown", "gphPoint")
        local sf = f.scrollFrame
        local c = sf and sf:GetScrollChild()
        if c and sf then
            local v = f.gphScrollOffset or 0
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, v)
            c:SetWidth(SCROLL_CONTENT_WIDTH)
            if c.SetHeight then c:SetHeight(c:GetHeight() or 1) end
        end
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", GPHOnDragStart)
    f:SetScript("OnDragStop", GPHOnDragStop)
    f:SetScript("OnHide", function()
        if f.gphProxyFrame then f.gphProxyFrame:Hide() end
        Addon.SaveFrameLayout(f, "gphShown", "gphPoint")
        -- Reset list scroll so next open doesn't inherit "bottom" from this session.
        if not f.gphGridMode and f.gphScrollBar then
            f.gphScrollOffset = 0
            f.gphScrollBar:SetMinMaxValues(0, 0)
            f.gphScrollBar:SetValue(0)
        end
    end)
    f._gphSkinAppliedOnFirstShow = nil  
    f:SetScript("OnShow", function()
        if f.gphProxyFrame then f.gphProxyFrame:Show() end
        if not f._gphSkinAppliedOnFirstShow and f.ApplySkin then
            f._gphSkinAppliedOnFirstShow = true
            f.ApplySkin()
        end
        if ApplyCustomizeToFrame then ApplyCustomizeToFrame(f) end
        if f.gphTitle then ApplyGphInventoryTitle(f.gphTitle) end
        
        f.gphScrollToDefaultOnNextRefresh = true
        f._gphHomebaseRetryScheduled = nil
        if gphFrame then gphFrame._refreshImmediate = true end
        if RefreshGPHUI then RefreshGPHUI() end
        -- Second refresh next frame when layout is ready; first run may have wrong scroll frame size.
        local df = Addon._gphSelectionDeferFrame
        if df then
            df:Show()
            df:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                self:Hide()
                if gphFrame then
                    gphFrame.gphScrollToDefaultOnNextRefresh = true
                    gphFrame._refreshImmediate = true
                end
                if RefreshGPHUI then RefreshGPHUI() end
            end)
        end
    end)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(10)
    f.EXPANDED_HEIGHT = 400

    
    
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
        
    end)
    f.gphEscCatcher = gphEscCatcher

    
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

    
    local gphMenu = CreateFrame("Frame", "FugaziBAGS_GPHMenu", f, "UIDropDownMenuTemplate")
    local function GPHTitleMenu_Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        local SV = _G.FugaziBAGSDB
        if not level or level == 1 then
            
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
                    
                    if Addon.StopGPHSession then Addon.StopGPHSession() end
                else
                    
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

            
            info = UIDropDownMenu_CreateInfo()
            info.text = "Autoselling"
            info.isNotRadio = true
            info.checked = (SV.gphAutoVendor == true)
            info.func = function()
                if not SV.gphAutoVendor then
                    StaticPopup_Show("GPH_AUTOSELL_CONFIRM")
                else
                    SV.gphAutoVendor = false
                    
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
                
            end
            UIDropDownMenu_AddButton(info)

            
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

            
            local forceGrid = GetPerChar("gphForceGridView", false)
            if not forceGrid then
                info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)
                local gridMode = GetPerChar("gphGridMode", false)
                info = UIDropDownMenu_CreateInfo()
                info.text = (not gridMode) and "|cff00ff00List View|r" or "List View"
                info.checked = not gridMode
                info.func = function()
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
    titleBar:SetScript("OnDragStart", GPHOnDragStart)
    titleBar:SetScript("OnDragStop", GPHOnDragStop)
    titleBar:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            UIDropDownMenu_Initialize(gphMenu, GPHTitleMenu_Initialize, "MENU")
            ToggleDropDownMenu(1, nil, gphMenu, "cursor", 0, 0)
        end
    end)
    f.gphTitleBar = titleBar

    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    ApplyGphInventoryTitle(title)
    f.gphTitle = title

    local GPH_BTN_W, GPH_BTN_H = 36, 18
    local GPH_BTN_GAP = 2

    

    
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

    
    
    local container = CreateFrame("Frame", "FugaziBAGS_InventoryContainer", keybindOwner)
    container:SetSize(1, 1)
    container:SetPoint("BOTTOMLEFT", keybindOwner, "BOTTOMLEFT", -10000, -10000)
    container:Hide()
    container:SetScript("OnShow", function()
        local forceGrid = GetPerChar("gphForceGridView", false)
        local wantGrid = GetPerChar("gphGridMode", false)
        local cg = _G.FugaziBAGS_CombatGrid
        f:Show()
        f.gphGridMode = (forceGrid or wantGrid)
        if f.gphGridMode and cg and cg.ShowInFrame then
            cg.ShowInFrame(f)
        else
            if cg and cg.HideInFrame then cg.HideInFrame(f) end
        end
    end)
    container:SetScript("OnHide", function()
        local cg = _G.FugaziBAGS_CombatGrid
        if cg and cg.HideInFrame then cg.HideInFrame(f) end
        f:Hide()
    end)
    _G.FugaziBAGS_InventoryContainer = container
    f.gphInventoryContainer = container

    
    local proxy = CreateFrame("Frame", nil, UIParent)
    proxy:SetSize(1, 1)
    proxy:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    proxy:Hide()
    proxy:SetScript("OnShow", function() container:Show() end)
    proxy:SetScript("OnHide", function() container:Hide() end)
    f.gphProxyFrame = proxy

    
    
    
    
    
    
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

    
    local _syncingVisibility = false
    f:HookScript("OnShow", function()
        if _syncingVisibility then return end
        _syncingVisibility = true
        if container and not container:IsShown() then container:Show() end
        _syncingVisibility = false
    end)
    f.SetGphStatusTextFitted = function(self, text)
        local fs = self.statusText
        if not fs or not text then return end

        fs:SetText(text)

        local btn = self.gphSearchBtn
        local frameRight = self:GetRight()
        local btnRight = btn and btn:GetRight()
        if not frameRight or not btnRight then
            return
        end
        local available = frameRight - btnRight - 8
        if available <= 0 then
            return
        end

        local font, size, flags = fs:GetFont()
        local baseFont = self._statusTextBaseFont or font
        local baseSize = self._statusTextBaseSize or size or 12
        local baseFlags = self._statusTextBaseFlags or flags

        
        fs:SetFont(baseFont, baseSize, baseFlags)
        local currentWidth = fs:GetStringWidth()
        local wantedSize = baseSize
        local minSize = 8

        if currentWidth > available then
            while wantedSize > minSize do
                wantedSize = wantedSize - 1
                fs:SetFont(baseFont, wantedSize, baseFlags)
                currentWidth = fs:GetStringWidth()
                if currentWidth <= available then break end
            end
        end
    end

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

    
    local function UpdateGPHCollapse()
        if not f.scrollFrame then return end
        if not f.gphGridMode then
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
    


    
    local function UpdateGPHButtonVisibility()
        if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
    end
    f.UpdateGPHButtonVisibility = UpdateGPHButtonVisibility


    
    if DB.gphDestroyPreferProspect == nil then DB.gphDestroyPreferProspect = false end

    
    local destroyBtn = CreateFrame("Button", nil, titleBar, "SecureActionButtonTemplate")
    destroyBtn:SetSize(22, 22) 

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
    destroyBg:SetTexture(0, 0, 0, 0) 
    destroyBtn.bg = destroyBg
    local destroyIcon = destroyBtn:CreateTexture(nil, "OVERLAY", nil, 7)
    destroyIcon:SetAllPoints(destroyBtn)
    destroyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) 
    destroyIcon:SetAlpha(1.0)
    destroyBtn.icon = destroyIcon

    local function UpdateDestroyButtonAppearance()
        local hasDE = Addon.IsSpellKnownByName("Disenchant")
        local hasProspect = Addon.IsSpellKnownByName("Prospecting")
        
        local preferProspect = DB.gphDestroyPreferProspect and hasProspect and hasDE
        local iconPath
        
        if (hasProspect and not hasDE) or preferProspect then
            
            iconPath = "Interface\\Icons\\inv_misc_gem_bloodgem_01"
        else
            
            iconPath = "Interface\\Icons\\Inv_rod_enchantedfelsteel"
        end

        if iconPath then
            destroyIcon:SetTexture(iconPath)
            destroyIcon:Show()
            destroyBtn:Show()
            destroyBtn:SetAlpha(0.6)
            
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
        
        if button ~= "LeftButton" then
            self:SetAttribute("macrotext1", "")
            return
        end
        
        if UnitCastingInfo and UnitCastingInfo("player") then
            self:SetAttribute("macrotext1", "")
            return
        end
        if IsShiftKeyDown() then
            
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

    
    local mailBtn = CreateFrame("Button", nil, titleBar)
    mailBtn:SetSize(22, 22) 

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
    mailIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) 
    mailIcon:SetTexture("Interface\\Icons\\inv_letter_09")
    mailBtn.icon = mailIcon

    
    if MailFrameTab1 then
        hooksecurefunc("PanelTemplates_SetTab", function(frame, id)
            if frame == MailFrame and f.UpdateGPHProfessionButtons then
                local d = CreateFrame("Frame")
                d:SetScript("OnUpdate", function(self) self:SetScript("OnUpdate", nil); f:UpdateGPHProfessionButtons() end)
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
                    
                elseif money > 0 then
                    
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

        
        
        if f.gphMailBtn then
            if isAtMail then
                local isSendTab = (MailFrame.selectedTab == 2)
                if isSendTab then
                    f.gphMailBtn.icon:SetTexture("Interface\\Icons\\inv_letter_19", true)
                else
                    f.gphMailBtn.icon:SetTexture("Interface\\Icons\\inv_letter_09", true)
                end

                
                f.gphMailBtn:SetSize(22, 22) 
                f.gphMailBtn:ClearAllPoints()
                if anchorToLeft then
                    f.gphMailBtn:SetPoint("LEFT", titleBar, "LEFT", 4, 0) 
                else
                    f.gphMailBtn:SetPoint("LEFT", lastBtn, "RIGHT", 4, 0) 
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
    
    


    
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetJustifyH("RIGHT")
    f.statusText = statusText
    statusText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -25, -45)
    statusText:SetWordWrap(false)
    if statusText.SetNonSpaceWrap then statusText:SetNonSpaceWrap(false) end
    do
        local font, size, flags = statusText:GetFont()
        f._statusTextBaseFont, f._statusTextBaseSize, f._statusTextBaseFlags = font, size or 12, flags
    end

    
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
    gphSearchEditBox:SetPoint("RIGHT", f, "TOPRIGHT", -8, 0) 

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
    
    gphSearchEditBox:SetScript("OnChar", function()
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphClickSound ~= false and PlaySoundFile then
            PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg")
        end
    end)
    
    gphSearchEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphClickSound ~= false and PlaySoundFile then
            PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\click.ogg") 
        end
    end)
    local function syncSearchFromEditBox()
        local raw = (f.gphSearchEditBox and f.gphSearchEditBox:GetText()) or ""
        local trimmed = raw:match("^%s*(.-)%s*$")
        if (f.gphSearchText or "") ~= trimmed then
            f.gphSearchText = trimmed
            if _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.ApplySearch then
                _G.FugaziBAGS_CombatGrid.ApplySearch(f.gphSearchText)
            end
            if RefreshGPHUI then RefreshGPHUI() end
            if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then RefreshBankUI() end
        end
    end
    gphSearchEditBox:SetScript("OnTextChanged", function(self)
        local old = f.gphSearchText or ""
        f.gphSearchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        
        if #f.gphSearchText < #old then
            local SV = _G.FugaziBAGSDB
            if SV and SV.gphClickSound ~= false and PlaySoundFile then
                PlaySoundFile("Interface\\AddOns\\__FugaziBAGS\\media\\hover.ogg")
            end
        end
        if _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.ApplySearch then
            _G.FugaziBAGS_CombatGrid.ApplySearch(f.gphSearchText)
        end
        RefreshGPHUI()
        if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then RefreshBankUI() end
    end)
    
    gphSearchEditBox:SetScript("OnKeyUp", function(self)
        syncSearchFromEditBox()
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

    
    local gphHeader = CreateFrame("Frame", nil, f)
    gphHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    gphHeader:SetPoint("TOPRIGHT", sep, "TOPRIGHT", 0, -4)
    gphHeader:SetHeight(14)
    f.gphHeader = gphHeader

    
    local gphBagSpaceBtn = CreateFrame("Button", nil, gphHeader)
    gphBagSpaceBtn:SetSize(36, 14)
    gphBagSpaceBtn:EnableMouse(true)
    gphBagSpaceBtn:RegisterForDrag("LeftButton")
    gphBagSpaceBtn:SetFrameLevel(gphHeader:GetFrameLevel() + 20)  
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
        
        
        if self.LayoutGrid then 
            self:LayoutGrid() 
        elseif _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.LayoutGrid then
            _G.FugaziBAGS_CombatGrid.LayoutGrid()
        end
        if _G.RefreshGPHUI then _G.RefreshGPHUI() end
    end

    
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
    scrollFrame:SetPoint("TOPLEFT", gphHeader, "BOTTOMLEFT", 0, -14) 
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 20)
    f.scrollFrame = scrollFrame
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end
    f.gphScrollBar = scrollFrame:GetName() and _G[scrollFrame:GetName() .. "ScrollBar"] or nil

    f.gphScrollOffset = 0  
    local scrollBar = f.gphScrollBar
    
    local function ClearGPHSelectionOnScroll()
        if not f.gphSelectedItemId then return end
        f.gphSelectedItemId = nil
        f.gphSelectedIndex = nil
        f.gphSelectedRowBtn = nil
        f.gphSelectedItemLink = nil
        if f.HideGPHUseOverlay then f.HideGPHUseOverlay(f) end
    end
    
    
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
    
    local function gphDoScroll(sf, delta)
        ClearGPHSelectionOnScroll()
        local c = sf:GetScrollChild()
        if not c then return end
        local cur = f.gphScrollOffset or 0
        local viewHeight = sf:GetHeight()
        local contentHeight = c:GetHeight()
        local maxScroll = math.max(0, contentHeight - viewHeight)
        local step = 20
        
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

    
    
    f.NegotiateSizes = function(self)
        if not DB then return end
        
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        local bW, bH, iW, iH
        
        local cg = _G.FugaziBAGS_CombatGrid
        
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
        if self._gridNeedsHeaderRefresh then
            self._gridNeedsHeaderRefresh = nil
            if self.gphGridMode and RefreshGPHUI then self._refreshImmediate = true; RefreshGPHUI() end
        end
        if not self._isDragging then
            self._throttleT = (self._throttleT or 0) + elapsed
            if self._throttleT >= 0.1 then
                self._throttleT = 0
                
                if not (InCombatLockdown and InCombatLockdown()) then
                    self:NegotiateSizes()
                end

                
                if not self.gphGridMode and RefreshGPHUI then
                    self._lastModifiers = self._lastModifiers or {}
                    local alt = IsAltKeyDown and IsAltKeyDown()
                    local ctrl = IsControlKeyDown and IsControlKeyDown()
                    if self._lastModifiers.alt ~= alt or self._lastModifiers.ctrl ~= ctrl then
                        self._lastModifiers.alt = alt
                        self._lastModifiers.ctrl = ctrl
                        self._refreshImmediate = true
                        RefreshGPHUI()
                    end
                end

                
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
            
            if self.gphSelectedItemId and (now - (self.gphSelectedTime or 0) > 10) then
                self.gphSelectedItemId = nil
                self.gphSelectedIndex = nil
                self.gphSelectedRowBtn = nil
                self.gphSelectedItemLink = nil
                if self.HideGPHUseOverlay then self.HideGPHUseOverlay(self) end
            end
            
            if InCombatLockdown and InCombatLockdown() then
                self.gphCombatRefreshElapsed = (self.gphCombatRefreshElapsed or 0) + elapsed
                if self.gphCombatRefreshElapsed >= 1 then
                    self.gphCombatRefreshElapsed = 0
                    if RefreshGPHUI then RefreshGPHUI() end
                end
            else
                self.gphCombatRefreshElapsed = 0
            end
            
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
                    local fullText = "|cffdaa520Gold:|r " .. goldStr
                        .. "   |cffdaa520Timer:|r |cffffffff" .. timerStr .. "|r"
                        .. "   |cffdaa520GPH:|r " .. gphStr
                    if self.SetGphStatusTextFitted then
                        self:SetGphStatusTextFitted(fullText)
                    else
                        self.statusText:SetText(fullText)
                    end
                end
            end
            Addon.RefreshItemDetailLive()
            
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
    
    
    UpdateGPHButtonVisibility()
    UpdateGPHCollapse()
    if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
    
    return f
end






--- Get main bank container (reagent bank etc).
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


local MAIN_BANK_SLOTS = 28
local NUM_BANK_BAGS = NUM_BANKBAGSLOTS or 6  
local BANK_ROW_HEIGHT = 18   
local BANK_LIST_WIDTH = 296  
local BANK_HEADER_HEIGHT = 18  
local BANK_DEBUG = false  

local function BankDebug(msg) if BANK_DEBUG and Addon.AddonPrint then Addon.AddonPrint("[Bank] " .. msg) end end


--- Clear one bank slot (pickup + clear).
local function DeleteBankSlot(bagID, slotID)
	if bagID == nil or slotID == nil then return end
	if PickupContainerItem and DeleteCursorItem then
		PickupContainerItem(bagID, slotID)
		DeleteCursorItem()
	end
end


local BANK_ROW_POOL, BANK_ROW_POOL_USED = {}, 0

--- Return all bank list rows to pool (reuse).
local function ResetBankRowPool()
	for i = 1, BANK_ROW_POOL_USED do
		if BANK_ROW_POOL[i] then BANK_ROW_POOL[i]:Hide() end
	end
	BANK_ROW_POOL_USED = 0
end


local BANK_AGG_POOL, BANK_AGG_POOL_USED = {}, 0
local BANK_ITEM_POOL, BANK_ITEM_POOL_USED = {}, 0


--- Aggregated bank data (stacked counts by item).
local function GetBankAggTable()
    BANK_AGG_POOL_USED = BANK_AGG_POOL_USED + 1
    local t = BANK_AGG_POOL[BANK_AGG_POOL_USED]
    if not t then t = {}; BANK_AGG_POOL[BANK_AGG_POOL_USED] = t end
    wipe(t)
    return t
end


--- Flat list of bank items (for list view).
local function GetBankItemTable()
    BANK_ITEM_POOL_USED = BANK_ITEM_POOL_USED + 1
    local t = BANK_ITEM_POOL[BANK_ITEM_POOL_USED]
    if not t then t = {}; BANK_ITEM_POOL[BANK_ITEM_POOL_USED] = t end
    wipe(t)
    return t
end


--- Reset bank row + data pools for refresh.
local function ResetBankDataPools()
    BANK_AGG_POOL_USED = 0
    BANK_ITEM_POOL_USED = 0
end
local BANK_DELETE_X_WIDTH = 16

--- Get or create one bank list row (icon, name, count).
local function GetBankRow(parent)
	BANK_ROW_POOL_USED = BANK_ROW_POOL_USED + 1
	local row = BANK_ROW_POOL[BANK_ROW_POOL_USED]
	if not row then
		row = CreateFrame("Frame", nil, parent)
		row:SetWidth(BANK_LIST_WIDTH)
		row:SetHeight(BANK_ROW_HEIGHT)
		row:EnableMouse(true)
		row.deleteBtn = nil
		local clickArea = CreateFrame("Button", nil, row)
		clickArea:SetPoint("LEFT", row, "LEFT", 0, 0)
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
	
	if row.deleteBtn then
		row.deleteBtn:Hide()
		row.deleteBtn:SetParent(nil)
		row.deleteBtn = nil
	end
	row:SetParent(parent)
	
	local bf = _G.TestBankFrame
	if bf and bf._bankListW then row:SetWidth(bf._bankListW) end
	row:Show()
	row.clickArea:Show()
	if row.pulseTex then row.pulseTex:Hide() end
	return row
end


--- Build bank frame (list/grid of bank slots, like default bank UI).
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
    f:SetScript("OnHide", function()
        local inv = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
        if inv and inv._gphPreBankAnchor then
            local p, r, rp, x, y = unpack(inv._gphPreBankAnchor)
            if p and rp and x and y then
                inv:ClearAllPoints()
                inv:SetPoint(p, r or UIParent, rp, x, y)
            end
            inv._gphPreBankAnchor = nil
            inv._gphRestoredFromBankOnHide = true
        end
    end)
	f:SetFrameStrata("DIALOG")
	f:SetFrameLevel(10)
    
    

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

	
	local bankMenu = CreateFrame("Frame", "FugaziBAGS_BankMenu", f, "UIDropDownMenuTemplate")
	local function BankTitleMenu_Initialize(self, level)
		local info = UIDropDownMenu_CreateInfo()
		local SV = _G.FugaziBAGSDB
		if not level or level == 1 then
            
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

			
			info = UIDropDownMenu_CreateInfo()
			
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

            
            local bankForceGrid = GetPerChar("gphBankForceGridView", false)
            if not bankForceGrid then
                info = UIDropDownMenu_CreateInfo(); info.text = ""; info.isTitle = true; info.notCheckable = true; UIDropDownMenu_AddButton(info)
                local bankGridMode = GetPerChar("gphBankGridMode", false)
                info = UIDropDownMenu_CreateInfo()
                info.text = (not f.gphGridMode) and "|cff00ff00List View|r" or "List View"
                info.checked = not f.gphGridMode
                info.func = function()
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

	
	local titleFrameLevel = f:GetFrameLevel() + 25

	local sep = f:CreateTexture(nil, "ARTWORK")
	sep:SetHeight(1)
	sep:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 10, -6)
	sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
	sep:SetTexture(1, 1, 1, 0.15)
	f.sep = sep


	
	local bagRow = CreateFrame("Frame", nil, f)
	bagRow:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 6, -6)
	bagRow:SetPoint("TOPRIGHT", sep, "TOPRIGHT", -6, -6)
	bagRow:SetHeight(0)
	bagRow:SetFrameLevel(f:GetFrameLevel() + 30)
	bagRow:EnableMouse(false)  
	f.bagRow = bagRow
	f.bagRowVisible = false
	bagRow:SetAlpha(0)
	bagRow:Hide()
	f.bagSlots = {}
	for i = 1, NUM_BANK_BAGS do
		local bagID = (NUM_BAG_SLOTS or 4) + i
		local btn = CreateFrame("Button", ("TestBankBag%d"):format(i), bagRow)
		btn:SetSize(20, 20)
		
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

	
	
	f.bankRarityFilter = nil
	local BANK_HEADER_Y_OFF = -(6 + 20 + 4)  
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
    
    bankSpaceBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    bankSpaceBtn.bg = bankSpaceBg
    
    bankSpaceBtn:SetScript("OnClick", function(self, button)
		if button ~= "LeftButton" then return end
		if Addon.PlayClickSound then Addon.PlayClickSound() end
		
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
	
    local bankSpaceGlow = bankSpaceBtn:CreateTexture(nil, "OVERLAY")
    bankSpaceGlow:SetAllPoints()
    bankSpaceGlow:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    
    bankSpaceGlow:SetVertexColor(1, 0.85, 0.2, 0.5)
	bankSpaceGlow:SetBlendMode("ADD")
	bankSpaceGlow:Hide()
	bankSpaceBtn.glow = bankSpaceGlow
	

	
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
	
	local bankChildReuse = {}
	local function fillChildReuse(t, ...)
		for i = 1, select("#", ...) do t[i] = select(i, ...) end
		return select("#", ...)
	end
	local function SyncModifierOverlaysForContent(content, altDown)
		if not content or not content.GetChildren then return end
		wipe(bankChildReuse)
		fillChildReuse(bankChildReuse, content:GetChildren())
		for i = 1, #bankChildReuse do
			local row = bankChildReuse[i]
			local ca = row and row.clickArea
			local modOv = ca and ca._fugaziModifierOverlay
			if modOv and modOv.Show and modOv.Hide and modOv.EnableMouse then
				if altDown then modOv:Show(); modOv:EnableMouse(true) else modOv:Hide(); modOv:EnableMouse(false) end
			end
		end
	end
	local defaultBankSpaceColor = { 1, 0.85, 0.4, 1 }
	f:SetScript("OnUpdate", function(self)
		if not self:IsShown() then return end
		
		pcall(SyncModifierOverlaysForContent, self.content, not not (IsAltKeyDown and IsAltKeyDown()))
		
		if self.bankSpaceBtn then
			local hasItem = (GetCursorInfo and GetCursorInfo() == "item")
			if self.bankSpaceBtn.glow then
				if hasItem then self.bankSpaceBtn.glow:Show() else self.bankSpaceBtn.glow:Hide() end
			end
			if self.bankSpaceBtn.fs then
				if hasItem then
					self.bankSpaceBtn.fs:SetTextColor(1, 1, 1, 1)
				else
					local c = self.bankSpaceTextColor or defaultBankSpaceColor
					self.bankSpaceBtn.fs:SetTextColor(c[1], c[2], c[3], c[4])
				end
			end
		end
	end)
	
	local leftPad, bagW, bagGap, spacing, numRarityBtns = 0, 36, 12, 4, 5
	local headerW = (f:GetWidth() or 340) - 14
	local qualityRight = headerW - 14
	local startX = leftPad + bagW + bagGap
	local rarityTotalW = qualityRight - startX
	local slotW = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
	if slotW < 24 then slotW = 24 end
	
	local function UpdateBankQualBtnVisual(bf, btn, q)
		if not btn or not btn.bg then return end
		local info = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]) or { r = 0.5, g = 0.5, b = 0.5 }
		local r, g, b = info.r or 0.5, info.g or 0.5, info.b or 0.5
		
		if q == 0 then r, g, b = 0.58, 0.58, 0.58
		elseif q == 1 then r, g, b = 0.96, 0.96, 0.96
		end
		local alpha = 0.35
		if bf.bankRarityFilter == q then
			r = math.min(1, r * 2.2)
			g = math.min(1, g * 2.2)
			b = math.min(1, b * 2.2)
			alpha = 0.95
		end
		
		
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
			
			local isSelectedFilter = (bf.bankRarityFilter == q)
			local fillAlpha = isSelectedFilter and 0.95 or 0.72
			if isSelectedFilter then
				br = math.min(1, br * 1.5)
				bg = math.min(1, bg * 1.5)
				bb = math.min(1, bb * 1.5)
			end
			
			btn.bg:ClearAllPoints()
			btn.bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
			btn.bg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
			btn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
			btn.bg:SetVertexColor(br, bg, bb, fillAlpha)
			Skins.AddRarityBorder(btn, bf._originalMainBorder, bf._originalEdgeFile, bf._originalEdgeSize)
			if btn.hl then btn.hl:SetVertexColor(1, 1, 1, 0.12) end
		else
			
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

			
			if shift and button == "RightButton" then
				Addon.RarityMoveJob = { mode = "bank_to_bags", rarity = self.quality }
				if Addon.RarityMoveWorker then
					Addon.RarityMoveWorker._t = 0
					Addon.RarityMoveWorker:Show()
				end
				return
			end

			
			if button == "LeftButton" and not ctrl and not alt then
				if f.bankRarityFilter == self.quality then
					f.bankRarityFilter = nil
					f.gphFilterQuality = nil
				else
					f.bankRarityFilter = self.quality
					f.gphFilterQuality = self.quality
				end
				
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
			if self.quality == 0 then r, g, b = 0.65, 0.65, 0.65
			elseif self.quality == 1 then r, g, b = 1, 1, 1
			end
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
		local br, bg_, bb = info.r or 0.5, info.g or 0.5, info.b or 0.5
		if q == 0 then br, bg_, bb = 0.58, 0.58, 0.58 elseif q == 1 then br, bg_, bb = 0.96, 0.96, 0.96 end
		bg:SetVertexColor(br, bg_, bb, 0.35)
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

	
	f.LayoutBankQualityButtons = function(self)
		local leftPad2, bagW2, bagGap2, spacing2, numBtns = 0, 36, 12, 4, 5
		local frameW = self:GetWidth() or 340
		
		
		
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

	
	f.bankScrollOffset = 0
	local scroll = CreateFrame("ScrollFrame", "TestBankScrollFrame", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", bankHeader, "BOTTOMLEFT", 0, -14) 
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




--- Bank row: mouse down (drag start).
local function BankRow_clickArea_OnMouseDown(self, mouseButton)
    local row = self:GetParent()
    if Addon.TriggerRowPulse then Addon.TriggerRowPulse(row) end
    local r = self:GetParent()
    if not r.bagID or not r.slotID then return end
    -- Store row/scroll so after move (bank->bags) refresh keeps list under cursor like bags do.
    local bf = _G.TestBankFrame
    if bf and bf:IsShown() and r.entryIndex and r._bankRowY then
        bf._bankLastClickedIndex = r.entryIndex
        bf._bankLastClickedRowY = r._bankRowY
        bf._bankScrollOffsetAtClick = bf.bankScrollOffset or 0
    end
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
--- Bank row: click (pickup, swap, modifier actions).
local function BankRow_clickArea_OnClick(self, button)
    if Addon.PlayClickSound then Addon.PlayClickSound() end
    local r = self:GetParent()
    if not r.bagID or not r.slotID then return end
    local Addon = _G.TestAddon

    
    if button == "LeftButton" and (IsAltKeyDown and IsAltKeyDown()) then
        local link = GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
        if link and Addon then
            local itemId = tonumber(link:match("item:(%d+)"))
            if itemId then
                local _, _, q = GetItemInfo(link)
                q = q or 0
                local protNow = Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(itemId, q) or false
                local SV = _G.FugaziBAGSDB or {}
                SV._manualUnprotected = SV._manualUnprotected or {}
                local set = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
                local prevOnly = Addon.GetGphPreviouslyWornOnlySet and Addon.GetGphPreviouslyWornOnlySet() or {}
                set[itemId] = nil
                prevOnly[itemId] = nil
                if SV.gphPreviouslyWornItemIds then SV.gphPreviouslyWornItemIds[itemId] = nil end
                if protNow then SV._manualUnprotected[itemId] = true
                else SV._manualUnprotected[itemId] = nil; set[itemId] = true end
            end
        end
        local gf = gphFrame or _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
        if gf then gf._refreshImmediate = true end
        if RefreshGPHUI then RefreshGPHUI() end
        if _G.FugaziBAGS_ScheduleRefreshBankUI then _G.FugaziBAGS_ScheduleRefreshBankUI() end
        return
    end

    
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
            local bf = _G.TestBankFrame
            if bf and bf:IsShown() and r.entryIndex and r._bankRowY then
                bf._bankLastClickedIndex = r.entryIndex
                bf._bankLastClickedRowY = r._bankRowY
                bf._bankScrollOffsetAtClick = bf.bankScrollOffset or 0
            end
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
    end
end
--- Bank row: accept item drag.
local function BankRow_clickArea_OnReceiveDrag(self)
    local r = self:GetParent()
    if GetCursorInfo and GetCursorInfo() == "item" and PickupContainerItem and r.bagID and r.slotID then
        PickupContainerItem(r.bagID, r.slotID)
    end
end
--- Bank row: mouse up (drop).
local function BankRow_clickArea_OnMouseUp(self, button)
    if button ~= "LeftButton" then return end
    if IsAltKeyDown and IsAltKeyDown() then return end
    local r = self:GetParent()
    if not r.bagID or not r.slotID or not PickupContainerItem then return end
    if GetCursorInfo and GetCursorInfo() == "item" then
        PickupContainerItem(r.bagID, r.slotID)
    end
end
--- Bank row: tooltip + secure button on enter.
local function BankRow_clickArea_OnEnter(self)
    local r = self:GetParent()
    
    if r.bagID and _G.TestBankFrame and _G.TestBankFrame:IsShown() and r.clickArea and r.clickArea._fugaziModifierOverlay and IsAltKeyDown and IsAltKeyDown() then
        local modOv = r.clickArea._fugaziModifierOverlay
        modOv:Show()
        modOv:EnableMouse(true)
    end
			local b, s = r.bagID, r.slotID
			local link = b and s and GetContainerItemLink and GetContainerItemLink(b, s)
			
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
--- Bank row: hide tooltip on leave.
local function BankRow_clickArea_OnLeave(self)
    GameTooltip:Hide()
end
--- Bank row: mouse wheel scrolls bank list.
local function BankRow_clickArea_OnMouseWheel(self,  delta)
    if _G.TestBankFrame and _G.TestBankFrame.scrollFrame and _G.TestBankFrame.scrollFrame.BankOnMouseWheel then
        _G.TestBankFrame.scrollFrame.BankOnMouseWheel(delta)
    end
end




--- Fill one list row: icon, name, count, rarity, vendor/AH value (inv or bank).
local function FillListRowVisuals(row, item, opts)
	opts = opts or {}
	local isBank = opts.isBank
	local destroyList = opts.destroyList or {}
	local nameRight = opts.nameRightMargin or -2
	local rowItemId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
	local isOnDestroyList = not isBank and rowItemId and destroyList[rowItemId]
	local hearthId = 6948
	local isHearth = (rowItemId == hearthId or (item.link and item.link:match("item:6948")))
	local hideIcons = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphHideIconsInList
	if hideIcons then
		if row.icon then row.icon:Hide() end
		if row.prevWornIcon then row.prevWornIcon:Hide() end
	else
		if row.icon then
			local tex = (Addon and Addon.GetSafeItemTexture) and Addon.GetSafeItemTexture(item.link or item.itemId, item.texture) or item.texture or "Interface\\Icons\\INV_Misc_QuestionMark"
			row.icon:SetTexture(tex)
			row.icon:Show()
			if isOnDestroyList then
				if row.icon.SetDesaturated then row.icon:SetDesaturated(true) end
				row.icon:SetVertexColor(0.55, 0.55, 0.55)
			elseif isHearth then
				if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
				row.icon:SetVertexColor(1, 1, 1)
			elseif item.isProtected then
				if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
				row.icon:SetVertexColor(0.65, 0.65, 0.65)
			else
				if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
				row.icon:SetVertexColor(1, 1, 1)
			end
		end
	end
	local qual = (item.quality and item.quality >= 0 and item.quality <= 7) and item.quality or 0
	local qInfo = (Addon and Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[qual]) or (Addon and Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[1]) or { r = 0.8, g = 0.8, b = 0.8, hex = "cccccc" }
	local leftOfName = row.icon
	local gap = 4
	if not hideIcons and not isBank and row.prevWornIcon then
		if item.previouslyWorn then
			row.prevWornIcon:SetTexture("Interface\\Icons\\INV_Shield_06")
			row.prevWornIcon:ClearAllPoints()
			row.prevWornIcon:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
			if isOnDestroyList then
				row.prevWornIcon:SetVertexColor(0.55, 0.55, 0.55)
			elseif item.isProtected then
				row.prevWornIcon:SetVertexColor(0.65, 0.65, 0.65)
			else
				row.prevWornIcon:SetVertexColor(1, 1, 1)
			end
			row.prevWornIcon:Show()
			leftOfName = row.prevWornIcon
			gap = 2
		else
			row.prevWornIcon:Hide()
		end
	end
	if row.nameFs then
		row.nameFs:ClearAllPoints()
		if hideIcons and row.clickArea then
			row.nameFs:SetPoint("LEFT", row.clickArea, "LEFT", 4, 0)
		else
			row.nameFs:SetPoint("LEFT", leftOfName, "RIGHT", gap, 0)
		end
		row.nameFs:SetPoint("RIGHT", row.clickArea, "RIGHT", nameRight, 0)
	end
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
		nameHex = qInfo.hex or "cccccc"
	end
	local plainName = item.name or "Unknown"
	row._plainName = plainName
	row._nameHex = nameHex
	if row.nameFs then
		row.nameFs:SetText("|cff" .. (nameHex or "cccccc") .. plainName .. "|r")
		row._normalNameText = row.nameFs:GetText()
	end
	if row.countFs then row.countFs:SetText((item.count and item.count > 1) and ("|cffaaaaaa x" .. item.count .. "|r") or "") end
	
	if row.protectedOverlay then
		if isBank then
			if item.isProtected or item.previouslyWorn then
				row.protectedOverlay:Show()
			else
				row.protectedOverlay:Hide()
			end
			if row.protectedKeyIcon then row.protectedKeyIcon:Hide() end
		else
			local capturedId = rowItemId
			local protectedSet = (Addon and Addon.GetGphProtectedSet) and Addon.GetGphProtectedSet() or {}
			local isManuallyProtected = (item.itemId and protectedSet[item.itemId]) or (capturedId and protectedSet[capturedId])
			local isPrevWorn = item.previouslyWorn
			local pendingDim = false
			if Addon and Addon.gphPendingAltUnprotect and capturedId then
				local t = Addon.gphPendingAltUnprotect[capturedId]
				if t then
					local now = (GetTime and GetTime()) or time()
					if (now - t) < 3 then pendingDim = true
					else Addon.gphPendingAltUnprotect[capturedId] = nil end
				end
			end
			if (item.isProtected and not isHearth) or isManuallyProtected then
				row.protectedOverlay:Show()
				row.protectedOverlay:SetAlpha(pendingDim and 0.45 or 0.85)
				if row.protectedKeyIcon then
					if isPrevWorn then
						row.protectedKeyIcon:Hide()
					else
						row.protectedKeyIcon:Show()
						local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
						if atVendor then
							row.protectedKeyIcon:SetAlpha(0.75)
							if row.protectedKeyIcon.SetDesaturated then row.protectedKeyIcon:SetDesaturated(0) end
						else
							local SV = _G.FugaziBAGSDB
							row.protectedKeyIcon:SetAlpha((SV and SV.gridProtectedKeyAlpha) or 0.2)
							if row.protectedKeyIcon.SetDesaturated then row.protectedKeyIcon:SetDesaturated(1) end
						end
					end
				end
			else
				row.protectedOverlay:Hide()
				if row.protectedKeyIcon then row.protectedKeyIcon:Hide() end
			end
		end
	end
end

RefreshBankUI = function()
	local bf = _G.TestBankFrame
	if not bf then return end
	if not bf:IsShown() then return end
    
    local inv = _G.TestGPHFrame
    if inv and inv.NegotiateSizes then inv:NegotiateSizes() end
	
	if bf.LayoutBankQualityButtons then bf:LayoutBankQualityButtons() end
	
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

	ResetBankRowPool()
    ResetBankDataPools()
	
	local bankListW = BANK_LIST_WIDTH
	if bf.scrollFrame then
		local sw = bf.scrollFrame:GetWidth()
		if sw and sw > 50 then bankListW = sw - 4 end  
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
			
			if type(t2) == "number" and t2 > 0 then stackCount = t2
			elseif type(t3) == "number" and t3 > 0 then stackCount = t3
			elseif type(t4) == "number" and t4 > 0 then stackCount = t4
			elseif type(t5) == "number" and t5 > 0 then stackCount = t5
			end
		end
		
		if link and (stackCount == 0 or not stackCount) then
			
			
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

        
		local isProtected = itemId and RarityIsProtected(itemId, quality)

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
        
        local isProtected = agg.itemId and RarityIsProtected(agg.itemId, agg.quality)
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
	
	
	
	for q = 0, 4 do qCounts[q] = 0 end
	for _, agg in pairs(aggregated) do
		local q = (agg.quality and agg.quality >= 0 and agg.quality <= 7) and agg.quality or 0
		local btnQ = (q >= 5 and q <= 7) and 4 or q
		qCounts[btnQ] = (qCounts[btnQ] or 0) + (agg.totalCount or 0)
	end
	if bf.bankSpaceFs then bf.bankSpaceFs:SetText(usedBankSlots .. "/" .. totalBankSlots) end
	bf._bankUsedSlots = usedBankSlots
	if ApplyCustomizeToFrame then ApplyCustomizeToFrame(bf) end
	
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
	
	local inv = _G.TestGPHFrame
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
				if not itemMatches and Addon.ItemMatchesSearch and item.link and searchLower then
					itemMatches = Addon.ItemMatchesSearch(item.link, item.bagID, item.slotID, searchLower)
				end
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
	
	local yOff = 0
	local listToUse = (sortMode == "category" and bankCategoryDrawList) or slotList
	local bankDividerIndex = 0
	bf.bankItemIndexToY = bf.bankItemIndexToY or {}
	wipe(bf.bankItemIndexToY)
	if bf.bankCategoryDividerPool then for _, d in ipairs(bf.bankCategoryDividerPool) do d:Hide() end end
	for idx, entry in ipairs(listToUse) do
		if entry.divider and entry.divider ~= "HIDDEN_FIRST" then
			
			bankDividerIndex = bankDividerIndex + 1
			if not bf.bankCategoryDividerPool then bf.bankCategoryDividerPool = {} end
			local pool = bf.bankCategoryDividerPool
			local div = pool[bankDividerIndex]
			if not div then
				
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
			yOff = yOff + 4  
			div:SetParent(content)
			div:ClearAllPoints()
			div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
			div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
			div:SetHeight(16)  
			
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
			
			if div.toggleBtn then
				if div.toggleBtn.text then
					
					div.toggleBtn.text:SetText("")
				end
				if div.toggleBtn.icon then
                    local r, g, b = 1, 1, 1
                    if useHeaderColor then
                        r, g, b = headerColor[1], headerColor[2], headerColor[3]
                    end
                    
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
			yOff = yOff + 16 + 4  
		elseif entry.divider and entry.divider == "HIDDEN_FIRST" then
			
			yOff = yOff + 0
		else
			local row = GetBankRow(content)
			if firstRow == nil then firstRow = row end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
			row.entryIndex = idx
			row._bankRowY = yOff
			bf.bankItemIndexToY[idx] = yOff
			local info = entry
			local bagID, slotID = info.bagID, info.slotID

			if not info.isProtected and bf.bankDefaultScrollY == nil then
				bf.bankDefaultScrollY = yOff
			end

			
			
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
				row.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
				row.nameFs:ClearAllPoints()
				row.nameFs:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
				row.nameFs:SetPoint("RIGHT", row.clickArea, "RIGHT", -40, 0)
			end
			if not hideIconsBank then
				if info.isProtected then
					if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
					row.icon:SetVertexColor(0.65, 0.65, 0.65)
				else
					if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
					row.icon:SetVertexColor(1, 1, 1)
				end
			end
			local QUALITY_COLORS = Addon and Addon.QUALITY_COLORS or {}
			local qInfo = QUALITY_COLORS[quality] or { r = 0.8, g = 0.8, b = 0.8, hex = "cccccc" }
			if info.isProtected then
				local mix, grey = 0.28, 0.48
				local r = (qInfo.r or 0.5) * mix + grey * (1 - mix)
				local g = (qInfo.g or 0.5) * mix + grey * (1 - mix)
				local b = (qInfo.b or 0.5) * mix + grey * (1 - mix)
				row.nameFs:SetText("|cff" .. string.format("%02x%02x%02x", math.floor(math.max(0, math.min(1, r)) * 255), math.floor(math.max(0, math.min(1, g)) * 255), math.floor(math.max(0, math.min(1, b)) * 255)) .. (name or "Unknown") .. "|r")
			else
				row.nameFs:SetText("|cff" .. (qInfo.hex or "cccccc") .. (name or "Unknown") .. "|r")
			end
			if info.isProtected or info.previouslyWorn then
				if row.protectedOverlay then row.protectedOverlay:Show() end
			else
				if row.protectedOverlay then row.protectedOverlay:Hide() end
			end
			row.countFs:SetText((count and count > 1) and ("|cffaaaaaa x" .. tostring(count) .. "|r") or "")
			row.totalCount = count
			if ApplyItemDetailsToRow then ApplyItemDetailsToRow(row, { name = name, quality = quality, isProtected = info.isProtected }) end

		
		
		if row.clickArea and bagID ~= nil and slotID ~= nil and _G.FugaziBAGS_EnsureSecureRowBtn then
			_G.FugaziBAGS_EnsureSecureRowBtn(row.clickArea, bagID, slotID)
		end
	end
end

	content:SetHeight(math.max(yOff, 1))
	
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
		
		
		if not bf._bankLastClickedIndex and bf.gphScrollToDefaultOnNextRefresh then
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
		
		if bf._bankLastClickedIndex and bf.bankItemIndexToY then
			local oldRowY = bf._bankLastClickedRowY
			local oldScroll = bf._bankScrollOffsetAtClick or 0
			local nextIdx = bf._bankLastClickedIndex
			local maxIdx = 0
			for i in pairs(bf.bankItemIndexToY) do if i > maxIdx then maxIdx = i end end
			if nextIdx > maxIdx and maxIdx > 0 then nextIdx = maxIdx end
			local newRowY = bf.bankItemIndexToY[nextIdx]
			if oldRowY and newRowY then
				local wantScroll = newRowY - oldRowY + oldScroll
				offset = math.max(0, math.min(maxScroll, wantScroll))
			end
			bf._bankLastClickedIndex = nil
			bf._bankLastClickedRowY = nil
			bf._bankScrollOffsetAtClick = nil
		end

		offset = math.min(offset, maxScroll)
		bf.bankScrollOffset = offset
		scrollBar:SetValue(offset)
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, offset)
		BankDebug("Step 8: viewH=" .. tostring(viewH) .. " maxScroll=" .. tostring(maxScroll) .. " offset=" .. tostring(offset))
	end

	
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


--- Schedule bank UI refresh next frame (after bag update).
function FugaziBAGS_ScheduleRefreshBankUI()
	local f = CreateFrame("Frame")
	f:SetScript("OnUpdate", function(self)
		self:SetScript("OnUpdate", nil)
		local bf = _G.TestBankFrame
		
		if not bf or not bf:IsShown() then return end
		if RefreshBankUI then RefreshBankUI() end
		
		if bf.gphGridMode and _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.BankRefreshSlots then
			_G.FugaziBAGS_CombatGrid.BankRefreshSlots()
		end
	end)
end

--- Inventory row: accept item drag onto slot.
local function GPHBtn_clickArea_OnReceiveDrag(self)
    local btn = self:GetParent()
    local item = btn.cachedItem
    if not item then return end
    if item.bag ~= nil and item.slot ~= nil and PickupContainerItem then
        PickupContainerItem(item.bag, item.slot)
        
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
--- Inventory row: mouse wheel scrolls list.
local function GPHBtn_clickArea_OnMouseWheel(self, delta)
    local btn = self:GetParent()
    local item, capturedId, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedItemIdx
    if not item then return end
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
end
--- Inventory row: tooltip, highlight, secure button.
local function GPHBtn_clickArea_OnEnter(self)
    local btn = self:GetParent()
    local item = btn.cachedItem
    if not item or not item.link then return end
    Addon.AnchorTooltipRight(self)
    if item.bag ~= nil and item.slot ~= nil and GameTooltip.SetBagItem then
        GameTooltip:SetBagItem(item.bag, item.slot)
    else
        local lp = item.link:match("|H(item:[^|]+)|h")
        if lp then GameTooltip:SetHyperlink(lp) end
    end

    
    if item.isDestroy then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click: Remove from list", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        return
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
--- Inventory row: hide tooltip on leave.
local function GPHBtn_clickArea_OnLeave(self)
    GameTooltip:Hide()
end
--- Inventory row: left/right click (use, sell, protect, destroy).
local function GPHBtn_clickArea_OnClick(self, button)
    if Addon.PlayClickSound then Addon.PlayClickSound() end
    local btn = self:GetParent()
    local item, capturedId, itemIdx = btn.cachedItem, btn.cachedItemId, btn.cachedItemIdx
    if not item then return end
    
    if item.isDestroy then
        if button == "RightButton" and capturedId then
            local list = Addon.GetGphDestroyList and Addon.GetGphDestroyList()
            if list then list[capturedId] = nil end
            if gphFrame then gphFrame._refreshImmediate = true end
            if RefreshGPHUI then RefreshGPHUI() end
        end
        return
    end
    if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
    
    if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
    
    if button == "RightButton" and IsShiftKeyDown() and item.link then
        local chatBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if chatBox and chatBox.Insert then
            chatBox:Insert(item.link)
            if chatBox.SetFocus then chatBox:SetFocus() end
        end
        if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
        return
    end
    
    
    
    
    if button == "RightButton" and not IsShiftKeyDown() then
        DebugClick(string.format(
            "CLICKAREA RMB bag=%s slot=%s combat=%s",
            tostring(item.bag), tostring(item.slot),
            tostring(InCombatLockdown and InCombatLockdown() or false)
        ))
        
        
        local inCombat = InCombatLockdown and InCombatLockdown()
        if not inCombat and item.bag ~= nil and item.slot ~= nil and _G.FugaziBAGS_EnsureSecureRowBtn then
            _G.FugaziBAGS_EnsureSecureRowBtn(self, item.bag, item.slot)
        end
        return
    end
    
    if IsControlKeyDown() and button == "LeftButton" then
        return
    end
                
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

--- Inventory row: mouse down (drag start, modifier overlay).
local function GPHBtn_clickArea_OnMouseDown(self,  mouseButton)
    if Addon.TriggerRowPulse then Addon.TriggerRowPulse(self:GetParent()) end
    local btn = self:GetParent()
    local item, capturedId = btn.cachedItem, btn.cachedItemId
    if not item then return end
    if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
    if (mouseButton ~= "LeftButton" and mouseButton ~= "RightButton") or not gphFrame then return end
    if IsControlKeyDown() then return end  
    
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


--- Show item cooldown spiral on row (like bag slot cooldown).
local function GPH_CheckRowCooldown(btn, item, idToSlot)
    if not btn or not btn.cooldownOverlay then return false end
    local capturedId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
    local onCooldown = false
    local frac = nil

    if item.bag ~= nil and item.slot ~= nil and GetContainerItemCooldown then
        local cStart, cDur = GetContainerItemCooldown(item.bag, item.slot)
        if cDur and cDur > 0 then
            local now = GetTime()
            local ends = (cStart or 0) + cDur
            onCooldown = ends > now
            if onCooldown then
                local remain = math.max(0, ends - now)
                frac = math.min(1, math.max(0, remain / cDur))
            end
        end
    else
        onCooldown = Addon.ItemIdHasCooldown(capturedId, idToSlot)
    end

    if onCooldown then
        
        local r, g, b, a = 0.75, 0.85, 1.0, 0.2
        local SV = _G.FugaziBAGSDB
        local hc = SV and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor
        if hc and #hc >= 3 then
            r, g, b = hc[1], hc[2], hc[3]
            a = (hc[4] or 0.7) * 0.4
        elseif btn:GetParent() and btn:GetParent().gphAccentTextColor then
            local c = btn:GetParent().gphAccentTextColor
            r, g, b = c[1] or r, c[2] or g, c[3] or b
        end
        btn.cooldownOverlay:SetVertexColor(r, g, b, a)

        local ca = btn.clickArea or btn
        local rowW = ca:GetWidth() or 0
        btn.cooldownOverlay:ClearAllPoints()
        btn.cooldownOverlay:SetPoint("TOPLEFT", ca, "TOPLEFT", 0, 0)
        btn.cooldownOverlay:SetPoint("BOTTOMLEFT", ca, "BOTTOMLEFT", 0, 0)

        if frac and rowW and rowW > 4 then
            btn.cooldownOverlay:SetWidth(rowW * frac)
        else
            btn.cooldownOverlay:SetWidth(rowW > 0 and rowW or 0.01)
        end

        btn.cooldownOverlay:Show()
    else
        btn.cooldownOverlay:Hide()
    end
    return onCooldown
end


--- Row cooldown tick (update spiral).
local function GPHRow_OnUpdateCooldown(self, elapsed)
    self._cdTimer = (self._cdTimer or 0) + elapsed
    if self.cachedItem and self._cdTimer > 0.25 then
        self._cdTimer = 0
        local map = Addon._gphIdToSlotTempCached
        if not GPH_CheckRowCooldown(self, self.cachedItem, map) then
            self:SetScript("OnUpdate", nil)
        end
    end
end


--- Update one inventory row: icon, count, name, cooldown, protected/destroy state.
local function UpdateGPHRowVisuals(btn, item, itemIdx, yOff, rowBelowDivider, destroyList, gphFrame, idToSlot)
    local dynW = gphFrame.gphDynContentWidth
    if dynW and dynW > 50 then btn:SetWidth(dynW - 8) end
    btn:SetPoint("TOPLEFT", btn:GetParent(), "TOPLEFT", 4, -yOff)

    
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
    FillListRowVisuals(btn, item, { destroyList = destroyList })

    if ApplyItemDetailsToRow then ApplyItemDetailsToRow(btn, item) end

    local capturedId = rowItemId

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

    btn.cachedItem = item
    btn.cachedItemId = capturedId
    btn.cachedItemIdx = itemIdx

    if not btn._scriptsBound then
        btn._scriptsBound = true
        
        btn.clickArea:RegisterForDrag("LeftButton")
        btn.clickArea:SetScript("OnReceiveDrag", GPHBtn_clickArea_OnReceiveDrag)
        btn.clickArea:SetScript("OnMouseWheel", GPHBtn_clickArea_OnMouseWheel)
        btn.clickArea:SetScript("OnClick", GPHBtn_clickArea_OnClick)
        btn.clickArea:SetScript("OnMouseDown", GPHBtn_clickArea_OnMouseDown)
        btn.clickArea:SetScript("OnEnter", GPHBtn_clickArea_OnEnter)
        btn.clickArea:SetScript("OnLeave", GPHBtn_clickArea_OnLeave)
    end

    
    
    if item.isDestroy or item.bag == nil or item.slot == nil then
        btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    else
        
        
        btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end

    if item.bag ~= nil and item.slot ~= nil and _G.FugaziBAGS_EnsureSecureRowBtn then
        _G.FugaziBAGS_EnsureSecureRowBtn(btn.clickArea, item.bag, item.slot)
    end
    
    if item.isDestroy or item.bag == nil or item.slot == nil then
        local par = btn.clickArea and btn.clickArea._fugaziSecPar
        if par then par:Hide() end
    end
    
    local overlay = btn.clickArea and btn.clickArea._fugaziVendorProtectOverlay
    if overlay then
        local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
        
        local protected = item.isProtected and true or false
        if capturedId and item.quality ~= nil then
            
            local Addon = _G.TestAddon
            if Addon and Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(capturedId, item.quality) then
                protected = true
            elseif RarityIsProtected(capturedId, item.quality) then
                protected = true
            end
        end
        if atVendor and protected then overlay:Show() else overlay:Hide() end
    end
    
    local modOv = btn.clickArea and btn.clickArea._fugaziModifierOverlay
    if modOv then
        local altDown = IsAltKeyDown and IsAltKeyDown()
        local ctrlDown = IsControlKeyDown and IsControlKeyDown()
        if altDown or ctrlDown then
            modOv:Show()
            modOv:EnableMouse(true)
        else
            modOv:Hide()
            modOv:EnableMouse(false)
        end
    end
end

RefreshGPHUI = function()
    if not gphFrame then gphFrame = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame end
    if not gphFrame then return end
    local gphSession = _G.gphSession
    
    local now = GetTime and GetTime() or time()
    local skipDebounce = gphFrame._refreshImmediate
    if skipDebounce then gphFrame._refreshImmediate = nil end
    if not skipDebounce and gphFrame._lastRefreshGPHUI and (now - gphFrame._lastRefreshGPHUI) < 0.25 then
        return
    end
    gphFrame._lastRefreshGPHUI = now
    
    local inCombat = InCombatLockdown and InCombatLockdown()
    if not inCombat then
        if gphFrame.NegotiateSizes then gphFrame:NegotiateSizes() end
    end
    
    if gphFrame.gphGridMode and _G.FugaziBAGS_CombatGrid and _G.FugaziBAGS_CombatGrid.RefreshSlots then
        _G.FugaziBAGS_CombatGrid.RefreshSlots()
    end
    
    if gphFrame.gphTitle then ApplyGphInventoryTitle(gphFrame.gphTitle) end
    if not inCombat then
        if gphFrame.UpdateGphTitleBarButtonLayout then gphFrame:UpdateGphTitleBarButtonLayout() end
        if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
        if gphFrame.UpdateGPHButtonVisibility then gphFrame:UpdateGPHButtonVisibility() end
    end
    if ApplyGPHFrameSkin then ApplyGPHFrameSkin(gphFrame) end
    if ApplyCustomizeToFrame then ApplyCustomizeToFrame(gphFrame) end
    if _G.UpdateSortIcon then _G.UpdateSortIcon() end
    
    if not gphFrame.gphGridMode then
        local poolOk, poolErr = pcall(Addon.ResetGPHPools)
        if not poolOk then
            Addon.AddonPrint("[Fugazi] GPH ResetGPHPools error: " .. tostring(poolErr))
            return
        end
    end
    
    Addon.ResetGPHDataPools()

    

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
    local nowGph = GetTime and GetTime() or time()  

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
        
        local dur = now - gphSession.startTime
        local liveGold = GetMoney() - gphSession.startGold
        if liveGold < 0 then liveGold = 0 end
        local totalValue = ComputeGPHTotalValue(gphSession, liveGold)
        local gph = dur > 0 and (totalValue / (dur / 3600)) or 0
        gphFrame.statusText:Show()
        local fullText = "|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold)
            .. "   |cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r"
            .. "   |cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph))
        if gphFrame.SetGphStatusTextFitted then
            gphFrame:SetGphStatusTextFitted(fullText)
        else
            gphFrame.statusText:SetText(fullText)
        end
        if gphFrame.gphSearchEditBox and gphFrame.gphSearchEditBox:IsShown() then
            gphFrame.gphSearchEditBox:SetPoint("RIGHT", gphFrame, "TOPRIGHT", -8, -38)
        end
    end

    
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

        local isProtected = Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(agg.itemId, agg.quality) or false
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
    
    
    
    

    local qualityButtons = (header and header.qualityButtons) or content.qualityButtons
    if not qualityButtons then
        if header then header.qualityButtons = {} else content.qualityButtons = {} end
        qualityButtons = header and header.qualityButtons or content.qualityButtons
    end

    
    local headerW = headerParent and headerParent:GetWidth() or content:GetWidth() or 300
    local rightEdgeGap = 4  
    local qualityRight = headerW - rightEdgeGap
    local leftPad = 0  
    local bagGap = 12  
    local spacing = 4  
    local numRarityBtns = 5
    local ROW_H = 18 
    local bagW, bagH = 36, 18

    
    local startX = leftPad + bagW + bagGap
    local rarityTotalW = qualityRight - startX
    local slotWidth = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
    if slotWidth < 10 then slotWidth = 10 end

    
    if gphFrame.gphBagSpaceBtn and gphFrame.gphBagSpaceBtn.fs then
        local bagText = usedSlots .. "/" .. totalSlots
        gphFrame.gphBagSpaceBtn.fs:SetText(bagText)
        
        local SV = _G.FugaziBAGSDB
        if SV and SV.gphCategoryHeaderFontCustom then
            local path = GetCategoryHeaderFontAndSize()
            gphFrame.gphBagSpaceBtn.fs:SetFont(path, 10, "")
        else
            gphFrame.gphBagSpaceBtn.fs:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
        end
        gphFrame.gphBagSpaceBtn:SetSize(bagW, bagH)
        gphFrame.gphBagSpaceBtn:ClearAllPoints()
        
        gphFrame.gphBagSpaceBtn:SetPoint("TOPLEFT", headerParent, "TOPLEFT", 0, headerY)
        
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
                                                
                                                local count = 1
                                                if GetContainerItemInfo then
                                                    local _, itemCount = GetContainerItemInfo(bag, slot)
                                                    if itemCount and itemCount > 0 then count = itemCount end
                                                end
                                                local vendorCopper = 0
                                                if GetItemInfo then
                                                    local sellPrice = select(11, GetItemInfo(link or itemId))
                                                    if sellPrice and sellPrice > 0 then
                                                        vendorCopper = sellPrice * count
                                                    end
                                                end

                                                PickupContainerItem(bag, slot)
                                                if CursorHasItem() then
                                                    if _G.gphSession then
                                                        _G.gphSession.itemsAutodeleted = (_G.gphSession.itemsAutodeleted or 0) + count
                                                        _G.gphSession.autodeletedItemCount = _G.gphSession.autodeletedItemCount or {}
                                                        _G.gphSession.autodeletedItemCount[itemId] = (_G.gphSession.autodeletedItemCount[itemId] or 0) + count
                                                    end
                                                    if _G.FugaziInstanceTracker_OnAutoDelete then
                                                        _G.FugaziInstanceTracker_OnAutoDelete(itemId, count, vendorCopper)
                                                    end
                                                    DeleteCursorItem()
                                                    deletedOne = true
                                                    break
                                                end
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

        
        
        local Skins = _G.__FugaziBAGS_Skins
        local useOriginalRarity = gphFrame and gphFrame._useOriginalRarityStyle and gphFrame._originalMainBorder and gphFrame._originalTitleBg and Skins and Skins.AddRarityBorder
        
        
        
        if useOriginalRarity and gphFrame.ApplySkin then
            local SVskin = _G.FugaziBAGSDB
            if not (SVskin and SVskin.gphCategoryHeaderFontCustom) then
                gphFrame:ApplySkin()
                
                useOriginalRarity = gphFrame and gphFrame._useOriginalRarityStyle and gphFrame._originalMainBorder and gphFrame._originalTitleBg and Skins and Skins.AddRarityBorder
            end
        end

        if qualBtn.rarityBorderTop then
            if useOriginalRarity then
                
                qualBtn.rarityBorderTop:Hide()
                qualBtn.rarityBorderBottom:Hide()
                qualBtn.rarityBorderLeft:Hide()
                qualBtn.rarityBorderRight:Hide()
            elseif rarityFlags and rarityFlags[q] then
                
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
        
        if q == 0 then r, g, b = 0.58, 0.58, 0.58
        elseif q == 1 then r, g, b = 0.96, 0.96, 0.96
        end
        local alpha = 0.35
        
        local delStage = Addon.gphRarityDelStage and Addon.gphRarityDelStage[q]
        if delStage and delStage.stage == 1 then
            
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
            
            r = (r + 0.5) * 0.5
            g = (g + 0.5) * 0.5
            b = (b + 0.5) * 0.5
            alpha = 0.22
        end
        
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
            
            
            local isBright = isSelectedFilter or isProtectedRarity
            local fillAlpha = isBright and 0.95 or 0.72
            if isBright then
                br = math.min(1, br * 1.5)
                bg = math.min(1, bg * 1.5)
                bb = math.min(1, bb * 1.5)
            end
            
            qualBtn.bg:ClearAllPoints()
            qualBtn.bg:SetPoint("TOPLEFT", qualBtn, "TOPLEFT", 1, -1)
            qualBtn.bg:SetPoint("BOTTOMRIGHT", qualBtn, "BOTTOMRIGHT", -1, 1)
            qualBtn.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            qualBtn.bg:SetVertexColor(br, bg, bb, fillAlpha)
            Skins.AddRarityBorder(qualBtn, gphFrame._originalMainBorder, gphFrame._originalEdgeFile, gphFrame._originalEdgeSize)
            if qualBtn.hl then qualBtn.hl:SetVertexColor(1, 1, 1, 0.12) end
        else
            
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
            
            local textHex = info.hex or "888888"
            if gphFrame and gphFrame.gphFilterQuality == q and not (delStage or Addon.gphPendingQuality[q]) then
                local ir, ig, ib = info.r or 0.5, info.g or 0.5, info.b or 0.5
                local lr = math.floor(math.min(1, ir * 0.35 + 0.82) * 255)
                local lg = math.floor(math.min(1, ig * 0.35 + 0.82) * 255)
                local lb = math.floor(math.min(1, ib * 0.35 + 0.82) * 255)
                textHex = ("%02x%02x%02x"):format(lr, lg, lb)
            end
            fs:SetText(labelText ~= "" and ("|cff" .. textHex .. labelText .. "|r") or "")
            
            local isHovered = (GetMouseFocus and GetMouseFocus() == qualBtn)
            fs:SetAlpha(isHovered and 1 or 0)
        end
        table.insert(header and header.headerElements or content.headerElements, qualBtn)
    end

    
    if gphFrame then
        gphFrame._gphQualityButtons = qualityButtons
        if not gphFrame._rarityGlowAnimator then
            local anim = CreateFrame("Frame", nil, gphFrame)
            anim:SetScript("OnUpdate", function(self)
                local parent = self:GetParent()
                if not parent or not parent:IsVisible() then return end
                local qb = parent._gphQualityButtons
                if not qb then return end
                local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}
                local t = GetTime()
                local pulseAlpha = 0.6 + 0.35 * math.sin(t * 1.5)
                for q = 0, 4 do
                    local btn = qb[q]
                    if not btn or not btn.bg then break end
                    if rarityFlags[q] then
                        local r, g, b, a = btn.bg:GetVertexColor()
                        btn.bg:SetVertexColor(r, g, b, pulseAlpha)
                    end
                end
            end)
            gphFrame._rarityGlowAnimator = anim
        end
    end

    if headerParent.LayoutGPHQualityButtons then
        headerParent:LayoutGPHQualityButtons()
    end

    if headerParent and not headerParent._fugaziLayoutHooked then
        headerParent._fugaziLayoutHooked = true
        headerParent.LayoutGPHQualityButtons = function(self)
            local qbTable = self.qualityButtons
            if not qbTable then return end
            
            local w = self:GetWidth() or 300
            local rw = w - 4 
            local sw = math.floor((rw - 48 - 16) / 5) 
            if sw < 8 then sw = 8 end
            for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
                local btn = qbTable[q]
                if btn then
                    btn:SetSize(sw, 14) 
                    btn:ClearAllPoints()
                    btn:SetPoint("LEFT", self, "LEFT", 48 + (i - 1) * (sw + 4), 0) 
                end
            end
        end
        headerParent:HookScript("OnSizeChanged", function() headerParent:LayoutGPHQualityButtons() end)
        headerParent:LayoutGPHQualityButtons()
    end

    
    

    
    if gphFrame.gphGridMode then return end

    local yOff = 0  
    local sortMode = DB.gphSortMode or "rarity"

    if sortMode == "vendor" then
        table.sort(itemList, GPH_Sort_Vendor)
    elseif sortMode == "itemlevel" then
        table.sort(itemList, GPH_Sort_ItemLevel)
    else
        table.sort(itemList, GPH_Sort_Rarity)
    end

    
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
            else
                
                local isProt = Addon.IsItemProtectedAPI and Addon.IsItemProtectedAPI(item.itemId, item.quality) or false
                if isProt then
                    item.isProtected = true
                    table.insert(aboveHearth, item)
                else
                    table.insert(rest, item)
                end
            end
        end
        wipe(Addon.gphItemList)
        itemList = Addon.gphItemList
        for _, item in ipairs(aboveHearth) do table.insert(itemList, item) end
        for _, item in ipairs(hearth) do table.insert(itemList, item) end
        for _, item in ipairs(rest) do table.insert(itemList, item) end
    end

    
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

    
    local searchLower = (gphFrame.gphSearchText and gphFrame.gphSearchText ~= "") and gphFrame.gphSearchText:lower():match("^%s*(.-)%s*$") or nil
    local exactQuality = nil
    if searchLower and searchLower ~= "" then
        for q = 0, 7 do
            local info = Addon.QUALITY_COLORS[q]
            if info and info.label and info.label:lower() == searchLower then
                exactQuality = q
                break
            end
        end
    end

    
    if searchLower and searchLower ~= "" then
        if not Addon._gphSearchPool then Addon._gphSearchPool = {} end
        wipe(Addon._gphSearchPool)
        local filtered = Addon._gphSearchPool
        for _, item in ipairs(itemList) do
            if exactQuality ~= nil then
                if item.quality == exactQuality then table.insert(filtered, item) end
            else
                local itemMatches = (item.name and item.name:lower():find(searchLower, 1, true))
                if not itemMatches and Addon.ItemMatchesSearch and item.link and searchLower then
                    itemMatches = Addon.ItemMatchesSearch(item.link, item.bag, item.slot, searchLower)
                end
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

    
    local destroyList = Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
    for did in pairs(destroyList) do
        if did ~= 6948 then 
            local inList = false
            for _, it in ipairs(itemList) do
                if it.itemId == did then inList = true; break end
            end
            if not inList then
                local info = destroyList[did]
                local storedName = type(info) == "table" and info.name
                local storedTex = type(info) == "table" and info.texture
                
                if info == true and GetItemInfo then
                    local n = GetItemInfo(did)
                    local t = n and select(10, GetItemInfo(did))
                    if n or t then
                        destroyList[did] = { name = n, texture = t, addedTime = time() }
                        storedName, storedTex = n, t
                    end
                end
                local name = storedName or (GetItemInfo and GetItemInfo(did)) or ("Item " .. tostring(did))
                
                local addDestroyEntry = true
                if searchLower and searchLower ~= "" then
                    local nameMatch = name and name:lower():find(searchLower, 1, true)
                    if not nameMatch and Addon.ItemMatchesSearch then
                        local link = "item:" .. tostring(did)
                        nameMatch = Addon.ItemMatchesSearch(link, nil, nil, searchLower)
                    end
                    local qq = (GetItemInfo and select(3, GetItemInfo(did))) or 0
                    local qualityMatch = (exactQuality ~= nil and qq == exactQuality)
                    if not nameMatch and not qualityMatch then addDestroyEntry = false end
                end
                if addDestroyEntry then
                    local previouslyWornOnlySet = Addon.GetGphPreviouslyWornOnlySet()
                    local _, _, q = GetItemInfo and GetItemInfo(did)
                    q = q or 0
                    
                    local isProtected = RarityIsProtected and RarityIsProtected(did, q)
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
        end
    end
    
    
    local normal = Addon._gphNormalPool
    local destroyed = Addon._gphDestroyedPool
    wipe(normal); wipe(destroyed)
    for _, item in ipairs(itemList) do
        if item.itemId and item.itemId ~= 6948 and destroyList[item.itemId] then
            item.isDestroy = true
            local info = destroyList[item.itemId]
            item.addedTime = (type(info) == "table" and info.addedTime) or 0
            table.insert(destroyed, item)
        else
            table.insert(normal, item)
        end
    end
    
    table.sort(destroyed, function(a, b)
        local atA = a.addedTime or 0
        local atB = b.addedTime or 0
        if atA ~= atB then return atA > atB end
        return (a.name or "") < (b.name or "")
    end)
    wipe(itemList)
    for _, item in ipairs(normal) do table.insert(itemList, item) end
    for _, item in ipairs(destroyed) do table.insert(itemList, item) end

    
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
        
        local needsAsyncRefresh = false
        for _, item in ipairs(itemList) do if item.itemType == "UNKNOWN" then needsAsyncRefresh = true; break end end
        if needsAsyncRefresh and not (Addon.gphCategoryRefreshFrame and Addon.gphCategoryRefreshFrame._categoryScheduled) then
            if not Addon.gphCategoryRefreshFrame then Addon.gphCategoryRefreshFrame = CreateFrame("Frame") end
            local cf = Addon.gphCategoryRefreshFrame
            cf._categoryScheduled = true
            cf._categoryAccum = 0
            cf:SetScript("OnUpdate", function(self, elapsed)
                self._categoryAccum = (self._categoryAccum or 0) + elapsed
                if self._categoryAccum >= 2.0 then 
                    self:SetScript("OnUpdate", nil)
                    self._categoryScheduled = nil
                    
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
        
        
        gphFrame._gphPrevDefaultScrollY = gphFrame.gphDefaultScrollY
        gphFrame.gphDefaultScrollY = nil  
        local selectedStillExists = false
        local selectedRowBtn = nil  
        local hadSelectedItemId = gphFrame and gphFrame.gphSelectedItemId ~= nil
        local itemIdToSlot = Addon.GetItemIdToBagSlot()
        Addon._gphIdToSlotTempCached = itemIdToSlot 
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
                yOff = yOff + 4  
                div:SetParent(content)
                div:ClearAllPoints()
                div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
                div:SetHeight(16)  
                if div.tex then
                    if isDelete then div.tex:SetTexture(0.32, 0.14, 0.14, 0.65) else div.tex:SetTexture(0.1, 0.3, 0.15, 0.7) end
                end
                
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
                
                if div.toggleBtn then
                    if div.toggleBtn.text then
                        
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
                yOff = yOff + 16 + 4  
            elseif entry.divider and (entry.divider == "HIDDEN_FIRST" or entry.divider == "BAG_PROTECTED") then
                
            else
                itemIdx = (gphFrame.gphCategoryDrawList and (itemIdx + 1)) or idx
                local item = entry
                if gphFrame then
                    gphFrame.gphItemIndexToY = gphFrame.gphItemIndexToY or {}
                    gphFrame.gphItemIndexToY[itemIdx] = yOff
                end
            
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
                    gphFrame.gphDefaultScrollY = yOff  
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
            
            local rowStep = ComputeItemDetailsRowHeight(18)
            yOff = yOff + rowStep
            end
        end
        
        if gphFrame and not selectedStillExists and hadSelectedItemId then
            local nextIdx = gphFrame.gphSelectedIndex and math.min(gphFrame.gphSelectedIndex, #listForAdvance) or 1
            local nextItem = listForAdvance[nextIdx]
            if nextItem and nextItem.link then
                local nextId = tonumber(nextItem.link:match("item:(%d+)"))
                if nextId then
                    gphFrame.gphSelectedItemId = nextId
                    gphFrame.gphSelectedIndex = nextIdx
                    gphFrame.gphSelectedRowBtn = nil  
                    
                    
                    local oldRowY = gphFrame.gphSelectedRowY
                    local idxToY = gphFrame.gphItemIndexToY
                    local oldScroll = gphFrame.gphScrollOffset or 0
                    if oldRowY and idxToY and idxToY[nextIdx] then
                        local newRowY = idxToY[nextIdx]
                        local wantScroll = newRowY - oldRowY + oldScroll
                        
                        if oldRowY <= 40 then
                            gphFrame.gphScrollToRowYOnLayout = 0
                        
                        elseif math.abs(wantScroll - oldScroll) > 80 then
                            gphFrame.gphScrollToRowYOnLayout = nil  
                        else
                            gphFrame.gphScrollToRowYOnLayout = wantScroll
                        end
                    end
                    
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
    
        if gphFrame.gphScrollBar then
            viewHeight = gphFrame.scrollFrame:GetHeight()
            local contentHeight = content:GetHeight()
            local maxScroll = math.max(0, contentHeight - viewHeight)
            local cur = gphFrame.gphScrollOffset or 0
            
            
            if gphFrame.gphScrollToDefaultOnNextRefresh then
                if gphFrame.gphDefaultScrollY and maxScroll > 0 then
                    cur = math.min(gphFrame.gphDefaultScrollY, maxScroll)
                    gphFrame.gphScrollToDefaultOnNextRefresh = nil
                    gphFrame._gphHomebaseRetryScheduled = nil  
                    gphFrame._pendingScrollToDefault = cur
                elseif maxScroll == 0 and gphFrame.gphDefaultScrollY then
                    
                    cur = 0
                    if not gphFrame._gphHomebaseRetryScheduled then
                        gphFrame._gphHomebaseRetryScheduled = true
                        local retryFrame = Addon._gphHomebaseRetryFrame
                        if not retryFrame then
                            retryFrame = CreateFrame("Frame")
                            Addon._gphHomebaseRetryFrame = retryFrame
                        end
                        retryFrame:SetScript("OnUpdate", function(self)
                            self:SetScript("OnUpdate", nil)
                            self:Hide()
                            if gphFrame and gphFrame.gphScrollToDefaultOnNextRefresh and RefreshGPHUI then
                                gphFrame._refreshImmediate = true
                                RefreshGPHUI()
                            end
                        end)
                        retryFrame:Show()
                    end
                else
                    cur = 0
                    gphFrame.gphScrollToDefaultOnNextRefresh = nil
                end
            end
            
            if gphFrame.gphScrollToRowYOnLayout then
                cur = math.max(0, math.min(maxScroll, gphFrame.gphScrollToRowYOnLayout))
                gphFrame.gphScrollToRowYOnLayout = nil
            end
            
            
            do
                local prevDefault = gphFrame._gphPrevDefaultScrollY
                local newDefault = gphFrame.gphDefaultScrollY
                if prevDefault and newDefault
                   and not gphFrame.gphScrollToDefaultOnNextRefresh
                   and not gphFrame.gphScrollToRowYOnLayout then
                    local diff = cur - prevDefault
                    if diff < 0 then diff = -diff end
                    if diff <= 80 and cur > 20 then
                        cur = math.max(0, math.min(maxScroll, newDefault))
                    end
                end
            end
            if cur > maxScroll then cur = maxScroll end
        gphFrame.gphScrollOffset = cur
        gphFrame.gphScrollBar:SetMinMaxValues(0, maxScroll)
        gphFrame.gphScrollBar:SetValue(cur)
    end
    
    local sf = gphFrame.scrollFrame
    local scrollChild = sf and sf:GetScrollChild()
    if scrollChild and scrollChild == content then
        scrollChild:ClearAllPoints()
        scrollChild:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, gphFrame.gphScrollOffset or 0)
        scrollChild:SetWidth(SCROLL_CONTENT_WIDTH)
    end
    end)  
    if not refreshOk then
        Addon.AddonPrint("[Fugazi] GPH refresh error: " .. tostring(refreshErr))
    end
    
    
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


--- Show/hide inventory (B key target).
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
_G.ToggleGPHFrame = ToggleGPHFrame  


--- Create main addon frame; register events, keybinds, options.
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

    
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        Addon.SaveFrameLayout(f, "frameShown", "framePoint")
        DB.mainFrameUserClosed = true
    end)

    
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
    resetText:SetText("|cffff8844Reset ID|r")  
    resetBtn.label = resetText
    resetBtn:SetScript("OnClick", function()
        ResetInstances()
        Addon.AddonPrint(Addon.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Instances reset.")
    end)
    resetBtn:SetScript("OnEnter", function(self)
        self.bg:SetTexture(0.5, 0.25, 0.1, 0.8)
        self.label:SetText("|cffffaa66Reset ID|r")  
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset Instance ID", 1, 0.6, 0.2)
        GameTooltip:AddLine("Resets all non-saved dungeon instances.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
        self.label:SetText("|cffff8844Reset ID|r")  
        GameTooltip:Hide()
    end)
    f.resetBtn = resetBtn

    
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

    
    local header2 = Addon.GetText(content)
    header2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    header2:SetText("|cff80c0ff--- Saved Lockouts ---|r")
    yOff = yOff + 18

    
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




local elapsed_acc, raidinfo_acc = 0, 0

--- Main loop tick (refresh throttle, bank refresh).
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




--- Hide ElvUI bank when we show ours (avoid double bank).
local function StealthHideElvUIBank()
    local E = _G.ElvUI and _G.ElvUI[1]
    if E and E.GetModule then
        local B = E:GetModule("Bags")
        if B then
            
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
        
        if not _G.InstanceTrackerKeybindOwner then
            _G.InstanceTrackerKeybindOwner = CreateFrame("Frame", "InstanceTrackerKeybindOwner", UIParent)
        end
        
        if DB.gphSession then
            Addon.SyncGPHSessionFromDB()
        end
        
        gphFrame = CreateGPHFrame()
        _G.TestGPHFrame = gphFrame
        
        
        local gc = _G.FugaziBAGS_GridContent
        if gc and gc:GetParent() ~= gphFrame then
            gc:SetParent(gphFrame)
            gc:ClearAllPoints()
            gc:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
            gc:Hide()
        end
        
        if not _G.ToggleGPHFrame then _G.ToggleGPHFrame = ToggleGPHFrame end
        if Addon.InstallGPHInvHook then Addon.InstallGPHInvHook() end
        Addon.RestoreFrameLayout(gphFrame, nil, "gphPoint")
        local container = _G.FugaziBAGS_InventoryContainer
        
        if container then container:Hide() end
        local SV = _G.FugaziBAGSDB
        if not (SV and SV.gphPoint and SV.gphPoint.point) then
            gphFrame:ClearAllPoints()
            
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
                            
                            inv._gphPreBankAnchor = { p, r, rp, x, y }
                            
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
                    
                    local retryCount = 0
                    local retryFrame = CreateFrame("Frame")
                    retryFrame:SetScript("OnUpdate", function(self, elapsed)
                        self._t = (self._t or 0) + elapsed
                        if self._t < 0.2 then return end
                        self._t = 0
                        retryCount = retryCount + 1
                        if RefreshBankUI then RefreshBankUI() end
                        
                        local used = _G.TestBankFrame and _G.TestBankFrame._bankUsedSlots or 0
                        if used > 0 or retryCount >= 5 then
                            self:SetScript("OnUpdate", nil)
                            self:Hide()
                        end
                    end)
                end
                
                
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
        

    elseif event == "CHAT_MSG_SYSTEM" then
        

    elseif event == "UPDATE_INSTANCE_INFO" then
        

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
        if inv then
            if inv._gphPreBankAnchor then
                local p, r, rp, x, y = unpack(inv._gphPreBankAnchor)
                if p and rp and x and y then
                    inv:ClearAllPoints()
                    inv:SetPoint(p, r or UIParent, rp, x, y)
                end
                inv._gphPreBankAnchor = nil
            elseif not inv._gphRestoredFromBankOnHide and Addon.RestoreFrameLayout then
                Addon.RestoreFrameLayout(inv, nil, "gphPreBankPoint")
            end
            inv._gphRestoredFromBankOnHide = nil
        end
    elseif event == "MERCHANT_SHOW" or event == "GOSSIP_SHOW" or event == "QUEST_GREETING" or event == "MAIL_SHOW" then
        gphNpcDialogTime = GetTime()
        
        do
            local defer = CreateFrame("Frame")
            defer:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                if Addon.HideBlizzardBags then Addon.HideBlizzardBags() end
            end)
        end
        if event == "MERCHANT_SHOW" then
            
            if _G.gphSession then
                Addon.gphMerchantGoldAtOpen = GetMoney()
                Addon.gphMerchantRepairCostAtOpen = (GetRepairAllCost and GetRepairAllCost()) or 0
            end
            Addon.InstallGphGreedyMuteOnce()
            if _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphAutoVendor then
                
                local defer = CreateFrame("Frame")
                defer:SetScript("OnUpdate", function(self)
                    self:SetScript("OnUpdate", nil)
                    if Addon.StartGphVendorRun then Addon.StartGphVendorRun() end
                end)
            end
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            
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
        
        if _G.gphSession and Addon.gphMerchantGoldAtOpen then
            local nowGold = GetMoney()
            local delta = nowGold - Addon.gphMerchantGoldAtOpen
            if delta > 0 then
                _G.gphSession.vendorGold = (_G.gphSession.vendorGold or 0) + delta
            end
            if GetRepairAllCost then
                local repairNow = GetRepairAllCost()
                local repairWas = Addon.gphMerchantRepairCostAtOpen or 0
                if repairWas > repairNow then
                    local spent = repairWas - repairNow
                    _G.gphSession.repairCopper = (_G.gphSession.repairCopper or 0) + spent
                    _G.gphSession.repairCount = (_G.gphSession.repairCount or 0) + 1
                end
            end
        end
        Addon.gphMerchantGoldAtOpen = nil
        Addon.gphMerchantRepairCostAtOpen = nil
        gphNpcDialogTime = nil
        if Addon.FinishGphVendorRun then Addon.FinishGphVendorRun() end
        if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
        
        if RefreshGPHUI then
            local d = CreateFrame("Frame")
            d:SetScript("OnUpdate", function(self) self:SetScript("OnUpdate", nil); RefreshGPHUI() end)
        end
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        
        
        
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
    elseif event == "BAG_UPDATE" then
        
        local mailOrVendor = (_G.MailFrame and _G.MailFrame:IsShown()) or (_G.MerchantFrame and _G.MerchantFrame:IsShown())
        if mailOrVendor then
            local d = CreateFrame("Frame")
            d:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                Addon.DiffBags()
                local gphSession = _G.gphSession
                if gphSession then Addon.DiffBagsGPH() end
                if gphFrame and gphFrame:IsShown() and RefreshGPHUI then
                    if not Addon.gphBagUpdateDeferFrame then Addon.gphBagUpdateDeferFrame = CreateFrame("Frame") end
                    local def = Addon.gphBagUpdateDeferFrame
                    if not def._gphScheduled then
                        def._gphScheduled = true
                        def._accum = 0
                        def:SetScript("OnUpdate", function(self2, elapsed)
                            self2._accum = (self2._accum or 0) + elapsed
                            if self2._accum < 0.05 then return end
                            self2:SetScript("OnUpdate", nil)
                            self2._gphScheduled = nil
                            if gphFrame then gphFrame._refreshImmediate = true end
                            if RefreshGPHUI then RefreshGPHUI() end
                            local cg = _G.FugaziBAGS_CombatGrid
                            if cg and gphFrame and gphFrame.gphGridMode and cg.RefreshSlots then cg.RefreshSlots() end
                        end)
                    end
                end
                if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then
                    if not Addon.bankUpdateDeferFrame then Addon.bankUpdateDeferFrame = CreateFrame("Frame") end
                    local bdef = Addon.bankUpdateDeferFrame
                    if not bdef._bankScheduled then
                        bdef._bankScheduled = true
                        bdef._accum = 0
                        bdef:SetScript("OnUpdate", function(self2, elapsed)
                            self2._accum = (self2._accum or 0) + elapsed
                            if self2._accum < 0.2 then return end
                            self2:SetScript("OnUpdate", nil)
                            self2._bankScheduled = nil
                            if _G.TestBankFrame and _G.TestBankFrame:IsShown() and RefreshBankUI then RefreshBankUI() end
                        end)
                    end
                end
                if gphFrame and gphFrame.UpdateDestroyMacro then gphFrame.UpdateDestroyMacro() end
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
            end)
        else
            Addon.DiffBags()
            local gphSession = _G.gphSession
            if gphSession then Addon.DiffBagsGPH() end
            
            if gphFrame and gphFrame:IsShown() then
                if not Addon.gphBagUpdateDeferFrame then Addon.gphBagUpdateDeferFrame = CreateFrame("Frame") end
                local defer = Addon.gphBagUpdateDeferFrame
                if not defer._gphScheduled then
                        defer._gphScheduled = true
                        defer._accum = 0
                        defer:SetScript("OnUpdate", function(self, elapsed)
                            self._accum = (self._accum or 0) + elapsed
                            if self._accum < 0.05 then return end
                            self:SetScript("OnUpdate", nil)
                            self._gphScheduled = nil
                            if gphFrame then gphFrame._refreshImmediate = true end
                            if RefreshGPHUI then RefreshGPHUI() end
                            local cg = _G.FugaziBAGS_CombatGrid
                            if cg and gphFrame and gphFrame.gphGridMode then
                                if cg.RefreshSlots then cg.RefreshSlots() end
                            end
                    end)
                end
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



SLASH_INSTANCETRACKER1 = "/fit"
SLASH_INSTANCETRACKER2 = "/fugazi"
SLASH_FUGAZIGPH1 = "/gph"
SlashCmdList["FUGAZIGPH"] = function() ToggleGPHFrame() end


--- Debug: list protected frame children (for taint).
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


SLASH_FUGAZITAINT1 = "/fugazitaint"
SlashCmdList["FUGAZITAINT"] = function(msg)
    local arg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local wantOn = (arg == "" or arg == "on" or arg == "1" or arg == "true")
    local wantOff = (arg == "off" or arg == "0" or arg == "false")
    if wantOn then
        if SetCVar then SetCVar("taintLog", "1") end
        print("|cff00aaff[FugaziBAGS]|r Taint logging |cff44ff44ON|r. Log file: Logs\\taint.log (updates when taint occurs or on logout).")
    elseif wantOff then
        if SetCVar then SetCVar("taintLog", "0") end
        print("|cff00aaff[FugaziBAGS]|r Taint logging |cffff4444OFF|r.")
    else
        local cur = (GetCVar and GetCVar("taintLog")) or "0"
        local isOn = (cur == "1")
        print("|cff00aaff[FugaziBAGS]|r Taint log is " .. (isOn and "|cff44ff44ON|r" or "|cffff4444OFF|r") .. ". Use |cffffcc00/fugazitaint on|r or |cffffcc00/fugazitaint off|r.")
    end
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
