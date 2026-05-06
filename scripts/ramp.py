from dataclasses import dataclass


@dataclass(frozen=True, kw_only=True)
class Step:
    speed: int
    steps: int

    def __str__(self) -> str:
        return f".{{ .speed = {self.speed}, .steps = {self.steps} }}"


def make_ramp(start: float, end: float, rate: float) -> list[int]:
    speed = start
    speeds = []
    while speed < end:
        speeds.append(int(speed * 100))
        speed += rate / speed
    return speeds


def make_hump(
    ramp: list[int],
    *,
    steps_per_speed: int = 10,
    steps_per_reverse: int = 100,
    direction: int = 1,
) -> list[Step]:
    [peak, *rest] = reversed(ramp)
    return (
        [
            Step(speed=speed, steps=steps_per_speed * direction)
            for speed in reversed(rest)
        ]
        + [Step(speed=peak, steps=steps_per_reverse * direction)]
        + [Step(speed=speed, steps=steps_per_speed * direction) for speed in rest]
    )


ramp = make_ramp(10, 600, 1000)
hump = make_hump(ramp) + make_hump(ramp, direction=-1)

for step in hump:
    print(f"{step},")
