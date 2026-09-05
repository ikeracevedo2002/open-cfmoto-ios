# Native iOS port

Android remains on `main`. The independent native implementation lives on `ios-native` under
`ios/` and does not change the Gradle application.

## Current milestone

The branch contains an iOS 17+ SwiftUI application that can:

- scan Carbit/EasyConnect, CARBIT token, Moto Morini and Thinkerride pairing QR formats;
- guide the rider through manually joining the dashboard SoftAP, which works with a free Personal Team;
- request local-network access and discover `_EasyConn._tcp` with Network.framework;
- listen for dashboard callbacks on TCP ports 10920, 10921 and 10922;
- encode/decode the 16-byte little-endian PXC control frame;
- answer channel selection, heartbeat, speed, serial, time and media negotiation requests;
- encode an app-owned animated projection surface as Baseline H.264 with VideoToolbox and serve
  Annex-B access units when the dashboard sends media command 114;
- show a live diagnostic log on the phone.

This is a transport/video milestone, not a production release. Touch/button input, a real navigation
surface, validated HUID authentication, Yunmo transport, trips/maps and recovery still need to be
ported and tested on real CFMoto hardware.

## Build

1. Open `ios/OpenCFMoto.xcodeproj` in Xcode 26 or newer.
2. Select your Apple development team for the `OpenCFMoto` target.
3. Use an actual iPhone. The simulator cannot join the motorcycle Wi-Fi network or scan its QR.
4. Build and run, tap **Scan bike QR**, and accept the Camera and Local Network prompts.
5. Open iOS Settings → Wi-Fi, join the SSID displayed by OpenCFMoto, return to the app and tap
   **I joined the bike Wi-Fi**.

The project deliberately does not enable Hotspot Configuration because Apple does not allow that
capability for free Personal Team provisioning profiles. A paid Apple Developer team can add it later
to automate SoftAP joining. No CarPlay entitlement is included: Apple must approve the appropriate
CarPlay application category before an App Store build can expose a CarPlay scene. The EasyConn link
can be developed and tested independently from that entitlement.

## Porting roadmap

1. Capture a successful control/media negotiation from an iPhone and compare it with Android logs.
2. Implement the RSA/HUID exchange with Security.framework after validating the expected iOS wire format.
3. Replace the animated H.264 test surface with the app's navigation compositor.
4. Translate dashboard touch and handlebar messages into the iOS navigation UI.
5. Port bike profiles, reconnect policy, GPX/trip storage, MapLibre and offline routing.
6. Request Apple's navigation/CarPlay entitlement and add the approved CarPlay scene.

## iOS platform boundaries

- iOS apps cannot start or control Apple's system CarPlay session as Android code starts Android Auto.
- Personal Hotspot cannot be configured programmatically with a public API, so QR profiles where the
  dashboard joins a phone-hosted hotspot require manual setup or a different supported transport.
- General screen mirroring of other apps is not an App Store-safe replacement for CarPlay. The native
  port should project its own navigation surface or use Apple's approved CarPlay templates.
