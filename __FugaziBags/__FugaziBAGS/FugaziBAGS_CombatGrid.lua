






























--[[
  FugaziBAGS_CombatGrid: bag grid view (works in combat). Slot grid + bag bar for inv and bank.
]]

local GetContainerItemInfo = _G.GetContainerItemInfo
local GetContainerItemLink = _G.GetContainerItemLink
local GetItemInfo = _G.GetItemInfo
local GetContainerNumSlots = _G.GetContainerNumSlots
local GetContainerItemCooldown = _G.GetContainerItemCooldown
local SetItemButtonTexture = _G.SetItemButtonTexture
local SetItemButtonCount = _G.SetItemButtonCount
local SetItemButtonDesaturated = _G.SetItemButtonDesaturated
local tonumber = _G.tonumber
local ipairs = _G.ipairs
local pairs = _G.pairs


local DEFAULTS = {
    gridCols = 10, gridSlotSize = 30, gridSpacing = 4,
    gridBorderSize = 2, gridGlowAlpha = 0.35,
    gridProtDesat = 0.80, gridConfirmAutoDel = true,
    gridProtectedKeyAlpha = 0.2,
}

local BAG_IDS         = { 0, 1, 2, 3, 4, -2 }
local MAX_SLOTS       = 36   
local BACKPACK_SLOTS  = 16   
local BAG_BAR_BTN_SZ  = 22   
local BAG_BAR_GAP     = 3
local BAG_BAR_PAD     = 6


local GPH_TOP_TO_GRID  = 93
local GPH_BOTTOM_BAR   = 20
local GPH_LEFT_MARGIN  = 12
local GPH_RIGHT_MARGIN = 8


local gridContent, gphRef, eventFrame
local bagFrames   = {}
local slotButtons = {}
local slotsReady  = false
local bagBar, bagBarBtns = nil, {}
local autoDelSlots = {}   


local lastSearchText = ""


local BANK_BAG_IDS    = { -1, 5, 6, 7, 8, 9, 10, 11 }  
local BANK_MAX_SLOTS  = 36
local bankGridContent, bankGphRef, bankEventFrame, bankDeferFrame
local bankBagFrames   = {}
local bankSlotButtons = {}
local bankSlotsReady  = false
local bankBagBar, bankBagBarBtns = nil, {}
local bankAutoDelSlots = {}




StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"] = StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"] or {
    text = "Add %s to auto-destroy list? It will be deleted from your bags while marked.",
    button1 = "Add to list",
    button2 = "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}





--- Get grid setting from DB or default (slot size, cols, etc).
local function S(key)
    local DB = _G.FugaziBAGSDB
    local v = (DB and DB[key] ~= nil) and DB[key] or DEFAULTS[key]
    if key == "gridBorderSize" and (not v or v < 2) then v = 2 end
    return v
end


--- Number of slots in bag (keyring -2 handled).
local function NumSlots(bag)
    if bag == -2 then
        if not gphRef or not gphRef._keyringForcedShown then
            return 0
        end
        local KEY_BAG = KEYRING_CONTAINER or -2
        local total = (GetContainerNumSlots and GetContainerNumSlots(KEY_BAG)) or 0
        if total == 0 then return 0 end
        local highest = 0
        for s = 1, total do
            if GetContainerItemInfo(KEY_BAG, s) then highest = s end
        end
        return math.min(total, highest + 1)
    end
    local n = GetContainerNumSlots and GetContainerNumSlots(bag)
    if n and n > 0 then return n end
    if bag == 0 then return BACKPACK_SLOTS end
    return 0
end


--- Number of slots in bank bag.
local function BankNumSlots(bag)
    local n = GetContainerNumSlots and GetContainerNumSlots(bag)
    if n and n > 0 then return n end
    if bag == -1 then return 28 end
    return 0
end


--- Get item quality (0–6) for bag slot.
local function ItemQuality(bag, slot)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return nil end
    local _, _, q = GetItemInfo(link)
    return q
end


--- Rarity color (r,g,b) for quality (grey=0.5, green=0.2,1,0.2, …).
local function QualityRGB(q)
    if not q then return nil end
    local A = _G.TestAddon
    if A and A.QUALITY_COLORS and A.QUALITY_COLORS[q] then
        local c = A.QUALITY_COLORS[q]
        return c.r, c.g, c.b
    end
    if GetItemQualityColor then
        local r, g, b = GetItemQualityColor(q)
        if r then return r, g, b end
    end
    return nil
end


--- Is slot protected (soulbound-to-vendor)? Uses main addon API.
local function IsItemProtected(bag, slot)
    local Addon = _G.TestAddon
    if not Addon then return false end
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return false end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return false end
    local _, _, q = GetItemInfo(link)
    q = q or 0
    if Addon.IsItemProtectedAPI then
        return Addon.IsItemProtectedAPI(itemId, q)
    end
    return false
end


--- Unique key for bag+slot (for tables).
local function SlotKey(bag, slot) return bag * 100 + slot end






--- Refresh one grid slot: icon, count, border, protected/destroy state.
local function RefreshSlot(bag, slot, match, searchMatch)
    local btn = slotButtons[bag] and slotButtons[bag][slot]
    if not btn then return end
    local tex, cnt, locked = GetContainerItemInfo(bag, slot)
    SetItemButtonTexture(btn, tex)
    SetItemButtonCount(btn, cnt)
    if match == nil then match = true end
    local q = tex and ItemQuality(bag, slot)
    SetItemButtonDesaturated(btn, locked or not match or (q == 0))
    btn:SetAlpha(match and 1 or 0.2)

    
    if btn.searchHighlight then
        if searchMatch then
            btn.searchHighlight:Show()
        else
            btn.searchHighlight:Hide()
        end
    end

    local skin = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original"
    if skin == "original" then
        
        btn.slotBg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
        if bag == -2 then
            btn.slotBg:SetVertexColor(0.45, 0.52, 0.52, 0.10)
        else
            btn.slotBg:SetVertexColor(0.50, 0.50, 0.55, 0.10)
        end
    elseif skin == "elvui" or skin == "elvui_real" or skin == "pimp_purple" then
        
        btn.slotBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        if skin == "pimp_purple" then
            btn.slotBg:SetVertexColor(0.20, 0.02, 0.32, 0.85)
        else
            
            btn.slotBg:SetVertexColor(0.06, 0.08, 0.09, 0.90)
        end
    else
        
        btn.slotBg:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        btn.slotBg:SetVertexColor(1, 1, 1, 0.25)
    end

    local iconTex = btn.icon or (btn.GetName and _G[btn:GetName() .. "IconTexture"])
    if iconTex then
        iconTex:ClearAllPoints()
        iconTex:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        iconTex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    if tex then
        local s, d, e = GetContainerItemCooldown(bag, slot)
        local cd = btn.cooldown
        if cd and CooldownFrame_SetTimer then CooldownFrame_SetTimer(cd, s, d, e) end
    else
        if btn.cooldown then btn.cooldown:Hide() end
    end

    local prot = tex and IsItemProtected(bag, slot)
    if btn.protOverlay then
        if prot then
            btn.protOverlay:SetTexture(0, 0, 0, S("gridProtDesat"))
            btn.protOverlay:Show()
        else
            btn.protOverlay:Hide()
        end
    end
    if btn._vendorProtectOverlay then
        local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
        if atVendor and prot then btn._vendorProtectOverlay:Show() else btn._vendorProtectOverlay:Hide() end
    end
    if btn.protectedKeyIcon then
        if prot then
            btn.protectedKeyIcon:Show()
            local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
            if atVendor then
                btn.protectedKeyIcon:SetAlpha(0.75)
                if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(0) end
            else
                btn.protectedKeyIcon:SetAlpha(S("gridProtectedKeyAlpha") or 0.2)
                if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(1) end
            end
        else
            btn.protectedKeyIcon:Hide()
        end
    end

    
    if btn.wornIcon then
        local Addon = _G.TestAddon
        if tex and Addon and Addon.GetGphPreviouslyWornOnlySet then
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
            local itemId = link and tonumber(link:match("item:(%d+)"))
            local prevOnly = Addon.GetGphPreviouslyWornOnlySet()
            if itemId and prevOnly and prevOnly[itemId] then
                btn.wornIcon:Show()
            else
                btn.wornIcon:Hide()
            end
        else
            btn.wornIcon:Hide()
        end
    end

    local adKey = SlotKey(bag, slot)
    if btn.autoDelOverlay then
        if autoDelSlots[adKey] and tex then
            btn.autoDelOverlay:Show()
            if btn.autoDelText then btn.autoDelText:Show() end
        else
            btn.autoDelOverlay:Hide()
            if btn.autoDelText then btn.autoDelText:Hide() end
            if not tex then autoDelSlots[adKey] = nil end
        end
    end

    if btn.rarityBorder then
        local q = tex and ItemQuality(bag, slot)
        local r, g, b = QualityRGB(q)
        local bsz = S("gridBorderSize")
        local ga  = S("gridGlowAlpha") or 0
        if q and q > 1 and r and ga > 0 then
            local rb = btn.rarityBorder
            rb[1]:SetHeight(bsz); rb[2]:SetHeight(bsz)
            rb[3]:SetWidth(bsz);  rb[4]:SetWidth(bsz)
            for _, t in ipairs(rb) do t:SetTexture(r, g, b, ga); t:Show() end
        else
            for _, t in ipairs(btn.rarityBorder) do t:Hide() end
        end
    end
end


--- Does slot match current search text?
local function SearchMatch(bag, slot, q)
    if not q or q == "" then return true end
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return false end
    local Addon = _G.TestAddon
    if Addon and Addon.ItemMatchesSearch then
        local ok, result = pcall(Addon.ItemMatchesSearch, link, bag, slot, q)
        if ok then return result end
        
    end
    local name = GetItemInfo and GetItemInfo(link)
    return name and name:lower():find(q, 1, true) ~= nil
end


--- Does slot match quality filter (e.g. show only grey)?
local function RarityMatch(bag, slot, filterQ)
    if filterQ == nil then return true end
    local q = ItemQuality(bag, slot)
    if q == nil then return false end
    if q == filterQ then return true end
    if filterQ == 4 and (q == 5 or q == 6) then return true end
    return false
end


--- Refresh all inventory grid slots (after bag update).
local function RefreshAllSlots()
    local searchQ
    local src = (gphRef and gphRef.gphSearchText and gphRef.gphSearchText ~= "") and gphRef.gphSearchText or (lastSearchText and lastSearchText ~= "" and lastSearchText)
    if src then
        searchQ = src:match("^%s*(.-)%s*$"):lower()
    end
    local filterQ = gphRef and gphRef.gphFilterQuality
    for _, bag in ipairs(BAG_IDS) do
        local n = NumSlots(bag)
        if slotButtons[bag] then
            for s = 1, MAX_SLOTS do
                if s <= n then
                    local sm = SearchMatch(bag, s, searchQ)
                    local rm = RarityMatch(bag, s, filterQ)
                    RefreshSlot(bag, s, sm and rm, (searchQ ~= nil and searchQ ~= "" and sm) or false)
                    slotButtons[bag][s]:Show()
                elseif slotButtons[bag][s] then
                    slotButtons[bag][s]:Hide()
                end
            end
        end
    end
end


do
    local timeoutFrame = CreateFrame("Frame")
    timeoutFrame._accum = 0
    timeoutFrame:SetScript("OnUpdate", function(self, elapsed)
        self._accum = (self._accum or 0) + elapsed
        if self._accum < 0.2 then return end  
        self._accum = 0
        local Addon = _G.TestAddon
        local clicks = Addon and Addon.gphGridDestroyClickTime
        if not clicks or not next(clicks) then return end
        local now = (GetTime and GetTime()) or (time and time()) or 0
        local anyCleared = false
        for itemId, t in pairs(clicks) do
            if (now - (t or 0)) > 1.0 then
                clicks[itemId] = nil
                anyCleared = true
                
                for _, bag in ipairs(BAG_IDS) do
                    local n = NumSlots(bag)
                    for slot = 1, n do
                        local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
                        local id = link and tonumber(link:match("item:(%d+)"))
                        if id == itemId then
                            autoDelSlots[SlotKey(bag, slot)] = nil
                        end
                    end
                end
            end
        end
        if anyCleared then
            RefreshAllSlots()
        end
    end)
end


--- Remove overlay textures from slot (clean for reuse).
local function StripSlotTextures(btn)
    local nt = btn:GetNormalTexture()
    if nt then nt:SetTexture(nil) end
    for _, m in pairs({"GetPushedTexture", "GetHighlightTexture"}) do
        if btn[m] then
            local t = btn[m](btn)
            if t then t:ClearAllPoints(); t:SetAllPoints(btn) end
        end
    end
end


--- Run auto-delete on slot if on destroy list.
local function DoAutoDelete(bag, slot)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return end
    if IsItemProtected(bag, slot) then return end
    PickupContainerItem(bag, slot)
    if CursorHasItem and CursorHasItem() then DeleteCursorItem() end
end


--- Grid slot: Alt=protect, Ctrl+RMB=add to destroy list (double to confirm).
local function HandleModifierClick(btn, button, bag, slot, altDown, ctrlDown)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return end
    local Addon = _G.TestAddon

    if altDown and button == "LeftButton" then
        if not Addon then return end

        local _, _, q = GetItemInfo(itemId)
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

        
        RefreshAllSlots()
        if _G.RefreshGPHUI then
            local inv = _G.TestGPHFrame or _G.FugaziBAGS_GPHFrame
            if inv then inv._refreshImmediate = true end
            _G.RefreshGPHUI()
        end
        
        if (bag == -1 or (bag >= 5 and bag <= 11)) and _G.FugaziBAGS_ScheduleRefreshBankUI then
            _G.FugaziBAGS_ScheduleRefreshBankUI()
        end

    elseif ctrlDown and button == "RightButton" then
        
        if bag == -1 or (bag >= 5 and bag <= 11) then return end
        
        if itemId == 6948 then return end
        if IsItemProtected and IsItemProtected(bag, slot) then return end
        if not (Addon and Addon.GetGphDestroyList) then return end
        local list = Addon.GetGphDestroyList()
        if not list then return end
        if list[itemId] then return end

        Addon.gphGridDestroyClickTime = Addon.gphGridDestroyClickTime or {}
        local clicks = Addon.gphGridDestroyClickTime
        local now = (GetTime and GetTime()) or time()
        local prev = clicks[itemId]

        local key = SlotKey(bag, slot)
        autoDelSlots[key] = true
        RefreshAllSlots()

        if prev and (now - prev) <= 1.0 then
            clicks[itemId] = nil
            if Addon and Addon.PlayTrashSound then Addon.PlayTrashSound() end
            local function addAndQueue()
                local name, _, _, _, _, _, _, _, _, texture = GetItemInfo and GetItemInfo(itemId) or nil
                if not name and GetItemInfo then name = GetItemInfo(link) end
                list[itemId] = {
                    name = name or ("Item "..tostring(itemId)),
                    texture = texture,
                    addedTime = time(),
                }
                if Addon.QueueDestroySlotsForItemId then
                    Addon.QueueDestroySlotsForItemId(itemId)
                end
                if _G.RefreshGPHUI then _G.RefreshGPHUI() end
            end
            local SV = _G.FugaziBAGSDB
            local needConfirm = SV and SV.gridConfirmAutoDel ~= false
            if needConfirm then
                local itemName = GetItemInfo and GetItemInfo(itemId) or (link or "this item")
                StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"].OnAccept = function()
                    addAndQueue()
                end
                StaticPopup_Show("FUGAZIGRID_DESTROY_CONFIRM", itemName)
            else
                addAndQueue()
            end
        else
            clicks[itemId] = now
        end
    end
end


--- Create one grid slot button (icon, count, cooldown, click).
local function MakeSlot(bag, slot, parent)
    local bname = (bag == -2) and "K" or tostring(bag)
    local name = ("FugaziGrid_B%s_S%d"):format(bname, slot)
    
    
    
    
    local btn, templateOk
    local ok = pcall(function()
        btn = CreateFrame("Button", name, parent, "ContainerFrameItemButtonTemplate")
    end)
    if ok and btn then templateOk = true
    else btn = CreateFrame("Button", name, parent, "ItemButtonTemplate") end
    if not btn then return nil end
    btn:SetID(slot)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    if btn.GetName then
        local co = _G[btn:GetName() .. "Cooldown"]
        if co then btn.cooldown = co; co:ClearAllPoints(); co:SetAllPoints(btn) end
    end

    StripSlotTextures(btn)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    local currentSkin = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original"
    if currentSkin == "original" then
        bg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
    else
        bg:SetTexture(nil)
    end
    bg:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if bg.SetDesaturated then bg:SetDesaturated(1) end
    bg:SetVertexColor(0.5, 0.5, 0.55, 0.1)
    btn.slotBg = bg

    
    local rb  = {}
    local bsz = S("gridBorderSize")
    local top = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(bsz); top:Hide()
    rb[1] = top
    local bot = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT"); bot:SetHeight(bsz); bot:Hide()
    rb[2] = bot
    local lft = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    lft:SetPoint("TOPLEFT", top, "BOTTOMLEFT"); lft:SetPoint("BOTTOMLEFT", bot, "TOPLEFT"); lft:SetWidth(bsz); lft:Hide()
    rb[3] = lft
    local rgt = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    rgt:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT"); rgt:SetPoint("BOTTOMRIGHT", bot, "TOPRIGHT"); rgt:SetWidth(bsz); rgt:Hide()
    rb[4] = rgt
    btn.rarityBorder = rb

    local po = btn:CreateTexture(nil, "OVERLAY", nil, 3)
    po:SetPoint("TOPLEFT", 1, -1); po:SetPoint("BOTTOMRIGHT", -1, 1)
    po:SetTexture(0, 0, 0, S("gridProtDesat")); po:Hide()
    btn.protOverlay = po

    
    local wornIcon = btn:CreateTexture(nil, "OVERLAY", nil, 5)
    wornIcon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    wornIcon:SetSize(12, 12)
    wornIcon:SetTexture("Interface\\Icons\\INV_shield_06")
    wornIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    wornIcon:Hide()
    btn.wornIcon = wornIcon

    
    local protectedKeyIcon = btn:CreateTexture(nil, "OVERLAY", nil, 5)
    protectedKeyIcon:SetAllPoints(btn)
    protectedKeyIcon:SetTexture("Interface\\Icons\\INV_Misc_Key_13")
    protectedKeyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    protectedKeyIcon:Hide()
    btn.protectedKeyIcon = protectedKeyIcon

    local adOv = btn:CreateTexture(nil, "OVERLAY", nil, 3)
    adOv:SetPoint("TOPLEFT", 1, -1); adOv:SetPoint("BOTTOMRIGHT", -1, 1)
    adOv:SetTexture(0.7, 0.1, 0.1, 0.6); adOv:Hide()
    btn.autoDelOverlay = adOv

    
    local sh = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    sh:SetAllPoints()
    sh:SetTexture(1, 1, 1, 0.20)
    sh:SetBlendMode("ADD")
    sh:Hide()
    btn.searchHighlight = sh

    local adFs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    adFs:SetPoint("CENTER"); adFs:SetText("|cffff3333DEL|r")
    adFs:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE"); adFs:Hide()
    btn.autoDelText = adFs

    local hl = btn:CreateTexture(nil, "OVERLAY", nil, 4)
    hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.2); hl:SetBlendMode("ADD"); hl:Hide()
    btn.bagHighlight = hl

    
    if templateOk and ContainerFrameItemButton_OnLoad then
        ContainerFrameItemButton_OnLoad(btn)
    end

    
    local vendorProtectOverlay = CreateFrame("Button", nil, btn)
    vendorProtectOverlay:SetAllPoints(btn)
    vendorProtectOverlay:SetFrameLevel((btn:GetFrameLevel() or 1) + 5)
    vendorProtectOverlay:EnableMouse(true)
    vendorProtectOverlay:RegisterForClicks("RightButtonUp")
    vendorProtectOverlay:SetScript("OnClick", function() end)
    vendorProtectOverlay:Hide()
    btn._vendorProtectOverlay = vendorProtectOverlay

    
        btn:HookScript("OnClick", function(self, button)
        local shiftDown = IsShiftKeyDown and IsShiftKeyDown()
        local altDown  = IsAltKeyDown and IsAltKeyDown()
        local ctrlDown = IsControlKeyDown and IsControlKeyDown()

        local b, s = self:GetParent():GetID(), self:GetID()

            if not altDown and not ctrlDown then return end

            
            
            if not (ctrlDown and button == "LeftButton") then
                HandleModifierClick(self, button, b, s, altDown, ctrlDown)
            end

        
        if altDown and button == "LeftButton" then
            if ClearCursor then ClearCursor() end
            PickupContainerItem(b, s)
            if ClearCursor then ClearCursor() end
        end
    end)

    btn:SetScript("OnDragStart", function(self)
        PickupContainerItem(self:GetParent():GetID(), self:GetID())
    end)
    btn:SetScript("OnReceiveDrag", function(self)
        PickupContainerItem(self:GetParent():GetID(), self:GetID())
    end)
    btn:SetScript("OnEnter", function(self)
        local b, s = self:GetParent():GetID(), self:GetID()
        local link = GetContainerItemLink and GetContainerItemLink(b, s)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if b == -1 then
            local invSlot = (BankButtonIDToInvSlotID and BankButtonIDToInvSlotID(s)) or (38 + s)
            GameTooltip:SetInventoryItem("player", invSlot)
        else
            GameTooltip:SetBagItem(b, s)
        end

        local prot = IsItemProtected and IsItemProtected(b, s)
        local isPrev = false
        do
            local A = _G.TestAddon
            if link and A and A.GetGphPreviouslyWornOnlySet then
                local prevOnly = A.GetGphPreviouslyWornOnlySet()
                local itemId = tonumber(link:match("item:(%d+)"))
                if itemId and prevOnly and prevOnly[itemId] then
                    isPrev = true
                end
            end
        end

        if isPrev then
            GameTooltip:AddLine("Previously worn gear", 0.40, 0.80, 0.40)
            GameTooltip:AddLine("Alt+LMB: Unprotect", 0.80, 0.80, 0.80)
        else
            if prot then
                GameTooltip:AddLine("Protected", 0.40, 0.80, 0.40)
                GameTooltip:AddLine("Alt+LMB: Unprotect", 0.80, 0.80, 0.80)
            else
                GameTooltip:AddLine("Unprotected", 1.00, 0.25, 0.25)
                GameTooltip:AddLine("Alt+LMB: Protect", 0.80, 0.80, 0.80)
            end
        end
        GameTooltip:AddLine("Ctrl+RMB: Autodelete", 0.90, 0.60, 0.60)

        GameTooltip:Show()
    end)
    btn.UpdateTooltip = btn:GetScript("OnEnter")
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end


