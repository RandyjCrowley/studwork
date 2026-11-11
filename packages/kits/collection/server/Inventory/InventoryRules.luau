--!strict
--[[
	Pure inventory rules (zero Roblox dependencies; tested under Lune).
	capacity() keeps the v1.2 Upgrades rule for the compat adapter's bridged-Upgrades cap bonus.

	validateMeta(meta) -> (ok, err?)   per-copy meta is saved, so it must stay tiny:
		<= MAX_META_KEYS keys, keys are strings <= MAX_META_KEY_LENGTH, values are
		string (<= MAX_META_STRING_LENGTH) | finite number | boolean, and the summed size of keys
		and values (numbers/booleans count 8) is <= MAX_META_BYTES.
	capacity(base, upgrades, levelOf) -> base + Σ levelOf(id) * perLevel over upgrades whose
		effect == "inventoryCap" (pinned contract), floored, never below 0.
	transferCheck(input) -> (ok, reason?)  ordered checks, first failure wins:
		"not_loaded" (either side) -> "same_player" -> "not_owned" -> "restricted" (either side
		restricted AND the item source starts with "paid:") -> "inventory_full".
	giftCheck(input) -> (ok, reason?)  Inventory.sendGift, ordered, first failure wins:
		"mail_off" -> "not_loaded" (sender) -> "bad_target" (toUserId not a positive integer) ->
		"same_player" -> "not_owned" -> "restricted_source" (source "paid:"/"paidcur:": the
		receiver's paid-random policy is unknown while they may be offline, so fail closed).
]]

local Validate = require(script.Parent.Parent.Util)

type UpgradeConfig = { effect: string?, perLevel: number? }

local InventoryRules = {}

InventoryRules.MAX_META_KEYS = 8
InventoryRules.MAX_META_KEY_LENGTH = 32
InventoryRules.MAX_META_STRING_LENGTH = 64
InventoryRules.MAX_META_BYTES = 256
InventoryRules.MAX_SOURCE_LENGTH = 64

InventoryRules.PAID_SOURCE_PREFIX = "paid:"
-- Rolls priced in a balance.paidCurrencies currency: paid random items for the policy (same trade
-- rules), but not Robux-bought, so rebirth does not keep them by default (review N5).
InventoryRules.PAID_CURRENCY_SOURCE_PREFIX = "paidcur:"

function InventoryRules.validateMeta(meta: any): (boolean, string?)
	if meta == nil then
		return true, nil
	end
	if type(meta) ~= "table" then
		return false, "meta must be a table"
	end
	local keys = 0
	local bytes = 0
	for key, value in meta do
		keys += 1
		if keys > InventoryRules.MAX_META_KEYS then
			return false, "meta has too many keys"
		end
		if type(key) ~= "string" or #key == 0 or #key > InventoryRules.MAX_META_KEY_LENGTH then
			return false, "meta keys must be strings of 1.." .. InventoryRules.MAX_META_KEY_LENGTH .. " chars"
		end
		bytes += #key
		local t = type(value)
		if t == "string" then
			if #value > InventoryRules.MAX_META_STRING_LENGTH then
				return false, "meta value for '" .. key .. "' is too long"
			end
			bytes += #value
		elseif t == "number" then
			if not Validate.isFiniteNumber(value) then
				return false, "meta value for '" .. key .. "' is not finite"
			end
			bytes += 8
		elseif t == "boolean" then
			bytes += 8
		else
			return false, "meta value for '" .. key .. "' must be string, number or boolean"
		end
	end
	if bytes > InventoryRules.MAX_META_BYTES then
		return false, "meta is too large"
	end
	return true, nil
end

function InventoryRules.capacity(
	base: number,
	upgrades: { [string]: UpgradeConfig }?,
	levelOf: (upgradeId: string) -> number
): number
	local cap = if Validate.isFiniteNumber(base) then base else 0
	for id, upgrade in (upgrades or {}) :: { [string]: UpgradeConfig } do
		if upgrade.effect == "inventoryCap" and Validate.isFiniteNumber(upgrade.perLevel) then
			local level = levelOf(id)
			if Validate.isNonNegativeNumber(level) then
				cap += level * (upgrade.perLevel :: number)
			end
		end
	end
	return math.max(0, math.floor(cap))
end

function InventoryRules.isPaidSource(source: string?): boolean
	if type(source) ~= "string" then
		return false
	end
	local robux, currency = InventoryRules.PAID_SOURCE_PREFIX, InventoryRules.PAID_CURRENCY_SOURCE_PREFIX
	return string.sub(source, 1, #robux) == robux or string.sub(source, 1, #currency) == currency
end

export type TransferInput = {
	fromLoaded: boolean,
	toLoaded: boolean,
	samePlayer: boolean,
	owned: boolean,
	source: string?,
	fromRestricted: boolean,
	toRestricted: boolean,
	toCount: number,
	toCap: number,
}

function InventoryRules.transferCheck(input: TransferInput): (boolean, string?)
	if not (input.fromLoaded and input.toLoaded) then
		return false, "not_loaded"
	end
	if input.samePlayer then
		return false, "same_player"
	end
	if not input.owned then
		return false, "not_owned"
	end
	if (input.fromRestricted or input.toRestricted) and InventoryRules.isPaidSource(input.source) then
		return false, "restricted"
	end
	if input.toCount >= input.toCap then
		return false, "inventory_full"
	end
	return true, nil
end

export type GiftInput = {
	mailEnabled: boolean,
	fromLoaded: boolean,
	fromUserId: number,
	toUserId: any,
	owned: boolean,
	source: string?,
}

function InventoryRules.giftCheck(input: GiftInput): (boolean, string?)
	if not input.mailEnabled then
		return false, "mail_off"
	end
	if not input.fromLoaded then
		return false, "not_loaded"
	end
	local to = input.toUserId
	if not (Validate.isInteger(to) and to > 0) then
		return false, "bad_target"
	end
	if to == input.fromUserId then
		return false, "same_player"
	end
	if not input.owned then
		return false, "not_owned"
	end
	if InventoryRules.isPaidSource(input.source) then
		return false, "restricted_source"
	end
	return true, nil
end

-- Gift request validation (RequestGift): toUserId must be a positive integer, not the sender.
function InventoryRules.validGiftTarget(senderUserId: number, toUserId: any): boolean
	return Validate.isInteger(toUserId) and toUserId > 0 and toUserId ~= senderUserId
end

return InventoryRules
