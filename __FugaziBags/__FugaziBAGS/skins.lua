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
    if val == "elvui_real" then return "elvui_real" end
    if val == "elvui" then return "elvui" end
    if val == "pimp_purple" then return "pimp_purple" end
    return "original"
end

local function ApplyGPHFrameSkin(f)
    local skinName = ResolveSkinName()
    local s = SKIN[skinName]
    if not s or not f then return end
    f:SetBackdrop(s.mainBackdrop)
    f:SetBackdropColor(unpack(s.mainBg))
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
    end
    if f.gphTitle then
        ApplyGphInventoryTitle(f.gphTitle)
        if s.titleTextColor then f.gphTitle:SetTextColor(unpack(s.titleTextColor)) end
        f.gphTitle:Show()
    end
    local btnColor = s.btnNormal
    local goldTop = { 0.65, 0.45, 0.15, 0.95 }
    local setBtn = function(btn, color)
        if btn and btn.bg and color then
            btn.bg:SetTexture(unpack(color))
        end
    end
    if skinName == "pimp_purple" then
        local goldHover = s.btnHoverGold or { 0.78, 0.58, 0.22, 1 }
        setBtn(f.gphCollapseBtn, goldTop)
        setBtn(f.gphSortBtn,     goldTop)
        setBtn(f.gphScaleBtn,    goldTop)
        setBtn(f.gphDestroyBtn,  goldTop)
        f.gphTitleBarBtnNormal = goldTop
        f.gphTitleBarBtnHover  = goldHover
        f.gphScaleBtnDim = s.scaleBtnDim
        f.gphScaleBtnBright = s.scaleBtnBright
        f.gphCollapseBtnDim = s.collapseBtnDim
        f.gphCollapseBtnBright = s.collapseBtnBright
    else
        setBtn(f.gphCollapseBtn, btnColor)
        setBtn(f.gphSortBtn,     btnColor)
        setBtn(f.gphScaleBtn,    btnColor)
        setBtn(f.gphDestroyBtn,  btnColor)
        f.gphTitleBarBtnNormal = btnColor
        f.gphTitleBarBtnHover  = s.searchBtnHover
    end
    f.gphScaleBtnDim = s.scaleBtnDim or { 0.1, 0.3, 0.15, 0.7 }
    f.gphScaleBtnBright = s.scaleBtnBright or { 0.15, 0.4, 0.2, 0.8 }
    f.gphCollapseBtnDim = s.collapseBtnDim or { 0.1, 0.3, 0.15, 0.7 }
    f.gphCollapseBtnBright = s.collapseBtnBright or { 0.15, 0.4, 0.2, 0.8 }
    local DB = _G.FugaziBAGSDB
    if f.gphCollapseBtn and f.gphCollapseBtn.bg then
        local coll = DB and DB.gphCollapsed and f.gphCollapseBtnBright or f.gphCollapseBtnDim
        if coll then f.gphCollapseBtn.bg:SetTexture(unpack(coll)) end
    end
    if f.gphScaleBtn and f.gphScaleBtn.bg then
        local scale = (DB and DB.gphScale15) and f.gphScaleBtnDim or f.gphScaleBtnBright
        if scale then f.gphScaleBtn.bg:SetTexture(unpack(scale)) end
    end
    if s.searchBtnBg and f.gphSearchBtn and f.gphSearchBtn.bg then
        f.gphSearchBtn.bg:SetTexture(unpack(s.searchBtnBg))
        f.gphSearchBtnNormal = s.searchBtnBg
        f.gphSearchBtnHover = s.searchBtnHover
    end
    if s.titleTextColor and f.gphSearchLabel then f.gphSearchLabel:SetTextColor(unpack(s.titleTextColor)) end
    if f.gphBagSpaceBtn and f.gphBagSpaceBtn.bg then
        if skinName == "pimp_purple" and s.searchBtnBg then
            f.gphBagSpaceBtn.bg:SetTexture(unpack(s.searchBtnBg))
        elseif s.btnNormal then
            f.gphBagSpaceBtn.bg:SetTexture(unpack(s.btnNormal))
        end
    end
    if s.titleTextColor and f.gphBagSpaceBtn and f.gphBagSpaceBtn.fs then f.gphBagSpaceBtn.fs:SetTextColor(unpack(s.titleTextColor)) end
    if s.bagSpaceGlow and f.gphBagSpaceBtn and f.gphBagSpaceBtn.glow then f.gphBagSpaceBtn.glow:SetVertexColor(unpack(s.bagSpaceGlow)) end
    if f.gphBottomBar then
        if skinName ~= "pimp_purple" then
            if f._pimpBottomLeopard then
                f._pimpBottomLeopard:Hide()
            end
            if s.bottomBarBg then
                f.gphBottomBar:SetBackdropColor(unpack(s.bottomBarBg))
            end
            if s.bottomBarBorder then
                f.gphBottomBar:SetBackdropBorderColor(unpack(s.bottomBarBorder))
            end
        else
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
        end
    end
    if s.bottomBarTextColor then
        if f.gphBottomLeft then f.gphBottomLeft:SetTextColor(unpack(s.bottomBarTextColor)) end
        if f.gphBottomCenter then f.gphBottomCenter:SetTextColor(unpack(s.bottomBarTextColor)) end
        if f.gphBottomRight then f.gphBottomRight:SetTextColor(unpack(s.bottomBarTextColor)) end
    end
    if s.sepColor and f.gphSep then f.gphSep:SetTexture(unpack(s.sepColor)) end
    if s.statusTextColor then
        if f.statusText then f.statusText:SetTextColor(unpack(s.statusTextColor)) end
        if f.gphStatusLeft then f.gphStatusLeft:SetTextColor(unpack(s.statusTextColor)) end
        if f.gphStatusCenter then f.gphStatusCenter:SetTextColor(unpack(s.statusTextColor)) end
        if f.gphStatusRight then f.gphStatusRight:SetTextColor(unpack(s.statusTextColor)) end
    end
    f.gphAccentTextColor = s.titleTextColor
    if f.updateToggle then f.updateToggle() end