--- Create all inventory grid slots (or reuse); layout on next frame.
local function EnsureSlots()
    if slotsReady or not gridContent then return end
    slotsReady = true
    for _, bag in ipairs(BAG_IDS) do
        local bname = (bag == -2) and "K" or tostring(bag)
        local bf = CreateFrame("Frame", ("FugaziGrid_Bag%s"):format(bname), gridContent)
        bf:SetID(bag); bf:SetAllPoints(gridContent)
        bagFrames[bag] = bf
        slotButtons[bag] = {}
        for s = 1, MAX_SLOTS do slotButtons[bag][s] = MakeSlot(bag, s, bf) end
    end
    
    if not flareAnimFrame then
        flareAnimFrame = CreateFrame("Frame", nil, UIParent)
        local SPEED = 0.45
        flareAnimFrame:SetScript("OnUpdate", function()
            if not gridContent or not gridContent:IsShown() then return end
            local angle = (GetTime() or 0) * SPEED
            for _, bag in ipairs(BAG_IDS) do
                if not slotButtons[bag] then break end
                for s = 1, MAX_SLOTS do
                    local btn = slotButtons[bag][s]
                    if btn and btn.flareSpin and btn.rarityBorderFrame and btn.rarityBorderFrame:IsShown() and btn.flareSpin.SetRotation then
                        btn.flareSpin:SetRotation(angle)
                    end
                end
            end
            if bankGridContent and bankGridContent:IsShown() and bankSlotButtons then
                for _, bag in ipairs(BANK_BAG_IDS) do
                    if not bankSlotButtons[bag] then break end
                    for s = 1, BANK_MAX_SLOTS do
                        local btn = bankSlotButtons[bag][s]
                        if btn and btn.flareSpin and btn.rarityBorderFrame and btn.rarityBorderFrame:IsShown() and btn.flareSpin.SetRotation then
                            btn.flareSpin:SetRotation(angle)
                        end
                    end
                end
            end
        end)
        flareAnimFrame:Show()
    end
