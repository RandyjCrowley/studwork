local State = require(script.Parent.State)

local cfg = {
	daily = { count = 2, rerollsPerSlot = 2 },
	weekly = { count = 1, rerollsPerSlot = 0 },
	pinMax = 2,
	quests = {
		d1 = { kind = "daily", objectives = { { kind = "counter", key = "k", target = 5 } }, reward = {} },
		d2 = {
			kind = "daily",
			title = "game.title.d2",
			objectives = {
				{ kind = "counter", key = "k", target = 2, label = "game.obj" },
				{ kind = "ack", key = "tour" },
			},
			reward = { { kind = "roll", table = "Crate" } },
		},
		w1 = { kind = "weekly", objectives = { { kind = "counter", key = "w", target = 10 } }, reward = {} },
		s1 = { kind = "chain", objectives = { { kind = "counter", key = "s", target = 1 } }, reward = {} },
		s2 = { kind = "chain", objectives = { { kind = "counter", key = "s", target = 1 } }, reward = {} },
		rep = {
			kind = "repeatable",
			cap = 3,
			objectives = { { kind = "counter", key = "r", target = 1 } },
			reward = {},
		},
		ev = { kind = "event", objectives = { { kind = "counter", key = "e", target = 1 } }, reward = {} },
	},
}

-- extra.progIds / extra.prog as the server sends them: sorted ids, "values;values"
local function wire(map)
	local ids = {}
	for id in map or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	local parts = {}
	for i, id in ids do
		parts[i] = table.concat(map[id], ",")
	end
	return ids, table.concat(parts, ";")
end

local function stateWith(board, prog, odds)
	local ids, text = wire(prog)
	return {
		loaded = true,
		modules = {
			Quests = { extra = { board = board, progIds = ids, prog = text, questOdds = odds or {} } },
		},
	}
end

local function board()
	return {
		day = { id = 100, endsAt = 9000, slots = { { q = "d1", s = 0, r = 1 }, { q = "d2", s = 1, r = 0 } } },
		week = { id = 98, endsAt = 50000, slots = { { q = "w1", s = 0, r = 0 } } },
		list = {
			{ q = "s1", s = 2 },
			{ q = "s2", s = 0 },
			{ q = "rep", s = 0, k = 1, cap = 3, p = 100 },
			{ q = "gone", s = 0 },
		},
		waiting = { { q = "d1", k = "daily", p = 99 } },
		pins = { "s2", "d1", "d2" },
	}
end

