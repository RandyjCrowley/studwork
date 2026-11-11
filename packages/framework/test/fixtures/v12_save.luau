--!nocheck
--[[
	TEST FIXTURE (v1.3.0): a v1.2 PlayerData save (Types.PlayerData, contract v1.2)
	with every field, for the _sandbox game (gameId "sandbox"), as a live v1.2 server wrote it to
	ProfileStore's `Data`. MigrationV12.spec.luau loads it through the framework with every real
	kit module and checks each value lands in its v1.3 section unchanged.

	Times are fixed around EPOCH (the harness clock starts there): lastSeen 30 s ago (under
	Offline's 60 s minimum: no payout), the streak already counted today (no advance), one
	persisted and one expiring multiplier (expires 10 minutes after EPOCH).
]]

local EPOCH = 1_750_000_000
local DAY = EPOCH // 86400 -- StreakMath.dayIndex(EPOCH) in UTC

local function item(uid: string, itemId: string, at: number, extra: { [string]: any }?): any
	local out = { uid = uid, itemId = itemId, acquiredAt = at }
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

local save = {
	schemaVersion = 7,
	firstJoin = EPOCH - 30 * 86400,
	lastSeen = EPOCH - 30,
	currency = { Coins = 12345, Gems = 7 },
	inventory = {
		["u-drop"] = item("u-drop", "crystal", EPOCH - 1000, { source = "drop" }),
		["u-paid"] = item("u-paid", "feather", EPOCH - 900, { source = "paid:EggRoll", mutation = "Gold" }),
		["u-paidcur"] = item("u-paidcur", "comet", EPOCH - 800, { source = "paidcur:Chest" }),
		["u-meta"] = item(
			"u-meta",
			"pebble",
			EPOCH - 700,
			{ source = "drop", meta = { note = "from grandma" } }
		),
		["u-rainbow"] = item("u-rainbow", "acorn", EPOCH - 600, { mutation = "Rainbow" }),
	},
	displayed = { slot01 = "u-drop", slot02 = "u-paid" },
	upgrades = { IncomeBoost = 3, BiggerBag = 2 },
	rebirths = 2,
	multipliers = {
		vip = { mult = 2 },
		potion = { mult = 1.5, expiresAt = EPOCH + 600 },
	},
	streak = { day = 4, lastDay = DAY },
	pity = { Chest = 9, Egg = 5 },
	stats = { sessions = 12, totalEarned = 99999, rolls = 40 },
	funnel = {
		Joined = EPOCH - 30 * 86400,
		FirstCollect = EPOCH - 30 * 86400 + 60,
		FirstUpgrade = EPOCH - 86400,
	},
	purchases = { ["receipt-1"] = EPOCH - 20000, ["receipt-2"] = EPOCH - 10000 },
	game = { sandbox = { blockTouches = 321 } },
	mail = {
		seen = { ["m-old"] = EPOCH - 5000 },
		attempts = { ["m-retry"] = 2 },
		dead = {
			{
				id = "m-dead",
				kind = "custom_kind",
				payload = { n = 1 },
				attempts = 10,
				error = "handler broke",
				at = EPOCH - 4500,
			},
		},
		box = {
			["m-held"] = {
				id = "m-held",
				kind = "core_gift",
				payload = { item = item("u-gift", "shell", EPOCH - 4200, { source = "drop" }) },
				sentAt = EPOCH - 4000,
				heldAt = EPOCH - 3900,
			},
		},
		outbox = {
			["k-out"] = {
				toUserId = 902,
				kind = "core_gift",
				payload = { item = item("u-out", "twig", EPOCH - 300, { source = "drop" }) },
				key = "k-out",
				at = EPOCH - 100,
			},
		},
	},
}

return { EPOCH = EPOCH, DAY = DAY, save = save }
