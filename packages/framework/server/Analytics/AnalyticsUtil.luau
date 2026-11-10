--!strict
--[[
	Pure analytics argument helpers (no Roblox globals). Owned by agent E.

	stepIndex(steps, step)  1-based index of `step` in the configured funnel, nil if absent
	validAmount(x)          finite number > 0
	sanitize(s, maxLen)     string with control characters removed, trimmed, cut to maxLen;
	                        nil when the result is empty or `s` is not a string
	clientAllowed(clientSteps, step)  true only when step is a non-empty string in clientSteps
]]

local AnalyticsUtil = {}

function AnalyticsUtil.stepIndex(steps: { string }?, step: string): number?
	if steps == nil or type(step) ~= "string" then
		return nil
	end
	return table.find(steps, step)
end

function AnalyticsUtil.validAmount(x: any): boolean
	return type(x) == "number" and x == x and x > 0 and x ~= math.huge
end

function AnalyticsUtil.sanitize(s: any, maxLen: number): string?
	if type(s) ~= "string" then
		return nil
	end
	local cleaned = string.gsub(s, "%c", "")
	cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
	cleaned = string.sub(cleaned, 1, maxLen)
	if cleaned == "" then
		return nil
	end
	return cleaned
end

function AnalyticsUtil.clientAllowed(clientSteps: { string }?, step: any): boolean
	if clientSteps == nil or type(step) ~= "string" or step == "" then
		return false
	end
	return table.find(clientSteps, step) ~= nil
end

return AnalyticsUtil
