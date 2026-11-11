--!strict
--[[
	Builds the sandbox world in code (no place file needed): spawn, 6 plots tagged "CorePlot"
	with 8 "SlotId" pads each, and the glowing collect block in the middle.
	A real game would ship these as models in the place; Core.Plot works with either.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local World = {}

local PLOT_COUNT = 6
local PLOT_RADIUS = 70
local SLOTS = 8

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

function World.build(): BasePart
	local folder = Instance.new("Folder")
	folder.Name = "SandboxWorld"

	part({
		Name = "Ground",
		Size = Vector3.new(260, 2, 260),
		Position = Vector3.new(0, -1, 0),
		Color = Color3.fromHex("#7BC67B"),
		Parent = folder,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.Position = Vector3.new(0, 0.5, 20)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = folder

	for i = 1, PLOT_COUNT do
		local angle = (i - 1) / PLOT_COUNT * math.pi * 2
		local center = Vector3.new(math.cos(angle) * PLOT_RADIUS, 0, math.sin(angle) * PLOT_RADIUS)
		local plot = Instance.new("Model")
		plot.Name = "Plot" .. i
		local base = part({
			Name = "Base",
			Size = Vector3.new(36, 1, 36),
			CFrame = CFrame.lookAt(center, Vector3.zero) * CFrame.new(0, 0.5, 0),
			Color = Color3.fromHex("#3A4170"),
			Parent = plot,
		})
		plot.PrimaryPart = base
		for s = 1, SLOTS do
			local col = (s - 1) % 4
			local row = (s - 1) // 4
			local pad = part({
				Name = "Slot" .. s,
				Size = Vector3.new(5, 0.4, 5),
				CFrame = base.CFrame * CFrame.new((col - 1.5) * 8, 0.7, (row - 0.5) * 10),
				Color = Color3.fromHex("#2B3050"),
				Parent = plot,
			})
			pad:SetAttribute("SlotId", string.format("slot%02d", s))
		end
		plot.Parent = folder
		CollectionService:AddTag(plot, "CorePlot")
	end

	local block = part({
		Name = "CollectBlock",
		Size = Vector3.new(6, 6, 6),
		Position = Vector3.new(0, 3, 0),
		Color = Color3.fromHex("#FFB547"),
		Material = Enum.Material.Neon,
		Parent = folder,
	})

	folder.Parent = Workspace
	return block
end

return World
