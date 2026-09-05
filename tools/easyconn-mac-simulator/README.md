# Mac EasyConn dashboard simulator

This tool makes a Mac behave like the EasyConn guest/dashboard while the
iPhone runs OpenCFMoto as the host. It exercises the real LAN transport; it is
not the in-process mock.

## Run it

1. Put the Mac and iPhone on the same Wi-Fi network.
2. From the repository root on the Mac, run:

   ```bash
   python3 tools/easyconn-mac-simulator/easyconn_dashboard_simulator.py
   ```

3. If macOS asks, allow incoming network connections for Python.
4. Open the Debug build on the iPhone and select **Development → Connect to Mac
   EasyConn simulator**.

No motorcycle QR or hotspot is needed. The simulator publishes
`_EasyConn._tcp` on port `10930`, answers the PXC discovery probe, and connects
back to the iPhone on ports `10920`, `10921`, and `10922`.

The test validates Bonjour discovery, PXC framing, client info, serial
validation, heartbeat, media negotiation, and H.264 delivery. OpenCFMoto
renders an app-owned animated navigation test surface, encodes it through
VideoToolbox, and returns Annex-B access units for media command `114`.
During capture, the Mac also sends an automatic DOWN/MOVE/UP drag using media
command `32`. The projected touch marker moves across the action bar and the
selected action changes, proving the reverse input channel. Pass
`--skip-touch-demo` to disable it.

Once frames are available, they are written to `easyconn-capture.h264` and can
be inspected with:

```bash
ffplay -f h264 -framerate 30 easyconn-capture.h264
```

When `ffmpeg` is installed, the simulator also creates
`easyconn-capture.mp4`. The MP4 wrapper adds 30 FPS timestamps, so Finder,
QuickTime and VLC show the real duration instead of `0 s`. The raw `.h264`
file is kept for protocol diagnostics.

The default capture is 300 frames. For a longer session, use `--frames 0` and
press `q` in the simulator terminal to stop. The simulator flushes the partial
file, renames it to `easyconn-capture.h264`, and runs `ffprobe` when available
to report how many frames decode successfully. You can choose another stop key
with `--stop-key x`.
