# Подключение моделей через Codex и Sloppy

В нативном клиенте откройте Settings → Models / Providers и выберите Connection.

## Codex

1. Выберите **Codex · Device code**.
2. Нажмите **Sign in to Codex**. Sloppy покажет код и откроет страницу входа.
3. Войдите в ChatGPT и введите device code. При необходимости включите device code login по ссылке в настройках.
4. После подтверждения выберите модель из обновлённого каталога и сохраните настройки.

Авторизация хранится на подключённом сервере Sloppy. Кнопка входа не импортирует локальную сессию Codex. В Dashboard тот же сценарий находится в карточке **OpenAI Codex**.

## Другой сервер Sloppy

Выберите **Sloppy server**, укажите адрес сервера и его access token, затем выберите модель и сохраните настройки. Поддерживаются адрес сервера и адрес с завершающим `/v1`.

Оба сервера должны содержать поддержку Sloppy inference v1. Если удалённый сервер ещё не обновлён, каталог может загружаться, а генерация вернёт HTTP 404. Ошибки доступа к каталогу показываются в настройках.

Запросы используют `POST /v1/providers/inference` с обычной авторизацией Sloppy. Каталог читается через `GET /v1/providers/models`. ID сохраняется с внешним префиксом `sloppy:`, например `sloppy:openai-oauth:gpt-5.4`. Текст передаётся потоком SSE. Вызовы инструментов возвращаются исходному серверу и выполняются там с его правилами разрешений. Цепочки Sloppy → Sloppy → Sloppy не поддерживаются.

В конфигурации поля `providerCatalogId`, `apiUrl`, `apiKey` и `model` задают соответственно `sloppy`, адрес сервера, его токен и ID модели на удалённом сервере. Ключ OpenAI из окружения для этого подключения не используется.

## Claude с личного компьютера

На личном компьютере установите официальный Claude Code, выполните `claude auth login` и добавьте в Sloppy провайдера **Claude Code** с моделью `sonnet`, `opus` или `haiku`. Авторизация Claude остаётся на личном компьютере. На рабочем нужен Sloppy, который обращается к этому Core; устанавливать Claude или копировать его tokens на рабочий компьютер не нужно.

В Dashboard рабочего компьютера откройте **Settings → Providers → Add provider → Sloppy server**. Выберите способ подключения:

- **Direct / localhost**: адрес Core личного компьютера и его Sloppy access token. Для прямой связи используйте его сетевой адрес или HTTPS URL. `127.0.0.1` обозначает текущий компьютер; на рабочем такой адрес подходит для локального туннеля к личному Core.
- **Relay**: выберите личный компьютер из списка узлов. Оба Core должны предварительно войти в один Sloppy Mesh через **Nodes → Join Remote Mesh**. На relay обоим узлам нужен grant `sloppy.models.inference`; существующий полный `sloppy.core.remote` также разрешает модели. Model-only grant не разрешает terminal или остальные Core API.

Нажмите **Test connection**, выберите `claude-code:sonnet` из каталога личного компьютера и сохраните. В relay-режиме адрес в конфигурации имеет вид `sloppy-relay://<personal-node-id>`, а `apiKey` остаётся пустым. Подключение использует подписанные идентификаторы узлов и шифрование между компьютерами. Relay пересылает поток; Claude выполняется на личном Core. Вызовы инструментов и разрешения выполняются на рабочем компьютере. Остановка запроса на рабочем отменяет inference на личном.

Relay здесь использует Sloppy Mesh `/v1/node/mesh/ws`. Достаточно исходящих подключений обоих компьютеров к существующему relay. Личный Core может слушать только localhost. Это не настройка публичного relay: используйте уже настроенный приватный coordinator; публичный multi-tenant managed relay и его enrollment являются отдельным механизмом. Текущий Mesh-клиент поддерживает WebSocket-соединения на macOS; Linux Core как исходящий Mesh-клиент пока возвращает `linux-urlsession-websocket`.

## Localhost API для других клиентов

Sloppy предоставляет OpenAI-compatible **Chat Completions** API:

```text
Base URL: http://127.0.0.1:25101/v1
API key:  Sloppy access token этого Core
Model:    sloppy:claude-code:sonnet
```

Это адрес рабочего Core, когда он настроен как proxy к личному. Если клиент работает непосредственно на личном компьютере, выберите `claude-code:sonnet`. Каталог доступен через `GET /v1/models`; запросы — через `POST /v1/chat/completions` с `Authorization: Bearer <Sloppy token>`. Model endpoints требуют авторизацию даже при выключенной авторизации Dashboard. Identity-enabled Core использует обычный access token пользователя.

```sh
curl http://127.0.0.1:25101/v1/chat/completions \
  -H "Authorization: Bearer $SLOPPY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"sloppy:claude-code:sonnet","stream":true,"messages":[{"role":"user","content":"Ответь кратко"}]}'
```

Поддерживаются text/image messages, function tools, поток `data:` с `[DONE]`, `max_tokens`/`max_completion_tokens`, `temperature` и `reasoning_effort`. Клиент сам выполняет возвращённые `tool_calls` и передаёт `tool` messages следующим запросом. Signed thinking сохраняется в ограниченном временном кэше на proxy, привязанном к вызывающему пользователю, модели и tool-call IDs; он не хранит Claude credentials. Responses API, audio и принудительный `tool_choice` в этой реализации не поддерживаются.