end

local function ApplyBankFrameSkin(f)
    local skinName = ResolveSkinName()
    local s = SKIN[skinName]
    if not s or not f then return end
    f:SetBackdrop(s.mainBackdrop)
    f:SetBackdropColor(unpack(s.mainBg))
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
    if f.bankTitleText and s.titleTextColor then
        f.bankTitleText:SetTextColor(unpack(s.titleTextColor))
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
        f.bankSpaceTextColor = { 1, 0.85, 0.4, 1 }
        f.bankSpaceGlowColor = { 1, 0.85, 0.2, 0.5 }

        if skinName == "elvui" or skinName == "elvui_real" or skinName == "pimp_purple" then
            if f.bankSpaceBtn.bg then
                if skinName == "pimp_purple" and s.searchBtnBg then
                    f.bankSpaceBtn.bg:SetTexture(unpack(s.searchBtnBg))
                elseif s.btnNormal then
                    f.bankSpaceBtn.bg:SetTexture(unpack(s.btnNormal))
                end
            end
            if f.bankSpaceBtn.fs and s.titleTextColor then
                f.bankSpaceTextColor = { unpack(s.titleTextColor) }
                f.bankSpaceBtn.fs:SetTextColor(unpack(f.bankSpaceTextColor))
            end
            if f.bankSpaceBtn.glow and s.bagSpaceGlow then
                f.bankSpaceGlowColor = { unpack(s.bagSpaceGlow) }
                f.bankSpaceBtn.glow:SetVertexColor(unpack(f.bankSpaceGlowColor))
            end
        else
            if f.bankSpaceBtn.fs then
                f.bankSpaceBtn.fs:SetTextColor(unpack(f.bankSpaceTextColor))
            end
            if f.bankSpaceBtn.glow then
                f.bankSpaceBtn.glow:SetVertexColor(unpack(f.bankSpaceGlowColor))
            end
        end
    end

    f.bankBtnNormal = btnColor
    if skinName == "pimp_purple" then
        f.bankBtnHover = { 0, 0, 0, 0 }
    else
        f.bankBtnHover = s.searchBtnHover or s.searchBtnBg
    end
end

-- Expose for FugaziBAGS.lua
_G.__FugaziBAGS_Skins = {
    SKIN = SKIN,
    ApplyGPHFrameSkin = ApplyGPHFrameSkin,
    ApplyBankFrameSkin = ApplyBankFrameSkin,
    ApplyGphInventoryTitle = ApplyGphInventoryTitle,
}
