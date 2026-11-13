local Routing = require(script.Parent.SoundRouting)
describe("effects routing", function()
	it("reroutes existing pooled voices when the local group preference changes", function()
		local attrs, groups = {}, {}
		local update
		local disconnected = false
		local player = {
			GetAttribute = function(_, key)
				return attrs[key]
			end,
			GetAttributeChangedSignal = function()
				return {
					Connect = function(_, fn)
						update = fn
						return {
							Disconnect = function()
								disconnected = true
							end,
						}
					end,
				}
			end,
		}
		local service = {
			FindFirstChild = function(_, name)
				return groups[name]
			end,
		}
		local function create()
			return setmetatable({
				IsA = function(_, class)
					return class == "SoundGroup"
				end,
			}, {
				__newindex = function(t, k, v)
					rawset(t, k, v)
					if k == "Parent" then
						groups[t.Name] = t
					end
				end,
			})
		end
		local route = Routing.new(player, service, create)
		local sound: any = {}
		route.attach(sound)
		expect(sound.SoundGroup.Name).toBe("CoreEffects")
		attrs.CoreEffectsGroup = "QuietEffects"
		update()
		expect(sound.SoundGroup.Name).toBe("QuietEffects")
		groups.Conflict = {
			IsA = function()
				return false
			end,
		}
		attrs.CoreEffectsGroup = "Conflict"
		update()
		expect(sound.SoundGroup).toBeNil()
		route.destroy()
		expect(disconnected).toBe(true)
	end)
end)
