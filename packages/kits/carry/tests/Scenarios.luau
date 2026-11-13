--!nocheck
--[[
	Scenarios: shared helpers for the carry sims (CheatSims, LegitSims, CarrySims) and the bench variant.
	Not a spec. Owner: sims builder (D).

	Everything runs on FakeWorld with the latency model. Unlike MovementRig (Movement only) and CarryKit (Carry with
	a stand-in Movement), `Scenarios.rig` boots the REAL Movement and the REAL Carry together, the way a game does:

	  local rig = S.rig({ movement = { responses = { teleport = "strike" } }, carry = { ... }, seed = 1 })
	  local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), jitter = S.jitter.rtt300, ping = 0.3 })
	  rig:run(10)
	  rig:count(p, "teleport")          -- strikes of one reason (rig:reasons(p), rig:strikes(p))
	  rig:events("Dropped")             -- Carry signal log, in order
	  rig.mv / rig.carry                -- the two APIs (rig.mv is nil with `movement = false`)

	`movement = false` boots Carry alone (Movement absent); `movement = {}` boots it at the defaults.
	Paths: S.walk, S.jumper, S.ledge, S.stopAndGo, S.platformRider, S.teleporting. Jitter presets: S.jitter.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")
local CF = require("packages/kits/carry/Carry/shared/CF.luau")
local MovementRig = require("packages/kits/carry/tests/MovementRig.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Carry = require(Modules:WaitForChild("Carry"):WaitForChild("module"))
local Movement = require(Modules:WaitForChild("Movement"):WaitForChild("module"))

local V = vector.create
local G = 196.2

local S = {}
S.V, S.CF, S.G, S.FakeWorld = V, CF, G, FakeWorld
S.Carry, S.Movement = Carry, Movement
S.lcg = MovementRig.lcg

-- jitter presets --------------------------------------------------------------------------------------------------------
S.jitter = {
	rtt300 = FakeWorld.jitter.rtt300, -- the probe's: 0.1-0.3 s freezes (0.5 s one in five)
	none = nil,
	-- a freeze every 0.5-3 s, all of them 0.5 s (the low-ping stop-and-go case)
	spiky = {
		firstMin = 0.5,
		firstSpan = 1,
		longChance = 1,
		long = 0.5,
		min = 0.5,
		span = 0,
		gapMin = 0.5,
		gapSpan = 2.5,
	},
}

-- paths (client position at client time s) --------------------------------------------------------------------------------

-- a straight walk along +X at `speed` studs/s
S.walk = MovementRig.walk
S.stand = FakeWorld.paths.stand
S.stopAndGo = MovementRig.stopAndGo
S.spawnWalk = MovementRig.spawnWalk
S.ledge = MovementRig.ledge

-- walks +X and jumps every 1.2-2.5 s
S.jumper = MovementRig.jumper

-- `path` shifted by `delta` from client time `atS` on (a scripted teleport)
S.teleporting = FakeWorld.paths.teleportAt

-- stands on a platform moving +X at `platformSpeed`, optionally walking `walkSpeed` along +Z (capped at `halfWidth`)
function S.platformRider(start, platformSpeed, walkSpeed, halfWidth)
	return function(s)
		local z = if walkSpeed then math.min(walkSpeed * s, halfWidth or 6) else 0
		return V(start.x + platformSpeed * s, start.y, start.z + z)
	end
end

-- a moving platform part: `rig:box` options for an anchored tagged part moving +X at `speed`
function S.platform(rig, tag, speed, y)
	local motion = function(t)
		return CF.new(V(speed * t, y or 4, 0))
	end
	return rig:box(V(0, y or 4, 0), V(4000, 2, 20), { tag }, { motion = motion })
end

-- fixtures ---------------------------------------------------------------------------------------------------------------
S.CARRIABLES = {
	Crate = { massClass = "medium", carriers = { min = 1, max = 1 }, gripPoints = { { 0, 0, 0 } } },
	Couch = {
		massClass = "heavy",
		carriers = { min = 2, max = 4 },
		gripPoints = { { -3, 0, 0 }, { 3, 0, 0 }, { -3, 0, 2 }, { 3, 0, 2 } },
	},
}

-- rig --------------------------------------------------------------------------------------------------------------------
local Rig = {}
Rig.__index = Rig

--[[
	opts: movement (config table | false), carry (config overrides, merged over { carriables = S.CARRIABLES }),
	seed, ground (top Y of the flat ground, default 0; false = none), gravity, killY, flags, isStudio, fw
]]
function S.rig(opts)
	opts = opts or {}
	local fwOpts = { seed = opts.seed or 1, gravity = opts.gravity, killY = opts.killY }
	for k, v in opts.fw or {} do
		fwOpts[k] = v
	end
	local self = setmetatable({
		fw = FakeWorld.new(fwOpts),
		log = {}, -- Carry signal events { name, args }
		strikeLog = {},
		crossLog = {},
		disqualified = {},
		players = {},
	}, Rig)
	if opts.ground ~= false then
		self.fw:addGround(opts.ground or 0, 32768)
	end
	local carryConfig = { carriables = S.CARRIABLES }
	for k, v in opts.carry or {} do
		carryConfig[k] = v
	end
	local boot = { config = { Carry = carryConfig }, flags = opts.flags, isStudio = opts.isStudio }
	if opts.movement == false then
		boot.modules = { Carry }
	else
		boot.modules = { Movement, Carry }
		boot.config.Movement = opts.movement or {}
	end
	self.h = StudWork.test.harness(boot)
	self.carry = self.h:use(Carry)
	self.carry.useWorld(self.fw.world)
	for _, name in { "PickedUp", "Dropped", "HandedOff", "Delivered", "Returned" } do
		self.carry.signals[name]:Connect(function(...)
			table.insert(self.log, { name = name, args = { ... } })
		end)
	end
	if opts.movement ~= false then
		self.mv = self.h:use(Movement)
		self.mv.useWorld(self.fw.world)
		self.mv.signals.Strike:Connect(function(player, reason, details)
			table.insert(self.strikeLog, { player = player, reason = reason, details = details })
		end)
		self.mv.signals.VolumeCrossed:Connect(function(player, kind, volume)
			table.insert(self.crossLog, { player = player, kind = kind, volume = volume })
		end)
		self.mv.signals.RunDisqualified:Connect(function(player, runId, reason)
			table.insert(self.disqualified, { player = player, runId = runId, reason = reason })
		end)
	end
	return self
end

-- add a player to the harness and the FakeWorld; `o` is FakeWorld's addPlayer options
function Rig:player(userId, o)
	local p = self.h:addPlayer({ userId = userId })
	self.fw:addPlayer(p, o or {})
	table.insert(self.players, p)
	return p
end

function Rig:run(seconds, each)
	self.fw:run(self.h, seconds, each)
end

-- frames until pred() is true (checked every frame) or `maxSeconds` pass; returns the sim time it became true
function Rig:runUntil(maxSeconds, pred)
	for _ = 1, math.floor(maxSeconds * 60 + 0.5) do
		if pred() then
			return self.fw.now
		end
		self.fw:frame(self.h, 1 / 60)
	end
	return if pred() then self.fw.now else nil
end

function Rig:hitch(seconds)
	self.fw:hitch(self.h, seconds)
end

-- `seconds` with a 0.45 s server hitch every ~15-25 s (the design probe's)
function Rig:runWithHitches(seconds, seed)
	local r = S.lcg((seed or 1) + 500)
	local nextHitch = self.fw.now + 10 + r() * 10
	local t = 0
	while t < seconds do
		if self.fw.now >= nextHitch then
			self:hitch(0.45)
			t += 0.45
			nextHitch = self.fw.now + 15 + r() * 10
		else
			self:run(1 / 60)
			t += 1 / 60
		end
	end
end

function Rig:strikes(player)
	return if self.mv then self.mv.strikes(player) else {}
end

function Rig:reasons(player)
	local out = {}
	for _, s in self:strikes(player) do
		table.insert(out, s.reason)
	end
	return out
end

function Rig:count(player, reason, filter)
	local n = 0
	for _, s in self:strikes(player) do
		if (reason == nil or s.reason == reason) and (filter == nil or filter(s)) then
			n += 1
		end
	end
	return n
end

function Rig:trusted(player)
	local _, t = self.mv.lastValid(player)
	return t
end

-- the Carry signal events named `name`, in order
function Rig:events(name)
	local out = {}
	for _, e in self.log do
		if e.name == name then
			table.insert(out, e)
		end
	end
	return out
end

-- the reasons of every Dropped event, in order
function Rig:dropReasons()
	local out = {}
	for _, e in self:events("Dropped") do
		table.insert(out, e.args[2])
	end
	return out
end

function Rig:box(position, size, tags, extra)
	local o = { position = position, size = size, tags = tags }
	for k, v in extra or {} do
		o[k] = v
	end
	return self.fw:addPart(o)
end

function Rig:crate(position, name)
	return self.fw:addPart({
		name = name or "Crate",
		position = position or V(0, 1, -3),
		size = V(2, 2, 2),
		tags = { "Crate" },
	})
end

function Rig:couch(position)
	return self.fw:addPart({
		name = "Couch",
		position = position or V(0, 1, -2.5),
		size = V(8, 2, 2),
		tags = { "Couch" },
	})
end

function Rig:zone(position, size)
	return self.fw:addPart({
		name = "Zone",
		position = position,
		size = size or V(30, 10, 30),
		tags = { "CarryDelivery" },
		canCollide = false,
	})
end

-- run until every player is trusted (Movement) and Carry has ticked: pick-ups need an accepted position
function Rig:settle()
	self:run(0.6)
end

S.Rig = Rig
return S