describe("Quests client State: views", function()
	local views = State.views(stateWith(board(), { d1 = { 3 }, s2 = { 0 }, w1 = { 99999 } }), cfg)

	it("builds the views in board order and skips ids the config doesn't have", function()
		local ids = {}
		for _, v in views do
			table.insert(ids, v.id .. (if v.waiting then "*" else ""))
		end
		expect(ids).toEqual({ "d1", "d2", "w1", "s1", "s2", "rep", "d1*" })
	end)

	it("maps status, slot, period and the free rerolls left", function()
		expect(views[1].status).toBe("active")
		expect(views[1].slot).toBe(1)
		expect(views[1].kind).toBe("daily")
		expect(views[1].periodId).toBe(100)
		expect(views[1].endsAt).toBe(9000)
		expect(views[1].rerollsLeft).toBe(1) -- 2 per slot, 1 used
		expect(views[2].status).toBe("complete")
		expect(views[2].rerollsLeft).toBe(2)
		expect(views[3].rerollsLeft).toBe(0) -- weekly: 0 per slot
		expect(views[4].status).toBe("claimed")
	end)

	it("reads live objective values from extra.prog, clamped to the target", function()
		expect(views[1].objectives[1].value).toBe(3)
		expect(views[1].objectives[1].target).toBe(5)
		expect(views[3].objectives[1].value).toBe(10)
		expect(views[5].objectives[1].value).toBe(0)
	end)

	it("a complete or claimed quest shows every objective full", function()
		expect(views[2].objectives[1].value).toBe(2)
		expect(views[4].objectives[1].value).toBe(1)
	end)

	it("keeps title keys, objective labels and the config rewards", function()
		expect(views[1].title).toBe("Quests.quest.d1")
		expect(views[2].title).toBe("game.title.d2")
		expect(views[2].objectives[1].label).toBe("game.obj")
		expect(views[2].reward[1].table).toBe("Crate")
	end)

	it("reads repeatable claims and cap, and waiting entries as complete and unpinned", function()
		expect(views[6].claims).toBe(1)
		expect(views[6].cap).toBe(3)
		local w = views[7]
		expect(w.waiting).toBe(true)
		expect(w.status).toBe("complete")
		expect(w.kind).toBe("daily")
		expect(w.pinned).toBe(false)
		expect(w.objectives[1].value).toBe(5)
	end)

	it("marks pinned quests", function()
		expect(views[1].pinned).toBe(true)
		expect(views[5].pinned).toBe(true)
		expect(views[3].pinned).toBe(false)
	end)

	it("takes an event quest's end time from the framework's active events", function()
		local b = board()
		b.list = { { q = "ev", s = 0 } }
		b.waiting = {}
		local st = stateWith(b)
		st.framework = { activeEvents = { evt = 777 } }
		local c = table.clone(cfg)
		c.quests = table.clone(cfg.quests)
		c.quests.ev = { kind = "event", event = "evt", objectives = cfg.quests.ev.objectives, reward = {} }
		local v = State.views(st, c)
		local ev = v[#v]
		expect(ev.id).toBe("ev")
		expect(ev.endsAt).toBe(777)
		expect(State.tabEndsAt(v, "event")).toBe(777)
		st.framework = nil
		v = State.views(st, c)
		expect(v[#v].endsAt).toBe(nil)
	end)

	it("caps the free rerolls at the server's maximum of 3", function()
		local c = table.clone(cfg)
		c.daily = { count = 2, rerollsPerSlot = 9 }
		expect(State.views(stateWith(board()), c)[1].rerollsLeft).toBe(2) -- 3 - 1 used
	end)

	it("keeps a waiting entry of kind event", function()
		local b = board()
		b.waiting = { { q = "ev", k = "event", p = 123 } }
		local v = State.views(stateWith(b), cfg)
		expect(v[#v].kind).toBe("event")
		expect(v[#v].waiting).toBe(true)
	end)

	it("an empty, unloaded or module-less state gives no views", function()
		for _, s in { {}, { loaded = false }, { modules = {} }, { modules = { Quests = {} } }, "x" } do
			expect(State.views(s, cfg)).toEqual({})
			expect(State.board(s)).toBe(nil)
			expect(State.prog(s)).toEqual({})
			expect(State.odds(s)).toEqual({})
		end
		expect(State.views(stateWith(board()), nil)).toEqual({})
	end)

	it("decodes extra.progIds + extra.prog; a malformed pair reads as far as it can be placed", function()
		local function progOf(ids, text)
			return State.prog({
				loaded = true,
				modules = { Quests = { extra = { progIds = ids, prog = text } } },
			})
		end
		expect(progOf({ "a", "b" }, "1,2;3")).toEqual({ a = { 1, 2 }, b = { 3 } })
		expect(progOf({ "a" }, "1e+15")).toEqual({ a = { 1e15 } })
		expect(progOf({}, "")).toEqual({}) -- the flag-off value
		expect(progOf(nil, "1")).toEqual({}) -- not sent yet
		expect(progOf({ "a" }, { 1 })).toEqual({})
		expect(progOf({ "a", 7, "c" }, "4;5;6")).toEqual({ a = { 4 } })
		expect(progOf({ "a", "b" }, "4")).toEqual({ a = { 4 } })
		expect(progOf({ "a" }, "4,x")).toEqual({ a = { 4, 0 } })
		expect(progOf({ "a" }, "1,2,3,4,5")).toEqual({ a = { 1, 2, 3, 4 } })
	end)

	it("an unknown list status reads as locked", function()
		local b = board()
		b.list = { { q = "s1", s = 3 } }
		expect(State.views(stateWith(b), cfg)[4].status).toBe("locked")
	end)
end)

describe("Quests client State: tabs", function()
	local views = State.views(stateWith(board()), cfg)

	it("always lists daily, weekly and story; event and waiting only when present", function()
		expect(State.tabsOf({})).toEqual({ "daily", "weekly", "chain" })
		expect(State.tabsOf(views)).toEqual({ "daily", "weekly", "chain", "waiting" })
		local b = board()
		b.waiting = {}
		b.list = { { q = "ev", s = 0 } }
		expect(State.tabsOf(State.views(stateWith(b), cfg))).toEqual({ "daily", "weekly", "chain", "event" })
	end)

	it("sorts quests into tabs: oneTime and repeatable in story, event apart, waiting apart", function()
		expect(#State.inTab(views, "daily")).toBe(2)
		expect(#State.inTab(views, "weekly")).toBe(1)
		local story = State.inTab(views, "chain")
		expect(#story).toBe(3)
		expect(story[3].id).toBe("rep")
		expect(#State.inTab(views, "waiting")).toBe(1)
		expect(#State.inTab(views, "event")).toBe(0)
	end)

	it("counts what is claimable and finds the first", function()
		expect(State.claimable(views)).toBe(2) -- d2 and the waiting d1
		expect(State.firstClaimable(views)).toBe(2)
		expect(State.firstClaimable({})).toBe(nil)
	end)

	it("a tab's reset time is the earliest endsAt of its slots", function()
		expect(State.tabEndsAt(views, "daily")).toBe(9000)
		expect(State.tabEndsAt(views, "weekly")).toBe(50000)
		expect(State.tabEndsAt(views, "chain")).toBe(nil)
	end)

	it("pinned: in view order, unfinished, at most pinMax", function()
		local pinned = State.pinned(views, 2)
		expect(#pinned).toBe(2)
		expect(pinned[1].id).toBe("d1")
		expect(pinned[2].id).toBe("d2")
		expect(#State.pinned(views, 0)).toBe(0)
		expect(#State.pinned(views, nil)).toBe(3)
		for _, v in pinned do
			expect(v.waiting).toBe(nil)
		end
	end)
end)

describe("Quests client State: resets-in", function()
	it("counts seconds left, never negative", function()
		expect(State.resetsIn(1000, 400)).toBe(600)
		expect(State.resetsIn(1000, 2000)).toBe(0)
		expect(State.resetsIn(nil, 5)).toBe(0)
	end)

	it("formats h:mm, rounding a started minute up", function()
		expect(State.duration(0)).toBe("0:00")
		expect(State.duration(1)).toBe("0:01")
		expect(State.duration(3600)).toBe("1:00")
		expect(State.duration(3661)).toBe("1:02")
		expect(State.duration(86399)).toBe("24:00")
		expect(State.duration(7 * 86400)).toBe("168:00")
		expect(State.duration(-4)).toBe("0:00")
	end)

	it('the reset line shows days and hours from 24 h on ("2d 16h"), h:mm below', function()
		local key, args = State.resetsLine(3600 + 61)
		expect(key).toBe("Quests.resetsIn")
		expect(args.time).toBe("1:02")
		key, args = State.resetsLine(64 * 3600 + 43 * 60) -- was shown as "64:43"
		expect(key).toBe("Quests.resetsInDays")
		expect(args.days).toBe(2)
		expect(args.hours).toBe(17) -- 16 h 43 min left: a started hour counts
		key, args = State.resetsLine(7 * 86400)
		expect(key).toBe("Quests.resetsInDays")
		expect(args.days).toBe(7)
		expect(args.hours).toBe(0)
		key, args = State.resetsLine(86399)
		expect(key).toBe("Quests.resetsInDays")
		expect(args.days).toBe(1)
		expect(args.hours).toBe(0)
		key = State.resetsLine(-4)
		expect(key).toBe("Quests.resetsIn")
	end)

	it("an item reward shows the catalog's display name (GameConfig.items is a list of defs)", function()
		local list = { { id = "gem", name = "Gem" }, { id = "star", name = "Star" } }
		local _, args = State.rewardLine({ kind = "item", item = "star" }, { items = list })
		expect(args.item).toBe("Star")
		_, args = State.rewardLine({ kind = "item", item = "star", count = 2 }, { items = list })
		expect(args.item).toBe("Star x2")
		_, args = State.rewardLine({ kind = "item", item = "nope" }, { items = list })
		expect(args.item).toBe("nope")
		expect(State.itemName(nil, "star")).toBe("star")
		expect(State.itemName({ star = { name = "Star" } }, "star")).toBe("Star")
	end)
end)

describe("Quests client State: transitions", function()
	local function snap(b, prog)
		return State.snapshot(State.views(stateWith(b, prog), cfg))
	end

	it("fires nothing for the first state after joining", function()
		local c, k = State.transitions(nil, snap(board()))
		expect(c).toEqual({})
		expect(k).toEqual({})
	end)

	it("fires completed when a quest's status turns complete", function()
		local before = snap(board())
		local b = board()
		b.day.slots[1].s = 1
		local c, k = State.transitions(before, snap(b))
		expect(c).toEqual({ "d1" })
		expect(k).toEqual({})
	end)

	it(
		"does not fire completed again for an already complete quest, or for one that appears complete",
		function()
			local before = snap(board())
			local c = State.transitions(before, snap(board()))
			expect(c).toEqual({})
			local b = board()
			b.list[2].s = 1 -- s2 was active: completes
			b.day.slots[2].s = 1
			local c2 = State.transitions(before, snap(b))
			expect(c2).toEqual({ "s2" })
			local fresh = board()
			fresh.list = {}
			local c3 = State.transitions(snap(fresh), snap(board()))
			expect(c3).toEqual({})
		end
	)

	it("fires claimed when a quest turns claimed or a repeatable's claims go up", function()
		local before = snap(board())
		local b = board()
		b.day.slots[2].s = 2
		b.list[3].k = 2
		local c, k = State.transitions(before, snap(b))
		expect(c).toEqual({})
		expect(k).toEqual({ "d2", "rep" })
	end)

	it("a waiting entry that leaves the list counts as claimed", function()
		local before = snap(board())
		local b = board()
		b.waiting = {}
		local _, k = State.transitions(before, snap(b))
		expect(k).toEqual({ "d1" })
	end)

	it("a reset that moves a complete slot to waiting fires neither", function()
		local before = snap(board())
		local b = board()
		b.day.slots = { { q = "d1", s = 0, r = 0 } }
		b.waiting = { { q = "d1", k = "daily", p = 99 }, { q = "d2", k = "daily", p = 100 } }
		local c, k = State.transitions(before, snap(b))
		expect(c).toEqual({})
		expect(k).toEqual({})
	end)
end)

describe("Quests client State: lines", function()
	it("objective lines: a label key wins, else by kind with the config key or source", function()
		local key, args =
			State.objectiveLine({ kind = "counter", key = "crates", target = 3, label = "game.crates" })
		expect(key).toBe("game.crates")
		expect(args).toEqual({})
		key, args = State.objectiveLine({ kind = "counter", key = "crates", target = 3 })
		expect(key).toBe("Quests.objective.counter")
		expect(args.key).toBe("crates")
		key, args = State.objectiveLine({ kind = "source", source = "itemCollected", target = 3 })
		expect(key).toBe("Quests.objective.source")
		expect(args.source).toBe("itemCollected")
		key, args = State.objectiveLine({ kind = "threshold", source = "rebirths", target = 2 })
		expect(key).toBe("Quests.objective.threshold")
		expect(args.target).toBe(2)
		expect(args.source).toBe("rebirths")
		key, args = State.objectiveLine({ kind = "ack", key = "tour" })
		expect(key).toBe("Quests.objective.ack")
		expect(args.key).toBe("tour")
	end)

	it("reward lines by kind, with the primary currency and the item's name", function()
		local ctx = { items = { gem = { name = "Gem" } }, primaryCurrency = "Coins" }
		local key, args = State.rewardLine({ kind = "currency", amount = 50 }, ctx)
		expect(key).toBe("Quests.reward.currency")
		expect(args.amount).toBe(50)
		expect(args.currency).toBe("Coins")
		_, args = State.rewardLine({ kind = "currency", amount = 5, currency = "Gems" }, ctx)
		expect(args.currency).toBe("Gems")
		key, args = State.rewardLine({ kind = "item", item = "gem", count = 3 }, ctx)
		expect(key).toBe("Quests.reward.item")
		expect(args.item).toBe("Gem x3")
		_, args = State.rewardLine({ kind = "item", item = "unknown" }, ctx)
		expect(args.item).toBe("unknown")
		key, args = State.rewardLine({ kind = "roll", table = "Crate" })
		expect(key).toBe("Quests.reward.roll")
		expect(args.table).toBe("Crate")
		key = State.rewardLine({ kind = "custom", handler = "x" })
		expect(key).toBe("Quests.reward.custom")
	end)
end)

describe("Quests client State: helpers", function()
	it("tabOf, titleKey and progressOf", function()
		local views = State.views(stateWith(board(), { d1 = { 3 } }), cfg)
		expect(State.tabOf(views[1])).toBe("daily")
		expect(State.tabOf(views[5])).toBe("chain")
		expect(State.tabOf(views[7])).toBe("waiting")
		expect(State.titleKey(cfg, "d1")).toBe("Quests.quest.d1")
		expect(State.titleKey(cfg, "d2")).toBe("game.title.d2")
		local v, t, r = State.progressOf(views[1])
		expect(v).toBe(3)
		expect(t).toBe(5)
		expect(r).toBe(0.6)
		v, t, r = State.progressOf(views[2]) -- complete: full
		expect(v).toBe(t)
		expect(r).toBe(1)
	end)
end)
