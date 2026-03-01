local addonName, ns = ...

local BagFrame = {}
ns:RegisterModule("BagFrame", BagFrame)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local BagScanner = ns:GetModule("BagScanner")
local ItemButton = ns:GetModule("ItemButton")
local Footer = ns:GetModule("Footer")
local SearchBar = ns:GetModule("SearchBar")
local Header = ns:GetModule("Header")
local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
local LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
local Utils = ns:GetModule("Utils")
local CategoryHeaderPool = ns:GetModule("CategoryHeaderPool")
local Theme = ns:GetModule("Theme")

local frame
local itemButtons = {}
local categoryHeaders = {}
local isInitialized = false
local viewingCharacter = nil -- nil = current character, or fullName string

-- Combat lockdown handling
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
local pendingAction = nil  -- "show", "toggle", or nil
local combatLockdownRegistered = false

-- Layout caching for incremental updates (Single View)
local buttonsBySlot = {}  -- Key: "bagID:slot" -> button reference
local buttonsByBag = {}   -- Key: bagID -> { slot -> button } for fast bag-specific lookups
local cachedItemData = {} -- Key: "bagID:slot" -> previous itemID (for comparison)
local cachedItemCount = {} -- Key: "bagID:slot" -> previous count (for stack updates)
local cachedItemCategory = {} -- Key: "bagID:slot" -> previous categoryId (for category view)
local layoutCached = false -- True when layout is cached and can do incremental updates

-- Category View: Item-key-based button tracking for efficient reuse
-- This allows button reuse when items move, avoiding expensive SetItem calls
local buttonsByItemKey = {}  -- Key: itemKey -> {button1, button2, ...} (array for stacked items)
local buttonPositions = {}   -- Key: button -> {x, y, index} for reflow detection
local categoryViewItems = {} -- Array of {itemKey, bagID, slot, categoryId, count} for current layout
local lastCategoryLayout = nil -- Previous categoryViewItems for comparison
local lastButtonByCategory = {} -- Key: categoryId -> last item button (for drop indicator anchor)
local lastTotalItemCount = 0 -- Track item count to detect Empty/Soul category changes
local pseudoItemButtons = {} -- Track Empty/Soul pseudo-item buttons for proper release
                             -- Keys are "Empty:<categoryId>" or "Soul:<categoryId>" to avoid overwrites in merged groups

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

-- Delta layout tracking: Skip layout recalc if settings unchanged
local lastLayoutSettings = nil  -- { columns, iconSize, spacing, slotCount, viewType }

-- Use shared utility functions for key generation
local function GetItemKey(itemData)
    return Utils:GetItemKey(itemData)
end

local function GetSlotKey(bagID, slot)
    return Utils:GetSlotKey(bagID, slot)
end

-- Helper to count keys in a hash table (# only works for array tables)
local function TableCount(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Forward declarations
local UpdateFrameAppearance
local SaveFramePosition
local RestoreFramePosition
local RegisterCombatEndCallback

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

-- Handle drops on empty space in the bag container
function BagFrame:HandleContainerDrop()
    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then return end

    -- Find first empty bag slot (bags 0 to NUM_BAG_SLOTS)
    for bagID = 0, NUM_BAG_SLOTS do
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

    -- If no empty slot found, clear cursor
    ClearCursor()
end

-- Separate container for secure item buttons - NOT a child of the bag frame
-- This prevents the bag frame from becoming protected
local secureButtonContainer = nil

local function CreateBagFrame()
    local f = CreateFrame("Frame", "GudaBagsBagFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 300)
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- Raise frame above BankFrame when clicked
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(self)
        -- Keep secure container above frame backdrop
        if self.container then
            self.container:SetFrameLevel(Constants.FRAME_LEVELS.RAISED + Constants.FRAME_LEVELS.CONTAINER)
            ItemButton:SyncFrameLevels(self.container)
        end

        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                bankFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end
    end)

    -- Ensure container stays above frame backdrop when mouse enters
    f:SetScript("OnEnter", function(self)
        if self.container then
            self.container:SetFrameLevel(self:GetFrameLevel() + Constants.FRAME_LEVELS.CONTAINER)
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

    -- Create separate secure button container as child of UIParent (not f)
    -- This prevents f from becoming protected when secure buttons are added
    if not secureButtonContainer then
        secureButtonContainer = CreateFrame("Frame", "GudaBagsSecureContainer", UIParent)
        secureButtonContainer:SetFrameStrata("HIGH")
        secureButtonContainer:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
        secureButtonContainer:Hide()  -- Start hidden
    end

    -- Initialize header component
    f.titleBar = Header:Init(f)
    Header:SetDragCallback(SaveFramePosition)

    -- Initialize search bar component
    f.searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        BagFrame:Refresh()
    end)

    -- Transfer button callbacks
    SearchBar:SetTransferTargetCallback(f, function()
        local GuildBankScanner = ns:GetModule("GuildBankScanner")
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            return {type = "guildbank", label = L["TRANSFER_TO_GUILD_BANK"]}
        end
        local BankScannerModule = ns:GetModule("BankScanner")
        if BankScannerModule and BankScannerModule:IsBankOpen() then
            -- Check if warband view is active (Retail only)
            local BankFooter = ns:GetModule("BankFrame.BankFooter")
            if ns.IsRetail and BankFooter then
                local bankType = BankFooter:GetCurrentBankType()
                if bankType == "warband" then
                    return {type = "warband", label = L["TRANSFER_TO_WARBAND"]}
                end
            end
            return {type = "bank", label = L["TRANSFER_TO_BANK"]}
        end
        return nil
    end)

    SearchBar:SetTransferCallback(f, function()
        BagFrame:TransferMatchedItems()
    end)

    -- Use the separate secure button container instead of creating one as child of f
    -- This keeps f unprotected so it can be shown during combat
    secureButtonContainer:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + SearchBar:GetTotalHeight(f) + Constants.FRAME.PADDING + 6))
    secureButtonContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING, Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING + 6)
    f.container = secureButtonContainer

    -- Sync secure container visibility with main frame
    f:HookScript("OnShow", function() secureButtonContainer:Show() end)
    f:HookScript("OnHide", function()
        secureButtonContainer:Hide()
        -- Reset to current character when bag closes
        if viewingCharacter then
            viewingCharacter = nil
            Header:SetViewingCharacter(nil, nil)
        end
        -- Close any open character dropdown
        if Characters then
            Characters:Hide()
        end
    end)

    -- Enable container as drop zone for empty space
    secureButtonContainer:EnableMouse(true)

    secureButtonContainer:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            BagFrame:HandleContainerDrop()
        end
    end)

    secureButtonContainer:SetScript("OnReceiveDrag", function(self)
        BagFrame:HandleContainerDrop()
    end)

    -- Initialize footer component
    f.footer = Footer:Init(f)
    Footer:SetKeyringCallback(function(isVisible)
        BagFrame:Refresh()
    end)
    Footer:SetSoulBagCallback(function(isVisible)
        BagFrame:Refresh()
    end)
    Footer:SetBagVisibilityCallback(function()
        BagFrame:Refresh()
    end)
    Footer:SetBackCallback(function()
        BagFrame:ViewCharacter(nil, nil)
    end)

    -- Initialize character dropdown callback
    Header:SetCharacterCallback(function(fullName, charData)
        BagFrame:ViewCharacter(fullName, charData)
    end)

    -- Initialize bank character dropdown callback (used by both BagFrame and BankFrame headers)
    Header:SetBankCharacterCallback(function(fullName, charData)
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule:IsShown() then
            BankFrameModule:ViewCharacter(fullName, charData)
        else
            BankFrameModule:Show()
            BankFrameModule:ViewCharacter(fullName, charData)
        end
    end)

    return f
