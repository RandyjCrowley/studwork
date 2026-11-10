--!strict
--[[
	Core.Net (v1.2, foundation). LEAD-OWNED. Public API: Types.NetAPI.

	handle(eventName, event, limit, handler)
	  Routes a game's own Blink server event through core's Net (server/Net.handleGame): calls
	  from players who left are dropped, every call is rate-limited per player with `limit`
	  ({ rate = tokens/s, burst }), the handler is pcall'd and errors are logged.
	  Checks: eventName is a short id, `event` has an `.On` function (a generated Blink server
	  event), limit.rate > 0 and limit.burst >= 1 (finite), handler is a function, and the name
	  is not already handled. Blink validates wire types; the handler still validates ownership,
	  ranges and game rules (never trust amounts, ids or positions from a client).

	Game code must never use RemoteEvent.OnServerEvent / OnServerInvoke directly (tools/lint
	guardrail "remotes").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))
local Validate = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Validate"))

local GameNet = {}

local ctx: any = nil

function GameNet.init(context: any)
	ctx = context
end

function GameNet.start() end

function GameNet.handle(
	eventName: string,
	event: any,
	limit: Types.RateLimitSpec,
	handler: (player: Player, ...any) -> ()
)
	assert(Validate.isId(eventName), "Core.Net.handle: eventName must be a short id string")
	assert(
		type(event) == "table" and type(event.On) == "function",
		"Core.Net.handle: event must be a generated Blink server event (with .On)"
	)
	assert(
		type(limit) == "table"
			and Validate.isPositiveNumber(limit.rate)
			and Validate.isPositiveNumber(limit.burst)
			and limit.burst >= 1,
		"Core.Net.handle: limit must be { rate > 0, burst >= 1 }"
	)
	assert(type(handler) == "function", "Core.Net.handle: handler must be a function")
	ctx.net.handleGame(eventName, event, { rate = limit.rate, burst = limit.burst }, handler)
end

return GameNet
