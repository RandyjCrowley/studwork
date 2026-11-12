--!strict
--[[
	Notifications client part (docs/framework/kits/notifications.md, "Client part").

	  - listens for the module's PromptOptIn(requestId) event (net.blink): Roblox's check and prompt run
	    through ./OptIn.luau, then OptInShown(requestId, shown) tells the server whether the prompt was shown
	  - reports the device's UTC offset once per session (SetUtcOffset; it only moves sends out of quiet hours)
	  - StudWork.use(Notifications).canPrompt() -> boolean?   the last client check (nil = not checked yet)

	The generated Blink module (./Net.luau, from ../net.blink) is optional here: a part running where
	there is no engine wire (a Lune spec) simply has no events to hear.
]]

local OptIn = require(script.OptIn)

local optIn: any = nil
local net: any = nil

local function service(): any
	local ok, found = pcall(function(): any
		return game:GetService("ExperienceNotificationService")
	end)
	return if ok then found else nil
end

local function report(requestId: string, shown: boolean)
	if net ~= nil and net.OptInShown ~= nil and type(net.OptInShown.Fire) == "function" then
		net.OptInShown.Fire(requestId, shown)
	end
end

local Notifications = {}

function Notifications.init(_context: any)
	local ok, loaded = pcall(function(): any
		return (require :: any)(script.Net)
	end)
	net = if ok then loaded else nil
	optIn = OptIn.new(service(), report)
end

function Notifications.start(_context: any)
	if net == nil then
		return
	end
	if net.PromptOptIn ~= nil and type(net.PromptOptIn.On) == "function" then
		net.PromptOptIn.On(function(requestId: string)
			if optIn ~= nil then
				optIn.prompt(requestId)
			end
		end)
	end
	if net.SetUtcOffset ~= nil and type(net.SetUtcOffset.Fire) == "function" then
		local localTime = os.time()
		local utcAsLocal = os.time(os.date("!*t") :: any)
		net.SetUtcOffset.Fire(OptIn.utcOffsetHours(localTime, utcAsLocal))
	end
end

Notifications.actions = { "optInShown", "setUtcOffset" }

Notifications.api = {
	canPrompt = function(): boolean?
		return if optIn ~= nil then optIn.canPrompt() else nil
	end,
}

return Notifications