end

function BagFrame:Refresh()
    if not frame then return end

    local viewType = Database:GetSetting("bagViewType") or "single"

    -- Detect view type change - must release all buttons when switching views
    local lastViewType = lastLayoutSettings and lastLayoutSettings.viewType
    local viewTypeChanged = lastViewType and lastViewType ~= viewType

    -- For category view (staying in category), preserve buttonsByItemKey for reuse optimization
    -- RefreshCategoryView will handle selective release/acquire
    -- But if switching TO category from another view, release all first
    if viewType ~= "category" or viewTypeChanged then
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
    end
    -- else: RefreshCategoryView handles button release/acquire with key-based reuse

    ReleaseAllCategoryHeaders()
    itemButtons = {}

    -- Release pseudo-item buttons BEFORE clearing the table
    for _, button in pairs(pseudoItemButtons) do
        ItemButton:Release(button)
    end

    -- Clear layout cache for full refresh
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCategory = {}
    -- Note: buttonsByItemKey preserved for category view reuse (unless view type changed)
    buttonPositions = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    -- Note: lastLayoutSettings is preserved until end of Refresh to detect view type changes

    local isViewingCached = viewingCharacter ~= nil
    local bags

    if isViewingCached then
        bags = Database:GetNormalizedBags(viewingCharacter) or {}
    else
        bags = BagScanner:GetCachedBags()
    end

    local iconSize = Database:GetSetting("iconSize")
    local spacing = Database:GetSetting("iconSpacing")
    local columns = Database:GetSetting("bagColumns")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    -- viewType already declared at top of function

    -- Calculate common settings
    local showSearchBar = Database:GetSetting("showSearchBar")
    local showFooterSetting = Database:GetSetting("showFooter")
    local showFooter = showFooterSetting or isViewingCached
    local showCategoryCount = Database:GetSetting("showCategoryCount")

    local showFilterChips = Database:GetSetting("showFilterChips")

    local settings = {
        columns = columns,
        iconSize = iconSize,
        spacing = spacing,
        showSearchBar = showSearchBar,
        showFilterChips = showFilterChips,
        showFooter = showFooter,
        showCategoryCount = showCategoryCount,
    }

    -- Classify bags by type
    local classifiedBags = BagClassifier:ClassifyBags(bags, isViewingCached)

    -- Build display order
    local showKeyring = Footer:IsKeyringVisible()
    local showSoulBag = Footer:IsSoulBagVisible()
    local bagsToShow = LayoutEngine:BuildDisplayOrder(classifiedBags, showKeyring, bags, showSoulBag)

    -- Filter out hidden bags in single view mode (not when viewing cached character)
    if viewType == "single" and not isViewingCached then
        local BagSlots = ns:GetModule("Footer.BagSlots")
        if BagSlots then
            local filteredBags = {}
            for _, bagInfo in ipairs(bagsToShow) do
                -- bagsToShow contains objects like {bagID = 0, needsSpacing = false}
                if not BagSlots:IsBagHidden(bagInfo.bagID) then
                    table.insert(filteredBags, bagInfo)
                end
            end
            bagsToShow = filteredBags
        end
    end

    if viewType == "category" then
        self:RefreshCategoryView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    else
        self:RefreshSingleView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    end

    -- Update slot info (show regular bags only, special bags in tooltip)
    if isViewingCached then
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bags) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        Footer:UpdateSlotInfo(usedSlots, totalSlots)
    else
        local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
        local totalSlots, freeSlots = BagScanner:GetTotalSlots()
        Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    end

    -- Update footer (bag slots, hearthstone, money, keyring state)
    if not isViewingCached then
        Footer:Update()
    end

    -- Save current view type for detecting view switches
    lastLayoutSettings = { viewType = viewType }
end

