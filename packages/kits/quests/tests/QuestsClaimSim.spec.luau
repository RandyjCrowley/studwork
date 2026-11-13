--!nocheck
--[[
	Gate sim: the Quests claim race (StudWork.test.sim: the real framework, the real ProfileStore
	session locks and the real Quests/Economy parts on several servers sharing one mock cloud).
	Each scenario must end with exactly one grant of the claimed reward:
	  a double claim (two actions in one frame), a claim during shutdown, a claim then a rejoin on a
	  second server, a save failure (world:failNext) around the claim, and a crash after the claim
	  (both lost together; the quest is claimable once again).
	Run: tools/test-sim packages/kits/quests/tests/QuestsClaimSim.spec.luau (also part of tools/test).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = StudWork.test.sim

local EPOCH = 19675 * 86400 + 12 * 3600 -- noon UTC: far from a boundary
local REWARD = 100

local function questsConfig()
	return {
		daily = { count = 0, rerollsPerSlot = 0 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = {
			once = {
				kind = "oneTime",
				objectives = { { kind = "counter", key = "tutorial", target = 1 } },
				reward = { { kind = "currency", amount = REWARD } },
			},
		},
	}
end

local function world()
	return F.world({
		epoch = EPOCH,
		config = {
			modules = { "Items", "Inventory", "Economy", "Quests" },
			config = { Quests = questsConfig() },
		},
	})
end

local function join(w, server, userId)
	local p = server:join(userId)
	assert(
		w:advanceUntil(function()
			return server:isLoaded(p)
		end, 120, 0.25),
		"loaded"
	)
	return p
end

local function coins(server, p)
	return server:section(p, "economy").currency.Coins
end

-- complete the quest and fold it into the save section
local function complete(w, server, p)
	server:use("Quests").progress(p, "tutorial")
	w:advance(2)
	assert(server:use("Quests").state(p, "once").status == "complete", "complete")
end

local function savedCoins(w, userId)
	local saved = F.saved(w, userId)
	return saved and saved.economy and saved.economy.currency.Coins or 0
end

describe("Quests claim race (sim)", function()
	it("a double claim grants once", function()
		local w = world()
		local a = F.server(w)
		local p = join(w, a, 1)
		complete(w, a, p)
		local ok1, first = a:action(p, "Quests", "claimQuest", "once")
		local ok2, second = a:action(p, "Quests", "claimQuest", "once")
		expect(ok1 and ok2).toBe(true)
		expect(first).toBe(true)
		expect(second).toBe(false)
		expect(coins(a, p)).toBe(REWARD)
		expect(#w:errors()).toBe(0)
	end)

	it("a claim during shutdown is saved with its grant; the next server sees it claimed", function()
		local w = world()
		local a = F.server(w)
		local p = join(w, a, 2)
		complete(w, a, p)
		expect(a:use("Quests").claim(p, "once")).toBe(true)
		local handle = a:shutdown()
		w:advanceUntil(function()
			return handle.done
		end, 60, 0.25)
		expect(savedCoins(w, 2)).toBe(REWARD)
		expect(F.saved(w, 2).quests.done.once ~= nil).toBe(true)
		local b = F.server(w)
		local p2 = join(w, b, 2)
		expect(select(2, b:use("Quests").claim(p2, "once"))).toBe("claimed")
		expect(coins(b, p2)).toBe(REWARD)
		expect(#w:errors()).toBe(0)
	end)

	it("a claim then a rejoin on a second server grants once", function()
		local w = world()
		local a = F.server(w)
		local b = F.server(w)
		local p = join(w, a, 3)
		complete(w, a, p)
		expect(a:use("Quests").claim(p, "once")).toBe(true)
		a:leave(p)
		local p2 = join(w, b, 3)
		local qb = b:use("Quests")
		expect(qb.state(p2, "once").status).toBe("claimed")
		qb.progress(p2, "tutorial")
		expect(select(2, qb.claim(p2, "once"))).toBe("claimed")
		expect(coins(b, p2)).toBe(REWARD)
		expect(#F.writerViolations(w, 3)).toBe(0)
	end)

	it("a save failure keeps the claim and the grant together: one grant in the end", function()
		local w = world()
		local a = F.server(w)
		local b = F.server(w)
		local p = join(w, a, 4)
		complete(w, a, p)
		expect(a:use("Quests").claim(p, "once")).toBe(true)
		-- the release save hits DataStore errors (ProfileStore retries)
		w:failNext(2, function(_op, _store, _key, writer)
			return writer == a.jobId
		end)
		a:leave(p)
		local p2 = join(w, b, 4)
		local qb = b:use("Quests")
		local status = qb.state(p2, "once").status
		if status ~= "claimed" then
			-- neither was saved: the quest is claimable once (never twice)
			expect(coins(b, p2)).toBe(0)
			qb.progress(p2, "tutorial")
			w:advance(2)
			expect(qb.claim(p2, "once")).toBe(true)
		end
		expect(select(2, qb.claim(p2, "once"))).toBe("claimed")
		expect(coins(b, p2)).toBe(REWARD)
		expect(#F.writerViolations(w, 4)).toBe(0)
	end)

	it("a crash after the claim loses both: the quest is claimable once again", function()
		local w = world()
		local a = F.server(w)
		local p = join(w, a, 5)
		complete(w, a, p)
		local h = a:spawn(a.save, a, p)
		w:advanceUntil(function()
			return h.done
		end, 30)
		expect(a:use("Quests").claim(p, "once")).toBe(true)
		expect(coins(a, p)).toBe(REWARD)
		a:crash() -- no saves, no BindToClose
		local b = F.server(w)
		local p2 = join(w, b, 5) -- waits for the dead session's lock
		local qb = b:use("Quests")
		expect(coins(b, p2)).toBe(0)
		expect(qb.state(p2, "once").status).toBe("complete")
		expect(qb.claim(p2, "once")).toBe(true)
		expect(select(2, qb.claim(p2, "once"))).toBe("claimed")
		expect(coins(b, p2)).toBe(REWARD)
	end)
end)
