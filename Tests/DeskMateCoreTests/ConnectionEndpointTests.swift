import Foundation
import Testing

@testable import DeskMateCore

@Suite struct ConnectionEndpointTests {
    @Test func httpsIsAccepted() throws {
        let endpoint = try ConnectionEndpoint.validate("https://tools.example.com/mcp").get()
        #expect(!endpoint.isLoopbackDevelopment)
        #expect(endpoint.displayHost == "tools.example.com")
    }

    @Test func httpIsAcceptedOnlyForExplicitLoopback() throws {
        for address in ["http://127.0.0.1:8765/mcp", "http://localhost:8765/mcp", "http://[::1]:8765/mcp"] {
            let endpoint = try ConnectionEndpoint.validate(address).get()
            #expect(endpoint.isLoopbackDevelopment, "\(address) should be marked as local development")
        }
        #expect(try ConnectionEndpoint.validate("http://127.0.0.1:8765/mcp").get().displayHost == "127.0.0.1:8765")
    }

    @Test func httpToOtherHostsIsRejected() {
        for address in [
            "http://example.com/mcp",
            "http://127.0.0.1.evil.example/mcp",
            "http://192.168.1.20/mcp",
            "http://0.0.0.0/mcp",
            "http://localhost.evil.example/mcp",
        ] {
            #expect(ConnectionEndpoint.validate(address) == .failure(.insecureRemoteHTTP), "\(address)")
        }
    }

    @Test func otherSchemesAndOddInputAreRejected() {
        #expect(ConnectionEndpoint.validate("ftp://example.com/mcp") == .failure(.unsupportedScheme("ftp")))
        #expect(ConnectionEndpoint.validate("file:///etc/passwd") == .failure(.unsupportedScheme("file")))
        #expect(ConnectionEndpoint.validate("ws://127.0.0.1/mcp") == .failure(.unsupportedScheme("ws")))
        #expect(ConnectionEndpoint.validate("") == .failure(.empty))
        #expect(ConnectionEndpoint.validate("   ") == .failure(.empty))
        #expect(ConnectionEndpoint.validate("example.com/mcp") != .success(try! ConnectionEndpoint.validate("https://example.com/mcp").get()))
        #expect(ConnectionEndpoint.validate("https://user:pass@example.com/mcp") == .failure(.credentialsInURL))
        #expect(ConnectionEndpoint.validate("https://example.com/mcp#frag") == .failure(.fragment))
        #expect(ConnectionEndpoint.validate("https://exa mple.com/mcp") == .failure(.malformed))
    }

    @Test func savedConfigurationIsRevalidatedWhenLoaded() {
        let json = Data(#"{"id":"\#(UUID().uuidString)","name":"X","endpoint":"http://example.com/mcp","auth":"none","isEnabled":true,"enabledTools":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MCPConnection.self, from: json) }
    }
}
