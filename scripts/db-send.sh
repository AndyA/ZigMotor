#!/bin/bash

set -ex

FW="$1"

openocd \
  -f etc/cmis-dap.cfg \
  -f etc/rp2040.cfg \
  -c "adapter speed 5000" \
  -c "program $FW reset exit"

# vim:ts=2:sw=2:sts=2:et:ft=sh

