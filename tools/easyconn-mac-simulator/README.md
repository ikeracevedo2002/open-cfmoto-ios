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

Once frames are available, they are written to `easyconn-capture.h264` and can
be inspected with:

```bash
ffplay -f h264 easyconn-capture.h264
```
