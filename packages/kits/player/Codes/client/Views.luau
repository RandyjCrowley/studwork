--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local React = require(ReplicatedStorage.Packages.React) :: any
local ReactCharm = require(ReplicatedStorage.Packages.ReactCharm) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local Responsive = require(ReplicatedStorage.UI.Responsive)
local ModalFit = require(ReplicatedStorage.UI.ModalFit)
local Layout = require(script.Parent.Layout)
local e = React.createElement
local Views = {}
local function textScale(): number
	local value = Players.LocalPlayer:GetAttribute("CoreTextScale")
	if type(value) == "number" then
		return math.clamp(value, 1, 1.5)
	end
	local preferred = tostring(GuiService.PreferredTextSize)
	return if string.find(preferred, "Largest", 1, true)
		then 1.5
		elseif string.find(preferred, "Larger", 1, true) then 1.35
		elseif string.find(preferred, "Large", 1, true) then 1.15
		else 1
end
local function textLimit(size: number?): any
	local pixels = math.ceil(size or UI.Theme.text.body * textScale())
	return e("UITextSizeConstraint", { MinTextSize = pixels, MaxTextSize = pixels })
end
local function target(): number
	return math.max(
		UI.Theme.touchTarget,
		Layout.touch(
			UI.Theme.metrics.minTouchTarget,
			Responsive.MIN_SCALE,
			ModalFit.minScale(UI.Theme.tokens)
		)
	)
end
local function button(text: string, action: () -> (), order: number): any
	return e("TextButton", {
		Text = text,
		FontFace = UI.Theme.font("body"),
		TextSize = UI.Theme.text.body * textScale(),
		TextColor3 = UI.Theme.color("text"),
		BackgroundColor3 = UI.Theme.color("accentAlt"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, target()),
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		[React.Event.Activated] = action,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, UI.Theme.metrics.cornerRadius) }),
		TextLimit = textLimit(),
	})
end
function Views.Screen(props: any): any
	local input, setInput = React.useState("")
	local notice, setNotice = React.useState(props.latest())
	local busy, setBusy = React.useState(props.pending())
	local available, setAvailable = React.useState(1)
	local _, redraw = React.useState(0)
	local inputRef = React.useRef(nil)
	local sources = ReactCharm.useAtom(props.sources)
	React.useEffect(function()
		local off = props.subscribe(function(result: string)
			setNotice(result)
			setBusy(false)
		end)
		local cameraConnection: any = nil
		local function refit()
			local camera = Workspace.CurrentCamera
			if camera then
				local size = camera.ViewportSize
				local height = Layout.available(
					size.Y,
					UserInputService.OnScreenKeyboardVisible,
					UserInputService.OnScreenKeyboardPosition.Y,
					UserInputService.OnScreenKeyboardSize.Y
				)
				setAvailable(height / math.max(size.Y, 1))
			end
		end
		local function watchCamera()
			if cameraConnection then
				cameraConnection:Disconnect()
			end
			local camera = Workspace.CurrentCamera
			if camera then
				cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
			end
			refit()
		end
		watchCamera()
		local connections = {
			Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera),
			GuiService:GetPropertyChangedSignal("PreferredTextSize"):Connect(function()
				redraw(function(n: number)
					return n + 1
				end)
			end),
			UserInputService:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Connect(refit),
			UserInputService:GetPropertyChangedSignal("OnScreenKeyboardPosition"):Connect(refit),
			UserInputService:GetPropertyChangedSignal("OnScreenKeyboardSize"):Connect(refit),
			Players.LocalPlayer:GetAttributeChangedSignal("CoreTextScale"):Connect(function()
				redraw(function(n: number)
					return n + 1
				end)
			end),
		}
		return function()
			off()
			if cameraConnection then
				cameraConnection:Disconnect()
			end
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})
	local function submit()
		local raw = input
		setInput("")
		if inputRef.current then
			inputRef.current:ReleaseFocus()
		end
		setNotice(nil)
		setBusy(props.api.redeem(raw))
	end
	local title = UI.useText("Codes.title")
	local placeholder = UI.useText("Codes.placeholder")
	local children: { [string]: any } = {
		Input = e("TextBox", {
			Text = input,
			PlaceholderText = placeholder,
			ClearTextOnFocus = false,
			MultiLine = false,
			TextEditable = not busy,
			FontFace = UI.Theme.font("body"),
			TextSize = UI.Theme.text.body * textScale(),
			TextColor3 = UI.Theme.color("text"),
			PlaceholderColor3 = UI.Theme.color("textMuted"),
			BackgroundColor3 = UI.Theme.color("surfaceAlt"),
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, target()),
			LayoutOrder = 1,
			ref = inputRef,
			[React.Change.Text] = function(box: TextBox)
				setInput(Layout.input(box.Text))
			end,
			[React.Event.FocusLost] = (function(_box: TextBox, enter: boolean)
				if enter then
					submit()
				end
			end) :: any,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, UI.Theme.metrics.cornerRadius) }),
			TextLimit = textLimit(),
		}),
		Submit = button(UI.text(if busy then "Codes.pending" else "Codes.redeem"), function()
			if not busy then
				submit()
			end
		end, 2),
		Close = button(UI.text("Codes.close"), props.onClose, 1000),
	}
	if notice then
		children.Notice = e(UI.Toast, { text = UI.text("Codes." .. notice), layoutOrder = 3 })
	end
	for index, source in sources do
		children["Odds" .. tostring(index)] = button(UI.text("Codes.odds") .. " · " .. source, function()
			props.odds(source)
		end, index + 3)
	end
	return e("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, available) }, {
		Modal = e(
			UI.Modal,
			{ open = true, title = if available < 1 then nil else title, dismissOnBackdrop = false },
			children
		),
	})
end
return Views
