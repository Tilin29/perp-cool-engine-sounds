// The PERPHeads light bar (models/perpheads/props/police_lightbar.mdl, workshop 2897742669), body only,
// every LED lens on its own material (materials/police_lightbar/lens_*.vmt), so each one can be lit on
// its own (SetSubMaterial). Model space as the original draws (long axis X, front +Y).
$modelname "perpheads/props/police_lightbar_leds.mdl"
$staticprop
$body "Body" "lightbar_leds.smd"
$surfaceprop "metal"
$illumposition 0 0 9.465
$cdmaterials "police_lightbar/"
$cdmaterials "models/jarheads/props/police_lightbar/"
$sequence "idle" "lightbar_leds.smd" fps 30
