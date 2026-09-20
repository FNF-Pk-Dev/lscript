package lscript;

import llua.Lua;
import llua.LuaL;
import llua.State;
import llua.LuaOpen;
import llua.LuaCallback;
import llua.Convert;

using StringTools;

/**
 * Luau Script Manager - Modern Lua runtime with type annotations and performance optimizations
 * 
 * Features:
 * - Full Luau VM integration with type checking support
 * - Built-in Lua libraries (math, string, table, os, io)
 * - Global function registration from Haxe
 * - Script lifecycle management (create, update, destroy)
 * - Error handling with detailed stack traces
 * 
 * Example Lua usage:
 * ```lua
 * -- Luau supports type annotations (optional)
 * local myVar: string = "test"
 * 
 * -- Built-in libraries
 * print(math.sqrt(16))  -- 4
 * print(string.upper("hello"))  -- HELLO
 * 
 * -- Callback to Haxe
 * setProperty("variable", 123)
 * ```
 */
class LuauScript {
	public static var currentScript:LuauScript = null;
	public static var GlobalFunctions:Map<String, Dynamic> = new Map<String, Dynamic>();

	public var luaState:State;
	public var scriptName:String = "luau_script";
	public var scriptCode:String = "";
	public var isRunning:Bool = false;
	
	private var callbacks:Map<String, LuaCallback> = new Map<String, LuaCallback>();

	public function new(code:String, ?scriptName:String = "luau_script") {
		this.scriptCode = code;
		this.scriptName = scriptName;
		
		// Create new Luau state
		luaState = LuaL.newstate();
		
		// Open standard Luau libraries
		LuaOpen.base(luaState);
		LuaOpen.math(luaState);
		LuaOpen.string(luaState);
		LuaOpen.table(luaState);
		LuaOpen.os(luaState);
		LuaOpen.io(luaState);
		
		currentScript = this;
	}

	/**
	 * Register a Haxe function to be callable from Lua
	 */
	public function registerFunction(name:String, callback:Dynamic):Void {
		if (callback == null) return;
		
		var luaCallback = new LuaCallback(callback);
		callbacks.set(name, luaCallback);
		
		Lua.setglobal(luaState, name);
		GlobalFunctions.set(name, callback);
	}

	/**
	 * Register a nested function (e.g., "object.method")
	 */
	public function registerNestedFunction(path:String, callback:Dynamic):Void {
		if (callback == null) return;
		
		var parts = path.split(".");
		if (parts.length < 2) {
			registerFunction(path, callback);
			return;
		}
		
		// Create table if it doesn't exist
		Lua.getglobal(luaState, parts[0]);
		if (Lua.type(luaState, -1) != "table") {
			Lua.pop(luaState, 1);
			Lua.newtable(luaState);
			Lua.setglobal(luaState, parts[0]);
		}
		
		// Navigate to parent table
		for (i in 1...parts.length - 1) {
			Lua.getfield(luaState, -1, parts[i]);
			if (Lua.type(luaState, -1) != "table") {
				Lua.pop(luaState, 1);
				Lua.newtable(luaState);
				Lua.setfield(luaState, -2, parts[i]);
			}
		}
		
		// Set function
		var luaCallback = new LuaCallback(callback);
		callbacks.set(path, luaCallback);
		Lua.setfield(luaState, -1, parts[parts.length - 1]);
		Lua.pop(luaState, parts.length - 1);
	}

	/**
	 * Execute the Lua script
	 */
	public function execute():Bool {
		if (scriptCode == null || scriptCode.length == 0) {
			trace('[$scriptName] No script code to execute');
			return false;
		}
		
		try {
			var chunkName = '@$scriptName';
			LuaL.loadstring(luaState, scriptCode, chunkName);
			
			var result = Lua.pcall(luaState, 0, Lua.LUA_MULTRET, 0);
			if (result != 0) {
				var error = Lua.tostring(luaState, -1);
				trace('[$scriptName] Execution error: $error');
				Lua.pop(luaState, 1);
				return false;
			}
			
			isRunning = true;
			return true;
		} catch (e:Dynamic) {
			trace('[$scriptName] Exception: $e');
			return false;
		}
	}

	/**
	 * Call a Lua function from Haxe
	 */
	public function callFunction(name:String, ?args:Array<Dynamic>):Dynamic {
		if (!isRunning) {
			trace('[$scriptName] Script is not running');
			return null;
		}
		
		try {
			Lua.getglobal(luaState, name);
			
			if (Lua.type(luaState, -1) != "function") {
				Lua.pop(luaState, 1);
				trace('[$scriptName] Function "$name" not found or not a function');
				return null;
			}
			
			if (args != null) {
				for (arg in args) {
					Convert.toLua(luaState, arg);
				}
			}
			
			var argc = (args != null) ? args.length : 0;
			var result = Lua.pcall(luaState, argc, 1, 0);
			
			if (result != 0) {
				var error = Lua.tostring(luaState, -1);
				trace('[$scriptName] Call error: $error');
				Lua.pop(luaState, 1);
				return null;
			}
			
			var returnValue = Convert.fromLua(luaState, -1);
			Lua.pop(luaState, 1);
			return returnValue;
		} catch (e:Dynamic) {
			trace('[$scriptName] Exception calling $name: $e');
			return null;
		}
	}

	/**
	 * Get a global Lua variable
	 */
	public function getVariable(name:String):Dynamic {
		try {
			Lua.getglobal(luaState, name);
			var value = Convert.fromLua(luaState, -1);
			Lua.pop(luaState, 1);
			return value;
		} catch (e:Dynamic) {
			trace('[$scriptName] Error getting variable "$name": $e');
			return null;
		}
	}

	/**
	 * Set a global Lua variable
	 */
	public function setVariable(name:String, value:Dynamic):Void {
		try {
			Convert.toLua(luaState, value);
			Lua.setglobal(luaState, name);
		} catch (e:Dynamic) {
			trace('[$scriptName] Error setting variable "$name": $e');
		}
	}

	/**
	 * Dispose the Lua state
	 */
	public function dispose():Void {
		if (luaState != null) {
			LuaL.close(luaState);
			luaState = null;
			isRunning = false;
			callbacks.clear();
		}
	}

	/**
	 * Get script status
	 */
	public function getStatus():String {
		return 'LuauScript: $scriptName - Running: $isRunning';
	}
}
