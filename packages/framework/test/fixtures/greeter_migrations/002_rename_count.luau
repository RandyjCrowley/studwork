--!strict
-- v1 { count } -> v2 { visits }
return function(old: any): any
	old.visits = old.count or 0
	old.count = nil
	return old
end
