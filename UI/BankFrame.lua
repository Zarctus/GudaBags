local addonName, ns = ...

local BankFrame = {}
ns:RegisterModule("BankFrame", BankFrame)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local BankScanner = ns:GetModule("BankScanner")
local ItemButton = ns:GetModule("ItemButton")
local SearchBar = ns:GetModule("SearchBar")
local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
local LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
local Utils = ns:GetModule("Utils")
local CategoryHeaderPool = ns:GetModule("CategoryHeaderPool")
local Theme = ns:GetModule("Theme")

local BankHeader = nil
local BankFooter = nil
local RetailBankScanner = nil

local frame
local searchBar
local itemButtons = {}
local categoryHeaders = {}
local viewingCharacter = nil

-- Combat lockdown handling
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
local pendingAction = nil  -- "show" or nil
local combatLockdownRegistered = false

-- Layout caching for incremental updates (same pattern as BagFrame)
local buttonsBySlot = {}  -- Key: "bagID:slot" -> button reference
local buttonsByBag = {}   -- Key: bagID -> { slot -> button } for fast bag-specific lookups
local cachedItemData = {} -- Key: "bagID:slot" -> previous itemID (for comparison)
local cachedItemCount = {} -- Key: "bagID:slot" -> previous count (for stack updates)
local cachedItemCategory = {} -- Key: "bagID:slot" -> previous categoryId (for category view)
local layoutCached = false -- True when layout is cached and can do incremental updates
local lastLayoutSettings = nil  -- Delta tracking for layout recalculation

-- Category View: Item-key-based button tracking
local buttonsByItemKey = {}
local categoryViewItems = {}
local lastCategoryLayout = nil
local lastButtonByCategory = {} -- Key: categoryId -> last item button (for drop indicator anchor)
local pseudoItemButtons = {} -- Track Empty/Soul pseudo-item buttons for proper release
                             -- Keys are "Empty:<categoryId>" or "Soul:<categoryId>" to avoid overwrites in merged groups
local lastTotalItemCount = 0 -- Track item count to detect Empty/Soul category changes

-- Helper to find a pseudo-item button by type (Empty or Soul)
local function FindPseudoItemButton(pseudoType)
    local prefix = pseudoType .. ":"
    for key, button in pairs(pseudoItemButtons) do
        if string.sub(key, 1, #prefix) == prefix then
            return button
        end
    end
    return nil
end

-- Use shared utility functions for key generation
local function GetItemKey(itemData)
    return Utils:GetItemKey(itemData)
end

local function GetSlotKey(bagID, slot)
    return Utils:GetSlotKey(bagID, slot)
end

-- Off-screen parent for Blizzard bank UI: must be SHOWN so that
-- BankFrame:IsShown() returns true when :Show() is called.
-- This lets the original GetActiveBankType() work without overriding it.
local offscreenParent = CreateFrame("Frame", nil, UIParent)
offscreenParent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, 10000)
offscreenParent:SetSize(1, 1)
offscreenParent:SetAlpha(0)
offscreenParent:Show()

-- Legacy hidden parent kept for non-Retail or fallback use
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local function LoadComponents()
    BankHeader = ns:GetModule("BankFrame.BankHeader")
    BankFooter = ns:GetModule("BankFrame.BankFooter")
    if ns.IsRetail then
        RetailBankScanner = ns:GetModule("RetailBankScanner")
    end
end

-------------------------------------------------
-- Category Header Pool (uses shared CategoryHeaderPool module)
-------------------------------------------------

local function AcquireCategoryHeader(parent)
    return CategoryHeaderPool:Acquire(parent)
end

local function ReleaseAllCategoryHeaders()
    if frame and frame.container then
        CategoryHeaderPool:ReleaseAll(frame.container)  -- Pass owner to release only this frame's headers
    end
    categoryHeaders = {}
end

-------------------------------------------------
-- Container Drop Handling (empty space acts as drop zone)
-------------------------------------------------

-- Handle drops on empty space in the bank container
function BankFrame:HandleContainerDrop()
    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then return end

    -- Determine which bank type we're viewing (character or warband)
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarband = currentBankType == "warband"

    -- Find an empty bank slot and place the item there
    -- Build bank bag list based on game version and bank type
    local bankBags = {}

    if isWarband and Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
        -- Warband bank tabs
        for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    elseif Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
        -- Modern Retail (12.0+) Character Bank Tabs
        for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    elseif Enum and Enum.BagIndex and Enum.BagIndex.Bank then
        -- Older Retail fallback
        table.insert(bankBags, Enum.BagIndex.Bank)
        if Enum.BagIndex.BankBag_1 then
            for i = Enum.BagIndex.BankBag_1, Enum.BagIndex.BankBag_7 do
                table.insert(bankBags, i)
            end
        end
    else
        -- Classic fallback
        if BANK_CONTAINER then
            table.insert(bankBags, BANK_CONTAINER)
        end
        if NUM_BANKBAGSLOTS then
            for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                table.insert(bankBags, i)
            end
        end
    end

    local placed = false
    for _, bagID in ipairs(bankBags) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if not itemInfo then
                    -- Empty slot found, place item here
                    C_Container.PickupContainerItem(bagID, slot)
                    placed = true
                    break
                end
            end
        end
        if placed then break end
    end

    -- If no empty slot found, just clear cursor
    if not placed then
        ClearCursor()
    end
end

local UpdateFrameAppearance
local RegisterCombatEndCallback

local function CreateBankFrame()
    local f = CreateFrame("Frame", "GudaBankFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- Raise frame above BagFrame when clicked
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(self)
        if self.container then
            ItemButton:SyncFrameLevels(self.container)
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

    -- Register for Escape key to close
    tinsert(UISpecialFrames, "GudaBankFrame")

    -- Close bank interaction and reset character when frame is hidden
    f:SetScript("OnHide", function()
        if ns.IsRetail then
            if C_PlayerInteractionManager and C_PlayerInteractionManager.ClearInteraction then
                C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.Banker)
            end
        else
            if CloseBankFrame then
                CloseBankFrame()
            end
        end
        -- Clear search bar text and filters
        SearchBar:Clear(f)
        -- Reset to current character when bank closes
        if viewingCharacter then
            viewingCharacter = nil
            BankHeader:SetViewingCharacter(nil, nil)
        end
        -- Close any open character dropdown
        local BankCharactersModule = ns:GetModule("BankFrame.BankCharacters")
        if BankCharactersModule then
            BankCharactersModule:Hide()
        end
    end)

    f.titleBar = BankHeader:Init(f)
    BankHeader:SetDragCallback(function() Database:SaveFramePosition(frame, "bankFrame") end)

    searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        BankFrame:Refresh()
    end)
    f.searchBar = searchBar

    -- Transfer button callbacks (bank → bags)
    SearchBar:SetTransferTargetCallback(f, function()
        return {type = "bags", label = ns.L["TRANSFER_TO_BAGS"]}
    end)

    SearchBar:SetTransferCallback(f, function()
        BankFrame:TransferMatchedItems()
    end)

    -- Create scroll frame for large bank contents
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBankScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + SearchBar:GetTotalHeight(f) + Constants.FRAME.PADDING + 6))
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING - 20, Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
    f.scrollFrame = scrollFrame

    -- Style the scroll bar
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() .. "ScrollBar"]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    -- Create container as scroll child
    local container = CreateFrame("Frame", "GudaBankContainer", scrollFrame)
    container:SetSize(1, 1)  -- Will be resized based on content
    scrollFrame:SetScrollChild(container)
    f.container = container

    -- Enable container as drop zone for empty space
    container:EnableMouse(true)

    container:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            BankFrame:HandleContainerDrop()
        end
    end)

    container:SetScript("OnReceiveDrag", function(self)
        BankFrame:HandleContainerDrop()
    end)

    local emptyMessage = CreateFrame("Frame", nil, f)
    emptyMessage:SetAllPoints(scrollFrame)
    emptyMessage:Hide()

    local emptyText = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", emptyMessage, "CENTER", 0, 10)
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:SetText(ns.L["BANK_NO_DATA"])
    emptyMessage.text = emptyText

    local emptyHint = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyHint:SetPoint("TOP", emptyText, "BOTTOM", 0, -8)
    emptyHint:SetTextColor(0.5, 0.5, 0.5)
    emptyHint:SetText(ns.L["BANK_VISIT_BANKER"])
    emptyMessage.hint = emptyHint

    f.emptyMessage = emptyMessage

    f.footer = BankFooter:Init(f)
    BankFooter:SetBackCallback(function()
        BankFrame:ViewCharacter(nil, nil)
    end)

    -- Set bank character callback (for characters dropdown in BankHeader)
    BankHeader:SetCharacterCallback(function(fullName, charData)
        if not BankFrame:IsShown() then
            BankFrame:Show()
        end
        BankFrame:ViewCharacter(fullName, charData)
    end)

    -- Create side tab bar for Retail bank tabs (vertical, on right side outside frame)
    if ns.IsRetail then
        local sideTabBar = CreateFrame("Frame", "GudaBankSideTabBar", f)
        sideTabBar:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, -55)
        sideTabBar:SetSize(32, 200)  -- Will resize based on tabs
        sideTabBar:Hide()  -- Hidden until tabs are shown
        f.sideTabBar = sideTabBar
        f.sideTabs = {}
    end

    -- Create bottom bank type tabs (Bank | Warband) - Retail only
    if ns.IsRetail and Constants.WARBAND_BANK_ACTIVE then
        f.bottomTabs = {}
        f.bottomTabBar = CreateFrame("Frame", "GudaBankBottomTabBar", f)
        f.bottomTabBar:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 8, 0)
        f.bottomTabBar:SetSize(200, 28)
        f.bottomTabBar:Hide()
    end

    return f
end

-------------------------------------------------
-- Side Tab Bar (Retail Bank Tabs - Vertical on Right)
-------------------------------------------------

local TAB_SIZE = 36
local TAB_SPACING = 2

