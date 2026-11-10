--!strict
--[[
	Panel: rounded surface with padding, outline stroke, gradient and drop shadow.

	props:
		title: string?               optional header in the display font
		size: UDim2?                 default: full width, auto height
		position: UDim2?, anchorPoint: Vector2?, layoutOrder: number?
		color: string?               palette key for the background (default "surface")
		automaticSize: Enum.AutomaticSize?  (default Y when no size given)
		children                     content, laid out vertically under the title
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Props = {
	title: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	color: string?,
	automaticSize: Enum.AutomaticSize?,
	children: any,
}

local function Panel(props: Props)
	local base = Theme.color(props.color or "surface")
	return e("Frame", {
		BackgroundColor3 = base,
		BorderSizePixel = 0,
		Size = props.size or UDim2.fromScale(1, 0),
		AutomaticSize = props.automaticSize
			or (if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.Y),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = Primitives.corner(),
		Stroke = Primitives.stroke(),
		Gradient = Primitives.gradient(base, 0.06),
		Shadow = Primitives.shadow(),
		-- Body holds padding + layout so the Shadow sibling is never laid out (see CurrencyCounter).
		Body = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, if props.size then 1 else 0),
			AutomaticSize = if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
		}, {
			Padding = Primitives.padding(),
			Layout = Primitives.list(Enum.FillDirection.Vertical, 8),
			Title = if props.title
				then e("TextLabel", {
					Text = props.title,
					FontFace = Theme.font("display"),
					TextSize = Theme.text.title,
					TextColor3 = Theme.color("text"),
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, Theme.text.title + 6),
					LayoutOrder = -1000,
				})
				else nil,
			Content = e(React.Fragment, nil, props.children),
		}),
	})
end

return Panel
