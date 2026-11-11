--!strict
--[[
	StudWork module test harness (module-api.md §15), pure Lune, no Studio. Modeled on §15's
	sketch and tools/lune/testkit/harness.luau; this is what StudWork.test.harness will expose.

	local h = Harness.new({ modules = { A, B }, servers = { A = implA, B = implB },
	                        config = { B = { ... } }, items = { ... }, serverConfig = { ... } })
	local p = h:addPlayer({ userId = 1, data = nil })   -- mock player + mock store (seeded save)
	h:tick(10)                                           -- advance the shared ticker + clock
	h:action(p, A, "doThing", "arg")                     -- loaded check + pcall
	h:rejoin(p, { secondsAway = 3600 })                  -- save -> release -> load -> migrate
	h:use(A).something(p)
	h:saved(p)                                           -- the stored save (deep copy)
	h:fire(p, "StateInit")                               -- a framework Blink client event
	h:fireCustom(event, p, ...)                          -- a module's own fake Blink event
	h.fake                                               -- recorded engine traffic: feedback,
	                                                     -- serverEvents, analytics, receipts...
	h:receipt({ ... }) -> "PurchaseGranted"|...          -- MarketplaceService.ProcessReceipt

	Harness.boot(opts) -> (h?, err?) returns the boot error instead of raising (fail-closed tests).
]]

local Server = (require :: any)(script.Parent.Parent.server)
local Platform = (require :: any)(script.Parent.Parent.server.Platform)
local Net = (require :: any)(script.Parent.Parent.server.Net)

local Harness = {}
Harness.__index = Harness

export type Options = {
	modules: { any },
	servers: { [string]: any }?,
	config: { [string]: any }?,
	items: { any }?,
	gameId: string?,
	theme: any?,
	products: any?,
	events: any?,
	serverConfig: any?,
	isStudio: boolean?,
	store: any?,
	startTime: number?,
	analytics: any?,
	compliance: any?,
	policy: { [number]: boolean | string }?, -- userId -> restricted, or "fail" (lookup errors)
	owned: { [number]: { [number]: boolean } }?, -- userId -> passId -> owns
}

-- A fake Blink event (client -> server: On; server -> client: Fire/FireAll), recording traffic.
function Harness.fakeEvent(name: string, log: { any }): any
	local ev: any = { name = name, listeners = {} }
	function ev.On(fn: any)
		table.insert(ev.listeners, fn)
	end
	function ev.Fire(player: any, ...: any)
		table.insert(log, { event = name, player = player, args = table.pack(...) })
	end
	function ev.FireAll(...: any)
		table.insert(log, { event = name, all = true, args = table.pack(...) })
	end
	return ev
end

-- The engine stand-in handed to Server.start (Platform.inert + recorders + players in game).
local function fakePlatform(self: any, opts: Options): any
	local fake: any = {
		serverEvents = {},
		analytics = {},
		receiptFn = nil,
		synced = {},
		consoleRun = nil,
		kicks = {},
	}
	self.fake = fake
	self.inGame = {}
	self.timers = {}
	local events: any = {}
	for _, name in Net.CLIENT_EVENTS do
		events[name] = Harness.fakeEvent(name, fake.serverEvents)
	end
	for _, name in Net.FRAMEWORK_SERVER_EVENTS do
		events[name] = Harness.fakeEvent(name, fake.serverEvents)
	end
	fake.events = events
	return Platform.inert({
		isStudio = opts.isStudio or false,
		now = function()
			return self.clock
		end,
		clock = function()
			return self.clock
		end,
		-- task.delay stand-in: fired by h:tick once the fake clock reaches it
		delay = function(seconds: number, fn: any)
			table.insert(self.timers, { at = self.clock + (seconds or 0), fn = fn })
		end,
		isPlayer = function(p: any): boolean
			return self.inGame[p] == true
		end,
		players = {
			list = function(): { any }
				local out = {}
				for p in self.inGame do
					table.insert(out, p)
				end
				table.sort(out, function(a, b)
					return a.UserId < b.UserId
				end)
				return out
			end,
			byUserId = function(id: number): any
				for p in self.inGame do
					if p.UserId == id then
						return p
					end
				end
				return nil
			end,
		},
		events = events,
		marketplace = {
			setProcessReceipt = function(fn: any)
				fake.receiptFn = fn
			end,
			-- readable here (unlike the live engine), so the §7.1 runtime check can be tested:
			-- a test replaces fake.receiptFn and ticks
			getProcessReceipt = function(): (boolean, any)
				return true, fake.receiptFn
			end,
			decision = function(name: string): string
				return name
			end,
			ownsPass = function(userId: number, id: number): boolean
				local owned = opts.owned and opts.owned[userId]
				return owned ~= nil and owned[id] == true
			end,
			onPassPurchaseFinished = function() end,
		},
		policyLookup = function(player: any): any
			local answer = opts.policy and opts.policy[player.UserId]
			if answer == "fail" then
				error("PolicyService down")
			end
			return { ArePaidRandomItemsRestricted = answer == true }
		end,
		analytics = {
			funnel = function(p: any, index: number, name: string)
				table.insert(fake.analytics, { kind = "funnel", player = p, index = index, name = name })
			end,
			economy = function(
				p: any,
				flow: string,
				currency: string,
				amount: number,
				ending: number,
				kind: string
			)
				table.insert(fake.analytics, {
					kind = "economy",
					player = p,
					flow = flow,
					currency = currency,
					amount = amount,
					ending = ending,
					type = kind,
				})
			end,
			custom = function(p: any, name: string, value: number, fields: any)
				table.insert(
					fake.analytics,
					{ kind = "custom", player = p, name = name, value = value, fields = fields }
				)
			end,
		},
		makeSync = function(hooks: any): any
			return {
				subscribe = function(player: any, state: any)
					fake.synced[player] = state
				end,
				set = function(player: any, state: any)
					fake.synced[player] = state
				end,
				remove = function(player: any)
					fake.synced[player] = nil
				end,
				flush = function()
					for player in fake.synced do
						hooks.sent(player)
					end
				end,
			}
		end,
		installConsole = function(run: any)
			fake.consoleRun = run
		end,
		kick = function(player: any, msg: string)
			table.insert(fake.kicks, { player = player, msg = msg })
			player:Kick(msg)
		end,
	})
