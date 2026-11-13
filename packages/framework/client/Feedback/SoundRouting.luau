--!strict
-- Generic local effects routing. Existing pooled voices follow a preference change immediately.
local SoundRouting = {}
function SoundRouting.new(player: any, soundService: any, create: () -> any): any
	local tracked: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function group(): any
		local name = if player then player:GetAttribute("CoreEffectsGroup") else nil
		if type(name) ~= "string" or #name == 0 or #name > 64 or string.find(name, "%c") then
			name = "CoreEffects"
		end
		local existing = soundService:FindFirstChild(name)
		if existing then
			return if existing:IsA("SoundGroup") then existing else nil
		end
		local made = create()
		made.Name = name
		made.Parent = soundService
		return made
	end
	local function route()
		local target = group()
		for sound in tracked do
			sound.SoundGroup = target
		end
	end
	local connection = if player
		then player:GetAttributeChangedSignal("CoreEffectsGroup"):Connect(route)
		else nil
	return {
		attach = function(sound: any)
			tracked[sound] = true
			sound.SoundGroup = group()
		end,
		destroy = function()
			if connection then
				connection:Disconnect()
			end
			table.clear(tracked)
		end,
	}
end
return SoundRouting
