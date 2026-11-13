--!nocheck
--[[
	An unchanged pose costs no write (review M2, carry.md "Object motion" step 6): a carried object whose clamped
	pose stays within the pose epsilon of its target keeps prev/target/tickAt/dirty, so a lerp in progress
	finishes and then writes stop; a real change writes again. FakeWorld counts CFrame writes.
]]
local CarryKit = require("packages/kits/carry/tests/CarryKit.luau")
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")

local V = CarryKit.V

local function pick(k, i, obj)
	local ok = k.carry.pickUp(k.p[i], obj)
	expect(ok).toBe(true)
end

-- a crate carried by one player on `path`, picked up and the first logic ticks done
local function soleCarrier(path)
	local k = CarryKit.new({ paths = { path } })
	local crate = k:crate(V(0, 1, -3))
	k:run(0.3)
	pick(k, 1, crate)
	return k, crate
end

describe("a held-still carried object is not rewritten", function()
	it("a sole carrier standing still: 0 writes over 10 s, after the pick-up lerp", function()
		local k, crate = soleCarrier(FakeWorld.paths.stand(V(0, 3, 0)))
		k:run(1) -- the in-progress lerp (if any) finishes
		k.fw:resetCounters()
		k:run(10)
		expect(k.fw.cframeWrites).toBe(0)
		expect(crate.anchored).toBe(true)
		expect(k.carry.stateOf(crate)).toBe("carried")
	end)

	it("a two-carrier object held still: 0 writes over 10 s", function()
		local k = CarryKit.new({ players = 2 })
		local couch = k:couch()
		k:run(0.3)
		pick(k, 1, couch)
		pick(k, 2, couch)
		k:run(1)
		k.fw:resetCounters()
		k:run(10)
		expect(k.fw.cframeWrites).toBe(0)
		expect(k.carry.stateOf(couch)).toBe("carried")
	end)

	it("a lerp in progress finishes at the target when the carrier stops, then writes stop", function()
		local k, crate = soleCarrier(FakeWorld.paths.line(V(0, 3, 0), V(0, 0, -8)))
		k:run(2)
		-- stop where the carrier is now
		local at = k.fw:truePosition(k.p[1])
		k.fw:setPath(k.p[1], FakeWorld.paths.stand(at))
		k:run(2) -- the carrier's last moves reach the server, the lerp ends
		local settledAt = crate.cf.p
		k.fw:resetCounters()
		k:run(5)
		expect(k.fw.cframeWrites).toBe(0)
		expect(vector.magnitude(crate.cf.p - settledAt)).toBeNear(0, 1e-9)
	end)

	it("walking again resumes the writes and the object follows", function()
		local k, crate = soleCarrier(FakeWorld.paths.stand(V(0, 3, 0)))
		k:run(2)
		k.fw:resetCounters()
		k:run(2)
		expect(k.fw.cframeWrites).toBe(0)
		local from = crate.cf.p
		k.fw:setPath(k.p[1], FakeWorld.paths.line(k.fw:truePosition(k.p[1]), V(0, 0, -8), k.fw.now))
		k:run(2)
		expect(k.fw.cframeWrites >= 40).toBe(true)
		expect(from.z - crate.cf.p.z > 10).toBe(true)
	end)

	it("jitter below the epsilon doesn't write; a pose change just above it does", function()
		local base = V(0, 3, 0)
		local jitter = 0.0004 -- studs, well under the 0.002 epsilon
		local mode = "jitter"
		local stepAt = 0
		local path = function(s)
			if mode == "step" and s >= stepAt then
				return base + V(0.01, 0, 0)
			end
			return base + V(jitter * math.sin(s * 7), 0, jitter * math.cos(s * 5))
		end
		local k, crate = soleCarrier(path)
		k:run(2)
		k.fw:resetCounters()
		k:run(10)
		expect(k.fw.cframeWrites).toBe(0)
		local before = crate.cf.p
		-- just above the epsilon: a 0.01-stud shift of the carrier (FakeWorld turns a moving player to face the
		-- move, so the held pose changes in position and heading together)
		mode, stepAt = "step", k.fw.now
		k:run(2)
		expect(k.fw.cframeWrites >= 1).toBe(true)
		expect(vector.magnitude(crate.cf.p - before) > 0.005).toBe(true)
		-- and it is quiet again afterwards
		k.fw:resetCounters()
		k:run(3)
		expect(k.fw.cframeWrites).toBe(0)
	end)
end)
