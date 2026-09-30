import AnyLanguageModel
import Foundation
@testable import PluginSDK
import SloppyRuntime
import Testing

@Test("Codex transports image bytes alongside text rather than dropping image segments")
func codexImageTransport() throws {
    let model = OpenAIOAuthModel(bearerToken: "fixture-token", model: "fixture-model")
    let pixels = Data([137, 80, 78, 71, 13, 10, 26, 10])
    let prompt = Transcript.Prompt(segments: [
        .text(.init(content: "Describe this sprite")),
        .image(.init(source: .data(pixels, mimeType: "image/png")))
    ])
    let input = model.transcriptToResponsesInput(Transcript(entries: [.prompt(prompt)]))
    let content = try #require(input.first?["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["text"] as? String == "Describe this sprite")
    #expect(content[1]["type"] as? String == "input_image")
    #expect(content[1]["image_url"] as? String == "data:image/png;base64,\(pixels.base64EncodedString())")
}

@Test("Mobile images enforce count, size and MIME bounds before invoking a provider")
func imageLimits() throws {
    let image = SloppyImageInput(data: Data([1]), mimeType: "image/png")
    try SloppyRuntimeHost.validateImages([image])
    #expect(throws: (any Error).self) { try SloppyRuntimeHost.validateImages(Array(repeating: image, count: 9)) }
    #expect(throws: (any Error).self) { try SloppyRuntimeHost.validateImages([SloppyImageInput(data: Data([1]), mimeType: "text/plain")]) }
    #expect(throws: (any Error).self) { try SloppyRuntimeHost.validateImages([SloppyImageInput(data: Data())]) }
}
