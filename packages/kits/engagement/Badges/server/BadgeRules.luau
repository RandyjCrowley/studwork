--!strict
--[[
	Badges: pure rules (docs/framework/kits/badges.md). No ctx, no engine: the server part and the
	specs both use these.

	  BadgeRules.KINDS                       trigger kind -> the module it needs (nil = none)
	  BadgeRules.validate(badges, enabled) -> { string }
	      every problem with config.Badges.badges, together; `enabled(moduleName) -> boolean`
	  BadgeRules.backoff(retry, failures) -> number
	      seconds before the next send attempt after `failures` failed ones (1 = the first):
	      min(retry.max, retry.base * retry.factor ^ (failures - 1))
	  BadgeRules.allowance(budget, players) -> number
	      calls per minute for this server: budget.base + budget.perPlayer * players, floored
	  BadgeRules.batches(ids, size) -> { { number } }
	      ids split into lists of at most `size` (CheckUserBadgesAsync takes 10)
	  BadgeRules.sortedKeys(t) -> { string }
]]

local BadgeRules = {}

BadgeRules.KINDS = table.freeze({
	manual = false,
	join = false,
	streak = "Streak",
	rebirths = "Rebirth",
	item = "Inventory",
	currency = "Economy",
	leaderboard = "Leaderboards",
})

BadgeRules.KEY_PATTERN = "^[%w_]+$"
BadgeRules.KEY_MAX = 32

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and v ~= math.huge and v ~= -math.huge
end

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function BadgeRules.sortedKeys(t: any): { string }
	local out = {}
	if type(t) == "table" then
		for k in t do
			if type(k) == "string" then
				table.insert(out, k)
			end
		end
	end
	table.sort(out)
	return out
end

function BadgeRules.validKey(key: any): boolean
	return type(key) == "string"
		and #key >= 1
		and #key <= BadgeRules.KEY_MAX
		and string.match(key, BadgeRules.KEY_PATTERN) ~= nil
end

function BadgeRules.validate(badges: any, enabled: (string) -> boolean): { string }
	local errors = {}
	if type(badges) ~= "table" then
		return { "config.Badges.badges must be a table" }
	end
	for key in badges do
		if not BadgeRules.validKey(key) then
			table.insert(
				errors,
				"config.Badges.badges: key '" .. tostring(key) .. "' must match ^[%w_]{1,32}$"
			)
		end
	end
	for _, key in BadgeRules.sortedKeys(badges) do
		local def = badges[key]
		local at = `config.Badges.badges.{key}`
		if type(def) ~= "table" then
			table.insert(errors, `{at} must be a table`)
			continue
		end
		if not isInteger(def.id) or def.id < 0 then
			table.insert(errors, `{at}.id must be a badge id (an integer; 0 = placeholder)`)
		end
		if def.toast ~= nil and type(def.toast) ~= "boolean" then
			table.insert(errors, `{at}.toast must be a boolean`)
		end
		local trigger = def.trigger
		if type(trigger) ~= "table" then
			table.insert(errors, `{at}.trigger must be a table with a kind`)
			continue
		end
		local kind = trigger.kind
		local needs = if type(kind) == "string" then BadgeRules.KINDS[kind] else nil
		if needs == nil then
			table.insert(
				errors,
				`{at}.trigger.kind '{tostring(kind)}' is not one of manual, join, streak, rebirths, item, currency, leaderboard`
			)
			continue
		end
		if needs and not enabled(needs) then
			table.insert(
				errors,
				`{at}: trigger '{kind}' needs the {needs} module (add it to GameConfig.modules)`
			)
		end
		if kind == "streak" or kind == "rebirths" then
			if not isInteger(trigger.atLeast) or trigger.atLeast < 1 then
				table.insert(errors, `{at}.trigger.atLeast must be an integer >= 1`)
			end
		elseif kind == "item" then
			if type(trigger.item) ~= "string" or trigger.item == "" then
				table.insert(errors, `{at}.trigger.item must be an item id`)
			end
		elseif kind == "currency" then
			if not isFinite(trigger.atLeast) or trigger.atLeast < 0 then
				table.insert(errors, `{at}.trigger.atLeast must be a number >= 0`)
			end
			if trigger.currency ~= nil and (type(trigger.currency) ~= "string" or trigger.currency == "") then
				table.insert(errors, `{at}.trigger.currency must be a currency id`)
			end
		elseif kind == "leaderboard" then
			if type(trigger.board) ~= "string" or trigger.board == "" then
				table.insert(errors, `{at}.trigger.board must be a board id`)
			end
			if not isInteger(trigger.rank) or trigger.rank < 1 then
				table.insert(errors, `{at}.trigger.rank must be an integer >= 1`)
			end
		end
	end
	return errors
end

function BadgeRules.backoff(retry: any, failures: number): number
	local base = if isFinite(retry.base) then retry.base else 5
	local factor = if isFinite(retry.factor) then retry.factor else 2
	local max = if isFinite(retry.max) then retry.max else 300
	local n = math.max(1, failures)
	return math.min(max, base * factor ^ (n - 1))
end

function BadgeRules.allowance(budget: any, players: number): number
	local base = if type(budget) == "table" and isFinite(budget.base) then budget.base else 0
	local per = if type(budget) == "table" and isFinite(budget.perPlayer) then budget.perPlayer else 0
	return math.floor(base + per * math.max(0, players))
end

function BadgeRules.batches(ids: { number }, size: number): { { number } }
	local out = {}
	local current = {}
	for _, id in ids do
		table.insert(current, id)
		if #current >= size then
			table.insert(out, current)
			current = {}
		end
	end
	if #current > 0 then
		table.insert(out, current)
	end
	return out
end

return BadgeRules
