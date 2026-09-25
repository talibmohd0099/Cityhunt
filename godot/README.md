# Lost City, Godot version

The same game as the browser version (`index.html` in the repo root), rebuilt in Godot 4.6 so it can
run as a native Android app with better graphics and physics later on.

## Get the APK

Every push to `main` that changes this folder builds a new APK and publishes it on the
`godot-apk-latest` release. On your Android phone open
https://github.com/talibmohd0099/Cityhunt/releases/tag/godot-apk-latest, tap `LostCity-Godot.apk`
and allow installing from your browser when asked. It installs as "Lost City Godot", next to the
web-version app.

## Open it in Godot

1. Install Godot 4.6.2 (standard version) from https://godotengine.org/download.
2. Open Godot, press Import, pick `godot/project.godot`.
3. Press F5 to play. Mouse drag looks around, WASD walks, Shift runs, Space sprints,
   C crouches, F toggles the light, E interacts.

## What is where

- `scripts/game.gd`: the game rules, clues, escape, director and end screens
- `scripts/player.gd`, `monster.gd`, `child.gd`: the three characters
- `scripts/hud.gd`: HUD, touch controls, start / pause / end / settings screens
- `scripts/world.gd`, `col.gd`: the city, lights, rain and collision
- `assets/baked/`: city, characters and textures exported from the browser version by `tools/bake`
- `tests/autoplay.gd`: plays whole games by itself and checks each step (runs on every build)

## Run the automatic test

```
godot --headless --path godot --fixed-fps 20 -s res://tests/autoplay.gd -- --mode=win --seed=3
```

`--mode=win` must end in a rescue, `--mode=lose` must end with being caught, `--mode=wild` lets the
creature hunt freely. It prints `ok` or `FAIL` for each check and exits with an error if anything failed.
