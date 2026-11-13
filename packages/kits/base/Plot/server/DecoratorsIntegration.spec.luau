--!strict
local Decorators = require(game:GetService("ServerScriptService").Modules.Plot.Decorators)
describe("Plot final decorated bounds", function()
	it("positions resized placeholder and off-center template after the callback", function()
		local model: any = {
			Size = { X = 2, Y = 2, Z = 2 },
			Parent = nil,
			Destroying = {
				Connect = function(_self: any, fn: any)
					local _callback = fn
					return { Disconnect = function() end }
				end,
			},
		}
		local isModel = true
		function model:IsA(name: string)
			return name == "BasePart" or isModel and name == "Model"
		end
		function model:GetDescendants()
			return {}
		end
		function model:GetBoundingBox()
			return { Position = { X = 2, Y = 3, Z = 1 } }, self.Size
		end
		function model:GetPivot()
			return {
				ToObjectSpace = function(_self: any, _frame: any)
					return {
						Position = { X = 0, Y = 0, Z = 0 },
						RightVector = { Y = 0 },
						UpVector = { Y = 1 },
						LookVector = {
							Y = 0,
						},
					}
				end,
				PointToObjectSpace = function(_self: any, position: any)
					return position
				end,
			}
		end
		function model:FindFirstChildWhichIsA(_name: string, _recursive: boolean)
			return self
		end
		function model:PivotTo(value: any)
			self.final = value
		end
		local surface: any = setmetatable({}, {
			__mul = function(_a: any, b: any)
				return b
			end,
		})
		local frames = {
			new = function(x: number, y: number, z: number)
				return { X = x, Y = y, Z = z }
			end,
		}
		local registry = Decorators.new(function() end)
		registry.decorate("resize", function(visual: any)
			visual.Size = { X = 2, Y = 10, Z = 2 }
			error("partial")
		end)
		local result = registry.apply(model, {}, {})
		local height = Decorators.place(result, surface, frames)
		expect(height).toBe(10)
		expect(model.final.Y).toBe(2)
		expect(model.final.X).toBe(-2)
		expect(model.CanQuery).toBe(false)
		isModel = false
		Decorators.place(registry.apply(model, {}, {}), surface, frames)
		expect(model.final.Y).toBe(5)
	end)
	it("places a BasePart with translated and rotated PivotOffset using projected corners", function()
		for _, relative in
			{
				{
					Position = { X = 0, Y = -5, Z = 0 },
					RightVector = { Y = 0 },
					UpVector = { Y = 1 },
					LookVector = {
						Y = 0,
					},
				},
				{
					Position = { X = -5, Y = 0, Z = 0 },
					RightVector = { Y = -1 },
					UpVector = { Y = 0 },
					LookVector = {
						Y = 0,
					},
				},
			}
		do
			local part: any = { CFrame = {}, Size = { X = 2, Y = 4, Z = 6 } }
			function part:IsA(name: string)
				return name == "BasePart"
			end
			function part:GetPivot()
				return {
					ToObjectSpace = function(_self: any, _frame: any)
						return relative
					end,
				}
			end
			function part:PivotTo(value: any)
				self.final = value
			end
			local surface: any = setmetatable({}, {
				__mul = function(_a: any, b: any)
					return b
				end,
			})
			local frames = {
				new = function(x: number, y: number, z: number)
					return { X = x, Y = y, Z = z }
				end,
			}
			local height = Decorators.place(part, surface, frames)
			local bottom = math.huge
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local cornerY = part.final.Y
							+ relative.Position.Y
							+ x * part.Size.X / 2 * relative.RightVector.Y
							+ y * part.Size.Y / 2 * relative.UpVector.Y
							+ z * part.Size.Z / 2 * relative.LookVector.Y
						bottom = math.min(bottom, cornerY)
					end
				end
			end
			expect(bottom).toBe(0)
			expect(part.final.X + relative.Position.X).toBe(0)
			expect(height).toBe(if relative.UpVector.Y == 1 then 4 else 2)
		end
	end)
end)
