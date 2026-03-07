--[[
================================================================================
  __FugaziInstanceTracker — by Fugazi | WoW 3.3.5a (WotLK)
================================================================================

  WHAT THIS ADDON DOES (in WoW terms)
  ----------------------------------
  • Hourly cap: Tracks how many instances you've entered per hour (like the
    dungeon finder limit). Shows "X/5" and a countdown until your next slot.
  • Lockouts: Lists your saved raid/dungeon lockouts by expansion (Classic,
    TBC, WotLK) — same idea as the calendar lockout list, but in a small window.
  • Ledger: A "run log" — each time you leave a dungeon/raid we save one entry:
    name, duration, gold earned, and items collected. You can click a run to see
    the item list, rename runs, or Shift+right-click items to link them in chat.
  • GPH (Gold Per Hour): Manual sessions you start/stop from __FugaziBAGS; when
    both addons are loaded, "Stop session" saves the run into this Ledger.
  • Item detail popup: When you click "Items" on a run, a second window shows
    the list of items; it can dock next to the Ledger. Search and collapse.

  DATA: The 5-per-hour limit is account-wide. Run history and settings are
  saved so they survive /reload and logout.

  This is a single addon — no separate "core" required.
================================================================================
]]

(function() local L = {}

L.ADDON_NAME = "InstanceTracker"
-- How many instance IDs you can "save" per real-world hour (soft cap; like dungeon finder).
L.MAX_INSTANCES_PER_HOUR = 5
L.HOUR_SECONDS = 3600
-- Max Ledger entries we keep (oldest dropped when full; like a fixed-size logbook).
L.MAX_RUN_HISTORY = 100
-- If you die and re-enter the same instance within this time, we restore the same run instead of starting a new one.
L.MAX_RESTORE_AGE_SECONDS = 5 * 60  -- 5 minutes
-- Width in pixels for scrollable list content (Ledger, item list, etc.); no gap left of scrollbar.
L.SCROLL_CONTENT_WIDTH = 296
-- Max visible chars for stat lines so text doesn't run under the scrollbar; truncate with "..." + tooltip
L.LEDGER_STAT_MAX_CHARS = 38
-- Flush left padding for content (avoids "syntax" indentation); used in Ledger, Run details, main window
L.CONTENT_LEFT_PAD = 4

function L.StripColorCodes(s)
    if not s or s == "" then return "" end
    return tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H[^|]*|h", ""):gsub("|h", "")
end

--- Truncate a WoW-colored string to maxVisibleChars visible characters, preserving color codes so gold amounts stay formatted.
function L.TruncateWithColors(str, maxVisibleChars)
    if not str or str == "" or maxVisibleChars <= 0 then return str or "" end
    local result, i, visible, len = "", 1, 0, #str
    while i <= len do
        if str:sub(i, i + 9):match("^|c%x%x%x%x%x%x%x%x") then
            result = result .. str:sub(i, i + 9)
            i = i + 10
        elseif str:sub(i, i + 1) == "|r" then
            result = result .. "|r"
            i = i + 2
        else
            visible = visible + 1
            if visible > maxVisibleChars - 3 then
                return result .. "..."
            end
            result = result .. str:sub(i, i)
            i = i + 1
        end
    end
    return result
end
-- WoW stack limit; used when confirming "delete all" so we don't try to delete more than one stack at a time.
L.GPH_MAX_STACK = 49

----------------------------------------------------------------------
-- Skins: no FIT-owned skin system. With __FugaziBAGS we use its skin (gphSkin etc).
-- Standalone: default look only.
----------------------------------------------------------------------

--- Applies skin to a frame: BAGS skin when __FugaziBAGS is loaded, else default.
function L.ApplyInstanceTrackerSkin(f)
    if not f then return end

    -- 1. Try FugaziBAGS skinning system first (Primary Source)
    local BSkins = _G.__FugaziBAGS_Skins
    if BSkins and BSkins.ApplyGPHFrameSkin then
        -- Map our specific IT elements to GPH names so BSkins can find them
        if f.itTitleBar and not f.gphTitleBar then f.gphTitleBar = f.itTitleBar end
        if f.itSep and not f.sep then f.sep = f.itSep end
        if f.itHourlyText and not f.statusText then f.statusText = f.itHourlyText end
        
        -- Store our title so it doesn't get replaced by player name
        local savedTitle = f.itTitleText and f.itTitleText:GetText()

        -- Apply the BAGS skin (handles all backdrops, colors, and overrides)
        BSkins.ApplyGPHFrameSkin(f)

        -- Restore title and ensure our specific buttons are skinned
        if savedTitle and f.itTitleText then f.itTitleText:SetText(savedTitle) end
        
        -- Standardize button backgrounds to match BAGS buttons
        local skinName = "original"
        local SV0 = _G.FugaziBAGSDB
        if SV0 and SV0.gphSkin then
            local val = SV0.gphSkin
            if val == "elvui_real" or val == "elvui" or val == "pimp_purple" or val == "fugazi" then skinName = val end
        end
        local btnColor = (BSkins.SKIN and BSkins.SKIN[skinName] and BSkins.SKIN[skinName].btnNormal) or { 0.1, 0.3, 0.15, 0.7 }
        local setBtn = function(btn) 
            if btn and btn.bg then 
                btn.bg:SetTexture(unpack(btnColor)) 
                if BSkins.AddBorder then BSkins.AddBorder(btn, btnColor) end
            end 
        end
        setBtn(f.collapseBtn); setBtn(f.statsBtn); setBtn(f.resetBtn); setBtn(f.gphBtn); setBtn(f.clearBtn)
        
        -- Skin scrollbars if they exist
        if f.scrollFrame and BSkins.SkinScrollBar then
            BSkins.SkinScrollBar(f.scrollFrame)
        end

    else
        -- Standalone: default look only (no skin choices)
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 24,
            insets   = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        f:SetBackdropColor(0.08, 0.08, 0.12, 0.92)
        f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.8)
    end

    -- 4. Font matching: sync title/header fonts with BAGS settings
    -- (always runs after ALL skin paths, including delegation and fallback)
    local SV = _G.FugaziBAGSDB
    if SV and f.itTitleText then
        local fontPath = "Fonts\\FRIZQT__.TTF"
        local titleSize = 12
        if SV.gphCategoryHeaderFontCustom then
            fontPath = (SV.gphCategoryHeaderFont and SV.gphCategoryHeaderFont ~= "") and SV.gphCategoryHeaderFont or fontPath
            local fs = (SV.gphCategoryHeaderFontSize and SV.gphCategoryHeaderFontSize >= 8 and SV.gphCategoryHeaderFontSize <= 20) and SV.gphCategoryHeaderFontSize or 12
            titleSize = math.min(20, fs + 1)
        end
        f.itTitleText:SetFont(fontPath, titleSize, "")
        -- Accent color override
        if SV.gphCategoryHeaderFontCustom and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor then
            local c = SV.gphSkinOverrides.headerTextColor
            if c and type(c) == "table" and #c >= 4 then
                f.itTitleText:SetTextColor(c[1], c[2], c[3], c[4])
            end
        end
    end

    -- 5. Frame opacity (match FugaziBAGS "Frame Opacity" slider: whole window uses gphFrameAlpha)
    local SVop = _G.FugaziBAGSDB
    local fa = (SVop and SVop.gphFrameAlpha) or 1
    f:SetAlpha(fa > 0.99 and 1 or fa)
end

----------------------------------------------------------------------
-- SavedVariables: persisted across /reload and logout (like keybinds).
-- InstanceTrackerDB holds all user settings and run history.
----------------------------------------------------------------------
InstanceTrackerDB = InstanceTrackerDB or {}
if InstanceTrackerDB.fitMute == nil then InstanceTrackerDB.fitMute = false end          -- /fit mute: no chat spam
if InstanceTrackerDB.valuationMode == nil then InstanceTrackerDB.valuationMode = "vendor" end  -- "vendor" or "auction" view for runs
if InstanceTrackerDB.gphInvKeybind == nil then InstanceTrackerDB.gphInvKeybind = true end
if InstanceTrackerDB.gphInvKeybindMigrated ~= true then
    InstanceTrackerDB.gphInvKeybindMigrated = true
    InstanceTrackerDB.gphInvKeybind = true   -- One-time: default B key to open Fugazi inventory
end
if InstanceTrackerDB.gphAutoVendor == nil then InstanceTrackerDB.gphAutoVendor = true end  -- Auto-sell greys at vendor
if InstanceTrackerDB.gphScale15 == nil then InstanceTrackerDB.gphScale15 = false end
if InstanceTrackerDB.gphDestroyList == nil then InstanceTrackerDB.gphDestroyList = {} end  -- Autodelete list (itemId -> info)
if InstanceTrackerDB.gphPreviouslyWornItemIds == nil then InstanceTrackerDB.gphPreviouslyWornItemIds = {} end
-- Per-character "never sell/delete" list (e.g. soul shard, hearthstone).
InstanceTrackerDB.gphProtectedItemIdsPerChar = InstanceTrackerDB.gphProtectedItemIdsPerChar or {}
-- Per-character "protect all of this rarity" (e.g. "protect all blues"); toggled via rarity bar.
InstanceTrackerDB.gphProtectedRarityPerChar = InstanceTrackerDB.gphProtectedRarityPerChar or {}
-- Cache: itemId -> "Weapon"/"Armor"/etc. for category sort; avoids hammering GetItemInfo.
InstanceTrackerDB.gphItemTypeCache = InstanceTrackerDB.gphItemTypeCache or {}
if InstanceTrackerDB.gphCollapseDebug == nil then InstanceTrackerDB.gphCollapseDebug = false end

-- [ADVANCED STATS] Lifetime across all characters/sessions. NEVER reset or replace this table (only add missing keys).
if InstanceTrackerDB.lifetimeStats == nil then
    InstanceTrackerDB.lifetimeStats = {
        totalGoldCopper = 0,
        totalRuns = 0,
        rarityBreakdown = {},
        bestGPH = 0,
        zoneEfficiency = {},
        vendorCopper = 0,
        vendorItemCount = 0,
        repairCopper = 0,
        repairCount = 0,
        instanceDeaths = 0,
        deletedItemCount = 0,
    }
end
L.LS = InstanceTrackerDB.lifetimeStats
-- Only set defaults for missing keys; never overwrite existing lifetime values.
if L.LS.vendorCopper == nil then L.LS.vendorCopper = 0 end
if L.LS.vendorItemCount == nil then L.LS.vendorItemCount = 0 end
if L.LS.repairCopper == nil then L.LS.repairCopper = 0 end
if L.LS.repairCount == nil then L.LS.repairCount = 0 end
if L.LS.instanceDeaths == nil then L.LS.instanceDeaths = 0 end
if L.LS.deletedItemCount == nil then L.LS.deletedItemCount = 0 end
if L.LS.totalGoldCopper == nil then L.LS.totalGoldCopper = 0 end
if L.LS.totalRuns == nil then L.LS.totalRuns = 0 end
if L.LS.bestGPH == nil then L.LS.bestGPH = 0 end

-- Account-wide gold snapshot: [realm#char] = copper (updated on PLAYER_MONEY / login)
InstanceTrackerDB.accountGold = InstanceTrackerDB.accountGold or {}
-- Total gold ever gained (any source) per character; Lifetime tab shows sum, mouseover per char
InstanceTrackerDB.lifetimeGoldGained = InstanceTrackerDB.lifetimeGoldGained or {}
InstanceTrackerDB.lastKnownMoney = InstanceTrackerDB.lastKnownMoney or {}
-- All deaths ever (not just in instance) per character; Lifetime tab shows sum, mouseover per char
InstanceTrackerDB.lifetimeDeaths = InstanceTrackerDB.lifetimeDeaths or {}

-- Per-item aggregates for autosell/autodelete fed by __FugaziBAGS
InstanceTrackerDB.autoDeleteStats = InstanceTrackerDB.autoDeleteStats or { items = {}, totalCount = 0, totalVendorCopper = 0 }
InstanceTrackerDB.autoVendorStats  = InstanceTrackerDB.autoVendorStats  or { items = {}, totalCount = 0, totalVendorCopper = 0 }


--- Returns a unique key for this character (Realm#Name) so we store protected items and settings per toon.
function L.GetGphCharKey()
    local r = (GetRealmName and GetRealmName()) or ""
    local c = (UnitName and UnitName("player")) or ""
    return (r or "") .. "#" .. (c or "")
end

--- Returns this character's "never sell/delete" list (e.g. soul shard). Migrates from old account-wide list once.
function L.GetGphProtectedSet()
    if not InstanceTrackerDB.gphProtectedItemIdsPerChar then
        InstanceTrackerDB.gphProtectedItemIdsPerChar = {}
    end
    local key = L.GetGphCharKey()
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

--- Items that were in your equipment slots and left (e.g. swapped weapon); we auto-protect those so rarity delete doesn't touch them.
function L.GetGphPreviouslyWornOnlySet()
    if not InstanceTrackerDB.gphPreviouslyWornOnlyPerChar then InstanceTrackerDB.gphPreviouslyWornOnlyPerChar = {} end
    local key = L.GetGphCharKey()
    if not InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key] then
        InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key] = {}
    end
    return InstanceTrackerDB.gphPreviouslyWornOnlyPerChar[key]
end

--- Returns "protect all of this rarity" flags (e.g. "protect all blues"). Toggled via the rarity bar; per-item list is separate.
function L.GetGphProtectedRarityFlags()
    if not InstanceTrackerDB.gphProtectedRarityPerChar then InstanceTrackerDB.gphProtectedRarityPerChar = {} end
    local key = L.GetGphCharKey()
    if not InstanceTrackerDB.gphProtectedRarityPerChar[key] then
        InstanceTrackerDB.gphProtectedRarityPerChar[key] = {}
    end
    return InstanceTrackerDB.gphProtectedRarityPerChar[key]
end

--- Global API for other addons: true if this item should not be sold/deleted (per-item or rarity protection).
function L.IsItemProtectedAPI(itemId, qualityArg)
    if not itemId then return false end
    local set = L.GetGphProtectedSet and L.GetGphProtectedSet()
    if set and set[itemId] == true then return true end
    local flags = L.GetGphProtectedRarityFlags and L.GetGphProtectedRarityFlags()
    if not flags then return false end
    local q = qualityArg
    if q == nil and GetItemInfo then local _, _, qq = GetItemInfo(itemId) q = qq end
    return q and flags[q] == true
end
_G.FugaziInstanceTracker_IsItemProtected = function(id) return L.IsItemProtectedAPI(id) end

--- Ensure autosell/autodelete stat tables exist (used by callbacks from __FugaziBAGS).
function L.EnsureAutoStatTables()
    if not InstanceTrackerDB.autoDeleteStats then
        InstanceTrackerDB.autoDeleteStats = { items = {}, totalCount = 0, totalVendorCopper = 0 }
    end
    if not InstanceTrackerDB.autoVendorStats then
        InstanceTrackerDB.autoVendorStats = { items = {}, totalCount = 0, totalVendorCopper = 0 }
    end
end

--- Called by __FugaziBAGS when its autodelete logic destroys items. itemId can be number, or item link (we extract id).
_G.FugaziInstanceTracker_OnAutoDelete = function(itemId, count, vendorCopper)
    if not InstanceTrackerDB or not itemId then return end
    if type(itemId) == "string" and itemId:match("item:%d+") then
        itemId = tonumber(itemId:match("item:(%d+)")) or itemId
    else
        itemId = tonumber(itemId) or itemId
    end
    L.EnsureAutoStatTables()
    count = count or 1
    vendorCopper = vendorCopper or 0

    local LS2 = InstanceTrackerDB.lifetimeStats
    if LS2 then
        LS2.deletedItemCount = (LS2.deletedItemCount or 0) + count
    end
    if currentRun then
        currentRun.itemsAutodeleted = (currentRun.itemsAutodeleted or 0) + count
        currentRun.autodeletedVendorCopper = (currentRun.autodeletedVendorCopper or 0) + vendorCopper
        currentRun.autodeletedItems = currentRun.autodeletedItems or {}
        currentRun.autodeletedItems[itemId] = (currentRun.autodeletedItems[itemId] or 0) + count
    end

    local stats = InstanceTrackerDB.autoDeleteStats
    stats.totalCount = (stats.totalCount or 0) + count
    stats.totalVendorCopper = (stats.totalVendorCopper or 0) + vendorCopper
    stats.items = stats.items or {}
    local entry = stats.items[itemId]
    if not entry then
        entry = { count = 0, vendorCopper = 0 }
        stats.items[itemId] = entry
    end
    entry.count = entry.count + count
    entry.vendorCopper = entry.vendorCopper + vendorCopper
end

--- Called by __FugaziBAGS when its autosell logic sells items.
_G.FugaziInstanceTracker_OnAutoVendor = function(itemId, count, vendorCopper)
    if not InstanceTrackerDB or not itemId then return end
    L.EnsureAutoStatTables()
    count = count or 1
    vendorCopper = vendorCopper or 0

    local stats = InstanceTrackerDB.autoVendorStats
    stats.totalCount = (stats.totalCount or 0) + count
    stats.totalVendorCopper = (stats.totalVendorCopper or 0) + vendorCopper
    stats.items = stats.items or {}
    local entry = stats.items[itemId]
    if not entry then
        entry = { count = 0, vendorCopper = 0 }
        stats.items[itemId] = entry
    end
    entry.count = entry.count + count
    entry.vendorCopper = entry.vendorCopper + vendorCopper
end

-- GPH vendor/summon/greedy/goblin logic removed: __FugaziBAGS owns autosell and summon Greedy when both addons are loaded.

-- Inv toggle: when on, bag key opens GPH instead of default bags (like Bagnon/OneBag: hook ToggleBackpack/OpenAllBags)
L.origToggleBackpack, L.origOpenAllBags = nil, nil
L.gphNpcDialogTime = nil  -- set on MERCHANT_SHOW / GOSSIP_SHOW / QUEST_GREETING so we don't close GPH when game auto-opens bags at NPC
L.merchantGoldAtOpen = nil  -- gold when vendor opened; on MERCHANT_CLOSED delta => vendored (positive) or repair (negative)
L.merchantRepairCostAtOpen = nil  -- repair cost when vendor opened; on MERCHANT_CLOSED we detect spent = this - current cost
function L.GPHInvBagKeyHandler()
    -- Delegate bag key to external GPH/bag addon if present; otherwise just close bags.
    local atVendor = _G.MerchantFrame and _G.MerchantFrame:IsShown()
    local atNpcRecently = L.gphNpcDialogTime and (GetTime() - L.gphNpcDialogTime) < 1.5
    if atVendor or atNpcRecently then
        if CloseAllBags then CloseAllBags() end
        if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
        return
    end
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
    if CloseAllBags then CloseAllBags() end
end
function L.InstallGPHInvHook()
    -- Backwards-compat stub: bag key override is now owned by __FugaziBAGS.
    return
end
function L.RemoveGPHInvHook()
    if L.origToggleBackpack then _G.ToggleBackpack = L.origToggleBackpack end
    if L.origOpenAllBags then _G.OpenAllBags = L.origOpenAllBags end
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
function L.ApplyGPHInvKeyOverride(btn)
    -- Backwards-compat stub: bag key override is now provided by __FugaziBAGS.
end

--- Saves a window's position (and optionally "was it open?") so after /reload we can put it back. Like the game remembering where you dragged the spellbook.
function L.SaveFrameLayout(frame, shownKey, pointKey)
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
    -- Persist scale with position for GPH so /reload restores both
    if pointKey == "gphPoint" and frame.GetScale then
        InstanceTrackerDB.gphScale15 = (frame:GetScale() or 1) >= 1.4
    end
end

--- Restores a window's position (and show/hide) from saved data after /reload.
function L.RestoreFrameLayout(frame, shownKey, pointKey)
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

--- Shrinks a window (collapse) without it jumping: keeps the top edge in place so the title bar stays under your cursor.
function L.CollapseInPlace(frame, collapsedHeight, isSnappedTo)
    if not frame then return end
    local debug = InstanceTrackerDB.gphCollapseDebug
    local inCombat = (InCombatLockdown and InCombatLockdown()) or false
    local heightBefore = frame:GetHeight()
    local pt, relTo, relPt, x, y = frame:GetPoint(1)
    local relToName = relTo and (relTo.GetName and relTo:GetName() or tostring(relTo)) or "nil"
    if debug then
        DEFAULT_CHAT_FRAME:AddMessage("[Fugazi collapse] L.CollapseInPlace: frame=" .. tostring(frame:GetName() or frame) .. " targetH=" .. tostring(collapsedHeight) .. " combat=" .. tostring(inCombat) .. " heightBefore=" .. tostring(heightBefore) .. " anchor=" .. tostring(pt) .. " relTo=" .. tostring(relToName))
    end
    if pt and relTo and isSnappedTo and isSnappedTo(relTo) then
        frame:SetHeight(collapsedHeight)
        if debug then
            DEFAULT_CHAT_FRAME:AddMessage("[Fugazi collapse] L.CollapseInPlace: snapped path; heightAfter=" .. tostring(frame:GetHeight()))
        end
        return
    end
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    frame:SetHeight(collapsedHeight)
    if debug then
        DEFAULT_CHAT_FRAME:AddMessage("[Fugazi collapse] L.CollapseInPlace: re-anchor path; heightAfter=" .. tostring(frame:GetHeight()) .. " (wanted " .. tostring(collapsedHeight) .. ")")
    end
end

--- Returns the label for a run in the Ledger: custom name if you renamed it, otherwise the zone name (e.g. "Utgarde Keep").
function L.GetRunDisplayName(run)
    if not run then return "?" end
    if run.customName and run.customName:match("%S") then return run.customName end
    return run.name or "?"
end

--- Prints a message to chat (yellow addon text). Does nothing if /fit mute is on.
function L.AddonPrint(msg)
    if msg and msg ~= "" and not InstanceTrackerDB.fitMute then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

----------------------------------------------------------------------
-- Runtime state: what the addon "remembers" while you play (not saved).
-- Frames = the actual UI windows; the rest = data for current session.
----------------------------------------------------------------------
local frame = nil              -- Main tracker window (lockouts + hourly cap)
local statsFrame = nil          -- Ledger window (run history list)
local ledgerDetailFrame = nil   -- Second window: one run per "page", Prev/Next flick through runs
local itemDetailFrame = nil     -- Popup that shows "items from this run"
local isInInstance = false
local currentZone = ""

-- Lockout snapshot: when we last asked the game for saved lockouts (to avoid spamming).
local lockoutQueryTime = 0
local lockoutCache = {}

-- Current run: the dungeon/raid you're in right now (saved to Ledger when you leave).
local currentRun = nil
local lastExitedZoneName = nil  -- Zone we just left; used so "has been reset" can mark it as don't-restore
local lastResetZoneName = nil   -- Zone that was just reset; we skip restoring this zone on re-enter but keep run in history

-- Bag tracking for "items gained this run": we take a snapshot when you enter, then only count increases (like a diff).
local bagBaseline = {}         -- Snapshot on enter: itemId -> count
local itemsGained = {}         -- Only goes up; used for "loot this run"
local itemLinksCache = {}      -- itemId -> full item link (so we can show names without calling GetItemInfo every time)
local lastEquippedItemIds = {} -- Items that were in equipment slots; if they appear in bags we treat as "unequipped" not "looted"

local startingGold = 0          -- Gold when you entered the instance (to show "earned this run")

-- GPH (Gold Per Hour) manual session: owned by __FugaziBAGS; we just show/record when both addons loaded.
local gphSession = nil
local gphBagBaseline = {}
local gphItemsGained = {}
local gphFrame = nil            -- The GPH/inventory frame is created by __FugaziBAGS

