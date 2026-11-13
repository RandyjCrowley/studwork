--!nocheck
--[[
	Quests kit test fixtures (Lune only; packages/kits/quests/tests/, not synced by Rojo).

	Config builders (plain tables; pass them as config.Quests / config.Goals):
	  F.counter(key, target?, label?)            a counter objective
	  F.source(source, target?, params?)         an add-source objective
	  F.threshold(source, target?, params?)      a value-source objective
	  F.ack(key)                                 an ack objective
	  F.currency(amount?, currency?) / F.item(itemId, count?) / F.roll(tableId) / F.custom(handler, params?)
	  F.quest(kind, objectives?, extra?)         one quest (objectives default: one counter "<kind>Key")
	  F.daily(extra?) F.weekly(extra?) F.chain(extra?) F.oneTime(extra?) F.repeatable(extra?) F.event(eventId?, extra?)
	  F.questsConfig(overrides?)                 a config with every quest kind: 4 daily (d1..d4),
	                                             3 weekly (w1..w3), chain story = { s1, s2, s3 }, oneTime
	                                             "once", grant-only "gift", repeatable "rep" (cap 2),
	                                             event "ev" (event testEvent); counters only
	  F.events()                                 GameConfig.events with testEvent (manual, 600 s)
	  F.items()                                  GameConfig.items: coin, gem (Common), star (Rare)
	  F.economy()                                config.Economy (Coins, no income)
	  F.rarity()                                 config.Rarity: free table FreeCrate, paid table PaidCrate
	  F.goalsChain()                             config.Goals.chain: call, ack and source goals

	Fakes:
	  F.signal(name?) -> signal                  :Connect(fn) -> connection, :Fire(...), .fired (count)
	  F.valueSource(opts?) -> source             a probe module that registers a VALUE source with
	      Quests and/or Goals in its init. opts = { name = "testValue", module = "TestSource",
	      quests = true, goals = false, changed = true }. source.ref / source.part go in the harness
	      (modules / servers); source:set(player, n) stores a value (and fires `changed` when it has
	      one); source:fire(player) fires it by hand; source.reads counts read calls; source.changed.
	  F.rewardModule(opts?) -> rewards           a probe module with its own save section
	      ({ got = 0, last = nil }) that registers a reward handler with Quests in init; the handler
	      writes only its own section (ctx.section(tx)). opts = { handler = "testReward",
	      module = "TestRewards", fail = false (the handler errors) }. rewards.ref / rewards.part;
	      rewards.calls = { { player, params, questId } }.
	  F.harness(opts)                            StudWork.test.harness with opts.probes = { source |
	                                             rewards, ... } merged into modules and servers
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")

local F = {}

F.Quests = require(Modules:WaitForChild("Quests"):WaitForChild("module"))
F.Goals = require(Modules:WaitForChild("Goals"):WaitForChild("module"))

local function merge(base: { [any]: any }, extra: { [any]: any }?): { [any]: any }
	local out = table.clone(base)
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

--------------------------------------------------------------------------------
-- objectives and rewards
--------------------------------------------------------------------------------

function F.counter(key: string, target: number?, label: string?)
	return { kind = "counter", key = key, target = target or 3, label = label }
end

function F.source(source: string, target: number?, params: any?)
	return { kind = "source", source = source, target = target or 10, params = params }
end

function F.threshold(source: string, target: number?, params: any?)
	return { kind = "threshold", source = source, target = target or 10, params = params }
end

function F.ack(key: string)
	return { kind = "ack", key = key }
end

function F.currency(amount: number?, currency: string?)
	return { kind = "currency", amount = amount or 10, currency = currency }
end

function F.item(itemId: string, count: number?)
	return { kind = "item", item = itemId, count = count }
end

function F.roll(tableId: string)
	return { kind = "roll", table = tableId }
end

function F.custom(handler: string, params: any?)
	return { kind = "custom", handler = handler, params = params }
end

--------------------------------------------------------------------------------
-- quests
--------------------------------------------------------------------------------

function F.quest(kind: string, objectives: { any }?, extra: { [string]: any }?)
	return merge({ kind = kind, objectives = objectives or { F.counter(kind .. "Key") } }, extra)
end

function F.daily(extra: { [string]: any }?)
	return F.quest("daily", nil, extra)
end

function F.weekly(extra: { [string]: any }?)
	return F.quest("weekly", nil, extra)
end

function F.chain(extra: { [string]: any }?)
	return F.quest("chain", nil, extra)
end

function F.oneTime(extra: { [string]: any }?)
	return F.quest("oneTime", nil, extra)
end

function F.repeatable(extra: { [string]: any }?)
	return F.quest("repeatable", nil, merge({ cap = 2 }, extra))
end

function F.event(eventId: string?, extra: { [string]: any }?)
	return F.quest("event", nil, merge({ event = eventId or "testEvent" }, extra))
end

function F.questsConfig(overrides: { [string]: any }?)
	local cfg = {
		daily = { count = 3, rerollsPerSlot = 1 },
		weekly = { count = 2, rerollsPerSlot = 0 },
		quests = {
			d1 = F.quest("daily", { F.counter("coin", 5) }),
			d2 = F.quest("daily", { F.counter("crate", 3) }),
			d3 = F.quest("daily", { F.counter("shop", 1) }, { weight = 2 }),
			d4 = F.quest("daily", { F.counter("jump", 10) }),
			w1 = F.quest("weekly", { F.counter("coin", 50) }),
			w2 = F.quest("weekly", { F.counter("day", 3) }),
			w3 = F.quest("weekly", { F.counter("crate", 20) }),
			s1 = F.quest("chain", { F.counter("talk", 1) }),
			s2 = F.quest("chain", { F.counter("coin", 10) }),
			s3 = F.quest("chain", { F.counter("crate", 2) }),
			once = F.quest("oneTime", { F.counter("tutorial", 1) }),
			gift = F.quest("oneTime", { F.counter("cat", 1) }, { offer = "grant" }),
			rep = F.quest("repeatable", { F.counter("coin", 5) }, { cap = 2 }),
			ev = F.quest("event", { F.counter("coin", 5) }, { event = "testEvent" }),
		},
		chains = { story = { "s1", "s2", "s3" } },
	}
	return merge(cfg, overrides)
end

function F.events()
	return { testEvent = { durationSec = 600 } }
end

function F.items()
	return {
		{ id = "coin", name = "Coin", rarity = "Common" },
		{ id = "gem", name = "Gem", rarity = "Common" },
		{ id = "star", name = "Star", rarity = "Rare" },
	}
end

function F.economy()
	return { primaryCurrency = "Coins", startingCurrency = { Coins = 0 } }
end

function F.rarity()
	return {
		rarityTables = {
			FreeCrate = { entries = { { itemId = "coin", weight = 3 }, { itemId = "star", weight = 1 } } },
			PaidCrate = { entries = { { itemId = "gem", weight = 1 } }, paid = true },
		},
	}
end

function F.goalsChain()
	return {
		{ id = "first", check = { call = true }, funnel = "GoalFirst" },
		{ id = "open", check = { ack = true }, widget = "Quests.button" },
		{ id = "rich", check = { source = "currency", atLeast = 50 }, target = { tag = "CoinSpot" } },
	}
end

--------------------------------------------------------------------------------
-- fakes
--------------------------------------------------------------------------------

function F.signal(name: string?)
	local signal = { name = name or "signal", fired = 0, handlers = {} }
	function signal.Connect(self, fn)
		local entry = { fn = fn }
		table.insert(self.handlers, entry)
		local connection = { Connected = true }
		function connection.Disconnect(c)
			c.Connected = false
			local i = table.find(self.handlers, entry)
			if i then
				table.remove(self.handlers, i)
			end
		end
		return connection
	end
	function signal.Fire(self, ...)
		self.fired += 1
		for _, entry in table.clone(self.handlers) do
			entry.fn(...)
		end
	end
	return signal
end

function F.valueSource(opts: { [string]: any }?)
	local o = opts or {}
	local name = o.name or "testValue"
	local moduleName = o.module or "TestSource"
	local source = { name = name, reads = 0, values = {} }
	source.changed = if o.changed == false then nil else F.signal(name .. ".changed")
	local function read(player)
		source.reads += 1
		return source.values[player]
	end
	function source.set(self, player, value)
		self.values[player] = value
		if self.changed then
			self.changed:Fire(player)
		end
	end
	function source.fire(self, player)
		self.changed:Fire(player)
	end
	source.ref = StudWork.defineModule({
		name = moduleName,
		version = "1.0.0",
		framework = "^1.7.0",
		optional = { F.Quests, F.Goals },
	})
	source.part = {
		init = function(ctx)
			local spec = { read = read, changed = source.changed }
			if o.quests ~= false and ctx.isEnabled(F.Quests) then
				ctx.depsExt[F.Quests].registerSource(name, spec)
			end
			if o.goals and ctx.isEnabled(F.Goals) then
				ctx.depsExt[F.Goals].registerSource(name, spec)
			end
		end,
	}
	return source
end

function F.rewardModule(opts: { [string]: any }?)
	local o = opts or {}
	local handler = o.handler or "testReward"
	local moduleName = o.module or "TestRewards"
	local rewards = { handler = handler, calls = {} }
	rewards.ref = StudWork.defineModule({
		name = moduleName,
		version = "1.0.0",
		framework = "^1.7.0",
		optional = { F.Quests },
		data = { key = string.lower(moduleName), version = 1, default = { got = 0 } },
	})
	rewards.part = {
		init = function(ctx)
			if not ctx.isEnabled(F.Quests) then
				return
			end
			ctx.depsExt[F.Quests].registerReward(handler, function(tx, player, params, questId)
				table.insert(rewards.calls, { player = player, params = params, questId = questId })
				if o.fail then
					error("testReward failed on purpose")
				end
				local mine = ctx.section(tx) -- this module's own section only
				mine.got += 1
				mine.last = questId
			end)
		end,
	}
	return rewards
end

-- StudWork.test.harness with probes (F.valueSource / F.rewardModule results) added.
function F.harness(opts: { [string]: any })
	local o = table.clone(opts)
	local modules = table.clone(o.modules or {})
	local servers = table.clone(o.servers or {})
	for _, probe in o.probes or {} do
		table.insert(modules, probe.ref)
		servers[probe.ref.name] = probe.part
	end
	o.probes = nil
	o.modules = modules
	o.servers = servers
	return StudWork.test.harness(o)
end

return F
