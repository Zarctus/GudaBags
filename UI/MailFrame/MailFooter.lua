local addonName, ns = ...

local MailFooter = {}
ns:RegisterModule("MailFrame.MailFooter", MailFooter)

local Constants = ns.Constants
local L = ns.L

local frame = nil
local backButton = nil
local onBackCallback = nil

local Money = nil
local Database = nil

local function LoadComponents()
    Money = ns:GetModule("Footer.Money")
    Database = ns:GetModule("Database")
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12|t"

local function FormatMoney(amount)
    if not amount or amount == 0 then return "" end

    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)
    local copper = amount % 100

    local result = ""
    if gold > 0 then
        result = string.format("%d%s", gold, GOLD_ICON)
    end
    if silver > 0 then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", silver, SILVER_ICON)
    end
    if copper > 0 or result == "" then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", copper, COPPER_ICON)
    end
    return result
end

function MailFooter:Init(parent)
    LoadComponents()

    frame = CreateFrame("Frame", "GudaMailFooter", parent)
    frame:SetHeight(Constants.FRAME.FOOTER_HEIGHT)
    frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", Constants.FRAME.PADDING, Constants.FRAME.PADDING - 2)
    frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -Constants.FRAME.PADDING, Constants.FRAME.PADDING - 2)

    -- Left side: mail count text
    local countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", frame, "LEFT", 0, 0)
    countText:SetTextColor(0.8, 0.8, 0.8)
    countText:SetShadowOffset(1, -1)
    countText:SetShadowColor(0, 0, 0, 1)
    frame.countText = countText

    -- Right side: total attached gold
    local moneyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    moneyText:SetTextColor(1, 0.82, 0)
    moneyText:SetShadowOffset(1, -1)
    moneyText:SetShadowColor(0, 0, 0, 1)
    frame.moneyText = moneyText

    -- Back button (hidden by default, shown when viewing other character)
    backButton = CreateFrame("Button", "GudaMailBackButton", frame)
    backButton:SetSize(60, 18)
    backButton:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local backText = backButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    backText:SetPoint("LEFT", backButton, "LEFT", 0, 0)
    backText:SetText(L["BACK_BUTTON"])
    backText:SetTextColor(0.6, 0.8, 1)
    backButton.text = backText

    backButton:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
    end)
    backButton:SetScript("OnLeave", function(self)
        self.text:SetTextColor(0.6, 0.8, 1)
    end)
    backButton:SetScript("OnClick", function()
        if onBackCallback then
            onBackCallback()
        end
    end)
    backButton:Hide()

    return frame
end

function MailFooter:Show()
    if not frame then return end
    frame:Show()
    if backButton then
        backButton:Hide()
    end
end

function MailFooter:Hide()
    if not frame then return end
    frame:Hide()
    if backButton then
        backButton:Hide()
    end
end

function MailFooter:Update(mailData)
    if not frame then return end

    mailData = mailData or {}

    -- Count items and mails
    local itemCount = 0
    local mailIndices = {}
    local totalMoney = 0

    for _, row in ipairs(mailData) do
        if row.hasItem then
            itemCount = itemCount + 1
        end
        mailIndices[row.mailIndex] = true
        totalMoney = totalMoney + (row.money or 0)
    end

    local mailCount = 0
    for _ in pairs(mailIndices) do
        mailCount = mailCount + 1
    end

    frame.countText:SetText(string.format(L["MAIL_ITEMS_COUNT"], itemCount, mailCount))

    if totalMoney > 0 then
        frame.moneyText:SetText(FormatMoney(totalMoney))
    else
        frame.moneyText:SetText("")
    end
end

function MailFooter:ShowBackButton()
    if backButton then
        backButton:Show()
        -- Shift count text to right of back button
        if frame and frame.countText then
            frame.countText:ClearAllPoints()
            frame.countText:SetPoint("LEFT", backButton, "RIGHT", 8, 0)
        end
    end
end

function MailFooter:HideBackButton()
    if backButton then
        backButton:Hide()
        -- Reset count text position
        if frame and frame.countText then
            frame.countText:ClearAllPoints()
            frame.countText:SetPoint("LEFT", frame, "LEFT", 0, 0)
        end
    end
end

function MailFooter:SetBackCallback(callback)
    onBackCallback = callback
end

function MailFooter:GetFrame()
    return frame
end
