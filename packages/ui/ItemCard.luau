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
local Layout = require(script.Parent.ItemCardLayout)
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

-- Product of every UIScale that applies to `inst` (its own and its ancestors').
local function scaleOf(inst: Instance): number
	local s = 1
	local node: Instance? = inst
	while node and not node:IsA("LayerCollector") do
		local u = node:FindFirstChildOfClass("UIScale")
		if u then
			s *= u.Scale
		end
		node = node.Parent
	end
	return s
end

local function ItemCard(props: Props)
	local color, glow, strength = Theme.rarity(props.rarity)
	local tappable = props.onActivated ~= nil
	local hasIncome, hasMutation = props.incomePerSec ~= nil, props.mutation ~= nil
	local cardRef = React.useRef(nil :: GuiObject?)
	-- The text rows keep fixed, readable sizes; the icon takes what is left in the card's real size.
	local icon, setIcon = React.useState(
		Layout.iconSize(Layout.WIDTH, Layout.WIDTH / Layout.ASPECT, Theme.text.small, hasIncome, hasMutation)
	)
	React.useEffect(function(): (() -> ())?
		local card = cardRef.current
		if card == nil then
			return nil
		end
		local function measure()
			local s = math.max(scaleOf(card), 0.01)
			setIcon(
				Layout.iconSize(
					card.AbsoluteSize.X / s,
					card.AbsoluteSize.Y / s,
					Theme.text.small,
					hasIncome,
					hasMutation
				)
			)
		end
		measure()
		local connection = card:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
		return function()
			connection:Disconnect()
		end
	end, { hasIncome, hasMutation } :: { any })
	return e(
		if tappable then "TextButton" else "Frame",
		{
			ref = cardRef,
			Text = if tappable then "" else nil,
			AutoButtonColor = if tappable then false else nil,
			BackgroundColor3 = Theme.color("surfaceAlt"),
			BorderSizePixel = 0,
			Size = props.size or UDim2.fromOffset(Layout.WIDTH, Layout.WIDTH / Layout.ASPECT),
			LayoutOrder = props.layoutOrder,
			[React.Event.Activated] = if tappable then props.onActivated else nil,
		} :: any,
		{
			Aspect = e("UIAspectRatioConstraint", { AspectRatio = Layout.ASPECT }),
			Corner = Primitives.corner(),
			Stroke = Primitives.stroke(
				if strength > 0 then glow else Theme.color("outline"),
				2 + math.floor(strength * 2)
			),
			Gradient = Primitives.gradient(Theme.color("surfaceAlt"), 0.08),
			Padding = Primitives.padding(Layout.PADDING),
			Layout = Primitives.list(
				Enum.FillDirection.Vertical,
				Layout.GAP,
				Enum.HorizontalAlignment.Center
			),
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
					Size = UDim2.fromOffset(icon, icon),
					Visible = icon > 0,
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
				TextSize = Theme.text.small,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Theme.color("text"),
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, Layout.nameHeight(Theme.text.small)),
				LayoutOrder = 2,
			}),
			Badge = e(RarityBadge, { rarity = props.rarity, layoutOrder = 3 }),
			Income = if props.incomePerSec
				then e("TextLabel", {
					Text = "+" .. Format.abbreviate(props.incomePerSec) .. "/s",
					FontFace = Theme.font("bold"),
					TextSize = Theme.text.small,
					TextColor3 = Theme.color("currency"),
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, Layout.INCOME),
					LayoutOrder = 4,
				})
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
					Size = UDim2.fromOffset(0, Layout.MUTATION),
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
