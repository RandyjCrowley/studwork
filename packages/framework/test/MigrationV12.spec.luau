--!nocheck
--[[
	The full v1.2 save migration (v1.3.0). A real v1.2 PlayerData save with every
	field (fixtures/v12_save.luau) is put in the store the way a v1.2 server left it (ProfileStore
	`Data`), then loads through the real framework boot of the _sandbox game: its real Config, its
	own module and every real kit module, the real ProfileStore 1.0.3 on the sim's mock DataStore
	(StudWork.test.sim). Every value lands in its v1.3 section unchanged (FrameworkSection's v1.2
	split + each module's migration 001 + sanitize), the player acts on it (balance, multipliers,
	inventory and cap, plot, mailbox claim, outbox delivery, pity, streak), and a save + reload
	loses nothing.

	The sections are checked in the snapshot taken at the moment the player loaded
	(server:heard("framework.PlayerLoaded")), before any tick: income (source "displayed") starts
	paying right after.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Fixture = require(script.Parent.fixtures.v12_save)

local SANDBOX = "examples/sandbox/default.project.json"
local STORE = "PlayerData_sandbox"
local EPOCH = Fixture.EPOCH

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = copy(x)
	end
	return out
end

local function joinLoaded(world, s, userId: number)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 60, 0.05),
		"loaded " .. userId
	)
	return p
end

local function released(world, userId: number)
	assert(
		world:advanceUntil(function()
			local raw = world:peek(STORE, "Player_" .. userId)
			local session = raw and raw.MetaData and raw.MetaData.ActiveSession
			return session == nil
		end, 60),
		"released " .. userId
	)
end

local function loadSnapshot(s, p): any
	local found = nil
	for _, args in s:heard("framework.PlayerLoaded").history do
		if args[1] == p then
			found = args[2]
		end
	end
	return copy(found)
end

