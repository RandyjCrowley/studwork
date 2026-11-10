--!strict
--[[
	AutoScale: a UIScale that follows the camera viewport (Responsive.scale), so layouts authored
	in design pixels grow on tablets/desktop and stay legible on phones. Put one directly under a
	ScreenGui's root frame. No props (optional `min`/`max` overrides are not exposed on purpose:
	Theme.touchTarget relies on Responsive.MIN_SCALE).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Responsive = require(script.Parent.Responsive)

local e = React.createElement

local function currentScale(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 1
	end
	local v = camera.ViewportSize
	return Responsive.scale(v.X, v.Y)
end

local function AutoScale(_props: {})
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
		return function()
			cameraConn:Disconnect()
			if viewportConn then
				viewportConn:Disconnect()
			end
		end
	end, {})
	return e("UIScale", { Scale = scale })
end

return AutoScale
