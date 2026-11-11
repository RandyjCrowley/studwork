--!strict
--[[
	v1.3.0: v1.2 leftover restored here (compat) for the still-live v1.2 Core.start
	Replication; the framework Replication caches by section version itself. Delete in v1.3.0.

	Pure per-player section cache for Replication (zero dependencies, tested under Lune). M2.

	Problem: every DataChanged used to deep-copy the whole PlayerData (Snapshot.copy) and
	charm-sync then diffed the whole tree, because every table in the new copy was new.

	Here a cache keeps, per top-level PlayerData key ("section"), the sanitised copy plus the
	source table reference and Data.sectionVersion it was copied at. `build` returns a NEW
	top-level table (so charm-sync sees a change) whose untouched sections are the SAME table
	references as last time - charm-sync's diff short-circuits on `old == new` for them.

	A section is re-copied when its version moved OR its source table reference changed (e.g. a
	reload hands a fresh data table; also a safety net if a writer replaced a section without the
	version moving). Scalar sections (rebirths, lastSeen, ...) are copied by value every build.
	Excluded (server-only) sections never appear in the output.

	SectionCache.new(excluded?) -> cache
	cache:build(data, versionOf) -> sanitised data copy
		versionOf(section) -> number   (Replication passes ctx.services.Data.sectionVersion)
	cache:reset()                       forget everything (next build copies every section)
	cache.copies                        number of section deep copies made so far (stats/tests)
]]

local Snapshot = require(
	game:GetService("ServerScriptService")
		:WaitForChild("Framework")
		:WaitForChild("Replication")
		:WaitForChild("Snapshot")
)

local SectionCache = {}
SectionCache.__index = SectionCache

-- Server-only sections (Types.ReplicatedState.data comment): never sent to the client.
SectionCache.SERVER_ONLY = table.freeze({
	purchases = true,
	pity = true,
	funnel = true,
	mail = true,
})

type Entry = { source: any, version: number, copy: any }

export type SectionCache = typeof(setmetatable(
	{} :: {
		excluded: { [string]: boolean },
		entries: { [string]: Entry },
		copies: number,
	},
	SectionCache
))

function SectionCache.new(excluded: { [string]: boolean }?): SectionCache
	return setmetatable({
		excluded = excluded or SectionCache.SERVER_ONLY,
		entries = {},
		copies = 0,
	}, SectionCache)
end

function SectionCache.reset(self: SectionCache)
	self.entries = {}
end

function SectionCache.build(self: SectionCache, data: any, versionOf: (section: string) -> number): any
	if type(data) ~= "table" then
		self.entries = {}
		return nil
	end
	local out: { [string]: any } = {}
	local entries = self.entries
	local seen: { [string]: boolean } = {}
	for key, value in data do
		if type(key) ~= "string" or self.excluded[key] then
			continue
		end
		if type(value) ~= "table" then
			local copied = Snapshot.copy(value)
			if copied ~= nil then
				out[key] = copied
			end
			entries[key] = nil
			continue
		end
		seen[key] = true
		local version = versionOf(key)
		local entry = entries[key]
		if entry == nil or entry.version ~= version or entry.source ~= value then
			entry = { source = value, version = version, copy = Snapshot.copy(value) }
			entries[key] = entry
			self.copies += 1
		end
		out[key] = (entry :: Entry).copy
	end
	-- drop cache entries for sections that disappeared
	for key in entries do
		if not seen[key] then
			entries[key] = nil
		end
	end
	return out
end

return SectionCache
