local addonName, ns = ...

ns.addonName = addonName

-- Read version from TOC file (compatible with all WoW versions)
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
ns.version = GetAddOnMetadata(addonName, "Version") or "1.0.0"

ns.Modules = {}

function ns:RegisterModule(name, module)
    self.Modules[name] = module
end

function ns:GetModule(name)
    return self.Modules[name]
end

function ns:Print(...)
    local msg = string.join(" ", tostringall(...))
    print("|cff00ccff[GudaBags]|r " .. msg)
end

function ns:Debug(...)
    if not self.debugMode then return end
    local msg = string.join(" ", tostringall(...))
    print("|cff888888[GudaBags Debug]|r " .. msg)
end

ns.debugMode = false

-- Performance tracking
ns.perfStats = {
    lastScanTime = 0,      -- ms for last BagScanner:ScanDirtyBags
    lastRefreshTime = 0,   -- ms for last BagFrame:Refresh
    scanCount = 0,         -- total scans since login
    refreshCount = 0,      -- total refreshes since login
}
