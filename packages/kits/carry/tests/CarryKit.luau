--!nocheck
--[[
	CarryKit: shared setup for Carry's specs: a FakeWorld, a harness with Carry (and optionally a stand-in
	Movement), players on scripted paths, and the standard fixtures (a crate, a couch, a delivery zone).

	  local k = CarryKit.new({ movement = true, config = { dropRules = {...} }, players = 2 })
	  k.fw, k.h, k.carry, k.mv, k.p[1], k.log (signal events in order)
	  k:crate(position?) / k:couch(position?) / k:zone(position, size)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")
local CarryFakeMovement = require("packages/kits/carry/tests/CarryFakeMovement.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Carry = require(Modules:WaitForChild("Carry"):WaitForChild("module"))
local Movement = require(Modules:WaitForChild("Movement"):WaitForChild("module"))

local V = vector.create

local CarryKit = {}
CarryKit.Carry = Carry
CarryKit.Movement = Movement
CarryKit.V = V

local CARRIABLES = {
	Crate = { massClass = "medium", carriers = { min = 1, max = 1 }, gripPoints = { { 0, 0, 0 } } },
	Anvil = { massClass = "heavy", carriers = { min = 1, max = 1 }, gripPoints = { { 0, 0, 0 } } },
	Couch = {
		massClass = "heavy",
		carriers = { min = 2, max = 4 },
		gripPoints = { { -3, 0, 0 }, { 3, 0, 0 }, { -3, 0, 2 }, { 3, 0, 2 } },
	},
}

function CarryKit.new(o)
	o = o or {}
	local k = { log = {} }
	local fw =
		FakeWorld.new({ seed = o.seed or 1, ground = if o.ground == false then nil else 0, killY = o.killY })
	k.fw = fw
	local config = { carriables = CARRIABLES }
	for key, value in o.config or {} do
		config[key] = value
	end
	local boot = { modules = { Carry }, config = { Carry = config } }
	if o.movement then
		k.mv = CarryFakeMovement.new(fw)
		boot.modules = { Movement, Carry }
		boot.servers = { Movement = k.mv.part }
	end
	for key, value in o.harness or {} do
		boot[key] = value
	end
	k.h = StudWork.test.harness(boot)
	k.carry = k.h:use(Carry)
	k.carry.useWorld(fw.world)

	for _, name in { "PickedUp", "Dropped", "HandedOff", "Delivered", "Returned" } do
		k.carry.signals[name]:Connect(function(...)
			table.insert(k.log, { name = name, args = { ... } })
		end)
	end

	k.p = {}
	for i = 1, o.players or 1 do
		local p = k.h:addPlayer({ userId = i })
		local at = (o.positions and o.positions[i]) or V((i - 1) * 3, 3, 0)
		fw:addPlayer(p, {
			path = (o.paths and o.paths[i]) or FakeWorld.paths.stand(at),
			jitter = o.jitter,
			ping = o.ping,
			walkSpeed = o.walkSpeed,
		})
		k.p[i] = p
	end

	function k:crate(position, name)
		return fw:addPart({
			name = name or "Crate",
			position = position or V(0, 1, -3),
			size = V(2, 2, 2),
			tags = { "Crate" },
		})
	end
	function k:anvil(position)
		return fw:addPart({
			name = "Anvil",
			position = position or V(0, 1, -3),
			size = V(2, 2, 2),
			tags = { "Anvil" },
		})
	end
	function k:couch(position)
		return fw:addPart({
			name = "Couch",
			position = position or V(0, 1, -2.5),
			size = V(8, 2, 2),
			tags = { "Couch" },
		})
	end
	function k:zone(position, size)
		return fw:addPart({
			name = "Zone",
			position = position,
			size = size or V(30, 10, 30),
			tags = { "CarryDelivery" },
			canCollide = false,
		})
	end
	-- the signal events named `name`, in order
	function k:events(name)
		local out = {}
		for _, e in self.log do
			if e.name == name then
				table.insert(out, e)
			end
		end
		return out
	end
	function k:run(seconds, each)
		fw:run(k.h, seconds, each)
	end
	-- let the ticker run until the first logic tick has happened
	function k:settle()
		fw:run(k.h, 0.5)
	end
	-- the tracked top speed (horizontal, studs/s) of a part's CFrame writes over `seconds`
	function k:topSpeed(part, seconds)
		local last = part.cf.p
		local top = 0
		fw:run(k.h, seconds, function()
			local p = part.cf.p
			local d = V(p.x - last.x, 0, p.z - last.z)
			top = math.max(top, vector.magnitude(d) * 60)
			last = p
		end)
		return top
	end
	return k
end

return CarryKit
