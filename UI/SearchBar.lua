local addonName, ns = ...

local SearchBar = {}
ns:RegisterModule("SearchBar", SearchBar)

local Constants = ns.Constants
local L = ns.L
local SearchParser = ns:GetModule("SearchParser")
local Database = ns:GetModule("Database")

local instances = {}
local searchOverlay = nil

-- Cached globals
local strfind = string.find
local strlower = string.lower
local pairs = pairs
local ipairs = ipairs
local next = next

-------------------------------------------------
-- Quality names for tooltips (indexed 0-7)
-------------------------------------------------
local QUALITY_NAMES = {
    [0] = "CHIP_QUALITY_POOR",
    [1] = "CHIP_QUALITY_COMMON",
    [2] = "CHIP_QUALITY_UNCOMMON",
    [3] = "CHIP_QUALITY_RARE",
    [4] = "CHIP_QUALITY_EPIC",
    [5] = "CHIP_QUALITY_LEGENDARY",
    [6] = "CHIP_QUALITY_ARTIFACT",
    [7] = "CHIP_QUALITY_HEIRLOOM",
}

-------------------------------------------------
-- Type chip definitions: {key, localeKey, itemType}
-------------------------------------------------
local TYPE_CHIPS = {
    {key = "Weapon",       localeKey = "CHIP_TYPE_WPN"},
    {key = "Armor",        localeKey = "CHIP_TYPE_ARM"},
    {key = "Consumable",   localeKey = "CHIP_TYPE_CON"},
    {key = "Trade Goods",  localeKey = "CHIP_TYPE_TRD"},
    {key = "Quest",        localeKey = "CHIP_TYPE_QST"},
    {key = "Junk",         localeKey = "CHIP_TYPE_JNK"},
}

-------------------------------------------------
-- Special chip definitions: {key, localeKey}
-------------------------------------------------
local SPECIAL_CHIPS = {
    {key = "boe", localeKey = "CHIP_SPECIAL_BOE"},
    {key = "new", localeKey = "CHIP_SPECIAL_NEW"},
}

