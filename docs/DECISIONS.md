
150. The unscannable notice gives its rows room, because Vietnamese and Chinese fuse them otherwise. The
QA screen-layout check compares how many rows a fixed screen draws in each language, and it caught the
unscannable banner drawing three rows in English, two in Chinese and one in Vietnamese — the render itself
showed every line present, so the structure was intact and the rows were too close: the banner stacked the
headline and the reason lines at a spacing of 1 and 2 points, and the Vietnamese script carries marks above
and below the letters (fixing "quét được" hangs a comma below the line, "đường" reaches above it), which
bridges two lines that sit that close, in the pixels the check reads and for the eye. The stacks now use 5
and 6 points, the three languages draw the same three rows, and the banner no longer relies on the accent
height of one script to separate its rows. The check that caught it is unchanged.
