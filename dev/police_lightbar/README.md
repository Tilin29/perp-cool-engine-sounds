# Light bar rebuild (addons/police_lightbar)

The PERPHeads light bar (`models/perpheads/props/police_lightbar.mdl`, workshop 2897742669) rebuilt as
`models/perpheads/props/police_lightbar_leds.mdl`: the same body, every LED lens on its own material
(`materials/police_lightbar/lens_*.vmt`), so cl_police can light each lens itself.

Then `install.cmd` copies the addon into garrysmod/addons (restart GMod). Run the steps from a working folder (scratch, not the repo):

1. `python -I gma_index.py <workshop>/content/4000/2897742669/content.gma` writes `index.json` (the archive's file list).
2. `python -I decompile.py` writes `src/lightbar_leds.smd` (body only, the mesh as stored: studiomdl turns a `$staticprop`
   +90 deg, which puts the bar's front at +Y like the cars; turned -90 it sat back to front on the cars; triangles wound
   for studiomdl; lenses named by where they end up) and `src/lens_textures.json`.
3. Copy `police_lightbar_leds.qc` into `src/`, then
   `<GarrysMod>/bin/studiomdl.exe -game <GarrysMod>/garrysmod -nop4 police_lightbar_leds.qc`; it writes to
   `garrysmod/models/perpheads/props/`: move the .mdl, .vvd and .dx90.vtx into `addons/police_lightbar/models/perpheads/props/`.
4. `python -I verify.py` compares the build with the original's mesh turned +90: every triangle in the same place and
   winding, and every lens at sh_police's module table position.

Left out of the rebuild (our bar never uses them): the LED / basic screen bodygroups, their 11 message skins,
the screen bone and the screenflip animation.

## Lens textures

`python -I make_vtf.py <addons/police_lightbar/materials/police_lightbar> <source folder>` builds `leds_large.vtf`
(512x128, the face lenses) and `leds_small.vtf` (256x128, the corner lenses) from `led_large.bmp` / `led_small.bmp`
(unlit) and `led_<large|small>_<red|white|blue|yellow>.png` (the user's lit versions): 5 frames, 0 unlit, 1 red,
2 white, 3 blue, 4 yellow; uncompressed BGRA8888 with mipmaps (no image library: `imageio.py` reads PNG / BMP).
The lit frames' alpha is 255, the unlit frame's 0: the lens VMTs' `$selfillum` mask, so a lit lens glows in the dark.

## The flashing (VMTs and skins, no Lua)

`python -I make_vmts.py <addons/police_lightbar/materials/police_lightbar> police_lightbar_leds.qc` writes the lens
materials and the QC's `$texturegroup`, then recompile (step 3 above). Skin 0 = unlit (`lens_*`); then police, fire,
medical x CODE 2, CODE 3 x phase 0, 1 (13 skins), each lens on a `flash_<size>_<colour>_<code>_<a|b|c>` material whose
proxies (CurrentTime, Add, WrapMinMax, LessOrEqual) run its pattern and set `$frame`: a / b the two wig-wag halves
(b = half a period later), c the centre's double flash. Phase 1 = half a period later, i.e. a and b swapped, so it
costs almost nothing: studiomdl allows 64 materials per model (this one has 51). The server sets the skin
(`AudioEngine.SetLights` / `LightbarSkin`).

`python -I check_vmts.py <materials dir> <the .mdl>` runs every skin's materials as Source's proxies do and compares each
lens's frame with cl_police's pattern (which the glow and HUD follow) every 5 ms: must report 0 differences.
