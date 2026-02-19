local addonName, ns = ...

local MailFrame = {}
ns:RegisterModule("MailFrame", MailFrame)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Theme = ns:GetModule("Theme")

local MailHeader = nil
local MailFooter = nil
local MailScanner = nil

local frame = nil
local viewingCharacter = nil
local mailRows = {}  -- Pre-created row frames
local currentMailData = {}  -- Currently displayed data

local ROW_HEIGHT = 44
local ICON_SIZE = 36
local MAX_VISIBLE_ROWS = 12

-------------------------------------------------
-- Lazy Load Components
-------------------------------------------------

local function LoadComponents()
    MailHeader = ns:GetModule("MailFrame.MailHeader")
    MailFooter = ns:GetModule("MailFrame.MailFooter")
    MailScanner = ns:GetModule("MailScanner")
end

-------------------------------------------------
-- Frame Position
-------------------------------------------------

local function SaveFramePosition()
    if not frame then return end

    local point, _, relativePoint, x, y = frame:GetPoint()
    Database:SetSetting("mailFramePoint", point)
    Database:SetSetting("mailFrameRelativePoint", relativePoint)
    Database:SetSetting("mailFrameX", x)
    Database:SetSetting("mailFrameY", y)
end

local function RestoreFramePosition()
    if not frame then return end

    local point = Database:GetSetting("mailFramePoint")
    local relativePoint = Database:GetSetting("mailFrameRelativePoint")
    local x = Database:GetSetting("mailFrameX")
    local y = Database:GetSetting("mailFrameY")

    if point and relativePoint and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    end
end

-------------------------------------------------
-- Frame Appearance
-------------------------------------------------

local function UpdateFrameAppearance()
    if not frame then return end

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")

    -- Apply theme background (ButtonFrameTemplate for Blizzard, backdrop for Guda)
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)

    if MailHeader then
        MailHeader:SetBackdropAlpha(bgAlpha)
    end
end

-------------------------------------------------
-- Mail Row UI
-------------------------------------------------

local function FormatDaysLeft(daysLeft)
    if not daysLeft then return "" end

    if daysLeft < 1 then
        local hours = math.floor(daysLeft * 24)
        if hours < 1 then hours = 1 end
        return string.format(L["MAIL_EXPIRES_HOURS"], hours)
    end

    return string.format(L["MAIL_EXPIRES_DAYS"], math.floor(daysLeft))
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12|t"

local function FormatMoneyShort(amount)
    if not amount or amount == 0 then return "" end

    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)

    local result = ""
    if gold > 0 then
        result = string.format("%d%s", gold, GOLD_ICON)
    end
    if silver > 0 then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", silver, SILVER_ICON)
    end
    return result
end

local function CreateMailRow(parent, index)
    local row = CreateFrame("Button", "GudaMailRow" .. index, parent)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)

    -- Background (alternating)
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.bg = bg

    -- Highlight
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0.08)

    -- Icon (left)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon = icon

    -- Quality border around icon
    local iconBorder = row:CreateTexture(nil, "OVERLAY")
    iconBorder:SetSize(ICON_SIZE + 2, ICON_SIZE + 2)
    iconBorder:SetPoint("CENTER", icon, "CENTER", 0, 0)
    iconBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
    iconBorder:Hide()
    row.iconBorder = iconBorder

    -- Item name / subject (top-left, after icon)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2)
    nameText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    -- Sender / count (bottom-left, after icon)
    local senderText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    senderText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 2)
    senderText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    senderText:SetJustifyH("LEFT")
    senderText:SetWordWrap(false)
    senderText:SetTextColor(0.7, 0.7, 0.7)
    row.senderText = senderText

    -- Expiration (top-right)
    local expiryText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expiryText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
    expiryText:SetJustifyH("RIGHT")
    row.expiryText = expiryText

    -- Money (bottom-right)
    local moneyText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyText:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 6)
    moneyText:SetJustifyH("RIGHT")
    moneyText:SetTextColor(1, 0.82, 0)
    row.moneyText = moneyText

    -- Tooltip on hover
    row:SetScript("OnEnter", function(self)
        if self.mailData and self.mailData.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.mailData.link)
            GameTooltip:Show()
        elseif self.mailData and self.mailData.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.mailData.itemID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row:Hide()
    return row
end

