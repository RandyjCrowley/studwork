--!nocheck
local RS = game:GetService("ReplicatedStorage")
local StudWork = require(RS.Framework)
local Items = require(RS.Modules.Items.module)
local Inventory = require(RS.Modules.Inventory.module)
local Economy = require(RS.Modules.Economy.module)
local Companions = require(RS.Modules.Companions.module)
local Follow = require(RS.Modules.Companions.client.Follow)
local Math = require(RS.Modules.Companions.shared.FollowMath)
describe("Companions desktop pure performance", function()
	it("measures actual module tick and event setup separately at fifty owners", function()
		local started = os.clock()
		local publications = 0
		local live = require(game:GetService("ServerScriptService").Modules.Companions).new()
		local initialize = live.init
		live.init = function(ctx)
			local proxy = table.clone(ctx)
			proxy.replicate = table.clone(ctx.replicate)
			proxy.replicate.setAll = function(key, value)
				publications += 1
				ctx.replicate.setAll(key, value)
			end
			initialize(proxy)
		end
		local h = StudWork.test.harness({
			modules = { Items, Inventory, Economy, Companions },
			servers = { Companions = live },
			items = {
				{
					id = "buddy",
					name = "Buddy",
					companions = { incomeBonus = 1 },
					economy = { incomePerSec = 1 },
				},
			},
			config = {
				Inventory = { starterItems = { "buddy", "buddy", "buddy" } },
				Companions = { incomeBonusEnabled = true },
			},
		})
		local players = {}
		for userId = 1, 50 do
			players[userId] = h:addPlayer({ userId = userId })
		end
		local api = h:use(Companions)
		for _, player in players do
			expect(#api.equipped(player)).toBe(3)
		end
		print(string.format("companions setup 50x3 %.3f ms", (os.clock() - started) * 1000))
		local initial = publications
		started = os.clock()
		for _ = 1, 600 do
			h:tick(1 / 60)
		end
		local tickMs = (os.clock() - started) * 1000 / 600
		print(string.format("companions+economy idle %.4f ms/tick; reference .94, threshold 1.128", tickMs))
		expect(tickMs < 1.128).toBe(true)
		started = os.clock()
		for _ = 1, 20 do
			for _, player in players do
				assert(api.refresh(player))
			end
		end
		print(string.format("no-op refresh %.4f ms/call", (os.clock() - started) * 1000 / 1000))
		h:tick(0.25)
		expect(publications).toBe(initial)
		for _ = 1, 4 do
			for _, player in players do
				local uid = api.equipped(player)[1].uid
				assert(api.unequip(player, uid))
			end
			h:tick(0.25)
			for _, player in players do
				assert(api.equipBest(player))
			end
			h:tick(0.25)
		end
		expect(publications - initial).toBe(8)
		print("churn: 400 mutations over 2s -> 8 roster publications; idle/no-op -> zero")
	end)
	it("times real nearest selection plus thirty motion calculations without engine draws", function()
		local candidates = {}
		for userId = 50, 1, -1 do
			for slot = 1, 3 do
				table.insert(candidates, { distance = userId, userId = userId, slot = slot })
			end
		end
		local started = os.clock()
		for frame = 1, 2000 do
			local selected = Follow.select(table.clone(candidates), 30)
			for _, candidate in selected do
				Math.formation(candidate.slot, 3, 3, 4)
				Math.alpha(1 / 30, 10)
				Math.motion("walk", frame / 30, 10, 0.5, false, false, 0.25, 1.5, 0.75)
			end
		end
		local elapsed = (os.clock() - started) * 1000 / 2000
		print(
			string.format(
				"150 candidates/30 selected pure selection+math %.4f ms/frame; excludes clones, raycasts, PivotTo, draws",
				elapsed
			)
		)
		expect(elapsed < 1).toBe(true)
		expect(#Follow.select(candidates, 12)).toBe(12)
	end)
end)
