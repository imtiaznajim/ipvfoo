import os.log
import SafariServices

/// Handles native messaging between Safari extension and native Swift code.
/// Primary use case: DNS resolution for IPv4/IPv6 address lookup.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let request = context.inputItems.first as? NSExtensionItem else {
            os_log(.error, "[Extension] No input item")
            return
        }

        // Extract message from request (API key differs by OS version)
        let message = extractMessage(from: request)

        // Process message asynchronously
        Task {
            let responseMessage = await handleMessage(message)
            sendResponse(responseMessage, to: context)
        }
    }
    
    /// Extract message from extension item using version-appropriate API.
    private func extractMessage(from request: NSExtensionItem) -> Any? {
        if #available(iOS 15.0, macOS 11.0, *) {
            return request.userInfo?[SFExtensionMessageKey]
        } else {
            return request.userInfo?["message"]
        }
    }
    
    /// Route message to appropriate handler based on command.
    private func handleMessage(_ message: Any?) async -> [String: Any] {
        guard let messageDict = message as? [String: Any],
              let command = messageDict["cmd"] as? String else {
            return ["echo": message ?? ""]
        }
        
        switch command {
        case "lookup":
            return await handleDNSLookup(messageDict)
        default:
            return ["echo": message ?? ""]
        }
    }
    
    /// Perform DNS resolution for domain.
    private func handleDNSLookup(_ messageDict: [String: Any]) async -> [String: Any] {
        guard let domain = messageDict["domain"] as? String else {
            return ["error": "Missing domain parameter"]
        }
        
        // Resolve DNS using port 443 (HTTPS)
        let resolvedAddress = await DNSResolver.resolve(domain: domain, port: 443) { message in
            os_log(.debug, "[DNS] %{public}@", message)
        }
        
        guard let resolvedAddress = resolvedAddress, !resolvedAddress.isEmpty else {
            os_log(.error, "[DNS] Resolution failed for domain=%{public}@", domain)
            return ["error": "DNS lookup failed"]
        }
        
        os_log(.info, "[DNS] Resolved domain=%{public}@ to address=%{public}@", domain, resolvedAddress)
        return ["resolvedAddress": resolvedAddress]
    }
    
    /// Send response back to extension context.
    private func sendResponse(_ responseMessage: [String: Any], to context: NSExtensionContext) {
        let response = NSExtensionItem()
        
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [SFExtensionMessageKey: responseMessage]
        } else {
            response.userInfo = ["message": responseMessage]
        }
        
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
