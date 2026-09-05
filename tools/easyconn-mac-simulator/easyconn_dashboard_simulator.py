#!/usr/bin/env python3
"""Emulate an EasyConn motorcycle dashboard on macOS.

The simulator publishes _EasyConn._tcp, accepts the iPhone discovery probe on
10930, then connects back to the iPhone's control and media listeners.
"""

from __future__ import annotations

import argparse
import json
import select
import shutil
import socket
import struct
import subprocess
import sys
import threading
import termios
import time
import tty
from pathlib import Path
from typing import Optional


PXC_HEADER = struct.Struct("<IIII")
MEDIA_HEADER = struct.Struct("<HHI")
DISCOVERY = 0x70000010
DISCOVERY_ACK = 0x70000011


def log(message: str) -> None:
    print(time.strftime("%H:%M:%S"), message, flush=True)


def recv_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ConnectionError("connection closed")
        data.extend(chunk)
    return bytes(data)


def pxc_frame(command: int, payload: bytes = b"") -> bytes:
    total_length = PXC_HEADER.size + len(payload)
    return PXC_HEADER.pack(command, total_length, command ^ total_length, 0) + payload


def recv_pxc(connection: socket.socket) -> tuple[int, bytes]:
    command, total_length, magic, _ = PXC_HEADER.unpack(recv_exact(connection, PXC_HEADER.size))
    if total_length < PXC_HEADER.size or magic != command ^ total_length:
        raise ValueError("invalid PXC frame")
    return command, recv_exact(connection, total_length - PXC_HEADER.size)


def media_frame(command: int, payload: bytes = b"", token: int = 0) -> bytes:
    return MEDIA_HEADER.pack(command, len(payload), token) + payload


def recv_media(connection: socket.socket) -> tuple[int, int, bytes]:
    command, length, token = MEDIA_HEADER.unpack(recv_exact(connection, MEDIA_HEADER.size))
    return command, token, recv_exact(connection, length)


def connect_with_retry(phone_ip: str, port: int) -> socket.socket:
    deadline = time.monotonic() + 10
    while True:
        try:
            connection = socket.create_connection((phone_ip, port), timeout=2)
            connection.settimeout(5)
            log(f"Connected to iPhone {phone_ip}:{port}")
            return connection
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.4)


def exchange_pxc(connection: socket.socket, command: int, payload: bytes = b"") -> tuple[int, bytes]:
    connection.sendall(pxc_frame(command, payload))
    reply_command, reply_payload = recv_pxc(connection)
    log(f"PXC 0x{command:08x} -> 0x{reply_command:08x} ({len(reply_payload)} bytes)")
    return reply_command, reply_payload


def run_control(phone_ip: str, stop_event: threading.Event) -> None:
    try:
        with connect_with_retry(phone_ip, 10922) as connection:
            exchange_pxc(connection, 0x00010000)
            command, payload = exchange_pxc(connection, 0x00010010)
            if command == 0x00010011 and payload:
                client = json.loads(payload.decode("utf-8"))
                log(f"iPhone client: {client.get('phoneModel')} / {client.get('pxcVersion')}")

            serial = json.dumps({"sn": "OPENCFMOTO-MAC-SIM"}, separators=(",", ":")).encode()
            connection.sendall(pxc_frame(0x000103E0, serial))
            for _ in range(2):
                reply_command, reply_payload = recv_pxc(connection)
                log(f"PXC serial reply 0x{reply_command:08x} ({len(reply_payload)} bytes)")

            while not stop_event.wait(2):
                reply_command, _ = exchange_pxc(connection, 0x70000000)
                if reply_command != 0x70000001:
                    raise ValueError("unexpected heartbeat response")
    except (OSError, ValueError, ConnectionError, json.JSONDecodeError) as error:
        if not stop_event.is_set():
            log(f"Control channel stopped: {error}")
            stop_event.set()


