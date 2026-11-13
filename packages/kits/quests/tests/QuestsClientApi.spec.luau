--!nocheck
--[[
	Quests client part with a plain-table fake state (QuestsClientKit; Lune; no UI kit here, so no screen is built): the api reads
	the replicated board, onCompleted / onClaimed fire on transitions and never for the first state,
	the actions fire the module's own Blink events, the part opens nothing and touches no input,
	and a client without the UI kit starts cleanly.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = require("packages/kits/quests/tests/Fixtures.luau")
local Kit = require("packages/kits/quests/tests/QuestsClientKit.luau")

local config = F.questsConfig()

local function newBoard(overrides)
	local b = {
		day = { id = 100, endsAt = 90000, slots = { { q = "d1", s = 0, r = 0 }, { q = "d2", s = 0, r = 0 } } },
		week = { id = 98, endsAt = 500000, slots = { { q = "w1", s = 0, r = 0 } } },
		list = { { q = "s1", s = 0 }, { q = "once", s = 0 } },
		waiting = {},
		pins = { "d1" },
	}
	for k, v in overrides or {} do
		b[k] = v
	end
	return b
end

local fs
local function boot(board)
	fs = Kit.new({ board = board or newBoard(), progIds = { "d1" }, prog = "1", questOdds = {} })
	fs:start({ config = { Quests = config } })
	return StudWork.use(F.Quests)
end

afterEach(function()
	if fs then
		fs:stop()
		fs = nil
	end
end)

describe("Quests client api", function()
	it("active() builds the views from state and config", function()
		local api = boot()
		local views = api.active()
		expect(#views).toBe(5)
		expect(views[1].id).toBe("d1")
		expect(views[1].objectives[1].value).toBe(1)
		expect(views[1].pinned).toBe(true)
		expect(api.board().pins[1]).toBe("d1")
		expect(api.read.views).toBe(require("packages/kits/quests/Quests/client/State.luau").views)
	end)

	it("active() is empty and board() nil before the board arrives", function()
		fs = Kit.new({})
		fs:start({ config = { Quests = config } })
		local api = StudWork.use(F.Quests)
		expect(api.active()).toEqual({})
		expect(api.board()).toBe(nil)
	end)

	it("onCompleted does not fire for the first state, then fires once per completion", function()
		local api = boot(newBoard({
			day = {
				id = 100,
				endsAt = 9,
				slots = { { q = "d1", s = 1, r = 0 }, { q = "d2", s = 0, r = 0 } },
			},
		}))
		local seen = {}
		local off = api.onCompleted(function(id)
			table.insert(seen, id)
		end)
		expect(seen).toEqual({}) -- d1 was already complete when the client joined
		local b = newBoard()
		b.day.slots[1].s = 1
		b.day.slots[2].s = 1
		fs:board(b)
		fs:check()
		expect(seen).toEqual({ "d2" }) -- d1 was complete before: only d2 is new
		fs:board(b) -- the same state again: nothing new
		fs:check()
		expect(seen).toEqual({ "d2" })
		off()
		local b2 = newBoard()
		b2.week.slots[1].s = 1
		fs:board(b2)
		fs:check()
		expect(seen).toEqual({ "d2" })
	end)

	it("onClaimed fires when a quest turns claimed", function()
		local api = boot()
		local seen = {}
		api.onClaimed(function(id)
			table.insert(seen, id)
		end)
		local b = newBoard()
		b.day.slots[1].s = 2
		fs:board(b)
		fs:check()
		expect(seen).toEqual({ "d1" })
	end)

	it("onCompleted / onClaimed refuse a non-function", function()
		local api = boot()
		expect(function()
			api.onCompleted("x")
		end).toThrow()
		expect(function()
			api.onClaimed(nil)
		end).toThrow()
	end)

	it("the actions fire the module's own events with the player's arguments", function()
		local api = boot()
		api.actions.claimQuest("d1")
		api.actions.rerollQuest("daily", 2)
		api.actions.pinQuest("d2", true)
		api.actions.ackQuest("tour")
		expect(#fs.fired).toBe(4)
		expect(fs.fired[1].event).toBe("ClaimQuest")
		expect(fs.fired[1].args[1]).toBe("d1")
		expect(fs.fired[2].event).toBe("RerollQuest")
		expect(fs.fired[2].args[1]).toBe("daily")
		expect(fs.fired[2].args[2]).toBe(2)
		expect(fs.fired[3].event).toBe("PinQuest")
		expect(fs.fired[4].event).toBe("AckQuest")
	end)

	it("never opens a screen, selects an object or fires an action on its own", function()
		local api = boot()
		local b = newBoard()
		b.day.slots[1].s = 1
		fs:board(b)
		fs:check()
		local ok, gui = pcall(function()
			return game:GetService("GuiService")
		end)
		if ok then
			expect(gui.SelectedObject).toBe(nil)
		end
		expect(#fs.fired).toBe(0)
		expect(#api.active()).toBe(5)
	end)

	it(
		"onClaimed fires for a one-time quest that leaves the board when claimed (the toast's source)",
		function()
			local api = boot()
			local claimed, completed = {}, {}
			api.onClaimed(function(id)
				table.insert(claimed, id)
			end)
			api.onCompleted(function(id)
				table.insert(completed, id)
			end)
			local b = newBoard()
			b.list[2].s = 1 -- "once" completes
			fs:board(b)
			fs:check()
			expect(completed).toEqual({ "once" })
			expect(claimed).toEqual({})
			local b2 = newBoard()
			b2.list = { { q = "s1", s = 0 } } -- claimed: the ledger holds it, the board no longer lists it
			fs:board(b2)
			fs:check()
			expect(claimed).toEqual({ "once" })
			fs:check() -- an unchanged state fires nothing more
			expect(claimed).toEqual({ "once" })
		end
	)

	it("boots with no config at all", function()
		fs = Kit.new({ board = { list = {}, waiting = {}, pins = {} } })
		fs:start()
		local api = StudWork.use(F.Quests)
		expect(api.active()).toEqual({})
	end)
end)

describe("Quests client: vanishedClaims (a claim the board no longer lists)", function()
	local Quests =
		require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Quests"):WaitForChild("client"))
	local function entry(id, status, waiting, periodId)
		return { id = id, status = status, claims = 0, waiting = waiting == true, periodId = periodId }
	end

	it("a complete quest gone from the snapshot was claimed", function()
		local prev = { a = entry("a", "complete"), b = entry("b", "active") }
		expect(Quests.vanishedClaims(prev, { b = entry("b", "active") })).toEqual({ "a" })
	end)

	it("nothing before the first state, for an active quest that left, or for a still-listed one", function()
		expect(Quests.vanishedClaims(nil, { a = entry("a", "complete") })).toEqual({})
		expect(Quests.vanishedClaims({ a = entry("a", "active") }, {})).toEqual({})
		expect(Quests.vanishedClaims({ a = entry("a", "complete") }, { a = entry("a", "claimed") })).toEqual({})
	end)

	it("a reset or an ended window (the id turns up waiting) is not a claim", function()
		local prev = { a = entry("a", "complete") }
		local snap = { ["a@w5"] = entry("a", "complete", true, 5) }
		expect(Quests.vanishedClaims(prev, snap)).toEqual({})
	end)

	it("a waiting entry that leaves is not counted here (State.transitions handles it)", function()
		local prev = { ["a@w5"] = entry("a", "complete", true, 5) }
		expect(Quests.vanishedClaims(prev, {})).toEqual({})
	end)

	it("sorted and once per id", function()
		local prev = { z = entry("z", "complete"), a = entry("a", "complete") }
		expect(Quests.vanishedClaims(prev, {})).toEqual({ "a", "z" })
	end)
end)
