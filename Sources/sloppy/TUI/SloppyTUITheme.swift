import Foundation
import Protocols
import TauTUI

struct SloppyTUIColor: Codable, Equatable, Sendable {
    var red: Int
    var green: Int
    var blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: String) throws {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.first == "#" else {
            throw SloppyTUIThemeError.invalidColor(hex)
        }
        let value = String(trimmed.dropFirst())
        guard let raw = Int(value, radix: 16) else {
            throw SloppyTUIThemeError.invalidColor(hex)
        }
        self.init(
            red: (raw >> 16) & 0xff,
            green: (raw >> 8) & 0xff,
            blue: raw & 0xff
        )
    }

    func foregroundStyle(_ text: String) -> String {
        AnsiStyling.rgb(UInt8(red), UInt8(green), UInt8(blue))(text)
    }

    var textBackground: Text.Background {
        .init(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
    }

    var background: AnsiStyling.Background {
        .rgb(UInt8(red), UInt8(green), UInt8(blue))
    }

    func blended(with other: SloppyTUIColor, amount: Double) -> SloppyTUIColor {
        let clampedAmount = min(1, max(0, amount))
        let inverseAmount = 1 - clampedAmount
        return SloppyTUIColor(
            red: Int((Double(red) * inverseAmount + Double(other.red) * clampedAmount).rounded()),
            green: Int((Double(green) * inverseAmount + Double(other.green) * clampedAmount).rounded()),
            blue: Int((Double(blue) * inverseAmount + Double(other.blue) * clampedAmount).rounded())
        )
    }
}

enum SloppyTUIThemeError: Error, CustomStringConvertible, Equatable {
    case invalidColor(String)

    var description: String {
        switch self {
        case .invalidColor(let value):
            return "invalid color `\(value)`; expected #RRGGBB"
        }
    }
}

struct SloppyTUIResolvedTheme: Equatable, Sendable {
    static let defaultID = "default"

    var id: String
    var name: String
    var source: String
    var accent: SloppyTUIColor
    var accentBright: SloppyTUIColor
    var foreground: SloppyTUIColor
    var muted: SloppyTUIColor
    var blue: SloppyTUIColor
    var green: SloppyTUIColor
    var yellow: SloppyTUIColor
    var orange: SloppyTUIColor
    var red: SloppyTUIColor
    var screenBackground: SloppyTUIColor
    var panelBackground: SloppyTUIColor
    var userMessageBackground: SloppyTUIColor
    var toolBackground: SloppyTUIColor
    var thinkingBackground: SloppyTUIColor
    var attachmentBackground: SloppyTUIColor
    var textBackground: SloppyTUIColor
    var truncatedBackground: SloppyTUIColor

    static let `default` = SloppyTUIResolvedTheme(
        id: defaultID,
        name: "Default",
        source: "built-in",
        accent: .init(red: 82, green: 211, blue: 194),
        accentBright: .init(red: 103, green: 232, blue: 249),
        foreground: .init(red: 226, green: 232, blue: 240),
        muted: .init(red: 148, green: 163, blue: 184),
        blue: .init(red: 96, green: 165, blue: 250),
        green: .init(red: 74, green: 222, blue: 128),
        yellow: .init(red: 250, green: 204, blue: 21),
        orange: .init(red: 251, green: 178, blue: 123),
        red: .init(red: 248, green: 113, blue: 113),
        screenBackground: .init(red: 12, green: 16, blue: 22),
        panelBackground: .init(red: 24, green: 24, blue: 24),
        userMessageBackground: .init(red: 55, green: 55, blue: 55),
        toolBackground: .init(red: 31, green: 41, blue: 55),
        thinkingBackground: .init(red: 38, green: 38, blue: 38),
        attachmentBackground: .init(red: 32, green: 45, blue: 42),
        textBackground: .init(red: 12, green: 16, blue: 22),
        truncatedBackground: .init(red: 12, green: 16, blue: 22)
    )
}

enum SloppyTUITheme {
    private static let resetBackground = "\u{001B}[49m"
    nonisolated(unsafe) private static var activeTheme = SloppyTUIResolvedTheme.default
    private static let black = AnsiStyling.color(30)
    private static let blockHorizontalPadding = 2
    private static let blockVerticalPadding = 1
    private static let waitingFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let thinkingWords = [
        "thinking",
        "processing",
        "looting",
        "brewing",
        "plotting",
        "untangling",
        "debugging",
        "polishing",
        "compiling",
        "noodling",
        "mulling",
        "pondering",
        "scheming",
        "conspiring",
        "ruminating",
        "calculating",
        "crunching",
        "simmering",
        "marinating",
        "stirring",
        "kneading",
        "seasoning",
        "toasting",
        "sizzling",
        "whisking",
        "fermenting",
        "distilling",
        "percolating",
        "decoding",
        "recursing",
        "refactoring",
        "spelunking",
        "triangulating",
        "calibrating",
        "aligning",
        "wrestling",
        "wrangling",
        "juggling",
        "balancing",
        "stacking",
        "unsticking",
        "unclumping",
        "deconfusing",
        "recombobulating",
        "decrinkling",
        "unspooling",
        "rewiring",
        "crosschecking",
        "sanitychecking",
        "overthinking",
        "underthinking",
        "sidequesting",
        "backtracking",
        "whiteboarding",
        "fingerpainting",
        "napkinmathing",
        "bikeshedding",
        "breadcrumbing",
        "threadpulling",
        "mapmaking",
        "sparkfinding",
        "buttonpushing",
        "leverpulling",
        "tinkering",
        "massaging",
        "tickling",
        "nudging",
        "squinting",
        "scrying",
        "divining",
        "unhexing",
        "dejinxing",
        "vibing",
        "vibechecking",
        "brainstorming",
        "mindmapping",
        "wordsmithing",
        "contextpacking",
        "answerbaking",
    ]

