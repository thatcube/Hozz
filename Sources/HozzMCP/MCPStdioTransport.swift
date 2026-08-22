import Foundation

/// Runs an ``MCPServer`` over stdin and stdout.
///
/// MCP clients launch the server as a subprocess and speak newline-delimited
/// JSON-RPC over the pipe. Nothing is written to stdout except protocol
/// messages — a stray `print` there corrupts the stream and the client simply
/// disconnects with no explanation, so diagnostics go to stderr.
public struct MCPStdioTransport: Sendable {
    private let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func run() async {
        FileHandle.standardError.write(
            Data("Hozz MCP server ready. Reading requests on stdin.\n".utf8)
        )

        var buffer = Data()
        let input = FileHandle.standardInput

        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // The client closed the pipe, which is how a normal shutdown
                // looks. Anything still buffered is a truncated message.
                break
            }
            buffer.append(chunk)

            // Messages are newline-delimited, but a read can land mid-message
            // or contain several, so the buffer is drained line by line.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])

                let trimmed = line.trimmingTrailingCarriageReturn()
                guard !trimmed.isEmpty else {
                    continue
                }
                if let reply = await server.handle(Data(trimmed)) {
                    write(reply)
                }
            }
        }
    }

    private func write(_ payload: Data) {
        var message = payload
        message.append(0x0A)
        FileHandle.standardOutput.write(message)
    }
}

private extension Data {
    func trimmingTrailingCarriageReturn() -> Data {
        guard last == 0x0D else {
            return self
        }
        return dropLast()
    }
}
