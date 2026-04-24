from dataclasses import dataclass


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


STEPS_PER_REVOLUTION = 3200

print("RPM,usPS")
for rpm in range(10, 1000):
    sps = rpm / 60 * STEPS_PER_REVOLUTION
    usps = 1_000_000 / sps
    print(f"{rpm:d},{usps:.3f}")
