import SwiftUI
import SloppyClientCore

struct DesktopResponseView: View {
    @Bindable var model: DesktopCompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showsResponseContent {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.showHistory && !model.messages.isEmpty {
                            history
                        } else if let text = model.responseText {
                            Text(text).font(.system(size: 14, weight: .semibold))
                                .lineLimit(8).textSelection(.enabled)
                            Text(model.status).font(.system(size: 13)).foregroundStyle(.secondary)
                        } else if model.canStop {
                            Text(model.status).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 10) {
                        Button("Close response", systemImage: "xmark", action: model.dismissResponse)
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                            .help("Close response")
                            .accessibilityIdentifier("pointer.close-response")
                        if model.canStop {
                            Button("Stop Agent", systemImage: "stop.fill") { Task { await model.stop() } }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                                .disabled(model.isStopping).help("Stop Agent")
                                .accessibilityIdentifier("pointer.stop")
                        }
                    }
                }
            }
            if let approval = model.pendingApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tool approval required").font(.caption.weight(.semibold))
                    Text(approval.tool ?? "Tool").font(.caption)
                    HStack {
                        Button("Allow") { Task { await model.approve(true) } }
                        Button("Deny") { Task { await model.approve(false) } }
                    }
                }
            }
            if let request = model.pendingInput {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.title ?? "Agent needs your input").font(.caption.weight(.semibold))
                        ForEach(request.questions) { question in
                            Text(question.question).font(.caption)
                            ForEach(question.options) { option in
                                Button(option.label) { model.selectedInputOptions[question.id] = option.id }
                                    .buttonStyle(.bordered)
                                    .tint(model.selectedInputOptions[question.id] == option.id ? .accentColor : .secondary)
                            }
                            if question.allowCustomAnswer {
                                TextField("Your answer", text: Binding(get: { model.inputAnswers[question.id] ?? "" },
                                                                     set: { model.inputAnswers[question.id] = $0 }))
                            }
                        }
                        Button("Reply") { Task { await model.answerInput() } }
                    }
                }.frame(maxHeight: 120)
            }
            if let image = model.image {
                HStack {
                    if let preview = NSImage(data: image.png) {
                        Image(nsImage: preview).resizable().scaledToFit().frame(width: 72, height: 44)
                    }
                    VStack(alignment: .leading) {
                        Text(model.context?.application ?? "Screen area").font(.caption.weight(.medium))
                        Text("\(image.width) × \(image.height)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.image = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4)
            }
            if let error = model.shortcutError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: DesktopCompanionLayout.contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if model.responsePanelHeight != height { model.responsePanelHeight = height; model.onLayoutChanged?() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pointer.response")
    }

    private var history: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages.filter { $0.role != .system }) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "You" : "Sloppy")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if !message.textContent.isEmpty {
                                Text(message.textContent).font(.system(size: 13)).textSelection(.enabled)
                            }
                            ForEach(message.segments.compactMap(\.attachment), id: \.id) { attachment in
                                Label(attachment.name, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(message.id)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 230)
            .onChange(of: model.messages.last?.id) { _, id in
                if let id { reader.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
