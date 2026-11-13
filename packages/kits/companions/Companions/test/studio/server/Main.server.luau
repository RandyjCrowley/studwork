--!strict
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
assert(RunService:IsStudio(), "Local fixture only")
local StudWork = require(RS:WaitForChild("Framework"))
local assets = Instance.new("Folder")
assets.Name = "GameAssets"
assets.Parent = RS
for index, name in { "Walker", "Hopper", "Flyer" } do
	local model = Instance.new("Model")
	model.Name = name
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2, 2, 2)
	body.Color = Color3.fromHSV(index / 3, 0.6, 1)
	body.Anchored = true
	body.Parent = model
	model.PrimaryPart = body
	model.Parent = assets
end
local function ground(name: string, size: Vector3, position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.Parent = workspace
	return part
end
ground("Ground", Vector3.new(150, 1, 150), Vector3.new(0, -1, 0))
for index = 1, 5 do
	ground("Step", Vector3.new(8, index, 3), Vector3.new(10, index / 2, index * 3))
end
local platform = ground("MovingPlatform", Vector3.new(10, 1, 10), Vector3.new(-15, 2, 0))
RunService.Heartbeat:Connect(function()
	platform.Position = Vector3.new(-15, 2, math.sin(os.clock()) * 12)
end)
StudWork.start(require(RS.Game.Config), { admins = {} })
StudWork.use(require(RS.Modules.Companions.module))
	.registerLook("Golden", function(model: Instance, _definition: any)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Color = Color3.fromRGB(255, 195, 35)
				part.Material = Enum.Material.Metal
			end
		end
	end)
