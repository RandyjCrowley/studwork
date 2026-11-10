--!nocheck
-- Extensions (§8) both directions, incl. the inverted pattern (H3), and txApi (§5.1).
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)

local def = StudWork.defineModule

-- "Collection": owns items, offers onItemRemoved (inverted: dependents hook their own cleanup).
local Collection = def({
	name = "Collection",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "collection", version = 1, default = { items = {} } },
})
-- "Rebirth": offers resetStep (natural direction: dependents add steps to Rebirth's tx).
local Rebirth = def({
	name = "Rebirth",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "rebirth", version = 1, default = { count = 0, coins = 0 } },
})
-- "Plot": optional on both; owns its own unrelated section.
local Plot = def({
	name = "Plot",
	version = "1.0.0",
	framework = "^1.3.0",
	optional = { Collection, Rebirth },
	data = { key = "plot", version = 1, default = { displayed = {}, resets = 0 } },
})
-- "Quests": hard dep on Rebirth's txApi.
local Quests = def({
	name = "Quests",
	version = "1.0.0",
	framework = "^1.3.0",
	dependsOn = { Rebirth },
	data = { key = "quests", version = 1, default = { done = 0 } },
})

local function servers()
	local cctx, rctx, pctx, qctx
	local removed = StudWork.hook()
	local steps = StudWork.hook()
	local s = {}
	s.Collection = {
		init = function(ctx)
			cctx = ctx
		end,
		api = {
			add = function(player, uid)
				return cctx.data.update(player, function(sec)
					sec.items[uid] = true
				end)
			end,
			remove = function(player, uid)
				return cctx.tx(player, function(tx)
					local sec = cctx.section(tx)
					sec.items[uid] = nil
					removed.fire(tx, player, { uid = uid }) -- hooks run inside Collection's tx
				end)
			end,
		},
		extensions = { onItemRemoved = removed.register },
	}
	s.Rebirth = {
		init = function(ctx)
			rctx = ctx
		end,
		api = {
			rebirth = function(player)
				return rctx.tx(player, function(tx)
					local sec = rctx.section(tx)
					sec.count += 1
					sec.coins = 0
					steps.fire(tx, player)
				end)
			end,
		},
		txApi = {
			grant = function(tx, amount)
				rctx.section(tx).coins += amount
				return true
			end,
		},
		extensions = {
			resetStep = function(_id, fn)
				steps.register(fn)
			end,
		},
	}
	s.Plot = {
		init = function(ctx)
			pctx = ctx
			if ctx.isEnabled(Collection) then
				ctx.depsExt[Collection].onItemRemoved(function(tx, _player, instance)
					local mine = ctx.section(tx) -- Plot's OWN section, inside Collection's tx
					for slot, uid in mine.displayed do
						if uid == instance.uid then
							mine.displayed[slot] = nil
						end
					end
				end)
			end
			if ctx.isEnabled(Rebirth) then
				ctx.depsExt[Rebirth].resetStep("plot", function(tx)
					local mine = ctx.section(tx)
					mine.displayed = {}
					mine.resets += 1
				end)
			end
		end,
		api = {
			display = function(player, slot, uid)
				return pctx.data.update(player, function(sec)
					sec.displayed[slot] = uid
				end)
			end,
		},
	}
	s.Quests = {
		init = function(ctx)
			qctx = ctx
		end,
		api = {
			complete = function(player, fail)
				return qctx.tx(player, function(tx)
					qctx.depsTx[Rebirth].grant(tx, 100)
					qctx.section(tx).done += 1
					if fail then
						error("quest failed")
					end
				end)
			end,
			grantOutside = function()
				return qctx.depsTx[Rebirth].grant({}, 1)
			end,
		},
	}
	return s
end

describe("inverted extension (H3): hook fires in the owner's tx, writes the hooker's own section", function()
	it("removing an item clears the Plot slot and touches nothing else", function()
		local h = Harness.new({ modules = { Collection, Rebirth, Plot }, servers = servers() })
		local p = h:addPlayer({ userId = 1 })
		h:use(Collection).add(p, "u1")
		h:use(Collection).add(p, "u2")
		h:use(Plot).display(p, "s1", "u1")
		h:use(Plot).display(p, "s2", "u2")
		h:removePlayer(p)
		local before = h:saved(p)
		h:addPlayer({ userId = 1 })

		expect(h:use(Collection).remove(p, "u1")).toBe(true)
		h:removePlayer(p)
		local after = h:saved(p)

		expect(after.collection.items.u1).toBeNil()
		expect(after.collection.items.u2).toBe(true)
		expect(after.plot.displayed.s1).toBeNil() -- the hook's side effect, in Plot's section
		expect(after.plot.displayed.s2).toBe("u2")
		expect(after.plot.resets).toBe(0)
		expect(after.rebirth).toEqual(before.rebirth) -- unrelated section unchanged
	end)

	it("a failing hook rolls back the owner's change too (one transaction)", function()
		local s = servers()
		local origInit = s.Plot.init
		s.Plot.init = function(ctx)
			origInit(ctx)
			ctx.depsExt[Collection].onItemRemoved(function()
				error("hook broke")
			end)
		end
		local h = Harness.new({ modules = { Collection, Plot }, servers = s })
		local p = h:addPlayer({ userId = 2 })
		h:use(Collection).add(p, "u1")
		h:use(Plot).display(p, "s1", "u1")
		expect(function()
			h:use(Collection).remove(p, "u1")
		end).toThrow("hook broke")
		h:removePlayer(p)
		expect(h:saved(p).collection.items.u1).toBe(true)
		expect(h:saved(p).plot.displayed.s1).toBe("u1")
	end)

	it("with Collection disabled, Plot boots and works without the hook", function()
		local h = Harness.new({ modules = { Plot }, servers = servers() })
		local p = h:addPlayer({ userId = 3 })
		expect(h:use(Plot).display(p, "s1", "x")).toBe(true)
	end)
end)

describe("natural-direction extension: Rebirth.resetStep", function()
	it("each reset step writes only its own section inside Rebirth's tx", function()
		local h = Harness.new({ modules = { Collection, Rebirth, Plot }, servers = servers() })
		local p = h:addPlayer({ userId = 4 })
		h:use(Plot).display(p, "s1", "u9")
		h:use(Collection).add(p, "u9")
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.rebirth.count).toBe(1)
		expect(saved.plot.resets).toBe(1)
		expect(next(saved.plot.displayed)).toBeNil()
		expect(saved.collection.items.u9).toBe(true)
	end)
end)

describe("txApi (§5.1)", function()
	it("combines another module's tx operation with your own section atomically", function()
		local h = Harness.new({ modules = { Rebirth, Quests }, servers = servers() })
		local p = h:addPlayer({ userId = 5 })
		expect(h:use(Quests).complete(p)).toBe(true)
		expect(function()
			h:use(Quests).complete(p, true)
		end).toThrow("quest failed")
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.rebirth.coins).toBe(100)
		expect(saved.quests.done).toBe(1)
	end)

	it("txApi refuses anything but an open tx", function()
		local h = Harness.new({ modules = { Rebirth, Quests }, servers = servers() })
		expect(function()
			h:use(Quests).grantOutside()
		end).toThrow("first argument must be the open tx")
	end)
end)
