--!nocheck
--[[
	StudWork.test: the public test entry (module-api.md §15). Lune only (it is served by the
	testkit's ServerScriptService.FrameworkTest; it is not in any Rojo build).

	  local h = StudWork.test.harness({ modules = { Collection..., MyModule }, config = { ... } })
	  local p = h:addPlayer({ userId = 1, data = nil })   -- mock player + store (seeded save)
	  h:tick(10)                                           -- the shared ticker + the framework clock
	  h:action(p, MyModule, "doThing", "arg")              -- rate limit + validation + pcall
	  h:purchase(p, "CoinPack1000", { retries = 2 })       -- receipt re-delivery simulation
	  h:rejoin(p, { secondsAway = 3600 })                  -- save -> load -> migrate -> offline
	  h:use(Economy).balance(p)
	  h:saved(p)                                           -- the stored (sectioned) save
	  h:console("economy", "grant", "100", "Coins")        -- a console line -> the reply text
	  h:sent("Notifications", "PromptOptIn")               -- what a module sent to a client (v1.7.0)

	The full list of options and methods: docs/framework/testing.md. Under the testkit's fake `game`,
	Workspace is an empty world, Players lists the harness's players and HttpService has GenerateGUID
	and JSON encode/decode.

	Options beyond Harness.new: every module's server part is found like a live game finds it
	(ServerScriptService.Modules.<Name>, module-api.md §19.9), so kit modules run for real; `servers = { Name = part }` injects
	a part (a test double, or the module under test) and wins over the live lookup. Several harnesses given the
	same `store = StudWork.test.memoryStore()` share one store (store.failNext(n) injects failures).

	  StudWork.test.boot(opts) -> (h?, err?)   a boot error is returned instead of raised
	  StudWork.test.memoryStore()              a shared in-memory store with failure injection
	  StudWork.test.legacyStore(seed?)         (v1.6.0) a game's OLD stores, in memory, read-only for the
	                                           framework (harness({ legacy = store }), adopting.md §3)
	  StudWork.test.player(userId, name?)      a bare mock player
	  StudWork.test.sim                        the multi-server simulation (real ProfileStore on a
	                                           mock DataStore, several servers, crashes, latency,
	                                           failure injection): sim.world(opts), sim.server(world,
	                                           opts), sim.gameServer(world, projectPath), sim.saved /
	                                           sim.section (the stored sectioned save), ...
	                                           see packages/framework/test/sim/README.md
]]

local Harness = require(script.Parent.harness)
-- The live server-part lookup (module-api.md §19.9): ServerScriptService.Modules[ref.server],
-- new() for a part factory, the Net child as `net`. The testkit's fake `game` maps every module
-- folder (packages/kits/*/*, examples/modules/*) there exactly like Rojo
-- (tools/lune/ModuleDiscovery.luau), so this is what a live game resolves to.
local Loader = require(script.Parent.Parent.server.Loader)
-- no Blink wire under Lune: drive actions with h:action; a generated Net.luau is never required
local NO_NET = { bindNet = false }

local Test = {}

-- (v1.7.0) No Blink wire under Lune, so a part loaded here has no generated Net module. Give it a
-- fake one instead: one recording event per event in the module's net.blink, so a module that
-- asks a client something (ctx.net.fire(player, part.net.PromptOptIn, ...)) works, and the spec
-- reads what was sent with h:sent(...). A client's request goes the other way: h:action(p, ref,
-- "name", ...) for a module action (an action backed by an event of the same name in net.blink).
-- Only a part without its own `net` and whose folder has a net.blink gets one.
local function withFakeNet(ref: any, part: any, log: { any }): any
	if type(part) ~= "table" or part.net ~= nil then
		return part
	end
	local ok, events = pcall(function(): any
		local modules = game:GetService("ServerScriptService"):FindFirstChild("Modules")
		local instance = modules and modules:FindFirstChild(ref.server)
		return instance and instance.__blinkEvents
	end)
	if not ok or type(events) ~= "table" or #events == 0 then
		return part
	end
	local net: { [string]: any } = {}
	for _, e in events do
		net[e.name] = Harness.fakeEvent(`{ref.name}.{e.name}`, log)
	end
	if table.isfrozen(part) then
		part = table.clone(part)
	end
	part.net = net
	return part
end

-- A plain table, built up front (Lune file reads yield, so no lazy metamethod lookup).
local function withModules(opts: any): any
	local injected = opts.servers or {}
	local servers = {}
	local netLog = {}
	for _, ref in opts.modules or {} do
		if type(ref) == "table" and type(ref.name) == "string" then
			if injected[ref.name] ~= nil then
				servers[ref.name] = injected[ref.name]
			else
				servers[ref.name] = withFakeNet(ref, Loader.defaultLoadServer(ref, nil, NO_NET), netLog)
			end
		end
	end
	local o = table.clone(opts)
	o.servers = servers
	o.moduleNetLog = netLog
	return o
end

function Test.harness(opts: any): any
	return Harness.new(withModules(opts))
end

function Test.boot(opts: any): (any, string?)
	return Harness.boot(withModules(opts))
end

Test.memoryStore = Harness.memoryStore
Test.legacyStore = Harness.legacyStore -- (added in v1.6.0)
Test.player = Harness.player
-- (added in v1.7.0, §23.10) StudWork.test.fakes: engine-service and Open Cloud stand-ins
Test.fakes = require(script.Parent.Fakes)

Test.sim = require(script.Parent.sim.Fixtures)

return Test
