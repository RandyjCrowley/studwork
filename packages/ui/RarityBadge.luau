--!strict
--[[
	RarityBadge: pill with the tier colour, glow stroke scaled by the theme tier glowStrength.

	props: rarity: string (RarityTier), layoutOrder: number?, size: UDim2? (auto by default)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local TextFit = require(script.Parent.TextFit)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Props = {
	rarity: string,
	layoutOrder: number?,
	size: UDim2?,
}

local function RarityBadge(props: Props)
	local color, glow, strength = Theme.rarity(props.rarity)
	return e("TextLabel", {
		Text = string.upper(props.rarity),
		FontFace = Theme.font("display"),
		TextSize = Theme.text.small,
		-- a fixed size fits its text for any theme font (Phase 2 P2-F, TextFit)
		TextScaled = props.size ~= nil,
		TextColor3 = Theme.color("outline"),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = props.size or UDim2.fromOffset(0, 22),
		AutomaticSize = if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
		Fit = if props.size
			then Primitives.textSize(
				TextFit.fixedLabel(Theme.text.small).MinTextSize :: number,
				Theme.text.small
			)
			else nil,
		-- glow: thicker, more opaque stroke for rarer tiers (Common has none)
		Glow = if strength > 0
			then Primitives.stroke(glow, 1 + math.floor(strength * 3 + 0.5), 1 - strength * 0.8)
			else nil,
	})
end

return RarityBadge
