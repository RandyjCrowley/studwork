--!strict
--[[
	The quests demo's own numbers (every balance and layout number lives in src/shared/Config; the
	`numbers` lint flags literals elsewhere). The game module builds the world from these.
]]

return {
	-- coin spots: touching one grants coins and counts Quests.progress(player, "coinTouched")
	coinsPerTouch = 5,
	touchCooldown = 1, -- seconds between rewards from the same spot for one player
	coinSize = 4,
	coinHeight = 2,
	coinSpots = {
		{ 12, 0 },
		{ -12, 0 },
		{ 0, 12 },
		{ 0, -12 },
		{ 18, 18 },
		{ -18, -18 },
	} :: { { number } },
	-- the guide (story quest giver, hands out the grant quest), the board pad and the far tower
	guidePosition = { 20, 3, 30 } :: { number },
	guideSize = { 4, 6, 4 } :: { number },
	boardPosition = { -20, 3, 30 } :: { number },
	boardSize = { 8, 6, 1 } :: { number },
	-- 600 studs away: beyond StreamingTargetRadius (256), so the goal pointer needs its fallback
	towerPosition = { 0, 20, 600 } :: { number },
	towerSize = { 10, 40, 10 } :: { number },
	groundSize = { 140, 2, 1300 } :: { number },
	groundCenterZ = 300,
	spawnPosition = { 0, 1, 40 } :: { number },
}
