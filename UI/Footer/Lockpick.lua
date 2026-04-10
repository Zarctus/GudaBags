local addonName, ns = ...

-- Standalone Pick Lock footer button for Rogues.
-- FULLY DECOUPLED from Footer.lua and BagFrame.lua to avoid taint.
-- Same architecture as Disenchant.lua — see that file for design rationale.

local _, playerClass = UnitClass("player")
if playerClass ~= "ROGUE" then return end

local PICK_LOCK_SPELL_ID = 1804

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

    button = CreateFrame("Button", "GudaBagsLockpickButton", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(Constants.BAG_SLOT_SIZE, Constants.BAG_SLOT_SIZE)
    button:SetFrameStrata("DIALOG")
    button:SetFrameLevel(10)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown")

    button:SetAttribute("type", "macro")
    local spellName = C_Spell.GetSpellName(PICK_LOCK_SPELL_ID)
    button:SetAttribute("macrotext", "/cast " .. (spellName or "Pick Lock"))

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
    icon:SetTexture("Interface\\Icons\\INV_Misc_Key_03")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["FOOTER_PICKLOCK"] or "Pick Lock")
        GameTooltip:AddLine(L["FOOTER_PICKLOCK_TOOLTIP"] or "Click to cast Pick Lock", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:Hide()
end

-- Position after the disenchant button if visible, otherwise after slotInfo
local function PositionButton()
    if not button then return end
    local footer = _G["GudaBagsFooter"]
    if not footer or not footer.slotInfoFrame then return end

    local slotInfo = footer.slotInfoFrame
    local right = slotInfo:GetRight()
    local _, centerY = slotInfo:GetCenter()
    if not right or not centerY then return end

    local halfSize = Constants.BAG_SLOT_SIZE / 2
    local offset = ns.IsRetail and -(Constants.BAG_SLOT_SIZE) or 0

    -- If disenchant button is visible, position after it
    local deButton = _G["GudaBagsDisenchantButton"]
    if deButton and deButton:IsShown() then
        local deRight = deButton:GetRight()
        if deRight then
            right = deRight
            offset = 0  -- already accounted for by disenchant position
        end
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "BOTTOMLEFT", right + halfSize + 1 + offset, centerY)
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
        if not IsSpellKnown(PICK_LOCK_SPELL_ID) then
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
