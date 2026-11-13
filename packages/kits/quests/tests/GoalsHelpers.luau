--!nocheck
--[[
	Goals spec helpers (Lune only; packages/kits/quests/tests/, not synced by Rojo). Builder C's own
	file next to Fixtures.luau.

	  G.boot(opts) -> h          StudWork.test.harness with Goals (+ Economy unless opts.modules):
	      opts.chain, opts.goals (extra config.Goals keys), opts.modules, opts.servers, opts.probes,
	      opts.funnel (analytics.funnel; default "Joined" + every chain funnel step), any harness option
	  G.funnels(h, p?) -> { string }   funnel step names logged (for p), in order
	  G.count(list, value) -> number
	  G.signalLog(h) -> log      records GoalChanged / ChainDone: log.changed = { { id, prev } },
	                             log.done = n
	  G.txProbe() -> probe       a probe module whose api.inTx(player, goalId) calls Goals.complete
	                             from INSIDE its own ctx.tx: returns (txOk, completeOk, reason)
	  G.fakeQuests(states) -> part   a Quests server part for `servers`: state(p, id) reads
	                             states[id] ({ status, values, objective? }), def(id) for every key
	                             of states (one objective, default counter target 3), signals Completed/Claimed/Progressed
	                             (F.signal) in part.fired
	  G.extraGoal(h, p) -> wire? the replicated extra.goal
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local F = require("packages/kits/quests/tests/Fixtures.luau")

local G = {}

G.F = F
G.Goals = F.Goals
G.Quests = F.Quests
G.Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))

function G.boot(opts)
	local o = table.clone(opts or {})
	local chain = o.chain or {}
	local goalsCfg = { chain = chain }
	for k, v in o.goals or {} do
		goalsCfg[k] = v
	end
	local funnel = o.funnel
	if funnel == nil then
		funnel = { "Joined" }
		for _, g in chain do
			if g.funnel then
				table.insert(funnel, g.funnel)
			end
		end
	end
	local config = table.clone(o.config or {})
	config.Goals = goalsCfg
	local modules = o.modules or { G.Economy, G.Goals }
	if table.find(modules, G.Economy) and config.Economy == nil then
		config.Economy = F.economy()
	end
	o.chain, o.goals, o.funnel = nil, nil, nil
	o.config = config
	o.modules = modules
	o.analytics = o.analytics or { funnel = funnel }
	return F.harness(o)
end

function G.funnels(h, p)
	local out = {}
	for _, a in h.fake.analytics do
		if a.kind == "funnel" and (p == nil or a.player == p) and a.name ~= "Joined" then
			table.insert(out, a.name)
		end
	end
	return out
end

function G.count(list, value)
	local n = 0
	for _, v in list do
		if v == value then
			n += 1
		end
	end
	return n
end

function G.signalLog(h)
	local log = { changed = {}, done = 0 }
	local api = h:use(G.Goals)
	api.signals.GoalChanged:Connect(function(_p, id, prev)
		table.insert(log.changed, { id = id, prev = prev })
	end)
	api.signals.ChainDone:Connect(function()
		log.done += 1
	end)
	return log
end

function G.txProbe()
	local probe = {}
	local ctx
	probe.ref = StudWork.defineModule({
		name = "GoalsTxProbe",
		version = "1.0.0",
		framework = "^1.7.0",
		optional = { G.Goals },
		data = { key = "goalstxprobe", version = 1, default = { n = 0 } },
	})
	probe.part = {
		init = function(c)
			ctx = c
		end,
		api = {
			inTx = function(player, goalId)
				local okC, why
				local okTx = ctx.tx(player, function(tx)
					ctx.section(tx).n += 1
					okC, why = ctx.deps[G.Goals].complete(player, goalId)
				end)
				return okTx, okC, why
			end,
		},
	}
	return probe
end

-- a signal whose state lives in upvalues (the framework freezes a module's api tables deeply)
local function closureSignal()
	local handlers = {}
	local signal = {}
	function signal.Connect(_self, fn)
		table.insert(handlers, fn)
		return {
			Disconnect = function()
				local i = table.find(handlers, fn)
				if i then
					table.remove(handlers, i)
				end
			end,
		}
	end
	function signal.Fire(_self, ...)
		for _, fn in table.clone(handlers) do
			fn(...)
		end
	end
	return signal
end

function G.fakeQuests(states)
	local part = { fired = {} }
	local signals = {
		Completed = closureSignal(),
		Claimed = closureSignal(),
		Progressed = closureSignal(),
		Rotated = closureSignal(),
	}
	part.fired = signals
	part.api = {
		state = function(_player, id)
			return states[id]
		end,
		def = function(id)
			if states[id] == nil then
				return nil
			end
			local objective = states[id].objective or { kind = "counter", key = "k", target = 3 }
			return { id = id, kind = "oneTime", objectives = { objective } }
		end,
		signals = signals,
	}
	return part
end

function G.extraGoal(h, p)
	local state = h:state(p)
	local slice = state and state.modules and state.modules.Goals
	return slice and slice.extra and slice.extra.goal
end

return G
