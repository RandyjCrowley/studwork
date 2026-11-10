--!strict
--[[
	Core module loader (pure: no Roblox services beyond requiring the shared Modules manifest).

	Server.start asks the loader for a boot plan: the foundation services plus the enabled
	optional modules, in BOOT_ORDER. Disabled modules are replaced in ctx.services by a frozen
	proxy whose every field access errors with Modules.notEnabledMessage(name), so a service that
	forgets ctx.isEnabled(...) gets a clear error instead of "attempt to index nil".

	BOOT_ORDER (init() for every planned service in this order, then start() in the same order;
	Replication, Net and Console are wired by Server.start around it):
	  - Data first: everyone else registers Data.onLoaded in start(), and Data must own profiles
	    before anything reads them.
	  - Items before Rarity/Inventory (they look item defs up), Inventory before Plot (Plot
	    displays inventory items), Economy before Upgrades/Rebirth (they spend/grant).
	  - Mail.init happens in the init pass, i.e. before Data.start loads any profile, so Data's
	    queued Mail messages always find their consumer.
	  - Replication.init runs before every service init (setReplicated is safe from start()) and
	    Replication.start after every service start, so it sees each service's initial values.
	  - Net.start after all handlers are registered (pre-start requests are queued, see Net).
	This is today's v1.0 ORDER, filtered to what is enabled, so the relative order of services
	never changes between a full and a partial module list.
]]

local Modules = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Modules"))

local ModuleLoader = {}

ModuleLoader.BOOT_ORDER = table.freeze({
	"Data",
	"Items",
	"Policy",
	"Rarity",
	"Inventory",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Events",
	"Shop",
	"Analytics",
	"Mail",
	"Plot",
})

-- Validates the module list again (ConfigValidate already did) and returns the boot plan.
-- On a bad list returns (nil, message) where message is Modules.resolve's errors unchanged,
-- joined by newlines.
function ModuleLoader.plan(moduleList: any): ({ string }?, string?)
	local order, errors = Modules.resolve(moduleList)
	if order == nil then
		return nil, table.concat(errors or { "invalid GameConfig.modules" }, "\n")
	end
	local enabled: { [string]: boolean } = {}
	for _, name in order do
		enabled[name] = true
	end
	local plan: { string } = {}
	for _, name in ModuleLoader.BOOT_ORDER do
		if Modules.isFoundation(name) or enabled[name] then
			table.insert(plan, name)
		end
	end
	return plan, nil
end

-- Frozen stand-in for a disabled module: reading or writing any field errors.
function ModuleLoader.disabledProxy(name: string): any
	local message = "[Core] " .. Modules.notEnabledMessage(name)
	local proxy = setmetatable({}, {
		__index = function()
			error(message, 2)
		end,
		__newindex = function()
			error(message, 2)
		end,
		__tostring = function()
			return "DisabledModule(" .. name .. ")"
		end,
	})
	return table.freeze(proxy)
end

-- ctx.services: real modules for every planned name, proxies for every other known module.
function ModuleLoader.services(all: { [string]: any }, plan: { string }): { [string]: any }
	local out: { [string]: any } = {}
	for _, name in plan do
		assert(all[name] ~= nil, "[Core] module loader: no service implementation for " .. name)
		out[name] = all[name]
	end
	for name in Modules.SPECS do
		if out[name] == nil then
			out[name] = ModuleLoader.disabledProxy(name)
		end
	end
	return table.freeze(out)
end

-- ctx.isEnabled: foundation -> true; module -> in the enabled list.
function ModuleLoader.isEnabledFn(moduleOrder: { string }): (name: string) -> boolean
	local enabled: { [string]: boolean } = {}
	for _, name in moduleOrder do
		enabled[name] = true
	end
	return function(name: string): boolean
		return enabled[name] == true or Modules.isFoundation(name)
	end
end

return ModuleLoader
