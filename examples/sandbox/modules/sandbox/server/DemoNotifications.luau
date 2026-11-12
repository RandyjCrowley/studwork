--!strict
--[[
	Sandbox demo hook for the Notifications module (docs/framework/kits/notifications.md): suggest the
	opt-in at a good moment and schedule an 'eggReady' notification.

	  - `sandbox egg [seconds]` (Studio console): "start an egg" for the first player: schedules eggReady
	    that many seconds ahead (default 60) and says now is a good moment for the opt-in prompt
	  - `sandbox optin` (Studio console): asks for the opt-in prompt now, if the rules allow it (the
	    session must be `optIn.minSessionSeconds` old: the sandbox Balance sets 30 and
	    `minSessions = 0`, so the first Studio session qualifies); says why when it doesn't
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
		local prompted, why = notifications.suggestOptIn(player, "eggStarted")
		local refused = if prompted then "" else ` ({DemoNotifications.explain(why)})`
		return `eggReady scheduled in {delay}s; opt-in prompt requested: {tostring(prompted)}{refused}`
	end, "sandbox egg [seconds]: schedule the eggReady notification and suggest the opt-in (Studio)")
	ctx.console.register("optin", function(player: any): string
		-- the console's caller is a Player (an Instance) from the chat/admin path, nil from the command bar
		local target = if typeof(player) == "Instance" or type(player) == "table"
			then player
			else Players:GetPlayers()[1]
		if target == nil then
			return "no player"
		end
		return DemoNotifications.optIn(ctx, target)
	end, "sandbox optin: ask for the notifications opt-in now, if the rules allow it (Studio)")
end

-- suggestOptIn's refusal reason, in words, with the Balance.luau optIn line that decides it
local REASONS: { [string]: string } = {
	too_early = "the session is younger than optIn.minSessionSeconds (never on join)",
	sessions = "fewer finished sessions than optIn.minSessions",
	asked = "already requested once this session",
	pending = "the last request is still waiting for the client's answer",
	max_prompts = "already shown optIn.maxPrompts times",
	cooldown = "asked within optIn.cooldownDays",
	not_suggested = "optIn.onSuggest = false",
	disabled = "the Notifications flag is off",
	no_event = "the PromptOptIn Blink event isn't bound",
	not_loaded = "the player's save isn't loaded yet",
	save_failed = "the request couldn't be written to the save",
	bad_params = "not a player",
}

function DemoNotifications.explain(why: string?): string
	local reason = why or "unknown"
	local text = REASONS[reason]
	return if text then `{reason}: {text}` else reason
end

-- `sandbox optin`: never on join, never past the module's rules (the prompt is only requested when
-- suggestOptIn says yes; the reply names the exact rule that refused it)
function DemoNotifications.optIn(ctx: any, player: any): string
	local notifications = ctx.deps[Notifications]
	local prompted, why = notifications.suggestOptIn(player, "console")
	if prompted then
		return "opt-in prompt requested (the client asks Roblox's own prompt)"
	end
	return "opt-in refused: " .. DemoNotifications.explain(why)
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
