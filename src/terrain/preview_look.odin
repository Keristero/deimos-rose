package terrain

// Made by `mise run preview:fit` (tools/preview_fit), from the original
// previews and their maps in plugins/classic_levels: do not edit. Where
// each preview's crop was, and how well it matched:
//   le01 cap1: (4, 0) of 3600 rows, 0.985
//   le02 cap2: (4, 1288) of 3600 rows, 0.987
//   le03 isp1: (6, 2480) of 3600 rows, 0.984
//   le04 cap3: (38, 312) of 3600 rows, 0.984
//   le05 jup3: (17, 1586) of 3600 rows, 0.802, left out
//   le06 inp3: (27, 17) of 3600 rows, 0.985
//   le07 jup2: (2, 2679) of 3600 rows, 0.928, left out
//   le08 isp3: (2, 6) of 3600 rows, 0.978
//   le09 isp2: (8, 178) of 3600 rows, 0.967
//   le10 inp2: (36, 1994) of 3600 rows, 0.981
//   le11 jup1: (34, 1232) of 3600 rows, 0.979
//   le12 inp1: (40, 2680) of 3600 rows, 0.980
// The look comes within 9.40 (RMS, 0-255) of the previews it was fitted to.
PREVIEW_LOOK :: Preview_Look {
	blur = 0.35,
	colour = {
		{1.0007, -0.0048, 0.0042, 0.0000},
		{-0.0181, 1.0359, -0.0177, 0.0000},
		{-0.0285, 0.0148, 1.0137, 0.0000},
	},
	tone = {
		{15.03, 48.56, 70.81, 94.90, 118.17, 146.17, 170.23, 193.98, 219.31, 240.52, 261.78, 276.43, 282.00, 283.14, 283.11, 283.41, 294.20},
		{23.15, 49.67, 70.93, 93.50, 121.70, 144.80, 167.42, 191.25, 212.81, 238.26, 261.20, 271.17, 278.27, 279.64, 279.21, 280.55, 282.34},
		{15.67, 39.09, 57.39, 81.72, 102.94, 121.72, 141.43, 157.48, 189.37, 204.93, 214.85, 234.28, 254.27, 274.28, 294.30, 314.31, 334.33},
	},
	across = {1.0000, 0.9950, 0.9881, 0.9817, 0.9721, 0.9571, 0.9349, 0.9070, 0.8751},
	down = {1.0000, 1.0002, 0.9868, 0.9656, 0.9301, 0.8728, 0.7752, 0.6037, 0.3268},
}
