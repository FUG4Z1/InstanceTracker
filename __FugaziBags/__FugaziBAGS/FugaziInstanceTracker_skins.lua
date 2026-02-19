----------------------------------------------------------------------
-- Instance Tracker skins: own copy so lockouts/ledger can be skinned
-- when BAGS is disabled. Uses FugaziBAGSDB.fitSkin. Loaded after main.
----------------------------------------------------------------------

local FIT_SKIN = {
    original = {
        mainBackdrop = {
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 24,
            insets   = { left = 6, right = 6, top = 6, bottom = 6 },
        },
        mainBg = { 0.08, 0.08, 0.12, 0.92 },
        mainBorder = { 0.6, 0.5, 0.2, 0.8 },
        titleBackdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = nil, tile = true, tileSize = 16, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } },
        titleBg = { 0.35, 0.28, 0.1, 0.7 },
        btnNormal = { 0.1, 0.3, 0.15, 0.7 },
        titleTextColor = { 1, 0.85, 0.4, 1 },
        sepColor = { 1, 1, 1, 0.15 },
        statusTextColor = { 1, 0.85, 0.4, 1 },
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
        btnNormal = { 0.1, 0.3, 0.15, 0.7 },
        titleTextColor = { 0.6, 0.85, 0.85, 1 },
        sepColor = { 0.18, 0.31, 0.31, 0.4 },
        statusTextColor = { 0.6, 0.85, 0.85, 1 },
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
        sepColor = { 0.25, 0.25, 0.25, 0.5 },
        statusTextColor = { 0.8, 0.8, 0.8, 1 },
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
        sepColor = { 0.70, 0.50, 0.90, 0.5 },
        statusTextColor = { 0.95, 0.85, 1.0, 1 },
    },
}

local function ResolveFitSkinName()
    -- Prefer FIT addon's saved setting so the FIT options panel works when this frame was created by BAGS.
    local val = (_G.InstanceTrackerDB and _G.InstanceTrackerDB.fitSkin)
        or (_G.FugaziBAGSDB and _G.FugaziBAGSDB.fitSkin)
        or "original"
    if val == "elvui_real" then return "elvui_real" end
    if val == "elvui" then return "elvui" end
    if val == "pimp_purple" then return "pimp_purple" end
    return "original"
end

local function ApplyInstanceTrackerFrameSkin(f)
    local skinName = ResolveFitSkinName()
    local s = FIT_SKIN[skinName]
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

    -- Support both BAGS (titleBar/fitTitle) and IT (itTitleBar/itTitleText) frame refs
    local titleBar = f.titleBar or f.itTitleBar
    if titleBar and s.titleBackdrop then
        titleBar:SetBackdrop(s.titleBackdrop)
        if s.titleBg then titleBar:SetBackdropColor(unpack(s.titleBg)) end
    end
    local titleText = f.fitTitle or f.itTitleText
    if titleText and s.titleTextColor then titleText:SetTextColor(unpack(s.titleTextColor)) end

    local btnColor = s.btnNormal
    local setBtn = function(btn) if btn and btn.bg and btnColor then btn.bg:SetTexture(unpack(btnColor)) end end
    setBtn(f.collapseBtn)
    setBtn(f.statsBtn)
    setBtn(f.resetBtn)
    setBtn(f.gphBtn)

    local sep = f.sep or f.itSep
    if s.sepColor and sep then sep:SetTexture(unpack(s.sepColor)) end
    local hourlyText = f.hourlyText or f.itHourlyText
    if s.statusTextColor and hourlyText then hourlyText:SetTextColor(unpack(s.statusTextColor)) end
end

local function ApplyInstanceTrackerStatsFrameSkin(f)
    local skinName = ResolveFitSkinName()
    local s = FIT_SKIN[skinName]
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
        f._pimpSuedeTex:Show()
    else
        if f._pimpSuedeTex then f._pimpSuedeTex:Hide() end
    end

    local titleBar = f.titleBar or f.itTitleBar
    if titleBar and s.titleBackdrop then
        titleBar:SetBackdrop(s.titleBackdrop)
        if s.titleBg then titleBar:SetBackdropColor(unpack(s.titleBg)) end
    end
    local titleText = f.fitTitle or f.itTitleText
    if titleText and s.titleTextColor then titleText:SetTextColor(unpack(s.titleTextColor)) end

    local btnColor = s.btnNormal
    local setBtn = function(btn) if btn and btn.bg and btnColor then btn.bg:SetTexture(unpack(btnColor)) end end
    setBtn(f.collapseBtn)
    setBtn(f.clearBtn)
end

_G.__FugaziInstanceTracker_Skins = {
    SKIN = FIT_SKIN,
    ApplyMain = ApplyInstanceTrackerFrameSkin,
    ApplyStats = ApplyInstanceTrackerStatsFrameSkin,
}