local function CreateSideTab(parent, index, isAllTab)
    local button = CreateFrame("Button", "GudaBankSideTab" .. (isAllTab and "All" or index), parent, "BackdropTemplate")
    button:SetSize(TAB_SIZE, TAB_SIZE)
    button.tabIndex = isAllTab and 0 or index

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    button:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TAB_SIZE - 6, TAB_SIZE - 6)
    icon:SetPoint("CENTER")
    -- Use chest icon for "All" tab, default bag icon for specific tabs (will be updated with actual icon)
    if isAllTab then
        icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\chest.png")
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")  -- Default, will be updated by ShowSideTabs
    end
    button.icon = icon

    -- Tab number text (for non-All tabs)
    if not isAllTab then
        local numText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        numText:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
        numText:SetText(tostring(index))
        numText:SetTextColor(0.8, 0.8, 0.8)
        button.numText = numText
    end

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    -- Selection indicator
    local selected = button:CreateTexture(nil, "OVERLAY")
    selected:SetAllPoints()
    selected:SetColorTexture(1, 0.82, 0, 0.3)
    selected:Hide()
    button.selected = selected

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local scanner = ns:GetModule("RetailBankScanner")

        if self.tabIndex == 0 then
            -- "All Tabs" - show combined total
            GameTooltip:SetText(ns.L["TOOLTIP_BANK_ALL_TABS"] or "All Tabs")
            if scanner then
                local totalSlots, occupiedSlots = 0, 0
                local bankType = scanner:GetCurrentBankType()
                local tabs = scanner:GetBankTabs(bankType)
                if tabs then
                    for _, tab in ipairs(tabs) do
                        local containerID = scanner:GetTabContainerID(tab.tabIndex, bankType)
                        if containerID then
                            local numSlots = C_Container.GetContainerNumSlots(containerID)
                            totalSlots = totalSlots + numSlots
                            for slot = 1, numSlots do
                                local itemInfo = C_Container.GetContainerItemInfo(containerID, slot)
                                if itemInfo then
                                    occupiedSlots = occupiedSlots + 1
                                end
                            end
                        end
                    end
                end
                if totalSlots > 0 then
                    GameTooltip:AddLine(string.format("%d / %d", occupiedSlots, totalSlots), 0.7, 0.7, 0.7)
                end
            end
        else
            -- Specific tab - show that tab's slots
            if self.tabName then
                GameTooltip:SetText(self.tabName)
            else
                GameTooltip:SetText(string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", self.tabIndex))
            end
            if scanner then
                local containerID = scanner:GetTabContainerID(self.tabIndex)
                if containerID then
                    local numSlots = C_Container.GetContainerNumSlots(containerID)
                    local occupiedSlots = 0
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(containerID, slot)
                        if itemInfo then
                            occupiedSlots = occupiedSlots + 1
                        end
                    end
                    GameTooltip:AddLine(string.format("%d / %d", occupiedSlots, numSlots), 0.7, 0.7, 0.7)
                end
            end
        end
        GameTooltip:Show()

        -- Skip hover highlighting if a specific tab is already selected (not "All")
        local scanner = ns:GetModule("RetailBankScanner")
        local selectedTab = scanner and scanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, no need to highlight
        end

        -- Highlight items from this tab (only when viewing "All" tabs)
        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and scanner and frame and frame.container and self.tabIndex > 0 then
            -- Convert tab index to container ID for retail bank (uses scanner's current bank type)
            local containerID = scanner:GetTabContainerID(self.tabIndex)
            if containerID then
                ItemButton:HighlightBagSlots(containerID, frame.container)
            end
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()

        -- Reset item highlighting (only if we were highlighting)
        local scanner = ns:GetModule("RetailBankScanner")
        local selectedTab = scanner and scanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, nothing to reset
        end

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and frame and frame.container then
            ItemButton:ResetAllAlpha(frame.container)
        end
    end)

    button:SetScript("OnClick", function(self)
        if RetailBankScanner then
            local currentTab = RetailBankScanner:GetSelectedTab()
            if currentTab == self.tabIndex then
                -- Clicking same tab - do nothing or show all
                if self.tabIndex ~= 0 then
                    RetailBankScanner:SetSelectedTab(0)
                end
            else
                RetailBankScanner:SetSelectedTab(self.tabIndex)
            end
            BankFrame:UpdateSideTabSelection()
        end
    end)

    return button
end

-- Tab icons
local TAB_ICON_DEFAULT = "Interface\\Icons\\INV_Misc_Bag_10"  -- Default fallback icon

function BankFrame:ShowSideTabs(characterFullName, bankType)
    if not frame or not frame.sideTabBar then return end
    if not ns.IsRetail then return end

    -- Get bank type from footer if not specified
    bankType = bankType or (BankFooter and BankFooter:GetCurrentBankType()) or "character"
    local isWarband = bankType == "warband"

    ns:Debug("ShowSideTabs - bankType:", bankType, "isWarband:", tostring(isWarband))

    local tabs = {}

    -- Get the appropriate tab container IDs based on bank type
    local tabContainerIDs = isWarband and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
    local tabsActive = isWarband and Constants.WARBAND_BANK_ACTIVE or Constants.CHARACTER_BANK_TABS_ACTIVE

    ns:Debug("  tabContainerIDs count:", tabContainerIDs and #tabContainerIDs or 0)
    ns:Debug("  tabsActive:", tostring(tabsActive))

    -- Try to get cached tabs from RetailBankScanner first
    if RetailBankScanner then
        local bankTypeEnum = isWarband and Enum.BankType.Account or Enum.BankType.Character
        local cachedTabs = RetailBankScanner:GetCachedBankTabs(bankTypeEnum)
        if cachedTabs and #cachedTabs > 0 then
            for _, tabData in ipairs(cachedTabs) do
                table.insert(tabs, {
                    index = tabData.index,
                    containerID = tabData.containerID,
                    name = tabData.name or (isWarband and string.format("Warband Tab %d", tabData.index) or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", tabData.index)),
                    icon = tabData.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                })
            end
            ns:Debug("  Got", #tabs, "tabs from RetailBankScanner cache")
        end
    end

    -- Fallback: For character bank, try Database
    if #tabs == 0 and not isWarband then
        tabs = Database:GetBankTabs(characterFullName) or {}
    end

    -- Fallback: For warband bank, try Database
    if #tabs == 0 and isWarband then
        local warbandTabs = Database:GetWarbandBankTabs()
        if warbandTabs and #warbandTabs > 0 then
            for _, tabData in ipairs(warbandTabs) do
                table.insert(tabs, {
                    index = tabData.index,
                    containerID = tabData.containerID,
                    name = tabData.name or string.format("Warband Tab %d", tabData.index),
                    icon = tabData.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                })
            end
            ns:Debug("  Got", #tabs, "tabs from Database warband cache")
        end
    end

    -- Fallback: For warband bank, try C_Bank.FetchPurchasedBankTabData directly
    if #tabs == 0 and isWarband and C_Bank and C_Bank.FetchPurchasedBankTabData then
        -- Check if warband bank is accessible (not locked)
        local warbandLocked = C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(Enum.BankType.Account)
        ns:Debug("  Warband FetchBankLockedReason:", tostring(warbandLocked))
        if warbandLocked == nil then
            local tabData = C_Bank.FetchPurchasedBankTabData(Enum.BankType.Account)
            ns:Debug("  FetchPurchasedBankTabData returned:", tabData and #tabData or 0, "tabs")
            if tabData then
                for i, tab in ipairs(tabData) do
                    local containerID = Constants.WARBAND_BANK_TAB_IDS and Constants.WARBAND_BANK_TAB_IDS[i]
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = tab.name or string.format("Warband Tab %d", i),
                        icon = tab.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                    })
                end
                ns:Debug("  Got", #tabs, "tabs from C_Bank.FetchPurchasedBankTabData")
            end
        end
    end

    -- Fallback: Generate tabs based on which containers have data (live check)
    if #tabs == 0 and tabsActive and tabContainerIDs then
        for i, containerID in ipairs(tabContainerIDs) do
            -- Check if this container has slots (either from live data or cached)
            local numSlots = C_Container.GetContainerNumSlots(containerID)
            ns:Debug("  Container", containerID, "numSlots:", numSlots or 0)

            if numSlots and numSlots > 0 then
                table.insert(tabs, {
                    index = i,
                    containerID = containerID,
                    name = isWarband
                        and string.format("Warband Tab %d", i)
                        or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", i),
                    icon = TAB_ICON_DEFAULT,
                })
            end
        end
    end

    -- Fallback: check normalized bank data if no live data (character bank only)
    if #tabs == 0 and not isWarband then
        local bankData = Database:GetNormalizedBank(characterFullName)
        if bankData and tabContainerIDs then
            for i, containerID in ipairs(tabContainerIDs) do
                if bankData[containerID] and bankData[containerID].numSlots and bankData[containerID].numSlots > 0 then
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", i),
                        icon = TAB_ICON_DEFAULT,
                    })
                end
            end
        end
    end

    -- Fallback: check normalized warband bank data if no live data
    if #tabs == 0 and isWarband then
        local warbandData = Database:GetNormalizedWarbandBank()
        if warbandData and tabContainerIDs then
            for i, containerID in ipairs(tabContainerIDs) do
                if warbandData[containerID] and warbandData[containerID].numSlots and warbandData[containerID].numSlots > 0 then
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = string.format("Warband Tab %d", i),
                        icon = TAB_ICON_DEFAULT,
                    })
                end
            end
        end
    end

    ns:Debug("  Final tabs count:", #tabs)

    -- Default single tab if nothing found
    if not tabs or #tabs == 0 then
        tabs = {{
            index = 1,
            name = isWarband and "Warband Tab 1" or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", 1),
            icon = TAB_ICON_DEFAULT,
        }}
    end

    -- Hide side tabs if only 1 character bank tab (for warband, always show since we have at least "All" + tab)
    -- For character bank with 6 tabs, we show them; for warband with 1 tab, we still show "All" + that tab
    if #tabs <= 1 and not isWarband then
        frame.sideTabBar:Hide()
        return
    end

    -- Create "All" tab button first
    if not frame.sideTabs[0] then
        frame.sideTabs[0] = CreateSideTab(frame.sideTabBar, 0, true)
    end
    frame.sideTabs[0]:ClearAllPoints()
    frame.sideTabs[0]:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
    frame.sideTabs[0]:Show()

    local prevButton = frame.sideTabs[0]

    -- Create/update tab buttons
    for i, tabData in ipairs(tabs) do
        if not frame.sideTabs[i] then
            frame.sideTabs[i] = CreateSideTab(frame.sideTabBar, i, false)
        end

        local button = frame.sideTabs[i]
        button.tabIndex = i
        button.tabName = tabData.name
        if tabData.icon then
            button.icon:SetTexture(tabData.icon)
        end

        button:ClearAllPoints()
        button:SetPoint("TOP", prevButton, "BOTTOM", 0, -TAB_SPACING)
        button:Show()

        prevButton = button
    end

    -- Hide excess tabs
    for i = #tabs + 1, #frame.sideTabs do
        if frame.sideTabs[i] then
            frame.sideTabs[i]:Hide()
        end
    end

    -- Resize tab bar
    local totalHeight = (TAB_SIZE + TAB_SPACING) * (#tabs + 1)
    frame.sideTabBar:SetSize(TAB_SIZE, totalHeight)

    -- Reset selection to "All"
    if RetailBankScanner then
        RetailBankScanner:SetSelectedTab(0)
    end

    frame.sideTabBar:Show()
    self:UpdateSideTabSelection()
end

function BankFrame:HideSideTabs()
    if frame and frame.sideTabBar then
        frame.sideTabBar:Hide()
    end
end

function BankFrame:UpdateSideTabSelection()
    if not frame or not frame.sideTabs then return end

    local selectedTab = RetailBankScanner and RetailBankScanner:GetSelectedTab() or 0

    for i, button in pairs(frame.sideTabs) do
        if button and button:IsShown() then
            if i == selectedTab then
                button.selected:Show()
                button:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                button.selected:Hide()
                button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            end
        end
    end
end

-------------------------------------------------
-- Bottom Bank Type Tabs (Bank | Warband - Below Frame)
-------------------------------------------------

local BOTTOM_TAB_WIDTH = 100
local BOTTOM_TAB_HEIGHT = 32
local BOTTOM_TAB_SPACING = 2

local function CreateBottomBankTypeTab(parent, bankType, label)
    local button = CreateFrame("Button", "GudaBankBottomTab" .. bankType, parent, "BackdropTemplate")
    button:SetSize(BOTTOM_TAB_WIDTH, BOTTOM_TAB_HEIGHT)
    button.bankType = bankType

    -- Create rounded bottom corners using a custom backdrop
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 0, bottom = 3},
    })
    button:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Mask the top edge to blend with frame (create seamless connection)
    local topMask = button:CreateTexture(nil, "OVERLAY")
    topMask:SetPoint("TOPLEFT", button, "TOPLEFT", 1, 0)
    topMask:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, 0)
    topMask:SetHeight(3)
    topMask:SetColorTexture(0.08, 0.08, 0.08, 0.95)
    button.topMask = topMask

    -- Tab label
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, -1)
    text:SetText(label)
    text:SetTextColor(0.8, 0.8, 0.8)
    button.text = text

    -- Highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 2, -2)
    highlight:SetPoint("BOTTOMRIGHT", -2, 2)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.3)

    -- Selection indicator (bottom glow)
    local selected = button:CreateTexture(nil, "BACKGROUND")
    selected:SetPoint("TOPLEFT", 2, -2)
    selected:SetPoint("BOTTOMRIGHT", -2, 2)
    selected:SetColorTexture(1, 0.82, 0, 0.2)
    selected:Hide()
    button.selected = selected

    button:SetScript("OnClick", function(self)
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        if currentBankType ~= self.bankType then
            if BankFooter then
                BankFooter:SetCurrentBankType(self.bankType)
            end
            BankFrame:UpdateBottomTabSelection()
            -- Notify BankFrame to refresh with new bank type
            if ns.OnBankTypeChanged then
                ns.OnBankTypeChanged(self.bankType)
            end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if self.bankType == "character" then
            GameTooltip:SetText("Character Bank")
        else
            GameTooltip:SetText("Warband Bank")
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return button
end

function BankFrame:ShowBottomTabs()
    if not frame or not frame.bottomTabBar then return end
    if not ns.IsRetail or not Constants.WARBAND_BANK_ACTIVE then return end

    -- Create tabs if they don't exist
    if not frame.bottomTabs.character then
        frame.bottomTabs.character = CreateBottomBankTypeTab(frame.bottomTabBar, "character", "Bank")
        frame.bottomTabs.character:SetPoint("TOPLEFT", frame.bottomTabBar, "TOPLEFT", 0, 0)
    end

    if not frame.bottomTabs.warband then
        frame.bottomTabs.warband = CreateBottomBankTypeTab(frame.bottomTabBar, "warband", "Warband")
        frame.bottomTabs.warband:SetPoint("LEFT", frame.bottomTabs.character, "RIGHT", BOTTOM_TAB_SPACING, 0)
    end

    frame.bottomTabs.character:Show()
    frame.bottomTabs.warband:Show()
    frame.bottomTabBar:Show()

    self:UpdateBottomTabSelection()
end

function BankFrame:HideBottomTabs()
    if not frame or not frame.bottomTabBar then return end

    if frame.bottomTabs.character then
        frame.bottomTabs.character:Hide()
    end
    if frame.bottomTabs.warband then
        frame.bottomTabs.warband:Hide()
    end
    frame.bottomTabBar:Hide()
end

function BankFrame:UpdateBottomTabSelection()
    if not frame or not frame.bottomTabs then return end

    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for bankType, button in pairs(frame.bottomTabs) do
        if button then
            if bankType == currentBankType then
                button.selected:Show()
                button:SetBackdropBorderColor(1, 0.82, 0, 1)
                button:SetBackdropColor(0.08, 0.08, 0.08, bgAlpha)
                button.text:SetTextColor(1, 0.82, 0)
                button.topMask:SetColorTexture(0.08, 0.08, 0.08, bgAlpha)
            else
                button.selected:Hide()
                button:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                button:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
                button.text:SetTextColor(0.6, 0.6, 0.6)
                button.topMask:SetColorTexture(0.05, 0.05, 0.05, 0.9)
            end
        end
    end
end

local function HasBankData(bank)
    if not bank then return false end
    for bagID, bagData in pairs(bank) do
        if bagData.numSlots and bagData.numSlots > 0 then
            return true
        end
    end
    return false
end

-- Filter bank data to only show containers from a specific tab (Retail only)
-- In modern Retail (TWW+), each bank tab IS a separate container
-- tabIndex: 1-based tab index (0 = all tabs)
-- isWarbandView: optional, if true use warband tab IDs
function BankFrame:FilterBankByTab(bank, tabIndex, isWarbandView)
    if not bank or not tabIndex or tabIndex < 1 then
        return bank
    end

    -- Determine which tab IDs to use based on bank type
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarband = isWarbandView or (currentBankType == "warband")

    -- For modern Retail with container-based tabs (character or warband)
    if Constants.CHARACTER_BANK_TABS_ACTIVE or isWarband then
        local filtered = {}

        -- Get the container ID for this specific tab
        local tabContainerIDs = isWarband and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
        local tabContainerID = tabContainerIDs and tabContainerIDs[tabIndex]

        ns:Debug("FilterBankByTab: tabIndex=", tabIndex, "isWarband=", tostring(isWarband), "containerID=", tostring(tabContainerID))

        if not tabContainerID then
            return bank  -- No valid tab container, return all
        end

        -- Only include the container that matches this tab
        for bagID, bagData in pairs(bank) do
            if bagID == tabContainerID then
                filtered[bagID] = bagData
                ns:Debug("FilterBankByTab: found matching container", bagID)
            end
        end

        return filtered
    end

    -- Legacy Retail (pre-TWW): slot-range based filtering
    -- Each tab has 98 slots in the main bank container
    local SLOTS_PER_TAB = 98
    local startSlot = ((tabIndex - 1) * SLOTS_PER_TAB) + 1
    local endSlot = tabIndex * SLOTS_PER_TAB

    local filtered = {}

    for bagID, bagData in pairs(bank) do
        -- Only filter the main bank container (bagID -1 or Enum.BagIndex.Bank)
        local mainBankID = Enum and Enum.BagIndex and Enum.BagIndex.Bank or -1
        if bagID == mainBankID or bagID == -1 then
            local filteredBag = {
                bagID = bagData.bagID,
                numSlots = 0,
                freeSlots = 0,
                bagType = bagData.bagType,
                containerItemID = bagData.containerItemID,
                containerTexture = bagData.containerTexture,
                slots = {},
            }

            if bagData.slots then
                for slot, slotData in pairs(bagData.slots) do
                    if slot >= startSlot and slot <= endSlot then
                        local displaySlot = slot - startSlot + 1
                        filteredBag.slots[displaySlot] = slotData
                        filteredBag.numSlots = math.max(filteredBag.numSlots, displaySlot)
                    end
                end
            end

            filteredBag.numSlots = math.min(SLOTS_PER_TAB, (bagData.numSlots or 0) - startSlot + 1)
            if filteredBag.numSlots < 0 then filteredBag.numSlots = 0 end

            for slot = 1, filteredBag.numSlots do
                if not filteredBag.slots[slot] then
                    filteredBag.freeSlots = filteredBag.freeSlots + 1
                end
            end

            if filteredBag.numSlots > 0 then
                filtered[bagID] = filteredBag
            end
        else
            filtered[bagID] = bagData
        end
    end

    return filtered
end

function BankFrame:RefreshPinIcons()
    for _, button in pairs(buttonsBySlot) do
        ItemButton:UpdatePinIcon(button)
    end
end

function BankFrame:Refresh()
    if not frame then return end

    ItemButton:ReleaseAll(frame.container)
    ReleaseAllCategoryHeaders()
    itemButtons = {}

    -- Clear layout cache for full refresh
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil

    local isViewingCached = viewingCharacter ~= nil
    local isBankOpen = BankScanner:IsBankOpen()
    local bank
    local selectedTab = 0  -- 0 = all tabs

    -- Check if we're viewing warband bank (Retail only)
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"

    ns:Debug("Refresh - currentBankType:", currentBankType, "isWarbandView:", tostring(isWarbandView))

    if isWarbandView then
        -- Get warband bank data
        if RetailBankScanner then
            bank = RetailBankScanner:GetCachedBank(Enum.BankType.Account) or {}
            -- Normalize the cached data
            if bank then
                local normalized = {}
                for bagID, bagData in pairs(bank) do
                    normalized[bagID] = bagData
                end
                bank = normalized
            end
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
        -- Fallback to database
        if not bank or not next(bank) then
            bank = Database:GetNormalizedWarbandBank() or {}
        end
        ns:Debug("  Warband bank data bags:", bank and next(bank) and "has data" or "empty")
    elseif isViewingCached then
        bank = Database:GetNormalizedBank(viewingCharacter) or {}
        -- On Retail, get selected tab for filtering
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    elseif isBankOpen then
        bank = BankScanner:GetCachedBank()
        -- On Retail, get selected tab for filtering live bank
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    else
        bank = Database:GetNormalizedBank() or {}
        -- On Retail, get selected tab for filtering cached bank
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    end

    -- Filter bank data by selected tab (Retail only)
    if selectedTab > 0 and ns.IsRetail then
        bank = self:FilterBankByTab(bank, selectedTab, isWarbandView)
    end

    local hasBankData = isBankOpen or HasBankData(bank)

    if not hasBankData then
        frame.container:Hide()
        frame.emptyMessage:Show()

        if isViewingCached then
            frame.emptyMessage.text:SetText(ns.L["BANK_NO_DATA"])
            frame.emptyMessage.hint:SetText(ns.L["BANK_NOT_VISITED"])
        else
            frame.emptyMessage.text:SetText(ns.L["BANK_NO_DATA"])
            frame.emptyMessage.hint:SetText(ns.L["BANK_VISIT_BANKER"])
        end

        local columns = Database:GetSetting("bankColumns")
        local iconSize = Database:GetSetting("iconSize")
        local spacing = Database:GetSetting("iconSpacing")
        local minWidth = (iconSize * columns) + (Constants.FRAME.PADDING * 2)
        local minHeight = (6 * iconSize) + (5 * spacing) + 80

        frame:SetSize(math.max(minWidth, 250), minHeight)
        BankFooter:UpdateSlotInfo(0, 0)
        return
    end

    frame.emptyMessage:Hide()
    frame.container:Show()

    local iconSize = Database:GetSetting("iconSize")
    local spacing = Database:GetSetting("iconSpacing")
    local columns = Database:GetSetting("bankColumns")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local viewType = Database:GetSetting("bankViewType") or "single"

    -- Use appropriate bag IDs for classification
    local bagIDsToUse = isWarbandView and Constants.WARBAND_BANK_TAB_IDS or Constants.BANK_BAG_IDS
    local classifiedBags = BagClassifier:ClassifyBags(bank, isViewingCached or not isBankOpen, bagIDsToUse)
    local bagsToShow = LayoutEngine:BuildDisplayOrder(classifiedBags, false)

    local showSearchBar = Database:GetSetting("showSearchBar")
    local showFilterChips = Database:GetSetting("showFilterChips")
    local showFooterSetting = Database:GetSetting("showFooter")
    local showFooter = showFooterSetting or isViewingCached or not isBankOpen
    local showCategoryCount = Database:GetSetting("showCategoryCount")
    local isReadOnly = isViewingCached or not isBankOpen
    local splitColumns = Database:GetSetting("splitBankColumns") or 2

    local settings = {
        columns = columns,
        iconSize = iconSize,
        spacing = spacing,
        showSearchBar = showSearchBar,
        showFilterChips = showFilterChips,
        showFooter = showFooter,
        showCategoryCount = showCategoryCount,
        splitColumns = splitColumns,
    }

    if viewType == "category" then
        self:RefreshCategoryView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    elseif viewType == "split" then
        self:RefreshSplitView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    else
        self:RefreshSingleView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    end

    if isViewingCached or not isBankOpen then
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bank) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        BankFooter:UpdateSlotInfo(usedSlots, totalSlots)
    elseif isWarbandView then
        -- Warband bank - calculate slots from bank data
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bank) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        BankFooter:UpdateSlotInfo(usedSlots, totalSlots)
    else
        local totalSlots, freeSlots = BankScanner:GetTotalSlots()
        local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
        BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    end

    if isBankOpen and not isViewingCached then
        BankFooter:Update()
    end