    static func setBarColor(_ raw: String) -> Bool {
        var next = activeTheme
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "default":
            next.accent = SloppyTUIResolvedTheme.default.accent
            next.accentBright = SloppyTUIResolvedTheme.default.accentBright
        case "red":
            next.accent = activeTheme.red
            next.accentBright = .init(red: 252, green: 165, blue: 165)
        case "blue":
            next.accent = activeTheme.blue
            next.accentBright = .init(red: 147, green: 197, blue: 253)
        case "green":
            next.accent = activeTheme.green
            next.accentBright = .init(red: 134, green: 239, blue: 172)
        case "yellow":
            next.accent = activeTheme.yellow
            next.accentBright = .init(red: 254, green: 240, blue: 138)
        case "purple":
            next.accent = .init(red: 192, green: 132, blue: 252)
            next.accentBright = .init(red: 216, green: 180, blue: 254)
        case "orange":
            next.accent = activeTheme.orange
            next.accentBright = .init(red: 253, green: 186, blue: 116)
        case "pink":
            next.accent = .init(red: 244, green: 114, blue: 182)
            next.accentBright = .init(red: 249, green: 168, blue: 212)
        case "cyan":
            next.accent = .init(red: 34, green: 211, blue: 238)
            next.accentBright = .init(red: 103, green: 232, blue: 249)
        default:
            return false
        }
        activeTheme = next
        return true
    }

    static func apply(_ theme: SloppyTUIResolvedTheme) {
        activeTheme = theme
    }

    static func resetDefault() {
        activeTheme = .default
    }

    static var currentTheme: SloppyTUIResolvedTheme {
        activeTheme
    }

    static func accent(_ text: String) -> String {
        activeTheme.accent.foregroundStyle(text)
    }

    static func accentBright(_ text: String) -> String {
        activeTheme.accentBright.foregroundStyle(text)
    }

    static func blue(_ text: String) -> String { activeTheme.blue.foregroundStyle(text) }
    static func green(_ text: String) -> String { activeTheme.green.foregroundStyle(text) }
    static func yellow(_ text: String) -> String { activeTheme.yellow.foregroundStyle(text) }
    static func orange(_ text: String) -> String { activeTheme.orange.foregroundStyle(text) }
    static func red(_ text: String) -> String { activeTheme.red.foregroundStyle(text) }
    static func muted(_ text: String) -> String { activeTheme.muted.foregroundStyle(text) }
    static func foreground(_ text: String) -> String { activeTheme.foreground.foregroundStyle(text) }
    static func rainbow(_ text: String) -> String {
        rainbow(text, frame: 0)
    }

    static func rainbow(_ text: String, frame: Int) -> String {
        let colors: [(String) -> String] = [red, orange, yellow, green, blue, accentBright]
        guard !colors.isEmpty else { return text }
        let offset = ((frame % colors.count) + colors.count) % colors.count
        return text.enumerated()
            .map { index, character in
                colors[(index + offset) % colors.count](String(character))
            }
            .joined()
    }

    private static var panelBackground: AnsiStyling.Background { activeTheme.panelBackground.background }
    private static var screenBackground: AnsiStyling.Background { activeTheme.screenBackground.background }
    private static var userMessageBackground: AnsiStyling.Background { activeTheme.userMessageBackground.background }
    private static var toolBackground: AnsiStyling.Background { activeTheme.toolBackground.background }
    private static var thinkingBackground: AnsiStyling.Background { activeTheme.thinkingBackground.background }
    private static var attachmentBackground: AnsiStyling.Background { activeTheme.attachmentBackground.background }

    static var selectListTheme: SelectListTheme {
        SelectListTheme(
            selectedPrefix: { accentBright($0) },
            selectedText: { accentBright(AnsiStyling.bold($0)) },
            description: { muted($0) },
            scrollInfo: { muted($0) },
            noMatch: { muted($0) }
        )
    }

    static var palette: ThemePalette {
        ThemePalette(
            editor: EditorTheme(
                borderColor: { accent($0) },
                selectList: selectListTheme
            ),
            selectList: selectListTheme,
            markdown: MarkdownComponent.MarkdownTheme(
                heading: { accentBright($0) },
                link: { blue(AnsiStyling.underline($0)) },
                linkUrl: { muted($0) },
                code: { yellow($0) },
                codeBlock: { green($0) },
                codeBlockBorder: { muted($0) },
                quote: { muted(AnsiStyling.italic($0)) },
                quoteBorder: { accent($0) },
                hr: { muted($0) },
                listBullet: { accent($0) },
                bold: AnsiStyling.bold,
                italic: AnsiStyling.italic,
                strikethrough: AnsiStyling.strikethrough,
                underline: AnsiStyling.underline
            ),
            textBackground: activeTheme.textBackground.textBackground,
            loader: Loader.LoaderTheme(
                spinner: { accentBright($0) },
                message: { muted($0) }
            ),
            truncatedBackground: activeTheme.truncatedBackground.background
        )
    }

    static func header(project: String, agent: String, session: String) -> String {
        let title = accentBright(AnsiStyling.bold("Sloppy TUI"))
        return "\(title)  \(muted("project:")) \(foreground(project))  \(muted("agent:")) \(foreground(agent))  \(muted("session:")) \(foreground(session))"
    }

    static func terminalTitle(status: String, session: AgentSessionSummary, agent: String) -> String {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSession = sessionDisplayTitle(session).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [
            normalizedStatus.isEmpty ? "idle" : normalizedStatus,
            normalizedSession.isEmpty ? "Session" : normalizedSession,
            normalizedAgent,
        ].filter { !$0.isEmpty }
        return "Sloppy - " + parts.joined(separator: " - ")
    }

    static func terminalTitleEscape(_ title: String) -> String {
        "\u{001B}]0;\(sanitizeTerminalTitle(title))\u{0007}"
    }

    static func sanitizeTerminalTitle(_ title: String) -> String {
        let cleaned = String(title.unicodeScalars.compactMap { scalar -> Character? in
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return nil
            }
            return Character(scalar)
        })
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return truncateEnd(collapsed, maxWidth: 160)
    }

    static func status(_ text: String, isBusy: Bool) -> String {
        if isBusy {
            return yellow(text)
        }
        if text.contains("\u{001B}[") {
            return text
        }
        return muted(text)
    }

    static func screenBackgroundLines(_ lines: [String], width: Int) -> [String] {
        lines.map { line in
            applyBackground(padded(line, width: width), width: width, background: screenBackground)
        }
    }

    static func operationStatusFooterLine(
        width: Int,
        statuses: [SloppyTUIOperationStatus],
        frame: Int
    ) -> String {
        guard !statuses.isEmpty else {
            return applyPanelBackground(padded("", width: width), width: width)
        }
        let parts = statuses.map { status in
            let detail = status.detail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail?.isEmpty == false ? muted(" · \(detail ?? "")") : ""
            return shimmeringText(status.label, frame: frame) + suffix
        }
        let text = "  " + parts.joined(separator: muted("  |  "))
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func noticeToastLines(_ text: String, width: Int) -> [String] {
        let toastWidth = max(1, min(width, max(24, min(72, width - 4))))
        let innerWidth = max(1, toastWidth - 2)
        let message = truncateEnd(
            text.replacingOccurrences(of: "\n", with: " "),
            maxWidth: max(1, innerWidth - 6)
        )
        let empty = centeredToastLine("", toastWidth: toastWidth, screenWidth: width)
        let messagePadding = max(0, innerWidth - VisibleWidth.measure(message))
        let leftPadding = messagePadding / 2
        let rightPadding = messagePadding - leftPadding
        let content = String(repeating: " ", count: leftPadding)
            + foreground(message)
            + String(repeating: " ", count: rightPadding)
        let messageLine = centeredToastLine(content, toastWidth: toastWidth, screenWidth: width)
        return [empty, messageLine, empty]
    }

    static func sessionStatusLine(context: String, attachments: String, sessionID: String) -> String {
        let details = (context + attachments).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = details.isEmpty ? "" : "\(details)  "
        return muted("\(suffix)last: \(shortID(sessionID))")
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatTokenCountShort(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private static func formatTokenCountCompact(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return value.rounded(.down) == value ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            return "\(Int((Double(count) / 1_000).rounded()))K"
        }
        return "\(count)"
    }

    private static func formatUSD(_ value: Double) -> String {
        let amount = max(0, value)
        if amount > 0, amount < 0.01 {
            return String(format: "$%.4f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    private static func formatPercent(_ value: Double) -> String {
        let percent = max(0, min(100, value))
        if percent > 0, percent < 0.1 {
            return String(format: "%.2f%%", percent)
        }
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return String(format: "%.0f%%", percent)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 1 {
            return "0s"
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }
        if value < 3_600 {
            let minutes = Int(value) / 60
            let remaining = value - Double(minutes * 60)
            return String(format: "%dm %.1fs", minutes, remaining)
        }
        let hours = Int(value) / 3_600
        let minutes = (Int(value) % 3_600) / 60
        return String(format: "%dh %dm", hours, minutes)
    }

    private static func formatCompactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 {
            return "\(total)s"
        }
        if total < 3_600 {
            return String(format: "%dm%02ds", total / 60, total % 60)
        }
        return String(format: "%dh%02dm", total / 3_600, (total % 3_600) / 60)
    }

    private static func contextUsageGrid(_ summary: SloppyTUIContextUsageSummary) -> [String] {
        let columns = 10
        let rows = 10
        let width = columns * rows
        guard summary.contextWindowTokens > 0 else {
            let row = Array(repeating: muted("□"), count: columns).joined(separator: " ")
            return Array(repeating: row, count: rows)
        }

        var filled = min(width, max(0, Int((Double(summary.totalTokens) / Double(summary.contextWindowTokens) * Double(width)).rounded())))
        if summary.totalTokens > 0, filled == 0 {
            filled = 1
        }
        var promptCount = min(filled, Int((Double(summary.promptTokens) / Double(summary.contextWindowTokens) * Double(width)).rounded()))
        var completionCount = min(max(0, filled - promptCount), Int((Double(summary.completionTokens) / Double(summary.contextWindowTokens) * Double(width)).rounded()))

        if summary.promptTokens > 0, filled > 0, promptCount == 0 {
            promptCount = 1
        }
        if summary.completionTokens > 0, filled > promptCount, completionCount == 0 {
            completionCount = 1
        }
        if summary.completionTokens > 0, filled == 1, promptCount == 1 {
            filled = 2
            completionCount = 1
        }
        if promptCount + completionCount > filled {
            completionCount = max(0, filled - promptCount)
        }

        let freeCount = max(0, width - promptCount - completionCount)
        let cells = Array(repeating: blue("●"), count: promptCount)
            + Array(repeating: green("●"), count: completionCount)
            + Array(repeating: muted("□"), count: freeCount)
        return stride(from: 0, to: cells.count, by: columns).map { index in
            cells[index..<min(index + columns, cells.count)].joined(separator: " ")
        }
    }

    static func welcomeScreen(
        width: Int,
        cwd: String,
        project: String,
        agent: String,
        model: String,
        mode: AgentChatMode,
        mcpSummary: SloppyTUIMCPStatusSummary = .empty,
        tipOffset: Int = 0,
        includeFooter: Bool = true
    ) -> [String] {
        let contentWidth = welcomeContentWidth(for: width)
        let left = max(0, (width - contentWidth) / 2)
        let indent = String(repeating: " ", count: left)
        var lines: [String] = []

        lines.append("")
        lines.append("")
        lines.append(contentsOf: logoLines(width: width))
        lines.append("")
        lines.append(indent + welcomePromptLine(width: contentWidth))
        lines.append(indent + welcomeMetaLine(width: contentWidth, project: project, agent: agent, model: model, mode: mode))
        lines.append(indent + welcomeShortcutsLine(width: contentWidth))
        lines.append("")
        lines.append(contentsOf: welcomeTipLines(width: width, contentWidth: contentWidth, offset: tipOffset))
        lines.append("")
        if includeFooter {
            lines.append(welcomeFooter(width: width, cwd: cwd, mcpSummary: mcpSummary))
        }
        lines.append("")
        return lines
    }

    private static func welcomeContentWidth(for width: Int) -> Int {
        max(1, min(max(1, width - 4), 64))
    }

    static func composerMetaLine(
        width: Int,
        mode: AgentChatMode,
        model: String,
        agent: String,
        provider: String,
        tokenUsage: SloppyTUITokenUsageSummary? = nil,
        lastTurnTokenUsage: TokenUsage? = nil,
        runElapsed: TimeInterval? = nil,
        stageElapsed: TimeInterval? = nil,
        animationFrame: Int = 0
    ) -> String {
        let modelText = truncateEnd(compactModel(model), maxWidth: max(4, width / 3))
        let agentText = truncateEnd(agent, maxWidth: max(4, width / 5))
        let providerText = truncateEnd(provider, maxWidth: max(4, width / 5))
        let text: String
        if let tokenUsage {
            text = "  " + modeTitle(mode, frame: animationFrame) + muted(" │ ")
                + contextIndicator(
                    model: modelText,
                    summary: tokenUsage,
                    lastTurnUsage: lastTurnTokenUsage,
                    runElapsed: runElapsed,
                    stageElapsed: stageElapsed
                )
        } else {
            text = "  " + modeTitle(mode, frame: animationFrame) + muted(" · ") + foreground(modelText) + muted("  ") + muted(agentText) + muted("  ") + muted(providerText)
        }
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func composerShellMetaLine(
        width: Int,
        cwd: String,
        agent: String,
        provider: String
    ) -> String {
        let cwdText = truncateStart(cwd, maxWidth: max(8, width / 2))
        let agentText = truncateEnd(agent, maxWidth: max(4, width / 5))
        let providerText = truncateEnd(provider, maxWidth: max(4, width / 5))
        let text = "  " + red(AnsiStyling.bold("shell")) + muted(" · ") + foreground(cwdText) + muted("  ") + muted(agentText) + muted("  ") + muted(providerText)
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func interruptControlLine(width: Int, frame: Int, isInterrupting: Bool) -> String {
        let action = isInterrupting ? "interrupting" : "interrupt"
        let text = "  " + foreground("esc") + muted(" \(action)")
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func tokenUsageStatus(_ summary: SloppyTUITokenUsageSummary) -> String {
        var text = formatTokenCountShort(summary.totalTokens)
        if let percent = summary.usagePercent {
            text += " (\(percent)%)"
        }
        if summary.cachedInputTokens > 0 {
            text += " · cached \(formatTokenCountShort(summary.cachedInputTokens))"
        }
        if summary.cachedInputTokens > 0, summary.promptTokens > 0 {
            text += " · uncached \(formatTokenCountShort(summary.uncachedInputTokens))"
        }
        if let costUSD = summary.costUSD {
            text += " · \(formatUSD(costUSD))"
        }
        return muted("tokens: ") + foreground(text)
    }

    static func turnTokenUsageBadge(_ usage: TokenUsage) -> String {
        "(\(usage.prompt) ↑ / \(usage.completion) ↓)"
    }

    static func runStatusLine(_ status: AgentRunStatusEvent) -> String {
        var label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            label = status.stage.rawValue
        }
        if let usage = status.tokenUsage {
            label += " \(turnTokenUsageBadge(usage))"
        }

        let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !details.isEmpty {
            return "\(label) - \(details)"
        }
        return label
    }

    static func tokenUsageFooterLine(width: Int, summary: SloppyTUITokenUsageSummary) -> String {
        let text = "  " + tokenUsageStatus(summary)
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func contextUsageProgressLine(width: Int, summary: SloppyTUITokenUsageSummary) -> String {
        let barWidth = max(3, min(12, width / 8))
        let bar = contextProgressBar(summary, width: barWidth)
        var details: [String] = []
        if let percent = summary.usagePercent, summary.contextWindowTokens > 0 {
            details.append("\(percent)%")
            details.append("\(formatTokenCountShort(summary.totalTokens))/\(formatTokenCountShort(summary.contextWindowTokens)) tokens")
            if summary.cachedInputTokens > 0 {
                details.append("cached \(formatTokenCountShort(summary.cachedInputTokens))")
            }
            if summary.cachedInputTokens > 0, summary.promptTokens > 0 {
                details.append("uncached \(formatTokenCountShort(summary.uncachedInputTokens))")
            }
            if let freeTokens = summary.freeTokens {
                details.append("free \(formatTokenCountShort(freeTokens))")
            }
        } else {
            details.append("\(formatTokenCountShort(summary.totalTokens)) tokens")
            details.append("context unknown")
        }
        if let costUSD = summary.costUSD {
            details.append(formatUSD(costUSD))
        }

        let text = "  " + muted("context ") + bar + muted(" ") + foreground(details.joined(separator: " · "))
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func exitSummaryLines(_ summary: SloppyTUIExitSummary, width: Int) -> [String] {
        let boxWidth = max(24, min(width, 96))
        let contentWidth = max(1, boxWidth - 4)
        let labelWidth = 18

        func content(_ text: String = "") -> String {
            let fitted = fittedLine(text, width: contentWidth)
            return muted("│ ") + padded(fitted, width: contentWidth) + muted(" │")
        }

        func row(_ label: String, _ value: String) -> String {
            let labelText = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            return content(blue(labelText) + foreground(value))
        }

        func timedRow(_ label: String, seconds: TimeInterval, percent: Double? = nil) -> String {
            let suffix = percent.map { muted(" (\(formatPercent($0)))") } ?? ""
            return row(label, formatDuration(seconds) + suffix)
        }

        var lines = [
            muted("╭") + muted(String(repeating: "─", count: max(0, boxWidth - 2))) + muted("╮"),
            content(),
            content(blue("Agent") + foreground(" powering down. ") + AnsiStyling.rgb(249, 168, 212)("Goodbye!")),
            content(),
            content(AnsiStyling.bold(foreground("Interaction Summary"))),
            row("Session ID:", summary.sessionID),
            row(
                "Tool Calls:",
                "\(summary.toolCallCount) ( ✓ \(summary.successfulToolCallCount) x \(summary.failedToolCallCount) )"
            ),
            row("Success Rate:", formatPercent(summary.successRate)),
            content(),
            content(AnsiStyling.bold(foreground("Performance"))),
            timedRow("Wall Time:", seconds: summary.wallTime),
            timedRow("Agent Active:", seconds: summary.agentActiveTime),
            timedRow("» API Time:", seconds: summary.apiTime, percent: summary.apiTimePercent),
            timedRow("» Tool Time:", seconds: summary.toolTime, percent: summary.toolTimePercent),
        ]

        if summary.canResume {
            lines.append(content())
            lines.append(content(blue("To resume this session: ") + foreground("sloppy -s \(summary.sessionID)")))
        }

        lines.append(content())
        lines.append(muted("╰") + muted(String(repeating: "─", count: max(0, boxWidth - 2))) + muted("╯"))
        return lines
    }

    static func contextUsageMarkdown(_ summary: SloppyTUIContextUsageSummary) -> String {
        let usagePercent = summary.usagePercent.map { "\($0)%" } ?? "unknown"
        let contextLabel = summary.contextWindowLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "unknown context"
            : summary.contextWindowLabel
        let title = summary.modelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? summary.modelID
            : summary.modelTitle
        let grid = contextUsageGrid(summary)
        let totalText = "\(formatTokenCountShort(summary.totalTokens))/\(contextLabel.lowercased()) tokens"
        let promptPercent = summary.promptPercent.map(formatPercent) ?? "n/a"
        let completionPercent = summary.completionPercent.map(formatPercent) ?? "n/a"
        let freeText: String
        if let freeTokens = summary.freeTokens,
           let freePercent = summary.freePercent {
            freeText = "\(formatTokenCountShort(freeTokens)) tokens (\(formatPercent(freePercent)))"
        } else {
            freeText = "unknown"
        }
        let pendingContext = summary.pendingContextAttached ? "yes" : "no"
        let pendingUploads = summary.pendingUploadCount > 0 ? "\(summary.pendingUploadCount)" : "none"
        let semanticDecisionLine: String
        if let usage = summary.semanticDecisionUsage {
            let estimatedMarker = usage.includesEstimatedCost ? "~" : ""
            let details = "\(usage.requestCount) calls · \(formatTokenCountShort(usage.inputTokens)) input tokens · \(estimatedMarker)\(formatUSD(usage.totalCostUSD))"
            semanticDecisionLine = muted("Routing decisions:") + " " + foreground(details)
        } else {
            semanticDecisionLine = muted("Routing decisions:") + " " + foreground("disabled or unused")
        }
        let categoryLines = summary.ledgerCategories.isEmpty
            ? "\(muted("No context ledger yet; using token usage fallback."))"
            : summary.ledgerCategories.map { item in
                "\(muted("-")) \(foreground(item.label)): \(foreground(formatTokenCountShort(item.tokens) + " tokens"))"
            }.joined(separator: "\n")
        let lastTurnLines = [
            "\(muted("-")) Input: \(foreground(formatTokenCountShort(summary.lastTurnInputTokens) + " tokens"))",
            "\(muted("-")) Cached input: \(foreground(formatTokenCountShort(summary.lastTurnCachedInputTokens) + " tokens"))",
            "\(muted("-")) Uncached input: \(foreground(formatTokenCountShort(summary.lastTurnUncachedInputTokens) + " tokens"))",
            "\(muted("-")) Cache creation: \(foreground(formatTokenCountShort(summary.lastTurnCacheCreationInputTokens) + " tokens"))",
            "\(muted("-")) Output: \(foreground(formatTokenCountShort(summary.lastTurnCompletionTokens) + " tokens"))",
            "\(muted("-")) Reasoning: \(foreground(formatTokenCountShort(summary.lastTurnReasoningTokens) + " tokens"))",
        ].joined(separator: "\n")
        let usageVisual = zip(
            grid,
            [
                "\(foreground(title)) \(muted("·")) \(foreground(totalText))",
                "\(muted(summary.modelID)) \(muted("·")) \(foreground(contextLabel)) context",
                "\(foreground("used \(usagePercent)")) \(muted("·")) \(foreground("free \(freeText)"))",
                "",
                "\(blue("●")) Input prompt:  \(foreground(formatTokenCountShort(summary.promptTokens) + " tokens")) \(muted("(\(promptPercent))"))",
                "\(green("●")) Completion: \(foreground(formatTokenCountShort(summary.completionTokens) + " tokens")) \(muted("(\(completionPercent))"))",
                "\(muted("□")) Free space: \(foreground(freeText))",
                "",
                "",
                "",
            ]
        ).map { row, detail in
            detail.isEmpty ? row : row + String(repeating: " ", count: 4) + detail
        }.joined(separator: "\n")

        return """
        ## Context Usage
        ```text
        \(usageVisual)

        \(muted("Context window"))
        \(categoryLines)

        \(muted("Last turn"))
        \(lastTurnLines)

        \(muted("Pending next-message context:")) \(foreground(pendingContext))
        \(muted("Pending uploads:")) \(foreground(pendingUploads))
        \(semanticDecisionLine)
        ```

        Attach workspace context with `/context changes` or `/context diff`.
        """
    }

    private static func contextProgressBar(_ summary: SloppyTUITokenUsageSummary, width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        guard summary.contextWindowTokens > 0 else {
            return muted("[\(String(repeating: "-", count: width))]")
        }

        var filled = min(
            width,
            max(0, Int((Double(summary.totalTokens) / Double(summary.contextWindowTokens) * Double(width)).rounded()))
        )
        if summary.totalTokens > 0, filled == 0 {
            filled = 1
        }
        let empty = max(0, width - filled)
        let content = String(repeating: "=", count: filled) + String(repeating: "-", count: empty)
        let percent = summary.usagePercent ?? 0
        let style: (String) -> String
        if percent >= 90 {
            style = red
        } else if percent >= 70 {
            style = orange
        } else if percent >= 50 {
            style = yellow
        } else {
            style = green
        }
        return muted("[") + style(content) + muted("]")
    }

    private static func contextIndicator(
        model: String,
        summary: SloppyTUITokenUsageSummary,
        lastTurnUsage: TokenUsage?,
        runElapsed: TimeInterval?,
        stageElapsed: TimeInterval?
    ) -> String {
        var parts: [String] = [foreground(model)]
        if summary.contextWindowTokens > 0 {
            let contextTokens = lastTurnUsage.map { $0.prompt + $0.completion } ?? summary.totalTokens
            let contextPercent = min(100, Int(((Double(contextTokens) / Double(summary.contextWindowTokens)) * 100).rounded()))
            parts.append(foreground("ctx \(formatTokenCountCompact(contextTokens))/\(formatTokenCountCompact(summary.contextWindowTokens))"))
            parts.append(contextIndicatorBar(tokens: contextTokens, contextWindowTokens: summary.contextWindowTokens, percent: contextPercent, width: 10) + muted(" ") + contextIndicatorPercent(contextPercent))
            if summary.totalTokens > 0 {
                parts.append(muted("spent \(formatTokenCountCompact(summary.totalTokens))"))
            }
        } else {
            if let lastTurnUsage {
                parts.append(foreground("last \(formatTokenCountCompact(lastTurnUsage.prompt))↑/\(formatTokenCountCompact(lastTurnUsage.completion))↓"))
            }
            parts.append(foreground("spent \(formatTokenCountCompact(summary.totalTokens))"))
            parts.append(muted("context unknown"))
        }
        if let runElapsed {
            parts.append(foreground(formatCompactDuration(runElapsed)))
        }
        if let stageElapsed {
            parts.append(yellow("⏱ \(formatCompactDuration(stageElapsed))"))
        }
        if let costUSD = summary.costUSD {
            parts.append(muted(formatUSD(costUSD)))
        }
        return parts.joined(separator: muted(" │ "))
    }

    private static func contextIndicatorBar(_ summary: SloppyTUITokenUsageSummary, width: Int) -> String {
        let percent = summary.usagePercent ?? 0
        return contextIndicatorBar(
            tokens: summary.totalTokens,
            contextWindowTokens: summary.contextWindowTokens,
            percent: percent,
            width: width
        )
    }

    private static func contextIndicatorBar(tokens: Int, contextWindowTokens: Int, percent: Int, width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        guard contextWindowTokens > 0 else {
            return muted("[\(String(repeating: "░", count: width))]")
        }

        var filled = min(
            width,
            max(0, Int((Double(tokens) / Double(contextWindowTokens) * Double(width)).rounded()))
        )
        if tokens > 0, filled == 0 {
            filled = 1
        }
        let empty = max(0, width - filled)
        let content = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        return muted("[") + contextIndicatorPercentStyle(percent)(content) + muted("]")
    }

    private static func contextIndicatorPercent(_ percent: Int) -> String {
        contextIndicatorPercentStyle(percent)("\(percent)%")
    }

    private static func contextIndicatorPercentStyle(_ percent: Int) -> (String) -> String {
        if percent >= 90 {
            return red
        }
        if percent >= 70 {
            return orange
        }
        if percent >= 50 {
            return yellow
        }
        return green
    }

    static func highlightedComposerLines(_ lines: [String], shellMode: Bool = false) -> [String] {
        var borderCount = 0
        var isContinuingProjectPath = false
        return lines.map { line in
            if isEditorBorderLine(line) {
                borderCount += 1
                isContinuingProjectPath = false
                if shellMode {
                    return red(strippingANSI(from: line))
                }
                return line
            }
            guard borderCount == 1 else {
                return line
            }
            let highlighted = highlightedComposerSyntax(
                in: line,
                isContinuingProjectPath: isContinuingProjectPath
            )
            isContinuingProjectPath = highlighted.isContinuingProjectPath
            return highlighted.line
        }
    }

    static func sessionListComposerPlaceholderLines(_ lines: [String], width: Int) -> [String] {
        guard lines.count >= 3 else { return lines }
        return lines.enumerated().map { index, line in
            guard index == 1 else { return line }
            return muted(fittedLine(" describe a task for a new session", width: width))
        }
    }

    private static func modeTitle(_ mode: AgentChatMode, frame: Int = 0) -> String {
        switch mode {
        case .ask:
            return green(mode.title)
        case .build:
            return blue(mode.title)
        case .plan:
            return accentBright(mode.title)
        case .debug:
            return yellow(mode.title)
        case .auto:
            return rainbow(mode.title, frame: frame)
        }
    }

    static func compactPickerDescription(_ model: String) -> String {
        compactModel(model)
    }

    static func modelPickerDescription(_ model: ProviderModelOption) -> String {
        var parts: [String] = []
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != model.id {
            parts.append(title)
        }
        if let contextWindow = model.contextWindow?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contextWindow.isEmpty {
            parts.append(contextWindow)
        }
        if !model.capabilities.isEmpty {
            parts.append(model.capabilities.joined(separator: ", "))
        }
        if parts.isEmpty {
            return compactModel(model.id)
        }
        return parts.joined(separator: " · ")
    }

    static func sessionDisplayTitle(_ session: AgentSessionSummary) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = sessionPreviewText(session)
        let lowercasedTitle = title.lowercased()
        let isDefaultTitle = lowercasedTitle.hasPrefix("session session-")
        let isLegacyTUITitle = lowercasedTitle == "tui chat"
        if (isDefaultTitle || isLegacyTUITitle), !preview.isEmpty {
            return truncateEnd(preview, maxWidth: 80)
        }
        if !title.isEmpty {
            return title
        }
        if !preview.isEmpty {
            return truncateEnd(preview, maxWidth: 80)
        }
        return "Session"
    }

    static func sessionHeaderTitle(_ session: AgentSessionSummary) -> String {
        "\(sessionDisplayTitle(session)) (\(shortID(session.id)))"
    }

    static func sessionPickerDescription(_ session: AgentSessionSummary) -> String {
        let preview = sessionPreviewText(session)
        let detail = preview.isEmpty ? "\(session.messageCount) messages" : preview
        return "\(relativeTime(session.updatedAt)) · \(shortID(session.id)) · \(detail)"
    }

    private static func sessionPreviewText(_ session: AgentSessionSummary) -> String {
        let preview = session.lastMessagePreview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        return preview.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func waitingIndicator(frame: Int, word: String, tokenUsage: TokenUsage? = nil) -> String {
        let spinner = waitingFrames[frame % waitingFrames.count]
        let usage = tokenUsage.map { " \(turnTokenUsageBadge($0))" } ?? ""
        return muted("\(spinner) ") + shimmeringText(word, frame: frame) + muted(usage)
    }

    static func shimmeringText(_ text: String, frame: Int) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return text }

        let shoulder = activeTheme.accent.blended(with: activeTheme.accentBright, amount: 0.55)
        let period = characters.count + 4
        let normalizedFrame = ((frame % period) + period) % period
        let highlightCenter = normalizedFrame - 2

        return characters.enumerated().map { index, character in
            let distance = abs(index - highlightCenter)
            let text = String(character)
            switch distance {
            case 0:
                return accentBright(text)
            case 1:
                return shoulder.foregroundStyle(text)
            default:
                return accent(text)
            }
        }.joined()
    }

    static func waitingWord(seed: String) -> String {
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        return thinkingWords[value % thinkingWords.count]
    }

    static func userMessageLines(_ text: String, width: Int) -> [String] {
        let prefixWidth = VisibleWidth.measure("› ")
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }

        let lines = rawLines.isEmpty ? [""] : rawLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? "› " : "  "
            return applyBackground(
                blockLeftPadding + muted(prefix) + highlightedMessageReferences(in: line),
                width: width,
                background: userMessageBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: userMessageBackground)
    }

    static func queuedMessageLines(_ message: SloppyTUIQueuedMessage, width: Int) -> [String] {
        let attachmentSuffix = message.uploads.isEmpty ? "" : " · attachments: \(message.uploads.count)"
        let contextSuffix = message.context == nil ? "" : " · context"
        let header = "queued · ctrl+b cancels" + attachmentSuffix + contextSuffix
        let prefixWidth = VisibleWidth.measure("⏳ ")
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = message.displayText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }
        let bodyLines = rawLines.isEmpty ? [""] : rawLines
        let lines = [header] + bodyLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? "⏳ " : "  "
            let styled = index == 0 ? muted(line) : highlightedMessageReferences(in: line)
            return applyBackground(
                blockLeftPadding + muted(prefix) + styled,
                width: width,
                background: userMessageBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: userMessageBackground)
    }

    static func thinkingLines(_ text: String, width: Int) -> [String] {
        let header = "thought "
        let prefixWidth = VisibleWidth.measure(header)
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }
        let lines = rawLines.isEmpty ? [""] : rawLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? header : String(repeating: " ", count: prefixWidth)
            return applyBackground(
                blockLeftPadding + muted(prefix) + foreground(line),
                width: width,
                background: thinkingBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: thinkingBackground)
    }

    static func buildProgressLines(_ progress: AgentBuildProgressEvent, width: Int) -> [String] {
        let title = " " + accentBright(AnsiStyling.bold(progress.title.trimmingCharacters(in: .whitespacesAndNewlines)))
        var lines = [fittedLine(title, width: width)]

        for item in progress.items {
            let marker = buildProgressMarker(for: item.status)
            let itemPrefix = "  \(marker.text) "
            let detailPrefix = "      "
            let itemStyle = buildProgressStyle(for: item.status)
            lines.append(contentsOf: wrappedBuildProgressLines(
                item.title,
                firstPrefix: itemPrefix,
                continuationPrefix: detailPrefix,
                width: width,
                style: { itemStyle(AnsiStyling.bold($0)) },
                prefixStyle: marker.style
            ))
            lines.append(contentsOf: wrappedBuildProgressLines(
                "DoD: \(item.definitionOfDone)",
                firstPrefix: detailPrefix,
                continuationPrefix: detailPrefix,
                width: width,
                style: styledBuildProgressDetail
            ))
            if let details = item.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                lines.append(contentsOf: wrappedBuildProgressLines(
                    "Notes: \(details)",
                    firstPrefix: detailPrefix,
                    continuationPrefix: detailPrefix,
                    width: width,
                    style: styledBuildProgressDetail
                ))
            }
        }

        return lines
    }

    static func toolCallLine(tool: String, reason: String?, summary: String?, width: Int) -> String {
        let summaryText = summary.map(singleLineDisplay)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = reason.map(singleLineDisplay)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonText = suffix?.isEmpty == false ? muted(" · \(suffix!)") : ""
        let label = summaryText?.isEmpty == false ? summaryText! : tool
        let line = fittedPaddedBlockLine(blue("✱") + foreground(" \(label)") + reasonText, width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolResultLine(tool: String, ok: Bool, error: String?, durationMs: Int?, width: Int) -> String {
        let status = ok ? green("done") : red("failed")
        let duration = durationMs.map { muted(" · \($0)ms") } ?? ""
        let errorText = error.map(singleLineDisplay)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = errorText?.isEmpty == false ? muted(" · \(errorText!)") : ""
        let line = fittedPaddedBlockLine(status + foreground(" \(tool)") + duration + suffix, width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolOverflowLine(hiddenCount: Int, width: Int) -> String {
        let suffix = hiddenCount == 1 ? "1 tool event" : "\(hiddenCount) tool events"
        let line = fittedPaddedBlockLine(muted("... +\(suffix) (ctrl+o to expand)"), width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolPaddingLine(width: Int) -> String {
        backgroundPaddingLine(width: width, background: toolBackground)
    }

    static func subSessionLine(
        title: String,
        childSessionId: String,
        status: SloppyTUISubSessionStatus,
        frame: Int,
        width: Int
    ) -> String {
        let statusText: String
        switch status {
        case .starting:
            statusText = muted(waitingFrames[frame % waitingFrames.count] + " ") + accentBright("starting")
        case .running(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? detail ?? "working" : "working"
            statusText = muted(waitingFrames[frame % waitingFrames.count] + " ") + accentBright(text)
        case .waiting(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? "waiting: \(detail ?? "")" : "waiting"
            statusText = yellow(text)
        case .done:
            statusText = green("done")
        case .interrupted(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? "stopped: \(detail ?? "")" : "stopped"
            statusText = red(text)
        }
        let line = fittedLine(
            blockLeftPadding
                + green("subagent")
                + foreground(" \(title)")
                + muted(" · ")
                + statusText
                + muted(" · \(shortID(childSessionId)) · ctrl+g to enter"),
            width: paddedBlockLineWidth(width)
        )
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func memoryCheckpointLine(_ checkpoint: AgentMemoryCheckpointEvent, frame: Int, width: Int) -> String {
        let statusText: String
        switch checkpoint.status {
        case .started:
            statusText = muted(waitingFrames[frame % waitingFrames.count] + " ") + accentBright("compacting context")
        case .succeeded:
            statusText = green(checkpoint.message)
        case .failed:
            statusText = red(checkpoint.message)
        }
        let reason = checkpoint.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonText = reason?.isEmpty == false ? muted(" · \(reason ?? "")") : ""
        let line = fittedLine(
            blockLeftPadding
                + green("compact")
                + muted(" · ")
                + statusText
                + reasonText,
            width: paddedBlockLineWidth(width)
        )
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func transcriptHintLine(expanded: Bool, childSessionCount: Int, width: Int) -> String {
        let mode = expanded ? "detailed transcript" : "compact transcript"
        let childHint = childSessionCount > 0 ? " · ctrl+g enters latest subagent · /subagents picks" : ""
        let line = fittedLine(" " + muted("\(mode) · ctrl+o toggles\(childHint)"), width: width)
        return applyPanelBackground(padded(line, width: width), width: width)
    }

    static func attachmentLine(name: String, mimeType: String, sizeBytes: Int, width: Int) -> String {
        let size = formattedBytes(sizeBytes)
        let line = fittedPaddedBlockLine(green("attached") + foreground(" ") + yellow(name) + muted("  \(mimeType), \(size)"), width: width)
        return applyBackground(padded(line, width: width), width: width, background: attachmentBackground)
    }

    static func diffLines(_ diff: String, width: Int) -> [String] {
        let contentWidth = max(1, width - 2)
        return diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let line = truncateEnd(String(rawLine), maxWidth: contentWidth)
                return " " + coloredDiffLine(line)
            }
    }

    static func workspaceDiffHeaderLine(
        branch: String,
        linesAdded: Int,
        linesDeleted: Int,
        truncated: Bool,
        width: Int
    ) -> String {
        let truncatedText = truncated ? muted(" · truncated") : ""
        let line = fittedPaddedBlockLine(
            green("Patched")
                + foreground(" \(branch)")
                + muted(" · ")
                + green("+\(linesAdded)")
                + muted(" ")
                + red("-\(linesDeleted)")
                + truncatedText,
            width: width
        )
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    private static func coloredDiffLine(_ line: String) -> String {
        if line.hasPrefix("diff --git") {
            return accentBright(line)
        }
        if line.hasPrefix("index ") || line.hasPrefix("\\ No newline") {
            return muted(line)
        }
        if line.hasPrefix("@@") {
            return blue(line)
        }
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return yellow(line)
        }
        if line.hasPrefix("+") {
            return green(line)
        }
        if line.hasPrefix("-") {
            return red(line)
        }
        return foreground(line)
    }

    static func commandPaletteLines(
        width: Int,
        commands: [SloppyTUISlashCommand],
        selectedIndex: Int,
        maxVisible: Int
    ) -> [String] {
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let visibleCount = max(1, min(maxVisible, commands.count))
        let start = max(0, min(selectedIndex - visibleCount / 2, commands.count - visibleCount))
        let end = min(commands.count, start + visibleCount)
        var lines: [String] = []

        for index in start..<end {
            let command = commands[index]
            let name = command.invocationPrefix + command.name
            let description = command.description ?? ""
            let raw: String
            if paletteWidth < 32 {
                raw = "  " + truncateEnd(name, maxWidth: max(1, paletteWidth - 2))
            } else {
                let nameWidth = max(10, min(22, paletteWidth / 3))
                let descWidth = max(1, paletteWidth - nameWidth - 4)
                raw = "  " + truncateEnd(name, maxWidth: nameWidth).padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " + truncateEnd(description, maxWidth: descWidth)
            }
            let line = padded(raw, width: paletteWidth)
            if index == selectedIndex {
                lines.append(indent + selectedLine(line))
            } else {
                lines.append(indent + applyPanelBackground(foreground(line), width: paletteWidth))
            }
        }
        if commands.count > visibleCount {
            let info = "  " + muted("\(selectedIndex + 1)/\(commands.count)")
            lines.append(indent + applyPanelBackground(padded(info, width: paletteWidth), width: paletteWidth))
        }
        return lines
    }

    static func reasoningEffortSliderLines(
        width: Int,
        efforts: [ReasoningEffort],
        selectedIndex: Int
    ) -> [String] {
        guard !efforts.isEmpty else { return [] }
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let innerWidth = max(1, paletteWidth - 4)
        let sliderWidth = max(1, min(innerWidth, max(24, efforts.count * 12 - 1)))
        let sliderLeft = max(0, (paletteWidth - sliderWidth) / 2)
        let boundedIndex = max(0, min(selectedIndex, efforts.count - 1))

        func panelLine(_ content: String) -> String {
            let line = String(repeating: " ", count: sliderLeft) + fittedLine(content, width: sliderWidth)
            return indent + applyPanelBackground(padded(line, width: paletteWidth), width: paletteWidth)
        }

        let labels = efforts.map(\.rawValue)
        let hint = "←/→ to change effort · Enter to confirm"
        return [
            panelLine(reasoningEffortAxisLine(width: sliderWidth)),
            panelLine(reasoningEffortTrackLine(width: sliderWidth, count: efforts.count, selectedIndex: boundedIndex)),
            panelLine(reasoningEffortLabelLine(labels: labels, selectedIndex: boundedIndex, width: sliderWidth)),
            indent + applyPanelBackground(padded("", width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("  " + muted(hint), width: paletteWidth), width: paletteWidth),
        ]
    }

    static func scrollbackModeSliderLines(
        width: Int,
        modes: [SloppyTUIScrollbackMode],
        selectedIndex: Int,
        lineLimit: Int
    ) -> [String] {
        guard !modes.isEmpty else { return [] }
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let innerWidth = max(1, paletteWidth - 4)
        let sliderWidth = max(1, min(innerWidth, max(34, modes.count * 13 - 1)))
        let sliderLeft = max(0, (paletteWidth - sliderWidth) / 2)
        let boundedIndex = max(0, min(selectedIndex, modes.count - 1))
        let selectedMode = modes[boundedIndex]

        func panelLine(_ content: String) -> String {
            let line = String(repeating: " ", count: sliderLeft) + fittedLine(content, width: sliderWidth)
            return indent + applyPanelBackground(padded(line, width: paletteWidth), width: paletteWidth)
        }

        let labels = modes.map(\.rawValue)
        let hint = "←/→ to change scrollback · Enter to confirm"
        return [
            panelLine(scrollbackModeAxisLine(width: sliderWidth)),
            panelLine(reasoningEffortTrackLine(width: sliderWidth, count: modes.count, selectedIndex: boundedIndex)),
            panelLine(reasoningEffortLabelLine(labels: labels, selectedIndex: boundedIndex, width: sliderWidth)),
            panelLine(muted(scrollbackModeDescription(selectedMode, lineLimit: lineLimit))),
            indent + applyPanelBackground(padded("", width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("  " + muted(hint), width: paletteWidth), width: paletteWidth),
        ]
    }

    static func addDirectoryInputLines(width: Int, value: String) -> [String] {
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let innerWidth = max(1, paletteWidth - 4)
        let fieldWidth = max(4, min(innerWidth, 72))
        let fieldLeft = max(0, (paletteWidth - fieldWidth) / 2)

        func panelLine(_ content: String) -> String {
            let line = String(repeating: " ", count: fieldLeft) + fittedLine(content, width: fieldWidth)
            return indent + applyPanelBackground(padded(line, width: paletteWidth), width: paletteWidth)
        }

        let displayedValue = value.isEmpty ? muted("Directory path...") : foreground(value)
        let fieldInnerWidth = max(1, fieldWidth - 4)
        let top = "┌" + String(repeating: "─", count: max(0, fieldWidth - 2)) + "┐"
        let bottom = "└" + String(repeating: "─", count: max(0, fieldWidth - 2)) + "┘"
        let field = "│ " + padded(fittedLine(displayedValue, width: fieldInnerWidth), width: fieldInnerWidth) + " │"
        return [
            indent + applyPanelBackground(padded("  " + foreground(AnsiStyling.bold("Add directory to workspace")), width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("  " + muted("Sloppy will be able to read files in this directory and edit when allowed."), width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("", width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("  " + foreground("Enter the path to the directory:"), width: paletteWidth), width: paletteWidth),
            panelLine(top),
            panelLine(field),
            panelLine(bottom),
            indent + applyPanelBackground(padded("", width: paletteWidth), width: paletteWidth),
            indent + applyPanelBackground(padded("  " + muted("Tab to complete · Enter to add · Esc to cancel"), width: paletteWidth), width: paletteWidth),
        ]
    }

    private static func reasoningEffortAxisLine(width: Int) -> String {
        let left = "Speed"
        let right = "Intelligence"
        let leftWidth = VisibleWidth.measure(left)
        let rightWidth = VisibleWidth.measure(right)
        guard leftWidth + rightWidth + 1 <= width else {
            return center(fittedLine(left + " / " + right, width: width), width: width)
        }
        let gap = width - leftWidth - rightWidth
        return foreground(left) + String(repeating: " ", count: gap) + foreground(right)
    }

    private static func scrollbackModeAxisLine(width: Int) -> String {
        let left = "Native"
        let right = "Viewport"
        let leftWidth = VisibleWidth.measure(left)
        let rightWidth = VisibleWidth.measure(right)
        guard leftWidth + rightWidth + 1 <= width else {
            return center(fittedLine(left + " / " + right, width: width), width: width)
        }
        let gap = width - leftWidth - rightWidth
        return foreground(left) + String(repeating: " ", count: gap) + foreground(right)
    }

    private static func scrollbackModeDescription(_ mode: SloppyTUIScrollbackMode, lineLimit: Int) -> String {
        switch mode {
        case .auto:
            return "Native until \(lineLimit) lines, then viewport"
        case .viewport:
            return "Always use fast internal viewport scrolling"
        case .limited:
            return "Native scrollback capped to \(lineLimit) lines"
        case .full:
            return "Full native scrollback without a render cap"
        }
    }

    private static func reasoningEffortTrackLine(width: Int, count: Int, selectedIndex: Int) -> String {
        guard width > 1 else { return foreground("▲") }
        let position = count <= 1
            ? width / 2
            : Int((Double(selectedIndex) * Double(width - 1) / Double(count - 1)).rounded())
        let left = String(repeating: "─", count: max(0, position))
        let right = String(repeating: "─", count: max(0, width - position - 1))
        return muted(left) + foreground("▲") + muted(right)
    }

    private static func reasoningEffortLabelLine(labels: [String], selectedIndex: Int, width: Int) -> String {
        let minimumWidth = labels.reduce(0) { $0 + VisibleWidth.measure($1) } + max(0, labels.count - 1)
        guard minimumWidth <= width else {
            let compact = labels.enumerated().map { index, label in
                index == selectedIndex ? green(AnsiStyling.bold(label)) : muted(label)
            }.joined(separator: " ")
            return fittedLine(compact, width: width)
        }

        var starts = labels.enumerated().map { index, label -> Int in
            let position = labels.count <= 1
                ? width / 2
                : Int((Double(index) * Double(width - 1) / Double(labels.count - 1)).rounded())
            return max(0, position - (VisibleWidth.measure(label) / 2))
        }

        for index in starts.indices.dropFirst() {
            let previousEnd = starts[index - 1] + VisibleWidth.measure(labels[index - 1])
            starts[index] = max(starts[index], previousEnd + 1)
        }
        if let lastStart = starts.last,
           let lastLabel = labels.last {
            let overflow = lastStart + VisibleWidth.measure(lastLabel) - width
            if overflow > 0 {
                starts = starts.map { max(0, $0 - overflow) }
            }
        }

        var line = ""
        var cursor = 0
        for (index, label) in labels.enumerated() {
            let start = max(cursor, starts[index])
            if start > cursor {
                line += String(repeating: " ", count: start - cursor)
            }
            line += index == selectedIndex ? green(AnsiStyling.bold(label)) : muted(label)
            cursor = start + VisibleWidth.measure(label)
        }
        if cursor < width {
            line += String(repeating: " ", count: width - cursor)
        }
        return line
    }

    static func quickReferenceLines(
        width: Int,
        shortcuts: [SloppyTUIShortcutDescriptor] = SloppyTUIShortcutCatalog.all
    ) -> [String] {
        let contentWidth = max(1, min(max(1, width), 120))
        var lines = ["## Quick reference", ""]

        guard !shortcuts.isEmpty else {
            return lines
        }

        let columns: Int
        if contentWidth >= 104 {
            columns = 3
        } else if contentWidth >= 68 {
            columns = 2
        } else {
            columns = 1
        }

        if columns == 1 {
            lines += shortcuts.map { shortcut in
                fittedLine("- `\(shortcut.key)` \(shortcut.description)", width: contentWidth)
            }
            return lines
        }

        let gap = 2
        let columnWidth = max(1, (contentWidth - ((columns - 1) * gap)) / columns)
        let rowCount = Int(ceil(Double(shortcuts.count) / Double(columns)))
        for row in 0..<rowCount {
            var rowText = ""
            for column in 0..<columns {
                let index = row + (column * rowCount)
                guard shortcuts.indices.contains(index) else {
                    continue
                }

                let raw = "`\(shortcuts[index].key)` \(shortcuts[index].description)"
                let cell = fittedLine(raw, width: columnWidth)
                if column > 0 {
                    rowText += String(repeating: " ", count: gap)
                }
                rowText += padded(cell, width: columnWidth)
            }
            lines.append(fittedLine(rowText, width: contentWidth))
        }

        return lines
    }

    static func pickerLines(width: Int, picker: SloppyTUIPicker, maxVisible: Int) -> [String] {
        let visibleLimit = max(1, maxVisible)
        let layout = pickerLayout(width: width, picker: picker, maxVisible: visibleLimit)
        let paletteWidth = layout.paletteWidth
        let indent = String(repeating: " ", count: layout.left)
        let visibleCount = max(1, min(visibleLimit, picker.items.count))
        let start = max(0, min(picker.selectedIndex - visibleCount / 2, picker.items.count - visibleCount))
        let end = min(picker.items.count, start + visibleCount)
        let prompt: String
        if picker.kind == .toolApproval {
            prompt = "Enter apply · Esc deny"
        } else if picker.supportsSearch {
            prompt = "type search · Enter apply · Esc cancel"
        } else {
            prompt = "Enter apply · Esc cancel"
        }
        var lines = [
            indent + padded("  " + foreground(AnsiStyling.bold(picker.title)) + "  " + muted(prompt), width: paletteWidth),
        ]
        if picker.supportsSearch {
            let query = picker.searchQuery.isEmpty ? muted("type to filter") : accentBright(picker.searchQuery)
            let count = muted("\(picker.items.count)/\(picker.totalItemCount)")
            lines.append(indent + padded("  " + muted("Search: ") + query + muted("  matches ") + count, width: paletteWidth))
        }

        let groupCounts = pickerGroupCounts(picker.items)
        var lastGroup: String?
        var bodyRows = 0
        for index in start..<end {
            let item = picker.items[index]
            if let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines),
               !group.isEmpty,
               group != lastGroup {
                let suffix = groupCounts[group].map { " (\($0))" } ?? ""
                lines.append(indent + padded("  " + muted(group + suffix), width: paletteWidth))
                bodyRows += 1
                lastGroup = group
            }
            let raw: String
            if picker.kind == .projectFile {
                raw = projectFilePickerLine(item: item, width: paletteWidth, styled: index != picker.selectedIndex)
            } else if paletteWidth < 32 {
                let marker = item.isCurrent ? "✓ " : "  "
                raw = "  " + marker + truncateEnd(item.label, maxWidth: max(1, paletteWidth - 4))
            } else {
                let nameWidth = max(14, min(42, paletteWidth / 2))
                let descWidth = max(1, paletteWidth - nameWidth - 6)
                let marker = item.isCurrent ? "✓ " : "  "
                let label = truncateEnd(item.label, maxWidth: nameWidth).padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                raw = "  " + marker + label + "  " + truncateEnd(item.description ?? "", maxWidth: descWidth)
            }
            let line = padded(raw, width: paletteWidth)
            if index == picker.selectedIndex {
                lines.append(indent + selectedLine(line))
            } else {
                lines.append(indent + foreground(line))
            }
            bodyRows += 1
        }
        if picker.items.isEmpty, picker.supportsSearch {
            lines.append(indent + padded("  " + muted("No matching models"), width: paletteWidth))
            bodyRows += 1
        }
        if picker.supportsSearch {
            let targetRows = visibleLimit * 2
            while bodyRows < targetRows {
                lines.append(indent + padded("", width: paletteWidth))
                bodyRows += 1
            }
        }
        if picker.items.count > visibleCount {
            let info = "  " + muted("\(picker.selectedIndex + 1)/\(picker.items.count)")
            lines.append(indent + padded(info, width: paletteWidth))
        }
        return lines
    }

    struct PickerLayout: Equatable {
        var paletteWidth: Int
        var left: Int
    }

    static func pickerLayout(width: Int, picker: SloppyTUIPicker, maxVisible: Int) -> PickerLayout {
        let availableWidth = max(1, width - 4)
        let maxPaletteWidth = max(1, min(availableWidth, 96))
        let usesStableCenteredLayout = picker.kind == .model || picker.totalItemCount > max(1, maxVisible)
        if usesStableCenteredLayout {
            return PickerLayout(
                paletteWidth: maxPaletteWidth,
                left: max(0, (width - maxPaletteWidth) / 2)
            )
        }

        let naturalWidth = pickerNaturalWidth(picker: picker)
        let paletteWidth = max(1, min(maxPaletteWidth, max(44, naturalWidth)))
        let left = width > paletteWidth ? min(2, max(0, width - paletteWidth)) : 0
        return PickerLayout(paletteWidth: paletteWidth, left: left)
    }

    private static func pickerNaturalWidth(picker: SloppyTUIPicker) -> Int {
        let prompt: String
        if picker.kind == .toolApproval {
            prompt = "Enter apply · Esc deny"
        } else if picker.supportsSearch {
            prompt = "type search · Enter apply · Esc cancel"
        } else {
            prompt = "Enter apply · Esc cancel"
        }

        var width = VisibleWidth.measure("  " + picker.title + "  " + prompt)
        if picker.supportsSearch {
            width = max(width, VisibleWidth.measure("  Search: type to filter  matches \(picker.totalItemCount)/\(picker.totalItemCount)"))
        }

        let sourceItems = picker.allItems ?? picker.items
        for item in sourceItems {
            if let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines),
               !group.isEmpty {
                width = max(width, VisibleWidth.measure("  " + group + " (\(sourceItems.filter { $0.group == item.group }.count))"))
            }

            let marker = item.isCurrent ? "✓ " : "  "
            let description = item.description ?? ""
            width = max(width, VisibleWidth.measure("  " + marker + item.label + "  " + description))
        }

        return width
    }

    static func sessionListLines(
        width: Int,
        height: Int,
        entries: [SloppyTUISessionListEntry],
        selectedIndex: Int,
        projectName: String,
        agentName: String
    ) -> [String] {
        let contentWidth = max(1, width)
        let grouped = Dictionary(grouping: entries, by: \.section)
        var lines: [String] = []
        lines.append(sessionListPanelRow("  " + accentBright(AnsiStyling.bold("Sessions")) + muted("  \(projectName) · \(agentName)"), width: contentWidth))
        lines.append(sessionListPanelRow("  " + muted("\(grouped[.waitingInput]?.count ?? 0) waiting · \(grouped[.working]?.count ?? 0) working · \(grouped[.completed]?.count ?? 0) completed"), width: contentWidth))
        lines.append(sessionListPanelRow("", width: contentWidth))

        var rowIndex = 0
        for section in SloppyTUISessionListSection.allCases {
            let sectionEntries = entries.filter { $0.section == section }
            guard !sectionEntries.isEmpty else { continue }
            lines.append(sessionListPanelRow("  " + foreground(AnsiStyling.bold(section.rawValue)), width: contentWidth))
            for entry in sectionEntries {
                let line = sessionListEntryLine(entry, width: contentWidth)
                if rowIndex == selectedIndex {
                    lines.append(selectedLine(sessionListPanelText(line, width: contentWidth)))
                } else {
                    lines.append(sessionListPanelRow(foreground(line), width: contentWidth))
                }
                rowIndex += 1
            }
            lines.append(sessionListPanelRow("", width: contentWidth))
        }

        if entries.isEmpty {
            lines.append(sessionListPanelRow("  " + muted("No TUI sessions yet."), width: contentWidth))
            lines.append(sessionListPanelRow("", width: contentWidth))
        }

        lines.append(sessionListHintRow("type below to create · enter to open", width: contentWidth))
        lines.append(sessionListHintRow("space to reply · ctrl+x to hide · ? for shortcuts", width: contentWidth))

        if lines.count > height {
            return Array(lines.prefix(max(0, height)))
        }
        if lines.count < height {
            lines += Array(repeating: sessionListPanelRow("", width: contentWidth), count: height - lines.count)
        }
        return lines
    }

    private static func sessionListPanelRow(_ text: String, width: Int) -> String {
        applyPanelBackground(sessionListPanelText(text, width: width), width: width)
    }

    private static func sessionListHintRow(_ text: String, width: Int) -> String {
        let indented = "  " + muted(text)
        if VisibleWidth.measure(indented) <= width {
            return sessionListPanelRow(indented, width: width)
        }
        return sessionListPanelRow(muted(text), width: width)
    }

    private static func sessionListPanelText(_ text: String, width: Int) -> String {
        padded(fittedLine(text, width: width), width: width)
    }

    private static func sessionListEntryLine(_ entry: SloppyTUISessionListEntry, width: Int) -> String {
        let pin = entry.tracked.pinned ? "* " : "  "
        let status: String
        switch entry.section {
        case .waitingInput:
            status = yellow("?")
        case .working:
            status = accentBright("~")
        case .completed:
            status = green("·")
        }
        let flags = entry.tracked.background ? muted(" bg") : ""
        let age = muted(relativeTime(entry.summary.updatedAt))
        let title = sessionDisplayTitle(entry.summary)
        let prefix = "  " + pin + status + " "
        let suffix = flags + muted("  ") + age
        let reserved = VisibleWidth.measure(prefix) + VisibleWidth.measure(suffix) + 2
        let available = max(8, width - reserved)
        let nameWidth = max(8, min(available / 2, 34))
        let detailWidth = max(1, available - nameWidth)
        let name = truncateEnd(title, maxWidth: nameWidth)
            .padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let detail = truncateEnd(entry.detail.replacingOccurrences(of: "\n", with: " "), maxWidth: detailWidth)
        return prefix + foreground(name) + muted("  ") + muted(detail) + suffix
    }

    private static func pickerGroupCounts(_ items: [SloppyTUIPickerItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !group.isEmpty
            else {
                continue
            }
            counts[group, default: 0] += 1
        }
        return counts
    }

    private static func projectFilePickerLine(item: SloppyTUIPickerItem, width: Int, styled: Bool) -> String {
        let isDirectory = item.value.hasSuffix("/")
        let icon = isDirectory ? "▣" : "◇"
        let name = item.label
        let parent = item.description ?? ""
        let prefix = "  \(icon) "
        let gap = parent.isEmpty ? "" : "  "
        let reserved = VisibleWidth.measure(prefix + gap)
        let available = max(1, width - reserved)

        if parent.isEmpty || available < 28 {
            let text = prefix + truncateEnd(name, maxWidth: max(1, width - VisibleWidth.measure(prefix)))
            return styled ? foreground(text) : text
        }

        let minimumNameWidth = min(max(12, width / 4), max(1, available))
        let idealNameWidth = min(max(minimumNameWidth, VisibleWidth.measure(name)), max(1, available / 2))
        let parentWidth = max(1, available - idealNameWidth)
        let renderedName = truncateEnd(name, maxWidth: idealNameWidth)
            .padding(toLength: idealNameWidth, withPad: " ", startingAt: 0)
        let renderedParent = truncateStart(parent, maxWidth: parentWidth)

        if styled {
            return foreground(prefix + renderedName + gap) + muted(renderedParent)
        }
        return prefix + renderedName + gap + renderedParent
    }

    static func overlayModal(
        base: [String],
        width: Int,
        title: String,
        subtitle: String,
        content: [String],
        maxWidth: Int
    ) -> [String] {
        let dimmed = base.map { AnsiStyling.dim($0) }
        let modalWidth = max(1, min(maxWidth, max(1, width - 8)))
        let left = max(0, (width - modalWidth) / 2)
        let top = max(1, (dimmed.count - content.count - 4) / 2)
        let indent = String(repeating: " ", count: left)
        var modal: [String] = []
        let titleText = truncateEnd(title, maxWidth: max(1, modalWidth / 2))
        let subtitleText = modalWidth > 36 ? truncateEnd(subtitle, maxWidth: max(1, modalWidth / 2)) : ""
        let gap = max(1, modalWidth - 4 - VisibleWidth.measure(titleText) - VisibleWidth.measure(subtitleText))
        modal.append(applyPanelBackground(padded("  " + foreground(AnsiStyling.bold(titleText)) + String(repeating: " ", count: gap) + muted(subtitleText) + "  ", width: modalWidth), width: modalWidth))
        modal.append(applyPanelBackground(padded("", width: modalWidth), width: modalWidth))
        for line in content {
            let inner = padded("  " + line, width: modalWidth)
            modal.append(applyPanelBackground(inner, width: modalWidth))
        }
        modal.append(applyPanelBackground(padded("", width: modalWidth), width: modalWidth))

        var result = dimmed
        for (offset, line) in modal.enumerated() {
            let index = top + offset
            guard result.indices.contains(index) else { continue }
            result[index] = overlay(line: result[index], overlay: indent + line, width: width)
        }
        return result
    }

    static func appFooter(
        width: Int,
        cwd: String,
        mcpSummary: SloppyTUIMCPStatusSummary = .empty,
        sourceControl: SloppyTUISourceControlFooterStatus? = nil
    ) -> String {
        welcomeFooter(width: width, cwd: cwd, mcpSummary: mcpSummary, sourceControl: sourceControl)
    }

    private static func interruptBars(frame: Int) -> String {
        let cells = 12
        let litCount = 4
        let cursor = frame % cells
        return (0..<cells).map { index in
            let distance = (index - cursor + cells) % cells
            if distance < litCount {
                return "█"
            }
            if distance == litCount {
                return "▓"
            }
            return "▒"
        }.joined()
    }

    static func normalize(lines: [String], width: Int, height: Int) -> [String] {
        let normalized = lines.prefix(height).map { rawLine in
            let line = fittedLine(rawLine, width: width)
            let visible = VisibleWidth.measure(line)
            guard visible < width else { return line }
            return line + String(repeating: " ", count: width - visible)
        }
        if normalized.count >= height {
            return Array(normalized)
        }
        return normalized + Array(repeating: String(repeating: " ", count: width), count: height - normalized.count)
    }

    static func modelPickerPrompt(current: String) -> String {
        " " + accentBright(AnsiStyling.bold("Select model")) + "  " + muted("current:") + " " + foreground(current)
    }

    static func roleTitle(_ title: String, role: AgentMessageRole) -> String {
        switch role {
        case .assistant:
            return accentBright(title)
        case .user:
            return blue(title)
        case .system:
            return muted(title)
        }
    }

    static func runStatus(_ label: String) -> String {
        let normalized = label.lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return red("_\(label)_")
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return green("_\(label)_")
        }
        return yellow("_\(label)_")
    }

    static func isModelProviderError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Model provider error")
            || text.localizedCaseInsensitiveContains("No models loaded")
    }

    static func errorBlock(_ text: String) -> String {
        "### \(red("Error"))\n\(text)"
    }

    private static func logoLines(width: Int) -> [String] {
        if width < 64 {
            return [center(accentBright(AnsiStyling.bold("sloppy")), width: width)]
        }
        let logo = [
            "███████╗██╗      ██████╗ ██████╗ ██████╗ ██╗   ██╗",
            "██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝",
            "███████╗██║     ██║   ██║██████╔╝██████╔╝ ╚████╔╝ ",
            "╚════██║██║     ██║   ██║██╔═══╝ ██╔═══╝   ╚██╔╝  ",
            "███████║███████╗╚██████╔╝██║     ██║        ██║   ",
            "╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚═╝        ╚═╝   ",
        ]
        return logo.map { center(accentBright($0), width: width) }
    }

    private static func welcomePromptLine(width: Int) -> String {
        let text: String
        if width < 48 {
            text = muted("Ask anything...")
        } else {
            text = muted("Ask anything...  ") + foreground("\"What is the tech stack of this project?\"")
        }
        return accent("▌") + " " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeMetaLine(width: Int, project: String, agent: String, model: String, mode: AgentChatMode) -> String {
        let modelText = truncateEnd(compactModel(model), maxWidth: max(8, width / 3))
        let agentText = truncateEnd(agent, maxWidth: max(6, width / 5))
        let projectText = truncateEnd(project, maxWidth: max(6, width / 5))
        let text = modeTitle(mode) + muted(" · ") + foreground(modelText) + muted("  ") + foreground(agentText) + muted("  ") + muted(projectText)
        return accent("▌") + " " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeShortcutsLine(width: Int) -> String {
        let text: String
        if width < 48 {
            text = foreground("/help") + muted(" commands")
        } else {
            text = foreground("tab") + muted(" mode") + muted("     ") + foreground("/model") + muted(" models") + muted("     ") + foreground("/help") + muted(" commands")
        }
        return "  " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeTipLines(width: Int, contentWidth: Int, offset: Int) -> [String] {
        let compact = contentWidth < 58
        let tips: [String] = compact
            ? [
                "/scrollback tunes timeline history rendering.",
                "Use /pet to toggle your Sloppie.",
                "Type # to reference project tasks.",
                "/undo and /redo are per-session.",
            ]
            : [
                "/scrollback auto keeps chats smooth when history gets large.",
                "Use /pet to toggle your terminal Sloppie and peek at its current mood.",
                "/undo and /redo restore file changes from the last completed TUI turn.",
                "Type @skill to invoke a skill, or @path to attach project files as explicit context.",
                "Type # to autocomplete active project tasks by id or title.",
                "Use /btw for a side question without disturbing the main task.",
                "Use /diff to preview source-control changes, or /context diff to attach them to the next message.",
            ]
        let count = min(tips.count, 1)
        let start = tips.isEmpty ? 0 : ((offset % tips.count) + tips.count) % tips.count
        let visibleTips = (0..<count).map { tips[(start + $0) % tips.count] }
        return visibleTips.map { tip in
            center(yellow("Tip") + muted("  ") + foreground(tip), width: width)
        }
    }

    private static func welcomeFooter(
        width: Int,
        cwd: String,
        mcpSummary: SloppyTUIMCPStatusSummary,
        sourceControl: SloppyTUISourceControlFooterStatus? = nil
    ) -> String {
        let mcp = mcpFooterStatus(summary: mcpSummary)
        let mcpSuffix = muted("  ") + mcp.indicator + muted(" ") + foreground(mcp.label) + muted("  /status")
        let right = sourceControl.map { muted(sourceControlFooterLabel($0)) } ?? ""
        let reserved = VisibleWidth.measure(mcpSuffix)
            + (right.isEmpty ? 0 : VisibleWidth.measure(right) + 1)
        let pathWidth = max(1, width - reserved)
        let path = truncateStart(shortPath(cwd), maxWidth: pathWidth)
        let left = muted(path) + mcpSuffix
        guard !right.isEmpty else {
            return VisibleWidth.measure(left) <= width ? left : muted(truncateStart(path, maxWidth: width))
        }
        let leftWidth = VisibleWidth.measure(left)
        let rightWidth = VisibleWidth.measure(right)
        guard leftWidth + rightWidth + 1 <= width else {
            return leftWidth <= width ? left : muted(truncateStart(path, maxWidth: width))
        }
        let gap = width - leftWidth - rightWidth
        return left + String(repeating: " ", count: gap) + right
    }

    private static func sourceControlFooterLabel(_ status: SloppyTUISourceControlFooterStatus) -> String {
        let provider = sourceControlProviderLabel(status.providerId)
        guard status.isRepository else {
            return provider.map { "\($0) no repository" } ?? "no source control"
        }

        let branch = status.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let branch, !branch.isEmpty {
            base = provider.map { "\($0) \(branch)" } ?? branch
        } else {
            base = provider.map { "\($0) repository" } ?? "source control"
        }

        guard status.linesAdded > 0 || status.linesDeleted > 0 else {
            return base
        }
        return "\(base) +\(status.linesAdded) -\(status.linesDeleted)"
    }

    private static func sourceControlProviderLabel(_ providerId: String?) -> String? {
        guard let providerId else { return nil }
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "git-cli" {
            return "git"
        }
        return trimmed
    }

    static func mcpStatusLine(_ status: MCPServerStatus) -> String {
        let state: String
        if !status.enabled {
            state = "disabled"
        } else if status.connected {
            state = "available"
        } else {
            state = "unavailable"
        }

        var exposed: [String] = []
        if status.exposeTools {
            exposed.append("tools")
        }
        if status.exposeResources {
            exposed.append("resources")
        }
        if status.exposePrompts {
            exposed.append("prompts")
        }

        var parts = [
            state,
            status.transport,
            exposed.isEmpty ? "exposes none" : "exposes \(exposed.joined(separator: ", "))",
        ]
        if let prefix = trimmedNonEmpty(status.toolPrefix) {
            parts.append("prefix \(prefix)")
        }
        if state == "unavailable", let message = compactMCPStatusMessage(status.message) {
            parts.append(message)
        }

        return "- `\(status.id)` - \(parts.joined(separator: " · "))"
    }

    static func mcpSummaryLine(_ summary: SloppyTUIMCPStatusSummary) -> String {
        "\(summary.available)/\(summary.total) MCPs available."
    }

    private static func mcpFooterStatus(summary: SloppyTUIMCPStatusSummary) -> (indicator: String, label: String) {
        let label = summary.total == 0
            ? "0 MCPs"
            : "\(summary.available)/\(summary.total) MCPs"

        if summary.total == 0 {
            return (muted("○"), label)
        }
        if summary.available == summary.total {
            return (green("○"), label)
        }
        if summary.available > 0 {
            return (yellow("○"), label)
        }
        return (red("○"), label)
    }

    private static func compactMCPStatusMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let line = message
            .components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        let compact = line
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return truncateEnd(compact, maxWidth: 120)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func centeredToastLine(_ content: String, toastWidth: Int, screenWidth: Int) -> String {
        let innerWidth = max(1, toastWidth - 2)
        let fitted = padded(fittedLine(content, width: innerWidth), width: innerWidth)
        let panel = applyPanelBackground(accent("▌") + fitted + accent("▐"), width: toastWidth)
        return center(panel, width: screenWidth)
    }

    private static func applyPanelBackground(_ line: String, width: Int) -> String {
        applyBackground(line, width: width, background: panelBackground)
    }

    private static func applyBackground(_ line: String, width: Int, background: AnsiStyling.Background) -> String {
        AnsiWrapping.applyBackgroundToLine(line, width: width, background: background) + resetBackground
    }

    private static var blockLeftPadding: String {
        String(repeating: " ", count: blockHorizontalPadding)
    }

    private static func paddedBlockContentWidth(width: Int, prefixWidth: Int) -> Int {
        max(1, width - (blockHorizontalPadding * 2) - prefixWidth)
    }

    private static func paddedBlockLineWidth(_ width: Int) -> Int {
        max(1, width - blockHorizontalPadding)
    }

    private static func fittedPaddedBlockLine(_ line: String, width: Int) -> String {
        fittedLine(blockLeftPadding + line, width: paddedBlockLineWidth(width))
    }

    private static func paddedBackgroundBlock(
        _ lines: [String],
        width: Int,
        background: AnsiStyling.Background
    ) -> [String] {
        let padding = Array(repeating: backgroundPaddingLine(width: width, background: background), count: blockVerticalPadding)
        return padding + lines + padding
    }

    private static func backgroundPaddingLine(width: Int, background: AnsiStyling.Background) -> String {
        applyBackground(padded("", width: width), width: width, background: background)
    }

    private static func wrappedBuildProgressLines(
        _ text: String,
        firstPrefix: String,
        continuationPrefix: String,
        width: Int,
        style: (String) -> String,
        prefixStyle: ((String) -> String)? = nil
    ) -> [String] {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let content = normalized.isEmpty ? " " : normalized
        let firstWidth = max(1, width - VisibleWidth.measure(firstPrefix))
        let firstWrapped = AnsiWrapping.wrapText(content, width: firstWidth)
        guard let first = firstWrapped.first else {
            return [fittedLine(firstPrefix, width: width)]
        }

        var lines = [styledBuildProgressLine(prefix: firstPrefix, text: first, style: style, prefixStyle: prefixStyle, width: width)]
        let remaining = firstWrapped.dropFirst()
        let continuationWidth = max(1, width - VisibleWidth.measure(continuationPrefix))
        for fragment in remaining {
            for wrapped in AnsiWrapping.wrapText(fragment, width: continuationWidth) {
                lines.append(styledBuildProgressLine(
                    prefix: continuationPrefix,
                    text: wrapped,
                    style: style,
                    prefixStyle: nil,
                    width: width
                ))
            }
        }
        return lines
    }

    private static func styledBuildProgressLine(
        prefix: String,
        text: String,
        style: (String) -> String,
        prefixStyle: ((String) -> String)?,
        width: Int
    ) -> String {
        let styledPrefix = prefixStyle?(prefix) ?? muted(prefix)
        return fittedLine(styledPrefix + style(text), width: width)
    }

    private static func styledBuildProgressDetail(_ text: String) -> String {
        if text.hasPrefix("DoD: ") {
            return muted("DoD: ") + foreground(String(text.dropFirst(5)))
        }
        if text.hasPrefix("Notes: ") {
            return muted("Notes: ") + foreground(String(text.dropFirst(7)))
        }
        return foreground(text)
    }

    private static func singleLineDisplay(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func buildProgressMarker(for status: AgentBuildProgressStatus) -> (text: String, style: (String) -> String) {
        switch status {
        case .done:
            return ("[x]", green)
        case .inProgress:
            return ("[~]", orange)
        case .blocked:
            return ("[!]", red)
        case .skipped:
            return ("[-]", muted)
        case .pending:
            return ("[ ]", muted)
        }
    }

    private static func buildProgressStyle(for status: AgentBuildProgressStatus) -> (String) -> String {
        switch status {
        case .done:
            return green
        case .inProgress:
            return orange
        case .blocked:
            return red
        case .skipped, .pending:
            return muted
        }
    }

    private static func selectedLine(_ line: String) -> String {
        let plain = strippingANSI(from: line)
        return "\u{001B}[48;2;251;178;123m\u{001B}[38;2;0;0;0m\(plain)\u{001B}[39m\u{001B}[49m"
    }

    private static func overlay(line: String, overlay: String, width: Int) -> String {
        let overlayWidth = VisibleWidth.measure(overlay)
        guard overlayWidth < width else { return overlay }
        let suffix = max(0, width - overlayWidth)
        return overlay + String(repeating: " ", count: suffix)
    }

    private static func center(_ text: String, width: Int) -> String {
        let visible = VisibleWidth.measure(text)
        guard visible < width else { return text }
        return String(repeating: " ", count: (width - visible) / 2) + text
    }

    private static func padded(_ text: String, width: Int) -> String {
        let visible = VisibleWidth.measure(text)
        if visible >= width { return text }
        return text + String(repeating: " ", count: width - visible)
    }

    static func fittedLine(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        guard VisibleWidth.measure(text) > width else { return text }

        let ellipsis = "…"
        let ellipsisWidth = VisibleWidth.measure(ellipsis)
        let contentWidth = max(0, width - ellipsisWidth)
        let truncated = truncateVisible(text, maxWidth: contentWidth)
        let reset = text.contains("\u{001B}") ? "\u{001B}[0m" : ""
        let result = truncated + ellipsis + reset
        guard VisibleWidth.measure(result) <= width else {
            return truncateVisible(result, maxWidth: width)
        }
        return result
    }

    private static func compactModel(_ model: String) -> String {
        let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "default" }
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }

    private static func shortPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let expanded: String
        if standardized == homePath {
            expanded = "~"
        } else if standardized.hasPrefix(homePath + "/") {
            expanded = "~" + standardized.dropFirst(homePath.count)
        } else {
            expanded = standardized
        }
        let parts = expanded.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return expanded }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    private static func truncateEnd(_ text: String, maxWidth: Int) -> String {
        fittedLine(text, width: maxWidth)
    }

    private static func truncateStart(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 1, VisibleWidth.measure(text) > maxWidth else { return text }
        let ellipsis = "…"
        let limit = max(0, maxWidth - VisibleWidth.measure(ellipsis))
        var result = ""
        var visible = 0
        for character in text.reversed() {
            let next = String(character)
            let nextWidth = VisibleWidth.measure(next)
            guard visible + nextWidth <= limit else { break }
            result = next + result
            visible += nextWidth
        }
        return ellipsis + result
    }

    private static func highlightedMessageReferences(in line: String) -> String {
        let spans = messageHighlightSpans(in: line)
        guard !spans.isEmpty else {
            return foreground(line)
        }

        var result = ""
        var cursor = line.startIndex
        for span in spans {
            let range = span.range
            if range.lowerBound > cursor {
                result += foreground(String(line[cursor..<range.lowerBound]))
            }
            result += span.style(String(line[range]))
            cursor = range.upperBound
        }
        if cursor < line.endIndex {
            result += foreground(String(line[cursor..<line.endIndex]))
        }
        return result
    }

    private struct MessageHighlightSpan {
        var range: Range<String.Index>
        var style: (String) -> String
    }

    private struct ComposerHighlightSpan {
        var range: Range<Int>
        var style: (String) -> String
    }

    private static func highlightedComposerSyntax(
        in line: String,
        isContinuingProjectPath: Bool
    ) -> (line: String, isContinuingProjectPath: Bool) {
        let plain = strippingANSI(from: line)
        let (spans, nextIsContinuingProjectPath) = composerHighlightSpans(
            in: plain,
            isContinuingProjectPath: isContinuingProjectPath
        )
        guard !spans.isEmpty else {
            return (line, nextIsContinuingProjectPath)
        }

        var result = ""
        var visibleOffset = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{001B}" {
                let escapeEnd = ansiEscapeEnd(in: line, from: index)
                result += String(line[index..<escapeEnd])
                index = escapeEnd
                continue
            }

            let character = String(line[index])
            if let span = spans.first(where: { $0.range.contains(visibleOffset) }) {
                result += span.style(character)
            } else {
                result += character
            }
            visibleOffset += 1
            index = line.index(after: index)
        }
        return (result, nextIsContinuingProjectPath)
    }

    private static func truncateVisible(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }

        var result = ""
        var visible = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{001B}" {
                let escapeEnd = ansiEscapeEnd(in: text, from: index)
                result += String(text[index..<escapeEnd])
                index = escapeEnd
                continue
            }

            let character = String(text[index])
            let characterWidth = VisibleWidth.measure(character)
            guard visible + characterWidth <= maxWidth else { break }
            result += character
            visible += characterWidth
            index = text.index(after: index)
        }
        return result
    }

    private static func composerHighlightSpans(
        in line: String,
        isContinuingProjectPath: Bool
    ) -> (spans: [ComposerHighlightSpan], isContinuingProjectPath: Bool) {
        var spans: [ComposerHighlightSpan] = []
        appendComposerSpans(
            pattern: #"(\[paste #[0-9]+(?: [^\]]+)?\])"#,
            captureGroup: 1,
            style: { orange(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        let nextIsContinuingProjectPath = appendComposerProjectPathSpans(
            line: line,
            isContinuingProjectPath: isContinuingProjectPath,
            spans: &spans
        )
        appendComposerSpans(
            pattern: #"(^|\s)(/[A-Za-z0-9_][A-Za-z0-9_-]*)"#,
            captureGroup: 2,
            style: { accentBright(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        appendComposerSpans(
            pattern: #"(^|\s)(#[A-Za-z0-9][A-Za-z0-9._:-]*)"#,
            captureGroup: 2,
            style: { green(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        return (
            spans.sorted { $0.range.lowerBound < $1.range.lowerBound },
            nextIsContinuingProjectPath
        )
    }

    private static func messageHighlightSpans(in line: String) -> [MessageHighlightSpan] {
        var spans: [MessageHighlightSpan] = []
        appendMessageSpans(
            pattern: #"(\[paste #[0-9]+(?: [^\]]+)?\])"#,
            captureGroup: 1,
            style: { orange(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        appendMessageSpans(
            pattern: #"(^|\s)(@[A-Za-z0-9._/\-~]+)"#,
            captureGroup: 2,
            style: { yellow($0) },
            line: line,
            spans: &spans
        )
        appendMessageSpans(
            pattern: #"(^|\s)(#[A-Za-z0-9][A-Za-z0-9._:-]*)"#,
            captureGroup: 2,
            style: { green(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func appendComposerSpans(
        pattern: String,
        captureGroup: Int,
        style: @escaping (String) -> String,
        line: String,
        spans: inout [ComposerHighlightSpan]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: nsRange) {
            let capturedRange = match.range(at: captureGroup)
            guard capturedRange.location != NSNotFound,
                  let range = Range(capturedRange, in: line)
            else {
                continue
            }

            let lower = line.distance(from: line.startIndex, to: range.lowerBound)
            let upper = line.distance(from: line.startIndex, to: range.upperBound)
            let offsetRange = lower..<upper
            guard !spans.contains(where: { overlaps($0.range, offsetRange) }) else {
                continue
            }
            spans.append(ComposerHighlightSpan(range: offsetRange, style: style))
        }
    }

    private static func appendComposerProjectPathSpans(
        line: String,
        isContinuingProjectPath: Bool,
        spans: inout [ComposerHighlightSpan]
    ) -> Bool {
        var nextIsContinuingProjectPath = false
        var index = line.startIndex
        var activeStart: String.Index?
        var activeHasPathCharacter = isContinuingProjectPath

        if isContinuingProjectPath {
            activeStart = line.startIndex
        }

        while index < line.endIndex {
            let character = line[index]
            if let start = activeStart {
                if character.isWhitespace, !isEscapedProjectPathWhitespace(in: line, at: index, end: line.endIndex) {
                    appendComposerProjectPathSpan(
                        line: line,
                        start: start,
                        end: index,
                        hasPathCharacter: activeHasPathCharacter,
                        spans: &spans
                    )
                    activeStart = nil
                    activeHasPathCharacter = false
                } else if character != "@" {
                    activeHasPathCharacter = true
                }
            } else if character == "@", isProjectPathTokenStart(in: line, at: index) {
                activeStart = index
                activeHasPathCharacter = false
            }
            index = line.index(after: index)
        }

        if let start = activeStart {
            appendComposerProjectPathSpan(
                line: line,
                start: start,
                end: line.endIndex,
                hasPathCharacter: activeHasPathCharacter,
                spans: &spans
            )
            nextIsContinuingProjectPath = activeHasPathCharacter
        }
        return nextIsContinuingProjectPath
    }

    private static func appendComposerProjectPathSpan(
        line: String,
        start: String.Index,
        end: String.Index,
        hasPathCharacter: Bool,
        spans: inout [ComposerHighlightSpan]
    ) {
        guard hasPathCharacter, start < end else {
            return
        }
        let lower = line.distance(from: line.startIndex, to: start)
        let upper = line.distance(from: line.startIndex, to: end)
        let offsetRange = lower..<upper
        guard !spans.contains(where: { overlaps($0.range, offsetRange) }) else {
            return
        }
        spans.append(ComposerHighlightSpan(range: offsetRange, style: { yellow($0) }))
    }

    private static func isProjectPathTokenStart(in line: String, at index: String.Index) -> Bool {
        guard index > line.startIndex else {
            return true
        }
        let previous = line.index(before: index)
        return line[previous].isWhitespace
    }

    private static func isEscapedProjectPathWhitespace(in line: String, at index: String.Index, end: String.Index) -> Bool {
        if hasOddProjectPathBackslashRunBefore(index, in: line) {
            return true
        }
        let next = line.index(after: index)
        return next < end && line[next] == "\\"
    }

    private static func hasOddProjectPathBackslashRunBefore(_ index: String.Index, in line: String) -> Bool {
        var count = 0
        var cursor = index
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else {
                break
            }
            count += 1
            cursor = previous
        }
        return count % 2 == 1
    }

    private static func appendMessageSpans(
        pattern: String,
        captureGroup: Int,
        style: @escaping (String) -> String,
        line: String,
        spans: inout [MessageHighlightSpan]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: nsRange) {
            let capturedRange = match.range(at: captureGroup)
            guard capturedRange.location != NSNotFound,
                  let range = Range(capturedRange, in: line)
            else {
                continue
            }

            guard !spans.contains(where: { overlaps($0.range, range) }) else {
                continue
            }
            spans.append(MessageHighlightSpan(range: range, style: style))
        }
    }

    private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func isEditorBorderLine(_ line: String) -> Bool {
        let plain = strippingANSI(from: line)
        return !plain.isEmpty && plain.allSatisfy { $0 == "─" }
    }

    private static func strippingANSI(from line: String) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{001B}" {
                index = ansiEscapeEnd(in: line, from: index)
                continue
            }
            result.append(line[index])
            index = line.index(after: index)
        }
        return result
    }

    private static func ansiEscapeEnd(in line: String, from start: String.Index) -> String.Index {
        let next = line.index(after: start)
        guard next < line.endIndex else {
            return next
        }

        if line[next] == "[" {
            var index = line.index(after: next)
            while index < line.endIndex {
                let scalar = line[index].unicodeScalars.first?.value ?? 0
                index = line.index(after: index)
                if scalar >= 0x40 && scalar <= 0x7E {
                    return index
                }
            }
            return line.endIndex
        }

        if line[next] == "]" {
            var index = line.index(after: next)
            while index < line.endIndex {
                if line[index] == "\u{0007}" {
                    return line.index(after: index)
                }
                if line[index] == "\u{001B}" {
                    let possibleTerminator = line.index(after: index)
                    if possibleTerminator < line.endIndex, line[possibleTerminator] == "\\" {
                        return line.index(after: possibleTerminator)
                    }
                }
                index = line.index(after: index)
            }
            return line.endIndex
        }

        return line.index(after: next)
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1024.0
        var unit = units[0]
        for nextUnit in units.dropFirst() where value >= 1024.0 {
            value /= 1024.0
            unit = nextUnit
        }
        return String(format: "%.1f %@", value, unit)
    }

    static func shortID(_ id: String) -> String {
        if id.hasPrefix("session-") {
            let compact = String(id.dropFirst("session-".count))
            guard compact.count > 8 else { return compact }
            return String(compact.prefix(8))
        }
        let compact = id
        guard compact.count > 12 else { return compact }
        return String(compact.prefix(8))
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
