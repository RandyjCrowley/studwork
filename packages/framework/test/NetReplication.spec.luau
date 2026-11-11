--!nocheck
-- v1.3.0: framework Net and Replication behind ctx (module-api.md §9, §10).
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
	data = {
		key = "wallet",
		version = 1,
		default = { coins = 0, secret = "x" },
		replicate = { "coins", "secret" },
		serverOnly = { "secret" },
	},
})
local Other = mod("Other", { data = { key = "other", version = 1, default = { n = 0 } } })

describe("ctx.net (Net)", function()
	-- v1.3.1 R19: Upgrades' `upgrade` action is the module's own Blink event (fake wire here,
	-- same limit 6/12 the framework's RequestUpgrade had); the Net pipeline exercised is the same.
	it("routes a module action's client event to its one owner, rate-limited, pcall'd", function()
		local got = {}
		local ev = Harness.fakeEvent("Upgrade", {})
		local h = Harness.new({
			modules = { Wallet },
			servers = {
				Wallet = {
					net = { Upgrade = ev },
					actions = {
						upgrade = {
							limit = { rate = 6, burst = 12 },
							handler = function(_player, id)
								table.insert(got, id)
								if id == "boom" then
									error("handler blew up")
								end
							end,
						},
					},
				},
			},
		})
		local p = h:addPlayer({ userId = 1 })
		h:fireCustom(ev, p, "a")
		h:fireCustom(ev, p, "boom")
		expect(table.concat(got, ",")).toBe("a,boom")
		expect(table.concat(h:warnings(), "\n")).toContain("action:Wallet.upgrade handler error")
		-- burst 12 at rate 6/s: a flood is cut off without advancing the clock
		for i = 1, 30 do
			h:fireCustom(ev, p, "x" .. i)
		end
		expect(#got < 20).toBe(true)
		expect(h.runtime.net.stats.limited > 0).toBe(true)
	end)

	it("a second owner of the same framework event is a boot error naming both", function()
		-- v1.3.1 (R19): framework.blink has no module events left (every framework client event
		-- is owned by a framework service at boot), so the two-module case is driven on a bare Net:
		-- the same net.claim that ctx.net.handle calls, the same error text.
		local Net = require(script.Parent.Parent.server.Net)
		local net = Net.new({
			events = nil,
			isPlayer = function()
				return true
			end,
			isLoaded = function()
				return true
			end,
			clock = os.clock,
			spawn = function() end,
			log = function() end,
		})
		net.forModule("Wallet").handle("ClientFunnel", function() end)
		local ok, err = pcall(function()
			net.forModule("Other").handle("ClientFunnel", function() end)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain(
			"framework event 'ClientFunnel' already has a handler (owned by Wallet); Other can't claim it too"
		)
		-- and a module event name that is not in framework.blink is refused, naming the real list
		local ok2, err3 = pcall(function()
			net.forModule("Wallet").handle("RequestRoll", function() end)
		end)
		expect(ok2).toBe(false)
		expect(tostring(err3)).toContain("unknown framework client event 'RequestRoll'")
		local _, err2 = Harness.boot({
			modules = { Wallet },
			servers = {
				Wallet = {
					init = function(ctx)
						ctx.net.handle("StateInit", function() end)
					end,
				},
			},
		})
		expect(err2).toContain("owned by framework")
	end)

	it("drops requests from players who left or aren't loaded; queues before boot finishes", function()
		local got = {}
		-- v1.3.1 R19: Rebirth's `rebirth` action on its own (fake) Blink event, limit 0.5/2
		local ev = Harness.fakeEvent("Rebirth", {})
		local h = Harness.new({
			modules = { Wallet },
			servers = {
				Wallet = {
					net = { Rebirth = ev },
					actions = {
						rebirth = {
							limit = { rate = 0.5, burst = 2 },
							handler = function(player)
								table.insert(got, player.UserId)
							end,
						},
					},
				},
			},
		})
		local ghost = Harness.player(99)
		h:fireCustom(ev, ghost) -- not in the game
		local p = Harness.player(5)
		h.players[5] = p
		h.inGame[p] = true -- joined, data not loaded yet
		h:fireCustom(ev, p)
		expect(#got).toBe(0)
		expect(h.runtime.net.stats.notLoaded).toBe(1)
		h:addPlayer({ userId = 5 })
		h:fireCustom(ev, p)
		expect(table.concat(got, ",")).toBe("5")
	end)

	it("handleEvent serves a module's own Blink event; framework events are refused for fire", function()
		local log = {}
		local ev = Harness.fakeEvent("PlaceItem", log)
		local c
		local got = {}
		local h = Harness.new({
			modules = { Wallet },
			servers = {
				Wallet = {
					init = function(ctx)
						c = ctx
						ctx.net.handleEvent("PlaceItem", ev, { rate = 1, burst = 1 }, function(_player, slot)
							table.insert(got, slot)
						end)
					end,
				},
			},
		})
		local p = h:addPlayer({ userId = 2 })
		h:fireCustom(ev, p, "s1")
		h:fireCustom(ev, p, "s2") -- burst 1: dropped
		expect(table.concat(got, ",")).toBe("s1")
		c.net.fire(p, ev, "hello")
		expect(log[#log].args[1]).toBe("hello")
		expect(function()
			c.net.fire(p, h.fake.events.StateSync, {})
		end).toThrow("'StateSync' is a framework event")
		expect(function()
			c.net.handleEvent("Bad", ev, { rate = 0, burst = 1 }, function() end)
		end).toThrow("limit must be")
		c.net.feedback(p, "toast", "hi")
		local last = h.fake.serverEvents[#h.fake.serverEvents]
		expect(last.event).toBe("Feedback")
		expect(last.args[1].Text).toBe("hi")
	end)
end)

describe("ctx.replicate (Replication)", function()
	it("ships listed data fields (minus serverOnly) and namespaced extras to the owner only", function()
		local c
		local h = Harness.new({
			modules = { Wallet, Other },
			servers = { Wallet = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		h:fire(a, "StateInit")
		h:fire(b, "StateInit")
		c.data.update(a, function(s)
			s.coins = 7
		end)
		c.replicate.set(a, "rate", 2.5)
		c.replicate.setAll("season", "spring")
		local sa = h:state(a)
		expect(sa.loaded).toBe(true)
		expect(sa.modules.Wallet.data.coins).toBe(7)
		expect(sa.modules.Wallet.data.secret).toBeNil()
		expect(sa.modules.Wallet.extra.rate).toBe(2.5)
		expect(sa.modules.Wallet.extra.season).toBe("spring")
		expect(sa.modules.Other).toBeNil() -- replicates nothing
		expect(sa.framework.paidRandomRestricted).toBe(false) -- policy lookup answered (fake)
		local sb = h:state(b)
		expect(sb.modules.Wallet.data.coins).toBe(0)
		expect(sb.modules.Wallet.extra.rate).toBeNil()
		expect(c.replicate.sent(a, "rate")).toBe(2.5)
		expect(c.replicate.sent(b, "rate")).toBeNil()
	end)

	it("unchanged sections keep their table reference between sends", function()
		local c
		local h = Harness.new({
			modules = { Wallet },
			servers = { Wallet = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		local p = h:addPlayer({ userId = 3 })
		h:fire(p, "StateInit")
		local first = h:state(p).modules.Wallet.data
		c.replicate.set(p, "ping", 1)
		local second = h:state(p).modules.Wallet.data
		expect(second).toBe(first)
		c.data.update(p, function(s)
			s.coins += 1
		end)
		expect(h:state(p).modules.Wallet.data).Not.toBe(first)
	end)

	it("sent() is nil until the client subscribed (StateInit)", function()
		local c
		local h = Harness.new({
			modules = { Wallet },
			servers = { Wallet = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		local p = h:addPlayer({ userId = 4, sync = false }) -- the window before StateInit
		c.replicate.set(p, "k", 1)
		h:tick(1)
		expect(c.replicate.sent(p, "k")).toBeNil()
		h:fire(p, "StateInit")
		h:tick(1)
		expect(c.replicate.sent(p, "k")).toBe(1)
	end)
end)
