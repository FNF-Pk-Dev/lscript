-- Luau Script Example with Type Annotations
-- This demonstrates the modern Lua runtime with optional type safety

local spriteX: number = 640
local spriteY: number = 360
local rotationSpeed: number = 100

function create()
	print("Luau script initialized!")
	print("Screen dimensions: " .. tostring(getRandomNum(1, 100)))
	
	-- Use built-in Lua libraries
	print("Math operations:")
	print("sqrt(16) = " .. tostring(math.sqrt(16)))
	print("max(3, 7) = " .. tostring(math.max(3, 7)))
	
	print("String operations:")
	print("upper('hello') = " .. string.upper("hello"))
	print("String length: " .. tostring(string.len("Luau")))
	
	-- Table operations
	local myTable = {1, 2, 3, 4, 5}
	table.insert(myTable, 6)
	print("Table size after insert: " .. tostring(#myTable))
end

function update(dt: number)
	-- Update sprite position
	spriteX = spriteX + dt * 50
	spriteY = spriteY + dt * 30
	
	-- Clamp to screen boundaries
	if spriteX > 1280 then spriteX = 0 end
	if spriteY > 720 then spriteY = 0 end
	
	-- Optional: call Haxe functions
	-- setProperty("sprite.x", spriteX)
	-- setProperty("sprite.y", spriteY)
end

-- Helper function
function getRandomNum(min: number, max: number): number
	return math.floor(math.random() * (max - min + 1)) + min
end

-- Luau supports type annotations for better performance and safety
function calculateDistance(x1: number, y1: number, x2: number, y2: number): number
	local dx = x2 - x1
	local dy = y2 - y1
	return math.sqrt(dx * dx + dy * dy)
end

print("Script loaded successfully!")
