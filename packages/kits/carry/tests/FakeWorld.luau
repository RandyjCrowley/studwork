--!nocheck
--[[
	FakeWorld: the scriptable test World for the carry kit (docs/framework/kits/carry.md, "The World
	seam"). One fake serves both modules: `Movement.useWorld(fw.world)` / `Carry.useWorld(fw.world)`.

	  local fw = FakeWorld.new({ seed = 1, ground = 0, gravity = 196.2, killY = -500 })
	  fw:addPlayer(player, { path = FakeWorld.paths.line(vector.create(0, 3, 0), vector.create(16, 0, 0)),
	                         jitter = FakeWorld.jitter.rtt300, ping = 0.3 })
	  fw:run(h, 10)          -- 10 s in 1/60 s frames: advances this world's clock AND h:tick(frame)
	  fw:hitch(h, 0.45)      -- one 0.45 s frame (the shared ticker then bursts catch-up calls)

	A player is any token (a harness player works). The scripted CLIENT path is path(s) -> vector (or
	x, y, z), the true root at client time s; the server reads it through the latency model, ported
	from the design's latency probe (carry.md "Worked numbers"):
	  - the client sends a snapshot every 1/60 s; each arrives after `baseLatency` (default 0.15 s,
	    a 300 ms RTT connection) + 0..`noise` (0.05), delivered IN ORDER (replicated state never goes
	    back in time);
	  - a freeze holds every snapshot sent during [fs, fs+F] until fs+F+base (freeze-then-catch-up):
	    F is 0.1..0.3 s, or 0.5 s for one in five; the next one starts 0.5..3 s later. `jitter` = a
	    config table (FakeWorld.jitter.rtt300 is the probe's) or false/nil for none; fw:freeze(player, s)
	    scripts one now;
	  - world.rootOf(player) is the latest snapshot that has arrived (before the first arrival of a new
	    character: the engine's server-authored spawn placement). The path is evaluated only when read.
	Server writes (fw:serverMove, or the module's world.setRootCFrame) fire onServerMove at once; the
	client adopts the new position one `baseLatency` later, so snapshots sent before that are STALE
	(old position) and arrive first.

	World parts (fw:addPart): boxes with a CF and size; casts are analytic (ray / block vs OBB) with the
	engine's filter: a cast hits every canQuery part, colliding or not, unless the opts say
	respectCanCollide (then canCollide = false parts are skipped, like RaycastParams.RespectCanCollide);
	it honours exclude, a part's `ignoredBy` groups, and fw:setCollidable(groupA, groupB, false) against
	the opts' collisionGroup (a part in a group that doesn't collide with it is skipped); anchored parts with
	`motion(t) -> CF` follow it on every advance (moving platforms); tags fire onTagAdded/Removed;
	unanchored parts fall under gravity, land on anchored canCollide boxes (a part with CanCollide off
	falls THROUGH them, like the engine) and are destroyed below killY (fw.destroyed).

	Counters (fw.casts, fw.blockcasts, fw.cframeWrites): world.cast / world.blockcast / world.setCFrame +
	world.setRootCFrame calls by the module. fw:resetCounters() zeroes them. Nothing a spec scripts
	(fw:serverMove, motion) is counted.

	Everything here is deterministic (a seeded LCG per player).
]]

local CF = require("packages/kits/carry/Carry/shared/CF.luau")
local Jump = require("packages/kits/carry/Carry/shared/Jump.luau")

local FakeWorld = {}

local V = vector.create
local ZERO = V(0, 0, 0)
local STEP = 1 / 60 -- snapshot send interval and the physics step

-- jitter presets (the probe's model, `freezes` below) -----------------------------------------------
FakeWorld.jitter = {
	-- freeze-then-catch-up spikes 0.1..0.3 s (0.5 s one in five) every 0.5..3 s, first within 1..3 s
	rtt300 = {
		firstMin = 1,
		firstSpan = 2,
		longChance = 0.2,
		long = 0.5,
		min = 0.1,
		span = 0.2,
		gapMin = 0.5,
		gapSpan = 2.5,
	},
}

-- scripted client paths -----------------------------------------------------------------------------
FakeWorld.paths = {}

function FakeWorld.paths.stand(position)
	return function(_s)
		return position
	end
end

-- position + velocity * (s - fromS) for s >= fromS (before it: the start position)
function FakeWorld.paths.line(position, velocity, fromS)
	fromS = fromS or 0
	return function(s)
		return position + velocity * math.max(0, s - fromS)
	end
end

-- `path` shifted by `delta` from client time `atS` on (a scripted teleport)
function FakeWorld.paths.teleportAt(path, atS, delta)
	return function(s)
		local p = path(s)
		if type(p) == "number" then
			error("FakeWorld.paths.teleportAt needs a path that returns a vector")
		end
		return if s >= atS then p + delta else p
	end
end

-- deterministic RNG (the probe's LCG) -------------------------------------------------------------
local function rng(seed)
	local s = seed * 7919 + 17
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

-- a part (a fake Instance) ----------------------------------------------------------------------------
local Part = {}
Part.__index = Part

function Part:GetAttribute(name)
	return self.attributes[name]
end

function Part:IsA(className)
	return className == "BasePart" or className == self.ClassName or (className == "Model" and self.isModel)
end

function Part:HasTag(tag)
	return self.tags[tag] == true
end

function Part:inverse()
	if self._invFor ~= self.cf then
		self._inv = CF.inverse(self.cf)
		self._invFor = self.cf
	end
	return self._inv
end

-- ray / block vs OBB -------------------------------------------------------------------------------------
-- A ray (origin o, vector d, length |d|) against the box part grown by `grow` (a half-size vector for a
-- block cast, conservative for rotated blocks). Returns t in [0, 1], local axis index, sign; nil on a
-- miss or when the origin starts inside the box (the engine reports no hit for a part you start in).
local function rayBox(part, o, d, grow)
	local inv = part:inverse()
	local lo, ld = CF.pointTo(inv, o), CF.rotate(inv, d)
	local half = part.size * 0.5 + grow
	local tmin, tmax = 0, 1
	local axis, sign = nil, 0
	local inside = true
	local oc = { lo.x, lo.y, lo.z }
	local dc = { ld.x, ld.y, ld.z }
	local hc = { half.x, half.y, half.z }
	for i = 1, 3 do
		local oi, di, hi = oc[i], dc[i], hc[i]
		if oi < -hi or oi > hi then
			inside = false
		end
		if math.abs(di) < 1e-9 then
			if oi < -hi or oi > hi then
				return nil
			end
		else
			local t1, t2 = (-hi - oi) / di, (hi - oi) / di
			local s1 = -1 -- entering through the min face when di > 0
			if t1 > t2 then
				t1, t2 = t2, t1
				s1 = 1
			end
			if t1 > tmin then
				tmin, axis, sign = t1, i, s1
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	if inside or axis == nil then
		return nil
	end
	return tmin, axis, sign
end

local function blockGrow(cf, size)
	-- conservative: the block's half extents as seen along the world axes
	local r = cf.r
	local hx, hy, hz = size.x * 0.5, size.y * 0.5, size.z * 0.5
	return V(
		math.abs(r[1]) * hx + math.abs(r[2]) * hy + math.abs(r[3]) * hz,
		math.abs(r[4]) * hx + math.abs(r[5]) * hy + math.abs(r[6]) * hz,
		math.abs(r[7]) * hx + math.abs(r[8]) * hy + math.abs(r[9]) * hz
	)
end

-- FakeWorld.new -----------------------------------------------------------------------------------------
--[[
	opts: seed (1), gravity (196.2), killY (-500), ground (a top Y: adds a flat ground part; nil = none),
	baseLatency (0.15 one-way), noise (0.05), ping (0.3 reported round trip; per player override)
]]
function FakeWorld.new(opts)
	opts = opts or {}
	local fw = {
		now = 0,
		casts = 0,
		blockcasts = 0,
		cframeWrites = 0,
		kicked = {}, -- [player] = message
		parts = {},
		destroyed = {}, -- parts the "engine" destroyed below killY
		_gravity = opts.gravity or 196.2,
		_killY = opts.killY or -500,
		_seed = opts.seed or 1,
		_base = opts.baseLatency or 0.15,
		_noise = opts.noise or 0.05,
		_ping = opts.ping or 0.3,
		_states = {}, -- [player] = state
		_order = {},
		_tagAdded = {}, -- [tag] = { fn }
		_tagRemoved = {},
		_nextPart = 0,
		_noCollide = {}, -- [A][B] = true: collision groups A and B don't collide (both orders)
	}

	-- helpers ------------------------------------------------------------------------------------------
	local function stateOf(player)
		return fw._states[player]
	end

	local function fire(list, ...)
		if list == nil then
			return
		end
		for _, fn in table.clone(list) do
			fn(...)
		end
	end

	local function addHandler(map, key, fn)
		map[key] = map[key] or {}
		table.insert(map[key], fn)
		return function()
			local list = map[key]
			local at = table.find(list, fn)
			if at then
				table.remove(list, at)
			end
		end
	end

	local function asVector(a, b, c)
		if type(a) == "number" then
			return V(a, b, c)
		end
		return a
	end

	local function rawPos(st, s)
		local p = asVector(st.path(s))
		for _, m in st.moves do
			if s >= m.t then
				p = p + m.delta
			end
		end
		return p
	end

	local function newState(player, o)
		fw._order[#fw._order + 1] = player
		local st = {
			player = player,
			rng = rng(fw._seed + #fw._order),
			base = o.baseLatency or fw._base,
			noise = o.noise or fw._noise,
			freezes = o.jitter or nil,
			fs = -1,
			freezeEnd = -1,
			prevArr = 0,
			ping = o.ping or fw._ping,
			path = o.path or FakeWorld.paths.stand(ZERO),
			moves = {},
			S = {},
			A = {},
			head = 1,
			n = 0,
			sendBase = 0,
			sendK = 0,
			humanoid = {
				alive = true,
				walkSpeed = o.walkSpeed or 16,
				-- o.jumpVelocity directly, or the live adapter's formula on Humanoid-style options:
				-- useJumpPower (default true), jumpPower (50), jumpHeight (7.2)
				jumpVelocity = o.jumpVelocity or Jump.velocity(
					o.useJumpPower ~= false,
					o.jumpPower or 50,
					o.jumpHeight or 7.2,
					fw._gravity
				),
				hipHeight = o.hipHeight or 2,
				rootHalfHeight = o.rootHalfHeight or 1,
				state = "Running",
				collisionGroup = o.collisionGroup or "Default",
			},
			inWorkspace = true,
			handlers = { character = {}, move = {} },
			lastDir = V(0, 0, -1),
		}
		if st.freezes then
			st.nextFreeze = st.freezes.firstMin + st.rng() * st.freezes.firstSpan
		end
		return st
	end

	local function resetStream(st, from)
		st.S, st.A, st.head, st.n = {}, {}, 1, 0
		st.sendBase, st.sendK, st.prevArr = from, 0, 0
		st.fs, st.freezeEnd = -1, -1
	end

	-- send snapshots up to server time `now`, in the probe's order of rng draws
	local function generate(st, now)
		local f = st.freezes
		while true do
			local s = st.sendBase + st.sendK * STEP
			if s > now then
				break
			end
			st.sendK += 1
			if f and s >= st.nextFreeze and s > st.freezeEnd then
				local long = st.rng() < f.longChance
				local F = if long then f.long else f.min + st.rng() * f.span
				st.fs, st.freezeEnd = s, s + F
				st.nextFreeze = st.freezeEnd + f.gapMin + st.rng() * f.gapSpan
			end
			local arr = s + st.base + st.rng() * st.noise
			if s >= st.fs and s <= st.freezeEnd then
				arr = st.freezeEnd + st.base
			end
			arr = math.max(arr, st.prevArr)
			st.prevArr = arr
			local n = st.n + 1
			st.n = n
			st.S[n], st.A[n] = s, arr
		end
		-- in order: the current view is the last snapshot that has arrived
		while st.head < st.n and st.A[st.head + 1] <= now do
			st.head += 1
		end
		if st.head > 512 then
			local keep = st.n - st.head + 1
			table.move(st.S, st.head, st.n, 1)
			table.move(st.A, st.head, st.n, 1)
			for i = keep + 1, st.n do
				st.S[i], st.A[i] = nil, nil
			end
			st.n, st.head = keep, 1
		end
	end

	local function arrived(st)
		return st.n > 0 and st.A[st.head] <= fw.now
	end

	local function viewS(st)
		local s = st.S[st.head]
		if st.deadS and s > st.deadS then
			s = st.deadS
		end
		return s
	end

	local function rootCF(st)
		if st.character == nil or not st.inWorkspace then
			return nil
		end
		if not arrived(st) then
			return st.serverRoot
		end
		local s = viewS(st)
		local p = rawPos(st, s)
		local q0, q1 = rawPos(st, s - 0.05), rawPos(st, s + 0.05)
		local dir = V(q1.x - q0.x, 0, q1.z - q0.z)
		if vector.magnitude(dir) > 1e-3 and vector.magnitude(q1 - q0) < 5 then
			st.lastDir = dir
		end
		return CF.lookAlong(p, st.lastDir)
	end

	-- the World --------------------------------------------------------------------------------------------
	local world = {}
	fw.world = world

	function world.clock()
		return fw.now
	end

	function world.players()
		local out = {}
		for _, p in fw._order do
			if fw._states[p] then
				out[#out + 1] = p
			end
		end
		return out
	end

	function world.rootOf(player)
		local st = stateOf(player)
		if st == nil then
			return nil, nil
		end
		local cf = rootCF(st)
		if cf == nil then
			return nil, nil
		end
		return cf.p, cf
	end

	function world.humanoidFacts(player)
		local st = stateOf(player)
		if st == nil or st.character == nil then
			return nil
		end
		return table.clone(st.humanoid)
	end

	function world.seatOf(player)
		local st = stateOf(player)
		if st == nil or st.seat == nil or not st.seat.weld then
			return nil, nil
		end
		return st.seat.part, st.seat.part.cf
	end

	function world.ping(player)
		local st = stateOf(player)
		return if st then st.ping else 0
	end

	function world.gravity()
		return fw._gravity
	end

	function world.killY()
		return fw._killY
	end

	local function skipped(part, o)
		if not part.canQuery or part.destroyedAt ~= nil then
			return true
		end
		if o.respectCanCollide and not part.canCollide then
			return true
		end
		if o.exclude then
			for _, e in o.exclude do
				if e == part then
					return true
				end
			end
		end
		if
			o.collisionGroup
			and (part.ignoredBy[o.collisionGroup] or not fw:collidable(part.collisionGroup, o.collisionGroup))
		then
			return true
		end
		return false
	end

	local function castAgainst(origin, dir, grow, o)
		local best, bestPart, bestAxis, bestSign
		for _, part in fw.parts do
			if not skipped(part, o) then
				local t, axis, sign = rayBox(part, origin, dir, grow)
				if t and (best == nil or t < best) then
					best, bestPart, bestAxis, bestSign = t, part, axis, sign
				end
			end
		end
		if best == nil then
			return nil
		end
		local localNormal = if bestAxis == 1
			then V(bestSign, 0, 0)
			elseif bestAxis == 2 then V(0, bestSign, 0)
			else V(0, 0, bestSign)
		return {
			instance = bestPart,
			position = origin + dir * best,
			normal = CF.rotate(bestPart.cf, localNormal),
			distance = best * vector.magnitude(dir),
		}
	end

	function world.cast(origin, dir, o)
		fw.casts += 1
		return castAgainst(origin, dir, ZERO, o or {})
	end

	function world.blockcast(cf, size, dir, o)
		fw.blockcasts += 1
		-- the block starts at cf.p; its extent grows each target box (the Minkowski sum)
		return castAgainst(cf.p, dir, blockGrow(cf, size), o or {})
	end

	function world.boundsOf(inst)
		return inst.cf, inst.size
	end

	function world.surfaceVelocityOf(inst)
		return if inst.anchored then inst.surfaceVelocity else ZERO
	end

	function world.tagged(tag)
		local out = {}
		for _, part in fw.parts do
			if part.tags[tag] then
				out[#out + 1] = part
			end
		end
		return out
	end

	function world.onTagAdded(tag, fn)
		return addHandler(fw._tagAdded, tag, fn)
	end

	function world.onTagRemoved(tag, fn)
		return addHandler(fw._tagRemoved, tag, fn)
	end

	function world.onCharacter(player, fn)
		local st = stateOf(player)
		if st == nil then
			return function() end
		end
		table.insert(st.handlers.character, fn)
		return function()
			local at = table.find(st.handlers.character, fn)
			if at then
				table.remove(st.handlers.character, at)
			end
		end
	end

	function world.onServerMove(player, fn)
		local st = stateOf(player)
		if st == nil then
			return function() end
		end
		table.insert(st.handlers.move, fn)
		return function()
			local at = table.find(st.handlers.move, fn)
			if at then
				table.remove(st.handlers.move, at)
			end
		end
	end

	function world.setCFrame(inst, cf)
		fw.cframeWrites += 1
		inst.cf = cf
	end

	function world.setRootCFrame(player, cf)
		fw.cframeWrites += 1
		fw:serverMove(player, cf)
	end

	function world.anchor(inst)
		inst.anchored = true
	end

	function world.unanchor(inst)
		inst.anchored = false
		inst.networkOwner = nil
	end

	function world.setCollide(inst, on)
		inst.canCollide = on
	end

	function world.setQuery(inst, on)
		inst.canQuery = on
	end

	function world.setCollisionGroup(inst, group)
		inst.collisionGroup = group
	end

	function world.velocityOf(inst)
		return inst.velocity
	end

	function world.setVelocity(inst, v)
		inst.velocity = v
	end

	function world.setWalkSpeed(player, speed)
		local st = stateOf(player)
		if st then
			st.humanoid.walkSpeed = speed
		end
	end

	function world.setAttribute(inst, name, value)
		inst.attributes[name] = value
	end

	function world.kick(player, message)
		fw.kicked[player] = message
	end

	-- scripting: players and characters --------------------------------------------------------------------
	--[[
		fw:addPlayer(player, { path, jitter, ping, baseLatency, noise, walkSpeed, jumpVelocity (or useJumpPower,
		jumpPower, jumpHeight), hipHeight,
		rootHalfHeight, spawn (a vector: the character's starting root; default the path at s = 0) })
		Spawns a character at once, fully arrived (as if it had been there for a while) unless
		opts.arrive == false (then it behaves like a fresh spawn: server placement first).
	]]
	function fw:addPlayer(player, o)
		o = o or {}
		local st = newState(player, o)
		fw._states[player] = st
		local start = o.spawn or asVector(st.path(0))
		st.serverRoot = CF.new(start)
		st.character = { Name = "Character" }
		if o.arrive == false then
			resetStream(st, fw.now + st.base)
		else
			-- the character has "always" been there: its snapshots started early enough that the first
			-- one has already arrived (client time before 0 is just the path evaluated there)
			resetStream(st, fw.now - (st.base + st.noise + 2 * STEP))
			generate(st, fw.now)
		end
		return st
	end

	function fw:removePlayer(player)
		fw._states[player] = nil
	end

	function fw:setPath(player, path)
		stateOf(player).path = path
	end

	function fw:setPing(player, seconds)
		stateOf(player).ping = seconds
	end

	function fw:humanoid(player)
		return stateOf(player).humanoid
	end

	function fw:setState(player, state)
		stateOf(player).humanoid.state = state
	end

	function fw:setInWorkspace(player, on)
		stateOf(player).inWorkspace = on
	end

	-- the TRUE client root at client time s (ground truth for assertions)
	function fw:truePosition(player, s)
		return rawPos(stateOf(player), s or fw.now)
	end

	-- the server's current view: the client time of the snapshot it sees (nil before the first arrival)
	function fw:viewTime(player)
		local st = stateOf(player)
		return if arrived(st) then viewS(st) else nil
	end

	function fw:freeze(player, seconds)
		local st = stateOf(player)
		st.fs, st.freezeEnd = fw.now, fw.now + seconds
	end

	function fw:seat(player, part, o)
		stateOf(player).seat = if part then { part = part, weld = not (o and o.weld == false) } else nil
	end

	local function fireCharacter(st, event, character)
		for _, fn in table.clone(st.handlers.character) do
			fn(event, character)
		end
	end

	-- the humanoid dies: "died" fires, the body stays where the server last saw it
	function fw:kill(player)
		local st = stateOf(player)
		st.humanoid.alive = false
		st.humanoid.state = "Dead"
		generate(st, fw.now)
		st.deadS = if arrived(st) then viewS(st) else nil
		fireCharacter(st, "died", st.character)
	end

	-- the character is removed (LoadCharacter, the void, leaving): "removing" fires, no root until the next spawn
	function fw:removeCharacter(player)
		local st = stateOf(player)
		if st.character == nil then
			return
		end
		local character = st.character
		fireCharacter(st, "removing", character)
		st.character = nil
		st.seat = nil
	end

	--[[
		fw:spawnCharacter(player, position, { path, cf }): a new character at the server's spawn
		placement `position`; "added" fires (the module reads rootOf there: the server-authored
		position). The client receives it one baseLatency later and its snapshots (the scripted `path`,
		default: standing at `position`) start then, so the first one arrives about 2 x baseLatency after.
		A path that is NOT at `position` is the respawn-as-a-teleport cheat.
	]]
	function fw:spawnCharacter(player, position, o)
		o = o or {}
		local st = stateOf(player)
		st.character = { Name = "Character" }
		st.humanoid.alive = true
		st.humanoid.state = "Running"
		st.deadS = nil
		st.moves = {}
		st.seat = nil
		st.path = o.path or FakeWorld.paths.stand(position)
		st.serverRoot = o.cf or CF.new(position)
		resetStream(st, fw.now + st.base)
		fireCharacter(st, "added", st.character)
	end

	function fw:respawn(player, position, o)
		fw:removeCharacter(player)
		fw:spawnCharacter(player, position, o)
	end

	--[[
		A SERVER script writes the character root's CFrame (game code, Plot's PivotTo, Movement.teleport):
		onServerMove fires now, with `cf`. The client adopts it one baseLatency later and keeps walking from
		there, so snapshots sent before that still show the OLD position and arrive first (stale samples).
		Before the first snapshot of a new character arrives, the server's own root is `cf`.
	]]
	function fw:serverMove(player, cf)
		local st = stateOf(player)
		local tMove = fw.now + st.base
		local before = rawPos(st, tMove)
		table.insert(st.moves, { t = tMove, delta = cf.p - before })
		if st.character ~= nil and not arrived(st) then
			st.serverRoot = cf
		end
		for _, fn in table.clone(st.handlers.move) do
			fn(cf)
		end
	end

	-- scripting: parts ---------------------------------------------------------------------------------------
	--[[
		fw:addPart({ name, position | cf, size (vector), tags = { "Tag" }, anchored (true), canCollide (true), canQuery (true),
		collisionGroup ("Default"), ignoredBy = { Group = true }, isModel, motion = function(t) -> CF,
		surfaceVelocity (vector), velocity, attributes, className })
		Returns the fake Instance: .Name, .ClassName, :GetAttribute, :IsA, :HasTag, and the fields cf,
		size, anchored, canCollide, canQuery, collisionGroup, velocity, attributes, tags, networkOwner.
	]]
	function fw:addPart(o)
		fw._nextPart += 1
		local part = setmetatable({
			Name = o.name or ("Part" .. fw._nextPart),
			ClassName = o.className or (if o.isModel then "Model" else "Part"),
			isModel = o.isModel or false,
			cf = o.cf or CF.new(o.position or ZERO),
			size = o.size or V(4, 4, 4),
			tags = {},
			anchored = o.anchored ~= false,
			canCollide = o.canCollide ~= false,
			canQuery = o.canQuery ~= false,
			collisionGroup = o.collisionGroup or "Default",
			ignoredBy = o.ignoredBy or {},
			motion = o.motion,
			surfaceVelocity = o.surfaceVelocity or ZERO,
			velocity = o.velocity or ZERO,
			attributes = table.clone(o.attributes or {}),
		}, Part)
		table.insert(fw.parts, part)
		for _, tag in o.tags or {} do
			fw:tag(part, tag)
		end
		return part
	end

	-- collision groups: every pair collides unless set otherwise (PhysicsService:CollisionGroupSetCollidable)
	function fw:setCollidable(a, b, on)
		local value = if on then nil else true
		fw._noCollide[a] = fw._noCollide[a] or {}
		fw._noCollide[b] = fw._noCollide[b] or {}
		fw._noCollide[a][b] = value
		fw._noCollide[b][a] = value
	end
	function fw:collidable(a, b)
		local row = fw._noCollide[a or "Default"]
		return row == nil or row[b or "Default"] == nil
	end

	function fw:addGround(topY, size)
		size = size or 2048
		return fw:addPart({
			name = "Ground",
			position = V(0, (topY or 0) - 2, 0),
			size = V(size, 4, size),
		})
	end

	function fw:tag(part, tag)
		if part.tags[tag] then
			return
		end
		part.tags[tag] = true
		fire(fw._tagAdded[tag], part)
	end

	function fw:untag(part, tag)
		if not part.tags[tag] then
			return
		end
		part.tags[tag] = nil
		fire(fw._tagRemoved[tag], part)
	end

	-- game code destroys a part (or the engine does, below killY): tags fire removed, it leaves casts
	function fw:destroy(part, byEngine)
		local at = table.find(fw.parts, part)
		if at == nil then
			return
		end
		table.remove(fw.parts, at)
		part.destroyedAt = fw.now
		if byEngine then
			table.insert(fw.destroyed, part)
		end
		for tag in table.clone(part.tags) do
			part.tags[tag] = nil
			fire(fw._tagRemoved[tag], part)
		end
	end

	-- time ---------------------------------------------------------------------------------------------------------
	local function physics(from, to)
		local steps = math.max(1, math.ceil((to - from) / STEP - 1e-9))
		local h = (to - from) / steps
		for _, part in table.clone(fw.parts) do
			if not part.anchored and part.destroyedAt == nil then
				for _ = 1, steps do
					local v = part.velocity
					v = V(v.x, v.y - fw._gravity * h, v.z)
					local p0 = part.cf.p
					local p1 = p0 + v * h
					-- land on an anchored, collidable box whose footprint holds the part's centre
					if part.canCollide and v.y <= 0 then
						local halfY = part.size.y * 0.5
						for _, floor in fw.parts do
							if floor ~= part and floor.anchored and floor.canCollide then
								local inv = floor:inverse()
								local l = CF.pointTo(inv, V(p1.x, p0.y, p1.z))
								local hs = floor.size * 0.5
								local top = floor.cf.p.y + hs.y
								if
									math.abs(l.x) <= hs.x
									and math.abs(l.z) <= hs.z
									and p0.y - halfY >= top - 1e-6
									and p1.y - halfY <= top
								then
									p1 = V(p1.x, top + halfY, p1.z)
									v = ZERO
									break
								end
							end
						end
					end
					part.cf = CF.new(p1, part.cf.r)
					part.velocity = v
					if p1.y < fw._killY then
						fw:destroy(part, true)
						break
					end
				end
			end
		end
	end

	-- advance this world's clock by dt (no harness)
	function fw:advance(dt)
		local from = fw.now
		fw.now = from + dt
		for _, part in fw.parts do
			if part.motion then
				part.cf = part.motion(fw.now)
			end
		end
		physics(from, fw.now)
		for _, player in fw._order do
			local st = fw._states[player]
			if st then
				generate(st, fw.now)
			end
		end
	end

	-- one frame of `dt`: this world's clock, then the harness (h:tick(dt)); the shared ticker bursts after a long frame
	function fw:frame(h, dt)
		fw:advance(dt)
		if h then
			h:tick(dt)
		end
	end

	-- `seconds` in 1/60 s frames; `each(frameTime)` runs before every frame (a scripted cheat, a probe)
	function fw:run(h, seconds, each)
		local frames = math.floor(seconds * 60 + 0.5)
		for _ = 1, frames do
			if each then
				each(fw.now)
			end
			fw:frame(h, STEP)
		end
	end

	-- a single long frame (a server hitch)
	function fw:hitch(h, seconds)
		fw:frame(h, seconds)
	end

	function fw:resetCounters()
		fw.casts, fw.blockcasts, fw.cframeWrites = 0, 0, 0
	end

	if opts.ground ~= nil then
		fw:addGround(opts.ground)
	end

	return fw
end

return FakeWorld
