--!strict
--[[
	Core server networking. LEAD-OWNED.

	- Owns every Blink `.On` registration for client -> server events (Blink allows one listener).
	- Rate-limits every request per player per event BEFORE any service sees it.
	- Services register exactly one handler per event with Net.handle(name, fn).
	- Blink already rejects malformed payloads (types and ranges in core.blink). Handlers must
	  still validate ownership and game rules and never trust amounts/ids/positions.

	- Listens to every client event as soon as this module is required (CoreServer require), not
	  at Core.start, so Blink's unbounded pre-listener queue never fills (L3). Requests that
	  arrive before Net.start are rate-limited and parked in a bounded PendingQueue
	  (PENDING_CAP; when full, new requests are dropped and one warning is printed), then
	  dispatched in arrival order by Net.start once every handler is registered.
	- Events without a handler (their module is not in GameConfig.modules) are dropped quietly:
	  still rate-limited, never warned per request. `net` in the console shows drop counts.

	Rate limits are anti-spam safety rails, not balance numbers, so they live here.
]]

local Players = game:GetService("Players")

local PendingQueue = require(script.PendingQueue)
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
	RequestMailClaim = { rate = 2, burst = 5 },
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
	"RequestMailClaim",
	"AdminTriggerEvent",
	"ClientFunnel",
}

-- Max requests (all players, all events) held between CoreServer require and Core.start.
local PENDING_CAP = 256

local handlers: { [string]: Handler } = {}
local limiter = RateLimit.new(os.clock)
local unhandled: { [string]: number } = {}
local started = false
local pending = PendingQueue.new(PENDING_CAP, function(cap: number)
	warn(`[Core.Net] {cap} client requests arrived before Core.start; dropping further early requests`)
end)

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

local function validPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function run(eventName: string, player: Player, args: { n: number, [number]: any })
	if not validPlayer(player) then
		return -- left while queued
	end
	local handler = handlers[eventName]
	if handler == nil then
		unhandled[eventName] = (unhandled[eventName] or 0) + 1 -- module off: drop quietly
		return
	end
	local ok, err = pcall(function()
		handler(player, table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[Core.Net] " .. eventName .. " handler error: " .. tostring(err))
	end
end

local function receive(eventName: string, player: Player, ...: any)
	if not validPlayer(player) then
		return
	end
	if not limiter:allow(player.UserId, eventName, LIMITS[eventName]) then
		return -- silently drop spam
	end
	if not started then
		pending:push(eventName, player, ...)
		return
	end
	run(eventName, player, table.pack(...))
end

-- Listen now (require time). Blink allows one listener per event; Net owns all of them.
for _, eventName in CLIENT_EVENTS do
	local event = (Generated :: any)[eventName]
	event.On(function(player: Player, ...: any)
		receive(eventName, player, ...)
	end)
end
Players.PlayerRemoving:Connect(function(player)
	limiter:forget(player.UserId)
end)

-- Called by Server.start after every service registered its handlers.
function Net.start()
	assert(not started, "[Core.Net] already started")
	started = true
	for _, entry in pending:drain() do
		task.spawn(run, entry.eventName, entry.player, entry.args)
	end
end

-- v1.2: a game's own Blink server event (Core.Net.handle via server/GameNet). Same treatment as
-- core events: players who left are dropped, per-player rate limit (bucket key "game:<name>"),
-- pcall'd handler with a warning on error. One handler per eventName; listens immediately.
local gameEvents: { [string]: boolean } = {}
function Net.handleGame(eventName: string, event: any, limit: RateLimit.Limit, handler: Handler)
	assert(not gameEvents[eventName], "[Core.Net] game event already handled: " .. eventName)
	gameEvents[eventName] = true
	local key = "game:" .. eventName
	event.On(function(player: Player, ...: any)
		if not validPlayer(player) then
			return
		end
		if not limiter:allow(player.UserId, key, limit) then
			return
		end
		local args = table.pack(...)
		local ok, err = pcall(function()
			handler(player, table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn("[Core.Net] game event " .. eventName .. " handler error: " .. tostring(err))
		end
	end)
end

-- Console summary: dropped-early and handler-less request counts.
function Net.stats(): string
	local lines = { `pending dropped (before start): {pending.dropped}` }
	for _, eventName in CLIENT_EVENTS do
		if handlers[eventName] == nil then
			table.insert(lines, `{eventName}: no handler (module off), dropped {unhandled[eventName] or 0}`)
		end
	end
	return table.concat(lines, "\n")
end

return Net
