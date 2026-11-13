--!strict
--[[
	ScaledRoot: a full-screen root frame for a ScreenGui that applies the responsive UIScale
	(Responsive.scale) WITHOUT pushing content off screen. A UIScale under a plain
	UDim2.fromScale(1, 1) frame scales the frame itself past the screen edges; ScaledRoot sizes
	itself to 1/scale so after scaling it covers exactly the screen.

	Usage: root:render(e(UI.ScaledRoot, nil, { MyScreen = e(MyScreen) }))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Responsive = require(script.Parent.Responsive)
local UserScale = require(script.Parent.UserScale)

local e = React.createElement

local function currentScale(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 1
	end
	local v = camera.ViewportSize
	local player = Players.LocalPlayer
	return UserScale.combined(
		Responsive.scale(v.X, v.Y),
		if player then player:GetAttribute("CoreUIScale") else nil
	)
end

local function ScaledRoot(props: { children: any? })
	local scale, setScale = React.useBinding(currentScale())
	React.useEffect(function()
		local viewportConn: RBXScriptConnection? = nil
		local function watch()
			if viewportConn then
				viewportConn:Disconnect()
				viewportConn = nil
			end
			local camera = Workspace.CurrentCamera
			if camera then
				viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
					setScale(currentScale())
				end)
			end
			setScale(currentScale())
		end
		watch()
		local cameraConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch)
		local player = Players.LocalPlayer
		local preferenceConn = if player
			then player:GetAttributeChangedSignal("CoreUIScale"):Connect(function()
				setScale(currentScale())
			end)
			else nil
		return function()
			cameraConn:Disconnect()
			if preferenceConn then
				preferenceConn:Disconnect()
			end
			if viewportConn then
				viewportConn:Disconnect()
			end
		end
	end, {})
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = scale:map(function(s: number)
			return UDim2.fromScale(1 / s, 1 / s)
		end),
	}, {
		Scale = e("UIScale", { Scale = scale }),
		Content = e(React.Fragment, nil, props.children),
	})
end

return ScaledRoot
