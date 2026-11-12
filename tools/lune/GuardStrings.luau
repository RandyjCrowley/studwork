--!nocheck
--[[
	tools/lune/GuardStrings: the `strings` check of tools/lune/guardrails.luau (v1.7.0,
	docs/framework/kits/localization.md, module-api.md §23.12): hard-coded English in the UI kit,
	kit client parts and framework client code, and string keys without an English default.

	  GuardStrings.scanSource(source, ctx) -> { string }   findings for one file's source;
	                                                       ctx = { path, defaults? = { [key] = true } }
	  GuardStrings.scanAll(fs) -> { string }               packages/ui/**, packages/kits/*/*/client/**,
	                                                       packages/framework/client/** (not specs, not
	                                                       Strings.luau default tables, not generated files)
	  GuardStrings.selfTest() -> { string }                planted-violation failures (empty = every
	                                                       planted case behaved); called by --self-test

	Each finding: `<path>:<line>: [strings] <message>` (the shape Guard.parseFinding reads).

	STUB (foundation): registered with the lint, scans nothing, plants nothing. The localization
	builder (B3) implements scanSource / scanAll and the planted cases listed on the page.
]]

local GuardStrings = {}

function GuardStrings.scanSource(_source: string, _ctx: any): { string }
	return {} -- STUB (B3)
end

function GuardStrings.scanAll(_fs: any): { string }
	return {} -- STUB (B3)
end

function GuardStrings.selfTest(): { string }
	return {} -- STUB (B3): plant `Text = "Close"` in a UI component, a toast literal and a key without a default
end

return GuardStrings
