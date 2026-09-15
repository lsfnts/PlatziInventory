#!/bin/sh
# This file is executed when starting Ly (before the TTY is taken control of)
# Custom startup code can be placed in this file or the start_cmd var can be pointed to a different file


# Reprogram the console's 16 hardware palette entries to the colors the login
# animation was built against.
#
# Why this is needed: animation.dur is colorFormat "16", and config.ini sets
# full_color = false, so DurFile.zig renders it through tb_color_16 -- a direct
# lookup into whatever 16 colors this VT's palette currently holds, with no RGB
# anywhere in the path. Left at the console default that lookup lands on stock
# ANSI red/green/blue. These values are what the .dur cell indices actually mean.
#
# Slots 0-7 are 8 colors k-means'd out of the artwork and sorted darkest ->
# lightest; every cell's *background* is one of them, which is what paints the
# picture. Slots 8-15 are the same 8 blended 45% toward white and are used as
# each cell's *foreground*, so the 0/1 glyphs read as texture over their own
# color. The split is forced, not stylistic: the Linux console reaches slots
# 8-15 only via bold, and bold brightens the foreground only -- a background can
# never be brighter than slot 7.
#
# Regenerate these together with the .dur file; the indices inside it are
# meaningless against a different palette.
if [ "$TERM" = "linux" ] || [ -w /dev/tty2 ]; then
	BG_DARKEST="343c2e"      # 0  deep leaf green
	BG_DARK="514f42"         # 1  shadowed foliage
	BG_MID_WARM="676660"     # 2  olive gray
	BG_MID="797e7c"          # 3  neutral gray
	BG_TEAL="829895"         # 4  the painting's teal ground
	BG_MAUVE="b18b90"        # 5  deep petal rose
	BG_PINK="cdabae"         # 6  mid petal pink
	BG_LIGHTEST="e9cbc6"     # 7  petal cream (also ly's "white" UI text)

	FG_DARKEST="8f948c"      # 8  slots 0-7, each blended 45% toward white
	FG_DARK="9f9e97"         # 9
	FG_MID_WARM="acaba7"     # 10
	FG_MID="b5b8b7"          # 11
	FG_TEAL="bac6c5"         # 12
	FG_MAUVE="d4bfc2"        # 13
	FG_PINK="e4d1d2"         # 14
	FG_LIGHTEST="f3e2e0"     # 15

	COLORS="${BG_DARKEST} ${BG_DARK} ${BG_MID_WARM} ${BG_MID} ${BG_TEAL} ${BG_MAUVE} ${BG_PINK} ${BG_LIGHTEST} ${FG_DARKEST} ${FG_DARK} ${FG_MID_WARM} ${FG_MID} ${FG_TEAL} ${FG_MAUVE} ${FG_PINK} ${FG_LIGHTEST}"

	set_palette() {
		i=0
		while [ $i -lt 16 ]; do
			printf "\033]P%x%s" ${i} "$(echo "$COLORS" | cut -d ' ' -f$(( i + 1)))"

			i=$(( i + 1 ))
		done

		clear # for fixing background artifacting after changing color
	}

	# ly's start_cmd runs before it takes the TTY, so stdout is already the
	# console when TERM says so; otherwise address ly@tty2's VT directly.
	if [ "$TERM" = "linux" ]; then
		set_palette
	else
		set_palette > /dev/tty2
	fi
fi
