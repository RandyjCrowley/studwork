--!strict
--[[
	The census (module-api.md §23.5): how many servers and players the experience has, from a
	framework-owned sorted map (`SW/_/census`), so modules scale their cadences with the server
	count, plus the usage items that carry each module's memory charges.

	  Census.new(opts) -> census
	    opts = { fixed = { servers, players, peakPlayers? }?  a fixed reading (harness `census = {...}`),
	             now = () -> number, interval = number, map = sorted-map backend?, log }
	    census.start()          begin reporting and reading (a background loop on a live server)
	    census.get() -> CensusInfo?     the last reading; nil until the first read; doesn't yield
	    census.api = ctx.data.census (the same function, frozen)

	STUB (foundation): `fixed` readings work (the harness and specs); without one `get` is nil and
	`start` does nothing. The report/read loop, the bucketed update, the 8-day peak and the usage
	items are the stores builder's (B1).
]]

local Census = {}

function Census.new(opts: any): any
	local fixed = opts.fixed
	local now: () -> number = opts.now or os.time
	local c: any = {}

	function c.start() end -- STUB (B1)

	function c.get(): any
		if type(fixed) ~= "table" then
			return nil
		end
		return table.freeze({
			servers = fixed.servers,
			players = fixed.players,
			peakPlayers = fixed.peakPlayers or fixed.players,
			at = now(),
		})
	end

	c.api = c.get
	return c
end

return Census