end




--- Clear highlight from all bag bar buttons.
local function ClearAllBagHighlights()
    for _, bag in ipairs(BAG_IDS) do
        if slotButtons[bag] then
            for _, btn in pairs(slotButtons[bag]) do
                if btn.bagHighlight then btn.bagHighlight:Hide() end
            end
        end
    end
end


--- Highlight one bag bar button (filter by bag).
local function HighlightBag(bagID)
    ClearAllBagHighlights()
    if slotButtons[bagID] then
        for s, btn in pairs(slotButtons[bagID]) do
            if btn:IsShown() and btn.bagHighlight then btn.bagHighlight:Show() end
        end
    end
end

--- Refresh bag bar (which bags shown, highlight).
local function RefreshBagBar()
    if not bagBar then return end
    for _, bb in ipairs(bagBarBtns) do
        if bb.bagID == 0 then
            bb.icon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
        elseif bb.bagID == -2 then
            bb.icon:SetTexture("Interface\\ContainerFrame\\KeyRing-Bag-Icon")
            if gphRef and gphRef._keyringForcedShown then
                bb.icon:SetVertexColor(1, 1, 1)
            else
                bb.icon:SetVertexColor(0.4, 0.4, 0.4)
            end
        elseif bb.bagID == -3 then
            bb.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        else
            local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(bb.bagID)
            local tex = invID and GetInventoryItemTexture and GetInventoryItemTexture("player", invID)
            
            if not tex then
                if isBank then
                    tex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag" 
                else
                    tex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag"
                end
            end
            bb.icon:SetTexture(tex)
        end
    end
