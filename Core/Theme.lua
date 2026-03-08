local addonName, ns = ...

local Theme = {}
ns:RegisterModule("Theme", Theme)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

-------------------------------------------------
-- Theme Definitions
-------------------------------------------------
local themes = {
    guda = {
        frameBg = {0.08, 0.08, 0.08, 1},
        frameBorder = {0.30, 0.30, 0.30, 1},
        headerBg = {0.12, 0.12, 0.12, 1},
        titleColor = {1, 1, 1, 1},
        slotBgColor = {0.15, 0.15, 0.15, 1},
        bankTabBg = {0.12, 0.12, 0.12, 1},
        bankTabBorder = {0.30, 0.30, 0.30, 1},
        bankTabSelected = {0.20, 0.20, 0.20, 1},
        footerButtonBg = {0.12, 0.12, 0.12, 1},
        footerButtonBorder = {0.30, 0.30, 0.30, 1},
        useBlizzardFrame = false,
        backdrop = {
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14,
            insets = {left = 3, right = 3, top = 3, bottom = 3},
        },
        headerBackdrop = {
            bgFile = "Interface\\Buttons\\WHITE8x8",
        },
        backdropSolid = {
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets = {left = 0, right = 0, top = 0, bottom = 0},
        },
    },
    blizzard = {
        frameBg = {1, 1, 1, 1},
        frameBorder = {1, 1, 1, 1},
        headerBg = {1, 1, 1, 1},
        titleColor = {1, 1, 1, 1},
        slotBgColor = {0.15, 0.15, 0.15, 1},
        bankTabBg = {0.12, 0.12, 0.12, 1},
        bankTabBorder = {0.30, 0.30, 0.30, 1},
        bankTabSelected = {0.20, 0.20, 0.20, 1},
        footerButtonBg = {0.5, 0.06, 0.06, 0.6},
        footerButtonBorder = {0.5, 0.06, 0.06, 1},
        useBlizzardFrame = true,
        backdrop = nil,
        headerBackdrop = nil,
        backdropSolid = {
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets = {left = 0, right = 0, top = 0, bottom = 0},
        },
    },
    retail = {
        frameBg = {0.08, 0.08, 0.08, 1},
        frameBorder = {0.30, 0.30, 0.30, 1},
        headerBg = {0.12, 0.12, 0.12, 1},
        titleColor = {1, 1, 1, 1},
        slotBgColor = {0.15, 0.15, 0.15, 1},
        bankTabBg = {0.12, 0.12, 0.12, 1},
        bankTabBorder = {0.30, 0.30, 0.30, 1},
        bankTabSelected = {0.20, 0.20, 0.20, 1},
        footerButtonBg = {0.12, 0.12, 0.12, 1},
        footerButtonBorder = {0.30, 0.30, 0.30, 1},
        useBlizzardFrame = false,
        useMetalFrame = true,
        backdrop = nil,
        headerBackdrop = nil,
        backdropSolid = {
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets = {left = 0, right = 0, top = 0, bottom = 0},
        },
        metalTextures = {
            corners = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\UIFrameMetal2x",
            horizontal = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\UIFrameMetalHorizontal2x",
            vertical = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\UIFrameMetalVertical2x",
            background = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\UI-Background-Rock",
        },
        slotTextures = {
            background = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\HDActionBarBtn",
            border = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\btn_border",
            highlight = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\btn_highlight_strong",
        },
    },
}

-------------------------------------------------
-- Classic border texture keys in ButtonFrameTemplate
-------------------------------------------------
local classicBorderKeys = {
    "BotLeftCorner", "BotRightCorner", "BottomBorder",
    "LeftBorder", "RightBorder",
    "TopRightCorner", "TopLeftCorner", "TopBorder",
}

-------------------------------------------------
-- Cache
-------------------------------------------------
local cachedTheme = nil

-------------------------------------------------
-- API
-------------------------------------------------

--- Returns the active theme table
function Theme:Get()
    if cachedTheme then
        return cachedTheme
    end
    local themeName = Database:GetSetting("theme") or "guda"
    if themeName == "retail" and ns.IsRetail then
        themeName = "guda"
    end
    cachedTheme = themes[themeName] or themes.guda
    return cachedTheme
end

--- Returns a single theme property value
function Theme:GetValue(key)
    local t = self:Get()
    return t[key]
end

-------------------------------------------------
-- ButtonFrameTemplate background helper
-------------------------------------------------

