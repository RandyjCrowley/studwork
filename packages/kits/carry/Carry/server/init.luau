--!strict
--[[
	Carry: the server part (docs/framework/kits/carry.md, "Carry"). Pick up, carry, hand off, throw, drop
	and deliver an object, alone or with other players.

	A part factory (`new`): each runtime gets its own state. api, signals and actions are complete at
	require time (the framework wraps them before init); init resets the state.

	  api: registerCarriable, setDropRule, pickUp, drop, handOff, releasePlayer, reportHazard, reset,
	       holders, isCarrying, objectOf, stateOf, useWorld
	  signals: PickedUp, Dropped, HandedOff, Delivered, Returned (created in init)
	  actions (net.blink): carryPickUp(objectId), carryDrop(objectId), carryHandOff(objectId, toUserId)

	How it works (every decision is the server's):
	  - While carried an object is ANCHORED. Its CFrame is written on the shared Heartbeat ticker at
	    `motionHz`, interpolating between the last two clamped targets computed on the logic tick
	    (`sampleSeconds`). Never unanchored, never PreSimulation.
	  - Every position judged is the ACCEPTED one: Movement's lastValid when Movement is enabled
	    (ctx.isEnabled(Movement) is checked before ctx.deps is touched), the raw root otherwise, where
	    Carry's own clamp (shared/Clamp.luau) keeps the object honest. A raw client position is never used
	    alone.
	  - On a drop CanCollide stays true; fling protection is a collision group (the built-in
	    "CarryDropped", or config.collisionGroup). `dropNoCollideSeconds` is an opt-in escape hatch.
	  - No save section: `Delivered`'s payload is the only integration point.

	Interpretations the design leaves open (all listed in the builder report):
	  - A `carried` object that loses its LAST holder is always dropped (belowMin only decides whether
	    the remaining holders keep a `gathering` object when slots fall below `min` but not to zero).
	  - Delivery zone boxes are cached at tag time and re-read every ZONE_REFRESH_SECONDS while an object
	    is carried (the World seam has no property-changed signal), and re-read fresh just before firing.
	  - A resting object's collision group is restored to "Default" (the group before a drop is not read).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local MovementRef = require(Modules:WaitForChild("Movement"):WaitForChild("module"))
local Shared = Modules:WaitForChild("Carry"):WaitForChild("shared")
local Blend = require(Shared:WaitForChild("Blend"))
local Box = require(Shared:WaitForChild("Box"))
local CF = require(Shared:WaitForChild("CF"))
local Clamp = require(Shared:WaitForChild("Clamp"))
local Codec = require(Shared:WaitForChild("Codec"))
local WorldModule = require(Shared:WaitForChild("World"))

local Engine = require(script.Engine)
local Landing = require(script.Landing)
local Rules = require(script.Rules)
local SignalTable = require(script.SignalTable)
local Throw = require(script.Throw)

local ACTION_LIMITS: { [string]: { rate: number, burst: number } } = {
	carryPickUp = { rate = 4, burst = 6 },
	carryDrop = { rate = 4, burst = 6 },
	carryHandOff = { rate = 2, burst = 4 },
}

local SIGNALS = { "PickedUp", "Dropped", "HandedOff", "Delivered", "Returned" }
local DROP_REASONS = {
	belowMin = true,
	tilt = true,
	stretch = true,
	hardLanding = true,
	carrierDied = true,
	carrierLeft = true,
	disqualified = true,
	teleport = true,
	hazard = true,
	missedThrow = true,
	manual = true,
	flagOff = true,
	removed = true,
}

local BUILTIN_GROUP = "CarryDropped"
local ZONE_REFRESH_SECONDS = 1
local ZERO = vector.create(0, 0, 0)
-- A clamped pose within these of the object's current `target` is "the same pose": nothing is refreshed and
-- nothing is written (a held-still object costs no CFrame writes). 0.002 studs is far below anything a client
-- can see or a rule can measure; 1e-4 on a rotation-matrix element is about 0.006 degrees.
local POSE_EPSILON_STUDS = 0.002
local POSE_EPSILON_ROTATION = 1e-4

local function samePose(a: any, b: any): boolean
	if vector.magnitude(a.p - b.p) > POSE_EPSILON_STUDS then
		return false
	end
	local ar, br = a.r, b.r
	for i = 1, 9 do
		if math.abs(ar[i] - br[i]) > POSE_EPSILON_ROTATION then
			return false
		end
	end
	return true
end

local function asCF(value: any): any
	if type(value) == "table" then
		return value
	end
	return CF.fromCFrame(value)
end

local function asVector(value: any): vector
	if value == nil then
		return ZERO
	end
	if typeof(value) == "vector" then
		return value
	end
	return vector.create(value.X or value.x or 0, value.Y or value.y or 0, value.Z or value.z or 0)
end

local Server = {}

function Server.new(): any
	local part: any = {}
	local signals: any = SignalTable.new()

	local ctx: any = nil
	local cfg: any = nil
	local world: any = nil
	local pendingWorld: any = nil
	local usingLive = false
	local triedLive = false
	local started = false
	local mvOn = false
	local stopWatchingCharacters: (() -> ())? = nil

	-- definitions and rules
	local defs: { [string]: any } = {}
	local tagRules: { [string]: any } = {}
	local globalRules: any = {}
	local rulesVersion = 0

	-- objects
	local objects: { [any]: any } = {} -- instance -> object record
	local byId: { [string]: any } = {}
	local active: { [any]: boolean } = {} -- object records out of `idle`/`delivered`
	local holding: { [any]: any } = {} -- player -> object record
	local lastPos: { [any]: { acc: vector, raw: vector? } } = {}
	local charConns: { [any]: () -> () } = {}
	local speedApplied: { [any]: number } = {}
	local nextId = 0
	local nextSeed = 0

	-- zones
	local zones: { any } = {}
	local zoneOf: { [any]: any } = {}
	local nextZone = 0
	local zoneRefreshAt = 0

	local tagDisconnects: { () -> () } = {}
	local lastLogic = -math.huge
	local lastMotion = -math.huge
	local scratch: { any } = {}

	-- logic-tick scratch, reused across objects and ticks (stepCarried never runs re-entrantly and keeps none of
	-- these past its return): no per-carrier or per-object table churn on the steady carried path
	local holdOffset = ZERO -- cfg.holdOffset as a vector (set in init); the hold CF has the identity rotation
	local occupied: { any } = {}
	local occPool: { any } = {}
	local implied: { [number]: vector } = {}
	local speeds: { number } = {}
	local clampParams = { speed = 0, dt = 0, maxDt = 0, riseSpeed = 0, fallSpeed = 0 }
	local landingParams: Landing.Params = { gravity = 196.2, hardLandingSpeed = 0, marginStuds = 0 }
	local landingCast = { respectCanCollide = true, ignoreCharacters = true, collisionGroup = nil :: string? }
	local DOWN = vector.create(0, -1, 0)
	-- how far down the probe looks: far enough to find a lift's floor under a lagging rider
	local PROBE_STUDS = 64

	-- The ground profile under the first carrier's path for Landing (LEDGE_SLOPE / LEDGE_SPACING / LEDGE_SAMPLES): rays
	-- straight down every LEDGE_SPACING studs from the previous probe's position (on the fall's first probe: the
	-- anchor, where the carriers last stood, whose ground is its standing height) to `to`, whose ground `groundTo` the
	-- probe's own ray found. A ledge is a run of drops each steeper than LEDGE_SLOPE; a stair riser is one of its own
	-- height, a cliff, a hole or a steep hillside one of its full height. Returns the highest ledge of the open fall so
	-- far, or math.huge when the fall has no anchor (its height then counts in full).
	local function ledgeAlong(obj: any, to: vector, stand: number, groundTo: number): number
		local fall = obj.fall
		local from: vector? = obj.fallFrom
		if fall.probes == 1 then
			local anchor = fall.anchor
			from = anchor
			obj.fallRun, obj.fallLedge = 0, if anchor == nil then math.huge else 0
			obj.fallG = if anchor ~= nil then anchor.y - stand else nil
		end
		obj.fallFrom = to
		local prevG: number? = obj.fallG
		if from == nil or prevG == nil then
			obj.fallG = groundTo
			return obj.fallLedge
		end
		local dx, dz = to.x - from.x, to.z - from.z
		local dist = math.sqrt(dx * dx + dz * dz)
		local n = math.clamp(math.ceil(dist / Landing.LEDGE_SPACING), 1, Landing.LEDGE_SAMPLES)
		local spacing = dist / n
		local topY = math.max(from.y, to.y)
		local reach = topY - math.min(from.y, to.y) + stand + PROBE_STUDS
		local run, ledge = obj.fallRun, obj.fallLedge
		local g = prevG
		for i = 1, n do
			local was = g
			if i == n then
				g = groundTo
			else
				local a = i / n
				local hit = world.cast(
					vector.create(from.x + dx * a, topY, from.z + dz * a),
					DOWN * reach,
					landingCast
				)
				g = if hit ~= nil then topY - hit.distance else topY - reach
			end
			local drop = was - g
			if drop > Landing.LEDGE_SLOPE * spacing then
				run += drop
				if run > ledge then
					ledge = run
				end
			else
				run = 0
			end
		end
		obj.fallRun, obj.fallLedge, obj.fallG = run, ledge, g
		return ledge
	end
	-- Landing's probe, on a tick the carried object went lower: is any carrier in the air (no ground within its
	-- standing height + AIR_GAP), is every carrier on the ground, how far above standing height are the carriers
	-- still (their mean, when every one is on the ground), and the highest ledge under the first carrier's path
	-- since the fall's anchor (`ledgeAlong`)? A ray straight down from each accepted root position (server-observed),
	-- against colliding parts only; characters and the carried object (CanQuery off) are never ground. It also
	-- follows the part under the first carrier: the same part lower than it was is a lift (`obj.fallRode`).
	local function landingProbe(obj: any): (boolean, boolean, number, number)
		local air, grounded = false, true
		local gap = 0
		local ledge = math.huge
		for k, entry in occupied do
			local facts = world.humanoidFacts(entry.player)
			local stand = if facts ~= nil then facts.hipHeight + facts.rootHalfHeight else 3
			landingCast.collisionGroup = if facts ~= nil then facts.collisionGroup else nil
			local hit = world.cast(entry.pos, DOWN * (stand + PROBE_STUDS), landingCast)
			local d = if hit ~= nil then hit.distance else math.huge
			if d > stand + Landing.AIR_GAP then
				air = true
			end
			if d > stand + Landing.GROUND_SLACK then
				grounded = false
			end
			gap += math.max(0, d - stand)
			if k == 1 then
				if obj.fall.probes == 1 then
					obj.fallSup, obj.fallRode = nil, false
				end
				if hit ~= nil then
					local y = world.boundsOf(hit.instance).p.y
					if hit.instance == obj.fallSup and y < obj.fallSupY - Landing.DESCEND_EPS then
						obj.fallRode = true
					end
					obj.fallSup, obj.fallSupY = hit.instance, y
				end
				ledge = ledgeAlong(obj, entry.pos, stand, entry.pos.y - math.min(d, stand + PROBE_STUDS))
			end
		end
		return air, grounded, if #occupied > 0 then gap / #occupied else 0, ledge
	end

	-- at the decision: did the ground the first carrier was last seen over move down since (a lift that stopped)?
	local function rodeDown(obj: any): boolean
		if obj.fallRode then
			return true
		end
		local sup = obj.fallSup
		if sup == nil then
			return false
		end
		return world.boundsOf(sup).p.y < obj.fallSupY - Landing.DESCEND_EPS
	end

	-- the hard-landing params under `rules` (the shared table, refilled), or nil with hard landing off
	local function landingParamsFor(rules: any): Landing.Params?
		local hardLimit = rules.hardLandingSpeed
		if type(hardLimit) ~= "number" then
			return nil
		end
		local lp = landingParams
		lp.gravity, lp.hardLandingSpeed = world.gravity(), hardLimit
		lp.marginStuds = if type(rules.hardLandingMarginStuds) == "number"
			then rules.hardLandingMarginStuds
			else 0
		return lp
	end

	local impl: any = {}

	-- helpers -------------------------------------------------------------------------------------------

	local function now(): number
		return (world :: any).clock()
	end

	local function isOn(): boolean
		local flag = cfg.flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		return ok and on == true
	end

	local function rulesFor(obj: any): any
		if obj.rulesVersion ~= rulesVersion then
			obj.rules = Rules.merge(cfg.dropRules, globalRules, obj.def.dropRules, tagRules[obj.tag])
			obj.rulesVersion = rulesVersion
		end
		return obj.rules
	end

	local function groupName(): string
		return cfg.collisionGroup or BUILTIN_GROUP
	end

	local function slotOf(obj: any, player: any): number?
		for i = 1, obj.def.carriers.max do
			if obj.slots[i] == player then
				return i
			end
		end
		return nil
	end

	local function poseOf(obj: any): any
		local cf = world.boundsOf(obj.inst)
		return cf
	end

	-- replication: one string per object, on state changes only, never before the first pick-up ----------

	local function publish(obj: any)
		if not obj.everPicked or not isOn() then
			return
		end
		local slotIds: { [number]: number } = {}
		for i, p in obj.slots do
			slotIds[i] = p.UserId
		end
		local throw = nil
		if obj.state == "thrown" and obj.throw ~= nil then
			throw =
				{ from = obj.throw.from.UserId, to = obj.throw.to.UserId, startedAt = obj.throw.startedAt }
		end
		ctx.replicate.setAll(
			"carry:" .. obj.id,
			Codec.encode({
				state = obj.state,
				tag = obj.tag,
				slots = slotIds,
				wobbleSeed = obj.wobbleSeed,
				throw = throw,
			})
		)
	end

	local function clearKey(obj: any)
		if obj.everPicked then
			ctx.replicate.setAll("carry:" .. obj.id, nil)
		end
	end

	local function setState(obj: any, state: string)
		obj.state = state
		if state == "idle" or state == "delivered" then
			active[obj] = nil
		else
			active[obj] = true
		end
	end

	-- walk speed: x speedFactor x (1 - speedPenalty x missing), divided back on release ------------------

	local function restoreSpeed(player: any)
		local applied = speedApplied[player]
		if applied == nil then
			return
		end
		speedApplied[player] = nil
		local facts = world.humanoidFacts(player)
		if facts ~= nil and applied ~= 0 then
			world.setWalkSpeed(player, facts.walkSpeed / applied)
		end
	end

	local function applySpeed(obj: any, player: any)
		if not cfg.applyWalkSpeed then
			return
		end
		local facts = world.humanoidFacts(player)
		if facts == nil then
			speedApplied[player] = nil
			return
		end
		local mass = cfg.massClasses[obj.def.massClass]
		local missing = obj.def.carriers.max - obj.count
		local factor = (mass.speedFactor or 1) * (1 - obj.def.speedPenalty * missing)
		factor = math.max(factor, 0.05)
		local base = facts.walkSpeed / (speedApplied[player] or 1)
		world.setWalkSpeed(player, base * factor)
		speedApplied[player] = factor
	end

	local function refreshSpeeds(obj: any)
		for i = 1, obj.def.carriers.max do
			local p = obj.slots[i]
			if p ~= nil then
				if obj.state == "carried" then
					applySpeed(obj, p)
				else
					restoreSpeed(p)
				end
			end
		end
	end

	-- group / collision ------------------------------------------------------------------------------------

	local function assignGroup(obj: any)
		world.setCollisionGroup(obj.inst, groupName())
		obj.grouped = true
	end

	local function restoreGroup(obj: any)
		if obj.grouped then
			world.setCollisionGroup(obj.inst, "Default")
			obj.grouped = false
		end
	end

	-- slot bookkeeping --------------------------------------------------------------------------------------

	local function watchCharacter(player: any)
		if charConns[player] ~= nil then
			return
		end
		charConns[player] = world.onCharacter(player, function(event: string)
			local obj = holding[player]
			if obj == nil then
				return
			end
			if event == "died" then
				if rulesFor(obj).carrierDied then
					impl.release(obj, player, "carrierDied")
				end
			elseif event == "removing" then
				impl.release(obj, player, "carrierLeft")
			end
		end)
	end

	local function unwatchCharacter(player: any)
		local disconnect = charConns[player]
		if disconnect ~= nil then
			charConns[player] = nil
			disconnect()
		end
	end

	local function takeOut(obj: any, index: number): any
		local player = obj.slots[index]
		obj.slots[index] = nil
		obj.count -= 1
		local uid = player.UserId
		local joined = obj.joined[uid]
		if joined ~= nil then
			obj.per[uid] = (obj.per[uid] or 0) + (now() - joined)
			obj.joined[uid] = nil
		end
		holding[player] = nil
		lastPos[player] = nil
		restoreSpeed(player)
		unwatchCharacter(player)
		return player
	end

	local function freeAll(obj: any)
		for i = 1, obj.def.carriers.max do
			if obj.slots[i] ~= nil then
				takeOut(obj, i)
			end
		end
	end

	local function samplePositions(player: any, acc: vector)
		local rawP = world.rootOf(player)
		local last = lastPos[player]
		if last == nil then
			lastPos[player] = { acc = acc, raw = rawP }
		else
			last.acc, last.raw = acc, rawP
		end
	end

	-- accepted positions ------------------------------------------------------------------------------------

	-- Movement booted AND policing this player now. Its flag off (the kill switch), no World, or the gap before a
	-- fresh baseline after the flag comes back on all mean "Movement absent" here: Carry falls back to the raw root
	-- and its own clamp instead of reading lastValid's (nil, false) as an untrusted carrier.
	local function mvActive(player: any): boolean
		return mvOn and ctx.deps[MovementRef].active(player) == true
	end

	-- (cf?, trusted): Movement's lastValid when active, else the raw root (trusted: Carry's clamp polices it)
	local function accepted(player: any): (any, boolean)
		if mvActive(player) then
			local cf, trusted = ctx.deps[MovementRef].lastValid(player)
			if cf == nil then
				return nil, false
			end
			return asCF(cf), trusted == true
		end
		local _, cf = world.rootOf(player)
		if cf == nil then
			return nil, false
		end
		return cf, true
	end

	local function agreeStuds(player: any): number
		local a = cfg.agree
		local facts = world.humanoidFacts(player)
		local ws = if facts ~= nil then facts.walkSpeed else 16
		return a.baseStuds + math.max(16, ws) * (a.sampleAgeSeconds + a.lagSeconds)
	end

	-- (refusal?, accepted cf?)
	local function presence(player: any): (string?, any)
		local rawP = world.rootOf(player)
		if rawP == nil then
			return "noCharacter", nil
		end
		local facts = world.humanoidFacts(player)
		if facts ~= nil and not facts.alive then
			return "noCharacter", nil
		end
		local cf, trusted = accepted(player)
		if cf == nil or not trusted then
			return "untrusted", nil
		end
		if mvActive(player) and vector.magnitude(rawP - cf.p) > agreeStuds(player) then
			return "disagree", nil
		end
		return nil, cf
	end

	-- state transitions ---------------------------------------------------------------------------------------

	local function rest(obj: any, state: string)
		-- anchored, colliding, where it is
		world.setVelocity(obj.inst, ZERO)
		world.anchor(obj.inst)
		world.setCollide(obj.inst, true)
		world.setQuery(obj.inst, true)
		restoreGroup(obj)
		obj.throw = nil
		obj.noCollideUntil = nil
		obj.slowSince = nil
		setState(obj, state)
	end

	local function lift(obj: any)
		local cf = poseOf(obj)
		world.setVelocity(obj.inst, ZERO)
		world.anchor(obj.inst)
		world.setCollide(obj.inst, false)
		-- CanQuery off too: the held object sits in front of its carrier, and any raycast that doesn't respect
		-- CanCollide (the engine default; a game's own anti-cheat or hit checks) would otherwise hit it. Every path
		-- out of `carried` (rest, dropObject, the throw) turns it back on with CanCollide.
		world.setQuery(obj.inst, false)
		restoreGroup(obj)
		obj.throw = nil
		obj.noCollideUntil = nil
		obj.slowSince = nil
		obj.prev, obj.target = cf, cf
		obj.tickAt = now()
		obj.lastAt = now()
		obj.fall = nil
		obj.dirty = false
		setState(obj, "carried")
	end

	local function dropObject(obj: any, reason: string, by: any)
		freeAll(obj)
		obj.throw = nil
		world.unanchor(obj.inst)
		world.setVelocity(obj.inst, ZERO)
		world.setCollide(obj.inst, true) -- never off: a dropped object always keeps colliding with the world
		world.setQuery(obj.inst, true)
		assignGroup(obj)
		if cfg.dropNoCollideSeconds ~= nil then
			world.setCollide(obj.inst, false)
			obj.noCollideUntil = now() + cfg.dropNoCollideSeconds
		end
		obj.slowSince = nil
		setState(obj, "dropped")
		publish(obj)
		signals.Dropped:Fire(obj.inst, reason, by)
	end

	-- Before anything else ends a carry (a delivery, a manual drop, a hand-off or throw, a release): an open fall
	-- that already qualifies as a hard landing (Landing.pending, not a lift) drops the object as one first. True if
	-- it did.
	local function resolveFall(obj: any): boolean
		local fall = obj.fall
		if obj.state ~= "carried" or fall == nil or not fall.open then
			return false
		end
		local lp = landingParamsFor(rulesFor(obj))
		if lp == nil or Landing.pending(fall, lp) == nil or rodeDown(obj) then
			return false
		end
		dropObject(obj, "hardLanding", nil)
		return true
	end

	local function returnToSpawn(obj: any, reason: string)
		freeAll(obj)
		rest(obj, "idle")
		world.setCFrame(obj.inst, obj.spawn)
		publish(obj)
		signals.Returned:Fire(obj.inst, reason)
	end

	-- Frees `player`'s slot and applies the "States (frozen)" table for the object's state.
	function impl.release(obj: any, player: any, reason: string): boolean
		local index = slotOf(obj, player)
		if index == nil then
			return false
		end
		if resolveFall(obj) then
			-- a fall that already qualifies ends the carry as a hard landing first (the slot is freed with it)
			return true
		end
		local wasCarried = obj.state == "carried"
		takeOut(obj, index)
		if not wasCarried then
			-- gathering: free the slot; no holders left means idle
			if obj.count == 0 then
				rest(obj, "idle")
			end
			publish(obj)
			return true
		end
		if obj.count >= obj.def.carriers.min then
			refreshSpeeds(obj)
			publish(obj)
			return true
		end
		local rules = rulesFor(obj)
		if obj.count > 0 and not rules.belowMin then
			-- belowMin off: the object is set down where it is; the remaining holders keep `gathering`
			rest(obj, "gathering")
			refreshSpeeds(obj)
			publish(obj)
			return true
		end
		dropObject(obj, reason, player)
		if reason == "carrierLeft" and rules.carrierLeft == "returnToSpawn" then
			returnToSpawn(obj, "carrierLeft")
		end
		return true
	end

	local function join(obj: any, player: any, cf: any)
		local index = 1
		while obj.slots[index] ~= nil do
			index += 1
		end
		obj.slots[index] = player
		obj.count += 1
		holding[player] = obj
		obj.joined[player.UserId] = now()
		samplePositions(player, cf.p)
		watchCharacter(player)
		if not obj.everPicked then
			obj.everPicked = true
		end
		if obj.startedAt == nil then
			obj.startedAt = now()
		end
		if obj.count >= obj.def.carriers.min then
			if obj.state ~= "carried" then
				lift(obj)
			end
		elseif obj.state == "idle" or obj.state == "dropped" then
			rest(obj, "gathering")
		end
		refreshSpeeds(obj)
		publish(obj)
		signals.PickedUp:Fire(player, obj.inst, index)
	end

	-- delivery ----------------------------------------------------------------------------------------------------

	local function zoneBox(zone: any)
		local cf, size = world.boundsOf(zone.inst)
		zone.cf, zone.size = cf, size
	end

	local function refreshZones(t: number)
		if t - zoneRefreshAt < ZONE_REFRESH_SECONDS then
			return
		end
		zoneRefreshAt = t
		for _, zone in zones do
			zoneBox(zone)
		end
	end

	local function inZone(zone: any, obj: any, pose: any, players: { any }): boolean
		if cfg.deliveryContainment == "center" then
			if not Box.contains(zone.cf, zone.size, pose.p) then
				return false
			end
		elseif not Box.containsBox(zone.cf, zone.size, pose, obj.size) then
			return false
		end
		for _, entry in players do
			if not entry.trusted then
				return false
			end
			if not Box.contains(zone.cf, zone.size, entry.pos, cfg.deliveryReachStuds) then
				return false
			end
		end
		return true
	end

	local function tryDeliver(obj: any, pose: any, players: { any }): boolean
		if #zones == 0 then
			return false
		end
		local t = now()
		refreshZones(t)
		for _, zone in zones do
			if inZone(zone, obj, pose, players) then
				zoneBox(zone) -- a fresh read just before firing
				if inZone(zone, obj, pose, players) then
					if resolveFall(obj) then
						-- a qualifying fall into (or onto the edge of) the zone is a hard landing, not a delivery
						return true
					end
					local carriers: { any } = {}
					for _, entry in players do
						table.insert(carriers, entry.player)
					end
					world.setCFrame(obj.inst, pose)
					obj.prev, obj.target = pose, pose
					obj.dirty = false
					freeAll(obj)
					rest(obj, "delivered")
					local per: { [number]: number } = table.clone(obj.per)
					publish(obj)
					signals.Delivered:Fire(obj.inst, zone.inst, table.freeze(carriers), {
						startedAt = obj.startedAt or t,
						deliveredAt = t,
						perCarrierSeconds = per,
					})
					return true
				end
			end
		end
		return false
	end

	-- the carried-object logic tick ------------------------------------------------------------------------------

	local function stepCarried(obj: any, t: number)
		local rules = rulesFor(obj)
		local def = obj.def
		local dt = t - obj.lastAt

		-- 1. accepted carrier positions; an untrusted or missing one loses the slot. Each entry is a pooled table;
		-- its hold CF is root * CF(holdOffset): the root's rotation (shared, never mutated) and the offset point.
		table.clear(occupied)
		local n = 0
		for i = 1, def.carriers.max do
			local p = obj.slots[i]
			if p ~= nil then
				local cf, trusted = accepted(p)
				if cf == nil then
					impl.release(obj, p, if mvActive(p) then "teleport" else "carrierLeft")
				elseif not trusted and rules.untrustedCarrier then
					impl.release(obj, p, "teleport")
				else
					n += 1
					local entry = occPool[n]
					if entry == nil then
						entry = {
							index = 0,
							player = nil,
							pos = ZERO,
							trusted = false,
							hold = { p = ZERO, r = cf.r },
						}
						occPool[n] = entry
					end
					entry.index, entry.player, entry.pos, entry.trusted = i, p, cf.p, trusted
					local hold = entry.hold
					hold.p, hold.r = CF.pointTo(cf, holdOffset), cf.r
					occupied[n] = entry
				end
			end
			if obj.state ~= "carried" then
				return
			end
		end
		if #occupied == 0 then
			return
		end

		-- 2/3. blend into a target
		local target, tilt, stretch = Blend.targetCF(occupied, def, implied)

		-- 4. clamp
		table.clear(speeds)
		local rise = 0
		for k, entry in occupied do
			local facts = world.humanoidFacts(entry.player)
			speeds[k] = if facts ~= nil then facts.walkSpeed else 16
			rise = math.max(rise, if facts ~= nil then facts.jumpVelocity else 50)
		end
		local cp = clampParams
		cp.speed = Clamp.objSpeed(speeds, cfg.clamp.speedSlack)
		cp.dt, cp.maxDt = dt, cfg.clamp.maxDtSeconds
		cp.riseSpeed, cp.fallSpeed = rise * cfg.clamp.riseSlack, cfg.clamp.maxFallSpeed
		local newPos = Clamp.step(obj.target.p, target.p, cp)
		local pose = CF.new(newPos, target.r)

		-- grip break: a slot whose implied pivot is too far from the clamped pivot is released
		local broke = false
		for k, entry in occupied do
			if vector.magnitude(implied[entry.index] - newPos) > cfg.clamp.gripBreakStuds then
				local last = lastPos[entry.player]
				local cap = Clamp.teleportCap(speeds[k], dt, cfg.agree.lagSeconds)
				local rawP = world.rootOf(entry.player)
				local jumped = last ~= nil and (vector.magnitude(entry.pos - last.acc) > cap)
				if
					last ~= nil
					and last.raw ~= nil
					and rawP ~= nil
					and vector.magnitude(rawP - last.raw) > cap
				then
					jumped = true
				end
				broke = true
				impl.release(obj, entry.player, if jumped then "teleport" else "stretch")
				if obj.state ~= "carried" then
					return
				end
			end
		end
		for _, entry in occupied do
			if holding[entry.player] == obj then
				samplePositions(entry.player, entry.pos)
			end
		end
		if broke then
			obj.lastAt = t -- the object stays at its last good pose this tick
			return
		end

		-- 5. drop rules on the clamped result
		local fragility = def.fragility
		local tiltLimit = rules.tiltDegrees
		if type(tiltLimit) == "number" and fragility > 0 and tilt > tiltLimit / fragility then
			dropObject(obj, "tilt", nil)
			return
		end
		local stretchLimit = rules.stretchStuds
		if type(stretchLimit) == "number" and fragility > 0 and stretch > stretchLimit / fragility then
			dropObject(obj, "stretch", nil)
			return
		end
		-- hard landing (Landing.luau): each fall is decided at its touchdown, on its height from its top (the last
		-- supported height or the apex) to the carriers' ground (server-observed: neither the landing's phase inside
		-- the tick, nor lag, nor the clamp's lag of the object behind the carriers (`target`) changes it), on a
		-- carrier having been in the air (stairs, ramps and descending platforms keep ground underfoot) and on a
		-- fall-like speed. The minimum fall sits above the carriers' own jump (`rise`) by hardLandingMarginStuds.
		local moved = not samePose(pose, obj.target)
		local lp = landingParamsFor(rules)
		if lp ~= nil then
			local fall = obj.fall
			if fall == nil then
				fall = Landing.new(obj.target.p.y, obj.lastAt)
				fall.anchor = occupied[1].pos -- the pick-up is a standing point: a jump straight after it is measured from here
				obj.fall = fall
			end
			local lastY = fall.lastY
			if
				Landing.step(
						fall,
						t,
						newPos.y,
						moved,
						rise,
						lp,
						landingProbe,
						obj,
						target.p.y,
						occupied[1].pos
					)
					~= nil
				and not rodeDown(obj)
			then
				dropObject(obj, "hardLanding", nil)
				return
			end
			-- A supported rise (walking up a ramp or stairs) is a standing point too: with every carrier on the
			-- ground, the next fall is measured from here, so a jump at a crest isn't counted from the foot of the
			-- climb. One short ray per carrier, only on rising ticks with no fall open.
			if moved and not fall.open and newPos.y > lastY + Landing.DESCEND_EPS then
				local supported = true
				for _, entry in occupied do
					local facts = world.humanoidFacts(entry.player)
					local stand = if facts ~= nil then facts.hipHeight + facts.rootHalfHeight else 3
					landingCast.collisionGroup = if facts ~= nil then facts.collisionGroup else nil
					if world.cast(entry.pos, DOWN * (stand + Landing.GROUND_SLACK), landingCast) == nil then
						supported = false
						break
					end
				end
				if supported then
					fall.top, fall.base, fall.anchor = newPos.y, newPos.y, occupied[1].pos
				end
			end
		else
			obj.fall = nil
		end

		-- 6. motion
		-- An unchanged pose leaves prev/target/tickAt/dirty alone: a lerp in progress still finishes at the
		-- target, then writes stop. (`obj.target` is the base of the next clamp step and of the fall tracking
		-- above, so it only moves when the pose does.)
		if moved then
			obj.prev = obj.target
			obj.target = pose
			obj.tickAt = t
			obj.dirty = true
		end
		obj.lastAt = t

		-- delivery (the object's own box at the clamped pose, and every carrier's accepted position)
		tryDeliver(obj, pose, occupied)
	end

	-- dropped / thrown objects: catch, kill plane, settle ------------------------------------------------------------

	local function stepFree(obj: any, t: number)
		local inst = obj.inst
		local pos = (poseOf(obj)).p
		local v = world.velocityOf(inst)

		-- predictive kill plane
		local killY = obj.def.killY or (world.killY() + cfg.killMarginStuds)
		if pos.y + math.min(v.y, 0) * (cfg.sampleSeconds + cfg.killHitchSeconds) < killY then
			returnToSpawn(obj, "void")
			return
		end

		if obj.noCollideUntil ~= nil and t >= obj.noCollideUntil then
			obj.noCollideUntil = nil
			world.setCollide(inst, true)
		end

		if obj.state == "thrown" and obj.throw ~= nil then
			local throw = obj.throw
			local receiver = throw.to
			if holding[receiver] == nil then
				local refusal, cf = presence(receiver)
				if refusal == nil and vector.magnitude(cf.p - pos) <= cfg.catchRadius then
					obj.throw = nil
					lift(obj)
					obj.slots[1] = receiver
					obj.count = 1
					holding[receiver] = obj
					obj.joined[receiver.UserId] = t
					if obj.startedAt == nil then
						obj.startedAt = t
					end
					samplePositions(receiver, cf.p)
					watchCharacter(receiver)
					refreshSpeeds(obj)
					publish(obj)
					signals.HandedOff:Fire(inst, throw.from, receiver, true)
					return
				end
			end
			if t >= throw.deadline then
				dropObject(obj, "missedThrow", receiver)
				return
			end
		end

		if vector.magnitude(v) < cfg.settle.speedStuds then
			if obj.slowSince == nil then
				obj.slowSince = t
			elseif t - obj.slowSince >= cfg.settle.seconds then
				rest(obj, "idle")
				publish(obj)
			end
		else
			obj.slowSince = nil
		end
	end

	-- ticks ---------------------------------------------------------------------------------------------------------

	local function ensureWorld(): boolean
		if world ~= nil then
			return true
		end
		if not triedLive then
			triedLive = true
			local live = WorldModule.live()
			if live ~= nil then
				impl.attachWorld(live, true)
				return true
			end
			ctx.log.debug("no World available (Lune harness, adopt, boot spec): Carry idles")
		end
		return false
	end

	local function logicTick()
		if not ensureWorld() then
			return
		end
		local t = now()
		if t - lastLogic < 0.5 * cfg.sampleSeconds then
			return -- a catch-up call after a hitch
		end
		lastLogic = t
		local on = isOn()
		table.clear(scratch)
		for obj in active do
			table.insert(scratch, obj)
		end
		for _, obj in scratch do
			if active[obj] then
				local state = obj.state
				if state == "carried" then
					if on then
						stepCarried(obj, t)
					end
				elseif state == "thrown" or state == "dropped" then
					stepFree(obj, t)
				end
			end
		end
	end

	local function motionTick()
		if world == nil then
			return
		end
		local t = now()
		if t - lastMotion < 0.5 / cfg.motionHz then
			return
		end
		lastMotion = t
		for obj in active do
			if obj.state == "carried" and obj.dirty then
				local a = math.clamp((t - obj.tickAt) / cfg.sampleSeconds, 0, 1)
				if a >= 1 then
					world.setCFrame(obj.inst, obj.target) -- the end of the step: the target itself, no lerp
					obj.dirty = false
				else
					world.setCFrame(obj.inst, CF.lerp(obj.prev, obj.target, a))
				end
			end
		end
	end

	-- objects and tags ------------------------------------------------------------------------------------------------

	local function see(inst: any, tag: string)
		if objects[inst] ~= nil then
			return
		end
		local def = defs[tag]
		if def == nil or (def.model ~= nil and inst.Name ~= def.model) then
			return
		end
		nextId += 1
		nextSeed += 1
		local id = tostring(nextId)
		local cf, size = world.boundsOf(inst)
		local obj: any = {
			inst = inst,
			id = id,
			tag = tag,
			def = def,
			state = "idle",
			slots = {},
			count = 0,
			spawn = cf,
			size = size,
			wobbleSeed = (nextSeed * 7919) % 1000,
			joined = {},
			per = {},
			everPicked = false,
			rulesVersion = -1,
		}
		objects[inst] = obj
		byId[id] = obj
		world.setAttribute(inst, "CarryObjectId", id)
		Engine.atomic(inst)
	end

	local function forget(inst: any)
		local obj = objects[inst]
		if obj == nil then
			return
		end
		local held = obj.count > 0
		if obj.state == "carried" then
			world.setQuery(inst, true) -- untagged mid-carry: don't leave it invisible to every query
		end
		freeAll(obj)
		objects[inst] = nil
		byId[obj.id] = nil
		active[obj] = nil
		clearKey(obj)
		if held then
			signals.Dropped:Fire(inst, "removed", nil)
		end
	end

	local function watchTag(tag: string)
		for _, inst in world.tagged(tag) do
			see(inst, tag)
		end
		table.insert(
			tagDisconnects,
			world.onTagAdded(tag, function(inst: any)
				see(inst, tag)
			end)
		)
		table.insert(
			tagDisconnects,
			world.onTagRemoved(tag, function(inst: any)
				local obj = objects[inst]
				if obj ~= nil and obj.tag == tag then
					forget(inst)
				end
			end)
		)
	end

	local function addZone(inst: any)
		if zoneOf[inst] ~= nil then
			return
		end
		nextZone += 1
		local zone: any = { inst = inst, id = nextZone }
		zoneBox(zone)
		zoneOf[inst] = zone
		table.insert(zones, zone)
	end

	local function removeZone(inst: any)
		local zone = zoneOf[inst]
		if zone ~= nil then
			zoneOf[inst] = nil
			table.remove(zones, table.find(zones, zone))
		end
	end

	local function detachWorld()
		for _, disconnect in tagDisconnects do
			disconnect()
		end
		table.clear(tagDisconnects)
		for _, disconnect in charConns do
			disconnect()
		end
		table.clear(charConns)
		if world ~= nil then
			for player in table.clone(speedApplied) do
				restoreSpeed(player)
			end
			for _, obj in objects do
				clearKey(obj)
			end
		end
		table.clear(objects)
		table.clear(byId)
		table.clear(active)
		table.clear(holding)
		table.clear(lastPos)
		table.clear(speedApplied)
		table.clear(zones)
		table.clear(zoneOf)
		if stopWatchingCharacters ~= nil then
			stopWatchingCharacters()
			stopWatchingCharacters = nil
		end
	end

	-- Swaps the adapter and clears every per-object baseline (the same as the flag going off and on).
	function impl.attachWorld(w: any, live: boolean?)
		detachWorld()
		world = w
		usingLive = live == true
		lastLogic, lastMotion, zoneRefreshAt = -math.huge, -math.huge, -math.huge
		if cfg == nil then
			return
		end
		if usingLive and cfg.collisionGroup == nil then
			if Engine.registerGroups(BUILTIN_GROUP) then
				stopWatchingCharacters = Engine.watchCharacters()
			end
		end
		for _, inst in world.tagged(cfg.deliveryTag) do
			addZone(inst)
		end
		table.insert(tagDisconnects, world.onTagAdded(cfg.deliveryTag, addZone))
		table.insert(tagDisconnects, world.onTagRemoved(cfg.deliveryTag, removeZone))
		for tag in defs do
			watchTag(tag)
		end
	end

	-- release everything (the flag went off): held objects are set down unanchored and settle ----------------

	local function releaseAll()
		if world == nil then
			return
		end
		for _, obj in objects do
			local state = obj.state
			if state == "gathering" or state == "carried" or state == "thrown" then
				dropObject(obj, "flagOff", nil)
			end
		end
		for _, obj in objects do
			clearKey(obj)
			obj.everPicked = false
		end
	end

	-- API -----------------------------------------------------------------------------------------------------------------

	local function objectFor(instance: any): any
		return objects[instance]
	end

	local function reasonOf(reason: any): string
		if type(reason) == "string" and DROP_REASONS[reason] then
			return reason
		end
		return "disqualified"
	end

	local api: any = {}

	function api.registerCarriable(tag: string, def: any)
		if cfg == nil then
			error("Carry.registerCarriable: Carry is not started yet", 2)
		end
		defs[tag] = Rules.normalize(tag, def, cfg, "Carry.registerCarriable")
		if world ~= nil then
			for _, obj in objects do
				if obj.tag == tag then
					obj.def = defs[tag]
				end
			end
			watchTag(tag)
		end
	end

	function api.setDropRule(tag: string?, rules: any)
		if type(rules) ~= "table" then
			error("Carry.setDropRule: rules must be a table", 2)
		end
		if tag == nil then
			globalRules = Rules.merge(globalRules, rules)
		else
			tagRules[tag] = Rules.merge(tagRules[tag], rules)
		end
		rulesVersion += 1
	end

	function api.pickUp(player: any, object: any): (boolean, string?)
		if not ensureWorld() or not isOn() then
			return false, "off"
		end
		local obj = objectFor(object)
		if obj == nil then
			return false, "notCarriable"
		end
		if obj.state == "delivered" then
			return false, "delivered"
		end
		if obj.state == "thrown" then
			return false, "thrown"
		end
		if holding[player] ~= nil then
			return false, "busy"
		end
		if obj.count >= obj.def.carriers.max then
			return false, "full"
		end
		if obj.state == "idle" or obj.state == "dropped" then
			local inUse = 0
			for o in active do
				if o.state == "gathering" or o.state == "carried" or o.state == "thrown" then
					inUse += 1
				end
			end
			if inUse >= cfg.maxObjects then
				return false, "capacity"
			end
		end
		local refusal, cf = presence(player)
		if refusal ~= nil then
			return false, refusal
		end
		local objCF, size = world.boundsOf(obj.inst)
		if Box.distance(objCF, size, cf.p) > (obj.def.pickUpRadius or cfg.pickUpRadius) then
			return false, "tooFar"
		end
		join(obj, player, cf)
		return true, nil
	end

	function api.drop(player: any, object: any): boolean
		local obj = objectFor(object)
		if obj == nil or world == nil or slotOf(obj, player) == nil then
			return false
		end
		return impl.release(obj, player, "manual")
	end

	function api.handOff(player: any, object: any, toPlayer: any): (boolean, string?)
		if not ensureWorld() or not isOn() then
			return false, "off"
		end
		local obj = objectFor(object)
		if obj == nil then
			return false, "notCarriable"
		end
		if obj.state == "delivered" then
			return false, "delivered"
		end
		if obj.state == "thrown" then
			return false, "thrown"
		end
		local index = slotOf(obj, player)
		if index == nil or obj.state ~= "carried" or obj.count ~= 1 or obj.def.carriers.min ~= 1 then
			return false, "notSoleHolder"
		end
		if toPlayer == nil or toPlayer == player or slotOf(obj, toPlayer) ~= nil then
			return false, "invalidReceiver"
		end
		local present = false
		for _, p in world.players() do
			if p == toPlayer then
				present = true
				break
			end
		end
		if not present then
			return false, "invalidReceiver"
		end
		if holding[toPlayer] ~= nil then
			return false, "receiverBusy"
		end
		local giverRefusal, giverCF = presence(player)
		if giverRefusal ~= nil then
			return false, giverRefusal
		end
		local recvRefusal, recvCF = presence(toPlayer)
		if recvRefusal ~= nil then
			return false, recvRefusal
		end
		local apart = vector.magnitude(giverCF.p - recvCF.p)
		local objCF, size = world.boundsOf(obj.inst)
		local adjacent = apart <= cfg.handOffRange
			and Box.distance(objCF, size, recvCF.p) <= (obj.def.pickUpRadius or cfg.pickUpRadius)
		if not adjacent then
			if apart > cfg.throwRange then
				return false, "tooFar"
			end
			if not cfg.massClasses[obj.def.massClass].throwable then
				return false, "notThrowable"
			end
		end
		if resolveFall(obj) then
			-- a hand-off or throw that would go ahead: a qualifying fall ends the carry as a hard landing first, and
			-- the giver no longer holds the object
			return false, "notSoleHolder"
		end
		if adjacent then
			-- adjacent: the slot is swapped in the same call
			local t = now()
			obj.slots[index] = toPlayer
			local giverUid = player.UserId
			obj.per[giverUid] = (obj.per[giverUid] or 0) + (t - (obj.joined[giverUid] or t))
			obj.joined[giverUid] = nil
			obj.joined[toPlayer.UserId] = t
			holding[player] = nil
			holding[toPlayer] = obj
			lastPos[player] = nil
			restoreSpeed(player)
			unwatchCharacter(player)
			samplePositions(toPlayer, recvCF.p)
			watchCharacter(toPlayer)
			refreshSpeeds(obj)
			publish(obj)
			signals.HandedOff:Fire(obj.inst, player, toPlayer, false)
			return true, nil
		end
		-- throw: the thrower's slot frees at once; the object is unanchored, server-owned, launched
		local t = now()
		takeOut(obj, index)
		obj.throw = { from = player, to = toPlayer, startedAt = t, deadline = t + cfg.catchWindowSeconds }
		world.unanchor(obj.inst)
		world.setCollide(obj.inst, true)
		world.setQuery(obj.inst, true)
		assignGroup(obj)
		local velocity = ZERO
		if mvActive(toPlayer) then
			velocity = asVector(ctx.deps[MovementRef].velocity(toPlayer))
		end
		world.setVelocity(
			obj.inst,
			Throw.velocity(objCF.p, recvCF.p, velocity, cfg.throwSpeed, world.gravity())
		)
		obj.slowSince = nil
		setState(obj, "thrown")
		publish(obj)
		return true, nil
	end

	function api.releasePlayer(player: any, reason: string)
		local obj = holding[player]
		if obj ~= nil then
			impl.release(obj, player, reasonOf(reason))
		end
	end

	function api.reportHazard(player: any, object: any)
		local obj = objectFor(object)
		if obj == nil or slotOf(obj, player) == nil or not rulesFor(obj).hazard then
			return
		end
		if obj.state == "carried" then
			dropObject(obj, "hazard", player)
		else
			impl.release(obj, player, "hazard")
		end
	end

	function api.reset(object: any, cframe: any): boolean
		local obj = objectFor(object)
		if obj == nil or world == nil then
			return false
		end
		freeAll(obj)
		if cframe ~= nil then
			obj.spawn = asCF(cframe)
		end
		rest(obj, "idle")
		world.setCFrame(obj.inst, obj.spawn)
		clearKey(obj)
		obj.everPicked = false
		obj.startedAt = nil
		obj.per = {}
		obj.joined = {}
		nextSeed += 1
		obj.wobbleSeed = (nextSeed * 7919) % 1000
		signals.Returned:Fire(obj.inst, "reset")
		return true
	end

	function api.holders(object: any): { any }
		local obj = objectFor(object)
		local out: { any } = {}
		if obj ~= nil then
			for i = 1, obj.def.carriers.max do
				if obj.slots[i] ~= nil then
					table.insert(out, obj.slots[i])
				end
			end
		end
		return table.freeze(out)
	end

	function api.isCarrying(player: any): any
		local obj = holding[player]
		return if obj ~= nil then obj.inst else nil
	end

	function api.objectOf(objectId: string): any
		local obj = byId[objectId]
		return if obj ~= nil then obj.inst else nil
	end

	function api.stateOf(object: any): string?
		local obj = objectFor(object)
		return if obj ~= nil then obj.state else nil
	end

	function api.useWorld(w: any)
		if started then
			impl.attachWorld(w, false)
		else
			pendingWorld = w
		end
	end

	api.signals = signals
	part.api = api

	-- actions (client -> server): ids only; the API takes Instances ---------------------------------------------------

	local function feedbackFor(player: any, reason: string?)
		if reason == "full" or reason == "tooFar" then
			ctx.net.feedback(player, "toast", ctx.text.format(player, "Carry." .. reason))
		end
	end

	local actions: { [string]: any } = {}
	actions.carryPickUp = {
		limit = ACTION_LIMITS.carryPickUp,
		handler = function(player: any, objectId: string)
			local obj = byId[objectId]
			if obj == nil then
				return false, "notCarriable"
			end
			local ok, reason = api.pickUp(player, obj.inst)
			if not ok then
				feedbackFor(player, reason)
			end
			return ok, reason
		end,
	}
	actions.carryDrop = {
		limit = ACTION_LIMITS.carryDrop,
		handler = function(player: any, objectId: string)
			local obj = byId[objectId]
			if obj == nil then
				return false
			end
			return api.drop(player, obj.inst)
		end,
	}
	actions.carryHandOff = {
		limit = ACTION_LIMITS.carryHandOff,
		handler = function(player: any, objectId: string, toUserId: number)
			local obj = byId[objectId]
			if obj == nil or world == nil then
				return false, "notCarriable"
			end
			local receiver = nil
			for _, p in world.players() do
				if p.UserId == toUserId then
					receiver = p
					break
				end
			end
			if receiver == nil then
				return false, "invalidReceiver"
			end
			local ok, reason = api.handOff(player, obj.inst, receiver)
			if not ok then
				feedbackFor(player, reason)
			end
			return ok, reason
		end,
	}
	part.actions = actions

	-- lifecycle ----------------------------------------------------------------------------------------------------------------

	function part.init(c: any)
		ctx = c
		cfg = c.config
		holdOffset = vector.create(cfg.holdOffset[1] or 0, cfg.holdOffset[2] or 0, cfg.holdOffset[3] or 0)
		for _, name in SIGNALS do
			signals[name] = c.signals.new(name)
		end
		table.clear(defs)
		for tag, def in cfg.carriables do
			defs[tag] = Rules.normalize(tag, def, cfg, "Carry config.carriables")
		end
	end

	function part.start(c: any)
		started = true
		mvOn = c.isEnabled(MovementRef)
		c.lifecycle.onTick(cfg.sampleSeconds, logicTick)
		c.lifecycle.onTick(1 / cfg.motionHz, motionTick)
		c.lifecycle.onPlayerRemoving(function(player: any)
			if world == nil then
				return
			end
			local obj = holding[player]
			if obj ~= nil then
				impl.release(obj, player, "carrierLeft")
			end
			for o in table.clone(active) do
				if o.state == "thrown" and o.throw ~= nil and o.throw.to == player then
					dropObject(o, "missedThrow", player)
				end
			end
			lastPos[player] = nil
			speedApplied[player] = nil
			unwatchCharacter(player)
		end)
		if cfg.flag ~= nil then
			c.flags.onChanged(cfg.flag, function(on: boolean)
				if not on then
					releaseAll()
				end
			end)
		end
		if mvOn then
			local movement = c.deps[MovementRef]
			-- a `log` response never drops anything: only a non-log strike or a disqualified run does
			movement.signals.RunDisqualified:Connect(function(player: any)
				local obj = holding[player]
				if obj ~= nil and rulesFor(obj).carrierDisqualified == "runDisqualified" then
					impl.release(obj, player, "disqualified")
				end
			end)
			movement.signals.Strike:Connect(function(player: any, _reason: any, details: any)
				local obj = holding[player]
				if
					obj ~= nil
					and rulesFor(obj).carrierDisqualified == "strike"
					and type(details) == "table"
					and details.response ~= nil
					and details.response ~= "log"
				then
					impl.release(obj, player, "disqualified")
				end
			end)
		end
		local w = pendingWorld
		pendingWorld = nil
		if w ~= nil then
			impl.attachWorld(w, false)
		end
	end

	return part
end

return Server
