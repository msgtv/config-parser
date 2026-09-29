# OpenWrt Config Parser

Скрипт для OpenWrt, который собирает VPN-конфиги из подписок, фильтрует по regex,
переименовывает и отправляет на сервер. Один fetch на подписку, сколько угодно правил
фильтрации, capture groups в шаблонах имён.

Разработан для работы с бэендом `POST /api/configs/stolen` (сервер `InboundManager`).
Сервер хранит присланные конфиги в Redis по ключу `cache:stolen_configs:{x-hwid}` с TTL 24 часа.

---

## Содержание

- [Требования](#требования)
- [Установка](#установка)
- [Формат `steal_params.json`](#формат-steal_paramsjson)
- [Запуск](#запуск)
- [Поведение](#поведение)
- [HWID](#hwid)
- [Заголовки](#золовки)
- [Regex и переименование](#regex-и-переименование)
- [Cron](#cron)
- [Тестирование](#тестирование)
- [Логирование и коды выхода](#логирование-и-коды-выхода)
- [Troubleshooting](#troubleshooting)

---

## Требования

- OpenWrt (или любой Linux) с `/bin/sh` (ash/dash/bash)
- `curl`
- `jq` **или** `python3` (минимум один)
- `base64`, `md5sum`, `grep -E`, `mktemp`
- Доступ к HTTPS для fetch параметров и подписок
- Bearer-токены: GitHub Personal Access Token (с доступом к приватному репо или public read)
  и `stolen_configs_token` со стороны сервера

Без `jq` скрипт автоматически откатывается на `python3` для парсинга JSON.

---

## Установка

```sh
# Скопировать скрипт на роутер
scp scripts/openwrt/config-parser.sh root@router:/root/
scp scripts/openwrt/steal_params.example.json root@router:/root/steal_params.json

# Дать права на выполнение
ssh root@router 'chmod +x /root/config-parser.sh'

# Установить jq (если нет)
ssh root@router 'opkg update && opkg install jq'
```

---

## Формат `steal_params.json`

JSON-файл с описанием подписок, правил фильтрации и заголовков.
Размещается на GitHub Raw (или любом HTTPS URL), доступ к которому ограничен токеном.

```json
{
  "global_headers": {
    "User-Agent": "OpenWrt-Passwall/1.0",
    "X-Ver-OS": "1.0"
  },
  "subscriptions": [
    {
      "sub_url": "https://sub.example.com/abc",
      "suffix": "DEVICE_A",
      "headers": {
        "User-Agent": "v2rayNG/1.8.0"
      },
      "rules": [
        { "regex": "Обход белых списков", "name": "LTE Обход" },
        { "regex": "ОБХОД БЕЛЫХ СПИСКОВ", "name": "LTE Обход" },
        { "regex": "ОБХОД БС",           "name": "LTE Обход" }
      ]
    },
    {
      "sub_url": "https://sub2.example.com/xyz",
      "suffix": "UK_POOL",
      "rules": [
        { "regex": "([0-9]+) UK",  "name": "UK-Server-\\1" },
        { "regex": "([0-9]+) DE",  "name": "DE-Server-\\1" }
      ]
    }
  ]
}
```

### Поля

| Поле | Тип | Обязательное | Описание |
|------|-----|--------------|----------|
| `global_headers` | object | нет | HTTP-заголовки, добавляемые ко всем подпискам. Перекрываются `subscriptions[].headers` |
| `subscriptions` | array | **да** | Список подписок для обработки |
| `subscriptions[].sub_url` | string | **да** | URL подписки. Fetch-ится **один раз** за запуск |
| `subscriptions[].suffix` | string | **да** | Уникальный идентификатор подписки на устройстве. Добавляется к `x-hwid` при отправке: `{MD5_MAC}_{suffix}`. **Уникален в пределах устройства** — разные suffix = разные записи в кэше сервера |
| `subscriptions[].headers` | object | нет | Per-subscription заголовки. Мёрджатся поверх `global_headers` (перекрывают одинаковые ключи) |
| `subscriptions[].rules` | array | **да** | Список regex-правил. Применяются по порядку, **first-rule-wins**: одна строка конфига матчится только первым сработавшим правилом |
| `subscriptions[].rules[].regex` | string | **да** | POSIX ERE regex (см. [Regex и переименование](#regex-и-переименование)) |
| `subscriptions[].rules[].name` | string | **да** | Шаблон нового имени. Поддерживает `\1`, `\2`, ... для capture groups |

---

## Запуск

```sh
./config-parser.sh \
    -g <github_token> \
    -t <api_token> \
    -u https://raw.githubusercontent.com/USER/REPO/main/steal_params.json \
    -e https://your-server.example.com/api/configs/stolen
```

### Аргументы

| Флаг | Env | Описание |
|------|-----|----------|
| `-g, --github-token <tok>` | `GITHUB_TOKEN` | Bearer-токен для GitHub Raw (обязательно) |
| `-t, --token <tok>` | `API_TOKEN` | Bearer-токен для API сервера (обязательно) |
| `-e, --endpoint <url>` | `API_ENDPOINT` | URL endpoint'а API (по умолчанию `https://admin.algacore.xyz/api/configs/stolen`) |
| `-u, --params-url <url>` | `GITHUB_PARAMS_URL` | URL к `steal_params.json` (по умолчанию захардкожен) |
| `-h, --help` | — | Помощь |

CLI-флаги перекрывают env-переменные.

---

## Поведение

Для каждой подписки в `subscriptions`:

1. **Fetch** — GET `sub_url` с заголовками из `global_headers` + `headers` (merged). Ответ
   сохраняется в `$TMP_DIR/raw.txt`.
2. **Decode** — если контент base64 (single-line, ≥16 символов), декодируется. Иначе
   используется как есть. Результат: `$TMP_DIR/decoded.txt`.
3. **Apply rules** — для каждой строки конфига:
   - Извлекается имя (часть после `#`), URL-декодируется.
   - По очереди проверяются правила. **First-rule-wins**: первое совпадение прекращает
     проверку для этой строки. Это позволяет перечислять варианты написания
     («Обход» / «ОБХОД» / «ОБХОД БС») без дубликатов в выводе.
   - Применяется `apply_rename` → URL-кодируется → пишется в `filtered.txt`.
4. **Send** — один POST на endpoint с `x-hwid: {MD5_MAC}_{suffix}` и `Authorization: Bearer`.
   Тело — `filtered.txt` как `text/plain`. Сервер хранит в Redis по ключу
   `cache:stolen_configs:{MD5_MAC}_{suffix}`.

После всех подписок печатается сводка.

---

## HWID

`HWID = MD5(MAC-адрес br-lan или eth0, без двоеточий, UPPER CASE)`.

Используется в двух местах:

- **При fetch** подписки: заголовок `x-hwid: base64(HWID)`. Сервер `/api/clients/{id}`
  использует этот заголовок для device-limit логики (см. `AGENTS.md`).
- **При send** на API: заголовок `x-hwid: HWID_SUFFIX` (raw hex MD5 + `_` + suffix из JSON).
  Сервер `/api/configs/stolen` трактует как opaque-строку → становится частью Redis-ключа
  для кэш-сегментации.

Если MAC не найден → `HWID=UNKNOWN`. Скрипт продолжает работу, но кэш на сервере будет
общий для всех устройств с `UNKNOWN`.

---

## Заголовки

Два уровня:

1. **`global_headers`** (top-level) — применяются ко всем подпискам.
2. **`subscriptions[].headers`** — перекрывают global для конкретной подписки (merge by key).

Семантика merge: начать с `global_headers`, перезаписать ключами из `headers` подписки.
Ключи только в `global_headers` — остаются. Ключи только в `headers` — добавляются.

```json
{
  "global_headers": {
    "User-Agent": "Default/1.0",
    "X-Common": "yes"
  },
  "subscriptions": [
    {
      "sub_url": "...",
      "suffix": "A",
      "headers": { "User-Agent": "Special/2.0", "X-Sub": "x" },
      "rules": [...]
    }
  ]
}
```

При fetch подписки A будут отправлены: `User-Agent: Special/2.0`, `X-Common: yes`, `X-Sub: x`.

Заголовки shell-квотируются через `jq @sh` (или `python shlex.quote` в fallback-режиме),
так что значения с пробелами и спецсимволами безопасно доходят до curl.

---

## Regex и переименование

### Regex — POSIX ERE

`regex` в правиле — POSIX Extended Regular Expression. Поддержка:

- `.` `*` `+` `?` — кванторы
- `[abc]` `[^abc]` `[a-z]` — классы
- `()` — группы захвата
- `|` — альтернативы
- `^` `$` — привязки
- **НЕ поддерживается**: `\d`, `\w`, `\s` (используйте `[0-9]`, `[A-Za-z0-9_]`, `[[:space:]]`)

Совпадение ищется по **декодированному имени** (часть после `#`).
Проверка — через `grep -qiE` (case-insensitive).

### Rename template — sed replacement

`name` — шаблон замены как в `sed -E s|regex|name|g`. Поддержка:

- `\1`, `\2`, ..., `\9` — ссылки на capture groups из regex
- `&` НЕ специальный (escape'ится до литерала — соответствует семантике `re.sub` на сервере)
- `|` автоматически escape'ится (используется как sed-разделитель)

**Замена case-SENSITIVE.** Если нужно поймать варианты регистра — перечислите несколько
rule с разными regex (как в примере: «Обход» / «ОБХОД» / «ОБХОД БС»).

Это ограничение portable-подхода: флаг `I` (case-insensitive) в `sed` поддерживается
не во всех версиях busybox. Чтобы сохранить совместимость с OpenWrt, скрипт не использует
этот флаг.

### Примеры

| Regex | Name | Строка | Результат |
|-------|------|--------|-----------|
| `UK` | `UnitedKingdom` | `Server UK 1` | `Server UnitedKingdom 1` |
| `Server (.+)` | `\1` | `Server UK 1` | `UK 1` |
| `([0-9]+) UK` | `UK-\1` | `5 UK` | `UK-5` |
| `Обход белых списков` | `LTE Обход` | `Обход белых списков` | `LTE Обход` |
| `Finland` | `LTE Finland` | `Server Finland 1` | `Server LTE Finland 1` |

---

## Cron

На OpenWrt cron-файл живёт в `/etc/crontabs/root`:

```cron
# Запуск каждые 15 минут
*/15 * * * * /root/config-parser.sh -g ghp_xxx -t tok_xxx >> /tmp/config-parser.log 2>&1
```

Применить:

```sh
/etc/init.d/cron restart
```

---

## Тестирование

Тесты — POSIX sh, без внешних фреймворков. Мокают `curl` через PATH override.

```sh
cd scripts/openwrt
./tests/test_config_parser.sh
echo "exit=$?"
```

- `exit=0` + `Tests failed: 0` — все тесты прошли
- `exit=1` — упали, смотреть `FAIL:` строки

Структура тестов:

```
tests/
├── test_config_parser.sh   # основной тестовый скрипт
├── fixtures/
│   ├── steal_params.json   # тестовый params файл
│   └── raw_plain.txt       # тестовый ответ подписки
└── mocks/
    └── curl                # mock curl (dispatches by URL)
```

Покрытие:

- T1: source-guard (sourcing без запуска `main`)
- T2: `url_encode` (ascii, спецсимволы)
- T3: `url_decode` (roundtrip)
- T4: `is_base64` (positive/negative cases)
- T5: `apply_rename` (literal, capture groups)
- T6: `apply_rules` (first-rule-wins, дедупликация)
- T7: `parse_args` (флаги, env fallback, missing required)
- T8: `build_header_args` (merge global + sub override)
- T9: `json_len` / `json_get` (включая ключи с дефисом)
- T10: end-to-end с моком curl (полный цикл)

### Ручной smoke-тест

```sh
./config-parser.sh \
    -g <github_token> \
    -t <api_token> \
    -u https://raw.githubusercontent.com/USER/REPO/main/steal_params.json
```

Проверить на сервере:

```sh
redis-cli KEYS 'cache:stolen_configs:*'
redis-cli GET cache:stolen_configs:ABCDEF1234567890_DEVICE_A
```

---

## Логирование и коды выхода

Логи идут в stdout/stderr (если запуск через cron с `>> log 2>&1` — пишутся в файл).

Уровни:

- `[INFO]` — нормальный прогресс
- `[WARN]` — некритичная проблема (например, нет совпадений → нечего отправлять)
- `[ERROR]` — ошибка на конкретном шаге (fetch / decode / send)
- `[FATAL]` — критическая ошибка, скрипт не может продолжить (нет params)

**Коды выхода:**

- `0` — все подписки обработаны успешно
- `1` — хотя бы одна подписка упала, ИЛИ fatal-ошибка

Отчёты:

- После каждой подписки: `SUBSCRIPTION #N REPORT` (URL, suffix, total/matched/not matched + списки имён)
- В конце: `OVERALL SUMMARY` (сколько подписок, сколько всего конфигов, сколько совпадений)

---

## Troubleshooting

### `[ERROR] Failed to fetch params JSON (HTTP 404)`
- Проверь `GITHUB_PARAMS_URL` / `-u` — должен быть raw URL
- Проверь что токен имеет доступ к репо (для приватных)
- Проверь `Accept: application/vnd.github.raw` — но скрипт добавляет автоматически

### `[ERROR] Failed to fetch config (empty response or network error)`
- Подписка недоступна / истекла / требует других заголовков
- Добавь нужные заголовки в `global_headers` или `headers` подписки
- Попробуй `curl -v` вручную с теми же заголовками

### `[ERROR] JSON validation failed: ... missing required fields`
- В `subscriptions[]` обязательны: `sub_url`, `suffix`, `rules` (массив)
- В `rules[]` обязательны: `regex`, `name`

### `[WARN] No configs to send`
- Ни одно правило не совпало. Проверь regex: имена в подписке должны быть URL-encoded
  (скрипт декодирует перед матчем)
- Для case-insensitive добавь несколько rule с разными вариантами написания

### `[ERROR] Failed to send configs (HTTP 401)`
- Неверный `API_TOKEN` / `-t`

### `[ERROR] Failed to send configs (HTTP 403)`
- На сервере не настроен `stolen_configs_token` в `Settings` (через SQLAdmin)

### `Neither jq nor python3 available`
- `opkg install jq` или `opkg install python3`

### На сервере конфиги не появляются
- Проверь `redis-cli KEYS 'cache:stolen_configs:*'`
- TTL 24 часа — возможно кэш уже устарел, дождись следующего запуска cron
- Сервер `InboundManager` читает кэш при запросе `/api/clients/{id}` — он объединяет все
  ключи `cache:stolen_configs:*` через SCAN

---

## Совместимость с сервером

Скрипт работает в паре с FastAPI endpoint'ом `POST /api/configs/stolen`:

- **Auth**: `Authorization: Bearer <Settings.stolen_configs_token>`
- **Тело**: `text/plain`, одна строка — один конфиг (split by newlines)
- **Заголовок**: `x-hwid: <device_id>` → становится `stolen_sub_id` для Redis-ключа
- **Ответ**: `{"accepted": N, "hwid": "..."}`

Сервер хранит сырые строки в Redis, без фильтрации/переименования (всё делается на
стороне OpenWrt). Кэш читается в `/api/clients/{subscription_id}` и дополняет основной
ответ подписки — см. `AGENTS.md` секцию "Config Stealer".