end

function BankFrame:RefreshSingleView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local columns = settings.columns

    -- Check if we should show tab sections (Retail bank with multiple tabs, viewing "All")
    local selectedTab = RetailBankScanner and RetailBankScanner:GetSelectedTab() or 0
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"
    local showTabSections = ns.IsRetail and selectedTab == 0 and (Constants.CHARACTER_BANK_TABS_ACTIVE or isWarbandView)

    -- Get tab info for headers
    local tabContainerIDs = isWarbandView and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
    local cachedTabs = nil
    if showTabSections and RetailBankScanner then
        local bankTypeEnum = isWarbandView and Enum.BankType.Account or Enum.BankType.Character
        cachedTabs = RetailBankScanner:GetCachedBankTabs(bankTypeEnum)
    end

    if showTabSections and tabContainerIDs and #tabContainerIDs > 1 then
        -- Render with tab sections
        self:RefreshSingleViewWithTabs(bank, settings, hasSearch, isReadOnly, tabContainerIDs, cachedTabs, isWarbandView)
        return
    end

    -- Standard single view (no tab sections)
    -- On Retail, use unified order (sequential by bag ID) to match native sort behavior
    -- This ensures profession materials don't appear after junk from regular bags
    local unifiedOrder = ns.IsRetail and not isReadOnly
    local allSlots = LayoutEngine:CollectAllSlots(bagsToShow, bank, isReadOnly, unifiedOrder)

    -- Calculate content dimensions accounting for needsSpacing (soul bags, etc. start new rows)
    local numSlots = #allSlots
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))

    -- Count actual rows including spacing breaks (same logic as CalculateButtonPositions)
    local totalRows = 0
    local sectionCount = 0
    local col = 0
    for _, slotInfo in ipairs(allSlots) do
        if slotInfo.needsSpacing then
            if col > 0 then
                totalRows = totalRows + 1  -- Complete the partial row
                col = 0
            end
            sectionCount = sectionCount + 1
        end
        col = col + 1
        if col >= columns then
            col = 0
            totalRows = totalRows + 1
        end
    end
    if col > 0 then
        totalRows = totalRows + 1  -- Final partial row
    end
    if totalRows < 1 then totalRows = 1 end

    local actualContentHeight = (iconSize * totalRows) + (spacing * math.max(0, totalRows - 1)) + (Constants.SECTION_SPACING * sectionCount)

    -- Calculate frame chrome heights (must match scroll frame positioning in UpdateFrameAppearance)
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    -- Top offset: same as scroll frame SetPoint TOPLEFT
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    -- Bottom offset: same as scroll frame SetPoint BOTTOMRIGHT
    -- Footer is at PADDING-2 from bottom with height FOOTER_HEIGHT, so top is at (PADDING-2)+FOOTER_HEIGHT
    -- Add extra padding (10) above footer for clearance
    local bottomOffset = showFooter
        and (Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    -- Calculate frame dimensions
    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeightNeeded = actualContentHeight + chromeHeight

    -- Apply minimum height (2 rows of icons + spacing + chrome)
    local minFrameHeight = (2 * iconSize) + (1 * spacing) + chromeHeight
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = actualContentHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container size to match actual content
    frame.container:SetSize(contentWidth, math.max(actualContentHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() .. "ScrollBar"]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    local positions = LayoutEngine:CalculateButtonPositions(allSlots, settings)

    for i, slotInfo in ipairs(allSlots) do
        local button = ItemButton:Acquire(frame.container)
        local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

        if slotInfo.itemData then
            ItemButton:SetItem(button, slotInfo.itemData, iconSize, isReadOnly)
            if hasSearch then
                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
            else
                ItemButton:ClearSearchState(button)
            end
            -- Cache item data for incremental updates
            cachedItemData[slotKey] = slotInfo.itemData.itemID
            cachedItemCount[slotKey] = slotInfo.itemData.count
        else
            ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isReadOnly)
            if hasSearch then
                ItemButton:SetSearchState(button, false)
            else
                ItemButton:ClearSearchState(button)
            end
            cachedItemData[slotKey] = nil
            cachedItemCount[slotKey] = nil
        end

        local pos = positions[i]
        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", pos.x, pos.y)

        -- Store button by slot key for incremental updates
        buttonsBySlot[slotKey] = button
        table.insert(itemButtons, button)

        -- Store by bagID for fast bag-specific lookups
        local bagID = slotInfo.bagID
        if not buttonsByBag[bagID] then
            buttonsByBag[bagID] = {}
        end
        buttonsByBag[bagID][slotInfo.slot] = button
    end

    layoutCached = true
end

function BankFrame:RefreshSplitView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local layout = LayoutEngine:BuildSplitViewLayout(bagsToShow, bank, settings, isReadOnly)

    -- Calculate chrome heights for scroll frame positioning
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    local bottomOffset = showFooter
        and (Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    local contentWidth = layout.contentWidth
    local containerHeight = layout.contentHeight

    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeightNeeded = containerHeight + chromeHeight
    local minFrameHeight = (2 * iconSize) + (1 * spacing) + chromeHeight
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)
    local scrollAreaHeight = actualFrameHeight - chromeHeight
    local needsScroll = containerHeight > scrollAreaHeight + 5

    frame:SetSize(frameWidth, actualFrameHeight)

    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING, bottomOffset)
    frame.container:SetSize(contentWidth, math.max(containerHeight, 1))

    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() .. "ScrollBar"]
    if needsScroll then
        if scrollBar then
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -topOffset - 16)
            scrollBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, bottomOffset + 16)
            scrollBar:Show()
        end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    for _, section in ipairs(layout.sections) do
        -- Create header with bag icon + name
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(section.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", section.x, section.headerY)

        if section.displayInfo.icon then
            header.icon:SetTexture(section.displayInfo.icon)
            header.icon:SetSize(12, 12)
            header.icon:Show()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header.icon, "RIGHT", 4, 0)
        else
            header.icon:Hide()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
        end
        header.text:SetText(section.displayInfo.name or "")

        local fontFile = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_SMALL, "")
        else
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_LARGE, "")
        end

        header.line:Show()
        header:EnableMouse(false)
        table.insert(categoryHeaders, header)

        -- Render item slots for this bag
        local bagID = section.bagID
        local bagData = bank[bagID]
        local sectionColumns = section.columns
        local numSlots = section.numSlots

        for slot = 1, numSlots do
            local itemData = bagData and bagData.slots and bagData.slots[slot]
            local button = ItemButton:Acquire(frame.container)
            local slotKey = bagID .. ":" .. slot

            if itemData then
                ItemButton:SetItem(button, itemData, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = itemData.itemID
                cachedItemCount[slotKey] = itemData.count
            else
                ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, false)
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = nil
                cachedItemCount[slotKey] = nil
            end

            local col = (slot - 1) % sectionColumns
            local row = math.floor((slot - 1) / sectionColumns)
            local x = section.x + col * (iconSize + spacing)
            local y = section.slotsStartY - (row * (iconSize + spacing))

            button.wrapper:ClearAllPoints()
            button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, y)

            buttonsBySlot[slotKey] = button
            table.insert(itemButtons, button)

            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][slot] = button
        end
    end

    layoutCached = true