-------------------------------------------------
-- Search Overlay (shared across instances)
-------------------------------------------------
local function CreateSearchOverlay()
    if searchOverlay then return end

    local overlay = CreateFrame("Button", "GudaBagsSearchOverlay", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetFrameLevel(100)
    overlay:EnableMouse(true)
    overlay:Hide()

    if overlay.SetPropagateMouseMotion then
        overlay:SetPropagateMouseMotion(true)
    else
        if overlay.SetMouseMotionEnabled then
            overlay:SetMouseMotionEnabled(false)
        end
    end

    if overlay.SetPropagateMouseClicks then
        overlay:SetPropagateMouseClicks(true)
    end

    overlay:SetScript("OnMouseDown", function()
        for _, instance in pairs(instances) do
            if instance.searchBox then
                instance.searchBox:ClearFocus()
            end
        end
        overlay:Hide()
    end)

    searchOverlay = overlay
end

-------------------------------------------------
-- Filter State (per instance)
-------------------------------------------------
local function CreateFilterState()
    return {
        qualities = {},   -- {[3]=true, [4]=true}
        types = {},       -- {["Weapon"]=true}
        specials = {},    -- {["boe"]=true}
        parsed = nil,     -- result of SearchParser:ParseSearchInput()
    }
end

local function HasAnyFilter(state)
    if next(state.qualities) then return true end
    if next(state.types) then return true end
    if next(state.specials) then return true end
    if state.parsed then return true end
    return false
end

-------------------------------------------------
-- Chip Strip UI
-------------------------------------------------

local function UpdateChipStripVisibility(searchBar)
    local state = searchBar.filterState
    local hasChips = next(state.qualities) or next(state.types) or next(state.specials)
    if searchBar.chipClearButton then
        if hasChips then
            searchBar.chipClearButton:Show()
        else
            searchBar.chipClearButton:Hide()
        end
    end
end

local function UpdateTransferButton(searchBar)
    local btn = searchBar.transferButton
    if not btn then return end

    local state = searchBar.filterState
    if not HasAnyFilter(state) then
        btn:Hide()
        return
    end

    if not searchBar.getTransferTarget then
        btn:Hide()
        return
    end

    local target = searchBar.getTransferTarget()
    if not target then
        btn:Hide()
        return
    end

    searchBar.transferTarget = target
    btn:Show()
end

local function NotifyFilterChanged(searchBar)
    UpdateChipStripVisibility(searchBar)
    UpdateTransferButton(searchBar)
    if searchBar.onSearchChanged then
        searchBar.onSearchChanged(searchBar.searchText or "")
    end
end

local function CreateQualityDot(chipStrip, qualityIndex, searchBar)
    local colors = Constants.QUALITY_COLORS[qualityIndex]
    if not colors then return nil end

    local size = Constants.FRAME.CHIP_SIZE
    local btn = CreateFrame("Button", nil, chipStrip)
    btn:SetSize(size, size)

    -- Color dot texture
    local dot = btn:CreateTexture(nil, "ARTWORK")
    dot:SetSize(size - 4, size - 4)
    dot:SetPoint("CENTER")
    dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    dot:SetVertexColor(colors[1], colors[2], colors[3])
    btn.dot = dot

    -- Border highlight (visible when active)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\WHITE8x8")
    border:SetVertexColor(colors[1], colors[2], colors[3], 0.6)
    border:Hide()
    btn.border = border

    -- Start inactive
    dot:SetAlpha(0.35)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local nameKey = QUALITY_NAMES[qualityIndex]
        GameTooltip:SetText(L[nameKey] or nameKey, colors[1], colors[2], colors[3])
        GameTooltip:Show()
        if not searchBar.filterState.qualities[qualityIndex] then
            self.dot:SetAlpha(0.6)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if not searchBar.filterState.qualities[qualityIndex] then
            self.dot:SetAlpha(0.35)
        end
    end)

    btn:SetScript("OnClick", function(self)
        local state = searchBar.filterState
        if state.qualities[qualityIndex] then
            state.qualities[qualityIndex] = nil
            self.dot:SetAlpha(0.35)
            self.border:Hide()
        else
            state.qualities[qualityIndex] = true
            self.dot:SetAlpha(1.0)
            self.border:Show()
        end
        NotifyFilterChanged(searchBar)
    end)

    btn.qualityIndex = qualityIndex
    return btn
end

local function CreateTypeChip(chipStrip, chipDef, searchBar)
    local btn = CreateFrame("Button", nil, chipStrip)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(L[chipDef.localeKey] or chipDef.key)
    btn.label = label

    -- Size to fit text + padding
    local textWidth = label:GetStringWidth() or 20
    btn:SetSize(textWidth + 10, Constants.FRAME.CHIP_SIZE)

    -- Background
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
    btn.bg = bg

    -- Start inactive
    label:SetTextColor(0.55, 0.55, 0.55)

    btn:SetScript("OnEnter", function(self)
        if not searchBar.filterState.types[chipDef.key] then
            self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        if not searchBar.filterState.types[chipDef.key] then
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end)

    btn:SetScript("OnClick", function(self)
        local state = searchBar.filterState
        if state.types[chipDef.key] then
            state.types[chipDef.key] = nil
            self.label:SetTextColor(0.55, 0.55, 0.55)
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        else
            state.types[chipDef.key] = true
            self.label:SetTextColor(1, 1, 1)
            self.bg:SetVertexColor(0.7, 0.55, 0.0, 0.9)
        end
        NotifyFilterChanged(searchBar)
    end)

    btn.chipKey = chipDef.key
    return btn
end

