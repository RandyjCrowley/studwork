--!strict
--[[
	Applies a mute to chat (design §4 "Text chat mute"; docs "Text chat and voice mute").

	  Chat.new(o) -> chat     o = { textChat: boolean, voice: boolean, service: () -> TextChatService?, log }
	  chat.start()            listens for new TextSources (DescendantAdded) to keep muted users muted
	  chat.mute(userId, player?)    CanSend = false on every TextSource of that user; voice: every
	                                AudioDeviceInput of the player gets AccessType Allow + an empty list
	  chat.unmute(userId, player?)  restores only what this module changed
	  chat.isMuted(userId) -> boolean

	Every engine touch is in pcall: a missing service or property never breaks moderation.
]]

local Chat = {}

local function isA(inst: any, className: string): boolean
	local ok, yes = pcall(function(): boolean
		return inst:IsA(className)
	end)
	return ok and yes == true
end

function Chat.new(o: any): any
	local self: any = {}
	local muted: { [number]: boolean } = {}
	-- TextSources this module set to CanSend = false (restored on unmute)
	local changed: { [any]: number } = {}
	-- AudioDeviceInput -> { accessType, list } as it was before the voice mute
	local voiceSaved: { [any]: any } = {}
	local connection: any = nil

	local function service(): any
		local ok, s = pcall(o.service)
		return if ok then s else nil
	end

	local function silence(source: any)
		local ok, userId = pcall(function(): any
			return source.UserId
		end)
		if not ok or type(userId) ~= "number" or not muted[userId] then
			return
		end
		pcall(function()
			if source.CanSend ~= false then
				source.CanSend = false
				changed[source] = userId
			end
		end)
	end

	local function sources(): { any }
		local tcs = service()
		if tcs == nil then
			return {}
		end
		local ok, list = pcall(function(): any
			return tcs:GetDescendants()
		end)
		return if ok and type(list) == "table" then list else {}
	end

	local function voiceInputs(player: any): { any }
		if player == nil then
			return {}
		end
		local ok, list = pcall(function(): any
			return player:GetDescendants()
		end)
		local out = {}
		if ok and type(list) == "table" then
			for _, inst in list do
				if isA(inst, "AudioDeviceInput") then
					table.insert(out, inst)
				end
			end
		end
		return out
	end

	function self.start()
		if not o.textChat then
			return
		end
		local tcs = service()
		if tcs == nil then
			return
		end
		pcall(function()
			connection = tcs.DescendantAdded:Connect(function(inst: any)
				if isA(inst, "TextSource") then
					silence(inst)
				end
			end)
		end)
	end

	function self.isMuted(userId: number): boolean
		return muted[userId] == true
	end

	function self.mute(userId: number, player: any?)
		muted[userId] = true
		if o.textChat then
			for _, inst in sources() do
				if isA(inst, "TextSource") then
					silence(inst)
				end
			end
		end
		if o.voice then
			for _, input in voiceInputs(player) do
				if voiceSaved[input] == nil then
					pcall(function()
						voiceSaved[input] = {
							accessType = input.AccessType,
							list = input:GetUserIdAccessList(),
						}
						input.AccessType = (Enum :: any).AccessModifierType.Allow
						input:SetUserIdAccessList({})
					end)
				end
			end
		end
	end

	function self.unmute(userId: number, player: any?)
		muted[userId] = nil
		for source, id in changed do
			if id == userId then
				changed[source] = nil
				pcall(function()
					source.CanSend = true
				end)
			end
		end
		for _, input in voiceInputs(player) do
			local saved = voiceSaved[input]
			if saved ~= nil then
				voiceSaved[input] = nil
				pcall(function()
					input.AccessType = saved.accessType
					input:SetUserIdAccessList(saved.list)
				end)
			end
		end
	end

	-- a player left: forget the instances (the mute itself stays in the save)
	function self.forget(userId: number)
		muted[userId] = nil
		for source, id in changed do
			if id == userId then
				changed[source] = nil
			end
		end
	end

	function self.stop()
		if connection ~= nil then
			pcall(function()
				connection:Disconnect()
			end)
			connection = nil
		end
	end

	return self
end

return Chat