describe("v1.2 save migration (every field, real kit modules, _sandbox game)", function()
	it(
		"every value lands in its v1.3 section unchanged, the player acts on it, save + reload keeps it",
		function()
			local v12 = Fixture.save
			local sim = StudWork.test.sim
			local world = sim.world({ epoch = EPOCH - 5 })
			local seeder = sim.gameServer(world, SANDBOX)
			-- an existing ProfileStore profile (MetaData and all) whose Data is the v1.2 save
			local first = joinLoaded(world, seeder, 901)
			seeder:leave(first)
			released(world, 901)
			local raw = world:peek(STORE, "Player_901")
			raw.Data = copy(v12)
			world:seed(STORE, "Player_901", raw)
			expect(world:now() < EPOCH + 30).toBe(true) -- lastSeen stays under Offline's 60 s minimum

			local s = sim.gameServer(world, SANDBOX)
			local p = joinLoaded(world, s, 901)
			local at = loadSnapshot(s, p)
			expect(at ~= nil).toBe(true)

			-- 1. every field in its section, unchanged
			expect(at.economy).toEqual({ currency = v12.currency, multipliers = v12.multipliers })
			expect(at.inventory).toEqual({ inventory = v12.inventory })
			expect(at.plot).toEqual({ displayed = v12.displayed })
			expect(at.upgrades).toEqual({ upgrades = v12.upgrades })
			expect(at.rebirth).toEqual({ rebirths = v12.rebirths })
			expect(at.streak).toEqual({ streak = v12.streak })
			expect(at.rarity).toEqual({ pity = v12.pity })
			expect(at.sandbox).toEqual(v12.game.sandbox)
			local fw = at._framework
			expect(fw.firstJoin).toBe(v12.firstJoin)
			expect(fw.lastSeen).toBe(v12.lastSeen)
			expect(fw.purchases).toEqual(v12.purchases)
			expect(fw.funnel).toEqual(v12.funnel)
			expect(fw.stats.totalEarned).toBe(v12.stats.totalEarned)
			expect(fw.stats.rolls).toBe(v12.stats.rolls)
			expect(fw.stats.sessions).toBe(v12.stats.sessions + 1) -- this load is a session
			expect(fw.migratedFrom).toBe(v12.schemaVersion)
			expect(fw.legacy).toBeNil() -- no v1.2 field was left over
			expect(at.mail.mail.seen).toEqual(v12.mail.seen)
			expect(at.mail.mail.attempts).toEqual(v12.mail.attempts)
			expect(at.mail.mail.dead).toEqual(v12.mail.dead)
			expect(at.mail.mail.box).toEqual(v12.mail.box)
			-- the outbox entry the v1.2 server committed but never sent is sent the moment Mail sees
			-- the player loaded (before PlayerLoaded fires), so it already left the outbox; its
			-- delivery to the recipient, exactly once, is step 3
			expect(next(at.mail.mail.outbox or {})).toBeNil()

			-- 2. the player can act on it
			local econ, inv = s:use("Economy"), s:use("Inventory")
			expect(econ.balance(p) >= 12345).toBe(true) -- income (displayed items) pays from here on
			expect(econ.balance(p, "Gems")).toBe(7)
			-- vip x2, potion x1.5, rebirths 2 x 0.5 -> x2, IncomeBoost level 3 x 0.1 -> x1.3 (multiply)
			expect(econ.getMultiplier(p)).toBeNear(2 * 1.5 * 2 * 1.3, 1e-9)
			expect(s:use("Upgrades").level(p, "IncomeBoost")).toBe(3)
			expect(s:use("Upgrades").level(p, "BiggerBag")).toBe(2)
			expect(s:use("Rebirth").multiplier(p)).toBeNear(2, 1e-9)
			expect(inv.count(p)).toBe(5)
			expect(inv.cap(p)).toBe(50 + 2 * 5) -- BiggerBag level 2
			expect(inv.get(p, "u-paid").source).toBe("paid:EggRoll")
			expect(inv.get(p, "u-paidcur").source).toBe("paidcur:Chest")
			expect(inv.get(p, "u-meta").meta.note).toBe("from grandma")
			expect(inv.get(p, "u-rainbow").mutation).toBe("Rainbow")
			expect(copy(s:use("Plot").displayed(p))).toEqual(v12.displayed)
			expect(s:use("Streak").get(p).day).toBe(4) -- already counted today: no advance, no reward
			local mail = s:use("Mail")
			local pending = mail.pending(p)
			expect(#pending).toBe(1)
			expect(pending[1].id).toBe("m-held")
			expect(pending[1].kind).toBe("core_gift")
			expect(mail.claim(p, "m-held")).toBe(true)
			expect(inv.get(p, "u-gift").itemId).toBe("shell")
			expect(#mail.pending(p)).toBe(0)
			-- pity 9 of Chest's threshold 10: the next Chest roll is forced to Epic or better
			local def, info = s:use("Rarity").roll("Chest", p, nil, { grant = true, reason = "test" })
			expect(info.ok).toBe(true)
			expect(info.pity).toBe(true)
			expect(def.id == "feather" or def.id == "comet").toBe(true)
			expect(s:section(p, "rarity").pity.Chest).toBe(0)
			expect(s:section(p, "rarity").pity.Egg).toBe(5)

			-- 3. the outbox entry the v1.2 server never sent reaches its recipient, exactly once
			local other = sim.gameServer(world, SANDBOX)
			local q = joinLoaded(world, other, 902)
			expect(world:advanceUntil(function()
				return other:use("Inventory").get(q, "u-out") ~= nil
			end, 120, 0.25)).toBe(true)
			expect(inv.get(p, "u-out")).toBeNil()
			expect(next(s:section(p, "mail").mail.outbox or {})).toBeNil()

			-- the expiring multiplier expires on the framework clock; the persisted one stays
			world:advance(EPOCH + 601 - world:now(), 0.5)
			expect(econ.getMultiplier(p)).toBeNear(2 * 2 * 1.3, 1e-9)
			expect(s:section(p, "economy").multipliers.potion).toBeNil()
			expect(copy(s:section(p, "economy").multipliers.vip)).toEqual({ mult = 2 })
			-- the next day counts: day 5
			world:advance(86400, 60)
			expect(s:use("Streak").get(p).day).toBe(5)

			-- 4. save + reload elsewhere: nothing lost
			local before = s:sections(p)
			before = copy(before)
			s:leave(p)
			released(world, 901)
			local saved = world:peek(STORE, "Player_901").Data
			expect(saved._versions.economy).toBe(1)
			expect(saved._versions.inventory).toBe(1)
			local p2 = joinLoaded(world, other, 901)
			local after = loadSnapshot(other, p2)
			for key, value in before do
				local got = after[key]
				if key == "_framework" then
					expect(got.stats.sessions).toBe(value.stats.sessions + 1)
					expect(got.lastSeen >= value.lastSeen).toBe(true) -- stamped by the leave save
					got.stats.sessions, value.stats.sessions = nil, nil
					got.lastSeen, value.lastSeen = nil, nil
				end
				expect(got).toEqual(value)
			end
			expect(other:use("Inventory").count(p2)).toBe(7) -- 5 + the claimed gift + the pity roll
			expect(#world:errors()).toBe(0)
		end
	)
end)
