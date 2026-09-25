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

Graphics can be set under Settings: Auto picks a level from how fast the phone runs; Low, Medium
and High fix it (render resolution, reflections, glow, flashlight shadow, how far cars are drawn).

## What is where

- `scripts/game.gd`: the game rules, clues, escape, director and end screens
- `scripts/player.gd`, `monster.gd`, `child.gd`: the three characters
- `scripts/hud.gd`: HUD, touch controls, start / pause / end / settings screens
- `scripts/world.gd`, `col.gd`: the city, lights, rain and collision
- `assets/baked/`: city, characters and textures exported from the browser version by `tools/bake`
- `assets/pbr/`: close-up surface detail (asphalt, paving slabs, brick relief, rain drops), made by
  `tools/textures/make_textures.py`
- `assets/vehicles/*_far.glb`: light stand-ins for the car models seen from far away, made by
  `tools/vehicles/make_far_lod.py`
- `shaders/`: wet streets, building walls, car paint, light halos and police light bars
- `tests/autoplay.gd`: plays whole games by itself and checks each step (runs on every build)

## Run the automatic test

```
godot --headless --path godot --fixed-fps 20 -s res://tests/autoplay.gd -- --mode=win --seed=3
```

`--mode=win` must end in a rescue, `--mode=lose` must end with being caught, `--mode=wild` lets the
creature hunt freely. It prints `ok` or `FAIL` for each check and exits with an error if anything failed.
