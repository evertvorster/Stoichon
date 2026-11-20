# deep_sky.exr — generated, do not edit

An atlas of the extended objects' **shape and colour**: dimensionless linear RGB in half float, one 512x512 cell
per object, in the order `SpacesimDeepSky.objects()` returns them. The object's integrated magnitude, the display
gain and the frame's currency are applied by the sampler, so the atlas survives a change to any of them.

Produced by `tools/bake_deep_sky.gd` from `addons/spacesim/celestial/shaders/deep_sky_profile.gdshaderinc` — the
same file `deep_sky_quad.gdshader` includes at run time, so a baked object and a procedural one cannot disagree.
