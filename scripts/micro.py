SIGNALS = (3, 4, 1, 2)
MICRO = (
    (1, (0, 0, 0, 0)),
    (32, (0, 0, 0, 1)),
    (128, (0, 0, 1, 0)),
    (256, (0, 0, 1, 1)),
    (1, (0, 1, 0, 0)),
    (4, (0, 1, 0, 1)),
    (256, (0, 1, 1, 0)),
    (64, (0, 1, 1, 1)),
    (1, (1, 0, 0, 0)),
    (256, (1, 0, 0, 1)),
    (2, (1, 0, 1, 0)),
    (8, (1, 0, 1, 1)),
    (1, (1, 1, 0, 0)),
    (64, (1, 1, 0, 1)),
    (8, (1, 1, 1, 0)),
    (16, (1, 1, 1, 1)),
)

step_codes: dict[int, list[int]] = {}

for step, bits in sorted(MICRO):
    mask = 0
    for bit, signal in zip(bits, SIGNALS):
        if bit:
            mask |= 1 << (signal - 1)
    # print(f"{step} => 0b{mask:04b},")
    step_codes.setdefault(step, []).append(mask)

for step in sorted(step_codes):
    [best, *rest] = step_codes[step]
    print(f"{step} => 0b{best:04b},", end="")
    if rest:
        print(f"  // also {', '.join(f'0b{mask:04b}' for mask in rest)}", end="")
    print()
