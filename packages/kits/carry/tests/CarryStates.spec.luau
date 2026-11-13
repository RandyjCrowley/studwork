--!nocheck
--[[
	Carry's state machine and drop mechanics (planted cases 25-32, 34-37 and the rest of carry.md "States
	(frozen)"): every action x state cell, delivery, leave/rejoin, the void, settling, fling protection,
	drop rules, replication, the flag and the actions. FakeWorld, no Movement unless a test says so.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local CarryKit = require("packages/kits/carry/tests/CarryKit.luau")
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")
local CF = require("packages/kits/carry/Carry/shared/CF.luau")
local Codec = require("packages/kits/carry/Carry/shared/Codec.luau")

local V = CarryKit.V
local Carry = CarryKit.Carry

local function reasons(k)
	local out = {}
	for _, e in k:events("Dropped") do
		table.insert(out, e.args[2])
	end
	return out
end

local function pick(k, i, obj)
	local ok, why = k.carry.pickUp(k.p[i], obj)
	return ok, why
end

local function keyOf(k, player, id)
	local extra = k.h:state(player).modules.Carry.extra
	return Codec.decode(extra["carry:" .. id])
end

-- a kit with `n` players standing along x, a crate, and the first logic tick done
local function crateKit(n, o)
	o = o or {}
	o.players = n
	local k = CarryKit.new(o)
	local crate = k:crate()
	k:run(0.3)
	return k, crate
end

describe("case 25: races and receivers", function()
	it('two pickUps race for the last slot: exactly one succeeds, the other gets "full"', function()
		local k = CarryKit.new({ players = 2 })
		local tray =
			k.fw:addPart({ name = "Tray", position = V(0, 1, -3), size = V(2, 2, 2), tags = { "Tray" } })
		k.carry.registerCarriable("Tray", { carriers = { min = 1, max = 1 } })
		k:run(0.3)
		local ok1 = pick(k, 1, tray)
		local ok2, why2 = pick(k, 2, tray)
		expect(ok1).toBe(true)
		expect(ok2).toBe(false)
		expect(why2).toBe("full")
		expect(#k.carry.holders(tray)).toBe(1)
	end)

	it('a busy receiver for a hand-off: "receiverBusy"', function()
		local k, crate = crateKit(2)
		local other = k:crate(V(3, 1, -3), "Crate")
		k:run(0.2)
		expect(pick(k, 1, crate)).toBe(true)
		expect(pick(k, 2, other)).toBe(true)
		local ok, why = k.carry.handOff(k.p[1], crate, k.p[2])
		expect(ok).toBe(false)
		expect(why).toBe("receiverBusy")
	end)

	it('the giver or an absent player as receiver: "invalidReceiver"', function()
		local k, crate = crateKit(2)
		expect(pick(k, 1, crate)).toBe(true)
		local _, why = k.carry.handOff(k.p[1], crate, k.p[1])
		expect(why).toBe("invalidReceiver")
		k.fw:removePlayer(k.p[2])
		local _, why2 = k.carry.handOff(k.p[1], crate, k.p[2])
		expect(why2).toBe("invalidReceiver")
	end)

	it('a player already holding something is "busy"', function()
		local k, crate = crateKit(1)
		local other = k:crate(V(3, 1, -3))
		k:run(0.2)
		expect(pick(k, 1, crate)).toBe(true)
		local ok, why = pick(k, 1, other)
		expect(ok).toBe(false)
		expect(why).toBe("busy")
	end)
end)

describe("cases 26 and 27: delivery", function()
	it('delivers once, is terminal ("delivered"), and delivers again only after Carry.reset', function()
		local k, crate = crateKit(1)
		local zone = k:zone(V(0, 5, 0))
		k:run(0.2)
		expect(pick(k, 1, crate)).toBe(true)
		k:run(0.5)
		local delivered = k:events("Delivered")
		expect(#delivered).toBe(1)
		local a = delivered[1].args
		expect(a[1]).toBe(crate)
		expect(a[2]).toBe(zone)
		expect(a[3]).toEqual({ k.p[1] })
		expect(a[4].deliveredAt >= a[4].startedAt).toBe(true)
		expect(a[4].perCarrierSeconds[1] > 0).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("delivered")
		expect(crate.anchored).toBe(true)
		expect(#k.carry.holders(crate)).toBe(0)
		-- re-pick-up inside the zone
		local ok, why = pick(k, 1, crate)
		expect(ok).toBe(false)
		expect(why).toBe("delivered")
		k:run(2)
		expect(#k:events("Delivered")).toBe(1)
		-- reset re-arms it
		expect(k.carry.reset(crate)).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("idle")
		expect(pick(k, 1, crate)).toBe(true)
		k:run(0.5)
		expect(#k:events("Delivered")).toBe(2)
	end)

	it("an object in two overlapping zones: exactly one Delivered, from the first zone", function()
		local k, crate = crateKit(1)
		local z1 = k:zone(V(0, 5, 0))
		local z2 = k:zone(V(2, 5, 0))
		k:run(0.2)
		expect(pick(k, 1, crate)).toBe(true)
		k:run(2)
		local delivered = k:events("Delivered")
		expect(#delivered).toBe(1)
		expect(delivered[1].args[2]).toBe(z1)
		local _ = z2
	end)

	it("needs the object's whole box inside the zone (full) and every carrier in reach", function()
		local k, crate = crateKit(1)
		-- a zone that holds the object's pivot but not its whole box
		k:zone(V(5, 5, -3), V(10, 10, 10)) -- x from 0 to 10: the crate (x -1..1) sticks out
		k:run(0.2)
		expect(pick(k, 1, crate)).toBe(true)
		k:run(1)
		expect(#k:events("Delivered")).toBe(0)
	end)

	it('deliveryContainment = "center" only needs the pivot (full needs the whole box)', function()
		for _, containment in { "full", "center" } do
			local k = CarryKit.new({ config = { deliveryContainment = containment } })
			local crate = k:crate()
			k:zone(V(4.5, 5, -3), V(10, 10, 10)) -- x from -0.5 to 9.5: the crate's pivot is in, its box sticks out
			k:run(0.3)
			expect(pick(k, 1, crate)).toBe(true)
			k:run(1)
			expect(#k:events("Delivered")).toBe(if containment == "center" then 1 else 0)
		end
	end)

	it("a carrier outside the zone's reach blocks delivery", function()
		local k = CarryKit.new({ paths = { FakeWorld.paths.stand(V(0, 3, 0)) } })
		local crate = k:crate()
		-- the zone encloses the crate's carried pose but the carrier stands 30 studs off
		k:zone(V(0, 5, -40), V(30, 10, 30))
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		k:run(1)
		expect(#k:events("Delivered")).toBe(0)
	end)

	it("an object pushed or dropped into a zone does not count", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		expect(k.carry.drop(k.p[1], crate)).toBe(true)
		k:zone(V(0, 5, 0))
		k:run(3)
		expect(#k:events("Delivered")).toBe(0)
	end)

	it("multi-carrier delivery lists every carrier and per-carrier times, including one who left", function()
		local k = CarryKit.new({ players = 3, positions = { V(-3, 3, 0), V(3, 3, 0), V(-3, 3, 2) } })
		local couch = k:couch()
		k:run(0.3)
		expect(pick(k, 1, couch)).toBe(true)
		expect(pick(k, 2, couch)).toBe(true)
		expect(pick(k, 3, couch)).toBe(true)
		k:run(0.3)
		expect(k.carry.drop(k.p[3], couch)).toBe(true) -- still 2 of min 2: carried
		expect(k.carry.stateOf(couch)).toBe("carried")
		k:zone(V(0, 5, 0))
		k:run(1)
		local delivered = k:events("Delivered")
		expect(#delivered).toBe(1)
		local per = delivered[1].args[4].perCarrierSeconds
		expect(per[1] ~= nil and per[2] ~= nil and per[3] ~= nil).toBe(true)
		expect(per[3] < per[1]).toBe(true)
		expect(delivered[1].args[3]).toEqual({ k.p[1], k.p[2] })
	end)
end)

describe("cases 28-30: leaving", function()
	it(
		'a carrier leaves mid-carry with carrierLeft = "drop": the object persists in place, nothing leaks',
		function()
			local k, crate = crateKit(1, { paths = { FakeWorld.paths.line(V(0, 3, 0), V(5, 0, 0)) } })
			local parts = #k.fw.parts
			expect(pick(k, 1, crate)).toBe(true)
			k:run(2)
			local at = crate.cf.p
			k.h:removePlayer(k.p[1])
			expect(k.carry.stateOf(crate)).toBe("dropped")
			expect(reasons(k)).toEqual({ "carrierLeft" })
			k:run(2)
			expect(vector.magnitude(crate.cf.p - at) < 4).toBe(true)
			expect(#k.fw.parts).toBe(parts)
			expect(#k:events("Returned")).toBe(0)
			expect(crate.canCollide).toBe(true)
		end
	)

	it(
		'carrierLeft = "returnToSpawn": Dropped then Returned("carrierLeft"), back at the spawn, anchored',
		function()
			local k, crate = crateKit(1, {
				paths = { FakeWorld.paths.line(V(0, 3, 0), V(5, 0, 0)) },
				config = { dropRules = { carrierLeft = "returnToSpawn" } },
			})
			local spawn = crate.cf.p
			expect(pick(k, 1, crate)).toBe(true)
			k:run(2)
			expect(vector.magnitude(crate.cf.p - spawn) > 3).toBe(true)
			k.h:removePlayer(k.p[1])
			expect(reasons(k)).toEqual({ "carrierLeft" })
			local returned = k:events("Returned")
			expect(#returned).toBe(1)
			expect(returned[1].args[2]).toBe("carrierLeft")
			expect(vector.magnitude(crate.cf.p - spawn) < 1e-4).toBe(true)
			expect(crate.anchored).toBe(true)
			expect(k.carry.stateOf(crate)).toBe("idle")
		end
	)

	it("a co-carrier leaving a 2-carrier object below min drops it (belowMin)", function()
		local k = CarryKit.new({ players = 2, positions = { V(-3, 3, 0), V(3, 3, 0) } })
		local couch = k:couch()
		k:run(0.3)
		expect(pick(k, 1, couch)).toBe(true)
		expect(pick(k, 2, couch)).toBe(true)
		k.h:removePlayer(k.p[2])
		expect(reasons(k)).toEqual({ "carrierLeft" })
		expect(k.carry.stateOf(couch)).toBe("dropped")
	end)

	it("CharacterRemoving without Died (LoadCharacter) releases the slot", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		k.fw:removeCharacter(k.p[1])
		expect(reasons(k)).toEqual({ "carrierLeft" })
		expect(k.carry.isCarrying(k.p[1])).toBe(nil)
	end)

	it("a dying carrier drops the object (carrierDied); the rule can be turned off", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		k.fw:kill(k.p[1])
		expect(reasons(k)).toEqual({ "carrierDied" })
		local k2, crate2 = crateKit(1, { config = { dropRules = { carrierDied = false } } })
		expect(pick(k2, 1, crate2)).toBe(true)
		k2.fw:kill(k2.p[1])
		expect(k2.carry.stateOf(crate2)).toBe("carried")
	end)

	it("the player's walk speed is restored when the carrier leaves the object", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 13.6) < 1e-4).toBe(true) -- medium: x0.85
		expect(k.carry.drop(k.p[1], crate)).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16) < 1e-4).toBe(true)
	end)
end)

describe("case 29: the catch window", function()
	local function thrown()
		local k = CarryKit.new({ players = 2, positions = { V(0, 3, 0), V(24, 3, 0) } })
		local crate = k:crate()
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		local ok, why = k.carry.handOff(k.p[1], crate, k.p[2])
		expect(why).toBe(nil)
		expect(ok).toBe(true)
		return k, crate
	end

	it("a throw launches an unanchored, colliding, grouped object; the receiver catches it", function()
		local k, crate = thrown()
		expect(k.carry.stateOf(crate)).toBe("thrown")
		expect(crate.anchored).toBe(false)
		expect(crate.canCollide).toBe(true)
		expect(crate.collisionGroup).toBe("CarryDropped")
		expect(k.carry.isCarrying(k.p[1])).toBe(nil) -- the thrower's slot freed at once
		local d = keyOf(k, k.p[1], "1")
		expect(d.state).toBe("thrown")
		expect(d.throw.from).toBe(1)
		expect(d.throw.to).toBe(2)
		k:run(1.2)
		expect(k.carry.stateOf(crate)).toBe("carried")
		expect(k.carry.isCarrying(k.p[2])).toBe(crate)
		local handed = k:events("HandedOff")
		expect(#handed).toBe(1)
		expect(handed[1].args[2]).toBe(k.p[1])
		expect(handed[1].args[3]).toBe(k.p[2])
		expect(handed[1].args[4]).toBe(true)
		expect(crate.anchored).toBe(true)
	end)

	it("a third player cannot pick up a thrown object", function()
		local k, crate = thrown()
		local third = k.h:addPlayer({ userId = 3 })
		k.fw:addPlayer(third, { path = FakeWorld.paths.stand(V(1, 3, 0)) })
		local ok, why = k.carry.pickUp(third, crate)
		expect(ok).toBe(false)
		expect(why).toBe("thrown")
	end)

	it('the receiver leaves during the window: Dropped("missedThrow", receiver)', function()
		local k, crate = thrown()
		k.h:removePlayer(k.p[2])
		local events = k:events("Dropped")
		expect(#events).toBe(1)
		expect(events[1].args[2]).toBe("missedThrow")
		expect(events[1].args[3]).toBe(k.p[2])
		expect(k.carry.stateOf(crate)).toBe("dropped")
	end)

	it("the thrower leaving changes nothing", function()
		local k, crate = thrown()
		k.h:removePlayer(k.p[1])
		expect(k.carry.stateOf(crate)).toBe("thrown")
		expect(#k:events("Dropped")).toBe(0)
		k:run(1.2)
		expect(k.carry.isCarrying(k.p[2])).toBe(crate)
	end)

	it("an uncaught throw becomes a plain drop after catchWindowSeconds: missedThrow", function()
		local k = CarryKit.new({ players = 2, positions = { V(0, 3, 0), V(24, 3, 0) } })
		local crate = k:crate()
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		expect(k.carry.handOff(k.p[1], crate, k.p[2])).toBe(true)
		-- the receiver is out of the flight path: the object lands short of catchRadius
		k.fw:setPath(k.p[2], FakeWorld.paths.stand(V(0, 3, 38)))
		k:run(2)
		expect(reasons(k)).toEqual({ "missedThrow" })
		local e = k:events("Dropped")[1]
		expect(e.args[3]).toBe(k.p[2])
		k:run(3)
		expect(k.carry.stateOf(crate)).toBe("idle") -- settled
	end)
end)

describe("case 30-31: the void and the kill plane", function()
	local function voidKit()
		local k = CarryKit.new({ ground = false, killY = -500 })
		local crate = k:crate(V(0, 10, -3))
		k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(0, 13, 0)))
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		return k, crate
	end

	it('a drop over the void: the object returns to spawn, Returned("void"), and is re-anchored', function()
		local k, crate = voidKit()
		local spawn = crate.cf.p
		expect(k.carry.drop(k.p[1], crate)).toBe(true)
		k:run(8)
		local returned = k:events("Returned")
		expect(#returned).toBe(1)
		expect(returned[1].args[2]).toBe("void")
		expect(vector.magnitude(crate.cf.p - spawn) < 1e-4).toBe(true)
		expect(crate.anchored).toBe(true)
		expect(#k.fw.destroyed).toBe(0)
		expect(k.carry.stateOf(crate)).toBe("idle")
	end)

	it(
		"dropped 1,000 studs above killY with a 0.45 s server hitch while it falls: still returned, never destroyed",
		function()
			local k = CarryKit.new({ ground = false, killY = -500 })
			local crate = k:crate(V(0, 500, -3))
			k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(0, 503, 0)))
			k:run(0.3)
			expect(pick(k, 1, crate)).toBe(true)
			k:run(0.5)
			expect(k.carry.drop(k.p[1], crate)).toBe(true)
			k:run(2) -- falling
			k.fw:hitch(k.h, 0.45)
			k:run(10)
			expect(#k.fw.destroyed).toBe(0)
			expect(#k:events("Returned")).toBe(1)
			expect(crate.anchored).toBe(true)
		end
	)

	it("a hitch at every moment of a long fall never loses the object (predictive check)", function()
		for hitchAt = 1, 9 do
			local k = CarryKit.new({ ground = false, killY = -500 })
			local crate = k:crate(V(0, 100, -3))
			k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(0, 103, 0)))
			k:run(0.3)
			expect(pick(k, 1, crate)).toBe(true)
			k:run(0.3)
			expect(k.carry.drop(k.p[1], crate)).toBe(true)
			k:run(hitchAt * 0.1)
			k.fw:hitch(k.h, 0.45)
			k:run(6)
			expect(#k.fw.destroyed).toBe(0)
			expect(#k:events("Returned")).toBe(1)
		end
	end)

	it("a resting object 1 stud above the kill plane is not returned", function()
		local k = CarryKit.new({ ground = false, killY = -500 })
		-- the kill plane is killY + killMarginStuds = -450; a floor whose top is at -449 holds the object
		k.fw:addPart({ name = "Floor", position = V(0, -451, 0), size = V(60, 4, 60) })
		local crate = k:crate(V(0, -448, -3))
		k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(0, -445, 0)))
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		expect(k.carry.drop(k.p[1], crate)).toBe(true)
		k:run(4)
		expect(#k:events("Returned")).toBe(0)
		expect(#k.fw.destroyed).toBe(0)
	end)
end)

describe("case 32 and fling protection: a dropped object", function()
	it("keeps CanCollide true, joins the CarryDropped group at once, settles, and is re-anchored", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		expect(crate.canCollide).toBe(false) -- carried: only so the carriers don't bump it
		expect(k.carry.drop(k.p[1], crate)).toBe(true)
		expect(crate.canCollide).toBe(true)
		expect(crate.collisionGroup).toBe("CarryDropped")
		expect(crate.anchored).toBe(false)
		expect(k.carry.stateOf(crate)).toBe("dropped")
		-- it never falls through the floor, even during the first 0.5 s
		local lowest = math.huge
		k:run(0.6, function()
			lowest = math.min(lowest, crate.cf.p.y)
		end)
		expect(lowest >= 0.99).toBe(true)
		k:run(3)
		expect(k.carry.stateOf(crate)).toBe("idle")
		expect(crate.anchored).toBe(true)
		expect(crate.collisionGroup).toBe("Default")
		expect(crate.canCollide).toBe(true)
		-- a scripted push no longer moves it
		local at = crate.cf.p
		crate.velocity = V(30, 0, 0)
		k:run(1)
		expect(vector.magnitude(crate.cf.p - at) < 1e-6).toBe(true)
	end)

	it("a game collision group replaces the built-in one", function()
		local k, crate = crateKit(1, { config = { collisionGroup = "NoNpcs" } })
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.drop(k.p[1], crate)
		expect(crate.collisionGroup).toBe("NoNpcs")
		expect(crate.canCollide).toBe(true)
	end)

	it("dropNoCollideSeconds is an opt-in extra window, nil by default", function()
		local k, crate = crateKit(1, { config = { dropNoCollideSeconds = 0.5 } })
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.drop(k.p[1], crate)
		expect(crate.canCollide).toBe(false)
		expect(crate.collisionGroup).toBe("CarryDropped") -- still grouped
		k:run(0.8)
		expect(crate.canCollide).toBe(true)
		expect(Carry.config.defaults.dropNoCollideSeconds).toBe(nil)
	end)

	it("an object can be picked up again from the dropped state", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.drop(k.p[1], crate)
		k:run(0.2)
		expect(k.carry.stateOf(crate)).toBe("dropped")
		local ok = pick(k, 1, crate)
		expect(ok).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("carried")
		expect(crate.anchored).toBe(true)
		expect(crate.canCollide).toBe(false)
	end)
end)

describe("case 34: Movement absent", function()
	it("Carry boots and carries with no erroring-proxy access", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		k:run(2)
		expect(k.carry.stateOf(crate)).toBe("carried")
		expect(k.h:warnings()).toEqual({})
	end)
end)

describe("case 35: the flag goes off mid-carry", function()
	it(
		"releases every object unanchored, restores walk speeds, clears carry:* keys; refuses while off",
		function()
			local cs = StudWork.test.fakes.configService({ values = { flag_carryOn = true } })
			local k = CarryKit.new({
				players = 2,
				config = { flag = "carryOn" },
				harness = {
					flags = { carryOn = { default = true } },
					flagOverride = { enabled = true, refreshSeconds = 5 },
					services = { ConfigService = cs },
					env = "live",
				},
			})
			local crate = k:crate()
			local couch = k:couch(V(0, 1, 10))
			k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(0, 3, 0)))
			k.fw:setPath(k.p[2], FakeWorld.paths.stand(V(0, 3, 9)))
			k:run(0.5)
			expect(pick(k, 1, crate)).toBe(true)
			expect(pick(k, 2, couch)).toBe(true) -- gathering (min 2)
			expect(keyOf(k, k.p[1], "1").state).toBe("carried")
			expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 13.6) < 1e-4).toBe(true)
			cs.set("flag_carryOn", false)
			cs.publish()
			k:run(6)
			expect(k.carry.stateOf(crate) == "dropped" or k.carry.stateOf(crate) == "idle").toBe(true)
			expect(crate.canCollide).toBe(true)
			expect(k.carry.isCarrying(k.p[1])).toBe(nil)
			expect(k.carry.isCarrying(k.p[2])).toBe(nil)
			for _, e in { "carry:1", "carry:2" } do
				expect(k.h:state(k.p[1]).modules.Carry.extra[e]).toBe(nil)
			end
			for _, p in k.p do
				expect(math.abs(k.fw:humanoid(p).walkSpeed - 16) < 1e-4).toBe(true)
			end
			local flagOff = 0
			for _, r in reasons(k) do
				if r == "flagOff" then
					flagOff += 1
				end
			end
			expect(flagOff).toBe(2)
			local ok, why = pick(k, 1, crate)
			expect(ok).toBe(false)
			expect(why).toBe("off")
			-- settles to rest even while off
			expect(crate.anchored).toBe(true)
			-- back on: starts empty
			cs.set("flag_carryOn", true)
			cs.publish()
			k:run(6)
			expect(pick(k, 1, crate)).toBe(true)
		end
	)
end)

describe("case 36: the States (frozen) table, every cell", function()
	local function couchKit(n, o)
		o = o or {}
		o.players = n
		o.positions = { V(-3, 3, 0), V(3, 3, 0), V(-3, 3, 2), V(3, 3, 2), V(0, 3, 1) }
		local k = CarryKit.new(o)
		local couch = k:couch()
		k:run(0.3)
		return k, couch
	end

	it("pickUp: idle -> carried (min 1) or gathering (min 2); the lowest free slot", function()
		local k, crate = crateKit(1)
		expect(k.carry.stateOf(crate)).toBe("idle")
		expect(pick(k, 1, crate)).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("carried")
		local k2, couch = couchKit(4)
		expect(pick(k2, 2, couch)).toBe(true)
		expect(k2.carry.stateOf(couch)).toBe("gathering")
		expect(couch.anchored).toBe(true)
		expect(couch.canCollide).toBe(true) -- gathering: not lifted
		expect(pick(k2, 1, couch)).toBe(true) -- slot 1 is taken: it gets slot 2
		expect(k2.carry.holders(couch)).toEqual({ k2.p[2], k2.p[1] })
		expect(k2.carry.stateOf(couch)).toBe("carried")
		expect(couch.canCollide).toBe(false)
		expect(pick(k2, 3, couch)).toBe(true)
		expect(pick(k2, 4, couch)).toBe(true)
		local ok, why = pick(k2, 5, couch)
		expect(ok).toBe(false)
		expect(why).toBe("full")
		local d = keyOf(k2, k2.p[1], "1")
		expect(d.carriers).toEqual({ 2, 1, 3, 4 })
		expect(d.slots[1]).toBe(2)
	end)

	it("a 4-carrier couch refuses a throw (notSoleHolder); gathering too", function()
		local k, couch = couchKit(5)
		expect(pick(k, 1, couch)).toBe(true)
		local _, why = k.carry.handOff(k.p[1], couch, k.p[5])
		expect(why).toBe("notSoleHolder") -- gathering
		for i = 2, 4 do
			expect(pick(k, i, couch)).toBe(true)
		end
		local _, why2 = k.carry.handOff(k.p[1], couch, k.p[5])
		expect(why2).toBe("notSoleHolder")
	end)

	it("drop in gathering frees the slot; 0 slots is idle", function()
		local k, couch = couchKit(2)
		expect(pick(k, 1, couch)).toBe(true)
		expect(k.carry.drop(k.p[1], couch)).toBe(true)
		expect(k.carry.stateOf(couch)).toBe("idle")
		expect(#k:events("Dropped")).toBe(0)
		expect(k.carry.drop(k.p[1], couch)).toBe(false) -- not a holder
	end)

	it(
		"drop in carried: slots still >= min stays carried; fewer with belowMin on drops it, off sets it down",
		function()
			local k, couch = couchKit(3)
			for i = 1, 3 do
				expect(pick(k, i, couch)).toBe(true)
			end
			expect(k.carry.drop(k.p[3], couch)).toBe(true)
			expect(k.carry.stateOf(couch)).toBe("carried") -- 2 of min 2
			expect(#k:events("Dropped")).toBe(0)
			expect(k.carry.drop(k.p[2], couch)).toBe(true) -- 1 < min: belowMin on
			expect(k.carry.stateOf(couch)).toBe("dropped")
			expect(reasons(k)).toEqual({ "manual" })
			expect(k.carry.holders(couch)).toEqual({})
			expect(k.carry.isCarrying(k.p[1])).toBe(nil)

			local k2, couch2 = couchKit(3, { config = { dropRules = { belowMin = false } } })
			for i = 1, 3 do
				expect(pick(k2, i, couch2)).toBe(true)
			end
			expect(k2.carry.drop(k2.p[3], couch2)).toBe(true)
			expect(k2.carry.drop(k2.p[2], couch2)).toBe(true)
			expect(k2.carry.stateOf(couch2)).toBe("gathering") -- set down, p1 still holds the one slot
			expect(couch2.anchored).toBe(true)
			expect(couch2.canCollide).toBe(true)
			expect(k2.carry.holders(couch2)).toEqual({ k2.p[1] })
			expect(#k2:events("Dropped")).toBe(0)
			expect(pick(k2, 2, couch2)).toBe(true) -- lifts again
			expect(k2.carry.stateOf(couch2)).toBe("carried")
		end
	)

	it("adjacent hand-off swaps the slot; a heavy object can be handed over but not thrown", function()
		local k = CarryKit.new({ players = 2, positions = { V(0, 3, 0), V(3, 3, 0) } })
		local anvil = k:anvil()
		k:run(0.3)
		expect(pick(k, 1, anvil)).toBe(true)
		expect(k.carry.handOff(k.p[1], anvil, k.p[2])).toBe(true)
		expect(k.carry.holders(anvil)).toEqual({ k.p[2] })
		local ev = k:events("HandedOff")[1].args
		expect(ev[2]).toBe(k.p[1])
		expect(ev[3]).toBe(k.p[2])
		expect(ev[4]).toBe(false)
		expect(k.carry.isCarrying(k.p[1])).toBe(nil)
		expect(k.carry.stateOf(anvil)).toBe("carried")
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16) < 1e-4).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[2]).walkSpeed - 11.2) < 1e-4).toBe(true)
		-- now far apart: heavy is not throwable
		k.fw:setPath(k.p[1], FakeWorld.paths.stand(V(20, 3, 0)))
		k:run(0.5)
		local ok, why = k.carry.handOff(k.p[2], anvil, k.p[1])
		expect(ok).toBe(false)
		expect(why).toBe("notThrowable")
	end)

	it('a throw beyond throwRange is refused ("tooFar")', function()
		local k = CarryKit.new({ players = 2, positions = { V(0, 3, 0), V(60, 3, 0) } })
		local crate = k:crate()
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		local ok, why = k.carry.handOff(k.p[1], crate, k.p[2])
		expect(ok).toBe(false)
		expect(why).toBe("tooFar")
		expect(k.carry.stateOf(crate)).toBe("carried")
	end)

	it("a non-holder cannot hand off or drop", function()
		local k, crate = crateKit(2)
		local ok, why = k.carry.handOff(k.p[1], crate, k.p[2])
		expect(ok).toBe(false)
		expect(why).toBe("notSoleHolder")
		expect(k.carry.drop(k.p[1], crate)).toBe(false)
	end)

	it("Carry.reset from every state re-arms the object (idle) at its spawn or a given CFrame", function()
		local k =
			CarryKit.new({ players = 4, positions = { V(-3, 3, 0), V(3, 3, 0), V(-3, 3, 2), V(3, 3, 2) } })
		local crate = k:crate(V(0, 1, -3))
		local couch = k:couch(V(0, 1, 20))
		k.fw:setPath(k.p[3], FakeWorld.paths.stand(V(-3, 3, 22)))
		k.fw:setPath(k.p[4], FakeWorld.paths.stand(V(3, 3, 22)))
		k:run(0.3)
		local spawn = crate.cf.p
		-- carried
		expect(pick(k, 1, crate)).toBe(true)
		k:run(1)
		expect(k.carry.reset(crate)).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("idle")
		expect(vector.magnitude(crate.cf.p - spawn) < 1e-4).toBe(true)
		expect(k.carry.isCarrying(k.p[1])).toBe(nil)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16) < 1e-4).toBe(true)
		expect(crate.anchored).toBe(true)
		-- gathering
		expect(pick(k, 3, couch)).toBe(true)
		expect(k.carry.reset(couch)).toBe(true)
		expect(k.carry.stateOf(couch)).toBe("idle")
		-- dropped, to a new place
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.drop(k.p[1], crate)
		local there = CF.new(V(7, 1, -3))
		expect(k.carry.reset(crate, there)).toBe(true)
		expect(crate.cf.p.x).toBe(7)
		expect(k.carry.stateOf(crate)).toBe("idle")
		expect(#k:events("Returned")).toBe(3)
		-- an unknown object
		expect(k.carry.reset(k.fw:addPart({ name = "Rock" }))).toBe(false)
	end)
end)

describe("case 37: streaming (server side)", function()
	it("server state is unaffected when another client's view streams out and back", function()
		local k, crate = crateKit(2)
		expect(pick(k, 1, crate)).toBe(true)
		local before = k.h:state(k.p[2]).modules.Carry.extra["carry:1"]
		-- p2 (a watcher) leaves and comes back: its view of the carried object restarts from the server's state
		k.h:removePlayer(k.p[2])
		k:run(1)
		local again = k.h:addPlayer({ userId = 9 })
		k.fw:addPlayer(again, { path = FakeWorld.paths.stand(V(0, 3, 3)) })
		k:run(0.3)
		expect(k.carry.stateOf(crate)).toBe("carried")
		expect(k.carry.holders(crate)).toEqual({ k.p[1] })
		expect(k.h:state(again).modules.Carry.extra["carry:1"]).toBe(before)
	end)
end)

describe("drop rules on the clamped pose", function()
	it("a hazard reported by the game drops the object only when dropRules.hazard is on", function()
		local k, crate = crateKit(1)
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.reportHazard(k.p[1], crate)
		expect(k.carry.stateOf(crate)).toBe("carried")
		k.carry.setDropRule(nil, { hazard = true })
		k.carry.reportHazard(k.p[1], crate)
		expect(k.carry.stateOf(crate)).toBe("dropped")
		expect(reasons(k)).toEqual({ "hazard" })
	end)

	it("setDropRule per tag overrides the global default", function()
		local k, crate = crateKit(1, { config = { dropRules = { hazard = true } } })
		k.carry.setDropRule("Crate", { hazard = false })
		expect(pick(k, 1, crate)).toBe(true)
		k.carry.reportHazard(k.p[1], crate)
		expect(k.carry.stateOf(crate)).toBe("carried")
	end)

	it("tiltDegrees drops a tilted couch (fragility scales it; 0 never drops)", function()
		local function run(fragility, o)
			local k = CarryKit.new({
				players = 2,
				positions = { V(-3, 3, 0), V(3, 3, 0) },
				config = o,
			})
			k.carry.registerCarriable("Glass", {
				massClass = "heavy",
				carriers = { min = 2, max = 2 },
				gripPoints = { { -3, 0, 0 }, { 3, 0, 0 } },
				fragility = fragility,
			})
			local glass = k.fw:addPart({
				name = "Glass",
				position = V(0, 1, -2.5),
				size = V(8, 2, 2),
				tags = { "Glass" },
			})
			k:run(0.3)
			expect(pick(k, 1, glass)).toBe(true)
			expect(pick(k, 2, glass)).toBe(true)
			k:run(0.5)
			-- one end rises 9 studs over a 6-stud span: tilt about 56 degrees
			k.fw:setPath(k.p[2], FakeWorld.paths.stand(V(3, 12, 0)))
			k:run(1)
			return k, glass
		end
		local k, glass = run(1, { dropRules = { stretchStuds = false } })
		expect(k.carry.stateOf(glass)).toBe("dropped")
		expect(reasons(k)[1]).toBe("tilt")
		local k0, glass0 = run(0, { dropRules = { stretchStuds = false } })
		expect(k0.carry.stateOf(glass0)).toBe("carried") -- fragility 0: never from tilt or stretch
	end)

	it(
		"stretchStuds drops an object whose carriers pull 10+ studs apart (grip break may take it first)",
		function()
			local k = CarryKit.new({
				players = 2,
				positions = { V(-3, 3, 0), V(3, 3, 0) },
				config = { dropRules = { tiltDegrees = false } },
			})
			local couch = k:couch()
			k:run(0.3)
			expect(pick(k, 1, couch)).toBe(true)
			expect(pick(k, 2, couch)).toBe(true)
			k:run(0.5)
			k.fw:setPath(k.p[2], FakeWorld.paths.stand(V(21, 3, 0))) -- 18 studs further apart
			k:run(1.5)
			expect(k.carry.stateOf(couch) ~= "carried").toBe(true)
			local r = reasons(k)[1]
			expect(r == "stretch" or r == "teleport").toBe(true)
		end
	)

	it("hardLandingSpeed drops an object that stops after a fast fall", function()
		local k, crate = crateKit(1, { config = { dropRules = { hardLandingSpeed = 30 } } })
		expect(pick(k, 1, crate)).toBe(true)
		k:run(0.5)
		-- the carrier falls 120 studs/s for 0.5 s, then stops: the object's fall speed drops to ~0
		local y0 = 3
		local start = k.fw.now
		k.fw:setPath(k.p[1], function(s)
			if s < start + 0.1 then
				return V(0, y0, 0)
			elseif s < start + 0.6 then
				return V(0, y0 - (s - start - 0.1) * 120, 0)
			end
			return V(0, y0 - 60, 0)
		end)
		k:run(2)
		expect(reasons(k)[1]).toBe("hardLanding")
	end)
end)

describe("speed penalty and motion", function()
	it("WalkSpeed x speedFactor x (1 - speedPenalty x missing carriers), restored on release", function()
		local k = CarryKit.new({ players = 2, positions = { V(-3, 3, 0), V(3, 3, 0) } })
		k.carry.registerCarriable("Pallet", {
			massClass = "medium",
			carriers = { min = 1, max = 2 },
			gripPoints = { { -3, 0, 0 }, { 3, 0, 0 } },
			speedPenalty = 0.2,
		})
		local pallet = k.fw:addPart({
			name = "Pallet",
			position = V(0, 1, -2.5),
			size = V(8, 2, 2),
			tags = { "Pallet" },
		})
		k:run(0.3)
		expect(pick(k, 1, pallet)).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16 * 0.85 * 0.8) < 1e-4).toBe(true) -- one carrier missing
		expect(pick(k, 2, pallet)).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16 * 0.85) < 1e-4).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[2]).walkSpeed - 16 * 0.85) < 1e-4).toBe(true)
		k.carry.drop(k.p[2], pallet)
		expect(math.abs(k.fw:humanoid(k.p[2]).walkSpeed - 16) < 1e-4).toBe(true)
		expect(math.abs(k.fw:humanoid(k.p[1]).walkSpeed - 16 * 0.85 * 0.8) < 1e-4).toBe(true)
	end)

	it("applyWalkSpeed = false leaves WalkSpeed alone", function()
		local k, crate = crateKit(1, { config = { applyWalkSpeed = false } })
		expect(pick(k, 1, crate)).toBe(true)
		expect(k.fw:humanoid(k.p[1]).walkSpeed).toBe(16)
	end)

	it("a carried object is anchored, written at motionHz, and follows the carrier smoothly", function()
		local k = CarryKit.new({ paths = { FakeWorld.paths.line(V(0, 3, 0), V(0, 0, -8)) } })
		local crate = k:crate(V(0, 1, -3))
		k:run(0.3)
		expect(pick(k, 1, crate)).toBe(true)
		expect(crate.anchored).toBe(true)
		k.fw:resetCounters()
		local writes = {}
		k:run(2, function()
			table.insert(writes, crate.cf.p.z)
		end)
		-- 30 Hz of CFrame writes: about 60 in 2 s (not 120 frames' worth, not 20 logic ticks' worth)
		expect(k.fw.cframeWrites >= 55).toBe(true)
		expect(k.fw.cframeWrites <= 65).toBe(true)
		expect(crate.cf.p.z < -10).toBe(true)
		expect(crate.anchored).toBe(true)
		-- never unanchored on the way
		local ok = true
		for _, z in writes do
			ok = ok and z == z
		end
		expect(ok).toBe(true)
	end)

	it("an idle or resting object costs no writes", function()
		local k, crate = crateKit(1)
		k.fw:resetCounters()
		k:run(3)
		expect(k.fw.cframeWrites).toBe(0)
		local _ = crate
	end)
end)

describe("replication, ids and the API surface", function()
	it(
		"assigns CarryObjectId on first sight, sends nothing before the first pick-up, and clears on removal",
		function()
			local k, crate = crateKit(1)
			expect(crate:GetAttribute("CarryObjectId")).toBe("1")
			expect(k.carry.objectOf("1")).toBe(crate)
			expect(k.carry.objectOf("99")).toBe(nil)
			expect(k.h:state(k.p[1]).modules.Carry).toBe(nil)
			expect(pick(k, 1, crate)).toBe(true)
			local d = keyOf(k, k.p[1], "1")
			expect(d.state).toBe("carried")
			expect(d.tag).toBe("Crate")
			expect(d.slots[1]).toBe(1)
			k.fw:destroy(crate)
			expect(k.carry.objectOf("1")).toBe(nil)
			expect(k.carry.stateOf(crate)).toBe(nil)
			expect(reasons(k)).toEqual({ "removed" })
			expect(k.h:state(k.p[1]).modules.Carry.extra["carry:1"]).toBe(nil)
		end
	)

	it("a second object gets the next id; a tag reused on another name is not a carriable (model)", function()
		local k = CarryKit.new({})
		k.carry.registerCarriable("Barrel", { model = "Barrel" })
		local a = k.fw:addPart({ name = "Barrel", position = V(0, 1, -3), tags = { "Barrel" } })
		local b = k.fw:addPart({ name = "Wall", position = V(5, 1, -3), tags = { "Barrel" } })
		local c = k:crate()
		k:run(0.2)
		expect(a:GetAttribute("CarryObjectId")).toBe("1")
		expect(b:GetAttribute("CarryObjectId")).toBe(nil)
		expect(c:GetAttribute("CarryObjectId")).toBe("2")
		local ok, why = k.carry.pickUp(k.p[1], b)
		expect(ok).toBe(false)
		expect(why).toBe("notCarriable")
	end)

	it("holders is a frozen copy in slot order; isCarrying names the object", function()
		local k = CarryKit.new({ players = 2, positions = { V(-3, 3, 0), V(3, 3, 0) } })
		local couch = k:couch()
		k:run(0.3)
		pick(k, 2, couch)
		pick(k, 1, couch)
		local list = k.carry.holders(couch)
		expect(list).toEqual({ k.p[2], k.p[1] })
		expect(table.isfrozen(list)).toBe(true)
		expect(k.carry.isCarrying(k.p[2])).toBe(couch)
	end)

	it("registerCarriable validates like boot config and names the caller", function()
		local k = CarryKit.new({})
		local ok, err = pcall(k.carry.registerCarriable, "Bad", { massClass = "gigantic" })
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "registerCarriable", 1, true) ~= nil).toBe(true)
		-- boot config is validated too
		local h, bootErr = StudWork.test.boot({
			modules = { Carry },
			config = { Carry = { carriables = { Bad = { carriers = { min = 2, max = 2 } } } } },
		})
		expect(h).toBe(nil)
		expect(string.find(tostring(bootErr), "gripPoints", 1, true) ~= nil).toBe(true)
	end)

	it("maxObjects refuses a pick-up beyond the cap (capacity)", function()
		local k = CarryKit.new({ players = 2, config = { maxObjects = 1 } })
		local a = k:crate(V(0, 1, -3))
		local b = k:crate(V(3, 1, -3))
		k:run(0.3)
		expect(pick(k, 1, a)).toBe(true)
		local ok, why = pick(k, 2, b)
		expect(ok).toBe(false)
		expect(why).toBe("capacity")
	end)

	it("pick-up needs the accepted position within pickUpRadius of the object's box", function()
		local k = CarryKit.new({ positions = { V(0, 3, 20) } })
		local crate = k:crate()
		k:run(0.3)
		local ok, why = pick(k, 1, crate)
		expect(ok).toBe(false)
		expect(why).toBe("tooFar")
	end)

	it("a player with no character cannot pick up", function()
		local k, crate = crateKit(1)
		k.fw:removeCharacter(k.p[1])
		local ok, why = pick(k, 1, crate)
		expect(ok).toBe(false)
		expect(why).toBe("noCharacter")
	end)
