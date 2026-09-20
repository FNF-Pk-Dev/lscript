package lscript;

import lscript.*;

import llua.Lua;
import llua.LuaL;
import llua.State;
import llua.LuaOpen;

import cpp.Callable;
import cpp.RawPointer;

using StringTools;

/**
 * The class used for making lua scripts.
 * 
 * Base code written by YoshiCrafter29 (https://github.com/YoshiCrafter29)
 * Fixed and tweaked by Srt (https://github.com/SrtHero278)
 * 
 * Features:
 * - Global variables accessible via the 'global' table in Lua
 * - Direct Haxe access to variables via getVar/setVar
 * 
 * Example Lua usage:
 * ```lua
 * global.myVar = "test"  -- Set global variable
 * print(global.myVar)    -- Access global variable
 * ```
 */
class LScript {
	public static var currentLua:LScript = null;
	
	public static var GlobalVars:Map<String, Dynamic> = new Map<String, Dynamic>();

	public var luaState:State;
	public var tracePrefix:String = "testScript: ";
	public var parent(get, set):Dynamic;
	public var script(get, null):Dynamic;
	public var unsafe(default, null):Bool;
	var toParse:String;

	/**
	 * The map containing the special vars so lua can utilize them by getting the location used in the `__special_id` field.
	 */
	public var specialVars:Map<Int, Dynamic> = [-1 => null];
	public var avalibableIndexes:Array<Int> = [];
	public var nextIndex:Int = 1;
	