def media_exchange(connection: socket.socket, command: int, payload: bytes = b"") -> bytes:
    connection.sendall(media_frame(command, payload))
    response, _, response_payload = recv_media(connection)
    expected = command + 1
    if response != expected:
        raise ValueError(f"media command {command} returned {response}, expected {expected}")
    log(f"Media {command} -> {response} ({len(response_payload)} bytes)")
    return response_payload


def send_touch(connection: socket.socket, action: int, x: int, y: int, pointer_id: int = 0) -> None:
    payload = bytearray(18)
    timestamp = int(time.monotonic() * 1000) & 0xFFFFFFFF
    struct.pack_into("<HHHHI", payload, 0, action, x, y, pointer_id, timestamp)
    connection.sendall(media_frame(32, bytes(payload)))
    names = {1: "up", 2: "down", 3: "move"}
    log(f"Touch {names.get(action, action)} -> ({x},{y})")


def capture_media(
    phone_ip: str,
    width: int,
    height: int,
    frame_count: int,
    output: Path,
    touch_demo: bool,
    stop_event: threading.Event,
) -> None:
    partial_output = output.with_name(output.name + ".part")
    received = 0
    try:
        with connect_with_retry(phone_ip, 10921) as control, connect_with_retry(phone_ip, 10920) as data:
            media_exchange(control, 48)

            configuration = bytearray(32)
            struct.pack_into("<HH", configuration, 0, width, height)
            struct.pack_into("<ii", configuration, 4, 30, 2)
            configuration[29] = 1
            media_exchange(control, 16, bytes(configuration))
            media_exchange(control, 96, b'{"width":%d,"height":%d}' % (width, height))
            media_exchange(control, 128)
            media_exchange(data, 112)

            partial_output.unlink(missing_ok=True)
            with partial_output.open("wb") as capture:
                frame_index = 0
                while not stop_event.is_set() and (frame_count <= 0 or frame_index < frame_count):
                    if touch_demo and frame_index == 4:
                        send_touch(control, 2, int(width * 0.64), int(height * 0.82))
                    elif touch_demo and 5 <= frame_index <= 9:
                        progress = (frame_index - 5) / 4
                        x = int(width * (0.64 + progress * 0.30))
                        send_touch(control, 3, x, int(height * 0.82))
                    elif touch_demo and frame_index == 10:
                        send_touch(control, 1, int(width * 0.94), int(height * 0.82))
                    data.sendall(media_frame(114))
                    try:
                        frame_size = struct.unpack("<I", recv_exact(data, 4))[0]
                        frame = recv_exact(data, frame_size)
                    except socket.timeout:
                        if not stop_event.is_set():
                            log("No H.264 frame returned; stopping media capture.")
                        break
                    if not frame.startswith((b"\x00\x00\x00\x01", b"\x00\x00\x01")):
                        raise ValueError("iPhone returned a frame that is not Annex-B H.264")
                    capture.write(frame)
                    received += 1
                    log(f"H.264 frame {received}: {len(frame)} bytes")
                    frame_index += 1

            if received:
                partial_output.replace(output)
                log(f"Saved {received} Annex-B H.264 frames to {output}")
                report_capture(output)
            else:
                partial_output.unlink(missing_ok=True)
                output.unlink(missing_ok=True)
    except KeyboardInterrupt:
        if received and partial_output.exists():
            partial_output.replace(output)
            log(f"Saved {received} Annex-B H.264 frames to {output}")
            report_capture(output)
        raise
    except (OSError, ValueError, ConnectionError) as error:
        if received and partial_output.exists():
            partial_output.replace(output)
            log(f"Saved {received} Annex-B H.264 frames after channel stop to {output}")
            report_capture(output)
        log(f"Media channel stopped: {error}")


