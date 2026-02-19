----------------------------------------------------------------------
-- __FugaziBAGS: inventory and bank (GPH-style). WoW 3.3.5a (WotLK)
-- Split scope + main to avoid Lua 200-locals limit. Uses FugaziBAGSDB and TestGPHFrame.
----------------------------------------------------------------------

local ADDON_NAME = "InstanceTracker"
local MAX_INSTANCES_PER_HOUR = 5
local HOUR_SECONDS = 3600
local MAX_RUN_HISTORY = 100
-- Only restore a run from history if it ended within this many seconds (e.g. died and re-entered before instance reset).
local MAX_RESTORE_AGE_SECONDS = 5 * 60  -- 5 minutes; after that treat as a new run
local SCROLL_CONTENT_WIDTH = 296  -- viewport width for scroll content (no gap left of scrollbar)
local GPH_MAX_STACK = 49  -- server max stack size; confirm when deleting more than this via red X

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
DB.fitSkin = DB.fitSkin or "original"

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

-- Helper: get the correct border color for the active skin (used for the GPH frame).
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

function ApplyTestSkin()
    if _G.TestGPHFrame and _G.TestGPHFrame.ApplySkin then _G.TestGPHFrame.ApplySkin() end
    if _G.TestBankFrame and _G.TestBankFrame.ApplySkin then _G.TestBankFrame.ApplySkin() end
    if _G.TestAddon and _G.TestAddon.ApplyStackSplitSkin then _G.TestAddon.ApplyStackSplitSkin() end
    -- Instance Tracker uses its own skin (fitSkin) and Escape menu; not tied to BAGS skin.
end

----------------------------------------------------------------------
-- Loader: keybind, bag hook, options panel (runs on ADDON_LOADED)
----------------------------------------------------------------------
local keybindOwner
local function ApplyBagKeyOverride()
    if not keybindOwner then
        keybindOwner = CreateFrame("Frame", "FugaziBAGSKeybindOwner", UIParent)
    end
    if not _G.FugaziBAGSBagKeyButton then
        local btn = CreateFrame("Button", "FugaziBAGSBagKeyButton", keybindOwner, "SecureActionButtonTemplate")
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", "/run ToggleGPHFrame()")
        btn:SetSize(1, 1)
        btn:SetPoint("BOTTOMLEFT", keybindOwner, "BOTTOMLEFT", -10000, -10000)
    end
    if ClearOverrideBindings then ClearOverrideBindings(keybindOwner) end
    local keys = {}
    for _, action in next, { "TOGGLEBACKPACK", "OPENALLBAGS" } do
        local k = GetBindingKey and GetBindingKey(action)
        if k and k ~= "" then keys[k] = true end
    end
    if next(keys) == nil then keys["B"] = true end
    for key, _ in pairs(keys) do
        if SetOverrideBindingClick then
            SetOverrideBindingClick(keybindOwner, true, key, "FugaziBAGSBagKeyButton", "LeftButton")
        end
    end
end

local function BagKeyHandler()
    if CloseAllBags then CloseAllBags() end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
end
local origToggleBackpack, origOpenAllBags
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

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    sub:SetText("Skin for inventory and bank windows:")

    local dropdown = CreateFrame("Frame", "FugaziBAGSOptionsSkinDropdown", panel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -8)
    dropdown:SetScale(1)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dropdown, 180) end

    local function SkinMenu_Initialize(_, level)
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
                    if SV then SV.gphSkin = opt.value end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, opt.text) end
                    if _G.ApplyTestSkin then _G.ApplyTestSkin() end
                end
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end

    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(dropdown, SkinMenu_Initialize) end

    -- Copy auto-destroy list from another character (per-character destroy list).
    local copyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    copyLabel:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 16, -24)
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
            dst[id] = { name = v.name, texture = v.texture }
            count = count + 1
        end

        -- Warm the current character's destroy list cache and refresh UI so the list appears immediately.
        if Addon and Addon.GetGphDestroyList then
            Addon.GetGphDestroyList()
        end
        if RefreshGPHUI then
            RefreshGPHUI()
        end
        print("|cff00aaff[__FugaziBAGS]|r Copied |cffffff00" .. tostring(count) .. "|r auto-destroy entries from |cffffff00" .. tostring(gphDestroyCopySourceKey) .. "|r to this character.")
    end)

    panel.refresh = function()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        local val = SV.gphSkin or "original"
        if val ~= "original" and val ~= "elvui" and val ~= "elvui_real" and val ~= "pimp_purple" then
            val = "original"
        end
        local text
        if val == "elvui" then
            text = "Elvui (Ebonhold)"
        elseif val == "elvui_real" then
            text = "ElvUI"
        elseif val == "pimp_purple" then
            text = "Pimp Purple"
        else
            text = "Original"
        end
        if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, val) end
        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, text) end
        if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(dropdown, nil, 1) end
    end

    panel.okay = function()
        if _G.ApplyTestSkin then _G.ApplyTestSkin() end
    end

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

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
                info.checked = ((_G.FugaziBAGSDB and _G.FugaziBAGSDB.fitSkin) or "original") == opt.value
                info.func = function()
                    local SV = _G.FugaziBAGSDB
                    if SV then SV.fitSkin = opt.value end
                    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(dropdown, opt.value) end
                    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dropdown, opt.text) end
                    if _G.InstanceTrackerFrame and _G.InstanceTrackerFrame.ApplySkin then _G.InstanceTrackerFrame:ApplySkin() end
                    if _G.InstanceTrackerStatsFrame and _G.InstanceTrackerStatsFrame.ApplySkin then _G.InstanceTrackerStatsFrame:ApplySkin() end
                end
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end
    end

    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(dropdown, FitSkinMenu_Initialize) end

    panel.refresh = function()
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        local val = SV.fitSkin or "original"
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

local addonLoaderDone = false
local function RunAddonLoader()
    if addonLoaderDone then return end
    addonLoaderDone = true
    CreateOptionsPanel()
    CreateInstanceTrackerOptionsPanel()
    InstallBagHook()
    ApplyBagKeyOverride()
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
				bagQualities[bagSlot] = quality or 0
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

	local function PrimarySort(a, b)
		local _, _, _, aLvl, _, _, _, _, _, _, aPrice = GetItemInfo(bagIDs[a])
		local _, _, _, bLvl, _, _, _, _, _, _, bPrice = GetItemInfo(bagIDs[b])
		if aLvl ~= bLvl and aLvl and bLvl then return aLvl > bLvl end
		if aPrice ~= bPrice and aPrice and bPrice then return aPrice > bPrice end
		local aName = GetItemInfo(bagIDs[a])
		local bName = GetItemInfo(bagIDs[b])
		if aName and bName then return aName < bName end
		return false
	end

	local function DefaultSort(a, b)
		local aID, bID = bagIDs[a], bagIDs[b]
		if (not aID) or (not bID) then return aID end
		local aOrder, bOrder = initialOrder[a] or 0, initialOrder[b] or 0
		if aID == bID then
			local ac, bc = bagStacks[a] or 0, bagStacks[b] or 0
			if ac == bc then return aOrder < bOrder end
			return ac < bc
		end
		local _, _, _, _, _, aType, aSubType, _, aEquipLoc = GetItemInfo(aID)
		local _, _, _, _, _, bType, bSubType, _, bEquipLoc = GetItemInfo(bID)
		local aRarity, bRarity = bagQualities[a] or 0, bagQualities[b] or 0
		if aRarity ~= bRarity then return aRarity > bRarity end
		if (itemTypes[aType] or 99) ~= (itemTypes[bType] or 99) then
			return (itemTypes[aType] or 99) < (itemTypes[bType] or 99)
		end
		local aSub = (itemSubTypes[aType] and itemSubTypes[aType][aSubType]) or 99
		local bSub = (itemSubTypes[bType] and itemSubTypes[bType][bSubType]) or 99
		if aSub ~= bSub then return aSub < bSub end
		return PrimarySort(a, b)
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

	-- Sort: desired order then generate moves (ElvUI B.Sort, no blacklist)
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
		local passNeeded = true
		while passNeeded do
			passNeeded = false
			local idx = 0
			for _, bag, slot in IterateBags(currentBagList, false) do
				local destination = Encode(bag, slot)
				if bagIDs[destination] then
					idx = idx + 1
					local source = bagSorted[idx]
					if source and ShouldMove(source, destination) then
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

--- Realm#Character key for per-char DB.
local function GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
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
    local protectedSet = Addon.GetGphProtectedSet and Addon.GetGphProtectedSet() or {}
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags() or {}
    if protectedSet[itemId] then return true end
    if rarityFlags[quality or 0] then return true end
    if Addon.GetGphPreviouslyWornOnlySet then
        local prevOnly = Addon.GetGphPreviouslyWornOnlySet()
        if prevOnly and prevOnly[itemId] then return true end
    end
    return false
end

local function FindNextFromBags(rarity)
    for bag = 0, 4 do
        local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemId = GetContainerItemID and GetContainerItemID(bag, slot)
            if itemId then
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

local function FindNextFromBank(rarity)
    -- Scan all known bank containers for the next non-protected item of this rarity.
    local function scanBag(bagID)
        if not bagID then return nil, nil end
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
        if not numSlots or numSlots <= 0 then return nil, nil end
        for slot = 1, numSlots do
            local itemId = GetContainerItemID and GetContainerItemID(bagID, slot)
            if itemId then
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
    if self._t < 0.05 then return end
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
        Addon.RarityMoveJob = nil
        self:Hide()
        return
    end

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