local function CreateSpecialChip(chipStrip, chipDef, searchBar)
    local btn = CreateFrame("Button", nil, chipStrip)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(L[chipDef.localeKey] or chipDef.key)
    btn.label = label

    local textWidth = label:GetStringWidth() or 20
    btn:SetSize(textWidth + 10, Constants.FRAME.CHIP_SIZE)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
    btn.bg = bg

    label:SetTextColor(0.55, 0.55, 0.55)

    btn:SetScript("OnEnter", function(self)
        if not searchBar.filterState.specials[chipDef.key] then
            self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        if not searchBar.filterState.specials[chipDef.key] then
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end)

    btn:SetScript("OnClick", function(self)
        local state = searchBar.filterState
        if state.specials[chipDef.key] then
            state.specials[chipDef.key] = nil
            self.label:SetTextColor(0.55, 0.55, 0.55)
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        else
            state.specials[chipDef.key] = true
            self.label:SetTextColor(1, 1, 1)
            self.bg:SetVertexColor(0.2, 0.6, 0.8, 0.9)
        end
        NotifyFilterChanged(searchBar)
    end)

    btn.chipKey = chipDef.key
    return btn
end

local function ResetChipVisuals(searchBar)
    -- Reset quality dots
    if searchBar.qualityDots then
        for _, dot in ipairs(searchBar.qualityDots) do
            dot.dot:SetAlpha(0.35)
            dot.border:Hide()
        end
    end
    -- Reset type chips
    if searchBar.typeChips then
        for _, chip in ipairs(searchBar.typeChips) do
            chip.label:SetTextColor(0.55, 0.55, 0.55)
            chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end
    -- Reset special chips
    if searchBar.specialChips then
        for _, chip in ipairs(searchBar.specialChips) do
            chip.label:SetTextColor(0.55, 0.55, 0.55)
            chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end
end

local function CreateChipStrip(searchBar, parent)
    local chipStrip = CreateFrame("Frame", nil, parent)
    chipStrip:SetHeight(Constants.FRAME.CHIP_STRIP_HEIGHT)
    chipStrip:SetPoint("TOPLEFT", searchBar, "BOTTOMLEFT", 0, -1)
    chipStrip:SetPoint("TOPRIGHT", searchBar, "BOTTOMRIGHT", 0, -1)

    local spacing = Constants.FRAME.CHIP_SPACING
    local xOffset = 4

    -- Quality dots (0-7)
    searchBar.qualityDots = {}
    for q = 0, 7 do
        local dot = CreateQualityDot(chipStrip, q, searchBar)
        if dot then
            dot:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
            xOffset = xOffset + Constants.FRAME.CHIP_SIZE + spacing
            searchBar.qualityDots[#searchBar.qualityDots + 1] = dot
        end
    end

    -- Small separator
    xOffset = xOffset + 2
    local sep1 = chipStrip:CreateTexture(nil, "ARTWORK")
    sep1:SetSize(1, Constants.FRAME.CHIP_SIZE - 2)
    sep1:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
    sep1:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep1:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    xOffset = xOffset + 1 + spacing

    -- Type chips
    searchBar.typeChips = {}
    for _, chipDef in ipairs(TYPE_CHIPS) do
        local chip = CreateTypeChip(chipStrip, chipDef, searchBar)
        chip:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
        xOffset = xOffset + chip:GetWidth() + spacing
        searchBar.typeChips[#searchBar.typeChips + 1] = chip
    end

    -- Separator
    xOffset = xOffset + 2
    local sep2 = chipStrip:CreateTexture(nil, "ARTWORK")
    sep2:SetSize(1, Constants.FRAME.CHIP_SIZE - 2)
    sep2:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
    sep2:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep2:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    xOffset = xOffset + 1 + spacing

    -- Special chips
    searchBar.specialChips = {}
    for _, chipDef in ipairs(SPECIAL_CHIPS) do
        local chip = CreateSpecialChip(chipStrip, chipDef, searchBar)
        chip:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
        xOffset = xOffset + chip:GetWidth() + spacing
        searchBar.specialChips[#searchBar.specialChips + 1] = chip
    end

    -- Clear-all button at far right
    local clearAll = CreateFrame("Button", nil, chipStrip)
    clearAll:SetSize(12, 12)
    clearAll:SetPoint("RIGHT", chipStrip, "RIGHT", -4, 0)
    clearAll:Hide()

    local clearIcon = clearAll:CreateTexture(nil, "ARTWORK")
    clearIcon:SetAllPoints()
    clearIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\close.png")
    clearIcon:SetVertexColor(0.5, 0.5, 0.5)
    clearAll.icon = clearIcon

    clearAll:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(0.8, 0.8, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["CHIP_CLEAR_ALL"] or "Clear all filters")
        GameTooltip:Show()
    end)
    clearAll:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.5, 0.5, 0.5)
        GameTooltip:Hide()
    end)
    clearAll:SetScript("OnClick", function()
        local state = searchBar.filterState
        state.qualities = {}
        state.types = {}
        state.specials = {}
        ResetChipVisuals(searchBar)
        NotifyFilterChanged(searchBar)
    end)

    searchBar.chipClearButton = clearAll
    searchBar.chipStrip = chipStrip
    return chipStrip
