import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import SloppyClientCore

struct ChatAttachmentPreviewContext: Sendable {
    var scope: [String] = []
    var load: @Sendable (ChatAttachment) async throws -> Data = { attachment in
        guard let data = attachment.previewData else { throw URLError(.resourceUnavailable) }
        return data
    }
}

extension EnvironmentValues {
    @Entry var chatAttachmentPreviewContext = ChatAttachmentPreviewContext()
}

/// ImageIO images are immutable; decoding and cache access stay on this actor.
struct ChatAttachmentThumbnail: @unchecked Sendable {
    let image: CGImage

    static func isImage(_ attachment: ChatAttachment) -> Bool {
        guard let type = UTType(mimeType: attachment.mimeType) else { return false }
        return type.conforms(to: .image)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 25 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return Self(image: image)
    }
}

actor ChatAttachmentThumbnailCache {
    static let shared = ChatAttachmentThumbnailCache()
    struct Key: Hashable, Sendable {
        let scope: [String]
        let attachmentID: String
    }
    private var values: [Key: ChatAttachmentThumbnail] = [:]
    private var order: [Key] = []
    private var cost = 0
    private let maximumCost = 24 * 1_024 * 1_024
    private var activeLoads = 0
    private let maximumLoads = 3

    private func acquireLoadSlot() async throws {
        // Cancellation-aware backpressure: scrolling cannot create unbounded original-image loads.
        while activeLoads >= maximumLoads {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        activeLoads += 1
    }

    func thumbnail(for attachment: ChatAttachment, context: ChatAttachmentPreviewContext) async throws -> ChatAttachmentThumbnail {
        let key = Key(scope: context.scope, attachmentID: attachment.id)
        try Task.checkCancellation()
        if let value = values[key] { return value }
        try await acquireLoadSlot()
        defer { activeLoads -= 1 }
        if let value = values[key] { return value }
        // Structured task inherits cancellation. Actor serializes ImageIO decode, not the UI.
        let data = try await context.load(attachment)
        try Task.checkCancellation()
        if let value = values[key] { return value }
        let value = try ChatAttachmentThumbnail.decode(data)
        try Task.checkCancellation()
        let imageCost = value.image.bytesPerRow * value.image.height
        while cost + imageCost > maximumCost, let oldest = order.first {
            order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) {
                cost -= removed.image.bytesPerRow * removed.image.height
            }
        }
        values[key] = value
        order.append(key)
        cost += imageCost
        return value
    }
}

struct ChatSentImagePreview: View {
    let attachment: ChatAttachment
    @Environment(\.chatAttachmentPreviewContext) private var context
    @State private var thumbnail: ChatAttachmentThumbnail?
    @State private var failed = false
    @State private var expanded = false
    @State private var retry = 0

    private var taskID: String {
        // JSON preserves component boundaries, unlike a delimiter-concatenated cache key.
        (try? String(data: JSONEncoder().encode(context.scope + [attachment.id, String(retry)]), encoding: .utf8)) ?? attachment.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thumbnail {
                Button { expanded = true } label: {
                    Image(decorative: thumbnail.image, scale: 2)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 160, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open image: \(attachment.name)")
                .accessibilityIdentifier("chat.sent-image.\(attachment.id)")
            } else {
                HStack(spacing: 8) {
                    if failed {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Preview unavailable")
                        Button("Retry") { retry += 1 }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading image…")
                    }
                }
                .font(.caption)
                .frame(minWidth: 160, minHeight: 64, alignment: .leading)
            }
            Text(attachment.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: taskID) {
            thumbnail = nil
            failed = false
            do {
                let result = try await ChatAttachmentThumbnailCache.shared.thumbnail(for: attachment, context: context)
                try Task.checkCancellation()
                thumbnail = result
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 12) {
                HStack {
                    Text(attachment.name).lineLimit(1)
                    Spacer()
                    Button("Done") { expanded = false }
                }
                if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 1).resizable().scaledToFit()
                }
            }
            .padding()
            .frame(minWidth: 320, idealWidth: 640, minHeight: 240, idealHeight: 480)
        }
    }
}
