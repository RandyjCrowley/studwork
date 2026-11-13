--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Schema = require(script.Parent:WaitForChild("shared"):WaitForChild("Schema"))
return StudWork.defineModule({
	name = "Settings",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Validated player preferences with owner-only replication",
	config = {
		schema = {
			flag = "string?",
			builtins = "{[string]: any}",
			schema = "{table}",
			debounceSeconds = "number(0..10)",
			saveDebounceSeconds = "number(0.1..60)",
			maxSettings = "integer(1..128)",
			maxBatch = "integer(1..32)",
			rate = { rate = "number(0..)", burst = "integer(1..)" },
			audio = { musicGroup = "string", effectsGroup = "string" },
		},
		defaults = Schema.DEFAULTS,
	},
	data = {
		key = "settings",
		version = 1,
		default = { values = {} },
		replicate = false,
		sanitize = Schema.sanitize,
	},
	strings = function(config: any): { [string]: string }
		local definitions = Schema.resolve(config)
		local strings: { [string]: string } = {
			["Settings.title"] = "Settings",
			["Settings.close"] = "Close",
			["Settings.reset"] = "Reset to defaults",
			["Settings.on"] = "On",
			["Settings.off"] = "Off",
			["Settings.decrease"] = "Decrease",
			["Settings.increase"] = "Increase",
			["Settings.saving"] = "Saving…",
			["Settings.saved"] = "Saved",
			["Settings.rejected"] = "That change could not be saved.",
			["Settings.musicVolume"] = "Music volume",
			["Settings.effectsVolume"] = "Effects volume",
			["Settings.reduceMotion"] = "Reduce motion",
			["Settings.lowDetail"] = "Low detail",
			["Settings.uiScale"] = "UI scale",
			["Settings.textSize"] = "Text size",
			["Settings.colorBlind"] = "Colour-friendly rarity colours",
			["Settings.haptics"] = "Haptics",
			["Settings.showTips"] = "Show tips",
			["Settings.category.audio"] = "Audio",
			["Settings.category.accessibility"] = "Accessibility",
			["Settings.category.graphics"] = "Graphics",
			["Settings.category.gameplay"] = "Gameplay",
			["Settings.choice.platform"] = "Follow device",
			["Settings.choice.standard"] = "Standard",
			["Settings.choice.large"] = "Large",
		}
		for id, definition in definitions do
			local categoryKey = "Settings.category." .. definition.category
			strings[categoryKey] = strings[categoryKey] or definition.category
			for index, choice in definition.choices or {} do
				strings["Settings.choice." .. id .. "." .. tostring(index)] = choice
			end
		end
		return strings
	end,
	client = "Settings",
})
