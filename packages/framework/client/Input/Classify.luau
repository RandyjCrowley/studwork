--!strict
--[[
	Pure device classification from enum NAMES (strings), so it is testable without Enum.

	Classify.fromPreferredInput(name) -> device?   Enum.PreferredInput names:
	  KeyboardAndMouse -> KeyboardMouse, Gamepad/MicroGamepad -> Gamepad, Touch -> Touch
	Classify.fromInputType(name) -> device?        Enum.UserInputType names:
	  Touch -> Touch, Gamepad1..8 -> Gamepad, Keyboard/Mouse* -> KeyboardMouse, others -> nil
	Classify.fromCapabilities(touch, keyboard, gamepad) -> device   fallback when neither is known
	  (touch without keyboard -> Touch, gamepad without keyboard -> Gamepad, else KeyboardMouse)
]]

export type Device = "KeyboardMouse" | "Touch" | "Gamepad"

local Classify = {}

function Classify.fromPreferredInput(name: string): Device?
	if name == "KeyboardAndMouse" then
		return "KeyboardMouse"
	elseif name == "Gamepad" or name == "MicroGamepad" then
		return "Gamepad"
	elseif name == "Touch" then
		return "Touch"
	end
	return nil
end

function Classify.fromInputType(name: string): Device?
	if name == "Touch" then
		return "Touch"
	elseif string.match(name, "^Gamepad%d+$") then
		return "Gamepad"
	elseif name == "Keyboard" or string.match(name, "^Mouse") then
		return "KeyboardMouse"
	end
	return nil
end

function Classify.fromCapabilities(touch: boolean, keyboard: boolean, gamepad: boolean): Device
	if touch and not keyboard then
		return "Touch"
	elseif gamepad and not keyboard then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

return Classify
