----------------------------------------------------------------------
-- __FugaziBAGS skins: definitions and apply functions for GPH + bank.
-- Loaded before FugaziBAGS.lua. Exposes __FugaziBAGS_Skins to global.
----------------------------------------------------------------------

local SKIN = {
    original = {
        mainBackdrop = {
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 24,
            insets   = { left = 2, right = 6, top = 6, bottom = 6 },
        },
        mainBg = { 0.08, 0.08, 0.12, 0.92 },
        mainBorder = { 0.6, 0.5, 0.2, 0.8 },
        titleBackdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 0.35, 0.28, 0.1, 0.7 },
        btnNormal = { 0.1, 0.3, 0.15, 0.7 },
        titleTextColor = { 1, 0.85, 0.4, 1 },
        searchBtnBg = { 0.1, 0.3, 0.15, 0.7 },
        searchBtnHover = { 0.15, 0.4, 0.2, 0.8 },
        scaleBtnDim = { 0.1, 0.3, 0.15, 0.7 },
        scaleBtnBright = { 0.15, 0.4, 0.2, 0.8 },
        collapseBtnDim = { 0.1, 0.3, 0.15, 0.7 },
        collapseBtnBright = { 0.15, 0.4, 0.2, 0.8 },
        statusTextColor = { 1, 0.85, 0.4, 1 },
        bottomBarBg = { 0.08, 0.06, 0.04, 0.9 },
        bottomBarBorder = { 0.6, 0.5, 0.2, 0.6 },
        bottomBarTextColor = { 1, 0.85, 0.4, 1 },
        sepColor = { 1, 1, 1, 0.15 },
        bagSpaceGlow = { 1, 0.85, 0.2, 0.5 },
    },
    elvui = {
        mainBackdrop = {
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            tile     = true, tileSize = 16, edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        },
        mainBg = { 0.1, 0.1, 0.1, 0.92 },
        mainBorder = { 0.2, 0.2, 0.2, 1 },
        titleBackdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 0.157, 0.239, 0.239, 0.95 },
        -- Ebonhold-style: teal/green buttons (not shared with ElvUI grey).
        btnNormal = { 0.1, 0.3, 0.15, 0.7 },
        titleTextColor = { 0.6, 0.85, 0.85, 1 },
        searchBtnBg = { 0.1, 0.3, 0.15, 0.7 },
        searchBtnHover = { 0.15, 0.4, 0.2, 0.8 },
        scaleBtnDim = { 0.1, 0.3, 0.15, 0.7 },
        scaleBtnBright = { 0.15, 0.4, 0.2, 0.8 },
        collapseBtnDim = { 0.1, 0.3, 0.15, 0.7 },
        collapseBtnBright = { 0.15, 0.4, 0.2, 0.8 },
        statusTextColor = { 0.6, 0.85, 0.85, 1 },
        bottomBarBg = { 0.08, 0.1, 0.12, 0.95 },
        bottomBarBorder = { 0.18, 0.31, 0.31, 0.6 },
        bottomBarTextColor = { 0.6, 0.85, 0.85, 1 },
        sepColor = { 0.18, 0.31, 0.31, 0.4 },
        bagSpaceGlow = { 0.2, 0.5, 0.5, 0.5 },
    },
    elvui_real = {
        mainBackdrop = {
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            tile     = true, tileSize = 16, edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        },
        mainBg = { 0.04, 0.04, 0.04, 0.98 },
        mainBorder = { 0.10, 0.10, 0.10, 1 },
        titleBackdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 0.08, 0.08, 0.08, 0.98 },
        btnNormal = { 0.18, 0.18, 0.18, 0.9 },
        titleTextColor = { 0.9, 0.9, 0.9, 1 },
        searchBtnBg = { 0.18, 0.18, 0.18, 0.9 },
        searchBtnHover = { 0.26, 0.26, 0.26, 0.95 },
        scaleBtnDim = { 0.18, 0.18, 0.18, 0.9 },
        scaleBtnBright = { 0.30, 0.30, 0.30, 0.95 },
        collapseBtnDim = { 0.18, 0.18, 0.18, 0.9 },
        collapseBtnBright = { 0.30, 0.30, 0.30, 0.95 },
        statusTextColor = { 0.8, 0.8, 0.8, 1 },
        bottomBarBg = { 0.03, 0.03, 0.03, 0.98 },
        bottomBarBorder = { 0.10, 0.10, 0.10, 1 },
        bottomBarTextColor = { 0.8, 0.8, 0.8, 1 },
        sepColor = { 0.25, 0.25, 0.25, 0.5 },
        bagSpaceGlow = { 0.5, 0.5, 0.5, 0.5 },
    },
    pimp_purple = {
        mainBackdrop = {
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            tile     = true, tileSize = 16, edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        },
        mainBg = { 0.30, 0.00, 0.50, 0.58 },
        mainBorder = { 0.75, 0.40, 0.95, 1 },
        titleBackdrop = { bgFile = "Interface\\AddOns\\__FugaziBAGS\\media\\Leopard", edgeFile = nil, tile = true, tileSize = 256, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 1, 1, 1, 0.72 },
        btnNormal = { 0.65, 0.45, 0.15, 0.95 },
        titleTextColor = { 1.0, 0.90, 1.0, 1 },
        searchBtnBg = { 0.40, 0.12, 0.60, 0.92 },
        searchBtnHover = { 0.52, 0.20, 0.78, 0.96 },
        scaleBtnDim = { 0.65, 0.45, 0.15, 0.95 },
        scaleBtnBright = { 0.78, 0.58, 0.22, 1 },
        collapseBtnDim = { 0.65, 0.45, 0.15, 0.95 },
        collapseBtnBright = { 0.78, 0.58, 0.22, 1 },
        btnHoverGold = { 0.78, 0.58, 0.22, 1 },
        statusTextColor = { 0.95, 0.85, 1.0, 1 },
        bottomBarBg = { 0.36, 0.26, 0.11, 0.85 },
        bottomBarBorder = { 0.62, 0.45, 0.20, 1 },
        bottomBarTextColor = { 1.0, 0.90, 0.9, 1 },
        sepColor = { 0.70, 0.50, 0.90, 0.5 },
        bagSpaceGlow = { 0.85, 0.50, 0.95, 0.6 },
    },
    -- "FUGAZI" skin: based on elvui_real plus your current overrides from gphSkinOverrides.
    fugazi = {
        mainBackdrop = {
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            tile     = true, tileSize = 16, edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        },
        -- From your gphSkinOverrides.mainBg
        mainBg = { 0.1333, 0.0510, 0.0039, 0.98 },
        mainBorder = { 0.10, 0.10, 0.10, 1 },
        -- Header: washed, scruffy look – custom Leopard texture tinted dark so it’s unique, not flat ElvUI
        titleBackdrop = { bgFile = "Interface\\AddOns\\__FugaziBAGS\\media\\Suede", edgeFile = nil, tile = true, tileSize = 128, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 0.14, 0.11, 0.09, 0.88 },
        btnNormal = { 0.18, 0.18, 0.18, 0.9 },
        -- Use your warm header text colour from gphSkinOverrides.headerTextColor
        titleTextColor = { 1.0, 0.81, 0.58, 1 },
        searchBtnBg = { 0.18, 0.18, 0.18, 0.9 },
        searchBtnHover = { 0.26, 0.26, 0.26, 0.95 },
        scaleBtnDim = { 0.18, 0.18, 0.18, 0.9 },
        scaleBtnBright = { 0.30, 0.30, 0.30, 0.95 },
        collapseBtnDim = { 0.18, 0.18, 0.18, 0.9 },
        collapseBtnBright = { 0.30, 0.30, 0.30, 0.95 },
        statusTextColor = { 1.0, 0.81, 0.58, 1 },
        bottomBarBg = { 0.03, 0.03, 0.03, 0.98 },
        bottomBarBorder = { 0.10, 0.10, 0.10, 1 },
        bottomBarTextColor = { 1.0, 0.81, 0.58, 1 },
        sepColor = { 0.25, 0.25, 0.25, 0.5 },
        bagSpaceGlow = { 0.5, 0.5, 0.5, 0.5 },
    },
}

