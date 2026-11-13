--!strict
--[[
	World: the Carry module's live adapter (docs/framework/kits/carry.md, "The World seam").

	Every world fact Carry reads goes through this table, so the Lune harness (no Workspace,
	CFrame, CollectionService or RunService) can swap in tests/FakeWorld.luau through
	Carry.useWorld(world). World.live() fetches the services LAZILY, inside a pcall, and returns nil
	when they are not available (the harness, test-adopt, a new-game boot spec): the module then
	idles. Never call it at module load or in init; the first tick (or start) is the earliest.

	The World type is spelled the same in Carry/shared/World.luau and Movement/shared/World.luau.
	Each live adapter implements only the members its module uses: the others raise
	"<member> is not used by Carry" (add the member here when Carry starts needing it).

	Positions are Luau `vector` values; orientation is ./CF.luau. Only this file converts to and
	from Vector3 / CFrame.
]]

local CF = require(script.Parent.CF)
local Jump = require(script.Parent.Jump)
local CastCache = require(script.Parent.CastCache)

export type CF = CF.CF
export type HumanoidFacts = {
	alive: boolean,
	walkSpeed: number,
	jumpVelocity: number, -- Jump.velocity: JumpPower, or sqrt(2 * g * JumpHeight)
	hipHeight: number,
	rootHalfHeight: number,
	state: string, -- informational only, never an exemption
	collisionGroup: string?, -- the root part's CollisionGroup: Movement's casts use it as the character's group
}
export type Hit = { instance: any, position: vector, normal: vector, distance: number }
-- respectCanCollide: skip CanCollide = false parts (RaycastParams.RespectCanCollide; the engine default is false,
-- so a plain cast hits every CanQuery = true part, colliding or not)
export type CastOpts = {
	exclude: { any }?,
	collisionGroup: string?,
	ignoreCharacters: boolean?,
	respectCanCollide: boolean?,
}
export type World = {
	clock: () -> number, -- monotonic seconds (live: os.clock())
	players: () -> { Player },
	rootOf: (player: Player) -> (vector?, CF?), -- nil: no character, no root, or not in Workspace
	humanoidFacts: (player: Player) -> HumanoidFacts?,
	seatOf: (player: Player) -> (any?, CF?), -- only a server Seat/VehicleSeat with a SeatWeld to this root
	ping: (player: Player) -> number, -- seconds, round trip (live: GetNetworkPing; 0 if unknown)
	gravity: () -> number,
	killY: () -> number,
	cast: (origin: vector, dir: vector, opts: CastOpts) -> Hit?,
	blockcast: (cf: CF, size: vector, dir: vector, opts: CastOpts) -> Hit?,
	boundsOf: (inst: any) -> (CF, vector),
	surfaceVelocityOf: (inst: any) -> vector,
	tagged: (tag: string) -> { any },
	onTagAdded: (tag: string, fn: (any) -> ()) -> () -> (),
	onTagRemoved: (tag: string, fn: (any) -> ()) -> () -> (),
	onCharacter: (
		player: Player,
		fn: (event: "added" | "removing" | "died", character: any) -> ()
	) -> () -> (),
	onServerMove: (player: Player, fn: (cf: CF) -> ()) -> () -> (),
	setCFrame: (inst: any, cf: CF) -> (),
	setRootCFrame: (player: Player, cf: CF) -> (),
	anchor: (inst: any) -> (),
	unanchor: (inst: any) -> (),
	setCollide: (inst: any, on: boolean) -> (),
	setQuery: (inst: any, on: boolean) -> (), -- CanQuery: off = invisible to every raycast and spatial query
	setCollisionGroup: (inst: any, group: string) -> (),
	velocityOf: (inst: any) -> vector,
	setVelocity: (inst: any, v: vector) -> (),
	setWalkSpeed: (player: Player, speed: number) -> (),
	setAttribute: (inst: any, name: string, value: any) -> (),
	kick: (player: Player, message: string) -> (),
}

local World = {}

local ZERO = vector.create(0, 0, 0)

local function unused(member: string): any
	return function()
		error(member .. " is not used by Carry", 2)
	end
end

local function toVec(v: any): vector
	return vector.create(v.X, v.Y, v.Z)