end

-- Render single view with tab sections (headers and spacing between tabs)
function BankFrame:RefreshSingleViewWithTabs(bank, settings, hasSearch, isReadOnly, tabContainerIDs, cachedTabs, isWarbandView)
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local columns = settings.columns

    local TAB_HEADER_HEIGHT = 18
    local TAB_SECTION_SPACING = 12

    -- Collect slots grouped by tab
    local tabSections = {}
    for tabIndex, containerID in ipairs(tabContainerIDs) do
        local bagData = bank[containerID]
        if bagData and bagData.numSlots and bagData.numSlots > 0 then
            local slots = {}
            for slot = 1, bagData.numSlots do
                local itemData = bagData.slots and bagData.slots[slot]
                table.insert(slots, {
                    bagID = containerID,
                    slot = slot,
                    itemData = itemData,
                })
            end

            -- Get tab name
            local tabName = string.format("Tab %d", tabIndex)
            if cachedTabs and cachedTabs[tabIndex] then
                tabName = cachedTabs[tabIndex].name or tabName
            elseif isWarbandView then
                tabName = string.format("Warband Tab %d", tabIndex)
            end

            table.insert(tabSections, {
                tabIndex = tabIndex,
                containerID = containerID,
                name = tabName,
                slots = slots,
            })
        end
    end

    -- Calculate layout
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local currentY = 0
    local tabLayouts = {}

    for _, section in ipairs(tabSections) do
        local numSlots = #section.slots
        local rows = math.ceil(numSlots / columns)
        local sectionHeight = TAB_HEADER_HEIGHT + (rows * (iconSize + spacing))

        table.insert(tabLayouts, {
            section = section,
            y = currentY,
            headerY = currentY,
            slotsStartY = currentY - TAB_HEADER_HEIGHT,
            rows = rows,
        })

        currentY = currentY - sectionHeight - TAB_SECTION_SPACING
    end

    local containerHeight = -currentY
    local frameWidth = contentWidth + Constants.FRAME.PADDING * 2

    -- Calculate chrome heights (must match scroll frame positioning)
    -- For tab sections view, search bar and footer are always shown
    local showFilterChips = settings.showFilterChips
    local chipHeight = showFilterChips and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6
    local bottomOffset = Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset
    local frameHeightNeeded = containerHeight + chromeHeight

    -- Apply minimum height (2 rows of icons + spacing + chrome)
    local minFrameHeight = (2 * iconSize) + (1 * spacing) + chromeHeight
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = containerHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container size
    frame.container:SetSize(contentWidth, math.max(containerHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() .. "ScrollBar"]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    -- Render tab sections
    for _, layout in ipairs(tabLayouts) do
        local section = layout.section

        -- Create tab header
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(contentWidth)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", 0, layout.headerY)

        -- Style the header
        header.icon:Hide()
        header.text:ClearAllPoints()
        header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
        header.text:SetText(section.name)

        -- Adjust font size based on icon size
        local fontFile = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_SMALL, "")
        else
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_LARGE, "")
        end

        header.line:Show()
        header.categoryId = "Tab_" .. section.tabIndex
        header:EnableMouse(false)

        table.insert(categoryHeaders, header)

        -- Render slots for this tab
        for i, slotInfo in ipairs(section.slots) do
            local button = ItemButton:Acquire(frame.container)
            local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

            if slotInfo.itemData then
                ItemButton:SetItem(button, slotInfo.itemData, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = slotInfo.itemData.itemID
                cachedItemCount[slotKey] = slotInfo.itemData.count
            else
                ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, false)
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = nil
                cachedItemCount[slotKey] = nil
            end

            -- Calculate position within section
            local col = (i - 1) % columns
            local row = math.floor((i - 1) / columns)
            local x = col * (iconSize + spacing)
            local y = layout.slotsStartY - (row * (iconSize + spacing))

            button.wrapper:ClearAllPoints()
            button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, y)

            buttonsBySlot[slotKey] = button
            table.insert(itemButtons, button)

            if not buttonsByBag[slotInfo.bagID] then
                buttonsByBag[slotInfo.bagID] = {}
            end
            buttonsByBag[slotInfo.bagID][slotInfo.slot] = button
        end
    end

    layoutCached = true