end


--- Create bag bar (backpack + bag 1–4 buttons).
local function CreateBagBar(parent)
    if bagBar then return bagBar end
    bagBar = CreateFrame("Frame", "FugaziGrid_"..(isBank and "Bank" or "").."BagBar", parent)
    bagBar:SetHeight(BAG_BAR_BTN_SZ + BAG_BAR_PAD); bagBar:Hide()
    
    local ids
    if isBank then
        ids = { -3, 5, 6, 7, 8, 9, 10, 11 }
    else
        ids = { 0, 1, 2, 3, 4, -2 }
    end
    
    for i, bagID in ipairs(ids) do
        local bb = CreateFrame("Button", ("FugaziGrid_"..(isBank and "Bank" or "").."BagBtn%d"):format(i), bagBar)
        bb:SetSize(BAG_BAR_BTN_SZ, BAG_BAR_BTN_SZ)
        bb:SetPoint("LEFT", bagBar, "LEFT", 10 + (i - 1) * (BAG_BAR_BTN_SZ + BAG_BAR_GAP), 0)
        bb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        bb:RegisterForDrag("LeftButton")
        local bg = bb:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(0.08, 0.08, 0.08, 0.9)
        local icon = bb:CreateTexture(nil, "ARTWORK"); icon:SetPoint("TOPLEFT", 2, -2); icon:SetPoint("BOTTOMRIGHT", -2, 2)
        bb.icon = icon; bb.bagID = bagID
        bb:SetScript("OnClick", function(self)
            if self.bagID == -2 then
                if gphRef and gphRef.ToggleKeyringFrame then gphRef:ToggleKeyringFrame()
                elseif ToggleKeyRing then ToggleKeyRing() end
            elseif self.bagID == -3 then
                PlaySound("igMainMenuOption")
                StaticPopup_Show("CONFIRM_BUY_BANK_SLOT")
            elseif self.bagID == 0 then
            else
                local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
                if invID then
                    if CursorHasItem and CursorHasItem() then PutItemInBag(invID)
                    else PickupBagFromSlot(invID) end
                end
            end
        end)
        bb:SetScript("OnDragStart", function(self)
            if self.bagID > 0 then
                local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
                if invID then PickupBagFromSlot(invID) end
            end
        end)
        bb:SetScript("OnReceiveDrag", function(self)
            if self.bagID > 0 then
                local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
                if invID then PutItemInBag(invID) end
            end
        end)
        bb:SetScript("OnEnter", function(self)
            if self.bagID >= 0 or self.bagID == -2 then HighlightBag(self.bagID) end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.bagID == -2 then
                GameTooltip:SetText("Keyring")
            elseif self.bagID == -3 then
                GameTooltip:SetText("Purchase Bank Bag Slot")
                local cost = GetBankSlotCost and GetBankSlotCost()
                if cost and cost > 0 then
                    SetTooltipMoney(GameTooltip, cost)
                end
            elseif self.bagID == 0 then
                GameTooltip:SetText("Backpack (16 slots)")
            else
                local invID = ContainerIDToInventoryID and ContainerIDToInventoryID(self.bagID)
                local link = invID and GetInventoryItemLink and GetInventoryItemLink("player", invID)
                if link then GameTooltip:SetHyperlink(link)
                else GameTooltip:SetText(string.format((isBank and "Bank " or "").."Bag %d (empty slot)", self.bagID)) end
            end
            local n = NumSlots(self.bagID)
            if self.bagID >= 0 and n > 0 then GameTooltip:AddLine(n .. " slots", 0.7, 0.7, 0.7) end
            GameTooltip:Show()
        end)
        bb:SetScript("OnLeave", function() ClearAllBagHighlights(); GameTooltip:Hide() end)
        bagBarBtns[i] = bb
    end
    return bagBar
