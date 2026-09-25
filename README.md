# Lost City

A mobile-first 3D survival rescue game that runs in the browser. It is night and raining in a New York / Paris-style city. You have to find a lost child, stay hidden from a huge creature hunting the streets, and get her out through a barricade.

**How to play:** the left thumb moves, the right thumb looks, and there are buttons for Sprint, Crouch, Light and Use. On desktop: WASD to move, Shift to run, Space to sprint, C to crouch, F for the light, E to interact.

## Run it locally

The game loads its assets with `fetch`, so it needs a local web server; opening `index.html` straight from disk won't work.

```bash
python3 -m http.server 8000
# then open http://localhost:8000
```

## Deploy

Every push to `main` publishes the game to GitHub Pages through `.github/workflows/deploy-pages.yml`. One-time setup: **Settings → Pages → Build and deployment → Source: GitHub Actions**. On a free GitHub plan the repository has to be public for Pages to work.

## Android APK

`.github/workflows/android-apk.yml` wraps the game in a [Capacitor](https://capacitorjs.com) Android app. It downloads three.js into the app, so the game works offline. Every push to `main` builds `LostCity.apk` and publishes it on the **apk-latest** release:

https://github.com/talibmohd0099/Cityhunt/releases/tag/apk-latest

To install it, open that page on your Android phone, tap `LostCity.apk`, and allow installs from your browser when Android asks. Every build is signed with the same debug key (`.github/android/debug.keystore`), so a new APK installs over the old one. The debug key is fine for sideloading. The Play Store needs a private release key instead.

Pull requests build the APK too. You can download it from the run's **Artifacts** section.

## What's inside

| Path | What it is |
|---|---|
| `index.html` | The whole game: rendering, city generation, AI, audio and UI |
| `assets/player.json` | The player character (a rigged Mixamo model) |
| `assets/xbot.json` | Animated humanoid rig (glTF with an embedded buffer) used for the player, the child and the monster |
| `assets/brick.jpg` | Brick detail texture for the facades |
| `assets/ripples.jpg` | Normal map for rain ripples in the puddle reflections |

Three.js r128 and its example loaders and post-processing passes are loaded from cdnjs / jsDelivr. There is no build step.

## Tech notes

- **Monster AI:** patrol → investigate → search → chase → lose. It detects you by distance, line of sight, how fast you move and whether your flashlight is on.
- **Rigged characters:** the clothing and the creature's skin are painted and sculpted in shaders.
- **Monster:** built on the same rig, but hunched, with longer arms, and a procedural head, claws and spines added.
- **Wet streets:** planar reflections, brick detail, bloom and a color grade.
- **Adaptive quality:** slow devices automatically turn off the reflections and bloom.
- **Sound:** all audio is synthesized with WebAudio.
- **Fallback:** if the character asset fails to load, the game falls back to procedural characters.
- **Weather:** the rain comes and goes at random, from clear to drizzle, rain and storm. Heavier rain hides more of your footsteps from the monster, and lightning only strikes in heavy rain.
- **Pause and settings:** the pause button (or Esc/P) pauses the game, which also happens automatically when the app goes to the background. Settings covers volume, rain volume, look speed, graphics (Auto/Low/High) and vibration, and they are saved on the device.
- **Records:** your rescues, attempts and best rescue time are saved on the device.

## License

All rights reserved. See [LICENSE](LICENSE). Third-party parts keep their own licenses.

## Credits

- The Xbot rig and the brick/water textures come from the [three.js examples](https://github.com/mrdoob/three.js/tree/dev/examples) (MIT).
- Fonts: Big Shoulders Display and Barlow (Google Fonts, OFL).
