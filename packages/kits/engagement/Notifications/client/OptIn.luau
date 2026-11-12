--!strict
--[[
	Notifications client: Roblox's opt-in prompt behind a small seam (docs/framework/kits/notifications.md,
	"Client part"). `service` is ExperienceNotificationService (or a test fake: it needs
	CanPromptOptInAsync and PromptOptIn); nothing here touches the engine directly, so specs pass a fake.

	  OptIn.new(service, report) -> { prompt(requestId), canPrompt() -> boolean? }
	      prompt: pcall(CanPromptOptInAsync); when true, PromptOptIn(); then report(requestId, shown)
	      (shown = whether Roblox's prompt was shown; a failed check reports false). `canPrompt` is the
	      last check (nil = not checked yet).
	  OptIn.utcOffsetHours(localTime, utcAsLocalTime) -> number
	      the device's UTC offset in hours, rounded to 0.25 and clamped to -14..14
]]

local OptIn = {}

function OptIn.new(service: any, report: (string, boolean) -> ()): any
	local last: boolean? = nil
	local self = {}

	function self.prompt(requestId: string)
		local checked, can = pcall(function(): any
			return service:CanPromptOptInAsync()
		end)
		last = checked and can == true
		local shown = false
		if last == true then
			shown = pcall(function()
				service:PromptOptIn()
			end)
		end
		report(requestId, shown)
	end

	function self.canPrompt(): boolean?
		return last
	end

	return self
end

function OptIn.utcOffsetHours(localTime: number, utcAsLocalTime: number): number
	local hours = (localTime - utcAsLocalTime) / 3600
	hours = math.floor(hours * 4 + 0.5) / 4
	return math.clamp(hours, -14, 14)
end

return OptIn
