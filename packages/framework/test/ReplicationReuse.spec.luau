--!nocheck
-- v1.7.0: Replication keeps a module's part of the state (the SAME table) while its data copy,
-- shared extra and per-player extra are unchanged, so charm-sync's diff skips it: a module that
-- changed nothing adds no per-tick churn when another module dirties the player.
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)

local def = StudWork.defineModule

local function mod(name, extra)
	local spec = { name = name, version = "1.0.0", framework = "^1.3.0" }
	for k, v in extra or {} do
		spec[k] = v
	end
	return def(spec)
end

local Wallet = mod("Wallet", {
	data = { key = "wallet", version = 1, default = { coins = 0 }, replicate = { "coins" } },
})
local Badge = mod("Badge", {
	data = { key = "badge", version = 1, default = { got = {} }, replicate = { "got" } },
})
local Board = mod("Board") -- extra only (setAll + set), no save section

local function boot()
	local ctxs = {}
	local function grab(name)
		return {
			init = function(ctx)
				ctxs[name] = ctx
			end,
		}
	end
	local h = Harness.new({
		modules = { Wallet, Badge, Board },
		servers = { Wallet = grab("Wallet"), Badge = grab("Badge"), Board = grab("Board") },
	})
	return h, ctxs
end

describe("Replication: unchanged module parts keep their table", function()
	it("another module's commit leaves a module's data-only and extra-only parts identical", function()
		local h, c = boot()
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		c.Board.replicate.setAll("rows", { 1, 2 })
		c.Board.replicate.set(p, "mine", { value = 3 })
		local first = h:state(p).modules
		c.Wallet.data.update(p, function(s)
			s.coins += 5
		end)
		local second = h:state(p).modules
		expect(second).Not.toBe(first)
		expect(second.Wallet).Not.toBe(first.Wallet)
		expect(second.Wallet.data.coins).toBe(5)
		expect(second.Badge).toBe(first.Badge)
		expect(second.Board).toBe(first.Board)
		expect(second.Board.extra.rows).toEqual({ 1, 2 })
		expect(second.Board.extra.mine.value).toBe(3)
	end)

	it("set and setAll rebuild only the module they belong to, with the new values", function()
		local h, c = boot()
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		h:fire(a, "StateInit")
		h:fire(b, "StateInit")
		c.Board.replicate.setAll("rows", { 1 })
		local a1, b1 = h:state(a).modules, h:state(b).modules
		c.Board.replicate.set(a, "mine", { value = 1 })
		local a2, b2 = h:state(a).modules, h:state(b).modules
		expect(a2.Board).Not.toBe(a1.Board)
		expect(a2.Board.extra.mine.value).toBe(1)
		expect(a2.Board.extra.rows).toEqual({ 1 })
		expect(a2.Wallet).toBe(a1.Wallet)
		expect(b2.Board).toBe(b1.Board) -- b's state wasn't touched by a's set
		c.Board.replicate.setAll("rows", { 1, 9 })
		local a3, b3 = h:state(a).modules, h:state(b).modules
		expect(a3.Board.extra.rows).toEqual({ 1, 9 })
		expect(b3.Board.extra.rows).toEqual({ 1, 9 })
		expect(a3.Board.extra.mine.value).toBe(1)
		expect(b3.Board.extra.mine).toBeNil()
		expect(a3.Wallet).toBe(a2.Wallet)
		expect(a3.Badge).toBe(a2.Badge)
	end)

	it("the module's own commit gives its part a new table", function()
		local h, c = boot()
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		local first = h:state(p).modules
		c.Badge.data.update(p, function(s)
			s.got.first = true
		end)
		local second = h:state(p).modules
		expect(second.Badge).Not.toBe(first.Badge)
		expect(second.Badge.data.got.first).toBe(true)
		expect(second.Wallet).toBe(first.Wallet)
	end)
end)