function BagFrame:RefreshSingleView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    local iconSize = settings.iconSize

    -- Collect all slots
    -- On Retail, use unified order (sequential by bag ID) to match native sort behavior
    -- This ensures profession materials don't appear after junk from regular bags
    local unifiedOrder = ns.IsRetail and not isViewingCached
    local allSlots = LayoutEngine:CollectAllSlots(bagsToShow, bags, isViewingCached, unifiedOrder)

    -- Calculate frame size
    local frameWidth, frameHeight = LayoutEngine:CalculateFrameSize(allSlots, settings)
    frame:SetSize(frameWidth, frameHeight)

    -- Calculate button positions
    local positions = LayoutEngine:CalculateButtonPositions(allSlots, settings)

    -- Render buttons
    for i, slotInfo in ipairs(allSlots) do
        local button = ItemButton:Acquire(frame.container)
        local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

        if slotInfo.itemData then
            ItemButton:SetItem(button, slotInfo.itemData, iconSize, isViewingCached)
            if hasSearch and not SearchBar:ItemMatchesFilters(frame, slotInfo.itemData) then
                button:SetAlpha(0.15)
            else
                button:SetAlpha(1)
            end
            -- Cache item data for incremental updates
            cachedItemData[slotKey] = slotInfo.itemData.itemID
            cachedItemCount[slotKey] = slotInfo.itemData.count
        else
            ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isViewingCached)
            if hasSearch then
                button:SetAlpha(0.15)
            else
                button:SetAlpha(1)
            end
            cachedItemData[slotKey] = nil
            cachedItemCount[slotKey] = nil
        end

        -- Position the wrapper frame
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

