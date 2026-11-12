--!strict
--[[
	`ctx.openCloud` (module-api.md §23.7): Open Cloud from a game server, deny by default.

	  OpenCloud.new(opts) -> { forModule(moduleName) -> OpenCloudAPI }
	    opts = { config = ServerConfig.openCloud?, transport = platform.openCloud, now, log }
	  OpenCloud.matches(pattern, path) -> boolean        `*` = exactly one segment, no `**`
	  OpenCloud.refusedSurface(path) -> string?          the surface to use for a hard-refused family
	  OpenCloud.checkPath(path) -> (pathPart?, problem?) relative, no `..`, scheme, `%`, empty segment

	transport (platform.openCloud; live: PlatformServices, tests: StudWork.test.fakes.openCloud()):
	  hasSecret(secretName) -> boolean
	  request({ secret, method, path, body? }) -> (ok, status?, body?)

	Order of checks in request (each refusal makes no request):
	  1. arguments (a programming error raises): secret name, method, path shape, body table;
	  2. hard-refused families, whatever the config says -> (false, nil, "forbidden"), one warning;
	  3. the allow-list: ServerConfig.openCloud.secrets[secret] lists the calling module, the
	     method and a path pattern the path matches -> else (false, nil, "not_allowed"), one
	     warning per (module, secret) naming the missing part;
	  4. the secret: available(secret) -> else (false, nil, "no_secret"), logged once;
	  5. the server's budget: at most perMinute requests a minute -> else (false, nil, "budget").
	A transport error is (false, nil, "failed"); a non-2xx answer is (false, status, body) for the
	caller to handle (modules decide retries). Secret values, request and response bodies and error
	texts are never logged; logs show the secret's name. `available` doesn't yield after the first
	call: the transport's answer is cached per secret (a server's secrets don't change while it
	runs) and the allow-list part is a table lookup per module.
]]

local OpenCloud = {}

OpenCloud.DEFAULT_PER_MINUTE = 600
OpenCloud.WINDOW_SECONDS = 60
OpenCloud.MAX_PATH_LENGTH = 2048
OpenCloud.METHODS = table.freeze({ GET = true, POST = true, PATCH = true, DELETE = true })

-- The families no allow-list entry can open: a path segment starting with `prefix` (compared in
-- lower case, so `Data-Stores` or `memory-store:flush` are caught too) -> the surface to use.
OpenCloud.REFUSED_FAMILIES = table.freeze({
	table.freeze({ prefix = "ordered-data-store", surface = "ctx.data.ordered" }),
	table.freeze({ prefix = "data-store", surface = "ctx.data" }),
	table.freeze({ prefix = "datastore", surface = "ctx.data" }),
	table.freeze({ prefix = "standard-datastore", surface = "ctx.data" }),
	table.freeze({ prefix = "ordered-datastore", surface = "ctx.data.ordered" }),
	table.freeze({ prefix = "memory-store", surface = "ctx.data.sortedMap" }),
	table.freeze({ prefix = "configs", surface = "ctx.flags" }),
	table.freeze({ prefix = "luau-execution", surface = "none (Luau execution is never allowed)" }),
})

local function split(path: string): { string }
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