end

function BankFrame:RefreshCategoryView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize

    -- Bank always shows soul bag items (no toggle button in bank footer)
    local items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot = LayoutEngine:CollectItemsForCategoryView(bagsToShow, bank, isReadOnly, true)

    local sections = LayoutEngine:BuildCategorySections(items, isReadOnly, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, true)

    local frameWidth, frameHeight = LayoutEngine:CalculateCategoryFrameSize(sections, settings)

    -- Calculate chrome heights for scroll frame positioning
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    -- Footer is at PADDING-2 from bottom with height FOOTER_HEIGHT
    -- Add extra padding (10) above footer for clearance
    local bottomOffset = showFooter
        and (Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    -- Derive actual content height using LayoutEngine's chrome calculation (different from scroll positioning)
    local layoutSearchBarHeight = showSearchBar and (Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + 4) or 0
    local layoutFooterHeight = showFooter and (Constants.FRAME.FOOTER_HEIGHT + 6) or Constants.FRAME.PADDING
    local layoutChrome = Constants.FRAME.TITLE_HEIGHT + layoutSearchBarHeight + layoutFooterHeight + Constants.FRAME.PADDING + 4
    local contentHeight = frameHeight - layoutChrome

    -- Recalculate frame height using our scroll frame chrome (may differ from LayoutEngine)
    local correctFrameHeight = contentHeight + chromeHeight

    -- Apply minimum frame height (2 rows of icons + chrome)
    local minFrameHeight = (2 * iconSize) + chromeHeight
    local adjustedFrameHeight = math.max(correctFrameHeight, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = contentHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container (scroll child) size to actual content height
    frame.container:SetSize(frameWidth - Constants.FRAME.PADDING * 2, math.max(contentHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() .. "ScrollBar"]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    local layout = LayoutEngine:CalculateCategoryPositions(sections, settings)

    for _, headerInfo in ipairs(layout.headers) do
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(headerInfo.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", headerInfo.x, headerInfo.y)

        -- No icons in category headers
        header.icon:Hide()
        header.text:ClearAllPoints()
        header.text:SetPoint("LEFT", header, "LEFT", 0, 0)

        -- Adjust font size based on icon size
        local fontFile = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_SMALL, "")
        else
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_LARGE, "")
        end

        -- Responsive text truncation based on available width
        local displayName = headerInfo.section.categoryName
        local numItems = #headerInfo.section.items
        -- Show count unless disabled OR only 1 item (redundant to show "(1)")
        local showCount = settings.showCategoryCount and numItems > 1
        local countSuffix = showCount and (" (" .. numItems .. ")") or ""
        header.fullName = displayName
        header.isShortened = false

        -- When not showing count, truncate based on item count
        -- 1 item: max 6 chars, 2+ items: max 13 chars
        if not showCount then
            local maxChars = numItems == 1 and 6 or 13
            if string.len(displayName) > maxChars then
                header.isShortened = true
                header.text:SetText(string.sub(displayName, 1, maxChars) .. "...")
            else
                header.text:SetText(displayName)
            end
        else
            -- Calculate available width (header width minus line spacing)
            local availableWidth = headerInfo.width - 10

            -- Set full text first to measure
            header.text:SetText(displayName .. countSuffix)
            local textWidth = header.text:GetStringWidth()

            -- Truncate if text is too wide (only for names longer than 4 characters)
            if textWidth > availableWidth and string.len(displayName) > 4 then
                header.isShortened = true
                -- Binary search for best fit
                local maxChars = string.len(displayName)
                while textWidth > availableWidth and maxChars > 1 do
                    maxChars = maxChars - 1
                    header.text:SetText(string.sub(displayName, 1, maxChars) .. "..." .. countSuffix)
                    textWidth = header.text:GetStringWidth()
                end
            end
        end

        -- Hide separator line for single-item categories
        if numItems <= 1 then
            header.line:Hide()
        else
            header.line:Show()
        end

        -- Store category info on header for drag-drop
        header.categoryId = headerInfo.section.categoryId
        header:EnableMouse(true)

        -- Add tooltip for shortened names
        header:SetScript("OnEnter", function(self)
            if self.isShortened then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
                GameTooltip:SetText(self.fullName)
                GameTooltip:Show()
            end
        end)
        header:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        -- Handle click for Empty category: place item in first empty bank slot
        header:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and self.categoryId == "Empty" then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    -- Find first empty bank slot (main bank first, then bank bags)
                    local bankBags = { BANK_CONTAINER }
                    for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                        table.insert(bankBags, i)
                    end
                    for _, bagID in ipairs(bankBags) do
                        local numSlots = C_Container.GetContainerNumSlots(bagID)
                        for slot = 1, numSlots do
                            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                            if not itemInfo then
                                -- Empty slot found, place item here
                                C_Container.PickupContainerItem(bagID, slot)
                                return
                            end
                        end
                    end
                end
            end
        end)

        table.insert(categoryHeaders, header)
    end

    -- Render expansion headers (separator labels for expansion tiers)
    if layout.expansionHeaders then
        for _, expHeader in ipairs(layout.expansionHeaders) do
            local header = AcquireCategoryHeader(frame.container)
            header:SetWidth(expHeader.width)
            header:SetHeight(20)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", expHeader.x, expHeader.y)

            -- Show expand/collapse arrow icon
            header.icon:SetSize(12, 12)
            if expHeader.isCollapsed then
                header.icon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            else
                header.icon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
            end
            header.icon:SetTexCoord(0, 1, 0, 1)
            header.icon:SetDesaturated(false)
            header.icon:ClearAllPoints()
            header.icon:SetPoint("LEFT", header, "LEFT", 0, 0)
            header.icon:Show()

            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header.icon, "RIGHT", 3, 0)

            local fontFile, _, fontFlags = header.text:GetFont()
            header.text:SetFont(fontFile, 13, "OUTLINE")

            -- Show label and item count
            local countText = expHeader.itemCount and expHeader.itemCount > 0
                and " |cff888888(" .. expHeader.itemCount .. ")|r" or ""
            header.text:SetText(expHeader.label .. countText)
            header.text:SetTextColor(0.4, 0.75, 1.0)

            header.line:ClearAllPoints()
            header.line:SetPoint("LEFT", header.text, "RIGHT", 6, 0)
            header.line:SetPoint("RIGHT", header, "RIGHT", 0, 0)
            header.line:SetHeight(2)
            header.line:SetVertexColor(0.3, 0.5, 0.7, 0.6)
            header.line:Show()

            header.categoryId = nil
            header:EnableMouse(true)

            -- Store tier for click handler
            local tier = expHeader.expansionTier
            header:SetScript("OnEnter", function(self)
                self.text:SetTextColor(0.6, 0.9, 1.0)
            end)
            header:SetScript("OnLeave", function(self)
                self.text:SetTextColor(0.4, 0.75, 1.0)
            end)
            header:SetScript("OnMouseDown", function(self, button)
                if button == "LeftButton" then
                    local collapsed = Database:GetSetting("collapsedExpansionTiers") or {}
                    collapsed[tier] = not collapsed[tier]
                    Database:SetSetting("collapsedExpansionTiers", collapsed)
                    BankFrame:Refresh()
                end
            end)

            table.insert(categoryHeaders, header)
        end
    end

    -- Reset last button tracking for drop indicator
    lastButtonByCategory = {}

    for index, itemInfo in ipairs(layout.items) do
        local button = ItemButton:Acquire(frame.container)
        local itemData = itemInfo.item.itemData
        local slotKey = itemData.bagID .. ":" .. itemData.slot

        -- Store category info before SetItem so it can use it for display logic
        button.categoryId = itemInfo.categoryId

        ItemButton:SetItem(button, itemData, iconSize, isReadOnly)

        -- Apply spotlight search highlighting
        if hasSearch then
            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
        else
            ItemButton:ClearSearchState(button)
        end

        -- Store layout position for drag-drop indicator
        button.iconSize = iconSize
        button.layoutX = itemInfo.x
        button.layoutY = itemInfo.y
        button.layoutIndex = index
        button.containerFrame = frame.container

        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", itemInfo.x, itemInfo.y)

        -- Track Empty/Soul pseudo-item buttons separately
        -- Use a unique key combining pseudo-item type and categoryId to avoid overwrites
        -- when multiple pseudo-items (Empty, Soul) are in the same merged group
        if itemData.isEmptySlots then
            local pseudoKey = (itemData.isSoulSlots and "Soul:" or "Empty:") .. itemInfo.categoryId
            pseudoItemButtons[pseudoKey] = button
        else
            -- Store button by slot key for incremental updates (not for pseudo-items)
            buttonsBySlot[slotKey] = button
            cachedItemData[slotKey] = itemData.itemID
            cachedItemCount[slotKey] = itemData.count
            cachedItemCategory[slotKey] = itemInfo.categoryId

            -- Store by bagID for fast bag-specific lookups
            local bagID = itemData.bagID
            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][itemData.slot] = button
        end

        table.insert(itemButtons, button)

        -- Track last button per category (for drop indicator anchor)
        if itemInfo.categoryId then
            lastButtonByCategory[itemInfo.categoryId] = button
        end
    end

    layoutCached = true
