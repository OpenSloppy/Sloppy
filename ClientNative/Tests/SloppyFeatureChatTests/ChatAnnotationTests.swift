import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Chat annotations")
struct ChatAnnotationTests {
    @Test("comments stay paired with their quoted selections")
    func quoteComments() {
        let quotes = [
            ChatComposerQuote(text: "First\r\nselection", comment: "Change this"),
            ChatComposerQuote(text: "Second selection", comment: "Keep this"),
        ]
        #expect(ChatComposerQuote.messageContent("Please apply", quotes: quotes)
                == "> First\n> selection\nComment: Change this\n\n> Second selection\nComment: Keep this\n\nPlease apply")
    }

    @Test("points use image coordinates and reject letterbox margins")
    func pointCoordinates() throws {
        let frame = ChatImageRegion.imageFrame(imageSize: CGSize(width: 1600, height: 800),
                                              canvasSize: CGSize(width: 800, height: 600))
        #expect(frame == CGRect(x: 0, y: 100, width: 800, height: 400))
        let region = try #require(ChatImageRegion.selection(
            from: CGPoint(x: 216, y: 197.2), to: CGPoint(x: 216, y: 197.2), imageFrame: frame))
        #expect(region.coordinateDescription == "x: 27.0%, y: 24.3%")
        #expect(ChatImageRegion.selection(from: CGPoint(x: 20, y: 10),
                                          to: CGPoint(x: 40, y: 120), imageFrame: frame) == nil)
    }

    @Test("reverse drags normalize areas and clip at image edges")
    func areaCoordinates() throws {
        let frame = CGRect(x: 100, y: 50, width: 400, height: 200)
        let region = try #require(ChatImageRegion.selection(
            from: CGPoint(x: 400, y: 200), to: CGPoint(x: 0, y: 0), imageFrame: frame))
        #expect(region == ChatImageRegion(x: 0, y: 0, width: 0.75, height: 0.75))
        #expect(ChatImageRegion.selection(from: .zero, to: .zero, imageFrame: .zero) == nil)
        #expect(ChatImageRegion(x: .nan, y: 2, width: .infinity, height: -1)
                == ChatImageRegion(x: 0, y: 1))
    }

    @Test("queued images retain notes and identify duplicate filenames by upload order")
    func queuedImageCoordinates() throws {
        let bytes = Data([1, 2, 3])
        let first = ChatComposerAttachment(name: "screenshot.png", mimeType: "image/png", data: bytes,
            annotations: [.init(region: .init(x: 0.27, y: 0.243), comment: "Fix this button")])
        let second = ChatComposerAttachment(name: "screenshot.png", mimeType: "image/png", data: bytes,
            annotations: [.init(region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4), comment: "Widen this area")])
        var queue = ChatMessageQueue()
        queue.enqueue(content: "Review", attachments: [first, second])
        let dequeued = queue.dequeue()
        let message = try #require(dequeued)
        #expect(message.attachments == [first, second])
        #expect(message.attachments.map(\.upload.contentBase64) == [bytes.base64EncodedString(), bytes.base64EncodedString()])
        let content = ChatComposerQuote.messageContent(message.content, quotes: message.quotes, attachments: message.attachments)
        #expect(content.contains("attachment 1: screenshot.png"))
        #expect(content.contains("attachment 2: screenshot.png"))
        #expect(content.contains("1. (x: 27.0%, y: 24.3%) Fix this button"))
        #expect(content.contains("width: 30.0%, height: 40.0%) Widen this area"))
        #expect(content.hasSuffix("\n\nReview"))
    }

    @Test("editing or deleting a note preserves other selections and image bytes")
    @MainActor
    func editingAnnotations() throws {
        let api = SloppyAPIClient()
        let model = ChatScreenViewModel(apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
            settings: ClientSettings(), connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false, responseNotificationScheduler: AnnotationTestNotifications(),
            onOpenSettings: { _ in })
        model.addQuoteToComposer("First")
        model.addQuoteToComposer("Second")
        let firstID = try #require(model.composerQuotes.first?.id)
        model.updateComposerQuote(id: firstID, comment: "First comment")
        #expect(model.composerQuotes.map(\.comment) == ["First comment", ""])
        model.removeComposerQuote(id: firstID)
        #expect(model.composerQuotes.map(\.text) == ["Second"])
        let bytes = Data([1, 2, 3])
        model.attachData(bytes, suggestedName: "screen.png", mimeType: "image/png")
        let attachment = try #require(model.composerAttachments.first)
        let notes = [ChatImageAnnotation(region: .init(x: 0.2, y: 0.3), comment: "Here")]
        model.updateImageAnnotations(id: attachment.id, annotations: notes)
        #expect(model.composerAttachments.first?.annotations == notes)
        #expect(model.composerAttachments.first?.data == bytes)
        model.updateImageAnnotations(id: attachment.id, annotations: [])
        #expect(model.composerAttachments.first?.annotations.isEmpty == true)
    }
}

@MainActor
private final class AnnotationTestNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
