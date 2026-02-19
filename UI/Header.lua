local addonName, ns = ...

local Header = {}
ns:RegisterModule("Header", Header)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local IconButton = ns:GetModule("IconButton")
local ItemButton = ns:GetModule("ItemButton")
local Theme = ns:GetModule("Theme")

local frame = nil
local onDragStop = nil
local viewingCharacterData = nil

local Characters = nil
local BankCharacters = nil

-- Debounce for sort/restack button
local lastSortTime = 0
local SORT_DEBOUNCE = 0.5  -- 500ms debounce

local function LoadComponents()
    Characters = ns:GetModule("Header.Characters")
    if Constants.FEATURES.BANK then
        BankCharacters = ns:GetModule("BankFrame.BankCharacters")
    end
end

local function CreateHeader(parent)
    local titleBar = CreateFrame("Frame", "GudaBagsHeader", parent, "BackdropTemplate")
    titleBar:SetHeight(Constants.FRAME.TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    titleBar:SetScript("OnMouseDown", function(self, button)
        -- Raise parent frame above other bag/bank frames when clicked
        -- BUT keep secure container above the frame backdrop
        parent:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(parent)
        if parent.container then
            parent.container:SetFrameLevel(Constants.FRAME_LEVELS.RAISED + Constants.FRAME_LEVELS.CONTAINER)
            ItemButton:SyncFrameLevels(parent.container)
        end

        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() and BankFrameModule:GetFrame() ~= parent then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                bankFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() and BagFrameModule:GetFrame() ~= parent then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
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

    -- Ensure container stays above frame backdrop when mouse enters header
    titleBar:SetScript("OnEnter", function()
        if parent.container then
            parent.container:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.CONTAINER)
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

    -- Left side icons (use feature flags to show/hide)
    local lastLeftButton = nil

    if Constants.FEATURES.CHARACTERS then
        local charactersButton = IconButton:Create(titleBar, "characters", {
            tooltip = L["TOOLTIP_CHARACTERS"],
            onClick = function(self)
                Characters:Toggle(self)
            end,
        })
        charactersButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        titleBar.charactersButton = charactersButton
        lastLeftButton = charactersButton
    end

    if Constants.FEATURES.BANK then
        local chestButton = IconButton:Create(titleBar, "chest", {
            tooltip = L["TOOLTIP_BANK"],
            onClick = function(self)
                -- Close guild bank if open
                local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
                local wasGuildBankOpen = GuildBankFrameModule and GuildBankFrameModule:GetFrame() and GuildBankFrameModule:GetFrame():IsShown()
                if wasGuildBankOpen then
                    GuildBankFrameModule:Hide()
                end
                if wasGuildBankOpen then
                    C_Timer.After(0, function()
                        BankCharacters:Toggle(self)
                    end)
                else
                    BankCharacters:Toggle(self)
                end
            end,
        })
        if lastLeftButton then
            chestButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            chestButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.chestButton = chestButton
        lastLeftButton = chestButton
    end

    if Constants.FEATURES.GUILD_BANK and IsInGuild() then
        local guildButton = IconButton:Create(titleBar, "guild", {
            tooltip = L["TOOLTIP_GUILD_BANK"],
            onClick = function()
                -- Close bank view if open
                local BankFrameModule = ns:GetModule("BankFrame")
                local wasBankOpen = BankFrameModule and BankFrameModule:GetFrame() and BankFrameModule:GetFrame():IsShown()
                if wasBankOpen then
                    BankFrameModule:Hide()
                end
                -- Close bank characters dropdown if open
                if BankCharacters then
                    BankCharacters:Hide()
                end
                local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
                if GuildBankFrameModule then
                    if wasBankOpen then
                        -- Defer to next frame to avoid script timeout from pool churn
                        C_Timer.After(0, function()
                            GuildBankFrameModule:Toggle()
                        end)
                    else
                        GuildBankFrameModule:Toggle()
                    end
                end
            end,
        })
        if lastLeftButton then
            guildButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            guildButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.guildButton = guildButton
        lastLeftButton = guildButton
    end

    if Constants.FEATURES.MAIL then
        local envelopeButton = IconButton:Create(titleBar, "envelope", {
            tooltip = L["TOOLTIP_MAIL"],
            onClick = function()
                local MailFrameModule = ns:GetModule("MailFrame")
                if MailFrameModule then
                    MailFrameModule:Toggle()
                end
            end,
        })
        if lastLeftButton then
            envelopeButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            envelopeButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.envelopeButton = envelopeButton
        lastLeftButton = envelopeButton
    end

    -- Center title with character name
    local playerName = UnitName("player")
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(playerName .. L["TITLE_BAGS"])
    title:SetTextColor(1, 0.82, 0)
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 1)
    titleBar.title = title

    -- Right side icons (created right-to-left for proper anchoring)
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
                if InCombatLockdown() then return end
                -- Debounce protection
                local now = GetTime()
                if now - lastSortTime < SORT_DEBOUNCE then
                    return
                end
                lastSortTime = now

                local BagFrameModule = ns:GetModule("BagFrame")
                local viewType = Database:GetSetting("bagViewType") or "single"

                if viewType == "category" then
                    BagFrameModule:RestackAndClean()
                else
                    BagFrameModule:SortBags()
                end
            end,
        })
        -- Dynamic tooltip based on view type
        sortButton:SetScript("OnEnter", function(self)
            local viewType = Database:GetSetting("bagViewType") or "single"
            local tooltip = viewType == "category" and L["TOOLTIP_RESTACK_CLEAN"] or L["TOOLTIP_SORT_BAGS"]
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

function Header:Init(parent)
    LoadComponents()
    frame = CreateHeader(parent)
    return frame
end

function Header:GetFrame()
    return frame
end

function Header:SetDragCallback(callback)
    onDragStop = callback
end

function Header:SetBackdropAlpha(alpha)
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
        -- Raise header above blizzardBg's NineSlice on retail
        local parent = frame:GetParent()
        if parent.blizzardBg then
            frame:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.HEADER)
        end
    end
    Theme:ApplyHeaderButtons(
        frame,
        {frame.charactersButton, frame.chestButton, frame.guildButton, frame.envelopeButton},
        {frame.settingsButton, frame.sortButton},
        frame.closeButton
    )
end

function Header:SetViewingCharacter(fullName, charData)
    viewingCharacterData = charData
    if not frame or not frame.title then return end

    if charData then
        -- Viewing another character
        local classColor = RAID_CLASS_COLORS[charData.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end
        frame.title:SetText(charData.name .. L["TITLE_BAGS"])
        frame.title:SetTextColor(r, g, b)
    else
        -- Back to current character
        local playerName = UnitName("player")
        frame.title:SetText(playerName .. L["TITLE_BAGS"])
        frame.title:SetTextColor(1, 0.82, 0)
    end
end

function Header:GetCharactersButton()
    if frame then
        return frame.charactersButton
    end
    return nil
end

function Header:IsViewingOther()
    return viewingCharacterData ~= nil
end

function Header:SetCharacterCallback(callback)
    if Characters then
        Characters:SetCallback(callback)
    end
end

function Header:SetBankCharacterCallback(callback)
    if BankCharacters then
        BankCharacters:SetCallback(callback)
    end
end
