// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// esptool invocations shared by the device runners. Each takes the esptool.py
// path explicitly; the runner resolves it from the ESP-IDF environment.

import path from "node:path";
import { execFileSync } from "node:child_process";

// Flashes the image a profile build left in <proofRoot>/build and leaves the
// chip in its bootloader, so capture can start before the firmware runs.
export function flashFirmware(esptool, device, proofRoot) {
  execFileSync("python3", [
    esptool, "--chip", "esp32c6", "--port", device,
    "--before", "default_reset", "--after", "no_reset", "write_flash", "@flash_args",
  ], { cwd: path.join(proofRoot, "build"), stdio: "inherit" });
}

// Starts the flashed firmware.
export function runFirmware(esptool, device) {
  execFileSync("python3", [esptool, "--chip", "esp32c6", "--port", device, "run"], { stdio: "inherit" });
}
