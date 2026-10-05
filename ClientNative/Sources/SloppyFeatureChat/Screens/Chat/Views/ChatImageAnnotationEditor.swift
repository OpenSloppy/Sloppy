import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ChatImageAnnotationEditor: View {
    let attachment: ChatComposerAttachment
    let save: @MainActor ([ChatImageAnnotation]) -> Void
    private let decodedImage: (image: Image, size: CGSize)?

    @State private var annotations: [ChatImageAnnotation]
    @State private var selectedID: UUID?
    @State private var provisionalRegion: ChatImageRegion?
    @FocusState private var focusedAnnotationID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(attachment: ChatComposerAttachment, save: @escaping @MainActor ([ChatImageAnnotation]) -> Void) {
        self.attachment = attachment
        self.save = save
        self.decodedImage = Self.decodeImage(attachment.data)
        _annotations = State(initialValue: attachment.annotations)
        _selectedID = State(initialValue: attachment.annotations.last?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.name).font(.headline).lineLimit(1)
                    Text("Click to mark a point. Drag to select an area.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to chat") {
                    save(annotations)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("chat.image.annotations.save")
            }

            if let decodedImage {
                canvas(image: decodedImage.image, size: decodedImage.size)
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo",
                                       description: Text("This attachment could not be opened."))
            }

            annotationComments
                .frame(height: 200)
        }
        .padding(20)
        .foregroundStyle(ChatAnnotationStyle.foreground(colorScheme))
        .background(ChatAnnotationStyle.background(colorScheme))
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 1000, minHeight: 650, idealHeight: 820)
        #endif
        .presentationDetents([.large])
    }

    private func canvas(image: Image, size: CGSize) -> some View {
        GeometryReader { geometry in
            let frame = ChatImageRegion.imageFrame(imageSize: size, canvasSize: geometry.size)
            ZStack(alignment: .topLeading) {
                image.resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())

                #if os(macOS)
                ChatImageAnnotationPointerInput { start, end in
                    provisionalRegion = ChatImageRegion.selection(from: start, to: end, imageFrame: frame)
                } ended: { start, end in
                    provisionalRegion = nil
                    guard let region = ChatImageRegion.selection(from: start, to: end, imageFrame: frame) else { return }
                    addAnnotation(region)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                #else
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                provisionalRegion = ChatImageRegion.selection(
                                    from: value.startLocation, to: value.location, imageFrame: frame)
                            }
                            .onEnded { value in
                                provisionalRegion = nil
                                guard let region = ChatImageRegion.selection(
                                    from: value.startLocation, to: value.location, imageFrame: frame
                                ) else { return }
                                addAnnotation(region)
                            }
                            .exclusively(before: SpatialTapGesture().onEnded { value in
                                guard let region = ChatImageRegion.selection(
                                    from: value.location, to: value.location, imageFrame: frame
                                ) else { return }
                                addAnnotation(region)
                            })
                    )
                    .accessibilityLabel("Screenshot annotation canvas")
                    .accessibilityIdentifier("chat.image.annotations.canvas")
                #endif

                ForEach(annotations) { annotation in
                    regionOutline(annotation.region, in: frame)
                        .allowsHitTesting(false)
                }
                if let provisionalRegion {
                    regionOutline(provisionalRegion, in: frame).allowsHitTesting(false)
                }
                ForEach(Array(annotations.enumerated()), id: \.element.id) { number, annotation in
                    Button {
                        selectedID = annotation.id
                        focusedAnnotationID = annotation.id
                    } label: {
                        Text("\(number + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ChatAnnotationStyle.ink)
                            .frame(width: 28, height: 28)
                            .background(ChatAnnotationStyle.mint, in: Circle())
                            .overlay(Circle().stroke(ChatAnnotationStyle.ink, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .position(x: frame.minX + annotation.region.x * frame.width,
                              y: frame.minY + annotation.region.y * frame.height)
                    .accessibilityLabel("Edit annotation \(number + 1)")
                }
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
        .clipped()
    }

    private func regionOutline(_ region: ChatImageRegion, in frame: CGRect) -> some View {
        Rectangle()
            .fill(ChatAnnotationStyle.mint.opacity(0.15))
            .overlay(Rectangle().stroke(ChatAnnotationStyle.mint, lineWidth: 2))
            .frame(width: max(2, region.width * frame.width), height: max(2, region.height * frame.height))
            .offset(x: frame.minX + region.x * frame.width, y: frame.minY + region.y * frame.height)
    }

    private var annotationComments: some View {
        VStack(alignment: .leading, spacing: 12) {
            if annotations.isEmpty {
                Text("Mark the screenshot, then write a comment for that location.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(annotations.enumerated()), id: \.element.id) { number, annotation in
                            HStack {
                                Button("\(number + 1) · \(annotation.region.coordinateDescription)") {
                                    selectedID = annotation.id
                                    focusedAnnotationID = annotation.id
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                Button {
                                    annotations.removeAll { $0.id == annotation.id }
                                    if selectedID == annotation.id { selectedID = annotations.last?.id }
                                } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove annotation \(number + 1)")
                            }
                            .padding(8)
                            .background(selectedID == annotation.id ? ChatAnnotationStyle.mint.opacity(0.25) : .clear)
                        }
                    }
                }
                Divider()
                if let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) {
                    Text("Comment for annotation \(index + 1)").font(.subheadline.weight(.semibold))
                    TextField("What should the agent pay attention to?", text: Binding(
                        get: { annotations.first(where: { $0.id == selectedID })?.comment ?? "" },
                        set: { comment in
                            guard let current = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
                            annotations[current].comment = comment
                        }
                    ), axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .focused($focusedAnnotationID, equals: selectedID)
                        .id(selectedID)
                        .task(id: selectedID) {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            focusedAnnotationID = selectedID
                        }
                        .accessibilityIdentifier("chat.image.annotations.comment")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func addAnnotation(_ region: ChatImageRegion) {
        let annotation = ChatImageAnnotation(region: region)
        annotations.append(annotation)
        selectedID = annotation.id
        focusedAnnotationID = annotation.id
    }

    private static func decodeImage(_ data: Data) -> (image: Image, size: CGSize)? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return (Image(nsImage: image), image.size)
        #elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return (Image(uiImage: image), image.size)
        #else
        return nil
        #endif
    }
}

enum ChatAnnotationStyle {
    static let mint = Color(red: 200 / 255, green: 226 / 255, blue: 174 / 255)
    static let ink = Color(red: 36 / 255, green: 37 / 255, blue: 33 / 255)
    static let paper = Color(red: 245 / 255, green: 242 / 255, blue: 233 / 255)
    static let forest = Color(red: 32 / 255, green: 38 / 255, blue: 30 / 255)

    static func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? forest : paper }
    static func foreground(_ scheme: ColorScheme) -> Color { scheme == .dark ? paper : ink }
}
