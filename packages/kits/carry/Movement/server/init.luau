--!strict
--[[
	Movement: the server part (docs/framework/kits/carry.md, "Movement"). A server-side validator for player
	characters: six checks (speed, teleport, volumeSweep, noGround, wallSweep, riseSpeed) over server-observed
	root positions, sampled at `sampleHz` (staggered into buckets). It reads the world ONLY through the kit's
	World adapter (Movement/shared/World.luau live, tests/FakeWorld.luau in specs): Movement.useWorld(world).

	A part factory (`new`): each runtime gets its own state.

	  api: startRun, endRun, teleport, exempt, strikes, lastValid, velocity, registerVolume,
	       registerPlatformSource, setSpeedCap, setResponse, useWorld
	  signals: Strike, RunDisqualified, VolumeCrossed
	  console (Studio): `movement samples <userId> [n]`
	No actions, no client part.

	Per-player state (carry.md "Per-player state (frozen)"): `base` always moves to the latest sample (struck or
	not), `accepted` advances only while trusted, trust returns after `trustAfterCleanSamples` clean samples or an
	anchor clearing. THE TRUST RULE (one rule): a failure revokes trust only when the check's configured response
	is not `log` AND the check is an integrity check (teleport incl. descent and respawn, speed, wallSweep,
	noGround, riseSpeed, or a volumeSweep crossing of a `noEntry` volume). Hazard and checkpoint crossings never do.

	Public CFrame arguments/results (teleport, lastValid) are the engine's CFrame live and the kit's CF table
	(shared/CF.luau) under Lune; internally everything is CF + vector.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignalTable = require(script.SignalTable)

local shared = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Movement"):WaitForChild("shared")
local CF = require(shared:WaitForChild("CF"))
local WorldMod = require(shared:WaitForChild("World"))
local Lag = require(shared:WaitForChild("Lag"))
local Caps = require(shared:WaitForChild("Caps"))
local Arc = require(shared:WaitForChild("Arc"))
local Slab = require(shared:WaitForChild("Slab"))
local Window = require(shared:WaitForChild("Window"))

type CFT = CF.CF

local SIGNALS = { "Strike", "RunDisqualified", "VolumeCrossed" }

local CHECKS =
	{ speed = true, teleport = true, volumeSweep = true, noGround = true, wallSweep = true, riseSpeed = true }
local RESPONSES = { log = true, strike = true, resetPosition = true, disqualifyRun = true }
local KINDS = { hazard = true, noEntry = true, checkpoint = true, platform = true, climbable = true }
local INTEGRITY = { teleport = true, speed = true, wallSweep = true, noGround = true, riseSpeed = true }
local MAX_STRIKES_KEPT = 500
local CAST_GROUP = "Default" -- the casts' collision group until the character's own group is known
local WALL_BACKOFF = 0.1 -- studs the wall rays start outside the chord

local ZERO = vector.create(0, 0, 0)

local Server = {}

-- public CFrame (or the kit's CF table under Lune) -> CF
local function toCF(v: any): CFT
	if type(v) == "table" and v.p ~= nil then
		return v
	end
	return CF.fromCFrame(v)
end

local function fromCF(cf: CFT): any
	if (CFrame :: any) ~= nil then
		return CF.toCFrame(cf)
	end
	return cf
end

type VolumeEntry = { inst: any, tag: string, kind: string, box: Slab.Box? }

type Strike = { reason: string, at: number, response: string, details: { [string]: any } }

type Run = { id: string, startedAt: number, eligible: boolean, disqualified: boolean, strikes: { Strike } }

type State = {
	player: any,
	userId: number,
	bucket: number,
	hooked: boolean,
	disc: { () -> () },
	-- baseline
	hasBase: boolean,
	flagRebase: boolean, -- the flag turned back on: no baseline yet, so `active(player)` is false
	base: vector,
	baseAt: number,
	accepted: CFT?,
	accPos: vector?,
	acceptedAt: number,
	prevAccPos: vector?,
	prevAccAt: number,
	trusted: boolean,
	cleanStreak: number,
	win: Window.Window,
	-- arc state
	grounded: boolean,
	y0: number,
	airAt: number?,
	groundAt: number,
	-- frames
	platform: { inst: any, cf: CFT }?,
	graceVel: vector?,
	graceAt: number,
	seat: { part: any, cf: CFT }?,
	-- anchors / exempt
	anchor: { target: CFT, issuedAt: number, mine: boolean, retries: number }?,
	selfWrite: boolean,
	exemptUntil: number,
	exemptReason: string?,
	exemptWas: boolean,
	-- sweeps
	lastCastAt: vector?,
	wallFrom: vector?,
	wallCount: number,
	-- respawn window
	respawning: boolean,
	added: boolean,
	refs: { { pos: vector, cf: CFT, at: number } },
	settleCount: number,
	settlePrev: vector?,
	-- facts
	facts: any,
	ping: number,
	pingAt: number,
	speedCapOverride: number?,
	-- records
	run: Run?,
	strikes: { Strike },
	strikeTotal: number,
	-- console ring
	sCount: number,
	sAt: { number },
	sX: { number },
	sY: { number },
	sZ: { number },
	sDt: { number },
	sHd: { number },
	sCap: { number },
	sGrounded: { boolean },
	sFail: { string },
}

function Server.new(): any
	local part: any = {}
	local ctx: any = nil
	local world: any = nil
	local worldTried = false
	local signals: any = SignalTable.new()
	local states: { [any]: State } = {}
	local stateCount = 0
	local playerList: { any }? = nil
	-- the states of playerList split by bucket (rebuilt with playerList), so a stagger call walks only its own
	-- bucket instead of the whole roster
	local bucketLists: { { State } } = {}
	local tickN = 0
	local wasOff = false

	-- config, cached in init
	local cfg: any = nil
	local minDt = 0.05
	local buckets = 6
	local overrides: { [string]: string } = {}
	local platformSource: ((any, number) -> any)? = nil

	-- volumes (cached boxes; zero engine queries per sample)
	local volumeKinds: { [string]: string } = {}
	local entriesByTag: { [string]: { [any]: VolumeEntry } } = {}
	local sweepList: { VolumeEntry } = {}
	local platformSet: { [any]: boolean } = {}
	local climbSet: { [any]: boolean } = {}
	local tagHooks: { [string]: { () -> () } } = {}

	-- per-sample scratch (no per-sample allocation on the clean path)
	local nf = 0
	local fReason: { string } = {}
	local fFlag: { string? } = {}
	local fKind: { string? } = {}
	local fInst: { any } = {}
	local fA: { number } = {}
	local fB: { number } = {}
	local crossN = 0
	local crossKind: { string } = {}
	local crossInst: { any } = {}
	local castCF: CFT = CF.new(ZERO)
	-- Every Movement cast asks "would the character collide with this?": RespectCanCollide skips CanCollide = false
	-- parts (zones, checkpoints, carried objects; the engine's default would hit them), and the collision group is
	-- the character root's own (set per sample from humanoidFacts), so parts in a group that doesn't collide with
	-- characters (dropped carry objects, team/VIP doors) are skipped too.
	local castOpts: any = { ignoreCharacters = true, respectCanCollide = true, collisionGroup = CAST_GROUP }
	local wallOpts: any = { ignoreCharacters = true, respectCanCollide = true, collisionGroup = CAST_GROUP }
	local groundSize = ZERO
	local groundDir = ZERO

	local function responseOf(check: string): string
		return overrides[check] or cfg.responses[check] or cfg.response
	end

	local function revokes(reason: string, kind: string?, response: string): boolean
		if response == "log" then
			return false
		end
		if reason == "volumeSweep" then
			return kind == "noEntry"
		end
		return INTEGRITY[reason] == true
	end

	local function flagOn(): boolean
		local flag = cfg.flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		return ok and on == true
	end

	-- volumes ---------------------------------------------------------------------------------------------

	local function rebuildSweepList()
		table.clear(sweepList)
		for _, byInst in entriesByTag do
			for _, e in byInst do
				if e.box ~= nil then
					table.insert(sweepList, e)
				end
			end
		end
	end

	local function addVolume(tag: string, inst: any)
		local kind = volumeKinds[tag]
		if kind == nil or world == nil then
			return
		end
		local byInst = entriesByTag[tag]
		if byInst == nil then
			byInst = {}
			entriesByTag[tag] = byInst
		end
		if kind == "platform" then
			platformSet[inst] = true
			byInst[inst] = { inst = inst, tag = tag, kind = kind, box = nil }
		elseif kind == "climbable" then
			climbSet[inst] = true
			byInst[inst] = { inst = inst, tag = tag, kind = kind, box = nil }
		else
			local ok, bcf, size = pcall(world.boundsOf, inst)
			if not ok then
				return
			end
			byInst[inst] = { inst = inst, tag = tag, kind = kind, box = Slab.box(bcf, size) }
		end
		rebuildSweepList()
	end

	local function removeVolume(tag: string, inst: any)
		local byInst = entriesByTag[tag]
		if byInst == nil or byInst[inst] == nil then
			return
		end
		local kind = byInst[inst].kind
		byInst[inst] = nil
		if kind == "platform" then
			platformSet[inst] = nil
		elseif kind == "climbable" then
			climbSet[inst] = nil
		end
		rebuildSweepList()
	end

	local function unwireTag(tag: string)
		local hooks = tagHooks[tag]
		if hooks then
			for _, d in hooks do
				d()
			end
			tagHooks[tag] = nil
		end
		local byInst = entriesByTag[tag]
		if byInst then
			for inst, e in byInst do
				if e.kind == "platform" then
					platformSet[inst] = nil
				elseif e.kind == "climbable" then
					climbSet[inst] = nil
				end
			end
			entriesByTag[tag] = nil
		end
		rebuildSweepList()
	end

	local function wireTag(tag: string)
		if world == nil or tagHooks[tag] ~= nil then
			return
		end
		tagHooks[tag] = {
			world.onTagAdded(tag, function(inst: any)
				addVolume(tag, inst)
			end),
			world.onTagRemoved(tag, function(inst: any)
				removeVolume(tag, inst)
			end),
		}
		for _, inst in world.tagged(tag) do
			addVolume(tag, inst)
		end
	end

	local function wireAllVolumes()
		for tag in volumeKinds do
			wireTag(tag)
		end
	end

	local function unwireAllVolumes()
		for tag in table.clone(tagHooks) do
			unwireTag(tag)
		end
	end

	-- the platform part (or an ancestor within ancestorDepth) a ground hit stands on
	local function platformOf(inst: any): any
		local cur = inst
		for _ = 0, cfg.platform.ancestorDepth do
			if cur == nil then
				return nil
			end
			if platformSet[cur] then
				return cur
			end
			cur = cur.Parent
		end
		return nil
	end

	-- state -----------------------------------------------------------------------------------------------

	local function newState(player: any): State
		local uid = player.UserId
		if type(uid) ~= "number" then
			uid = stateCount + 1
		end
		local kept = cfg.samplesKept
		local windowCap = math.ceil(
			cfg.speedWindowSeconds * cfg.sampleHz / math.max(cfg.minSampleFraction, 0.05)
		) + 8
		stateCount += 1
		return {
			player = player,
			userId = uid,
			bucket = uid % buckets,
			hooked = false,
			disc = {},
			hasBase = false,
			flagRebase = false,
			base = ZERO,
			baseAt = -math.huge,
			accepted = nil,
			accPos = nil,
			acceptedAt = 0,
			prevAccPos = nil,
			prevAccAt = 0,
			trusted = false,
			cleanStreak = 0,
			win = Window.new(windowCap),
			grounded = true,
			y0 = 0,
			airAt = nil,
			groundAt = 0,
			platform = nil,
			graceVel = nil,
			graceAt = 0,
			seat = nil,
			anchor = nil,
			selfWrite = false,
			exemptUntil = -math.huge,
			exemptReason = nil,
			exemptWas = false,
			lastCastAt = nil,
			wallFrom = nil,
			wallCount = 0,
			respawning = false,
			added = false,
			refs = {},
			settleCount = 0,
			settlePrev = nil,
			facts = nil,
			ping = 0,
			pingAt = -math.huge,
			speedCapOverride = nil,
			run = nil,
			strikes = {},
			strikeTotal = 0,
			sCount = 0,
			sAt = table.create(kept, 0),
			sX = table.create(kept, 0),
			sY = table.create(kept, 0),
			sZ = table.create(kept, 0),
			sDt = table.create(kept, 0),
			sHd = table.create(kept, 0),
			sCap = table.create(kept, 0),
			sGrounded = table.create(kept, false),
			sFail = table.create(kept, ""),
		}
	end

	local function setAccepted(st: State, cf: CFT, now: number)
		st.prevAccPos, st.prevAccAt = st.accPos, st.acceptedAt
		st.accepted, st.accPos, st.acceptedAt = cf, cf.p, now
	end

	-- a fresh baseline at this sample (anchor cleared, respawn arrival, exempt ended, flag on, first sample).
	-- `accept`: also trust it and move `accepted` there.
	local function rebase(st: State, now: number, pos: vector, cf: CFT, accept: boolean)
		st.hasBase = true
		st.flagRebase = false
		st.base, st.baseAt = pos, now
		Window.clear(st.win)
		st.grounded, st.groundAt, st.y0, st.airAt = true, now, pos.y, nil
		st.platform, st.graceVel, st.seat = nil, nil, nil
		st.lastCastAt, st.wallFrom, st.wallCount = nil, pos, 0
		if accept then
			st.trusted, st.cleanStreak = true, 0
			st.accPos = nil -- no velocity across a re-baseline
			setAccepted(st, cf, now)
		end
	end

	local function refreshFacts(st: State, now: number): any
		if st.facts == nil or now - st.pingAt >= cfg.lag.pingRefreshSeconds then
			st.facts = world.humanoidFacts(st.player)
			st.ping = world.ping(st.player)
			st.pingAt = now
		end
		return st.facts
	end

	-- failures and strikes ---------------------------------------------------------------------------------

	local function addFail(reason: string, flag: string?, kind: string?, inst: any, a: number, b: number)
		nf += 1
		fReason[nf], fFlag[nf], fKind[nf], fInst[nf], fA[nf], fB[nf] = reason, flag, kind, inst, a, b
	end

	local function integrityFailed(): boolean
		for i = 1, nf do
			if fReason[i] ~= "volumeSweep" or fKind[i] == "noEntry" then
				return true
			end
		end
		return false
	end

	local function sweepVolumes(from: vector, to: vector)
		for i = 1, #sweepList do
			local e = sweepList[i]
			if Slab.crosses(e.box :: Slab.Box, from, to) then
				crossN += 1
				crossKind[crossN], crossInst[crossN] = e.kind, e.inst
				if e.kind == "hazard" or e.kind == "noEntry" then
					addFail("volumeSweep", nil, e.kind, e.inst, 0, 0)
				end
			end
		end
	end

	-- Records the scratch failures (strikes, trust, window/arc re-baseline) and returns the new strikes. The caller
	-- then sets base/baseAt and calls flush.
	local function commitSample(st: State, now: number, pos: vector, cf: CFT, dt: number): { Strike }?
		local newStrikes: { Strike }? = nil
		if nf > 0 then
			local anyRevoke = false
			local list: { Strike } = {}
			for i = 1, nf do
				local reason = fReason[i]
				local response = responseOf(reason)
				local details: { [string]: any } = { response = response, dt = dt }
				local flag = fFlag[i]
				if flag then
					details[flag] = true
				end
				if fKind[i] then
					details.kind = fKind[i]
				end
				if fInst[i] ~= nil then
					details.volume = fInst[i]
				end
				if fA[i] ~= 0 then
					details.value = fA[i]
				end
				if fB[i] ~= 0 then
					details.limit = fB[i]
				end
				local strike: Strike =
					{ reason = reason, at = now, response = response, details = table.freeze(details) }
				list[i] = table.freeze(strike)
				if revokes(reason, fKind[i], response) then
					anyRevoke = true
				end
			end
			newStrikes = list
			Window.clear(st.win)
			st.y0, st.airAt = pos.y, nil
			if anyRevoke then
				st.trusted, st.cleanStreak = false, 0
				return newStrikes
			end
		end
		st.cleanStreak += 1
		if st.trusted then
			setAccepted(st, cf, now)
		elseif st.cleanStreak >= cfg.trustAfterCleanSamples then
			st.trusted = true
			setAccepted(st, cf, now)
		end
		return newStrikes
	end

	local function teleportTo(st: State, cf: CFT, now: number)
		if world == nil then
			return
		end
		if st.respawning then
			world.setRootCFrame(st.player, cf) -- the handler appends it to the server-authored positions
			return
		end
		st.anchor = { target = cf, issuedAt = now, mine = true, retries = cfg.anchor.retries }
		st.selfWrite = true
		world.setRootCFrame(st.player, cf)
		st.selfWrite = false
	end

	local function disqualify(st: State, reason: string)
		local run = st.run
		if run and not run.disqualified then
			run.disqualified = true
			run.eligible = false
			signals.RunDisqualified:Fire(st.player, run.id, reason)
		end
	end

	local function kickCheck(st: State, now: number)
		local limit = cfg.maxStrikesBeforeKick
		if limit <= 0 then
			return
		end
		local count = 0
		for i = #st.strikes, 1, -1 do
			local s = st.strikes[i]
			if now - s.at > cfg.strikeDecaySeconds then
				break
			end
			if s.response ~= "log" then
				count += 1
			end
		end
		if count >= limit then
			local ok, text = pcall(ctx.text.format, st.player, "Movement.kicked")
			world.kick(st.player, if ok then text else "Removed for unusual movement")
		end
	end

	-- signals and effects, after the state is final (handlers may read lastValid)
	local function flush(st: State, now: number, newStrikes: { Strike }?, preAccepted: CFT?)
		if crossN > 0 then
			local n = crossN
			crossN = 0
			for i = 1, n do
				signals.VolumeCrossed:Fire(st.player, crossKind[i], crossInst[i])
			end
		end
		if newStrikes == nil then
			return
		end
		for _, strike in newStrikes do
			table.insert(st.strikes, strike)
			if #st.strikes > MAX_STRIKES_KEPT then
				table.remove(st.strikes, 1)
			end
			st.strikeTotal += 1
			if st.run then
				table.insert(st.run.strikes, strike)
				if strike.response ~= "log" then
					st.run.eligible = false
				end
			end
			pcall(ctx.replicate.set, st.player, "movement", `{st.strikeTotal}|{strike.reason}`)
		end
		for _, strike in newStrikes do
			signals.Strike:Fire(st.player, strike.reason, strike.details)
			if strike.response == "resetPosition" and preAccepted ~= nil then
				teleportTo(st, preAccepted, now)
			elseif strike.response == "disqualifyRun" then
				disqualify(st, strike.reason)
			end
		end
		kickCheck(st, now)
	end

	local function record(
		st: State,
		now: number,
		pos: vector,
		dt: number,
		hd: number,
		cap: number,
		grounded: boolean
	)
		local kept = cfg.samplesKept
		local i = st.sCount % kept + 1
		st.sCount += 1
		st.sAt[i], st.sX[i], st.sY[i], st.sZ[i] = now, pos.x, pos.y, pos.z
		st.sDt[i], st.sHd[i], st.sCap[i], st.sGrounded[i] = dt, hd, cap, grounded
		if nf > 0 then
			local names = fReason[1]
			for k = 2, nf do
				names ..= "," .. fReason[k]
			end
			st.sFail[i] = names
		else
			st.sFail[i] = ""
		end
	end

	-- respawn window ---------------------------------------------------------------------------------------

	local function envelopeParams(facts: any, tpLag: number, effCap: number): Caps.EnvelopeParams
		return {
			reach = cfg.anchor.reachStuds,
			effCap = effCap,
			lag = tpLag,
			jumpVelocity = facts.jumpVelocity,
			walkSpeed = facts.walkSpeed,
			launchSlack = cfg.arc.launchSlack,
			gravity = world.gravity(),
			gravitySlack = cfg.arc.gravitySlack,
			heightSlackStuds = cfg.arc.heightSlackStuds,
		}
	end

	local function respawnSample(st: State, now: number, pos: vector, cf: CFT, facts: any)
		local refs = st.refs
		if #refs == 0 then
			-- the engine had not placed the root yet at CharacterAdded: the first read is the server's placement
			refs[1] = { pos = pos, cf = cf, at = now }
			st.baseAt = now
			return
		end
		local effCap =
			Caps.effectiveSpeed(st.speedCapOverride or cfg.speedCap, facts.walkSpeed, cfg.speedSlack)
		local tpLag = Lag.teleportLag(Lag.allowance(st.ping, cfg.lag), cfg.teleport.minLagSeconds)
		local p = envelopeParams(facts, tpLag, effCap)
		local ref = refs[#refs]
		local dt = now - st.baseAt
		nf, crossN = 0, 0
		if Caps.inRespawnEnvelope(p, ref.pos.x, ref.pos.y, ref.pos.z, ref.at, now, pos.x, pos.y, pos.z) then
			-- an arrival: the replicated root agrees with the latest server-authored position
			st.respawning = false
			rebase(st, now, pos, cf, true)
			sweepVolumes(ref.pos, pos)
			local newStrikes = commitSample(st, now, pos, cf, dt)
			flush(st, now, newStrikes, nil)
			return
		end
		local stale = false
		for i = 1, #refs - 1 do
			local r = refs[i]
			if Caps.inRespawnEnvelope(p, r.pos.x, r.pos.y, r.pos.z, r.at, now, pos.x, pos.y, pos.z) then
				stale = true
			end
		end
		if st.settlePrev then
			if vector.magnitude(pos - st.settlePrev) < cfg.respawn.settleStuds then
				st.settleCount += 1
			else
				st.settleCount = 0
			end
		end
		st.settlePrev = pos
		local settled = st.settleCount >= cfg.respawn.settleSamples - 1
		local timedOut = now - ref.at >= cfg.respawn.maxSettleSeconds
		if (settled and not stale) or timedOut then
			-- settled away from every server-authored position: a respawn used as a teleport
			st.respawning = false
			local hd = math.sqrt((pos.x - ref.pos.x) ^ 2 + (pos.z - ref.pos.z) ^ 2)
			rebase(st, now, pos, cf, false)
			st.trusted, st.cleanStreak = true, 0
			st.accPos = nil
			setAccepted(st, ref.cf, now) -- the server position, unless the response leaves it trusted
			addFail("teleport", "respawn", nil, nil, hd, 0)
			local newStrikes = commitSample(st, now, pos, cf, dt)
			flush(st, now, newStrikes, ref.cf)
			return
		end
		st.baseAt = now
	end

	-- the full sample ------------------------------------------------------------------------------------

	local function verifyClimb(pos: vector, cf: CFT): boolean
		local look = CF.lookVector(cf)
		local hit = world.cast(pos, look * cfg.climb.reachStuds, castOpts)
		if hit == nil then
			return false
		end
		local inst = hit.instance
		return inst.ClassName == "TrussPart" or climbSet[inst] == true
	end

	-- noclip: a ray from the last wall cast to the sample hits a face, and the reverse ray hits a parallel face of
	-- the same part (a slab was crossed), or the sample is inside it. The edge margin and the parallel-face rule
	-- filter grazes, corner cuts and walking round a thin wall's end. Returns the part, or nil.
	local function wallCheck(from: vector, to: vector): any
		local dir = to - from
		-- both rays start 0.1 stud outside the chord, so a sample that lands exactly ON a face still counts
		local u = dir / vector.magnitude(dir)
		local hit = world.cast(from - u * WALL_BACKOFF, dir + u * WALL_BACKOFF, wallOpts)
		if hit == nil then
			return nil
		end
		local inst = hit.instance
		local bcf, size = world.boundsOf(inst)
		local inv = CF.inverse(bcf)
		local localN = CF.rotate(inv, hit.normal)
		local ax, ay, az = math.abs(localN.x), math.abs(localN.y), math.abs(localN.z)
		local axis = if ax >= ay and ax >= az then 1 elseif ay >= az then 2 else 3
		local lp = CF.pointTo(inv, hit.position)
		local lc = { lp.x, lp.y, lp.z }
		local half = { size.x * 0.5, size.y * 0.5, size.z * 0.5 }
		for a = 1, 3 do
			if a ~= axis and half[a] - math.abs(lc[a]) < cfg.wallSweep.edgeMarginStuds then
				return nil -- entered near the entry face's edge
			end
		end
		local back = world.cast(to + u * WALL_BACKOFF, -(dir + u * (2 * WALL_BACKOFF)), wallOpts)
		local penetration
		if back ~= nil then
			if back.instance ~= inst or vector.dot(hit.normal, back.normal) > -0.9 then
				return nil
			end
			penetration = vector.magnitude(back.position - hit.position)
		else
			-- no reverse hit: the sample is inside the part (a ray that starts inside a part hits nothing)
			local le = CF.pointTo(inv, to)
			if math.abs(le.x) <= half[1] and math.abs(le.y) <= half[2] and math.abs(le.z) <= half[3] then
				penetration = vector.magnitude(to - hit.position)
			else
				return nil
			end
		end
		if penetration < cfg.wallSweep.minPenetrationStuds then
			return nil
		end
		return inst
	end

	local function handleAnchor(st: State, now: number, pos: vector, cf: CFT, dt: number): boolean
		local a = st.anchor
		if a == nil then
			return false
		end
		if vector.magnitude(pos - a.target.p) <= cfg.anchor.reachStuds then
			-- the server move landed: this is the new baseline
			st.anchor = nil
			rebase(st, now, pos, cf, true)
			return true
		end
		if now - a.issuedAt >= cfg.anchor.timeoutSeconds then
			if a.mine and a.retries > 0 then
				a.retries -= 1
				a.issuedAt = now
				st.selfWrite = true
				world.setRootCFrame(st.player, a.target) -- only Movement's own teleports are ever re-issued
				st.selfWrite = false
			else
				st.anchor = nil
				local preAccepted = st.accepted
				nf, crossN = 0, 0
				addFail("teleport", "anchorTimeout", nil, nil, 0, 0)
				local newStrikes = commitSample(st, now, pos, cf, dt)
				st.base, st.baseAt, st.wallFrom, st.lastCastAt = pos, now, pos, nil
				flush(st, now, newStrikes, preAccepted)
				return true
			end
		end
		return false -- checked against the pre-move base like any sample
	end

	local function sampleState(st: State, now: number)
		if now - st.baseAt < minDt then
			return -- a catch-up call or a hitch burst: nothing new to measure
		end
		local pos, cf = world.rootOf(st.player)
		if pos == nil or cf == nil then
			return
		end
		local facts = refreshFacts(st, now)
		if facts == nil or not facts.alive then
			return
		end
		local group = facts.collisionGroup or CAST_GROUP
		castOpts.collisionGroup = group
		wallOpts.collisionGroup = group
		if st.respawning then
			if st.added then
				respawnSample(st, now, pos, cf, facts)
			end
			return
		end
		if not st.hasBase then
			rebase(st, now, pos, cf, true)
			return
		end
		if now < st.exemptUntil then
			st.exemptWas = true
			rebase(st, now, pos, cf, true)
			return
		end
		if st.exemptWas then
			st.exemptWas = false
			rebase(st, now, pos, cf, true)
			return
		end
		local dt = now - st.baseAt
		if st.anchor and handleAnchor(st, now, pos, cf, dt) then
			return
		end

		local base = st.base
		-- the cheap path: a still player who was grounded at the previous sample costs one read and a compare
		if st.grounded and st.platform == nil and st.seat == nil then
			if st.graceVel ~= nil and now - st.graceAt > cfg.platform.graceSeconds then
				st.graceVel = nil
			end
			if st.graceVel == nil then
				local dx, dz = pos.x - base.x, pos.z - base.z
				if dx * dx + dz * dz < 1e-4 and math.abs(pos.y - base.y) < 0.01 then
					st.base, st.baseAt = pos, now
					st.cleanStreak += 1
					if st.trusted then
						setAccepted(st, cf, now)
					elseif st.cleanStreak >= cfg.trustAfterCleanSamples then
						st.trusted = true
						setAccepted(st, cf, now)
					end
					return
				end
			end
		end

		local walk = facts.walkSpeed
		local effCap = Caps.effectiveSpeed(st.speedCapOverride or cfg.speedCap, walk, cfg.speedSlack)
		local tpLag = Lag.teleportLag(Lag.allowance(st.ping, cfg.lag), cfg.teleport.minLagSeconds)
		local gravity = world.gravity()

		-- the frame the root is measured in: a verified seat or a tagged platform (relative motion). A platform
		-- just left only widens the allowances for graceSeconds (its last velocity stays allowed).
		local ox, oy, oz = 0, 0, 0
		local onFrame, onPlatform, seated = false, false, false
		local fspeed, fup, fdown = 0, 0, 0
		local seatPart, seatCF = world.seatOf(st.player)
		if seatPart ~= nil and seatCF ~= nil then
			seated = true
			local prev = st.seat
			if prev ~= nil and prev.part == seatPart then
				local moved = CF.pointTo(CF.mul(seatCF, CF.inverse(prev.cf)), base)
				ox, oy, oz = moved.x - base.x, moved.y - base.y, moved.z - base.z
				onFrame = true
			end
			st.seat = { part = seatPart, cf = seatCF }
		else
			st.seat = nil
		end
		local platNowCF: CFT? = nil
		local plat = st.platform
		if not onFrame and plat ~= nil then
			platNowCF = world.boundsOf(plat.inst)
			local moved = CF.pointTo(CF.mul(platNowCF :: CFT, CF.inverse(plat.cf)), base)
			local sv = world.surfaceVelocityOf(plat.inst)
			ox, oy, oz =
				moved.x - base.x + sv.x * dt, moved.y - base.y + sv.y * dt, moved.z - base.z + sv.z * dt
			if platformSource ~= nil then
				local ok, v = pcall(platformSource, plat.inst, now)
				if ok and v ~= nil then
					ox, oy, oz = ox + v.x * dt, oy + v.y * dt, oz + v.z * dt
				end
			end
			onFrame, onPlatform = true, true
		end
		if onFrame then
			fspeed = math.sqrt(ox * ox + oy * oy + oz * oz) / dt
			fup, fdown = math.max(0, oy / dt), math.max(0, -oy / dt)
			if onPlatform then
				st.graceVel, st.graceAt = vector.create(ox / dt, oy / dt, oz / dt), now
			end
		elseif st.graceVel ~= nil then
			if now - st.graceAt <= cfg.platform.graceSeconds then
				local gv = st.graceVel
				fspeed = vector.magnitude(gv)
				fup, fdown = math.max(0, gv.y), math.max(0, -gv.y)
			else
				st.graceVel = nil
			end
		end

		-- predicted base: where the frame would have carried the previous sample
		local px, py, pz = base.x + ox, base.y + oy, base.z + oz
		local predicted = if onFrame then vector.create(px, py, pz) else base
		local rx, ry, rz = pos.x - px, pos.y - py, pos.z - pz
		local hd = math.sqrt(rx * rx + rz * rz)

		nf, crossN = 0, 0
		local sl = cfg.teleport.slackStuds

		-- teleport cap (horizontal, per sample)
		local tpCap = Caps.teleportCap(effCap, dt, tpLag, sl, fspeed, cfg.teleport.capStuds)
		local teleportFailed = false
		if hd > tpCap then
			addFail("teleport", nil, nil, nil, hd, tpCap)
			teleportFailed = true
		end
		-- descent bound (a drop no gravity-consistent fall reaches)
		if not teleportFailed then
			local maxDrop = Caps.maxDrop(
				gravity,
				cfg.arc.gravitySlack,
				dt,
				tpLag,
				sl,
				st.grounded,
				now - st.groundAt,
				fdown
			)
			if ry < -maxDrop then
				addFail("teleport", "descent", nil, nil, -ry, maxDrop)
				teleportFailed = true
			end
		end
		-- volume sweep (analytic, from the predicted base: a platform-relative start)
		sweepVolumes(predicted, pos)
		-- rise cap (per sample)
		local riseCap = Caps.riseCap(
			facts.jumpVelocity,
			walk,
			cfg.arc.launchSlack,
			cfg.speedSlack,
			dt,
			tpLag,
			cfg.rise.slackStuds,
			cfg.rise.speedCap,
			fup
		)
		if ry > riseCap then
			addFail("riseSpeed", nil, nil, nil, ry, riseCap)
		end
		-- sliding-window speed (the window's lag is the same floored teleport lag)
		if not integrityFailed() then
			local win = st.win
			Window.push(win, st.baseAt, hd, rx, rz, onFrame, fspeed)
			Window.prune(win, now - cfg.speedWindowSeconds - 1e-9)
			local oldest = Window.oldestStart(win)
			if oldest ~= nil then
				local measure = Window.measure(win)
				local limit = Caps.windowLimit(effCap, now - oldest, tpLag, sl, Window.maxFrameSpeed(win))
				if measure > limit then
					addFail("speed", nil, nil, nil, measure, limit)
				end
			end
		end

		-- ground (a downward Blockcast, skipped while grounded and level) and the jump/fall envelope
		local climbing = not seated and facts.state == "Climbing" and verifyClimb(pos, cf)
		local grounded = seated or climbing -- a verified seat or climb: the arc is suspended
		local hitInst: any = nil
		if not grounded then
			local last = st.lastCastAt
			if
				st.grounded
				and st.platform == nil
				and last ~= nil
				and math.abs(ry) < 0.05
				and vector.magnitude(pos - last) < cfg.groundCast.skipStuds
			then
				grounded = true -- cast skipped
			else
				castCF.p = pos
				local hit = world.blockcast(castCF, groundSize, groundDir, castOpts)
				st.lastCastAt = pos
				local reach = facts.hipHeight + facts.rootHalfHeight + cfg.groundCast.groundedSlackStuds
				if hit ~= nil and hit.distance <= reach then
					grounded = true
					hitInst = hit.instance
				end
			end
		end
		if not grounded and nf == 0 then
			local airAt = st.airAt or now
			local launch = Arc.launchSpeed(facts.jumpVelocity, walk, cfg.arc.launchSlack, fup)
			local g = Arc.gravity(gravity, cfg.arc.gravitySlack)
			local maxY =
				Arc.maxY(st.y0, now - airAt, tpLag, cfg.arc.graceSeconds, launch, g, cfg.arc.heightSlackStuds)
			if pos.y > maxY then
				addFail(
					if ry > 0 then "riseSpeed" else "noGround",
					nil,
					nil,
					nil,
					pos.y - st.y0,
					maxY - st.y0
				)
			end
		end

		-- noclip: a thin ray from the last wall cast to the sample, every everySamples-th sample
		local ws = cfg.wallSweep
		if ws.enabled and (seated or onPlatform) then
			st.wallFrom, st.wallCount = pos, 0 -- no cast in a moving frame: don't keep a stale start
		end
		if ws.enabled and not seated and not onPlatform and not teleportFailed then
			st.wallCount += 1
			if st.wallCount >= ws.everySamples then
				local from = st.wallFrom or base
				local wx, wz = pos.x - from.x, pos.z - from.z
				if math.sqrt(wx * wx + wz * wz) >= ws.minStuds then
					st.wallCount = 0
					st.wallFrom = pos
					local wall = wallCheck(from, pos)
					if wall ~= nil then
						addFail("wallSweep", nil, nil, wall, 0, 0)
					end
				end
			end
		end

		local struck = nf > 0
		if struck then
			st.wallFrom = pos
		end
		local preAccepted = st.accepted
		local newStrikes = commitSample(st, now, pos, cf, dt)
		record(st, now, pos, dt, hd, tpCap, grounded)

		if grounded then
			st.grounded, st.y0, st.groundAt, st.airAt = true, pos.y, now, nil
		else
			st.grounded = false
			if not struck then
				st.airAt = st.airAt or now
			end
		end
		-- the platform this sample stands on (its server CFrame is the next sample's "previous")
		local platform = if hitInst ~= nil then platformOf(hitInst) else nil
		if platform ~= nil then
			local pcf = if plat ~= nil
					and plat.inst == platform
					and platNowCF ~= nil
				then platNowCF
				else (world.boundsOf(platform))
			st.platform = { inst = platform, cf = pcf }
		else
			st.platform = nil
		end
		st.base, st.baseAt = pos, now
		flush(st, now, newStrikes, preAccepted)
	end

	-- hooks ---------------------------------------------------------------------------------------------

	local function attach(st: State)
		if st.hooked or world == nil then
			return
		end
		st.hooked = true
		local player = st.player
		local function onCharacterEvent(event: string, _character: any)
			if event == "died" or event == "removing" then
				st.respawning, st.added = true, false
				st.accepted, st.accPos, st.prevAccPos = nil, nil, nil
				st.trusted, st.cleanStreak = false, 0
				st.refs, st.anchor, st.platform, st.seat, st.graceVel = {}, nil, nil, nil, nil
			elseif event == "added" then
				local now = world.clock()
				st.respawning, st.added = true, true
				st.accepted, st.accPos, st.prevAccPos = nil, nil, nil
				st.trusted, st.cleanStreak = false, 0
				st.anchor, st.platform, st.seat, st.graceVel = nil, nil, nil, nil
				st.settleCount, st.settlePrev = 0, nil
				st.refs = {}
				local pos, cf = world.rootOf(player)
				if pos ~= nil and cf ~= nil then
					st.refs[1] = { pos = pos, cf = cf, at = now }
				end
			end
		end
		local function onServerMoveEvent(cf: CFT)
			local now = world.clock()
			if st.respawning then
				if st.added then
					table.insert(st.refs, { pos = cf.p, cf = cf, at = now })
					st.settleCount, st.settlePrev = 0, nil
				end
				return
			end
			if not st.hasBase or st.selfWrite then
				return
			end
			local a = st.anchor
			if a ~= nil and a.mine and vector.magnitude(cf.p - a.target.p) < 0.1 then
				return -- the echo of Movement's own write
			end
			st.anchor = { target = cf, issuedAt = now, mine = false, retries = 0 }
		end
		-- pcall-guarded: a harness/sim Players service may model no Character concept at all (its
		-- world.onCharacter/onServerMove then error); Movement degrades to "no character ever seen"
		-- for that player rather than failing the whole tick (the same spirit as World.live() -> nil).
		local okChar, discChar = pcall(world.onCharacter, player, onCharacterEvent)
		if okChar then
			table.insert(st.disc, discChar)
		else
			ctx.log.debug(
				`Movement: world.onCharacter errored for a player ({tostring(discChar)}); no character tracking for them`
			)
		end
		local okMove, discMove = pcall(world.onServerMove, player, onServerMoveEvent)
		if okMove then
			table.insert(st.disc, discMove)
		else
			ctx.log.debug(
				`Movement: world.onServerMove errored for a player ({tostring(discMove)}); no anchor tracking for them`
			)
		end
	end

	local function unhook(st: State)
		for _, d in st.disc do
			d()
		end
		st.disc = {}
		st.hooked = false
	end

	local function stateFor(player: any): State
		local st = states[player]
		if st == nil then
			st = newState(player)
			states[player] = st
		end
		return st
	end

	local function ensureWorld(): boolean
		if world ~= nil then
			return true
		end
		if worldTried then
			return false
		end
		worldTried = true
		local live = WorldMod.live()
		if live == nil then
			ctx.log.debug("Movement: no World (the engine services are not available); idling")
			return false
		end
		world = live
		wireAllVolumes()
		return true
	end

	local function clearBaselines(st: State)
		st.hasBase = false
		st.respawning, st.added = false, false
		st.accepted, st.accPos, st.prevAccPos = nil, nil, nil
		st.trusted, st.cleanStreak = false, 0
		st.anchor, st.platform, st.seat, st.graceVel = nil, nil, nil, nil
		st.refs, st.facts, st.pingAt = {}, nil, -math.huge
		st.baseAt = -math.huge
		st.exemptWas = false
		Window.clear(st.win)
	end

	local function tick(_dt: number)
		if not ensureWorld() then
			return
		end
		if not flagOn() then
			wasOff = true
			return
		end
		if wasOff then
			-- flag on again: every player's next sample is a fresh, trusted baseline (a mid-respawn player keeps the rule)
			wasOff = false
			for _, st in states do
				if not st.respawning then
					st.hasBase = false
					st.flagRebase = true
					st.baseAt = -math.huge
					st.anchor = nil
				end
			end
		end
		local cursor = tickN % buckets
		tickN += 1
		if playerList == nil or cursor == 0 then
			local list = world.players()
			playerList = list
			for b = 1, buckets do
				table.clear(bucketLists[b])
			end
			for i = 1, #list do
				local st = stateFor(list[i])
				local bl = bucketLists[st.bucket + 1]
				bl[#bl + 1] = st
			end
		end
		local now = world.clock()
		local bl = bucketLists[cursor + 1]
		for i = 1, #bl do
			local st = bl[i]
			if states[st.player] == st then -- not removed by a handler earlier in this call
				if not st.hooked then
					attach(st)
				end
				sampleState(st, now)
			end
		end
	end

	-- api -------------------------------------------------------------------------------------------------

	local api: any = {}

	function api.startRun(player: any, runId: string)
		local st = stateFor(player)
		local clock = if world then world.clock() else 0
		st.run = { id = runId, startedAt = clock, eligible = true, disqualified = false, strikes = {} }
	end

	function api.endRun(player: any, runId: string): (boolean, { Strike })
		local st = states[player]
		local run = if st then st.run else nil
		if st == nil or run == nil or run.id ~= runId then
			return false, {}
		end
		st.run = nil
		return run.eligible, table.freeze(table.clone(run.strikes))
	end

	function api.teleport(player: any, cframe: any)
		if not ensureWorld() then
			return
		end
		local st = stateFor(player)
		attach(st)
		teleportTo(st, toCF(cframe), world.clock())
	end

	function api.exempt(player: any, seconds: number?, reason: string?)
		local st = stateFor(player)
		local clock = if world then world.clock() else 0
		st.exemptUntil = clock + (seconds or cfg.exemptDefaultSeconds)
		st.exemptReason = reason
	end

	function api.strikes(player: any): { Strike }
		local st = states[player]
		if st == nil then
			return table.freeze({})
		end
		return table.freeze(table.clone(st.strikes))
	end

	function api.lastValid(player: any): (any, boolean)
		local st = states[player]
		if
			st == nil
			or world == nil
			or st.respawning
			or not st.hasBase
			or st.accepted == nil
			or not flagOn()
		then
			return nil, false
		end
		return fromCF(st.accepted), st.trusted
	end

	-- Is Movement policing positions right now (for `player`, if given)? False with the flag off, with no World,
	-- and from the flag turning back on until the player's fresh baseline. Carry falls back to its own clamp then,
	-- exactly as with Movement absent, instead of reading lastValid's (nil, false) as "untrusted".
	function api.active(player: any?): boolean
		if world == nil or wasOff or not flagOn() then
			return false
		end
		if player ~= nil then
			local st = states[player]
			if st ~= nil and st.flagRebase then
				return false
			end
		end
		return true
	end

	function api.velocity(player: any): any
		local st = states[player]
		if st == nil or st.accPos == nil or st.prevAccPos == nil then
			return nil
		end
		local span = st.acceptedAt - st.prevAccAt
		if span <= 0 then
			return nil
		end
		return (st.accPos - st.prevAccPos) / span
	end

	function api.registerVolume(tag: string, kind: string)
		if type(tag) ~= "string" or tag == "" then
			error("Movement.registerVolume: tag must be a non-empty string", 2)
		end
		if KINDS[kind] ~= true then
			error(
				`Movement.registerVolume: '{tostring(kind)}' is not a volume kind (hazard, noEntry, checkpoint, platform, climbable)`,
				2
			)
		end
		if volumeKinds[tag] ~= nil then
			unwireTag(tag)
		end
		volumeKinds[tag] = kind
		wireTag(tag)
	end

	function api.registerPlatformSource(fn: (any, number) -> any)
		if type(fn) ~= "function" then
			error("Movement.registerPlatformSource: expected a function(part, t) -> Vector3", 2)
		end
		platformSource = fn
	end

	function api.setSpeedCap(player: any, studsPerSec: number?)
		stateFor(player).speedCapOverride = studsPerSec
	end

	function api.setResponse(check: string, response: string)
		if CHECKS[check] ~= true then
			error(`Movement.setResponse: '{tostring(check)}' is not a check name`, 2)
		end
		if RESPONSES[response] ~= true then
			error(
				`Movement.setResponse: '{tostring(response)}' is not a response (log, strike, resetPosition, disqualifyRun)`,
				2
			)
		end
		overrides[check] = response
	end

	-- the test seam: swaps the adapter and clears every per-player baseline (the same as flipping the flag off and on)
	function api.useWorld(w: any)
		for _, st in states do
			unhook(st)
			clearBaselines(st)
		end
		unwireAllVolumes()
		world = w
		worldTried = true
		playerList = nil
		wasOff = false
		if cfg ~= nil then
			wireAllVolumes()
		end
	end

	api.signals = signals
	part.api = api

	function part.init(c: any)
		ctx = c
		cfg = ctx.config
		minDt = cfg.minSampleFraction / cfg.sampleHz
		buckets = cfg.staggerBuckets
		table.clear(bucketLists)
		for b = 1, buckets do
			bucketLists[b] = {}
		end
		groundSize = vector.create(cfg.groundCast.footprintStuds, 0.2, cfg.groundCast.footprintStuds)
		groundDir = vector.create(0, -cfg.groundCast.lengthStuds, 0)
		for _, name in SIGNALS do
			signals[name] = ctx.signals.new(name)
		end
		for tag, kind in cfg.volumes do
			volumeKinds[tag] = kind
		end
		if world ~= nil then
			wireAllVolumes()
		end
		if ctx.isStudio then
			ctx.console.register(
				"samples",
				function(_player: any, userId: any, n: any): string
					local uid = tonumber(userId)
					local found: State? = nil
					for _, st in states do
						if st.userId == uid then
							found = st
						end
					end
					if found == nil then
						return "no sampled player with that userId"
					end
					local st: State = found
					local kept = cfg.samplesKept
					local want = math.min(tonumber(n) or 10, kept, st.sCount)
					if want <= 0 then
						return "no samples yet"
					end
					local lines = {}
					for k = want - 1, 0, -1 do
						local i = (st.sCount - 1 - k) % kept + 1
						table.insert(
							lines,
							string.format(
								"t=%.2f pos=(%.1f, %.1f, %.1f) dt=%.3f hd=%.2f cap=%.2f grounded=%s fail=%s",
								st.sAt[i],
								st.sX[i],
								st.sY[i],
								st.sZ[i],
								st.sDt[i],
								st.sHd[i],
								st.sCap[i],
								tostring(st.sGrounded[i]),
								if st.sFail[i] == "" then "-" else st.sFail[i]
							)
						)
					end
					return table.concat(lines, "\n")
				end,
				"movement samples <userId> [n]: a player's last n samples (position, dt, displacement, caps, grounded, check results)"
			)
		end
	end

	function part.start(_ctx: any)
		ctx.lifecycle.onTick(1 / (cfg.sampleHz * cfg.staggerBuckets), tick)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			local st = states[player]
			if st == nil then
				return
			end
			if st.run then
				disqualify(st, "left")
			end
			unhook(st)
			states[player] = nil
			playerList = nil
		end)
	end

	return part
end

return Server
