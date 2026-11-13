--!strict
local RS = game:GetService("ReplicatedStorage")
local StudWork = require(RS.Framework)
local Items = require(RS.Modules.Items.module)
local Inventory = require(RS.Modules.Inventory.module)
local Companions = require(RS.Modules.Companions.module)
local Economy = require(RS.Modules.Economy.module)
local Rebirth = require(RS.Modules.Rebirth.module)
local State = require(RS.Modules.Companions.client.State)
local function boot(config: any?, extra: any?): any
	local opts: any = {
		modules = { Items, Inventory, Companions },
		items = {
			{
				id = "pebble",
				name = "Pebble",
				rarity = "Common",
				companions = { score = 1, incomeBonus = 2 },
			},
			{ id = "bird", name = "Bird", rarity = "Rare", companions = { score = 2, incomeBonus = 4 } },
			{ id = "stone", name = "Stone", rarity = "Common" },
		} :: { any },
		config = { Companions = config or { autoEquipBest = false } },
	}
	for key, value in extra or {} do
		opts[key] = value
	end
	return StudWork.test.harness(opts)
end
local function extensionHarness(): (any, any)
	local holder: any = {}
	local Probe = StudWork.defineModule({
		name = "CompanionProbe",
		version = "1.0.0",
		framework = "^1.7.0",
		dependsOn = { Companions, Inventory },
	})
	local h = boot(nil, {
		modules = { Items, Inventory, Companions, Probe },
		servers = { CompanionProbe = {
			init = function(ctx: any)
				holder.ctx = ctx
			end,
		} },
	})
	return h, holder
