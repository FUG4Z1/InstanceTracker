----------------------------------------------------------------------
-- __FugaziBAGS: Combat Grid (separate file)
----------------------------------------------------------------------
--
-- WHY THIS FILE EXISTS
-- The addon started as Fugazi Instance Tracker with a manageable loot list. That list
-- slowly grew into a full inventory (the "list view" in FugaziBAGS.lua). The problem:
-- that list view was never safe to use in combat — WoW's taint system blocked things left right and cente
-- like right-click-to-use and keybinds, so you couldn't use potions or open bags in a fight.
-- Instead of rewriting the whole addon, this file was added as a separate, "combat-safe"
-- layer: when you're in combat (or when you force grid mode), the addon switches to a
-- grid of real bag slots that use Blizzard's secure templates. So you get:
--   • Out of combat / city: list view (sort, filter, GPH timer, etc.)
--   • In combat (or "force grid" on): this grid — like the default WoW bags, but inside
--     our window, so you can use items and open/close with B without taint errors.
-- It all works now, and grid mode is kept in this file so the main addon stays one place
-- for list logic and this file stays one place for secure grid logic.
--
-- WHAT THIS FILE DOES
-- • Provides the grid of bag slots (backpack + bags 1–4 + keyring) that you see in "grid mode".
-- • Uses Blizzard's ContainerFrameItemButtonTemplate so clicks (use item, drag, etc.) run
--   in a secure path and work in combat.
-- • ShowInFrame(f) / HideInFrame(f): show or hide this grid inside the inventory window,
--   and switch the main addon back to list view when you leave combat (unless "force grid" is on).
-- • Same idea for the bank: ShowInBankFrame / HideInBankFrame for grid mode in the bank window.
-- • Search and rarity filter apply to the grid (dim non-matching slots).
-- • Alt+click = protect/unprotect; Ctrl+right-double-click = add to autodelete list (with confirm).
--
----------------------------------------------------------------------

-- Cached WoW API (faster than _G every time)
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

-- Default grid look (columns, slot size, spacing, border, glow, "ask before autodelete")
local DEFAULTS = {
    gridCols = 10, gridSlotSize = 30, gridSpacing = 4,
    gridBorderSize = 2, gridGlowAlpha = 0.35,
    gridProtDesat = 0.80, gridConfirmAutoDel = true,
    gridProtectedKeyAlpha = 0.2,
}
-- Bag IDs we show: 0 = backpack, 1–4 = equipped bags, -2 = keyring (like default bag bar)
local BAG_IDS         = { 0, 1, 2, 3, 4, -2 }
local MAX_SLOTS       = 36   -- Max slots we ever show per bag (biggest bag size)
local BACKPACK_SLOTS  = 16   -- Default backpack size (16 slots)
local BAG_BAR_BTN_SZ  = 22   -- Size of each bag bar button (backpack, bag1..4, keyring)
local BAG_BAR_GAP     = 3
local BAG_BAR_PAD     = 6

-- Where the grid sits inside the GPH frame (below title/buttons, above bottom bar)
local GPH_TOP_TO_GRID  = 93
local GPH_BOTTOM_BAR   = 20
local GPH_LEFT_MARGIN  = 12
local GPH_RIGHT_MARGIN = 8

-- Inventory grid state (one grid for the main bags window)
local gridContent, gphRef, eventFrame
local bagFrames   = {}
local slotButtons = {}
local slotsReady  = false
local bagBar, bagBarBtns = nil, {}
local autoDelSlots = {}   -- Slots marked "will be destroyed" (red DEL overlay)

-- Bank grid: separate state so inventory and bank can both be in grid mode at once
local BANK_BAG_IDS    = { -1, 5, 6, 7, 8, 9, 10, 11 }  -- Main bank (-1) + bank bag slots
local BANK_MAX_SLOTS  = 36
local bankGridContent, bankGphRef, bankEventFrame
local bankBagFrames   = {}
local bankSlotButtons = {}
local bankSlotsReady  = false
local bankBagBar, bankBagBarBtns = nil, {}
local bankAutoDelSlots = {}

-- Ctrl+right-double-click on a grid slot: first click marks "DEL", second within 0.5s adds to autodelete list.

-- Popup when you confirm "add to autodelete" from the grid (same idea as the red X in list view, but for grid).
StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"] = StaticPopupDialogs["FUGAZIGRID_DESTROY_CONFIRM"] or {
    text = "Add %s to auto-destroy list? It will be deleted from your bags while marked.",
    button1 = "Add to list",
    button2 = "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

