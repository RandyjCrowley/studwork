--!nocheck
--[[
	MovementRig: scenario helpers for the Movement specs (booting the REAL Movement part under the harness on
	FakeWorld). Not a spec. Owner: Movement builder (the sims builder has its own Scenarios.luau).

	  local rig = Rig.new({ config = { response = "strike" }, ground = 0, seed = 1 })
	  local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16), jitter = FakeWorld.jitter.rtt300, ping = 0.3 })
	  rig:run(10)
	  rig:strikesOf(p)       -- every recorded strike of player p (reasons through rig:reasons(p))
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")
local CF = require("packages/kits/carry/Carry/shared/CF.luau")

local Movement =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Movement"):WaitForChild("module"))

local V = vector.create
local G = 196.2

local Rig = {}
Rig.__index = Rig
Rig.V = V
Rig.FakeWorld = FakeWorld
Rig.CF = CF

-- paths ---------------------------------------------------------------------------------------------

-- straight walk along +X at `speed` from `start`
function Rig.walk(start, speed)
	return FakeWorld.paths.line(start, V(speed, 0, 0))
end

local function lcg(seed)
	local s = seed * 7919 + 17
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end
Rig.lcg = lcg

-- stands 4.5-6 s, walks 1-3 s along +X, repeating (the empty-window case)
function Rig.stopAndGo(seed, start, speed, duration)
	local r = lcg(seed + 1000)
	local segs = {} -- { t0, t1, x0, moving }
	local t, x = 0, start.x
	local standing = true
	while t < duration + 10 do
		local len = if standing then 4.5 + r() * 1.5 else 1 + r() * 2
		table.insert(segs, { t, t + len, x, not standing })
		if not standing then
			x += speed * len
		end
		t += len
		standing = not standing
	end
	return function(s)
		for _, seg in segs do
			if s < seg[2] then
				local dx = if seg[4] then speed * math.max(0, s - seg[1]) else 0
				return V(seg[3] + dx, start.y, start.z)
			end
		end
		return V(x, start.y, start.z)
	end
end

-- a fresh spawn at `spawn` (above the floor; root rests at restY): the client falls to it, then walks +X.
-- `t0` is the time the character was spawned (paths are in absolute client time)
function Rig.spawnWalk(spawn, restY, speed, t0)
	return function(s)
		local u = math.max(0, s - t0)
		local y = math.max(restY, spawn.y - 0.5 * G * u * u)
		return V(spawn.x + speed * u, y, spawn.z)
	end
end

-- walks +X and jumps every 1.2-2.5 s (a jump: v 50, gravity 196.2)
function Rig.jumper(seed, start, speed)
	local r = lcg(seed + 2000)
	local jumps = {}
	local t = 1 + r()
	for _ = 1, 400 do
		table.insert(jumps, t)
		t += 1.2 + r() * 1.3
	end
	return function(s)
		local y = start.y
		for _, j in jumps do
			if s >= j and s < j + 2 * 50 / G then
				local u = s - j
				y = start.y + 50 * u - 0.5 * G * u * u
				break
			end
		end
		return V(start.x + speed * s, y, start.z)
	end
end

-- walks +X off an edge at x = edgeX and falls `drop` studs (landing on a lower floor placed by the caller)
function Rig.ledge(start, speed, edgeX, drop)
	local tEdge = (edgeX - start.x) / speed
	local tLand = tEdge + math.sqrt(2 * drop / G)
	return function(s)
		local x = start.x + speed * s
		if s <= tEdge then
			return V(x, start.y, start.z)
		elseif s >= tLand then
			return V(x, start.y - drop, start.z)
		end
		local u = s - tEdge
		return V(x, start.y - 0.5 * G * u * u, start.z)
	end
end

-- rig ----------------------------------------------------------------------------------------------

--[[
	opts: config (Movement config overrides), ground (top Y of a flat ground, default 0; false = none),
	seed, gravity, flags, isStudio, fw (FakeWorld.new options merged)
]]
function Rig.new(opts)
	opts = opts or {}
	local fwOpts = { seed = opts.seed or 1, gravity = opts.gravity, killY = opts.killY }
	for k, v in opts.fw or {} do
		fwOpts[k] = v
	end
	local self = setmetatable({
		fw = FakeWorld.new(fwOpts),
		strikeLog = {}, -- { player, reason, details }
		crossLog = {}, -- { player, kind, volume }
		disqualified = {},
		players = {},
	}, Rig)
	if opts.ground ~= false then
		self.fw:addGround(opts.ground or 0, 32768) -- wide enough for a 60 s run at 32 studs/s
	end
	self.h = StudWork.test.harness({
		modules = { Movement },
		config = { Movement = opts.config or {} },
		flags = opts.flags,
		isStudio = opts.isStudio,
	})
	self.api = self.h:use(Movement)
	self.api.useWorld(self.fw.world)
	self.api.signals.Strike:Connect(function(player, reason, details)
		table.insert(self.strikeLog, { player = player, reason = reason, details = details })
	end)
	self.api.signals.VolumeCrossed:Connect(function(player, kind, volume)
		table.insert(self.crossLog, { player = player, kind = kind, volume = volume })
	end)
	self.api.signals.RunDisqualified:Connect(function(player, runId, reason)
		table.insert(self.disqualified, { player = player, runId = runId, reason = reason })
	end)
	return self
end

-- add a player to both the harness and the FakeWorld; `o` is FakeWorld's addPlayer options (+ userId)
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
	local frames = math.floor(maxSeconds * 60 + 0.5)
	for _ = 1, frames do
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

function Rig:strikesOf(player)
	return self.api.strikes(player)
end

function Rig:reasons(player)
	local out = {}
	for _, s in self.api.strikes(player) do
		table.insert(out, s.reason)
	end
	return out
end

function Rig:count(player, reason, filter)
	local n = 0
	for _, s in self.api.strikes(player) do
		if (reason == nil or s.reason == reason) and (filter == nil or filter(s)) then
			n += 1
		end
	end
	return n
end

-- a thin world part: position + size; `tags`
function Rig:box(position, size, tags, extra)
	local o = { position = position, size = size, tags = tags }
	for k, v in extra or {} do
		o[k] = v
	end
	return self.fw:addPart(o)
end

return Rig
