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

-- A valid fixture GameConfig (v1.3 shape; `modules` are kit module names, `data` is the fixture
-- game module's own data). Overrides are merged recursively into every non-array table
-- (e.g. { config = { Offline = { offline = { autoPay = false } } } }).
function Fixtures.config(overrides: { [string]: any }?): any
	local config = {
		gameId = Fixtures.GAME_ID,
		modules = { "Items", "Inventory", "Economy", "Offline", "Friends", "Mail" },
		items = {
			{ id = "rock", name = "Rock", rarity = "Common", economy = { incomePerSec = 2 } },
			{ id = "gem", name = "Gem", rarity = "Rare", economy = { incomePerSec = 10 } },
			{ id = "egg", name = "Egg", rarity = "Epic", economy = { incomePerSec = 5 } },
			{ id = "dust", name = "Dust", rarity = "Common", economy = { incomePerSec = 0 } },
		},
		config = {
			Economy = {
				primaryCurrency = "Coins",
				startingCurrency = { Coins = 0 },
				income = { tickSeconds = 1, source = "owned" },
				multiplierStacking = "multiply",
			},
			Inventory = { inventory = { cap = 3 }, starterItems = {} },
			Rarity = { mutations = {} },
			Offline = {
				offline = { capSeconds = 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
			},
			Friends = { friends = { checkIntervalSec = 30, coPlayMultiplier = 1.5 } },
		},
		products = { passes = {}, devProducts = { Coins100 = 1001, Egg = 1002 } },
		events = {},
		data = { default = {}, version = 1 },
	}
	if overrides then
		merge(config, World.deepCopy(overrides))
	end
	return config
end

-- One world + helpers. opts.config overrides Fixtures.config; opts.epoch = the unix time at t = 0.
function Fixtures.world(opts: any?)
	local o = opts or {}
	local world = World.new({ dt = o.dt, verbose = o.verbose, epoch = o.epoch })
	world.config = Fixtures.config(o.config)
	return world
end

function Fixtures.server(world: any, opts: any?)
	local o = table.clone(opts or {})
	o.config = o.config or world.config
	o.modules = o.modules or o.config.modules
	return world:server(o)
end

-- A server that boots a REAL game (v1.3.0 boot tests): the game's own
-- Config, game module and ServerConfig, through its Rojo project (`projectPath`, e.g.
-- "games/<g>/default.project.json"), with the real framework and kit modules. Call on
-- the spec's main thread (the project file is read here).
function Fixtures.gameServer(world: any, projectPath: string, opts: any?)
	local Loader = require(script.Parent.Loader)
	local o = table.clone(opts or {})
	o.project = Loader.readProject(projectPath)
	o.config = { modules = {} } -- replaced by the game's own Config at boot
	return world:server(o)
end

-- Boots the game's real project (Fixtures.gameServer), joins one player, plays a few seconds and
-- leaves. Returns { names = module names in boot order, server, world, loaded, errors, bootWarnings }.
-- Used by each game's Boot.spec.luau.
function Fixtures.bootGame(projectPath: string, opts: any?): any
	local world = Fixtures.world()
	local server = Fixtures.gameServer(world, projectPath, opts)
	local names = {}
	for _, ref in server.runtime.order do
		table.insert(names, ref.name)
	end
	local p = server:join(1)
	local loaded = world:advanceUntil(function()
		return server:isLoaded(p)
	end, 30)
	world:advance(5)
	server:leave(p)
	world:advance(10)
	local bootWarnings = {}
	for _, w in server.warnings do
		if string.find(w, "failed", 1, true) or string.find(w, "invalid", 1, true) then
			table.insert(bootWarnings, w)
		end
	end
	return {
		names = names,
		server = server,
		world = world,
		loaded = loaded,
		errors = world:errors(),
		bootWarnings = bootWarnings,
		state = server.runtime.state,
	}
end

-- The v1.3 save root of a user as it is in the mock DataStore right now (ProfileStore's `Data`
-- field: _framework, _versions and one section per module), or nil.
function Fixtures.saved(world: any, userId: number): any
	local raw = world:peek(Fixtures.STORE, Fixtures.key(userId))
	return raw and raw.Data
end

-- One section of the stored save (`saved(...)[key]`), or nil.
function Fixtures.section(world: any, userId: number, key: string): any
	local root = Fixtures.saved(world, userId)
	return if type(root) == "table" then root[key] else nil
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

-- Every amount Economy granted `player` with the given reason (Economy.CurrencyChanged history).
function Fixtures.grants(server: any, player: any, reason: string): { number }
	local list = {}
	for _, args in server:heard("Economy.CurrencyChanged").history do
		if args[1] == player and args[5] == reason then
			table.insert(list, args[4])
		end
	end
	return list
end

-- A real purchase of `product` (a fixture devProduct) by `player` whose handler adds `itemId`
-- through Inventory's purchase ops, so the copy carries the "paid:<product>" source the framework
-- derives from the purchase. Advances the world until ProcessReceipt answers; returns the
-- player's instance.
local purchaseSeq = 0
function Fixtures.buyItem(world: any, server: any, player: any, product: string, itemId: string): any
	server._itemProducts = server._itemProducts or {}
	local slot = server._itemProducts[product]
	if slot == nil then
		slot = {}
		server._itemProducts[product] = slot
		server:onProduct(product, function(tx)
			slot.last = tx.use(server:ref("Inventory")).addItem(slot.itemId)
		end)
	end
	slot.itemId = itemId
	slot.last = nil
	purchaseSeq += 1
	local productId = world.config.products.devProducts[product]
	assert(productId, "sim: no fixture devProduct " .. product)
	local h = server:purchase(Fixtures.receipt(player.UserId, "buyItem-" .. purchaseSeq, productId))
	assert(
		world:advanceUntil(function()
			return h.done
		end, 30),
		"buyItem: ProcessReceipt answered"
	)
	assert(h.result == "PurchaseGranted" and slot.last ~= nil, "buyItem: " .. tostring(h.result or h.error))
	return server:use("Inventory").get(player, slot.last.uid)
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
