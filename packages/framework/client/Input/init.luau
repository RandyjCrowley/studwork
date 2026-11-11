--!strict
--[[
	Core.Client.Input. OWNED BY AGENT G (core/g-client). Public API: Types.InputAPI. See README.md.

	device() -> "KeyboardMouse" | "Touch" | "Gamepad"
	    From UserInputService.PreferredInput (Enum.PreferredInput, observed with
	    GetPropertyChangedSignal); falls back to LastInputTypeChanged + capability flags when the
	    property is unavailable.
	deviceChanged: Signal<InputDevice>  fires only on an actual change.
	bind(actionId, binding, handler)  ContextActionService:BindAction with binding.keys +
	    binding.gamepad; handler("Began"/"Ended") (Cancel counts as "Ended"). Input passes
	    through (ContextActionResult.Pass) so default controls keep working. With
	    touchButton = true an on-screen button is created (shown on touch devices by Roblox),
	    titled binding.title and tinted with the theme's accent (client/Theme.luau; GameConfig.palette
	    overrides still win). Re-binding an id replaces it.
	unbind(actionId)
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))
local Types = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Types"))

local ClientTheme = require(script.Parent.Theme)
local Classify = require(script.Classify)

local Input = {}

local current: Types.InputDevice = "KeyboardMouse"
Input.deviceChanged = (Signal.new() :: any) :: Types.Signal<Types.InputDevice>

local bound: { [string]: boolean } = {}
local paletteOverrides: { [string]: string }? = nil

local function setDevice(device: Types.InputDevice?)
	if device ~= nil and device ~= current then
		current = device
		Input.deviceChanged:Fire(device)
	end
end

local function readPreferred(): Types.InputDevice?
	local ok, value = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(value) == "EnumItem" then
		return Classify.fromPreferredInput(value.Name) :: Types.InputDevice?
	end
	return nil
end

function Input.device(): Types.InputDevice
	return current
end

-- A theme colour (GameConfig.palette overrides first, as in v1.2), as a Color3.
local function themeColor(key: string): Color3
	local override = if paletteOverrides then paletteOverrides[key] else nil
	if type(override) == "string" and string.match(override, "^#%x%x%x%x%x%x$") then
		return Color3.fromHex(override)
	end
	return Color3.fromHex(ClientTheme.current().colors[key])
end

local function styleTouchButton(actionId: string, title: string?)
	if title then
		ContextActionService:SetTitle(actionId, title)
	end
	local button = ContextActionService:GetButton(actionId)
	if button and button:IsA("ImageButton") then
		local theme = ClientTheme.current()
		button.ImageColor3 = themeColor("accent")
		local minSize = theme.metrics.minTouchTarget
		if button.AbsoluteSize.X < minSize then
			button.Size = UDim2.fromOffset(minSize * 1.4, minSize * 1.4)
		end
		local titleLabel = button:FindFirstChild("ActionTitle")
		if titleLabel and titleLabel:IsA("TextLabel") then
			titleLabel.TextColor3 = themeColor("text")
			titleLabel.FontFace = Font.new(theme.fonts.display, Enum.FontWeight.Bold)
		end
	end
end

function Input.bind(actionId: string, binding: Types.InputBinding, handler: (state: "Began" | "Ended") -> ())
	assert(type(actionId) == "string" and actionId ~= "", "Input.bind: actionId must be a non-empty string")
	if bound[actionId] then
		ContextActionService:UnbindAction(actionId)
	end
	local inputs: { any } = {}
	if binding.keys then
		for _, key in binding.keys do
			table.insert(inputs, key)
		end
	end
	if binding.gamepad then
		for _, key in binding.gamepad do
			table.insert(inputs, key)
		end
	end
	local pressed = false
	ContextActionService:BindAction(actionId, function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			pressed = true
			handler("Began")
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			if pressed then
				pressed = false
				handler("Ended")
			end
		end
		return Enum.ContextActionResult.Pass
	end, binding.touchButton == true, table.unpack(inputs))
	bound[actionId] = true
	if binding.touchButton then
		styleTouchButton(actionId, binding.title)
	end
end

function Input.unbind(actionId: string)
	if bound[actionId] then
		bound[actionId] = nil
		ContextActionService:UnbindAction(actionId)
	end
end

local started = false

function Input.start(ctx: any)
	if started then
		return
	end
	started = true
	if ctx and ctx.config and type(ctx.config.palette) == "table" then
		paletteOverrides = ctx.config.palette
	end

	local preferred = readPreferred()
	if preferred then
		current = preferred :: any
		UserInputService:GetPropertyChangedSignal("PreferredInput" :: any):Connect(function()
			setDevice(readPreferred())
		end)
	else
		current = Classify.fromCapabilities(
			UserInputService.TouchEnabled,
			UserInputService.KeyboardEnabled,
			UserInputService.GamepadEnabled
		) :: any
		local last = Classify.fromInputType(UserInputService:GetLastInputType().Name)
		if last then
			current = last :: Types.InputDevice
		end
		UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
			setDevice(Classify.fromInputType(inputType.Name) :: Types.InputDevice?)
		end)
	end
end

return Input
