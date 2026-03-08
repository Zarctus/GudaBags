local addonName, ns = ...

local BankHeader = {}
ns:RegisterModule("BankFrame.BankHeader", BankHeader)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local IconButton = ns:GetModule("IconButton")
local ItemButton = ns:GetModule("ItemButton")
local Theme = ns:GetModule("Theme")

local frame = nil
local onDragStop = nil
local viewingCharacterData = nil

local BankCharacters = nil

-- Debounce for sort/restack button
local lastSortTime = 0
local SORT_DEBOUNCE = 0.5  -- 500ms debounce

local function LoadComponents()
    BankCharacters = ns:GetModule("BankFrame.BankCharacters")
end

local function CreateHeader(parent)
    local titleBar = CreateFrame("Frame", "GudaBankHeader", parent, "BackdropTemplate")
    titleBar:SetHeight(Constants.FRAME.TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    titleBar:SetScript("OnMouseDown", function(self, button)
        -- Raise parent frame above other bag/bank frames when clicked
        parent:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(parent)
        if parent.container then
            ItemButton:SyncFrameLevels(parent.container)
        end
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            -- Also lower BagFrame's secure container (it's parented to UIParent, not BagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
    end)

    titleBar:SetScript("OnDragStart", function()
        if not Database:GetSetting("locked") then
            parent:StartMoving()
        end
    end)

    titleBar:SetScript("OnDragStop", function()
        parent:StopMovingOrSizing()
        if onDragStop then
            onDragStop()
        end
    end)

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local headerBackdrop = Theme:GetValue("headerBackdrop")
    if headerBackdrop then
        titleBar:SetBackdrop(headerBackdrop)
        local headerBg = Theme:GetValue("headerBg")
        titleBar:SetBackdropColor(headerBg[1], headerBg[2], headerBg[3], bgAlpha)
    else
        titleBar:SetBackdrop(nil)
    end

    local lastLeftButton = nil

    if Constants.FEATURES.CHARACTERS then
        local charactersButton = IconButton:Create(titleBar, "characters", {
            tooltip = L["TOOLTIP_CHARACTERS_BANK"],
            onClick = function(self)
                BankCharacters:Toggle(self)
            end,
        })
        charactersButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        titleBar.charactersButton = charactersButton
        lastLeftButton = charactersButton
    end

    local playerName = UnitName("player")
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(playerName .. L["TITLE_BANK"])
    title:SetTextColor(1, 0.82, 0)
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 1)
    titleBar.title = title

    local closeButton = IconButton:CreateCloseButton(titleBar, {
        onClick = function()
            parent:Hide()
        end,
        point = "RIGHT",
        offsetX = 0,
        offsetY = 0,
    })
    titleBar.closeButton = closeButton
    local lastRightButton = closeButton

    local settingsButton = IconButton:Create(titleBar, "settings", {
        tooltip = L["TOOLTIP_SETTINGS"],
        onClick = function()
            local SettingsPopup = ns:GetModule("SettingsPopup")
            SettingsPopup:Toggle()
        end,
    })
    settingsButton:SetPoint("RIGHT", lastRightButton, "LEFT", -4, 0)
    titleBar.settingsButton = settingsButton
    lastRightButton = settingsButton

    if Constants.FEATURES.SORT then
        local sortButton = IconButton:Create(titleBar, "sort", {
            onClick = function()
                -- Debounce protection
                local now = GetTime()
                if now - lastSortTime < SORT_DEBOUNCE then
                    return
                end
                lastSortTime = now

                local BankFrameModule = ns:GetModule("BankFrame")
                local viewType = Database:GetSetting("bankViewType") or "single"

                if viewType == "category" then
                    BankFrameModule:RestackAndClean()
                else
                    BankFrameModule:SortBank()
                end
            end,
        })
        -- Dynamic tooltip based on view type
        sortButton:SetScript("OnEnter", function(self)
            local viewType = Database:GetSetting("bankViewType") or "single"
            local tooltip = viewType == "category" and L["TOOLTIP_RESTACK_CLEAN"] or L["TOOLTIP_SORT_BANK"]
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(tooltip)
            GameTooltip:Show()
        end)
        sortButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        sortButton:SetPoint("RIGHT", lastRightButton, "LEFT", -4, 0)
        titleBar.sortButton = sortButton
        lastRightButton = sortButton
    end

    return titleBar
end

function BankHeader:Init(parent)
    LoadComponents()
    frame = CreateHeader(parent)
    return frame
end

function BankHeader:GetFrame()
    return frame
end

function BankHeader:SetDragCallback(callback)
    onDragStop = callback
end

function BankHeader:SetBackdropAlpha(alpha)
    if not frame then return end
    local headerBackdrop = Theme:GetValue("headerBackdrop")
    if headerBackdrop then
        frame:SetBackdrop(headerBackdrop)
        local headerBg = Theme:GetValue("headerBg")
        frame:SetBackdropColor(headerBg[1], headerBg[2], headerBg[3], alpha)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", frame:GetParent(), "TOPLEFT", 4, -4)
        frame:SetPoint("TOPRIGHT", frame:GetParent(), "TOPRIGHT", -4, -4)
        if frame.closeButton then frame.closeButton:SetSize(22, 22) end
    else
        frame:SetBackdrop(nil)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", frame:GetParent(), "TOPLEFT", 0, 1)
        frame:SetPoint("TOPRIGHT", frame:GetParent(), "TOPRIGHT", 4, 0)
        local closeSize = ns.IsRetail and 22 or 32
        if frame.closeButton then frame.closeButton:SetSize(closeSize, closeSize) end
        -- Raise header above blizzardBg's NineSlice or metalFrame overlay
        local parent = frame:GetParent()
        if parent.blizzardBg or parent.metalFrame then
            frame:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.HEADER)
        end
    end
    Theme:ApplyHeaderButtons(
        frame,
        {frame.charactersButton},
        {frame.settingsButton, frame.sortButton},
        frame.closeButton
    )
end

function BankHeader:SetViewingCharacter(fullName, charData)
    viewingCharacterData = charData
    if not frame or not frame.title then return end

    if charData then
        local classColor = RAID_CLASS_COLORS[charData.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end
        frame.title:SetText(charData.name .. L["TITLE_BANK"])
        frame.title:SetTextColor(r, g, b)
    else
        local playerName = UnitName("player")
        frame.title:SetText(playerName .. L["TITLE_BANK"])
        frame.title:SetTextColor(1, 0.82, 0)
    end
end

function BankHeader:GetCharactersButton()
    if frame then
        return frame.charactersButton
    end
    return nil
end

function BankHeader:IsViewingOther()
    return viewingCharacterData ~= nil
end

function BankHeader:SetCharacterCallback(callback)
    if BankCharacters then
        BankCharacters:SetCallback(callback)
    end
end

function BankHeader:SetSortEnabled(enabled)
    if frame and frame.sortButton then
        if enabled then
            frame.sortButton:Enable()
            frame.sortButton:SetAlpha(1)
        else
            frame.sortButton:Disable()
            frame.sortButton:SetAlpha(0.4)
        end
    end
end
