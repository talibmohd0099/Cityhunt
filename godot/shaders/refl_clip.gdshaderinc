// Drop anything below the street when drawing the wet-street reflection (camera layer 20).
#define REFL_CLIP if ((CAMERA_VISIBLE_LAYERS & uint(1 << 19)) != uint(0) && (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y < -0.02) { discard; }
