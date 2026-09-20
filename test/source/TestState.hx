package;

import lscript.LuauScript;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;

class TestState extends FlxState {
	var script:LuauScript;

	override public function create() {
		super.create();
		
		// Load and initialize Luau script
		var scriptCode = openfl.Assets.getText("assets/test.lua");
		script = new LuauScript(scriptCode, "TestState");
		
		// Register global functions available to Lua
		script.registerFunction("print", function(args:haxe.Rest<Dynamic>) {
			trace("[Lua] " + args.toArray().map(Std.string).join(" "));
		});
		
		script.registerFunction("getRandomNum", function(min:Int, max:Int) {
			return FlxG.random.int(min, max);
		});
		
		script.registerNestedFunction("FlxG.width", function() {
			return FlxG.width;
		});
		
		script.registerNestedFunction("FlxG.height", function() {
			return FlxG.height;
		});
		
		// Execute script
		if (script.execute()) {
			trace("Script loaded successfully");
			// Call create callback if it exists
			script.callFunction("create");
		} else {
			trace("Failed to load script");
		}
	}

	override public function update(elapsed:Float) {
		super.update(elapsed);
		script.callFunction("update", [elapsed]);
	}

	override public function destroy() {
		if (script != null) {
			script.dispose();
		}
		super.destroy();
	}
}