def report_capture(output: Path) -> None:
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        return
    result = subprocess.run(
        [
            ffprobe,
            "-v", "error",
            "-f", "h264",
            "-count_frames",
            "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames",
            "-of", "default=nw=1:nk=1",
            str(output),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    count = result.stdout.strip()
    if result.returncode == 0 and count:
        log(f"ffprobe decoded {count} video frames from {output}")
    elif result.stderr.strip():
        log(f"ffprobe validation failed: {result.stderr.strip().splitlines()[-1]}")


def wait_for_stop_key(stop_event: threading.Event, stop_key: str) -> None:
    if not sys.stdin.isatty():
        log(f"Interactive stop disabled because stdin is not a TTY; use --frames N instead of --frames 0")
        return

    file_descriptor = sys.stdin.fileno()
    previous_attributes = termios.tcgetattr(file_descriptor)
    try:
        tty.setcbreak(file_descriptor)
        log(f"Press {stop_key!r} to stop and save the H.264 capture")
        while not stop_event.is_set():
            ready, _, _ = select.select([sys.stdin], [], [], 0.2)
            if ready and sys.stdin.read(1).lower() == stop_key:
                stop_event.set()
                log(f"Stop key {stop_key!r} received; flushing capture")
                return
    finally:
        termios.tcsetattr(file_descriptor, termios.TCSADRAIN, previous_attributes)


def accept_discovery(server: socket.socket) -> str:
    connection, address = server.accept()
    with connection:
        command, payload = recv_pxc(connection)
        if command != DISCOVERY:
            raise ValueError(f"unexpected discovery command 0x{command:08x}")
        log(f"Discovery from iPhone {address[0]}: {payload.decode('utf-8', errors='replace')}")
        connection.sendall(pxc_frame(DISCOVERY_ACK, b'{"status":true}'))
        return address[0]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Use a Mac as an EasyConn dashboard for OpenCFMoto iOS")
    parser.add_argument("--width", type=int, default=800)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument(
        "--frames",
        type=int,
        default=300,
        help="number of frames to request; use 0 to stream until --stop-key (default: 300)",
    )
    parser.add_argument("--output", type=Path, default=Path("easyconn-capture.h264"))
    parser.add_argument(
        "--stop-key",
        default="q",
        help="single key that ends an infinite capture and saves it (default: q)",
    )
    parser.add_argument(
        "--skip-touch-demo",
        action="store_true",
        help="do not send the automatic EasyConn drag gesture",
    )
    return parser.parse_args()


def main() -> int:
    if sys.platform != "darwin":
        log("Warning: Bonjour publishing uses macOS dns-sd; this script is intended to run on a Mac.")

    args = parse_args()
    if len(args.stop_key) != 1:
        log("--stop-key must contain exactly one character")
        return 2
    publisher: Optional[subprocess.Popen] = None
    stop_event = threading.Event()
    stop_key_thread: Optional[threading.Thread] = None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("0.0.0.0", 10930))
            server.listen(1)
            log("Listening for the iPhone EasyConn probe on :10930")

            publisher = subprocess.Popen(
                [
                    "dns-sd", "-R", "OpenCFMoto Mac TFT", "_EasyConn._tcp", "local.", "10930",
                    "packagename=com.cfmoto.cfmotointernational",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            log("Published OpenCFMoto Mac TFT as _EasyConn._tcp")
            log("On the iPhone, choose Development > Connect to Mac EasyConn simulator")

            phone_ip = accept_discovery(server)
            control_thread = threading.Thread(target=run_control, args=(phone_ip, stop_event), daemon=True)
            control_thread.start()
            stop_key_thread = threading.Thread(
                target=wait_for_stop_key,
                args=(stop_event, args.stop_key.lower()),
                daemon=True,
            )
            stop_key_thread.start()
            capture_media(
                phone_ip,
                args.width,
                args.height,
                args.frames,
                args.output,
                not args.skip_touch_demo,
                stop_event,
            )
            if not stop_event.is_set() and args.frames > 0:
                log("Capture limit reached; press Control-C to stop the simulator")
            while not stop_event.wait(1):
                pass
    except KeyboardInterrupt:
        log("Stopping simulator")
    except (OSError, ValueError, ConnectionError, FileNotFoundError) as error:
        log(f"Simulator failed: {error}")
        return 1
    finally:
        stop_event.set()
        if publisher is not None:
            publisher.terminate()
            try:
                publisher.wait(timeout=2)
            except subprocess.TimeoutExpired:
                publisher.kill()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