local GPH_CLASS_COLORS = {
    WARRIOR  = { 0.78, 0.61, 0.43 },
    PALADIN  = { 0.96, 0.55, 0.73 },
    HUNTER   = { 0.67, 0.83, 0.45 },
    ROGUE    = { 1.0,  0.96, 0.41 },
    PRIEST   = { 1.0,  1.0,  1.0  },
    DEATHKNIGHT = { 0.77, 0.12, 0.23 },
    SHAMAN   = { 0.0,  0.44, 0.87 },
    MAGE     = { 0.41, 0.8,  0.94 },
    WARLOCK  = { 0.58, 0.51, 0.79 },
    DRUID    = { 1.0,  0.49, 0.04 },
}

local function GetGphPlayerNameTitleAndColor()
    local name = (UnitName and UnitName("player")) or "Player"
    if not name or name == "" then name = "Player" end
    local _, class = UnitClass and UnitClass("player")
    local darken = 0.68
    local r, g, b = 0.65, 0.6, 0.5
    if class and GPH_CLASS_COLORS[class] then
        local c = GPH_CLASS_COLORS[class]
        r = (c[1] or 0.5) * darken
        g = (c[2] or 0.5) * darken
        b = (c[3] or 0.5) * darken
    end
    return name, r, g, b
end

