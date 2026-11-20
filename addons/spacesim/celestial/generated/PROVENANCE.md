# milky_way.exr — generated, do not edit

An equirectangular map of the galactic band's **shape**: longitude across (zero at the galactic centre), latitude
up, linear RGB in half float, in the GALACTIC frame. The sampler applies the frame's rotation and the band's
surface brightness and display gain, so the map survives a change to any of them.

Produced by `tools/bake_band.gd` from `addons/spacesim/celestial/shaders/milky_way.gdshaderinc` — the same file
`celestial_sky.gdshader` includes at run time, so the baked and the procedural band cannot disagree.
