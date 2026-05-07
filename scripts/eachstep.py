def foo(rpm: float, rate: float) -> float:
    return (rpm**3 - 2 * rate) / (2 * rpm)


rpm = 20
rate = 5000
while rpm < 100:
    print(f"{rpm}, {foo(rpm, rate)}")
    rpm += rate / (rpm * rpm)
