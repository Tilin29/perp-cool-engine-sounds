# Light bar rebuild (addons/police_lightbar)

The PERPHeads light bar (`models/perpheads/props/police_lightbar.mdl`, workshop 2897742669) rebuilt as
`models/perpheads/props/police_lightbar_leds.mdl`: the same body, every LED lens on its own material
(`materials/police_lightbar/lens_*.vmt`), so cl_police can light each lens itself.

Run from a working folder (scratch, not the repo):

1. `python -I gma_index.py <workshop>/content/4000/2897742669/content.gma` writes `index.json` (the archive's file list).
2. `python -I decompile.py` writes `src/lightbar_leds.smd` (body only, in the pose the game draws, turned for
   `$staticprop`, triangles wound for studiomdl) and `src/lens_textures.json`.
3. Copy `police_lightbar_leds.qc` into `src/`, then
   `<GarrysMod>/bin/studiomdl.exe -game <GarrysMod>/garrysmod -nop4 police_lightbar_leds.qc`; it writes to
   `garrysmod/models/perpheads/props/`: move the .mdl, .vvd and .dx90.vtx into `addons/police_lightbar/models/perpheads/props/`.
4. `python -I verify.py` compares the build with the original: every triangle in the same place and winding.

Left out of the rebuild (our bar never uses them): the LED / basic screen bodygroups, their 11 message skins,
the screen bone and the screenflip animation.

## Lens textures

`python -I make_vtf.py <addons/police_lightbar/materials/police_lightbar> <source folder>` builds `leds_large.vtf`
(512x128, the face lenses) and `leds_small.vtf` (256x128, the corner lenses) from `led_large.bmp` / `led_small.bmp`
(unlit) and `led_<large|small>_<red|white|blue|yellow>.png` (the user's lit versions): 5 frames, 0 unlit, 1 red,
2 white, 3 blue, 4 yellow; uncompressed BGRA8888 with mipmaps (no image library: `imageio.py` reads PNG / BMP).
The lit frames' alpha is 255, the unlit frame's 0: the lens VMTs' `$selfillum` mask, so a lit lens glows in the dark.
cl_police's `AudioLightbarLens` material proxy picks each lens's frame as the bar is drawn.
