import Foundation
import HozzMCP
import HozzReceive
import HozzStore

// The MCP server an assistant launches as a subprocess.
//
// It reads the same database the Mac app writes, so an assistant sees exactly
// what the user sees — there is no second copy and no sync step between them.
//
// The data directory is passed in rather than guessed. The Mac app is
// sandboxed, so its store lives inside its container, but this tool is launched
// by the assistant and therefore runs *outside* that sandbox: resolving
// "Application Support" here would silently point at a different, empty
// directory. The app prints the correct absolute path in its Assistant tab.
//
// Nothing is ever written to stdout except protocol messages: a stray print
// corrupts the JSON-RPC stream and the client disconnects with no explanation.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hozz-mcp: \(message)\n".utf8))
    exit(1)
}

func resolveDirectory() -> URL {
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        if argument == "--data-dir", let path = arguments.first {
            return URL(fileURLWithPath: path)
        }
        if argument.hasPrefix("--data-dir=") {
            return URL(fileURLWithPath: String(argument.dropFirst("--data-dir=".count)))
        }
    }
    if let path = ProcessInfo.processInfo.environment["HOZZ_DATA_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    // Only correct when the app is not sandboxed; kept as a convenience for
    // running the tool by hand.
    guard let directory = try? StoreLocation.supportDirectory() else {
        fail("could not locate Hozz's data. Pass --data-dir <path>.")
    }
    return directory.appending(path: "Received", directoryHint: .isDirectory)
}

let directory = resolveDirectory()

guard FileManager.default.fileExists(
    atPath: directory.appending(path: "hozz-received.sqlite").path
) else {
    fail(
        """
        no received data at \(directory.path). Open Hozz on this Mac, connect \
        your phone, and sync at least once. If Hozz is installed, copy the \
        configuration from its Assistant tab, which contains the correct path.
        """
    )
}

let store: IngestStore
do {
    store = try IngestStore(directory: directory)
} catch {
    fail("could not open Hozz's data: \(error.localizedDescription)")
}

await MCPStdioTransport(server: MCPServer(store: store)).run()
