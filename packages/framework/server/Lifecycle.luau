--!strict
--[[
	ctx.lifecycle (module-api.md §3): onPlayerLoaded, onPlayerRemoving, onTick, onShutdown.
	One shared, batched ticker for all modules (tick(dt) is driven by Heartbeat on a live server
	and by the harness in tests). Each handler runs in pcall, tagged with its module, so one
	module's failure never stops another's. onPlayerRemoving handlers must not yield (a yield is
	reported and the handler is abandoned, as before the final save).
]]

local Lifecycle = {}

function Lifecycle.new(log: (string) -> ())
	local loaded: { { tag: string, fn: (any) -> () } } = {}
	local removing: { { tag: string, fn: (any) -> () } } = {}
	local shutdown: { { tag: string, fn: () -> () } } = {}
	local ticks: { { tag: string, interval: number, acc: number, fn: (number) -> () } } = {}

	local function run(tag: string, what: string, fn: any, ...: any)
		local co = coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			log(`[{tag}] {what} failed: {tostring(err)}`)
		elseif coroutine.status(co) ~= "dead" then
			coroutine.close(co)
			log(`[{tag}] {what} yielded (not allowed); handler abandoned`)
		end
	end

	local lc = {}

	function lc.api(tag: string)
		return table.freeze({
			onPlayerLoaded = function(fn: (player: any) -> ())
				assert(type(fn) == "function", "onPlayerLoaded expects a function")
				table.insert(loaded, { tag = tag, fn = fn })
			end,
			onPlayerRemoving = function(fn: (player: any) -> ())
				assert(type(fn) == "function", "onPlayerRemoving expects a function")
				table.insert(removing, { tag = tag, fn = fn })
			end,
			onTick = function(seconds: number, fn: (dt: number) -> ())
				assert(type(seconds) == "number" and seconds > 0, "onTick(seconds, fn): seconds must be > 0")
				assert(type(fn) == "function", "onTick expects a function")
				table.insert(ticks, { tag = tag, interval = seconds, acc = 0, fn = fn })
			end,
			onShutdown = function(fn: () -> ())
				assert(type(fn) == "function", "onShutdown expects a function")
				table.insert(shutdown, { tag = tag, fn = fn })
			end,
		})
	end

	function lc.firePlayerLoaded(player: any)
		for _, h in loaded do
			run(h.tag, "onPlayerLoaded", h.fn, player)
		end
	end

	function lc.firePlayerRemoving(player: any)
		for _, h in removing do
			run(h.tag, "onPlayerRemoving", h.fn, player)
		end
	end

	function lc.fireShutdown()
		for _, h in shutdown do
			local ok, err = pcall(h.fn :: any)
			if not ok then
				log(`[{h.tag}] onShutdown failed: {tostring(err)}`)
			end
		end
	end

	-- Advance the shared ticker by dt seconds; each handler fires once per elapsed interval
	-- (catch-up capped at 10 per call so a long hitch can't spiral).
	function lc.tick(dt: number)
		for _, t in ticks do
			t.acc += dt
			local n = 0
			while t.acc >= t.interval and n < 10 do
				t.acc -= t.interval
				n += 1
				run(t.tag, "onTick", t.fn, t.interval)
			end
			if n == 10 then
				t.acc = 0
			end
		end
	end

	return lc
end

return Lifecycle
