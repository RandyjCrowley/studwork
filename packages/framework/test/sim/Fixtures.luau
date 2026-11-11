--!nocheck
--[[
	GameConfig fixture for the simulation, plus small helpers shared by the scenario specs.
	Balance numbers here are TEST fixtures, not a game's balance.
]]

local World = require(script.Parent.World)

local Fixtures = {}

Fixtures.GAME_ID = "sim"
Fixtures.STORE = "PlayerData_sim"

function Fixtures.key(userId: number): string
	return "Player_" .. tostring(userId)
end

local function merge(into: { [string]: any }, from: { [string]: any })
	for k, v in from do
		if type(v) == "table" and type(into[k]) == "table" and #v == 0 then
			merge(into[k], v)
		else
			into[k] = v
		end
	end
end

-- A valid GameConfig. `balance` overrides are merged one level deep per table.
function Fixtures.config(overrides: { [string]: any }?): any
	local config = {
		gameId = Fixtures.GAME_ID,
		modules = { "Items", "Inventory", "Economy", "Offline", "Friends", "Mail" },
		items = {
			{ id = "rock", name = "Rock", rarity = "Common", incomePerSec = 2 },
			{ id = "gem", name = "Gem", rarity = "Rare", incomePerSec = 10 },
			{ id = "egg", name = "Egg", rarity = "Epic", incomePerSec = 5 },
			{ id = "dust", name = "Dust", rarity = "Common", incomePerSec = 0 },
		},
		balance = {
			primaryCurrency = "Coins",
			startingCurrency = { Coins = 0 },
			starterItems = {},
			income = { tickSeconds = 1, source = "owned" },
			multiplierStacking = "multiply",
			inventory = { cap = 3 },
			mutations = {},
			offline = { capSeconds = 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
			friends = { checkIntervalSec = 30, coPlayMultiplier = 1.5 },
		},
		products = { passes = {}, devProducts = { Coins100 = 1001 } },
		events = {},
		data = { defaults = {}, version = 1 },
	}
	if overrides then
		merge(config, World.deepCopy(overrides))
	end
	return config
end

-- One world + helpers. opts.config overrides Fixtures.config.
function Fixtures.world(opts: any?)
	local o = opts or {}
	local world = World.new({ dt = o.dt, verbose = o.verbose })
	world.config = Fixtures.config(o.config)
	return world
end

function Fixtures.server(world: any, opts: any?)
	local o = table.clone(opts or {})
	o.config = o.config or world.config
	o.modules = o.modules or o.config.modules
	return world:server(o)
end

-- The v1.3 save root of a user as it is in the mock DataStore right now (ProfileStore's `Data`
-- field: _framework, _versions and one section per module), or nil.
function Fixtures.storedRaw(world: any, userId: number): any
	local raw = world:peek(Fixtures.STORE, Fixtures.key(userId))
	return raw and raw.Data
end

-- A sectioned save as the flat v1.2 PlayerData the scenarios assert on (the inverse of
-- FrameworkSection.splitV12): every section's fields at the top level, the _framework fields,
-- schemaVersion = _framework.schemaVersion, game[gameId] = the game module's section.
-- core-v1.3.0 step 4b-IIa: the save layout changed (module-api.md §6), the assertions didn't.
function Fixtures.flatten(root: any): any
	if type(root) ~= "table" or type(root._framework) ~= "table" then
		return root -- empty template (never saved) or not a v1.3 save
	end
	local flat: { [string]: any } = {}
	for key, section in root do
		if key == "_framework" then
			for k, v in section do
				if k == "schemaVersion" then
					flat.schemaVersion = v
				elseif k ~= "_owners" then
					flat[k] = v
				end
			end
		elseif key == Fixtures.GAME_ID then
			flat.game = { [Fixtures.GAME_ID] = section }
		elseif key ~= "_versions" and type(section) == "table" then
			for k, v in section do
				flat[k] = v
			end
		end
	end
	return flat
end

-- The saved PlayerData of a user as it is in the mock DataStore right now, flattened, or nil.
function Fixtures.stored(world: any, userId: number): any
	return Fixtures.flatten(Fixtures.storedRaw(world, userId))
end

-- The ProfileStore session holder (JobId) recorded in the DataStore, or nil.
function Fixtures.lockHolder(world: any, userId: number): string?
	local raw = world:peek(Fixtures.STORE, Fixtures.key(userId))
	local session = raw and raw.MetaData and raw.MetaData.ActiveSession
	return session and session[2]
end

local function sameValue(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not sameValue(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
Fixtures.sameValue = sameValue

-- "Never two writers": every committed write that CHANGED a profile's Data must come from the
-- server that held the session lock in the value it replaced (or from a server taking a free
-- lock). Returns a list of violations (empty = fine).
function Fixtures.writerViolations(world: any, userId: number): { string }
	local violations = {}
	local key = Fixtures.key(userId)
	for _, w in world.log do
		if w.store == Fixtures.STORE and w.key == key then
			local before = w.before
			local beforeData = before and before.Data
			local afterData = w.after and w.after.Data
			if before ~= nil and not sameValue(beforeData, afterData) then
				local session = before.MetaData and before.MetaData.ActiveSession
				local holder = session and session[2]
				if holder ~= nil and holder ~= w.writer then
					table.insert(
						violations,
						string.format("t=%.2f %s changed Data while %s held the lock", w.at, w.writer, holder)
					)
				end
			end
		end
	end
	return violations
end

-- Every value fired on a signal with the given reason (CurrencyChanged history).
function Fixtures.grants(server: any, player: any, reason: string): { number }
	local list = {}
	for _, args in server.signals.CurrencyChanged.history do
		if args[1] == player and args[5] == reason then
			table.insert(list, args[4])
		end
	end
	return list
end

function Fixtures.receipt(userId: number, purchaseId: string, productId: number?): any
	return {
		PlayerId = userId,
		PurchaseId = purchaseId,
		ProductId = productId or 1001,
		CurrencySpent = 10,
		PlaceIdWherePurchased = 1,
	}
end

return Fixtures
