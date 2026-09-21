package lscript;

import lscript.LScript;

import llua.State;

/**
 * Convenience wrapper around `LScript` for callers that only want "a Luau state I can register
 * functions on and run a chunk with".
 *
 * It used to be a second, independent implementation that built its own VM state and wrapped Haxe
 * callbacks in `llua.LuaCallback` objects - but never pushed those before `Lua.setglobal()`, so its
 * `registerFunction()` stored whatever happened to be on the stack and calling it from Lua went
 * through a null function pointer. It now delegates to `LScript`, which owns the VM, the protected
 * dispatch and the conversions, so this class inherits all of that.
 *
 * Like it used to, the state is opened with every standard library (`LScript`'s `unsafe` mode).
 */
class LuauScript
{
	public static var currentScript:LuauScript = null;

	public static var GlobalFunctions:Map<String, Dynamic> = new Map<String, Dynamic>();

	/** The state of the script in this wrapper, `null` after `dispose()`. */
	public var luaState(default, null):State;
	public var scriptName:String = "luau_script";
	public var scriptCode:String = "";
	public var isRunning:Bool = false;

	/** The script doing the actual work. */
	public var lscript(default, null):LScript;

	/** Last error reported by the VM, if any. */
	public var lastError:String = null;

	public function new(code:String, ?scriptName:String = "luau_script")
	{
		this.scriptCode = (code != null) ? code : "";
		this.scriptName = (scriptName != null) ? scriptName : "luau_script";

		lscript = new LScript(this.scriptCode, true);
		lscript.tracePrefix = '[$this.scriptName] ';
		lscript.parseError = (err:String) ->
		{
			lastError = err;
			trace('[$this.scriptName] $err');
		};
		lscript.functionError = (func:String, err:String) ->
		{
			lastError = err;
			trace('[$this.scriptName] error in "$func": $err');
		};

		luaState = lscript.luaState;
		currentScript = this;
	}

	/** Registers a Haxe function the script can call by name. */
	public function registerFunction(name:String, callback:Dynamic):Void
	{
		if (callback == null || name == null) return;

		lscript.setVar(name, callback);
		GlobalFunctions.set(name, callback);
	}

	/** Registers a function at a nested path such as `"object.method"` or `"a.b.c"`. */
	public function registerNestedFunction(path:String, callback:Dynamic):Void
	{
		if (callback == null || path == null) return;

		final parts:Array<String> = path.split(".");
		if (parts.length < 2)
		{
			registerFunction(path, callback);
			return;
		}

		// Built as Haxe maps and handed over in one go: the conversion turns each level into a real
		// Lua table, and the innermost value (the callback) stays callable.
		var nested:Dynamic = callback;
		var position:Int = parts.length - 1;
		while (position >= 1)
		{
			final holder:haxe.ds.StringMap<Dynamic> = new haxe.ds.StringMap<Dynamic>();
			holder.set(parts[position], nested);
			nested = holder;
			position--;
		}

		lscript.setVar(parts[0], nested);
		GlobalFunctions.set(path, callback);
	}

	/** Runs the chunk. @return `false` when the VM reported a parse or runtime error. */
	public function execute():Bool
	{
		if (lscript == null || lscript.closed) return false;

		lastError = null;
		lscript.execute();
		isRunning = (lastError == null);
		return isRunning;
	}

	/** Calls a global function of the script. */
	public function callFunction(name:String, ?args:Array<Dynamic>):Dynamic
	{
		if (lscript == null || lscript.closed || !isRunning)
		{
			trace('[$this.scriptName] Script is not running');
			return null;
		}
		return lscript.callFunc(name, args);
	}

	/** Reads a global of the script. */
	public function getVariable(name:String):Dynamic
	{
		if (lscript == null || lscript.closed) return null;
		return lscript.getVar(name);
	}

	/** Sets a global of the script. */
	public function setVariable(name:String, value:Dynamic):Void
	{
		if (lscript == null || lscript.closed) return;
		lscript.setVar(name, value);
	}

	/** Closes the VM state; the wrapper cannot be used afterwards. */
	public function dispose():Void
	{
		if (lscript != null && !lscript.closed) lscript.stop();

		luaState = null;
		isRunning = false;
		GlobalFunctions.clear();
		if (currentScript == this) currentScript = null;
	}

	/** Short description of the wrapper, for logs. */
	public function getStatus():String
	{
		return 'LuauScript: $scriptName - Running: $isRunning';
	}
}
