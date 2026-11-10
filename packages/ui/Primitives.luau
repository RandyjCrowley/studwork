--!strict
--[[
	Small element helpers shared by the kit (UICorner/UIStroke/UIPadding/UIGradient/shadow).
	Each returns a React element; pass them as children.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Theme = require(script.Parent.Theme)

local e = React.createElement

local Primitives = {}

function Primitives.corner(radius: number?)
	return e("UICorner", { CornerRadius = UDim.new(0, radius or Theme.metrics.cornerRadius) })
end

function Primitives.stroke(color: Color3?, thickness: number?, transparency: number?)
	return e("UIStroke", {
		Color = color or Theme.color("outline"),
		Thickness = thickness or Theme.metrics.strokeThickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Primitives.padding(px: number?)
	local p = Theme.padding(px)
	return e("UIPadding", { PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p })
end

function Primitives.gradient(base: Color3, lift: number?)
	return e("UIGradient", { Color = Theme.gradient(base, lift), Rotation = 90 })
end

-- Soft drop shadow: an offset, semi-transparent rounded frame behind the parent (ZIndex -1).
function Primitives.shadow(offset: number?, radius: number?)
	local o = offset or 4
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, o),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		ZIndex = -1,
	}, {
		Corner = Primitives.corner(radius),
	})
end

function Primitives.list(direction: Enum.FillDirection?, gap: number?, align: Enum.HorizontalAlignment?)
	return e("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 8),
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function Primitives.textSize(min: number, max: number)
	return e("UITextSizeConstraint", { MinTextSize = min, MaxTextSize = max })
end

return Primitives
