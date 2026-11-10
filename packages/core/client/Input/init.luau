--!strict
--[[
	Core.Client.Input. OWNED BY AGENT G (core/g-client). Public API: Types.InputAPI.

	PHASE 0 STUB: device detection from UserInputService.PreferredInput / last input type and
	bind() through ContextActionService (touch button via createTouchButton). Agent G: robust
	device switching, gamepad UI hints, custom touch button styling from the palette.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

local Input = {}

local current: Types.InputDevice = "KeyboardMouse"
Input.deviceChanged = (Signal.new() :: any) :: Types.Signal<Types.InputDevice>

local function classify(inputType: Enum.UserInputType): Types.InputDevice?
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.find(inputType.Name, "Gamepad") then
		return "Gamepad"
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseMovement
	then
		return "KeyboardMouse"
	end
	return nil
end

local function setDevice(device: Types.InputDevice)
	if device ~= current then
		current = device
		Input.deviceChanged:Fire(device)
	end
end

function Input.device(): Types.InputDevice
	return current
end

function Input.bind(actionId: string, binding: Types.InputBinding, handler: (state: "Began" | "Ended") -> ())
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
	ContextActionService:BindAction(actionId, function(_, state)
		if state == Enum.UserInputState.Begin then
			handler("Began")
		elseif state == Enum.UserInputState.End then
			handler("Ended")
		end
		return Enum.ContextActionResult.Pass
	end, binding.touchButton == true, table.unpack(inputs))
	if binding.title and binding.touchButton then
		ContextActionService:SetTitle(actionId, binding.title)
	end
end

function Input.unbind(actionId: string)
	ContextActionService:UnbindAction(actionId)
end

function Input.start(_ctx: any)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		current = "Touch" :: Types.InputDevice
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		current = "Gamepad" :: Types.InputDevice
	end
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local device = classify(inputType)
		if device then
			setDevice(device :: Types.InputDevice)
		end
	end)
end

return Input
