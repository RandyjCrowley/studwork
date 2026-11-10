-- The sandbox config must always pass core's validator (Core.start refuses invalid configs).
local Config = require(script.Parent.Config)
local ConfigValidate =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("ConfigValidate"))

describe("sandbox Config", function()
	it("is a valid GameConfig", function()
		local errors = ConfigValidate.validate(Config)
		if #errors > 0 then
			error(table.concat(errors, "\n"))
		end
		expect(#errors).toBe(0)
	end)
end)
