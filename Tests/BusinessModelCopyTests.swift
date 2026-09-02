import Foundation
import XCTest

/// Hozz may change how it is funded. Product copy must not turn today's price
/// or tier structure into a permanent promise.
final class BusinessModelCopyTests: XCTestCase {
    func testShippedCopyMakesNoPermanentPricingPromise() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            repository.appending(path: "App"),
            repository.appending(path: "Mac"),
            repository.appending(path: "docs"),
            repository.appending(path: "receiver"),
            repository.appending(path: "README.md"),
            repository.appending(path: "CONTRIBUTING.md"),
            repository.appending(path: "AGENTS.md"),
            repository.appending(path: "project.yml")
        ]
        let forbidden = [
            "free forever",
            "free and open source",
            "free, open-source",
            "free, open source",
            "no subscription",
            "no paywall",
            "no paid tier",
            "no paid features",
            "nothing to sell you",
            "non-commercial",
            "more free apps"
        ]

        var violations: [String] = []
        for file in try textFiles(in: roots) {
            let text = try String(contentsOf: file, encoding: .utf8)
                .lowercased()
            for phrase in forbidden where text.contains(phrase) {
                let relative = file.path.replacingOccurrences(
                    of: repository.path + "/",
                    with: ""
                )
                violations.append("\(relative): \(phrase)")
            }
        }

        XCTAssertEqual(
            violations,
            [],
            """
            Hozz does not promise a permanent price or tier structure:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    private func textFiles(in roots: [URL]) throws -> [URL] {
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ) else {
                continue
            }
            if !isDirectory.boolValue {
                files.append(root)
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let file = enumerator?.nextObject() as? URL {
                let values = try file.resourceValues(
                    forKeys: [.isRegularFileKey]
                )
                guard values.isRegularFile == true else {
                    continue
                }
                if ["swift", "md", "plist"].contains(
                    file.pathExtension.lowercased()
                ) {
                    files.append(file)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
