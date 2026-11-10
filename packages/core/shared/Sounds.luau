--!strict
--[[
	Sound keys -> Roblox audio library asset ids. OWNED BY AGENT G (core/g-client) in Phase 1.

	Phase 0 stub: every key exists so callers never break; ids of 0 mean "no sound yet" and
	Feedback.sound() silently skips them. Agent G fills real ids from the Roblox audio library
	(already licensed for Roblox; see docs/research/art-direction.md).
]]

local Sounds: { [string]: { id: number, volume: number?, pitch: number? } } = {
	-- rarity reveal stingers (RarityTiers soundKey values)
	rarity_common = { id = 0 },
	rarity_uncommon = { id = 0 },
	rarity_rare = { id = 0 },
	rarity_epic = { id = 0 },
	rarity_legendary = { id = 0 },
	rarity_mythic = { id = 0 },
	rarity_secret = { id = 0 },
	-- economy / UI
	coin_tick = { id = 0 },
	purchase = { id = 0 },
	rebirth = { id = 0 },
	ui_click = { id = 0 },
	ui_error = { id = 0 },
	streak = { id = 0 },
	event_start = { id = 0 },
}

return Sounds
