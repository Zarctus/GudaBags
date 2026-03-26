local addonName, ns = ...

local Money = {}
ns:RegisterModule("Footer.Money", Money)

local Utils = ns:GetModule("Utils")

local Database = ns:GetModule("Database")

local moneyFrame = nil

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:10|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:10|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:10|t"

local function FormatMoney(amount)
    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)
    local copper = amount % 100

    local result = ""
    if gold > 0 then
        result = string.format("%d %s ", gold, GOLD_ICON)
    end
    if silver > 0 or gold > 0 then
        result = result .. string.format("%d %s ", silver, SILVER_ICON)
    end
    result = result .. string.format("%d %s", copper, COPPER_ICON)
    return result
end

local TOOLTIP_FONT_SIZE = 11

local function SetTooltipSmallFont()
    local fontName, _, fontFlags = GameFontNormal:GetFont()
    for i = 1, GameTooltip:NumLines() do
        local leftText = _G["GameTooltipTextLeft" .. i]
        local rightText = _G["GameTooltipTextRight" .. i]
        if leftText then
            leftText:SetFont(fontName, TOOLTIP_FONT_SIZE, fontFlags)
        end
        if rightText then
            rightText:SetFont(fontName, TOOLTIP_FONT_SIZE, fontFlags)
        end
    end
end

local L = ns.L

local function AddCharacterLine(char)
    local classColor = RAID_CLASS_COLORS[char.class]
    local colorR, colorG, colorB = 0.7, 0.7, 0.7
    if classColor then
        colorR, colorG, colorB = classColor.r, classColor.g, classColor.b
    end
    local raceIcon = Utils:GetRaceIcon(char.race, char.sex)
    local name = raceIcon .. " " .. char.name
    GameTooltip:AddDoubleLine(name, FormatMoney(char.money), colorR, colorG, colorB, 1, 1, 1)
end

local function ShowMoneyTooltip(frame)
    if not frame then return end

    GameTooltip:SetOwner(frame, "ANCHOR_TOPRIGHT", 0, frame:GetHeight() + 4)
    GameTooltip:ClearLines()

    local allRealms = Database:GetSetting("goldTrackAllRealms")

    if allRealms then
        -- Cross-realm view: group by realm with subtotals
        local chars = Database:GetAllCharacters(false, false)
        local totalMoney = 0
        for _, c in ipairs(chars) do totalMoney = totalMoney + c.money end

        GameTooltip:AddDoubleLine(L["TOOLTIP_ACCOUNT_GOLD"], FormatMoney(totalMoney), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine(" ")

        -- Group characters by realm
        local realms = {}
        local realmOrder = {}
        for _, char in ipairs(chars) do
            local realm = char.realm
            if not realms[realm] then
                realms[realm] = { chars = {}, total = 0 }
                table.insert(realmOrder, realm)
            end
            table.insert(realms[realm].chars, char)
            realms[realm].total = realms[realm].total + char.money
        end
        table.sort(realmOrder)

        for i, realm in ipairs(realmOrder) do
            local realmData = realms[realm]
            if i > 1 then GameTooltip:AddLine(" ") end
            GameTooltip:AddDoubleLine(realm, FormatMoney(realmData.total), 0.6, 0.6, 0.6, 1, 1, 1)
            for _, char in ipairs(realmData.chars) do
                AddCharacterLine(char)
            end
        end
    else
        -- Same-realm view (original behavior)
        local chars = Database:GetAllCharacters(false, true)
        local totalMoney = Database:GetTotalMoney(false, true)

        GameTooltip:AddDoubleLine(L["TOOLTIP_REALM_GOLD"], FormatMoney(totalMoney), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine(" ")

        for _, char in ipairs(chars) do
            AddCharacterLine(char)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["TOOLTIP_RIGHT_CLICK_GOLD"], 0.5, 0.5, 0.5)

    SetTooltipSmallFont()
    GameTooltip:Show()
end

-- Right-click dropdown menu for gold options
local goldDropdown = CreateFrame("Frame", "GudaBagsGoldDropdown", UIParent, "UIDropDownMenuTemplate")
goldDropdown.displayMode = "MENU"

-- Click-away overlay to close dropdown when clicking outside
local clickAwayOverlay = CreateFrame("Button", nil, UIParent)
clickAwayOverlay:SetAllPoints(UIParent)
clickAwayOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
clickAwayOverlay:EnableMouse(true)
clickAwayOverlay:RegisterForClicks("AnyUp")
clickAwayOverlay:Hide()
clickAwayOverlay:SetScript("OnClick", function()
    CloseDropDownMenus()
    clickAwayOverlay:Hide()
end)

goldDropdown:HookScript("OnHide", function()
    clickAwayOverlay:Hide()
end)

local function ShowGoldMenu(frame)
    UIDropDownMenu_Initialize(goldDropdown, function(self, level)
        level = level or 1
        if level == 1 then
            -- Toggle: Track all realms
            local info = UIDropDownMenu_CreateInfo()
            info.text = L["GOLD_TRACK_ALL_REALMS"]
            info.isNotRadio = true
            info.keepShownOnClick = true
            info.checked = Database:GetSetting("goldTrackAllRealms")
            info.func = function()
                Database:SetSetting("goldTrackAllRealms", not Database:GetSetting("goldTrackAllRealms"))
                ShowMoneyTooltip(frame)
            end
            UIDropDownMenu_AddButton(info, level)

            -- Submenu: Exclude characters
            info = UIDropDownMenu_CreateInfo()
            info.text = L["GOLD_EXCLUDE_CHARACTER"]
            info.hasArrow = true
            info.notCheckable = true
            info.value = "blacklist"
            UIDropDownMenu_AddButton(info, level)
        elseif level == 2 then
            -- Character blacklist submenu
            local allChars = Database:GetAllCharacters(false, false, true)  -- skipBlacklist=true to show all
            for _, char in ipairs(allChars) do
                local info = UIDropDownMenu_CreateInfo()
                local classColor = RAID_CLASS_COLORS[char.class]
                if classColor then
                    info.text = classColor:WrapTextInColorCode(char.name .. " - " .. char.realm)
                else
                    info.text = char.name .. " - " .. char.realm
                end
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = not Database:IsGoldBlacklisted(char.fullName)
                info.func = function()
                    Database:ToggleGoldBlacklist(char.fullName)
                    ShowMoneyTooltip(frame)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, goldDropdown, frame, 0, frame:GetHeight())
    clickAwayOverlay:Show()
    clickAwayOverlay:SetFrameLevel(goldDropdown:GetFrameLevel() - 1)
end

local function CloseGoldMenu()
    if UIDROPDOWNMENU_OPEN_MENU == goldDropdown then
        CloseDropDownMenus()
    end
end

local moneyFrameCount = 0
local ICON_SIZE = 11
local FONT_SIZE = 14

function Money:Init(parent)
    moneyFrameCount = moneyFrameCount + 1
    local frameName = "GudaBagsMoneyFrame" .. moneyFrameCount

    moneyFrame = CreateFrame("Frame", frameName, parent, "SmallMoneyFrameTemplate")
    moneyFrame:SetPoint("RIGHT", parent, "RIGHT", 14, 0)
    moneyFrame.frameName = frameName
    moneyFrame:EnableMouse(true)

    moneyFrame:SetScript("OnEnter", function(self)
        ShowMoneyTooltip(self)
    end)

    moneyFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    moneyFrame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ShowGoldMenu(self)
        end
    end)

    -- Set absolute sizes for money frame icons and font
    local coinButtons = {"GoldButton", "SilverButton", "CopperButton"}
    for _, buttonName in ipairs(coinButtons) do
        local coinButton = _G[frameName .. buttonName]
        if coinButton then
            coinButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            coinButton:SetScript("OnEnter", function(self)
                ShowMoneyTooltip(self:GetParent())
            end)
            coinButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            coinButton:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    ShowGoldMenu(self:GetParent())
                end
            end)

            -- Set absolute icon size
            local icon = _G[frameName .. buttonName .. "Texture"]
            if icon then
                icon:SetSize(ICON_SIZE, ICON_SIZE)
            end

            -- Set absolute font size
            local text = coinButton:GetFontString()
            if text then
                local fontName, _, fontFlags = text:GetFont()
                text:SetFont(fontName, FONT_SIZE, fontFlags)
            end
        end
    end

    return moneyFrame