local function ApplyGphInventoryTitle(fs)
    if not fs then return end
    local name = GetGphPlayerNameTitleAndColor()
    fs:SetText(name)
end

local function ResolveSkinName()
    local SV = _G.FugaziBAGSDB
    local val = SV and SV.gphSkin or "original"
    if val == "fugazi" then return "fugazi" end
    if val == "elvui_real" then return "elvui_real" end
    if val == "elvui" then return "elvui" end
    if val == "pimp_purple" then return "pimp_purple" end
    return "original"
end

--- Adds a 1px border around a button using the given color (used for Search, bag space, and bank bag space so they match).
local function AddBorder(btn, color)
    if not btn then return end
    if not btn._borderTop then
        local t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetHeight(1); t:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0); t:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
        btn._borderTop = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetHeight(1); t:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0); t:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        btn._borderBottom = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetWidth(1); t:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0); t:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        btn._borderLeft = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetWidth(1); t:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0); t:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        btn._borderRight = t
    end
    local r, g, b, a = unpack(color or {1,1,1,1})
    local br, bg, bb = r * 1.5, g * 1.5, b * 1.5
    if br > 1 then br = 1 end; if bg > 1 then bg = 1 end; if bb > 1 then bb = 1 end
    btn._borderTop:SetVertexColor(br, bg, bb, 0.8)
    btn._borderBottom:SetVertexColor(br, bg, bb, 0.8)
    btn._borderLeft:SetVertexColor(br, bg, bb, 0.8)
    btn._borderRight:SetVertexColor(br, bg, bb, 0.8)
end

--- Border for original-skin rarity buttons: when edgeFile/edgeSize given, uses same textured border as main frame; else 2px solid.
--- For the textured border we draw it on a separate frame 2px larger than the button, behind the button (lower frame level),
--- so the button's highlight/click effects don't overlap the border and cause distortion.
local function AddRarityBorder(btn, borderColor, edgeFile, edgeSize)
    if not btn then return end
    if edgeFile and edgeSize then
        -- Don't put backdrop on the button; use a sibling frame so border sits outside and behind.
        if not btn._rarityBorderFrame then
            local parent = btn:GetParent()
            if not parent then return end
            local bf = CreateFrame("Frame", nil, parent)
            bf:SetFrameStrata(btn:GetFrameStrata() or "MEDIUM")
            -- Draw the rarity border slightly ABOVE the button so it isn't hidden behind
            -- the button background, but still separate from the button's own highlight.
            bf:SetFrameLevel((btn:GetFrameLevel() or 1) + 1)
            bf:EnableMouse(false)
            btn._rarityBorderFrame = bf
        end
        local bf = btn._rarityBorderFrame
        bf:ClearAllPoints()
        bf:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
        bf:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -2)
        bf:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = edgeFile,
            tile = true,
            tileSize = 16,
            edgeSize = edgeSize,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        bf:SetBackdropColor(0, 0, 0, 0)
        bf:SetBackdropBorderColor(unpack(borderColor or {0.6, 0.5, 0.2, 0.8}))
        bf:Show()
        if btn._rarityBorderTop then btn._rarityBorderTop:Hide() end
        if btn._rarityBorderBottom then btn._rarityBorderBottom:Hide() end
        if btn._rarityBorderLeft then btn._rarityBorderLeft:Hide() end
        if btn._rarityBorderRight then btn._rarityBorderRight:Hide() end
        return
    end
    -- When switching away from textured border, hide the outer frame so it doesn't linger.
    if btn._rarityBorderFrame then
        btn._rarityBorderFrame:Hide()
        btn._rarityBorderFrame:SetBackdrop(nil)
    end
    local w = 2
    if not btn._rarityBorderTop then
        local t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetHeight(w); t:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0); t:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
        btn._rarityBorderTop = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetHeight(w); t:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0); t:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        btn._rarityBorderBottom = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetWidth(w); t:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0); t:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        btn._rarityBorderLeft = t
        t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        t:SetWidth(w); t:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0); t:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        btn._rarityBorderRight = t
    end
    local r, g, b, a = unpack(borderColor or {0.6, 0.5, 0.2, 0.8})
    btn._rarityBorderTop:SetVertexColor(r, g, b, a)
    btn._rarityBorderBottom:SetVertexColor(r, g, b, a)
    btn._rarityBorderLeft:SetVertexColor(r, g, b, a)
    btn._rarityBorderRight:SetVertexColor(r, g, b, a)
