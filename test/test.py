import random
import colorsys

DELTA_PERCENT = 10
NUM_COLOURS = 20

def gen_col():
    """Generate a random RGB colour."""
    return tuple(random.randrange(256) for _ in range(3))

def col_dif(c0, c1):
    """Calculate the percentage difference between two colours."""
    return sum(abs(a - b) for a, b in zip(c0, c1)) / (3 * 255) * 100

def is_col_in_set(col, s):
    """Check whether a similar colour already exists."""
    return any(col_dif(col, c) < DELTA_PERCENT for c in s)

colours = set()

while len(colours) < NUM_COLOURS:
    col = gen_col()
    if not is_col_in_set(col, colours):
        colours.add(col)


for r, g, b in sorted(
    colours,
    key=lambda c: colorsys.rgb_to_hsv(*(v / 255 for v in c))
):
    hexcode = f"#{r:02X}{g:02X}{b:02X}"
    print(f"\033[48;2;{r};{g};{b}m          \033[0m {hexcode}")


_ = """
#FA674E
#E9A05A
#8D9776
#689031
#2E7507
#0CEF38
#36FCB6
#0BD6D5
#1B3B43
#6B6B78
#4429E1
#7C3EFA
#59256D
#DFACE7
#A228AF
#F748FC
#C41D5F
"""
