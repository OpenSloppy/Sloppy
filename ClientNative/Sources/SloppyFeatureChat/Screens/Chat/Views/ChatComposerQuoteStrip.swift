import SwiftUI

struct ChatComposerQuoteStrip: View {
    let quotes: [ChatComposerQuote]
    let update: @MainActor (ChatComposerQuote.ID, String) -> Void
    let remove: @MainActor (ChatComposerQuote.ID) -> Void

    @FocusState private var focusedID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(quotes.enumerated()), id: \.element.id) { number, quote in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Annotation \(number + 1)", systemImage: "quote.opening")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button { remove(quote.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove annotation \(number + 1)")
                            }
                            Text(quote.text).font(.caption).lineLimit(2)
                            Divider()
                            TextField("Add a comment…", text: Binding(
                                get: { quote.comment }, set: { update(quote.id, $0) }
                            ), axis: .vertical)
                                .font(.callout)
                                .lineLimit(1...3)
                                .textFieldStyle(.plain)
                                .focused($focusedID, equals: quote.id)
                                .accessibilityLabel("Comment for annotation \(number + 1)")
                                .accessibilityIdentifier("chat.composer.annotation.\(quote.id).comment")
                        }
                        .id(quote.id)
                        .padding(12)
                        .frame(width: 280, alignment: .topLeading)
                        .foregroundStyle(ChatAnnotationStyle.foreground(colorScheme))
                        .background(ChatAnnotationStyle.background(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxHeight: 164)
            .accessibilityIdentifier("chat.composer.quotes")
            .onChange(of: quotes.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .trailing) }
                focusedID = id
            }
            .onAppear {
                if let id = quotes.last?.id { proxy.scrollTo(id, anchor: .trailing) }
                focusedID = quotes.last?.id
            }
        }
    }
}
