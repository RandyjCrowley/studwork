--!strict
--[[
	Carry demo numbers (owner: the Carry builder): object sizes, the delivery zone, the kill-plane test
	drop. Read through Tuning.carry (tools/lint "numbers" keeps literals in src/shared/Config).
]]
return {
	crate = { size = { 3, 3, 3 }, position = { -12, 1.5, 0 } },
	-- a 2-carrier heavy object: two players, one at each end
	couch = { size = { 8, 3, 3 }, position = { 0, 1.5, 0 } },
	-- the delivery zone: the whole object box must end up inside, with the carriers within reach
	zone = { size = { 18, 8, 18 }, position = { 0, 4, -30 } },
	-- the kill-plane test drop: a ledge past the ground's edge with a crate on it. Carry the crate off
	-- the end and drop it: it falls into the void, and Carry returns it to its spawn on the ledge
	ledge = { size = { 12, 2, 12 }, position = { 136, -1, 0 } },
	voidCrate = { size = { 3, 3, 3 }, position = { 136, 1.5, 0 } },
	colors = {
		crate = "#C8844A",
		couch = "#7A6FCB",
		zone = "#5ED1C9",
		ledge = "#8C8C99",
		voidCrate = "#D95D5D",
	},
	zoneTransparency = 0.65,
}
