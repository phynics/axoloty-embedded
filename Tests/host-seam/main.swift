// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host entry point for the device-smoke application. The application ends by
// requesting a restart, which the host seam records and terminates cleanly, so
// this return path is only reached when the link probes fail before `runSmoke`.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

exit(startDeviceSmoke(hostSmokeSeam()))