end

function Harness.player(userId: number, name: string?): any
	local p: any = { UserId = userId, Name = name or ("Player" .. userId), kicked = nil }
	function p.Kick(self: any, msg: string)
		self.kicked = msg
	end
	return setmetatable(p, {
		__tostring = function()
			return p.Name
		end,
	})
end

local function build(opts: Options): (any, any)
	local self: any = setmetatable({}, Harness)
	self.clock = opts.startTime or 1_700_000_000
	self.store = opts.store or Server.memoryStore()
	self.logs = {}
	self.players = {}
	local servers = opts.servers or {}
	local gameConfig = {
		gameId = opts.gameId or "test-game",
		modules = opts.modules,
		config = opts.config,
		items = opts.items or {},
		theme = opts.theme,
		products = opts.products,
		events = opts.events,
		analytics = opts.analytics,
		compliance = opts.compliance,
	}
	self.gameConfig = gameConfig
	local ok, rt = pcall(Server.start, gameConfig, opts.serverConfig, {
		loadServer = function(ref: any)
			return servers[ref.name]
		end,
		store = self.store,
		now = function()
			return self.clock
		end,
		isStudio = opts.isStudio or false,
		logSink = function(level: string, msg: string)
			table.insert(self.logs, { level = level, msg = msg })
		end,
		kick = function(player: any, msg: string)
			player:Kick(msg)
		end,
		bindPlatform = false,
		platform = fakePlatform(self, opts),
	})
	if not ok then
		return nil, rt
	end
	self.runtime = rt
	return self, nil
end

function Harness.new(opts: Options): any
	local h, err = build(opts)
	if h == nil then
		error(err, 2)
	end
	return h
end

function Harness.boot(opts: Options): (any, string?)
	local h, err = build(opts)
	return h, if err == nil then nil else tostring(err)
end

-- A real client subscribes (StateInit) right after joining and is sent its state (odds included)
-- before it can buy anything, so the harness does the same for a loaded player (core-v1.3.0
-- v1.3.0: a paid roll needs the odds disclosed to the client).
-- spec.sync = false skips it (a test of the not-yet-subscribed window).
local function syncJoin(self: any, p: any, sync: boolean?)
	if p.loaded and sync ~= false then
		self.runtime.replication.subscribe(p)
		self.runtime.replication.step()
	end
end

function Harness.addPlayer(
	self: any,
	spec: { userId: number, name: string?, data: any?, sync: boolean? }
): any
	local p = self.players[spec.userId] or Harness.player(spec.userId, spec.name)
	self.players[spec.userId] = p
	if spec.data ~= nil then
		self.store.save(spec.userId, spec.data)
	end
	self.inGame[p] = true
	p.loaded = self.runtime.playerAdded(p)
	syncJoin(self, p, spec.sync)
	return p
end

