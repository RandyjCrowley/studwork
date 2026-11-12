--!strict
-- Measured wrapped text: AutomaticSize.Y is unreliable in nested modal layouts.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Theme = require(script.Parent.Theme)
local e = React.createElement

export type Props = {
	text: string,
	textSize: (string | number)?,
	font: ("display" | "body" | "bold")?,
	color: string?,
	backgroundColor: string?,
	padding: number?,
	layoutOrder: number?,
	alignment: Enum.TextXAlignment?,
	onHeight: ((number) -> ())?,
}

local function estimate(text: string, size: number, width: number, pad: number): number
	local chars = utf8.len(text) or #text
	local perLine = math.max(1, math.floor(math.max(1, width - 2 * pad) / (size * 1.0)))
	return math.max(size + 2 * pad, math.ceil(chars / perLine) * math.ceil(size * 1.3) + 2 * pad)
end

local function WrappedText(props: Props)
	local ref = React.useRef(nil :: TextLabel?)
	local size: number
	if type(props.textSize) == "number" then
		size = props.textSize
	else
		local key: string = props.textSize or "small"
		size = Theme.text[key] or Theme.text.small
	end
	local font = Theme.font(props.font or "body")
	local pad = props.padding or 0
	local height, setHeight = React.useState(estimate(props.text, size, 180, pad))
	React.useEffect(function(): (() -> ())?
		local label = ref.current
		if label == nil then
			return nil
		end
		local active = true
		local serial = 0
		local lastWidth = -1
		local function measure()
			serial += 1
			local request = serial
			local ancestorScale = 1
			local ancestor = label.Parent
			while ancestor do
				if ancestor:IsA("GuiObject") then
					for _, child in ancestor:GetChildren() do
						if child:IsA("UIScale") then
							ancestorScale *= child.Scale
						end
					end
				end
				ancestor = ancestor.Parent
			end
			local width = label.AbsoluteSize.X / math.max(ancestorScale, 0.001)
			if width < 1 or math.abs(width - lastWidth) < 0.5 then
				return
			end
			lastWidth = width
			local inner = math.max(1, width - 2 * pad)
			local fallback = estimate(props.text, size, width, pad)
			setHeight(fallback)
			task.spawn(function()
				local params = Instance.new("GetTextBoundsParams")
				params.Text = props.text
				params.Font = font
				params.Size = size
				params.Width = inner
				local ok, bounds = pcall(function()
					return TextService:GetTextBoundsAsync(params)
				end)
				params:Destroy()
				if active and request == serial and ok then
					local measured = math.max(size + 2 * pad, math.ceil(bounds.Y) + 2 * pad + 2)
					setHeight(measured)
					if props.onHeight then
						props.onHeight(measured)
					end
				end
			end)
		end
		measure()
		local a = label:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
		local scales: { RBXScriptConnection } = {}
		local ancestor = label.Parent
		while ancestor do
			for _, child in ancestor:GetChildren() do
				if child:IsA("UIScale") then
					table.insert(
						scales,
						child:GetPropertyChangedSignal("Scale"):Connect(function()
							lastWidth = -1
							measure()
						end)
					)
				end
			end
			ancestor = ancestor.Parent
		end
		return function()
			active = false
			a:Disconnect()
			for _, connection in scales do
				connection:Disconnect()
			end
		end
	end, { props.text, size, font, pad, props.onHeight } :: { any })
	return e("TextLabel", {
		ref = ref,
		Text = props.text,
		FontFace = font,
		TextSize = size,
		TextWrapped = true,
		TextColor3 = Theme.color(props.color or "text"),
		BackgroundColor3 = if props.backgroundColor then Theme.color(props.backgroundColor) else nil,
		BackgroundTransparency = if props.backgroundColor then 0 else 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		TextXAlignment = props.alignment or Enum.TextXAlignment.Left,
		LayoutOrder = props.layoutOrder,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
	})
end

return WrappedText
