from dataclasses import dataclass


@dataclass(kw_only=True)
class PidController:
    Kp: float
    Ki: float
    Kd: float
    set_point: float = 0
    prev_err: float = 0
    integral: float = 0

    def update(self, current: float) -> float:
        err = self.set_point - current
        self.integral += err
        output = (
            (self.Kp * err)
            + (self.Ki * self.integral)
            + (self.Kd * (err - self.prev_err))
        )
        self.prev_err = err
        return output


pid = PidController(Kp=0.2, Ki=0.000001, Kd=0.2, set_point=2000)

current = 0
for _ in range(200):
    output = pid.update(current)
    print(f"Current: {current:.2f}, Output: {output:.2f}")
    current += output
