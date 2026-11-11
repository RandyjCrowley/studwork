--!strict
--[[
	COMPAT (deleted in Phase 2). The v1.2 config VIEW the unchanged v1.2 kit services read
	(ctx.config.balance.*, ctx.config.items[i].incomePerSec, ctx.config.mail, ...), built from a
	v1.3 GameConfig plus each enabled module's merged + validated config (module-api.md §11).
	Pure; shared so the client (HUD palette / primary currency) builds the same view.

	Where each kit's v1.2 config lives now (Phase 1 kit agents: this is your starting point; the
	keys inside each module's config are the v1.2 `balance` keys, unchanged):

	  v1.2                          v1.3
	  balance.primaryCurrency       config.Economy.primaryCurrency      (default "Coins")
	  balance.startingCurrency      config.Economy.startingCurrency
	  balance.income                config.Economy.income
	  balance.multiplierStacking    config.Economy.multiplierStacking
	  items[i].incomePerSec         items[i].economy.incomePerSec       (Economy itemFields)
	  balance.paidCurrencies        GameConfig.compliance.paidCurrencies (framework, §14 C3)
	  balance.inventory             config.Inventory.inventory          ({ cap })
	  balance.starterItems          config.Inventory.starterItems
	  balance.rarityTables          config.Rarity.rarityTables
	  balance.mutations             config.Rarity.mutations             (Items reads it too)
	  balance.upgrades              config.Upgrades.upgrades
	  balance.rebirth               config.Rebirth.rebirth
	  balance.offline               config.Offline.offline
	  balance.streak                config.Streak.streak
	  balance.friends               config.Friends.friends
	  balance.plot                  config.Plot.plot
	  assetsFolderName              config.Plot.assetsFolderName
	  mail                          config.Mail.mail
	  palette                       GameConfig.client.palette           (framework client UI)
	  data (game table)             the game module's own data (games/<g>/modules/<gameId>)
	  analytics, products, events   unchanged, top level

	V12Config.view(gameConfig, configs, gameModule?) -> v1.2-shaped GameConfig
	  gameConfig  the v1.3 GameConfig (modules = refs)
	  configs     { [moduleName]: merged config } (framework ConfigValidate result.configs)
	  gameModule  the game's implicit module ref (its data -> v1.2 `data`)
]]

local V12Config = {}

-- module -> the v1.2 balance keys it owns
V12Config.BALANCE_OWNERS = table.freeze({
	Economy = { "primaryCurrency", "startingCurrency", "income", "multiplierStacking" },
	Inventory = { "inventory", "starterItems" },
	Rarity = { "rarityTables", "mutations" },
	Upgrades = { "upgrades" },
	Rebirth = { "rebirth" },
	Offline = { "offline" },
	Streak = { "streak" },
	Friends = { "friends" },
	Plot = { "plot" },
} :: { [string]: { string } })

-- v1.2 Modules.MODULE_ORDER: the eleven kit modules behind the bridge
V12Config.MODULE_ORDER = table.freeze({
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
})

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

-- v1.3 item (base fields + economy namespace) -> v1.2 ItemDef (incomePerSec at the top level)
function V12Config.item(item: any): any
	local out: { [string]: any } = {}
	for k, v in item do
		if k ~= "economy" then
			out[k] = copy(v)
		end
	end
	local economy = item.economy
	out.incomePerSec = if type(economy) == "table" and type(economy.incomePerSec) == "number"
		then economy.incomePerSec
		else 0
	return out
end

function V12Config.view(gameConfig: any, configs: { [string]: any }, gameModule: any?): any
	local names: { [string]: boolean } = {}
	for _, ref in (gameConfig.modules or {}) :: { any } do
		if type(ref) == "table" and type(ref.name) == "string" then
			names[ref.name] = true
		end
	end
	local modules: { string } = {}
	for _, name in V12Config.MODULE_ORDER do
		if names[name] then
			table.insert(modules, name)
		end
	end
	local balance: { [string]: any } = {}
	for owner, keys in V12Config.BALANCE_OWNERS do
		local c = configs[owner]
		if c ~= nil then
			for _, key in keys do
				if c[key] ~= nil then
					balance[key] = copy(c[key])
				end
			end
		end
	end
	balance.primaryCurrency = balance.primaryCurrency or "Coins"
	local compliance = gameConfig.compliance
	if type(compliance) == "table" and type(compliance.paidCurrencies) == "table" then
		balance.paidCurrencies = copy(compliance.paidCurrencies)
	end
	local items = {}
	for i, item in (gameConfig.items or {}) :: { any } do
		items[i] = V12Config.item(item)
	end
	local plot = configs.Plot
	local mail = configs.Mail
	local client = gameConfig.client
	local data: any = nil
	if gameModule ~= nil and gameModule.data ~= nil then
		data = { defaults = copy(gameModule.data.default), version = gameModule.data.version }
	end
	return {
		gameId = gameConfig.gameId,
		modules = modules,
		items = items,
		balance = balance,
		products = copy(gameConfig.products or { passes = {}, devProducts = {} }),
		events = copy(gameConfig.events or {}),
		palette = if type(client) == "table" then copy(client.palette) else nil,
		data = data or { defaults = {}, version = 1 },
		analytics = copy(gameConfig.analytics),
		mail = if mail ~= nil then copy(mail.mail) else nil,
		assetsFolderName = if plot ~= nil then plot.assetsFolderName else nil,
	}
end

-- The other direction, for code that still holds a v1.2-shaped GameConfig (the multi-server
-- sim's fixtures; step 4b-IIb's scaffold conversion can reuse it): v1.2 module names, `balance`,
-- `mail`, `assetsFolderName`, `palette`, `data`, items with a top-level incomePerSec -> the v1.3
-- shape. refFor(name) returns the kit module's ModuleRef. The v1.2 game table (`data`) is not a
-- GameConfig key any more: it becomes the game module's data (returned second).
function V12Config.fromV12(v12: any, refFor: (name: string) -> any): (any, any)
	local enabled: { [string]: boolean } = {}
	local modules = {}
	for _, name in v12.modules or {} do
		enabled[name] = true
		table.insert(modules, refFor(name))
	end
	local config: { [string]: any } = {}
	local function put(owner: string, key: string, value: any)
		if value ~= nil and enabled[owner] then
			config[owner] = config[owner] or {}
			config[owner][key] = copy(value)
		end
	end
	local balance = v12.balance or {}
	for owner, keys in V12Config.BALANCE_OWNERS do
		for _, key in keys do
			put(owner, key, balance[key])
		end
	end
	put("Mail", "mail", v12.mail)
	put("Plot", "assetsFolderName", v12.assetsFolderName)
	local items = {}
	for i, item in v12.items or {} do
		local out: { [string]: any } = {}
		for k, v in item do
			if k ~= "incomePerSec" then
				out[k] = copy(v)
			end
		end
		if enabled.Economy and type(item.incomePerSec) == "number" then
			out.economy = { incomePerSec = item.incomePerSec }
		end
		items[i] = out
	end
	local data = v12.data
	return {
		gameId = v12.gameId,
		modules = modules,
		config = config,
		compliance = if balance.paidCurrencies
			then { paidCurrencies = copy(balance.paidCurrencies) }
			else nil,
		items = items,
		products = copy(v12.products),
		events = copy(v12.events),
		client = if v12.palette then { palette = copy(v12.palette) } else nil,
		analytics = copy(v12.analytics),
	},
		if type(data) == "table"
			then { defaults = copy(data.defaults or {}), version = data.version or 1 }
			else { defaults = {}, version = 1 }
end

return V12Config
