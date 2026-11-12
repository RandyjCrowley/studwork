--!strict
--[[
	`ctx.openCloud` (module-api.md §23.7): Open Cloud from a game server, deny by default.

	  OpenCloud.new(opts) -> { forModule(moduleName) -> OpenCloudAPI }
	    opts = { config = ServerConfig.openCloud?, transport = platform.openCloud, now, log, analytics? }

	transport (platform.openCloud; live: PlatformServices, tests: StudWork.test.fakes.openCloud()):
	  hasSecret(secretName) -> boolean
	  request({ secret, method, path, body? }) -> (ok, status?, body?)

	A request is made only when ServerConfig.openCloud.secrets[secret] lists the calling module, the
	method and a path pattern the path matches (`*` = exactly one segment). Anything else returns
	(false, nil, "not_allowed") with one warning per (module, secret). The hard-refused families
	(data stores, ordered data stores, memory stores, configs, Luau execution) return
	(false, nil, "forbidden"). An unavailable secret returns (false, nil, "no_secret"); over
	`perMinute` requests a minute (false, nil, "budget"). Secret values, request and response bodies
	are never logged; logs show the secret's name.

	FIRST CUT (foundation, so the notification builder's specs can run against the fake): the
	allow-list, the refused families, the secret check and the per-minute budget are implemented
	here; the owner of this file (B2) hardens and specs them (path normalisation edge cases,
	analytics, the cached `available`, the live transport in PlatformServices).
]]

local OpenCloud = {}

OpenCloud.DEFAULT_PER_MINUTE = 600
OpenCloud.METHODS = table.freeze({ GET = true, POST = true, PATCH = true, DELETE = true })

-- The families no allow-list entry can open: path segment (or prefix) -> the surface to use.
OpenCloud.REFUSED_SEGMENTS = table.freeze({
	{ segment = "data-stores", surface = "ctx.data" },
	{ segment = "ordered-data-stores", surface = "ctx.data.ordered" },
	{ segment = "memory-store", surface = "ctx.data.sortedMap", prefix = true },
	{ segment = "configs", surface = "ctx.flags", prefix = true },
	{ segment = "luau-execution", surface = "none (Luau execution is never allowed)", prefix = true },
})

local function split(path: string): { string }
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

function OpenCloud.matches(pattern: string, path: string): boolean
	local p, q = split(pattern), split(path)
	if #p ~= #q then
		return false
	end
	for i, seg in p do
		if seg ~= "*" and seg ~= q[i] then
			return false
		end
	end
	return true
end

-- -> the surface name when `path` is in a hard-refused family
function OpenCloud.refusedSurface(path: string): string?
	for _, seg in split(path) do
		for _, family in OpenCloud.REFUSED_SEGMENTS do
			local hit = if (family :: any).prefix
				then string.sub(seg, 1, #family.segment) == family.segment
				else seg == family.segment
			if hit then
				return family.surface
			end
		end
	end
	return nil
end

local function badPath(path: any): boolean
	return type(path) ~= "string"
		or path == ""
		or string.find(path, "..", 1, true) ~= nil
		or string.find(path, "://", 1, true) ~= nil
		or string.sub(path, 1, 1) == "/"
end

function OpenCloud.new(opts: any): any
	local config = if type(opts.config) == "table" then opts.config else {}
	local secrets: { [string]: any } = if type(config.secrets) == "table" then config.secrets else {}
	local perMinute: number = if type(config.perMinute) == "number"
		then config.perMinute
		else OpenCloud.DEFAULT_PER_MINUTE
	local transport = opts.transport
	local now: () -> number = opts.now or os.time
	local log: (string) -> () = opts.log or function(_m: string) end
	local warned: { [string]: boolean } = {}
	local windowStart, used = 0, 0

	local function warnOnce(id: string, message: string)
		if not warned[id] then
			warned[id] = true
			log(message)
		end
	end

	local self: any = {}

	function self.forModule(moduleName: string): any
		local function rule(secretName: string): any
			local r = secrets[secretName]
			if type(r) == "table" and type(r.modules) == "table" and table.find(r.modules, moduleName) then
				return r
			end
			return nil
		end

		local function available(secretName: string): boolean
			if type(secretName) ~= "string" or rule(secretName) == nil then
				warnOnce(
					`na:{moduleName}:{tostring(secretName)}`,
					`[StudWork.OpenCloud] {moduleName} isn't allowed to use secret '{tostring(secretName)}': add it to ServerConfig.openCloud.secrets with modules = {"{"} "{moduleName}" {"}"}`
				)
				return false
			end
			if transport == nil then
				return false
			end
			local ok, has = pcall(transport.hasSecret, secretName)
			return ok and has == true
		end

		local function request(req: any): (boolean, number?, any)
			if type(req) ~= "table" or type(req.secret) ~= "string" then
				error(`{moduleName}: ctx.openCloud.request({"{"} secret, method, path, body? {"}"})`, 2)
			end
			if not OpenCloud.METHODS[req.method] then
				error(`{moduleName}: ctx.openCloud.request: method must be GET, POST, PATCH or DELETE`, 2)
			end
			if badPath(req.path) then
				error(`{moduleName}: ctx.openCloud.request: path must be relative, with no '..' or scheme`, 2)
			end
			local surface = OpenCloud.refusedSurface(req.path)
			if surface ~= nil then
				warnOnce(
					`forbidden:{moduleName}:{req.secret}`,
					`[StudWork.OpenCloud] {moduleName}: that path family is refused; use {surface}`
				)
				return false, nil, "forbidden"
			end
			local r = rule(req.secret)
			local allowed = false
			if r ~= nil and type(r.methods) == "table" and table.find(r.methods, req.method) then
				for _, pattern in (if type(r.paths) == "table" then r.paths else {}) :: { string } do
					if OpenCloud.matches(pattern, req.path) then
						allowed = true
						break
					end
				end
			end
			if not allowed then
				warnOnce(
					`deny:{moduleName}:{req.secret}`,
					`[StudWork.OpenCloud] {moduleName}: {req.method} {req.path} with secret '{req.secret}' is not in ServerConfig.openCloud.secrets (needs the module, the method and a path pattern)`
				)
				return false, nil, "not_allowed"
			end
			if transport == nil or not available(req.secret) then
				return false, nil, "no_secret"
			end
			local t = now()
			if t - windowStart >= 60 then
				windowStart, used = t, 0
			end
			if used >= perMinute then
				return false, nil, "budget"
			end
			used += 1
			local ok, accepted, status, body = pcall(transport.request, {
				secret = req.secret,
				method = req.method,
				path = req.path,
				body = req.body,
			})
			if not ok then
				return false, nil, "failed" -- never the error text: it could carry a secret
			end
			return accepted == true and (status == nil or (status >= 200 and status < 300)), status, body
		end

		return table.freeze({ available = available, request = request })
	end

	return self
end

return OpenCloud