end

-- Register for combat end event to execute pending actions and refresh open bank
RegisterCombatEndCallback = function()
    if combatLockdownRegistered then return end
    combatLockdownRegistered = true

    Events:Register("PLAYER_REGEN_ENABLED", function()
        if pendingAction then
            local action = pendingAction
            pendingAction = nil
            if action == "show" then
                BankFrame:Show()
            end
        elseif frame and frame:IsShown() then
            -- Bank was already open during combat - refresh to catch any changes
            if BankScanner:IsBankOpen() then
                BankScanner:ScanAllBank()
            end
            BankFrame:Refresh()
        end
    end, BankFrame)
end

function BankFrame:Toggle()
    LoadComponents()

    if not frame then
        frame = CreateBankFrame()
        Database:RestoreFramePosition(frame, "bankFrame", "CENTER", "CENTER", 0, 0)
    end

    if frame:IsShown() then
        frame:Hide()
    else
        if BankScanner:IsBankOpen() then
            BankScanner:ScanAllBank()
        end
        UpdateFrameAppearance()  -- Set search bar/footer visibility first
        self:Refresh()           -- Then calculate layout with correct scroll positioning
        frame:Show()
    end
end

function BankFrame:Show()
    LoadComponents()

    if not frame then
        frame = CreateBankFrame()
        Database:RestoreFramePosition(frame, "bankFrame", "CENTER", "CENTER", 0, 0)
    end

    if BankScanner:IsBankOpen() then
        BankScanner:ScanAllBank()
    end
    UpdateFrameAppearance()  -- Set search bar/footer visibility first
    self:Refresh()           -- Then calculate layout with correct scroll positioning
    frame:Show()
end

function BankFrame:Hide()
    if frame then
        frame:Hide()
        if viewingCharacter then
            viewingCharacter = nil
            BankHeader:SetViewingCharacter(nil, nil)
        end
        -- Release ALL buttons (item buttons and pseudo-item buttons) to prevent stacking
        ItemButton:ReleaseAll(frame.container)
        ReleaseAllCategoryHeaders()
        -- Clear layout cache so next open does full refresh
        buttonsBySlot = {}
        buttonsByBag = {}
        cachedItemData = {}
        cachedItemCount = {}
        cachedItemCategory = {}
        buttonsByItemKey = {}
        categoryViewItems = {}
        lastCategoryLayout = nil
        lastTotalItemCount = 0
        pseudoItemButtons = {}
        itemButtons = {}
        layoutCached = false
        lastLayoutSettings = nil
    end
end

function BankFrame:IsShown()
    return frame and frame:IsShown()
end

function BankFrame:InvalidateLayout()
    layoutCached = false
end

function BankFrame:GetFrame()
    return frame
end

function BankFrame:GetViewingCharacter()
    return viewingCharacter
end

function BankFrame:ViewCharacter(fullName, charData)
    viewingCharacter = fullName
    BankHeader:SetViewingCharacter(fullName, charData)

    UpdateFrameAppearance()
    self:Refresh()
end

function BankFrame:IsViewingCached()
    return viewingCharacter ~= nil or not BankScanner:IsBankOpen()
end