end

-------------------------------------------------
-- CreateSearchBar (main factory)
-------------------------------------------------
local function CreateSearchBar(parent)
    CreateSearchOverlay()

    local searchBar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    searchBar:SetHeight(Constants.FRAME.SEARCH_BAR_HEIGHT)
    searchBar:SetPoint("TOPLEFT", parent, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
    searchBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
    searchBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    searchBar:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    searchBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    local searchIcon = searchBar:CreateTexture(nil, "OVERLAY")
    searchIcon:SetSize(12, 12)
    searchIcon:SetPoint("LEFT", searchBar, "LEFT", 8, 0)
    searchIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\search.png")
    searchIcon:SetVertexColor(0.6, 0.6, 0.6)
    searchBar.searchIcon = searchIcon

    -- Clear button at the right
    local clearButton = CreateFrame("Button", nil, searchBar)
    clearButton:SetSize(10, 10)
    clearButton:SetPoint("RIGHT", searchBar, "RIGHT", -8, 0)
    clearButton:Hide()

    local clearIcon = clearButton:CreateTexture(nil, "ARTWORK")
    clearIcon:SetAllPoints()
    clearIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\close.png")
    clearIcon:SetVertexColor(0.4, 0.4, 0.4)
    clearButton.icon = clearIcon

    clearButton:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(0.7, 0.7, 0.7)
    end)
    clearButton:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.4, 0.4, 0.4)
    end)

    searchBar.clearButton = clearButton

    -- Transfer button (left of clear button)
    local transferButton = CreateFrame("Button", nil, searchBar)
    transferButton:SetSize(12, 12)
    transferButton:SetPoint("RIGHT", clearButton, "LEFT", -4, 0)
    transferButton:Hide()

    local transferIcon = transferButton:CreateTexture(nil, "ARTWORK")
    transferIcon:SetAllPoints()
    transferIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\transfer.png")
    transferIcon:SetVertexColor(1, 0.82, 0)
    transferButton.icon = transferIcon

    transferButton:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 0.5)
        if searchBar.transferTarget then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(searchBar.transferTarget.label or "Transfer")
            GameTooltip:Show()
        end
    end)
    transferButton:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(1, 0.82, 0)
        GameTooltip:Hide()
    end)
    transferButton:SetScript("OnClick", function()
        if searchBar.onTransfer then
            searchBar.onTransfer()
        end
    end)

    searchBar.transferButton = transferButton
    searchBar.transferTarget = nil
    searchBar.getTransferTarget = nil
    searchBar.onTransfer = nil

    local searchBox = CreateFrame("EditBox", nil, searchBar)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 6, 0)
    searchBox:SetPoint("RIGHT", transferButton, "LEFT", -4, 0)
    searchBox:SetHeight(18)
    searchBox:SetFontObject(GameFontHighlightSmall)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(50)

    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 0, 0)
    placeholder:SetText(L["SEARCH_PLACEHOLDER"])
    searchBox.placeholder = placeholder

    searchBar.searchBox = searchBox
    searchBar.searchText = ""
    searchBar.onSearchChanged = nil
    searchBar.filterState = CreateFilterState()

    -- Create chip strip below search bar
    CreateChipStrip(searchBar, parent)

    clearButton:SetScript("OnClick", function()
        searchBox:SetText("")
        searchBox:ClearFocus()
    end)

    -- Debounce timer for search callbacks (avoid re-filtering on every keystroke)
    local searchDebounceTimer = nil
    local SEARCH_DEBOUNCE_DELAY = 0.15  -- 150ms

    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        if text == "" then
            placeholder:Show()
            searchIcon:SetVertexColor(0.6, 0.6, 0.6)
            clearButton:Hide()
        else
            placeholder:Hide()
            searchIcon:SetVertexColor(1, 0.82, 0)
            clearButton:Show()
        end
        searchBar.searchText = text

        -- Parse search input through SearchParser (cheap, cached)
        if SearchParser then
            searchBar.filterState.parsed = SearchParser:ParseSearchInput(text)
        else
            searchBar.filterState.parsed = nil
        end

        UpdateTransferButton(searchBar)

        -- Debounce the expensive callback (re-filters all items)
        if searchDebounceTimer then
            searchDebounceTimer:Cancel()
        end

        if text == "" then
            -- Immediate callback on clear for responsive feel
            if searchBar.onSearchChanged then
                searchBar.onSearchChanged(text)
            end
        else
            searchDebounceTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE_DELAY, function()
                searchDebounceTimer = nil
                if searchBar.onSearchChanged then
                    searchBar.onSearchChanged(searchBar.searchText)
                end
            end)
        end
    end)

    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    searchBox:HookScript("OnEditFocusGained", function()
        searchOverlay:Show()
    end)

    searchBox:HookScript("OnEditFocusLost", function(self)
        searchOverlay:Hide()
        -- Clear search text when clicking outside all GudaBags frames
        local overAnyFrame = false
        for parent, _ in pairs(instances) do
            if parent:IsMouseOver() then
                overAnyFrame = true
                break
            end
        end
        if not overAnyFrame then
            self:SetText("")
        end
    end)

    return searchBar
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function SearchBar:Init(parent)
    local instance = CreateSearchBar(parent)
    instances[parent] = instance
    return instance
