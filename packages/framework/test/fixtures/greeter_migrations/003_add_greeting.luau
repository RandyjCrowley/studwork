--!strict
-- v2 -> v3: greeting derived from visits
return function(old: any): any
	old.greeting = if old.visits > 0 then "welcome back" else "hello"
	return old
end
