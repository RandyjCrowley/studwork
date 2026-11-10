--!strict
--[[
	Pure GameConfig validation. Returns a list of error strings (empty = valid) so the same code
	runs in Core.start (asserts) and in Lune tests. Core.start refuses to boot on errors.
]]

local RarityTiers = require(script.Parent.RarityTiers)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Validate)

type GameConfig = Types.GameConfig

local ConfigValidate = {}

function ConfigValidate.validate(config: any): { string }
	local errors: { string } = {}
	local function err(msg: string)
		table.insert(errors, msg)
	end

	if type(config) ~= "table" then
		return { "config must be a table" }
	end
	if not Validate.isId(config.gameId, 32) then
		err("gameId must be a short id string ([%w_-.:], <= 32 chars)")
	end

	-- items
	local itemIds: { [string]: boolean } = {}
	if type(config.items) ~= "table" then
		err("items must be a list")
	else
		for i, item in config.items do
			local where = "items[" .. tostring(i) .. "]"
			if type(item) ~= "table" then
				err(where .. " must be a table")
				continue
			end
			if not Validate.isId(item.id) then
				err(where .. ".id invalid")
			elseif itemIds[item.id] then
				err(where .. ".id duplicate '" .. item.id .. "'")
			else
				itemIds[item.id] = true
			end
			if type(item.name) ~= "string" then
				err(where .. ".name must be a string")
			end
			if not RarityTiers.isTier(item.rarity) then
				err(where .. ".rarity must be a RarityTier")
			end
			if not Validate.isNonNegativeNumber(item.incomePerSec) then
				err(where .. ".incomePerSec must be a finite number >= 0")
			end
		end
	end

	local b = config.balance
	if type(b) ~= "table" then
		err("balance must be a table")
		return errors
	end
	if not Validate.isId(b.primaryCurrency, 32) then
		err("balance.primaryCurrency must be an id")
	end
	if type(b.income) ~= "table" or not Validate.isPositiveNumber(b.income.tickSeconds) then
		err("balance.income.tickSeconds must be > 0")
	elseif b.income.source ~= "displayed" and b.income.source ~= "owned" then
		err("balance.income.source must be 'displayed' or 'owned'")
	end
	if type(b.inventory) ~= "table" or not Validate.isInteger(b.inventory.cap) or b.inventory.cap < 1 then
		err("balance.inventory.cap must be an integer >= 1")
	end

	-- mutations
	local mutationIds: { [string]: boolean } = {}
	if b.mutations ~= nil then
		for i, m in b.mutations do
			local where = "balance.mutations[" .. tostring(i) .. "]"
			if type(m) ~= "table" or not Validate.isId(m.id) then
				err(where .. ".id invalid")
				continue
			end
			mutationIds[m.id] = true
			if not Validate.isPositiveNumber(m.multiplier) then
				err(where .. ".multiplier must be > 0")
			end
		end
	end

	-- rarity tables
	if type(b.rarityTables) ~= "table" then
		err("balance.rarityTables must be a table")
	else
		for tableId, t in b.rarityTables do
			local where = "balance.rarityTables." .. tostring(tableId)
			if type(t) ~= "table" or type(t.entries) ~= "table" or #t.entries == 0 then
				err(where .. ".entries must be a non-empty list")
				continue
			end
			for i, e in t.entries do
				if type(e) ~= "table" or not itemIds[e.itemId] then
					err(where .. ".entries[" .. i .. "].itemId unknown")
				end
				if type(e) == "table" and not Validate.isPositiveNumber(e.weight) then
					err(where .. ".entries[" .. i .. "].weight must be > 0")
				end
			end
			if t.luckMinTier ~= nil and not RarityTiers.isTier(t.luckMinTier) then
				err(where .. ".luckMinTier invalid")
			end
			if t.pity ~= nil then
				if not Validate.isInteger(t.pity.threshold) or t.pity.threshold < 1 then
					err(where .. ".pity.threshold must be an integer >= 1")
				end
				if not RarityTiers.isTier(t.pity.minTier) then
					err(where .. ".pity.minTier invalid")
				end
			end
			if t.mutationChance ~= nil and not Validate.inRange(t.mutationChance, 0, 1) then
				err(where .. ".mutationChance must be 0..1")
			end
			if t.cost ~= nil then
				if not Validate.isId(t.cost.currency, 32) or not Validate.isPositiveNumber(t.cost.amount) then
					err(where .. ".cost needs currency id and amount > 0")
				end
			end
		end
	end

	-- starter items
	if b.starterItems ~= nil then
		for _, id in b.starterItems do
			if not itemIds[id] then
				err("balance.starterItems: unknown item '" .. tostring(id) .. "'")
			end
		end
	end

	-- upgrades
	if b.upgrades ~= nil then
		for id, u in b.upgrades do
			local where = "balance.upgrades." .. tostring(id)
			if not Validate.isId(id) then
				err(where .. " id invalid")
			end
			if type(u) ~= "table" then
				err(where .. " must be a table")
				continue
			end
			if not Validate.isPositiveNumber(u.baseCost) or not Validate.isPositiveNumber(u.costGrowth) then
				err(where .. " baseCost/costGrowth must be > 0")
			end
			if not Validate.isInteger(u.maxLevel) or u.maxLevel < 1 then
				err(where .. ".maxLevel must be an integer >= 1")
			end
			if u.effect ~= "incomeMultiplier" and u.effect ~= "inventoryCap" and u.effect ~= "custom" then
				err(where .. ".effect invalid")
			end
			if not Validate.isFiniteNumber(u.perLevel) then
				err(where .. ".perLevel must be a number")
			end
		end
	end

	-- rebirth
	local r = b.rebirth
	if type(r) ~= "table" then
		err("balance.rebirth must be a table")
	else
		if not Validate.isPositiveNumber(r.baseCost) or not Validate.isPositiveNumber(r.costGrowth) then
			err("balance.rebirth baseCost/costGrowth must be > 0")
		end
		if not Validate.isNonNegativeNumber(r.multiplierPerRebirth) then
			err("balance.rebirth.multiplierPerRebirth must be >= 0")
		end
		if type(r.keepInventory) ~= "boolean" then
			err("balance.rebirth.keepInventory must be a boolean")
		end
	end

	-- offline
	local o = b.offline
	if type(o) ~= "table" then
		err("balance.offline must be a table")
	else
		if not Validate.isNonNegativeNumber(o.capSeconds) then
			err("balance.offline.capSeconds must be >= 0")
		end
		if not Validate.isNonNegativeNumber(o.minSeconds) then
			err("balance.offline.minSeconds must be >= 0")
		end
		if not Validate.inRange(o.payoutFraction, 0, 1) then
			err("balance.offline.payoutFraction must be 0..1")
		end
		if type(o.autoPay) ~= "boolean" then
			err("balance.offline.autoPay must be a boolean")
		end
	end

	-- streak
	if type(b.streak) ~= "table" or not Validate.isNonNegativeNumber(b.streak.graceHours) then
		err("balance.streak.graceHours must be >= 0")
	end

	-- friends
	if type(b.friends) ~= "table" or not Validate.isPositiveNumber(b.friends.checkIntervalSec) then
		err("balance.friends.checkIntervalSec must be > 0")
	end

	-- products
	local p = config.products
	if type(p) ~= "table" or type(p.passes) ~= "table" or type(p.devProducts) ~= "table" then
		err("products must have passes and devProducts tables")
	else
		for name, id in p.passes do
			if not Validate.isInteger(id) or id < 0 then
				err("products.passes." .. tostring(name) .. " must be an integer id (0 = not created yet)")
			end
		end
		for name, id in p.devProducts do
			if not Validate.isInteger(id) or id < 0 then
				err(
					"products.devProducts."
						.. tostring(name)
						.. " must be an integer id (0 = not created yet)"
				)
			end
		end
	end

	-- events
	if type(config.events) ~= "table" then
		err("events must be a table (may be empty)")
	else
		for id, e in config.events do
			local where = "events." .. tostring(id)
			if type(e) ~= "table" or not Validate.isPositiveNumber(e.durationSec) then
				err(where .. ".durationSec must be > 0")
				continue
			end
			if e.schedule ~= nil then
				local s = e.schedule
				if not Validate.isInteger(s.hourUtc) or s.hourUtc < 0 or s.hourUtc > 23 then
					err(where .. ".schedule.hourUtc must be 0..23")
				end
				if
					s.minuteUtc ~= nil
					and (not Validate.isInteger(s.minuteUtc) or s.minuteUtc < 0 or s.minuteUtc > 59)
				then
					err(where .. ".schedule.minuteUtc must be 0..59")
				end
				if
					s.weekday ~= nil and (not Validate.isInteger(s.weekday) or s.weekday < 1 or s.weekday > 7)
				then
					err(where .. ".schedule.weekday must be 1..7 (1 = Sunday)")
				end
			end
		end
	end

	-- palette
	if config.palette ~= nil then
		for key, hex in config.palette do
			if type(hex) ~= "string" or string.match(hex, "^#%x%x%x%x%x%x$") == nil then
				err("palette." .. tostring(key) .. " must be '#RRGGBB'")
			end
		end
	end

	-- admins
	if config.admins ~= nil then
		for i, id in config.admins do
			if not Validate.isInteger(id) then
				err("admins[" .. i .. "] must be a user id")
			end
		end
	end

	-- analytics
	if config.analytics ~= nil then
		if type(config.analytics.funnel) ~= "table" then
			err("analytics.funnel must be a list of step names")
		end
	end

	-- game data
	if config.data ~= nil and type(config.data.defaults) ~= "table" then
		err("data.defaults must be a table")
	end

	return errors
end

function ConfigValidate.assertValid(config: any): GameConfig
	local errors = ConfigValidate.validate(config)
	if #errors > 0 then
		error("[Core] invalid GameConfig:\n  - " .. table.concat(errors, "\n  - "), 2)
	end
	return config :: GameConfig
end

return ConfigValidate