end

function SearchBar:GetInstance(parent)
    return instances[parent]
end

local function AreFilterChipsEnabled()
    if not Database then
        Database = ns:GetModule("Database")
    end
    return Database and Database:GetSetting("showFilterChips") or false
end

function SearchBar:Show(parent)
    local instance = instances[parent]
    if instance then
        instance:Show()
        if instance.chipStrip then
            if AreFilterChipsEnabled() then
                instance.chipStrip:Show()
            else
                instance.chipStrip:Hide()
                -- Clear chip filters when chips are disabled
                if instance.filterState then
                    instance.filterState.qualities = {}
                    instance.filterState.types = {}
                    instance.filterState.specials = {}
                    ResetChipVisuals(instance)
                    UpdateChipStripVisibility(instance)
                end
            end
        end
    end
end

function SearchBar:Hide(parent)
    local instance = instances[parent]
    if instance then
        -- Clear search text and filters when hiding
        if instance.searchBox then
            instance.searchBox:SetText("")
            instance.searchBox:ClearFocus()
        end
        if instance.filterState then
            instance.filterState.qualities = {}
            instance.filterState.types = {}
            instance.filterState.specials = {}
            instance.filterState.parsed = nil
            ResetChipVisuals(instance)
            UpdateChipStripVisibility(instance)
        end
        instance:Hide()
        if instance.chipStrip then
            instance.chipStrip:Hide()
        end
    end
end