end
describe("Companions authoritative equipment", function()
	it("rejects spoofed, malformed, duplicate, ineligible and full equipment", function()
		local h = boot({ autoEquipBest = false, slots = 1 })
		local p, q = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local a, b = inv.add(p, "pebble"), inv.add(q, "bird")
		local stone = inv.add(p, "stone")
		for _, uid in { "", string.rep("x", 65), 1, {} } :: { any } do
			local ok, why = api.equip(p, uid)
			expect(ok).toBe(false)
			expect(why).toBe("invalid_uid")
		end
		expect(select(2, api.equip(p, b.uid))).toBe("not_owned")
		expect(select(2, api.equip(p, stone.uid))).toBe("not_companion")
		expect(api.equip(p, a.uid)).toBe(true)
		expect(select(2, api.equip(p, a.uid))).toBe("already_equipped")
		local other = inv.add(p, "bird")
		expect(select(2, api.equip(p, other.uid))).toBe("slots_full")
		expect(api.bonus(p)).toBe(3)
		expect(table.isfrozen(api.equipped(p)[1])).toBe(true)
	end)
	it("preserves a manually empty set across additions and rejoin", function()
		local h = boot({ autoEquipBest = true })
		local p = h:addPlayer({ userId = 3 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local copy = inv.add(p, "pebble")
		expect(api.equipped(p)[1].uid).toBe(copy.uid)
		expect(api.unequip(p, copy.uid)).toBe(true)
		inv.add(p, "bird")
		expect(#api.equipped(p)).toBe(0)
		h:rejoin(p)
		expect(#api.equipped(p)).toBe(0)
		expect(api.equipBest(p)).toBe(true)
		expect(#api.equipped(p)).toBe(2)
	end)
	it("ranks rarity before score and uses custom score then uid", function()
		local h, holder = extensionHarness()
		local p = h:addPlayer({ userId = 4 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local a, b = inv.add(p, "pebble"), inv.add(p, "bird")
		holder.ctx.depsExt[Companions].scoreWith("custom", function(_player: any, copy: any)
			return if copy.uid == a.uid then 1000 else 0
		end)
		api.equipBest(p)
		expect(api.equipped(p)[1].uid).toBe(b.uid)
		expect(api.equipped(p)[2].uid).toBe(a.uid)
	end)
	it("refresh synchronously removes newly reserved copies and fails closed", function()
		local h, holder = extensionHarness()
		local p = h:addPlayer({ userId = 5 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local copy = inv.add(p, "pebble")
		local reserved = false
		local conn = holder.ctx.depsExt[Companions].canEquipWith("trade", function()
			return not reserved
		end)
		api.equip(p, copy.uid)
		reserved = true
		expect(api.bonus(p)).toBe(1)
		expect(api.refresh(p)).toBe(true)
		expect(#api.equipped(p)).toBe(0)
		expect(select(2, api.equip(p, copy.uid))).toBe("locked")
		conn:Disconnect()
		expect(api.equip(p, copy.uid)).toBe(true)
		holder.ctx.depsExt[Companions].canEquipWith("broken", function()
			error("predicate failure")
		end)
		expect(#api.equipped(p)).toBe(0)
	end)
	it("clears equipment within the inventory removal transaction and on transfer", function()
		local captured: any
		local live = require(game:GetService("ServerScriptService").Modules.Companions).new()
		local initialize = live.init
		live.init = function(ctx: any)
			captured = ctx
			initialize(ctx)
		end
		local holder: any = {}
		local Probe = StudWork.defineModule({
			name = "AtomicProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Companions, Inventory },
		})
		local h = boot(nil, {
			modules = { Items, Inventory, Companions, Probe },
			servers = {
				Companions = live,
				AtomicProbe = {
					init = function(ctx: any)
						holder.ctx = ctx
					end,
				},
			},
		})
		local p, q = h:addPlayer({ userId = 6 }), h:addPlayer({ userId = 7 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local copy = inv.add(p, "pebble")
		api.equip(p, copy.uid)
		local sawClean = false
		holder.ctx.depsExt[Inventory].onItemRemoved(function(tx: any)
			sawClean = #captured.section(tx).equipped == 0
		end)
		expect(inv.transfer(p, q, copy.uid)).toBe(true)
		expect(sawClean).toBe(true)
		expect(#api.equipped(p)).toBe(0)
		expect(api.bonus(p)).toBe(1)
		expect(inv.get(q, copy.uid) ~= nil).toBe(true)
	end)
	it("auto equips starters exactly once and exposes immediate metadata-only roster", function()
		local h = boot({ autoEquipBest = true }, {
			config = {
				Companions = { autoEquipBest = true },
				Inventory = {
					starterItems = { "pebble", "bird" },
				},
			},
		})
		local p = h:addPlayer({ userId = 8 })
		expect(#h:use(Companions).equipped(p)).toBe(2)
		local state = h:state(p)
		expect(state ~= nil).toBe(true)
	end)
end)

describe("Companions replication and integration", function()
	it("includes every loaded owner, whitelists records, coalesces and skips no-op snapshots", function()
		local h = boot({ autoEquipBest = true })
		local players = {}
		for id = 1, 50 do
			local player = h:addPlayer({ userId = id })
			table.insert(players, player)
			h:use(Inventory).add(player, "pebble", { meta = { private = "hidden" } })
		end
		h:tick(0.25)
		local p = players[1]
		local roster = State.roster(h:state(p))
		local count = 0
		for _, owner in roster do
			count += 1
			expect(#owner.equipped).toBe(1)
			local copy: any = owner.equipped[1]
			expect(copy.meta).toBe(nil)
			expect(copy.source).toBe(nil)
			expect(copy.acquiredAt).toBe(nil)
			expect(copy.position).toBe(nil)
			local keys = 0
			for _ in copy do
				keys += 1
			end
			expect(keys).toBe(2)
		end
		expect(count).toBe(50)
		local before = h:state(p).modules.Companions.extra.roster
		expect(h:use(Companions).refresh(p)).toBe(true)
		h:tick(2)
		expect(h:state(p).modules.Companions.extra.roster == before).toBe(true)
		h:removePlayer(players[50])
		expect(State.roster(h:state(p))["50"]).toBe(nil)
		expect(h:console("companions debug")).toContain("owners=49")
	end)
	it("retains saved equipment while a flag is off and restores immediately", function()
		local h = boot(
			{ autoEquipBest = false, flag = "followers" },
			{ isStudio = true, flags = { followers = { default = true } } }
		)
		local p = h:addPlayer({ userId = 80 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local copy = inv.add(p, "pebble")
		api.equip(p, copy.uid)
		h:console("flags set followers false")
		expect(api.bonus(p)).toBe(1)
		expect(State.enabled(h:state(p))).toBe(false)
		expect((next(State.roster(h:state(p))))).toBe(nil)
		expect(select(2, api.equipBest(p))).toBe("disabled")
		expect(State.equipped(h:state(p))[1]).toBe(copy.uid)
		h:console("flags set followers true")
		expect(api.equipped(p)[1].uid).toBe(copy.uid)
		expect(State.roster(h:state(p))["80"].equipped[1].uid).toBe(copy.uid)
	end)
	it("invalidates the one Economy factor before refresh returns", function()
		local holder: any = {}
		local Probe = StudWork.defineModule({
			name = "RateProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Companions },
		})
		local h = boot(nil, {
			modules = { Items, Inventory, Economy, Companions, Probe },
			items = {
				{
					id = "pebble",
					name = "Pebble",
					economy = { incomePerSec = 1 },
					companions = { incomeBonus = 2 },
				},
			},
			config = { Companions = { autoEquipBest = false, incomeBonusEnabled = true } },
			servers = { RateProbe = {
				init = function(ctx: any)
					holder.ctx = ctx
				end,
			} },
		})
		local p = h:addPlayer({ userId = 81 })
		local api, inv, economy = h:use(Companions), h:use(Inventory), h:use(Economy)
		local copy = inv.add(p, "pebble")
		local reserved = false
		holder.ctx.depsExt[Companions].canEquipWith("reservation", function()
			return not reserved
		end)
		api.equip(p, copy.uid)
		local boosted = economy.getRate(p)
		reserved = true
		expect(api.refresh(p)).toBe(true)
		local plain = economy.getRate(p)
		expect(boosted).toBe(plain * 3)
	end)
	it("follows Inventory rebirth decisions without duplicating the keep policy", function()
		local h = boot(nil, {
			modules = { Items, Inventory, Economy, Rebirth, Companions },
			config = { Companions = { autoEquipBest = false }, Rebirth = { rebirth = { baseCost = 0 } } },
		})
		local p = h:addPlayer({ userId = 82 })
		local inv, api = h:use(Inventory), h:use(Companions)
		local copy = inv.add(p, "pebble")
		api.equip(p, copy.uid)
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		expect(inv.get(p, copy.uid)).toBe(nil)
		expect(#api.equipped(p)).toBe(0)
	end)
end)

describe("Companions transaction edge cases", function()
	it("sanitizes stale saves and keeps only the paid copy retained by Rebirth", function()
		local h = boot(nil, {
			modules = { Items, Inventory, Economy, Rebirth, Companions },
			config = { Companions = { autoEquipBest = false }, Rebirth = { rebirth = { baseCost = 0 } } },
		})
		local p = h:addPlayer({
			userId = 90,
			data = {
				_framework = {
					schemaVersion = 2,
					firstJoin = 1,
					lastSeen = 1,
					_owners = { inventory = "Inventory", companions = "Companions" },
				},
				_versions = { inventory = 1, companions = 1 },
				inventory = {
					inventory = {
						paid = { uid = "paid", itemId = "pebble", source = "paid:Fixed", acquiredAt = 0 },
						earned = { uid = "earned", itemId = "bird", acquiredAt = 0 },
					},
				},
				companions = { equipped = { "missing", "paid", "earned", "paid" }, manual = true },
			},
		})
		local api = h:use(Companions)
		expect(#api.equipped(p)).toBe(2)
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		expect(#api.equipped(p)).toBe(1)
		expect(api.equipped(p)[1].uid).toBe("paid")
		h:rejoin(p)
		expect(api.equipped(p)[1].uid).toBe("paid")
	end)
	it("mail escrow removes equipment atomically and never refills on removal", function()
		local Mail = require(RS.Modules.Mail.module)
		local h = boot({ autoEquipBest = true }, { modules = { Items, Mail, Inventory, Companions } })
		local p = h:addPlayer({ userId = 91 })
		local copy = h:use(Inventory).add(p, "pebble")
		expect(#h:use(Companions).equipped(p)).toBe(1)
		expect(h:use(Inventory).sendGift(p, 92, copy.uid)).toBe(true)
		expect(#h:use(Companions).equipped(p)).toBe(0)
	end)
	it("rejects yielding predicates and ignores nonfinite scores", function()
		local h, holder = extensionHarness()
		local p = h:addPlayer({ userId = 93 })
		local copy = h:use(Inventory).add(p, "pebble")
		local ext = holder.ctx.depsExt[Companions]
		ext.scoreWith("nonfinite", function()
			return 0 / 0
		end)
		expect(h:use(Companions).equipBest(p)).toBe(true)
		local conn = ext.canEquipWith("yield", function()
			coroutine.yield()
			return true
		end)
		expect(#h:use(Companions).equipped(p)).toBe(0)
		expect(select(2, h:use(Companions).equip(p, copy.uid))).toBe("locked")
		conn:Disconnect()
		expect(h:use(Companions).equip(p, copy.uid)).toBe(true)
	end)
	it("returns failed refresh before a reservation offer may activate", function()
		local captured: any
		local live = require(game:GetService("ServerScriptService").Modules.Companions).new()
		local initialize = live.init
		local fail = false
		live.init = function(ctx: any)
			local proxy = table.clone(ctx)
			proxy.tx = function(...: any)
				if fail then
					return false
				end
				return ctx.tx(...)
			end
			captured = proxy
			initialize(proxy)
		end
		local h = boot(nil, { servers = { Companions = live } })
		local p = h:addPlayer({ userId = 94 })
		local api = h:use(Companions)
		local copy = h:use(Inventory).add(p, "pebble")
		api.equip(p, copy.uid)
		fail = true
		local ok, reason = api.refresh(p)
		expect(ok).toBe(false)
		expect(reason).toBe("transaction_failed")
		expect(captured ~= nil).toBe(true)
		fail = false
		expect(api.refresh(p)).toBe(true)
	end)
end)

describe("Companions appearance bridge", function()
	it("delegates static and mutation looks and invalidates one Plot decorator", function()
		local Plot = require(RS.Modules.Plot.module)
		local registered, invalidations, decorate = 0, 0, nil :: any
		local h = boot(nil, {
			modules = { Items, Inventory, Plot, Companions },
			servers = {
				Plot = {
					extensions = {
						decorate = function(id: string, fn: any)
							expect(id).toBe("companions")
							registered += 1
							decorate = fn
							return {
								Invalidate = function()
									invalidations += 1
								end,
								Disconnect = function() end,
							}
						end,
					},
				},
			},
		})
		local api = h:use(Companions)
		local order = {}
		local conn = api.registerLook("static", function(model: any)
			table.insert(order, "static")
			model.Name = "Styled"
		end)
		api.registerLook("mutation", function()
			table.insert(order, "mutation")
		end)
		expect(registered).toBe(1)
		expect(invalidations).toBe(2)
		local model = { Name = "Primitive" } :: any
		decorate(model, { companions = { look = "static" } }, { mutation = "mutation" })
		expect(order).toEqual({ "static", "mutation" })
		expect(model.Name).toBe("Styled")
		conn:Disconnect()
		conn:Disconnect()
		expect(invalidations).toBe(3)
	end)
end)

describe("Companions semantic publication", function()
	it("publishes no roster or save writes on idle ticks and no roster on no-op refresh", function()
		local publications, transactions = 0, 0
		local live = require(game:GetService("ServerScriptService").Modules.Companions).new()
		local initialize = live.init
		live.init = function(ctx: any)
			local proxy = table.clone(ctx)
			proxy.replicate = table.clone(ctx.replicate)
			proxy.replicate.setAll = function(key: string, value: any)
				publications += 1
				ctx.replicate.setAll(key, value)
			end
			proxy.tx = function(...: any)
				transactions += 1
				return ctx.tx(...)
			end
			initialize(proxy)
		end
		local h = boot(nil, { servers = { Companions = live } })
		local p = h:addPlayer({ userId = 95 })
		local initial, writes = publications, transactions
		expect(initial).toBe(1)
		h:tick(10)
		expect(publications).toBe(initial)
		expect(transactions).toBe(writes)
		expect(h:use(Companions).refresh(p)).toBe(true)
		h:tick(1)
		expect(publications).toBe(initial)
		local copy = h:use(Inventory).add(p, "pebble")
		h:use(Companions).equip(p, copy.uid)
		expect(publications).toBe(initial)
		h:tick(0.25)
		expect(publications).toBe(initial + 1)
	end)
end)
