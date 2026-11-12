--!nocheck
--[[
	tools/lune/GuardTextFilter: the `textfilter` check of tools/lune/guardrails.luau (v1.7.0,
	docs/framework/kits/textfilter.md, module-api.md §23.12): a client-supplied string reaching a
	player or a shared store without TextFilter, or a whole TextFilter record reaching one, in game,
	example and kit server code. Best effort, same function. `-- guard: allow textfilter` with a reason
	skips a line. A legacy list may name it (Guard.LEGACY_CHECKS).

	  GuardTextFilter.scanSource(source, ctx) -> { string }   findings for one file's source;
	                                                          ctx = { path, isServer = boolean }
	  GuardTextFilter.scanGame(fs, dir) -> { string }         a game folder's server code
	  GuardTextFilter.scanAll(fs) -> { string }               kit and example server files
	  GuardTextFilter.selfTest() -> { string }                planted-violation failures; called by --self-test

	Each finding: `<path>:<line>: [textfilter] <message>`.

	STUB (foundation): registered with the lint, scans nothing, plants nothing. The Badges and
	TextFilter builder (B5) implements the scan and the planted cases listed on the page.
]]

local GuardTextFilter = {}

function GuardTextFilter.scanSource(_source: string, _ctx: any): { string }
	return {} -- STUB (B5)
end

function GuardTextFilter.scanGame(_fs: any, _dir: string): { string }
	return {} -- STUB (B5)
end

function GuardTextFilter.scanAll(_fs: any): { string }
	return {} -- STUB (B5)
end

function GuardTextFilter.selfTest(): { string }
	return {} -- STUB (B5): the nine planted violations and the three clean flows on the page
end

return GuardTextFilter
