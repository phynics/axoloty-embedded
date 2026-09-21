// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import DeviceSmokeApplication
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct HostAgentSmokeMain {
    static func main() {
        do {
            try HostAgentConfiguration.load(from: ProcessInfo.processInfo.environment)
            exit(startDeviceSmoke(hostAgentSmokeSeam()))
        } catch {
            FileHandle.standardError.write(Data("host smoke configuration failed: \(error)\n".utf8))
            exit(64)
        }
    }
}
