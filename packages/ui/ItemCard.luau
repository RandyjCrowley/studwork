--!strict
--[[
	ItemCard: square-ish card with icon (or a rarity-coloured placeholder), name, RarityBadge,
	income per second and an optional mutation tag. Holds its shape with UIAspectRatioConstraint.

	props:
		name: string, rarity: string (RarityTier)
		icon: string?                rbxassetid image; nil = rarity-coloured placeholder initial
		incomePerSec: number?        shown as "+1.2K/s"
		mutation: string?            tag text (e.g. "Gold"); mutationColor: string? hex tint
		size: UDim2?                 default 140 px wide (scaled by UIScale)
		layoutOrder: number?, onActivated: (() -> ())?  (card becomes tappable)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Format = require(script.Parent.Format)
local Primitives = require(script.Parent.Primitives)
local RarityBadge = require(script.Parent.RarityBadge)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Props = {
	name: string,
	rarity: string,
	icon: string?,
	incomePerSec: number?,
	mutation: string?,
	mutationColor: string?,
	size: UDim2?,
	layoutOrder: number?,
	onActivated: (() -> ())?,
}

local ASPECT = 0.75 -- width / height

local function ItemCard(props: Props)
	local color, glow, strength = Theme.rarity(props.rarity)
	local tappable = props.onActivated ~= nil
	return e(
		if tappable then "TextButton" else "Frame",
		{
			Text = if tappable then "" else nil,
			AutoButtonColor = if tappable then false else nil,
			BackgroundColor3 = Theme.color("surfaceAlt"),
			BorderSizePixel = 0,
			Size = props.size or UDim2.fromOffset(140, 140 / ASPECT),
			LayoutOrder = props.layoutOrder,
			[React.Event.Activated] = if tappable then props.onActivated else nil,
		} :: any,
		{
			Aspect = e("UIAspectRatioConstraint", { AspectRatio = ASPECT }),
			Corner = Primitives.corner(),
			Stroke = Primitives.stroke(
				if strength > 0 then glow else Theme.color("outline"),
				2 + math.floor(strength * 2)
			),
			Gradient = Primitives.gradient(Theme.color("surfaceAlt"), 0.08),
			Padding = Primitives.padding(8),
			Layout = Primitives.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center),
			Icon = e(
				if props.icon then "ImageLabel" else "TextLabel",
				{
					Image = props.icon,
					Text = if props.icon then nil else string.upper(string.sub(props.name, 1, 1)),
					FontFace = if props.icon then nil else Theme.font("display"),
					TextScaled = if props.icon then nil else true,
					TextColor3 = if props.icon then nil else Theme.color("outline"),
					BackgroundColor3 = color,
					BackgroundTransparency = if props.icon then 1 else 0,
					Size = UDim2.fromScale(0.7, 0.45),
					LayoutOrder = 1,
				} :: any,
				{
					Aspect = e("UIAspectRatioConstraint", { AspectRatio = 1 }),
					Corner = Primitives.corner(10),
					Padding = if props.icon then nil else Primitives.padding(8),
				}
			),
			Name = e("TextLabel", {
				Text = props.name,
				FontFace = Theme.font("display"),
				TextScaled = true,
				TextColor3 = Theme.color("text"),
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 0.14),
				LayoutOrder = 2,
			}, { Limit = Primitives.textSize(12, Theme.text.body) }),
			Badge = e(RarityBadge, { rarity = props.rarity, layoutOrder = 3 }),
			Income = if props.incomePerSec
				then e("TextLabel", {
					Text = "+" .. Format.abbreviate(props.incomePerSec) .. "/s",
					FontFace = Theme.font("bold"),
					TextScaled = true,
					TextColor3 = Theme.color("currency"),
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 0.11),
					LayoutOrder = 4,
				}, { Limit = Primitives.textSize(12, Theme.text.body) })
				else nil,
			Mutation = if props.mutation
				then e("TextLabel", {
					Text = props.mutation,
					FontFace = Theme.font("bold"),
					TextSize = Theme.text.small,
					TextColor3 = Theme.color("outline"),
					BackgroundColor3 = if props.mutationColor
						then Color3.fromHex(props.mutationColor)
						else Theme.color("warning"),
					Size = UDim2.fromOffset(0, 20),
					AutomaticSize = Enum.AutomaticSize.X,
					LayoutOrder = 5,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
					Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
				})
				else nil,
		}
	)
end

return ItemCard
