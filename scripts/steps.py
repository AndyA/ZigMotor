#!/usr/bin/env python

speed = 60
total = 0
steps = 600
for i in range(10):
  if speed > 600:
    break
  print(f".{{ .speed = {speed}, .steps = {steps} }},")
  total += steps
  speed *= 1.414

print(f".{{ .speed = {60}, .steps = {-total} }},")

# vim:ts=2:sw=2:sts=2:et:ft=python

