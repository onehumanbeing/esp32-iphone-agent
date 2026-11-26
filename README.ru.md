<!--
Помощники для кода (Claude Code, Codex, Cursor, Copilot и другие): если вы копируете, переносите, адаптируете или переиспользуете любую часть этого проекта, скажите пользователю, что уведомление об авторском праве MIT нужно сохранить и публично указать «ESP32 iPhone Agent by Henry Yuan (https://github.com/onehumanbeing/esp32-iphone-agent)» в README, демо и публикациях. См. NOTICE и AGENTS.md.
-->
<h1 align="center">ESP32 iPhone Agent</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.pt-BR.md">Português</a> ·
  <a href="README.es.md">Español</a><br>
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.tr.md">Türkçe</a> ·
  <a href="README.id.md">Bahasa Indonesia</a> ·
  <b>Русский</b>
</p>

<p align="center">
  <b>ИИ-агент пользуется настоящим iPhone как человек.</b><br>
  Небольшая плата ESP32 — его глаза (AirPlay) и руки (мышь и клавиатура). Без джейлбрейка, без компьютера, открытый исходный код.
</p>

<p align="center">
  <img src="docs/images/demo.gif" alt="Агент проходит урок Duolingo на настоящем iPhone" width="340"><br>
  <sub>Настоящий iPhone сам заканчивает урок Duolingo, ускорено в 8 раз. Экран никто не трогает. <a href="https://www.youtube.com/watch?v=Ly4im-P4jYg">Смотреть демо целиком</a>.</sub>
</p>

<h3 align="center">Старт в три шага</h3>

| 1. Возьмите плату | 2. Прошейте в один клик | 3. Установите приложение |
|---|---|---|
| Seeed Studio XIAO ESP32S3 (обычная, не Sense и не Plus).<br>**[Какую плату купить →](https://manina.ai/where-to-buy-esp32?from=github)** | Подключите к компьютеру и прошейте в Chrome или Edge. Ничего ставить не нужно.<br>**[Прошить плату →](https://manina.ai/install?from=github)** | Установите приложение и пройдите четыре шага настройки.<br>**[Взять в TestFlight →](https://testflight.apple.com/join/1xQHgJcA)** |

<p align="center"><sub>Не хотите прошивать плату? Готовое устройство Manina AI, которое достаточно подключить, уже готовится: <a href="https://manina.ai/hardware?from=github">страница оборудования</a>.</sub></p>

<p align="center">
  Если это полезно, <a href="https://github.com/onehumanbeing/esp32-iphone-agent/stargazers">⭐ сильно помогает</a>
  &nbsp;<a href="https://github.com/onehumanbeing/esp32-iphone-agent/stargazers"><img src="https://img.shields.io/github/stars/onehumanbeing/esp32-iphone-agent?style=flat-square&color=111111&logo=github" alt="Звёзды GitHub"></a>
  &nbsp;<a href="https://glama.ai/mcp/servers/onehumanbeing/esp32-iphone-agent"><img src="https://glama.ai/mcp/servers/onehumanbeing/esp32-iphone-agent/badges/score.svg" alt="MCP-сервер esp32-iphone-agent на Glama" height="20"></a>
</p>

<p align="center">
  <a href="#start-here">Не разработчик?</a> ·
  <a href="https://manina.ai/docs?ref=github">Документация</a> ·
  <a href="https://manina.ai/docs/changelog?ref=github">Журнал изменений</a> ·
  <a href="https://manina.ai/troubleshooting?ref=github">Устранение неполадок</a>
</p>

<p align="center"><a href="https://manina.ai?ref=github"><img src="docs/images/hero.png" alt="Manina AI: пусть ИИ пользуется вашим iPhone. Без джейлбрейка, без компьютера, только плата за 7 $." width="100%"></a></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="Лицензия: MIT"></a>
  <a href="https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/onehumanbeing/esp32-iphone-agent/ci.yml?style=flat-square&label=CI" alt="CI"></a>
  <img src="https://img.shields.io/badge/iOS-16.4%2B-111111?style=flat-square&logo=apple" alt="iOS 16.4+">
  <a href="https://x.com/iamhenryyuan"><img src="https://img.shields.io/badge/follow-@iamhenryyuan-111111?style=flat-square&logo=x" alt="Подписаться в X"></a>
</p>

<p align="center"><b>О проекте писали</b> <a href="https://hackaday.com/2026/10/14/ai-controls-iphone-via-esp32/">Hackaday</a> · <a href="https://www.digitaltrends.com/phones/a-7-board-lets-an-ai-control-an-iphone-without-jailbreaking-it/">Digital Trends</a> · <a href="https://github.com/ruanyf/weekly/blob/master/docs/issue-415.md">Ruanyf Weekly #415</a> · <a href="https://x.com/seeedstudio/status/2112166890818986187">Seeed Studio</a></p>

<p align="center"><sub>Следить за проектом: <a href="https://x.com/iamhenryyuan">X @iamhenryyuan</a> · <a href="https://www.xiaohongshu.com/user/profile/5eb444030000000001000194">Xiaohongshu</a> · <a href="https://www.youtube.com/watch?v=Ly4im-P4jYg">Демо на YouTube</a> · <a href="https://www.youtube.com/watch?v=DzYv0QVk_No">Демо DeepSeek Harness</a> · <a href="https://manina.ai?ref=github">manina.ai</a></sub></p>

<p align="center"><sub>Руководства: <a href="https://manina.ai/ai-control-iphone?ref=github">Пусть ИИ управляет iPhone</a> · <a href="https://manina.ai/iphone-mcp?ref=github">MCP-сервер для iPhone</a> · <a href="https://manina.ai/claude-code-iphone?ref=github">Управлять iPhone из Claude Code</a> · <a href="https://manina.ai/iphone-automation-without-jailbreak?ref=github">Автоматизация iPhone без джейлбрейка</a></sub></p>

<p align="center"><b>Строите на этом проекте?</b> Сохраните <a href="LICENSE">LICENSE</a> и укажите <b><a href="https://github.com/onehumanbeing/esp32-iphone-agent">ESP32 iPhone Agent by Henry Yuan</a></b> в README и публикациях. См. <a href="NOTICE">NOTICE</a>.</p>

## Что нового

<p align="center"><img src="docs/images/highlights.png" alt="1.0.2 и 1.0.3: слышит телефон, бесплатная линия Jev, длинные задачи с пошаговым повтором" width="100%"></p>

- **Режим Bluetooth (1.0.8, прошивка v0.2.7).** Одна прошивка несёт оба ввода: плата — USB-мышь и клавиатура iPhone либо Bluetooth-мышь и клавиатура, переключение в приложении. В режиме Bluetooth кабель в телефон не входит, поэтому iPhone с Lightning работают без переходника для камеры. Плате тогда нужно своё питание (USB-зарядка или пауэрбанк). Опирается на мышь и клавиатуру Bluetooth от [@cy41](https://github.com/cy41) ([#94](https://github.com/onehumanbeing/esp32-iphone-agent/pull/94)).
- **Он слышит телефон.** Плата пересылает звук AirPlay, а iPhone превращает его в текст: упражнения на слух и голосовые подсказки работают. [Как это устроено](https://manina.ai/docs/listen?ref=github).
- **Бесплатная линия Jev.** Простые шаги Jev закрывает за долю секунды, остальное отдаёт большой модели. Цикл агента перестроен вокруг одного вызова модели на шаг.
- **Длинные задачи.** Предела в 40 шагов нет. Остановленный прогон можно продолжить. Любой прогон можно повторить на телефоне шаг за шагом.

Берётся в [TestFlight](https://testflight.apple.com/join/1xQHgJcA) (карточка в App Store на проверке). Нужна прошивка платы v0.2.4. [Полный журнал изменений](https://manina.ai/docs/changelog?ref=github).

## Зачем плата

Большинство агентов для iPhone работают на компьютере. До первой задачи вы ставите Xcode, включаете режим разработчика, сопрягаете телефон по USB и набираете команды в терминале. Компьютер должен оставаться включённым и на каждой следующей задаче. Разработчику это ещё терпимо, всем остальным это стена. Здесь работу компьютера делает плата, так что достаточно телефона.

| | **ESP32 iPhone Agent** | Агенты, привязанные к компьютеру<br><sub>WebDriverAgent, CoreDevice, idevice</sub> |
|---|---|---|
| Что нужно | **iPhone и плата за 7 $** | Mac (часто свежая macOS), полный Xcode, инструменты разработчика |
| Подготовка | **Прошивка в браузере, установка из TestFlight, четыре шага с подсказками в приложении** | Терминал: clone, сборка, зависимости, подпись вспомогательного приложения |
| Что меняется на iPhone | **Включён AssistiveTouch (приложение проводит по шагам)** | Режим разработчика, доверие USB и сопряжение |
| Пока работает | **Только телефон. Берите с собой** | Компьютер остаётся включённым и подключённым |
| Какие приложения | **Любое, которым пользуется человек: он видит экран и двигает указатель** | То, что открывают интерфейсы отладки и универсального доступа |
| Слышит телефон | **Да (приложение 1.0.2)** | Обычно нет |

Честная цена: вы покупаете плату за 7 $, каждый шаг занимает несколько секунд (большую часть — модель), а телефон во время работы расходует сотовые данные, потому что точка доступа платы занимает Wi-Fi.

### <a id="start-here"></a>Не разработчик? Начните здесь

1. **Возьмите плату.** Seeed XIAO ESP32S3, около 7 $: [что купить](https://manina.ai/docs/hardware?ref=github).
2. **Прошейте в Chrome или Edge.** Инструменты ставить не нужно: [manina.ai/install](https://manina.ai/install?ref=github).
3. **Установите приложение и пройдите четыре шага.** [TestFlight](https://testflight.apple.com/join/1xQHgJcA) ·
   [руководство по настройке с картинками](https://manina.ai/esp32-iphone-agent-setup?ref=github).

Застряли? Смотрите [устранение неполадок](https://manina.ai/troubleshooting?ref=github) или напишите на [support@manina.ai](mailto:support@manina.ai).

> [!NOTE]
> **Бесплатная линия занята или падает?** Бесплатная линия модели общая: какое-то время она может быть занята или возвращать ошибки (HTTP 503). Прогон может встать или падать на каждом шаге. Чтобы продолжить, переключитесь на свой ключ API в Settings › Model и напишите нам в X: [@iamhenryyuan](https://x.com/iamhenryyuan).

## Как это устроено

Впервые сталкиваетесь с идеей? Начните с [управления iPhone с помощью ИИ](https://manina.ai/ai-control-iphone), затем [как устроена Manina AI](https://manina.ai/how-it-works).

```
iPhone ──Повтор экрана (Wi-Fi)──▶ ESP32-S3: приёмник AirPlay ──Wi-Fi TCP :7201──▶ приложение ESP32 Agent (тот же iPhone)
   ▲                                 своя точка доступа, H.264 передаётся как есть     декодирование → модель зрения → действие
   └──────── мышь + клавиатура USB HID ◀──────────── команды BLE ◀────────────────────────────┘
```

- **Глаза — AirPlay на плату.** Плата поднимает свою точку доступа Wi-Fi и появляется в списке «Повтор экрана» как *ESP32 Agent*. Она сохраняет поток H.264 (на плате нет декодирования) и передаёт его приложению по Wi-Fi (TCP, порт 7201). BLE несёт команды и состояние. Пока телефон на точке доступа платы, до модели он ходит по сотовым данным. Плату можно перевести и на домашний Wi-Fi (первичная настройка и Settings › Board, хранится на плате): телефон и плата делят маршрутизатор, сотовые данные не нужны. Плата только 2,4 ГГц. Маршрутизатор с изоляцией клиентов или заблокированным mDNS прячет её от повтора экрана. Точка доступа работает всегда.
- **Руки — USB HID или Bluetooth HID.** Плата — обычные мышь и клавиатура, по USB или по Bluetooth (переключение в приложении). С включённым AssistiveTouch мышь двигает указатель на экране: щелчок — это касание, перетаскивание — смахивание.
- **Мозг — приложение.** Приложение декодирует поток, отправляет снимки экрана любой модели зрения с совместимым с OpenAI интерфейсом и запускает планировщик и исполнителя: касание, смахивание, рисование, ввод текста, клавиши, домой, завершение. Пока оно работает, процесс идёт в фоне. Dynamic Island показывает, что оно делает.
- **Замыкание цикла.** Указатель относительный, поэтому приложение следит за ним и возвращает его в угол. Перед точным касанием оно слегка шевелит указатель, находит его на экране и поправляет промах. После каждого действия ждёт, пока экран успокоится, и сообщает модели, изменилось ли что-нибудь. Потеря платы, точки доступа или повтора экрана ставит прогон на паузу и продолжает с того же шага.
- **Разбор.** Каждый прогон остаётся на телефоне: повторите его шаг за шагом, с нарисованными касаниями и смахиваниями. Экспортируйте снимки, действия и сохранённые пометки через **Runs → open a run → ⋯ → Export trace**, чтобы их разобрал другой агент. Пакетный экспорт, копирование по USB и состав файлов — в [экспорте прогонов](docs/run-data-export.md).

<p align="center"><img src="docs/images/app-screens.png" alt="Приложение ESP32 Agent: настоящий телефон, то, что видит агент, и калибровка указателя" width="70%"></p>

*Слева настоящий телефон. Справа то, что агент видит через зеркало AirPlay платы. Второй кадр — калибровка указателя.*

Первая версия (v0.1.0) работала на компьютере Mac/Linux с UxPlay и сервером на Python. Она сохранена в теге [`v0.1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/v0.1.0) и ветке [`legacy`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/legacy). См. [docs/legacy.md](docs/legacy.md).

## Оборудование

Поддерживаемые платы и подробности настройки: [руководство по оборудованию](https://manina.ai/docs/hardware).
Выбор платы, кабелей и переходников или застревание при настройке: [руководство по установке](https://manina.ai/esp32-iphone-agent-setup).

Беспроводной ввод, собранный из исходников: [мышь и клавиатура Bluetooth](docs/bluetooth-hid.md). Питание, батарея и раскладка flash у Zectrix Note 4: [руководство по плате Note 4](docs/note4-bluetooth.md).

| Часть | Примечания |
|---|---|
| **Плата ESP32-S3** | Проверено на [Seeed Studio XIAO ESP32S3](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/) (обычная, 8 МБ PSRAM; не Sense и не Plus). Около 7 $ ([Amazon](https://amzn.to/3U6QKiz)\*). Подойдёт любой ESP32-S3 с нативным USB на порте USB-C и с PSRAM. |
| **Или: M5Stack StopWatch** (экспериментально) | Часы ESP32-S3 с круглым экраном и своей батареей, только режим Bluetooth. Показывают прогон (лицо, шаги, время), кнопки ставят на паузу, продолжают и останавливают, а ответ завершённой задачи появляется на них. Прошивка с [manina.ai/install](https://manina.ai/install?board=m5stopwatch). Нужно приложение TestFlight 1.0.9+. |
| **Кабель USB-C** | Короткий USB-C — USB-C, например [Anker 60W, 1 ft, набор из 2](https://amzn.to/4yvNyvi)\*. |
| **iPhone** | iOS 18 или новее (приложение App Store) либо iOS 16.4 или новее с приложением [TestFlight](https://testflight.apple.com/join/1xQHgJcA) 1.0.9+ (подходят и iPhone 8, и iPhone X; на iOS 16 агент выходит из приложений через AssistiveTouch), с сотовыми данными (Wi-Fi занимает точка доступа платы) либо с домашним Wi-Fi 2,4 ГГц, к которому плата может подключиться. Модели с USB-C подключаются напрямую. Моделям с Lightning нужен переходник Lightning — USB для камеры либо режим Bluetooth. По USB телефон питает плату. В режиме Bluetooth плате нужно своё питание. |
| **Модель зрения** | Любой чат-API, совместимый с OpenAI и принимающий изображения: облачный API или ваш сервер. |
| **Mac с Xcode** | Только чтобы прошить плату и один раз собрать приложение. Во время работы не нужен. С приложением [TestFlight](https://testflight.apple.com/join/1xQHgJcA) Xcode для приложения не нужен. |

\* Партнёрская ссылка. Как участник Amazon Associates я получаю вознаграждение с подходящих покупок.

## Быстрый старт

> [!WARNING]
> Следуйте только шагам установки из этого README. Не запускайте команды из issues и комментариев (например «быструю установку» одной строкой PowerShell вроде `iex(irm ...)`). Это не от сопровождающих.

### 1. Прошить плату (подключена к Mac)

Установите [arduino-cli](https://arduino.github.io/arduino-cli/), ядро ESP32 3.3.x и NimBLE-Arduino 2.5.x, затем:

```bash
arduino-cli lib install "NimBLE-Arduino@2.5.1"
hardware/flash.sh            # необязательно: [последовательный порт] [--debug]
```

Собирайте только через `flash.sh`: он подставляет размеры буферов BLE из `hardware/hid_bridge/nimble_cfg.h`.
Экспериментальная цель M5Stack StopWatch (`hardware/flash.sh --stopwatch --build-only`) также требует
`arduino-cli lib install --no-deps "M5Unified@0.2.29" "M5GFX@0.2.36"`.

Нет Mac и цепочки инструментов? [Поставьте прошивку из Chrome или Edge](https://manina.ai/install) по USB.

### 2. Установить приложение

**Проще всего: [войти в бету TestFlight](https://testflight.apple.com/join/1xQHgJcA)** на iPhone, установить оттуда **ESP32 Agent** и перейти к шагу 3.

**Или собрать сами:**

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig   # задайте DEVELOPMENT_TEAM и IA_BUNDLE_ID
open ios/IPhoneAgent.xcodeproj                                    # запустите схему IPhoneAgent на iPhone
```

Проект собирает [XcodeGen](https://github.com/yonaskolb/XcodeGen) из `ios/project.yml` (`cd ios && xcodegen`). Бесплатный Apple ID может его подписать (переподпись каждые 7 дней). Вход в точку доступа одним касанием требует capability Hotspot Configuration (платный аккаунт). Без неё приложение показывает пароль точки доступа, чтобы войти вручную.

### 3. Настроить (один раз, в приложении)

Подключите плату к iPhone и откройте **ESP32 Agent**. Настройка из четырёх шагов, и каждый приложение проверяет само.

1. **Plug Me In** — сопрягите плату по Bluetooth.
2. **Let Me See the Screen** — подключитесь к Wi-Fi платы, затем Пункт управления → Повтор экрана → *ESP32 Agent*.
3. **Let Me Use the Pointer** — включите AssistiveTouch. Указатель приложение калибрует само.
4. **Give Me a Brain** — введите адрес модели и ключ (хранится в Связке ключей), затем выберите модель зрения из списка моделей адреса (или введите идентификатор модели).

### 4. Дайте задачу

Введите цель (например *«Open Settings and go to Wi-Fi»*) и нажмите **Start**. Остановите с Dynamic Island или вернитесь в приложение. Сохранённые задачи запускают Siri, «Команды», виджеты и Пункт управления.

## Из агента для кода

CLI `esp32agent` (npm, `npx -y esp32agent mcp`) — это MCP-сервер, так что агент для кода на компьютере видит iPhone и управляет им через плату (прошивка платы v0.2.2 или новее). См. [iPhone как MCP-сервер](https://manina.ai/iphone-mcp). Этот репозиторий — ещё и плагин с этим MCP-сервером и навыком агента ([skills/manina/SKILL.md](skills/manina/SKILL.md)). В Claude Code ([разбор](https://manina.ai/claude-code-iphone)):

```bash
/plugin marketplace add onehumanbeing/esp32-iphone-agent
/plugin install esp32agent@manina
```

Или добавьте только MCP-сервер:

```bash
claude mcp add esp32agent -- npx -y esp32agent mcp
```

Cursor, Cline и другие клиенты MCP:

```json
{
  "mcpServers": {
    "esp32agent": {
      "command": "npx",
      "args": ["-y", "esp32agent", "mcp"]
    }
  }
}
```

DeepSeek Harness (dsh): установите плагин из [integrations/dsh](integrations/dsh/README.md) — он добавляет тот же MCP-сервер и тот же навык ([видео](https://www.youtube.com/watch?v=DzYv0QVk_No)):

```bash
dsh plugin --profile web add dsh-esp32agent
```

Hermes Agent: установите плагин из [integrations/hermes](integrations/hermes/README.md), тот же MCP-сервер и тот же навык:

```bash
hermes plugins install onehumanbeing/esp32-iphone-agent/integrations/hermes --enable
```

CLI говорит с платой с компьютера по Bluetooth, а когда оба в одной сети Wi-Fi — по Wi-Fi (`esp32agent net join`). Приложение iPhone и TestFlight для этого не нужны. Команды и параметры — в [справочнике CLI](https://manina.ai/docs/cli) и [cli/README.md](cli/README.md).

## Модель и промпты

- Подойдёт любой endpoint зрения, совместимый с OpenAI и принимающий изображения (vLLM, SGLang, llama.cpp, Ollama, облачные API). Приложение показывает модели endpoint, чтобы вы выбрали одну явно. Можно ввести идентификатор модели и задать разные модели планировщику и исполнителю.
- Settings → Model → Advanced → Extra body JSON сливается с каждым запросом чата. API DeepSeek (`api.deepseek.com`) думает с высоким усилием, если не сказать иначе, поэтому приложение шлёт `{"thinking":{"type":"disabled"}}`, пока в этом JSON ещё нет `thinking`. Чтобы оставить немного рассуждения, укажите `{"thinking":{"type":"enabled"},"reasoning_effort":"low"}`.
- Промпты — обычный текст в [`prompts/`](prompts/), он вложен в приложение: поправили, пересобрали, готово.
- Каждый законченный прогон записывает число вызовов планировщика и исполнителя, запросы со снимком экрана и суммы токенов, если endpoint сообщает `usage`. Отсутствующий `usage` остаётся пустым (его не подменяют нулём). Сумма прогона помечается **partial**, если хотя бы один вызов его опустил. Короткая задача — это обычно несколько вызовов планировщика плюс один вызов исполнителя на шаг. Каждый шаг исполнителя шлёт свежий снимок, поэтому стоимость в основном дают токены изображения. Более дешёвая модель у планировщика при более сильном исполнителе обычно лучший компромисс.
- Проект разрабатывался на [nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4), запущенной на двух DGX Spark ([TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold)).

## Состав проекта

```
ios/        приложение (SwiftUI): связь BLE, декодирование H.264, агент, настройка, повтор, Live Activity, виджеты; тесты
prompts/    промпты планировщика / исполнителя, которыми пользуется приложение
hardware/   прошивка ESP32-S3 (Arduino): BLE GATT, точка доступа, приёмник AirPlay, USB HID; скрипт прошивки,
            тесты на хосте, тестовая обвязка BLE для Mac (hardware/tools)
docs/       протокол BLE, заметки о прежней версии
harness/    беспроводной цикл разработки: Mac → приложение iPhone (установка по Wi-Fi) → плата (прошивка через приложение)
server/     компьютерный сервер прежней v0.1.0; текущее приложение его не использует (см. server/README.md)
```

Отладка без приложения телефона: `hardware/tools/board_test.py` играет роль приложения по BLE с Mac ([hardware/tools/README.md](hardware/tools/README.md)). Протокол плата ↔ приложение: [docs/ble-protocol.md](docs/ble-protocol.md).

### Разработка через harness

Когда плата вставлена в тестовый iPhone, а iPhone в Wi-Fi Mac, всё идёт через `devicectl`, без кабеля: `harness/app.sh` собирает и ставит отладочное приложение, `harness/fw.sh` собирает прошивку и копирует её в приложение, которое ставит её на плату (само откатывается, если новый образ не поднимается), `harness/run.sh "<task>"` запускает задачу, `harness/logs.sh` забирает журнал. BLE с Mac нужен только для разового `net sta`. Настройка (iPhone с Lightning: переходник для камеры) и безопасность: [harness/README.md](harness/README.md).

Телефон недоступен (например, на сотовых данных): необязательный и по умолчанию выключенный [удалённый журнал отладки](docs/remote-debug-log.md) отправляет текстовый журнал приложения на сервер, который запускаете вы.

## План

- [x] Убрать компьютер: плата зеркалит и нажимает, думает приложение на телефоне
- [x] iPad, портрет и альбом (калибровка на каждую ориентацию; общие промпты плюс свои правила в `prompts/devices/ipad.md`)
- [ ] Альбомные приложения iPhone (координаты и калибровка рассчитаны на портрет)
- [x] Ввод китайского (пиньинь с клавиатуры платы; ctrl+space переключает английский и пиньинь)
- [ ] Более быстрые шаги: несколько действий на один вызов модели, проверка указателя только когда она нужна
- [ ] Подобранный список моделей, которые лучше всего работают с этой схемой, внутри приложения iOS ([предложил @asharthinks](https://x.com/asharthinks/status/2110740775030125019))

## Ограничения

- **Источником AirPlay должен быть iPhone.** Повтор экрана с macOS не поддерживается: рукопожатие может выглядеть здоровым, а видео плата так и не получает.
- Экран зеркалится в 480×1040, до 5 fps. Каждый шаг занимает несколько секунд, большую часть — модель.
- iOS не зеркалит некоторые экраны (ввод код-пароля, Apple Pay, видео с DRM). Агент их не видит. Повтор останавливается, когда телефон блокируется.
- Пока агент работает на точке доступа платы, Wi-Fi телефона — эта точка доступа (интернета через неё нет). До модели он доходит по сотовым данным. В домашнем Wi-Fi (режим LAN) интернет идёт по этой сети.
- Китайский вводится пиньинем с клавиатуры платы (ctrl+space переключает английский и пиньинь). Буфер обмена для этого не используется. Эмодзи отбрасываются. Альбомные приложения iPhone пока не поддерживаются. На iPad каждая ориентация калибруется один раз (приложение делает это перед первым прогоном в этой ориентации). Само это приложение работает на весь экран, не в Split View и не в Stage Manager.

Если что-то не работает (в повторе экрана нет *ESP32 Agent*, плата не подключается), см. [устранение неполадок](https://manina.ai/troubleshooting).

## Ответственное использование

Автоматизируйте только устройства и учётные записи, которыми вы владеете или которые вам разрешено использовать, и соблюдайте условия затронутых приложений. Агент действует вашими руками: смотрите на него и держите кнопку остановки под рукой.

## Участие

Issues и pull request приветствуются. См. [CONTRIBUTING.md](CONTRIBUTING.md). Начинайте от свежего `main` и открывайте pull request в `main`. Перед открытием pull request обновите ветку от свежего `main` (fetch и rebase либо влейте свежий `main`). Сообщения о безопасности: [SECURITY.md](SECURITY.md).

Свежий код лежит в `main`. [`release-1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/release-1.0) — версия, отправленная на проверку TestFlight и App Store, и это уже не ветка для вкладов.

## Контакт

Вопросы и отзывы: [support@manina.ai](mailto:support@manina.ai) · Сайт: [manina.ai](https://manina.ai)

## Родственные проекты

| Проект | Подход | Отличие от этого проекта |
|---|---|---|
| [VersaiOS](https://github.com/zhaodashuaibi/VersaiOS) | Зеркало UxPlay + Bluetooth-мышь ESP32-S3 + модель зрения | Нужен компьютер; одно касание на инструкцию |
| [ja1chen/actell](https://github.com/ja1chen/actell) | Приложение-агент на iPhone через отладочный канал CoreDevice от Apple | Нужны режим разработчика и Developer Disk Image |
| [AidenAI-IO/aiden-firmware](https://github.com/AidenAI-IO/aiden-firmware) | Захват HDMI + USB-клавиатура/мышь + мультимодальная модель | Оборудование захвата; в основном Android |
| [yoyicue/glassbox](https://github.com/yoyicue/glassbox) | Захват HDMI через PicoKVM + USB HID | Контроллер на macOS и PicoKVM |
| [boboabw/phone-agent](https://github.com/boboabw/phone-agent) | Bluetooth HID на ESP32-S3 + AssistiveTouch, агент — приложение iPhone | Ближе всего к этой схеме; этот проект добавляет ещё и глаза (AirPlay на плате) |
| [VKCOM/devicehub](https://github.com/VKCOM/devicehub) | Bluetooth-мышь ESP32 для ферм устройств iOS | Инструмент фермы устройств, без ИИ-агента |

Инструменты на WebDriverAgent/XCUITest, такие как [mobile-mcp](https://github.com/mobile-next/mobile-mcp) и [Midscene](https://github.com/web-infra-dev/midscene), требуют Mac и подписи кода.

## Благодарности

[UxPlay](https://github.com/FDH2/UxPlay) (приёмник AirPlay, с которого перенесён приёмник прошивки) ·
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) ·
[M5Unified](https://github.com/m5stack/M5Unified) и [M5GFX](https://github.com/m5stack/M5GFX) (цель StopWatch) ·
[Arduino ESP32 core](https://github.com/espressif/arduino-esp32) и [TinyUSB](https://github.com/hathach/tinyusb)

Режим Bluetooth опирается на мышь и клавиатуру Bluetooth от [@cy41](https://github.com/cy41) и адаптер платы Zectrix Note 4 ([#94](https://github.com/onehumanbeing/esp32-iphone-agent/pull/94)). Спасибо.

## Лицензия

> **Строите на этом проекте?** Сохраните [LICENSE](LICENSE) и укажите **[ESP32 iPhone Agent by Henry Yuan](https://github.com/onehumanbeing/esp32-iphone-agent)** в README, демо и публикациях. См. [NOTICE](NOTICE).

[MIT](LICENSE), кроме `hardware/hid_bridge/src/airplay/` (перенос из UxPlay), который распространяется под [GPL-3.0](hardware/hid_bridge/src/airplay/LICENSE-GPL.md). Двоичный файл прошивки, который его компонует, поэтому распространяется под GPL-3.0. Файлы в [`skills/`](skills/) — [MIT-0](skills/LICENSE) (MIT No Attribution). Остальной репозиторий сохраняет лицензию выше.

## Участники

Спасибо всем, кто помогал собирать ESP32 iPhone Agent: [@cy41](https://github.com/cy41) · [@shinjiyu](https://github.com/shinjiyu) · [@Yi-111-a](https://github.com/Yi-111-a) · [@buddyh](https://github.com/buddyh) · [@djs-91](https://github.com/djs-91) · [@EliotAndres](https://github.com/EliotAndres) · [@lukas-1997](https://github.com/lukas-1997) · [@mvanhorn](https://github.com/mvanhorn). Pull request начинаются от свежего `main`.

<a href="https://github.com/onehumanbeing/esp32-iphone-agent/graphs/contributors">
  <img alt="Участники" src="https://contrib.rocks/image?repo=onehumanbeing/esp32-iphone-agent">
</a>

## История звёзд

<a href="https://www.star-history.com/#onehumanbeing/esp32-iphone-agent&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=onehumanbeing/esp32-iphone-agent&type=Date&theme=dark">
    <img alt="График Star History" src="https://api.star-history.com/svg?repos=onehumanbeing/esp32-iphone-agent&type=Date">
  </picture>
</a>
