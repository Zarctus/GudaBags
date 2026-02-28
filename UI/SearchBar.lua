local addonName, ns = ...

local SearchBar = {}
ns:RegisterModule("SearchBar", SearchBar)

local Constants = ns.Constants
local L = ns.L

local instances = {}
local searchOverlay = nil

local function CreateSearchOverlay()
    if searchOverlay then return end

    local overlay = CreateFrame("Button", "GudaBagsSearchOverlay", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetFrameLevel(100)
    overlay:EnableMouse(true)
    overlay:Hide()

    -- Allow mouse motion events (hover) to pass through to frames below
    -- This enables tooltips on items while search is active
    if overlay.SetPropagateMouseMotion then
        overlay:SetPropagateMouseMotion(true)
    else
        -- Fallback for older clients: disable mouse motion events
        -- by using SetMouseMotionEnabled if available
        if overlay.SetMouseMotionEnabled then
            overlay:SetMouseMotionEnabled(false)
        end
    end

    -- Allow clicks and drags to pass through to item buttons below
    if overlay.SetPropagateMouseClicks then
        overlay:SetPropagateMouseClicks(true)
    end

    -- Use OnMouseDown instead of OnClick: with propagated clicks,
    -- OnClick won't fire but OnMouseDown still fires as a notification.
    -- Only clear focus (not search text) so the propagated click can
    -- still interact with the item below without a UI refresh disrupting it.
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

    local searchBox = CreateFrame("EditBox", nil, searchBar)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 6, 0)
    searchBox:SetPoint("RIGHT", clearButton, "LEFT", -4, 0)
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

    clearButton:SetScript("OnClick", function()
        searchBox:SetText("")
        searchBox:ClearFocus()
    end)

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
        if searchBar.onSearchChanged then
            searchBar.onSearchChanged(text)
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
        -- Clear search when clicking away (unless Enter was pressed to keep filter)
        -- The overlay click also clears, but this handles other focus loss cases
        if searchOverlay:IsShown() then
            -- Focus lost while overlay is shown = user clicked on overlay, let overlay handle it
        else
            -- Focus lost by other means (tab, clicking a button, etc.) - but overlay should have caught it
            -- This is a fallback in case overlay didn't catch the click
        end
        searchOverlay:Hide()
    end)

    return searchBar
end

function SearchBar:Init(parent)
    local instance = CreateSearchBar(parent)
    instances[parent] = instance
    return instance
end

function SearchBar:GetInstance(parent)
    return instances[parent]
end

function SearchBar:Show(parent)
    local instance = instances[parent]
    if instance then
        instance:Show()
    end
end

function SearchBar:Hide(parent)
    local instance = instances[parent]
    if instance then
        instance:Hide()
        if instance.searchBox then
            instance.searchBox:ClearFocus()
        end
    end
end

function SearchBar:Clear(parent)
    local instance = instances[parent]
    if instance and instance.searchBox then
        instance.searchBox:SetText("")
        instance.searchBox:ClearFocus()
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

function SearchBar:ItemMatchesSearch(itemData, searchText)
    if not searchText or searchText == "" then
        return true
    end

    if not itemData then
        return false
    end

    local searchLower = string.lower(searchText)

    if itemData.name and string.find(string.lower(itemData.name), searchLower, 1, true) then
        return true
    end

    if itemData.itemType and string.find(string.lower(itemData.itemType), searchLower, 1, true) then
        return true
    end

    if itemData.itemSubType and string.find(string.lower(itemData.itemSubType), searchLower, 1, true) then
        return true
    end

    return false
end
