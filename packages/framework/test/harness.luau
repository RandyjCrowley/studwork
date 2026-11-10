--!strict
--[[
	StudWork module test harness (module-api.md §15), pure Lune, no Studio. Modeled on §15's
	sketch and packages/core/tests/harness.luau; this is what StudWork.test.harness will expose.

	local h = Harness.new({ modules = { A, B }, servers = { A = implA, B = implB },
	                        config = { B = { ... } }, items = { ... }, serverConfig = { ... } })
	local p = h:addPlayer({ userId = 1, data = nil })   -- mock player + mock store (seeded save)
	h:tick(10)                                           -- advance the shared ticker + clock
	h:action(p, A, "doThing", "arg")                     -- loaded check + pcall
	h:rejoin(p, { secondsAway = 3600 })                  -- save -> release -> load -> migrate
	h:use(A).something(p)
	h:saved(p)                                           -- the stored save (deep copy)

	Harness.boot(opts) -> (h?, err?) returns the boot error instead of raising (fail-closed tests).
]]

local Server = (require :: any)(script.Parent.Parent.server)

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
}

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

function Harness.addPlayer(self: any, spec: { userId: number, name: string?, data: any? }): any
	local p = self.players[spec.userId] or Harness.player(spec.userId, spec.name)
	self.players[spec.userId] = p
	if spec.data ~= nil then
		self.store.save(spec.userId, spec.data)
	end
	p.loaded = self.runtime.playerAdded(p)
	return p
end

function Harness.removePlayer(self: any, p: any)
	self.runtime.playerRemoving(p)
end

function Harness.rejoin(self: any, p: any, opts: { secondsAway: number? }?)
	self.runtime.playerRemoving(p)
	self.clock += (opts and opts.secondsAway) or 0
	p.loaded = self.runtime.playerAdded(p)
	return p
end

function Harness.tick(self: any, seconds: number)
	local whole = math.floor(seconds)
	for _ = 1, whole do
		self.clock += 1
		self.runtime.tick(1)
	end
	local rest = seconds - whole
	if rest > 0 then
		self.clock += rest
		self.runtime.tick(rest)
	end
end

function Harness.action(self: any, p: any, ref: any, name: string, ...: any): (boolean, any)
	return self.runtime.action(p, ref, name, ...)
end

function Harness.use(self: any, ref: any): any
	return self.runtime.use(ref)
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