-- Incremental update: only update changed slots without full layout recalculation
-- dirtyBags: optional table of {bagID = true} for bags that changed
function BankFrame:IncrementalUpdate(dirtyBags)
    if not frame or not frame:IsShown() then return end

    -- Never do incremental updates while viewing a cached character
    -- Live bank events should not affect cached character display
    if viewingCharacter then return end

    -- Recent items removal is now handled by ghost slots in incremental update
    -- Just clear the flag so it doesn't accumulate
    local RecentItems = ns:GetModule("RecentItems")
    if RecentItems then
        RecentItems:WasItemRemoved()  -- Clear the flag, but don't force refresh
    end

    if not layoutCached then
        -- No cached layout, do full refresh
        self:Refresh()
        return
    end

    local bank = BankScanner:GetCachedBank()
    -- Cache settings once at start (avoid repeated GetSetting calls)
    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local isReadOnly = viewingCharacter ~= nil or not BankScanner:IsBankOpen()
    local viewType = Database:GetSetting("bankViewType") or "single"
    local isCategoryView = viewType == "category"

    -- If no dirty bags specified, check all (fallback behavior)
    local checkAllBags = not dirtyBags or not next(dirtyBags)

    -- For category view: check if item's CATEGORY changed (not just itemID)
    -- If item moves within same category, do incremental update
    -- If item moves between categories or slot becomes empty/filled, do full refresh
    if isCategoryView then
        local CategoryManager = ns:GetModule("CategoryManager")
        local needsFullRefresh = false
        local itemUpdates = {}
        local countUpdates = {}
        local ghostSlots = {}

        -- Detect soul bags for category override (must match BuildCategorySections logic)
        -- Bank always shows soul items (forceSoulVisible)
        local soulCategoryEnabled = false
        if CategoryManager then
            local cats = CategoryManager:GetCategories()
            local soulDef = cats and cats.definitions and cats.definitions["Soul"]
            soulCategoryEnabled = soulDef and soulDef.enabled
        end

        local function checkBag(bagID)
            local slotButtons = buttonsByBag[bagID] or {}
            local bagData = bank[bagID]

            -- Count cached buttons for this bag
            local cachedButtonCount = 0
            for _ in pairs(slotButtons) do
                cachedButtonCount = cachedButtonCount + 1
            end

            local currentItemCount = 0
            if bagData and bagData.slots then
                for _, itemData in pairs(bagData.slots) do
                    if itemData then
                        currentItemCount = currentItemCount + 1
                    end
                end
            end

            -- If no buttons cached for this bag but items exist now, new item appeared - need refresh
            if cachedButtonCount == 0 then
                if currentItemCount > 0 then
                    ns:Debug("Bank CategoryView REFRESH: bag", bagID, "was empty, now has", currentItemCount, "items")
                    needsFullRefresh = true
                end
                return
            end

            -- If MORE items than buttons, new item appeared - need refresh
            if currentItemCount > cachedButtonCount then
                ns:Debug("Bank CategoryView REFRESH: bag", bagID, "has MORE items", currentItemCount, ">", cachedButtonCount)
                needsFullRefresh = true
                return
            end
            -- If fewer items, some were removed - keep ghost slots (lazy approach)
            if currentItemCount < cachedButtonCount then
                ns:Debug("Bank CategoryView LAZY: bag", bagID, "has FEWER items", currentItemCount, "<", cachedButtonCount, "- keeping ghosts")
            end

            -- Detect soul bag for category override
            local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
            local isSoulBag = (bagType == "soul")

            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil
                local oldCategory = cachedItemCategory[slotKey]

                if oldItemID ~= newItemID then
                    if not newItemData then
                        -- Slot became empty - show empty texture but keep position (no layout refresh)
                        ns:Debug("Bank CategoryView GHOST: empty slot at", slotKey, "oldID=", oldItemID)
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        -- Keep cachedItemCategory so we know this slot existed
                        table.insert(ghostSlots, slotKey)
                    else
                        -- Soul bag items use "Soul" category override (same as BuildCategorySections)
                        local newCategory
                        if soulCategoryEnabled and isSoulBag then
                            newCategory = "Soul"
                        else
                            newCategory = CategoryManager and CategoryManager:CategorizeItem(newItemData, bagID, slot, isReadOnly) or "Miscellaneous"
                        end

                        if oldCategory ~= newCategory then
                            ns:Debug("Bank CategoryView REFRESH: category changed at", slotKey, "from", oldCategory, "to", newCategory)
                            needsFullRefresh = true
                            return
                        end

                        itemUpdates[slotKey] = {button = button, itemData = newItemData, category = newCategory}
                    end
                elseif newItemData then
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        countUpdates[slotKey] = {button = button, count = newItemData.count}
                    end
                end
            end

            -- Check for items in slots we don't have buttons for (new slots)
            if bagData and bagData.slots then
                for slot, itemData in pairs(bagData.slots) do
                    if itemData and not slotButtons[slot] then
                        ns:Debug("Bank CategoryView REFRESH: new item at untracked slot", bagID .. ":" .. slot)
                        needsFullRefresh = true
                        return
                    end
                end
            end
        end

        if checkAllBags then
            for bagID in pairs(buttonsByBag) do
                checkBag(bagID)
                if needsFullRefresh then break end
            end
        else
            for bagID in pairs(dirtyBags) do
                checkBag(bagID)
                if needsFullRefresh then break end
            end
        end

        if needsFullRefresh then
            ns:Debug("Bank CategoryView: FULL REFRESH triggered")
            self:Refresh()
            return
        end

        if #ghostSlots > 0 then
            ns:Debug("Bank CategoryView LAZY: kept", #ghostSlots, "ghost slots, no refresh")
        end

        for slotKey, update in pairs(itemUpdates) do
            ItemButton:SetItem(update.button, update.itemData, iconSize, isReadOnly)
            cachedItemData[slotKey] = update.itemData.itemID
            cachedItemCount[slotKey] = update.itemData.count
            cachedItemCategory[slotKey] = update.category
            if hasSearch then
                ItemButton:SetSearchState(update.button, SearchBar:ItemMatchesFilters(frame, update.itemData))
            else
                ItemButton:ClearSearchState(update.button)
            end
        end

        for slotKey, update in pairs(countUpdates) do
            SetItemButtonCount(update.button, update.count)
            cachedItemCount[slotKey] = update.count
        end

        -- Calculate empty slot counts and first empty slots using LIVE data
        local emptyCount = 0
        local soulEmptyCount = 0
        local firstEmptyBagID, firstEmptySlot = nil, nil
        local firstSoulBagID, firstSoulSlot = nil, nil

        for bagID = Constants.BANK_MAIN_BAG, Constants.BANK_BAG_MAX do
            if bagID == Constants.BANK_MAIN_BAG or (bagID >= Constants.BANK_BAG_MIN and bagID <= Constants.BANK_BAG_MAX) then
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                    local isSoulBag = (bagType == "soul")
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if not itemInfo then
                            if isSoulBag then
                                soulEmptyCount = soulEmptyCount + 1
                                if not firstSoulBagID then
                                    firstSoulBagID, firstSoulSlot = bagID, slot
                                end
                            else
                                emptyCount = emptyCount + 1
                                if not firstEmptyBagID then
                                    firstEmptyBagID, firstEmptySlot = bagID, slot
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Check if Empty/Soul categories need to appear or disappear
        local emptyButtonExists = FindPseudoItemButton("Empty") ~= nil
        local soulButtonExists = FindPseudoItemButton("Soul") ~= nil
        local emptyNeedsButton = emptyCount > 0
        local soulNeedsButton = soulEmptyCount > 0

        if (emptyNeedsButton and not emptyButtonExists) or (not emptyNeedsButton and emptyButtonExists) then
            ns:Debug("Bank CategoryView REFRESH: Empty category visibility changed")
            self:Refresh()
            return
        end
        if (soulNeedsButton and not soulButtonExists) or (not soulNeedsButton and soulButtonExists) then
            ns:Debug("Bank CategoryView REFRESH: Soul category visibility changed")
            self:Refresh()
            return
        end

        -- Update pseudo-item counters and slot references directly
        local emptyBtn = FindPseudoItemButton("Empty")
        if emptyBtn then
            SetItemButtonCount(emptyBtn, emptyCount)
            if emptyBtn.itemData then
                emptyBtn.itemData.emptyCount = emptyCount
                emptyBtn.itemData.count = emptyCount
                if firstEmptyBagID then
                    emptyBtn.itemData.bagID = firstEmptyBagID
                    emptyBtn.itemData.slot = firstEmptySlot
                    emptyBtn.wrapper:SetID(firstEmptyBagID)
                    emptyBtn:SetID(firstEmptySlot)
                end
            end
        end
        local soulBtn = FindPseudoItemButton("Soul")
        if soulBtn then
            SetItemButtonCount(soulBtn, soulEmptyCount)
            if soulBtn.itemData then
                soulBtn.itemData.emptyCount = soulEmptyCount
                soulBtn.itemData.count = soulEmptyCount
                if firstSoulBagID then
                    soulBtn.itemData.bagID = firstSoulBagID
                    soulBtn.itemData.slot = firstSoulSlot
                    soulBtn.wrapper:SetID(firstSoulBagID)
                    soulBtn:SetID(firstSoulSlot)
                end
            end
        end

        local totalSlots, freeSlots = BankScanner:GetTotalSlots()
        local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
        BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
        if BankScanner:IsBankOpen() and not viewingCharacter then
            BankFooter:Update()
        end
        return
    end

    -- Single view: full incremental update (items stay in fixed slots)
    -- Optimized: Only iterate buttons in dirty bags using buttonsByBag index
    if checkAllBags then
        -- Fallback: check all bags
        for bagID, slotButtons in pairs(buttonsByBag) do
            local bagData = bank[bagID]
            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil

                if oldItemID ~= newItemID then
                    if newItemData then
                        ItemButton:SetItem(button, newItemData, iconSize, isReadOnly)
                        cachedItemData[slotKey] = newItemID
                        cachedItemCount[slotKey] = newItemData.count
                        if hasSearch then
                            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    else
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        if hasSearch then
                            ItemButton:SetSearchState(button, false)
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    end
                elseif newItemData then
                    -- Same item - only update if count changed (stacking)
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        SetItemButtonCount(button, newItemData.count)
                        cachedItemCount[slotKey] = newItemData.count
                    end
                end
            end
        end
    else
        -- Fast path: only check dirty bags (O(dirty bags) instead of O(all buttons))
        for bagID in pairs(dirtyBags) do
            local slotButtons = buttonsByBag[bagID]
            if slotButtons then
                local bagData = bank[bagID]
                for slot, button in pairs(slotButtons) do
                    local slotKey = bagID .. ":" .. slot
                    local newItemData = bagData and bagData.slots and bagData.slots[slot]
                    local oldItemID = cachedItemData[slotKey]
                    local newItemID = newItemData and newItemData.itemID or nil

                    if oldItemID ~= newItemID then
                        if newItemData then
                            ItemButton:SetItem(button, newItemData, iconSize, isReadOnly)
                            cachedItemData[slotKey] = newItemID
                            cachedItemCount[slotKey] = newItemData.count
                            if hasSearch then
                                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        else
                            ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                            cachedItemData[slotKey] = nil
                            cachedItemCount[slotKey] = nil
                            if hasSearch then
                                ItemButton:SetSearchState(button, false)
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        end
                    elseif newItemData then
                        -- Same item - only update if count changed (stacking)
                        local oldCount = cachedItemCount[slotKey]
                        if oldCount ~= newItemData.count then
                            SetItemButtonCount(button, newItemData.count)
                            cachedItemCount[slotKey] = newItemData.count
                        end
                    end
                end
            end
        end
    end

    -- Update footer slot info
    local totalSlots, freeSlots = BankScanner:GetTotalSlots()
    local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
    BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    if BankScanner:IsBankOpen() and not viewingCharacter then
        BankFooter:Update()
    end
end

-- dirtyBags: table of {bagID = true} for bags that were updated
ns.OnBankUpdated = function(dirtyBags)
    if not viewingCharacter and frame and frame:IsShown() then
        -- Use incremental update if layout is cached, otherwise full refresh
        if layoutCached then
            BankFrame:IncrementalUpdate(dirtyBags)
        else
            BankFrame:Refresh()
        end
    end

    -- Also update bag frame if open (items may have moved between bank and bags)
    -- This is needed on Retail where BAG_UPDATE doesn't always fire for player bags
    -- when items are moved from Warband bank
    -- Use IncrementalUpdate to preserve ghost slots instead of full Refresh
    local BagFrame = ns:GetModule("BagFrame")
    local BagScanner = ns:GetModule("BagScanner")
    if BagFrame and BagFrame:IsShown() then
        BagScanner:ScanAllBags()
        -- Let IncrementalUpdate handle it (preserves ghost slots)
        -- If layout isn't cached yet, IncrementalUpdate will call Refresh internally
        BagFrame:IncrementalUpdate()
    end
end

-- Disable the default Blizzard bank frame completely
-- Must be called when bank opens since _G.BankFrame may not exist at addon load time
local blizzBankDisabled = false
local function HideDefaultBankFrame()
    if blizzBankDisabled then return end
    if _G.BankFrame then
        blizzBankDisabled = true
        _G.BankFrame:SetParent(hiddenParent)
        _G.BankFrame:UnregisterAllEvents()
    end
end
HideDefaultBankFrame()

ns.OnBankOpened = function()
    HideDefaultBankFrame()
    LoadComponents()

    if not frame then
        frame = CreateBankFrame()
        Database:RestoreFramePosition(frame, "bankFrame", "CENTER", "CENTER", 0, 0)
    end

    -- Always reset to current character's bank when opening the banker
    if viewingCharacter then
        viewingCharacter = nil
        BankHeader:SetViewingCharacter(nil, nil)
    end

    -- Show Blizzard's BankFrame off-screen so GetActiveBankType() returns
    -- the correct bank type for ContainerFrameItemButton_OnClick deposits
    if ns.IsRetail and _G.BankFrame then
        -- Set bankType BEFORE Show() to prevent FetchBankLockedReason(nil) error
        if _G.BankFrame.BankPanel then
            _G.BankFrame.BankPanel.bankType = Enum.BankType.Character
        end
        _G.BankFrame:Show()
        if _G.BankFrame.BankPanel then
            _G.BankFrame.BankPanel:Show()
        end
    end

    BankFrame:Show()
end

ns.OnBankClosed = function()
    if frame and frame:IsShown() then
        BankScanner:SaveToDatabase()
        BankFrame:Hide()
    end

    -- Hide Blizzard's BankFrame so GetActiveBankType() returns nil,
    -- allowing normal item use (food, potions, containers) via right-click
    if ns.IsRetail and _G.BankFrame then
        _G.BankFrame:Hide()
    end
end

UpdateFrameAppearance = function()
    if not frame then return end

    local isViewingCached = viewingCharacter ~= nil
    local isBankOpen = BankScanner:IsBankOpen()

    -- UI Scale
    local uiScale = Database:GetSetting("uiScale") / 100
    frame:SetScale(uiScale)

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")
    local borderOpacity = Database:GetSetting("borderOpacity") / 100

    local customBgColor = nil
    local bgR = Database:GetSetting("bgColorR")
    local bgG = Database:GetSetting("bgColorG")
    local bgB = Database:GetSetting("bgColorB")
    if bgR and bgG and bgB and (bgR + bgG + bgB) > 0 then
        customBgColor = { bgR / 255, bgG / 255, bgB / 255 }
    end

    -- Apply theme background
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders, customBgColor, borderOpacity)

    BankHeader:SetBackdropAlpha(bgAlpha)

    ItemButton:UpdateSlotAlpha(bgAlpha)
    ItemButton:ApplyThemeTextures()
    ItemButton:UpdateFontSize()
    local TrackedBar = ns:GetModule("TrackedBar")
    if TrackedBar then
        TrackedBar:UpdateFontSize()
        TrackedBar:UpdateSize()
    end
    local QuestBar = ns:GetModule("QuestBar")
    if QuestBar then
        QuestBar:UpdateFontSize()
        QuestBar:UpdateSize()
    end

    local showSearchBar = Database:GetSetting("showSearchBar")
    local showFooter = Database:GetSetting("showFooter")

    -- Only toggle search bar visibility here - scroll frame positioning is handled by Refresh()
    -- This prevents overwriting the correct scrollbar width calculation from Refresh()
    if showSearchBar then
        SearchBar:Show(frame)
    else
        SearchBar:Hide(frame)
    end

    if isViewingCached then
        BankFooter:ShowCached(viewingCharacter)
        BankHeader:SetSortEnabled(false)
        -- Show side tabs and bottom tabs for Retail cached bank viewing
        if ns.IsRetail then
            BankFrame:ShowSideTabs(viewingCharacter)
            BankFrame:ShowBottomTabs()
        end
    elseif not isBankOpen then
        BankFooter:ShowCached(Database:GetPlayerFullName())
        BankHeader:SetSortEnabled(false)
        -- Show side tabs and bottom tabs for Retail cached bank viewing
        if ns.IsRetail then
            BankFrame:ShowSideTabs(Database:GetPlayerFullName())
            BankFrame:ShowBottomTabs()
        end
    elseif showFooter then
        BankHeader:SetSortEnabled(true)
        -- On Retail with bank open, show footer with action buttons and bottom tabs
        if ns.IsRetail then
            local currentBankType = BankFooter:GetCurrentBankType() or "character"
            BankFooter:ShowLive(currentBankType)
            BankFrame:ShowSideTabs(Database:GetPlayerFullName(), currentBankType)
            BankFrame:ShowBottomTabs()
        else
            BankFooter:Show()
            BankFrame:HideSideTabs()
            BankFrame:HideBottomTabs()
        end
    else
        BankFooter:Hide()
        BankHeader:SetSortEnabled(true)
        BankFrame:HideSideTabs()
        BankFrame:HideBottomTabs()
    end