----------------------------------------------------------------------
-- Settings: read options from saved DB or use defaults (columns, slot size, etc.)
----------------------------------------------------------------------
--- Returns a grid setting (e.g. gridCols, gridSlotSize); uses your saved value or the default.
local function S(key)
    local DB = _G.FugaziBAGSDB
    local v = (DB and DB[key] ~= nil) and DB[key] or DEFAULTS[key]
    if key == "gridBorderSize" and (not v or v < 2) then v = 2 end
    return v
end

--- How many slots this bag has (backpack = 16, keyring only if shown; other bags from WoW).
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

--- How many slots this bank bag has (main bank = 28, same idea as the default bank UI).
local function BankNumSlots(bag)
    local n = GetContainerNumSlots and GetContainerNumSlots(bag)
    if n and n > 0 then return n end
    if bag == -1 then return 28 end
    return 0
end

--- Item quality (0=grey, 1=white, 2=green, 3=blue, 4=purple) for one slot — used for borders and filter.
local function ItemQuality(bag, slot)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return nil end
    local _, _, q = GetItemInfo(link)
    return q
end

--- Returns red, green, blue for a quality level so we can draw coloured borders (green/blue/purple).
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

--- True if this slot is protected (Alt+click lock, rarity protect, or "previously worn") — won't show autodelete.
local function IsItemProtected(bag, slot)
    local Addon = _G.TestAddon
    if not Addon then return false end
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return false end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return false end
    -- Manual protect always wins
    local protectedSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
    if protectedSet[itemId] then return true end
    -- Check if manually unprotected (Alt+LMB override)
    local SV = _G.FugaziBAGSDB
    if SV and SV._manualUnprotected and SV._manualUnprotected[itemId] then return false end
    -- Rarity-wide protection
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}
    local _, _, q = GetItemInfo(link)
    if q and rarityFlags[q] then return true end
    -- Previously worn
    if Addon.GetGphPreviouslyWornOnlySet then
        local prevOnly = Addon.GetGphPreviouslyWornOnlySet()
        if prevOnly and prevOnly[itemId] then return true end
    end
    return false
end

--- Unique key for one bag+slot (used to track which slots are marked for autodelete in the grid).
local function SlotKey(bag, slot) return bag * 100 + slot end



--- Updates one grid slot: icon, count, cooldown, lock overlay, rarity border, protected overlay, DEL overlay.
-- "match" = false dims the slot when search/rarity filter doesn't match (like greying out filtered items).
-- searchMatch = true when this slot matches the active search text (used to add a soft highlight).
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

    -- Search highlight: when a search is active and this slot matches, add a soft glow.
    if btn.searchHighlight then
        if searchMatch then
            btn.searchHighlight:Show()
        else
            btn.searchHighlight:Hide()
        end
    end

    local skin = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin) or "original"
    if skin == "original" then
        -- Original skin: satchel-of-Cenarius style background for slots
        btn.slotBg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
        if bag == -2 then
            btn.slotBg:SetVertexColor(0.45, 0.52, 0.52, 0.10)
        else
            btn.slotBg:SetVertexColor(0.50, 0.50, 0.55, 0.10)
        end
    elseif skin == "elvui" or skin == "elvui_real" or skin == "pimp_purple" then
        -- ElvUI Ebonhold + Pimp Purple: flat, glassy squares that match the frame.
        btn.slotBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        if skin == "pimp_purple" then
            btn.slotBg:SetVertexColor(0.20, 0.02, 0.32, 0.85)
        else
            -- ElvUI Ebonhold: dark glassy grey/teal, similar to mainBg.
            btn.slotBg:SetVertexColor(0.06, 0.08, 0.09, 0.90)
        end
    else
        -- Other skins (ElvUI real, etc.): use a subtle standard quickslot-style backdrop.
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

    -- Show shield icon for previously-worn items
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

--- True if the item in this slot matches the search text (name contains the string; used to dim non-matches).
local function SearchMatch(bag, slot, q)
    if not q or q == "" then return true end
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return false end
    local name = GetItemInfo and GetItemInfo(link)
    return name and name:lower():find(q, 1, true) ~= nil
end

