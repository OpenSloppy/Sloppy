import Foundation
import Testing
import SloppyClientCore

@Suite("Source file references")
struct SourceFileReferenceTests {
    @Test(arguments: [
        ("/Users/vlad/Project/File.swift:42", "/Users/vlad/Project/File.swift", 42, nil),
        ("Sources/File.swift:42:7", "Sources/File.swift", 42, 7),
        ("File.swift:42", "File.swift", 42, nil),
        ("Sources/File.swift#L42", "Sources/File.swift", 42, nil),
        ("Sources/File.swift#L42-L50", "Sources/File.swift", 42, nil),
        ("file:///Users/vlad/My%20Project/File.swift:42", "/Users/vlad/My Project/File.swift", 42, nil),
        ("./Sources/File.swift", "Sources/File.swift", nil, nil),
        ("Sources/%D0%A2%D0%B5%D1%81%D1%82.swift#L2", "Sources/Тест.swift", 2, nil),
    ] as [(String, String, Int?, Int?)])
    func parsesFileLinks(example: (String, String, Int?, Int?)) throws {
        let (link, path, line, column) = example
        let url = try #require(URL(string: link))
        let reference = try #require(SourceFileReference(url: url))
        #expect(reference == SourceFileReference(path: path, line: line, column: column))
    }

    @Test(arguments: [
        "https://github.com/team/repo/blob/main/File.swift#L42", "mailto:dev@example.com",
        "sloppy://auth/callback", "file://other-machine/File.swift", "//example.com/File.swift",
        "File.swift:0", "Sources/File.swift:42:0", "File.swift#L0", "File.swift#L42-L2",
        "File.swift#section", "File.swift:4#L5", "File.swift?download=true", "Sources/",
        "File.swift:999999999999999999999999999999999999", "File%00.swift", "File%0A.swift",
    ])
    func ignoresExternalAndInvalidLinks(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(SourceFileReference(url: url) == nil)
    }
}