end

local function ApplyGPHFrameSkin(f)
    local skinName = ResolveSkinName()
    local s = SKIN[skinName]
    if not s or not f then return end
    local SV = _G.FugaziBAGSDB
    -- Color overrides:
    -- - mainBg (frame background) should ALWAYS respect the color picker, even when "Customize" is off
    -- - headerTextColor should only respect overrides when "Customize" is enabled
    local allOverrides = (SV and SV.gphSkinOverrides) or {}
    local function color(key, defaultTbl)
        local ov = allOverrides[key]
        if ov and type(ov) == "table" and #ov >= 4 then
            if key == "headerTextColor" and not (SV and SV.gphCategoryHeaderFontCustom) then
                -- Ignore header text override when Customize is off
            else
                return ov[1], ov[2], ov[3], ov[4]
            end
        end
        if defaultTbl then return unpack(defaultTbl) end
        return 1, 1, 1, 1
    end
    -- Frame opacity (gphFrameAlpha) is applied by ApplyFrameAlpha in FugaziBAGS.lua;
    -- the skin itself always renders at full strength so the chrome fade logic stays consistent.
    local r, g, b, a = color("mainBg", s.mainBg)
    f:SetBackdrop(s.mainBackdrop)
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(unpack(s.mainBorder))

    if skinName == "pimp_purple" then
        if not f._pimpSuedeTex then
            local tex = f:CreateTexture(nil, "BACKGROUND")
            tex:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
            tex:SetTexture("Interface\\AddOns\\__FugaziBAGS\\media\\Suede")
            tex:SetAlpha(0.72)
            f._pimpSuedeTex = tex
        end
        f._pimpSuedeTex:SetAlpha(0.72)
        f._pimpSuedeTex:Show()
    else
        if f._pimpSuedeTex then f._pimpSuedeTex:Hide() end
    end
    local titleBar = f.gphTitleBar
    if titleBar then
        titleBar:SetBackdrop(s.titleBackdrop)
        titleBar:SetBackdropColor(unpack(s.titleBg))
        if titleBar._fugaziEpicOverlay then titleBar._fugaziEpicOverlay:Hide() end
    end
    if f.gphTitle then
        ApplyGphInventoryTitle(f.gphTitle)
        f.gphTitle:SetTextColor(color("headerTextColor", s.titleTextColor))
        f.gphTitle:Show()
    end
    local btnColor = s.btnNormal
    local goldTop = { 0.65, 0.45, 0.15, 0.95 }
    local setBtn = function(btn, color)
        if btn and btn.bg and color then
            btn.bg:SetTexture(unpack(color))
            AddBorder(btn, color)
        end
    end
    if skinName == "pimp_purple" then
        local goldHover = s.btnHoverGold or { 0.78, 0.58, 0.22, 1 }
        setBtn(f.gphSortBtn,     goldTop)
        setBtn(f.gphScaleBtn,    goldTop)
        setBtn(f.gphInvBtn,      goldTop)
        setBtn(f.gphSummonBtn,   goldTop)
        
        -- Profession buttons should NEVER have backgrounds
        if f.gphDestroyBtn then
            if f.gphDestroyBtn.bg then f.gphDestroyBtn.bg:SetTexture(nil); f.gphDestroyBtn.bg:SetAlpha(0) end
            if f.gphDestroyBtn._borderTop then f.gphDestroyBtn._borderTop:Hide() end
            if f.gphDestroyBtn._borderBottom then f.gphDestroyBtn._borderBottom:Hide() end
            if f.gphDestroyBtn._borderLeft then f.gphDestroyBtn._borderLeft:Hide() end
            if f.gphDestroyBtn._borderRight then f.gphDestroyBtn._borderRight:Hide() end
        end
        if f.gphMailBtn then
            if f.gphMailBtn.bg then f.gphMailBtn.bg:SetTexture(nil); f.gphMailBtn.bg:SetAlpha(0) end
            if f.gphMailBtn._borderTop then f.gphMailBtn._borderTop:Hide() end
            if f.gphMailBtn._borderBottom then f.gphMailBtn._borderBottom:Hide() end
            if f.gphMailBtn._borderLeft then f.gphMailBtn._borderLeft:Hide() end
            if f.gphMailBtn._borderRight then f.gphMailBtn._borderRight:Hide() end
        end
        
        f.gphTitleBarBtnNormal = goldTop
        f.gphTitleBarBtnHover  = goldHover
        f.gphScaleBtnDim = s.scaleBtnDim
        f.gphScaleBtnBright = s.scaleBtnBright
    else
        setBtn(f.gphSortBtn,     btnColor)
        setBtn(f.gphScaleBtn,    btnColor)
        setBtn(f.gphInvBtn,      btnColor)
        setBtn(f.gphSummonBtn,   btnColor)
        
        -- Profession buttons should NEVER have backgrounds or green boxes
        if f.gphDestroyBtn then
            if f.gphDestroyBtn.bg then f.gphDestroyBtn.bg:SetTexture(nil); f.gphDestroyBtn.bg:SetAlpha(0) end
            if f.gphDestroyBtn._borderTop then f.gphDestroyBtn._borderTop:Hide() end
            if f.gphDestroyBtn._borderBottom then f.gphDestroyBtn._borderBottom:Hide() end
            if f.gphDestroyBtn._borderLeft then f.gphDestroyBtn._borderLeft:Hide() end
            if f.gphDestroyBtn._borderRight then f.gphDestroyBtn._borderRight:Hide() end
        end
        if f.gphMailBtn then
            if f.gphMailBtn.bg then f.gphMailBtn.bg:SetTexture(nil); f.gphMailBtn.bg:SetAlpha(0) end
            if f.gphMailBtn._borderTop then f.gphMailBtn._borderTop:Hide() end
            if f.gphMailBtn._borderBottom then f.gphMailBtn._borderBottom:Hide() end
            if f.gphMailBtn._borderLeft then f.gphMailBtn._borderLeft:Hide() end
            if f.gphMailBtn._borderRight then f.gphMailBtn._borderRight:Hide() end
        end
        
        f.gphTitleBarBtnNormal = btnColor
        f.gphTitleBarBtnHover  = s.searchBtnHover
    end
    f.gphScaleBtnDim = s.scaleBtnDim or { 0.1, 0.3, 0.15, 0.7 }
    f.gphScaleBtnBright = s.scaleBtnBright or { 0.15, 0.4, 0.2, 0.8 }
    local DB = _G.FugaziBAGSDB
    if f.gphScaleBtn and f.gphScaleBtn.bg then
        local scale = (DB and DB.gphScale15) and f.gphScaleBtnDim or f.gphScaleBtnBright
        if scale then f.gphScaleBtn.bg:SetTexture(unpack(scale)) end
    end
    -- Search and bag space: same texture + color (incl. alpha) as header bar so they match exactly
    local titleBgFile = (s.titleBackdrop and s.titleBackdrop.bgFile) or "Interface\\Tooltips\\UI-Tooltip-Background"
    f._gphHeaderBgFile = titleBgFile
    if s.titleBg and f.gphSearchBtn and f.gphSearchBtn.bg then
        f.gphSearchBtn.bg:SetTexture(titleBgFile)
        f.gphSearchBtn.bg:SetVertexColor(unpack(s.titleBg))
        AddBorder(f.gphSearchBtn, s.titleBg)
        f.gphSearchBtnNormal = s.titleBg
        f.gphSearchBtnHover = s.searchBtnHover
    end
    if f.gphSearchLabel then f.gphSearchLabel:SetTextColor(color("headerTextColor", s.titleTextColor)) end
    if f.gphBagSpaceBtn and f.gphBagSpaceBtn.bg and s.titleBg then
        f.gphBagSpaceBtn.bg:SetTexture(titleBgFile)
        f.gphBagSpaceBtn.bg:SetVertexColor(unpack(s.titleBg))
        AddBorder(f.gphBagSpaceBtn, s.titleBg)
    end
    if f.gphBagSpaceBtn and f.gphBagSpaceBtn.fs then f.gphBagSpaceBtn.fs:SetTextColor(color("headerTextColor", s.titleTextColor)) end
    if s.bagSpaceGlow and f.gphBagSpaceBtn and f.gphBagSpaceBtn.glow then f.gphBagSpaceBtn.glow:SetVertexColor(unpack(s.bagSpaceGlow)) end
    f._useOriginalRarityStyle = (skinName == "original")
    f._originalTitleBg = (skinName == "original" and s.titleBg) and s.titleBg or nil
    f._originalMainBorder = (skinName == "original" and s.mainBorder) and s.mainBorder or nil
    local mb = (skinName == "original" and s.mainBackdrop) and s.mainBackdrop or nil
    f._originalEdgeFile = (mb and mb.edgeFile) and mb.edgeFile or nil
    f._originalEdgeSize = (mb and mb.edgeSize) and math.min(12, mb.edgeSize) or 8
    if f.gphBottomBar then
        -- Default bottom bar backdrop (restored when not fugazi/pimp_purple)
        local defaultBottomBackdrop = {
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        }
        if skinName == "pimp_purple" then
            if f._fugaziBottomLeopard then f._fugaziBottomLeopard:Hide() end
            f.gphBottomBar:SetBackdrop(defaultBottomBackdrop)
            if s.bottomBarBg then
                f.gphBottomBar:SetBackdropColor(unpack(s.bottomBarBg))
            end
            if s.bottomBarBorder then
                f.gphBottomBar:SetBackdropBorderColor(unpack(s.bottomBarBorder))
            end
            if not f._pimpBottomLeopard then
                local lb = f.gphBottomBar:CreateTexture(nil, "BACKGROUND")
                lb:SetPoint("TOPLEFT", f.gphBottomBar, "TOPLEFT", 0, 0)
                lb:SetPoint("BOTTOMRIGHT", f.gphBottomBar, "BOTTOMRIGHT", 0, 0)
                lb:SetTexture("Interface\\AddOns\\__FugaziBAGS\\media\\Leopard")
                lb:SetTexCoord(0, 1, 0.0, 20.0 / 256.0)
                lb:SetAlpha(0.72)
                f._pimpBottomLeopard = lb
            else
                f._pimpBottomLeopard:SetTexCoord(0, 1, 0.0, 20.0 / 256.0)
                f._pimpBottomLeopard:Show()
            end
        elseif skinName == "fugazi" then
            if f._pimpBottomLeopard then f._pimpBottomLeopard:Hide() end
            -- Same textured backdrop as header (Suede strip) so bottom bar matches top bar
            f.gphBottomBar:SetBackdrop(s.titleBackdrop)
            f.gphBottomBar:SetBackdropColor(unpack(s.titleBg))
            if s.bottomBarBorder then
                f.gphBottomBar:SetBackdropBorderColor(unpack(s.bottomBarBorder))
            end
            if f.gphBottomBar._fugaziEpicOverlay then f.gphBottomBar._fugaziEpicOverlay:Hide() end
        else
            if f._pimpBottomLeopard then f._pimpBottomLeopard:Hide() end
            if f._fugaziBottomLeopard then f._fugaziBottomLeopard:Hide() end
            if f.gphBottomBar._fugaziEpicOverlay then f.gphBottomBar._fugaziEpicOverlay:Hide() end
            f.gphBottomBar:SetBackdrop(defaultBottomBackdrop)
            if s.bottomBarBg then
                f.gphBottomBar:SetBackdropColor(unpack(s.bottomBarBg))
            end
            if s.bottomBarBorder then
                f.gphBottomBar:SetBackdropBorderColor(unpack(s.bottomBarBorder))
            end
        end
    end
    if s.bottomBarTextColor then
        if f.gphBottomLeft then f.gphBottomLeft:SetTextColor(unpack(s.bottomBarTextColor)) end
        if f.gphBottomCenter then f.gphBottomCenter:SetTextColor(unpack(s.bottomBarTextColor)) end
        if f.gphBottomRight then f.gphBottomRight:SetTextColor(unpack(s.bottomBarTextColor)) end
    end
    if s.sepColor and f.gphSep then f.gphSep:SetTexture(unpack(s.sepColor)) end
    if f.statusText then f.statusText:SetTextColor(color("headerTextColor", s.statusTextColor)) end
    do local r, g, b, a = color("headerTextColor", s.titleTextColor); f.gphAccentTextColor = { r, g, b, a } end
    if f.updateToggle then f.updateToggle() end
    -- Frame opacity uses a separate backdrop layer; keep it in sync when skin is applied.
    if f._gphAlphaBg then
        local bd = f:GetBackdrop()
        if bd then
            f._gphAlphaBg:SetBackdrop(bd)
            local r, g, b, a = f:GetBackdropColor()
            f._gphAlphaBg:SetBackdropColor(r or 0.08, g or 0.08, b or 0.12, 1)
            local br, bg_, bb, ba = f:GetBackdropBorderColor()
            f._gphAlphaBg:SetBackdropBorderColor(br or 0.6, bg_ or 0.5, bb or 0.2, ba or 0.8)
            f:SetBackdrop(nil)
        end
    end
