--!nocheck
--[[
	Quests: the deterministic deal (Quests/shared/Deal.luau and the server's use of it). The pinned
	values were computed independently (a reference implementation of the page's algorithm outside
	Luau); FNV-1a("abc") = 0x1A47E90B is the published test vector.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Deal = require(ReplicatedStorage.Modules.Quests.shared.Deal)
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F

local W = { d1 = 1, d2 = 1, d3 = 2, d4 = 1 }
local POOL = { "d1", "d2", "d3", "d4" }
local DAY = 19675 -- the harness's default startTime (1_700_000_000) is day 19675 at offset 0

describe("Quests Deal (pure)", function()
	it("pins fnv1a32, xorshift32 and the seed string", function()
		expect(Deal.fnv1a32("")).toBe(2166136261)
		expect(Deal.fnv1a32("a")).toBe(3826002220)
		expect(Deal.fnv1a32("abc")).toBe(0x1A47E90B)
		expect(Deal.xorshift32(1)).toBe(270369)
		expect(Deal.xorshift32(0x9E3779B9)).toBe(1359758873)
		expect(Deal.xorshift32(4294967295)).toBe(253983)
		expect(Deal.seed(1, "daily", 19675, 1, 1, 0)).toBe(437054717)
		expect(Deal.seed(42, "weekly", 19670, 3, 2, 1)).toBe(4261497181)
	end)

	it("pins the dealt sets (weights included) and the zero-seed fallback", function()
		local expected = {
			[1] = { "d3", "d1", "d4" },
			[2] = { "d4", "d3", "d1" },
			[3] = { "d1", "d2", "d3" },
			[42] = { "d4", "d3", "d1" },
			[1001] = { "d1", "d3", "d2" },
		}
		for userId, ids in expected do
			local got = Deal.deal({
				userId = userId,
				kind = "daily",
				periodId = DAY,
				poolVersion = 1,
				pool = POOL,
				weights = W,
				count = 3,
			})
			expect(`{userId}:{table.concat(got, ",")}`).toBe(`{userId}:{table.concat(ids, ",")}`)
		end
		expect(Deal.pick(POOL, W, 0)).toBe("d2")
		expect(Deal.pick({}, W, 5)).toBe(nil)
		-- candidate order doesn't matter: they are walked in id order
		expect(Deal.pick({ "d4", "d2", "d3", "d1" }, W, 437054717)).toBe(Deal.pick(POOL, W, 437054717))
	end)

	it("deals min(count, #pool) distinct ids", function()
		local got = Deal.deal({
			userId = 7,
			kind = "weekly",
			periodId = 1,
			poolVersion = 1,
			pool = { "a", "b" },
			weights = {},
			count = 5,
		})
		expect(#got).toBe(2)
		expect(got[1] ~= got[2]).toBe(true)
	end)
end)

describe("Quests deal on the server", function()
	it("deals the pinned set to user 1 on day 19675 and saves it", function()
		local h, p, q = K.boot()
		expect(K.ids(q, p, "daily")).toEqual({ "d3", "d1", "d4" })
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(s.day.id).toBe(DAY)
		expect(K.slotIds(s.day)).toEqual({ "d3", "d1", "d4" })
		expect(s.day.seen).toEqual({ d1 = true, d2 = false, d3 = true, d4 = true })
		expect(#s.week.slots).toBe(2)
	end)

	it("gives the same set and progress after a rejoin on another server (shared store)", function()
		local store = StudWork.test.memoryStore()
		local a = K.harness({ store = store })
		local p = a:addPlayer({ userId = 42 })
		local qa = a:use(K.Quests)
		local daily = K.ids(qa, p, "daily")
		expect(daily).toEqual({ "d4", "d3", "d1" })
		qa.progress(p, "jump", 4)
		a:removePlayer(p)
		local b = K.harness({ store = store })
		local p2 = b:addPlayer({ userId = 42 })
		local qb = b:use(K.Quests)
		expect(K.ids(qb, p2, "daily")).toEqual(daily)
		expect(qb.state(p2, "d4").values).toEqual({ 4 })
	end)

	it("deals the same set again after a crash rolled the save back (no saved set yet)", function()
		local a = K.harness({ store = StudWork.test.memoryStore() })
		local b = K.harness({ store = StudWork.test.memoryStore() })
		local pa = a:addPlayer({ userId = 1001 })
		local pb = b:addPlayer({ userId = 1001 })
		expect(K.ids(a:use(K.Quests), pa, "daily")).toEqual({ "d1", "d3", "d2" })
		expect(K.ids(b:use(K.Quests), pb, "daily")).toEqual({ "d1", "d3", "d2" })
	end)

	it("refills a removed quest's slot deterministically, but not a claimed one", function()
		local section = {
			day = {
				id = DAY,
				slots = {
					{ q = "d1", n = { 2 }, s = 0, r = 0 },
					{ q = "gone", n = { 1 }, s = 0, r = 0 },
					{ q = "old", n = { 9 }, s = 2, r = 0 },
				},
				seen = { d1 = true, d2 = false, d3 = false, d4 = false, gone = true, old = true },
			},
		}
		local function loadOnce()
			local h, p, q = K.boot({ data = K.saveWith(section) })
			return h, p, q
		end
		local h, p, q = loadOnce()
		local ids = K.ids(q, p, "daily")
		expect(#ids).toBe(2) -- d1 + the refill; the claimed placeholder is hidden
		expect(ids[1]).toBe("d1")
		local refill = ids[2]
		local candidates = { "d2", "d3", "d4" }
		expect(Deal.pick(candidates, W, Deal.seed(1, "daily", DAY, 1, 2, 0))).toBe(refill)
		expect(q.state(p, "d1").values).toEqual({ 2 })
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(#s.day.slots).toBe(3)
		expect(s.day.slots[3]).toEqual({ q = "old", n = { 9 }, s = 2, r = 0 })
		expect(s.day.seen.gone).toBe(nil)
		-- deterministic: another server loading the same old save refills the same id
		local _, p2, q2 = loadOnce()
		expect(K.ids(q2, p2, "daily")[2]).toBe(refill)
	end)

	it("keeps quests with unmet requires out of the deal", function()
		local cfg = F.questsConfig({
			daily = { count = 3, rerollsPerSlot = 1 },
		})
		cfg.quests.d2 = F.quest("daily", { F.counter("crate", 3) }, { requires = { quests = { "once" } } })
		cfg.quests.d5 = F.quest("daily", { F.counter("fish", 1) }, { requires = { quests = { "once" } } })
		local h, p, q = K.boot({ quests = cfg, userId = 3 })
		local ids = K.ids(q, p, "daily")
		table.sort(ids)
		expect(ids).toEqual({ "d1", "d3", "d4" })
		expect(q.state(p, "d2").status).toBe("locked")
		h:removePlayer(p)
		expect(K.section(h, p).day.seen).toEqual({ d1 = true, d3 = true, d4 = true })
	end)
end)
