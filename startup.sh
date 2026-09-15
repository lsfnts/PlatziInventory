#!/bin/sh
# This file is executed when starting Ly (before the TTY is taken control of)
# Custom startup code can be placed in this file or the start_cmd var can be pointed to a different file
#
# NOTE: this file must be executable (chmod +x). ly runs start_cmd directly, so a
# non-executable startup.sh is skipped silently and the animation comes up in the
# stock ANSI palette.


# Reprogram the console's 16 hardware palette entries to the colors the login
# animation was built against.
#
# animation.dur is colorFormat "16" and config.ini sets full_color = false, so
# DurFile.zig renders it through tb_color_16 -- a direct index into whatever 16
# colors this VT's palette holds, with no RGB anywhere in the path. If this
# script does not run, the animation still draws perfectly but every index lands
# on the stock ANSI palette: the teal ground comes out electric blue, petals come
# out cyan and magenta. That is the failure mode to look for.
#
# Slot 0 is every cell's background (the .dur stores bg = 0 for all of them), so
# it covers most of the screen and is deliberately a dark neutral. Slots 1-15 are
# 15 colors clustered out of correct.png on the animation's own 160x42 character
# grid, sorted darkest -> lightest, and carry the picture as the 0/1 glyph
# colors.
#
# Three things shape these values, and all three matter:
#   - They are lifted well above their literal samples, because a glyph inks only
#     about a fifth of its cell and would otherwise average out almost black.
#   - The clustering runs in CIELAB on the *already lifted* colors, not on raw
#     samples, so the clusters are separated in the space the screen actually
#     shows. Lifting centroids afterwards instead compresses the bright end and
#     collapses distinct clusters back together.
#   - Dense regions are down-weighted. The teal ground is the largest area in the
#     painting, and unweighted clustering spends several slots splitting it into
#     shades nobody can distinguish while the flowers share what is left.
# No two slots here are closer than dE 9.9; every pair is comfortably telling-apart
# distance. Regenerate these together with the .dur file -- the indices inside it
# are meaningless against a different palette, and re-running the generator on a
# different character grid shifts the clusters.
BACKGROUND="1b1d1a"   # 0   dark neutral ground (also ly's default bg)
MOSS="828779"         # 1   \
LEAF="7c9574"         # 2    |
OLIVE="929f70"        # 3    |
ROSE_DEEP="d287a2"    # 4    |
CLAY="bb9795"         # 5    |
TEAL_DIM="9db2ae"     # 6    |
SAGE="a5b29b"         # 7    |  15 colors sampled from correct.png,
TAN="beb489"          # 8    |  ordered darkest -> lightest
ROSE="e6b0c0"         # 9    |
PEARL="cdc6c9"        # 10   |
TEAL="b3ceca"         # 11   |
LILAC="e3c4e2"        # 12   |
PEACH="fdc6b3"        # 13   |
BLUSH="f3d5e0"        # 14  /
CREAM="ffdfd2"        # 15  lightest -- also ly's bold-white UI text

COLORS="${BACKGROUND} ${MOSS} ${LEAF} ${OLIVE} ${ROSE_DEEP} ${CLAY} ${TEAL_DIM} ${SAGE} ${TAN} ${ROSE} ${PEARL} ${TEAL} ${LILAC} ${PEACH} ${BLUSH} ${CREAM}"

set_palette() {
	i=0
	while [ $i -lt 16 ]; do
		printf "\033]P%x%s" ${i} "$(echo "$COLORS" | cut -d ' ' -f$(( i + 1)))"

		i=$(( i + 1 ))
	done

	# Raw erase rather than `clear`: this runs before ly takes the TTY, where
	# TERM may be unset and terminfo therefore unavailable. Fixes the background
	# artifacting left behind by changing the palette.
	printf "\033[H\033[2J"
}

# Apply to both the VT ly is about to take and our own stdout, because which one
# is the console depends on how ly was started. Setting the palette twice is
# harmless; setting it nowhere leaves the stock ANSI colors up.
[ -w /dev/tty2 ] && set_palette > /dev/tty2
[ -t 1 ] && set_palette

exit 0
