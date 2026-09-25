# Lost City

A mobile-first 3D survival rescue game that runs in the browser. It is night and raining in a New York / Paris-style city. You have to find a lost child, stay hidden from a huge creature hunting the streets, and get her out through a barricade.

**How to play:** the left thumb moves, the right thumb looks, and there are buttons for Sprint, Crouch, Light and Use. On desktop: WASD to move, Shift to run, Space to sprint, C to crouch, F for the light, E to interact.

## Run it locally

The game loads its assets with `fetch`, so it needs a local web server; opening `index.html` straight from disk won't work.

```bash
python3 -m http.server 8000
# then open http://localhost:8000
```

To play it from a public URL, you can enable **GitHub Pages** (Settings → Pages → Deploy from branch → `main`, folder `/`).

## What's inside

| Path | What it is |
|---|---|
| `index.html` | The whole game: rendering, city generation, AI, audio and UI |
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

## Credits

- The Xbot rig and the brick/water textures come from the [three.js examples](https://github.com/mrdoob/three.js/tree/dev/examples) (MIT).
- Fonts: Big Shoulders Display and Barlow (Google Fonts, OFL).
