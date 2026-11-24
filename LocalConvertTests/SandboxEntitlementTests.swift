import Darwin
import Foundation
import Security
import Testing

/// These tests run inside the signed, sandboxed host app and read the entitlements the kernel
/// actually enforces (via `SecTask`), not just the source plist.
@Suite("Sandbox & privacy")
struct SandboxEntitlementTests {
    private func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    @Test func appSandboxIsEnabled() {
        #expect(entitlement("com.apple.security.app-sandbox") as? Bool == true)
    }

    @Test func outgoingNetworkIsNotEntitled() {
        #expect(entitlement("com.apple.security.network.client") as? Bool != true)
    }

    @Test func incomingNetworkIsNotEntitled() {
        #expect(entitlement("com.apple.security.network.server") as? Bool != true)
    }

    @Test func onlyUserSelectedFilesAreWritable() {
        #expect(entitlement("com.apple.security.files.user-selected.read-write") as? Bool == true)
        for key in [
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.all",
            "com.apple.security.temporary-exception.files.absolute-path.read-write",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write",
            "com.apple.security.temporary-exception.mach-lookup.global-name",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
        ] {
            #expect(entitlement(key) as? Bool != true, "unexpected entitlement \(key)")
        }
    }

    @Test func processRunsInsideSandboxContainer() {
        #expect(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
    }

    /// Empirical check: the kernel must refuse an outbound TCP connection, even to loopback.
    /// Without the sandbox this would fail with ECONNREFUSED instead of EPERM.
    @Test func outboundSocketIsDeniedByKernel() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            #expect(errno == EPERM || errno == EACCES)
            return
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let error = errno
        #expect(result == -1)
        #expect(error == EPERM || error == EACCES, "connect() failed with errno \(error); expected a sandbox denial")
    }
}
