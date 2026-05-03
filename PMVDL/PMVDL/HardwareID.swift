import Foundation
import IOKit

enum HardwareID {
    static let current: String = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer {
            if service != 0 {
                IOObjectRelease(service)
            }
        }

        guard service != 0,
              let cfValue = IORegistryEntryCreateCFProperty(
                service,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
              ) else {
            return "unknown"
        }

        return (cfValue.takeRetainedValue() as? String) ?? "unknown"
    }()
}
