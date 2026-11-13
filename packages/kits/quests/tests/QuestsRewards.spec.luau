--!nocheck
--[[
	Quests rewards (docs/framework/kits/quests.md, "Reward", "Roll rewards: disclosed, luck 1, never
	paid"): a roll reward rolls at luck exactly 1 while the player has a session luck boost, the
	disclosed extra.questOdds are Rarity.getOddsDetail(table, nil, 1), a paid table is a boot error,
	rolled copies carry the quest's source, and a full inventory refuses before rolling.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F
local Quests = K.Quests
local Economy = K.ref("Economy")
local Items = K.ref("Items")
local Inventory = K.ref("Inventory")
local Rarity = K.ref("Rarity")

local function rollConfig(cap)
	return {
		daily = { count = 0, rerollsPerSlot = 0 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = {
			crate = F.quest(
				"repeatable",
				{ F.counter("open", 1) },
				{ cap = cap or 100, reward = { F.roll("FreeCrate") } }
			),
		},
	}
end

local function boot(cap, invCap)
	return K.boot({
		quests = rollConfig(cap),
		modules = { Items, Inventory, Rarity },
		items = F.items(),
		config = { Rarity = F.rarity(), Inventory = { inventory = { cap = invCap or 500 } } },
	})
end

local function stars(inv, p, source)
	local n, total = 0, 0
	for _, inst in inv.list(p) do
		if source == nil or inst.source == source then
			total += 1
			if inst.itemId == "star" then
				n += 1
			end
		end
	end
	return n, total
end

describe("Quests roll rewards", function()
	it("roll at luck exactly 1 even while the player has a luck boost", function()
		local h, p, q = boot()
		local rarity = h:use(Rarity)
		rarity.setLuck(p, 1000, "FreeCrate")
		-- the boost is real: Rarity's own roll at session luck lands on the rare tier
		for _ = 1, 40 do
			rarity.roll("FreeCrate", p, nil, { grant = true, reason = "test" })
		end
		local inv = h:use(Inventory)
		local boosted = stars(inv, p, "test")
		expect(boosted >= 36).toBe(true)
		for _ = 1, 100 do
			q.progress(p, "open")
			expect(q.claim(p, "crate")).toBe(true)
		end
		local starCount, total = stars(inv, p, "Quests:crate")
		expect(total).toBe(100)
		expect(starCount < 60).toBe(true) -- 1 in 4 at luck 1 (about 25), not ~100
		expect(starCount > 5).toBe(true)
	end)

	it("replicates extra.questOdds = getOddsDetail(table, nil, 1) to everyone", function()
		local h, p = boot()
		local rarity = h:use(Rarity)
		rarity.setLuck(p, 50, "FreeCrate")
		h:tick(1)
		local odds = h:state(p).modules.Quests.extra.questOdds
		expect(odds.FreeCrate).toEqual(rarity.getOddsDetail("FreeCrate", nil, 1))
		expect(odds.PaidCrate).toBe(nil) -- only tables a roll reward names
		local p2 = h:addPlayer({ userId = 2 })
		expect(h:state(p2).modules.Quests.extra.questOdds.FreeCrate).toEqual(odds.FreeCrate)
	end)

	it("a paid table is a boot error", function()
		local c = rollConfig()
		c.quests.crate.reward = { F.roll("PaidCrate") }
		local h, err = StudWork.test.boot({
			modules = { Quests, Items, Inventory, Rarity },
			items = F.items(),
			config = { Quests = c, Rarity = F.rarity() },
		})
		expect(h).toBe(nil)
		expect(string.find(err, "is paid", 1, true) ~= nil).toBe(true)
	end)

	it("a full inventory refuses the roll before anything is rolled or recorded", function()
		local h, p, q = boot(5, 1)
		local inv = h:use(Inventory)
		inv.add(p, "gem")
		q.progress(p, "open")
		expect(select(2, q.claim(p, "crate"))).toBe("inventory_full")
		expect(inv.count(p)).toBe(1)
		expect(q.state(p, "crate").claims).toBe(0)
		expect(q.state(p, "crate").status).toBe("complete")
		expect(h:warnings()).toEqual({})
	end)

	it("grants currency, items and rolls together in one claim", function()
		local c = rollConfig()
		c.quests.crate.reward = { F.currency(25), F.item("gem", 2), F.roll("FreeCrate") }
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy, Items, Inventory, Rarity },
			items = F.items(),
			config = { Economy = F.economy(), Rarity = F.rarity() },
		})
		local got
		q.signals.Claimed:Connect(function(_, id, rewards)
			got = { id = id, n = #rewards }
		end)
		q.progress(p, "open")
		expect(q.claim(p, "crate")).toBe(true)
		expect(h:use(Economy).balance(p)).toBe(25)
		expect(h:use(Inventory).count(p)).toBe(3)
		expect(got).toEqual({ id = "crate", n = 3 })
	end)

	it("logs the claim analytics and the funnel step on the first claim", function()
		local c = rollConfig()
		c.quests.crate.reward = {}
		c.quests.crate.funnel = "FirstCrate"
		local h, p, q = K.boot({ quests = c, analytics = { funnel = { "Joined", "FirstCrate" } } })
		q.progress(p, "open")
		q.claim(p, "crate")
		q.progress(p, "open")
		q.claim(p, "crate")
		local funnel, custom = 0, {}
		for _, call in h.fake.analytics do
			if call.kind == "funnel" and call.name == "FirstCrate" then
				funnel += 1
			elseif call.kind == "custom" and call.name == "QuestClaimed" then
				table.insert(custom, call.fields.quest .. ":" .. call.fields.kind .. ":" .. call.value)
			end
		end
		expect(funnel).toBe(1)
		expect(custom).toEqual({ "crate:repeatable:1", "crate:repeatable:1" })
	end)
end)
