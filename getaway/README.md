# Getaway (prototype)

A one-thumb driving game: you are in a getaway car at night in the rain, with the police right
behind you. Drag left and right to steer through the traffic. The longer you last, the faster it
gets. Passing a car closely scores a bonus, and close calls in a row multiply it. Hit anything and
you are busted.

It is a small Godot 4.6 project next to Lost City and reuses its car models, surface textures and
rain sounds.

## Get the APK

Every push to `main` that changes this folder builds a new APK and publishes it on the
`getaway-apk-latest` release. On your Android phone open
https://github.com/talibmohd0099/Cityhunt/releases/tag/getaway-apk-latest, tap `Getaway.apk`
and allow installing from your browser when asked. It installs as its own app, "Getaway".

## Open it in Godot

1. Install Godot 4.6.2 (standard version) from https://godotengine.org/download.
2. Open Godot, press Import, pick `getaway/project.godot`.
3. Press F5 to play. Click to start, then drag with the mouse or use the arrow keys to steer.

## What is where

- `scripts/game.gd`: the rules: steering, traffic, crashes, close calls, score and speed
- `scripts/city.gd`: the street that scrolls past the car: road, sidewalks, lamps, buildings, rain
- `scripts/car_models.gd`: builds the cars from the Lost City models (full model close, light stand-in far)
- `scripts/hud.gd`, `game_audio.gd`: the screens and the sound
- `shaders/`: wet road, night buildings, car paint and rain
- `assets/sounds/engine_loop.wav`, `siren_loop.wav`, `whoosh.wav`: made by `tools/getaway/make_sounds.py`
- `tests/autoplay.gd`: drives whole runs by itself and checks each step (runs on every build)

## Run the automatic test

```
godot --headless --path getaway --fixed-fps 30 -s res://tests/autoplay.gd -- --seed=1
```

It drives for a minute, crashes on purpose, checks the busted screen and the saved best score,
then starts a new run. It prints `ok` or `FAIL` for each check and exits with an error if anything
failed.