end

local appearanceSettings = {
    bgAlpha = true,
    showBorders = true,
    iconFontSize = true,
    trackedBarSize = true,
    trackedBarColumns = true,
    questBarSize = true,
    questBarColumns = true,
    theme = true,
    retailEmptySlots = true,
    uiScale = true,
    bgColorR = true,
    bgColorG = true,
    bgColorB = true,
    borderOpacity = true,
}

local resizeSettings = {
    showFooter = true,
    showSearchBar = true,
    showFilterChips = true,
    compactMode = true,
}

local function OnSettingChanged(event, key, value)
    if not frame or not frame:IsShown() then return end

    -- When changing view type while viewing another character, reset to current character
    if key == "bankViewType" and viewingCharacter then
        viewingCharacter = nil
        BankHeader:SetViewingCharacter(nil, nil)
    end

    if appearanceSettings[key] then
        UpdateFrameAppearance()
    elseif resizeSettings[key] then
        UpdateFrameAppearance()
        BankFrame:Refresh()
    elseif key == "groupIdenticalItems" then
        -- Force full release when toggling item grouping to prevent visual artifacts
        -- Item structure changes fundamentally (grouped vs individual) but keys stay same
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        pseudoItemButtons = {}
        BankFrame:Refresh()
    else
        BankFrame:Refresh()
    end
end

function BankFrame:TransferMatchedItems()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ns.L["TRANSFER_COMBAT"], 1.0, 0.1, 0.1, 1.0)
        return
    end
    if not frame or not BankScanner:IsBankOpen() then return end

    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"

    local bank, bagIDs
    if isWarbandView and RetailBankScanner then
        bank = RetailBankScanner:GetCachedBank(Enum.BankType.Account) or {}
        bagIDs = Constants.WARBAND_BANK_TAB_IDS
    else
        bank = BankScanner:GetCachedBank()
        bagIDs = Constants.BANK_BAG_IDS
    end

    if not bank or not bagIDs then return end

    for _, bagID in ipairs(bagIDs) do
        local bagData = bank[bagID]
        if bagData and bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                if itemData and itemData.itemID and SearchBar:ItemMatchesFilters(frame, itemData) then
                    C_Container.UseContainerItem(bagID, slot)
                end
            end
        end
    end
end

function BankFrame:SortBank()
    if not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort bank: not at banker")
        return
    end

    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        -- Check if viewing Warband bank
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        if currentBankType == "warband" then
            SortEngine:SortWarbandBank()
        else
            SortEngine:SortBank()
        end
    else
        ns:Print("SortEngine not loaded")
    end
end

-- Restack items and clean ghost slots (for category view)
function BankFrame:RestackAndClean()
    if not frame or not frame:IsShown() then return end
    if not BankScanner:IsBankOpen() then
        ns:Print("Cannot restack bank: not at banker")
        return
    end

    -- Play sound feedback
    PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)

    -- Use SortEngine's restack function (consolidates stacks without sorting)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        -- Check if viewing Warband bank
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        local restackFunc = currentBankType == "warband" and SortEngine.RestackWarbandBank or SortEngine.RestackBank
        restackFunc(SortEngine, function()
            -- Callback when restack is complete - now clean ghost slots
            C_Timer.After(0.1, function()
                if frame and frame:IsShown() then
                    -- Release all buttons first (they would be orphaned otherwise)
                    ItemButton:ReleaseAll(frame.container)

                    -- Clear all layout caches (removes ghost slots)
                    buttonsBySlot = {}
                    buttonsByBag = {}
                    cachedItemData = {}
                    cachedItemCount = {}
                    cachedItemCategory = {}
                    buttonsByItemKey = {}
                    categoryViewItems = {}
                    lastCategoryLayout = nil
                    lastTotalItemCount = 0
                    pseudoItemButtons = {}
                    layoutCached = false
                    lastLayoutSettings = nil

                    -- Rescan and refresh
                    BankScanner:ScanAllBank()
                    BankFrame:Refresh()
                end
            end)
        end)
    else
        -- Fallback if no SortEngine
        BankScanner:ScanAllBank()
        BankFrame:Refresh()
    end
end

Events:Register("SETTING_CHANGED", OnSettingChanged, BankFrame)

-- Refresh when categories are updated (reordered, grouped, etc.)
-- Force full refresh by releasing all buttons since category assignments changed
Events:Register("CATEGORIES_UPDATED", function()
    if frame and frame:IsShown() then
        -- Release all buttons to force full refresh (category assignments changed)
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        pseudoItemButtons = {}
        BankFrame:Refresh()
    end
end, BankFrame)

Events:Register("PLAYER_MONEY", function()
    if frame and frame:IsShown() then
        BankFooter:UpdateMoney()
    end
end, BankFrame)

-- Bank bag slot configuration changed (bag added/removed from bank bag slot)
-- Force re-scan + full refresh since the batched scanner may not have processed yet
if not ns.IsRetail then
    Events:Register("PLAYERBANKBAGSLOTS_CHANGED", function()
        if frame and frame:IsShown() and not viewingCharacter then
            ns:Debug("PLAYERBANKBAGSLOTS_CHANGED - forcing rescan + full refresh")
            BankScanner:ScanAllBank()
            layoutCached = false
            BankFrame:Refresh()
        end
    end, BankFrame)
end

-- Update item lock state (when picking up/putting down items)
Events:Register("ITEM_LOCK_CHANGED", function(event, bagID, slotID)
    -- Skip when viewing cached character - lock state is for current character only
    if viewingCharacter then return end
    if frame and frame:IsShown() and bagID and slotID then
        ItemButton:UpdateLockForItem(bagID, slotID)
    end
end, BankFrame)

-- Callback for when Retail bank tab changes
ns.OnRetailBankTabChanged = function(tabIndex)
    if frame and frame:IsShown() then
        -- Update side tab selection visuals
        BankFrame:UpdateSideTabSelection()
        -- Refresh the display with the new tab filter
        BankFrame:Refresh()
    end
end

-- Callback for when bank type changes (Character Bank vs Warband Bank)
ns.OnBankTypeChanged = function(bankType)
    if frame and frame:IsShown() then
        ns:Debug("Bank type changed to:", bankType)

        -- Sync Blizzard BankPanel.bankType so the original GetActiveBankType()
        -- returns the correct enum for UseContainerItem deposits
        if _G.BankFrame and _G.BankFrame.BankPanel then
            _G.BankFrame.BankPanel.bankType = bankType == "warband" and Enum.BankType.Account or Enum.BankType.Character
        end

        -- Update RetailBankScanner's current bank type so BAG_UPDATE events are processed correctly
        if RetailBankScanner then
            local bankTypeEnum = bankType == "warband" and Enum.BankType.Account or Enum.BankType.Character
            RetailBankScanner:SetCurrentBankType(bankTypeEnum)
            RetailBankScanner:SetSelectedTab(0)  -- Reset tab selection to "All"
            -- Rescan the new bank type to get fresh data
            if BankScanner:IsBankOpen() then
                RetailBankScanner:ScanAllBank()
            end
        end

        -- Get the character being viewed
        local characterFullName = viewingCharacter or Database:GetPlayerFullName()

        -- Refresh side tabs for the new bank type
        BankFrame:ShowSideTabs(characterFullName, bankType)

        -- Update footer action buttons for the new bank type
        local isBankOpen = BankScanner and BankScanner:IsBankOpen()
        BankFooter:UpdateRetailActionButtons(isBankOpen, bankType)

        -- Refresh the display with the new bank type's data
        BankFrame:Refresh()
    end
end