local function UpdateMailRow(row, data, index)
    if not data then
        row:Hide()
        return
    end

    -- Alternating background
    if index % 2 == 0 then
        row.bg:SetVertexColor(0.12, 0.12, 0.12, 0.5)
    else
        row.bg:SetVertexColor(0.08, 0.08, 0.08, 0.5)
    end

    row.mailData = data

    if data.hasItem then
        -- Item row
        row.icon:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.icon:Show()

        -- Quality border
        if data.quality and data.quality > 1 then
            local colors = Constants.QUALITY_COLORS[data.quality]
            if colors then
                row.iconBorder:SetVertexColor(colors[1], colors[2], colors[3], 0.8)
                row.iconBorder:Show()
            else
                row.iconBorder:Hide()
            end
        else
            row.iconBorder:Hide()
        end

        -- Item name (quality colored)
        local name = data.name or data.subject or ""
        if data.count and data.count > 1 then
            name = name .. " x" .. data.count
        end
        local colors = Constants.QUALITY_COLORS[data.quality or 0]
        if colors then
            row.nameText:SetTextColor(colors[1], colors[2], colors[3])
        else
            row.nameText:SetTextColor(1, 1, 1)
        end
        row.nameText:SetText(name)
    else
        -- Money-only or empty mail
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        row.icon:Show()
        row.iconBorder:Hide()

        row.nameText:SetText(data.subject or L["MAIL_MONEY_ONLY"])
        row.nameText:SetTextColor(1, 0.82, 0)
    end

    -- Sender
    row.senderText:SetText(data.sender or "")

    -- Expiration
    local daysLeft = data.daysLeft or 0
    local expiryStr = FormatDaysLeft(daysLeft)
    if daysLeft < 3 then
        row.expiryText:SetTextColor(1, 0.2, 0.2)
    elseif daysLeft < 7 then
        row.expiryText:SetTextColor(1, 0.82, 0)
    else
        row.expiryText:SetTextColor(0.6, 0.6, 0.6)
    end
    row.expiryText:SetText(expiryStr)

    -- Money
    if data.money and data.money > 0 then
        row.moneyText:SetText(FormatMoneyShort(data.money))
    else
        row.moneyText:SetText("")
    end

    row:Show()
end

-------------------------------------------------
-- Frame Creation
-------------------------------------------------

local function CreateMailFrame()
    LoadComponents()

    local f = CreateFrame("Frame", "GudaMailFrame", UIParent, "BackdropTemplate")
    f:SetSize(420, 400)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- Raise frame when clicked
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(self)

        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                local ItemButton = ns:GetModule("ItemButton")
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
    end)

    -- Initial backdrop (will be properly set by UpdateFrameAppearance)
    local backdrop = Theme:GetValue("backdrop")
    if backdrop then
        f:SetBackdrop(backdrop)
        local bgAlpha = Database:GetSetting("bgAlpha") / 100
        local bg = Theme:GetValue("frameBg")
        f:SetBackdropColor(bg[1], bg[2], bg[3], bgAlpha)
        local border = Theme:GetValue("frameBorder")
        f:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    end
    f:Hide()

    -- Register for Escape key
    tinsert(UISpecialFrames, "GudaMailFrame")

    -- Reset viewing character on hide
    f:SetScript("OnHide", function()
        if viewingCharacter then
            viewingCharacter = nil
            MailHeader:SetViewingCharacter(nil, nil)
        end
        local MailCharactersModule = ns:GetModule("MailFrame.MailCharacters")
        if MailCharactersModule then
            MailCharactersModule:Hide()
        end
    end)

    -- Header
    f.titleBar = MailHeader:Init(f)
    MailHeader:SetDragCallback(SaveFramePosition)
    MailHeader:SetCharacterCallback(function(fullName, charData)
        MailFrame:ViewCharacter(fullName, charData)
    end)

    -- Search bar
    local SearchBar = ns:GetModule("SearchBar")
    local searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        MailFrame:Refresh()
    end)
    f.searchBar = searchBar

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "GudaMailScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + Constants.FRAME.PADDING + 6))
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING - 20, Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
    f.scrollFrame = scrollFrame

    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() .. "ScrollBar"]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    -- Container (scroll child)
    local container = CreateFrame("Frame", "GudaMailContainer", scrollFrame)
    container:SetSize(1, 1)
    scrollFrame:SetScrollChild(container)
    f.container = container

    -- Pre-create row frames
    local containerWidth = 420 - Constants.FRAME.PADDING * 2 - 20
    for i = 1, MAX_VISIBLE_ROWS * 2 do  -- Pre-create enough for scrolling
        local row = CreateMailRow(container, i)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:SetPoint("RIGHT", container, "RIGHT", 0, 0)
        table.insert(mailRows, row)
    end

    -- Empty state message
    local emptyMessage = CreateFrame("Frame", nil, f)
    emptyMessage:SetAllPoints(scrollFrame)
    emptyMessage:Hide()

    local emptyText = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", emptyMessage, "CENTER", 0, 10)
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:SetText(L["MAIL_NO_DATA"])
    emptyMessage.text = emptyText

    f.emptyMessage = emptyMessage

    -- Footer
    f.footer = MailFooter:Init(f)
    MailFooter:SetBackCallback(function()
        MailFrame:ViewCharacter(nil, nil)
    end)

    return f
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function MailFrame:GetFrame()
    return frame
