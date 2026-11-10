--!strict
--[[
	Server console for Studio testing and live admin use. LEAD-OWNED.

	Creates ServerScriptService.CoreServer.CoreConsole (BindableFunction). From the Studio command
	bar (Server context during Play) or the Studio MCP server VM:
		game.ServerScriptService.CoreServer.CoreConsole:Invoke("help")
		game.ServerScriptService.CoreServer.CoreConsole:Invoke("event", "CoinRain")
	Services register commands in start() with ctx.console.register(name, help, fn). Commands
	return a string. BindableFunctions are server-only, so clients can never reach this.
]]

local ServerScriptService = game:GetService("ServerScriptService")

type Command = { help: string, fn: (...any) -> string? }

local Console = {}

local commands: { [string]: Command } = {}

function Console.register(name: string, help: string, fn: (...any) -> string?)
	assert(commands[name] == nil, "[Core.Console] command already registered: " .. name)
	commands[name] = { help = help, fn = fn }
end

local function run(name: any, ...: any): string
	if name == nil or name == "help" then
		local lines = { "Core console commands:" }
		local names = {}
		for n in commands do
			table.insert(names, n)
		end
		table.sort(names)
		for _, n in names do
			table.insert(lines, "  " .. n .. " - " .. commands[n].help)
		end
		return table.concat(lines, "\n")
	end
	local command = commands[name]
	if command == nil then
		return "unknown command '" .. tostring(name) .. "' (try 'help')"
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return command.fn(table.unpack(args, 1, args.n))
	end)
	if not ok then
		return "error: " .. tostring(result)
	end
	return if result == nil then "ok" else tostring(result)
end

function Console.start()
	local root = ServerScriptService:FindFirstChild("CoreServer")
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "CoreConsole"
	bindable.OnInvoke = run
	bindable.Parent = root or ServerScriptService
end

return Console
