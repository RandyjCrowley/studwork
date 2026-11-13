--!strict
-- The Movement demo's world pieces (owner: the Movement builder): a hazard volume, a noEntry
-- volume, a tagged moving platform, a seat and a truss (Tuning.movement,
-- examples/carry/src/shared/Config/TuningMovement.luau). The scripted teleport cheat is client-side:
-- src/client/Main.client.luau.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))
local T = Tuning.movement

local MovementWorld = {}

-- A part from a props table. Three keys are not settable properties in the engine, so they are handled here:
-- ClassName picks the class at creation (it is read-only afterwards), Tags go through CollectionService, and
-- Parent is set last, once the part is fully built.
local function part(props: { [string]: any }): BasePart
	local p: any = if props.ClassName == "TrussPart" then Instance.new("TrussPart") else Instance.new("Part")
	assert(
		props.ClassName == nil or p.ClassName == props.ClassName,
		"MovementWorld.part: unsupported ClassName"
	)
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		if k ~= "ClassName" and k ~= "Tags" and k ~= "Parent" then
			p[k] = v
		end
	end
	for _, tag in props.Tags or {} do
		CollectionService:AddTag(p, tag)
	end
	p.Parent = props.Parent
	return p
end

function MovementWorld.build(folder: Folder)
	if next(T) == nil then
		return -- Tuning.movement is empty (an earlier boot without the demo pieces)
	end

	-- the hazard: tagged "Hazard" (config.Movement.volumes.Hazard = "hazard"), passable (no collide)
	part({
		Name = "Hazard",
		Size = T.hazard.size,
		Position = T.hazard.position,
		CanCollide = false,
		Transparency = 0.4,
		Color = Color3.fromHex("#E04B4B"),
		Tags = { "Hazard" },
		Parent = folder,
	})

	-- the no-entry block: behind a wall a legitimate player never reaches
	part({
		Name = "NoEntryWall",
		Size = Vector3.new(2, 10, 30),
		Position = T.noEntry.position - Vector3.new(T.noEntry.size.X / 2 + 1, 0, 0),
		Color = Color3.fromHex("#555555"),
		Parent = folder,
	})
	part({
		Name = "NoEntry",
		Size = T.noEntry.size,
		Position = T.noEntry.position,
		CanCollide = false,
		Transparency = 0.6,
		Color = Color3.fromHex("#8A2BE2"),
		Tags = { "NoEntry" },
		Parent = folder,
	})

	-- the moving platform: tagged "MovingPlatform" (config.Movement.volumes.MovingPlatform = "platform")
	local platform = part({
		Name = "MovingPlatform",
		Size = T.platform.size,
		Position = T.platform.position,
		Color = Color3.fromHex("#4B8BE0"),
		Tags = { "MovingPlatform" },
		Parent = folder,
	})
	local origin = T.platform.position
	local travel, speed = T.platform.travel, T.platform.speed
	local period = travel * 4 / speed -- a full back-and-forth triangle wave
	RunService.Heartbeat:Connect(function()
		if platform.Parent == nil then
			return
		end
		local u = (os.clock() % period) / period * 4
		local tri = if u < 1 then u elseif u < 3 then 2 - u else u - 4
		platform.CFrame = CFrame.new(origin + Vector3.new(tri * travel, 0, 0))
	end)

	-- a real seat: the engine creates the SeatWeld itself when a humanoid sits
	local seat = Instance.new("Seat")
	seat.Anchored = true
	seat.Size = Vector3.new(4, 1, 4)
	seat.Position = T.seat.position
	seat.Color = Color3.fromHex("#C9A227")
	seat.Parent = folder

	-- a truss: Movement's climb check accepts ClassName == "TrussPart" with no tag needed
	part({
		Name = "Truss",
		ClassName = "TrussPart",
		Size = Vector3.new(2, T.truss.height, 2),
		Position = T.truss.position,
		Color = Color3.fromHex("#8B5A2B"),
		Parent = folder,
	})

	-- a climbable-tagged ladder, next to the truss: the other accepted climb surface
	part({
		Name = "Climbable",
		Size = Vector3.new(2, T.truss.height, 2),
		Position = T.truss.position + Vector3.new(6, 0, 0),
		Color = Color3.fromHex("#8B5A2B"),
		Transparency = 0.3,
		Tags = { "Climbable" },
		Parent = folder,
	})
end

return MovementWorld
