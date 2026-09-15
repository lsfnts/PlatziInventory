#!/bin/sh
# This file is executed when starting Ly (before the TTY is taken control of)
# Custom startup code can be placed in this file or the start_cmd var can be pointed to a different file


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
# 15 colors k-means'd out of the artwork, sorted darkest -> lightest, and carry
# the picture as the 0/1 glyph colors. They are lifted well above their literal
# values because a glyph inks only about a fifth of its cell and would otherwise
# average out almost black against slot 0.
#
# Regenerate these together with the .dur file; the indices inside it are
# meaningless against a different palette.
BACKGROUND="181917"   # 0   dark neutral ground (also ly's default bg)
ROSE_DEEP="b95779"    # 1   \
LEAF="768a69"         # 2    |
OLIVE="939b65"        # 3    |
SAGE="95a58a"         # 4    |
MAUVE="d194a8"        # 5    |
TEAL_DIM="9cafac"     # 6    |
TAN="bab27e"          # 7    |  15 colors sampled from correct.png,
TEAL="a9bdb9"         # 8    |  ordered darkest -> lightest
PEACH="e9ac90"        # 9    |
LILAC="dcb6cf"        # 10   |
TEAL_PALE="adc9c6"    # 11   |
AQUA="b0d0cc"         # 12   |
PEARL="d1cbce"        # 13   |
CREAM="f4cbb8"        # 14  /
BLUSH="f0d6df"        # 15  lightest -- also ly's bold-white UI text

COLORS="${BACKGROUND} ${ROSE_DEEP} ${LEAF} ${OLIVE} ${SAGE} ${MAUVE} ${TEAL_DIM} ${TAN} ${TEAL} ${PEACH} ${LILAC} ${TEAL_PALE} ${AQUA} ${PEARL} ${CREAM} ${BLUSH}"

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
# harmless; setting it nowhere is the bug that leaves the stock ANSI colors up.
# Note there is deliberately no `[ "$TERM" = linux ]` guard here -- systemd does
# not always export TERM to the unit, and that guard silently skips everything.
[ -w /dev/tty2 ] && set_palette > /dev/tty2
[ -t 1 ] && set_palette

exit 0