local blizzBgCount = 0
-- How far to extend the NineSlice beyond the frame on each side (retail
-- NineSlice border is ~8-10px wide; extending pushes border outward so
-- content at PADDING=8 sits comfortably inside the visible border)
local BLIZ_EXTEND_LEFT = 4
local BLIZ_EXTEND_TOP = 1
local BLIZ_EXTEND_RIGHT = 0
local BLIZ_EXTEND_BOTTOM = 1

--- Creates a hidden ButtonFrameTemplate child (once) to use as background
local function EnsureBlizzardBg(frame)
    if frame.blizzardBg then return frame.blizzardBg end

    blizzBgCount = blizzBgCount + 1
    local name = "GudaBagsThemeBg" .. blizzBgCount
    local bliz = CreateFrame("Frame", name, frame, "ButtonFrameTemplate")
    bliz:EnableMouse(false)
    bliz:SetFrameLevel(frame:GetFrameLevel())

    -- Hide all ButtonFrameTemplate UI elements
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(bliz) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(bliz) end
    if bliz.Inset then bliz.Inset:Hide() end
    if bliz.CloseButton then bliz.CloseButton:Hide() end
    if bliz.TitleContainer then bliz.TitleContainer:Hide() end
    if bliz.PortraitFrame then bliz.PortraitFrame:SetAlpha(0) end
    if bliz.PortraitContainer then bliz.PortraitContainer:Hide() end
    if bliz.portrait then bliz.portrait:SetAlpha(0) end

    bliz:Hide()
    frame.blizzardBg = bliz
    return bliz
end

-------------------------------------------------
-- Metal Frame (Retail theme on Classic)
-------------------------------------------------

local metalFrameCount = 0