-- -> (the path without its query, nil) or (nil, what is wrong with it)
function OpenCloud.checkPath(path: any): (string?, string?)
	if type(path) ~= "string" or path == "" then
		return nil, "path must be a non-empty string"
	end
	if #path > OpenCloud.MAX_PATH_LENGTH then
		return nil, "path is too long"
	end
	if string.find(path, "://", 1, true) then
		return nil, "path must be relative (no scheme)"
	end
	if string.find(path, "..", 1, true) then
		return nil, "path must not contain '..'"
	end
	if string.find(path, "[%c%s\\#]") then
		return nil, "path must not contain spaces, control characters, '\\' or '#'"
	end
	local pathPart = string.match(path, "^([^?]*)") :: string
	if pathPart == "" or string.sub(pathPart, 1, 1) == "/" then
		return nil, "path must be relative (no leading '/')"
	end
	if string.find(pathPart, "//", 1, true) or string.sub(pathPart, -1) == "/" then
		return nil, "path must not have empty segments"
	end
	if string.find(pathPart, "%", 1, true) then
		return nil, "path segments must not be percent-encoded"
	end
	for _, seg in split(pathPart) do
		if seg == "." then
			return nil, "path must not contain '.' segments"
		end
	end
	return pathPart, nil
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
	local pathPart = string.match(path, "^([^?]*)") or path
	for _, seg in split(string.lower(pathPart)) do
		for _, family in OpenCloud.REFUSED_FAMILIES do
			if string.sub(seg, 1, #family.prefix) == family.prefix then
				return family.surface
			end
		end
	end
	return nil
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
	local hasSecretCache: { [string]: boolean } = {}
	local windowStart, used = -math.huge, 0

	local function warnOnce(id: string, message: string)
		if not warned[id] then
			warned[id] = true
			log(message)
		end
	end

	-- the transport's answer for a secret, asked once per server (a raising transport = no secret)
	local function secretExists(secretName: string): boolean
		local cached = hasSecretCache[secretName]
		if cached ~= nil then
			return cached
		end
		local exists = false
		if transport ~= nil then
			local ok, has = pcall(transport.hasSecret, secretName)
			exists = ok and has == true
		end
		hasSecretCache[secretName] = exists
		return exists
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

		local function notAllowed(secretName: string, missing: string)
			warnOnce(
				`deny:{moduleName}:{secretName}`,
				`[StudWork.OpenCloud] {moduleName}: secret '{secretName}' refused: {missing} (ServerConfig.openCloud.secrets)`
			)
		end

		local function available(secretName: string): boolean
			if type(secretName) ~= "string" or secretName == "" then
				return false
			end
			if rule(secretName) == nil then
				notAllowed(secretName, `the entry doesn't list modules = {"{"} "{moduleName}" {"}"}`)
				return false
			end
			if not secretExists(secretName) then
				warnOnce(
					`nosecret:{moduleName}:{secretName}`,
					`[StudWork.OpenCloud] {moduleName}: secret '{secretName}' is not available (missing from the secrets store, HTTP requests off, or a local playtest without a local secret); its requests return no_secret`
				)
				return false
			end
			return true
		end

		local function request(req: any): (boolean, number?, any)
			if type(req) ~= "table" or type(req.secret) ~= "string" or req.secret == "" then
				error(`{moduleName}: ctx.openCloud.request({"{"} secret, method, path, body? {"}"})`, 2)
			end
			if not OpenCloud.METHODS[req.method] then
				error(`{moduleName}: ctx.openCloud.request: method must be GET, POST, PATCH or DELETE`, 2)
			end
			local pathPart, problem = OpenCloud.checkPath(req.path)
			if pathPart == nil then
				error(`{moduleName}: ctx.openCloud.request: {problem}`, 2)
			end
			if req.body ~= nil and type(req.body) ~= "table" then
				error(`{moduleName}: ctx.openCloud.request: body must be a table (sent as JSON)`, 2)
			end
			local secretName: string = req.secret
			local surface = OpenCloud.refusedSurface(pathPart :: string)
			if surface ~= nil then
				warnOnce(
					`forbidden:{moduleName}:{secretName}`,
					`[StudWork.OpenCloud] {moduleName}: {req.method} {pathPart} is in a refused family; use {surface}`
				)
				return false, nil, "forbidden"
			end
			local r = rule(secretName)
			if r == nil then
				notAllowed(secretName, `the entry doesn't list modules = {"{"} "{moduleName}" {"}"}`)
				return false, nil, "not_allowed"
			end
			if type(r.methods) ~= "table" or not table.find(r.methods, req.method) then
				notAllowed(secretName, `method {req.method} isn't in its methods`)
				return false, nil, "not_allowed"
			end
			local matched = false
			for _, pattern in (if type(r.paths) == "table" then r.paths else {}) :: { any } do
				if type(pattern) == "string" and OpenCloud.matches(pattern, pathPart :: string) then
					matched = true
					break
				end
			end
			if not matched then
				notAllowed(secretName, `no pattern in its paths matches '{pathPart}'`)
				return false, nil, "not_allowed"
			end
			if not available(secretName) then
				return false, nil, "no_secret"
			end
			local t = now()
			if t - windowStart >= OpenCloud.WINDOW_SECONDS then
				windowStart, used = t, 0
			end
			if used >= perMinute then
				warnOnce(
					`budget:{moduleName}:{math.floor(windowStart)}`,
					`[StudWork.OpenCloud] {moduleName}: this server's {perMinute} Open Cloud requests a minute are used up (ServerConfig.openCloud.perMinute)`
				)
				return false, nil, "budget"
			end
			used += 1
			local ok, accepted, status, body = pcall(transport.request, {
				secret = secretName,
				method = req.method,
				path = req.path,
				body = req.body,
			})
			if not ok then
				-- never the error text: it could carry a header value
				warnOnce(
					`failed:{moduleName}:{secretName}`,
					`[StudWork.OpenCloud] {moduleName}: a request with secret '{secretName}' failed (network or HTTP error)`
				)
				return false, nil, "failed"
			end
			local code: number? = if type(status) == "number" then status else nil
			local success = accepted == true and (code == nil or (code >= 200 and code < 300))
			return success, code, body
		end

		return table.freeze({ available = available, request = request })
	end

	return self
end

return OpenCloud
