```sh
openocd \
  -f etc/cmis-dap.cfg \
  -f etc/rp2040.cfg \
  -c "adapter speed 5000" \
  -c "program zig-out/firmware/swoopy.uf2 reset exit"
```
