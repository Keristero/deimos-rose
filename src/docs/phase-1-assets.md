# Phase 1 — Asset pipeline

**Status: complete.** `mise run assets:extract` then `mise run assets:verify`.

```
read 871 entries  crc ok 871  crc bad 0  written 746  passthrough 473
pak entries CRC-verified: 871
manifest entries: 746
outputs present: 746/746
assets verified
```

871 CRC-validated entries matches the figure the clean-room remaster project
reports for the same corpus, from independent code.

## Output

| Directory | Files | Contents |
|---|---:|---|
| `assets/sprites/im08/` | 125 | RGBA PNG, IA+IC plates combined |
| `assets/images/im16/` | 45 | RGBA PNG from 16-bit TGA |
| `assets/audio/` | 99 | 16-bit PCM WAV, 44.1 kHz |
| `assets/films/` | 4 | replay data, byte-exact passthrough |
| `assets/records/` | 473 | definition records, byte-exact passthrough |
| `assets/manifest.json` | 1 | 746 entries with type, size, CRC32, dimensions |

871 inputs → 746 outputs because the 250 GIF plate files collapse into 125
paired sprites.

## What the originals turned out to be

**Every PAK is a stored (method 0) ZIP.** No decompressor is needed — only a
central-directory walk. The CRC32 in each entry gives byte-exact extraction
verification for free, which is what the 871/871 figure above is.

**Sprites ship as two GIF plates.** `Expl Small Red IA[EXSR].gif` is the
alpha plate, `Expl Small Red IC[exsr].gif` the colour plate; the four-byte code
is UPPERCASE for alpha and lowercase for colour. 125 pairs, zero dimension
mismatches. Pairing keys on the four-byte code with case folded away, not on
the human-readable name; name-based pairing leaves two false orphans because
the labels differ in whitespace.

**The IA plate is a QuickDraw mask and is inverted with respect to alpha.**
White (255) is fully *transparent*, black fully opaque, greys are partial
coverage. Getting this backwards produces sprites on a solid green field —
which is exactly what the first run produced. Verified on `EXSR`, where IA is
255 across precisely the region IC fills with its `[0,255,156]` background key.

**Sprite plates carry grid markers.** Two non-greyscale values appear in the
alpha plate, `[0,0,255]` and `[255,0,255]`, at pixels where the colour plate
holds the same value. They are sheet structure, not image content — the sprites
are horizontal strips of animation frames (`PL1B` is 394×48 with 7 banking
frames of the player ship). They are currently written as transparent.
**Decoding them into frame rectangles is Phase 3 work.**

**Interface art is 16-bit TGA.** Uncompressed type 2, 16 bpp, bottom-origin,
packed `A RRRRR GGGGG BBBBB` — the same 1555 pixel the original's blitter
(`U_Pixel16`, `W_Pixel16`) works in. stb_image, and therefore raylib, rejects
16 bpp TGA, so `data/tga.odin` decodes it. 5→8 bit expansion uses
`(c << 3) | (c >> 2)` so full-scale 31 maps to 255, not 248.

**All 99 audio files are AIFF-C / `ima4`,** 44.1 kHz, 96 mono and 3 stereo.
Apple's IMA ADPCM: 34-byte packets expanding to 64 samples per channel, stereo
packets alternating. The 2-byte packet preamble carries the predictor in the
top 9 bits and the step index in the low 7. Decoding is verified exactly:
`acbo` is 436 packets and produces 27,904 samples.

## Decisions

**WAV, not OGG.** Odin's vendored stb_vorbis and raylib both decode Vorbis;
neither encodes it. Adding an encoder to shrink 99 sound effects is not worth
the build dependency. WAV is lossless and raylib loads it directly.

**Definition records pass through byte-exact.** `unde` (386), `tefo` (54),
`leve` (12), `idli` (6), `stli` (5), `wede` (5), `plde` (2), `coli`, `flli`,
`reli` are copied rather than decoded, and catalogued in the manifest. Their
field layouts are Phase 3. The original plan listed "definitions round-trip
through JSON" under Phase 1; that was misscoped — it depends on format work
that belongs with the data layer. The manifest gives Phase 3 its index.

**`parse_res_name` allocates nothing.** All fields alias the input path, and
plate pairing uses a fixed-size `Pair_Key` value. The first version returned an
allocated pair string and Odin's test runner correctly flagged the leak.

## Known trade-offs

`assets/` is ~124 MB: 56 MB of PNG and 56 MB of WAV. PNG output goes through
stb_image_write, whose compression is weak, and ADPCM→PCM16 is a 4× expansion.
Both are fine locally and both have obvious later fixes (a real PNG encoder,
QOA or Vorbis audio) if distribution size ever matters. `assets/` is
gitignored; it is regenerated in five seconds from the PAKs.

## Verification

`mise run assets:verify` is independent of the extractor. It re-opens the
original PAKs and re-checks all 871 CRCs, parses `manifest.json`, confirms
every listed output exists and is non-empty, re-decodes every PNG and asserts
its dimensions match the manifest, and checks every WAV header against the
recorded channel count and sample rate.

## Open questions for later phases

- Frame rectangles within sprite strips: what exactly do the blue and magenta
  markers delimit? Needed before anything can be drawn.
- The extractor only walks the PAKs. `" Data/Local"` holds four more files —
  `last` (a saved replay), `TESM` (a text image), `pref` (preferences) and
  `cred` (a string list). The engine looks in `Data/Local` *before* the PAKs,
  so these are overrides; implementing that lookup order belongs with the
  resource layer in Phase 3.
- **Alpha-only plates exist.** `Text - Small IA[TESM].gif` has no `IC` partner
  in `Data/Local` or in any PAK. A mask with no colour plate is presumably
  tinted at draw time, which is how a bitmap font would work. Within the PAKs
  every plate pairs cleanly, so TESM is currently the only known case.
- `im08` is 8-bit-sourced and `im16` 16-bit, but both decode to RGBA. Whether
  the engine treats them differently at runtime is not yet established.
