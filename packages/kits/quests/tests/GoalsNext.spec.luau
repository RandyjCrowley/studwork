--!nocheck
-- Goals "what's next" (docs/framework/kits/quests.md, Goals API setNext): the hand-over after the
-- chain, nil hides, an error counts as nil and is logged (at most once a minute), answers compared
-- by value, and the provider runs at most once per nextSeconds per player even with a
-- CurrencyChanged every tick.
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local Goals, Economy = G.Goals, G.Economy

local CHAIN = { { id = "only", check = { call = true }, funnel = "Only" } }

local function finished(h, userId)
	local p = h:addPlayer({ userId = userId })
	h:use(Goals).complete(p, "only")
	h:tick(1)
	return p
end

local function warningsWith(h, text)
	local n = 0
	for _, w in h:warnings() do
		if string.find(w, text, 1, true) then
			n += 1
		end
	end
	return n
end

describe("Goals setNext", function()
	it("hands over to the provider when the chain ends (wire-safe answer, extra.goal next = true)", function()
		local h = G.boot({ chain = CHAIN })
		local goals = h:use(Goals)
		goals.setNext(function()
			return {
				text = "game.next.rebirth",
				args = { n = 3, bad = function() end },
				target = { position = { 1, 2, 3 } },
				widget = "Rebirth.button",
			}
		end)
		local p = finished(h, 1)
		local view = goals.current(p)
		expect(view.isNext).toBe(true)
		expect(view.id).toBeNil()
		expect(view.text).toBe("game.next.rebirth")
		expect(view.args).toEqual({ n = 3 }) -- the function dropped: wire-safe only
		expect(view.target).toEqual({ position = { 1, 2, 3 } })
		expect(view.widget).toBe("Rebirth.button")
		local wire = G.extraGoal(h, p)
		expect(wire.next).toBe(true)
		expect(wire.text).toBe("game.next.rebirth")
	end)

	it("nil hides the pill and the pointer", function()
		local h = G.boot({ chain = CHAIN })
		local answer = { text = "game.next.a" }
		h:use(Goals).setNext(function()
			return answer
		end)
		local p = finished(h, 2)
		expect(h:use(Goals).current(p).text).toBe("game.next.a")
		answer = nil
		h:use(Economy).grant(p, 1, "test") -- a relevant signal: re-run when the slot comes up
		h:tick(6)
		expect(h:use(Goals).current(p)).toBeNil()
		expect(G.extraGoal(h, p)).toBeNil()
	end)

	it("an error counts as nil and is logged at most once a minute", function()
		local h = G.boot({ chain = CHAIN })
		h:use(Goals).setNext(function()
			error("boom")
		end)
		local p = finished(h, 3)
		expect(h:use(Goals).current(p)).toBeNil()
		for _ = 1, 10 do
			h:use(Economy).grant(p, 1, "test")
			h:tick(5)
		end
		expect(warningsWith(h, "setNext provider failed")).toBe(1)
		for _ = 1, 4 do -- past the minute: logged again
			h:use(Economy).grant(p, 1, "test")
			h:tick(5)
		end
		expect(warningsWith(h, "setNext provider failed")).toBe(2)
	end)

	it("runs at most once per nextSeconds per player under a CurrencyChanged every tick", function()
		local h = G.boot({ chain = CHAIN, goals = { nextSeconds = 5 } })
		local calls = 0
		h:use(Goals).setNext(function()
			calls += 1
			return { text = "game.next.b" }
		end)
		local p = finished(h, 4)
		local base = calls
		for _ = 1, 30 do
			h:use(Economy).grant(p, 1, "income") -- CurrencyChanged every second
			h:tick(1)
		end
		expect(calls - base <= 30 / 5 + 1).toBe(true)
		expect(calls - base >= 5).toBe(true)
		-- idle (no signal): the provider doesn't run at all
		local idle = calls
		h:tick(30)
		expect(calls).toBe(idle)
	end)

	it("a second setNext replaces the provider; players past the chain get its answer", function()
		local h = G.boot({ chain = CHAIN })
		h:use(Goals).setNext(function()
			return { text = "game.next.one" }
		end)
		local p = finished(h, 5)
		expect(h:use(Goals).current(p).text).toBe("game.next.one")
		h:use(Goals).setNext(function()
			return { text = "game.next.two" }
		end)
		h:tick(6)
		expect(h:use(Goals).current(p).text).toBe("game.next.two")
		expect(pcall(h:use(Goals).setNext, "not a function")).toBe(false)
	end)

	it("not per tick: an unchanged answer replicates nothing new", function()
		local h = G.boot({ chain = CHAIN })
		h:use(Goals).setNext(function()
			return { text = "game.next.same", target = { tag = "Board" } }
		end)
		local p = finished(h, 6)
		local first = G.extraGoal(h, p)
		for _ = 1, 4 do
			h:use(Economy).grant(p, 1, "test")
			h:tick(5)
		end
		expect(G.extraGoal(h, p)).toBe(first) -- the same table: never re-sent
	end)

	it("the flag off then on: the provider runs again for a finished player (no stale pointer)", function()
		local h = G.boot({
			chain = CHAIN,
			goals = { flag = "g" },
			flags = { g = { default = true } },
			isStudio = true,
		})
		local goals = h:use(Goals)
		local answer = "game.next.a"
		goals.setNext(function()
			return { text = answer }
		end)
		local p = finished(h, 8)
		expect(goals.current(p).text).toBe("game.next.a")
		h:use(Economy).grant(p, 5, "test") -- schedules a provider run in a wheel slot
		h:tick(1)
		h:console("flags set g false")
		h:tick(10) -- the slot passes while off
		h:console("flags set g true")
		answer = "game.next.b"
		for _ = 1, 5 do
			h:use(Economy).grant(p, 5, "test")
			h:tick(3)
		end
		h:tick(20)
		expect(goals.current(p).text).toBe("game.next.b")
	end)
end)
