package;

import lscript.LuauScript;
import flixel.FlxGame;
import flixel.FlxState;
import flixel.text.FlxText;
import flixel.util.FlxColor;

class Main extends openfl.display.Sprite {
	public function new():Void {
		super();
		addChild(new FlxGame(1280, 720, TestState, 120, 120, true));
	}
}