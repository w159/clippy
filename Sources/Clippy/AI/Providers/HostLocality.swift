import Foundation
import Darwin

/// Decides whether a URL provably stays on this Mac. Deliberately narrow: private
/// LAN addresses, `.local` names and tailnet names are other machines.
enum HostLocality {
    static func isVerifiedLoopback(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            // inet_pton accepts only strict dotted-quad, so "127.1" and hex forms fail.
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { raw in
                raw.prefix(15).allSatisfy { $0 == 0 } && raw[15] == 1
            }
        }
        return false
    }
}
