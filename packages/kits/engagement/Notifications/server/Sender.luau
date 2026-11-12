--!strict
--[[
	Open Cloud send results and retry timing (docs/framework/kits/notifications.md, "Failure and budget
	behaviour"). Pure.

	  Sender.classify(ok, status, reason) -> "sent" | "retry" | "refused" | "budget" | "unavailable"
	      the three results of ctx.openCloud.request:
	        2xx                              sent
	        429, 5xx, a network failure      retry (the entry goes back on the due list)
	        another 4xx                      refused (never retried)
	        "budget" (this server's Open Cloud rate)   budget (wait, don't count an attempt)
	        "not_allowed" | "no_secret" | "forbidden"  unavailable (a setup problem)
	  Sender.backoff(retry, attempts) -> seconds     min(max, base x factor^(attempts - 1))
]]

local Sender = {}

export type Retry = { base: number, factor: number, max: number, attempts: number }

function Sender.classify(ok: boolean, status: number?, reason: any): string
	if ok then
		return "sent"
	end
	if status == nil then
		if reason == "budget" then
			return "budget"
		elseif reason == "not_allowed" or reason == "no_secret" or reason == "forbidden" then
			return "unavailable"
		end
		return "retry" -- "failed": the transport raised (network)
	end
	if status == 429 or status >= 500 then
		return "retry"
	end
	if status >= 400 then
		return "refused"
	end
	return "retry" -- a 3xx or 1xx is not an acceptance
end

function Sender.backoff(retry: Retry, attempts: number): number
	local n = math.max(1, attempts)
	return math.min(retry.max, retry.base * retry.factor ^ (n - 1))
end

return Sender
