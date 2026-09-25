// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// ESP-IDF entry point for the ESP32-C6 device smoke image.
//
// The SDK starts `app_main`. This platform builds its seam and hands control
// to the application, so no application source names the SDK entry point.

/// ESP-IDF application entry point.
@c @implementation public func app_main() {
    _ = startDeviceSmoke(esp32c6SmokeSeam())
}