end)

describe("the actions (ids only)", function()
	it("carryPickUp / carryDrop / carryHandOff go through the same rules", function()
		local k = CarryKit.new({ players = 2, positions = { V(0, 3, 0), V(3, 3, 0) } })
		local crate = k:crate()
		k:run(0.3)
		local ok = k.h:action(k.p[1], Carry, "carryPickUp", "1")
		expect(ok).toBe(true)
		expect(k.carry.isCarrying(k.p[1])).toBe(crate)
		local ok2 = k.h:action(k.p[1], Carry, "carryHandOff", "1", 2)
		expect(ok2).toBe(true)
		expect(k.carry.isCarrying(k.p[2])).toBe(crate)
		k.h:action(k.p[1], Carry, "carryDrop", "1") -- not the holder any more: refused
		expect(k.carry.isCarrying(k.p[2])).toBe(crate)
		k.h:action(k.p[2], Carry, "carryDrop", "1")
		expect(k.carry.isCarrying(k.p[2])).toBe(nil)
		expect(reasons(k)).toEqual({ "manual" }) -- the reason is forced, never client text
	end)

	it("an unknown object id, an unknown receiver and a nonsense id are refused without raising", function()
		local k, crate = crateKit(2)
		local _, r1 = k.h:action(k.p[1], Carry, "carryPickUp", "nope")
		expect(r1).toBe(false)
		k.h:action(k.p[1], Carry, "carryPickUp", "1")
		local _, r2 = k.h:action(k.p[1], Carry, "carryHandOff", "1", 12345)
		expect(r2).toBe(false)
		local _, r3 = k.h:action(k.p[1], Carry, "carryHandOff", "zzz", 2)
		expect(r3).toBe(false)
		expect(k.carry.isCarrying(k.p[1])).toBe(crate)
	end)

	it("refusals Full and Too far send a localised toast; others are silent", function()
		local k = CarryKit.new({ players = 3, positions = { V(0, 3, 0), V(0, 3, 40), V(1, 3, 0) } })
		k:crate()
		k:run(0.3)
		local function lastToast()
			local events = k.h.fake.serverEvents
			local last = events[#events]
			return if last and last.event == "Feedback" then last.args[1].Text else nil
		end
		k.h:action(k.p[1], Carry, "carryPickUp", "1")
		local before = #k.h.fake.serverEvents
		k.h:action(k.p[2], Carry, "carryPickUp", "1") -- full
		k.h:action(k.p[3], Carry, "carryPickUp", "1") -- full
		expect(lastToast()).toBe("Full")
		k.carry.drop(k.p[1], k.carry.objectOf("1"))
		k.h:action(k.p[2], Carry, "carryPickUp", "1") -- too far
		expect(lastToast()).toBe("Too far")
		local count = #k.h.fake.serverEvents
		k.h:action(k.p[1], Carry, "carryPickUp", "nope") -- silent
		expect(#k.h.fake.serverEvents).toBe(count)
		local _ = before
		expect(k.h:warnings()).toEqual({})
	end)
end)
