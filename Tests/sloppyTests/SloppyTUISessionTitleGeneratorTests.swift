import SloppyRuntime
import Testing
@testable import sloppy

@Test func tuiSessionTitleUsesFirstUserLine() {
    let title = SloppyTUISessionTitleGenerator.title(for: "надо еще добавить автогенерацию заголовка\n\nподробности ниже")

    #expect(title == "надо еще добавить автогенерацию заголовка — подробности ниже")
}

@Test func tuiSessionTitleStripsSkillInvocationPrefix() {
    let title = SloppyTUISessionTitleGenerator.title(for: "@TUI при аттаче файла через ctrl+v вставлять текст")

    #expect(title == "при аттаче файла через ctrl+v вставлять текст")
}

@Test func tuiSessionTitleSkipsAttachmentContextLines() {
    let title = SloppyTUISessionTitleGenerator.title(for: "[Attached files]\n- screenshot.png (image/png, 10 bytes)\nПочини отображение картинки")

    #expect(title == "Почини отображение картинки")
}

@Test func tuiSessionTitleFallsBackForEmptyInput() {
    #expect(SloppyTUISessionTitleGenerator.title(for: " \n ", fallback: "Fallback") == "Fallback")
}

@Test func tuiSessionTitleTruncatesLongInput() {
    let title = SloppyTUISessionTitleGenerator.title(for: "one two three four five six seven eight nine ten eleven twelve")

    #expect(title == "one two three four five six seven eight nine ten eleven")
}

@Test func sessionTitleUsesMoreThanTheFirstLineForContext() {
    let title = AgentSessionTitleGenerator.title(
        for: "Есть проблема\nЗаголовки сессий не отражают содержание работы"
    )

    #expect(title == "Есть проблема — Заголовки сессий не отражают содержание работы")
}

@Test func sessionTitleSkipsRuntimeAndMarkdownNoise() {
    let title = AgentSessionTitleGenerator.title(
        for: "[Sloppy runtime mode]\n# Исправить заголовки\n```swift\nlet ignored = true\n```"
    )

    #expect(title == "Исправить заголовки")
}
