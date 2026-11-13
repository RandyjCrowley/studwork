--!nocheck
--[[
	Gate sim: the Quests daily/weekly reset across the boundary (StudWork.test.sim, several servers
	sharing one mock cloud). For utcOffsetHours -5, 0 and +9: the set dealt before the boundary is
	the same after a rejoin on another server, and a new set is dealt after the boundary on the
	server the player is on (and is again the same on the next server). Weekly sets turn over on
	monday or sunday as configured.
	Run: tools/test-sim packages/kits/quests/tests/QuestsResetSim.spec.luau (also part of tools/test).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = StudWork.test.sim

local DAY = 86400

local function questsConfig(extra)
	local quests = {}
	for i = 1, 6 do
		quests["d" .. i] =
			{ kind = "daily", objectives = { { kind = "counter", key = "k" .. i, target = 5 } } }
	end
	for i = 1, 4 do
		quests["w" .. i] =
			{ kind = "weekly", objectives = { { kind = "counter", key = "k" .. i, target = 50 } } }
	end
	local cfg = {
		daily = { count = 3, rerollsPerSlot = 1 },
		weekly = { count = 2, rerollsPerSlot = 0 },
		quests = quests,
	}
	for k, v in extra or {} do
		cfg[k] = v
	end
	return cfg
end

local function world(epoch, cfg)
	return F.world({
		epoch = epoch,
		config = { modules = { "Quests" }, config = { Quests = cfg } },
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

local function slots(server, p, kind)
	local out, period = {}, nil
	for _, v in server:use("Quests").active(p) do
		if v.kind == kind and not v.waiting then
			table.insert(out, v.id)
			period = v.periodId
		end
	end
	return table.concat(out, ","), period
end

local function leave(w, server, p)
	server:leave(p)
	w:advance(10, 0.5)
end

describe("Quests reset across the boundary (sim)", function()
	for _, offset in { -5, 0, 9 } do
		it(`utcOffsetHours {offset}: same set after a server hop, a new set after the boundary`, function()
			local reset = 19676 * DAY - offset * 3600
			local w = world(reset - 60, questsConfig({ utcOffsetHours = offset }))
			local a = F.server(w)
			local b = F.server(w)
			local p = join(w, a, 77)
			local before, period = slots(a, p, "daily")
			expect(period).toBe(19675)
			local qa = a:use("Quests")
			for id in string.gmatch(before, "[^,]+") do
				qa.progress(p, qa.def(id).objectives[1].key, 2)
			end
			leave(w, a, p)
			local p2 = join(w, b, 77)
			local same, samePeriod = slots(b, p2, "daily")
			expect(same).toBe(before)
			expect(samePeriod).toBe(19675)
			for _, v in b:use("Quests").active(p2) do
				if v.kind == "daily" then
					expect(v.objectives[1].value).toBe(2) -- the progress came along
				end
			end
			-- cross the boundary on b
			w:advance(90, 0.5)
			local after, newPeriod = slots(b, p2, "daily")
			expect(newPeriod).toBe(19676)
			expect(b:heard("Quests.Rotated"):count() >= 1).toBe(true)
			-- and the new set is the same on the next server
			leave(w, b, p2)
			local p3 = join(w, a, 77)
			local again, againPeriod = slots(a, p3, "daily")
			expect(again).toBe(after)
			expect(againPeriod).toBe(19676)
			expect(#w:errors()).toBe(0)
		end)
	end

	for _, case in { { starts = "monday", boundary = 19681 }, { starts = "sunday", boundary = 19680 } } do
		it(`weekly sets turn over on {case.starts}`, function()
			local w = world(case.boundary * DAY - 60, questsConfig({ weekStartsOn = case.starts }))
			local a = F.server(w)
			local p = join(w, a, 5)
			local _, period = slots(a, p, "weekly")
			expect(period).toBe(case.boundary - 7)
			w:advance(90, 0.5)
			local _, newPeriod = slots(a, p, "weekly")
			expect(newPeriod).toBe(case.boundary)
			expect(#w:errors()).toBe(0)
		end)
	end
end)