end


--- Layout inventory grid (cols, slot size, position slots).
local function LayoutGrid()
    if not gridContent or not gphRef then return end
    local cols    = S("gridCols")
    local size    = S("gridSlotSize")
    local spacing = S("gridSpacing")

    local total = 0
    for _, bag in ipairs(BAG_IDS) do total = total + NumSlots(bag) end
    if total <= 0 then total = BACKPACK_SLOTS end

    local rows  = math.ceil(total / cols)
    local gridW = cols * size + (cols - 1) * spacing
    local gridH = rows * size + (rows - 1) * spacing
    local pad   = 10
    local contentW = gridW + pad * 2
    local contentH = gridH + pad * 2
    gridContent:SetSize(contentW, contentH)

    local bbH = 0
    if bagBar and bagBar:IsShown() then
        bbH = BAG_BAR_BTN_SZ + BAG_BAR_PAD
        bagBar:ClearAllPoints()
        bagBar:SetPoint("TOPLEFT", gridContent, "BOTTOMLEFT", 0, 0)
        bagBar:SetWidth(contentW)
        RefreshBagBar()
    end

    local frameW = GPH_LEFT_MARGIN + contentW + GPH_RIGHT_MARGIN
    local frameH = GPH_TOP_TO_GRID + contentH + bbH + 6 + GPH_BOTTOM_BAR
    gphRef.gphGridFrameW = frameW
    gphRef.gphGridFrameH = frameH
    
    if not (InCombatLockdown and InCombatLockdown()) then
        gphRef:SetSize(frameW, frameH)
    end
    gphRef._gridNeedsHeaderRefresh = true

    local idx = 0
    for _, bag in ipairs(BAG_IDS) do
        local n = NumSlots(bag)
        for s = 1, MAX_SLOTS do
            local btn = slotButtons[bag] and slotButtons[bag][s]
            if s <= n and btn then
                local r = math.floor(idx / cols)
                local c = idx % cols
                btn:SetSize(size, size)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", gridContent, "TOPLEFT",
                    pad + c * (size + spacing),
                    -(pad + r * (size + spacing)))
                btn:Show()
                idx = idx + 1
            elseif btn then
                btn:Hide()
            end
        end
    end
    RefreshAllSlots()
end




--- Show/hide bag bar.
local function ToggleBagBar()
    if not gridContent or not gphRef then return end
    if not bagBar then CreateBagBar(gridContent) end
    if bagBar:IsShown() then bagBar:Hide() else bagBar:Show(); RefreshBagBar() end
    LayoutGrid()
end


--- Compute frame size for grid (from cols, rows, margins).
local function ComputeFrameSize(isBank)
    local cols    = S("gridCols")
    local size    = S("gridSlotSize")
    local spacing = S("gridSpacing")
    local total = 0
    local ids = isBank and BANK_BAG_IDS or BAG_IDS
    for _, bag in ipairs(ids) do
        if isBank then total = total + BankNumSlots(bag)
        else total = total + NumSlots(bag) end
    end
    if total <= 0 then total = isBank and 28 or BACKPACK_SLOTS end
    local rows  = math.ceil(total / cols)
    local gridW = cols * size + (cols - 1) * spacing
    local gridH = rows * size + (rows - 1) * spacing
    local pad   = 10
    local contentW = gridW + pad * 2
    local contentH = gridH + pad * 2
    local frameW = GPH_LEFT_MARGIN + contentW + GPH_RIGHT_MARGIN
    local frameH = GPH_TOP_TO_GRID + contentH + 6 + GPH_BOTTOM_BAR
    return frameW, frameH
end





--- Show grid in inventory frame (replace list view).
local function ShowInFrame(f)
    if not f then return end
    if not f.gphHeader and not f._isBankFrame then return end
    gphRef = f
    if not gridContent then
        gridContent = CreateFrame("Frame", nil, f)
        gridContent:Hide(); EnsureSlots()
    end
    if gridContent:GetParent() ~= f then
        gridContent:SetParent(f)
        gridContent:ClearAllPoints()
    end
    if f.gphHeader then
        gridContent:SetPoint("TOPLEFT", f.gphHeader, "BOTTOMLEFT", 0, -6)
    else
        gridContent:SetPoint("TOPLEFT", f, "TOPLEFT", GPH_LEFT_MARGIN, -GPH_TOP_TO_GRID)
    end
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:RegisterEvent("BAG_UPDATE")
        local deferFrame = CreateFrame("Frame"); deferFrame:Hide()
        deferFrame:SetScript("OnUpdate", function(self)
            self:Hide()
            if gridContent and gridContent:IsShown() then LayoutGrid() end
        end)
        eventFrame:SetScript("OnEvent", function(_, ev)
            if gridContent and gridContent:IsShown() then
                deferFrame:Show()
                if ev == "BAG_UPDATE" and bagBar and bagBar:IsShown() then
                    RefreshBagBar()
                end
            end
        end)
    end
    f.gphGridContent = gridContent; f.gphGridMode = true
    f.LayoutGrid = LayoutGrid
    f.ComputeFrameSize = ComputeFrameSize
    if f.scrollFrame then f.scrollFrame:Hide() end
    if f.gphScrollBar then f.gphScrollBar:Hide() end
    gridContent:Show(); LayoutGrid()
end