end

local function ApplyBankFrameSkin(f)
    local skinName = ResolveSkinName()
    local s = SKIN[skinName]
    if not s or not f then return end
    local SV = _G.FugaziBAGSDB
    local overrides = (SV and SV.gphCategoryHeaderFontCustom and SV.gphSkinOverrides) or {}
    local function color(key, defaultTbl)
        local ov = overrides[key]
        if ov and type(ov) == "table" and #ov >= 4 then return ov[1], ov[2], ov[3], ov[4] end
        if defaultTbl then return unpack(defaultTbl) end
        return 1, 1, 1, 1
    end
    -- Same as inventory: let ApplyFrameAlpha handle fade; skin provides a solid base.
    local r, g, b, a = color("mainBg", s.mainBg)
    f:SetBackdrop(s.mainBackdrop)
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(unpack(s.mainBorder))

    if skinName == "pimp_purple" then
        if not f._pimpSuedeTex then
            local tex = f:CreateTexture(nil, "BACKGROUND")
            tex:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
            tex:SetTexture("Interface\\AddOns\\__FugaziBAGS\\media\\Suede")
            tex:SetAlpha(0.72)
            f._pimpSuedeTex = tex
        end
        f._pimpSuedeTex:SetAlpha(0.72)
        f._pimpSuedeTex:Show()
    elseif f._pimpSuedeTex then
        f._pimpSuedeTex:Hide()
    end
    local titleBar = f.titleBar
    if titleBar then
        titleBar:SetBackdrop(s.titleBackdrop)
        titleBar:SetBackdropColor(unpack(s.titleBg))
    end
    if f.bankTitleText then
        f.bankTitleText:SetTextColor(color("headerTextColor", s.titleTextColor))
    end
    local btnColor = s.btnNormal
    if skinName == "pimp_purple" then
        btnColor = { 0, 0, 0, 0 }
    end
    local setBtn = function(btn) if btn and btn.bg then btn.bg:SetTexture(unpack(btnColor)) end end
    setBtn(f.purchaseBtn)
    setBtn(f.toggleBtn)
    if f.bankSortBtn and f.bankSortBtn.bg then f.bankSortBtn.bg:SetTexture(unpack(btnColor)) end

    if f.bankSpaceBtn then
        local titleBgFile = (s.titleBackdrop and s.titleBackdrop.bgFile) or "Interface\\Tooltips\\UI-Tooltip-Background"
        f.bankSpaceBtnNormalFile = titleBgFile
        f.bankSpaceBtnNormal = s.titleBg
        f.bankSpaceBtnHover = s.searchBtnHover or s.titleBg
        do local r, g, b, a = color("headerTextColor", s.titleTextColor); f.bankSpaceTextColor = { r, g, b, a } end
        f.bankSpaceGlowColor = { 1, 0.85, 0.2, 0.5 }
        if f.bankSpaceBtn.bg and s.titleBg then
            f.bankSpaceBtn.bg:SetTexture(titleBgFile)
            f.bankSpaceBtn.bg:SetVertexColor(unpack(s.titleBg))
            AddBorder(f.bankSpaceBtn, s.titleBg)
        end
        if f.bankSpaceBtn.fs then
            f.bankSpaceBtn.fs:SetTextColor(unpack(f.bankSpaceTextColor))
        end
        if skinName == "elvui" or skinName == "elvui_real" or skinName == "pimp_purple" then
            if f.bankSpaceBtn.glow and s.bagSpaceGlow then
                f.bankSpaceGlowColor = { unpack(s.bagSpaceGlow) }
                f.bankSpaceBtn.glow:SetVertexColor(unpack(f.bankSpaceGlowColor))
            end
        end
        if f.bankSpaceBtn.glow then
            f.bankSpaceBtn.glow:SetVertexColor(unpack(f.bankSpaceGlowColor))
        end
    end
    f._useOriginalRarityStyle = (skinName == "original")
    f._originalTitleBg = (skinName == "original" and s.titleBg) and s.titleBg or nil
    f._gphHeaderBgFile = (s.titleBackdrop and s.titleBackdrop.bgFile) or "Interface\\Tooltips\\UI-Tooltip-Background"
    f._originalMainBorder = (skinName == "original" and s.mainBorder) and s.mainBorder or nil
    local mb = (skinName == "original" and s.mainBackdrop) and s.mainBackdrop or nil
    f._originalEdgeFile = (mb and mb.edgeFile) and mb.edgeFile or nil
    f._originalEdgeSize = (mb and mb.edgeSize) and math.min(12, mb.edgeSize) or 8

    f.bankBtnNormal = btnColor
    if skinName == "pimp_purple" then
        f.bankBtnHover = { 0, 0, 0, 0 }
    else
        f.bankBtnHover = s.searchBtnHover or s.searchBtnBg
    end
