--!strict
-- Movement demo numbers (owner: the Movement builder): hazard / noEntry volumes, moving platform,
-- seat, truss and the scripted teleport cheat. Read through Tuning.movement.
return {
	-- the hazard strip: walking through it is a volumeSweep crossing (kind "hazard")
	hazard = { position = Vector3.new(40, 0.5, 20), size = Vector3.new(10, 1, 20) },
	-- the no-entry block: behind the wall, out of bounds for a legitimate player
	noEntry = { position = Vector3.new(-60, 2, 0), size = Vector3.new(10, 4, 10) },
	-- the moving platform: rides back and forth along X at this speed
	platform = {
		position = Vector3.new(0, 1, 60),
		size = Vector3.new(16, 1, 16),
		speed = 12, -- studs/s
		travel = 40, -- studs each way from `position`
	},
	seat = { position = Vector3.new(20, 1, -40) },
	truss = { position = Vector3.new(-20, 10, -40), height = 20 },
	-- the scripted teleport cheat (Studio-only, src/client/Main.client.luau): a player who chats this
	-- moves their own character 40 studs forward with a CLIENT-side root CFrame write (what an
	-- exploited client does), so the Studio gate can see a Strike and `movement samples`
	cheatCommand = "/cheat",
	cheatDistance = 40,
}
