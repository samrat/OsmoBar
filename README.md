# Osmo Control (macOS)

Native SwiftUI macOS menu bar app + floating Studio Control Window for controlling a **DJI Osmo Pocket 3** while using it in **Webcam (UVC)** mode.

## Architecture & Transports

Inspired by [`datagutt/node-osmo`](https://github.com/datagutt/node-osmo) and Pocket 3 DUML reverse-engineering research, **Osmo Control** unifies three transports so every control works seamlessly alongside FaceTime, Zoom, Google Meet, or OBS:

1. **USB UVC Control Plane (`IOKit` pipe 0)**
   - Works concurrently while another app streams video from the Pocket 3 webcam.
   - Automatically parses the camera's UVC VideoControl descriptor and exposes hardware Pan/Tilt, Zoom (1×–4×), Exposure, White Balance, Brightness, Contrast, Saturation, Sharpness, Gain, and Focus controls whenever the camera firmware exposes them.
2. **Bluetooth LE DUML (`CoreBluetooth` — service `FFF0`, `FFF4` notify / `FFF5` write)**
   - Scans for Osmo Pocket 3 (by name or DJI manufacturer ID `0x08AA` / `0xF7AA`, model `0x0020`).
   - Handles pairing (`[0x01, 0x00]` arm on `FFF4`, `00/2B` wake, `07/45` PIN handshake, `07/46` approval, 1 Hz keepalive).
   - Streams live **Battery % + Charging state** (`0D/02`) and **Gimbal Pitch/Roll/Yaw telemetry** (`04/05`), plus can wake the Pocket 3 Wi-Fi AP (`53/10`) and query credentials (`07/07`, `07/0E`).
3. **Optional Direct Pocket 3 Wi-Fi Datalink (`192.168.2.1:9004` DUML-over-UDP)**
   - DJI Pocket 3 firmware restricts some Pro settings (manual ISO, Shutter, EV, Kelvin WB, Color Profile, Flip/Lock) and raw gimbal motor commands over BLE-only.
   - Connecting the optional UDP/9004 datalink unlocks full 20 Hz virtual joystick steering (`04/01`), closed-loop smooth angle presets, Recenter (`04/4C FE08`), Selfie/Forward Flip (`04/4C FE09`), Gimbal Lock/Follow, and all `02/*` Pro camera controls + `00/99` readback.

## Features

- **Menu Bar Popover**: Compact gimbal steering pad, Recenter, Flip, Lock/Follow, saved angle presets, quick zoom (`1×`–`4×`), EV/Brightness, White Balance, and live battery indicator.
- **Pop-out Studio Window**: Floating-capable ("Always on Top" pin), optional toggleable live framing preview (`AVCaptureVideoPreviewLayer`), full Gimbal & Presets panel, arrow-key nudging, full Image & Exposure panel, and live Transport/Protocol Diagnostics.

## Build & Run

```bash
# Run unit tests (CRC8/CRC16, DUML framing, Pocket 3 command vectors, UVC descriptor & PTZ)
swift test

# Build and package OsmoControl.app
chmod +x scripts/build-app.sh
./scripts/build-app.sh

# Launch the app
open build/OsmoControl.app
```