--- Per-char "force grid" setting (from DB).
local function GetPerCharForceGrid()
    local SV = _G.FugaziBAGSDB
    if not SV then return false end
    if not SV.gphPerChar then return SV.gphForceGridView or false end
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    local k = (r or "") .. "#" .. (c or "")
    if not SV.gphPerChar[k] then return SV.gphForceGridView or false end
    local v = SV.gphPerChar[k].gphForceGridView
    if v == nil then return SV.gphForceGridView or false end
    return v
end


--- Hide grid in frame (back to list view).
local function HideInFrame(f)
    if gridContent then gridContent:Hide() end
    if bagBar then bagBar:Hide() end
    table.wipe(autoDelSlots)
    if f then
        f.gphGridMode = false
        f.gphGridContent = nil
        if f.scrollFrame then f.scrollFrame:Show() end
        if f.gphScrollBar then f.gphScrollBar:Show() end
        local w = f.gphGridFrameW or 340
        local h = f.gphGridFrameH or f.EXPANDED_HEIGHT or 400
        f:SetSize(w, h)
    end
    gphRef = nil
end






--- Create all bank grid slots (or reuse).
local function BankEnsureSlots()
    if bankSlotsReady or not bankGridContent then return end
    bankSlotsReady = true
    for _, bag in ipairs(BANK_BAG_IDS) do
        local bf = CreateFrame("Frame", ("FugaziBankGrid_Bag%d"):format(bag < 0 and 99 or bag), bankGridContent)
        bf:SetID(bag); bf:SetAllPoints(bankGridContent)
        bankBagFrames[bag] = bf
        bankSlotButtons[bag] = {}
        for s = 1, BANK_MAX_SLOTS do bankSlotButtons[bag][s] = MakeSlot(bag, s, bf) end
    end
end



--- Refresh one bank grid slot.
local function BankRefreshSlot(bag, slot, match, searchMatch)
    local btn = bankSlotButtons[bag] and bankSlotButtons[bag][slot]
    if not btn then return end
    local tex, cnt, locked = GetContainerItemInfo(bag, slot)
    SetItemButtonTexture(btn, tex)
    SetItemButtonCount(btn, cnt)
    if match == nil then match = true end
    local q = tex and ItemQuality(bag, slot)
    SetItemButtonDesaturated(btn, locked or not match or (q == 0))
    btn:SetAlpha(match and 1 or 0.2)

    if btn.searchHighlight then
        if searchMatch then
            btn.searchHighlight:Show()
        else
            btn.searchHighlight:Hide()
        end
    end
    
    local skin = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original"
    if skin == "original" then
        
        btn.slotBg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
        btn.slotBg:SetVertexColor(0.5, 0.5, 0.55, 0.1)
    elseif skin == "elvui" or skin == "elvui_real" or skin == "pimp_purple" then
        
        btn.slotBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        if skin == "pimp_purple" then
            btn.slotBg:SetVertexColor(0.20, 0.02, 0.32, 0.85)
        else
            btn.slotBg:SetVertexColor(0.06, 0.08, 0.09, 0.90)
        end
    else
        
        btn.slotBg:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        btn.slotBg:SetVertexColor(1, 1, 1, 0.25)
    end

    local iconTex = btn.icon or (btn.GetName and _G[btn:GetName() .. "IconTexture"])
    if iconTex then
        iconTex:ClearAllPoints()
        iconTex:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        iconTex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    if tex then
        local s, d, e = GetContainerItemCooldown(bag, slot)
        local cd = btn.cooldown
        if cd and CooldownFrame_SetTimer then CooldownFrame_SetTimer(cd, s, d, e) end
    else
        if btn.cooldown then btn.cooldown:Hide() end
    end

    local prot = tex and IsItemProtected(bag, slot)
    if btn.protOverlay then
        if prot then
            btn.protOverlay:SetTexture(0, 0, 0, S("gridProtDesat"))
            btn.protOverlay:Show()
        else
            btn.protOverlay:Hide()
        end
    end
    if btn._vendorProtectOverlay then
        local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
        if atVendor and prot then btn._vendorProtectOverlay:Show() else btn._vendorProtectOverlay:Hide() end
    end
    if btn.protectedKeyIcon then
        if prot then
            btn.protectedKeyIcon:Show()
            local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
            if atVendor then
                btn.protectedKeyIcon:SetAlpha(0.5)
                if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(0) end
            else
                btn.protectedKeyIcon:SetAlpha(S("gridProtectedKeyAlpha") or 0.2)
                if btn.protectedKeyIcon.SetDesaturated then btn.protectedKeyIcon:SetDesaturated(1) end
            end
        else
            btn.protectedKeyIcon:Hide()
        end
    end

    if btn.rarityBorder then
        local q = tex and ItemQuality(bag, slot)
        local r, g, b = QualityRGB(q)
        local bsz = S("gridBorderSize")
        local ga  = S("gridGlowAlpha") or 0
        if q and q > 1 and r and ga > 0 then
            local rb = btn.rarityBorder
            rb[1]:SetHeight(bsz); rb[2]:SetHeight(bsz)
            rb[3]:SetWidth(bsz);  rb[4]:SetWidth(bsz)
            for _, t in ipairs(rb) do t:SetTexture(r, g, b, ga); t:Show() end
        else
            for _, t in ipairs(btn.rarityBorder) do t:Hide() end
        end
    end
end


--- Refresh all bank grid slots.
local function BankRefreshAllSlots()
    local searchQ
    local searchSrc = (bankGphRef and bankGphRef.gphSearchText and bankGphRef.gphSearchText ~= "") and bankGphRef.gphSearchText or (gphRef and gphRef.gphSearchText and gphRef.gphSearchText ~= "") and gphRef.gphSearchText or (lastSearchText and lastSearchText ~= "" and lastSearchText)
    if searchSrc then
        searchQ = searchSrc:match("^%s*(.-)%s*$"):lower()
    end
    local filterQ = bankGphRef and bankGphRef.gphFilterQuality
    for _, bag in ipairs(BANK_BAG_IDS) do
        local n = BankNumSlots(bag)
        if bankSlotButtons[bag] then
            for s = 1, BANK_MAX_SLOTS do
                if s <= n then
                    local sm = SearchMatch(bag, s, searchQ)
                    local rm = RarityMatch(bag, s, filterQ)
                    BankRefreshSlot(bag, s, sm and rm, (searchQ ~= nil and searchQ ~= "" and sm) or false)
                    bankSlotButtons[bag][s]:Show()
                elseif bankSlotButtons[bag][s] then
                    bankSlotButtons[bag][s]:Hide()
                end
            end
        end
    end
