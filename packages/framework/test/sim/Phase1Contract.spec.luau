--[[
	core-v1.3.0 Phase 1: every entry of (internal build report, not public) is
	offered by the kit modules through the framework's normal surfaces (api / txApi / extensions /
	api.signals, Extensions.wrap*). Real kit modules, real framework: the _sandbox game (all eleven
	modules) and the sim fixture game (a free currency, Mail).
]]

local F = require(script.Parent.Fixtures)

local SANDBOX = "games/_sandbox/default.project.json"

local function loaded(world, server, player): boolean
	return world:advanceUntil(function()
		return server:isLoaded(player)
	end, 30)
end

local function refOf(server, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	error("no module " .. name)
end

local function api(server, name: string): any
	return server.runtime.apis[refOf(server, name)]
end
local function txApi(server, name: string): any
	return server.runtime.txApis[refOf(server, name)]
end
local function ext(server, name: string): any
	return server.runtime.exts[refOf(server, name)]
end

-- One framework tx for `player` (what ctx.tx does for a module).
local function inTx(server, player, fn): (boolean, any)
	return server.runtime.data.runTx(player, fn)
end

local function sandbox(userId: number)
	local world = F.world()
	local server = F.gameServer(world, SANDBOX)
	local p = server:join(userId)
	assert(loaded(world, server, p), "load")
	world:advance(1)
	return world, server, p
end

local function record(signal): { any }
	local calls = {}
	signal:Connect(function(...)
		table.insert(calls, table.pack(...))
	end)
	return calls
end

describe("Phase 1 contract on bridged modules: Collection", function()
	it("Items.mutation(id) / mutations(): frozen defs with the economy namespace", function()
		local world, server = sandbox(301)
		local Items = api(server, "Items")
		local gold = Items.mutation("Gold")
		expect(gold.id).toBe("Gold")
		expect(gold.multiplier).toBe(2)
		expect(gold.economy.incomeMultiplier).toBe(2)
		expect(table.isfrozen(gold)).toBe(true)
		expect(table.isfrozen(gold.economy)).toBe(true)
		expect(Items.mutation("Nope")).toBeNil()
		local all = Items.mutations()
		expect(#all).toBe(2)
		expect(all[2].economy.incomeMultiplier).toBe(5)
		expect(#world:errors()).toBe(0)
	end)

	it("Rarity.txApi.roll(tx, tableId, luck?) rolls through compliance inside the caller's tx", function()
		local world, server, p = sandbox(302)
		local Rarity = txApi(server, "Rarity")
		local def, info
		local committed = inTx(server, p, function(tx)
			def, info = Rarity.roll(tx, "Block")
		end)
		expect(committed).toBe(true)
		expect(info.ok).toBe(true)
		expect(type(def.id)).toBe("string")
		local _, bad
		inTx(server, p, function(tx)
			_, bad = Rarity.roll(tx, "NoSuchTable")
		end)
		expect(bad.ok).toBe(false)
		expect(bad.reason).toBe("unknown_table")
		expect(api(server, "Rarity").tiers()[1] ~= nil).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("Inventory.txApi add/remove/list/count + signals on api.signals", function()
		local world, server, p = sandbox(303)
		local Inv = txApi(server, "Inventory")
		local signals = api(server, "Inventory").signals
		local added, removed = record(signals.ItemAdded), record(signals.ItemRemoved)
		local before = api(server, "Inventory").count(p)
		local instance, n, list
		inTx(server, p, function(tx)
			instance = Inv.add(tx, "twig", { source = "drop" })
			n = Inv.count(tx)
			list = Inv.list(tx)
		end)
		expect(instance.itemId).toBe("twig")
		expect(n).toBe(before + 1)
		expect(#list).toBe(before + 1)
		expect(table.isfrozen(list[1])).toBe(true)
		world:advance(0.1)
		expect(#added).toBe(1)
		expect(api(server, "Inventory").get(p, instance.uid).itemId).toBe("twig")

		local ok
		inTx(server, p, function(tx)
			ok = Inv.remove(tx, instance.uid, "test")
		end)
		expect(ok).toBe(true)
		local again
		inTx(server, p, function(tx)
			again = Inv.remove(tx, instance.uid, "test")
		end)
		expect(again).toBe(false)
		world:advance(0.1)
		expect(#removed).toBe(1)
		expect(removed[1][2].uid).toBe(instance.uid)
		expect(api(server, "Inventory").get(p, instance.uid)).toBeNil()
		expect(#world:errors()).toBe(0)
	end)

	it(
		"Inventory.extensions.onItemRemoved: inside txApi.remove's tx; a fresh tx after a v1.2 removal",
		function()
			local world, server, p = sandbox(304)
			local rt = server.runtime
			local hooks = {}
			local openTx = nil
			ext(server, "Inventory").onItemRemoved(function(tx, player, instance)
				table.insert(hooks, {
					valid = rt.data.isTxHandle(tx),
					same = tx == openTx,
					userId = player.UserId,
					uid = instance.uid,
					frozen = table.isfrozen(instance),
				})
			end)
			local Inventory = api(server, "Inventory")
			local a = Inventory.add(p, "twig", { source = "drop" })
			local b = Inventory.add(p, "acorn", { source = "drop" })
			-- txApi.remove: the hook runs inside the removing tx (contract semantics), exactly once
			inTx(server, p, function(tx)
				openTx = tx
				txApi(server, "Inventory").remove(tx, a.uid, "test")
			end)
			openTx = nil
			world:advance(0.1)
			expect(#hooks).toBe(1)
			expect(hooks[1].same).toBe(true)
			expect(hooks[1].uid).toBe(a.uid)
			-- v1.2 api.remove: bridged semantics, a fresh tx right after the removal commits
			Inventory.remove(p, b.uid, "test")
			world:advance(0.1)
			expect(#hooks).toBe(2)
			expect(hooks[2].valid).toBe(true)
			expect(hooks[2].same).toBe(false)
			expect(hooks[2].userId).toBe(304)
			expect(hooks[2].uid).toBe(b.uid)
			expect(hooks[2].frozen).toBe(true)
			expect(#world:errors()).toBe(0)
		end
	)
end)

describe("Phase 1 contract on bridged modules: Economy kit", function()
	it("Economy.txApi.grant + CurrencyChanged; txApi.spend refuses a paid currency", function()
		local world, server, p = sandbox(305)
		local Economy = api(server, "Economy")
		local changed = record(Economy.signals.CurrencyChanged)
		local before = Economy.balance(p)
		local granted
		inTx(server, p, function(tx)
			granted = txApi(server, "Economy").grant(tx, 40, "quest")
		end)
		expect(granted).toBe(true)
		expect(Economy.balance(p)).toBe(before + 40)
		world:advance(0.1)
		local seen = false
		for _, c in changed do
			if c[5] == "quest" and c[4] == 40 then
				seen = true
			end
		end
		expect(seen).toBe(true)
		-- sandbox Coins are sold for Robux (compliance.paidCurrencies)
		local ok, err = pcall(inTx, server, p, function(tx)
			txApi(server, "Economy").spend(tx, 1, "test")
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "spendForRoll", 1, true) ~= nil).toBe(true)
		expect(Economy.balance(p)).toBe(before + 40)
	end)

	it("Economy.txApi.spend of a free currency, in the caller's tx", function()
		local world = F.world()
		local server = F.server(world)
		local p = server:join(306)
		assert(loaded(world, server, p), "load")
		local Economy = api(server, "Economy")
		Economy.grant(p, 100, "test")
		local changed = record(Economy.signals.CurrencyChanged)
		local spent, tooMuch
		inTx(server, p, function(tx)
			spent = txApi(server, "Economy").spend(tx, 30, "shop:hat")
			tooMuch = txApi(server, "Economy").spend(tx, 1000, "shop:car")
		end)
		expect(spent).toBe(true)
		expect(tooMuch).toBe(false)
		expect(Economy.balance(p)).toBe(70)
		world:advance(0.1)
		expect(#changed).toBe(1)
		expect(changed[1][4]).toBe(-30)
		expect(changed[1][5]).toBe("shop:hat")
		expect(#world:errors()).toBe(0)
	end)

	it("Upgrades/Rebirth signals; Rebirth.extensions.resetStep runs inside the rebirth tx", function()
		local world, server, p = sandbox(307)
		local rt = server.runtime
		expect(api(server, "Upgrades").signals.UpgradePurchased ~= nil).toBe(true)
		local rebirthed = record(api(server, "Rebirth").signals.Rebirthed)
		local steps = {}
		ext(server, "Rebirth").resetStep("phase1-test", function(tx, player)
			local section = rt.data.section(tx, "rebirth")
			table.insert(steps, {
				valid = rt.data.isTxHandle(tx),
				userId = player.UserId,
				rebirthsInTx = section.rebirths,
			})
		end)
		api(server, "Economy").grant(p, 5000, "test")
		expect(api(server, "Rebirth").rebirth(p)).toBe(true)
		world:advance(0.1)
		expect(#steps).toBe(1)
		expect(steps[1].valid).toBe(true)
		expect(steps[1].userId).toBe(307)
		expect(steps[1].rebirthsInTx).toBe(0) -- before the v1.2 update's `rebirths += 1`
		expect(#rebirthed).toBe(1)
		expect(rebirthed[1][2]).toBe(1)
		expect(#world:errors()).toBe(0)
	end)
end)

describe("Phase 1 contract on bridged modules: Base and Social", function()
	it("Plot.displayed(player) is a frozen slot -> uid map; DisplayCleared(player, slotId)", function()
		local world, server, p = sandbox(308)
		local Plot = api(server, "Plot")
		local cleared = record(Plot.signals.DisplayCleared)
		expect(Plot.signals.ItemDisplayed ~= nil).toBe(true)
		-- the sim has no plot models (Plot.display needs one), so write Plot's section as v1.2 does
		local item = api(server, "Inventory").add(p, "twig", { source = "drop" })
		inTx(server, p, function(tx)
			server.runtime.data.section(tx, "plot").displayed.slot07 = item.uid
		end)
		local displayed = Plot.displayed(p)
		expect(table.isfrozen(displayed)).toBe(true)
		expect(displayed.slot07).toBe(item.uid)
		expect(pcall(function()
			(displayed :: any).slot07 = nil
		end)).toBe(false)
		-- DisplayCleared(player, slotId) follows the v1.2 ItemUndisplayed(player, uid, slotId)
		Plot.signals.ItemUndisplayed:Fire(p, item.uid, "slot07")
		world:advance(0.1)
		expect(#cleared).toBe(1)
		expect(cleared[1][1].UserId).toBe(308)
		expect(cleared[1][2]).toBe("slot07")
		expect(cleared[1].n).toBe(2)
		expect(#world:errors()).toBe(0)
	end)

	it("Mail.txApi.send + extensions.registerKind: claimFn in a tx; false holds; true delivers", function()
		local world = F.world()
		local server = F.server(world)
		local rt = server.runtime
		local a, b = server:join(311), server:join(312)
		assert(loaded(world, server, a) and loaded(world, server, b), "load")
		local claims = {}
		local answer = false
		ext(server, "Mail").registerKind("phase1_test", function(tx, player, payload, info)
			table.insert(claims, {
				valid = rt.data.isTxHandle(tx),
				userId = player.UserId,
				n = payload.n,
				kind = info.kind,
			})
			if answer then
				txApi(server, "Economy").grant(tx, payload.n, "mail")
			end
			return answer
		end)
		local sent
		inTx(server, a, function(tx)
			sent = txApi(server, "Mail").send(tx, 312, "phase1_test", { n = 7 })
		end)
		expect(sent).toBe(true)
		world:advanceUntil(function()
			return #claims >= 1
		end, 30)
		world:advance(1)
		expect(claims[1].valid).toBe(true)
		expect(claims[1].userId).toBe(312)
		expect(claims[1].n).toBe(7)
		expect(claims[1].kind).toBe("phase1_test")
		local Mail = api(server, "Mail")
		local pending = Mail.pending(b)
		expect(#pending).toBe(1) -- held
		expect(api(server, "Economy").balance(b)).toBe(0)
		answer = true
		expect((Mail.claim(b, pending[1].id))).toBe(true)
		expect(#Mail.pending(b)).toBe(0)
		expect(api(server, "Economy").balance(b)).toBe(7)
		expect(#world:errors()).toBe(0)
	end)
end)
