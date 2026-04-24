from dataclasses import dataclass
from math import sqrt


@dataclass(kw_only=True)
class Plan:
    decay: float = 0.0
    attack: float = 0.0
    sustain: float = 0.0
    release: float = 0.0


@dataclass(kw_only=True)
class Controller:
    current_step: int = 0
    current_rpm: float = 0.0


STEPS_PER_REVOLUTION = 200 * 4
MAX_RPM = 500.0
MAX_ACCEL = 200.0  # rpm/s

step = 0
print("step,rpm,µs/step")
while True:
    # u2 = v2 + 2 * a * s
    s = step / STEPS_PER_REVOLUTION
    rps = sqrt(2 * MAX_ACCEL * s)  # rps
    rpm = rps * 60.0
    if rpm > MAX_RPM:
        break
    usps = 0 if rpm == 0 else 1_000_000 / (rpm * STEPS_PER_REVOLUTION)
    print(f"{step},{rpm:.10f},{usps:.10f}")
    step += 1