end

local function SkinScrollBar(self)
    if not self then return end
    local name = self:GetName()
    if not name then return end

    local scrollbar = _G[name.."ScrollBar"]
    if not scrollbar then return end

    -- Aggressively hide standard Blizzard buttons (up/down arrows)
    local up = _G[name.."ScrollBarScrollUpButton"]
    local down = _G[name.."ScrollBarScrollDownButton"]
    if up then 
        up:Hide(); up:SetAlpha(0); up:EnableMouse(false) 
        if up:GetNormalTexture() then up:GetNormalTexture():SetTexture(nil) end
        if up:GetPushedTexture() then up:GetPushedTexture():SetTexture(nil) end
    end
    if down then 
        down:Hide(); down:SetAlpha(0); down:EnableMouse(false) 
        if down:GetNormalTexture() then down:GetNormalTexture():SetTexture(nil) end
        if down:GetPushedTexture() then down:GetPushedTexture():SetTexture(nil) end
    end

    -- Clear all legacy textures from the scrollbar frame itself
    for i = 1, scrollbar:GetNumRegions() do
        local region = select(i, scrollbar:GetRegions())
        if region:GetObjectType() == "Texture" then
            region:SetTexture(nil)
        end
    end

    -- Add flat vertical rail (the groove)
    if not scrollbar.bg then
        local bg = scrollbar:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TOPLEFT", scrollbar, "TOPLEFT", 0, 0)
        bg:SetPoint("BOTTOMRIGHT", scrollbar, "BOTTOMRIGHT", 0, 0)
        bg:SetTexture(0, 0, 0, 0.4) -- Semi-transparent dark rail
        scrollbar.bg = bg
    end

    -- Add sleek flat thumb
    local thumb = scrollbar:GetThumbTexture()
    if thumb then
        thumb:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        thumb:SetWidth(12)
        -- Color it appropriately for the skin
        local s = ResolveSkinName()
        if s == "pimp_purple" then
            thumb:SetVertexColor(0.75, 0.40, 0.95, 0.8)
        else
            thumb:SetVertexColor(0.2, 0.6, 0.5, 0.8) -- Default ebon-greenish
        end
    end