--- Creates the 8-piece metal border overlay (once per frame)
local function EnsureMetalFrame(frame)
    if frame.metalFrame then return frame.metalFrame end

    local theme = themes.retail
    local tex = theme.metalTextures

    metalFrameCount = metalFrameCount + 1
    local mf = CreateFrame("Frame", "GudaBagsMetalFrame" .. metalFrameCount, frame)
    mf:EnableMouse(false)
    mf:SetAllPoints(frame)
    mf:SetFrameLevel(frame:GetFrameLevel())

    mf.edges = {}

    -- Background
    local bg = mf:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(tex.background)
    bg:SetPoint("TOPLEFT", 2, -21)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    mf.bg = bg

    -- Corner texcoords from Dragonflight3 CreatePaperDollFrame (exact values)
    -- TopLeft corner
    local tl = mf:CreateTexture(nil, "OVERLAY")
    tl:SetTexture(tex.corners)
    tl:SetSize(75, 75)
    tl:SetPoint("TOPLEFT", mf, "TOPLEFT", -13, 16)
    tl:SetTexCoord(0.00195312, 0.294922, 0.00195312, 0.294922)
    mf.edges[#mf.edges + 1] = tl

    -- TopRight corner
    local tr = mf:CreateTexture(nil, "OVERLAY")
    tr:SetTexture(tex.corners)
    tr:SetSize(75, 75)
    tr:SetPoint("TOPRIGHT", mf, "TOPRIGHT", 4, 16)
    tr:SetTexCoord(0.298828, 0.591797, 0.00195312, 0.294922)
    mf.edges[#mf.edges + 1] = tr

    -- BottomLeft corner
    local bl = mf:CreateTexture(nil, "OVERLAY")
    bl:SetTexture(tex.corners)
    bl:SetSize(32, 32)
    bl:SetPoint("BOTTOMLEFT", mf, "BOTTOMLEFT", -13, -3)
    bl:SetTexCoord(0.298828, 0.423828, 0.298828, 0.423828)
    mf.edges[#mf.edges + 1] = bl

    -- BottomRight corner
    local br = mf:CreateTexture(nil, "OVERLAY")
    br:SetTexture(tex.corners)
    br:SetSize(32, 32)
    br:SetPoint("BOTTOMRIGHT", mf, "BOTTOMRIGHT", 4, -3)
    br:SetTexCoord(0.427734, 0.552734, 0.298828, 0.423828)
    mf.edges[#mf.edges + 1] = br

    -- Top edge (connects TopLeft to TopRight)
    local top = mf:CreateTexture(nil, "OVERLAY")
    top:SetTexture(tex.horizontal)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT", 0, 0)
    top:SetPoint("TOPRIGHT", tr, "TOPLEFT", 0, 0)
    top:SetHeight(75)
    top:SetTexCoord(0.0, 1.0, 0.00390625, 0.589844)
    mf.edges[#mf.edges + 1] = top

    -- Bottom edge (connects BottomLeft to BottomRight)
    local bottom = mf:CreateTexture(nil, "OVERLAY")
    bottom:SetTexture(tex.horizontal)
    bottom:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT", 0, 0)
    bottom:SetHeight(32)
    bottom:SetTexCoord(0.0, 0.5, 0.597656, 0.847656)
    mf.edges[#mf.edges + 1] = bottom

    -- Left edge (connects TopLeft to BottomLeft)
    local left = mf:CreateTexture(nil, "OVERLAY")
    left:SetTexture(tex.vertical)
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT", 0, 0)
    left:SetWidth(75)
    left:SetTexCoord(0.00195312, 0.294922, 0.0, 1.0)
    mf.edges[#mf.edges + 1] = left

    -- Right edge (connects TopRight to BottomRight)
    local right = mf:CreateTexture(nil, "OVERLAY")
    right:SetTexture(tex.vertical)
    right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT", 0, 0)
    right:SetPoint("BOTTOMLEFT", br, "TOPLEFT", 0, 0)
    right:SetWidth(75)
    right:SetTexCoord(0.298828, 0.591797, 0.0, 1.0)
    mf.edges[#mf.edges + 1] = right

    mf:Hide()
    frame.metalFrame = mf
    return mf
end

--- Apply the correct background for the current theme.
--- Call this from UpdateFrameAppearance in each frame module.
--- @param frame table The main addon frame
--- @param bgAlpha number 0-1 opacity
--- @param showBorders boolean Whether borders are visible
function Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)
    local useMetal = self:GetValue("useMetalFrame")
    if useMetal then
        -- Hide other theme elements
        if frame.blizzardBg then frame.blizzardBg:Hide() end
        if frame.SetBackdrop then frame:SetBackdrop(nil) end
        if frame.themeBg then frame.themeBg:Hide() end
        -- Create/show metal frame
        local mf = EnsureMetalFrame(frame)
        mf:SetFrameLevel(frame:GetFrameLevel())
        mf:SetAllPoints(frame)
        mf:Show()
        mf.bg:SetAlpha(bgAlpha)
        -- Show/hide border pieces
        for _, piece in ipairs(mf.edges) do
            piece:SetShown(showBorders)
            piece:SetAlpha(showBorders and bgAlpha or 0)
        end
        return
    end

    local useBlizzard = self:GetValue("useBlizzardFrame")

    if useBlizzard then
        -- Hide metal frame if switching from retail theme
        if frame.metalFrame then frame.metalFrame:Hide() end
        -- Blizzard theme: ButtonFrameTemplate child provides bg + border
        local bliz = EnsureBlizzardBg(frame)
        -- Match the frame's own level so the Blizzard bg covers frames below,
        -- just like SetBackdrop does for the Guda theme.  The frame's children
        -- (header, item buttons, scroll child) already have higher explicit
        -- levels so they render on top.
        local baseLvl = frame:GetFrameLevel()
        bliz:SetFrameLevel(baseLvl)
        bliz:SetAllPoints(frame)
        bliz:Show()

        -- Background texture
        bliz.Bg:SetAlpha(bgAlpha)
        bliz.Bg:ClearAllPoints()
        if bliz.TopTileStreaks then
            bliz.TopTileStreaks:Hide()
        end

        if showBorders then
            bliz.Bg:SetPoint("TOPLEFT", 2, -21)
            bliz.Bg:SetPoint("BOTTOMRIGHT", -2, 2)
        else
            bliz.Bg:SetPoint("TOPLEFT", 2, 0)
            bliz.Bg:SetPoint("BOTTOMRIGHT", -2, 0)
        end

        -- Hide title bar background (our custom header handles the title area)
        if bliz.TitleBg then
            bliz.TitleBg:SetAlpha(showBorders and bgAlpha or 0)
        end

        -- Classic border pieces (stay at frame edges — works fine on Classic)
        for _, key in ipairs(classicBorderKeys) do
            if bliz[key] then
                bliz[key]:SetShown(showBorders)
                bliz[key]:SetAlpha(bgAlpha)
            end
        end

        -- Retail NineSlice: extend outward so the thick border wraps around
        -- content instead of eating into the PADDING area. Hide center fill
        -- since Bg handles the background.
        if bliz.NineSlice then
            bliz.NineSlice:SetShown(showBorders)
            bliz.NineSlice:SetAlpha(bgAlpha)
            bliz.NineSlice:SetFrameLevel(baseLvl)
            bliz.NineSlice:ClearAllPoints()
            bliz.NineSlice:SetPoint("TOPLEFT", bliz, "TOPLEFT", -BLIZ_EXTEND_LEFT, BLIZ_EXTEND_TOP)
            bliz.NineSlice:SetPoint("BOTTOMRIGHT", bliz, "BOTTOMRIGHT", BLIZ_EXTEND_RIGHT, -BLIZ_EXTEND_BOTTOM)
            if bliz.NineSlice.Center then
                bliz.NineSlice.Center:Hide()
            end
        end

        -- Clear the main frame backdrop entirely
        frame:SetBackdrop(nil)

        -- Hide the old themeBg texture if it exists from previous approach
        if frame.themeBg then frame.themeBg:Hide() end
    else
        -- Guda theme: normal backdrop
        if frame.blizzardBg then
            frame.blizzardBg:Hide()
        end
        if frame.metalFrame then frame.metalFrame:Hide() end
        if frame.themeBg then frame.themeBg:Hide() end

        frame:SetBackdrop(self:GetValue("backdrop"))
        local bg = self:GetValue("frameBg")
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bgAlpha)

        if showBorders then
            local border = self:GetValue("frameBorder")
            frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
        else
            frame:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end
end

--- Sync the blizzardBg child frame level after the parent frame level changes.
--- Call this whenever you SetFrameLevel on a bag/bank frame.
function Theme:SyncBlizzardBgLevel(frame)
    if frame and frame.blizzardBg and frame.blizzardBg:IsShown() then
        local baseLvl = frame:GetFrameLevel()
        frame.blizzardBg:SetFrameLevel(baseLvl)
        if frame.blizzardBg.NineSlice then
            frame.blizzardBg.NineSlice:SetFrameLevel(baseLvl)
        end
    end
    if frame and frame.metalFrame and frame.metalFrame:IsShown() then
        frame.metalFrame:SetFrameLevel(frame:GetFrameLevel())
    end
end

-------------------------------------------------
-- Header Icon Button Styling
-------------------------------------------------
local BLIZZARD_ICON_SIZE = 14
local BLIZZARD_ICON_BG_W = 24
local BLIZZARD_ICON_BG_H = 18
local GUDA_ICON_SIZE = 16

local iconBgBackdrop = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 8,
    insets = {left = 2, right = 2, top = 2, bottom = 2},
}

local function EnsureIconBg(button)
    if button.themeBg then return button.themeBg end
    local bg = CreateFrame("Frame", nil, button, "BackdropTemplate")
    bg:SetSize(BLIZZARD_ICON_BG_W, BLIZZARD_ICON_BG_H)
    bg:SetPoint("CENTER")
    bg:SetFrameLevel(button:GetFrameLevel())
    bg:SetBackdrop(iconBgBackdrop)
    bg:SetBackdropColor(0.5, 0.06, 0.06, 0.6)
    bg:SetBackdropBorderColor(0.5, 0.06, 0.06, 1)
    bg:Hide()
    button.themeBg = bg
    return bg
end

local BLIZZARD_GAP = 10
local GUDA_GAP = 4

-- Retail-style red close button texcoords (from redbutton2x atlas)
local CLOSE_TEXCOORDS = {
    normal   = {0.152344, 0.292969, 0.0078125, 0.304688},
    pushed   = {0.152344, 0.292969, 0.320312, 0.617188},
    highlight = {0.449219, 0.589844, 0.0078125, 0.304688},
}
local CLOSE_TEXTURE = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\redbutton2x"

local function StyleCloseButton(btn, useMetal)
    if useMetal then
        if not btn._metalStyled then
            -- Save original textures
            btn._origNormal = btn:GetNormalTexture()
            btn._origPushed = btn:GetPushedTexture()
            btn._origHighlight = btn:GetHighlightTexture()

            -- Hide original textures
            if btn._origNormal then btn._origNormal:SetAlpha(0) end
            if btn._origPushed then btn._origPushed:SetAlpha(0) end
            if btn._origHighlight then btn._origHighlight:SetAlpha(0) end

            -- Create retail-style textures
            local normal = btn:CreateTexture(nil, "BORDER")
            normal:SetTexture(CLOSE_TEXTURE)
            normal:SetAllPoints(btn)
            normal:SetTexCoord(unpack(CLOSE_TEXCOORDS.normal))
            btn:SetNormalTexture(normal)
            btn._metalNormal = normal

            local pushed = btn:CreateTexture(nil, "BORDER")
            pushed:SetTexture(CLOSE_TEXTURE)
            pushed:SetAllPoints(btn)
            pushed:SetTexCoord(unpack(CLOSE_TEXCOORDS.pushed))
            btn:SetPushedTexture(pushed)
            btn._metalPushed = pushed

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetTexture(CLOSE_TEXTURE)
            hl:SetAllPoints(btn)
            hl:SetTexCoord(unpack(CLOSE_TEXCOORDS.highlight))
            hl:SetBlendMode("ADD")
            btn:SetHighlightTexture(hl)
            btn._metalHighlight = hl

            btn._metalStyled = true
        end
        btn:SetSize(20, 20)
    elseif btn._metalStyled then
        -- Hide metal textures
        if btn._metalNormal then btn._metalNormal:SetAlpha(0) end
        if btn._metalPushed then btn._metalPushed:SetAlpha(0) end
        if btn._metalHighlight then btn._metalHighlight:SetAlpha(0) end

        -- Restore original textures
        if btn._origNormal then
            btn._origNormal:SetAlpha(1)
            btn:SetNormalTexture(btn._origNormal)
        end
        if btn._origPushed then
            btn._origPushed:SetAlpha(1)
            btn:SetPushedTexture(btn._origPushed)
        end
        if btn._origHighlight then
            btn._origHighlight:SetAlpha(1)
            btn:SetHighlightTexture(btn._origHighlight)
        end

        btn._metalStyled = false
    end
end

--- Public wrapper for StyleCloseButton
function Theme:StyleCloseButton(btn, useMetal)
    StyleCloseButton(btn, useMetal)
end

local METAL_ICON_SIZE = 13
local METAL_ICON_BG_W = 21
local METAL_ICON_BG_H = 17

local function StyleButton(btn, useBlizzard, useMetal)
    if useMetal then
        btn:SetSize(METAL_ICON_SIZE, METAL_ICON_SIZE)
        local bg = EnsureIconBg(btn)
        bg:SetSize(METAL_ICON_BG_W, METAL_ICON_BG_H)
        bg:SetBackdropColor(0.15, 0.12, 0.10, 0.6)
        bg:SetBackdropBorderColor(0.45, 0.40, 0.35, 1)
        bg:Show()
    elseif useBlizzard then
        btn:SetSize(BLIZZARD_ICON_SIZE, BLIZZARD_ICON_SIZE)
        local bg = EnsureIconBg(btn)
        bg:SetSize(BLIZZARD_ICON_BG_W, BLIZZARD_ICON_BG_H)
        bg:SetBackdropColor(0.5, 0.06, 0.06, 0.6)
        bg:SetBackdropBorderColor(0.5, 0.06, 0.06, 1)
        bg:Show()
    else
        btn:SetSize(GUDA_ICON_SIZE, GUDA_ICON_SIZE)
        if btn.themeBg then btn.themeBg:Hide() end
    end
end

--- Apply theme-appropriate styling and spacing to header icon buttons.
--- @param headerFrame table The title bar frame
--- @param leftButtons table Ordered array of left-side icon buttons (nil entries skipped)
--- @param rightButtons table Ordered array of right-side icon buttons after closeButton (nil entries skipped)
--- @param closeButton table The close button (anchor for right-side chain)
function Theme:ApplyHeaderButtons(headerFrame, leftButtons, rightButtons, closeButton)
    local useBlizzard = self:GetValue("useBlizzardFrame")
    local useMetal = self:GetValue("useMetalFrame")
    local gap = (useBlizzard or useMetal) and BLIZZARD_GAP or GUDA_GAP
    local firstLeftOffset = (useBlizzard or useMetal) and 13 or 4

    -- Style close button for metal theme
    if closeButton then
        StyleCloseButton(closeButton, useMetal)
    end

    -- Left side: first anchors to headerFrame LEFT, rest chain to previous
    local prevBtn = nil
    for _, btn in ipairs(leftButtons) do
        if btn then
            StyleButton(btn, useBlizzard, useMetal)
            btn:ClearAllPoints()
            if prevBtn then
                btn:SetPoint("LEFT", prevBtn, "RIGHT", gap, 0)
            else
                btn:SetPoint("LEFT", headerFrame, "LEFT", firstLeftOffset, 0)
            end
            prevBtn = btn
        end
    end

    -- Right side: chain from closeButton leftward
    prevBtn = closeButton
    for _, btn in ipairs(rightButtons) do
        if btn then
            StyleButton(btn, useBlizzard, useMetal)
            btn:ClearAllPoints()
            btn:SetPoint("RIGHT", prevBtn, "LEFT", -gap, 0)
            prevBtn = btn
        end
    end
end

-------------------------------------------------
-- Cache Invalidation
-------------------------------------------------
Events:Register("SETTING_CHANGED", function(event, key)
    if key == "theme" then
        cachedTheme = nil
    end
end, Theme)
