--!nocheck
--[[
	Offline on the framework clock (core-v1.3.0 Phase 2: ctx.now). The real Offline + Economy
	server parts on the plain StudWork harness. Time away is measured from the framework's
	lastSeen stamp to ctx.now, both driven only by the harness clock (h:rejoin's secondsAway),
	which is years away from the real os.time(): a module still reading os.time() would see
	every return capped.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local ModuleServers = require("packages/kits/economy/server/ModuleServers.luau")

local Kit = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy")
local Economy = require(Kit:WaitForChild("Economy"))
local Offline = require(Kit:WaitForChild("Offline"))

local function boot(offline: any?)
	return Harness.new({
		modules = { Economy, Offline },
		servers = {
			Economy = ModuleServers.loadServer({ name = "Economy", server = "Economy" }),
			Offline = ModuleServers.loadServer({ name = "Offline", server = "Offline" }),
		},
		startTime = 1_600_000_000,
		config = {
			Economy = { startingCurrency = { Coins = 0 } },
			Offline = { offline = offline or { capSeconds = 3600, minSeconds = 60, autoPay = false } },
		},
	})
end

describe("Offline: time away on ctx.now", function()
	it("reports exactly the harness time away, skips short absences, caps long ones", function()
		local h = boot()
		local returns = {}
		h:use(Offline).onReturn(function(player, seconds)
			table.insert(returns, { userId = player.UserId, seconds = seconds })
		end)
		local p = h:addPlayer({ userId = 7 })
		expect(#returns).toBe(0) -- first session: nothing

		h:rejoin(p, { secondsAway = 600 })
		expect(#returns).toBe(1)
		expect(returns[1].seconds).toBe(600)

		h:rejoin(p, { secondsAway = 30 }) -- under minSeconds
		expect(#returns).toBe(1)

		h:rejoin(p, { secondsAway = 5 * 3600 }) -- capped at capSeconds
		expect(#returns).toBe(2)
		expect(returns[2].seconds).toBe(3600)
	end)
end)