function Harness.removePlayer(self: any, p: any)
	self.runtime.playerRemoving(p)
	self.inGame[p] = nil
end

function Harness.rejoin(self: any, p: any, opts: { secondsAway: number? }?)
	self.runtime.playerRemoving(p)
	self.clock += (opts and opts.secondsAway) or 0
	p.loaded = self.runtime.playerAdded(p)
	syncJoin(self, p, nil)
	return p
end

-- A framework Blink client event arriving from `p` (goes through Net: rate limit, queue, drops).
function Harness.fire(self: any, p: any, eventName: string, ...: any)
	for _, fn in self.fake.events[eventName].listeners do
		fn(p, ...)
	end
end

function Harness.fireCustom(_self: any, event: any, p: any, ...: any)
	for _, fn in event.listeners do
		fn(p, ...)
	end
end

function Harness.receipt(self: any, receipt: any): any
	assert(self.fake.receiptFn, "ProcessReceipt was not claimed")
	return self.fake.receiptFn(receipt)
end

-- The replicated state the player's client was last sent (subscribe with StateInit first).
function Harness.state(self: any, p: any): any
	self.runtime.replication.step()
	return self.fake.synced[p]
end

function Harness.console(self: any, ...: any): string
	return self.fake.consoleRun(...)
end

-- Runs every platform.delay timer that is due at the current fake clock.
function Harness.runTimers(self: any)
	local due = {}
	local keep = {}
	for _, t in self.timers do
		table.insert(if t.at <= self.clock then due else keep, t)
	end
	self.timers = keep
	for _, t in due do
		t.fn()
	end
end

function Harness.tick(self: any, seconds: number)
	local whole = math.floor(seconds)
	for _ = 1, whole do
		self.clock += 1
		self:runTimers()
		self.runtime.tick(1)
	end
	local rest = seconds - whole
	if rest > 0 then
		self.clock += rest
		self:runTimers()
		self.runtime.tick(rest)
	end
end

function Harness.action(self: any, p: any, ref: any, name: string, ...: any): (boolean, any)
	return self.runtime.action(p, ref, name, ...)
end

function Harness.use(self: any, ref: any): any
	return self.runtime.use(ref)
end

-- A developer-product purchase by `p` (module-api.md §15): builds the receipt for `product` (a
-- GameConfig.products.devProducts name or a product id) and hands it to ProcessReceipt. Roblox
-- re-delivers a receipt answered NotProcessedYet; `retries` is how many re-deliveries to try.
-- opts.redeliver: also re-deliver after PurchaseGranted (duplicate delivery). opts.purchaseId fixes
-- the PurchaseId (the same id across harnesses = the same purchase). -> (last decision, every one)
function Harness.purchase(self: any, p: any, product: string | number, opts: any?): (string, { string })
	local o = opts or {}
	local id: any = product
	if type(product) == "string" then
		local products = self.gameConfig.products
		id = products and products.devProducts and products.devProducts[product]
	end
	assert(type(id) == "number", `h:purchase: unknown product {tostring(product)}`)
	self.purchaseSeq = (self.purchaseSeq or 0) + 1
	local receipt = {
		PlayerId = p.UserId,
		PurchaseId = o.purchaseId or `harness-{self.purchaseSeq}`,
		ProductId = id,
		CurrencySpent = o.price or 0,
		PlaceIdWherePurchased = 1,
	}
	local decisions = {}
	for _ = 1, 1 + (o.retries or 0) do
		local decision = self:receipt(receipt)
		table.insert(decisions, decision)
		if decision ~= "NotProcessedYet" and not o.redeliver then
			break
		end
	end
	return decisions[#decisions], decisions
end

-- An in-memory store several harnesses can share (one "DataStore" seen by every server), with
-- failure injection: store.failNext(n) makes the next n load/save calls raise.
function Harness.memoryStore(): any
	local s = Server.memoryStore()
	local fails = 0
	local function failing(fn: any): any
		return function(...: any): ...any
			if fails > 0 then
				fails -= 1
				error("injected store failure", 0)
			end
			return fn(...)
		end
	end
	s.load = failing(s.load)
	s.save = failing(s.save)
	function s.failNext(n: number)
		fails += n
	end
	return s
end

function Harness.saved(self: any, p: any): any
	return self.store.load(p.UserId)
end

function Harness.shutdown(self: any)
	self.runtime.shutdown()
end

function Harness.warnings(self: any): { string }
	local out = {}
	for _, l in self.logs do
		if l.level == "warn" then
			table.insert(out, l.msg)
		end
	end
	return out
end

return Harness
