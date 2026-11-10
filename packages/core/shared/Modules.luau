--!strict
--[[
	Core module manifest (pure, no Roblox globals). LEAD-OWNED, part of the frozen contract.

	FOUNDATION services always run. MODULES run only when listed in GameConfig.modules.
	  requires = hard dependencies: must also be listed, or Core.start errors.
	  optional = soft integrations: used only when that module is enabled too. A service checks
	             ctx.isEnabled(name) before calling an optional dependency.
	API = the exact public function names of each server namespace (Types.<Name>API). The facade
	exposes frozen tables built from these lists, so init/start and private helpers never leak.

	resolve(list) validates a GameConfig.modules list and returns the boot order of the enabled
	modules (dependencies first, ties in MODULE_ORDER).
]]

local Modules = {}

-- Server namespaces that are always on.
Modules.FOUNDATION = { "Data", "Policy", "Analytics", "Events", "Shop" }

-- Every optional module in default boot order (a valid topological order).
Modules.MODULE_ORDER = {
	"Items",
	"Inventory",
	"Rarity",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Mail",
	"Plot",
}

export type ModuleSpec = {
	requires: { string },
	optional: { string },
}

Modules.SPECS = {
	Items = { requires = {}, optional = {} },
	Inventory = { requires = { "Items" }, optional = { "Plot", "Upgrades" } },
	Rarity = { requires = { "Items" }, optional = { "Inventory", "Economy" } },
	Economy = { requires = {}, optional = { "Items", "Rebirth", "Upgrades", "Friends" } },
	Upgrades = { requires = { "Economy" }, optional = { "Rebirth" } },
	Rebirth = { requires = { "Economy" }, optional = { "Inventory", "Upgrades", "Plot", "Items" } },
	Offline = { requires = {}, optional = { "Economy" } },
	Streak = { requires = {}, optional = { "Economy" } },
	Friends = { requires = {}, optional = { "Economy" } },
	Mail = { requires = {}, optional = {} },
	Plot = { requires = { "Inventory" }, optional = { "Items" } },
} :: { [string]: ModuleSpec }

-- Public functions per server namespace (must match Types.<Name>API exactly).
Modules.API = {
	Data = { "get", "update", "onLoaded", "isLoaded", "getGame", "updateGame", "saveAsync" },
	Policy = { "paidRandomRestricted", "isKnown" },
	Analytics = { "funnel", "economy", "custom" },
	Events = { "schedule", "trigger", "isActive", "onEnded" },
	Shop = { "onProduct", "ownsPass", "onPassOwned" },
	Items = { "register", "get", "all", "byTag", "incomeOf" },
	Inventory = { "add", "remove", "get", "list", "count", "cap", "transfer", "canTrade" },
	Rarity = { "roll", "getOdds", "getOddsDetail", "tiers" },
	Economy = {
		"grant",
		"spend",
		"balance",
		"addIncomeSource",
		"removeIncomeSource",
		"addMultiplier",
		"removeMultiplier",
		"getMultiplier",
		"getRate",
	},
	Upgrades = { "level", "cost", "purchase" },
	Rebirth = { "canRebirth", "rebirth", "cost", "multiplier" },
	Offline = { "onReturn" },
	Streak = { "onDaily", "get" },
	Friends = { "onCoPlay", "friendsInServer" },
	Mail = { "send", "onReceive" },
	Plot = { "get", "owner", "display", "clearDisplay", "slots", "onAssigned" },
} :: { [string]: { string } }

-- Client Actions that belong to a module (calling them with the module off errors).
Modules.CLIENT_ACTIONS = {
	display = "Plot",
	clearDisplay = "Plot",
	rebirth = "Rebirth",
	upgrade = "Upgrades",
	roll = "Rarity",
	gift = "Inventory",
} :: { [string]: string }

function Modules.isModule(name: any): boolean
	return type(name) == "string" and Modules.SPECS[name] ~= nil
end

function Modules.isFoundation(name: any): boolean
	return type(name) == "string" and table.find(Modules.FOUNDATION, name) ~= nil
end

function Modules.notEnabledMessage(name: string): string
	return name .. " is not enabled in GameConfig.modules"
end

-- Validates a GameConfig.modules value. Returns (order, nil) with the enabled modules in boot
-- order, or (nil, errors) listing every unknown name, duplicate and missing dependency.
function Modules.resolve(list: any): ({ string }?, { string }?)
	local errors: { string } = {}
	if type(list) ~= "table" then
		return nil, { "modules must be a list of module names (use {} for foundation only)" }
	end
	local enabled: { [string]: boolean } = {}
	for i, name in list do
		if type(i) ~= "number" then
			table.insert(errors, "modules must be a list (array), got key " .. tostring(i))
		elseif Modules.isFoundation(name) then
			table.insert(errors, `modules[{i}] '{name}' is foundation (always on); remove it from the list`)
		elseif not Modules.isModule(name) then
			table.insert(
				errors,
				`modules[{i}] unknown module '{tostring(name)}' (known: {table.concat(
					Modules.MODULE_ORDER,
					", "
				)})`
			)
		elseif enabled[name] then
			table.insert(errors, `modules[{i}] '{name}' listed twice`)
		else
			enabled[name] = true
		end
	end
	for _, name in Modules.MODULE_ORDER do
		if enabled[name] then
			for _, dep in Modules.SPECS[name].requires do
				if not enabled[dep] then
					table.insert(
						errors,
						`module '{name}' requires '{dep}': add "{dep}" to GameConfig.modules`
					)
				end
			end
		end
	end
	if #errors > 0 then
		return nil, errors
	end
	local order: { string } = {}
	for _, name in Modules.MODULE_ORDER do
		if enabled[name] then
			table.insert(order, name)
		end
	end
	return order, nil
end

return Modules
