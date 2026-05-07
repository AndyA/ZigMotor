def foo(rpm: float, rate: float) -> float:
    return (rpm * rpm - 2 * rate) / (2 * rpm)


rpm = 20
rate = 5000
while rpm < 50:
    print(f"{rpm}, {foo(rpm, rate)}")
    rpm += rate / (rpm * rpm)
