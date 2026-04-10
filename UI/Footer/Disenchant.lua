local addonName, ns = ...

-- Standalone Disenchant footer button for Enchanters.
-- FULLY DECOUPLED from Footer.lua and BagFrame.lua to avoid taint.
-- This module manages its own lifecycle via a throttled OnUpdate that polls
-- GudaBagsBagFrame:IsShown() (read-only, no hooks on the bag frame).
-- Footer.lua never references this module.

local DISENCHANT_SPELL_ID = 13262

local Constants = ns.Constants
local L = ns.L

local button = nil
local eventFrame = CreateFrame("Frame")
local isButtonShown = false
local pendingVisible = nil  -- true/false when deferred during combat
local POLL_INTERVAL = 0.1   -- check bag frame visibility 10x/sec
local elapsed = 0

-- Create the secure button (called once on PLAYER_LOGIN)
local function CreateButton()
    local Theme = ns:GetModule("Theme")

    button = CreateFrame("Button", "GudaBagsDisenchantButton", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(Constants.BAG_SLOT_SIZE, Constants.BAG_SLOT_SIZE)
    button:SetFrameStrata("DIALOG")
    button:SetFrameLevel(10)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown")

    -- All secure attributes set ONCE — never again
    button:SetAttribute("type", "macro")
    local spellName = C_Spell.GetSpellName(DISENCHANT_SPELL_ID)
    button:SetAttribute("macrotext", "/cast " .. (spellName or "Disenchant"))

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")
    button:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
    button:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\Spell_Holy_RemoveCurse")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["FOOTER_DISENCHANT"] or "Disenchant")
        GameTooltip:AddLine(L["FOOTER_DISENCHANT_TOOLTIP"] or "Click to cast Disenchant", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:Hide()
end

-- Position button using absolute coords relative to UIParent.
-- NEVER anchor to bag frame elements — that makes the bag frame protected during combat.
local function PositionButton()
    if not button then return end
    local footer = _G["GudaBagsFooter"]
    if not footer or not footer.slotInfoFrame then return end

    local slotInfo = footer.slotInfoFrame
    local right = slotInfo:GetRight()
    local _, centerY = slotInfo:GetCenter()
    if not right or not centerY then return end

    local halfSize = Constants.BAG_SLOT_SIZE / 2
    -- On Retail there's no keyring button, so shift 1 button left to fill the gap
    local offset = ns.IsRetail and -(Constants.BAG_SLOT_SIZE) or 0
    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "BOTTOMLEFT", right + halfSize + 1 + offset, centerY)
end

-- Show/hide the button — only called from our own OnUpdate context
local function ShowButton()
    if isButtonShown then return end
    if InCombatLockdown() then
        pendingVisible = true
        return
    end
    PositionButton()
    button:Show()
    isButtonShown = true
end

local function HideButton()
    if not isButtonShown then return end
    if InCombatLockdown() then
        pendingVisible = false
        return
    end
    button:Hide()
    isButtonShown = false
end

-- Throttled OnUpdate: polls bag frame visibility in our OWN execution context.
-- No hooks on the bag frame = no taint propagation.
local function OnUpdate(self, dt)
    elapsed = elapsed + dt
    if elapsed < POLL_INTERVAL then return end
    elapsed = 0

    if not button then return end

    local bagFrame = _G["GudaBagsBagFrame"]
    if bagFrame and bagFrame:IsShown() then
        ShowButton()
    else
        HideButton()
    end
end

-- Event handling
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- Only create for enchanters
        if not IsSpellKnown(DISENCHANT_SPELL_ID) then
            self:UnregisterAllEvents()
            return
        end

        CreateButton()

        -- Start polling bag frame visibility
        self:SetScript("OnUpdate", OnUpdate)

        -- Handle combat end for deferred show/hide
        self:RegisterEvent("PLAYER_REGEN_ENABLED")

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingVisible == true then
            pendingVisible = nil
            ShowButton()
        elseif pendingVisible == false then
            pendingVisible = nil
            HideButton()
        end
    end
end)
