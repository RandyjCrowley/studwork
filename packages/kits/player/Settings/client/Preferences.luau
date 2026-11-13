--!strict
-- Event-driven application hooks, injectable so offline checks never call engine services.
local Preferences = {}
function Preferences.textScale(mode: any, preferred: any): number
	if mode == "large" then
		return 1.25
	end
	if mode ~= "platform" then
		return 1
	end
	local name = tostring(preferred)
	if string.find(name, "Largest", 1, true) then
		return 1.5
	end
	if string.find(name, "Larger", 1, true) then
		return 1.35
	end
	if string.find(name, "Large", 1, true) then
		return 1.15
	end
	return 1
end
function Preferences.new(opts: any): any
	for _, name in { opts.audio.musicGroup, opts.audio.effectsGroup } do
		assert(
			type(name) == "string" and #name > 0 and #name <= 64 and string.find(name, "%c") == nil,
			"Settings: invalid audio group"
		)
	end
	local player = opts.player
	local gui = opts.gui
	local connections: { any } = {}
	local state: { [string]: any } = {}
	local self: any = {}
	local function preference(property: string, fallback: any): any
		local ok, value = pcall(function()
			return gui[property]
		end)
		return if ok then value else fallback
	end
	local function group(name: string): any
		local found = opts.sounds:FindFirstChild(name)
		if found then
			return if found:IsA("SoundGroup") then found else nil
		end
		local made = opts.createGroup()
		made.Name = name
		made.Parent = opts.sounds
		return made
	end
	function self.default(def: any): any
		if def.id == "reduceMotion" and def.default == false then
			return preference("ReducedMotionEnabled", false) == true
		end
		return def.default
	end
	function self.apply(id: string, value: any)
		state[id] = value
		if id == "musicVolume" or id == "effectsVolume" then
			local target =
				group(if id == "musicVolume" then opts.audio.musicGroup else opts.audio.effectsGroup)
			if target then
				target.Volume = value
			end
			if id == "effectsVolume" then
				player:SetAttribute("CoreEffectsGroup", opts.audio.effectsGroup)
			end
		elseif id == "textSize" then
			player:SetAttribute(
				"CoreTextScale",
				Preferences.textScale(value, preference("PreferredTextSize", "Medium"))
			)
		else
			local names = {
				reduceMotion = "CoreReducedMotion",
				lowDetail = "CoreLowDetail",
				uiScale = "CoreUIScale",
				colorBlind = "CoreColorBlind",
				haptics = "CoreHaptics",
				showTips = "CoreShowTips",
			}
			if names[id] then
				player:SetAttribute(names[id], value)
			end
		end
	end
	for _, property in { "ReducedMotionEnabled", "PreferredTextSize" } do
		local ok, connection = pcall(function()
			return gui:GetPropertyChangedSignal(property):Connect(function()
				if property == "ReducedMotionEnabled" then
					opts.refreshDefault("reduceMotion")
				elseif state.textSize == "platform" then
					self.apply("textSize", "platform")
				end
			end)
		end)
		if ok then
			table.insert(connections, connection)
		end
	end
	function self.destroy()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
	return self
end
return Preferences
