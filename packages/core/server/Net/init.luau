--!strict
--[[
	Core server networking. LEAD-OWNED.

	- Owns every Blink `.On` registration for client -> server events (Blink allows one listener).
	- Rate-limits every request per player per event BEFORE any service sees it.
	- Services register exactly one handler per event with Net.handle(name, fn).
	- Blink already rejects malformed payloads (types and ranges in core.blink). Handlers must
	  still validate ownership and game rules and never trust amounts/ids/positions.

	Rate limits are anti-spam safety rails, not balance numbers, so they live here.
]]

local Players = game:GetService("Players")

local RateLimit = require(script.RateLimit)
local Generated = require(script.Generated)

type Handler = (player: Player, ...any) -> ()

local Net = {}

Net.events = Generated

-- tokens per second / burst, per player per event
local LIMITS: { [string]: RateLimit.Limit } = {
	StateInit = { rate = 0.2, burst = 2 },
	RequestDisplay = { rate = 8, burst = 16 },
	RequestClearDisplay = { rate = 8, burst = 16 },
	RequestRebirth = { rate = 0.5, burst = 2 },
	RequestUpgrade = { rate = 6, burst = 12 },
	RequestRoll = { rate = 4, burst = 8 },
	RequestGift = { rate = 1, burst = 3 },
	AdminTriggerEvent = { rate = 1, burst = 3 },
	ClientFunnel = { rate = 2, burst = 10 },
}

local CLIENT_EVENTS = {
	"StateInit",
	"RequestDisplay",
	"RequestClearDisplay",
	"RequestRebirth",
	"RequestUpgrade",
	"RequestRoll",
	"RequestGift",
	"AdminTriggerEvent",
	"ClientFunnel",
}

local handlers: { [string]: Handler } = {}
local limiter = RateLimit.new(os.clock)
local droppedWarned: { [string]: boolean } = {}
local started = false

function Net.handle(eventName: string, handler: Handler)
	assert(LIMITS[eventName] ~= nil, "[Core.Net] unknown client event " .. eventName)
	assert(handlers[eventName] == nil, "[Core.Net] handler already registered for " .. eventName)
	handlers[eventName] = handler
end

function Net.feedback(player: Player, kind: string, text: string, rarity: string?, position: Vector3?)
	Generated.Feedback.Fire(player, {
		Kind = string.sub(kind, 1, 32),
		Text = string.sub(text, 1, 120),
		Rarity = rarity,
		Position = position,
	})
end

local function dispatch(eventName: string, player: Player, ...: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return
	end
	if not limiter:allow(player.UserId, eventName, LIMITS[eventName]) then
		return -- silently drop spam
	end
	local handler = handlers[eventName]
	if handler == nil then
		if not droppedWarned[eventName] then
			droppedWarned[eventName] = true
			warn("[Core.Net] no handler registered for " .. eventName .. "; requests are dropped")
		end
		return
	end
	local args = table.pack(...)
	local ok, err = pcall(function()
		handler(player, table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[Core.Net] " .. eventName .. " handler error: " .. tostring(err))
	end
end

function Net.start()
	assert(not started, "[Core.Net] already started")
	started = true
	for _, eventName in CLIENT_EVENTS do
		local event = (Generated :: any)[eventName]
		event.On(function(player: Player, ...: any)
			dispatch(eventName, player, ...)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player.UserId)
	end)
end

return Net