-- Autodelete / destroy list: double-click red X = delete from bags; Shift+double-click = add to "destroy list".
local gphDeleteClickTime = gphDeleteClickTime or {}   -- First click time per item (0.5s window for second click)
local gphDestroyClickTime = gphDestroyClickTime or {}
local gphDestroyQueue = {}      -- Items waiting to be destroyed (throttled so we don't spam the server)
local gphDestroyerThrottle = 0
L.GPH_DESTROY_DELAY = 0.4   -- Seconds between each queued destroy (like SimpleAutoDelete)

-- Dedicated frame for auto-destroy (delay like SimpleAutoDelete-WOTLK so DeleteCursorItem runs in a valid context)
local gphDestroyerFrame = nil
function L.EnsureGPHDestroyerFrame()
    if gphDestroyerFrame then return end
    gphDestroyerFrame = CreateFrame("Frame")
    gphDestroyerFrame:Hide()
    gphDestroyerFrame:SetScript("OnUpdate", function(self, elapsed)
        if #gphDestroyQueue == 0 then self:Hide(); return end
        gphDestroyerThrottle = gphDestroyerThrottle + elapsed
        if gphDestroyerThrottle >= L.GPH_DESTROY_DELAY then
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
function L.QueueDestroySlotsForItemId(itemId)
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
        L.EnsureGPHDestroyerFrame()
        if gphDestroyerFrame then gphDestroyerFrame:Show() end
    end
end

-- Confirmation state for clear
local clearConfirmPending = false

local gphPendingQuality = gphPendingQuality or {}

--- Delete all items of a given quality from bags (GPH rarity delete).
function L.DeleteAllOfQuality(quality)
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
                    local skip = (itemId and L.GetGphProtectedSet()[itemId]) or false

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
        L.AddonPrint(
            "[InstanceTracker] Deleted " .. deletedCount .. " " .. label .. " items."
        )
    end
end

-- Item quality = WoW's grey/white/green/blue/purple/orange. We use these for colors and labels in the UI.
L.QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d", label = "Trash" },         
    [1] = { r = 1.00, g = 1.00, b = 1.00, hex = "ffffff", label = "White" },
    [2] = { r = 0.12, g = 1.00, b = 0.00, hex = "1eff00", label = "Green" },         -- Note: QUALITY COLOR LABELS ARE HERE! (OFF)
    [3] = { r = 0.00, g = 0.44, b = 0.87, hex = "0070dd", label = "Blue" },
    [4] = { r = 0.64, g = 0.21, b = 0.93, hex = "a335ee", label = "Purple" },
    [5] = { r = 1.00, g = 0.50, b = 0.00, hex = "ff8000", label = "Orange" },
}

-- Shared helpers for value/row formatting

-- Per-run valuation helpers. We only count items that are still in your bags at the end of the run
-- toward auction/vendor value. For runs that also track soldDuringSession, this is driven by
-- item.remainingCount; otherwise we fall back to item.count.
function L.ComputeRunVendorItemsValue(run)
    if not run or not run.items then return 0 end
    local total = 0
    for _, item in ipairs(run.items) do
        local link = item and item.link
        local count = (item and (item.remainingCount or item.count)) or 0
        if link and count > 0 then
            local _, _, _, _, _, _, _, _, _, _, vp = GetItemInfo(link)
            if vp and vp > 0 then
                total = total + vp * count
            end
        end
    end
    return total
end

function L.ComputeRunAuctionItemsValue(run)
    if not run or not run.items then return 0 end
    local Addon = _G.TestAddon or _G.FugaziBAGS
    if not (Addon and Addon.ComputeGPHEstimatedValue) then return 0 end
    local list = {}
    for _, item in ipairs(run.items) do
        local link = item and item.link
        local count = (item and (item.remainingCount or item.count)) or 0
        local quality = (item and item.quality) or 0
        if link and count > 0 then
            list[#list + 1] = { link = link, count = count, quality = quality }
        end
    end
    if #list == 0 then return 0 end
    local total = Addon.ComputeGPHEstimatedValue(list) or 0
    return total
end

-- Row height that tracks FugaziBAGS "Row Icon Size" slider when available, so Ledger rows
-- feel like the inventory list. Falls back to a simple base height when bags aren't loaded.
-- Row height that tracks FugaziBAGS "Row Icon Size" slider when available, so Ledger rows
-- feel like the inventory list. Falls back to a simple base height when bags aren't loaded.
function L.GetFugaziRowHeight(baseHeight)
    local SV = _G.FugaziBAGSDB
    -- 18 is the standard "premium" height for the list mode; match BAGS row icon size slider everywhere
    local rowStep = baseHeight or 18
    if SV and type(SV.gphItemDetailsIconSize) == "number" then
        rowStep = math.max(16, math.min(48, SV.gphItemDetailsIconSize + 6))
    end
    return rowStep
end

--- Reads FugaziBAGS font/color customization and returns settings for IT to match.
--- Returns: { fontPath, titleSize, headerSize, rowSize, rowIconSize, accentColor, skinName }
--- Cached so we don't allocate a new table every second when Ledger/main window OnUpdate runs (was causing memory climb).
L._fontSettingsCache, L._fontSettingsCacheKey = nil, nil
function L.GetFugaziFontSettings()
    local SV = _G.FugaziBAGSDB
    local key = "n"
    if SV then
        key = (SV.gphSkin or "") .. "|" .. (SV.gphCategoryHeaderFontCustom and "1" or "0") .. (SV.gphCategoryHeaderFont or "") .. "|" .. tostring(SV.gphCategoryHeaderFontSize or "")
            .. "|" .. (SV.gphItemDetailsCustom and "1" or "0") .. (SV.gphItemDetailsFont or "") .. "|" .. tostring(SV.gphItemDetailsFontSize or "") .. "|" .. tostring(SV.gphItemDetailsIconSize or "")
            .. "|" .. (SV.gphCategoryHeaderFontCustom and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor and "1" or "0")
    end
    if L._fontSettingsCacheKey == key and L._fontSettingsCache then return L._fontSettingsCache end

    local result = {
        fontPath = "Fonts\\FRIZQT__.TTF",
        titleSize = 12,
        headerSize = 10,
        rowSize = 11,
        rowFontPath = "Fonts\\FRIZQT__.TTF",
        rowIconSize = 16,
        accentColor = nil, -- nil = use skin default
        -- Default FIT row label color (light blue); can be overridden via FugaziBAGS \"FIT row label text\" color.
        rowLabelColor = { 0.5, 0.8, 1.0, 1 },
        skinName = "original",
    }
    if not SV then L._fontSettingsCacheKey = key; L._fontSettingsCache = result; return result end

    -- Resolve skin name
    local val = SV.gphSkin or "original"
    if val == "elvui_real" or val == "elvui" or val == "pimp_purple" or val == "fugazi" then result.skinName = val end

    -- Custom font settings (mirrors BAGS' ApplyCustomizeToFrame logic)
    if SV.gphCategoryHeaderFontCustom then
        local path = (SV.gphCategoryHeaderFont and SV.gphCategoryHeaderFont ~= "") and SV.gphCategoryHeaderFont or "Fonts\\FRIZQT__.TTF"
        local fontSize = (SV.gphCategoryHeaderFontSize and SV.gphCategoryHeaderFontSize >= 8 and SV.gphCategoryHeaderFontSize <= 20) and SV.gphCategoryHeaderFontSize or 12
        result.fontPath = path
        -- Match inventory behaviour: title slightly larger than category header,
        -- and re-use the category header size for sub-headers inside FIT windows.
        result.titleSize = math.min(20, fontSize + 1)
        result.headerSize = fontSize
    end

    -- Row font settings (mirrors BAGS' ApplyItemDetailsToRow logic)
    if SV.gphItemDetailsCustom then
        local rowPath = (SV.gphItemDetailsFont and SV.gphItemDetailsFont ~= "") and SV.gphItemDetailsFont or "Fonts\\FRIZQT__.TTF"
        local rowFontSize = (SV.gphItemDetailsFontSize and SV.gphItemDetailsFontSize >= 8 and SV.gphItemDetailsFontSize <= 16) and SV.gphItemDetailsFontSize or 11
        result.rowSize = rowFontSize
        result.rowFontPath = rowPath
        result.rowIconSize = (SV.gphItemDetailsIconSize and SV.gphItemDetailsIconSize >= 12 and SV.gphItemDetailsIconSize <= 28) and SV.gphItemDetailsIconSize or 16
    end

    -- Accent/header text color override
    if SV.gphCategoryHeaderFontCustom and SV.gphSkinOverrides and SV.gphSkinOverrides.headerTextColor then
        local c = SV.gphSkinOverrides.headerTextColor
        if c and type(c) == "table" and #c >= 4 then
            result.accentColor = c
        end
    end

    -- FIT row label color override (independent of header customization toggle).
    if SV.gphSkinOverrides and SV.gphSkinOverrides.fitRowColor then
        local c = SV.gphSkinOverrides.fitRowColor
        if c and type(c) == "table" and #c >= 3 then
            result.rowLabelColor = { c[1], c[2], c[3], c[4] or 1 }
        end
    end

    L._fontSettingsCacheKey = key
    L._fontSettingsCache = result
    return result
end

--- Applies BAGS-matching fonts and colors to an Instance Tracker frame's title and key elements.
function L.ApplyFugaziFontsToFrame(f)
    if not f then return end
    local fs = L.GetFugaziFontSettings()

    -- Title text: match BAGS title font
    if f.itTitleText then
        f.itTitleText:SetFont(fs.fontPath, fs.titleSize, "")
        if fs.accentColor then
            f.itTitleText:SetTextColor(fs.accentColor[1], fs.accentColor[2], fs.accentColor[3], fs.accentColor[4])
        end
    end
end

--- Colors a label using the configured FIT row label color from FugaziBAGS.
function L.ColorizeFugaziRowLabel(text)
    local settings = L.GetFugaziFontSettings()
    local c = settings.rowLabelColor or { 0.5, 0.8, 1.0, 1 }
    local r = tonumber(c[1]) or 0.5
    local g = tonumber(c[2]) or 0.8
    local b = tonumber(c[3]) or 1.0
    local hex = string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
    return "|cff" .. hex .. tostring(text) .. "|r"
end

--- Styles a section header font string ("--- Current ---", "--- History ---", etc.)
--- Uses BAGS header/title font at header size, distinct from row text.
function L.StyleFugaziHeader(fs)
    if not fs then return end
    local settings = L.GetFugaziFontSettings()
    fs:SetFont(settings.fontPath, settings.headerSize, "")
    if settings.accentColor and type(settings.accentColor) == "table" and #settings.accentColor >= 4 then
        fs:SetTextColor(settings.accentColor[1], settings.accentColor[2], settings.accentColor[3], settings.accentColor[4])
    else
        -- Soft teal/blue similar to original Fugazi header tint
        fs:SetTextColor(0.5, 0.8, 1.0, 1)
    end
end

----------------------------------------------------------------------
-- Instance database: "which expansion does this dungeon belong to?"
-- Used to group lockouts (Classic / TBC / WotLK) and show the right label.
----------------------------------------------------------------------
L.INSTANCE_EXPANSION = {
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

L.EXPANSION_ORDER = { "classic", "tbc", "wotlk" }
local EXPANSION_LABELS = {
    classic = "|cffffcc00Classic|r",
    tbc     = "|cff1eff00The Burning Crusade|r",
    wotlk   = "|cff0070ddWrath of the Lich King|r",
}

function L.GetExpansion(instanceName)
    if not instanceName then return nil end
    local direct = L.INSTANCE_EXPANSION[instanceName]
    if direct then return direct end
    for knownName, exp in pairs(L.INSTANCE_EXPANSION) do
        if instanceName:find(knownName, 1, true) or knownName:find(instanceName, 1, true) then
            L.INSTANCE_EXPANSION[instanceName] = exp
            return exp
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Formatting: turn numbers into readable text (time, gold, quality colors).
----------------------------------------------------------------------
--- Countdown timer: "5m 30s" or "Ready" when zero (like the hourly cap next-slot display).
function L.FormatTime(seconds)
    if seconds <= 0 then
        return "Ready"
    end

    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)

    -- Very long lockouts: only show hours (no minutes/seconds ticking for days).
    if h >= 100 then
        return string.format("%dh", h)
    end

    -- More than 5 minutes left:
    -- - With hours: show "112h 57m"
    -- - Without hours: show "59m"
    if seconds > 5 * 60 then
        if h > 0 then
            return string.format("%dh %02dm", h, m)
        elseif m > 0 then
            return string.format("%dm", m)
        end
    end

    -- Last 5 minutes: show seconds as well.
    if h > 0 then
        return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

--- Short duration: "5m 30s" (used in Ledger and run tooltips).
function L.FormatTimeMedium(seconds)
    if seconds <= 0 then return "0s" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh %dm", h, m)
    elseif m > 0 then return string.format("%dm %ds", m, s)
    else return string.format("%ds", s) end
end

--- Turns copper into colored "Xg Xs Xc" (gold/silver/copper) for display.
function L.FormatGold(copper)
    if not copper or copper <= 0 then return "|cffeda55f0c|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("|cffffd700%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, s, c)
    elseif s > 0 then return string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else return string.format("|cffeda55f%d|rc", c) end
end

--- Short gold string for tight UI with inventory-style colors (gold yellow, silver grey, copper orange); full amount in tooltip.
function L.FormatGoldShort(copper)
    if not copper or copper <= 0 then return "|cffeda55f0c|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("|cffffd700%d|rg", g) end
    if s > 0 then return string.format("|cffc7c7cf%d|rs", s) end
    return string.format("|cffeda55f%d|rc", c)
end

--- Copper to plain "Xg Xs Xc" (no color).
function L.FormatGoldPlain(copper)
    if not copper or copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then return string.format("%ds %dc", s, c)
    else return string.format("%dc", c) end
end

--- Timestamp to "DD.M.YY - HH:MM".
function L.FormatDateTime(timestamp)
    if not timestamp then return "" end
    local dt = date("*t", timestamp)
    if not dt then return "" end
    -- Format: DD.M.YY - HH:MM (e.g., "11.2.26 - 14:30")
    return string.format("%d.%d.%d - %02d:%02d", dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
end

--- Wrap text in color (r,g,b 0-1).
function L.ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

--- Private tooltip for scanning item tooltips (never touch GameTooltip so bag hover works).
local scanTooltip = nil
function L.GetScanTooltip()
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "FugaziInstanceTrackerScanTT", UIParent, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTooltip:ClearAllPoints()
        scanTooltip:SetPoint("CENTER", UIParent, "CENTER", 99999, 99999)  -- off-screen when shown
    end
    return scanTooltip
end

--- Build map itemId -> {bag, slot} (first slot per item) for GetItemCooldown.
function L.GetItemIdToBagSlot()
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
function L.ItemIdHasCooldown(itemId, itemIdToSlot)
    if not itemId or not itemIdToSlot then return false end
    local t = itemIdToSlot[itemId]
    if not t or not GetContainerItemCooldown then return false end
    local start, duration = GetContainerItemCooldown(t.bag, t.slot)
    if not duration or duration <= 0 then return false end
    return (start or 0) + duration > GetTime()
end

--- True if the item's tooltip contains "Cooldown remaining:" (e.g. potion on CD). Uses private tooltip.
function L.ItemLinkHasCooldownRemaining(link)
    if not link or link == "" then return false end
    local st = L.GetScanTooltip()
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
function L.AnchorTooltipRight(ownerFrame)
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

--- Format quality counts for Ledger: numbers only in rarity color (no "Trash"/"Green"/"Blue" labels) to save space.
function L.FormatQualityCounts(qc)
    if not qc then return "" end
    local parts = {}
    for q = 0, 5 do
        local count = qc[q]
        if count and count > 0 then
            local info = L.QUALITY_COLORS[q]
            if info then
                table.insert(parts, "|cff" .. info.hex .. count .. "|r")
            end
        end
    end
    if #parts == 0 then return "|cff555555-|r" end
    return table.concat(parts, "  ")
end

--- Drops instance entries older than 1 hour from the "recent instances" list (so the X/5 count is accurate).
function L.PurgeOld()
    local now = time()
    local fresh = {}
    for _, entry in ipairs(InstanceTrackerDB.recentInstances or {}) do
        if (entry.time + L.HOUR_SECONDS) > now then fresh[#fresh + 1] = entry end
    end
    InstanceTrackerDB.recentInstances = fresh
end

--- Return current instance count this hour (after purging old entries).
function L.GetInstanceCount()
    L.PurgeOld()
    return #(InstanceTrackerDB.recentInstances or {})
end

--- Remove a single entry from recentInstances by index.
function L.RemoveInstance(index)
    local recent = InstanceTrackerDB.recentInstances or {}
    if index >= 1 and index <= #recent then
        table.remove(recent, index)
        L.AddonPrint(
            L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed entry #" .. index .. "."
        )
    end
end

--- Record entering an instance (name) and print count this hour.
function L.RecordInstance(name)
    if not InstanceTrackerDB.recentInstances then InstanceTrackerDB.recentInstances = {} end
    L.PurgeOld()
    local now = time()
    for _, entry in ipairs(InstanceTrackerDB.recentInstances) do
        if entry.name == name and (now - entry.time) < 60 then return end
    end
    table.insert(InstanceTrackerDB.recentInstances, { name = name, time = time() })
    L.AddonPrint(
        L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Entered: " .. L.ColorText(name, 1, 1, 0.6)
        .. " (" .. L.ColorText(L.GetInstanceCount() .. "/" .. L.MAX_INSTANCES_PER_HOUR, 1, 0.6, 0.2)
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

--- Takes a snapshot of your bags when you enter a dungeon; we compare later to see what you looted this run.
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

--- Compares current bags to the snapshot we took when you entered; adds any increase to "items gained this run". Protected items and hearthstone don't count as loot.
local function DiffBags()
    local current = ScanBags()
    local currentEquipped = GetEquippedItemIds()
    local protected = L.GetGphProtectedSet()
    local previouslyWornOnly = L.GetGphPreviouslyWornOnlySet()
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
                    -- Track all qualities including greys (quality 0) so the item list shows full loot.
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
    if currentRun then
        InstanceTrackerDB.currentRun = currentRun
        InstanceTrackerDB.bagBaseline = bagBaseline
        InstanceTrackerDB.itemsGained = itemsGained
    end
end

-- NOTE: Legacy standalone GPH session logic (DiffBagsGPH / StartGPHSession / StopGPHSession)
-- has been removed. __FugaziBAGS now owns all GPH sessions and inventory UI; this addon
-- only records finished sessions via FugaziInstanceTracker_RecordGPHRun.

--- Sum vendor (sell) value of items from a GPH item list. Used when "Use auction value" is off.
local function SumVendorValueFromItemList(itemList)
    if not itemList or type(itemList) ~= "table" then return 0 end
    local total = 0
    for _, it in ipairs(itemList) do
        local sell = (it and it.sellPrice) and it.sellPrice or 0
        local cnt = (it and it.count) and it.count or 1
        total = total + (sell * cnt)
    end
    return total
end

--- API for __FugaziBAGS: record a GPH session into the InstanceTracker ledger when both addons are loaded.
--- Called by BAGS when user stops a session from the inventory (play/stop button).
--- BAGS is responsible for computing estimatedValueCopper (usually raw gold + auction-style item value).
--- Optional: repairCount, repairCopper, deaths, itemsAutodeleted, vendorGoldCopper, autodeletedVendorCopper for this session (for Run details).
--- Signature: (startTime, endTime, startGold, goldEarned, itemList, qualityCounts [, estimatedValueCopper [, estimatedGPHCopper [, repairCount [, repairCopper [, deaths [, itemsAutodeleted [, vendorGoldCopper [, autodeletedVendorCopper ]]]]]]]])
_G.FugaziInstanceTracker_RecordGPHRun = function(startTime, endTime, startGold, goldEarned, itemList, qualityCounts, estimatedValueCopper, estimatedGPHCopper, repairCount, repairCopper, deaths, itemsAutodeleted, vendorGoldCopper, autodeletedVendorCopper)
    if not startTime or not endTime or not InstanceTrackerDB then return end
    local dur = endTime - startTime
    local run = {
        name = "GPH" .. (L.FormatDateTime(startTime) ~= "" and (" - " .. L.FormatDateTime(startTime)) or ""),
        enterTime = startTime,
        exitTime = endTime,
        duration = dur,
        goldCopper = goldEarned or 0,
        qualityCounts = qualityCounts or {},
        items = itemList or {},
        estimatedValueCopper = estimatedValueCopper,
        estimatedGPHCopper = estimatedGPHCopper,
        repairCount = repairCount or 0,
        repairCopper = repairCopper or 0,
        deaths = deaths or 0,
        itemsAutodeleted = itemsAutodeleted or 0,
        vendorGold = vendorGoldCopper or 0,
        autodeletedVendorCopper = autodeletedVendorCopper or 0,
    }
    if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
    table.insert(InstanceTrackerDB.runHistory, 1, run)
    while #InstanceTrackerDB.runHistory > L.MAX_RUN_HISTORY do
        table.remove(InstanceTrackerDB.runHistory)
    end
    L.AddonPrint(
        L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "GPH session recorded: " .. L.FormatTimeMedium(dur)
        .. " | " .. L.FormatGoldPlain(goldEarned or 0)
        .. " |cff44ff44 - Saved to Run Stats history|r"
    )

    -- [ADVANCED STATS] Update lifetime/analytic data
    local LS = InstanceTrackerDB.lifetimeStats
    if L.LS then
        L.LS.totalGoldCopper = (L.LS.totalGoldCopper or 0) + (goldEarned or 0)
        L.LS.totalRuns = (L.LS.totalRuns or 0) + 1
        
        -- Rarity breakdown
        L.LS.rarityBreakdown = L.LS.rarityBreakdown or {}
        if qualityCounts then
            for q, count in pairs(qualityCounts) do
                L.LS.rarityBreakdown[q] = (L.LS.rarityBreakdown[q] or 0) + count
            end
        end

        -- Best GPH
        local gph = estimatedGPHCopper or (dur > 60 and (goldEarned or 0) / (dur / 3600)) or 0
        if gph > (L.LS.bestGPH or 0) then
            L.LS.bestGPH = gph
        end

        -- Zone efficiency: use current zone for GPH sessions
        if dur > 30 then
            local zoneName = (GetRealZoneText and GetRealZoneText()) or "Unknown"
            if zoneName and zoneName ~= "" then
                L.LS.zoneEfficiency = L.LS.zoneEfficiency or {}
                local ze = L.LS.zoneEfficiency[zoneName]
                if not ze then
                    ze = { totalGold = 0, totalDuration = 0, runCount = 0 }
                    L.LS.zoneEfficiency[zoneName] = ze
                end
                ze.totalGold = ze.totalGold + ((goldEarned or 0) / 10000) -- convert copper to gold
                ze.totalDuration = ze.totalDuration + dur
                ze.runCount = ze.runCount + 1
            end
        end
    end

    if statsFrame and statsFrame:IsShown() and type(RefreshStatsUI) == "function" then
        RefreshStatsUI()
    end
end

----------------------------------------------------------------------
-- Stats: run tracking helpers
----------------------------------------------------------------------
--- If the player re-enters the same dungeon (e.g. after dying and being teleported out),
-- restore the most recent run for that zone from history so the session continues.
-- Only restores if the run ended within L.MAX_RESTORE_AGE_SECONDS (5 min); after that or if instance reset, start fresh.
local function RestoreRunFromHistory(zoneName)
    local history = InstanceTrackerDB.runHistory
    if not history or #history == 0 or not zoneName or zoneName == "" then return false end
    -- If this zone was just reset, don't restore (start fresh) but keep the run in the list
    if lastResetZoneName and lastResetZoneName == zoneName then
        lastResetZoneName = nil
        return false
    end
    local now = time()
    for i = 1, #history do
        local run = history[i]
        if run and run.name == zoneName then
            local exitTime = run.exitTime or run.enterTime
            if (now - exitTime) > L.MAX_RESTORE_AGE_SECONDS then
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
                repairCount = run.repairCount or 0,
                repairCopper = run.repairCopper or 0,
                deaths = run.deaths or 0,
                itemsAutodeleted = run.itemsAutodeleted or 0,
                autodeletedVendorCopper = run.autodeletedVendorCopper or 0,
                autodeletedItems = {},
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
            L.AddonPrint(
                L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. "Resumed previous run: " .. L.ColorText(run.name, 1, 1, 0.6) .. "."
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
        repairCount = 0,
        repairCopper = 0,
        deaths = 0,
        itemsAutodeleted = 0,
        autodeletedVendorCopper = 0,
        autodeletedItems = {},
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
    L.AddonPrint(
        L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Stats tracking started for " .. L.ColorText(name, 1, 1, 0.6) .. "."
    )
end

--- Called when you leave the instance: saves the run to the Ledger (duration, gold, items) and clears current run state.
local function FinalizeRun()
    if not currentRun then return end
    DiffBags()
    -- Gold earned = current money - starting money
    local goldEarned = GetMoney() - startingGold
    if goldEarned < 0 then goldEarned = 0 end
    currentRun.goldCopper = goldEarned

    local now = time()

    -- Final bag snapshot so we can distinguish between "kept" vs "sold during run"
    local finalCounts = ScanBags()
    local baseCounts = bagBaseline or {}

    -- Dungeon runs: item list = what was looted. No sold/autodeleted flags.
    local itemList = {}
    for itemId, item in pairs(currentRun.items) do
        local totalCount = item.count or 0
        local finalCount = math.max(0, (finalCounts[itemId] or 0) - (baseCounts[itemId] or 0))
        local soldCount = totalCount > finalCount and (totalCount - finalCount) or 0
        table.insert(itemList, {
            link = item.link,
            quality = item.quality,
            count = totalCount,
            name = item.name,
            remainingCount = finalCount,
            soldCount = soldCount,
            soldDuringSession = false,
            autodeletedDuringSession = false,
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
        repairCount = currentRun.repairCount or 0,
        repairCopper = currentRun.repairCopper or 0,
        deaths = currentRun.deaths or 0,
        itemsAutodeleted = currentRun.itemsAutodeleted or 0,
        autodeletedVendorCopper = currentRun.autodeletedVendorCopper or 0,
        characterName = UnitName("player"),
    }

    if not InstanceTrackerDB.runHistory then InstanceTrackerDB.runHistory = {} end
    table.insert(InstanceTrackerDB.runHistory, 1, run)
    while #InstanceTrackerDB.runHistory > L.MAX_RUN_HISTORY do
        table.remove(InstanceTrackerDB.runHistory)
    end

    L.AddonPrint(
        L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
        .. "Run complete: " .. L.ColorText(run.name, 1, 1, 0.6)
        .. " - " .. L.FormatTimeMedium(run.duration)
        .. " | " .. L.FormatGoldPlain(run.goldCopper)
    )

    -- [ADVANCED STATS] Update lifetime/analytic data
    local LS = InstanceTrackerDB.lifetimeStats
    if L.LS then
        L.LS.totalGoldCopper = (L.LS.totalGoldCopper or 0) + (run.goldCopper or 0)
        L.LS.totalRuns = (L.LS.totalRuns or 0) + 1
        
        -- Rarity breakdown
        L.LS.rarityBreakdown = L.LS.rarityBreakdown or {}
        if run.qualityCounts then
            for q, count in pairs(run.qualityCounts) do
                L.LS.rarityBreakdown[q] = (L.LS.rarityBreakdown[q] or 0) + count
            end
        end

        -- Best GPH (Gold Per Hour)
        if run.duration and run.duration > 60 then -- Only count runs > 1 min
            local gph = (run.goldCopper or 0) / (run.duration / 3600)
            if gph > (L.LS.bestGPH or 0) then
                L.LS.bestGPH = gph
            end
        end

        -- Zone Efficiency
        if run.name and run.name ~= "" and not run.name:find("GPH") then
            L.LS.zoneEfficiency = L.LS.zoneEfficiency or {}
            local ze = L.LS.zoneEfficiency[run.name] or { totalGold = 0, totalDuration = 0, runCount = 0 }
            ze.totalGold = ze.totalGold + (run.goldCopper or 0)
            ze.totalDuration = ze.totalDuration + (run.duration or 0)
            ze.runCount = ze.runCount + 1
            L.LS.zoneEfficiency[run.name] = ze
        end
    end


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

-- (Duplicate FugaziInstanceTracker_RecordGPHRun removed — the _G version at line ~1217
-- already handles lifetime stats aggregation and is the single source of truth.)

----------------------------------------------------------------------
-- Lockout cache
----------------------------------------------------------------------
local function UpdateLockoutCache()
    lockoutQueryTime = time()
    local numSaved = GetNumSavedInstances()
    -- Grow or shrink lockoutCache in-place to avoid allocating new tables every refresh.
    for i = 1, numSaved do
        local instName, instID, instReset, instDiff, locked, extended, mostsig, isRaid = GetSavedInstanceInfo(i)
        if instName then
            local info = lockoutCache[i]
            if not info then
                info = {}
                lockoutCache[i] = info
            end
            info.name = instName
            info.id = instID
            info.resetAtQuery = instReset
            info.diff = instDiff
            info.locked = locked
            info.extended = extended
            info.isRaid = isRaid
        else
            lockoutCache[i] = nil
        end
    end
    -- Trim any leftover entries if the number of saved instances shrank.
    for i = numSaved + 1, #lockoutCache do
        lockoutCache[i] = nil
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
    -- Dungeon runs: show only what was looted. No sold/autodeleted.
    local itemList = {}
    for _, item in pairs(currentRun.items) do
        local totalCount = item.count or 0
        table.insert(itemList, {
            link = item.link,
            quality = item.quality,
            count = totalCount,
            name = item.name,
            remainingCount = totalCount,
            soldCount = 0,
            soldDuringSession = false,
            autodeletedDuringSession = false,
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

----------------------------------------------------------------------
-- UI: Object pools (wrapped in do block to stay under Lua 5.1 limit of 200 locals per function)
----------------------------------------------------------------------
local ResetPools, ResetStatsPools, GetRow, GetText, GetStatsRow, GetStatsText, GetTopItemRow, ResetTopItemRowPool
do
    local ROW_POOL, ROW_POOL_USED = {}, 0
    local TEXT_POOL, TEXT_POOL_USED = {}, 0
    local STATS_ROW_POOL, STATS_ROW_POOL_USED = {}, 0
    local STATS_TEXT_POOL, STATS_TEXT_POOL_USED = {}, 0

    ResetPools = function()
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

    --- Ledger row/text pools: we reuse the same row and text frames instead of creating new ones each refresh (avoids memory leak and keeps UI snappy).
    ResetStatsPools = function()
    for i = 1, STATS_ROW_POOL_USED do
        if STATS_ROW_POOL[i] then
            STATS_ROW_POOL[i]:Hide()
            STATS_ROW_POOL[i]:EnableMouse(false)
            if STATS_ROW_POOL[i].deleteBtn then STATS_ROW_POOL[i].deleteBtn:Hide() end
        end
    end
    STATS_ROW_POOL_USED = 0
    for i = 1, STATS_TEXT_POOL_USED do
        if STATS_TEXT_POOL[i] then STATS_TEXT_POOL[i]:SetText(""); STATS_TEXT_POOL[i]:Hide() end
    end
    STATS_TEXT_POOL_USED = 0
    ResetTopItemRowPool()
    end

    GetRow = function(parent, showDelete)
    ROW_POOL_USED = ROW_POOL_USED + 1
    local row = ROW_POOL[ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
    
    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    local rh = fontSettings.rowSize and (fontSettings.rowSize + 4) or 16
    row:SetHeight(rh)
    row.left:SetFont(rowFont, fontSettings.rowSize, "")
    row.right:SetFont(rowFont, fontSettings.rowSize, "")
    
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

    GetText = function(parent)
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

    GetStatsRow = function(parent, withDelete, isTwoLine)
    STATS_ROW_POOL_USED = STATS_ROW_POOL_USED + 1
    local row = STATS_ROW_POOL[STATS_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(L.SCROLL_CONTENT_WIDTH)
        row:SetHeight(L.GetFugaziRowHeight(16))

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
            L.AnchorTooltipRight(self)
            GameTooltip:AddLine("Remove this run", 1, 0.4, 0.4)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function(self)
            self:SetText("|cffff4444x|r")
            GameTooltip:Hide()
        end)
        row.deleteBtn = delBtn

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        left:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        left:SetJustifyH("LEFT")
        row.left = left
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        right:SetJustifyH("RIGHT")
        row.right = right
        
        local subLeft = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        subLeft:SetPoint("BOTTOMLEFT", delBtn, "BOTTOMRIGHT", 2, 0)
        subLeft:SetJustifyH("LEFT")
        row.subLeft = subLeft
        local subRight = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        subRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
        subRight:SetJustifyH("RIGHT")
        row.subRight = subRight
        
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.08)
        hl:Hide()
        row.highlight = hl
        local selBg = row:CreateTexture(nil, "BACKGROUND")
        selBg:SetAllPoints()
        selBg:SetTexture(0.22, 0.42, 0.18, 0.55)
        selBg:Hide()
        row.selectedBg = selBg
        STATS_ROW_POOL[STATS_ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    
    if isTwoLine then
        row:SetHeight(math.max(26, fontSettings.rowSize * 2.2 + 2))
        local leftOff = withDelete and 16 or 4
        row.left:ClearAllPoints()
        row.left:SetPoint("TOPLEFT", row, "TOPLEFT", leftOff, -2)
        row.right:ClearAllPoints()
        row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
        row.subLeft:ClearAllPoints()
        row.subLeft:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", leftOff, 2)
        row.subRight:ClearAllPoints()
        row.subRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 2)
        row.subLeft:Show()
        row.subRight:Show()
    else
        row:SetHeight(L.GetFugaziRowHeight(16))
        local leftOff = withDelete and 16 or 4
        row.left:ClearAllPoints()
        row.left:SetPoint("LEFT", row, "LEFT", leftOff, 0)
        row.right:ClearAllPoints()
        row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.subLeft:Hide()
        row.subRight:Hide()
    end
    
    row.left:SetFont(rowFont, fontSettings.rowSize, "")
    row.right:SetFont(rowFont, fontSettings.rowSize, "")
    local subSize = math.max(8, fontSettings.rowSize - 2)
    row.subLeft:SetFont(rowFont, subSize, "")
    row.subRight:SetFont(rowFont, subSize, "")
    
    row.left:SetText("")
    row.right:SetText("")
    row.subLeft:SetText("")
    row.subRight:SetText("")
    row.highlight:Hide()
    if row.selectedBg then row.selectedBg:Hide() end
    row:EnableMouse(false)
    row:SetScript("OnMouseUp", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)

    if withDelete then
        row.deleteBtn:Show()
    else
        row.deleteBtn:Hide()
    end
    return row
    end

    GetStatsText = function(parent)
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
    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    fs:SetFont(rowFont, fontSettings.rowSize, "")
    return fs
    end

    --- Pool of 10 row frames for "Top autodeleted" / "Top autosold" (item name with rarity+link+tooltip, count+gold with full-amount tooltip).
    local TOP_ITEM_ROW_POOL, TOP_ITEM_ROW_POOL_USED = {}, 0
    ResetTopItemRowPool = function()
    for i = 1, TOP_ITEM_ROW_POOL_USED do if TOP_ITEM_ROW_POOL[i] then TOP_ITEM_ROW_POOL[i]:Hide() end end
    TOP_ITEM_ROW_POOL_USED = 0
    end
    GetTopItemRow = function(parent, fontSettings, rowH, rightMargin, rightBlockW)
    TOP_ITEM_ROW_POOL_USED = TOP_ITEM_ROW_POOL_USED + 1
    local row = TOP_ITEM_ROW_POOL[TOP_ITEM_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetHeight(rowH)
        row:EnableMouse(false)
        local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
        local rs = fontSettings.rowSize or 11
        local idx = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        idx:SetPoint("LEFT", row, "LEFT", 8, 0)
        idx:SetFont(rowFont, rs, "")
        row.indexFs = idx
        local nameFrame = CreateFrame("Frame", nil, row)
        nameFrame:SetPoint("LEFT", idx, "RIGHT", 2, 0)
        nameFrame:SetPoint("RIGHT", row, "RIGHT", -(rightBlockW + rightMargin), 0)
        nameFrame:SetHeight(rowH)
        nameFrame:EnableMouse(true)
        nameFrame.fs = nameFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFrame.fs:SetPoint("LEFT", nameFrame, "LEFT", 0, 0)
        nameFrame.fs:SetFont(rowFont, rs, "")
        nameFrame.fs:SetJustifyH("LEFT")
        nameFrame.fs:SetWordWrap(false)
        nameFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.itemLink then
                local lp = self.itemLink:match("|H(item:[^|]+)|h") or self.itemLink
                if lp then GameTooltip:SetHyperlink(lp) end
            end
            if self.fullName and #(self.fullName or "") > 14 then
                GameTooltip:AddLine(self.fullName, 0.8, 0.8, 0.8)
            end
            GameTooltip:AddLine("Shift+Right-click: link in chat", 0.5, 0.7, 0.5)
            GameTooltip:Show()
        end)
        nameFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
        nameFrame:SetScript("OnMouseUp", function(self, button)
            if IsShiftKeyDown() and button == "RightButton" and self.itemLink then
                local toInsert = self.itemLink
                if not toInsert:match("|Hitem:") and GetItemInfo then
                    local id = tonumber(toInsert:match("item:(%d+)"))
                    if id then
                        local _, link = GetItemInfo(id)
                        if link then toInsert = link end
                    end
                end
                local chatBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                if not chatBox and ChatEdit_ActivateChat and _G.ChatFrame1EditBox then ChatEdit_ActivateChat(_G.ChatFrame1EditBox); chatBox = _G.ChatFrame1EditBox end
                if chatBox then chatBox:Insert(toInsert) end
            end
        end)
        row.itemBtn = nameFrame
        local rightFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rightFs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -rightMargin, 0)
        rightFs:SetJustifyH("RIGHT")
        rightFs:SetWordWrap(false)
        rightFs:SetFont(rowFont, rs, "")
        row.rightFs = rightFs
        local goldHover = CreateFrame("Frame", nil, row)
        goldHover:SetPoint("TOPRIGHT", row, "TOPRIGHT", -rightMargin, 0)
        goldHover:SetSize(rightBlockW, rowH)
        goldHover:EnableMouse(true)
        goldHover:SetScript("OnEnter", function(self)
            if self.copper then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:AddLine(L.FormatGold(self.copper), 1, 0.85, 0.4)
                GameTooltip:Show()
            end
        end)
        goldHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.goldHover = goldHover
        TOP_ITEM_ROW_POOL[TOP_ITEM_ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    return row
    end
end

----------------------------------------------------------------------
-- Ledger Detail window: separate pools so we don't steal Ledger rows
----------------------------------------------------------------------
L.DETAIL_ROW_POOL, L.DETAIL_ROW_POOL_USED = {}, 0
L.DETAIL_TEXT_POOL, L.DETAIL_TEXT_POOL_USED = {}, 0

function L.ResetDetailPools()
    for i = 1, L.DETAIL_ROW_POOL_USED do
        if L.DETAIL_ROW_POOL[i] then
            L.DETAIL_ROW_POOL[i]:Hide()
            L.DETAIL_ROW_POOL[i]:EnableMouse(false)
            if L.DETAIL_ROW_POOL[i].deleteBtn then L.DETAIL_ROW_POOL[i].deleteBtn:Hide() end
        end
    end
    L.DETAIL_ROW_POOL_USED = 0
    for i = 1, L.DETAIL_TEXT_POOL_USED do
        if L.DETAIL_TEXT_POOL[i] then L.DETAIL_TEXT_POOL[i]:Hide() end
    end
    L.DETAIL_TEXT_POOL_USED = 0
end

function L.GetDetailRow(parent, withDelete)
    L.DETAIL_ROW_POOL_USED = L.DETAIL_ROW_POOL_USED + 1
    local row = L.DETAIL_ROW_POOL[L.DETAIL_ROW_POOL_USED]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetWidth(L.SCROLL_CONTENT_WIDTH)
        row:SetHeight(L.GetFugaziRowHeight(16))
        -- Detail rows no longer need an inline delete button; deletion is handled via Ctrl+Right-click on the Ledger overview.
        -- Reserve a fixed block on the right for numeric values so labels never overlap the gold text.
        local rightBlockW = 120
        local left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        left:SetPoint("LEFT", row, "LEFT", 0, 0)
        left:SetJustifyH("LEFT")
        left:SetWidth(L.SCROLL_CONTENT_WIDTH - 24 - rightBlockW)
        left:SetWordWrap(false)
        row.left = left
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        right:SetJustifyH("RIGHT")
        right:SetWidth(rightBlockW)
        right:SetWordWrap(false)
        row.right = right
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.08)
        hl:Hide()
        row.highlight = hl
        L.DETAIL_ROW_POOL[L.DETAIL_ROW_POOL_USED] = row
    end
    row:SetParent(parent)
    row:Show()
    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    row:SetHeight(L.GetFugaziRowHeight(16))
    row.left:SetFont(rowFont, fontSettings.rowSize, "")
    row.right:SetFont(rowFont, fontSettings.rowSize, "")
    row.left:SetText("")
    row.right:SetText("")
    row.highlight:Hide()
    row:EnableMouse(false)
    row:SetScript("OnMouseUp", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    -- withDelete is now ignored; delete is driven from the Ledger only.
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    return row
end

function L.GetDetailText(parent)
    L.DETAIL_TEXT_POOL_USED = L.DETAIL_TEXT_POOL_USED + 1
    local fs = L.DETAIL_TEXT_POOL[L.DETAIL_TEXT_POOL_USED]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        L.DETAIL_TEXT_POOL[L.DETAIL_TEXT_POOL_USED] = fs
    end
    fs:SetParent(parent)
    fs:ClearAllPoints()
    fs:Show()
    fs:SetText("")
    fs:SetWidth(L.SCROLL_CONTENT_WIDTH - 24)
    fs:SetWordWrap(false)
    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    fs:SetFont(rowFont, fontSettings.rowSize, "")
    return fs
end

----------------------------------------------------------------------
-- Item Detail Popup: the window that shows "items from this run" when you
-- click an Items row in the Ledger. Can dock next to Ledger; supports search.
----------------------------------------------------------------------
-- If we don't have the item in cache we show a ? icon instead of a broken texture.
L.ITEM_ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
function L.GetSafeItemTexture(linkOrId, _storedTexture)
    local id = type(linkOrId) == "number" and linkOrId or nil
    if not id and type(linkOrId) == "string" then id = tonumber((linkOrId or ""):match("item:(%d+)")) end
    local tex = nil
    if GetItemInfo then
        tex = (id and select(10, GetItemInfo(id))) or (linkOrId and select(10, GetItemInfo(linkOrId)))
    end
    -- Only use live GetItemInfo result; never use stored texture (can go stale and show red ?)
    if tex and type(tex) == "string" and tex ~= "" and tex:match("^Interface") then return tex end
    return L.ITEM_ICON_FALLBACK
end

local ITEM_BTN_POOL, ITEM_BTN_POOL_USED = {}, 0

function L.ResetItemBtnPool()
    for i = 1, ITEM_BTN_POOL_USED do if ITEM_BTN_POOL[i] then ITEM_BTN_POOL[i]:Hide() end end
    ITEM_BTN_POOL_USED = 0
end

--- Gets a reusable row button from the pool for the item list (icon + name + count). Pool = we reuse rows instead of creating new ones every refresh (no leak).
function L.GetItemBtn(parent)
    ITEM_BTN_POOL_USED = ITEM_BTN_POOL_USED + 1
    local btn = ITEM_BTN_POOL[ITEM_BTN_POOL_USED]
    if not btn then
        btn = CreateFrame("Button", nil, parent)
        btn:EnableMouse(true)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetHitRectInsets(0, 0, 0, 0)
        btn:SetWidth(L.SCROLL_CONTENT_WIDTH)
        btn:SetHeight(18)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16)
        icon:SetHeight(16)
        icon:SetPoint("LEFT", btn, "LEFT", 0, 0)
        btn.icon = icon
        local nameFs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFs:SetPoint("RIGHT", btn, "RIGHT", -40, 0)
        nameFs:SetJustifyH("LEFT")
        btn.nameFs = nameFs
        local countFs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countFs:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
        countFs:SetJustifyH("RIGHT")
        btn.countFs = countFs
        local coin = btn:CreateTexture(nil, "OVERLAY")
        coin:SetWidth(12)
        coin:SetHeight(12)
        coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        coin:SetPoint("LEFT", icon, "RIGHT", 2, 0)
        btn.soldCoin = coin
        coin:Hide()
        local trashIcon = btn:CreateTexture(nil, "OVERLAY")
        trashIcon:SetWidth(12)
        trashIcon:SetHeight(12)
        trashIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_17")
        trashIcon:SetPoint("LEFT", icon, "RIGHT", 2, 0)
        btn.autodeletedIcon = trashIcon
        trashIcon:Hide()
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.1)
        ITEM_BTN_POOL[ITEM_BTN_POOL_USED] = btn
    end
    btn:SetParent(parent)
    btn:Show()

    local fontSettings = L.GetFugaziFontSettings()
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    local rh = L.GetFugaziRowHeight(18)
    btn:SetHeight(rh)
    btn.icon:SetWidth(rh - 2)
    btn.icon:SetHeight(rh - 2)
    btn.nameFs:SetFont(rowFont, fontSettings.rowSize, "")
    btn.countFs:SetFont(rowFont, fontSettings.rowSize, "")

    btn.itemLink = nil
    if btn.soldCoin then btn.soldCoin:Hide() end
    if btn.autodeletedIcon then btn.autodeletedIcon:Hide() end
    if btn.RegisterForClicks then btn:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    return btn
end

-- One handler per action so we don't create new closures every second when the item list is open (avoids memory leak).
function L.ItemDetailBtn_OnClick(self, button)
    -- Left-click on a search result (runIndex set): jump to that run in Ledger (highlight row, open Detail, refresh item list to that run)
    if button == "LeftButton" and self.runIndex and self.runRef then
        if not statsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
        if not statsFrame and L.CreateStatsFrame then statsFrame = L.CreateStatsFrame() end
        if statsFrame and not statsFrame:IsShown() and frame and frame:IsShown() then
            statsFrame:ClearAllPoints()
            statsFrame:SetWidth(frame:GetWidth())
            statsFrame:SetHeight(frame:GetHeight())
            statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            statsFrame:Show()
            L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
        end
        if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(self.runIndex) end
        ShowItemDetail(self.runRef)
        if type(RefreshStatsUI) == "function" then RefreshStatsUI() end
        return
    end
    -- Shift+RMB only: open chat and link item
    if not (IsShiftKeyDown() and button == "RightButton" and self.itemLink) then return end
    local chatBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if not chatBox and ChatEdit_ActivateChat and _G.ChatFrame1EditBox then
        ChatEdit_ActivateChat(_G.ChatFrame1EditBox)
        chatBox = _G.ChatFrame1EditBox
    end
    if not chatBox then
        for ci = 1, NUM_CHAT_WINDOWS do
            local eb = _G["ChatFrame" .. ci .. "EditBox"]
            if eb and eb:IsVisible() then chatBox = eb; break end
        end
    end
    if chatBox then chatBox:Insert(self.itemLink) end
end
function L.ItemDetailBtn_OnEnter(self)
    if self.itemLink then
        L.AnchorTooltipRight(self)
        local lp = self.itemLink:match("|H(item:[^|]+)|h")
        if lp then GameTooltip:SetHyperlink(lp) end
        GameTooltip:AddLine("From: " .. (self.runDisplayName or "?"), 0.6, 0.8, 0.6)
        GameTooltip:AddLine("Shift+Right-click: link in chat", 0.5, 0.7, 0.5)
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
end
function L.ItemDetailBtn_OnLeave()
    GameTooltip:Hide()
    if itemDetailFrame and itemDetailFrame.fromTooltip then
        itemDetailFrame.fromTooltip:Hide()
    end
end

function L.CreateItemDetailFrame()
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
        local snapTo = nil
        -- Prefer snapping to the right of Ledger Detail if we're near it, else Ledger
        local d = ledgerDetailFrame
        local stats = _G.InstanceTrackerStatsFrame
        if d and d:IsShown() then
            local lx, rx = f:GetLeft(), d:GetRight()
            if lx and rx and (lx - rx) >= -120 and (lx - rx) <= 120 then
                local fb, ft, sb, st = f:GetBottom(), f:GetTop(), d:GetBottom(), d:GetTop()
                if fb and ft and sb and st and ft > sb and fb < st then snapTo = d end
            end
        end
        if not snapTo and stats and stats:IsShown() then
            local lx, rx = f:GetLeft(), stats:GetRight()
            if lx and rx and (lx - rx) >= -120 and (lx - rx) <= 120 then
                local fb, ft, sb, st = f:GetBottom(), f:GetTop(), stats:GetBottom(), stats:GetTop()
                if fb and ft and sb and st and ft > sb and fb < st then snapTo = stats end
            end
        end
        if snapTo then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", snapTo, "TOPRIGHT", 4, 0)
        end
        L.SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
    end)
    f:SetScript("OnHide", function()
        L.SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
        f:SetScript("OnUpdate", nil)  -- stop update loop when closed (reduces memory climb)
    end)
    -- Whenever item detail is shown, dock to the right of Ledger Detail (if open) or Ledger
    f:SetScript("OnShow", function()
        if f._itemDetailOnUpdate then f:SetScript("OnUpdate", f._itemDetailOnUpdate) end
        local d = ledgerDetailFrame
        local stats = _G.InstanceTrackerStatsFrame
        local target = (d and d:IsShown()) and d or (stats and stats:IsShown() and stats) or nil
        if target then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", target, "TOPRIGHT", 4, 0)
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
        L.SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
        f:Hide()
    end)

    local qualLine = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qualLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -6)
    qualLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -6)
    qualLine:SetJustifyH("LEFT")
    f.qualLine = qualLine

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerItemScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", qualLine, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 6)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(L.SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Expose for skinning
    f.itTitleBar = titleBar
    f.itTitleText = title

    -- Allow shared skin to apply to item detail window as well.
    f.ApplySkin = function()
        L.ApplyInstanceTrackerSkin(f)
    end
    L.ApplyInstanceTrackerSkin(f)
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end

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
            L.CollapseInPlace(f, ITEM_DETAIL_COLLAPSED_HEIGHT, function(rel)
                return rel == statsFrame or rel == gphFrame or rel == _G.InstanceTrackerStatsFrame or rel == ledgerDetailFrame
            end)
            f.scrollFrame:Show()
            f.qualLine:Show()
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
            f.qualLine:Show()
            -- When expanding: prefer dock to Ledger Detail > Ledger > GPH, then saved collapse point, then DB
            local d = ledgerDetailFrame
            local stats = _G.InstanceTrackerStatsFrame
            local target = (d and d:IsShown()) and d or (stats and stats:IsShown() and stats) or nil
            if target then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", target, "TOPRIGHT", 4, 0)
            elseif gphFrame and gphFrame:IsShown() then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
            elseif f.collapseSavedPoint then
                local sp = f.collapseSavedPoint
                f:ClearAllPoints()
                f:SetPoint(sp[1], sp[2], sp[3], sp[4], sp[5])
                f.collapseSavedPoint = nil
            elseif InstanceTrackerDB.itemDetailPoint and InstanceTrackerDB.itemDetailPoint.point then
                L.RestoreFrameLayout(f, nil, "itemDetailPoint")
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

    -- Populate item list from current run or from ledger search (instance name, item name, or rarity). Search text comes from Ledger search bar only.
    function f:RefreshItemDetailList()
        local run = self.currentRun
        if not run then return end
        local items = {}
        local qc = {}
        local titleText = run.name or "Unknown"
        local searchText = (statsFrame and statsFrame.ledgerSearchEditBox and (statsFrame.ledgerSearchEditBox:GetText() or ""):match("^%s*(.-)%s*$")) or ""
        if searchText and searchText ~= "" then
            local searchLower = searchText:lower()
            local history = InstanceTrackerDB.runHistory or {}
            for runIndex, r in ipairs(history) do
                local runNameLower = r.name and r.name:lower() or ""
                local customLower = r.customName and r.customName:lower() or ""
                local runMatches = runNameLower:find(searchLower, 1, true) or (customLower ~= "" and customLower:find(searchLower, 1, true))
                local runDisp = L.GetRunDisplayName(r)
            for _, item in ipairs(r.items or {}) do
                    local itemNameLower = (item.name and item.name:lower()) or ""
                    local itemMatches = itemNameLower:find(searchLower, 1, true)
                    local qualityMatches = false
                    for q = 0, 5 do
                        local info = L.QUALITY_COLORS[q]
                        if info and info.label and info.label:lower():find(searchLower, 1, true) and item.quality == q then
                            qualityMatches = true
                            break
                        end
                    end
                    if runMatches or itemMatches or qualityMatches then
                        local c = item.count or 0
                        table.insert(items, {
                            link = item.link,
                            quality = item.quality,
                            count = c,
                            name = item.name,
                            runDisplayName = runDisp,
                            runIndex = runIndex,
                            runRef = r,
                            soldDuringSession = item.soldDuringSession,
                            autodeletedDuringSession = item.autodeletedDuringSession,
                            remainingCount = item.remainingCount,
                            soldCount = item.soldCount,
                        })
                        qc[item.quality] = (qc[item.quality] or 0) + c
                    end
                end
            end
            table.sort(items, function(a, b)
                if a.quality ~= b.quality then return a.quality > b.quality end
                return (a.name or "") < (b.name or "")
            end)
            titleText = "Search: " .. searchText
        else
            items = run.items or {}
            qc = run.qualityCounts or {}
            -- GPH sessions: kept first, then sold to vendor, then autodeleted at very bottom
            if run and run.name and run.name:find("^GPH") and #items > 0 then
                table.sort(items, function(a, b)
                    local tierA = (a.autodeletedDuringSession and 2) or (a.soldDuringSession and 1) or 0
                    local tierB = (b.autodeletedDuringSession and 2) or (b.soldDuringSession and 1) or 0
                    if tierA ~= tierB then return tierA < tierB end
                    if (a.quality or 0) ~= (b.quality or 0) then return (a.quality or 0) > (b.quality or 0) end
                    return (a.name or "") < (b.name or "")
                end)
            end
        end
        self.title:SetText(titleText)
        self.qualLine:SetText(L.FormatQualityCounts(qc))
        L.ResetItemBtnPool()
        local content = self.content
        local yOff = 4
        for _, item in ipairs(items) do
            local btn = L.GetItemBtn(content)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            btn.itemLink = item.link
            btn.runDisplayName = item.runDisplayName or L.GetRunDisplayName(run)
            btn.runIndex = item.runIndex
            btn.runRef = item.runRef

            local sold = item.soldDuringSession
            local autodeleted = item.autodeletedDuringSession
            local qInfo = L.QUALITY_COLORS[item.quality] or L.QUALITY_COLORS[1]
            local baseName = item.name or "Unknown"

            -- Icon tint: sold = slight desaturation; autodeleted = full B&W (grey); kept = full color.
            btn.icon:SetTexture(L.GetSafeItemTexture(item.link, nil))
            if autodeleted then
                btn.icon:SetVertexColor(0.6, 0.6, 0.6)
            elseif sold then
                btn.icon:SetVertexColor(0.88, 0.88, 0.9)
            else
                btn.icon:SetVertexColor(1, 1, 1)
            end

            -- Text: sold = slightly desaturated (hint of quality color); autodeleted = full B&W; kept = full quality color.
            if autodeleted then
                btn:SetAlpha(0.82)
                btn.nameFs:SetText("|cffbbbbbb" .. baseName .. "|r")
            elseif sold then
                btn:SetAlpha(0.95)
                local r, g, b = (qInfo.r or 0.7) * 0.6 + 0.5, (qInfo.g or 0.7) * 0.6 + 0.5, (qInfo.b or 0.7) * 0.6 + 0.5
                local hex = string.format("%02x%02x%02x", math.min(255, r * 255), math.min(255, g * 255), math.min(255, b * 255))
                btn.nameFs:SetText("|cff" .. hex .. baseName .. "|r")
            else
                btn:SetAlpha(1)
                btn.nameFs:SetText("|cff" .. qInfo.hex .. baseName .. "|r")
            end

            -- Leading icon: gold coin = sold to vendor; red-shaded icon = autodeleted (destroyed). Only one shown.
            if btn.soldCoin then btn.soldCoin:Hide() end
            if btn.autodeletedIcon then btn.autodeletedIcon:Hide() end
            local leadingIcon = nil
            -- If an item was both sold and autodeleted during the session, treat it as autodeleted visually:
            -- greyed out text/icon and red trash icon (no gold coin), so it's clearly a loss, not a sale.
            if autodeleted then
                leadingIcon = btn.autodeletedIcon
                if leadingIcon then leadingIcon:SetVertexColor(0.9, 0.35, 0.35) end
            elseif sold then
                leadingIcon = btn.soldCoin
                if leadingIcon then leadingIcon:SetVertexColor(1, 1, 1) end
            end

            btn.countFs:SetText(item.count > 1 and ("|cffaaaaaa x" .. item.count .. "|r") or "")
            btn:SetScript("OnClick", L.ItemDetailBtn_OnClick)
            btn:SetScript("OnEnter", L.ItemDetailBtn_OnEnter)
            btn:SetScript("OnLeave", L.ItemDetailBtn_OnLeave)
            -- Hide category icons: match FugaziBAGS "Hide Category Icons" in item list.
            -- When icons are hidden, sold shows gold coin as leading icon; autodeleted shows trash icon.
            local hideIcons = _G.FugaziBAGSDB and _G.FugaziBAGSDB.gphHideIconsInList
            btn.nameFs:ClearAllPoints()
            if hideIcons then
                btn.icon:Hide()
                if leadingIcon then
                    leadingIcon:Show()
                    leadingIcon:ClearAllPoints()
                    leadingIcon:SetPoint("LEFT", btn, "LEFT", 4, 0)
                    btn.nameFs:SetPoint("LEFT", leadingIcon, "RIGHT", 4, 0)
                else
                    btn.nameFs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                end
                btn.nameFs:SetPoint("RIGHT", btn, "RIGHT", -40, 0)
            else
                btn.icon:Show()
                if leadingIcon then
                    leadingIcon:Show()
                    leadingIcon:ClearAllPoints()
                    leadingIcon:SetPoint("LEFT", btn.icon, "RIGHT", 2, 0)
                    btn.nameFs:SetPoint("LEFT", leadingIcon, "RIGHT", 4, 0)
                else
                    btn.nameFs:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
                end
                btn.nameFs:SetPoint("RIGHT", btn, "RIGHT", -40, 0)
            end
            yOff = yOff + btn:GetHeight()
        end
        if #items == 0 then yOff = yOff + 4 end
        content:SetHeight(yOff + 8)
    end

    -- Live update when showing current run or GPH items. Throttle to 2s to avoid ~130kb/s climb when items window is open.
    local itemDetail_elapsed = 0
    f._itemDetailOnUpdate = function(self, elapsed)
        itemDetail_elapsed = itemDetail_elapsed + elapsed
        if itemDetail_elapsed >= 2 then
            itemDetail_elapsed = 0
            if self:IsShown() and self.liveSource then
                RefreshItemDetailLive()
            end
        end
    end
    -- Reusable one-frame defer (avoids leaking a new frame every time we open from ledger)
    f._deferFrame = CreateFrame("Frame", nil, f)
    return f
end

--- Opens (or updates) the item detail popup for a run. run = the run table (current or from history); liveSource = "currentRun" or "gph" if we should refresh the list every second.
ShowItemDetail = function(run, liveSource)
    if not itemDetailFrame then itemDetailFrame = L.CreateItemDetailFrame() end
    local f = itemDetailFrame
    statsFrame = _G.InstanceTrackerStatsFrame
    local wasShown = f:IsShown()
    f.currentRun = run
    f.liveSource = liveSource or nil
    f:RefreshItemDetailList()

    -- Dock item detail to the right of the rightmost visible: Ledger Detail > Ledger > GPH
    local ledger = _G.InstanceTrackerStatsFrame
    local detail = ledgerDetailFrame
    local openFromLedger = (ledger and ledger:IsShown()) or (detail and detail:IsShown())
    local dockTo = (detail and detail:IsShown()) and detail or (ledger and ledger:IsShown() and ledger) or nil
    -- Apply dock immediately whenever we have a dock target
    if dockTo then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", dockTo, "TOPRIGHT", 4, 0)
    elseif not wasShown then
        if gphFrame and gphFrame:IsShown() then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
        elseif InstanceTrackerDB.itemDetailPoint and InstanceTrackerDB.itemDetailPoint.point then
            L.RestoreFrameLayout(f, nil, "itemDetailPoint")
        end
    end
    f:Show()
    -- Re-apply dock after show (in case show/layout reset position)
    if dockTo then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", dockTo, "TOPRIGHT", 4, 0)
    elseif not wasShown and gphFrame and gphFrame:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", gphFrame, "TOPRIGHT", 4, 0)
    end
    if not wasShown and openFromLedger then
        InstanceTrackerDB.itemDetailCollapsed = (InstanceTrackerDB.statsCollapsed == true)
        if f.UpdateItemDetailCollapse then f.UpdateItemDetailCollapse() end
    end
    -- Defer one frame when opening from ledger/detail: re-dock so it sticks to the right of the rightmost (reuse one frame to avoid memory leak)
    if openFromLedger then
        local defer = f._deferFrame or CreateFrame("Frame", nil, f)
        f._deferFrame = defer
        defer:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            local d = ledgerDetailFrame
            local s = _G.InstanceTrackerStatsFrame
            local target = (d and d:IsShown()) and d or (s and s:IsShown() and s) or nil
            if f and f:IsShown() and target then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", target, "TOPRIGHT", 4, 0)
                InstanceTrackerDB.itemDetailCollapsed = (InstanceTrackerDB.statsCollapsed == true)
                if f.UpdateItemDetailCollapse then f.UpdateItemDetailCollapse() end
            end
        end)
    end
    L.SaveFrameLayout(f, "itemDetailShown", "itemDetailPoint")
end

----------------------------------------------------------------------
-- Live refresh for item detail (called every 1s from OnUpdate)
----------------------------------------------------------------------
RefreshItemDetailLive = function()
    if not itemDetailFrame or not itemDetailFrame:IsShown() or not itemDetailFrame.liveSource then return end
    local ledgerSearch = (statsFrame and statsFrame.ledgerSearchEditBox and (statsFrame.ledgerSearchEditBox:GetText() or ""):match("^%s*(.-)%s*$")) or ""
    if ledgerSearch and ledgerSearch ~= "" then return end  -- don't overwrite when Ledger search is active
    local src = itemDetailFrame.liveSource
    local snap = nil
    if src == "currentRun" then
        snap = BuildCurrentRunSnapshot()
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
        -- Keep Ledger Detail window in sync: if viewing deleted run, show prev or close; if viewing a run after it, decrement page
        if ledgerDetailFrame and ledgerDetailFrame:IsShown() then
            if ledgerDetailFrame.detailPage == index then
                if index > 1 then
                    ledgerDetailFrame.detailPage = index - 1
                else
                    ledgerDetailFrame:Hide()
                end
            elseif ledgerDetailFrame.detailPage > index then
                ledgerDetailFrame.detailPage = ledgerDetailFrame.detailPage - 1
            end
            if ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then
                L.RefreshLedgerDetailUI()
            end
        end
        L.AddonPrint(
            L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Removed run #" .. index .. "."
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
            if ledgerDetailFrame and ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then
                L.RefreshLedgerDetailUI()
            end
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

-- GPH_AUTOSELL_CONFIRM is owned by __FugaziBAGS; do not register it here or it overwrites BAGS's popup and breaks "Yes, enable" (wrong DB + wrong frame).

StaticPopupDialogs["INSTANCETRACKER_CLEAR_HISTORY"] = {
    text = "Are you sure you want to clear ALL run history?\nThis cannot be undone.\n\nLifetime stats (vendored, repairs, autodeleted) will NOT be cleared.",
    button1 = "Yes, Clear",
    button2 = "Cancel",
    OnAccept = function()
        -- Only clear the run list (empty in place so we don't replace the table reference).
        -- Never touch lifetimeStats, autoVendorStats, autoDeleteStats, or any other persistent data.
        local rh = InstanceTrackerDB.runHistory
        if rh then
            while #rh > 0 do table.remove(rh) end
        else
            InstanceTrackerDB.runHistory = {}
        end
        if ledgerDetailFrame and ledgerDetailFrame:IsShown() then ledgerDetailFrame:Hide() end
        L.AddonPrint(
            L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Run history cleared. Lifetime stats unchanged."
        )
        RefreshStatsUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Legacy GPH popups (delete stack / split stack / delete quality) have been
-- migrated into __FugaziBAGS. InstanceTracker no longer defines its own GPH
-- StaticPopupDialogs; the inventory UI and item deletion flows are owned by BAGS.

--- True if run is a manual GPH session (name starts with "GPH"). Defined early so Ledger nav buttons can use it.
local function IsGPHRun(run)
    return run and run.name and run.name:find("^GPH")
end

--- Returns { indices = list of runHistory indices for the tab (Sessions = GPH, Dungeons = non-GPH), ordinal = 1-based position of detailPage in that list }.
--- For tab 1 (Lifetime) returns session indices so nav can show "Run 1 of N" and Next goes to first session. Defined early for Ledger nav buttons.
local function GetTabRunIndicesAndOrdinal(history, selectedTab, detailPage)
    local indices = {}
    if selectedTab == 2 then
        for i, run in ipairs(history) do if IsGPHRun(run) then indices[#indices + 1] = i end end
    elseif selectedTab == 3 then
        for i, run in ipairs(history) do if not IsGPHRun(run) and (run.name or "") ~= "" then indices[#indices + 1] = i end end
    else
        for i, run in ipairs(history) do if IsGPHRun(run) then indices[#indices + 1] = i end end
    end
    local ordinal = 0
    if detailPage and #indices > 0 then
        for o, idx in ipairs(indices) do if idx == detailPage then ordinal = o break end end
    end
    return { indices = indices, ordinal = ordinal }
end

----------------------------------------------------------------------
-- Ledger (Stats) Window: the "run log" — current run + history list.
-- L.CreateStatsFrame builds the window once; RefreshStatsUI fills it with rows.
----------------------------------------------------------------------
function L.CreateStatsFrame()
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
        L.SaveFrameLayout(f, "statsShown", "statsPoint")
    end)
    f:SetScript("OnHide", function()
        L.SaveFrameLayout(f, "statsShown", "statsPoint")
        f:SetScript("OnUpdate", nil)  -- stop update loop when closed so closure can be GC'd (reduces memory climb)
    end)
    f:SetScript("OnShow", function()
        if f._statsOnUpdate then f:SetScript("OnUpdate", f._statsOnUpdate) end
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

    -- Expose for skinning
    f.itTitleBar = titleBar
    f.itTitleText = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Search bar at top of Ledger (search all runs' items; click result = jump to run + Detail + item list)
    local ledgerSearchBar = CreateFrame("Frame", nil, f)
    ledgerSearchBar:SetHeight(26)
    ledgerSearchBar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -4)
    ledgerSearchBar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -4)
    f.ledgerSearchBar = ledgerSearchBar
    local ledgerSearchEdit = CreateFrame("EditBox", nil, ledgerSearchBar)
    ledgerSearchEdit:SetHeight(20)
    ledgerSearchEdit:SetPoint("LEFT", ledgerSearchBar, "LEFT", 0, 0)
    ledgerSearchEdit:SetPoint("RIGHT", ledgerSearchBar, "RIGHT", 0, 0)
    ledgerSearchEdit:SetAutoFocus(false)
    ledgerSearchEdit:SetFontObject("GameFontHighlightSmall")
    ledgerSearchEdit:SetTextInsets(6, 4, 0, 0)
    local searchBg = ledgerSearchEdit:CreateTexture(nil, "BACKGROUND")
    searchBg:SetAllPoints()
    searchBg:SetTexture(0.1, 0.1, 0.15, 0.9)
    ledgerSearchEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ledgerSearchEdit:SetScript("OnTextChanged", function()
        if InstanceTrackerDB.statsCollapsed then
            InstanceTrackerDB.statsCollapsed = false
            if f.UpdateStatsCollapse then f.UpdateStatsCollapse() end
        end
        if type(RefreshStatsUI) == "function" then RefreshStatsUI() end
    end)
    ledgerSearchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.ledgerSearchEditBox = ledgerSearchEdit

    -- Ledger bar (buttons below search bar)
    local ledgerBar = CreateFrame("Frame", nil, f)
    ledgerBar:SetHeight(18)
    ledgerBar:SetPoint("TOPLEFT", ledgerSearchBar, "BOTTOMLEFT", 0, -2)
    ledgerBar:SetPoint("TOPRIGHT", ledgerSearchBar, "BOTTOMRIGHT", 0, -2)
    f.ledgerBar = ledgerBar

    local qBtns = {}
    local btnWidth = (340 - 12) / 6
    -- Layout: total width ~= search bar, 4px gaps (similar to inventory).
    local totalWidth = 340 - 12
    local spacing = 4
    local numBtns = 6
    local slotWidth = math.floor((totalWidth - spacing * (numBtns - 1)) / numBtns)
    if slotWidth < 16 then slotWidth = 16 end

    for q = 0, 5 do
        local btn = CreateFrame("Button", nil, ledgerBar)
        btn:SetSize(slotWidth, 18)
        local x = (slotWidth + spacing) * q
        btn:SetPoint("LEFT", ledgerBar, "LEFT", x, 0)
        btn.quality = q

        -- See-through gold tint (like FugaziBAGS rarity buttons: low alpha, glassy).
        local goldSteps = {
            { 0.90, 0.90, 0.90, 0.35 },
            { 0.95, 0.90, 0.75, 0.35 },
            { 0.98, 0.88, 0.55, 0.38 },
            { 0.96, 0.80, 0.35, 0.40 },
            { 0.88, 0.68, 0.25, 0.42 },
            { 0.78, 0.58, 0.20, 0.45 },
        }
        local col = goldSteps[q + 1] or goldSteps[#goldSteps]

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        bg:SetVertexColor(col[1], col[2], col[3], col[4])
        btn.bg = bg

        -- HIGHLIGHT layer: mouseover glow (same as FugaziBAGS rarity buttons).
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        hl:SetVertexColor(1, 1, 1, 0.30)
        btn.hl = hl

        -- Glass strip: dim by default, brightens on hover (like BAGS fs alpha 0 -> 1).
        local glass = btn:CreateTexture(nil, "ARTWORK")
        glass:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        glass:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        glass:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 0)
        glass:SetVertexColor(1, 1, 1, 0)
        btn.glass = glass

        -- Subtle 1px border (softer than solid black).
        local border = {
            top    = btn:CreateTexture(nil, "OVERLAY"),
            bottom = btn:CreateTexture(nil, "OVERLAY"),
            left   = btn:CreateTexture(nil, "OVERLAY"),
            right  = btn:CreateTexture(nil, "OVERLAY"),
        }
        for _, t in pairs(border) do
            t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            t:SetVertexColor(0.3, 0.3, 0.3, 0.5)
        end
        border.top:SetHeight(1)
        border.top:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        border.top:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
        border.bottom:SetHeight(1)
        border.bottom:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        border.bottom:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        border.left:SetWidth(1)
        border.left:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        border.left:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        border.right:SetWidth(1)
        border.right:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
        border.right:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        btn.border = border

        -- Reserved label (currently blank).
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetAlpha(0)
        fs:SetText("")
        btn.fs = fs

        btn:SetScript("OnEnter", function(self)
            self.glass:SetVertexColor(1, 1, 1, 0.32)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText("placeholder")
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self.glass:SetVertexColor(1, 1, 1, 0)
            GameTooltip:Hide()
        end)

        qBtns[q] = btn
    end
    f.ledgerBarButtons = qBtns

    -- Detail nav bar (Prev / Run X of Y / Next) at bottom of Ledger — always visible; Ledger is the "brain" navigator
    local detailNavBar = CreateFrame("Frame", nil, f)
    detailNavBar:SetHeight(26)
    detailNavBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 6)
    detailNavBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    f.detailNavBar = detailNavBar
    local detailPrevBtn = CreateFrame("Button", nil, detailNavBar)
    detailPrevBtn:SetSize(50, 20)
    detailPrevBtn:SetPoint("LEFT", detailNavBar, "LEFT", 0, 0)
    detailPrevBtn:SetNormalFontObject(GameFontNormalSmall)
    detailPrevBtn:SetHighlightFontObject(GameFontHighlightSmall)
    detailPrevBtn:SetText(L.ColorizeFugaziRowLabel("< Prev"))
    detailPrevBtn:SetScript("OnClick", function()
        local history = InstanceTrackerDB.runHistory or {}
        if #history == 0 then return end
        local tab = (f and f.selectedTab) or 1
        local detailPage = (ledgerDetailFrame and ledgerDetailFrame.detailPage) or 1
        if tab == 1 then
            return
        end
        local prevIdx = detailPage - 1
        if prevIdx < 1 then
            f.selectedTab = 1
            if ledgerDetailFrame and ledgerDetailFrame:IsShown() then ledgerDetailFrame:Hide() end
            if type(UpdateStatsTabs) == "function" then UpdateStatsTabs() end
        else
            local prevRun = history[prevIdx]
            local wantTab = prevRun and IsGPHRun(prevRun) and 2 or 3
            f.selectedTab = wantTab
            if _G.InstanceTrackerStatsFrame then _G.InstanceTrackerStatsFrame.selectedTab = wantTab end
            if type(UpdateStatsTabs) == "function" then UpdateStatsTabs() end
            if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(prevIdx) end
            if f and f:IsShown() and type(RefreshStatsUI) == "function" then RefreshStatsUI() end
            local sc, nc, gc = { 0.4, 0.35, 0.15, 0.9 }, { 0.15, 0.15, 0.15, 0.7 }, { 0.25, 0.25, 0.22, 0.85 }
            if f.statsTab1 and f.statsTab1.bg then f.statsTab1.bg:SetTexture(unpack(wantTab == 1 and gc or nc)) end
            if f.statsTab2 and f.statsTab2.bg then f.statsTab2.bg:SetTexture(unpack(wantTab == 2 and sc or nc)) end
            if f.statsTab3 and f.statsTab3.bg then f.statsTab3.bg:SetTexture(unpack(wantTab == 3 and sc or nc)) end
        end
        local page = (ledgerDetailFrame and ledgerDetailFrame.detailPage) or 1
        local run = history[page]
        if run and itemDetailFrame and itemDetailFrame:IsShown() then ShowItemDetail(run) end
    end)
    detailPrevBtn:SetScript("OnEnter", function(self) self:SetText("|cffffcc88< Prev|r") end)
    detailPrevBtn:SetScript("OnLeave", function(self) self:SetText(L.ColorizeFugaziRowLabel("< Prev")) end)
    f.detailNavPrevBtn = detailPrevBtn
    local detailNextBtn = CreateFrame("Button", nil, detailNavBar)
    detailNextBtn:SetSize(50, 20)
    detailNextBtn:SetPoint("RIGHT", detailNavBar, "RIGHT", 0, 0)
    detailNextBtn:SetNormalFontObject(GameFontNormalSmall)
    detailNextBtn:SetHighlightFontObject(GameFontHighlightSmall)
    detailNextBtn:SetText(L.ColorizeFugaziRowLabel("Next >"))
    detailNextBtn:SetScript("OnClick", function()
        local history = InstanceTrackerDB.runHistory or {}
        if #history == 0 then return end
        local tab = (f and f.selectedTab) or 1
        local detailPage = (ledgerDetailFrame and ledgerDetailFrame.detailPage) or 1
        if tab == 1 then
            -- Lifetime: go to run 1 (most recent, any type) and switch to Sessions or Dungeons tab
            local firstRun = history[1]
            if not firstRun then return end
            local wantTab = IsGPHRun(firstRun) and 2 or 3
            f.selectedTab = wantTab
            if _G.InstanceTrackerStatsFrame then _G.InstanceTrackerStatsFrame.selectedTab = wantTab end
            if type(UpdateStatsTabs) == "function" then UpdateStatsTabs() end
            if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(1) end
            if f:IsShown() and type(RefreshStatsUI) == "function" then RefreshStatsUI() end
            -- Force tab strip (Lifetime/Sessions/Dungeons) to show the active tab
            local sc, nc, gc = { 0.4, 0.35, 0.15, 0.9 }, { 0.15, 0.15, 0.15, 0.7 }, { 0.25, 0.25, 0.22, 0.85 }
            if f.statsTab1 and f.statsTab1.bg then f.statsTab1.bg:SetTexture(unpack(wantTab == 1 and gc or nc)) end
            if f.statsTab2 and f.statsTab2.bg then f.statsTab2.bg:SetTexture(unpack(wantTab == 2 and sc or nc)) end
            if f.statsTab3 and f.statsTab3.bg then f.statsTab3.bg:SetTexture(unpack(wantTab == 3 and sc or nc)) end
        else
            -- Sessions or Dungeons: next run in record order (switch tab if next run is other type)
            local nextIdx = detailPage + 1
            if nextIdx <= #history then
                local nextRun = history[nextIdx]
                local wantTab = nextRun and IsGPHRun(nextRun) and 2 or 3
                f.selectedTab = wantTab
                if _G.InstanceTrackerStatsFrame then _G.InstanceTrackerStatsFrame.selectedTab = wantTab end
                if type(UpdateStatsTabs) == "function" then UpdateStatsTabs() end
                if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(nextIdx) end
                if f and f:IsShown() and type(RefreshStatsUI) == "function" then RefreshStatsUI() end
                local sc, nc, gc = { 0.4, 0.35, 0.15, 0.9 }, { 0.15, 0.15, 0.15, 0.7 }, { 0.25, 0.25, 0.22, 0.85 }
                if f.statsTab1 and f.statsTab1.bg then f.statsTab1.bg:SetTexture(unpack(wantTab == 1 and gc or nc)) end
                if f.statsTab2 and f.statsTab2.bg then f.statsTab2.bg:SetTexture(unpack(wantTab == 2 and sc or nc)) end
                if f.statsTab3 and f.statsTab3.bg then f.statsTab3.bg:SetTexture(unpack(wantTab == 3 and sc or nc)) end
            end
        end
        local page = (ledgerDetailFrame and ledgerDetailFrame.detailPage) or 1
        local run = history[page]
        if run and itemDetailFrame and itemDetailFrame:IsShown() then ShowItemDetail(run) end
    end)
    detailNextBtn:SetScript("OnEnter", function(self) self:SetText("|cffffcc88Next >|r") end)
    detailNextBtn:SetScript("OnLeave", function(self) self:SetText(L.ColorizeFugaziRowLabel("Next >")) end)
    f.detailNavNextBtn = detailNextBtn
    local detailPageLabel = detailNavBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detailPageLabel:SetPoint("CENTER", detailNavBar, "CENTER", 0, 0)
    detailPageLabel:SetTextColor(0.85, 0.75, 0.5, 1)
    f.detailNavPageLabel = detailPageLabel

    -- Scroll frame (must exist before collapse button); sits below ledger bar, above detail nav when visible
    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerStatsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", ledgerBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", detailNavBar, "TOPRIGHT", -28, 4)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(L.SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    content:EnableMouse(true)
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- Enable shared skinning with __FugaziBAGS
    f.ApplySkin = function()
        L.ApplyInstanceTrackerSkin(f)
    end
    L.ApplyInstanceTrackerSkin(f)
    -- Match FugaziBAGS scrollbar look
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end

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
            L.CollapseInPlace(f, 150, function(rel)
                return rel == frame or rel == _G.InstanceTrackerFrame
            end)
            f.scrollFrame:Show()
            -- Keep search bar and ledger bar visible when collapsed so they don't go missing after expand→collapse.
            if f.ledgerSearchBar then f.ledgerSearchBar:Show() end
            if f.ledgerBar then f.ledgerBar:Show() end
            if f.detailNavBar then f.detailNavBar:SetHeight(0); f.detailNavBar:Hide() end
        else
            collapseBg:SetTexture(0.35, 0.28, 0.1, 0.7)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            f:SetHeight(f.EXPANDED_HEIGHT)
            f.scrollFrame:Show()
            if f.ledgerSearchBar then f.ledgerSearchBar:Show() end
            if f.ledgerBar then f.ledgerBar:Show() end
            if f.detailNavBar then f.detailNavBar:SetHeight(26); f.detailNavBar:Show() end
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

    -- Tabs: Lifetime (always-on stats) | Sessions (manual GPH) | Dungeons (auto-recorded)
    local statsTab1 = CreateFrame("Button", nil, f)
    statsTab1:SetSize(58, 20)
    statsTab1:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -4)
    local statsTab1Bg = statsTab1:CreateTexture(nil, "BACKGROUND")
    statsTab1Bg:SetAllPoints()
    statsTab1.bg = statsTab1Bg
    local statsTab1Text = statsTab1:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsTab1Text:SetPoint("CENTER")
    statsTab1Text:SetText("Lifetime")
    statsTab1.text = statsTab1Text

    local statsTab2 = CreateFrame("Button", nil, f)
    statsTab2:SetSize(58, 20)
    statsTab2:SetPoint("LEFT", statsTab1, "RIGHT", 2, 0)
    local statsTab2Bg = statsTab2:CreateTexture(nil, "BACKGROUND")
    statsTab2Bg:SetAllPoints()
    statsTab2.bg = statsTab2Bg
    local statsTab2Text = statsTab2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsTab2Text:SetPoint("CENTER")
    statsTab2Text:SetText("Sessions")
    statsTab2.text = statsTab2Text

    local statsTab3 = CreateFrame("Button", nil, f)
    statsTab3:SetSize(58, 20)
    statsTab3:SetPoint("LEFT", statsTab2, "RIGHT", 2, 0)
    local statsTab3Bg = statsTab3:CreateTexture(nil, "BACKGROUND")
    statsTab3Bg:SetAllPoints()
    statsTab3.bg = statsTab3Bg
    local statsTab3Text = statsTab3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsTab3Text:SetPoint("CENTER")
    statsTab3Text:SetText("Dungeons")
    statsTab3.text = statsTab3Text
    f.statsTab1 = statsTab1
    f.statsTab2 = statsTab2
    f.statsTab3 = statsTab3

    f.selectedTab = 1
    if currentRun then f.selectedTab = 3 end
    local function UpdateStatsTabs()
        -- Use global frame as source of truth so nav-button tab switch always matches
        local frameRef = _G.InstanceTrackerStatsFrame or f
        local tab = (frameRef and frameRef.selectedTab) or 1
        local selectedColor = { 0.4, 0.35, 0.15, 0.9 }
        local normalColor = { 0.15, 0.15, 0.15, 0.7 }
        local greyColor = { 0.25, 0.25, 0.22, 0.85 }

        -- Search bar + ledger bar visible on all tabs (Lifetime, Sessions, Dungeons)
        if f.ledgerSearchBar then f.ledgerSearchBar:Show() end
        if f.ledgerBar then f.ledgerBar:Show() end
        f.scrollFrame:SetPoint("TOPLEFT", f.ledgerBar, "BOTTOMLEFT", 0, -4)
        if f.scrollFrame and f.scrollFrame.SetVerticalScroll then f.scrollFrame:SetVerticalScroll(0) end

        RefreshStatsUI()
        -- Apply tab button highlight from current selectedTab (re-read in case RefreshStatsUI or handler set it)
        local curTab = (frameRef and frameRef.selectedTab) or 1
        statsTab1.bg:SetTexture(unpack(curTab == 1 and greyColor or normalColor))
        statsTab2.bg:SetTexture(unpack(curTab == 2 and selectedColor or normalColor))
        statsTab3.bg:SetTexture(unpack(curTab == 3 and selectedColor or normalColor))
    end
    statsTab1:SetScript("OnClick", function()
        if InstanceTrackerDB.statsCollapsed then InstanceTrackerDB.statsCollapsed = false; if f.UpdateStatsCollapse then f.UpdateStatsCollapse() end end
        f.selectedTab = 1; UpdateStatsTabs()
    end)
    statsTab2:SetScript("OnClick", function()
        if InstanceTrackerDB.statsCollapsed then InstanceTrackerDB.statsCollapsed = false; if f.UpdateStatsCollapse then f.UpdateStatsCollapse() end end
        f.selectedTab = 2; UpdateStatsTabs()
    end)
    statsTab3:SetScript("OnClick", function()
        if InstanceTrackerDB.statsCollapsed then InstanceTrackerDB.statsCollapsed = false; if f.UpdateStatsCollapse then f.UpdateStatsCollapse() end end
        f.selectedTab = 3; UpdateStatsTabs()
    end)
    f.UpdateStatsTabs = UpdateStatsTabs
    UpdateStatsTabs()

    -- Search bar repositioned below tabs
    ledgerSearchBar:ClearAllPoints()
    ledgerSearchBar:SetPoint("TOPLEFT", statsTab1, "BOTTOMLEFT", 0, -4)
    ledgerSearchBar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -4)

    local stats_elapsed = 0
    f._statsOnUpdate = function(self, elapsed)
        stats_elapsed = stats_elapsed + elapsed
        if stats_elapsed >= 1 then
            stats_elapsed = 0
            local fontSettings = L.GetFugaziFontSettings()
            local fontHash = (fontSettings.titlePath or "") .. (fontSettings.titleSize or 0) .. (fontSettings.rowSize or 0) .. (fontSettings.rowFontPath or "")
            if not f.lastFontHash then f.lastFontHash = fontHash end
            if f.lastFontHash ~= fontHash then
                f.lastFontHash = fontHash
                if _G.InstanceTrackerFrame then L.ApplyInstanceTrackerSkin(_G.InstanceTrackerFrame) end
                if _G.InstanceTrackerStatsFrame then L.ApplyInstanceTrackerSkin(_G.InstanceTrackerStatsFrame) end
                if _G.InstanceTrackerLedgerDetailFrame then L.ApplyInstanceTrackerSkin(_G.InstanceTrackerLedgerDetailFrame) end
                if _G.InstanceTrackerItemDetailFrame then L.ApplyInstanceTrackerSkin(_G.InstanceTrackerItemDetailFrame) end
                if type(RefreshUI) == "function" then RefreshUI() end
                if type(RefreshStatsUI) == "function" then RefreshStatsUI() end
                if type(L.RefreshLedgerDetailUI) == "function" then L.RefreshLedgerDetailUI() end
            end
            if currentRun and self.selectedTab == 3 then
                RefreshStatsUI(true)
            end
        end
    end
    -- OnUpdate: attach when frame is created so timer ticks; OnHide clears it when Ledger is closed.
    f:SetScript("OnUpdate", f._statsOnUpdate)
    return f
end

--- Fills the scroll content with always-on lifetime stats (no sessions/dungeons). Tab 1 only.
function L.RefreshStatsLifetimeUI(content)
    -- Use existing lifetimeStats; never replace it (lifetime must never reset on reload).
    local LS = InstanceTrackerDB.lifetimeStats or {}
    local yOff = 6
    local fontSettings = L.GetFugaziFontSettings()
    local hdrSpacing = (fontSettings.headerSize or 11) + 8
    local rowH = L.GetFugaziRowHeight(18)
    local sectionGap = 8
    content._statHoverFrames = content._statHoverFrames or {}
    for _, hf in ipairs(content._statHoverFrames) do if hf then hf:Hide() end end

    local statHoverIdx = 0
    local function AddStat(label, value, color, fullTextForTooltip)
        local row = GetStatsRow(content, false)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        row.left:SetText(L.ColorizeFugaziRowLabel(label .. ":"))
        -- Constrain value column: gap after label so value doesn't run into it (truncation then gives consistent look).
        row.right:ClearAllPoints()
        row.right:SetPoint("LEFT", row.left, "RIGHT", 12, 0)
        row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.right:SetWordWrap(false)
        local displayValue = (value and value:match("|c")) and value or ((color or "|cffffffff") .. (value or "") .. "|r")
        local plainValue = fullTextForTooltip or L.StripColorCodes(displayValue)
        local maxValChars = math.max(6, L.LEDGER_STAT_MAX_CHARS - #label - 8)
        if #plainValue > maxValChars then
            if value and value:match("|c") then
                displayValue = L.TruncateWithColors(displayValue, maxValChars)
            else
                displayValue = (color or "|cffcccccc") .. plainValue:sub(1, maxValChars - 3) .. "...|r"
            end
            if not fullTextForTooltip then fullTextForTooltip = plainValue end
        end
        row.right:SetText(displayValue)
        if fullTextForTooltip and #plainValue > maxValChars then
            statHoverIdx = statHoverIdx + 1
            local hf = content._statHoverFrames[statHoverIdx]
            if not hf then
                hf = CreateFrame("Frame", nil, content)
                hf:EnableMouse(true)
                hf:SetScript("OnEnter", function(self)
                    if self._fullText then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(self._fullText, 1, 1, 1, true)
                        GameTooltip:Show()
                    end
                end)
                hf:SetScript("OnLeave", function() GameTooltip:Hide() end)
                content._statHoverFrames[statHoverIdx] = hf
            end
            hf._fullText = fullTextForTooltip
            hf:ClearAllPoints()
            hf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
            hf:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - 8, -(yOff + row:GetHeight()))
            hf:Show()
        end
        yOff = yOff + row:GetHeight()
    end

    -- Current gold = account-wide total (all chars this realm); keep current char's value up to date then sum
    local AG = InstanceTrackerDB.accountGold or {}
    local ckey = L.GetGphCharKey()
    AG[ckey] = GetMoney()
    local accountGoldTotal = 0
    for _, v in pairs(AG) do accountGoldTotal = accountGoldTotal + (v or 0) end
    local currentGoldRow = GetStatsRow(content, false)
    currentGoldRow:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    currentGoldRow.left:SetText(L.ColorizeFugaziRowLabel("Current gold:"))
    currentGoldRow.right:SetText(L.FormatGold(accountGoldTotal))
    local currentGoldRowH = currentGoldRow:GetHeight()
    if not content.summaryGoldHoverFrame then
        local hoverF = CreateFrame("Frame", nil, content)
        hoverF:SetSize(280, 18)
        hoverF:EnableMouse(true)
        hoverF:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Per character (this realm); main line = sum", 0.6, 0.85, 0.6)
            local AG = InstanceTrackerDB.accountGold or {}
            local total = 0
            for _, v in pairs(AG) do total = total + (v or 0) end
            GameTooltip:AddLine(L.FormatGoldPlain(total), 1, 0.85, 0.4)
            for key, copper in pairs(AG) do
                local label = (key and tostring(key):gsub("#", " – ")) or "?"
                GameTooltip:AddLine(label .. ": " .. L.FormatGoldPlain(copper or 0), 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        hoverF:SetScript("OnLeave", function() GameTooltip:Hide() end)
        content.summaryGoldHoverFrame = hoverF
    end
    content.summaryGoldHoverFrame:ClearAllPoints()
    content.summaryGoldHoverFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
    content.summaryGoldHoverFrame:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - 8, -(yOff + currentGoldRowH))
    content.summaryGoldHoverFrame:Show()
    yOff = yOff + currentGoldRowH + 4

    -- Lifetime Gold = total gold ever gained (account); mouseover shows per-character
    local totalGained = 0
    for _, v in pairs(InstanceTrackerDB.lifetimeGoldGained or {}) do totalGained = totalGained + (v or 0) end
    local lifetimeGoldRow = GetStatsRow(content, false)
    lifetimeGoldRow:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    lifetimeGoldRow.left:SetText(L.ColorizeFugaziRowLabel("Lifetime Gold:"))
    lifetimeGoldRow.right:SetText(L.FormatGold(totalGained))
    yOff = yOff + lifetimeGoldRow:GetHeight()
    if not content.lifetimeGoldHoverFrame then
        local hf = CreateFrame("Frame", nil, content)
        hf:SetSize(280, 16)
        hf:EnableMouse(true)
        hf:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Lifetime gold gained (per character)", 0.6, 0.85, 0.6)
            local LG = InstanceTrackerDB.lifetimeGoldGained or {}
            for key, copper in pairs(LG) do
                local label = (key and tostring(key):gsub("#", " – ")) or "?"
                GameTooltip:AddLine(label .. ": " .. L.FormatGold(copper or 0), 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        hf:SetScript("OnLeave", function() GameTooltip:Hide() end)
        content.lifetimeGoldHoverFrame = hf
    end
    content.lifetimeGoldHoverFrame:ClearAllPoints()
    content.lifetimeGoldHoverFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(yOff - rowH))
    content.lifetimeGoldHoverFrame:Show()
    yOff = yOff + sectionGap

    -- Economy & activity (always counted, not tied to sessions)
    local econHeader = GetStatsText(content)
    econHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    econHeader:SetText("--- Economy & activity ---")
    L.StyleFugaziHeader(econHeader)
    yOff = yOff + hdrSpacing
    -- Economy rows: only the actual gold amount uses L.FormatGold (yellow/silver/copper); counts and labels use neutral grey.
    AddStat("Vendored", L.FormatGold(LS.vendorCopper or 0) .. "|cffaaaaaa (" .. (LS.vendorItemCount or 0) .. " sales)|r", nil)
    AddStat("Repairs", "|cffaaaaaa" .. (LS.repairCount or 0) .. " repairs, |r" .. L.FormatGold(LS.repairCopper or 0), nil)
    -- Deaths = all lifetime deaths (account); mouseover per character
    local totalDeaths = 0
    for _, v in pairs(InstanceTrackerDB.lifetimeDeaths or {}) do totalDeaths = totalDeaths + (v or 0) end
    local deathsRow = GetStatsRow(content, false)
    deathsRow:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    deathsRow.left:SetText(L.ColorizeFugaziRowLabel("Deaths:"))
    deathsRow.right:SetText("|cffcc6666" .. tostring(totalDeaths) .. "|r")
    local deathsRowH = deathsRow:GetHeight()
    yOff = yOff + deathsRowH
    if not content.lifetimeDeathsHoverFrame then
        local df = CreateFrame("Frame", nil, content)
        df:SetSize(280, 16)
        df:EnableMouse(true)
        df:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Deaths (per character)", 0.6, 0.85, 0.6)
            local LD = InstanceTrackerDB.lifetimeDeaths or {}
            for key, n in pairs(LD) do
                local label = (key and tostring(key):gsub("#", " – ")) or "?"
                GameTooltip:AddLine(label .. ": " .. tostring(n or 0), 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        df:SetScript("OnLeave", function() GameTooltip:Hide() end)
        content.lifetimeDeathsHoverFrame = df
    end
    content.lifetimeDeathsHoverFrame:ClearAllPoints()
    content.lifetimeDeathsHoverFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(yOff - deathsRowH))
    content.lifetimeDeathsHoverFrame:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - 8, -yOff)
    content.lifetimeDeathsHoverFrame:Show()
    yOff = yOff + sectionGap
    local delStats = InstanceTrackerDB.autoDeleteStats
    local totalDeleted = (delStats and delStats.totalCount) or (LS.deletedItemCount or 0)
    local totalDeletedCopper = (delStats and delStats.totalVendorCopper) or 0
    local autodelValue = "|cffaaaaaa" .. (totalDeleted or 0) .. " items, |r" .. L.FormatGold(totalDeletedCopper or 0) .. "|cffaaaaaa lost|r"
    local autodelTooltip = string.format("%d items, %s lost", totalDeleted or 0, L.FormatGoldPlain(totalDeletedCopper or 0))
    AddStat("Items autodeleted", autodelValue, nil, autodelTooltip)
    yOff = yOff + sectionGap

    -- Top autodeleted items (rarity-colored name, linkable, item tooltip; gold amount has full-value tooltip)
    local delStats = InstanceTrackerDB.autoDeleteStats
    if delStats and delStats.items then
        local delHeader = GetStatsText(content)
        delHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        delHeader:SetText("--- Top autodeleted items ---")
        L.StyleFugaziHeader(delHeader)
        yOff = yOff + hdrSpacing
        local tmp = {}
        for itemId, entry in pairs(delStats.items) do
            table.insert(tmp, { itemId = itemId, count = entry.count or 0, copper = entry.vendorCopper or 0 })
        end
        table.sort(tmp, function(a, b) return a.copper > b.copper end)
        local contentW = content:GetWidth() or 260
        local rightMargin = 12
        local rightBlockW = 108
        local shown = 0
        for i = 1, math.min(5, #tmp) do
            local row = tmp[i]
            if row.count > 0 then
                local r = GetTopItemRow(content, fontSettings, rowH, rightMargin, rightBlockW)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
                r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                r:SetHeight(rowH)
                r.indexFs:SetText(string.format("|cffcccccc%d.|r ", i))
                local name = tostring(row.itemId)
                local quality, link = 0, nil
                if GetItemInfo then local n, l, q = GetItemInfo(row.itemId) if n then name = n end if q then quality = q end if l then link = l end end
                local fullName = name
                if #name > 14 then name = name:sub(1, 11) .. "..." end
                local qInfo = L.QUALITY_COLORS[quality] or L.QUALITY_COLORS[1]
                r.itemBtn.fs:SetText("|cff" .. qInfo.hex .. name .. "|r")
                r.itemBtn.itemLink = link or ("item:" .. row.itemId)
                r.itemBtn.fullName = (#(fullName or "") > 14) and fullName or nil
                r.rightFs:SetText(string.format("|cffffffffx%d|r  %s", row.count, L.FormatGoldShort(row.copper or 0)))
                r.rightFs:SetWidth(rightBlockW)
                r.rightFs:SetWordWrap(false)
                r.goldHover.copper = row.copper or 0
                r.goldHover:ClearAllPoints()
                r.goldHover:SetPoint("TOPRIGHT", r, "TOPRIGHT", -rightMargin, 0)
                r.goldHover:SetSize(rightBlockW, rowH)
                yOff = yOff + rowH
                shown = shown + 1
            end
        end
        if shown == 0 then
            local none = GetStatsText(content)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            none:SetText("|cff888888No autodelete data yet.|r")
            yOff = yOff + rowH
        end
        yOff = yOff + sectionGap
    end

    -- Top autosold items (rarity-colored name, linkable, item tooltip; gold amount has full-value tooltip)
    local vendStats = InstanceTrackerDB.autoVendorStats
    if vendStats and vendStats.items then
        local vendHeader = GetStatsText(content)
        vendHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        vendHeader:SetText("--- Top autosold items ---")
        L.StyleFugaziHeader(vendHeader)
        yOff = yOff + hdrSpacing
        local tmp2 = {}
        for itemId, entry in pairs(vendStats.items) do
            table.insert(tmp2, { itemId = itemId, count = entry.count or 0, copper = entry.vendorCopper or 0 })
        end
        table.sort(tmp2, function(a, b) return a.copper > b.copper end)
        local rightMargin = 12
        local rightBlockW = 108
        local shown2 = 0
        for i = 1, math.min(5, #tmp2) do
            local row = tmp2[i]
            if row.count > 0 then
                local r = GetTopItemRow(content, fontSettings, rowH, rightMargin, rightBlockW)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
                r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                r:SetHeight(rowH)
                r.indexFs:SetText(string.format("|cffcccccc%d.|r ", i))
                local name = tostring(row.itemId)
                local quality, link = 0, nil
                if GetItemInfo then local n, l, q = GetItemInfo(row.itemId) if n then name = n end if q then quality = q end if l then link = l end end
                local fullName = name
                if #name > 14 then name = name:sub(1, 11) .. "..." end
                local qInfo = L.QUALITY_COLORS[quality] or L.QUALITY_COLORS[1]
                r.itemBtn.fs:SetText("|cff" .. qInfo.hex .. name .. "|r")
                r.itemBtn.itemLink = link or ("item:" .. row.itemId)
                r.itemBtn.fullName = (#(fullName or "") > 14) and fullName or nil
                r.rightFs:SetText(string.format("|cffffffffx%d|r  %s", row.count, L.FormatGoldShort(row.copper or 0)))
                r.rightFs:SetWidth(rightBlockW)
                r.rightFs:SetWordWrap(false)
                r.goldHover.copper = row.copper or 0
                r.goldHover:ClearAllPoints()
                r.goldHover:SetPoint("TOPRIGHT", r, "TOPRIGHT", -rightMargin, 0)
                r.goldHover:SetSize(rightBlockW, rowH)
                yOff = yOff + rowH
                shown2 = shown2 + 1
            end
        end
        if shown2 == 0 then
            local none = GetStatsText(content)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            none:SetText("|cff888888No autosell data yet.|r")
            yOff = yOff + rowH
        end
        yOff = yOff + sectionGap
    end

    content:SetHeight(math.max(24, yOff + sectionGap))
    return yOff + 4
end

--- Fills the scroll content with full summary (legacy: run stats + economy). Used only for backward compatibility if needed.
function L.RefreshStatsSummaryUI(content)
    -- Use existing lifetimeStats; never replace it (lifetime must never reset on reload).
    local LS = InstanceTrackerDB.lifetimeStats or {}
    local yOff = 4
    local fontSettings = L.GetFugaziFontSettings()
    local hdrSpacing = (fontSettings.headerSize or 11) + 6
    content._statHoverFrames = content._statHoverFrames or {}
    for _, hf in ipairs(content._statHoverFrames) do if hf then hf:Hide() end end
    local statHoverIdx = 0
    local rowH = L.GetFugaziRowHeight(18)

    local function AddStat(label, value, color)
        local fullText = L.ColorizeFugaziRowLabel(label .. ":") .. "  " .. (color or "|cffffffff") .. value .. "|r"
        local plain = L.StripColorCodes(fullText)
        local prefixLen = #label + 3
        local maxValueChars = L.LEDGER_STAT_MAX_CHARS - prefixLen - 3
        local truncated = #plain > L.LEDGER_STAT_MAX_CHARS
        local valuePlain = plain:sub(prefixLen + 1)
        local displayText = fullText
        if truncated then
            displayText = L.ColorizeFugaziRowLabel(label .. ":") .. "  " .. (color or "|cffffffff") .. valuePlain:sub(1, maxValueChars) .. "...|r"
        end
        local fs = GetStatsText(content)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        fs:SetWidth(L.SCROLL_CONTENT_WIDTH - 24)
        fs:SetWordWrap(false)
        fs:SetText(displayText)
        if truncated then
            statHoverIdx = statHoverIdx + 1
            local hf = content._statHoverFrames[statHoverIdx]
            if not hf then
                hf = CreateFrame("Frame", nil, content)
                hf:EnableMouse(true)
                hf:SetScript("OnEnter", function(self)
                    if self._fullText then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(self._fullText, 1, 1, 1)
                        GameTooltip:Show()
                    end
                end)
                hf:SetScript("OnLeave", function() GameTooltip:Hide() end)
                content._statHoverFrames[statHoverIdx] = hf
            end
            hf._fullText = plain
            hf:ClearAllPoints()
            hf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
            hf:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - 8, -(yOff + rowH))
            hf:Show()
        end
        yOff = yOff + rowH
    end

    -- Current gold = account-wide total (all chars this realm)
    local AG2 = InstanceTrackerDB.accountGold or {}
    AG2[L.GetGphCharKey()] = GetMoney()
    local accountGoldTotal2 = 0
    for _, v in pairs(AG2) do accountGoldTotal2 = accountGoldTotal2 + (v or 0) end
    local currentGoldFs = GetStatsText(content)
    currentGoldFs:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    currentGoldFs:SetWidth(L.SCROLL_CONTENT_WIDTH - 24)
    currentGoldFs:SetWordWrap(false)
    currentGoldFs:SetText(L.ColorizeFugaziRowLabel("Current gold:") .. "  " .. L.FormatGold(accountGoldTotal2))
    if not content.summaryGoldHoverFrame then
        local f = CreateFrame("Frame", nil, content)
        f:SetSize(280, 18)
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Per character (this realm); main line = sum", 0.6, 0.85, 0.6)
            local AG = InstanceTrackerDB.accountGold or {}
            local total = 0
            for _, v in pairs(AG) do total = total + (v or 0) end
            GameTooltip:AddLine(L.FormatGoldPlain(total), 1, 0.85, 0.4)
            for key, copper in pairs(AG) do
                local label = (key and tostring(key):gsub("#", " – ")) or "?"
                GameTooltip:AddLine(label .. ": " .. L.FormatGoldPlain(copper or 0), 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        content.summaryGoldHoverFrame = f
    end
    content.summaryGoldHoverFrame:ClearAllPoints()
    content.summaryGoldHoverFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
    content.summaryGoldHoverFrame:Show()
    yOff = yOff + rowH + 4

    local totalGained2 = 0
    for _, v in pairs(InstanceTrackerDB.lifetimeGoldGained or {}) do totalGained2 = totalGained2 + (v or 0) end
    AddStat("Lifetime Gold", L.FormatGoldPlain(totalGained2), "|cffffd700")
    AddStat("Total Runs", LS.totalRuns or 0)
    AddStat("Best GPH", L.FormatGoldPlain(LS.bestGPH or 0) .. "/hr", "|cff66dd88")
    yOff = yOff + 8

    -- Economy & activity (vendored, repairs, deaths, destroyed)
    local econHeader = GetStatsText(content)
    econHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    econHeader:SetText("--- Economy & activity ---")
    L.StyleFugaziHeader(econHeader)
    yOff = yOff + hdrSpacing
    -- Same rule: only actual gold amount uses FormatGold; counts/labels neutral grey.
    AddStat("Vendored", L.FormatGold(LS.vendorCopper or 0) .. "|cffaaaaaa (" .. (LS.vendorItemCount or 0) .. " sales)|r", nil)
    AddStat("Repairs", "|cffaaaaaa" .. (LS.repairCount or 0) .. " repairs, |r" .. L.FormatGold(LS.repairCopper or 0), nil)
    AddStat("Deaths (in instance)", tostring(LS.instanceDeaths or 0), "|cffcc6666")
    local delStats2 = InstanceTrackerDB.autoDeleteStats
    local totalDeleted2 = (delStats2 and delStats2.totalCount) or (LS.deletedItemCount or 0)
    local totalDeletedCopper2 = (delStats2 and delStats2.totalVendorCopper) or 0
    AddStat("Items autodeleted", "|cffaaaaaa" .. (totalDeleted2 or 0) .. " items, |r" .. L.FormatGold(totalDeletedCopper2 or 0) .. "|cffaaaaaa lost|r", nil)
    yOff = yOff + 8

    -- Top autodeleted items (lifetime, by lost vendor value)
    local delStats = InstanceTrackerDB.autoDeleteStats
    if delStats and delStats.items then
        local delHeader = GetStatsText(content)
        delHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        delHeader:SetText("--- Top autodeleted items ---")
        L.StyleFugaziHeader(delHeader)
        yOff = yOff + hdrSpacing

        local tmp = {}
        for itemId, entry in pairs(delStats.items) do
            table.insert(tmp, { itemId = itemId, count = entry.count or 0, copper = entry.vendorCopper or 0 })
        end
        table.sort(tmp, function(a, b) return a.copper > b.copper end)

        local shown = 0
        for i = 1, math.min(5, #tmp) do
            local row = tmp[i]
            if row.count > 0 then
                local name = tostring(row.itemId)
                if GetItemInfo then
                    local itemName = GetItemInfo(row.itemId)
                    if itemName then name = itemName end
                end
                local line = GetStatsText(content)
                line:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
                line:SetText(string.format("|cffcccccc%d.|r |cffffffcc%s|r x%d |cffaaaaaa(%s)|r", i, name, row.count, L.FormatGoldPlain(row.copper or 0)))
                yOff = yOff + 16
                shown = shown + 1
            end
        end
        if shown == 0 then
            local none = GetStatsText(content)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            none:SetText("|cff888888No autodelete data yet.|r")
            yOff = yOff + 16
        end
        yOff = yOff + 4
    end

    -- Top autosold items (lifetime, by vendor value gained)
    local vendStats = InstanceTrackerDB.autoVendorStats
    if vendStats and vendStats.items then
        local vendHeader = GetStatsText(content)
        vendHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        vendHeader:SetText("--- Top autosold items ---")
        L.StyleFugaziHeader(vendHeader)
        yOff = yOff + hdrSpacing

        local tmp2 = {}
        for itemId, entry in pairs(vendStats.items) do
            table.insert(tmp2, { itemId = itemId, count = entry.count or 0, copper = entry.vendorCopper or 0 })
        end
        table.sort(tmp2, function(a, b) return a.copper > b.copper end)

        local shown2 = 0
        for i = 1, math.min(5, #tmp2) do
            local row = tmp2[i]
            if row.count > 0 then
                local name = tostring(row.itemId)
                if GetItemInfo then
                    local itemName = GetItemInfo(row.itemId)
                    if itemName then name = itemName end
                end
                local line = GetStatsText(content)
                line:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
                line:SetText(string.format("|cffcccccc%d.|r |cffffffcc%s|r x%d |cffaaaaaa(%s)|r", i, name, row.count, L.FormatGoldPlain(row.copper or 0)))
                yOff = yOff + 16
                shown2 = shown2 + 1
            end
        end
        if shown2 == 0 then
            local none = GetStatsText(content)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            none:SetText("|cff888888No autosell data yet.|r")
            yOff = yOff + 16
        end
        yOff = yOff + 4
    end

    local rbHeader = GetStatsText(content)
    rbHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    rbHeader:SetText("--- Rarity Breakdown ---")
    L.StyleFugaziHeader(rbHeader)
    yOff = yOff + hdrSpacing
    local rbText = GetStatsText(content)
    rbText:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rbText:SetText(L.FormatQualityCounts(LS.rarityBreakdown) or "|cff888888No data|r")
    yOff = yOff + 22

    local zeHeader = GetStatsText(content)
    zeHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    zeHeader:SetText("--- Best Zones (GPH) ---")
    L.StyleFugaziHeader(zeHeader)
    yOff = yOff + hdrSpacing

    local list = {}
    for name, data in pairs(LS.zoneEfficiency or {}) do
        if data.runCount > 0 and data.totalDuration > 30 then
            local gph = data.totalGold / (data.totalDuration / 3600)
            table.insert(list, { name = name, gph = gph, count = data.runCount })
        end
    end
    table.sort(list, function(a, b) return a.gph > b.gph end)

    if #list == 0 then
        local none = GetStatsText(content)
        none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        none:SetText("|cff888888No instance data yet.|r")
        yOff = yOff + 16
    else
        for i = 1, math.min(5, #list) do
            local item = list[i]
            local row = GetStatsRow(content, false, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
            row.left:SetText("|cff666666" .. i .. ".|r |cffffffcc" .. item.name .. "|r")
            row.right:SetText(L.FormatGold(item.gph) .. "/h")
            row.subLeft:SetText("|cff888888(" .. item.count .. " runs)|r")
            row.subRight:SetText("")
            yOff = yOff + row:GetHeight()
        end
    end

    return yOff
end


----------------------------------------------------------------------
-- Shared Ledger row handlers (no new closures per refresh = no memory leak when Ledger is open)
----------------------------------------------------------------------
function L.StatsRow1_OnMouseUp(self, button)
    if button ~= "LeftButton" then return end
    if self.deleteBtn and self.deleteBtn:IsMouseOver() then return end
    if self.runRef then StaticPopup_Show("INSTANCETRACKER_RENAME_RUN", nil, nil, self.runRef) end
end
function L.StatsRow1_OnEnter(self)
    if self.deleteBtn and self.deleteBtn:IsMouseOver() then return end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine("Click to rename", 0.5, 0.8, 1)
    GameTooltip:Show()
end
function L.StatsRow1_OnLeave() GameTooltip:Hide() end
function L.StatsRow1_Delete_OnClick(self)
    local row = self:GetParent()
    if row and row.deleteIdx then RemoveRunEntry(row.deleteIdx) end
end
function L.StatsRow2_OnMouseUp(self)
    if self.runRef then ShowItemDetail(self.runRef) end
end
function L.StatsRow2_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine("Click to view items", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end
function L.StatsRow2_OnLeave() GameTooltip:Hide() end
local function StatsCurrentRunItems_OnMouseUp()
    local snap = BuildCurrentRunSnapshot()
    if snap then ShowItemDetail(snap, "currentRun") end
end
local function StatsCurrentRunItems_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine("Click to view items", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end
local function StatsCurrentRunItems_OnLeave() GameTooltip:Hide() end

--- Click Ledger search result row: jump to run (highlight row, open Detail, open item list)
local function LedgerSearchResultRow_OnMouseUp(self, button)
    if button ~= "LeftButton" or not self.runIndex then return end
    local run = self.runRef
    if not run then return end
    if statsFrame and statsFrame.ledgerSearchEditBox then
        statsFrame.ledgerSearchEditBox:SetText("")
        statsFrame.ledgerSearchEditBox:ClearFocus()
    end
    if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(self.runIndex) end
    if type(ShowItemDetail) == "function" then ShowItemDetail(run) end
    if type(RefreshStatsUI) == "function" then RefreshStatsUI() end
end
local function LedgerSearchResultRow_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine("Click: open run details and item list", 0.6, 0.85, 0.6)
    GameTooltip:Show()
end
local function LedgerSearchResultRow_OnLeave() GameTooltip:Hide() end

--- Click overview row: left = open run details, right = rename, Ctrl+right = delete entry
local function StatsOverviewRow_OnMouseUp(self, button)
    if button == "RightButton" then
        if IsControlKeyDown() and self.gotoPage then
            if type(RemoveRunEntry) == "function" then RemoveRunEntry(self.gotoPage) end
            if type(RefreshStatsUI) == "function" then RefreshStatsUI() end
            if ledgerDetailFrame and ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then L.RefreshLedgerDetailUI() end
            return
        end
        if self.runRef then
            StaticPopup_Show("INSTANCETRACKER_RENAME_RUN", nil, nil, self.runRef)
        end
        return
    end
    if button ~= "LeftButton" then return end
    if self.gotoPage then
        if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(self.gotoPage) end
    end
end
local function StatsOverviewRow_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine("Left-click: open run details", 0.6, 0.85, 0.6)
    GameTooltip:AddLine("Right-click: rename run", 0.6, 0.85, 0.6)
    GameTooltip:AddLine("Ctrl+Right-click: delete entry", 0.6, 0.85, 0.6)
    GameTooltip:Show()
end
local function StatsOverviewRow_OnLeave() GameTooltip:Hide() end

--- Create the Ledger Detail window (same size as Ledger, opens next to it). Prev/Next flick through runs.
local function CreateLedgerDetailFrame()
    local backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    }
    local f = CreateFrame("Frame", "InstanceTrackerLedgerDetailFrame", UIParent)
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
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(10)
    f.detailPage = 1

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
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText("Run details")
    title:SetTextColor(1, 0.85, 0.4, 1)
    
    f.itTitleBar = titleBar
    f.itTitleText = title

    -- Valuation mode toggle: Vendor Value Runs / Auction Value Runs
    local modeBtn = CreateFrame("Button", nil, titleBar)
    modeBtn:SetHeight(18)
    modeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
    modeBtn:SetNormalFontObject(GameFontNormalSmall)
    modeBtn:SetHighlightFontObject(GameFontHighlightSmall)
    -- Static label to explain that both vendor and auction views are shown.
    modeBtn:SetText("|cffccccccVendor + Auction view|r")
    modeBtn:SetScript("OnClick", nil)
    modeBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("This run shows both views:", 0.6, 0.85, 0.6)
        GameTooltip:AddLine("- Raw gold and vendor totals", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("- Auction totals when pricing data exists", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    modeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerLedgerDetailScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 6)
    f.scrollFrame = scrollFrame
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(L.SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    if L.ApplyInstanceTrackerSkin then L.ApplyInstanceTrackerSkin(f) end
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end
    return f
end

--- Redraw the Ledger Detail window with the run at detailPage. Prev/Next update and refresh.
L.RefreshLedgerDetailUI = function(forceRebuild)
    if not ledgerDetailFrame then return end
    if not forceRebuild and not ledgerDetailFrame:IsShown() then return end
    L.ResetDetailPools()
    if ledgerDetailFrame.scrollFrame then ledgerDetailFrame.scrollFrame:SetVerticalScroll(0) end

    local content = ledgerDetailFrame.content
    content._detailHoverFrames = content._detailHoverFrames or {}
    for _, hf in ipairs(content._detailHoverFrames) do if hf then hf:Hide() end end
    local detailHoverIdx = 0

    -- fullText = text currently assigned to the fontstring (usually the right-side value)
    -- tooltipLine (optional) = alternate full-line text to show in the tooltip, e.g. "Label: value"
    local function MaybeTruncateDetail(fs, fullText, rowY, rowH, maxChars, tooltipLine)
        local valuePlain = L.StripColorCodes(fullText or "")
        local limit = maxChars or L.LEDGER_STAT_MAX_CHARS
        local wantTooltipAlways = tooltipLine ~= nil
        if #valuePlain <= limit and not wantTooltipAlways then return end
        if #valuePlain > limit then
            fs:SetText(valuePlain:sub(1, limit - 3) .. "...")
        end
        detailHoverIdx = detailHoverIdx + 1
        local hf = content._detailHoverFrames[detailHoverIdx]
        if not hf then
            hf = CreateFrame("Frame", nil, content)
            hf:EnableMouse(true)
            hf:SetScript("OnEnter", function(self)
                if self._fullText then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(self._fullText, 1, 1, 1, true)
                    GameTooltip:Show()
                end
            end)
            hf:SetScript("OnLeave", function() GameTooltip:Hide() end)
            content._detailHoverFrames[detailHoverIdx] = hf
        end
        local tooltipPlain = tooltipLine and L.StripColorCodes(tooltipLine) or valuePlain
        hf._fullText = tooltipPlain
        hf:ClearAllPoints()
        hf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -rowY)
        hf:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - 8, -(rowY + rowH))
        hf:Show()
    end

    local yOff = 6
    local fontSettings = L.GetFugaziFontSettings()
    local lineH = L.GetFugaziRowHeight(18)
    local rowGap = 4
    local sectionGap = 8
    local itemsGainedMargin = 8
    local history = InstanceTrackerDB.runHistory or {}
    local page = ledgerDetailFrame.detailPage or 1
    if page < 1 then page = 1 end
    if page > #history then page = math.max(1, #history) end
    ledgerDetailFrame.detailPage = page

    local run = history[page]
    -- Title bar: show character name (who completed this run), centered; same font/skin as rest of frame
    if ledgerDetailFrame.itTitleText then
        ledgerDetailFrame.itTitleText:SetText(run and (run.characterName and run.characterName ~= "" and run.characterName or "Run details") or "Run details")
    end
    if not run or #history == 0 then
        local noRun = L.GetDetailText(content)
        noRun:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        noRun:SetText("|cff888888No run at this index.|r")
        content:SetHeight(24)
        if statsFrame and statsFrame.detailNavPageLabel then
            statsFrame.detailNavPageLabel:SetText("—")
            statsFrame.detailNavPrevBtn:Hide()
            statsFrame.detailNavNextBtn:Hide()
        end
        return
    end

    -- Run name row (click to rename); use header style so it matches section headers
    local nameRowY = yOff
    local nameRow = L.GetDetailRow(content, false)
    nameRow:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    nameRow.runRef = run
    local nameText = L.GetRunDisplayName(run)
    nameRow.left:SetText(nameText)
    nameRow.right:SetText("")
    L.StyleFugaziHeader(nameRow.left)
    MaybeTruncateDetail(nameRow.left, nameText, nameRowY, lineH)
    nameRow:EnableMouse(true)
    nameRow:SetScript("OnMouseUp", L.StatsRow1_OnMouseUp)
    nameRow:SetScript("OnEnter", L.StatsRow1_OnEnter)
    nameRow:SetScript("OnLeave", L.StatsRow1_OnLeave)
    local nameRowH = nameRow:GetHeight()
    if not nameRowH or nameRowH < 18 then nameRowH = lineH end
    yOff = yOff + nameRowH + rowGap

    local dur = run.duration or 0
    local dateStr = run.enterTime and L.FormatDateTime(run.enterTime) or ""
    local rDurY = yOff
    local rDur = L.GetDetailRow(content, false)
    rDur:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rDur.left:SetText(L.ColorizeFugaziRowLabel("Duration:"))
    local durText = "|cffffffff" .. L.FormatTimeMedium(dur) .. "|r  |cff666666" .. dateStr .. "|r"
    rDur.right:SetText(durText)
    MaybeTruncateDetail(rDur.right, durText, rDurY, lineH)
    yOff = yOff + lineH + rowGap

    -- Extra space before Items gained (interactive row)
    yOff = yOff + itemsGainedMargin

    -- Items gained (clickable row; needs visual separation)
    local qcText = L.FormatQualityCounts(run.qualityCounts)
    if qcText == "|cff555555-|r" or qcText == "" then qcText = "|cff888888No items|r" end
    local rItemsY = yOff
    local rItems = L.GetDetailRow(content, false)
    rItems:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rItems.left:SetText(L.ColorizeFugaziRowLabel("Items gained:"))
    rItems.right:SetText(qcText)
    MaybeTruncateDetail(rItems.right, qcText, rItemsY, lineH)
    rItems.runRef = run
    rItems.highlight:Show()
    rItems:EnableMouse(true)
    rItems:SetScript("OnMouseUp", L.StatsRow2_OnMouseUp)
    rItems:SetScript("OnEnter", L.StatsRow2_OnEnter)
    rItems:SetScript("OnLeave", L.StatsRow2_OnLeave)
    yOff = yOff + lineH + itemsGainedMargin

    -- Section gap before economy block
    yOff = yOff + sectionGap

    local rawGold = run.goldCopper or 0
    local vendorItems = L.ComputeRunVendorItemsValue(run)
    local auctionItems = L.ComputeRunAuctionItemsValue(run)
    local runVendorGold = run.vendorGold or 0
    local runRepairCopper = run.repairCopper or 0

    -- Total net gold change during the run (vendored items, quests, looted coins, repairs, etc.)
    local rGoldY = yOff
    local rGold = L.GetDetailRow(content, false)
    rGold:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rGold.left:SetText(L.ColorizeFugaziRowLabel("Total gold this run:"))
    local rGoldText = L.FormatGold(rawGold)
    rGold.right:SetText(rGoldText)
    local rGoldTooltip = (L.StripColorCodes(rGold.left:GetText() or "") .. "  " .. L.StripColorCodes(rGoldText or ""))
    MaybeTruncateDetail(rGold.right, rGoldText, rGoldY, lineH, 16, rGoldTooltip)
    yOff = yOff + lineH + rowGap

    -- Total gold per hour (directly under total gold)
    local rawGPH = 0
    if run.duration and run.duration > 0 then
        rawGPH = math.floor(((run.goldCopper or 0) / run.duration) * 3600)
    end
    local rGphY = yOff
    local rGph = L.GetDetailRow(content, false)
    rGph:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rGph.left:SetText(L.ColorizeFugaziRowLabel("Total gold g/h:"))
    local rGphText = L.FormatGold(rawGPH) .. "/h"
    rGph.right:SetText(rGphText)
    local rGphTooltip = (L.StripColorCodes(rGph.left:GetText() or "") .. "  " .. L.StripColorCodes(rGphText or ""))
    MaybeTruncateDetail(rGph.right, rGphText, rGphY, lineH, 16, rGphTooltip)
    yOff = yOff + lineH + rowGap

    -- Vendor gold from items sold during this run (NPC sales)
    if runVendorGold > 0 then
        local rVendGoldY = yOff
        local rVendGold = L.GetDetailRow(content, false)
        rVendGold:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rVendGold.left:SetText(L.ColorizeFugaziRowLabel("Vendor gold (Items sold during this session/run):"))
        local rVendGoldText = L.FormatGold(runVendorGold)
        rVendGold.right:SetText(rVendGoldText)
        local rVendGoldTooltip = (L.StripColorCodes(rVendGold.left:GetText() or "") .. "  " .. L.StripColorCodes(rVendGoldText or ""))
        MaybeTruncateDetail(rVendGold.right, rVendGoldText, rVendGoldY, lineH, 16, rVendGoldTooltip)
        yOff = yOff + lineH + rowGap
    end

    -- Approximate "raw" gold: coins/quests/etc. without vendor sales (repairs added back)
    local rawNoVendor = rawGold - runVendorGold + runRepairCopper
    local rRawY = yOff
    local rRaw = L.GetDetailRow(content, false)
    rRaw:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rRaw.left:SetText(L.ColorizeFugaziRowLabel("Raw gold (no vendor sales):"))
    local rRawText = L.FormatGold(rawNoVendor)
    rRaw.right:SetText(rRawText)
    local rRawTooltip = (L.StripColorCodes(rRaw.left:GetText() or "") .. "  " .. L.StripColorCodes(rRawText or ""))
    MaybeTruncateDetail(rRaw.right, rRawText, rRawY, lineH, 16, rRawTooltip)
    yOff = yOff + lineH + rowGap

    -- Vendor value of items still in your bags after the run
    local rVendY = yOff
    local rVend = L.GetDetailRow(content, false)
    rVend:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
    rVend.left:SetText(L.ColorizeFugaziRowLabel("Vendor value (Items in Bags after Session/Run):"))
    local rVendText = L.FormatGold(vendorItems)
    rVend.right:SetText(rVendText)
    local rVendTooltip = (L.StripColorCodes(rVend.left:GetText() or "") .. "  " .. L.StripColorCodes(rVendText or ""))
    MaybeTruncateDetail(rVend.right, rVendText, rVendY, lineH, 16, rVendTooltip)
    yOff = yOff + lineH + rowGap

    -- Auction-side view (when we have an estimatedValueCopper from GPH/BAGS)
    if auctionItems > 0 then
        local rAucY = yOff
        local rAuc = L.GetDetailRow(content, false)
        rAuc:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rAuc.left:SetText(L.ColorizeFugaziRowLabel("Auction value (bag items):"))
        local rAucText = L.FormatGold(auctionItems)
        rAuc.right:SetText(rAucText)
        local rAucTooltip = (L.StripColorCodes(rAuc.left:GetText() or "") .. "  " .. L.StripColorCodes(rAucText or ""))
        MaybeTruncateDetail(rAuc.right, rAucText, rAucY, lineH, 16, rAucTooltip)
        yOff = yOff + lineH + rowGap
    end

    -- Per-run stats (this session/run only; consistent row spacing)
    local runRepairs = run.repairCount or 0
    local runRepairCopper = run.repairCopper or 0
    local runDeaths = run.deaths or 0
    local runAutodel = run.itemsAutodeleted or 0
    local runAutodelCopper = run.autodeletedVendorCopper or 0
    do
        local rRepY = yOff
        local rRep = L.GetDetailRow(content, false)
        rRep:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rRep.left:SetText(L.ColorizeFugaziRowLabel("Repairs (this run):"))
        local rRepText = runRepairs .. " repairs, " .. L.FormatGold(runRepairCopper)
        rRep.right:SetText(rRepText)
        local rRepTooltip = (L.StripColorCodes(rRep.left:GetText() or "") .. "  " .. L.StripColorCodes(rRepText or ""))
        MaybeTruncateDetail(rRep.right, rRepText, rRepY, lineH, nil, rRepTooltip)
        yOff = yOff + lineH + rowGap

        local rDeathY = yOff
        local rDeath = L.GetDetailRow(content, false)
        rDeath:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rDeath.left:SetText(L.ColorizeFugaziRowLabel("Deaths (this run):"))
        local rDeathText = "|cffcc6666" .. runDeaths .. "|r"
        rDeath.right:SetText(rDeathText)
        local rDeathTooltip = (L.StripColorCodes(rDeath.left:GetText() or "") .. "  " .. L.StripColorCodes(rDeathText or ""))
        MaybeTruncateDetail(rDeath.right, rDeathText, rDeathY, lineH, nil, rDeathTooltip)
        yOff = yOff + lineH + rowGap

        local rDelY = yOff
        local rDel = L.GetDetailRow(content, false)
        rDel:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rDel.left:SetText(L.ColorizeFugaziRowLabel("Items autodeleted (this run):"))
        local rDelText = string.format("%d items, %s lost", runAutodel, L.FormatGoldPlain(runAutodelCopper))
        rDel.right:SetText(rDelText)
        local rDelTooltip = (L.StripColorCodes(rDel.left:GetText() or "") .. "  " .. L.StripColorCodes(rDelText or ""))
        MaybeTruncateDetail(rDel.right, rDelText, rDelY, lineH, nil, rDelTooltip)
        yOff = yOff + lineH + rowGap
    end

    yOff = yOff + sectionGap
    content:SetHeight(yOff)

    -- Nav on Ledger window: Run X of N, Prev/Next visibility
    if statsFrame and statsFrame.detailNavPageLabel then
        statsFrame.detailNavPageLabel:SetText("Run " .. page .. " of " .. #history)
        if page > 1 then statsFrame.detailNavPrevBtn:Show() else statsFrame.detailNavPrevBtn:Hide() end
        if page < #history then statsFrame.detailNavNextBtn:Show() else statsFrame.detailNavNextBtn:Hide() end
    end
end

--- Open the Ledger Detail window on the given run index (1-based). Positions it next to the Ledger.
function ShowLedgerDetail(runIndex)
    if not statsFrame then return end
    if not ledgerDetailFrame then
        ledgerDetailFrame = CreateLedgerDetailFrame()
    end
    ledgerDetailFrame:ClearAllPoints()
    ledgerDetailFrame:SetPoint("TOPLEFT", statsFrame, "TOPRIGHT", 4, 0)
    ledgerDetailFrame:SetWidth(statsFrame:GetWidth())
    ledgerDetailFrame:SetHeight(statsFrame:GetHeight())
    ledgerDetailFrame.detailPage = runIndex
    ledgerDetailFrame:Show()
    L.RefreshLedgerDetailUI()
end

--- Displays search results from the Ledger (item-level filtering). Optional tabFilter(run) limits to Sessions or Dungeons.
local function RefreshStatsLedgerSearchResults(content, history, yOff, searchText, ledgerBarFilter, tabFilter)
    local searchLower = searchText:lower()
    local results = {}
    for i, run in ipairs(history) do
        if tabFilter and not tabFilter(run) then
            -- skip runs not in this tab
        else
            local runNameLower = (run.name and run.name:lower()) or ""
            local customLower = (run.customName and run.customName:lower()) or ""
            local runMatches = runNameLower:find(searchLower, 1, true) or (customLower ~= "" and customLower:find(searchLower, 1, true))
            for _, item in ipairs(run.items or {}) do
                if ledgerBarFilter == nil or item.quality == ledgerBarFilter then
                    local itemNameLower = (item.name and item.name:lower()) or ""
                    local itemMatches = itemNameLower:find(searchLower, 1, true)
                    local qualityMatches = false
                    for q = 0, 5 do
                        local info = L.QUALITY_COLORS[q]
                        if info and info.label and info.label:lower():find(searchLower, 1, true) and item.quality == q then
                            qualityMatches = true
                            break
                        end
                    end
                    if runMatches or itemMatches or qualityMatches then
                        table.insert(results, { runIndex = i, run = run, item = item })
                    end
                end
            end
        end
    end
    table.sort(results, function(a, b)
        if a.runIndex ~= b.runIndex then return a.runIndex < b.runIndex end
        if a.item.quality ~= b.item.quality then return a.item.quality > b.item.quality end
        return (a.item.name or "") < (b.item.name or "")
    end)
    local hdrSearch = GetStatsText(content)
    hdrSearch:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    hdrSearch:SetText("--- Search: \"" .. searchText:sub(1, 24) .. (searchText:len() > 24 and "..." or "") .. "\" (" .. #results .. ") ---")
    L.StyleFugaziHeader(hdrSearch)
    yOff = yOff + 18
    if #results == 0 then
        local noRes = GetStatsText(content)
        noRes:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        noRes:SetText("|cff888888No matching items.|r")
        yOff = yOff + 14
    else
        for _, r in ipairs(results) do
            local row = GetStatsRow(content, false, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            row.runIndex = r.runIndex
            row.runRef = r.run
            local runDisp = L.GetRunDisplayName(r.run)
            local qInfo = L.QUALITY_COLORS[r.item.quality] or L.QUALITY_COLORS[1]
            local itemStr = "|cff" .. qInfo.hex .. (r.item.name or "?") .. "|r"
            if r.item.count and r.item.count > 1 then itemStr = itemStr .. " x" .. r.item.count end
            row.left:SetText(itemStr)
            row.right:SetText("")
            row.subLeft:SetText("|cff888888from " .. runDisp .. "|r")
            row.subRight:SetText("")
            row.highlight:Show()
            row:EnableMouse(true)
            row:SetScript("OnMouseUp", LedgerSearchResultRow_OnMouseUp)
            row:SetScript("OnEnter", LedgerSearchResultRow_OnEnter)
            row:SetScript("OnLeave", LedgerSearchResultRow_OnLeave)
            yOff = yOff + row:GetHeight() + 2
        end
    end
    yOff = yOff + 8
    content:SetHeight(yOff)
end

--- Returns the first (runIndex, run) that has an item matching searchText (and optional ledgerBarFilter). No tab filter = search all runs. Used to auto-open Detail + item list when typing in Ledger search.
local function GetFirstLedgerSearchMatch(history, searchText, ledgerBarFilter)
    if not searchText or searchText == "" then return nil, nil end
    local searchLower = searchText:lower()
    for i, run in ipairs(history) do
        local runNameLower = (run.name and run.name:lower()) or ""
        local customLower = (run.customName and run.customName:lower()) or ""
        local runMatches = runNameLower:find(searchLower, 1, true) or (customLower ~= "" and customLower:find(searchLower, 1, true))
        for _, item in ipairs(run.items or {}) do
            if ledgerBarFilter == nil or item.quality == ledgerBarFilter then
                local itemNameLower = (item.name and item.name:lower()) or ""
                local itemMatches = itemNameLower:find(searchLower, 1, true)
                local qualityMatches = false
                for q = 0, 5 do
                    local info = L.QUALITY_COLORS[q]
                    if info and info.label and info.label:lower():find(searchLower, 1, true) and item.quality == q then
                        qualityMatches = true
                        break
                    end
                end
                if runMatches or itemMatches or qualityMatches then
                    return i, run
                end
            end
        end
    end
    return nil, nil
end

--- Build rarity breakdown and zone efficiency from dungeon runs only (exclude GPH).
local function GetDungeonOnlyStats()
    local history = InstanceTrackerDB.runHistory or {}
    local rarityBreakdown = {}
    local zoneEfficiency = {}
    for _, run in ipairs(history) do
        if not IsGPHRun(run) and run.name and run.name ~= "" then
            if run.qualityCounts then
                for q, count in pairs(run.qualityCounts) do
                    rarityBreakdown[q] = (rarityBreakdown[q] or 0) + count
                end
            end
            local dur = run.duration or 0
            local gold = run.goldCopper or 0
            local ze = zoneEfficiency[run.name] or { totalGold = 0, totalDuration = 0, runCount = 0 }
            ze.totalGold = ze.totalGold + gold
            ze.totalDuration = ze.totalDuration + dur
            ze.runCount = ze.runCount + 1
            zoneEfficiency[run.name] = ze
        end
    end
    return rarityBreakdown, zoneEfficiency
end

--- Scratch arrays for RefreshStatsUI to avoid allocating hundreds of tables per second (was causing 70–80 KB/s climb).
local _scratchFilteredIndex, _scratchFilteredRun = {}, {}
local _scratchValidIndex, _scratchValidRun = {}, {}

--- Redraws the Ledger: tab 1 = Lifetime (always-on), tab 2 = Sessions (GPH list), tab 3 = Dungeons (run list + rarity/zones).
RefreshStatsUI = function(forceRebuild)
    local frame = _G.InstanceTrackerStatsFrame or statsFrame
    statsFrame = frame
    if not frame then return end
    if not forceRebuild and not frame:IsShown() then return end
    ResetStatsPools()
    -- Do not reset scroll here (causes flick to top); scroll is reset only when switching tabs in UpdateStatsTabs.

    -- Ledger nav bar: "Run X of Y" = chronological (all runs). Lifetime shows "Run 1 of N"; Next goes to run 1 (most recent). Sessions/Dungeons: Prev/Next move 1..N and switch tab when run type changes.
    do
        local history = InstanceTrackerDB.runHistory or {}
        local tab = frame.selectedTab or 1
        local detailPage = (ledgerDetailFrame and ledgerDetailFrame.detailPage) or 1
        local n = #history
        if frame.detailNavPageLabel then
            if n == 0 then
                frame.detailNavPageLabel:SetText("—")
                frame.detailNavPrevBtn:Hide()
                frame.detailNavNextBtn:Hide()
            else
                local showOrdinal = (tab == 1) and 1 or (detailPage >= 1 and detailPage <= n) and detailPage or 1
                frame.detailNavPageLabel:SetText("Run " .. showOrdinal .. " of " .. n)
                if tab == 1 then
                    frame.detailNavPrevBtn:Hide()
                    frame.detailNavNextBtn:Show()
                else
                    frame.detailNavPrevBtn:Show()
                    frame.detailNavNextBtn:Show()
                    if detailPage <= 1 then frame.detailNavPrevBtn:Hide() end
                    if detailPage >= n then frame.detailNavNextBtn:Hide() end
                end
            end
        end
    end

    -- Re-apply frame opacity from BAGS so FIT windows stay in sync when Ledger is open
    local SVop = _G.FugaziBAGSDB
    local fa = (SVop and SVop.gphFrameAlpha) or 1
    for _, frameName in ipairs({ "InstanceTrackerFrame", "InstanceTrackerStatsFrame", "InstanceTrackerLedgerDetailFrame", "InstanceTrackerItemDetailFrame" }) do
        local fr = _G[frameName]
        if fr and fr.SetAlpha then fr:SetAlpha(fa > 0.99 and 1 or fa) end
    end

    local content = frame.content
    local fontSettings = L.GetFugaziFontSettings()
    local hdrSpacing = (fontSettings.headerSize or 11) + 6

    -- Ledger search drives path only (tab + Detail + item list). Do this before tab check so typing from Lifetime switches to Sessions/Dungeons.
    local searchTextEarly = (frame.ledgerSearchEditBox and frame.ledgerSearchEditBox:GetText() or ""):match("^%s*(.-)%s*$")
    if searchTextEarly and searchTextEarly ~= "" then
        local historyEarly = InstanceTrackerDB.runHistory or {}
        local ledgerBarFilterEarly = frame.ledgerBarFilter
        local firstRunIndex, firstRun = GetFirstLedgerSearchMatch(historyEarly, searchTextEarly, ledgerBarFilterEarly)
        if firstRunIndex and firstRun then
            local wantTab = IsGPHRun(firstRun) and 2 or 3
            frame.selectedTab = wantTab
            local selectedColor = { 0.4, 0.35, 0.15, 0.9 }
            local normalColor = { 0.15, 0.15, 0.15, 0.7 }
            local greyColor = { 0.25, 0.25, 0.22, 0.85 }
            if frame.statsTab1 and frame.statsTab1.bg then frame.statsTab1.bg:SetTexture(unpack(wantTab == 1 and greyColor or normalColor)) end
            if frame.statsTab2 and frame.statsTab2.bg then frame.statsTab2.bg:SetTexture(unpack(wantTab == 2 and selectedColor or normalColor)) end
            if frame.statsTab3 and frame.statsTab3.bg then frame.statsTab3.bg:SetTexture(unpack(wantTab == 3 and selectedColor or normalColor)) end
            if type(ShowLedgerDetail) == "function" then ShowLedgerDetail(firstRunIndex) end
            if type(ShowItemDetail) == "function" then ShowItemDetail(firstRun) end
        end
    end

    -- Tab 1: Lifetime (always-on stats only)
    if frame.selectedTab == 1 then
        if InstanceTrackerDB.statsCollapsed then
            local hdr = GetStatsText(content)
            hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
            hdr:SetText("--- Lifetime ---")
            L.StyleFugaziHeader(hdr)
            content:SetHeight(24)
            return
        end
        L.RefreshStatsLifetimeUI(content)
        return
    end

    local yOff = 0
    local now = time()
    local history = InstanceTrackerDB.runHistory or {}

    -- Hide Lifetime-tab hover frames so they don't sit on top of Sessions/Dungeons and show wrong tooltips
    if content.summaryGoldHoverFrame then content.summaryGoldHoverFrame:Hide() end
    if content.lifetimeGoldHoverFrame then content.lifetimeGoldHoverFrame:Hide() end
    if content.lifetimeDeathsHoverFrame then content.lifetimeDeathsHoverFrame:Hide() end
    if content._statHoverFrames then for _, hf in ipairs(content._statHoverFrames) do if hf then hf:Hide() end end end

    -- Filter by tab: Sessions = GPH only, Dungeons = non-GPH only
    local tabFilter = (frame.selectedTab == 2) and function(r) return IsGPHRun(r) end
        or (frame.selectedTab == 3) and function(r) return not IsGPHRun(r) end
        or nil
    local collapsedLabel = (frame.selectedTab == 2) and "--- Sessions ---" or "--- Dungeons ---"
    local rowH = L.GetFugaziRowHeight(18)
    local smallH = L.GetFugaziRowHeight(16)

    if InstanceTrackerDB.statsCollapsed then
        local hdr = GetStatsText(content)
        hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        hdr:SetText(collapsedLabel)
        L.StyleFugaziHeader(hdr)
        content:SetHeight(24)
        return
    end

    -- Current run (live) – only on Dungeons tab
    local hdr = GetStatsText(content)
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    L.StyleFugaziHeader(hdr)
    if frame.selectedTab == 3 and currentRun then
        local dur = now - currentRun.enterTime
        local liveGold = GetMoney() - startingGold
        if liveGold < 0 then liveGold = 0 end
        hdr:SetText("--- Current: " .. (currentRun.name or "?") .. " ---")
        yOff = yOff + hdrSpacing
        local rDur = GetStatsRow(content, false, true)
        rDur:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rDur.left:SetText("|cffffffcc" .. (currentRun.name or "?") .. "|r")
        rDur.right:SetText("")
        rDur.subLeft:SetText("|cffaaaaaa" .. L.FormatTimeMedium(dur) .. "|r  |cff888888" .. L.FormatDateTime(currentRun.enterTime) .. "|r")
        rDur.subRight:SetText(L.FormatGold(liveGold))
        yOff = yOff + rDur:GetHeight()
        local rItems = GetStatsRow(content, false)
        rItems:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rItems.right:SetText("")
        local qcText = L.FormatQualityCounts(currentRun.qualityCounts)
        if qcText == "|cff555555-|r" or qcText == "" then qcText = "|cff888888None|r" end
        rItems.left:SetText("|cffccccccItems gained:|r " .. qcText)
        rItems.highlight:Show()
        rItems:EnableMouse(true)
        rItems:SetScript("OnMouseUp", StatsCurrentRunItems_OnMouseUp)
        rItems:SetScript("OnEnter", StatsCurrentRunItems_OnEnter)
        rItems:SetScript("OnLeave", StatsCurrentRunItems_OnLeave)
        yOff = yOff + rItems:GetHeight()
    else
        if frame.selectedTab == 3 then
            hdr:SetText("--- Current Run ---")
            yOff = yOff + hdrSpacing
            local noRun = GetStatsText(content)
            noRun:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            noRun:SetText("|cff888888Not in an instance.|r")
            yOff = yOff + smallH
        else
            hdr:SetText("--- Sessions ---")
            yOff = yOff + hdrSpacing
        end
    end
    yOff = yOff + 10

    -- Filtered history (reuse scratch arrays to avoid 100+ table allocations per refresh)
    wipe(_scratchFilteredIndex)
    wipe(_scratchFilteredRun)
    for i, run in ipairs(history) do
        if not tabFilter or tabFilter(run) then
            _scratchFilteredIndex[#_scratchFilteredIndex + 1] = i
            _scratchFilteredRun[#_scratchFilteredRun + 1] = run
        end
    end

    -- Filter: rarity bar limits by quality. (Search text only drives path via early block above; no search results shown in Ledger.)
    local ledgerBarFilter = frame.ledgerBarFilter

    -- Valid history (filter by quality bar or use filtered; reuse scratch)
    wipe(_scratchValidIndex)
    wipe(_scratchValidRun)
    if ledgerBarFilter ~= nil then
        for idx = 1, #_scratchFilteredRun do
            local run = _scratchFilteredRun[idx]
            if run.qualityCounts and run.qualityCounts[ledgerBarFilter] and run.qualityCounts[ledgerBarFilter] > 0 then
                _scratchValidIndex[#_scratchValidIndex + 1] = _scratchFilteredIndex[idx]
                _scratchValidRun[#_scratchValidRun + 1] = run
            end
        end
    else
        for idx = 1, #_scratchFilteredRun do
            _scratchValidIndex[#_scratchValidIndex + 1] = _scratchFilteredIndex[idx]
            _scratchValidRun[#_scratchValidRun + 1] = _scratchFilteredRun[idx]
        end
    end

    local nValid = #_scratchValidIndex
    local hdr2 = GetStatsText(content)
    hdr2:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
    if ledgerBarFilter ~= nil then
        hdr2:SetText("--- Filtered History (" .. nValid .. ") ---")
    else
        hdr2:SetText("--- History (" .. nValid .. "/" .. L.MAX_RUN_HISTORY .. ") ---")
    end
    L.StyleFugaziHeader(hdr2)
    yOff = yOff + hdrSpacing

    if nValid == 0 then
        local noHist = GetStatsText(content)
        noHist:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        noHist:SetText(ledgerBarFilter ~= nil and "|cff888888No runs matching filter.|r" or "|cff888888No runs recorded yet.|r")
        yOff = yOff + smallH
    else
        local detailPage = (ledgerDetailFrame and ledgerDetailFrame:IsShown()) and ledgerDetailFrame.detailPage or nil
        for idx = 1, nValid do
            local i = _scratchValidIndex[idx]
            local run = _scratchValidRun[idx]
            local dur = run.duration or 0
            local row = GetStatsRow(content, false, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
            row.gotoPage = i
            row.runRef = run
            
            row.left:SetText("|cff666666" .. i .. ".|r |cffffffcc" .. L.GetRunDisplayName(run) .. "|r")
            row.right:SetText("")
            row.subLeft:SetText("|cffaaaaaa" .. L.FormatTimeMedium(dur) .. "|r  |cff888888" .. L.FormatDateTime(run.enterTime) .. "|r")
            row.subRight:SetText(L.FormatGold(run.goldCopper))
            
            if row.selectedBg then
                if detailPage and i == detailPage then row.selectedBg:Show() else row.selectedBg:Hide() end
            end
            row.highlight:Show()
            row:EnableMouse(true)
            row:SetScript("OnMouseUp", StatsOverviewRow_OnMouseUp)
            row:SetScript("OnEnter", StatsOverviewRow_OnEnter)
            row:SetScript("OnLeave", StatsOverviewRow_OnLeave)
            yOff = yOff + row:GetHeight() + 2
        end
    end

    -- Dungeons tab only: rarity breakdown and best zones (from dungeon runs only)
    if frame.selectedTab == 3 then
        local rarityBreakdown, zoneEfficiency = GetDungeonOnlyStats()
        yOff = yOff + 8
        local rbHeader = GetStatsText(content)
        rbHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        rbHeader:SetText("--- Rarity Breakdown ---")
        L.StyleFugaziHeader(rbHeader)
        yOff = yOff + hdrSpacing
        local rbText = GetStatsText(content)
        rbText:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
        rbText:SetText(L.FormatQualityCounts(rarityBreakdown) or "|cff888888No data|r")
        yOff = yOff + rowH + 4
        local zeHeader = GetStatsText(content)
        zeHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
        zeHeader:SetText("--- Best Zones (GPH) ---")
        L.StyleFugaziHeader(zeHeader)
        yOff = yOff + hdrSpacing
        local list = {}
        for name, data in pairs(zoneEfficiency or {}) do
            if data.runCount > 0 and data.totalDuration > 30 then
                local gph = data.totalGold / (data.totalDuration / 3600)
                table.insert(list, { name = name, gph = gph, count = data.runCount })
            end
        end
        table.sort(list, function(a, b) return a.gph > b.gph end)
        if #list == 0 then
            local none = GetStatsText(content)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
            none:SetText("|cff888888No instance data yet.|r")
            yOff = yOff + smallH
        else
            for i = 1, math.min(5, #list) do
                local item = list[i]
                local row = GetStatsRow(content, false, true)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOff)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
                row.left:SetText("|cff666666" .. i .. ".|r |cffffffcc" .. L.TruncateWithColors(item.name, 22) .. "|r")
                row.right:SetText(L.FormatGold(item.gph) .. "/h")
                row.subLeft:SetText("|cff888888(" .. item.count .. " runs)|r")
                row.subRight:SetText("")
                yOff = yOff + row:GetHeight()
            end
        end
        yOff = yOff + 4
    end

    yOff = yOff + 8
    content:SetHeight(yOff)
end
----------------------------------------------------------------------
-- GPH (Gold Per Hour) window: the inventory/session UI. Actually created
-- by __FugaziBAGS when both addons are loaded; we define pools and refresh
-- logic here so the Ledger can show GPH sessions and record them.
----------------------------------------------------------------------
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
        row:SetWidth(L.SCROLL_CONTENT_WIDTH)
        row:SetHeight(L.GetFugaziRowHeight(18))

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

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        left:SetPoint("LEFT", delBtn, "RIGHT", 2, 0)
        left:SetJustifyH("LEFT")
        row.left = left
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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
        btn:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
            if L.GetGphProtectedSet then L.GetGphProtectedSet()[d.itemId] = nil end
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
            L.QueueDestroySlotsForItemId(itemId)
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
            L.QueueDestroySlotsForItemId(itemId)
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
        if id and L.GetGphProtectedSet then
            L.GetGphProtectedSet()[id] = nil
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
            L.AddonPrint(
                L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "GPH session reset."
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
        L.SaveFrameLayout(f, "gphShown", "gphPoint")
    end)
    f:SetScript("OnHide", function()
        -- Don't save when frame is at bank layout (2,-80); keep user's preferred position for /reload
        local p, _, rp, x, y = f:GetPoint(1)
        if not (p and rp and x == 2 and y == -80) then
            L.SaveFrameLayout(f, "gphShown", "gphPoint")
        end
    end)
    f:SetScript("OnShow", function()
        -- When GPH is shown, scroll so first visible row is the line above hearthstone (saved items above require scrolling up)
        f.gphScrollToDefaultOnNextRefresh = true
        -- Defer refresh so frame is fully shown (RefreshGPHUI returns if not IsShown()) and layout is ready
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

    -- Order left-to-right: bag (keybind), magnifier (scale). Autosell/summon Greedy are in __FugaziBAGS when that addon is loaded.
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
    invBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function UpdateInvBtn()
        invBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
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
        if _G.InstanceTrackerGPHCombatToggleBtn then
            GameTooltip:AddLine("Bag key works in combat.", 0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("In combat: use |cffaaffaa/gph|r or click to open", 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine("Left-click: Toggle inv key", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end
    invBtn:SetScript("OnClick", function()
        InstanceTrackerDB.gphInvKeybind = not InstanceTrackerDB.gphInvKeybind
        if InstanceTrackerDB.gphInvKeybind then
            L.InstallGPHInvHook()
            if f.gphInvKeybindBtn then
                f.gphInvKeybindBtn:Show()
                f.gphInvKeybindBtn:SetAlpha(1)
                L.ApplyGPHInvKeyOverride(f.gphInvKeybindBtn)
            end
        else
            L.RemoveGPHInvHook()
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
        if InstanceTrackerDB.gphInvKeybind then
            invBtn.bg:SetTexture(0.5, 0.45, 0.2, 0.9)
        else
            invBtn.bg:SetTexture(0.55, 0.2, 0.15, 0.9)
        end
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

    -- SecureHandlerClickTemplate button: override targets this so bag key works in combat (secure handler can Show/Hide ref'd frame)
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
        if InstanceTrackerDB.gphInvKeybind and f.gphInvKeybindBtn then
            L.ApplyGPHInvKeyOverride(f.gphInvKeybindBtn)
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
        local debug = InstanceTrackerDB.gphCollapseDebug
        local inCombat = (InCombatLockdown and InCombatLockdown()) or false
        if debug then
            DEFAULT_CHAT_FRAME:AddMessage("[Fugazi collapse] UpdateGPHCollapse: gphCollapsed=" .. tostring(InstanceTrackerDB.gphCollapsed) .. " combat=" .. tostring(inCombat) .. " hasScroll=" .. tostring(f.scrollFrame ~= nil) .. " frameH=" .. tostring(f:GetHeight()))
        end
        if not f.scrollFrame then return end
        if f.gphCollapseBtn then f.gphCollapseBtn:Show(); f.gphCollapseBtn:SetFrameLevel(f:GetFrameLevel() + 50) end
        if InstanceTrackerDB.gphCollapsed then
            collapseBg:SetTexture(0.4, 0.35, 0.2, 0.8)
            collapseIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            local collH = InstanceTrackerDB.gphDockedToMain and 150 or 70
            L.CollapseInPlace(f, collH, function(rel)
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
        if InstanceTrackerDB.gphSortMode ~= "vendor" and InstanceTrackerDB.gphSortMode ~= "rarity" and InstanceTrackerDB.gphSortMode ~= "itemlevel" and InstanceTrackerDB.gphSortMode ~= "category" then
            InstanceTrackerDB.gphSortMode = "rarity"
        end
        if InstanceTrackerDB.gphSortMode == "vendor" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        elseif InstanceTrackerDB.gphSortMode == "itemlevel" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_19")
        elseif InstanceTrackerDB.gphSortMode == "category" then
            sortIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
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
        elseif mode == "category" then
            GameTooltip:AddLine("Category (Weapon, Armor, etc.)", 0.7, 0.8, 1)
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
        elseif mode == "itemlevel" then
            InstanceTrackerDB.gphSortMode = "category"
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

    -- Scale ×1.5: left of bag button; magnifying glass icon
    local scaleBtn = CreateFrame("Button", nil, titleBar)
    scaleBtn:EnableMouse(true)
    scaleBtn:SetHitRectInsets(0, 0, 0, 0)
    scaleBtn:SetSize(22, GPH_BTN_H)
    scaleBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    invBtn:ClearAllPoints()
    invBtn:SetPoint("LEFT", scaleBtn, "RIGHT", GPH_BTN_GAP, 0)
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

    -- Title bar layout: scale (magnifier), then bag (keybind). No summon/autosell here; __FugaziBAGS owns those when loaded.
    local function UpdateGphTitleBarButtonLayout()
        scaleBtn:ClearAllPoints()
        scaleBtn:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
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
    gphBottomRight:SetText(GetMoney and L.FormatGold(GetMoney()) or "")

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
                content:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
        c:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
    content:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
                L.AnchorTooltipRight(self)
                local lp = link:match("|H(item:[^|]+)|h") or link
                if lp then GameTooltip:SetHyperlink(lp) end
                GameTooltip:AddLine(" ")
                local id = tonumber(link:match("item:(%d+)"))
                if id and L.GetGphProtectedSet and L.GetGphProtectedSet()[id] then
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
            c:SetWidth(L.SCROLL_CONTENT_WIDTH)
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
            -- No full RefreshGPHUI here (list updates on BAG_UPDATE / user actions). Only tick the timer/gold/GPH status so it updates in combat.
            if gphSession and self.gphStatusCenter then
                local nowGph = time()
                local dur = nowGph - gphSession.startTime
                local liveGold = (GetMoney and GetMoney()) and (GetMoney() - gphSession.startGold) or 0
                if liveGold < 0 then liveGold = 0 end
                local gph = dur > 0 and (liveGold / (dur / 3600)) or 0
                if InstanceTrackerDB.gphCollapsed and self.gphStatusLeft and self.gphStatusRight then
                    self.gphStatusLeft:SetText("|cffdaa520Gold:|r " .. L.FormatGold(liveGold))
                    self.gphStatusCenter:SetText("|cffdaa520Timer:|r |cffffffff" .. L.FormatTimeMedium(dur) .. "|r")
                    self.gphStatusRight:SetText("|cffdaa520GPH:|r " .. L.FormatGold(math.floor(gph)))
                else
                    self.statusText:SetText(
                        "|cffdaa520Gold:|r " .. L.FormatGold(liveGold)
                        .. "   |cffdaa520Timer:|r |cffffffff" .. L.FormatTimeMedium(dur) .. "|r"
                        .. "   |cffdaa520GPH:|r " .. L.FormatGold(math.floor(gph))
                    )
                end
            end
            RefreshItemDetailLive()
            -- Bottom bar: FPS left, time center, gold right (latency/ms removed - not reliable on this client)
            if self.gphBottomLeft and self.gphBottomCenter and self.gphBottomRight then
                local fps = (GetFramerate and GetFramerate()) or 0
                self.gphBottomLeft:SetText(("%.0f FPS"):format(fps))
                if date then self.gphBottomCenter:SetText(date("%H:%M")) end
                self.gphBottomRight:SetText(GetMoney and L.FormatGold(GetMoney()) or "")
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
        L.AddonPrint("[Fugazi] GPH ResetGPHPools error: " .. tostring(poolErr))
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
            gphFrame.gphStatusLeft:SetText("|cffdaa520Gold:|r " .. L.FormatGold(liveGold))
            gphFrame.gphStatusLeft:Show()
            gphFrame.gphStatusCenter:SetText("|cffdaa520Timer:|r |cffffffff" .. L.FormatTimeMedium(dur) .. "|r")
            gphFrame.gphStatusCenter:Show()
            gphFrame.gphStatusRight:SetText("|cffdaa520GPH:|r " .. L.FormatGold(math.floor(gph)))
            gphFrame.gphStatusRight:Show()
        else
            if gphFrame.gphStatusLeft then gphFrame.gphStatusLeft:Hide() end
            if gphFrame.gphStatusCenter then gphFrame.gphStatusCenter:Hide() end
            if gphFrame.gphStatusRight then gphFrame.gphStatusRight:Hide() end
            gphFrame.statusText:Show()
            gphFrame.statusText:SetText(
                "|cffdaa520Gold:|r " .. L.FormatGold(liveGold)
                .. "   |cffdaa520Timer:|r |cffffffff" .. L.FormatTimeMedium(dur) .. "|r"
                .. "   |cffdaa520GPH:|r " .. L.FormatGold(math.floor(gph))
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
        local info = L.QUALITY_COLORS[q] or L.QUALITY_COLORS[1]
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
        local rarityFlags = L.GetGphProtectedRarityFlags and L.GetGphProtectedRarityFlags()
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
            if IsControlKeyDown() and button == "LeftButton" and L.GetGphProtectedRarityFlags then
                local flags = L.GetGphProtectedRarityFlags()
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
            L.AnchorTooltipRight(self)
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
    local prevWornSet = L.GetGphProtectedSet()
    local previouslyWornOnlySet = L.GetGphPreviouslyWornOnlySet()
    local rarityFlags = L.GetGphProtectedRarityFlags and L.GetGphProtectedRarityFlags()
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
        local protectedSet = L.GetGphProtectedSet()
        local rFlags = L.GetGphProtectedRarityFlags and L.GetGphProtectedRarityFlags()
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
            local info = L.QUALITY_COLORS[q]
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
                    local info = L.QUALITY_COLORS[q]
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
            local prevWornSet = L.GetGphProtectedSet()
            local previouslyWornOnlySet = L.GetGphPreviouslyWornOnlySet()
            local _, _, q = GetItemInfo and GetItemInfo(did)
            q = q or 0
            local rFlags = L.GetGphProtectedRarityFlags and L.GetGphProtectedRarityFlags()
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

    -- When sort by category: group by GetItemInfo type, order like AH (Weapon, Armor, ...)
    local GPH_CATEGORY_ORDER = { "Weapon", "Armor", "Container", "Consumable", "Gem", "Trade Goods", "Recipe", "Quest", "Miscellaneous", "Other" }
    gphFrame.gphCategoryGroups = nil
    gphFrame.gphCategoryItemList = nil
    if sortMode == "category" and #itemList > 0 and GetItemInfo then
        local typeCache = InstanceTrackerDB.gphItemTypeCache
        if type(typeCache) ~= "table" then
            typeCache = {}
            InstanceTrackerDB.gphItemTypeCache = typeCache
        end
        for _, item in ipairs(itemList) do
            local itemId = item.itemId or (item.link and tonumber(item.link:match("item:(%d+)")))
            local itemType = itemId and typeCache[itemId]
            if not itemType then
                local _, _, _, _, _, giType = GetItemInfo(item.link or item.itemId)
                itemType = (giType and giType ~= "" and giType) or "Other"
                if itemId then typeCache[itemId] = itemType end
            end
            item.itemType = itemType
        end
        local groups = {}
        for _, item in ipairs(itemList) do
            local t = item.itemType or "Other"
            if not groups[t] then groups[t] = {} end
            table.insert(groups[t], item)
        end
        for _, items in pairs(groups) do
            table.sort(items, function(a, b)
                if a.quality ~= b.quality then return a.quality > b.quality end
                if a.name ~= b.name then return a.name < b.name end
                return (a.fromCursor and 1 or 0) < (b.fromCursor and 1 or 0)
            end)
        end
        local orderedGroups = {}
        for _, catName in ipairs(GPH_CATEGORY_ORDER) do
            if groups[catName] and #groups[catName] > 0 then
                table.insert(orderedGroups, { name = catName, items = groups[catName] })
            end
        end
        for catName, items in pairs(groups) do
            local found
            for _, c in ipairs(GPH_CATEGORY_ORDER) do if c == catName then found = true break end end
            if not found then table.insert(orderedGroups, { name = catName, items = items }) end
        end
        gphFrame.gphCategoryGroups = orderedGroups
        if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
        local flat = {}
        local drawList = {}
        for _, grp in ipairs(orderedGroups) do
            local collapsed = gphFrame.gphCategoryCollapsed[grp.name]
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
    else
        gphFrame.gphCategoryDrawList = nil
    end

    if #itemList == 0 then
        local noItems = GetGPHText(content)
        noItems:SetPoint("TOPLEFT", content, "TOPLEFT", L.CONTENT_LEFT_PAD, -yOff)
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
        local itemIdToSlot = L.GetItemIdToBagSlot()
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
                    div = CreateFrame("Button", nil, content)
                    div:EnableMouse(true)
                    div:RegisterForClicks("LeftButtonUp")
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
                    table.insert(pool, div)
                end
                local catName = entry.divider or ""
                local collapsed = entry.collapsed
                div:SetParent(content)
                div:ClearAllPoints()
                div:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -yOff)
                div:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, 0)
                div:SetHeight(12)
                div:EnableMouse(true)
                if div.RegisterForClicks then div:RegisterForClicks("LeftButtonUp") end
                div.label:SetText("|cff888888" .. catName .. (collapsed and " [+]|r" or " [−]|r"))
                div.label:Show()
                div.categoryName = catName
                div:SetScript("OnClick", function()
                    if not gphFrame.gphCategoryCollapsed then gphFrame.gphCategoryCollapsed = {} end
                    gphFrame.gphCategoryCollapsed[catName] = not gphFrame.gphCategoryCollapsed[catName]
                    if RefreshGPHUI then RefreshGPHUI() end
                end)
                div:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Click to collapse/expand")
                    GameTooltip:Show()
                end)
                div:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
            btn.icon:SetTexture(L.GetSafeItemTexture(item.link or item.itemId, item.texture))
            local qInfo = L.QUALITY_COLORS[item.quality] or L.QUALITY_COLORS[1]
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
                gphFrame.gphSelectedIndex = itemIdx
                gphFrame.gphSelectedRowY = yOff
                if btn.selectedTex then btn.selectedTex:Show() end
            else
                if btn.selectedTex then btn.selectedTex:Hide() end
            end

            -- Dark overlay for items on cooldown (GetContainerItemCooldown; reliable)
            if btn.cooldownOverlay then
                if L.ItemIdHasCooldown(capturedId, itemIdToSlot) then
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
                L.AnchorTooltipRight(self)
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
                                L.QueueDestroySlotsForItemId(capturedId)
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
                    elseif capturedCount > L.GPH_MAX_STACK then
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
                if IsControlKeyDown() and button == "LeftButton" and capturedId and L.GetGphProtectedSet then
                    local set = L.GetGphProtectedSet()
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
                    gphFrame.gphSelectedIndex = itemIdx
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
                    gphFrame.gphSelectedIndex = itemIdx
                    gphFrame.gphSelectedRowBtn = btn
                    gphFrame.gphSelectedItemLink = item.link
                    gphFrame.gphSelectedTime = time()
                    if gphFrame.gphRightClickUseOverlay then
                        local map = L.GetItemIdToBagSlot()
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
                gphFrame.gphSelectedIndex = itemIdx
                gphFrame.gphSelectedItemLink = item.link
                gphFrame.gphSelectedTime = time()
                gphFrame._refreshImmediate = true
                if gphFrame then gphFrame.gphLastRowActionTime = GetTime() end
                RefreshGPHUI()
            end)
            btn.clickArea:SetScript("OnEnter", function(self)
                if item.link then
                    L.AnchorTooltipRight(self)
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
                L.AddonPrint("[Fugazi] GPH row " .. tostring(itemIdx) .. " error: " .. tostring(rowErr))
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
            local map = L.GetItemIdToBagSlot and L.GetItemIdToBagSlot()
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
        spacer:SetSize(L.SCROLL_CONTENT_WIDTH or 296, fillerHeight)
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
            -- When opening GPH, default scroll so the first visible row is the divider line above hearthstone (saved items above require scrolling up).
            if gphFrame.gphScrollToDefaultOnNextRefresh then
                gphFrame.gphScrollToDefaultOnNextRefresh = nil
                if gphFrame.gphDefaultScrollY then
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
        scrollChild:SetWidth(L.SCROLL_CONTENT_WIDTH)
    end
    end)  -- pcall around refresh body
    if not refreshOk then
        L.AddonPrint("[Fugazi] GPH refresh error: " .. tostring(refreshErr))
    end
    -- Force collapse button level after refresh so it stays on top of close/sort
    if gphFrame.gphCollapseBtn then
        gphFrame.gphCollapseBtn:Show()
        gphFrame.gphCollapseBtn:SetFrameLevel(gphFrame:GetFrameLevel() + 50)
    end
end

--- Show or hide GPH window; now delegated to external bag addon when available.
local function ToggleGPHFrame()
    if _G.ToggleGPHFrame and _G.ToggleGPHFrame ~= ToggleGPHFrame then
        _G.ToggleGPHFrame()
    end
end
-- Do NOT assign _G.ToggleGPHFrame here; __FugaziBAGS owns the global now.

--- Builds the main tracker window: hourly cap, recent instances list, lockouts by expansion, and buttons (Ledger, GPH, etc.).
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
        L.SaveFrameLayout(f, "frameShown", "framePoint")
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

    -- Expose elements for skinning from shared skin definition.
    f.itTitleBar = titleBar
    f.itTitleText = title

    -- Close button: stay closed until user opens via /fit or minimap (no auto-show)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        L.SaveFrameLayout(f, "frameShown", "framePoint")
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
        if not statsFrame then statsFrame = L.CreateStatsFrame() end
        if statsFrame:IsShown() then
            L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
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
            L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
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
        L.AddonPrint(L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1) .. "Instances reset.")
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

    -- Expose for skinning
    f.itHourlyText = hourlyText
    f.itSep = sep

    local scrollFrame = CreateFrame("ScrollFrame", "InstanceTrackerScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(L.SCROLL_CONTENT_WIDTH)
    content:SetHeight(1)
    content:EnableMouse(true)
    scrollFrame:SetScrollChild(content)
    f.content = content
    f.scrollFrame = scrollFrame
    if _G.__FugaziBAGS_Skins and _G.__FugaziBAGS_Skins.SkinScrollBar then
        _G.__FugaziBAGS_Skins.SkinScrollBar(scrollFrame)
    end

    -- Allow external skin updates (called from __FugaziBAGS ApplyTestSkin).
    -- When the bags skin changes, reskin main + ledger + item detail together.
    f.ApplySkin = function()
        L.ApplyInstanceTrackerSkin(f)
        if _G.InstanceTrackerStatsFrame then
            L.ApplyInstanceTrackerSkin(_G.InstanceTrackerStatsFrame)
        end
        if _G.InstanceTrackerLedgerDetailFrame then
            L.ApplyInstanceTrackerSkin(_G.InstanceTrackerLedgerDetailFrame)
        end
        if _G.InstanceTrackerItemDetailFrame then
            L.ApplyInstanceTrackerSkin(_G.InstanceTrackerItemDetailFrame)
        end
    end
    -- Apply initial skin if __FugaziBAGS is loaded.
    L.ApplyInstanceTrackerSkin(f)

    return f
end

--- Redraws the main window: hourly cap text, recent instances rows, and (if not collapsed) lockout list. Uses pooled rows.
--- Single-line rows with truncation + mouseover (same rules as Ledger). Flush left padding (4). Main scrollbar skinned like others.
RefreshUI = function(forceRebuild)
    if not frame then return end
    if not forceRebuild and not frame:IsShown() then return end
    L.PurgeOld()
    ResetPools()

    local now = time()
    local recent = InstanceTrackerDB.recentInstances or {}
    local count = #recent
    local remaining = L.MAX_INSTANCES_PER_HOUR - count
    local content = frame.content
    local pad = 4

    content._mainHoverFrames = content._mainHoverFrames or {}
    for _, hf in ipairs(content._mainHoverFrames) do if hf then hf:Hide() end end
    local mainHoverIdx = 0
    local function AddMainRowHover(rowY, rowH, fullPlainText)
        mainHoverIdx = mainHoverIdx + 1
        local hf = content._mainHoverFrames[mainHoverIdx]
        if not hf then
            hf = CreateFrame("Frame", nil, content)
            hf:EnableMouse(true)
            hf:SetScript("OnEnter", function(self)
                if self._fullText then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(self._fullText, 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            hf:SetScript("OnLeave", function() GameTooltip:Hide() end)
            content._mainHoverFrames[mainHoverIdx] = hf
        end
        hf._fullText = fullPlainText
        hf:ClearAllPoints()
        hf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -rowY)
        hf:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", L.SCROLL_CONTENT_WIDTH - pad, -(rowY + rowH))
        hf:Show()
    end

    local fontSettings = L.GetFugaziFontSettings()
    local hdrSpacing = (fontSettings.headerSize or 11) + 6
    local rowSpacing = L.GetFugaziRowHeight(16)
    local rowFont = fontSettings.rowFontPath or fontSettings.fontPath
    local mainMaxChars = 36

    local countColor
    if remaining <= 0 then countColor = "|cffff4444"
    elseif remaining <= 2 then countColor = "|cffff8800"
    else countColor = "|cff44ff44" end

    local nextSlot = ""
    if count >= L.MAX_INSTANCES_PER_HOUR and recent[1] then
        nextSlot = "  |cffcccccc(next slot in " .. L.FormatTime(recent[1].time + L.HOUR_SECONDS - now) .. ")|r"
    end
    frame.hourlyText:SetFont(rowFont, fontSettings.rowSize, "")
    frame.hourlyText:SetText(
        L.ColorizeFugaziRowLabel("Hourly Cap:") .. "  "
        .. countColor .. count .. "/" .. L.MAX_INSTANCES_PER_HOUR .. "|r"
        .. "  " .. countColor .. "(" .. remaining .. " left)|r"
        .. nextSlot
    )

    local yOff = 0
    local header1 = GetText(content)
    header1:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
    header1:SetText("--- Recent Instances ---")
    L.StyleFugaziHeader(header1)
    yOff = yOff + hdrSpacing

    if #recent == 0 then
        local none = GetText(content)
        none:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
        none:SetText("|cff888888No recent instances.|r")
        yOff = yOff + rowSpacing
    else
        for i, entry in ipairs(recent) do
            local timeLeft = L.HOUR_SECONDS - (now - entry.time)
            local row = GetRow(content, true)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
            local idx = i
            row.deleteBtn:SetScript("OnClick", function() L.RemoveInstance(idx); RefreshUI() end)
            local leftText = "|cff666666" .. i .. ".|r  |cffffffcc" .. (entry.name or "Unknown") .. "|r"
            row.left:SetWidth(L.SCROLL_CONTENT_WIDTH - 75)
            row.left:SetWordWrap(false)
            local plain = L.StripColorCodes(leftText)
            if #plain > mainMaxChars then
                row.left:SetText(plain:sub(1, mainMaxChars - 3) .. "...")
                AddMainRowHover(yOff, rowSpacing, plain)
            else
                row.left:SetText(leftText)
            end
            row.right:SetText(timeLeft > 0 and ("|cffff8844" .. L.FormatTime(timeLeft) .. "|r") or "|cff44ff44Expired|r")
            yOff = yOff + rowSpacing
        end
    end

    yOff = yOff + 10

    if InstanceTrackerDB.lockoutsCollapsed then
        L.CollapseInPlace(frame, 150, function() return false end)
        content:SetHeight(1)
        return
    end

    local header2 = GetText(content)
    header2:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
    header2:SetText("--- Saved Lockouts ---")
    L.StyleFugaziHeader(header2)
    yOff = yOff + hdrSpacing

    -- Periodically refresh our local lockout snapshot, but avoid spamming RequestRaidInfo here.
    -- The actual server query is throttled separately in OnUpdate (raidinfo_acc) and on login.
    if time() - lockoutQueryTime > 5 then
        UpdateLockoutCache()
    end
    local buckets = { classic = {}, tbc = {}, wotlk = {}, unknown = {} }
    for _, info in ipairs(lockoutCache) do
        local exp = L.GetExpansion(info.name)
        if exp then
            table.insert(buckets[exp], info)
        else
            table.insert(buckets.unknown, info)
        end
    end

    local lockoutRowH = L.GetFugaziRowHeight(16)
    for _, exp in ipairs(L.EXPANSION_ORDER) do
        local bucket = buckets[exp]
        if #bucket > 0 then
            local expH = GetText(content)
            expH:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
            expH:SetText(EXPANSION_LABELS[exp])
            L.StyleFugaziHeader(expH)
            yOff = yOff + hdrSpacing

            table.sort(bucket, function(a, b) return a.name < b.name end)
            for _, info in ipairs(bucket) do
                local row = GetRow(content, false)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
                row:SetHeight(lockoutRowH)

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
                local leftText = lockColor .. info.name .. "|r" .. diffTag
                local statusText
                if not info.locked then
                    statusText = "|cff44ff44Available|r"
                else
                    local current_reset = info.resetAtQuery - (now - lockoutQueryTime)
                    if current_reset > 0 then
                        statusText = "|cffff8844" .. L.FormatTime(current_reset) .. "|r"
                    else
                        statusText = "|cff44ff44Available|r"
                    end
                end

                row.left:SetWidth(L.SCROLL_CONTENT_WIDTH - 80)
                row.left:SetWordWrap(false)
                row.right:SetJustifyH("RIGHT")
                row.right:SetFont(rowFont, fontSettings.rowSize, "")
                row.right:SetText(statusText)
                local plain = L.StripColorCodes(leftText)
                if #plain > mainMaxChars then
                    row.left:SetText(plain:sub(1, mainMaxChars - 3) .. "...")
                    AddMainRowHover(yOff, lockoutRowH, plain)
                else
                    row.left:SetText(leftText)
                end
                yOff = yOff + lockoutRowH
            end
            yOff = yOff + 8
        end
    end
    if buckets.unknown and #buckets.unknown > 0 then
        local expH = GetText(content)
        expH:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
        expH:SetText("|cff999999Other|r")
        yOff = yOff + hdrSpacing
        for _, info in ipairs(buckets.unknown) do
            local row = GetRow(content, false)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -yOff)
            row:SetHeight(lockoutRowH)

            row.left:SetWidth(L.SCROLL_CONTENT_WIDTH - 80)
            row.left:SetWordWrap(false)
            local leftText = "|cffff4444" .. info.name .. "|r"
            local statusText
            if not info.locked then
                statusText = "|cff44ff44Available|r"
            else
                local current_reset = info.resetAtQuery - (now - lockoutQueryTime)
                if current_reset > 0 then
                    statusText = "|cffff8844" .. L.FormatTime(current_reset) .. "|r"
                else
                    statusText = "|cff44ff44Available|r"
                end
            end
            row.right:SetJustifyH("RIGHT")
            row.right:SetFont(rowFont, fontSettings.rowSize, "")
            row.right:SetText(statusText)
            local plain = L.StripColorCodes(leftText)
            if #plain > mainMaxChars then
                row.left:SetText(plain:sub(1, mainMaxChars - 3) .. "...")
                AddMainRowHover(yOff, lockoutRowH, plain)
            else
                row.left:SetText(leftText)
            end
            yOff = yOff + lockoutRowH
        end
        yOff = yOff + 8
    end
    yOff = yOff + 8
    content:SetHeight(yOff)
    frame:SetHeight(frame.EXPANDED_HEIGHT)
end

----------------------------------------------------------------------
-- Periodic update: runs every frame on the main window. Every 1s we refresh
-- the lockout list and item detail (if open); every 30s we re-query raid info.
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
-- ElvUI: when "Inv" (bag key opens GPH) is on, block bags opening at bank
-- Load order does not matter: we hook after ElvUI has loaded (PLAYER_LOGIN).
----------------------------------------------------------------------
local elvUIBankBagsHooked = false
local function TryHookElvUIBankBags()
    if elvUIBankBagsHooked then return end
    local ElvUI = _G.ElvUI
    if not ElvUI or type(ElvUI) ~= "table" then return end
    local E = ElvUI[1]
    if not E or type(E.GetModule) ~= "function" then return end
    local B = E:GetModule("Bags", true)
    if not B or type(B.OpenBank) ~= "function" then return end
    local origOpenBank = B.OpenBank
    B.OpenBank = function(self)
        origOpenBank(self)
        if InstanceTrackerDB.gphInvKeybind and B.BagFrame and B.BagFrame.Hide and B.BagFrame:IsShown() then
            B.BagFrame:Hide()
        end
    end
    elvUIBankBagsHooked = true
end

----------------------------------------------------------------------
-- Event handling: the game tells us when things happen (login, zone change,
-- bag update, etc.). We react by updating state and refreshing the UI.
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_MONEY")
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
        if not InstanceTrackerDB.accountGold then InstanceTrackerDB.accountGold = {} end
        if not InstanceTrackerDB.lifetimeGoldGained then InstanceTrackerDB.lifetimeGoldGained = {} end
        if not InstanceTrackerDB.lastKnownMoney then InstanceTrackerDB.lastKnownMoney = {} end
        if not InstanceTrackerDB.lifetimeDeaths then InstanceTrackerDB.lifetimeDeaths = {} end
        local key = L.GetGphCharKey()
        InstanceTrackerDB.accountGold[key] = GetMoney()
        InstanceTrackerDB.lastKnownMoney[key] = GetMoney()
        L.PurgeOld()
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
            -- Do not re-snapshot bags on reload: that would replace "bags at enter" with "bags now" and make every item show as vendored in the items window.
        end
        
        -- GPH session/vendor/destroy live in __FugaziBAGS; no session restore here.

        -- Default layout on reload: lockouts/stats collapsed, GPH expanded so item list is visible
        InstanceTrackerDB.lockoutsCollapsed = true
        InstanceTrackerDB.statsCollapsed = true
        InstanceTrackerDB.gphCollapsed = false
        frame = CreateMainFrame()
        frame:SetScript("OnHide", function() frame:SetScript("OnUpdate", nil) end)
        frame:SetScript("OnShow", function() frame:SetScript("OnUpdate", OnUpdate) end)
        L.RestoreFrameLayout(frame, "frameShown", "framePoint")
        if not (InstanceTrackerDB.framePoint and InstanceTrackerDB.framePoint.point) then
            frame:ClearAllPoints()
            frame:SetPoint("TOP", UIParent, "CENTER", 0, 200)
        end
        if frame:IsShown() then frame:SetScript("OnUpdate", OnUpdate) end
        RequestRaidInfo()
        if frame:IsShown() then RefreshUI() end
        InstanceTrackerDB.gphDockedToMain = false
        -- GPH/inventory window is owned by __FugaziBAGS; do not create or restore gphFrame here.
        if InstanceTrackerDB.gphInvKeybind then L.InstallGPHInvHook() end
        TryHookElvUIBankBags()
        if InstanceTrackerDB.statsShown then
            if not statsFrame then statsFrame = L.CreateStatsFrame() end
            statsFrame:ClearAllPoints()
            statsFrame:SetWidth(frame:GetWidth())
            statsFrame:SetHeight(frame:GetHeight())
            statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            statsFrame:Show()
            RefreshStatsUI()
        end
        L.AddonPrint(
            L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Loaded. Type " .. L.ColorText("/fit help", 1, 1, 0.6) .. " for all commands."
        )

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local inInstance, instanceType = IsInInstance()
        local zoneName = GetInstanceInfo and select(1, GetInstanceInfo()) or GetRealZoneText()
        if inInstance and (instanceType == "party" or instanceType == "raid") then
            if not isInInstance or currentZone ~= zoneName then
                if currentRun and currentRun.name ~= zoneName then FinalizeRun() end
                isInInstance = true
                currentZone = zoneName
                L.RecordInstance(zoneName)
                RequestRaidInfo()
                if not currentRun or currentRun.name ~= zoneName then
                    RestoreRunFromHistory(zoneName)
                end
                if not currentRun or currentRun.name ~= zoneName then StartRun(zoneName) end
                -- Switch Ledger to Dungeons tab when entering a dungeon
                if statsFrame and statsFrame:IsShown() and statsFrame.UpdateStatsTabs and currentRun then
                    statsFrame.selectedTab = 3
                    statsFrame:UpdateStatsTabs()
                end
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
        -- Items destroyed: client typically doesn't print a system message, so we don't parse chat for it
        if msg:find("too many instances") then
            L.AddonPrint(
                L.ColorText("[InstanceTracker] ", 0.4, 0.8, 1)
                .. L.ColorText("WARNING: ", 1, 0.2, 0.2) .. "You've hit the hourly instance cap!"
            )
            if not InstanceTrackerDB.mainFrameUserClosed and frame and not frame:IsShown() then frame:Show(); L.SaveFrameLayout(frame, "frameShown", "framePoint"); RefreshUI() end
        elseif lastExitedZoneName and lower:find("has been reset") then
            -- Instance/dungeon reset: keep the run in history (so it stays in the list) but don't restore it on re-enter.
            lastResetZoneName = lastExitedZoneName
            lastExitedZoneName = nil
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        UpdateLockoutCache(); RefreshUI()

    elseif event == "PLAYER_MONEY" then
        local key = L.GetGphCharKey()
        local now = GetMoney()
        if InstanceTrackerDB.accountGold then
            InstanceTrackerDB.accountGold[key] = now
        end
        -- Lifetime gold gained: any increase in gold counts as "gained"
        if InstanceTrackerDB.lifetimeGoldGained and key then
            local last = InstanceTrackerDB.lastKnownMoney[key]
            if last and now > last then
                InstanceTrackerDB.lifetimeGoldGained[key] = (InstanceTrackerDB.lifetimeGoldGained[key] or 0) + (now - last)
            end
            InstanceTrackerDB.lastKnownMoney[key] = now
        end
    elseif event == "MERCHANT_SHOW" or event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then
        L.gphNpcDialogTime = GetTime()
        if event == "MERCHANT_SHOW" then
            L.merchantGoldAtOpen = GetMoney()
            L.merchantRepairCostAtOpen = (GetRepairAllCost and select(1, GetRepairAllCost())) or 0
        end
    elseif event == "MERCHANT_CLOSED" then
        if InstanceTrackerDB.lifetimeStats then
            local LS = InstanceTrackerDB.lifetimeStats
            -- Keep alias in sync just in case something reassigned L.LS earlier.
            L.LS = LS

            local nowGold = GetMoney()
            if L.merchantGoldAtOpen then
                local delta = nowGold - L.merchantGoldAtOpen
                if delta > 0 then
                    LS.vendorCopper = (LS.vendorCopper or 0) + delta
                    LS.vendorItemCount = (LS.vendorItemCount or 0) + 1
                    -- Per-run vendor gold (instance runs only for now; GPH sessions are handled separately in BAGS)
                    if currentRun then
                        currentRun.vendorGold = (currentRun.vendorGold or 0) + delta
                    end
                end
                L.merchantGoldAtOpen = nil
            end

            -- Repair: detect via GetRepairAllCost (like EbonholdStuff) so we count repair even when player also sold
            local repairCostNow = (GetRepairAllCost and select(1, GetRepairAllCost())) or 0
            local repairSpent = (L.merchantRepairCostAtOpen or 0) - repairCostNow
            if repairSpent > 0 then
                LS.repairCopper = (LS.repairCopper or 0) + repairSpent
                LS.repairCount = (LS.repairCount or 0) + 1
                if currentRun then
                    currentRun.repairCopper = (currentRun.repairCopper or 0) + repairSpent
                    currentRun.repairCount = (currentRun.repairCount or 0) + 1
                end
                -- Live-refresh lifetime + run details so repairs show up immediately.
                if statsFrame and statsFrame:IsShown() and type(RefreshStatsUI) == "function" then
                    RefreshStatsUI()
                end
                if ledgerDetailFrame and ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then
                    L.RefreshLedgerDetailUI()
                end
            end
            L.merchantRepairCostAtOpen = nil
        end
        L.gphNpcDialogTime = nil
    elseif event == "PLAYER_DEAD" then
        local key = L.GetGphCharKey()
        if InstanceTrackerDB.lifetimeDeaths then
            InstanceTrackerDB.lifetimeDeaths[key] = (InstanceTrackerDB.lifetimeDeaths[key] or 0) + 1
        end
        if currentRun then
            currentRun.deaths = (currentRun.deaths or 0) + 1
        end
        if InstanceTrackerDB.lifetimeStats and (currentRun or (IsInInstance and IsInInstance())) then
            local LS = InstanceTrackerDB.lifetimeStats
            L.LS = LS
            LS.instanceDeaths = (LS.instanceDeaths or 0) + 1
        end
        -- Live-refresh lifetime + run details so deaths show up immediately.
        if statsFrame and statsFrame:IsShown() and type(RefreshStatsUI) == "function" then
            RefreshStatsUI()
        end
        if ledgerDetailFrame and ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then
            L.RefreshLedgerDetailUI()
        end
    elseif event == "BAG_UPDATE" then
        if currentRun then DiffBags() end
        -- GPH window, destroy list, and vendor/summon live in __FugaziBAGS only.
    end
end)
----------------------------------------------------------------------
-- Slash commands: /fit, /fugazi, /gph. Type /fit help in chat for the full list
-- (toggle windows, mute, reset hour, stats/Ledger, skin, etc.).
----------------------------------------------------------------------
SLASH_INSTANCETRACKER1 = "/fit"
SLASH_INSTANCETRACKER2 = "/fugazi"
SLASH_FUGAZIGPH1 = "/gph"
SLASH_INSTANCETRACKER_LEDGER1 = "/ledger"
SlashCmdList["INSTANCETRACKER_LEDGER"] = function()
    if not frame then
        frame = CreateMainFrame()
        frame:SetScript("OnHide", function() frame:SetScript("OnUpdate", nil) end)
        frame:SetScript("OnShow", function() frame:SetScript("OnUpdate", OnUpdate) end)
    end
    if not frame:IsShown() then frame:Show(); L.SaveFrameLayout(frame, "frameShown", "framePoint") end
    if not statsFrame then statsFrame = L.CreateStatsFrame() end
    statsFrame:ClearAllPoints()
    statsFrame:SetWidth(frame:GetWidth())
    statsFrame:SetHeight(frame:GetHeight())
    statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
    if not statsFrame:IsShown() then
        InstanceTrackerDB.statsCollapsed = InstanceTrackerDB.lockoutsCollapsed
        if statsFrame.UpdateStatsCollapse then statsFrame.UpdateStatsCollapse() end
        statsFrame:Show()
        L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
        RefreshStatsUI()
    end
end
SlashCmdList["FUGAZIGPH"] = function()
    if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
end
SlashCmdList["INSTANCETRACKER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local cmd = msg:match("^([%w]+)") or ""

    if cmd == "help" or msg == "help" then
        L.AddonPrint(L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Commands:")
        L.AddonPrint("  |cffaaddff/fit|r              Toggle main window (no args)")
        L.AddonPrint("  |cffaaddff/fit help|r        Show this list")
        L.AddonPrint("  |cffaaddff/fit mute|r        Mute all addon chat output")
        L.AddonPrint("  |cffaaddff/fit reset|r       Clear recent instance history (this hour)")
        L.AddonPrint("  |cffaaddff/fit status|r      Show instances used this hour in chat")
        L.AddonPrint("  |cffaaddff/fit stats|r       Toggle Run Stats (Ledger) window")
        L.AddonPrint("  |cffaaddff/ledger|r          Open Ledger directly")
        L.AddonPrint("  |cffaaddff/fit gph|r or |cffaaddff/fit inv|r or |cffaaddff/gph|r  Toggle Gold Per Hour window")
        L.AddonPrint("  (Bind your bag key to |cffffcc00/fit gph|r or |cffffcc00/gph|r when Inv is on)")
        L.AddonPrint("  |cffaaddff/fit vp|r  Show that autosell/summon are in __FugaziBAGS")
        L.AddonPrint("  |cffaaddff/fit options|r  Open options (valuation, etc.; right-click minimap)")
        return
    end

    if cmd == "mute" then
        InstanceTrackerDB.fitMute = not InstanceTrackerDB.fitMute
        -- Always show mute state (can't mute the mute confirmation)
        DEFAULT_CHAT_FRAME:AddMessage(
            L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Chat output " .. (InstanceTrackerDB.fitMute and "|cffff4444muted|r." or "|cff44ff44unmuted|r.")
        )
        return
    end

    if cmd == "skin" then
        if _G.FugaziBAGSDB and _G.__FugaziBAGS_Skins then
            print("|cff00aaff[FIT]|r Skin is controlled by __FugaziBAGS. Change it in the BAGS options.")
        else
            print("|cff00aaff[FIT]|r Instance Tracker uses the default look when run without __FugaziBAGS.")
        end
        return
    end

    if cmd == "options" or cmd == "opts" or cmd == "skins" then
        if _G.ShowFITSkinPopup then
            _G.ShowFITSkinPopup()
        else
            print("|cff00aaff[FIT]|r Not ready. Right-click minimap icon or /reload.")
        end
        return
    end

    if cmd == "vendorprotect" or cmd == "vp" then
        L.AddonPrint(L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Autosell and Summon Greedy are controlled by |cffaaffaa__FugaziBAGS|r (inventory window toggles).")
        return
    end

    if cmd == "reset" then
        InstanceTrackerDB.recentInstances = {}
        L.AddonPrint(L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1) .. "Recent instance history cleared.")
        RefreshUI()
        return
    end

    if cmd == "status" then
        L.PurgeOld()
        local c = #(InstanceTrackerDB.recentInstances or {})
        L.AddonPrint(
            L.ColorText("[Fugazi Instance Tracker] ", 0.4, 0.8, 1)
            .. "Instances this hour: " .. L.ColorText(c .. "/" .. L.MAX_INSTANCES_PER_HOUR, 1, 0.8, 0.2)
            .. " (" .. L.ColorText((L.MAX_INSTANCES_PER_HOUR - c) .. " remaining", 0.4, 1, 0.4) .. ")"
        )
        return
    end

    if cmd == "stats" then
        if _G.InstanceTrackerStatsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
        if not statsFrame then statsFrame = L.CreateStatsFrame() end
        if statsFrame:IsShown() then
            L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            statsFrame:Hide()
        else
            if frame and frame:IsShown() then
                statsFrame:ClearAllPoints()
                statsFrame:SetWidth(frame:GetWidth())
                statsFrame:SetHeight(frame:GetHeight())
                statsFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
            end
            statsFrame:Show()
            L.SaveFrameLayout(statsFrame, "statsShown", "statsPoint")
            RefreshStatsUI()
        end
        return
    end

    if cmd == "gph" or cmd == "inv" then
        if _G.ToggleGPHFrame then _G.ToggleGPHFrame() end
        return
    end

    -- No subcommand or unknown: toggle main window
    if not frame then
        frame = CreateMainFrame()
        frame:SetScript("OnHide", function() frame:SetScript("OnUpdate", nil) end)
        frame:SetScript("OnShow", function() frame:SetScript("OnUpdate", OnUpdate) end)
    end
    if frame:IsShown() then
        frame:Hide()
        L.SaveFrameLayout(frame, "frameShown", "framePoint")
        InstanceTrackerDB.mainFrameUserClosed = true
    else
        InstanceTrackerDB.mainFrameUserClosed = false
        RequestRaidInfo()
        frame:Show()
        L.SaveFrameLayout(frame, "frameShown", "framePoint")
        RefreshUI()
    end
end

----------------------------------------------------------------------
-- Apply current skin (BAGS or default) to all FIT frames. FIT does not set skin; BAGS directs when loaded.
----------------------------------------------------------------------
local function ApplyFITSkinToAllFrames()
    -- Delegate visual styling to L.ApplyInstanceTrackerSkin; force-rebuild all content so every FIT window uses current BAGS font/skin.
    local n = 0
    if _G.InstanceTrackerFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerFrame)
        n = n + 1
        if type(RefreshUI) == "function" then RefreshUI(true) end
    end
    if _G.InstanceTrackerStatsFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerStatsFrame)
        n = n + 1
        if type(RefreshStatsUI) == "function" then RefreshStatsUI(true) end
    end
    if _G.InstanceTrackerLedgerDetailFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerLedgerDetailFrame)
        if type(L.RefreshLedgerDetailUI) == "function" then L.RefreshLedgerDetailUI(true) end
    end
    if _G.InstanceTrackerItemDetailFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerItemDetailFrame)
        n = n + 1
        if _G.InstanceTrackerItemDetailFrame.RefreshItemDetailList then _G.InstanceTrackerItemDetailFrame:RefreshItemDetailList() end
    end
    if n > 0 and type(RefreshUI) == "function" then RefreshUI(true) end
end
_G.ApplyFITSkinToAllFrames = ApplyFITSkinToAllFrames

--- Called by FugaziBAGS when header/row customisation, frame opacity, skin, etc. change. FIT rebuilds all content with current BAGS font/skin so every window matches.
_G.FugaziInstanceTracker_RefreshSkinFromBAGS = function()
    -- Use latest BAGS DB values (no stale font cache).
    L._fontSettingsCacheKey = nil
    -- Sync local frame refs from globals so RefreshUI/RefreshStatsUI/RefreshLedgerDetailUI see the right frames (locals can be nil until first open).
    if _G.InstanceTrackerFrame then frame = _G.InstanceTrackerFrame end
    if _G.InstanceTrackerStatsFrame then statsFrame = _G.InstanceTrackerStatsFrame end
    if _G.InstanceTrackerLedgerDetailFrame then ledgerDetailFrame = _G.InstanceTrackerLedgerDetailFrame end

    if _G.InstanceTrackerFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerFrame)
        if type(RefreshUI) == "function" then RefreshUI(true) end
    end
    if _G.InstanceTrackerStatsFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerStatsFrame)
        if type(RefreshStatsUI) == "function" then RefreshStatsUI(true) end
    end
    if _G.InstanceTrackerLedgerDetailFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerLedgerDetailFrame)
        if type(L.RefreshLedgerDetailUI) == "function" then L.RefreshLedgerDetailUI(true) end
    end
    if _G.InstanceTrackerItemDetailFrame then
        L.ApplyInstanceTrackerSkin(_G.InstanceTrackerItemDetailFrame)
        if _G.InstanceTrackerItemDetailFrame.RefreshItemDetailList then _G.InstanceTrackerItemDetailFrame:RefreshItemDetailList() end
    end
end

----------------------------------------------------------------------
-- Standalone skin popup (right-click minimap). Avoids broken Escape menu.
----------------------------------------------------------------------
local fitSkinPopup
function L.CreateFITSkinPopup()
    if fitSkinPopup then return fitSkinPopup end
    local f = CreateFrame("Frame", "FITSkinPopup", UIParent)
    f:SetWidth(220)
    f:SetHeight(120)
    f:SetPoint("CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("FIT Options")

    local valuationCb = CreateFrame("CheckButton", nil, f, "OptionsBaseCheckButtonTemplate")
    valuationCb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    valuationCb:SetScript("OnClick", function(self)
        InstanceTrackerDB.valuationMode = self:GetChecked() and "auction" or "vendor"
        if type(RefreshUI) == "function" then RefreshUI() end
        if statsFrame and statsFrame:IsShown() and type(RefreshStatsUI) == "function" then RefreshStatsUI() end
        if ledgerDetailFrame and ledgerDetailFrame:IsShown() and type(L.RefreshLedgerDetailUI) == "function" then L.RefreshLedgerDetailUI() end
    end)
    valuationCb:SetChecked(InstanceTrackerDB.valuationMode == "auction")
    valuationCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Use auction value", 0.6, 0.85, 0.6)
        GameTooltip:AddLine("When checked, new runs store item value using auction estimates when available.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("When unchecked, new runs store only vendor sell value for items. Past runs are not changed.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    valuationCb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cbText = valuationCb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cbText:SetPoint("LEFT", valuationCb, "RIGHT", 4, 1)
    cbText:SetText("Use auction value")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 4)
    close:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    fitSkinPopup = f
    return f
end

function L.ShowFITSkinPopup()
    L.CreateFITSkinPopup():Show()
end
_G.ShowFITSkinPopup = L.ShowFITSkinPopup

function L.CreateInstanceTrackerOptionsPanel()
        if _G.FugaziInstanceTrackerOptionsPanel then return end
    -- Parent to InterfaceOptionsFrame so panel lives inside options UI and buttons receive clicks (WotLK).
    local parent = _G.InterfaceOptionsFrame and _G.InterfaceOptionsFrame or UIParent
    local panel = CreateFrame("Frame", "FugaziInstanceTrackerOptionsPanel", parent)
    -- Standalone mode (no __FugaziBAGS): simple options panel just for valuation mode.
    -- Show up in Interface → AddOns as "_Fugazi Instance Tracker".
    panel.name = "_Fugazi Instance Tracker"
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end
    panel.refresh = function() end
    -- Give panel a size so scroll frame in Interface Options shows our content (WotLK).
    panel:SetWidth(400)
    panel:SetHeight(280)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Fugazi Instance Tracker")

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    sub:SetText("Run details show both vendor and auction-style values when available.")

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

eventFrame:HookScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        L.CreateInstanceTrackerOptionsPanel()
    end
end)
end)()
