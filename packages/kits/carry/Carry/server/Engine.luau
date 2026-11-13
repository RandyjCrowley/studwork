--!strict
--[[
	Engine: the few live-engine facts Carry needs that are not part of the World seam (pcall-guarded, so
	they do nothing under the Lune harness or a fake World):

	  Engine.atomic(inst)                  ModelStreamingMode = Atomic on a carriable Model (never half-streams)
	  Engine.registerGroups(group)         registers the built-in collision group `group` ("CarryDropped") and
	                                       the characters group; they never collide with each other. Returns
	                                       true when the engine services were available
	  Engine.watchCharacters()             puts player-character parts still in the "Default" group into the
	                                       characters group (so a dropped object can pass through characters
	                                       only); returns a disconnect

	The built-in default group excludes characters ONLY. A game that sets config.collisionGroup uses its
	own group and Carry never touches characters. CanCollide is never changed here.
]]

local Engine = {}

Engine.CHARACTERS = "CarryCharacters"

function Engine.atomic(inst: any)
	pcall(function()
		if inst:IsA("Model") then
			inst.ModelStreamingMode = (Enum :: any).ModelStreamingMode.Atomic
		end
	end)
end

function Engine.registerGroups(group: string): boolean
	local ok = pcall(function()
		local physics = (game :: any):GetService("PhysicsService")
		for _, name in { group, Engine.CHARACTERS } do
			if not physics:IsCollisionGroupRegistered(name) then
				physics:RegisterCollisionGroup(name)
			end
		end
		physics:CollisionGroupSetCollidable(group, Engine.CHARACTERS, false)
	end)
	return ok
end

function Engine.watchCharacters(): () -> ()
	local connections: { any } = {}
	local ok = pcall(function()
		local Players = (game :: any):GetService("Players")
		local function assign(part: any)
			if part:IsA("BasePart") and part.CollisionGroup == "Default" then
				part.CollisionGroup = Engine.CHARACTERS
			end
		end
		local function watch(character: any)
			for _, d in character:GetDescendants() do
				assign(d)
			end
			table.insert(connections, character.DescendantAdded:Connect(assign))
		end
		local function watchPlayer(player: any)
			table.insert(connections, player.CharacterAdded:Connect(watch))
			if player.Character then
				watch(player.Character)
			end
		end
		table.insert(connections, Players.PlayerAdded:Connect(watchPlayer))
		for _, player in Players:GetPlayers() do
			watchPlayer(player)
		end
	end)
	if not ok then
		return function() end
	end
	return function()
		for _, c in connections do
			c:Disconnect()
		end
		table.clear(connections)
	end
end

return Engine