--- True if the slot's item quality matches the current rarity filter (e.g. "show only blue").
local function RarityMatch(bag, slot, filterQ)
    if filterQ == nil then return true end
    local q = ItemQuality(bag, slot)
    if q == nil then return false end
    if q == filterQ then return true end
    if filterQ == 4 and (q == 5 or q == 6) then return true end
    return false
end

--- Refreshes every visible slot (icon, count, cooldown, borders, search/rarity dimming) — call after bag update or filter change.
local function RefreshAllSlots()
    local searchQ
    if gphRef and gphRef.gphSearchText and gphRef.gphSearchText ~= "" then
        searchQ = gphRef.gphSearchText:match("^%s*(.-)%s*$"):lower()
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

--- Removes Blizzard's default slot textures (normal/pushed/highlight) so our grid looks clean and consistent.
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

--- Picks up the item and deletes it (for autodelete list); does nothing if the slot is protected.
local function DoAutoDelete(bag, slot)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return end
    if IsItemProtected(bag, slot) then return end
    PickupContainerItem(bag, slot)
    if CursorHasItem and CursorHasItem() then DeleteCursorItem() end
end

--- Handles Alt and Ctrl clicks on a grid slot: Alt+LMB = protect/unprotect; Ctrl+LMB = clear DEL; Ctrl+RMB double-click = add to autodelete list.
local function HandleModifierClick(btn, button, bag, slot, altDown, ctrlDown)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not link then return end
    local itemId = tonumber(link:match("item:(%d+)"))
    if not itemId then return end
    local Addon = _G.TestAddon

    if altDown and button == "LeftButton" then
        if not (Addon and Addon.GetGphProtectedSet) then return end
        local set = Addon.GetGphProtectedSet()
        if not set then return end
        if set[itemId] then
            -- Unprotect: remove from manual protect + clear previously-worn so manual choice wins
            set[itemId] = nil
            local SV = _G.FugaziBAGSDB
            if SV and SV.gphPreviouslyWornItemIds then
                SV.gphPreviouslyWornItemIds[itemId] = nil
            end
            -- Mark as manually unprotected so rarity-wide protection doesn't re-apply
            if not SV._manualUnprotected then SV._manualUnprotected = {} end
            SV._manualUnprotected[itemId] = true
        else
            -- Protect: manual override always wins
            set[itemId] = true
            local SV = _G.FugaziBAGSDB
            if SV and SV._manualUnprotected then SV._manualUnprotected[itemId] = nil end
        end
        RefreshAllSlots()

    elseif ctrlDown and button == "LeftButton" then
        if Addon and Addon.gphGridDestroyClickTime then
            Addon.gphGridDestroyClickTime[itemId] = nil
        end
        local list = Addon and Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
        if not list[itemId] then
            local key = SlotKey(bag, slot)
            autoDelSlots[key] = nil
            RefreshAllSlots()
        end

    elseif ctrlDown and button == "RightButton" then
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

        if prev and (now - prev) <= 0.5 then
            clicks[itemId] = nil
            if Addon and Addon.PlayTrashSound then Addon.PlayTrashSound() end
            local function addAndQueue()
                local name, _, _, _, _, _, _, _, _, texture = GetItemInfo and GetItemInfo(itemId) or nil
                if not name and GetItemInfo then name = GetItemInfo(link) end
                list[itemId] = {
                    name = name or ("Item "..tostring(itemId)),
                    texture = texture,
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

--- Creates one grid slot button (icon, count, cooldown, rarity border, lock overlay, DEL overlay). Uses Blizzard's ContainerFrameItemButtonTemplate so use/drag works in combat.
local function MakeSlot(bag, slot, parent)
    local bname = (bag == -2) and "K" or tostring(bag)
    local name = ("FugaziGrid_B%s_S%d"):format(bname, slot)
    -- ContainerFrameItemButtonTemplate provides a secure execution path for
    -- UseContainerItem / PickupContainerItem (required on 3.3.5a servers).
    -- Show/Hide of the parent frame in combat is handled by a SecureHandler
    -- keybind so protected children are not a problem.
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

    -- Coloured rarity border: four textures (top/bottom/left/right) so we can tint them directly like ElvUI does.
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

    -- Shield icon for previously-worn items
    local wornIcon = btn:CreateTexture(nil, "OVERLAY", nil, 5)
    wornIcon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    wornIcon:SetSize(12, 12)
    wornIcon:SetTexture("Interface\\Icons\\INV_shield_06")
    wornIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    wornIcon:Hide()
    btn.wornIcon = wornIcon

    -- Key overlay for protected items: covers whole slot; shadow (0.15, desat) normally; at vendor 0.75 full color.
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

    -- Soft highlight used for search matches (independent of bag highlight).
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

    -- Let Blizzard's template handle clicks (secure path for UseContainerItem).
    if templateOk and ContainerFrameItemButton_OnLoad then
        ContainerFrameItemButton_OnLoad(btn)
    end

    -- At vendor, block right-click sell on protected items until user unprotects (Alt+click or unprotect rarity).
    local vendorProtectOverlay = CreateFrame("Button", nil, btn)
    vendorProtectOverlay:SetAllPoints(btn)
    vendorProtectOverlay:SetFrameLevel((btn:GetFrameLevel() or 1) + 5)
    vendorProtectOverlay:EnableMouse(true)
    vendorProtectOverlay:RegisterForClicks("RightButtonUp")
    vendorProtectOverlay:SetScript("OnClick", function() end)
    vendorProtectOverlay:Hide()
    btn._vendorProtectOverlay = vendorProtectOverlay

    -- Modifier hook runs AFTER Blizzard's secure OnClick, so normal use/drag (including Shift+RMB socket/split) stays default.
    btn:HookScript("OnClick", function(self, button)
        local shiftDown = IsShiftKeyDown and IsShiftKeyDown()
        local altDown  = IsAltKeyDown and IsAltKeyDown()
        local ctrlDown = IsControlKeyDown and IsControlKeyDown()

        local b, s = self:GetParent():GetID(), self:GetID()

        if not altDown and not ctrlDown then return end

        -- Alt/Ctrl rarity management (protect / add to destroy list, etc.)
        HandleModifierClick(self, button, b, s, altDown, ctrlDown)

        -- Alt+LMB: Blizzard already picked up the item; put it back so Alt+click doesn't move it.
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

--- Creates all bag frames and slot buttons once (backpack + bags 1–4 + keyring); idempotent.
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
    -- Single OnUpdate: set rotation on center-pinned flare (smooth slow spin).
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

---------------------------------------------------------------------------
-- bag bar: real bag equipment slots + keyring
---------------------------------------------------------------------------
local function ClearAllBagHighlights()
    for _, bag in ipairs(BAG_IDS) do
        if slotButtons[bag] then
            for _, btn in pairs(slotButtons[bag]) do
                if btn.bagHighlight then btn.bagHighlight:Hide() end
            end
        end
    end
end

--- Highlights all visible slots for one bag (when you hover that bag's button in the bag bar).
local function HighlightBag(bagID)
    ClearAllBagHighlights()
    if slotButtons[bagID] then
        for s, btn in pairs(slotButtons[bagID]) do
            if btn:IsShown() and btn.bagHighlight then btn.bagHighlight:Show() end
        end
    end
end

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
            -- Apply empty slot icon suitable for bag or bank slot
            if not tex then
                if isBank then
                    tex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag" -- bank empty Bag slot
                else
                    tex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag"
                end
            end
            bb.icon:SetTexture(tex)
        end
    end
end

--- Creates the row of bag buttons (backpack, bag 1–4, keyring) below the grid; click = highlight bag or keyring / buy bank slot.
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

--- Positions every slot in a rows×columns grid and resizes the GPH frame to fit (like arranging default bag slots in a rectangle).
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
    gphRef:SetSize(frameW, frameH)
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

---------------------------------------------------------------------------
-- bag bar toggle
---------------------------------------------------------------------------
local function ToggleBagBar()
    if not gridContent or not gphRef then return end
    if not bagBar then CreateBagBar(gridContent) end
    if bagBar:IsShown() then bagBar:Hide() else bagBar:Show(); RefreshBagBar() end
    LayoutGrid()
end

--- Returns the width and height the frame would need to fit the grid (for the main addon to size the window).
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

----------------------------------------------------------------------
-- Public API: what FugaziBAGS.lua calls to show/hide grid mode
----------------------------------------------------------------------
--- Shows the grid inside the inventory window (replaces list view); registers BAG_UPDATE and sets up layout. Called when you enter combat or toggle to grid.
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

--- Current character's "force grid" setting (must match main addon's per-char storage so list view shows correctly).
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

--- Hides the grid. In combat (or "force grid" for this char): just hide grid content; out of combat: switch back to list view and show the scroll list.
local function HideInFrame(f)
    local inCombat = InCombatLockdown and InCombatLockdown()
    local container = _G.FugaziBAGS_InventoryContainer
    local DB = _G.FugaziBAGSDB or {}
    local forceGrid = GetPerCharForceGrid()

    -- In combat (or forceGrid for this char), only tear down grid visuals.
    -- Do NOT switch to list-view layout — the next open will re-show the grid.
    if inCombat or forceGrid then
        if gridContent then gridContent:Hide() end
        if bagBar then bagBar:Hide() end
        table.wipe(autoDelSlots)
        -- Keep gphGridMode = true so reopen path goes straight to grid.
        gphRef = nil
        return
    end

    -- Out of combat, full teardown: switch back to list-view layout.
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

----------------------------------------------------------------------
-- Bank grid: same idea as inventory grid but for the bank window (separate slots/state so both can be open)
----------------------------------------------------------------------

--- Creates all bank bag frames and slot buttons once (main bank + bank bags); idempotent.
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

--- Same as RefreshSlot but for a bank grid slot (icon, count, cooldown, borders, protection).
-- searchMatch = true when this slot matches the active search text (for highlight).
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
        -- Original skin: satchel-of-Cenarius look for bank grid slots
        btn.slotBg:SetTexture("Interface\\Icons\\inv_misc_bag_satchelofcenarius")
        btn.slotBg:SetVertexColor(0.5, 0.5, 0.55, 0.1)
    elseif skin == "elvui" or skin == "elvui_real" or skin == "pimp_purple" then
        -- ElvUI Ebonhold + Pimp Purple: same glassy squares as inventory grid.
        btn.slotBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        if skin == "pimp_purple" then
            btn.slotBg:SetVertexColor(0.20, 0.02, 0.32, 0.85)
        else
            btn.slotBg:SetVertexColor(0.06, 0.08, 0.09, 0.90)
        end
    else
        -- Other skins: standard quickslot-style background.
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

--- Refreshes every bank grid slot (search/rarity filter applied from bank frame if set).
local function BankRefreshAllSlots()
    local searchQ
    if bankGphRef and bankGphRef.gphSearchText and bankGphRef.gphSearchText ~= "" then
        searchQ = bankGphRef.gphSearchText:match("^%s*(.-)%s*$"):lower()
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

--- Positions every bank slot in a rows×columns grid and resizes the bank frame to fit.
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
    bankGphRef:SetSize(frameW, frameH)

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

--- Shows the grid inside the bank window (replaces bank list); same idea as ShowInFrame but for the bank.
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
    -- Position below the bank title bar area
    bankGridContent:SetPoint("TOPLEFT", f, "TOPLEFT", GPH_LEFT_MARGIN, -GPH_TOP_TO_GRID)
    if not bankEventFrame then
        bankEventFrame = CreateFrame("Frame")
        bankEventFrame:RegisterEvent("BAG_UPDATE")
        bankEventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
        bankEventFrame:RegisterEvent("PLAYERBANKBAGSLOTS_CHANGED")
        
        local bankDeferFrame = CreateFrame("Frame"); bankDeferFrame:Hide()
        bankDeferFrame:SetScript("OnUpdate", function(self)
            self:Hide()
            if bankGridContent and bankGridContent:IsShown() then BankRefreshAllSlots() end
        end)

        bankEventFrame:SetScript("OnEvent", function()
            if bankGridContent and bankGridContent:IsShown() then
                bankDeferFrame:Show()
            end
        end)
    end
    f.gphGridContent = bankGridContent; f.gphGridMode = true
    if f.scrollFrame then f.scrollFrame:Hide() end
    if f.gphScrollBar then f.gphScrollBar:Hide() end
    bankGridContent:Show(); BankLayoutGrid()
end

--- Hides the bank grid and shows the bank list view again.
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

    -- Table the main addon uses: ShowInFrame/HideInFrame for inventory grid, ShowInBankFrame/HideInBankFrame for bank, LayoutGrid, ApplySearch, etc.
_G.FugaziBAGS_CombatGrid = {
    ShowInFrame      = ShowInFrame,
    HideInFrame      = HideInFrame,
    ShowInBankFrame  = ShowInBankFrame,
    HideInBankFrame  = HideInBankFrame,
    ApplySearch      = function(t)
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

-- On load: create the grid content frame and slot buttons so they're ready when you first open bags in grid mode.
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