function BagFrame:RefreshCategoryView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    local iconSize = settings.iconSize

    -- Collect items and count empty slots (including soul bag slots)
    local items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot = LayoutEngine:CollectItemsForCategoryView(bagsToShow, bags, isViewingCached)

    -- Note: Search filtering removed - now uses alpha dimming like Single View
    -- Items stay in layout, non-matching items are dimmed to 0.3 alpha

    -- Phase 4: Key-based button reuse
    -- Build map of new items by key
    local newItemsByKey = {}
    local newItemsKeyList = {}  -- Ordered list of keys
    for _, item in ipairs(items) do
        local key = GetItemKey(item.itemData)
        if key then
            if not newItemsByKey[key] then
                newItemsByKey[key] = {}
                table.insert(newItemsKeyList, key)
            end
            table.insert(newItemsByKey[key], item)
        end
    end

    -- Find buttons to keep vs release
    local buttonsToKeep = {}  -- key -> {button, ...}
    local buttonsToRelease = {}

    for key, buttons in pairs(buttonsByItemKey) do
        local needed = newItemsByKey[key] and #newItemsByKey[key] or 0
        local available = #buttons

        if needed > 0 then
            -- Keep up to 'needed' buttons
            buttonsToKeep[key] = {}
            for i = 1, math.min(needed, available) do
                table.insert(buttonsToKeep[key], buttons[i])
            end
            -- Release excess buttons
            for i = needed + 1, available do
                table.insert(buttonsToRelease, buttons[i])
            end
        else
            -- Item no longer exists, release all buttons
            for _, button in ipairs(buttons) do
                table.insert(buttonsToRelease, button)
            end
        end
    end

    -- Release unused buttons
    for _, button in ipairs(buttonsToRelease) do
        ItemButton:Release(button)
    end

    -- Note: pseudo-item buttons are released in Refresh() before calling this function
    -- Just clear the table to rebuild fresh
    pseudoItemButtons = {}

    -- Clear tracking (will rebuild below)
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    buttonPositions = {}
    categoryViewItems = {}
    itemButtons = {}

    -- Build category sections (include empty slot count for "Empty" and "Soul" categories)
    local sections = LayoutEngine:BuildCategorySections(items, isViewingCached, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot)

    -- Calculate frame size
    local frameWidth, frameHeight = LayoutEngine:CalculateCategoryFrameSize(sections, settings)
    frame:SetSize(frameWidth, frameHeight)

    -- Calculate positions
    local layout = LayoutEngine:CalculateCategoryPositions(sections, settings)

    -- Render category headers
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
        local fontFile, _, fontFlags = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            header.text:SetFont(fontFile, Constants.CATEGORY_FONT_LARGE, fontFlags)
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

        -- Handle click for Empty category: place item in first empty slot
        header:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and self.categoryId == "Empty" then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    -- Find first empty bag slot
                    for bagID = 0, NUM_BAG_SLOTS do
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

    -- Render item buttons with key-based reuse
    -- Track which kept buttons we've used per key
    local usedKeptButtons = {}
    for key in pairs(buttonsToKeep) do
        usedKeptButtons[key] = 0
    end

    local reusedCount = 0
    local acquiredCount = 0

    -- Reset last button tracking for drop indicator
    lastButtonByCategory = {}

    for index, itemInfo in ipairs(layout.items) do
        local itemData = itemInfo.item.itemData
        local slotKey = GetSlotKey(itemData.bagID, itemData.slot)
        local itemKey = GetItemKey(itemData)

        -- Try to reuse existing button for this item key
        local button
        if itemKey and buttonsToKeep[itemKey] then
            local used = usedKeptButtons[itemKey]
            if used < #buttonsToKeep[itemKey] then
                button = buttonsToKeep[itemKey][used + 1]
                usedKeptButtons[itemKey] = used + 1
                reusedCount = reusedCount + 1
            end
        end

        -- Acquire new button if no reusable one found
        if not button then
            button = ItemButton:Acquire(frame.container)
            acquiredCount = acquiredCount + 1
        end

        -- Store category info before SetItem so it can use it for display logic
        button.categoryId = itemInfo.categoryId

        ItemButton:SetItem(button, itemData, iconSize, isViewingCached)

        -- Apply search highlighting (dim non-matching items)
        if hasSearch and not SearchBar:ItemMatchesFilters(frame, itemData) then
            button:SetAlpha(0.15)
        else
            button:SetAlpha(1)
        end

        -- Store layout position for drag-drop indicator
        button.iconSize = iconSize
        button.layoutX = itemInfo.x
        button.layoutY = itemInfo.y
        button.layoutIndex = index
        button.containerFrame = frame.container

        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", itemInfo.x, itemInfo.y)

        -- Don't track Empty/Soul category pseudo-item in incremental update structures
        -- It represents aggregated empty slots, not a real item slot
        -- But DO track it separately for proper release
        -- Use a unique key combining pseudo-item type and categoryId to avoid overwrites
        -- when multiple pseudo-items (Empty, Soul) are in the same merged group
        if itemData.isEmptySlots then
            local pseudoKey = (itemData.isSoulSlots and "Soul:" or "Empty:") .. itemInfo.categoryId
            pseudoItemButtons[pseudoKey] = button
        else
            -- Store button by slot key for incremental updates (legacy)
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

            -- Store by item key for smart button reuse
            if itemKey then
                if not buttonsByItemKey[itemKey] then
                    buttonsByItemKey[itemKey] = {}
                end
                table.insert(buttonsByItemKey[itemKey], button)
            end
        end

        -- Store button position for reflow detection
        buttonPositions[button] = {x = itemInfo.x, y = itemInfo.y, index = index}

        -- Store item info for incremental comparison
        table.insert(categoryViewItems, {
            itemKey = itemKey,
            bagID = itemData.bagID,
            slot = itemData.slot,
            slotKey = slotKey,
            categoryId = itemInfo.categoryId,
            count = itemData.count,
            x = itemInfo.x,
            y = itemInfo.y,
            index = index,
        })

        table.insert(itemButtons, button)

        -- Track last button per category (for drop indicator anchor)
        if itemInfo.categoryId then
            lastButtonByCategory[itemInfo.categoryId] = button
        end
    end

    ns:Debug(string.format("Category refresh: %d reused, %d acquired, %d released",
        reusedCount, acquiredCount, #buttonsToRelease))

    -- Save current layout for next incremental update comparison
    lastCategoryLayout = categoryViewItems
    -- Track item count to detect Empty/Soul category changes in incremental updates
    lastTotalItemCount = #categoryViewItems

    layoutCached = true
end

-- Register for combat end event to execute pending actions and refresh open bags
RegisterCombatEndCallback = function()
    if combatLockdownRegistered then return end
    combatLockdownRegistered = true

    Events:Register("PLAYER_REGEN_ENABLED", function()
        if pendingAction then
            local action = pendingAction
            pendingAction = nil
            if action == "show" then
                BagFrame:Show()
            elseif action == "toggle" then
                BagFrame:Toggle()
            end
        elseif frame and frame:IsShown() then
            -- Bags were already open during combat - refresh to catch any changes
            BagScanner:ScanAllBags()
            BagFrame:Refresh()
        end
    end, BagFrame)
end

function BagFrame:Toggle()
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end

    if frame:IsShown() then
        self:Hide()  -- Use BagFrame:Hide() to properly release buttons
    else
        BagScanner:ScanAllBags()
        -- Clean up stale Recent items (items no longer in bags)
        -- If items were removed, force full button release to prevent texture artifacts
        local RecentItems = ns:GetModule("RecentItems")
        if RecentItems and RecentItems:CleanupStale() then
            ItemButton:ReleaseAll(frame.container)
            buttonsByItemKey = {}
        end
        self:Refresh()
        UpdateFrameAppearance()
        frame:Show()
    end
end

function BagFrame:Show()
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end

    BagScanner:ScanAllBags()
    -- Clean up Recent items: both expired (time-based) and stale (no longer in bags)
    -- If any items were removed, force full button release to prevent texture artifacts
    local RecentItems = ns:GetModule("RecentItems")
    local needsFullRefresh = false
    if RecentItems then
        -- Pass true to skip event firing since we'll refresh manually
        if RecentItems:Cleanup(true) then needsFullRefresh = true end
        if RecentItems:CleanupStale() then needsFullRefresh = true end
    end
    if needsFullRefresh then
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
    end
    self:Refresh()
    UpdateFrameAppearance()
    frame:Show()
end

function BagFrame:Hide()
    if frame then
        frame:Hide()
        -- Reset to current character when closing
        if viewingCharacter then
            viewingCharacter = nil
            Header:SetViewingCharacter(nil, nil)
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
        -- Category view item-key tracking
        buttonsByItemKey = {}
        buttonPositions = {}
        categoryViewItems = {}
        lastCategoryLayout = nil
        lastTotalItemCount = 0
        pseudoItemButtons = {}
        itemButtons = {}
        layoutCached = false
        lastLayoutSettings = nil
    end
end

function BagFrame:IsShown()
    return frame and frame:IsShown()
end

function BagFrame:GetFrame()
    return frame
end

function BagFrame:GetViewingCharacter()
    return viewingCharacter
end

function BagFrame:ViewCharacter(fullName, charData)
    viewingCharacter = fullName
    Header:SetViewingCharacter(fullName, charData)

    UpdateFrameAppearance()
    self:Refresh()
end

function BagFrame:IsViewingCached()
    return viewingCharacter ~= nil
end

-- Incremental update: only update changed slots without full layout recalculation
-- dirtyBags: optional table of {bagID = true} for bags that changed
function BagFrame:IncrementalUpdate(dirtyBags)
    if not frame or not frame:IsShown() then return end

    -- Never do incremental updates while viewing a cached character
    -- Live bag events should not affect cached character display
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

    local bags = BagScanner:GetCachedBags()
    -- Cache settings once at start (avoid repeated GetSetting calls)
    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local viewType = Database:GetSetting("bagViewType") or "single"
    local isCategoryView = viewType == "category"

    -- If no dirty bags specified, check all (fallback behavior)
    local checkAllBags = not dirtyBags or not next(dirtyBags)

    -- Category view: Item-key-based button reuse for efficiency
    -- Buttons are tracked by item key, not by slot
    -- When items move, the SAME button follows - no expensive SetItem call needed
    if isCategoryView then
        local CategoryManager = ns:GetModule("CategoryManager")

        -- Build map of current items from bag data (by item key)
        local currentItemsByKey = {}   -- itemKey -> {itemData, bagID, slot, category}[]
        local currentItemsBySlot = {}  -- slotKey -> {itemData, itemKey, category}
        local totalCurrentItems = 0

        local bagsToShow = Constants.BAG_IDS  -- Player bags
        for _, bagID in ipairs(bagsToShow) do
            local bagData = bags[bagID]
            if bagData and bagData.slots then
                for slot, itemData in pairs(bagData.slots) do
                    if itemData then
                        local itemKey = GetItemKey(itemData)
                        local slotKey = GetSlotKey(bagID, slot)
                        local category = CategoryManager and CategoryManager:CategorizeItem(itemData, bagID, slot, false) or "Miscellaneous"

                        if not currentItemsByKey[itemKey] then
                            currentItemsByKey[itemKey] = {}
                        end
                        table.insert(currentItemsByKey[itemKey], {
                            itemData = itemData,
                            bagID = bagID,
                            slot = slot,
                            slotKey = slotKey,
                            category = category,
                        })
                        currentItemsBySlot[slotKey] = {
                            itemData = itemData,
                            itemKey = itemKey,
                            category = category,
                        }
                        totalCurrentItems = totalCurrentItems + 1
                    end
                end
            end
        end

        -- Count available ghost slots (buttons that are or will become empty)
        -- This includes:
        -- 1. Buttons already showing empty (cachedItemData is nil)
        -- 2. Buttons for slots that are NOW empty in currentItemsBySlot (item was removed)
        local ghostSlots = {}  -- Array of {slotKey, button} for reuse
        for slotKey, button in pairs(buttonsBySlot) do
            if not cachedItemData[slotKey] then
                -- This button is already showing empty (ghost) - available for reuse
                table.insert(ghostSlots, {slotKey = slotKey, button = button})
            elseif not currentItemsBySlot[slotKey] then
                -- This button's slot is now empty (item was removed) - will become ghost
                table.insert(ghostSlots, {slotKey = slotKey, button = button})
            end
        end

        -- Check if we need full refresh:
        -- 1. If any item changed categories
        -- 2. If more NEW items than available ghost slots
        -- 3. If unique item count increased beyond available buttons + ghosts
        local needsFullRefresh = false
        local newItemsNeedingButtons = {}  -- Items that need buttons (no existing key match)

        -- Count total cached buttons (excluding ghosts and slots that will become ghosts)
        local totalCachedButtons = 0
        for slotKey in pairs(buttonsBySlot) do
            if cachedItemData[slotKey] and currentItemsBySlot[slotKey] then
                -- Button has cached data AND slot still has an item (not becoming ghost)
                totalCachedButtons = totalCachedButtons + 1
            end
        end

        -- With item grouping, compare unique item types (keys) vs buttons, not slots vs buttons
        -- Multiple slots with same item share one button
        -- Always use unique item count for category view comparison (grouping is inherent to category view)
        local uniqueItemCount = TableCount(currentItemsByKey)

        -- If more unique items than buttons + ghosts, need full refresh
        local totalAvailable = totalCachedButtons + #ghostSlots
        ns:Debug("CategoryView check: items=", totalCurrentItems, "unique=", uniqueItemCount, "cached=", totalCachedButtons, "ghosts=", #ghostSlots, "total=", totalAvailable)
        if uniqueItemCount > totalAvailable then
            ns:Debug("CategoryView REFRESH: more unique items", uniqueItemCount, "than available slots", totalAvailable)
            needsFullRefresh = true
        end

        -- Calculate empty slot counts and first empty slots using LIVE data (not cached)
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
        local emptyCount = 0
        local soulEmptyCount = 0
        local firstEmptyBagID, firstEmptySlot = nil, nil
        local firstSoulBagID, firstSoulSlot = nil, nil

        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                local isSoulBag = (bagType == "soul")
                for slot = 1, numSlots do
                    -- Use live container data, not cached
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if not itemInfo then
                        if isSoulBag then
                            soulEmptyCount = soulEmptyCount + 1
                            if not firstSoulBagID then
                                firstSoulBagID, firstSoulSlot = bagID, slot
                            end
                        elseif bagType == "regular" or bagID == 0 then
                            emptyCount = emptyCount + 1
                            if not firstEmptyBagID then
                                firstEmptyBagID, firstEmptySlot = bagID, slot
                            end
                        end
                    end
                end
            end
        end

        -- Check if Empty category needs to appear or disappear (requires full refresh)
        local emptyButtonExists = FindPseudoItemButton("Empty") ~= nil
        local emptyNeedsButton = emptyCount > 0

        if (emptyNeedsButton and not emptyButtonExists) or (not emptyNeedsButton and emptyButtonExists) then
            ns:Debug("CategoryView REFRESH: Empty category visibility changed")
            needsFullRefresh = true
        end
        -- Note: Soul visibility check removed - it was causing false positives
        -- Soul button updates are handled below if the button exists

        -- Update pseudo-item counters and slot references directly (if no full refresh needed)
        if not needsFullRefresh then
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
        end

        -- Update lastTotalItemCount for tracking
        lastTotalItemCount = totalCurrentItems

        -- NOTE: We intentionally don't check for untracked slots here.
        -- In Category View with item grouping, multiple slots share buttons,
        -- so buttonsBySlot doesn't track every individual slot.
        -- The itemKey-based check below properly handles new items.

        -- Check for category changes in existing items
        if not needsFullRefresh and lastCategoryLayout then
            for _, prevItem in ipairs(lastCategoryLayout) do
                local currentSlot = currentItemsBySlot[prevItem.slotKey]
                if currentSlot then
                    -- Item still in this slot - check if category changed
                    if prevItem.categoryId ~= currentSlot.category then
                        ns:Debug("CategoryView REFRESH: category changed at", prevItem.slotKey)
                        needsFullRefresh = true
                        break
                    end
                end
            end
        end

        -- Skip remaining checks if already need refresh
        if not needsFullRefresh then
            for itemKey, items in pairs(currentItemsByKey) do
                local existingButtons = buttonsByItemKey[itemKey]
                local hasButton = existingButtons and #existingButtons > 0
                -- In category view with grouping, we need exactly 1 button per unique itemKey
                if not hasButton then
                    -- This is a new item type that needs a button
                    local itemName = items[1] and items[1].itemData and items[1].itemData.name or "unknown"
                    ns:Debug("CategoryView: new itemKey needs button:", itemName)
                    table.insert(newItemsNeedingButtons, items[1])
                end
            end

            -- If more new item types than ghost slots available, need full refresh
            if #newItemsNeedingButtons > #ghostSlots then
                ns:Debug("CategoryView REFRESH: need", #newItemsNeedingButtons, "new buttons, only", #ghostSlots, "ghosts available")
                needsFullRefresh = true
            end
        end

        if needsFullRefresh then
            ns:Debug("CategoryView: FULL REFRESH triggered")
            self:Refresh()
            return
        end

        -- No full refresh needed - do incremental updates
        ns:Debug("CategoryView: INCREMENTAL update starting, items=", totalCurrentItems, "ghosts=", #ghostSlots)
        local buttonsReused = 0
        local buttonsUpdated = 0
        local countUpdates = 0
        local ghostsCreated = 0
        local ghostsReused = 0

        -- First pass: Update existing slots (same slot, same or different item)
        for slotKey, button in pairs(buttonsBySlot) do
            -- Skip the Empty category pseudo-item button (it represents aggregated empty slots, not a real item)
            if not button.isEmptySlotButton then
                local currentSlot = currentItemsBySlot[slotKey]
                local oldItemID = cachedItemData[slotKey]

                if currentSlot then
                -- Slot has an item now
                local newItemData = currentSlot.itemData
                local newItemID = newItemData.itemID

                if oldItemID == newItemID then
                    -- Same item - just check count
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        SetItemButtonCount(button, newItemData.count)
                        cachedItemCount[slotKey] = newItemData.count
                        countUpdates = countUpdates + 1
                    end
                    buttonsReused = buttonsReused + 1
                elseif oldItemID == nil then
                    -- Ghost slot getting an item back - update it
                    ItemButton:SetItem(button, newItemData, iconSize, false)
                    cachedItemData[slotKey] = newItemID
                    cachedItemCount[slotKey] = newItemData.count
                    cachedItemCategory[slotKey] = currentSlot.category
                    ghostsReused = ghostsReused + 1

                    if hasSearch and not SearchBar:ItemMatchesFilters(frame, newItemData) then
                        button:SetAlpha(0.15)
                    else
                        button:SetAlpha(1)
                    end
                else
                    -- Different item - update button
                    ItemButton:SetItem(button, newItemData, iconSize, false)
                    cachedItemData[slotKey] = newItemID
                    cachedItemCount[slotKey] = newItemData.count
                    cachedItemCategory[slotKey] = currentSlot.category
                    buttonsUpdated = buttonsUpdated + 1

                    if hasSearch and not SearchBar:ItemMatchesFilters(frame, newItemData) then
                        button:SetAlpha(0.15)
                    else
                        button:SetAlpha(1)
                    end
                end
            else
                -- Slot is now empty - item was removed (sold/moved/deleted)
                if oldItemID then
                    -- Show ghost slot instead of full refresh
                    -- Parse bagID and slot from slotKey (format: "bagID:slot", bagID can be negative)
                    local bagID, slot = slotKey:match("^(-?%d+):(%d+)$")
                    bagID = tonumber(bagID)
                    slot = tonumber(slot)
                    if bagID and slot then
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        button:SetAlpha(hasSearch and 0.3 or 1)
                        ghostsCreated = ghostsCreated + 1
                    end
                end
            end
            end  -- end if not button.isEmptySlotButton
        end

        -- Second pass: Find buttons whose itemKey no longer exists (item completely removed)
        -- This handles grouped items where the primary slot wasn't the one removed
        for itemKey, buttons in pairs(buttonsByItemKey) do
            if not currentItemsByKey[itemKey] then
                -- This item type no longer exists - convert buttons to ghosts
                for _, button in ipairs(buttons) do
                    -- Find the slotKey for this button
                    for slotKey, btn in pairs(buttonsBySlot) do
                        if btn == button and cachedItemData[slotKey] then
                            local bagID, slot = slotKey:match("^(-?%d+):(%d+)$")
                            bagID = tonumber(bagID)
                            slot = tonumber(slot)
                            if bagID and slot then
                                ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                                cachedItemData[slotKey] = nil
                                cachedItemCount[slotKey] = nil
                                button:SetAlpha(hasSearch and 0.3 or 1)
                                ghostsCreated = ghostsCreated + 1
                            end
                            break
                        end
                    end
                end
            end
        end

        ns:Debug("CategoryView INCREMENTAL: reused=", buttonsReused, "updated=", buttonsUpdated, "counts=", countUpdates, "ghostsNew=", ghostsCreated, "ghostsReused=", ghostsReused)

        -- Update footer slot info (show regular bags only, special bags in tooltip)
        local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
        local totalSlots, freeSlots = BagScanner:GetTotalSlots()
        Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
        Footer:Update()
        return
    end

    -- Single view: full incremental update (items stay in fixed slots)
    -- Optimized: Only iterate buttons in dirty bags using buttonsByBag index
    if checkAllBags then
        -- Fallback: check all bags
        for bagID, slotButtons in pairs(buttonsByBag) do
            local bagData = bags[bagID]
            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil

                if oldItemID ~= newItemID then
                    if newItemData then
                        ItemButton:SetItem(button, newItemData, iconSize, false)
                        cachedItemData[slotKey] = newItemID
                        cachedItemCount[slotKey] = newItemData.count
                        if hasSearch and not SearchBar:ItemMatchesFilters(frame, newItemData) then
                            button:SetAlpha(0.15)
                        else
                            button:SetAlpha(1)
                        end
                    else
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        button:SetAlpha(hasSearch and 0.3 or 1)
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
                local bagData = bags[bagID]
                for slot, button in pairs(slotButtons) do
                    local slotKey = bagID .. ":" .. slot
                    local newItemData = bagData and bagData.slots and bagData.slots[slot]
                    local oldItemID = cachedItemData[slotKey]
                    local newItemID = newItemData and newItemData.itemID or nil

                    if oldItemID ~= newItemID then
                        -- Item actually changed - update button
                        if newItemData then
                            ItemButton:SetItem(button, newItemData, iconSize, false)
                            cachedItemData[slotKey] = newItemID
                            cachedItemCount[slotKey] = newItemData.count
                            if hasSearch and not SearchBar:ItemMatchesFilters(frame, newItemData) then
                                button:SetAlpha(0.15)
                            else
                                button:SetAlpha(1)
                            end
                        else
                            ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                            cachedItemData[slotKey] = nil
                            cachedItemCount[slotKey] = nil
                            button:SetAlpha(hasSearch and 0.3 or 1)
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

    -- Update footer slot info (show regular bags only, special bags in tooltip)
    local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
    local totalSlots, freeSlots = BagScanner:GetTotalSlots()
    Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    Footer:Update()
end

-- dirtyBags: table of {bagID = true} for bags that were updated
ns.OnBagsUpdated = function(dirtyBags)
    ns:Debug("OnBagsUpdated called, frame shown:", frame and frame:IsShown() or false)
    -- Only auto-refresh when viewing current character
    if not viewingCharacter then
        if frame and frame:IsShown() then
            local viewType = Database:GetSetting("bagViewType") or "single"
            ns:Debug("OnBagsUpdated refreshing, viewType:", viewType)
            -- Use incremental update if layout is cached (for both single and category view)
            -- This preserves ghost slots when items are removed
            if layoutCached then
                BagFrame:IncrementalUpdate(dirtyBags)
            else
                BagFrame:Refresh()
            end
        end
    end
end

UpdateFrameAppearance = function()
    if not frame then return end

    local isViewingCached = viewingCharacter ~= nil

    -- Background alpha
    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")

    -- Apply theme background (ButtonFrameTemplate for Blizzard, backdrop for Guda)
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)

    Header:SetBackdropAlpha(bgAlpha)

    -- Update slot background alpha (item icons stay fully visible)
    ItemButton:UpdateSlotAlpha(bgAlpha)

    -- Update icon font size and tracked bar
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

    -- Show/Hide search bar (always hide for cached views)
    local showSearchBar = Database:GetSetting("showSearchBar")
    local showFooter = Database:GetSetting("showFooter")
    -- Always show footer space for cached views (money display)
    local footerHeight = (not showFooter and not isViewingCached) and Constants.FRAME.PADDING or (Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING + 6)

    frame.container:ClearAllPoints()
    if showSearchBar then
        SearchBar:Show(frame)
        frame.container:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + SearchBar:GetTotalHeight(frame) + Constants.FRAME.PADDING + 6))
    else
        SearchBar:Hide(frame)
        frame.container:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2))
    end
    frame.container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING, footerHeight)

    -- Footer visibility (always show money for cached views)
    if isViewingCached then
        Footer:ShowCached(viewingCharacter)
    elseif showFooter then
        Footer:Show()
    else
        Footer:Hide()
    end

