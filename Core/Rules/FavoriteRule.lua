local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")
local Database = ns:GetModule("Database")

-- Rule type: "isFavorite"
-- Value: true (match favorites) or false (match non-favorites)
RuleEngine:RegisterEvaluator("isFavorite", function(ruleValue, itemData)
    if not itemData or not itemData.itemID then return false end
    local isFav = Database:IsFavorite(itemData.itemID)
    if ruleValue == true or ruleValue == "true" then
        return isFav
    else
        return not isFav
    end
end)
