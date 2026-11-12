--!strict
--[[
	Fake ExperienceNotificationService (StudWork.test.fakes.experienceNotificationService,
	module-api.md §23.10): the client-only opt-in prompt service, for client-part specs (the part takes
	the service table through a seam). Never talks to Roblox.

	  local fake = StudWork.test.fakes.experienceNotificationService({ canPrompt = true, failNext = n })

	Engine surface: CanPromptOptInAsync() -> boolean (raises while failNext is pending); PromptOptIn();
	fake.OptInPromptClosed (a signal, :Connect), fired by fake.close() (Roblox gives no result).
	Test surface: calls { { method } }, failNext(n), setCanPrompt(bool), close(), prompts() -> number.
]]

local Signal = (require :: any)(script.Parent.Parent.Parent.shared.Signal)

local NotificationFake = {}

function NotificationFake.new(opts: any?): any
	local o = opts or {}
	local canPrompt = o.canPrompt ~= false
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local prompted = 0
	local fake: any =
		{ calls = {}, OptInPromptClosed = Signal.new("ExperienceNotificationFake.OptInPromptClosed") }

	function fake.CanPromptOptInAsync(_self: any): boolean
		table.insert(fake.calls, { method = "CanPromptOptInAsync" })
		if failures > 0 then
			failures -= 1
			error("ExperienceNotificationService:CanPromptOptInAsync failed (injected)", 0)
		end
		return canPrompt
	end

	function fake.PromptOptIn(_self: any)
		table.insert(fake.calls, { method = "PromptOptIn" })
		prompted += 1
	end

	function fake.failNext(n: number)
		failures += n
	end

	function fake.setCanPrompt(value: boolean)
		canPrompt = value
	end

	function fake.prompts(): number
		return prompted
	end

	function fake.close()
		fake.OptInPromptClosed:Fire()
	end

	return fake
end

return NotificationFake
