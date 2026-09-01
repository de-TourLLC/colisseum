local record = { name = "colisseum", values = { 3, 1, 4 } }
local sum = record.values[1] + record.values[2] + record.values[3]
return record.name .. ":" .. sum, record.values[2] < record.values[3]