end

-- Settings that only need appearance update (no full refresh)
local appearanceSettings = {
    bgAlpha = true,
    showBorders = true,
    iconFontSize = true,
    trackedBarSize = true,
    trackedBarColumns = true,
    questBarSize = true,
    questBarColumns = true,
    theme = true,
}

-- Settings that need both appearance update AND resize
local resizeSettings = {
    showFooter = true,
    showSearchBar = true,
    showFilterChips = true,
}

-- Debounce state for QuestBar toggle
local questBarDebounceTimer = nil
local questBarLastValue = nil
local QUESTBAR_DEBOUNCE_DELAY = 0.2

local function OnSettingChanged(event, key, value)
    -- Handle QuestBar toggle instantly with debounce for rapid clicks
    if key == "showQuestBar" then
        local QuestBar = ns:GetModule("QuestBar")
        if not QuestBar then return end

        -- Cancel any pending debounce
        if questBarDebounceTimer then
            questBarDebounceTimer:Cancel()
            questBarDebounceTimer = nil
        end

        -- Show/hide instantly on first toggle
        if questBarLastValue == nil or questBarLastValue ~= value then
            if value then
                QuestBar:Show()
                QuestBar:Refresh()
            else
                QuestBar:Hide()
            end
            questBarLastValue = value
        end

        -- Debounce to reset state after rapid clicks settle
        questBarDebounceTimer = C_Timer.NewTimer(QUESTBAR_DEBOUNCE_DELAY, function()
            questBarDebounceTimer = nil
        end)
        return
    end

    if not frame or not frame:IsShown() then return end

    -- When changing view type while viewing another character, reset to current character
    if key == "bagViewType" and viewingCharacter then
        viewingCharacter = nil
        Header:SetViewingCharacter(nil, nil)
    end

    if appearanceSettings[key] then
        UpdateFrameAppearance()
    elseif resizeSettings[key] then
        UpdateFrameAppearance()
        BagFrame:Refresh()
    elseif key == "hoverBagline" then
        -- Refresh footer layout for hover bagline mode (preserves cached view state)
        UpdateFrameAppearance()
    elseif key == "groupIdenticalItems" then
        -- Force full release when toggling item grouping to prevent visual artifacts
        -- Item structure changes fundamentally (grouped vs individual) but keys stay same
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        BagFrame:Refresh()
    else
        BagFrame:Refresh()
    end