end

--- Full "FUGAZI" preset: when a user selects the FUGAZI skin, apply these DB options so they get
--- the same look — fonts, font sizes, icon size, hide options, frame opacity, and all colors.
function ApplyFugaziPreset()
    local SV = _G.FugaziBAGSDB
    if not SV then return end
    SV.gphSkin = "fugazi"
    -- Frame opacity
    SV.gphFrameAlpha = 1
    -- Header / category: font, size, enable customisation
    SV.gphCategoryHeaderFontCustom = true
    SV.gphCategoryHeaderFont = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\AncientModernTales.ttf"
    SV.gphCategoryHeaderFontSize = 12
    -- Row / item details: font (Eight Bit Dragon), font size 15, icon size, opacity 100%, enable customisation
    SV.gphItemDetailsCustom = true
    SV.gphItemDetailsFont = "Interface\\AddOns\\__FugaziBAGS\\media\\Fonts\\EightBitDragon.ttf"
    SV.gphItemDetailsFontSize = 15
    SV.gphItemDetailsIconSize = 14
    SV.gphItemDetailsAlpha = 1
    -- Visibility
    SV.gphHideIconsInList = true
    SV.gphHideTopButtons = true
    SV.gphBankHideTopButtons = true
    -- Colors (header text, FIT row label, item icon tint, frame background)
    SV.gphSkinOverrides = {
        fitRowColor = { 1, 0.945, 0.89, 1 },
        headerTextColor = { 1, 0.808, 0.584, 1 },
        itemDetailsIconColor = { 0.965, 1, 0.953 },
        mainBg = { 0.133, 0.051, 0.004, 0.98 },
    }
end

-- Expose for FugaziBAGS.lua (AddBorder for Search/bag; AddRarityBorder for original-skin rarity buttons)
_G.__FugaziBAGS_Skins = {
    SKIN = SKIN,
    ApplyGPHFrameSkin = ApplyGPHFrameSkin,
    ApplyBankFrameSkin = ApplyBankFrameSkin,
    ApplyGphInventoryTitle = ApplyGphInventoryTitle,
    SkinScrollBar = SkinScrollBar,
    AddBorder = AddBorder,
    AddRarityBorder = AddRarityBorder,
    ApplyFugaziPreset = ApplyFugaziPreset,
}
_G.ApplyFugaziPreset = ApplyFugaziPreset

