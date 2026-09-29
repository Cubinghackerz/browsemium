# Browsemium brand

`logo.svg` is the source of truth. Its two solid triangles make one mark: a
64-unit vertical seam, with the right half 40 units lower. Keep that offset and
the seam intact when scaling or recolouring. Run
`python3 Scripts/generate-brand-assets.py` after changing the geometry.

The mark uses the current text colour on light and dark surfaces. On very dark
surfaces use white; on light surfaces use near-black. Do not add outlines,
gradients, or colour to the mark. The app icon puts the white mark on a dark
824-unit rounded plate with a subtle shadow. The light plate variant is
`icon-light.svg` and is a reference, not the shipping icon.

Keep at least 80/1024 of the mark canvas clear on every side. At 16 px, use
only the mark, never the wordmark. Set “Browsemium” in Geist Sans, sentence
case, with tight tracking (-0.02em); keep a gap of at least one seam width
between mark and type.

The site self-hosts the Geist webfont; the app bundles the Geist variable TTF
for the New Tab wordmark. The OFL licence is recorded in `ThirdPartyNotices/`.
