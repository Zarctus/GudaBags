local addonName, ns = ...

-- Standalone Prospecting footer button for Jewelcrafters.
-- FULLY DECOUPLED from Footer.lua and BagFrame.lua to avoid taint.
-- Same architecture as Disenchant.lua — see that file for design rationale.

local PROSPECTING_SPELL_ID = 31252

local Constants = ns.Constants
local L = ns.L

local button = nil
local eventFrame = CreateFrame("Frame")
local isButtonShown = false
local pendingVisible = nil
local POLL_INTERVAL = 0.1
local elapsed = 0

local function CreateButton()
    local Theme = ns:GetModule("Theme")

    button = CreateFrame("Button", "GudaBagsProspectingButton", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(Constants.BAG_SLOT_SIZE, Constants.BAG_SLOT_SIZE)
    button:SetFrameStrata("DIALOG")
    button:SetFrameLevel(10)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown")

    button:SetAttribute("type", "macro")
    local spellName = C_Spell.GetSpellName(PROSPECTING_SPELL_ID)
    button:SetAttribute("macrotext", "/cast " .. (spellName or "Prospecting"))

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
    icon:SetSize(Constants.BAG_SLOT_SIZE - 2, Constants.BAG_SLOT_SIZE - 2)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_BloodGem_01")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["FOOTER_PROSPECTING"] or "Prospecting")
        GameTooltip:AddLine(L["FOOTER_PROSPECTING_TOOLTIP"] or "Click to cast Prospecting", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:Hide()
end

-- Position after the rightmost visible spell button, or after slotInfo
local function PositionButton()
    if not button then return end
    local footer = _G["GudaBagsFooter"]
    if not footer or not footer.slotInfoFrame then return end

    local slotInfo = footer.slotInfo or footer.slotInfoFrame
    local baseRight = slotInfo:GetRight()
    local _, centerY = footer.slotInfoFrame:GetCenter()
    if not baseRight or not centerY then return end

    local halfSize = Constants.BAG_SLOT_SIZE / 2

    -- Chain after the rightmost visible preceding button
    local buttons = { _G["GudaBagsLockpickButton"], _G["GudaBagsDisenchantButton"] }
    for _, btn in ipairs(buttons) do
        if btn and btn:IsShown() then
            local r = btn:GetRight()
            if r then baseRight = r; break end
        end
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "BOTTOMLEFT", baseRight + halfSize + 4, centerY)
end

local function ShowButton()
    if InCombatLockdown() then
        if not isButtonShown then pendingVisible = true end
        return
    end
    PositionButton()
    if not isButtonShown then
        button:Show()
        isButtonShown = true
    end
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

eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        if not IsSpellKnown(PROSPECTING_SPELL_ID) then
            self:UnregisterAllEvents()
            return
        end

        CreateButton()
        self:SetScript("OnUpdate", OnUpdate)
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
