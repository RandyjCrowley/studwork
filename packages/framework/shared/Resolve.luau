--!strict
--[[
	Resolve a GameConfig.modules list (module-api.md §3 step 1). Pure; used by both sides.
	Generalises v1.2 shared/Modules.luau's resolve(): instead of a closed SPECS table, each
	ModuleRef declares its own dependsOn.

	Resolve.resolve(list, frameworkVersion) -> (order: { ModuleRef }?, errors: { string }?)
	  - every entry must be a ModuleRef (strings get a hint), listed once, with a unique name
	  - hard deps (dependsOn) must also be listed: no auto-enabling (an explicit list keeps games honest)
	  - data.key unique among enabled modules; framework range satisfied
	  - topo-sort on hard deps, ties broken by list order; a cycle is an error naming the cycle
	  Optional deps are NOT ordering edges (v1.2 had Inventory optional-on Plot while Plot requires
	  Inventory); a module must not call an optional dep's API before start anyway.
	All errors are collected, not fail-fast.
]]

local DefineModule = require(script.Parent.defineModule)
local Semver = require(script.Parent.Semver)

local Resolve = {}

function Resolve.notEnabledMessage(name: string): string
	return name .. " is not enabled in GameConfig.modules"
end

-- `isRef` is injectable only so the cycle path can be tested: refs from defineModule can't form a
-- cycle (a definition can only reference definitions that already exist), but hand-built
-- manifests on the client side or a future generator could.
function Resolve.resolve(
	list: any,
	frameworkVersion: string,
	isRef: ((any) -> boolean)?
): ({ any }?, { string }?)
	local isModuleRef = isRef or DefineModule.isModuleRef
	local errors: { string } = {}
	if type(list) ~= "table" then
		return nil, { "modules must be a list of module references (use {} for framework only)" }
	end
	local listed: { any } = {}
	local byName: { [string]: any } = {}
	local byKey: { [string]: string } = {}
	local position: { [any]: number } = {}
	for i, ref in list do
		if type(i) ~= "number" then
			table.insert(errors, "modules must be a list (array), got key " .. tostring(i))
		elseif type(ref) == "string" then
			table.insert(
				errors,
				`modules[{i}] is the string "{ref}": list module references (require the module definition), not names`
			)
		elseif not isModuleRef(ref) then
			table.insert(
				errors,
				`modules[{i}] is not a ModuleRef (a value returned by StudWork.defineModule)`
			)
		elseif position[ref] then
			table.insert(errors, `modules[{i}] '{ref.name}' listed twice`)
		elseif byName[ref.name] then
			table.insert(
				errors,
				`modules[{i}] two different modules are named '{ref.name}' (names must be unique; two copies of the same module.luau?)`
			)
		else
			position[ref] = i
			byName[ref.name] = ref
			table.insert(listed, ref)
			if ref.data then
				local key = ref.data.key
				if byKey[key] then
					table.insert(
						errors,
						`data.key '{key}' is declared by both '{byKey[key]}' and '{ref.name}': each save section has exactly one owner`
					)
				else
					byKey[key] = ref.name
				end
			end
			if not Semver.satisfies(frameworkVersion, ref.framework) then
				table.insert(
					errors,
					`module '{ref.name}' {ref.version} needs framework {ref.framework}, but this is framework {frameworkVersion}`
				)
			end
		end
	end
	for _, ref in listed do
		for _, dep in ref.dependsOn do
			if not position[dep] then
				if byName[dep.name] then
					table.insert(
						errors,
						`module '{ref.name}' depends on a different copy of '{dep.name}' than the one listed (require the same module.luau)`
					)
				else
					table.insert(
						errors,
						`module '{ref.name}' requires '{dep.name}': add {dep.name} to GameConfig.modules`
					)
				end
			end
		end
	end
	if #errors > 0 then
		return nil, errors
	end

	-- Topo-sort: repeatedly take the first module in list order whose hard deps are all placed.
	local placed: { [any]: boolean } = {}
	local order: { any } = {}
	while #order < #listed do
		local progressed = false
		for _, ref in listed do
			if not placed[ref] then
				local ready = true
				for _, dep in ref.dependsOn do
					if not placed[dep] then
						ready = false
						break
					end
				end
				if ready then
					placed[ref] = true
					table.insert(order, ref)
					progressed = true
					break
				end
			end
		end
		if not progressed then
			-- Find and name one cycle among the remaining modules (DFS from the first unplaced).
			local start
			for _, ref in listed do
				if not placed[ref] then
					start = ref
					break
				end
			end
			local stack: { any } = {}
			local onStack: { [any]: number } = {}
			local cycle: { string }? = nil
			local visited: { [any]: boolean } = {}
			local function dfs(ref: any)
				if cycle then
					return
				end
				table.insert(stack, ref)
				onStack[ref] = #stack
				visited[ref] = true
				for _, dep in ref.dependsOn do
					if cycle then
						return
					end
					if onStack[dep] then
						local names = {}
						for j = onStack[dep], #stack do
							table.insert(names, stack[j].name)
						end
						table.insert(names, dep.name)
						cycle = names
						return
					elseif not placed[dep] and not visited[dep] then
						dfs(dep)
					end
				end
				onStack[ref] = nil
				table.remove(stack)
			end
			dfs(start)
			local names = cycle or { start.name }
			return nil, { "dependency cycle: " .. table.concat(names, " -> ") }
		end
	end
	return order, nil
end

return Resolve
