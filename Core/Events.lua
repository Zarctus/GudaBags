local addonName, ns = ...

local Events = {}
ns:RegisterModule("Events", Events)

local callbacks = {}
local eventFrame = CreateFrame("Frame")

local function OnEvent(self, event, ...)
    if not callbacks[event] then return end
    for owner, callback in pairs(callbacks[event]) do
        local success, err = pcall(callback, event, ...)
        if not success then
            ns:Print("Error in", event, "handler:", err)
        end
    end
end

eventFrame:SetScript("OnEvent", OnEvent)

-- Custom events (not WoW events) don't need frame registration
local customEvents = {
    SETTING_CHANGED = true,
    BAGS_UPDATED = true,
    CATEGORIES_UPDATED = true,
}

function Events:Register(event, callback, owner)
    if not callbacks[event] then
        callbacks[event] = {}
        -- Only register with frame for WoW system events
        if not customEvents[event] then
            eventFrame:RegisterEvent(event)
        end
    end
    callbacks[event][owner] = callback
end

function Events:Unregister(event, owner)
    if not callbacks[event] then return end
    callbacks[event][owner] = nil

    local hasCallbacks = false
    for _ in pairs(callbacks[event]) do
        hasCallbacks = true
        break
    end

    if not hasCallbacks then
        callbacks[event] = nil
        -- Only unregister for WoW system events
        if not customEvents[event] then
            eventFrame:UnregisterEvent(event)
        end
    end
end

function Events:UnregisterAll(owner)
    for event in pairs(callbacks) do
        self:Unregister(event, owner)
    end
end

function Events:OnBagUpdate(callback, owner)
    self:Register("BAG_UPDATE", callback, owner)
end

function Events:OnBankOpened(callback, owner)
    self:Register("BANKFRAME_OPENED", callback, owner)
end

function Events:OnBankClosed(callback, owner)
    self:Register("BANKFRAME_CLOSED", callback, owner)
end

function Events:OnPlayerLogin(callback, owner)
    self:Register("PLAYER_LOGIN", callback, owner)
end

function Events:OnPlayerMoney(callback, owner)
    self:Register("PLAYER_MONEY", callback, owner)
end

function Events:OnAddonLoaded(callback, owner)
    self:Register("ADDON_LOADED", function(event, loadedAddon)
        if loadedAddon == addonName then
            callback(event, loadedAddon)
        end
    end, owner)
end

function Events:Fire(event, ...)
    if not callbacks[event] then return end
    for owner, callback in pairs(callbacks[event]) do
        local success, err = pcall(callback, event, ...)
        if not success then
            ns:Print("Error in", event, "handler:", err)
        end
    end
end

-------------------------------------------------
-- Throttle helper: coalesce rapid fires of the same event
-- Returns a function that, when called, fires the event
-- after `delay` seconds, resetting the timer on each call.
-------------------------------------------------
local throttleTimers = {}

function Events:FireThrottled(event, delay, ...)
    if throttleTimers[event] then
        throttleTimers[event]:Cancel()
    end
    local args = {...}
    throttleTimers[event] = C_Timer.NewTimer(delay, function()
        throttleTimers[event] = nil
        self:Fire(event, unpack(args))
    end)
end