end


--- Layout bank grid (cols, slot size).
local function BankLayoutGrid()
    if not bankGridContent or not bankGphRef then return end
    local cols    = S("gridCols")
    local size    = S("gridSlotSize")
    local spacing = S("gridSpacing")

    local total = 0
    for _, bag in ipairs(BANK_BAG_IDS) do total = total + BankNumSlots(bag) end
    if total <= 0 then total = 28 end

    local rows  = math.ceil(total / cols)
    local gridW = cols * size + (cols - 1) * spacing
    local gridH = rows * size + (rows - 1) * spacing
    local pad   = 10
    local contentW = gridW + pad * 2
    local contentH = gridH + pad * 2
    bankGridContent:SetSize(contentW, contentH)

    local frameW = GPH_LEFT_MARGIN + contentW + GPH_RIGHT_MARGIN
    local frameH = GPH_TOP_TO_GRID + contentH + 6 + GPH_BOTTOM_BAR
    bankGphRef.gphGridFrameW = frameW
    bankGphRef.gphGridFrameH = frameH
    if not (InCombatLockdown and InCombatLockdown()) then
        bankGphRef:SetSize(frameW, frameH)
    end

    local idx = 0
    for _, bag in ipairs(BANK_BAG_IDS) do
        local n = BankNumSlots(bag)
        for s = 1, BANK_MAX_SLOTS do
            local btn = bankSlotButtons[bag] and bankSlotButtons[bag][s]
            if s <= n and btn then
                local r = math.floor(idx / cols)
                local c = idx % cols
                btn:SetSize(size, size)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", bankGridContent, "TOPLEFT",
                    pad + c * (size + spacing),
                    -(pad + r * (size + spacing)))
                btn:Show()
                idx = idx + 1
            elseif btn then
                btn:Hide()
            end
        end
    end
    BankRefreshAllSlots()
end


--- Show grid in bank frame (replace bank list).
local function ShowInBankFrame(f)
    if not f then return end
    bankGphRef = f
    f._isBankFrame = true
    if not bankGridContent then
        bankGridContent = CreateFrame("Frame", nil, f)
        bankGridContent:Hide()
        BankEnsureSlots()
    end
    if bankGridContent:GetParent() ~= f then
        bankGridContent:SetParent(f)
        bankGridContent:ClearAllPoints()
    end
    
    bankGridContent:SetPoint("TOPLEFT", f, "TOPLEFT", GPH_LEFT_MARGIN, -GPH_TOP_TO_GRID)
    if not bankEventFrame then
        bankEventFrame = CreateFrame("Frame")
        bankEventFrame:RegisterEvent("BAG_UPDATE")
        bankEventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
        bankEventFrame:RegisterEvent("PLAYERBANKBAGSLOTS_CHANGED")
        
        bankDeferFrame = CreateFrame("Frame"); bankDeferFrame:Hide()
        bankDeferFrame:SetScript("OnUpdate", function(self)
            self:Hide()
            if bankGridContent and bankGridContent:IsShown() then BankRefreshAllSlots() end
        end)

        bankEventFrame:SetScript("OnEvent", function()
            if bankGridContent and bankGridContent:IsShown() and bankDeferFrame then
                bankDeferFrame:Show()
            end
        end)
    end
    f.gphGridContent = bankGridContent; f.gphGridMode = true
    if f.scrollFrame then f.scrollFrame:Hide() end
    if f.gphScrollBar then f.gphScrollBar:Hide() end
    bankGridContent:Show(); BankLayoutGrid()
end


--- Hide grid in bank frame (back to list).
local function HideInBankFrame(f)
    if bankGridContent then bankGridContent:Hide() end
    if f then
        f.gphGridMode = false
        f.gphGridContent = nil
        if f.scrollFrame then f.scrollFrame:Show() end
        if f.gphScrollBar then f.gphScrollBar:Show() end
    end
    bankGphRef = nil
end

    
_G.FugaziBAGS_CombatGrid = {
    ShowInFrame      = ShowInFrame,
    HideInFrame      = HideInFrame,
    ShowInBankFrame  = ShowInBankFrame,
    HideInBankFrame  = HideInBankFrame,
    ApplySearch      = function(t)
        lastSearchText = (t and t ~= "" and t:match("^%s*(.-)%s*$")) or ""
        if gphRef then gphRef.gphSearchText = t end
        if bankGphRef then bankGphRef.gphSearchText = t end
        RefreshAllSlots()
        if bankGridContent and bankGridContent:IsShown() then BankRefreshAllSlots() end
    end,
    RefreshSlots     = RefreshAllSlots,
    LayoutGrid       = LayoutGrid,
    ToggleBagBar     = ToggleBagBar,
    IsBagBarShown    = function() return bagBar and bagBar:IsShown() end,
    IsShown          = function() return gridContent and gridContent:IsShown() end,
    ComputeFrameSize = ComputeFrameSize,
    BankRefreshSlots = BankRefreshAllSlots,
    BankLayoutGrid   = BankLayoutGrid,
    IsBankShown      = function() return bankGridContent and bankGridContent:IsShown() end,
}


local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(_, _, addon)
    if addon and addon:lower():find("fugazibags") then
        if not gridContent then
            gridContent = CreateFrame("Frame", nil, UIParent)
            gridContent:SetSize(1, 1)
            gridContent:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
            gridContent:Hide(); EnsureSlots()
        end
    end
end)
