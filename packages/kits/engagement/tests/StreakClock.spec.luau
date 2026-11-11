--!nocheck
--[[
	Streak on the framework clock (core-v1.3.0 Phase 2: ctx.now). The real Streak + Economy
	server parts on the plain StudWork harness; the harness clock (h.clock, h:rejoin's
	secondsAway) is the only time source, far from the real os.time(), so a module still reading
	os.time() would fail every day rollover below.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local EngagementServers = require("packages/kits/engagement/server/ModuleServers.luau")
local EconomyServers = require("packages/kits/economy/server/ModuleServers.luau")

local Kits = ReplicatedStorage:WaitForChild("Kits")
local Streak = require(Kits:WaitForChild("Engagement"):WaitForChild("Streak"))
local Economy = require(Kits:WaitForChild("Economy"):WaitForChild("Economy"))

local DAY = 86400
local HOUR = 3600
local NOON = 19000 * DAY + 12 * HOUR -- a UTC noon, years before the real clock

local function boot()
	return Harness.new({
		modules = { Economy, Streak },
		servers = {
			Economy = EconomyServers.loadServer({ name = "Economy", server = "Economy" }),
			Streak = EngagementServers.loadServer({ name = "Streak", server = "Streak" }),
		},
		startTime = NOON,
		config = {
			Economy = { startingCurrency = { Coins = 0 } },
			Streak = {
				streak = {
					graceHours = 6,
					rewards = { { day = 1, amount = 40 }, { day = 2, amount = 5 }, { day = 3, amount = 7 } },
				},
			},
		},
	})
end

describe("Streak: day rollover and grace on ctx.now", function()
	it("same day, next day, one missed day inside the grace window, then a reset", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local streak, economy = h:use(Streak), h:use(Economy)
		expect(streak.get(p).day).toBe(1)
		expect(economy.balance(p)).toBe(40)

		h:rejoin(p, { secondsAway = 3 * HOUR }) -- 15:00, same day
		expect(streak.get(p).day).toBe(1)
		expect(economy.balance(p)).toBe(40)

		h:rejoin(p, { secondsAway = 20 * HOUR }) -- next day 11:00
		expect(streak.get(p).day).toBe(2)
		expect(economy.balance(p)).toBe(45)

		-- skip a whole day; back 4 h after it ended (graceHours = 6): the streak continues
		h:rejoin(p, { secondsAway = 13 * HOUR + DAY + 4 * HOUR }) -- day+3, 04:00
		expect(h.clock).toBe(NOON + 2 * DAY + 16 * HOUR)
		expect(streak.get(p).day).toBe(3)
		expect(economy.balance(p)).toBe(52)

		-- skip another day; back 7 h after it ended: past the grace window -> reset to day 1
		h:rejoin(p, { secondsAway = 20 * HOUR + DAY + 7 * HOUR }) -- day+5, 07:00
		expect(streak.get(p).day).toBe(1)
		expect(economy.balance(p)).toBe(92)
	end)

	it("the hourly check rolls the day over for a player who stays online past midnight", function()
		local h = boot()
		local p = h:addPlayer({ userId = 2 })
		local streak = h:use(Streak)
		expect(streak.get(p).day).toBe(1)
		h:tick(13 * HOUR) -- online from noon to 01:00 the next day
		expect(streak.get(p).day).toBe(2)
	end)
end)
