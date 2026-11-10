--!strict
--[[
	Core.Streak. OWNED BY AGENT E (core/e-meta). Public API: Types.StreakAPI.

	Daily login streak in UTC (day index = os.time() // 86400), see StreakMath.luau for the exact
	rules: same day -> nothing; next day -> +1; one missed day is forgiven when the player returns
	within balance.streak.graceHours after the missed day ended; otherwise reset to 1. Clock skew
	(today < lastDay) never resets.

	Evaluated when the player's data loads and again every CHECK_INTERVAL seconds for players who
	stay online across UTC midnight. When a day counts:
	  - PlayerData.streak = { day, lastDay } (Data.update)
	  - reward from balance.streak.rewards for the streak day (wrapped by loopAfter; currency
	    defaults to balance.primaryCurrency) through Economy.grant(reason "streak")
	  - StreakAdvanced signal + onDaily handlers + "toast" feedback + Analytics.custom("StreakDay")

	get(player) returns a copy of PlayerData.streak ({ day = 0, lastDay = 0 } when not loaded).
	Studio console: `streak dump` / `streak advance` (pretend a day passed for the first player).
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))
local StreakMath = require(script.StreakMath)

local CHECK_INTERVAL = 60 -- seconds between midnight re-checks for online players
local DAY = 86400

local Streak = {}

local ctx: any = nil
local handlers = HandlerList.new()

local function streakConfig(): Types.StreakConfig
	return ctx.config.balance.streak
end

local function readState(player: Player): StreakMath.State?
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return nil
	end
	local s = data.streak or { day = 0, lastDay = 0 }
	return { day = s.day or 0, lastDay = s.lastDay or 0 }
end

local function grantReward(player: Player, day: number): (number?, string?)
	local cfg = streakConfig()
	local reward = StreakMath.rewardFor(day, cfg.rewards, cfg.loopAfter)
	if reward == nil or type(reward.amount) ~= "number" or reward.amount <= 0 then
		return nil, nil
	end
	local currency: string = reward.currency or ctx.config.balance.primaryCurrency
	local ok, granted = pcall(ctx.services.Economy.grant, player, reward.amount, "streak", currency)
	if ok and granted then
		return reward.amount, currency
	end
	return nil, nil
end

-- Evaluates the streak at time `now`. Returns the new streak day when the day counted.
local function evaluate(player: Player, now: number): number?
	local state = readState(player)
	if state == nil then
		return nil
	end
	local nextState, outcome = StreakMath.advance(state, now, streakConfig().graceHours)
	if not StreakMath.counts(outcome) then
		return nil
	end
	local written = ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.streak = { day = nextState.day, lastDay = nextState.lastDay }
	end)
	if not written then
		return nil
	end
	local day = nextState.day
	local amount, currency = grantReward(player, day)
	ctx.signals.StreakAdvanced:Fire(player, day)
	handlers:fire(player, day)
	local text = if amount then `Day {day} streak! +{amount} {currency}` else `Day {day} streak!`
	pcall(ctx.net.feedback, player, "toast", text)
	pcall(ctx.services.Analytics.custom, player, "StreakDay", day)
	return day
end

function Streak.init(context: any)
	ctx = context
end

function Streak.start()
	ctx.services.Data.onLoaded(function(player: Player)
		evaluate(player, os.time())
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			local now = os.time()
			for _, player in Players:GetPlayers() do
				if ctx.services.Data.isLoaded(player) then
					task.spawn(evaluate, player, now)
				end
			end
		end
	end)

	ctx.console.register(
		"streak",
		"streak <dump|advance> [userId]: show or advance a player's streak (Studio)",
		function(...: any)
			local args = { ... }
			local last = tonumber(args[#args])
			local player = (last and Players:GetPlayerByUserId(last)) or Players:GetPlayers()[1]
			if player == nil then
				return "no player in server"
			end
			local state = readState(player)
			if state == nil then
				return "data not loaded"
			end
			if args[1] == "advance" then
				if not ctx.isStudio then
					return "streak advance is Studio-only"
				end
				-- pretend the last counted day was yesterday, then evaluate now
				local now = os.time()
				ctx.services.Data.update(player, function(d: Types.PlayerData)
					d.streak = { day = math.max(state.day, 1), lastDay = now // DAY - 1 }
				end)
				local day = evaluate(player, now)
				return `advanced: day {day or "?"}`
			end
			return `day {state.day}, lastDay {state.lastDay} (today {os.time() // DAY})`
		end
	)
end

function Streak.onDaily(handler: (player: Player, streakDay: number) -> ()): Types.Connection
	return handlers:add(handler)
end

function Streak.get(player: Player): Types.StreakState
	local state = readState(player)
	return if state then { day = state.day, lastDay = state.lastDay } else { day = 0, lastDay = 0 }
end

return Streak