end

function Money:Show()
    if moneyFrame then
        moneyFrame:Show()
    end
end

function Money:Hide()
    CloseGoldMenu()
    if moneyFrame then
        moneyFrame:Hide()
    end
end

function Money:Update()
    if not moneyFrame then return end
    local money = GetMoney()
    MoneyFrame_Update(moneyFrame.frameName, money)
end

function Money:GetFrame()
    return moneyFrame
end

function Money:UpdateCached(characterFullName)
    if not moneyFrame then return end
    local money = Database:GetMoney(characterFullName)
    MoneyFrame_Update(moneyFrame.frameName, money)
end

-- Update with Warband bank money (Retail only)
function Money:UpdateWarband()
    if not moneyFrame then return end
    local money = 0
    -- Try different APIs to get Warband bank money
    if C_Bank then
        -- Try FetchDepositedMoney first
        if C_Bank.FetchDepositedMoney then
            money = C_Bank.FetchDepositedMoney(Enum.BankType.Account) or 0
            ns:Debug("Warband money via FetchDepositedMoney:", money)
        end
        -- Try GetBankMoney if available
        if money == 0 and C_Bank.GetBankMoney then
            money = C_Bank.GetBankMoney(Enum.BankType.Account) or 0
            ns:Debug("Warband money via GetBankMoney:", money)
        end
    end
    -- Try AccountBankPanel if available (Blizzard's UI)
    if money == 0 and AccountBankPanel then
        if AccountBankPanel.GetMoney then
            money = AccountBankPanel:GetMoney() or 0
            ns:Debug("Warband money via AccountBankPanel:GetMoney:", money)
        elseif AccountBankPanel.money then
            money = AccountBankPanel.money or 0
            ns:Debug("Warband money via AccountBankPanel.money:", money)
        end
    end
    -- Try C_CurrencyInfo for warbound gold
    if money == 0 and C_CurrencyInfo and C_CurrencyInfo.GetWarModeRewardBonus then
        -- This is a fallback - may not be the right API
    end
    ns:Debug("UpdateWarband called, final money:", money, "frameName:", moneyFrame.frameName)
    MoneyFrame_Update(moneyFrame.frameName, money)
    ns:Debug("MoneyFrame_Update called for Warband")
end

-- Get current Warband bank money amount
function Money:GetWarbandMoney()
    if C_Bank then
        if C_Bank.FetchDepositedMoney then
            local money = C_Bank.FetchDepositedMoney(Enum.BankType.Account)
            if money and money > 0 then return money end
        end
        if C_Bank.GetBankMoney then
            local money = C_Bank.GetBankMoney(Enum.BankType.Account)
            if money and money > 0 then return money end
        end
    end
    return 0
end