end

SaveFramePosition = function()
    if not frame then return end
    local point, _, relativePoint, x, y = frame:GetPoint()
    Database:SetSetting("framePoint", point)
    Database:SetSetting("frameRelativePoint", relativePoint)
    Database:SetSetting("frameX", x)
    Database:SetSetting("frameY", y)
end

RestoreFramePosition = function()
    if not frame then return end
    local point = Database:GetSetting("framePoint")
    local relativePoint = Database:GetSetting("frameRelativePoint")
    local x = Database:GetSetting("frameX")
    local y = Database:GetSetting("frameY")

    frame:ClearAllPoints()
    if point and x and y then
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    else
        -- Default position: bottom-right corner
        frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -5, 5)
    end
end

-- Sort bags using SortEngine
function BagFrame:SortBags()
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        SortEngine:SortBags()
    else
        ns:Print("SortEngine not loaded")
    end
end

-- Restack items and clean ghost slots (for category view)
-- This combines partial stacks without fully sorting the bags
function BagFrame:RestackAndClean()
    if not frame or not frame:IsShown() then return end

    -- Play sound feedback
    PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)

    -- Use SortEngine's restack function (consolidates stacks without sorting)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        SortEngine:RestackBags(function()
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
                    buttonPositions = {}
                    categoryViewItems = {}
                    lastCategoryLayout = nil
                    lastTotalItemCount = 0
                    pseudoItemButtons = {}
                    layoutCached = false
                    lastLayoutSettings = nil

                    -- Rescan and refresh
                    BagScanner:ScanAllBags()
                    BagFrame:Refresh()
                end
            end)
        end)
    else
        -- Fallback if no SortEngine
        BagScanner:ScanAllBags()
        BagFrame:Refresh()
    end
