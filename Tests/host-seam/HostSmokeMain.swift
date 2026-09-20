// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host entry point for the device-smoke application. The application ends by
// requesting a restart, which the host seam records and terminates cleanly, so
// this return path is only reached when the link probes fail before `runSmoke`.
//
// `@main` keeps the entry point out of a file named `main.swift`, which the
// repository's copied-source rule treats as a portable-Core filename.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct HostSmokeMain {
    static func main() {
        exit(startDeviceSmoke(hostSmokeSeam()))
    }
}