function SearchBar:Clear(parent)
    local instance = instances[parent]
    if instance and instance.searchBox then
        instance.searchBox:SetText("")
        instance.searchBox:ClearFocus()
        -- Also clear chip filters
        if instance.filterState then
            instance.filterState.qualities = {}
            instance.filterState.types = {}
            instance.filterState.specials = {}
            instance.filterState.parsed = nil
            ResetChipVisuals(instance)
            UpdateChipStripVisibility(instance)
        end
    end
end

function SearchBar:GetSearchText(parent)
    local instance = instances[parent]
    if instance then
        return instance.searchText or ""
    end
    return ""
end

function SearchBar:SetSearchCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.onSearchChanged = callback
    end
end

-- Returns true if any filter is active (chips or text)
function SearchBar:HasActiveFilters(parent)
    local instance = instances[parent]
    if not instance then return false end
    return HasAnyFilter(instance.filterState)
end

-- Returns the total height of search bar + chip strip when visible
function SearchBar:GetTotalHeight(parent)
    local instance = instances[parent]
    if not instance then return Constants.FRAME.SEARCH_BAR_HEIGHT end
    if AreFilterChipsEnabled() then
        return Constants.FRAME.SEARCH_BAR_HEIGHT + Constants.FRAME.CHIP_STRIP_HEIGHT + 1
    end
    return Constants.FRAME.SEARCH_BAR_HEIGHT
end

-- Check if an item matches all active filters (chips + text operators)
function SearchBar:ItemMatchesFilters(parent, itemData)
    local instance = instances[parent]
    if not instance then return true end

    local state = instance.filterState
    if not HasAnyFilter(state) then return true end
    if not itemData then return false end

    -- 1) Quality chips: OR within group
    if next(state.qualities) then
        if not state.qualities[itemData.quality or -1] then
            return false
        end
    end

    -- 2) Type chips: OR within group
    if next(state.types) then
        local itemType = itemData.itemType
        local matched = false
        if itemType then
            if state.types[itemType] then
                matched = true
            end
            -- "Junk" chip matches quality 0 items
            if not matched and state.types["Junk"] and (itemData.quality or -1) == 0 then
                matched = true
            end
        elseif state.types["Junk"] and (itemData.quality or -1) == 0 then
            matched = true
        end
        if not matched then return false end
    end

    -- 3) Special chips: AND (each active special must match)
    if next(state.specials) then
        local context = {
            tooltipScanner = ns:GetModule("TooltipScanner"),
            recentItems = ns:GetModule("RecentItems"),
        }
        for specialKey in pairs(state.specials) do
            if SearchParser and not SearchParser:MatchKeyword(specialKey, itemData, context) then
                return false
            end
        end
    end

    -- 4) Parsed operators + keywords + text from search box
    if state.parsed then
        local context = {
            tooltipScanner = ns:GetModule("TooltipScanner"),
            recentItems = ns:GetModule("RecentItems"),
        }
        if SearchParser and not SearchParser:MatchesParsed(state.parsed, itemData, context) then
            return false
        end
    end

    return true
end

-- Transfer button: set the callback that determines the transfer target
function SearchBar:SetTransferTargetCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.getTransferTarget = callback
    end
end

-- Transfer button: set the callback that performs the transfer
function SearchBar:SetTransferCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.onTransfer = callback
    end
end

-- Re-evaluate transfer button visibility (call when bank opens/closes)
function SearchBar:UpdateTransferState(parent)
    local instance = instances[parent]
    if instance then
        UpdateTransferButton(instance)
    end
end

-- Legacy compatibility: plain text matching
function SearchBar:ItemMatchesSearch(itemData, searchText)
    if not searchText or searchText == "" then
        return true
    end

    if not itemData then
        return false
    end

    local searchLower = strlower(searchText)

    if itemData.name and strfind(strlower(itemData.name), searchLower, 1, true) then
        return true
    end

    if itemData.itemType and strfind(strlower(itemData.itemType), searchLower, 1, true) then
        return true
    end

    if itemData.itemSubType and strfind(strlower(itemData.itemSubType), searchLower, 1, true) then
        return true
    end

    return false
end
