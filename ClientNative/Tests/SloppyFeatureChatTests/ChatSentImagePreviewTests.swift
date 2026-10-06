import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("Sent attachment previews")
struct ChatSentImagePreviewTests {
    private func attachment(id: String = "image") -> ChatAttachment {
        ChatAttachment(id: id, name: "shot.png", mimeType: "image/png", sizeBytes: 100)
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1200, height: 600,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func supportedImageTypesAndNonimageFallback() {
        for mime in ["image/png", "image/jpeg", "image/gif", "image/heic", "image/tiff"] {
            var image = attachment()
            image.mimeType = mime
            #expect(ChatAttachmentThumbnail.isImage(image))
        }
        for mime in ["application/pdf", "text/plain", "application/octet-stream", "unknown"] {
            var file = attachment()
            file.mimeType = mime
            #expect(!ChatAttachmentThumbnail.isImage(file))
        }
    }

    @Test func thumbnailIsDownsampledWithoutChangingAspectRatio() throws {
        let thumbnail = try ChatAttachmentThumbnail.decode(png())
        #expect(thumbnail.image.width == 640)
        #expect(thumbnail.image.height == 320)
        #expect(throws: (any Error).self) { try ChatAttachmentThumbnail.decode(Data([1, 2, 3])) }
        #expect(throws: (any Error).self) { try ChatAttachmentThumbnail.decode(Data(count: 26 * 1_024 * 1_024)) }
    }

    @Test func optimisticBytesAreNotPersistedAndHistoryKeepsMultipleAttachments() throws {
        var first = attachment()
        first.previewData = try png()
        first.relativePath = "sessions/a/assets/shot.png"
        let second = attachment(id: "second")
        for text in [[], [ChatMessageSegment(kind: .text, text: "See these images")]] {
            let message = ChatMessage(role: .user, segments: text + [
                ChatMessageSegment(kind: .attachment, attachment: first),
                ChatMessageSegment(kind: .attachment, attachment: second),
            ])
            let data = try JSONEncoder().encode(message)
            let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
            let attachments = restored.segments.compactMap(\.attachment)
            #expect(attachments.map(\.id) == ["image", "second"])
            #expect(attachments.first?.relativePath == first.relativePath)
            #expect(attachments.allSatisfy { $0.previewData == nil })
            #expect(message.segments.compactMap(\.attachment).first?.previewData != nil)
        }
    }

    @Test func repeatedScrollUsesCacheButSessionAndInstanceAreIsolated() async throws {
        let cache = ChatAttachmentThumbnailCache()
        let calls = PreviewLoadProbe(data: try png())
        func context(_ scope: [String]) -> ChatAttachmentPreviewContext {
            ChatAttachmentPreviewContext(scope: scope, load: { _ in try await calls.load() })
        }
        _ = try await cache.thumbnail(for: attachment(), context: context(["instance", "agent", "session"]))
        _ = try await cache.thumbnail(for: attachment(), context: context(["instance", "agent", "session"]))
        #expect(await calls.count == 1)
        _ = try await cache.thumbnail(for: attachment(), context: context(["other", "agent", "session"]))
        _ = try await cache.thumbnail(for: attachment(), context: context(["instance", "agent", "other"]))
        #expect(await calls.count == 3)
    }

    @Test func failedLoadCanRetryAndMissingOptimisticDataIsUnavailable() async throws {
        let cache = ChatAttachmentThumbnailCache()
        await #expect(throws: (any Error).self) {
            try await cache.thumbnail(for: attachment(), context: ChatAttachmentPreviewContext())
        }
        let data = try png()
        _ = try await cache.thumbnail(for: attachment(), context: .init(load: { _ in data }))
    }

    @Test func cancelledLoadDoesNotPopulateCache() async throws {
        let cache = ChatAttachmentThumbnailCache()
        let probe = PreviewLoadProbe(data: try png())
        let context = ChatAttachmentPreviewContext(load: { _ in try await probe.load(delay: .milliseconds(200)) })
        let task = Task { try await cache.thumbnail(for: attachment(), context: context) }
        while await probe.count == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        _ = try await cache.thumbnail(for: attachment(), context: context)
        #expect(await probe.count == 2)
    }

    @Test func concurrentLoadsAreBounded() async throws {
        let cache = ChatAttachmentThumbnailCache()
        let probe = PreviewLoadProbe(data: try png())
        let context = ChatAttachmentPreviewContext(load: { _ in try await probe.load(delay: .milliseconds(10)) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let image = attachment(id: "\(index)")
                group.addTask { _ = try await cache.thumbnail(for: image, context: context) }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maximumActive <= 3)
        #expect(await probe.count == 12)
    }
}

private actor PreviewLoadProbe {
    let data: Data
    private(set) var count = 0
    private var active = 0
    private(set) var maximumActive = 0
    init(data: Data) { self.data = data }
    func load(delay: Duration = .zero) async throws -> Data {
        count += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return data
    }
}
