--!strict
--[[
	SessionLeaderboard server part. Everything it touches comes from ctx (module-api.md §5); the
	only other require is the public StudWork facade and Economy's definition (a ref, used with
	ctx.isEnabled / ctx.deps).

	Session points: in memory per player, reset on join. They come from Economy's CurrencyChanged
	(positive deltas, optionally one currency) when Economy is enabled, and from api.add.
	Every config.tickSeconds (the shared ticker): rebuild the top list (ctx.replicate.setAll "top"),
	refresh each player's "earned", and save a new best session into this module's own section.
	On leave: save the best one last time (ctx.data.update never yields, so it is allowed in
	onPlayerRemoving).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Economy"))

export type Entry = { userId: number, name: string, earned: number }

local SessionLeaderboard = {}

local ctx: any = nil
local earned: { [any]: number } = {} -- player -> points this session (loaded players only)
local top: { Entry } = {}
local newBest = StudWork.hook() -- api.onNewBest(fn(player, best))

-- Pure: the `n` highest entries, ties broken by userId (stable across servers and ticks).
function SessionLeaderboard.rank(scores: { Entry }, n: number): { Entry }
	local list = table.clone(scores)
	table.sort(list, function(a: Entry, b: Entry): boolean
		if a.earned ~= b.earned then
			return a.earned > b.earned
		end
		return a.userId < b.userId
	end)
	local out = {}
	for i = 1, math.min(n, #list) do
		out[i] = table.freeze(table.clone(list[i]))
	end
	return out
end

local function addPoints(player: any, amount: number): boolean
	local current = earned[player]
	if current == nil then
		return false -- not loaded yet, or already left
	end
	earned[player] = current + amount
	return true
end

local function saveBest(player: any)
	local points = earned[player]
	if points == nil then
		return
	end
	local improved = false
	ctx.data.update(player, function(section: any)
		if points > section.best then
			section.best = points
			improved = true
		end
	end)
	if improved then
		newBest.fire(player, points)
	end
end

local function refresh()
	local scores: { Entry } = {}
	for player, points in earned do
		table.insert(scores, { userId = player.UserId, name = player.Name, earned = points })
		ctx.replicate.set(player, "earned", points)
		saveBest(player)
	end
	top = SessionLeaderboard.rank(scores, ctx.config.top)
	ctx.replicate.setAll("top", top)
end

-- State is reset in init, so a fresh boot (a test harness, a second runtime) never sees another
-- boot's players or hooks.
function SessionLeaderboard.init(c: any)
	ctx = c
	earned = {}
	top = {}
	newBest = StudWork.hook()
end

function SessionLeaderboard.start(c: any)
	c.lifecycle.onPlayerLoaded(function(player: any)
		earned[player] = 0
		c.data.update(player, function(section: any)
			section.sessions += 1
		end)
	end)
	c.lifecycle.onPlayerRemoving(function(player: any)
		saveBest(player)
		earned[player] = nil
	end)
	c.lifecycle.onTick(c.config.tickSeconds, refresh)

	-- The optional dependency: only when the game enabled Economy (a disabled optional dependency
	-- is an erroring proxy, so check first). Its signals are part of its public API.
	if c.isEnabled(Economy) then
		c.deps[Economy].signals.CurrencyChanged:Connect(
			function(player: any, currency: string, _newBalance: number, delta: number, _reason: string?)
				if delta > 0 and (c.config.currency == nil or currency == c.config.currency) then
					addPoints(player, delta)
				end
			end
		)
	end
end

-- Public API: StudWork.use(SessionLeaderboard) on the server, ctx.deps[SessionLeaderboard] in a
-- module that depends on it. The framework freezes it.
SessionLeaderboard.api = {
	-- points this player earned this session (0 when not loaded)
	earned = function(player: any): number
		return earned[player] or 0
	end,
	-- the best session ever, as saved (updated every tickSeconds and on leave)
	best = function(player: any): number
		return ctx.data.get(player).best
	end,
	-- how many sessions this player has started in this game
	sessions = function(player: any): number
		return ctx.data.get(player).sessions
	end,
	-- the top list as of the last tick: { { userId, name, earned } }, frozen
	top = function(): { Entry }
		return table.freeze(table.clone(top))
	end,
	-- report points yourself (games without Economy, or points that aren't currency).
	-- false when the player isn't loaded.
	add = function(player: any, amount: number): boolean
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
			error("SessionLeaderboard.add: amount must be a finite number > 0", 2)
		end
		return addPoints(player, amount)
	end,
	-- fn(player, best) after a new best session is saved
	onNewBest = function(fn: (player: any, best: number) -> ())
		newBest.register(fn)
	end,
}

return SessionLeaderboard
