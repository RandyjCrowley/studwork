--!strict
--[[
	Streak: the engagement kit's server module (v1.3.0 module API). See README.md.

	Daily login streak, see StreakMath.luau for the exact rules: same day -> nothing; next day ->
	+1; one missed day is forgiven when the player returns within config.streak.graceHours after
	the missed day ended; otherwise reset to 1. Clock skew never resets. Days are counted in the
	configured time zone: config.streak.utcOffsetHours (default 0 = UTC, the v1.2 behaviour).

	Evaluated when the player's data loads and again every CHECK_INTERVAL seconds (the shared
	ticker) for players who stay online across midnight. When a day counts:
	  - section "streak" = { streak = { day, lastDay } } (v1.2 shape), and in the SAME tx the
	    reward for that day (config.streak.rewards, wrapped by loopAfter; currency defaults to
	    Economy's primary currency) through the OPTIONAL Economy dependency
	    (ctx.depsTx[Economy].grant(tx, amount, "streak", currency))
	  - api.signals.StreakAdvanced(player, day) + onDaily handlers, a "toast" and
	    analytics.custom("StreakDay", day) after the commit.

	api: onDaily(handler) -> Connection, get(player) -> { day, lastDay } (a copy),
	expiresAt(player) -> number? (v1.7.0: the unix time the streak ends without a visit),
	signals.StreakAdvanced. Console: `streak dump [userId]`, `streak advance [userId]` (Studio).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StreakMath = require(script.StreakMath)
local SignalTable = require(script.SignalTable)
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

local CHECK_INTERVAL = 60 -- seconds between midnight re-checks for online players

local Streak = {}

local ctx: any = nil
local signals = SignalTable.new()

local function streakConfig(): any
	local cfg = ctx.config.streak
	return if type(cfg) == "table" then cfg else {}
end

local function offsetHours(): number
	local h = streakConfig().utcOffsetHours
	return if type(h) == "number" and h == h then h else 0
end

local function readState(player: any): StreakMath.State?
	if not ctx.data.isLoaded(player) then
		return nil
	end
	local section = ctx.data.get(player)
	local s = if section and type(section.streak) == "table" then section.streak else {}
	return { day = tonumber(s.day) or 0, lastDay = tonumber(s.lastDay) or 0 }
end

-- Evaluates the streak at unix time `now`. Returns the new streak day when the day counted.
local function evaluate(player: any, now: number): number?
	local state = readState(player)
	if state == nil then
		return nil
	end
	local cfg = streakConfig()
	local nextState, outcome = StreakMath.advance(state, now, cfg.graceHours, offsetHours())
	if not StreakMath.counts(outcome) then
		return nil
	end
	local day = nextState.day
	local reward = StreakMath.rewardFor(day, cfg.rewards, cfg.loopAfter)
	local granted: number? = nil
	local grantedCurrency: string? = nil
	local ok, committed = pcall(ctx.tx, player, function(tx: any)
		local section = ctx.section(tx)
		local current = if type(section.streak) == "table" then section.streak else {}
		-- re-check inside the tx: another evaluation may have counted this day already
		if (tonumber(current.lastDay) or 0) == nextState.lastDay and (tonumber(current.day) or 0) > 0 then
			error("already counted", 0)
		end
		section.streak = { day = nextState.day, lastDay = nextState.lastDay }
		if
			reward ~= nil
			and type(reward.amount) == "number"
			and reward.amount > 0
			and ctx.isEnabled(Economy)
		then
			if ctx.depsTx[Economy].grant(tx, reward.amount, "streak", reward.currency) then
				granted = reward.amount
				grantedCurrency = reward.currency
			end
		end
	end)
	if not ok or committed ~= true then
		return nil
	end
	signals.StreakAdvanced:Fire(player, day)
	-- (Economy's primary currency name isn't Streak's to read: a reward without `currency` shows
	-- the amount only)
	local suffix = if grantedCurrency then " " .. grantedCurrency else ""
	local text = if granted then `Day {day} streak! +{granted}{suffix}` else `Day {day} streak!`
	pcall(ctx.net.feedback, player, "toast", text)
	pcall(ctx.analytics.custom, player, "StreakDay", day)
	return day
end

-- players whose save is loaded in this server (no Players service: the module only sees ctx)
local online: { [any]: boolean } = {}

local function targetPlayer(arg: any): any
	local id = tonumber(arg)
	local first = nil
	for player in online do
		if id ~= nil and player.UserId == id then
			return player
		end
		first = first or player
	end
	return if id == nil then first else nil
end

function Streak.init(context: any)
	ctx = context
	signals.StreakAdvanced = ctx.signals.new("StreakAdvanced")
	ctx.console.register("dump", function(_player: any, userId: any): string
		local player = targetPlayer(userId)
		local state = if player then readState(player) else nil
		if state == nil then
			return "no loaded player"
		end
		local today = StreakMath.dayIndex(ctx.now(), offsetHours())
		return `day {state.day}, lastDay {state.lastDay} (today {today}, UTC{offsetHours()})`
	end, "streak dump [userId]: show a player's streak")
	ctx.console.register("advance", function(_player: any, userId: any): string
		if not ctx.isStudio then
			return "streak advance is Studio-only"
		end
		local player = targetPlayer(userId)
		local state = if player then readState(player) else nil
		if state == nil then
			return "no loaded player"
		end
		local now = ctx.now()
		-- pretend the last counted day was yesterday, then evaluate now
		ctx.data.update(player, function(section: any)
			section.streak = {
				day = math.max(state.day, 1),
				lastDay = StreakMath.dayIndex(now, offsetHours()) - 1,
			}
		end)
		local day = evaluate(player, now)
		return `advanced: day {day or "?"}`
	end, "streak advance [userId]: pretend a day passed (Studio)")
end

function Streak.start(_context: any)
	ctx.data.onLoaded(function(player: any)
		online[player] = true
		evaluate(player, ctx.now())
	end)
	ctx.lifecycle.onPlayerRemoving(function(player: any)
		online[player] = nil
	end)
	ctx.lifecycle.onTick(CHECK_INTERVAL, function()
		local now = ctx.now()
		for player in table.clone(online) do
			if ctx.data.isLoaded(player) then
				task.spawn(evaluate, player, now)
			end
		end
	end)
end

Streak.api = {
	onDaily = function(handler: (player: any, streakDay: number) -> ()): any
		return signals.StreakAdvanced:Connect(handler)
	end,
	get = function(player: any): { day: number, lastDay: number }
		local state = readState(player)
		return if state then { day = state.day, lastDay = state.lastDay } else { day = 0, lastDay = 0 }
	end,
	-- (v1.7.0, additive) the unix time at which the player's streak ends if they don't return: the end
	-- of the grace window after the next day. nil for a player with no streak or whose save isn't loaded.
	expiresAt = function(player: any): number?
		local state = readState(player)
		if state == nil then
			return nil
		end
		return StreakMath.expiresAt(state, streakConfig().graceHours, offsetHours())
	end,
	signals = signals,
}

return Streak
