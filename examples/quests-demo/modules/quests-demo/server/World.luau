--!strict
--[[
	The quests demo world, built in code from Tuning.luau (no place file needed), under
	Workspace.DemoWorld:
	  - Ground and a SpawnLocation
	  - coin spots tagged "DemoCoin" (the first goal's target, tag form)
	  - DemoGuide (the story quest giver; the third goal's target, path form)
	  - DemoBoard, tagged "DemoBoard" (the "what's next" target after the chain)
	  - DemoTower, 600 studs away: beyond StreamingTargetRadius (256), so the edge arrow and the
	    goal's fallback position are what the player sees until it streams in
	World.canBuild() is false where there are no engine instances (Lune specs, the sim).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))

local World = {}

World.FOLDER = "DemoWorld"

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

-- CollectionService, or nil where there is none (a Lune spec's fake game has no such service)
local function collection(): any
	local ok, service = pcall(function(): any
		return game:GetService("CollectionService")
	end)
	return if ok then service else nil
end

function World.canBuild(): boolean
	local service = collection()
	local ok, addTag = pcall(function(): any
		return service and service.AddTag
	end)
	return ok and type(addTag) == "function"
end

function World.find(): Instance?
	return Workspace:FindFirstChild(World.FOLDER)
end

function World.build(): Instance
	local existing = World.find()
	if existing then
		return existing
	end
	local CollectionService = collection()
	local folder = Instance.new("Folder")
	folder.Name = World.FOLDER

	local ground = Tuning.groundSize
	part({
		Name = "Ground",
		Size = vec(ground),
		Position = Vector3.new(0, -ground[2] / 2, Tuning.groundCenterZ),
		Material = Enum.Material.Grass,
		Parent = folder,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Position = vec(Tuning.spawnPosition)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = folder

	for i, xz in Tuning.coinSpots do
		local coin = part({
			Name = "DemoCoin" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1, Tuning.coinSize, Tuning.coinSize),
			Position = Vector3.new(xz[1], Tuning.coinHeight, xz[2]),
			Material = Enum.Material.Neon,
			CanCollide = false,
			Parent = folder,
		})
		CollectionService:AddTag(coin, "DemoCoin")
	end

	part({
		Name = "DemoGuide",
		Size = vec(Tuning.guideSize),
		Position = vec(Tuning.guidePosition),
		Parent = folder,
	})

	local board = part({
		Name = "DemoBoard",
		Size = vec(Tuning.boardSize),
		Position = vec(Tuning.boardPosition),
		Parent = folder,
	})
	CollectionService:AddTag(board, "DemoBoard")

	part({
		Name = "DemoTower",
		Size = vec(Tuning.towerSize),
		Position = vec(Tuning.towerPosition),
		Material = Enum.Material.Slate,
		Parent = folder,
	})

	folder.Parent = Workspace
	return folder
end

return World