end

function MailFrame:GetViewingCharacter()
    return viewingCharacter
end

function MailFrame:Toggle()
    if not frame then
        frame = CreateMailFrame()
        RestoreFramePosition()
        UpdateFrameAppearance()
    end

    if frame:IsShown() then
        frame:Hide()
    else
        self:Show()
    end
end

function MailFrame:Show()
    if not frame then
        frame = CreateMailFrame()
        RestoreFramePosition()
        UpdateFrameAppearance()
    end

    frame:Show()
    MailFooter:Show()
    self:Refresh()
end

function MailFrame:Hide()
    if frame then
        frame:Hide()
    end
end

function MailFrame:Refresh()
    if not frame or not frame:IsShown() then return end

    -- Get mail data
    local mailData
    if viewingCharacter then
        mailData = Database:GetMailbox(viewingCharacter)
    else
        if MailScanner then
            mailData = MailScanner:GetCachedMail()
        else
            mailData = Database:GetMailbox()
        end
    end

    if not mailData then mailData = {} end

    -- Apply search filter
    local SearchBar = ns:GetModule("SearchBar")
    local searchText = SearchBar and SearchBar:GetSearchText(frame) or ""
    searchText = searchText:lower()

    local filteredData = {}
    if searchText == "" then
        filteredData = mailData
    else
        for _, row in ipairs(mailData) do
            local match = false
            if row.name and row.name:lower():find(searchText, 1, true) then
                match = true
            elseif row.sender and row.sender:lower():find(searchText, 1, true) then
                match = true
            elseif row.subject and row.subject:lower():find(searchText, 1, true) then
                match = true
            end
            if match then
                table.insert(filteredData, row)
            end
        end
    end

    currentMailData = filteredData

    -- Show/hide empty state
    if #filteredData == 0 then
        frame.emptyMessage:Show()
        if viewingCharacter then
            frame.emptyMessage.text:SetText(L["MAIL_NO_DATA"])
        elseif #mailData == 0 then
            frame.emptyMessage.text:SetText(L["MAIL_NO_DATA"])
        else
            frame.emptyMessage.text:SetText(L["SEARCH_PLACEHOLDER"])
        end
    else
        frame.emptyMessage:Hide()
    end

    -- Ensure enough row frames
    while #mailRows < #filteredData do
        local i = #mailRows + 1
        local row = CreateMailRow(frame.container, i)
        row:SetPoint("TOPLEFT", frame.container, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:SetPoint("RIGHT", frame.container, "RIGHT", 0, 0)
        table.insert(mailRows, row)
    end

    -- Update rows
    for i, row in ipairs(mailRows) do
        if i <= #filteredData then
            UpdateMailRow(row, filteredData[i], i)
        else
            row:Hide()
        end
    end

    -- Resize container for scrolling
    local contentHeight = #filteredData * ROW_HEIGHT
    frame.container:SetHeight(math.max(contentHeight, 1))
    local containerWidth = frame.scrollFrame:GetWidth()
    frame.container:SetWidth(containerWidth > 0 and containerWidth or 380)

    -- Update footer
    MailFooter:Update(filteredData)

    -- Update back button
    if viewingCharacter then
        MailFooter:ShowBackButton()
    else
        MailFooter:HideBackButton()
    end
end

function MailFrame:ViewCharacter(fullName, charData)
    viewingCharacter = fullName

    if MailHeader then
        MailHeader:SetViewingCharacter(fullName, charData)
    end

    self:Refresh()
end

-------------------------------------------------
-- Mail Updated Callback
-------------------------------------------------

ns.OnMailUpdated = function()
    if frame and frame:IsShown() and not viewingCharacter then
        MailFrame:Refresh()
    end
end

-------------------------------------------------
-- Settings Changed
-------------------------------------------------

Events:Register("SETTING_CHANGED", function(event, key, value)
    if not frame then return end

    if key == "bgAlpha" or key == "showBorders" or key == "theme" then
        UpdateFrameAppearance()
    end
end, MailFrame)
