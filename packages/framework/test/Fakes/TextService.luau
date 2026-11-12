--!strict
--[[
	Fake TextService (StudWork.test.fakes.textService, module-api.md §23.10): the filter stand-in for
	ctx.services.get("TextService"). Records every call, never talks to Roblox.

	  local fake = StudWork.test.fakes.textService({
	    replace = { ["badword"] = "#######" },   case-insensitive substring -> replacement (true = the same
	                                             number of '#')
	    failNext = n,                            the next n FilterStringAsync calls raise
	    offline = { userId, ... },               FilterStringAsync for these authors raises (not in the server)
	    hiddenFrom = { userId, ... },            GetNonChatStringForUserAsync for these viewers raises
	  })
	  harness({ services = { TextService = fake } })

	Engine surface:
	  FilterStringAsync(text, fromUserId, context?) -> result
	    result:GetNonChatStringForBroadcastAsync() -> string
	    result:GetNonChatStringForUserAsync(toUserId) -> string
	    result:GetChatForUserAsync(toUserId) -> string
	Test surface: calls { { method, text?, userId?, context? } }, failNext(n), filter(text) -> string.
	Filtered output is a pure function of the input, so specs can assert it. The original is never in
	`calls` for result methods, only for FilterStringAsync (the submission).
]]

local TextFake = {}

local function escapePattern(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

function TextFake.new(opts: any?): any
	local o = opts or {}
	local replace: { [string]: string } = o.replace or {}
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local offline: { [number]: boolean } = {}
	local hiddenFrom: { [number]: boolean } = {}
	for _, id in (o.offline or {}) :: any do
		offline[id] = true
	end
	for _, id in (o.hiddenFrom or {}) :: any do
		hiddenFrom[id] = true
	end
	local fake: any = { calls = {} }

	function fake.failNext(n: number)
		failures += n
	end

	function fake.filter(text: string): string
		local out = text
		for word, replacement in replace :: any do
			local pattern = string.gsub(escapePattern(word), "%a", function(c: string): string
				return `[{string.lower(c)}{string.upper(c)}]`
			end)
			local r: string = if replacement == true then string.rep("#", #word) else replacement
			out = string.gsub(out, pattern, (string.gsub(r, "%%", "%%%%")))
		end
		return out
	end

	function fake.FilterStringAsync(_self: any, text: string, fromUserId: number, context: any?): any
		table.insert(
			fake.calls,
			{ method = "FilterStringAsync", text = text, userId = fromUserId, context = context }
		)
		if failures > 0 then
			failures -= 1
			error("TextService:FilterStringAsync failed (injected)", 0)
		end
		if offline[fromUserId] then
			error("TextService:FilterStringAsync: the author is not in this server (injected)", 0)
		end
		local filtered = fake.filter(text)
		local result: any = {}
		function result.GetNonChatStringForBroadcastAsync(_r: any): string
			table.insert(fake.calls, { method = "GetNonChatStringForBroadcastAsync", userId = fromUserId })
			return filtered
		end
		function result.GetNonChatStringForUserAsync(_r: any, toUserId: number): string
			table.insert(fake.calls, { method = "GetNonChatStringForUserAsync", userId = toUserId })
			if hiddenFrom[toUserId] then
				error("TextFilterResult:GetNonChatStringForUserAsync failed (injected)", 0)
			end
			return filtered
		end
		function result.GetChatForUserAsync(_r: any, toUserId: number): string
			table.insert(fake.calls, { method = "GetChatForUserAsync", userId = toUserId })
			if hiddenFrom[toUserId] then
				error("TextFilterResult:GetChatForUserAsync failed (injected)", 0)
			end
			return filtered
		end
		return result
	end

	return fake
end

return TextFake
