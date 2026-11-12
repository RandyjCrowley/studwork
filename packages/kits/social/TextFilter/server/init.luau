--!strict
--[[
	TextFilter: the server part (docs/framework/kits/textfilter.md).

	FOUNDATION SKELETON: a valid part that FAILS CLOSED: `filter` and `store` refuse every call
	(`filter_failed`, so the caller shows its fallback), `textFor` and `shown` return nil, `release`
	does nothing. Unfiltered text can never come out of it. The badges and text builder (B5)
	implements the page: contexts, the fresh filter per submission, the re-display cache, originals
	in this module's section, shownMaxDays, rate limit and the content-sharing policy.
]]

local TextFilter = {}

function TextFilter.init(_context: any) end -- STUB (B5)

function TextFilter.start(_context: any) end -- STUB (B5)

TextFilter.api = {
	-- STUB (B5)
	filter = function(_author: any, _text: string, _context: string): (boolean, any)
		return false, "filter_failed"
	end,
	textFor = function(_viewer: any, _author: any, _text: string, _context: string): string?
		return nil
	end,
	store = function(_author: any, _text: string, _context: string): (boolean, any)
		return false, "filter_failed"
	end,
	shown = function(_stored: any, _viewer: any?): string?
		return nil
	end,
	release = function(_author: any, _stored: any) end,
}

return TextFilter