	public function new(code:String, ?unsafe:Bool = false) {
		luaState = LuaL.newstate();
		if(unsafe)
			LuaL.openlibs(luaState);
		else {
			LuaOpen.base(luaState);
			LuaOpen.math(luaState);
			LuaOpen.string(luaState);
			LuaOpen.table(luaState);
		}
		this.unsafe = unsafe;
		
		// Luau doesn't need hxtrace registration
		// Lua.register_hxtrace_func(Callable.fromStaticFunction(scriptTrace));
		// Lua.register_hxtrace_lib(luaState);

		Lua.newtable(luaState);
		final tableIndex = Lua.gettop(luaState); //The variable position of the table. Used for paring the metatable with this table.
		Lua.pushvalue(luaState, tableIndex);

		LuaL.newmetatable(luaState, "__scriptMetatable");
		final metatableIndex = Lua.gettop(luaState); //The variable position of the table. Used for setting the functions inside this metatable.
		Lua.pushvalue(luaState, metatableIndex);
		Lua.setglobal(luaState, "__scriptMetatable");

		Lua.pushstring(luaState, '__index'); //This is a function in the metatable that is called when you to get a var that doesn't exist.
		Lua.pushcfunction(luaState, MetatableFunctions.callIndex);
		Lua.settable(luaState, metatableIndex);
		
		Lua.pushstring(luaState, '__newindex'); //This is a function in the metatable that is called when you to set a var that was originally null.
		Lua.pushcfunction(luaState, MetatableFunctions.callNewIndex);
		Lua.settable(luaState, metatableIndex);
		
		Lua.pushstring(luaState, '__call'); //This is a function in the metatable that is called when you call a function inside the table.
		Lua.pushcfunction(luaState, MetatableFunctions.callMetatableCall);
		Lua.settable(luaState, metatableIndex);

		Lua.pushstring(luaState, '__gc'); //This is a function in the metatable that is called when you call a function inside the table.
		Lua.pushcfunction(luaState, MetatableFunctions.callGarbageCollect);
		Lua.settable(luaState, metatableIndex);

		Lua.setmetatable(luaState, tableIndex);

		LuaL.newmetatable(luaState, "__enumMetatable");
		final enumMetatableIndex = Lua.gettop(luaState); //The variable position of the table. Used for setting the functions inside this metatable.
		Lua.pushvalue(luaState, enumMetatableIndex);

		Lua.pushstring(luaState, '__index'); //This is a function in the metatable that is called when you to get a var that doesn't exist.
		Lua.pushcfunction(luaState, MetatableFunctions.callEnumIndex);
		Lua.settable(luaState, enumMetatableIndex);

		specialVars[0] = {"import": (unsafe) ? ClassWorkarounds.importClass : ClassWorkarounds.importClassSafe};

		Lua.newtable(luaState);
		final scriptTableIndex = Lua.gettop(luaState);
		Lua.pushvalue(luaState, scriptTableIndex);
		Lua.setglobal(luaState, "script");

		Lua.pushstring(luaState, '__special_id'); //This is a helper var in the table that is used by the conversion functions to detect a special var.
		Lua.pushinteger(luaState, 0);
		Lua.settable(luaState, scriptTableIndex);

		LuaL.getmetatable(luaState, "__scriptMetatable");
		Lua.setmetatable(luaState, scriptTableIndex);
		
		// Create global table for sharing variables between scripts
		createGlobalTable();

		//Adding a suffix to the end of the lua file to attach a metatable to the global vars. (So you don't have to do `script.parent.this`)
		toParse = preprocessCode(code) + '\nsetmetatable(_G, {
			__newindex = function (notUsed, name, value)
				__scriptMetatable.__newindex(script.parent, name, value)
			end,
			__index = function (notUsed, name)
				return __scriptMetatable.__index(script.parent, name)
			end
		})';
	}

	public function execute() {
		final lastLua:LScript = currentLua;
		currentLua = this;

		if (LuaL.luau_loadsource(luaState, "script", toParse) != 0) {
			parseError(Lua.tostring(luaState, -1));
			currentLua = lastLua;
			return;
		}

		if (Lua.pcall(luaState, 0, 0, 0) != 0) {
			parseError(Lua.tostring(luaState, -1));
		}

		currentLua = lastLua;
	}

	private function preprocessCode(code:String):String {

		var processedCode = code;

		processedCode = ~/\bglobal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=/g.map(processedCode, function (e) {
			var varName = e.matched(1);
			return varName + " =";
		});

		processedCode = ~/\bglobal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(/g.map(processedCode, function (e) {
			var varName = e.matched(1);
			return varName + " (";
		});
		
		return processedCode;
	}

	public dynamic function parseError(err:String) {
		trace("Lua code was unable to be parsed.\n" + err);
	}

	public dynamic function functionError(func:String, err:String) {
		Sys.println(tracePrefix + 'Function("$func") Error: ${Lua.tostring(luaState, -1)}');
	}

	public dynamic function print(line:Int, s:String) {
		Sys.println('${tracePrefix}:${line}: ' + s);
	}

	static inline function scriptTrace(s:String):Int {
		var info:Lua_Debug = {};
		Lua.getstack(currentLua.luaState, 1, info);
		Lua.getinfo(currentLua.luaState, "l", info);

		var toTrace = "";
		final numParams = Lua.gettop(currentLua.luaState);
		for (i in 0...(numParams - 1))
			toTrace += Std.string(CustomConvert.fromLua(-numParams + i));

		currentLua.print(info.currentline, toTrace);
		return 0;
	}

	public function getVar(name:String):Dynamic {
		var toReturn:Dynamic = null;

		final lastLua:LScript = currentLua;
		currentLua = this;

		Lua.getglobal(luaState, name);
		toReturn = CustomConvert.fromLua(-1);
		Lua.pop(luaState, 1);

		currentLua = lastLua;

		return toReturn;
	}

	public function setVar(name:String, newValue:Dynamic) {
		final lastLua:LScript = currentLua;
		currentLua = this;

		CustomConvert.toLua(newValue);
		Lua.setglobal(luaState, name);
		
		currentLua = lastLua;
	}

	public function callFunc(name:String, ?params:Array<Dynamic>):Dynamic {
		final lastLua:LScript = currentLua;
		currentLua = this;

		Lua.settop(luaState, 0);
		Lua.getglobal(luaState, name); //Finds the function from the script.

		if (!Lua.isfunction(luaState, -1))
			return null;

		//Pushes the parameters of the script.
		var nparams:Int = 0;
		if (params != null && params.length > 0) {
			nparams = params.length;
	   		for (val in params)
				CustomConvert.toLua(val);
		}
		
		//Calls the function of the script. If it does not return 0, will trace what went wrong.
		if (Lua.pcall(luaState, nparams, 1, 0) != 0) {
			functionError(name, Lua.tostring(luaState, -1));
			return null;
		}

		//Grabs and returns the result of the function.
		final v = CustomConvert.fromLua(Lua.gettop(luaState));
		Lua.settop(luaState, 0);
		currentLua = lastLua;
		return v;
	}

	inline function get_script() {
		return specialVars[0];
	}

	inline function get_parent() {
		return specialVars[0].parent;
	}
	inline function set_parent(newParent:Dynamic) {
		return specialVars[0].parent = newParent;
	}
	
	/**
	 * Creates a global table that can be used to share variables between different lua scripts
	 */
	function createGlobalTable() {
		// Create the global metatable for shared variables
		LuaL.newmetatable(luaState, "__globalMetatable");
		final globalMetatableIndex = Lua.gettop(luaState);
		
		// Set __index function for the global table
		Lua.pushstring(luaState, "__index");
		Lua.pushcfunction(luaState, Callable.fromStaticFunction(globalIndex));
		Lua.settable(luaState, globalMetatableIndex);
		
		// Set __newindex function for the global table
		Lua.pushstring(luaState, "__newindex");
		Lua.pushcfunction(luaState, Callable.fromStaticFunction(globalNewIndex));
		Lua.settable(luaState, globalMetatableIndex);
		
		// Create the global table
		Lua.newtable(luaState);
		final globalTableIndex = Lua.gettop(luaState);
		
		// Set metatable for the global table
		LuaL.getmetatable(luaState, "__globalMetatable");
		Lua.setmetatable(luaState, globalTableIndex);
		
		// Set the global table in the Lua state
		Lua.setglobal(luaState, "global");
	}
	
	/**
	 * The C function for __index of the global table
	 */
	public static function globalIndex(state:StatePointer):Int {
		final globalName = Lua.tostring(cast state, -1);
		if (LScript.GlobalVars.exists(globalName)) {
			CustomConvert.toLua(LScript.GlobalVars.get(globalName));
			return 1;
		}
		Lua.pushnil(cast state);
		return 1;
	}
	
	/**
	 * The C function for __newindex of the global table
	 */
	public static function globalNewIndex(state:StatePointer):Int {
		final globalName = Lua.tostring(cast state, -2);
		final value = CustomConvert.fromLua(-1);
		LScript.GlobalVars.set(globalName, value);
		return 0;
	}
}