end

local function toVector3(v: vector): any
	return (Vector3 :: any).new(v.x, v.y, v.z)
end

local function charOf(player: any): any
	return player.Character
end

local function rootPart(player: any): any
	local character = charOf(player)
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function humanoidOf(player: any): any
	local character = charOf(player)
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- every BasePart of an instance (the part itself, or a Model's descendants)
local function partsOf(inst: any): { any }
	if inst:IsA("BasePart") then
		return { inst }
	end
	local parts = {}
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

-- the part whose assembly stands for the instance (a Model's PrimaryPart, else its first part)
local function mainPart(inst: any): any
	if inst:IsA("BasePart") then
		return inst
	end
	return inst.PrimaryPart or partsOf(inst)[1]
end

-- The live adapter, or nil when the engine services are not available (never raises).
function World.live(): World?
	local ok, services = pcall(function(): any
		return {
			Workspace = game:GetService("Workspace"),
			Players = game:GetService("Players"),
			CollectionService = game:GetService("CollectionService"),
			RunService = game:GetService("RunService"),
		}
	end)
	if not ok or services == nil or services.Workspace == nil or services.Players == nil then
		return nil
	end
	local Workspace: any = services.Workspace
	local Players: any = services.Players
	local CollectionService: any = services.CollectionService

	-- The landing probe's casts: one RaycastParams per option set and an event-driven character exclude list,
	-- the same CastCache as Movement's adapter (a byte-identical copy; tests/SharedCopies.spec.luau).
	local function connection(signal: any, fn: (any) -> ()): () -> ()
		local c = signal:Connect(fn)
		return function()
			c:Disconnect()
		end
	end
	local casts = CastCache.new({
		newParams = function(): any
			return (RaycastParams :: any).new()
		end,
		excludeFilter = function(): any
			return (Enum :: any).RaycastFilterType.Exclude
		end,
		getPlayers = function(): { any }
			return Players:GetPlayers()
		end,
		playerAdded = function(fn: (any) -> ()): () -> ()
			return connection(Players.PlayerAdded, fn)
		end,
		playerRemoving = function(fn: (any) -> ()): () -> ()
			return connection(Players.PlayerRemoving, fn)
		end,
		characterAdded = function(player: any, fn: (any) -> ()): () -> ()
			return connection(player.CharacterAdded, fn)
		end,
		characterRemoving = function(player: any, fn: (any) -> ()): () -> ()
			return connection(player.CharacterRemoving, fn)
		end,
	})

	return {
		clock = os.clock,
		players = function(): { Player }
			return Players:GetPlayers()
		end,
		rootOf = function(player: Player): (vector?, CF?)
			local root = rootPart(player)
			if root == nil or not root:IsDescendantOf(Workspace) then
				return nil, nil
			end
			local cf = CF.fromCFrame(root.CFrame)
			return cf.p, cf
		end,
		humanoidFacts = function(player: Player): HumanoidFacts?
			local humanoid, root = humanoidOf(player), rootPart(player)
			if humanoid == nil or root == nil then
				return nil
			end
			local state = humanoid:GetState()
			local jump = Jump.velocity(
				humanoid.UseJumpPower,
				humanoid.JumpPower,
				humanoid.JumpHeight,
				Workspace.Gravity
			)
			return {
				alive = humanoid.Health > 0 and state ~= (Enum :: any).HumanoidStateType.Dead,
				walkSpeed = humanoid.WalkSpeed,
				jumpVelocity = jump,
				hipHeight = humanoid.HipHeight,
				rootHalfHeight = root.Size.Y / 2,
				state = state.Name,
				collisionGroup = root.CollisionGroup,
			}
		end,
		seatOf = unused("seatOf"),
		ping = unused("ping"),
		gravity = function(): number
			return Workspace.Gravity
		end,
		killY = function(): number
			return Workspace.FallenPartsDestroyHeight
		end,
		cast = function(origin: vector, dir: vector, opts: CastOpts): Hit?
			-- the hard-landing ground probe (a tick where a carried object goes lower), through the cached params
			local result = Workspace:Raycast(toVector3(origin), toVector3(dir), casts.params(opts))
			if result == nil then
				return nil
			end
			local position = toVec(result.Position)
			return {
				instance = result.Instance,
				position = position,
				normal = toVec(result.Normal),
				distance = vector.magnitude(position - origin),
			}
		end,
		blockcast = unused("blockcast"),
		boundsOf = function(inst: any): (CF, vector)
			if inst:IsA("Model") then
				local cf, size = inst:GetBoundingBox()
				return CF.fromCFrame(cf), toVec(size)
			end
			return CF.fromCFrame(inst.CFrame), toVec(inst.Size)
		end,
		surfaceVelocityOf = unused("surfaceVelocityOf"),
		tagged = function(tag: string): { any }
			return CollectionService:GetTagged(tag)
		end,
		onTagAdded = function(tag: string, fn: (any) -> ()): () -> ()
			local connection = CollectionService:GetInstanceAddedSignal(tag):Connect(fn)
			return function()
				connection:Disconnect()
			end
		end,
		onTagRemoved = function(tag: string, fn: (any) -> ()): () -> ()
			local connection = CollectionService:GetInstanceRemovedSignal(tag):Connect(fn)
			return function()
				connection:Disconnect()
			end
		end,
		-- Fires for characters that arrive AFTER the call (a character already in the world is not replayed).
		onCharacter = function(
			player: Player,
			fn: (event: "added" | "removing" | "died", character: any) -> ()
		): () -> ()
			local connections: { any } = {}
			local function watchDeath(character: any)
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid ~= nil then
					table.insert(
						connections,
						humanoid.Died:Connect(function()
							fn("died", character)
						end)
					)
				end
			end
			table.insert(
				connections,
				(player :: any).CharacterAdded:Connect(function(character: any)
					watchDeath(character)
					fn("added", character)
				end)
			)
			table.insert(
				connections,
				(player :: any).CharacterRemoving:Connect(function(character: any)
					fn("removing", character)
				end)
			)
			local current = charOf(player)
			if current ~= nil then
				watchDeath(current)
			end
			return function()
				for _, c in connections do
					c:Disconnect()
				end
				table.clear(connections)
			end
		end,
		onServerMove = unused("onServerMove"),
		setCFrame = function(inst: any, cf: CF)
			if inst:IsA("Model") then
				inst:PivotTo(CF.toCFrame(cf))
			else
				inst.CFrame = CF.toCFrame(cf)
			end
		end,
		setRootCFrame = unused("setRootCFrame"),
		anchor = function(inst: any)
			for _, part in partsOf(inst) do
				part.Anchored = true
			end
		end,
		-- anchored parts are always server-owned and SetNetworkOwner errors on them, so the owner is
		-- cleared only after unanchoring
		unanchor = function(inst: any)
			for _, part in partsOf(inst) do
				part.Anchored = false
			end
			local main = mainPart(inst)
			if main ~= nil then
				pcall(function()
					main:SetNetworkOwner(nil)
				end)
			end
		end,
		setCollide = function(inst: any, on: boolean)
			for _, part in partsOf(inst) do
				part.CanCollide = on
			end
		end,
		setQuery = function(inst: any, on: boolean)
			for _, part in partsOf(inst) do
				part.CanQuery = on
			end
		end,
		setCollisionGroup = function(inst: any, group: string)
			for _, part in partsOf(inst) do
				part.CollisionGroup = group
			end
		end,
		velocityOf = function(inst: any): vector
			local part = mainPart(inst)
			if part == nil then
				return ZERO
			end
			return toVec(part.AssemblyLinearVelocity)
		end,
		setVelocity = function(inst: any, v: vector)
			for _, part in partsOf(inst) do
				part.AssemblyLinearVelocity = toVector3(v)
				if v == ZERO then
					part.AssemblyAngularVelocity = toVector3(ZERO)
				end
			end
		end,
		setWalkSpeed = function(player: Player, speed: number)
			local humanoid = humanoidOf(player)
			if humanoid ~= nil then
				humanoid.WalkSpeed = speed
			end
		end,
		setAttribute = function(inst: any, name: string, value: any)
			inst:SetAttribute(name, value)
		end,
		kick = unused("kick"),
	}
end

return World
