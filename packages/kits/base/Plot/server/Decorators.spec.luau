--!strict
local Decorators = require(game:GetService("ServerScriptService").Modules.Plot.Decorators)

local function node(class: string): any
	local value: any =
		{ ClassName = class, children = {}, CanQuery = true, CanTouch = true, CanCollide = true }
	function value:IsA(name: string): boolean
		return name == class
			or name == "BasePart" and (class == "Part" or class == "MeshPart")
			or name == "JointInstance" and class == "Motor6D"
			or name == "LuaSourceContainer" and class == "Script"
	end
	function value:GetDescendants(): { any }
		local all = {}
		for _, child in self.children do
			table.insert(all, child)
			for _, nested in child:GetDescendants() do
				table.insert(all, nested)
			end
		end
		return all
	end
	function value:IsDescendantOf(root: any): boolean
		local parent = self.Parent
		while parent do
			if parent == root then
				return true
			end
			parent = parent.Parent
		end
		return false
	end
	function value:FindFirstChildWhichIsA(name: string): any
		for _, child in self:GetDescendants() do
			if child:IsA(name) then
				return child
			end
		end
		return nil
	end
	local destroyCallbacks = {}
	value.Destroying = {
		Connect = function(_self: any, fn: any)
			table.insert(destroyCallbacks, fn)
			return { Disconnect = function() end }
		end,
	}
	function value:Destroy()
		for _, callback in destroyCallbacks do
			callback()
		end
		self.Parent = nil
		for _, child in self.children do
			child:Destroy()
		end
		self.children = {}
	end
	return value
end
local function attach(child: any, parent: any)
	child.Parent = parent
	table.insert(parent.children, child)
end

describe("Plot decorators", function()
	it("preserves order, sanitizes partial failures and invalidates", function()
		local dirty = 0
		local registry = Decorators.new(function()
			dirty += 1
		end)
		local sequence = {}
		local connection = registry.decorate("resize", function(visual: any)
			table.insert(sequence, 1)
			visual.Size = Vector3.new(4, 6, 4)
			error("partial")
		end)
		registry.decorate("finish", function(visual: any)
			table.insert(sequence, 2)
			visual.CanQuery = true
		end)
		local part = node("Part")
		local result: any = registry.apply(part, {}, {})
		expect(result.Size.Y).toBe(6)
		expect(result.CanQuery).toBe(false)
		expect(table.concat(sequence, ",")).toBe("1,2")
		connection:Invalidate()
		expect(dirty).toBe(3)
		connection:Disconnect()
		connection:Disconnect()
		expect(dirty).toBe(4)
		result:Destroy()
	end)
	it("replaces destroyed or empty geometry without rerunning callbacks", function()
		local registry = Decorators.new(function() end, function()
			return node("Part")
		end)
		local calls = 0
		registry.decorate("remove", function(visual: any)
			calls += 1
			visual:Destroy()
			error("destroyed")
		end)
		local model = node("Model")
		local part = node("Part")
		attach(part, model)
		local result: any = registry.apply(model, {}, {})
		expect(result:IsA("BasePart")).toBe(true)
		expect(result.CanQuery).toBe(false)
		expect(calls).toBe(1)
		result:Destroy()
	end)
	it("closes yielded callbacks before they can mutate a sanitized visual", function()
		local registry = Decorators.new(function() end)
		local suspended: thread? = nil
		local changed = false
		registry.decorate("yielding", function()
			suspended = coroutine.running()
			coroutine.yield()
			changed = true
		end)
		registry.apply(node("Part"), {}, {})
		expect(coroutine.status(suspended :: thread)).toBe("dead")
		expect((coroutine.resume(suspended :: thread))).toBe(false)
		expect(changed).toBe(false)
	end)
	it("preserves internal beam and trail attachments and clears external endpoints", function()
		local model = node("Model")
		local part = node("Part")
		attach(part, model)
		local a = node("Attachment")
		attach(a, part)
		local b = node("Attachment")
		attach(b, part)
		local outside = node("Attachment")
		local beam = node("Beam")
		beam.Attachment0 = a
		beam.Attachment1 = b
		attach(beam, part)
		local trail = node("Trail")
		trail.Attachment0 = a
		trail.Attachment1 = outside
		attach(trail, part)
		Decorators.sanitize(model)
		expect(beam.Attachment0).toBe(a)
		expect(beam.Attachment1).toBe(b)
		expect(trail.Attachment0).toBe(a)
		expect(trail.Attachment1).toBe(nil)
	end)
end)
