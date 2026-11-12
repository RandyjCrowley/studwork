--!strict
--[[
	TextFilter module definition (kit: social, v1.7.0). One way to filter any player-entered text by
	who will see it (public, friends, private). Design: docs/framework/kits/textfilter.md. Server
	part only (no client part, no net.blink).

	Save section "textfilter" = { originals = { [id] = { t, c, at } }, nextId }, never replicated: the
	original text stays inside this module's section.
	Strings: TextFilter.hidden (the fallback shown for text that can't be shown, English "...") and
	TextFilter.refused.

	config (GameConfig.config.TextFilter): maxLength, trim, cache, perPlayerPerMinute, originals,
	shownMaxDays, fallbackKey, respectContentSharing (the page's table).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "TextFilter",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Filters player-entered text by audience: public, friends or private (social kit)",
	config = {
		schema = {
			maxLength = "integer(1..200)",
			trim = "boolean",
			cache = { maxEntries = "integer(1..)", seconds = "number(0..)" },
			perPlayerPerMinute = "integer(1..)",
			originals = { max = "integer(1..)" },
			shownMaxDays = "number(0..)",
			fallbackKey = "string",
			respectContentSharing = "boolean",
		},
		defaults = {
			maxLength = 40,
			trim = true,
			cache = { maxEntries = 500, seconds = 600 },
			perPlayerPerMinute = 20,
			originals = { max = 100 },
			shownMaxDays = 30,
			fallbackKey = "TextFilter.hidden",
			respectContentSharing = true,
		},
	},
	data = {
		key = "textfilter",
		version = 1,
		default = { originals = {}, nextId = 1 },
		replicate = false,
	},
	strings = {
		["TextFilter.hidden"] = "...",
		["TextFilter.refused"] = "That text can't be used",
	},
})
