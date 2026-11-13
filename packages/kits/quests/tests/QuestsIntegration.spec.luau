--!nocheck
--[[
	Quests server -> client integration: the REAL server part runs in the harness, and the player's
	replicated state (h:state(p), what the client receives) goes through the client's State readers
	(Quests/client/State.luau) and the client part's watcher. Nothing here is hand-built wire data.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local Kit = require("packages/kits/quests/tests/QuestsClientKit.luau")
local State = require("packages/kits/quests/Quests/client/State.luau")
local F = K.F

local function cfg()
	return F.questsConfig({ chains = { story = { "s1", "s2", "s3" } } })
end

local function viewOf(views, id, waiting)
	for _, v in views do
		if v.id == id and (v.waiting == true) == (waiting == true) then
			return v
		end
	end
	return nil
end

local function ids(views)
	local out = {}
	for _, v in views do
		table.insert(out, v.id)
	end
	return out
end

local fs
afterEach(function()
	if fs then
		fs:stop()
		fs = nil
	end
end)

describe("Quests client readers on the real replicated state", function()
	it("builds the same list the server's active() reports, in board order", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		h:tick(1)
		local views = State.views(h:state(p), config)
		local server = q.active(p)
		expect(ids(views)).toEqual(ids(server))
		for i, v in views do
			expect(v.kind).toBe(server[i].kind)
			expect(v.status).toBe(server[i].status)
			expect(v.slot).toBe(server[i].slot)
			expect(v.periodId).toBe(server[i].periodId)
			expect(v.rerollsLeft).toBe(server[i].rerollsLeft)
			expect(v.pinned).toBe(server[i].pinned)
		end
		expect(#State.inTab(views, "daily")).toBe(3)
		expect(#State.inTab(views, "weekly")).toBe(2)
		expect(State.tabsOf(views)).toEqual({ "daily", "weekly", "chain" })
		local day = h:state(p).modules.Quests.extra.board.day
		expect(State.tabEndsAt(views, "daily")).toBe(day.endsAt)
	end)

	it("reads progress, completion and claim as the server reports them", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local id, key, target = K.slotQuest(q, p, "daily", 1)
		q.progress(p, key, target - 1)
		h:tick(2) -- past replicateSeconds
		local v = viewOf(State.views(h:state(p), config), id)
		expect(v.status).toBe("active")
		expect(v.objectives[1].value).toBe(target - 1)
		expect(v.objectives[1].target).toBe(target)
		expect(State.claimable(State.views(h:state(p), config))).toBe(0)

		q.progress(p, key, 1)
		h:tick(2)
		local views = State.views(h:state(p), config)
		expect(viewOf(views, id).status).toBe("complete")
		expect(State.claimable(views)).toBe(1)
		expect(views[State.firstClaimable(views)].id).toBe(id)

		expect(q.claim(p, id)).toBe(true)
		h:tick(2)
		views = State.views(h:state(p), config)
		expect(viewOf(views, id).status).toBe("claimed")
		expect(State.claimable(views)).toBe(0)
	end)

	it("follows rerolls (count left and the new quest) and pins (order, limit)", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local before = State.views(h:state(p), config)
		expect(viewOf(before, K.ids(q, p, "daily")[1]).rerollsLeft).toBe(1)
		local ok, newId = q.reroll(p, "daily", 1)
		expect(ok).toBe(true)
		h:tick(1)
		local views = State.views(h:state(p), config)
		local first = State.inTab(views, "daily")[1]
		expect(first.id).toBe(newId)
		expect(first.rerollsLeft).toBe(0)
		expect(State.inTab(views, "daily")[2].rerollsLeft).toBe(1)
		expect(State.inTab(views, "weekly")[1].rerollsLeft).toBe(0)

		expect(q.pin(p, "s1", true)).toBe(true)
		expect(q.pin(p, newId, true)).toBe(true)
		h:tick(1)
		views = State.views(h:state(p), config)
		expect(viewOf(views, "s1").pinned).toBe(true)
		expect(ids(State.pinned(views, 3))).toEqual({ newId, "s1" }) -- board order: daily slots first
		-- the tracker's order is the board's order; a smaller pinMax cuts from the end
		expect(#State.pinned(views, 1)).toBe(1)
		q.pin(p, "s1", false)
		h:tick(1)
		expect(viewOf(State.views(h:state(p), config), "s1").pinned).toBe(false)
	end)

	it("reads a chain step, a repeatable's claims and cap, and a capped repeatable as claimed", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local views = State.views(h:state(p), config)
		expect(viewOf(views, "s1").kind).toBe("chain")
		expect(viewOf(views, "s2")).toBe(nil) -- a later step isn't on the board yet
		expect(viewOf(views, "rep").cap).toBe(2)
		expect(viewOf(views, "rep").claims).toBe(0)

		q.progress(p, "talk", 1)
		expect(q.claim(p, "s1")).toBe(true)
		h:tick(1)
		views = State.views(h:state(p), config)
		expect(viewOf(views, "s1")).toBe(nil)
		expect(viewOf(views, "s2").status).toBe("active")

		q.progress(p, "coin", 5)
		expect(q.claim(p, "rep")).toBe(true)
		h:tick(1)
		local rep = viewOf(State.views(h:state(p), config), "rep")
		expect(rep.claims).toBe(1)
		expect(rep.status).toBe("active")
		q.progress(p, "coin", 5)
		expect(q.claim(p, "rep")).toBe(true)
		h:tick(1)
		rep = viewOf(State.views(h:state(p), config), "rep")
		expect(rep.claims).toBe(2)
		expect(rep.status).toBe("claimed")
	end)

	it("reads an event quest with the framework's event end time", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		expect(viewOf(State.views(h:state(p), config), "ev")).toBe(nil)
		h:console("events", "event", "testEvent")
		h:tick(1)
		local state = h:state(p)
		local ev = viewOf(State.views(state, config), "ev")
		expect(ev ~= nil).toBe(true)
		expect(ev.status).toBe("active")
		expect(State.tabsOf(State.views(state, config))).toEqual({ "daily", "weekly", "chain", "event" })
		local endsAt = state.framework.activeEvents.testEvent
		expect(type(endsAt)).toBe("number")
		expect(ev.endsAt).toBe(endsAt)
		expect(State.tabEndsAt(State.views(state, config), "event")).toBe(endsAt)
		q.progress(p, "coin", 5)
		h:tick(1)
		expect(viewOf(State.views(h:state(p), config), "ev").status).toBe("complete")
	end)

	it("reads waiting rewards after a reset, claimable from the waiting tab", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local id, key, target = K.slotQuest(q, p, "daily", 1)
		q.progress(p, key, target)
		h:tick(2)
		local day = h:state(p).modules.Quests.extra.board.day
		h.clock = day.endsAt + 1
		h:tick(5)
		local state = h:state(p)
		local views = State.views(state, config)
		local w = viewOf(views, id, true)
		expect(w ~= nil).toBe(true)
		expect(w.status).toBe("complete")
		expect(w.kind).toBe("daily")
		expect(w.periodId).toBe(day.id)
		expect(State.tabsOf(views)[#State.tabsOf(views)]).toBe("waiting")
		expect(#State.inTab(views, "waiting")).toBe(1)
		expect(w.pinned).toBe(false)
		local nextDay = state.modules.Quests.extra.board.day
		expect(nextDay.id > day.id).toBe(true)
		expect(State.tabEndsAt(views, "daily")).toBe(nextDay.endsAt)
		expect(State.resetsIn(nextDay.endsAt, h.clock)).toBe(math.ceil(nextDay.endsAt - h.clock))
		expect(q.claim(p, id)).toBe(true)
		h:tick(1)
		expect(viewOf(State.views(h:state(p), config), id, true)).toBe(nil)
	end)

	it("reads the odds the server discloses for roll rewards", function()
		local config = cfg()
		config.quests.d1.reward = { F.roll("FreeCrate") }
		local h, p = K.boot({
			quests = config,
			modules = { K.ref("Items"), K.ref("Inventory"), K.ref("Rarity") },
			config = { Rarity = F.rarity() },
			items = F.items(),
		})
		local odds = State.odds(h:state(p))
		expect(odds.FreeCrate ~= nil).toBe(true)
		expect(odds.FreeCrate).toEqual(h:state(p).modules.Quests.extra.questOdds.FreeCrate)
		expect((State.rewardLine(config.quests.d1.reward[1]))).toBe("Quests.reward.roll")
	end)

	it("reads empty tables while the flag is off", function()
		local config = cfg()
		config.flag = "quests_off"
		local h, p = K.boot({ quests = config, flags = { quests_off = { default = false } } })
		expect(State.views(h:state(p), config)).toEqual({})
	end)
end)

describe("Quests client part watcher on the real replicated state", function()
	it("fires onCompleted once and onClaimed once, never for the first state", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local id, key, target = K.slotQuest(q, p, "daily", 1)
		q.progress(p, key, target - 1)
		h:tick(2)
		fs = Kit.new({})
		fs.state = h:state(p)
		fs:start({ config = { Quests = config } })
		local api = StudWork.use(F.Quests)
		local completed, claimed = {}, {}
		api.onCompleted(function(qid)
			table.insert(completed, qid)
		end)
		api.onClaimed(function(qid)
			table.insert(claimed, qid)
		end)
		fs:check()
		expect(completed).toEqual({})
		expect(#api.active() > 0).toBe(true)

		q.progress(p, key, 1)
		h:tick(2)
		fs.state = h:state(p)
		fs:check()
		fs:check() -- an unchanged state fires nothing again
		expect(completed).toEqual({ id })
		expect(claimed).toEqual({})

		expect(q.claim(p, id)).toBe(true)
		h:tick(2)
		fs.state = h:state(p)
		fs:check()
		fs:check()
		expect(completed).toEqual({ id })
		expect(claimed).toEqual({ id })
	end)

	it("fires onClaimed (not onCompleted) when a waiting reward is claimed after a reset", function()
		local config = cfg()
		local h, p, q = K.boot({ quests = config })
		local id, key, target = K.slotQuest(q, p, "daily", 1)
		q.progress(p, key, target)
		h:tick(2)
		fs = Kit.new({})
		fs.state = h:state(p)
		fs:start({ config = { Quests = config } })
		local api = StudWork.use(F.Quests)
		local completed, claimed = {}, {}
		api.onCompleted(function(qid)
			table.insert(completed, qid)
		end)
		api.onClaimed(function(qid)
			table.insert(claimed, qid)
		end)
		fs:check()
		h.clock = h:state(p).modules.Quests.extra.board.day.endsAt + 1
		h:tick(5) -- the reset moves it to waiting: not a completion, not a claim
		fs.state = h:state(p)
		fs:check()
		expect(completed).toEqual({})
		expect(claimed).toEqual({})
		expect(q.claim(p, id)).toBe(true)
		h:tick(2)
		fs.state = h:state(p)
		fs:check()
		expect(completed).toEqual({})
		expect(claimed).toEqual({ id })
	end)
end)