end

-- Clean ghost slots without restacking (used when items are removed externally, e.g., leaving BG)
function BagFrame:Clean()
    if not frame then return end

    -- Release all buttons (they would be orphaned otherwise)
    ItemButton:ReleaseAll(frame.container)

    -- Clear all layout caches (removes ghost slots)
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    buttonPositions = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil

    -- Rescan and refresh
    BagScanner:ScanAllBags()
    if frame:IsShown() then
        BagFrame:Refresh()
    end
end

function BagFrame:TransferMatchedItems()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(L["TRANSFER_COMBAT"], 1.0, 0.1, 0.1, 1.0)
        return
    end
    if not frame then return end

    local bags = BagScanner:GetCachedBags()
    if not bags then return end

    -- Determine target bank type for UseContainerItem
    local bankType = nil
    if ns.IsRetail then
        local BankFooter = ns:GetModule("BankFrame.BankFooter")
        if BankFooter then
            local currentBankType = BankFooter:GetCurrentBankType()
            if currentBankType == "warband" then
                bankType = Enum.BankType.Account
            end
        end
    end

    for bagID, bagData in pairs(bags) do
        if bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                if itemData and itemData.itemID and SearchBar:ItemMatchesFilters(frame, itemData) then
                    C_Container.UseContainerItem(bagID, slot, nil, bankType)
                end
            end
        end
    end
