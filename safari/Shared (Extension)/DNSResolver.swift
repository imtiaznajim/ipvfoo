import Darwin
import Foundation
import Network

/// Wrapper for CheckedContinuation that prevents multiple resume calls.
/// Swift continuations crash if resumed more than once - this guards against races
/// between timeout, success, and failure paths (similar to Promise.resolve() in JS).
private class OnceContinuation<T> {
    private var resumed = false
    private let continuation: CheckedContinuation<T, Never>
    
    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }
    
    /// Resume continuation with value, ignoring subsequent calls.
    func resume(returning value: T) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

class DNSResolver {
    static func resolve(
        domain: String,
        port: UInt16,
        logger: ((String) -> Void)? = nil
    ) async -> String? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logger?("[DNS] Resolution invalid port=\(port)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let onceContinuation = OnceContinuation(continuation)
            
            // Create UDP connection to trigger DNS resolution without needing handshake
            let connection = NWConnection(
                host: NWEndpoint.Host(domain),
                port: nwPort,
                using: .udp
            )

            // Cleanup and complete the async operation
            @Sendable func finish(_ value: String?) {
                // Clear handler before cancelling to prevent re-entry
                connection.stateUpdateHandler = nil
                connection.cancel()
                onceContinuation.resume(returning: value)
            }

            // Monitor connection state to extract resolved IP
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Connection prepared - extract resolved IP from endpoint
                    if let resolvedIP = extractIPAddress(from: connection) {
                        logger?("[DNS] Resolved domain=\(domain) to ip=\(resolvedIP)")
                        finish(resolvedIP)
                    }
                case let .failed(error):
                    logger?("[DNS] Resolution failed domain=\(domain) error=\(error.localizedDescription)")
                default:
                    // Ignore cancelled/preparing states - either we initiated it or it's transient
                    break
                }
            }

            connection.start(queue: .global())
            
            // Timeout after 5 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                finish(nil)
            }
        }
    }
    
    /// Extract IP address from connection's remote endpoint.
    /// Returns string representation of resolved IPv4 or IPv6 address.
    private static func extractIPAddress(from connection: NWConnection) -> String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, _) = endpoint else {
            return nil
        }
        
        // Convert NWEndpoint.Host to string representation
        switch host {
        case let .ipv4(addr):
            return addr.debugDescription
        case let .ipv6(addr):
            return addr.debugDescription
        default:
            return nil
        }
    }
}
