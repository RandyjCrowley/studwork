--!strict
--[[
	Offline (economy kit), server part. v1.3.0: a real StudWork module (no save
	section). config.Offline.offline = { capSeconds, minSeconds, payoutFraction, autoPay }; every
	key has a default (the values every shipped game uses: 8 h, 60 s, 0.5, true), so the cap other
	modules coordinate with is config here (through the API, not by sharing files).

	api (v1.2): onReturn(fn(player, secondsAway)) -> Connection

	When a player's save has loaded (ctx.lifecycle.onPlayerLoaded; the framework keeps
	ctx.framework.lastSeen at the previous session's last save until the first save of this one):
	  secondsAway = clamp(now - lastSeen, 0, capSeconds), skipped on the first session
	  (ctx.framework.sessions == 1) or below minSeconds (OfflineMath).
	  autoPay (needs Economy, optional): pays floor(Economy.getRate * secondsAway * payoutFraction)
	  with reason "offline" and a "pop" feedback. Economy computes the rate from save data only, so
	  it is right here whatever order load handlers run in; session-only boosts (co-play, passes
	  applied later) are deliberately not in it.
	  onReturn handlers run every time secondsAway >= minSeconds, each in its own thread.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OfflineMath = require(script.OfflineMath)

local EconomyRef =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module")) :: any

local Offline = {}

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }

function Offline.new(): any
	local ctx: any = nil
	local handlers: { (any, number) -> () } = {}

	local api: { [string]: any } = {}

	function api.onReturn(handler: (player: any, secondsAway: number) -> ()): Connection
		assert(
			type(handler) == "function",
			"Offline.onReturn(fn): fn must be a function(player, secondsAway)"
		)
		table.insert(handlers, handler)
		local connection: any = { Connected = true }
		function connection.Disconnect(conn: any)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end
		return connection
	end

	local function onLoaded(player: any)
		local o = ctx.config.offline
		local away = OfflineMath.secondsAway(
			ctx.now(),
			ctx.framework.lastSeen(player),
			ctx.framework.sessions(player),
			o
		)
		if away == nil then
			return
		end
		if o.autoPay and ctx.isEnabled(EconomyRef) then
			local economy = ctx.deps[EconomyRef]
			local amount = OfflineMath.payout(economy.getRate(player), away, o.payoutFraction)
			if amount > 0 and economy.grant(player, amount, "offline") then
				ctx.net.feedback(player, "pop", "+" .. tostring(amount))
			end
		end
		for _, fn in table.clone(handlers) do
			task.spawn(fn, player, away)
		end
	end

	local part: { [string]: any } = { api = api }

	function part.init(context: any)
		ctx = context
		ctx.lifecycle.onPlayerLoaded(onLoaded)
	end

	return part
end

return Offline