end

Events:Register("SETTING_CHANGED", OnSettingChanged, BagFrame)

-- Refresh when categories are updated (reordered, grouped, etc.)
-- Force full refresh by releasing all buttons since category assignments changed
Events:Register("CATEGORIES_UPDATED", function()
    if frame and frame:IsShown() then
        -- Release all buttons to force full refresh (category assignments changed)
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        BagFrame:Refresh()
    end
end, BagFrame)

-- Update money display when money changes
Events:Register("PLAYER_MONEY", function()
    if frame and frame:IsShown() then
        Footer:UpdateMoney()
        Database:SaveMoney(GetMoney())
    end
end, BagFrame)

-- Update item lock state (when picking up/putting down items)
Events:Register("ITEM_LOCK_CHANGED", function(event, bagID, slotID)
    -- Skip when viewing cached character - lock state is for current character only
    if viewingCharacter then return end
    if frame and frame:IsShown() and bagID and slotID then
        ItemButton:UpdateLockForItem(bagID, slotID)
    end
end, BagFrame)

-- Clean ghost slots when entering world (leaving BG, instance, etc.)
-- This handles temporary items being removed (e.g., AV-only items when leaving AV)
Events:Register("PLAYER_ENTERING_WORLD", function()
    -- Small delay to let bag contents stabilize after zone transition
    C_Timer.After(0.5, function()
        BagFrame:Clean()
    end)
end, BagFrame)

-- Refresh when interaction windows open/close to toggle item grouping
-- Items are shown ungrouped when bank/trade/mail/merchant/auction is open
local function RefreshForInteractionWindow()
    if frame and frame:IsShown() then
        -- Defer during combat - PLAYER_REGEN_ENABLED will refresh open bags
        if InCombatLockdown() then
            RegisterCombatEndCallback()
            return
        end
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "category" then
            -- Force full refresh since grouping state changed
            ItemButton:ReleaseAll(frame.container)
            buttonsByItemKey = {}
            BagFrame:Refresh()
        end
    end
end

-- Trade window
Events:Register("TRADE_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("TRADE_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Mail window
Events:Register("MAIL_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("MAIL_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Merchant/Vendor window
Events:Register("MERCHANT_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("MERCHANT_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Auto-vendor gray items at merchant
local function AutoVendorJunk()
    if not Database:GetSetting("autoVendorJunk") then return end

    local totalPrice = 0
    local itemsSold = 0

    for bagID = Constants.PLAYER_BAG_MIN, Constants.PLAYER_BAG_MAX do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.quality == 0 then
                local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemInfo.hyperlink)
                if sellPrice and sellPrice > 0 then
                    C_Container.UseContainerItem(bagID, slot)
                    totalPrice = totalPrice + sellPrice * itemInfo.stackCount
                    itemsSold = itemsSold + 1
                end
            end
        end
    end

    if itemsSold > 0 then
        ns:Print(string.format(L["AUTO_VENDOR_SOLD"], itemsSold, GetCoinTextureString(totalPrice)))
    end
end
Events:Register("MERCHANT_SHOW", AutoVendorJunk, "AutoVendor")

-- Auction house
Events:Register("AUCTION_HOUSE_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("AUCTION_HOUSE_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Bank window (our own bank frame showing affects grouping)
-- Small delay on open to ensure BankFrame is fully shown before checking
Events:Register("BANKFRAME_OPENED", function()
    C_Timer.After(0.05, function()
        RefreshForInteractionWindow()
        if frame then SearchBar:UpdateTransferState(frame) end
    end)
end, BagFrame)
Events:Register("BANKFRAME_CLOSED", function()
    RefreshForInteractionWindow()
    if frame then SearchBar:UpdateTransferState(frame) end
end, BagFrame)

Events:OnPlayerLogin(function()
    isInitialized = true
    ns:Print(string.format(L["ADDON_LOADED"], ns.version))

    -- Pre-create the bag frame and pre-warm item button pool
    -- This must happen before combat to avoid taint issues when opening bags during combat
    -- (ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat)
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end
    ItemButton:PreWarm(frame.container, 200)

    -- Override default bag functions to use GudaBags
    ToggleBackpack = function()
        BagFrame:Toggle()
    end

    ToggleBag = function(bagID)
        BagFrame:Toggle()
    end

    OpenAllBags = function()
        BagFrame:Show()
    end

    CloseAllBags = function()
        BagFrame:Hide()
    end

    OpenBag = function(bagID)
        BagFrame:Show()
    end

    CloseBag = function(bagID)
        BagFrame:Hide()
    end

    OpenBackpack = function()
        BagFrame:Show()
    end

    CloseBackpack = function()
        BagFrame:Hide()
    end

    ToggleAllBags = function()
        BagFrame:Toggle()
    end
end, BagFrame)
