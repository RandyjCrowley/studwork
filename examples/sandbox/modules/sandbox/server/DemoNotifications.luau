--!strict
--[[
	Sandbox demo hook for the Notifications module (docs/framework/kits/notifications.md): suggest the
	opt-in at a good moment and schedule an 'eggReady' notification.

	  - `sandbox egg [seconds]` (Studio console): "start an egg" for the first player: schedules eggReady
	    that many seconds ahead (default 60) and says now is a good moment for the opt-in prompt
	  - every 30 s a loaded player is offered the prompt: the module refuses until the session is old
	    enough and the other optIn rules pass (never on join)

	The sandbox template eggReady has messageId = "" (a placeholder), so nothing is ever sent: the due
	entry is scheduled, limited and cleared as usual. Everything checks `ctx.isEnabled(Notifications)`
	first: the sandbox may run without the module.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Notifications =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Notifications"):WaitForChild("module"))

local DEFAULT_EGG_SECONDS = 60
local OFFER_INTERVAL = 30

local DemoNotifications = {}

function DemoNotifications.init(ctx: any)
	if not ctx.isEnabled(Notifications) then
		return
	end
	ctx.console.register("egg", function(_player: any, seconds: any): string
		local player = Players:GetPlayers()[1]
		if player == nil then
			return "no player"
		end
		local notifications = ctx.deps[Notifications]
		local delay = tonumber(seconds) or DEFAULT_EGG_SECONDS
		local userId = player.UserId
		task.spawn(function()
			local ok, reason = notifications.schedule(userId, "eggReady", ctx.now() + delay)
			ctx.log.info(`demo egg for {userId} in {delay}s: {tostring(ok)} {tostring(reason)}`)
		end)
		local prompted = notifications.suggestOptIn(player, "eggStarted")
		return `eggReady scheduled in {delay}s; opt-in prompt requested: {tostring(prompted)}`
	end, "sandbox egg [seconds]: schedule the eggReady notification and suggest the opt-in (Studio)")
end

function DemoNotifications.start(ctx: any)
	if not ctx.isEnabled(Notifications) then
		return
	end
	local notifications = ctx.deps[Notifications]
	ctx.lifecycle.onTick(OFFER_INTERVAL, function()
		for _, player in Players:GetPlayers() do
			notifications.suggestOptIn(player, "sandbox")
		end
	end)
end

return DemoNotifications
