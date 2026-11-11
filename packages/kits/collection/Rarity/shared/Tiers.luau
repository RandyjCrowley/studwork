--!strict
--[[
	Rarity tiers of the collection kit (module-api.md §12, §13). Pure, shared (server + client).

	config.Rarity.tiers is a preset name ("standard7", the default) or a custom ORDERED list
	{ { id, color?, glow?, glowStrength?, soundKey? } } (lowest tier first; the order is the tier
	order used by luck, pity and the UI). Collection contributes the resolved list as
	theme.rarity.tiers and validates every item's `rarity` against it.

	Tiers.PRESETS.standard7     Common < Uncommon < Rare < Epic < Legendary < Mythic < Secret
	Tiers.resolve(spec) -> (tiers?, errors)   frozen list of frozen tier defs, or every problem
	Tiers.rankMap(tiers) -> { [id]: 1..n }
	Tiers.defaultLuckMinTier(tiers) -> id     "Rare" in standard7: the tier at position min(3, n)
]]

local Tiers = {}

export type TierDef = {
	id: string,
	color: string?,
	glow: string?,
	glowStrength: number?,
	soundKey: string?,
}

Tiers.DEFAULT_PRESET = "standard7"
Tiers.MAX_TIERS = 32

local function tier(id: string, color: string, glow: string, glowStrength: number, soundKey: string): TierDef
	return table.freeze({
		id = id,
		color = color,
		glow = glow,
		glowStrength = glowStrength,
		soundKey = soundKey,
	})
end

-- docs/research/art-direction.md: rarity reads through colour, glow and a distinct sound per tier.
Tiers.PRESETS = table.freeze({
	standard7 = table.freeze({
		tier("Common", "#C9CFD9", "#E6EAF0", 0.0, "rarity_common"),
		tier("Uncommon", "#6BD66B", "#A6F0A6", 0.15, "rarity_uncommon"),
		tier("Rare", "#4DA3FF", "#9CCBFF", 0.35, "rarity_rare"),
		tier("Epic", "#B26BFF", "#D7B0FF", 0.55, "rarity_epic"),
		tier("Legendary", "#FFB547", "#FFE0A3", 0.75, "rarity_legendary"),
		tier("Mythic", "#FF5DA8", "#FFB3D6", 0.9, "rarity_mythic"),
		tier("Secret", "#2EF2E0", "#B8FFF8", 1.0, "rarity_secret"),
	}),
}) :: { [string]: { TierDef } }

local function isHex(v: any): boolean
	return type(v) == "string" and string.match(v, "^#%x%x%x%x%x%x$") ~= nil
end

local function isTierId(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= 32 and string.match(v, "^[%w_%-]+$") ~= nil
end

local TIER_FIELDS = { id = true, color = true, glow = true, glowStrength = true, soundKey = true }

function Tiers.resolve(spec: any): ({ TierDef }?, { string })
	local errors: { string } = {}
	if spec == nil then
		spec = Tiers.DEFAULT_PRESET
	end
	if type(spec) == "string" then
		local preset = Tiers.PRESETS[spec]
		if preset == nil then
			local names = {}
			for name in Tiers.PRESETS do
				table.insert(names, name)
			end
			table.sort(names)
			table.insert(
				errors,
				`config.Rarity.tiers: unknown preset '{spec}' (presets: {table.concat(names, ", ")}; or a list of tiers)`
			)
			return nil, errors
		end
		return preset, errors
	end
	if type(spec) ~= "table" then
		table.insert(
			errors,
			"config.Rarity.tiers must be a preset name or a list of { id, color?, glow?, soundKey? }"
		)
		return nil, errors
	end
	local n = #spec
	if n == 0 then
		table.insert(errors, "config.Rarity.tiers: the tier list is empty")
	elseif n > Tiers.MAX_TIERS then
		table.insert(errors, `config.Rarity.tiers: at most {Tiers.MAX_TIERS} tiers`)
	end
	for k in spec do
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
			table.insert(errors, `config.Rarity.tiers must be a list (array), got key {tostring(k)}`)
		end
	end
	local out: { TierDef } = {}
	local seen: { [string]: boolean } = {}
	for i = 1, n do
		local t = spec[i]
		local where = `config.Rarity.tiers[{i}]`
		if type(t) ~= "table" then
			table.insert(errors, where .. " must be a table { id, color?, glow?, soundKey? }")
			continue
		end
		for field in t do
			if not TIER_FIELDS[field] then
				table.insert(errors, `{where}.{tostring(field)}: unknown field`)
			end
		end
		if not isTierId(t.id) then
			table.insert(errors, where .. ".id must be a short id string (letters, digits, _ -)")
		elseif seen[t.id] then
			table.insert(errors, `{where}.id duplicate '{t.id}'`)
		else
			seen[t.id] = true
		end
		if t.color ~= nil and not isHex(t.color) then
			table.insert(errors, where .. ".color must be '#RRGGBB'")
		end
		if t.glow ~= nil and not isHex(t.glow) then
			table.insert(errors, where .. ".glow must be '#RRGGBB'")
		end
		if
			t.glowStrength ~= nil
			and (type(t.glowStrength) ~= "number" or not (t.glowStrength >= 0 and t.glowStrength <= 1))
		then
			table.insert(errors, where .. ".glowStrength must be a number in 0..1")
		end
		if t.soundKey ~= nil and (type(t.soundKey) ~= "string" or t.soundKey == "") then
			table.insert(errors, where .. ".soundKey must be a non-empty string")
		end
		table.insert(
			out,
			table.freeze({
				id = t.id,
				color = t.color,
				glow = t.glow,
				glowStrength = t.glowStrength,
				soundKey = t.soundKey,
			})
		)
	end
	if #errors > 0 then
		return nil, errors
	end
	return table.freeze(out), errors
end

function Tiers.rankMap(tiers: { TierDef }): { [string]: number }
	local rank: { [string]: number } = {}
	for i, t in tiers do
		rank[t.id] = i
	end
	return rank
end

function Tiers.defaultLuckMinTier(tiers: { TierDef }): string
	return tiers[math.min(3, #tiers)].id
end

return table.freeze(Tiers)