--- Create the GPH window (timer, items list, sort). Starts hidden.
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
            if f.HideGPHUseOverlay then f.HideGPHUseOverlay(f) end
        end
        f:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
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
        if f.gphTitle then ApplyGphInventoryTitle(f.gphTitle) end
        if f.UpdateGPHProfessionButtons then f:UpdateGPHProfessionButtons() end
        f.gphScrollToDefaultOnNextRefresh = true
        local defer = CreateFrame("Frame")
        defer:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            if RefreshGPHUI then RefreshGPHUI() end
        end)
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
        if not Addon.gphPendingQuality then return end
        local hadPending = false
        for q in pairs(Addon.gphPendingQuality) do
            Addon.gphPendingQuality[q] = nil
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
    -- Title: same template as bank (GameFontNormalLarge). Color re-applied with delays to override client gold reset.
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    ApplyGphInventoryTitle(title)
    f.gphTitle = title

    local GPH_BTN_W, GPH_BTN_H = 36, 18
    local GPH_BTN_GAP = 2

    -- Autosell toggle only (Blizzard bags always hidden when addon is on)
    local invBtn = CreateFrame("Button", nil, titleBar)
    invBtn:EnableMouse(true)
    invBtn:SetHitRectInsets(0, 0, 0, 0)
    invBtn:SetSize(22, GPH_BTN_H)
    invBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    local invBg = invBtn:CreateTexture(nil, "BACKGROUND")
    invBg:SetAllPoints()
    invBtn.bg = invBg
    local GPH_ICON_SZ = 16
    local invIcon = invBtn:CreateTexture(nil, "ARTWORK")
    invIcon:SetWidth(GPH_ICON_SZ)
    invIcon:SetHeight(GPH_ICON_SZ)
    invIcon:SetPoint("CENTER")
    invIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    invBtn.icon = invIcon
    f.gphInvBtn = invBtn
    invBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function UpdateInvBtn()
        if Addon.GphIsGoblinMerchantSummoned() then
            invBtn.icon:SetTexture("Interface\\Icons\\achievement_goblinhead")
        else
            invBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        end
        local on = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphAutoVendor
        if on then
            invBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7)  -- green when ON
        else
            invBtn.bg:SetTexture(0.45, 0.12, 0.1, 0.7)  -- red when OFF
        end
    end
    local function ShowInvTooltip()
        GameTooltip:SetOwner(invBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        local on = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphAutoVendor
        GameTooltip:AddLine("Autoselling: " .. (on and "|cff44ff44ON|r" or "|cffff4444OFF|r"), 0.9, 0.8, 0.5)
        GameTooltip:AddLine("LMB: Toggle autoselling", 0.6, 0.6, 0.5)
        GameTooltip:AddLine("RMB: Summon Goblin Merchant", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    -- Only this button and GPH_AUTOSELL_CONFIRM may change gphAutoVendor. B key only toggles frame.
    invBtn:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            if Addon.GphIsGoblinMerchantSummoned() then
                Addon.GphDismissCurrentCompanion()
            end
            Addon.DoGphSummonGoblinMerchantNow()
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            if GameTooltip:GetOwner() == invBtn then ShowInvTooltip() end
            return
        end
        local SV = _G.FugaziBAGSDB
        if not SV then return end
        if SV.gphAutoVendor then
            SV.gphAutoVendor = false
            UpdateInvBtn()
        else
            StaticPopup_Show("GPH_AUTOSELL_CONFIRM")
        end
        if GameTooltip:GetOwner() == invBtn then ShowInvTooltip() end
    end)
    invBtn:SetScript("OnEnter", function()
        invBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.8)
        ShowInvTooltip()
    end)
    invBtn:SetScript("OnLeave", function() UpdateInvBtn(); GameTooltip:Hide() end)
    UpdateInvBtn()
    f.UpdateInvBtn = UpdateInvBtn  -- so GPH_AUTOSELL_CONFIRM popup can refresh the button after turning autosell ON

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

    -- Proxy frame: syncs visibility with f for non-secure open (e.g. /gph); keybind in combat toggles f directly via ref.
    local proxy = CreateFrame("Frame", nil, UIParent)
    proxy:SetSize(1, 1)
    proxy:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    proxy:Hide()
    proxy:SetScript("OnShow", function() f:Show() end)
    proxy:SetScript("OnHide", function() f:Hide() end)
    f.gphProxyFrame = proxy

    -- SecureHandlerClickTemplate: ref points at main frame f (not proxy) so handle stays valid in combat; proxy ref was Invalid frame handle.
    local combatToggleOk, combatToggleBtn = pcall(CreateFrame, "Button", "InstanceTrackerGPHCombatToggleBtn", keybindOwner, "SecureHandlerClickTemplate")
    if combatToggleOk and combatToggleBtn then
        combatToggleBtn:SetSize(1, 1)
        combatToggleBtn:SetPoint("BOTTOMLEFT", keybindOwner, "BOTTOMLEFT", -10000, -10000)
        combatToggleBtn:Hide()
        combatToggleBtn:SetAttribute("_onclick", [=[
            local gph = self:GetFrameRef("GPHFrame")
            if gph then
                if gph:IsShown() then gph:Hide() else gph:Show() end
            end
        ]=])
        if SecureHandlerSetFrameRef then
            SecureHandlerSetFrameRef(combatToggleBtn, "GPHFrame", f)
        end
        f.gphCombatToggleBtn = combatToggleBtn
        if DB.gphInvKeybind and f.gphInvKeybindBtn then
            Addon.ApplyGPHInvKeyOverride(f.gphInvKeybindBtn)
        end
    end

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
    if DB.gphCollapsed == nil then DB.gphCollapsed = false end
    -- Set textures immediately so button is visible before scrollFrame exists (UpdateGPHCollapse returns early until then)
    local isPimpPurpleCollapse = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin == "pimp_purple")
    if DB.gphCollapsed then
        if not isPimpPurpleCollapse then
            if f.gphCollapseBtnBright then collapseBg:SetTexture(unpack(f.gphCollapseBtnBright)) else collapseBg:SetTexture(0.15, 0.4, 0.2, 0.8) end
        else
            collapseBg:SetTexture(nil)
        end
        collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
    else
        if not isPimpPurpleCollapse then
            if f.gphCollapseBtnDim then collapseBg:SetTexture(unpack(f.gphCollapseBtnDim)) else collapseBg:SetTexture(0.1, 0.3, 0.15, 0.7) end
        else
            collapseBg:SetTexture(nil)
        end
        collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
    end
    local function UpdateGPHCollapse()
        if not f.scrollFrame then return end
        local inCombat = InCombatLockdown and InCombatLockdown()
        if f.gphCollapseBtn then
            f.gphCollapseBtn:Show()
            f.gphCollapseBtn:SetFrameLevel(f:GetFrameLevel() + 50)
        end
        local isPimpPurpleCollapse = (_G.FugaziBAGSDB and _G.FugaziBAGSDB.gphSkin == "pimp_purple")
        if DB.gphCollapsed then
            if not isPimpPurpleCollapse then
                if f.gphCollapseBtnBright then collapseBg:SetTexture(unpack(f.gphCollapseBtnBright)) else collapseBg:SetTexture(0.15, 0.4, 0.2, 0.8) end
            else
                collapseBg:SetTexture(nil)
            end
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            local collH = DB.gphDockedToMain and 150 or 70
            if not inCombat then
                if f.gphHeader then f.gphHeader:Hide() end
                f.scrollFrame:Hide()
                f.gphForceHeight = collH
                f.gphForceHeightFrames = 8
                local w = f:GetWidth() or 340
                f:SetSize(w, collH)
            else
                f.gphCollapseResizePending = true
            end
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
            if not isPimpPurpleCollapse then
                if f.gphCollapseBtnDim then collapseBg:SetTexture(unpack(f.gphCollapseBtnDim)) else collapseBg:SetTexture(0.1, 0.3, 0.15, 0.7) end
            else
                collapseBg:SetTexture(nil)
            end
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            if not inCombat then
                f.gphForceHeight = f.EXPANDED_HEIGHT
                f.gphForceHeightFrames = 8
                local w = f:GetWidth() or 340
                f:SetSize(w, f.EXPANDED_HEIGHT)
            else
                f.gphCollapseResizePending = true
            end
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
    f.UpdateGPHCollapse = UpdateGPHCollapse
    UpdateGPHCollapse()
    local function ShowCollapseTooltip()
        GameTooltip:SetOwner(collapseBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(DB.gphCollapsed and "Expand" or "Collapse", 0.5, 0.8, 1)
        if InCombatLockdown and InCombatLockdown() then
            GameTooltip:AddLine("Unavailable in combat", 0.6, 0.5, 0.5)
        end
        GameTooltip:Show()
    end
    collapseBtn:SetScript("OnClick", function()
        if InCombatLockdown and InCombatLockdown() then return end
        DB.gphCollapsed = not DB.gphCollapsed
        UpdateGPHCollapse()
        f._refreshImmediate = true
        RefreshGPHUI()
        if GameTooltip:GetOwner() == collapseBtn then ShowCollapseTooltip() end
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        if f.gphTitleBarBtnHover then self.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else self.bg:SetTexture(0.5, 0.4, 0.15, 0.8) end
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
    sortBtnBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    sortBtn.bg = sortBtnBg
    local sortIcon = sortBtn:CreateTexture(nil, "ARTWORK")
    sortIcon:SetPoint("CENTER")
    sortIcon:SetSize(GPH_ICON_SZ, GPH_ICON_SZ)
    sortBtn.icon = sortIcon
    f.gphSortBtn = sortBtn
    local function UpdateGPHSortIcon()
        if DB.gphSortMode == nil then DB.gphSortMode = "rarity" end
        if DB.gphSortMode ~= "vendor" and DB.gphSortMode ~= "rarity" and DB.gphSortMode ~= "itemlevel" and DB.gphSortMode ~= "category" then
            DB.gphSortMode = "rarity"
        end
        if DB.gphSortMode == "vendor" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        elseif DB.gphSortMode == "itemlevel" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
        elseif DB.gphSortMode == "category" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Chest_Chain_04")
        else
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01")
        end
    end
    UpdateGPHSortIcon()
    local function RunBagSort()
        -- Built-in stack consolidate + sort (ElvUI-style); player bags only.
        if GPH_BagSort_Run then
            GPH_BagSort_Run(RefreshGPHUI)
            return true
        end
        return false
    end
    local function ShowSortTooltip(btn)
        btn = btn or sortBtn
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        local mode = DB.gphSortMode or "rarity"
        if mode == "vendor" then
            GameTooltip:AddLine("Vendorprice", 0.7, 0.8, 1)
        elseif mode == "itemlevel" then
            GameTooltip:AddLine("ItemLvl", 0.7, 0.8, 1)
        elseif mode == "category" then
            GameTooltip:AddLine("Category (Weapon, Armor, etc.)", 0.7, 0.8, 1)
        else
            GameTooltip:AddLine("Rarity", 0.7, 0.8, 1)
        end
        GameTooltip:AddLine("Shift+Click: sort bags / consolidate stacks", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end
    sortBtn:SetScript("OnClick", function(_, button)
        if IsShiftKeyDown() then
            if RunBagSort() then
                -- List refreshes via GPH_BagSort_Run callback when sort finishes
            end
            if GameTooltip:GetOwner() == sortBtn then ShowSortTooltip(sortBtn) end
            return
        end
        local mode = DB.gphSortMode or "rarity"
        if mode == "rarity" then
            DB.gphSortMode = "vendor"
        elseif mode == "vendor" then
            DB.gphSortMode = "itemlevel"
        elseif mode == "itemlevel" then
            DB.gphSortMode = "category"
        else
            DB.gphSortMode = "rarity"
        end
        UpdateGPHSortIcon()
        if gphFrame then gphFrame._refreshImmediate = true end
        RefreshGPHUI()
        if GameTooltip:GetOwner() == sortBtn then ShowSortTooltip(sortBtn) end
    end)
    sortBtn:SetScript("OnEnter", function(self)
        if f.gphTitleBarBtnHover then self.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else self.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        ShowSortTooltip(self)
    end)
    sortBtn:SetScript("OnLeave", function()
        UpdateGPHSortIcon()
        if f.gphTitleBarBtnNormal then sortBtn.bg:SetTexture(unpack(f.gphTitleBarBtnNormal)) else sortBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7) end
        GameTooltip:Hide()
    end)

    -- Scale ×1.5: magnifying glass icon
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
        local SV = _G.FugaziBAGSDB
        local scale15 = SV and SV.gphScale15
        local skin = SV and SV.gphSkin or "original"
        if skin == "pimp_purple" then
            -- Pimp Purple: no background texture for scale button, only change frame scale.
            scaleBtn.bg:SetTexture(nil)
            if scale15 then
                f:SetScale(1.5)
            else
                f:SetScale(1)
            end
            return
        end
        if scale15 then
            if f.gphScaleBtnBright then scaleBtn.bg:SetTexture(unpack(f.gphScaleBtnBright)) else scaleBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
            f:SetScale(1.5)
        else
            if f.gphScaleBtnDim then scaleBtn.bg:SetTexture(unpack(f.gphScaleBtnDim)) else scaleBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7) end
            f:SetScale(1)
        end
    end
    local function ShowScaleTooltip()
        local SV = _G.FugaziBAGSDB
        local scale15 = SV and SV.gphScale15
        GameTooltip:SetOwner(scaleBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(scale15 and "Scale 1.5× (on)" or "Scale 1.5× (off)", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("Click to toggle", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end
    scaleBtn:SetScript("OnClick", function()
        local SV = _G.FugaziBAGSDB
        if not SV then SV = {}; _G.FugaziBAGSDB = SV end
        SV.gphScale15 = not SV.gphScale15
        UpdateScaleBtn()
        local bf = _G.TestBankFrame
        if bf and bf:IsShown() then
            bf:SetScale(bf:GetParent() == f and 1 or f:GetScale())
        end
        if GameTooltip:GetOwner() == scaleBtn then ShowScaleTooltip() end
    end)
    scaleBtn:SetScript("OnEnter", function()
        local SV = _G.FugaziBAGSDB
        local skin = SV and SV.gphSkin or "original"
        if skin ~= "pimp_purple" then
            if f.gphTitleBarBtnHover then scaleBtn.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else scaleBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
        else
            scaleBtn.bg:SetTexture(nil)
        end
        ShowScaleTooltip()
    end)
    scaleBtn:SetScript("OnLeave", function() UpdateScaleBtn(); GameTooltip:Hide() end)
    UpdateScaleBtn()

    -- GPH Vendor (pet): leftmost of the four; order will be pet, magnifier, bag, enchant.
    if DB.gphSummonGreedy == nil then DB.gphSummonGreedy = true end
    local sumBtn = CreateFrame("Button", nil, titleBar)
    sumBtn:EnableMouse(true)
    sumBtn:SetHitRectInsets(0, 0, 0, 0)
    sumBtn:SetSize(22, GPH_BTN_H)
    sumBtn:SetPoint("LEFT", scaleBtn, "RIGHT", GPH_BTN_GAP, 0)  -- layout repositions to sumBtn left of invBtn in UpdateGphTitleBarButtonLayout
    local sumBg = sumBtn:CreateTexture(nil, "BACKGROUND")
    sumBg:SetAllPoints()
    sumBtn.bg = sumBg
    local sumIcon = sumBtn:CreateTexture(nil, "ARTWORK")
    sumIcon:SetPoint("CENTER")
    sumIcon:SetSize(GPH_ICON_SZ, GPH_ICON_SZ)
    sumBtn.icon = sumIcon
    f.gphSummonBtn = sumBtn
    local function UpdateGphSummonBtn()
        local on = DB.gphSummonGreedy ~= false
        if on then
            sumBg:SetTexture(0.1, 0.3, 0.15, 0.7)  -- green when ON
            sumIcon:SetVertexColor(1, 1, 1)
            sumIcon:SetTexture("Interface\\Icons\\inv_harvestgolempet")
        else
            sumBg:SetTexture(0.45, 0.12, 0.1, 0.7)  -- red when OFF
            sumIcon:SetVertexColor(1, 0.85, 0.85)
            sumIcon:SetTexture("Interface\\Icons\\inv_harvestgolempet")
        end
        -- Goblin state shows on autosell button (invBtn), not on this pet button
        if f.gphInvBtn and f.gphInvBtn.icon then
            if Addon.GphIsGoblinMerchantSummoned() then
                f.gphInvBtn.icon:SetTexture("Interface\\Icons\\achievement_goblinhead")
            else
                f.gphInvBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
            end
        end
    end
    sumBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    sumBtn:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            -- Always resummon Greedy: if already out, dismiss then summon so spamming RMB resummons (pet catches up when it lags)
            if Addon.GphIsGreedySummoned() then
                Addon.GphDismissCurrentCompanion()
            end
            Addon.DoGphSummonGreedyNow()
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
            return
        end
        -- LeftButton: toggle auto-summon
        DB.gphSummonGreedy = DB.gphSummonGreedy == false
        UpdateGphSummonBtn()
        if DB.gphSummonGreedy ~= false and not Addon.GphIsGreedySummoned() then
            Addon.DoGphSummonGreedyNow()
        end
    end)
    local function ShowGphSummonTooltip()
        GameTooltip:SetOwner(sumBtn, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("LMB: AutoSummon " .. (DB.gphSummonGreedy ~= false and "(on)" or "(off)"), 0.9, 0.8, 0.5)
        GameTooltip:AddLine("RMB: Summon Pet", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    sumBtn:SetScript("OnEnter", function()
        sumBg:SetTexture(0.15, 0.4, 0.2, 0.8)
        ShowGphSummonTooltip()
    end)
    sumBtn:SetScript("OnLeave", function() UpdateGphSummonBtn(); GameTooltip:Hide() end)
    sumBtn:SetScript("OnUpdate", function(self)
        if GameTooltip:GetOwner() == self then ShowGphSummonTooltip() end
    end)
    f.UpdateGphSummonBtn = UpdateGphSummonBtn
    UpdateGphSummonBtn()

    -- Left-to-right: (greedy) (autosell) (scale) (prospecting when has DE/Prospect). Hide pet button and shift others left when player doesn't have Greedy.
    local function UpdateGphTitleBarButtonLayout()
        local hasGreedy = Addon.GphPlayerHasGreedyCompanion()
        if hasGreedy then
            sumBtn:Show()
            sumBtn:ClearAllPoints()
            sumBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
            invBtn:ClearAllPoints()
            invBtn:SetPoint("LEFT", sumBtn, "RIGHT", GPH_BTN_GAP, 0)
        else
            sumBtn:Hide()
            invBtn:ClearAllPoints()
            invBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
        end
        scaleBtn:ClearAllPoints()
        scaleBtn:SetPoint("LEFT", invBtn, "RIGHT", GPH_BTN_GAP, 0)
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
        local SV = _G.FugaziBAGSDB
        local skinVal = SV and SV.gphSkin or "original"
        local useTitleBarColor = (skinVal == "elvui_real") and f.gphTitleBarBtnNormal
        if gphSession then
            if useTitleBarColor then
                toggleBtn.bg:SetTexture(unpack(useTitleBarColor))
            else
                toggleBtn.bg:SetTexture(0.3, 0.15, 0.1, 0.7)
            end
            toggleBtn.icon:SetTexture(GPH_STOP_TEXTURE)
            resetBtn:Show()
        else
            if useTitleBarColor then
                toggleBtn.bg:SetTexture(unpack(useTitleBarColor))
            else
                toggleBtn.bg:SetTexture(0.1, 0.3, 0.15, 0.7)
            end
            toggleBtn.icon:SetTexture(GPH_PLAY_TEXTURE)
            resetBtn:Hide()
        end
    end
    f.updateToggle = UpdateToggleBtn
    UpdateToggleBtn()
    toggleBtn:SetScript("OnClick", function()
        -- When stopping a GPH session and the Instance Tracker addon is enabled,
        -- mirror this session into the InstanceTracker run ledger (same data shape
        -- as the original built-in GPH window used).
        local hadSession = gphSession ~= nil
        local snapshot = nil
        if hadSession and _G.FugaziInstanceTracker_RecordGPHRun and DB and DB.gphSession then
            local sess = DB.gphSession
            if type(sess) == "table" and sess.startTime and sess.startGold and type(sess.items) == "table" then
                local now = time and time() or nil
                local startTime = sess.startTime
                local startGold = sess.startGold or 0
                local curGold = (GetMoney and GetMoney()) or 0
                local goldEarned = curGold - startGold
                if goldEarned < 0 then goldEarned = 0 end
                local itemList = {}
                for _, item in pairs(sess.items) do
                    table.insert(itemList, {
                        link = item.link,
                        quality = item.quality,
                        count = item.count,
                        name = item.name,
                    })
                end
                table.sort(itemList, function(a, b)
                    if a.quality ~= b.quality then return (a.quality or 0) > (b.quality or 0) end
                    return (a.name or "") < (b.name or "")
                end)
                local anythingGained = (goldEarned > 0) or (#itemList > 0)
                if anythingGained and now then
                    snapshot = {
                        startTime = startTime,
                        endTime = now,
                        startGold = startGold,
                        goldEarned = goldEarned,
                        itemList = itemList,
                        qualityCounts = sess.qualityCounts or {},
                    }
                end
            end
        end

        if gphSession then
            Addon.StopGPHSession()
        else
            Addon.StartGPHSession()
        end

        if snapshot and _G.FugaziInstanceTracker_RecordGPHRun then
            _G.FugaziInstanceTracker_RecordGPHRun(
                snapshot.startTime,
                snapshot.endTime,
                snapshot.startGold,
                snapshot.goldEarned,
                snapshot.itemList,
                snapshot.qualityCounts
            )
        end

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
        local SV = _G.FugaziBAGSDB
        local skinVal = SV and SV.gphSkin or "original"
        local hoverColor = (skinVal == "elvui_real") and f.gphTitleBarBtnHover
        if hoverColor then
            self.bg:SetTexture(unpack(hoverColor))
        elseif gphSession then
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
    if DB.gphDestroyPreferProspect == nil then DB.gphDestroyPreferProspect = false end

    local destroyBtn = CreateFrame("Button", nil, f, "SecureActionButtonTemplate")
    destroyBtn:SetSize(22, GPH_BTN_H)
    destroyBtn:SetPoint("LEFT", scaleBtn, "RIGHT", GPH_BTN_GAP, 0)
    destroyBtn:SetFrameLevel((f:GetFrameLevel() or 0) + 20)
    destroyBtn:EnableMouse(true)
    destroyBtn:SetHitRectInsets(0, 0, 0, 0)
    destroyBtn:RegisterForClicks("AnyUp")
    destroyBtn:SetAttribute("type1", "macro")
    destroyBtn:SetAttribute("macrotext1", "")
    local destroyBg = destroyBtn:CreateTexture(nil, "BACKGROUND")
    destroyBg:SetAllPoints()
    destroyBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    destroyBtn.bg = destroyBg
    local destroyIcon = destroyBtn:CreateTexture(nil, "ARTWORK")
    destroyIcon:SetWidth(GPH_ICON_SZ - 1)
    destroyIcon:SetHeight(GPH_ICON_SZ - 1)
    destroyIcon:SetPoint("CENTER")
    destroyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    destroyIcon:SetAlpha(0.9)
    destroyBtn.icon = destroyIcon
    local function UpdateDestroyButtonAppearance()
        local hasDE = Addon.IsSpellKnownByName("Disenchant")
        local hasProspect = Addon.IsSpellKnownByName("Prospecting")
        local preferProspect = DB.gphDestroyPreferProspect and hasProspect and hasDE
        local iconPath
        if preferProspect or (hasProspect and not hasDE) then
            local _, _, icon = GetSpellInfo(Addon.GPH_SPELL_IDS.Prospecting)
            iconPath = icon
        elseif hasDE then
            local _, _, icon = GetSpellInfo(Addon.GPH_SPELL_IDS.Disenchant)
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
        GameTooltip:AddLine("Destroy Next (Disenchant / Prospect)", 0.9, 0.8, 0.5)
        GameTooltip:AddLine("One Click: Cast on next valid Item.", 0.7, 0.6, 1)
        GameTooltip:Show()
    end
    destroyBtn:SetScript("OnEnter", function()
        local SV = _G.FugaziBAGSDB
        local skin = SV and SV.gphSkin or "original"
        if skin ~= "pimp_purple" then
            if f.gphTitleBarBtnHover then destroyBtn.bg:SetTexture(unpack(f.gphTitleBarBtnHover)) else destroyBtn.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
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
        destroyIcon:SetAlpha(0.9)
        GameTooltip:Hide()
    end)
    f.gphDestroyBtn = destroyBtn
    f.UpdateDestroyButtonAppearance = UpdateDestroyButtonAppearance
    f.UpdateDestroyMacro = function() end

    local function UpdateGPHProfessionButtons()
        local hasProspect = Addon.IsSpellKnownByName("Prospecting")
        local hasDE = Addon.IsSpellKnownByName("Disenchant")
        if hasProspect or hasDE then
            f.gphDestroyBtn:Show()
            f.gphDestroyBtn:SetPoint("LEFT", f.gphScaleBtn, "RIGHT", GPH_BTN_GAP, 0)
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
    gphSearchBtnBg:SetTexture(0.1, 0.3, 0.15, 0.7)
    gphSearchBtn.bg = gphSearchBtnBg
    local gphSearchLabel = gphSearchBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gphSearchLabel:SetPoint("CENTER")
    gphSearchLabel:SetText("Search")
    gphSearchLabel:SetTextColor(1, 0.85, 0.4, 1)
    f.gphSearchBtn = gphSearchBtn
    f.gphSearchLabel = gphSearchLabel
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
    gphSearchBtn:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        if parent.gphSearchBtnHover then self.bg:SetTexture(unpack(parent.gphSearchBtnHover))
        else self.bg:SetTexture(0.15, 0.4, 0.2, 0.8) end
    end)
    gphSearchBtn:SetScript("OnLeave", function(self)
        local parent = self:GetParent()
        if parent.gphSearchBtnNormal then self.bg:SetTexture(unpack(parent.gphSearchBtnNormal))
        else self.bg:SetTexture(0.1, 0.3, 0.15, 0.7) end
    end)

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

    -- Fixed header (bag + rarity row); same horizontal bounds as sep (left and right anchored to sep).
    local gphHeader = CreateFrame("Frame", nil, f)
    gphHeader:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    gphHeader:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT", 0, -4)
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
    local bagSpaceFs = gphBagSpaceBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bagSpaceFs:SetPoint("CENTER")
    bagSpaceFs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
    bagSpaceFs:SetTextColor(1, 0.85, 0.4, 1)
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
            -- Ctrl+Click: toggle custom inventory bag row + keyring row inside __FugaziBAGS
            if f.invBagRow then
                f.invBagRowVisible = not f.invBagRowVisible
                local h = f.invBagRowVisible and 24 or 0
                f.invBagRow:SetHeight(h)
                f.invBagRow:SetAlpha(f.invBagRowVisible and 1 or 0)
                if f.invBagRowVisible then f.invBagRow:Show() else f.invBagRow:Hide() end
            end
            return
        end
        if button ~= "LeftButton" then return end
        if GetCursorInfo and GetCursorInfo() == "item" then
            placeCursorInFirstFreeSlot()
        end
    end)
    gphBagSpaceBtn:SetScript("OnEnter", function(self)
        if GetCursorInfo and GetCursorInfo() == "item" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Drop to place in first free bag slot")
            GameTooltip:Show()
        else
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Bag space (drag items here to place in first free slot)")
            GameTooltip:AddLine("Ctrl+Click: Toggle default bag bar + keyring.", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end
    end)
    gphBagSpaceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.gphBagSpaceBtn = gphBagSpaceBtn

    -- Inventory bag row (custom bag bar + keyring) toggled by Ctrl+Click on bag space button.
    local invBagRow = CreateFrame("Frame", nil, f)
    -- Anchor just below the whole inventory frame so the row appears beneath it.
    invBagRow:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 6, -4)
    invBagRow:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -6, -4)
    invBagRow:SetHeight(0)
    invBagRow:SetFrameLevel(f:GetFrameLevel() + 30)
    invBagRow:EnableMouse(false)
    invBagRow:SetAlpha(0)
    invBagRow:Hide()
    f.invBagRow = invBagRow
    f.invBagRowVisible = false

    local function CreateInvBagButton(index, bagID, label, iconTexture)
        local btn = CreateFrame("Button", ("FugaziInvBag%d"):format(index), invBagRow)
        btn:SetSize(20, 20)
        btn:SetPoint("LEFT", invBagRow, "LEFT", (index - 1) * 22, 0)
        btn:SetFrameLevel(invBagRow:GetFrameLevel() + 1)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0.05, 0.05, 0.05, 0.9)
        btn.bg = bg
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("CENTER")
        icon:SetSize(18, 18)
        if iconTexture then
            icon:SetTexture(iconTexture)
        else
            if ContainerIDToInventoryID and GetInventoryItemTexture then
                local invID = ContainerIDToInventoryID(bagID)
                if invID then
                    local tex = GetInventoryItemTexture("player", invID)
                    if tex then icon:SetTexture(tex) end
                end
            end
        end
        btn.icon = icon
        btn.bagID = bagID
        btn:SetScript("OnClick", function(self, button)
            if self.bagID == -2 then
                -- Our own embedded keyring under the FugaziBAGS inventory.
                if f.ToggleKeyringFrame then
                    f:ToggleKeyringFrame()
                end
            else
                if ToggleBag then
                    ToggleBag(self.bagID)
                end
            end
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label or "Bag")
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return btn
    end

    -- Backpack (0) + 4 bag slots (1-4)
    f.invBagButtons = {}
    f.invBagButtons[1] = CreateInvBagButton(1, 0, "Backpack", "Interface\\Buttons\\Button-Backpack-Up")
    for i = 1, (NUM_BAG_SLOTS or 4) do
        f.invBagButtons[i + 1] = CreateInvBagButton(i + 1, i, ("Bag %d"):format(i), nil)
    end
    -- Keyring (-2) at the end (opens our embedded keyring frame)
    f.invBagButtons[#f.invBagButtons + 1] = CreateInvBagButton(#f.invBagButtons + 1, -2, "Keyring", "Interface\\ContainerFrame\\KeyRing-Bag-Icon")

    -- Embedded keyring frame that shows the contents of KEYRING_CONTAINER under the FugaziBAGS inventory.
    local KEYRING_BAG = KEYRING_CONTAINER or -2
    local keyringFrame = CreateFrame("Frame", nil, f)
    keyringFrame:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 6, -28)
    keyringFrame:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -6, -28)
    keyringFrame:SetHeight(28)
    keyringFrame:Hide()
    f.keyringFrame = keyringFrame
    f.keyringButtons = {}

    local function RefreshKeyringFrame()
        if not KEYRING_BAG or not GetContainerNumSlots then return end
        local numSlots = GetContainerNumSlots(KEYRING_BAG)
        if not numSlots or numSlots <= 0 then
            for _, btn in ipairs(f.keyringButtons) do
                btn:Hide()
            end
            return
        end

        local size = 24
        local spacing = 2
        keyringFrame:SetHeight(size + 4)

        for slot = 1, numSlots do
            local btn = f.keyringButtons[slot]
            if not btn then
                btn = CreateFrame("Button", ("FugaziKeyringSlot%d"):format(slot), keyringFrame)
                btn:SetSize(size, size)
                if slot == 1 then
                    btn:SetPoint("LEFT", keyringFrame, "LEFT", 0, 0)
                else
                    btn:SetPoint("LEFT", f.keyringButtons[slot - 1], "RIGHT", spacing, 0)
                end
                local icon = btn:CreateTexture(nil, "ARTWORK")
                icon:SetAllPoints()
                btn.icon = icon
                btn:SetScript("OnClick", function(self)
                    if PickupContainerItem and KEYRING_BAG then
                        PickupContainerItem(KEYRING_BAG, self.slot)
                    end
                end)
                btn:SetScript("OnEnter", function(self)
                    if GameTooltip and KEYRING_BAG then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        if GameTooltip.SetBagItem then
                            GameTooltip:SetBagItem(KEYRING_BAG, self.slot)
                        end
                        GameTooltip:Show()
                    end
                end)
                btn:SetScript("OnLeave", function()
                    if GameTooltip then GameTooltip:Hide() end
                end)
                f.keyringButtons[slot] = btn
            end

            btn.slot = slot
            local texture, itemCount, locked, quality = GetContainerItemInfo(KEYRING_BAG, slot)
            if texture then
                btn.icon:SetTexture(texture)
                btn.icon:SetVertexColor(1, 1, 1)
                btn:Show()
            else
                btn.icon:SetTexture(nil)
                btn:Hide()
            end
        end

        -- Hide any extra buttons if the keyring shrank.
        for i = numSlots + 1, #f.keyringButtons do
            f.keyringButtons[i]:Hide()
        end
    end

    function f:ToggleKeyringFrame()
        if not self.keyringFrame then return end
        if self.keyringFrame:IsShown() then
            self.keyringFrame:Hide()
        else
            RefreshKeyringFrame()
            self.keyringFrame:Show()
        end
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

    -- Right-click use overlay: created under UIParent so when hidden it never blocks list clicks; only parent to row when showing.
    local overlayOk, overlayBtn = pcall(CreateFrame, "Button", nil, UIParent, "SecureActionButtonTemplate")
    if overlayOk and overlayBtn then
        overlayBtn:RegisterForClicks("RightButtonUp")
        overlayBtn:SetSize(0, 0)
        overlayBtn:ClearAllPoints()
        overlayBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -9999, -9999)
        overlayBtn:SetFrameStrata("BACKGROUND")
        overlayBtn:SetFrameLevel(0)
        overlayBtn:EnableMouse(false)
        overlayBtn:Hide()
        overlayBtn:SetScript("OnMouseWheel", function(self, delta)
            if scrollFrame.GPHOnMouseWheel then scrollFrame.GPHOnMouseWheel(delta) end
        end)
        overlayBtn:SetScript("OnEnter", function(self)
            local link = f.gphSelectedItemLink
            if link then
                Addon.AnchorTooltipRight(self)
                if f.gphSelectedBag ~= nil and f.gphSelectedSlot ~= nil and GameTooltip.SetBagItem then
                    GameTooltip:SetBagItem(f.gphSelectedBag, f.gphSelectedSlot)
                else
                    local lp = link:match("|H(item:[^|]+)|h") or link
                    if lp then GameTooltip:SetHyperlink(lp) end
                end
                GameTooltip:AddLine(" ")
                local id = tonumber(link:match("item:(%d+)"))
                if id and Addon.GetGphProtectedSet and Addon.GetGphProtectedSet()[id] then
                    GameTooltip:AddLine("Protected — won't be auto-sold", 0.4, 0.8, 0.4)
                    GameTooltip:AddLine(" ")
                end
                GameTooltip:AddLine("LMB: Select", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("RMB: Use (or select row, then RMB again)", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Shift+LMB: Pick up", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Shift+RMB: Link to Chat", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("CTRL+LMB: Protect Item", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        overlayBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        -- On second RMB (use): clear selection so highlight goes away after use
        overlayBtn:SetScript("PreClick", function(self)
            local fr = f
            if not fr then return end
            fr.gphSelectedItemId = nil
            fr.gphSelectedIndex = nil
            fr.gphSelectedRowBtn = nil
            fr.gphSelectedItemLink = nil
            fr.gphSelectedBag = nil
            fr.gphSelectedSlot = nil
            if fr.HideGPHUseOverlay then fr:HideGPHUseOverlay() end
            local defer = CreateFrame("Frame", nil, UIParent)
            defer:SetScript("OnUpdate", function(d)
                d:SetScript("OnUpdate", nil)
                if RefreshGPHUI then RefreshGPHUI() end
            end)
        end)
        f.gphRightClickUseOverlay = overlayBtn
        -- Helper: fully hide overlay so it never blocks list clicks (move off, low strata, no mouse).
        f.HideGPHUseOverlay = function(self)
            local fr = self or f
            if not fr.gphRightClickUseOverlay then return end
            local ov = fr.gphRightClickUseOverlay
            ov:SetParent(UIParent)
            ov:ClearAllPoints()
            ov:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -9999, -9999)
            ov:SetSize(0, 0)
            ov:SetFrameStrata("BACKGROUND")
            ov:SetFrameLevel(0)
            ov:EnableMouse(false)
            ov:Hide()
        end
    end
    f.gphSelectedTime = 0  -- time() when selected; second right-click on overlay = use (taint-free)

    f.gphSelectedItemId = nil
    f.gphSelectedItemLink = nil
    local gph_elapsed = 0
    local gph_debug_t = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        -- Enforce collapse/expand height every frame (client or template may be resetting it)
        if DB then
            local w = self:GetWidth() or 340
            local wantH
            if DB.gphCollapsed then
                wantH = DB.gphDockedToMain and 150 or 70
                self:SetSize(w, wantH)
            elseif self.EXPANDED_HEIGHT then
                wantH = self.EXPANDED_HEIGHT
                self:SetSize(w, wantH)
            end
        end
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
            if self.UpdateGphSummonBtn then self.UpdateGphSummonBtn() end
            -- In combat, BAG_UPDATE is often delayed until combat ends; poll every 1s so new loot shows up
            if InCombatLockdown and InCombatLockdown() then
                self.gphCombatRefreshElapsed = (self.gphCombatRefreshElapsed or 0) + 0.5
                if self.gphCombatRefreshElapsed >= 1 then
                    self.gphCombatRefreshElapsed = 0
                    if RefreshGPHUI then RefreshGPHUI() end
                end
            else
                self.gphCombatRefreshElapsed = 0
            end
            -- Tick timer/gold/GPH status
            if gphSession and self.gphStatusCenter then
                local dur = now - gphSession.startTime
                local liveGold = (GetMoney and GetMoney()) and (GetMoney() - gphSession.startGold) or 0
                if liveGold < 0 then liveGold = 0 end
                local gph = dur > 0 and (liveGold / (dur / 3600)) or 0
                if DB.gphCollapsed and self.gphStatusLeft and self.gphStatusRight then
                    self.gphStatusLeft:SetText("|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold))
                    self.gphStatusCenter:SetText("|cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r")
                    self.gphStatusRight:SetText("|cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph)))
                else
                    self.statusText:SetText(
                        "|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold)
                        .. "   |cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r"
                        .. "   |cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph))
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
    return f
end

----------------------------------------------------------------------
-- Bank window: ElvUI-style (grid of slots, sort, close).
----------------------------------------------------------------------
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
local BANK_HEADER_HEIGHT = 14
local BANK_DEBUG = false
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
local function ResetBankRowPool()
	for i = 1, BANK_ROW_POOL_USED do
		if BANK_ROW_POOL[i] then BANK_ROW_POOL[i]:Hide() end
	end
	BANK_ROW_POOL_USED = 0
end
local BANK_DELETE_X_WIDTH = 16
local function GetBankRow(parent)
	BANK_ROW_POOL_USED = BANK_ROW_POOL_USED + 1
	local row = BANK_ROW_POOL[BANK_ROW_POOL_USED]
	if not row then
		row = CreateFrame("Frame", nil, parent)
		row:SetWidth(BANK_LIST_WIDTH)
		row:SetHeight(BANK_ROW_HEIGHT)
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
		-- Same layout as inventory: name full width, count at right (count created after so it draws on top)
		local nameFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		nameFs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
		nameFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
		nameFs:SetJustifyH("LEFT")
		row.nameFs = nameFs
		local countFs = clickArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		countFs:SetPoint("RIGHT", clickArea, "RIGHT", -2, 0)
		countFs:SetJustifyH("RIGHT")
		row.countFs = countFs
		local hl = clickArea:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		hl:SetVertexColor(1, 1, 1, 0.1)
		row.hl = hl
		BANK_ROW_POOL[BANK_ROW_POOL_USED] = row
	end
	row:SetParent(parent)
	row:Show()
	row.clickArea:Show()
	if row.deleteBtn then row.deleteBtn:Show() end
	return row
end

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
	f:SetScript("OnDragStart", function() f:StartMoving() end)
	f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
	f:SetFrameStrata("DIALOG")
	f:SetFrameLevel(10)

	-- Title bar (same style as GPH)
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
	f.titleBar = titleBar
	local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
	title:SetText((UnitName and UnitName("target")) or "Bank")
	title:SetTextColor(1, 0.85, 0.4, 1)
	f.bankTitleText = title

	-- Keep all interactive elements above the scroll (frame level) so they receive clicks
	local titleFrameLevel = f:GetFrameLevel() + 25
	local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	closeBtn:SetFrameLevel(titleFrameLevel)
	closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
	closeBtn:SetScript("OnClick", function()
		f:Hide()
		if CloseBankFrame then CloseBankFrame() end
	end)

	-- Purchase Bags button (opens buy bank slot flow)
	local purchaseBtn = CreateFrame("Button", nil, f)
	purchaseBtn:SetFrameLevel(titleFrameLevel)
	purchaseBtn:SetSize(22, 18)
	purchaseBtn:EnableMouse(true)
	local purchaseBg = purchaseBtn:CreateTexture(nil, "BACKGROUND")
	purchaseBg:SetAllPoints()
	purchaseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
	purchaseBtn.bg = purchaseBg
	local purchaseIcon = purchaseBtn:CreateTexture(nil, "ARTWORK")
	purchaseIcon:SetSize(14, 14)
	purchaseIcon:SetPoint("CENTER")
	purchaseIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
	-- Helper: update purchase button visibility based on remaining bank slots.
	local function UpdatePurchaseButtonVisibility()
		if not purchaseBtn then return end
		if not GetNumBankSlots or not GetBankSlotCost then
			purchaseBtn:Show()
			return
		end
		local numSlots, full = GetNumBankSlots()
		-- When bank is full, many cores return full=true or cost=0; hide button in both cases.
		local cost = GetBankSlotCost()
		if full or cost == 0 then
			purchaseBtn:Hide()
		else
			purchaseBtn:Show()
		end
	end

	purchaseBtn:SetScript("OnClick", function()
		-- Prevent crash when cost is nil (MoneyFrame_Update errors)
		if not _G.FugaziBAGS_MoneyFrameUpdateSafe then
			_G.FugaziBAGS_MoneyFrameUpdateSafe = true
			local orig = MoneyFrame_Update
			if orig then
				MoneyFrame_Update = function(frameOrName, money, ...)
					if money == nil or money ~= money then money = 0 end
					return orig(frameOrName, money, ...)
				end
			end
		end
		-- No fake fallback price (would mislead if real cost is e.g. 25g). Use API only; nil -> 0 so we don't crash.
		local cost = (GetBankSlotCost and GetBankSlotCost())
		if cost == nil or cost ~= cost or cost < 0 then cost = 0 end
		-- Show dialog: prefer button (so OnAccept works), else Blizzard popup with cost
		if _G.BankFramePurchaseButton then
			_G.BankFramePurchaseButton:Click()
			-- After buying, bank slots may be full; re-evaluate visibility shortly.
			if C_Timer and C_Timer.After then
				C_Timer.After(0.2, UpdatePurchaseButtonVisibility)
			end
		elseif StaticPopup_Show then
			StaticPopup_Show("CONFIRM_BUY_BANK_SLOT", cost)
			return
		end
		-- Force money frame to show cost next frame (ElvUI/Blizzard sometimes don't display it when frame was hidden)
		if C_Timer and C_Timer.After then
			C_Timer.After(0.05, function()
				for i = 1, 4 do
					for _, prefix in ipairs({ "ElvUI_StaticPopup", "StaticPopup" }) do
						local name = prefix .. i
						local d = _G[name]
						if d and d:IsShown() then
							local mf = _G[name .. "MoneyFrame"] or (d.moneyFrame)
							if mf and MoneyFrame_Update then
								MoneyFrame_Update(mf, cost)
								return
							end
						end
					end
				end
			end)
		else
			local t = 0
			local tick = CreateFrame("Frame")
			tick:SetScript("OnUpdate", function(self, elapsed)
				t = t + elapsed
				if t < 0.05 then return end
				self:SetScript("OnUpdate", nil)
				for i = 1, 4 do
					for _, prefix in ipairs({ "ElvUI_StaticPopup", "StaticPopup" }) do
						local name = prefix .. i
						local d = _G[name]
						if d and d:IsShown() then
							local mf = _G[name .. "MoneyFrame"] or (d.moneyFrame)
							if mf and MoneyFrame_Update then
								MoneyFrame_Update(mf, cost)
								return
							end
						end
					end
				end
			end)
		end
	end)
	purchaseBtn:SetScript("OnEnter", function()
		if f.bankBtnHover then purchaseBg:SetTexture(unpack(f.bankBtnHover)) else purchaseBg:SetTexture(0.5, 0.4, 0.15, 0.8) end
		GameTooltip:SetOwner(purchaseBtn, "ANCHOR_LEFT")
		GameTooltip:SetText("Purchase bank bag slot")
		GameTooltip:Show()
	end)
	purchaseBtn:SetScript("OnLeave", function()
		if f.bankBtnNormal then purchaseBg:SetTexture(unpack(f.bankBtnNormal)) else purchaseBg:SetTexture(0.35, 0.28, 0.1, 0.7) end
		GameTooltip:Hide()
	end)
	f.purchaseBtn = purchaseBtn

	-- Initial visibility state based on current bank status.
	UpdatePurchaseButtonVisibility()

	-- Toggle Bags button (show/hide bank bag bar)
	local toggleBtn = CreateFrame("Button", nil, f)
	toggleBtn:SetFrameLevel(titleFrameLevel)
	toggleBtn:SetSize(22, 18)
	-- Toggle furthest left, then purchase, then sort next to close:
		toggleBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
	toggleBtn:EnableMouse(true)
	local toggleBg = toggleBtn:CreateTexture(nil, "BACKGROUND")
	toggleBg:SetAllPoints()
	toggleBg:SetTexture(0.35, 0.28, 0.1, 0.7)
	toggleBtn.bg = toggleBg
	local toggleIcon = toggleBtn:CreateTexture(nil, "ARTWORK")
	toggleIcon:SetSize(14, 14)
	toggleIcon:SetPoint("CENTER")
	toggleIcon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
	toggleBtn:SetScript("OnClick", function()
		if not f.bagRow or not f.scrollFrame then return end
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
		-- Do not re-anchor header or scroll: list and rarity buttons stay in the same place (fixed to sep)
		if RefreshBankUI then RefreshBankUI() end
	end)
	toggleBtn:SetScript("OnEnter", function()
		if f.bankBtnHover then toggleBg:SetTexture(unpack(f.bankBtnHover)) else toggleBg:SetTexture(0.5, 0.4, 0.15, 0.8) end
		GameTooltip:SetOwner(toggleBtn, "ANCHOR_LEFT")
		GameTooltip:SetText("Toggle bank bag bar")
		GameTooltip:Show()
	end)
	toggleBtn:SetScript("OnLeave", function()
		if f.bankBtnNormal then toggleBg:SetTexture(unpack(f.bankBtnNormal)) else toggleBg:SetTexture(0.35, 0.28, 0.1, 0.7) end
		GameTooltip:Hide()
	end)
	f.toggleBtn = toggleBtn

	local sortBtn = CreateFrame("Button", nil, f)
	sortBtn:SetFrameLevel(titleFrameLevel)
	sortBtn:SetSize(22, 18)
	sortBtn:EnableMouse(true)
	local sortBg = sortBtn:CreateTexture(nil, "BACKGROUND")
	sortBg:SetAllPoints()
	sortBg:SetTexture(0.35, 0.28, 0.1, 0.7)
	sortBtn.bg = sortBg
	local sortIcon = sortBtn:CreateTexture(nil, "ARTWORK")
	sortIcon:SetSize(16, 16)
	sortIcon:SetPoint("CENTER")
	sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01")
	f.bankSortBtn = sortBtn
	f.bankSortBtn.icon = sortIcon

	-- Final layout for title buttons (left → right: purchase, toggle, sort, close).
	-- Close button is already anchored at top-right of the frame.
	if sortBtn and closeBtn then
		sortBtn:ClearAllPoints()
		sortBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
	end
	if toggleBtn and sortBtn then
		toggleBtn:ClearAllPoints()
		toggleBtn:SetPoint("RIGHT", sortBtn, "LEFT", -2, 0)
	end
	if purchaseBtn and toggleBtn then
		purchaseBtn:ClearAllPoints()
		purchaseBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -2, 0)
	end
	local function UpdateBankSortIcon()
		local mode = DB.gphSortMode or "rarity"
		if mode == "vendor" then
			sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
		elseif mode == "itemlevel" then
			sortIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
		elseif mode == "category" then
			sortIcon:SetTexture("Interface\\Icons\\INV_Chest_Chain_04")
		else
			sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01")
		end
	end
	UpdateBankSortIcon()
	local function ShowBankSortTooltip(btn)
		btn = btn or sortBtn
		GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
		GameTooltip:ClearLines()
		local mode = DB.gphSortMode or "rarity"
		if mode == "vendor" then
			GameTooltip:AddLine("Vendorprice", 0.7, 0.8, 1)
		elseif mode == "itemlevel" then
			GameTooltip:AddLine("ItemLvl", 0.7, 0.8, 1)
		elseif mode == "category" then
			GameTooltip:AddLine("Category (Weapon, Armor, etc.)", 0.7, 0.8, 1)
		else
			GameTooltip:AddLine("Rarity", 0.7, 0.8, 1)
		end
		GameTooltip:AddLine("Shift+Click: sort bank / consolidate stacks", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end
	sortBtn:SetScript("OnClick", function(_, button)
		if button == "LeftButton" and IsShiftKeyDown() and GPH_BagSort_Run and GetBankMainContainer() then
			local mainBank = GetBankMainContainer()
			local list = { mainBank }
			for i = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6) do list[#list + 1] = i end
			GPH_BagSort_Run(function() if RefreshBankUI then RefreshBankUI() end end, "bank", list)
			if GameTooltip:GetOwner() == sortBtn then ShowBankSortTooltip(sortBtn) end
			return
		end
		local mode = DB.gphSortMode or "rarity"
		if mode == "rarity" then DB.gphSortMode = "vendor"
		elseif mode == "vendor" then DB.gphSortMode = "itemlevel"
		elseif mode == "itemlevel" then DB.gphSortMode = "category"
		elseif mode == "category" then DB.gphSortMode = "rarity"
		else DB.gphSortMode = "rarity" end
		UpdateBankSortIcon()
		if RefreshBankUI then RefreshBankUI() end
		if GameTooltip:GetOwner() == sortBtn then ShowBankSortTooltip(sortBtn) end
	end)
	sortBtn:SetScript("OnEnter", function(self)
		sortBg:SetTexture(0.5, 0.4, 0.15, 0.8)
		ShowBankSortTooltip(self)
	end)
	sortBtn:SetScript("OnLeave", function() sortBg:SetTexture(0.35, 0.28, 0.1, 0.7); GameTooltip:Hide() end)

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
		slotBg:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		slotBg:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
	bankSpaceBtn:SetSize(36, BANK_HEADER_HEIGHT)
	bankSpaceBtn:SetPoint("LEFT", bankHeader, "LEFT", 0, 0)
	bankSpaceBtn:EnableMouse(true)
	bankSpaceBtn:RegisterForDrag("LeftButton")
	bankSpaceBtn:SetHitRectInsets(0, 0, 0, 0)
    local bankSpaceBg = bankSpaceBtn:CreateTexture(nil, "BACKGROUND")
    bankSpaceBg:SetAllPoints()
    -- Default gold-ish background; ElvUI "real" skin will override this.
    bankSpaceBg:SetTexture(0.35, 0.28, 0.1, 0.7)
    bankSpaceBtn.bg = bankSpaceBg
	local bankSpaceFs = bankSpaceBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bankSpaceFs:SetPoint("CENTER")
	bankSpaceFs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
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
	local function placeCursorInFirstFreeBankSlot()
		local mainBank = GetBankMainContainer()
		if not mainBank then return false end
		for slot = 1, MAIN_BANK_SLOTS do
			if not (GetContainerItemLink and GetContainerItemLink(mainBank, slot)) then
				if PickupContainerItem then PickupContainerItem(mainBank, slot) end
				if RefreshBankUI then RefreshBankUI() end
				return true
			end
		end
		for i = 1, NUM_BANK_BAGS do
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
	-- Return (bankBagId, bankSlotId) for first free slot, or (nil, nil). Used for Postal-style multi-stack move in one go.
	local function getFirstFreeBankSlot()
		local mainBank = GetBankMainContainer()
		if not mainBank then return nil, nil end
		for slot = 1, MAIN_BANK_SLOTS do
			if not (GetContainerItemLink and GetContainerItemLink(mainBank, slot)) then
				return mainBank, slot
			end
		end
		for i = 1, NUM_BANK_BAGS do
			local bagID = (NUM_BAG_SLOTS or 4) + i
			local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
			for slot = 1, numSlots do
				if not (GetContainerItemLink and GetContainerItemLink(bagID, slot)) then
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
					if not (GetContainerItemLink and GetContainerItemLink(bag, slot)) then
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
	bankSpaceBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	bankSpaceBtn:SetScript("OnClick", function(_, button)
		if button ~= "LeftButton" then return end
		if GetCursorInfo and GetCursorInfo() == "item" then placeCursorInFirstFreeBankSlot() end
	end)
	bankSpaceBtn:SetScript("OnEnter", function()
		if GetCursorInfo and GetCursorInfo() == "item" then
			GameTooltip:SetOwner(bankSpaceBtn, "ANCHOR_RIGHT")
			GameTooltip:SetText("Drop to place in first free bank slot")
			GameTooltip:Show()
		else
			GameTooltip:SetOwner(bankSpaceBtn, "ANCHOR_RIGHT")
			GameTooltip:SetText("Bank slots used / total (drag items here to deposit)")
			GameTooltip:Show()
		end
	end)
	bankSpaceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.bankSpaceFs = bankSpaceFs
	f.bankSpaceBtn = bankSpaceBtn
	-- Bank space as drop target: glow + numbers turn white when cursor has an item
	f:SetScript("OnUpdate", function(self)
		if not self:IsShown() then return end
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
	local qualityRight = headerW - 4
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
		btn.bg:SetVertexColor(r, g, b, alpha)
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
			-- Ctrl+Right: move all items of this rarity from bank to bags (respecting protected lists)
			if IsControlKeyDown() and button == "RightButton" then
				Addon.RarityMoveJob = { mode = "bank_to_bags", rarity = self.quality }
				if Addon.RarityMoveWorker then
					Addon.RarityMoveWorker._t = 0
					Addon.RarityMoveWorker:Show()
				end
				return
			end

			if button == "RightButton" then
				f.bankRarityFilter = nil
			else
				f.bankRarityFilter = self.quality
			end
			if RefreshBankUI then RefreshBankUI() end
		end)
		qualBtn:SetScript("OnEnter", function(self)
			local info2 = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[self.quality]) or { r = 0.5, g = 0.5, b = 0.5 }
			local r, g, b = (info2.r or 0.5) * 1.2, (info2.g or 0.5) * 1.2, (info2.b or 0.5) * 1.2
			self.bg:SetVertexColor(r, g, b, 0.55)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(rarityLabels[self.quality] or "Rarity")
			GameTooltip:AddLine("Left: Filter by rarity.", 0.6, 0.6, 0.6)
			GameTooltip:AddLine("Right: Clear filter.", 0.6, 0.6, 0.6)
			GameTooltip:AddLine("Ctrl+Right: Move this rarity to bags.", 0.5, 0.8, 1.0)
			GameTooltip:Show()
		end)
		qualBtn:SetScript("OnLeave", function(self)
			UpdateBankQualBtnVisual(f, self, self.quality)
			GameTooltip:Hide()
		end)
        local info = (Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]) or { r = 0.5, g = 0.5, b = 0.5, hex = "888888" }
		bg:SetVertexColor(info.r or 0.5, info.g or 0.5, info.b or 0.5, 0.35)
		qualBtn:SetText("0")
		local bfs = qualBtn:GetFontString()
		if bfs then
			bfs:SetAllPoints()
			bfs:SetJustifyH("CENTER")
			bfs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
		end
		f.bankQualityButtons[q] = qualBtn
	end

	-- Scrollable list: use same template as GPH (UIPanelScrollFrameTemplate) so scrolling works; we drive offset + content position manually
	f.bankScrollOffset = 0
	local scroll = CreateFrame("ScrollFrame", "TestBankScrollFrame", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", bankHeader, "BOTTOMLEFT", 0, -6)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 6)
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

RefreshBankUI = function()
	local bf = _G.TestBankFrame
	if not bf then return end
	if not bf:IsShown() then return end
	-- Sync bank sort button icon with current display sort mode (same icons as inventory)
	if bf.bankSortBtn and bf.bankSortBtn.icon then
		local mode = DB.gphSortMode or "rarity"
		if mode == "vendor" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
		elseif mode == "itemlevel" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
		elseif mode == "category" then bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Chest_Chain_04")
		else bf.bankSortBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Amethyst_01") end
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
	local now = GetTime and GetTime() or time()
	bf._lastRefreshBankUI = now
	bf._refreshImmediate = nil

	ResetBankRowPool()
	local content = bf.content
	local slotList = {}
	local totalBankSlots, usedBankSlots = 0, 0
	local qCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
	-- Aggregate by item type (one row per item, total count), like inventory; first slot used for interaction
	local aggregated = {}
	local emptySlots = {}
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
		-- When client doesn't provide count (e.g. bank), assume 1 per slot so we at least show stack count
		if link and (stackCount == 0 or not stackCount) then stackCount = 1 end
		stackCount = stackCount or 0
		if not link then
			emptySlots[#emptySlots + 1] = { bagID = bagID, slotID = slotID, link = nil, name = "Empty", quality = 0, sellPrice = 0, itemLevel = 0, count = 0, texture = nil }
			return
		end
		usedBankSlots = usedBankSlots + 1
		local name, quality, iLevel, tex, sell, itemType = "Unknown", 0, 0, nil, 0, "Other"
		if GetItemInfo then
			name, _, quality, iLevel, _, itemType, _, _, _, tex, sell = GetItemInfo(link)
			name = name or "Unknown"
			quality = (quality and quality >= 0 and quality <= 6) and quality or 0
			itemType = (itemType and itemType ~= "" and itemType) or "Other"
		end
		texture = tex or texture
		local itemId = tonumber(link:match("item:(%d+)"))
		if not itemId then return end
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
		if not aggregated[itemId] then
			aggregated[itemId] = {
				firstBagID = bagID, firstSlotID = slotID, totalCount = 0,
				link = link, name = name, quality = quality, sellPrice = sell or 0, itemLevel = iLevel or 0, texture = texture, itemType = itemType,
			}
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
		slotList[#slotList + 1] = {
			bagID = agg.firstBagID, slotID = agg.firstSlotID, link = agg.link, name = agg.name, quality = agg.quality,
			sellPrice = agg.sellPrice, itemLevel = agg.itemLevel, count = agg.totalCount, texture = agg.texture, itemType = agg.itemType or "Other",
		}
	end
	-- Do not add empty slots to the list so they are never shown (user asked to hide them)
	-- for _, es in ipairs(emptySlots) do slotList[#slotList + 1] = es end
	-- Rarity button counts: 5 buttons (0-4); legendary (5) and artifact (6) count as epic (4)
	for q = 0, 4 do qCounts[q] = 0 end
	for _, agg in pairs(aggregated) do
		local q = (agg.quality and agg.quality >= 0 and agg.quality <= 6) and agg.quality or 0
		local btnQ = (q == 5 or q == 6) and 4 or q
		qCounts[btnQ] = (qCounts[btnQ] or 0) + (agg.totalCount or 0)
	end
	if bf.bankSpaceFs then bf.bankSpaceFs:SetText(usedBankSlots .. "/" .. totalBankSlots) end
	-- Display sort: same as inventory (rarity / vendor / itemlevel / category)
	local sortMode = DB.gphSortMode or "rarity"
	local GPH_CATEGORY_ORDER = { "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }
	local function categoryOrder(t) for i, c in ipairs(GPH_CATEGORY_ORDER) do if c == t then return i end end return 999 end
	local function emptyLast(a, b)
		local aEmpty = not a.link
		local bEmpty = not b.link
		if aEmpty ~= bEmpty then return not aEmpty end
		return false
	end
	if sortMode == "vendor" then
		table.sort(slotList, function(a, b)
			if emptyLast(a, b) then return true end
			if emptyLast(b, a) then return false end
			if (a.sellPrice or 0) ~= (b.sellPrice or 0) then return (a.sellPrice or 0) > (b.sellPrice or 0) end
			local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
			if ao ~= bo then return ao > bo end
			return (a.name or "") < (b.name or "")
		end)
	elseif sortMode == "itemlevel" then
		table.sort(slotList, function(a, b)
			if emptyLast(a, b) then return true end
			if emptyLast(b, a) then return false end
			if (a.itemLevel or 0) ~= (b.itemLevel or 0) then return (a.itemLevel or 0) > (b.itemLevel or 0) end
			local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
			if ao ~= bo then return ao > bo end
			return (a.name or "") < (b.name or "")
		end)
	elseif sortMode == "category" then
		table.sort(slotList, function(a, b)
			if emptyLast(a, b) then return true end
			if emptyLast(b, a) then return false end
			local at, bt = a.itemType or "Other", b.itemType or "Other"
			local ao, bo = categoryOrder(at), categoryOrder(bt)
			if ao ~= bo then return ao < bo end
			if (a.quality or 0) ~= (b.quality or 0) then return (a.quality or 0) > (b.quality or 0) end
			return (a.name or "") < (b.name or "")
		end)
	else
		table.sort(slotList, function(a, b)
			if emptyLast(a, b) then return true end
			if emptyLast(b, a) then return false end
			local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
			if ao ~= bo then return ao > bo end
			return (a.name or "") < (b.name or "")
		end)
	end
	-- Rarity filter: epic (4) shows 4, 5, 6; other filters show that quality only
	local filterQ = bf.bankRarityFilter
	if filterQ ~= nil then
		local filtered = {}
		for _, info in ipairs(slotList) do
			local q = info.quality or 0
			if q == filterQ or (filterQ == 4 and (q == 5 or q == 6)) then filtered[#filtered + 1] = info end
		end
		slotList = filtered
	end
	-- Search filter (same as inventory): when bank is open, use GPH frame search text to filter bank list too
	local inv = gphFrame or _G.TestGPHFrame
	if inv and inv.gphSearchText and inv.gphSearchText ~= "" then
		local searchLower = inv.gphSearchText:lower():match("^%s*(.-)%s*$")
		local exactQuality = nil
		for q = 0, 6 do
			local info = Addon.QUALITY_COLORS and Addon.QUALITY_COLORS[q]
			if info and info.label and info.label:lower() == searchLower then exactQuality = q; break end
		end
		local filtered = {}
		for _, item in ipairs(slotList) do
			if exactQuality ~= nil then
				if (item.quality or 0) == exactQuality then filtered[#filtered + 1] = item end
			else
				local itemMatches = (item.name and item.name:lower():find(searchLower, 1, true))
				local qualityMatches = false
				for q = 0, 6 do
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
		local groups = {}
		for _, info in ipairs(slotList) do
			local t = info.itemType or "Other"
			if not groups[t] then groups[t] = {} end
			table.insert(groups[t], info)
		end
		for _, items in pairs(groups) do
			table.sort(items, function(a, b)
				local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
				if ao ~= bo then return ao > bo end
				return (a.name or "") < (b.name or "")
			end)
		end
		if not bf.bankCategoryCollapsed then bf.bankCategoryCollapsed = {} end
		bankCategoryDrawList = {}
		for _, catName in ipairs(GPH_CATEGORY_ORDER) do
			if groups[catName] and #groups[catName] > 0 then
				local collapsed = bf.bankCategoryCollapsed[catName]
				table.insert(bankCategoryDrawList, { divider = catName, collapsed = collapsed })
				if not collapsed then
					for _, info in ipairs(groups[catName]) do table.insert(bankCategoryDrawList, info) end
				end
			end
		end
		for catName, items in pairs(groups) do
			local found
			for _, c in ipairs(GPH_CATEGORY_ORDER) do if c == catName then found = true break end end
			if not found then
				local collapsed = bf.bankCategoryCollapsed[catName]
				table.insert(bankCategoryDrawList, { divider = catName, collapsed = collapsed })
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
				qualBtn:SetText("|cff" .. (info.hex or "888888") .. tostring(count) .. "|r")
				local bfs = qualBtn:GetFontString()
				if bfs then
					bfs:SetAllPoints()
					bfs:SetJustifyH("CENTER")
					bfs:SetFont("Fonts\\FRIZQT__.TTF", 7, "")
				end
			end
		end
	end
	BankDebug("Step 4: slotList count=" .. tostring(#slotList))

	local bankDeleteClickTime = bf._bankDeleteClickTime or {}
	bf._bankDeleteClickTime = bankDeleteClickTime
	local yOff = 0
	local firstRow = nil
	local listToUse = (sortMode == "category" and bankCategoryDrawList) or slotList
	local bankDividerIndex = 0
	if bf.bankCategoryDividerPool then for _, d in ipairs(bf.bankCategoryDividerPool) do d:Hide() end end
	for idx, entry in ipairs(listToUse) do
		if entry.divider then
			-- Collapsible category header (same look and behavior as inventory)
			bankDividerIndex = bankDividerIndex + 1
			if not bf.bankCategoryDividerPool then bf.bankCategoryDividerPool = {} end
			local pool = bf.bankCategoryDividerPool
			local div = pool[bankDividerIndex]
			if not div then
				-- Visual header frame (not clickable itself)
				div = CreateFrame("Frame", nil, content)
				div:EnableMouse(false)
				local tex = div:CreateTexture(nil, "ARTWORK")
				tex:SetTexture(0.4, 0.35, 0.2, 0.7)
				tex:SetPoint("TOPLEFT", div, "TOPLEFT", 0, 0)
				tex:SetPoint("TOPRIGHT", div, "TOPRIGHT", 0, 0)
				tex:SetHeight(1)
				div.tex = tex
				local label = div:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
				label:SetJustifyH("LEFT")
				div.label = label
				-- Small collapse toggle button on the LEFT ([+]/[−]), label to the right
				local toggle = CreateFrame("Button", nil, div)
				toggle:SetSize(14, 12)
				toggle:SetPoint("LEFT", div, "LEFT", 0, 0)
				local tfs = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
				tfs:SetPoint("CENTER")
				toggle.text = tfs
				div.toggleBtn = toggle
				-- Label sits just to the right of the toggle
				label:ClearAllPoints()
				label:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
				table.insert(pool, div)
			end
			local catName = entry.divider or ""
			local collapsed = entry.collapsed
			div:SetParent(content)
			div:ClearAllPoints()
			div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
			div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
			div:SetHeight(12)
			-- Label: just the category name, colored; not clickable.
			div.label:SetText("|cff888888" .. catName .. "|r")
			div.label:Show()
			div.categoryName = catName
			-- Toggle button: only this small area is clickable to collapse/expand
			if div.toggleBtn and div.toggleBtn.text then
				div.toggleBtn.text:SetText(collapsed and "[+]" or "[−]")
				-- Match header text color (grey) instead of gold
				div.toggleBtn.text:SetTextColor(0.53, 0.53, 0.53, 1)
				div.toggleBtn:SetScript("OnClick", function()
					if not bf.bankCategoryCollapsed then bf.bankCategoryCollapsed = {} end
					bf.bankCategoryCollapsed[catName] = not bf.bankCategoryCollapsed[catName]
					if RefreshBankUI then RefreshBankUI() end
				end)
				div.toggleBtn:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetText("Click to collapse/expand")
					GameTooltip:Show()
				end)
				div.toggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
				div.toggleBtn:Show()
			end
			div:Show()
			yOff = yOff + 12
		else
			local row = GetBankRow(content)
			if firstRow == nil then firstRow = row end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
			local info = entry
			local bagID, slotID = info.bagID, info.slotID
			yOff = yOff + BANK_ROW_HEIGHT
			row:SetHeight(BANK_ROW_HEIGHT)
			row.bagID = bagID
			row.slotID = slotID
			local link = info.link or (GetContainerItemLink and GetContainerItemLink(bagID, slotID))
			if idx == 1 and BANK_DEBUG then
				BankDebug("Step 5: first row parent=" .. tostring(row:GetParent()) .. " content=" .. tostring(content) .. " row:IsShown()=" .. tostring(row:IsShown()) .. " content:GetParent()=" .. tostring(content:GetParent()))
			end
			local name = info.name or "Empty"
			local quality = info.quality or 0
			local count = info.count or 0
			local texture = info.texture or (GetContainerItemInfo and GetContainerItemInfo(bagID, slotID))
			if texture then
				row.icon:SetTexture(texture)
				row.icon:Show()
			else
				row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
				row.icon:Show()
			end
			local QUALITY_COLORS = Addon.QUALITY_COLORS or {}
			local info2 = Addon.QUALITY_COLORS[quality] or { r = 0.8, g = 0.8, b = 0.8, hex = "cccccc" }
			row.nameFs:SetText("|cff" .. (info2.hex or "cccccc") .. (name or "Unknown") .. "|r")
			local showCount = (count and count > 1) and ("|cffaaaaaa x" .. tostring(count) .. "|r") or ""
			row.countFs:SetText(showCount)
			row.totalCount = count

			if row.deleteBtn then
			if link then row.deleteBtn:Show() else row.deleteBtn:Hide() end
			row.deleteBtn:SetScript("OnClick", function()
				local r = row
				if not r.bagID or not r.slotID then return end
				local now = GetTime and GetTime() or 0
				local key = r.bagID .. "_" .. r.slotID
				if bankDeleteClickTime[key] and (now - bankDeleteClickTime[key]) <= 0.5 then
					bankDeleteClickTime[key] = nil
					DeleteBankSlot(r.bagID, r.slotID)
					if RefreshBankUI then RefreshBankUI() end
				else
					bankDeleteClickTime[key] = now
				end
			end)
			row.deleteBtn:SetScript("OnEnter", function(self)
				self:SetText("|cffff8888x|r")
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText("Double-click to destroy this item")
				GameTooltip:Show()
			end)
			row.deleteBtn:SetScript("OnLeave", function(self)
				self:SetText("|cffff4444x|r")
				GameTooltip:Hide()
			end)
			row.deleteBtn:SetScript("OnMouseWheel", function(_, delta)
				if bf.scrollFrame and bf.scrollFrame.BankOnMouseWheel then bf.scrollFrame.BankOnMouseWheel(delta) end
			end)
		end

		row.clickArea:SetScript("OnMouseDown", function(self, mouseButton)
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
		end)
		row.clickArea:SetScript("OnClick", function(self, button)
			local r = self:GetParent()
			if not r.bagID or not r.slotID then return end
			if button == "RightButton" then
				-- Right-click: put bank item into bags (ElvUI-style)
				local link = GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
				if link and PickupContainerItem and PutItemInBackpack then
					PickupContainerItem(r.bagID, r.slotID)
					PutItemInBackpack()
				end
			else
				-- Left-click: pick up / place (skip if shift was down – split dialog already shown in OnMouseDown)
				if IsShiftKeyDown() and (r.totalCount or 0) > 1 then return end
				if PickupContainerItem then PickupContainerItem(r.bagID, r.slotID) end
			end
		end)
		row.clickArea:SetScript("OnReceiveDrag", function(self)
			local r = self:GetParent()
			if GetCursorInfo and GetCursorInfo() == "item" and PickupContainerItem and r.bagID and r.slotID then
				PickupContainerItem(r.bagID, r.slotID)
			end
		end)
		-- Fallback: when drag starts from addon list, OnReceiveDrag often doesn't fire; OnMouseUp (drop) still places item into bank
		row.clickArea:SetScript("OnMouseUp", function(self, button)
			if button ~= "LeftButton" then return end
			local r = self:GetParent()
			if not r.bagID or not r.slotID or not PickupContainerItem then return end
			if GetCursorInfo and GetCursorInfo() == "item" then
				PickupContainerItem(r.bagID, r.slotID)
			end
		end)
		row.clickArea:SetScript("OnEnter", function(self)
			local r = self:GetParent()
			local link = r.bagID and r.slotID and GetContainerItemLink and GetContainerItemLink(r.bagID, r.slotID)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if link then
				GameTooltip:SetHyperlink(link)
			else
				GameTooltip:SetText("Empty slot")
			end
			GameTooltip:Show()
		end)
		row.clickArea:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.clickArea:SetScript("OnMouseWheel", function(_, delta)
			if bf.scrollFrame and bf.scrollFrame.BankOnMouseWheel then bf.scrollFrame.BankOnMouseWheel(delta) end
		end)
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
		local offset = math.min(bf.bankScrollOffset or 0, maxScroll)
		bf.bankScrollOffset = offset
		scrollBar:SetValue(offset)
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, offset)
		BankDebug("Step 8: viewH=" .. tostring(viewH) .. " maxScroll=" .. tostring(maxScroll) .. " offset=" .. tostring(offset))
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
    -- Re-apply player name, font object, and color so class color sticks
    if gphFrame.gphTitle then ApplyGphInventoryTitle(gphFrame.gphTitle) end
    if gphFrame.UpdateGphTitleBarButtonLayout then gphFrame:UpdateGphTitleBarButtonLayout() end
    if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
    local poolOk, poolErr = pcall(Addon.ResetGPHPools)
    if not poolOk then
        Addon.AddonPrint("[Fugazi] GPH ResetGPHPools error: " .. tostring(poolErr))
        return
    end

    -- Red border and slot counts are set inside the single bag loop below (no extra scan)

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
        local collapsed = DB.gphCollapsed
        if collapsed and gphFrame.gphStatusLeft and gphFrame.gphStatusCenter and gphFrame.gphStatusRight then
            gphFrame.statusText:Hide()
            gphFrame.statusText:SetText("")
            gphFrame.gphStatusLeft:SetText("|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold))
            gphFrame.gphStatusLeft:Show()
            gphFrame.gphStatusCenter:SetText("|cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r")
            gphFrame.gphStatusCenter:Show()
            gphFrame.gphStatusRight:SetText("|cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph)))
            gphFrame.gphStatusRight:Show()
        else
            if gphFrame.gphStatusLeft then gphFrame.gphStatusLeft:Hide() end
            if gphFrame.gphStatusCenter then gphFrame.gphStatusCenter:Hide() end
            if gphFrame.gphStatusRight then gphFrame.gphStatusRight:Hide() end
            gphFrame.statusText:Show()
            gphFrame.statusText:SetText(
                "|cffdaa520Gold:|r " .. Addon.FormatGold(liveGold)
                .. "   |cffdaa520Timer:|r |cffffffff" .. Addon.FormatTimeMedium(dur) .. "|r"
                .. "   |cffdaa520GPH:|r " .. Addon.FormatGold(math.floor(gph))
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

    Addon.gphPendingQuality = Addon.gphPendingQuality or {}
    for q = 0, 5 do
        if Addon.gphPendingQuality[q] and (nowGph - Addon.gphPendingQuality[q]) > 5 then
            Addon.gphPendingQuality[q] = nil
        end
    end

    Addon.ScanBags()
    local liveQualityCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
    -- Single bag pass: count total/used slots (for red border + bag button) and build aggregated list; GetItemInfo only once per itemId
    local itemList = {}
    local prevWornSet = Addon.GetGphProtectedSet()
    local previouslyWornOnlySet = Addon.GetGphPreviouslyWornOnlySet()
    local rarityFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags()
    local typeCache = DB.gphItemTypeCache or {}
    DB.gphItemTypeCache = typeCache
    local aggregated = {}
    local emptySlots = {}
    local totalSlots, usedSlots = 0, 0
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        totalSlots = totalSlots + numSlots
        for slot = 1, numSlots do
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
            local texture, count, locked = GetContainerItemInfo(bag, slot)
            count = count or 0
            if not link then
                table.insert(emptySlots, { bag = bag, slot = slot })
            else
                usedSlots = usedSlots + 1
                local itemId = tonumber(link:match("item:(%d+)"))
                if not aggregated[itemId] then
                    local name, _, quality, iLevel, _, itemType, _, _, _, tex, sellPrice = GetItemInfo(link)
                    quality = quality or 0
                    name = name or "Unknown"
                    sellPrice = sellPrice or 0
                    iLevel = iLevel or 0
                    texture = tex or texture
                    if itemId then typeCache[itemId] = (itemType and itemType ~= "" and itemType) or "Other" end
                    aggregated[itemId] = {
                        totalCount = 0, firstBag = bag, firstSlot = slot, link = link, texture = texture,
                        name = name, quality = quality, itemId = itemId, sellPrice = sellPrice or 0, itemLevel = iLevel or 0,
                        itemType = typeCache[itemId] or "Other",
                    }
                end
                aggregated[itemId].totalCount = aggregated[itemId].totalCount + count
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
        local q = (agg.quality ~= nil and agg.quality >= 0 and agg.quality <= 6) and agg.quality or 0
        local btnQ = (q == 5 or q == 6) and 4 or math.min(q, 4)
        liveQualityCounts[btnQ] = (liveQualityCounts[btnQ] or 0) + agg.totalCount
        local isProtected = agg.itemId and (prevWornSet[agg.itemId] or (rarityFlags and agg.quality and rarityFlags[agg.quality]))
        local previouslyWorn = agg.itemId and previouslyWornOnlySet[agg.itemId]
        table.insert(itemList, {
            bag = agg.firstBag, slot = agg.firstSlot, link = agg.link, texture = agg.texture, count = agg.totalCount,
            name = agg.name, quality = agg.quality, itemId = agg.itemId, sellPrice = agg.sellPrice, itemLevel = agg.itemLevel,
            itemType = agg.itemType, isProtected = isProtected and true or nil, previouslyWorn = previouslyWorn and true or nil,
        })
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
    local ROW_H = 14
    local bagW, bagH = 36, 14
    -- Rarity buttons: fill from after bag to 4px before frame
    local startX = leftPad + bagW + bagGap
    local rarityTotalW = qualityRight - startX
    local slotWidth = math.floor((rarityTotalW - spacing * (numRarityBtns - 1)) / numRarityBtns)
    if slotWidth < 24 then slotWidth = 24 end

    -- Bag space: below Search, same size as Search (36x20); drop target, keep on top of header
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
        if headerParent and headerParent.GetFrameLevel then
            gphFrame.gphBagSpaceBtn:SetFrameLevel(headerParent:GetFrameLevel() + 20)
        end
        gphFrame.gphBagSpaceBtn:Show()
        table.insert(header and header.headerElements or content.headerElements, gphFrame.gphBagSpaceBtn)
    end

    for i, q in ipairs({ 0, 1, 2, 3, 4 }) do
        local count = liveQualityCounts[q] or 0
        local info = Addon.QUALITY_COLORS[q] or Addon.QUALITY_COLORS[1]
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
        if Addon.gphPendingQuality[q] then
            r, g, b = 0.9, 0.2, 0.2
        end
        local alpha = 0.35
        -- Brighten when this quality is the active filter (1st-click selected, items filtered)
        if gphFrame and gphFrame.gphFilterQuality == q and not Addon.gphPendingQuality[q] then
            r = math.min(1, r * 2.2)
            g = math.min(1, g * 2.2)
            b = math.min(1, b * 2.2)
            alpha = 0.95
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

        if Addon.gphPendingQuality[q] then
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
            -- Ctrl+Right: move all items of this rarity from bags to bank (only when bank window is open)
            if IsControlKeyDown() and button == "RightButton" then
                local bf = _G.TestBankFrame
                if bf and bf:IsShown() then
                    Addon.RarityMoveJob = { mode = "bags_to_bank", rarity = self.quality }
                    if Addon.RarityMoveWorker then
                        Addon.RarityMoveWorker._t = 0
                        Addon.RarityMoveWorker:Show()
                    end
                end
                return
            end
            -- Ctrl+Left: toggle protect all items of this rarity (separate from per-item whitelist; deselecting clears only rarity protection)
            if IsControlKeyDown() and button == "LeftButton" and Addon.GetGphProtectedRarityFlags then
                local flags = Addon.GetGphProtectedRarityFlags()
                flags[self.quality] = not flags[self.quality]
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
                return
            end
            if button == "RightButton" then
                if gphFrame then gphFrame.gphFilterQuality = nil end
                for qKey in pairs(Addon.gphPendingQuality) do Addon.gphPendingQuality[qKey] = nil end
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
                return
            end
            -- 1st click: filter by this quality (sort by color). 2nd: red/DEL. 3rd: delete confirmation. RMB clears.
            if gphFrame and gphFrame.gphFilterQuality == self.quality then
                if Addon.gphPendingQuality[self.quality] then
                    -- 3rd click: show delete confirmation
                    if self.currentCount > 0 then
                        StaticPopup_Show("GPH_DELETE_QUALITY", self.currentCount, self.label, {quality = self.quality})
                    end
                else
                    -- 2nd click: set pending (red/DEL); focus hidden edit box so ESC cancels (same as right-click)
                    Addon.gphPendingQuality[self.quality] = GetTime and GetTime() or time()
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
                for qKey in pairs(Addon.gphPendingQuality) do Addon.gphPendingQuality[qKey] = nil end
                if gphFrame then gphFrame._refreshImmediate = true end
                RefreshGPHUI()
            end
        end)
        qualBtn:SetScript("OnEnter", function(self)
            if not self.label then return end
            Addon.AnchorTooltipRight(self)
            GameTooltip:SetText(self.label or "Rarity")
            GameTooltip:AddLine("LMB: Filter by rarity.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("RMB: Clear.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Double+LMB: Delete whole rarity.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Ctrl+LMB: Protect all items of this rarity.", 0.5, 0.9, 0.5)
            GameTooltip:AddLine("Ctrl+RMB (Bank open): Move this rarity to bank.", 0.5, 0.8, 1.0)
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
    local sortMode = DB.gphSortMode or "rarity"
    -- Empty slots (no link) and destroy ghosts (no bag/slot) go to end
    local function emptyLast(a, b)
        local aEmpty = not a.link
        local bEmpty = not b.link
        if aEmpty ~= bEmpty then return not aEmpty end
        return false
    end
    if sortMode == "vendor" then
        table.sort(itemList, function(a, b)
            if emptyLast(a, b) then return true end
            if emptyLast(b, a) then return false end
            if a.sellPrice ~= b.sellPrice then return (a.sellPrice or 0) > (b.sellPrice or 0) end
            local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
            if ao ~= bo then return ao > bo end
            return (a.name or "") < (b.name or "")
        end)
    elseif sortMode == "itemlevel" then
        table.sort(itemList, function(a, b)
            if emptyLast(a, b) then return true end
            if emptyLast(b, a) then return false end
            if (a.itemLevel or 0) ~= (b.itemLevel or 0) then return (a.itemLevel or 0) > (b.itemLevel or 0) end
            local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
            if ao ~= bo then return ao > bo end
            return (a.name or "") < (b.name or "")
        end)
    else
        table.sort(itemList, function(a, b)
            if emptyLast(a, b) then return true end
            if emptyLast(b, a) then return false end
            local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
            if ao ~= bo then return ao > bo end
            return (a.name or "") < (b.name or "")
        end)
    end

    -- Order: (*) protected first (above divider), then hearthstone (6948), then rest.
    do
        local protectedSet = Addon.GetGphProtectedSet()
        local rFlags = Addon.GetGphProtectedRarityFlags and Addon.GetGphProtectedRarityFlags()
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

    -- Filter by selected rarity; epic (4) shows epic + legendary + artifact (4, 5, 6)
    if gphFrame.gphFilterQuality ~= nil then
        local q = gphFrame.gphFilterQuality
        local filtered = {}
        for _, item in ipairs(itemList) do
            local iq = item.quality or 0
            if iq == q or (q == 4 and (iq == 5 or iq == 6)) then table.insert(filtered, item) end
        end
        itemList = filtered
    end

    -- Filter by GPH search (item name or rarity); exact quality label so "common" only white, "uncomm" only green
    if gphFrame.gphSearchText and gphFrame.gphSearchText ~= "" then
        local searchLower = gphFrame.gphSearchText:lower():match("^%s*(.-)%s*$")
        local exactQuality = nil
        for q = 0, 6 do
            local info = Addon.QUALITY_COLORS[q]
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
                for q = 0, 6 do
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
                    destroyList[did] = { name = n, texture = t }
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
                bag = nil,
                slot = nil,
            })
        end
    end
    -- Push destroy-list items to the very bottom (preserve order). Build itemList as new table so we don't mutate normal (needed for non-category draw list).
    local normal, destroyed = {}, {}
    for _, item in ipairs(itemList) do
        if item.itemId and destroyList[item.itemId] then
            table.insert(destroyed, item)
        else
            table.insert(normal, item)
        end
    end
    itemList = {}
    for _, item in ipairs(normal) do table.insert(itemList, item) end
    for _, item in ipairs(destroyed) do table.insert(itemList, item) end

    -- When sort by category: group by GetItemInfo type, order like AH (Weapon, Armor, ...)
    local GPH_CATEGORY_ORDER = { "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }
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
            local itemType = itemId and typeCache[itemId]
            if not itemType or itemType == "Other" then
                local _, _, _, _, _, giType = GetItemInfo(item.link or item.itemId)
                itemType = (giType and giType ~= "" and giType) or "Other"
                if itemId then typeCache[itemId] = itemType end
            end
            item.itemType = itemType
        end
        local groups = {}
        for _, item in ipairs(itemList) do
            local t = (item.itemId and destroyList[item.itemId]) and "DELETE" or (item.itemType or "Other")
            if not groups[t] then groups[t] = {} end
            table.insert(groups[t], item)
        end
        for _, items in pairs(groups) do
            table.sort(items, function(a, b)
                local ao, bo = Addon.RaritySortOrder(a.quality), Addon.RaritySortOrder(b.quality)
                if ao ~= bo then return ao > bo end
                return (a.name or "") < (b.name or "")
            end)
        end
        local orderedGroups = {}
        for _, catName in ipairs(GPH_CATEGORY_ORDER) do
            if groups[catName] and #groups[catName] > 0 then
                table.insert(orderedGroups, { name = catName, items = groups[catName] })
            end
        end
        for catName, items in pairs(groups) do
            if catName ~= "DELETE" then
                local found
                for _, c in ipairs(GPH_CATEGORY_ORDER) do if c == catName then found = true break end end
                if not found then table.insert(orderedGroups, { name = catName, items = items }) end
            end
        end
        -- DELETE header at bottom: all autodelete items in one collapsible section
        if groups["DELETE"] and #groups["DELETE"] > 0 then
            table.insert(orderedGroups, { name = "DELETE", items = groups["DELETE"] })
        end
        gphFrame.gphCategoryGroups = orderedGroups
        if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
        local flat = {}
        local drawList = {}
        for _, grp in ipairs(orderedGroups) do
            local collapsed = (grp.name == "DELETE") and (gphFrame.gphCategoryCollapsed["DELETE"] ~= false) or gphFrame.gphCategoryCollapsed[grp.name]
            table.insert(drawList, { divider = grp.name, collapsed = collapsed })
            if not collapsed then
                for _, item in ipairs(grp.items) do
                    table.insert(drawList, item)
                    table.insert(flat, item)
                end
            end
        end
        gphFrame.gphCategoryItemList = flat
        gphFrame.gphCategoryDrawList = drawList
        -- Item types can load async; schedule one short delayed refresh so category headers appear as soon as GetItemInfo cache fills
        if not (Addon.gphCategoryRefreshFrame and Addon.gphCategoryRefreshFrame._categoryScheduled) then
            if not Addon.gphCategoryRefreshFrame then Addon.gphCategoryRefreshFrame = CreateFrame("Frame") end
            local cf = Addon.gphCategoryRefreshFrame
            cf._categoryScheduled = true
            cf._categoryAccum = 0
            cf:SetScript("OnUpdate", function(self, elapsed)
                self._categoryAccum = (self._categoryAccum or 0) + elapsed
                if self._categoryAccum >= 0.25 then
                    self:SetScript("OnUpdate", nil)
                    self._categoryScheduled = nil
                    if gphFrame and gphFrame:IsShown() and DB and DB.gphSortMode == "category" and RefreshGPHUI then RefreshGPHUI() end
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
            local drawList = {}
            for _, item in ipairs(normal) do table.insert(drawList, item) end
            table.insert(drawList, { divider = "DELETE", collapsed = deleteCollapsed })
            if not deleteCollapsed then
                for _, item in ipairs(destroyed) do table.insert(drawList, item) end
            end
            local flat = {}
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
        local listToUse = gphFrame.gphCategoryDrawList or itemList
        local listForAdvance = gphFrame.gphCategoryItemList or itemList
        local itemIdx = 0
        local dividerIndex = 0
        if gphFrame.gphCategoryDividerPool then for _, d in ipairs(gphFrame.gphCategoryDividerPool) do d:Hide() end end
        for idx, entry in ipairs(listToUse) do
            if entry.divider then
                dividerIndex = dividerIndex + 1
                if not gphFrame.gphCategoryDividerPool then gphFrame.gphCategoryDividerPool = {} end
                local pool = gphFrame.gphCategoryDividerPool
                local div = pool[dividerIndex]
                if not div then
                    -- Visual header frame (not clickable itself)
                    div = CreateFrame("Frame", nil, content)
                    div:EnableMouse(false)
                    local tex = div:CreateTexture(nil, "ARTWORK")
                    tex:SetTexture(0.4, 0.35, 0.2, 0.7)
                    tex:SetPoint("TOPLEFT", div, "TOPLEFT", 0, 0)
                    tex:SetPoint("TOPRIGHT", div, "TOPRIGHT", 0, 0)
                    tex:SetHeight(1)
                    div.tex = tex
                    local label = div:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    label:SetPoint("LEFT", div, "LEFT", 4, 0)
                    label:SetJustifyH("LEFT")
                    div.label = label
                    -- Small collapse toggle button on the LEFT ([+]/[−]), label to the right
                    local toggle = CreateFrame("Button", nil, div)
                    toggle:SetSize(14, 12)
                    toggle:SetPoint("LEFT", div, "LEFT", 0, 0)
                    local tfs = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    tfs:SetPoint("CENTER")
                    toggle.text = tfs
                    div.toggleBtn = toggle
                    -- Move label to sit just right of the toggle
                    div.label:ClearAllPoints()
                    div.label:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
                    table.insert(pool, div)
                end
                local catName = entry.divider or ""
                local collapsed = entry.collapsed
                local isDelete = (catName == "DELETE")
                div:SetParent(content)
                div:ClearAllPoints()
                div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
                div:SetHeight(12)
                if div.tex then
                    if isDelete then div.tex:SetTexture(0.32, 0.14, 0.14, 0.65) else div.tex:SetTexture(0.4, 0.35, 0.2, 0.7) end
                end
                -- Label: just the category text, colorized (no clickable hints here)
                div.label:SetText((isDelete and "|cff8a5555" or "|cff888888") .. catName .. "|r")
                div.label:Show()
                div.categoryName = catName
                -- Toggle button: only this small area is clickable to collapse/expand
                if div.toggleBtn and div.toggleBtn.text then
                    div.toggleBtn.text:SetText(collapsed and "[+]" or "[−]")
                    -- Match header text color: red for DELETE, grey otherwise
                    if isDelete then
                        div.toggleBtn.text:SetTextColor(0.54, 0.33, 0.33, 1)
                    else
                        div.toggleBtn.text:SetTextColor(0.53, 0.53, 0.53, 1)
                    end
                    div.toggleBtn:SetScript("OnClick", function()
                        if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
                        gphFrame.gphCategoryCollapsed[catName] = not gphFrame.gphCategoryCollapsed[catName]
                        if RefreshGPHUI then RefreshGPHUI() end
                    end)
                    div.toggleBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Click to collapse/expand")
                        GameTooltip:Show()
                    end)
                    div.toggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    div.toggleBtn:Show()
                end
                div:Show()
                yOff = yOff + 12
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
            local btn = Addon.GetGPHItemBtn(content)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
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
            local qInfo = Addon.QUALITY_COLORS[item.quality] or Addon.QUALITY_COLORS[1]
            -- Previously worn icon (shield) only; no soulbound scan to avoid lag
            local leftOfName = btn.icon
            local gap = 4
            if btn.prevWornIcon then
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
            btn.nameFs:SetPoint("LEFT", leftOfName, "RIGHT", gap, 0)
            btn.nameFs:SetPoint("RIGHT", btn.clickArea, "RIGHT", -2, 0)
            -- Name: destroy-list = full grey; protected = blended quality tint; else quality color.
            local nameHex
            if isOnDestroyList then
                nameHex = "888888"
            elseif item.isProtected then
                local mix = 0.28
                local grey = 0.48
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

            -- Double-click [x] to delete from bags (first click = pending, second = delete, NO subtract from tracking)
            local itemId = nil
            if item.link then itemId = tonumber(item.link:match("item:(%d+)")) end
            local capturedId = itemId
            local capturedCount = item.count
            -- Key double-click by slot so same row must be clicked twice (avoids wrong-stack delete when multiple stacks exist)
            local deleteKey = (item.bag ~= nil and item.slot ~= nil) and ("b"..item.bag.."s"..item.slot) or ("i"..tostring(capturedId))

            -- Selected-row highlight: match by (bag, slot), by itemId for destroy ghosts, or by index (after advance-on-use)
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
                if btn.selectedTex then btn.selectedTex:Show() end
            else
                if btn.selectedTex then btn.selectedTex:Hide() end
            end

            -- Dark overlay for items on cooldown (use slot when available)
            if btn.cooldownOverlay then
                local onCooldown = false
                if item.bag ~= nil and item.slot ~= nil and GetContainerItemCooldown then
                    local start, duration = GetContainerItemCooldown(item.bag, item.slot)
                    onCooldown = duration and duration > 0 and (start or 0) + duration > GetTime()
                else
                    onCooldown = Addon.ItemIdHasCooldown(capturedId, itemIdToSlot)
                end
                if onCooldown then
                    btn.cooldownOverlay:Show()
                else
                    btn.cooldownOverlay:Hide()
                end
            end

            -- Red overlay for "mark for auto-destroy" (Shift+double-click X); dark red, not bright, not near-black
            if btn.destroyOverlay then
                if (Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {})[capturedId] then
                    btn.destroyOverlay:SetVertexColor(0.28, 0.12, 0.12)
                    btn.destroyOverlay:SetAlpha(0.72)
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

            -- Hide red X for empty slots (Show/Hide for 3.3.5; SetShown not available)
            if btn.deleteBtn then
                if item.link then btn.deleteBtn:Show() else btn.deleteBtn:Hide() end
            end

            -- Clear stale double-click state (older than 0.5s)
            if Addon.gphDeleteClickTime[deleteKey] and (now - (Addon.gphDeleteClickTime[deleteKey] or 0)) > 0.5 then
                Addon.gphDeleteClickTime[deleteKey] = nil
            end

            btn.deleteBtn:SetText("|cffff4444x|r")
            btn.deleteBtn:SetScript("OnEnter", function(self)
                self:SetText("|cffff8888x|r")
                self:SetWidth(16)
                self:SetHeight(16)
                Addon.AnchorTooltipRight(self)
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
                -- No throttle on X button so double-click always registers (row throttle was dropping X clicks)
                local now = GetTime and GetTime() or time()
                -- Shift+double-click X: toggle mark for auto-destroy (no "Inv" required)
                if IsShiftKeyDown() then
                    if Addon.gphDestroyClickTime[capturedId] and (now - Addon.gphDestroyClickTime[capturedId]) <= 0.5 then
                        Addon.gphDestroyClickTime[capturedId] = nil
                        local list = Addon.GetGphDestroyList and Addon.GetGphDestroyList() or {}
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
                                Addon.QueueDestroySlotsForItemId(capturedId)
                            end
                        end
                        RefreshGPHUI()
                        if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    else
                        Addon.gphDestroyClickTime[capturedId] = now
                    end
                    return
                end
                Addon.gphDestroyClickTime[capturedId] = nil
                -- Double-click X within 0.5s to delete (keyed by slot so same row must be clicked twice)
                if Addon.gphDeleteClickTime[deleteKey] and (now - Addon.gphDeleteClickTime[deleteKey]) <= 0.5 then
                    Addon.gphDeleteClickTime[deleteKey] = nil
                    if item.bag ~= nil and item.slot ~= nil then
                        if item.previouslyWorn then
                            StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId, count = capturedCount, bag = item.bag, slot = item.slot })
                        elseif capturedCount > GPH_MAX_STACK then
                            StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_STACK", capturedCount, nil, { itemId = capturedId, count = capturedCount, bag = item.bag, slot = item.slot })
                        else
                            Addon.DeleteGPHSlot(item.bag, item.slot)
                            RefreshGPHUI()
                        end
                    else
                        if item.previouslyWorn then
                            StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_PREVIOUSLY_WORN", nil, nil, { itemId = capturedId, count = capturedCount })
                        elseif capturedCount > GPH_MAX_STACK then
                            StaticPopup_Show("INSTANCETRACKER_GPH_DELETE_STACK", capturedCount, nil, { itemId = capturedId, count = capturedCount })
                        else
                            Addon.DeleteGPHItem(capturedId, capturedCount)
                            RefreshGPHUI()
                        end
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                else
                    Addon.gphDeleteClickTime[deleteKey] = now
                end
            end)

            btn.clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn.clickArea:RegisterForDrag("LeftButton")
            btn.clickArea:SetScript("OnReceiveDrag", function(self)
                if item.bag ~= nil and item.slot ~= nil and PickupContainerItem then
                    PickupContainerItem(item.bag, item.slot)
                    -- Defer refresh so bag state has updated and list shows new positions
                    local defer = CreateFrame("Frame", nil, UIParent)
                    defer:SetScript("OnUpdate", function(self)
                        self:SetScript("OnUpdate", nil)
                        if gphFrame then gphFrame._refreshImmediate = true end
                        if RefreshGPHUI then RefreshGPHUI() end
                    end)
                end
            end)
            btn.clickArea:SetScript("OnMouseWheel", function(self, delta)
                if gphFrame and gphFrame.scrollFrame and gphFrame.scrollFrame.GPHOnMouseWheel then
                    gphFrame.scrollFrame.GPHOnMouseWheel(delta)
                end
            end)
            btn.clickArea:SetScript("OnClick", function(self, button)
                if _G.MerchantFrame and _G.MerchantFrame:IsShown() and _G.FugaziVendorProtectUnhookNow then _G.FugaziVendorProtectUnhookNow() end
                -- Throttle row actions to ~4/sec so fast macros don't highlight/mark everything
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                -- RMB (no shift): when bank is open, only move to bank; when bank is closed, only use/equip item.
                if button == "RightButton" and not IsShiftKeyDown() and item.bag ~= nil and item.slot ~= nil then
                    local bf = _G.TestBankFrame
                    -- Bank OPEN: "sorting mode" – send item to first free bank slot, do NOT use item here.
                    if bf and bf:IsShown() and bf.GetFirstFreeBankSlot and PickupContainerItem and (not GetCursorInfo or GetCursorInfo() ~= "item") then
                        local bankBag, bankSlot = bf:GetFirstFreeBankSlot()
                        if bankBag and bankSlot then
                            PickupContainerItem(item.bag, item.slot)
                            PickupContainerItem(bankBag, bankSlot)
                            if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                            return
                        end
                        -- If bank is full or we couldn't get a slot, just do nothing on RMB.
                        if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                        return
                    end
                    -- Bank closed: first right-click selects row and attaches overlay; second right-click hits overlay = use (taint-free).
                    gphFrame.gphSelectedItemId = capturedId
                    gphFrame.gphSelectedBag = item.bag
                    gphFrame.gphSelectedSlot = item.slot
                    gphFrame.gphSelectedIndex = itemIdx
                    gphFrame.gphSelectedRowBtn = btn
                    gphFrame.gphSelectedItemLink = item.link
                    gphFrame.gphSelectedTime = time()
                    if gphFrame.gphRightClickUseOverlay and btn then
                        local bag, slot = item.bag, item.slot
                        local overlay = gphFrame.gphRightClickUseOverlay
                        pcall(function()
                            overlay:SetAttribute("type", "macro")
                            overlay:SetAttribute("macrotext", "/use " .. bag .. " " .. slot)
                        end)
                        overlay:SetParent(btn)
                        overlay:ClearAllPoints()
                        overlay:SetAllPoints(btn)
                        overlay:SetFrameStrata("DIALOG")
                        local rowTop = btn.clickArea and btn.clickArea:GetFrameLevel() or btn:GetFrameLevel()
                        overlay:SetFrameLevel(rowTop + 1)
                        overlay:EnableMouse(true)
                        overlay:Show()
                    end
                    gphFrame._refreshImmediate = true
                    if RefreshGPHUI then RefreshGPHUI() end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
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
            end)
            btn.clickArea:SetScript("OnMouseDown", function(_, mouseButton)
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
                            local defer = CreateFrame("Frame", nil, UIParent)
                            defer:SetScript("OnUpdate", function(self) self:SetScript("OnUpdate", nil); if gphFrame then gphFrame._refreshImmediate = true end; if RefreshGPHUI then RefreshGPHUI() end end)
                        end
                    else
                        PickupContainerItem(item.bag, item.slot)
                        -- Defer refresh so list shows slot as empty after pickup
                        local defer = CreateFrame("Frame", nil, UIParent)
                        defer:SetScript("OnUpdate", function(self)
                            self:SetScript("OnUpdate", nil)
                            if gphFrame then gphFrame._refreshImmediate = true end
                            if RefreshGPHUI then RefreshGPHUI() end
                        end)
                    end
                    return
                end
                if IsShiftKeyDown() then return end    -- Shift+right = link in OnClick
                if gphFrame and (GetTime() - (gphFrame.gphLastRowActionTime or 0)) < 0.1 then return end
                if mouseButton == "RightButton" then
                    -- Set selection and position overlay on this row so the upcoming RightMouseUp hits overlay = use/equip
                    gphFrame.gphSelectedItemId = capturedId
                    gphFrame.gphSelectedBag = item.bag
                    gphFrame.gphSelectedSlot = item.slot
                    gphFrame.gphSelectedIndex = itemIdx
                    gphFrame.gphSelectedRowBtn = btn
                    gphFrame.gphSelectedItemLink = item.link
                    gphFrame.gphSelectedTime = time()
                    if gphFrame.gphRightClickUseOverlay and btn then
                        local bag, slot = item.bag, item.slot
                        if bag == nil or slot == nil then
                            local map = Addon.GetItemIdToBagSlot()
                            local t = map and capturedId and map[capturedId]
                            if t then bag, slot = t.bag, t.slot end
                        end
                        if bag ~= nil and slot ~= nil then
                            local overlay = gphFrame.gphRightClickUseOverlay
                            pcall(function()
                                overlay:SetAttribute("type", "macro")
                                overlay:SetAttribute("macrotext", "/use " .. bag .. " " .. slot)
                            end)
                            overlay:SetParent(btn)
                            overlay:ClearAllPoints()
                            overlay:SetAllPoints(btn)
                            overlay:SetFrameStrata("DIALOG")
                            local rowTop = btn.clickArea and btn.clickArea:GetFrameLevel() or btn:GetFrameLevel()
                            overlay:SetFrameLevel(rowTop + 1)
                            overlay:EnableMouse(true)
                            overlay:Show()
                        end
                    end
                    if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                    return
                end
                -- LeftButton: select (only for rows without bag/slot, e.g. destroy ghosts; real slots use LMB for pickup in OnClick)
                gphFrame.gphSelectedItemId = capturedId
                gphFrame.gphSelectedBag = item.bag
                gphFrame.gphSelectedSlot = item.slot
                gphFrame.gphSelectedIndex = itemIdx
                gphFrame.gphSelectedItemLink = item.link
                gphFrame.gphSelectedTime = time()
                gphFrame._refreshImmediate = true
                if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                RefreshGPHUI()
            end)
            btn.clickArea:SetScript("OnEnter", function(self)
                if item.link then
                    Addon.AnchorTooltipRight(self)
                    -- Use SetBagItem so tooltip shows actual bind state (Soulbound); SetHyperlink shows template (Bind on Pickup)
                    if item.bag ~= nil and item.slot ~= nil and GameTooltip.SetBagItem then
                        GameTooltip:SetBagItem(item.bag, item.slot)
                    else
                        local lp = item.link:match("|H(item:[^|]+)|h")
                        if lp then GameTooltip:SetHyperlink(lp) end
                    end
                    -- Real inventory: no "remote control" instructions; only GPH-specific hints
                    if item.isProtected then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Protected — won't be auto-sold", 0.4, 0.8, 0.4)
                    end
                    if item.bag ~= nil then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Right-click: Select  |  Right-click again: Use", 0.5, 0.5, 0.5)
                        GameTooltip:AddLine("Ctrl+click: Protect from autosell  |  Shift+right-click: Link in chat", 0.5, 0.5, 0.5)
                    end
                    GameTooltip:Show()
                elseif item.bag ~= nil then
                    Addon.AnchorTooltipRight(self)
                    GameTooltip:SetText("Empty slot")
                    GameTooltip:Show()
                end
            end)
            btn.clickArea:SetScript("OnLeave", function() GameTooltip:Hide() end)
            yOff = yOff + 18
            end)  -- end pcall
            if not rowOk then
                Addon.AddonPrint("[Fugazi] GPH row " .. tostring(itemIdx) .. " error: " .. tostring(rowErr))
                yOff = yOff + 18
            end
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
                    -- One-frame refresh so the new selection gets highlighted and overlay positioned
                    local defer = CreateFrame("Frame", nil, UIParent)
                    defer:SetScript("OnUpdate", function(self)
                        self:SetScript("OnUpdate", nil)
                        if RefreshGPHUI then RefreshGPHUI() end
                    end)
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

    if gphFrame.gphRightClickUseOverlay then
        local ov = gphFrame.gphRightClickUseOverlay
        local row = gphFrame.gphSelectedRowBtn
        local bag, slot = gphFrame.gphSelectedBag, gphFrame.gphSelectedSlot
        if bag == nil and slot == nil and gphFrame.gphSelectedItemId then
            local map = Addon.GetItemIdToBagSlot and Addon.GetItemIdToBagSlot()
            local t = map and map[gphFrame.gphSelectedItemId]
            if t then bag, slot = t.bag, t.slot end
        end
        if row and bag ~= nil and slot ~= nil then
            pcall(function()
                ov:SetAttribute("type", "macro")
                ov:SetAttribute("macrotext", "/use " .. bag .. " " .. slot)
            end)
            ov:SetParent(row)
            ov:ClearAllPoints()
            ov:SetAllPoints(row)
            ov:SetFrameStrata("DIALOG")
            local rowTop = row.clickArea and row.clickArea:GetFrameLevel() or row:GetFrameLevel()
            ov:SetFrameLevel(rowTop + 1)
            ov:EnableMouse(true)
            ov:Show()
        else
            if gphFrame.HideGPHUseOverlay then gphFrame.HideGPHUseOverlay(gphFrame) end
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
            if gphFrame.gphScrollToDefaultOnNextRefresh then
                gphFrame.gphScrollToDefaultOnNextRefresh = nil
                local sortMode = DB and DB.gphSortMode or "rarity"
                if sortMode == "category" then
                    cur = 0
                elseif gphFrame.gphDefaultScrollY then
                    cur = math.min(gphFrame.gphDefaultScrollY, maxScroll)
                else
                    cur = 0
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
    -- Force collapse button level after refresh so it stays on top of close/sort
    if gphFrame.gphCollapseBtn then
        gphFrame.gphCollapseBtn:Show()
        gphFrame.gphCollapseBtn:SetFrameLevel(gphFrame:GetFrameLevel() + 50)
    end
end

--- Show or hide GPH window; position next to main frame if shown.
local function ToggleGPHFrame()
    -- Reuse frame by global name in case it was created but not assigned (e.g. after an error)
    if _G.TestGPHFrame then gphFrame = _G.TestGPHFrame end
    if not gphFrame then gphFrame = CreateGPHFrame() end
        if gphFrame:IsShown() then
            Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
            gphFrame:Hide()
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedItemLink = nil
        else
            -- Use live global so we don't reset position/scale when main's DB was captured before WoW loaded saved vars
            local SV = _G.FugaziBAGSDB
            if not (SV and SV.gphPoint and SV.gphPoint.point) then
                gphFrame:ClearAllPoints()
                gphFrame:SetPoint("TOP", UIParent, "CENTER", 0, -100)
            end
            if SV and SV.gphScale15 then gphFrame:SetScale(1.5) else gphFrame:SetScale(1) end
            if gphFrame.ApplySkin then gphFrame.ApplySkin() end
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            gphFrame:Show()
            Addon.SaveFrameLayout(gphFrame, "gphShown", "gphPoint")
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
-- Periodic update
----------------------------------------------------------------------
local elapsed_acc, raidinfo_acc = 0, 0
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
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- ElvUI bag/bank frames use OnHide -> CloseBankFrame(), so we must NOT call :Hide() or the bank closes.
-- "Stealth hide": move off-screen, alpha 0, no mouse — frame stays "shown" so OnHide doesn't run.
-- We hide both B.BagFrame (inventory) and B.BankFrame so __FugaziBAGS fully takes over when enabled.
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
        if DB.gphCollapsed == nil then DB.gphCollapsed = false end
        -- Always create our own frame and claim the global. When InstanceTracker is loaded it may have set TestGPHFrame to its (old) frame; reusing that breaks the autosell button (no UpdateInvBtn).
        gphFrame = CreateGPHFrame()
        _G.TestGPHFrame = gphFrame
        _G.ToggleGPHFrame = function()
            if gphFrame then
                if gphFrame:IsShown() then gphFrame:Hide() else gphFrame:Show() end
            end
        end
        if Addon.InstallGPHInvHook then Addon.InstallGPHInvHook() end
        Addon.RestoreFrameLayout(gphFrame, "gphShown", "gphPoint")
        local SV = _G.FugaziBAGSDB
        if not (SV and SV.gphPoint and SV.gphPoint.point) then
            gphFrame:ClearAllPoints()
            gphFrame:SetPoint("TOP", UIParent, "CENTER", 0, -100)
        end
        local scale15 = SV and SV.gphScale15
        if scale15 then gphFrame:SetScale(1.5) else gphFrame:SetScale(1) end
        if gphFrame.ApplySkin then gphFrame.ApplySkin() end
        if gphFrame.UpdateGPHProfessionButtons then gphFrame:UpdateGPHProfessionButtons() end
        if gphFrame:IsShown() then
            gphFrame.gphSelectedItemId = nil
            gphFrame.gphSelectedIndex = nil
            gphFrame.gphSelectedRowBtn = nil
            gphFrame.gphSelectedItemLink = nil
            RefreshGPHUI()
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
                if inv then
                    bf:SetParent(inv)
                    bf:SetScale(1)
                    inv:Show()
                    if RefreshGPHUI then RefreshGPHUI() end
                    do
                        local p, _, rp, x, y = inv:GetPoint(1)
                        if not (p == "TOPLEFT" and rp == "TOP" and x == 2 and y == -80) then
                            Addon.SaveFrameLayout(inv, "gphShown", "gphPoint")
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
                if bf.bankTitleText then
                    bf.bankTitleText:SetText((UnitName and UnitName("target")) or "Bank")
                end
                if RefreshBankUI then RefreshBankUI() end
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
    elseif event == "MERCHANT_SHOW" or event == "GOSSIP_SHOW" or event == "QUEST_GREETING" or event == "MAIL_SHOW" then
        gphNpcDialogTime = GetTime()
        -- At any vendor/NPC/mailbox: hide default bags and show GPH so only FugaziBAGS is visible
        do
            local defer = CreateFrame("Frame")
            defer:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                if Addon.HideBlizzardBags then Addon.HideBlizzardBags() end
                local inv = gphFrame or _G.TestGPHFrame
                if not inv and CreateGPHFrame then inv = CreateGPHFrame() end
                if inv and not inv:IsShown() then
                    if _G.TestGPHFrame then gphFrame = _G.TestGPHFrame end
                    if not gphFrame then gphFrame = inv end
                    inv:Show()
                    if Addon.SaveFrameLayout then Addon.SaveFrameLayout(inv, "gphShown", "gphPoint") end
                    if RefreshGPHUI then RefreshGPHUI() end
                end
            end)
        end
        if event == "MERCHANT_SHOW" then
            Addon.InstallGphGreedyMuteOnce()
            if _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphAutoVendor then Addon.StartGphVendorRun() end
            if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
        end
    elseif event == "MERCHANT_CLOSED" then
        gphNpcDialogTime = nil
        if Addon.FinishGphVendorRun then Addon.FinishGphVendorRun() end
        if gphFrame and gphFrame.UpdateGphSummonBtn then gphFrame.UpdateGphSummonBtn() end
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
    elseif event == "BAG_UPDATE" then
        Addon.DiffBags()
        if gphSession then Addon.DiffBagsGPH() end
        -- Coalesce: defer one RefreshGPHUI to next frame so rapid BAG_UPDATEs don't each trigger a full refresh (use separate frame so we don't overwrite gphFrame's OnUpdate)
        if gphFrame and gphFrame:IsShown() then
            if not Addon.gphBagUpdateDeferFrame then Addon.gphBagUpdateDeferFrame = CreateFrame("Frame") end
            local defer = Addon.gphBagUpdateDeferFrame
            if not defer._gphScheduled then
                defer._gphScheduled = true
                defer:SetScript("OnUpdate", function(self)
                    self:SetScript("OnUpdate", nil)
                    self._gphScheduled = nil
                    if RefreshGPHUI then RefreshGPHUI() end
                end)
            end
        end
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

-- Minimap button: only __FugaziInstanceTracker creates it (avoids duplicate when both addons loaded).