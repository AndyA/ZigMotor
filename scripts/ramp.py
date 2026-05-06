import math
from dataclasses import dataclass
from functools import cached_property


@dataclass(frozen=True, kw_only=True)
class Step:
    speed: float
    steps: int

    def __str__(self) -> str:
        return (
            f".{{ .speed = {int(self.norm.speed * 100)}, .steps = {self.norm.steps} }}"
        )

    @cached_property
    def norm(self) -> "Step":
        abs_steps = max(1, self.steps, -self.steps)
        return Step(
            speed=abs(self.speed),
            steps=int(
                math.copysign(1, self.speed) * math.copysign(1, self.steps) * abs_steps
            ),
        )

    @property
    def reversed(self) -> "Step":
        return Step(speed=self.speed, steps=-self.steps)

    @classmethod
    def for_time(cls, speed: float, time: float) -> "Step":
        return cls(speed=speed, steps=int(speed * time))


def make_ramp(start: float, end: float, rate: float) -> list[float]:
    speed = start
    speeds = []
    while speed < end:
        speeds.append(speed)
        speed += rate / speed
    return speeds


def make_hump(
    ramp: list[float],
    *,
    direction: int = 1,
    step_time: float = 0.002,
    hang_time: float = 10,
) -> list[Step]:
    [peak, *rest] = reversed(ramp)
    return (
        [
            Step.for_time(speed=speed * direction, time=step_time)
            for speed in reversed(rest)
        ]
        + [Step.for_time(speed=peak * direction, time=hang_time)]
        + [Step.for_time(speed=speed * direction, time=step_time) for speed in rest]
    )


def reverse_hump(hump: list[Step]) -> list[Step]:
    return [step.reversed for step in reversed(hump)]


ramp = make_ramp(10, 1000, 250)
hump = make_hump(ramp, step_time=0.25, hang_time=10)

for step in hump + reverse_hump(hump):
    print(f"{step},")
