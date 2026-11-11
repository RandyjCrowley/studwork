--!strict
--[[
	TEST FIXTURE (v1.3.0): kept from the deleted v1.2 shared Sounds.luau: the v1.2 sound table Theme.spec compares the
	framework's default theme against.
	Never required by game or kit code.
	Sound keys -> Roblox audio library asset ids.

	Every id below was checked (2026-11-10) with economy.roblox.com/v2/assets/<id>/details:
	AssetTypeId 3 (Audio), Creator.Id 1 ("Roblox"), i.e. Roblox's own audio library, usable in
	any experience. Store page: https://create.roblox.com/store/asset/<id>. The pick of which
	sound fits which key was made from names only (not auditioned) - swap freely.
	id = 0 means "no sound": Feedback.sound() silently skips it. Keys are part of the contract
	(RarityTiers.soundKey + callers): never remove one, only add.
	volume (0..1, default 0.5) and pitch (PlaybackSpeed multiplier, default 1) are optional.
]]

local Sounds: { [string]: { id: number, volume: number?, pitch: number? } } = {
	-- rarity reveal stingers (RarityTiers soundKey values), rising in weight per tier
	rarity_common = { id = 15675055424, volume = 0.4 }, -- Roblox_UI_Cute_Pop
	rarity_uncommon = { id = 17208204604, volume = 0.45 }, -- Roblox GUI - Bubble
	rarity_rare = { id = 17208361335, volume = 0.5 }, -- Roblox GUI - Notification High
	rarity_epic = { id = 17208327798, volume = 0.55 }, -- Roblox GUI - Aura
	rarity_legendary = { id = 15675043410, volume = 0.6 }, -- Roblox_UI_Tonal_Stinger
	rarity_mythic = { id = 16480578169, volume = 0.6 }, -- Audio/Roblox_Pinball_8Bit_Riser_01
	rarity_secret = { id = 16480577565, volume = 0.65 }, -- Audio/Roblox_Pinball_8Bit_Riser_04
	-- economy / UI
	coin_tick = { id = 16480580213, volume = 0.35 }, -- Audio/Roblox_Pinball_8Bit_Blip_01 (pitch ramps in Feedback)
	purchase = { id = 17208380755, volume = 0.5 }, -- Roblox GUI - Purchase
	rebirth = { id = 15675046931, volume = 0.6 }, -- Roblox_UI_Sweep
	ui_click = { id = 15675059323, volume = 0.4 }, -- Roblox_UI_Bright_Click
	ui_error = { id = 17208353912, volume = 0.45 }, -- Roblox GUI - Negative
	streak = { id = 17208372272, volume = 0.5 }, -- Roblox GUI - Notification Low
	event_start = { id = 15675085146, volume = 0.5 }, -- Roblox_UI_Indicator
}

return Sounds
