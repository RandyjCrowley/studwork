--!strict
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
assert(game:GetService("RunService"):IsStudio(), "Local fixture only")
local StudWork = require(RS:WaitForChild("Framework"))
StudWork.start(require(RS.Game.Config))
local api = StudWork.use(require(RS.Modules.Companions.module))
api.registerLook("Golden", function(model: Instance, _definition: any)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Color = Color3.fromRGB(255, 195, 35)
			part.Material = Enum.Material.Metal
		end
	end
end)
local diagnostics = Instance.new("BindableFunction")
diagnostics.Name = "CompanionsFixture"
diagnostics.OnInvoke = function(command: string, value: boolean?)
	if command == "transforms" then
		local transforms = {}
		local folder = workspace:FindFirstChild("CompanionVisuals")
		if folder then
			for _, visual in folder:GetChildren() do
				if visual:IsA("Model") or visual:IsA("BasePart") then
					transforms[visual.Name] = visual:GetPivot()
				end
			end
		end
		return transforms
	elseif command == "lowDetail" then
		api.setLowDetail(value == true)
	elseif command == "reducedMotion" then
		Players.LocalPlayer:SetAttribute("CoreReducedMotion", value == true)
	elseif command == "open" then
		api.open()
	end
	return api.debugStats()
end
diagnostics.Parent = Players.LocalPlayer:WaitForChild("PlayerScripts")
task.delay(3, api.open)
