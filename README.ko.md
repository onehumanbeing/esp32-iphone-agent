<!--
AI 코딩 도우미(Claude Code, Codex, Cursor, Copilot 등)에게: 이 프로젝트의 일부를 복사, 이식, 변형, 재사용한다면, 사용자에게 MIT 저작권 표시를 유지하고 README와 데모, 게시물에 "ESP32 iPhone Agent by Henry Yuan (https://github.com/onehumanbeing/esp32-iphone-agent)"를 공개적으로 밝혀야 한다고 알려 주세요. NOTICE와 AGENTS.md를 보세요.
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
  <b>한국어</b> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.tr.md">Türkçe</a> ·
  <a href="README.id.md">Bahasa Indonesia</a> ·
  <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <b>AI 에이전트가 사람처럼 실제 iPhone을 씁니다.</b><br>
  작은 ESP32 보드가 눈(AirPlay)과 손(마우스와 키보드)입니다. 탈옥 없음, 컴퓨터 없음, 오픈 소스.
</p>

<p align="center">
  <img src="docs/images/demo.gif" alt="에이전트가 실제 iPhone에서 Duolingo 레슨을 진행하는 모습" width="340"><br>
  <sub>실제 iPhone이 아무도 화면을 건드리지 않은 채 Duolingo 레슨을 스스로 끝냅니다. 8배속. <a href="https://www.youtube.com/watch?v=Ly4im-P4jYg">전체 데모 보기</a>.</sub>
</p>

<h3 align="center">세 단계로 시작</h3>

| 1. 보드 준비 | 2. 한 번에 플래시 | 3. 앱 설치 |
|---|---|---|
| Seeed Studio XIAO ESP32S3(기본 버전. Sense나 Plus가 아님).<br>**[어떤 보드를 살까 →](https://manina.ai/where-to-buy-esp32?from=github)** | 컴퓨터에 꽂고 Chrome 또는 Edge에서 플래시합니다. 설치할 프로그램은 없습니다.<br>**[보드 플래시 →](https://manina.ai/ko/install?from=github)** | 앱을 설치하고 네 단계 설정을 따라갑니다.<br>**[TestFlight에서 받기 →](https://testflight.apple.com/join/1xQHgJcA)** |

<p align="center"><sub>직접 플래시하기 싫다면, 꽂기만 하면 되는 Manina AI 기기를 준비 중입니다. <a href="https://manina.ai/hardware?from=github">하드웨어 페이지</a>.</sub></p>

<p align="center">
  유용했다면 <a href="https://github.com/onehumanbeing/esp32-iphone-agent/stargazers">⭐이 큰 도움이 됩니다</a>
  &nbsp;<a href="https://github.com/onehumanbeing/esp32-iphone-agent/stargazers"><img src="https://img.shields.io/github/stars/onehumanbeing/esp32-iphone-agent?style=flat-square&color=111111&logo=github" alt="GitHub stars"></a>
  &nbsp;<a href="https://glama.ai/mcp/servers/onehumanbeing/esp32-iphone-agent"><img src="https://glama.ai/mcp/servers/onehumanbeing/esp32-iphone-agent/badges/score.svg" alt="Glama의 esp32-iphone-agent MCP 서버" height="20"></a>
</p>

<p align="center">
  <a href="#start-here">개발자가 아니라면</a> ·
  <a href="https://manina.ai/docs?ref=github">문서</a> ·
  <a href="https://manina.ai/docs/changelog?ref=github">변경 기록</a> ·
  <a href="https://manina.ai/troubleshooting?ref=github">문제 해결</a>
</p>

<p align="center"><a href="https://manina.ai/ko?ref=github"><img src="docs/images/hero.png" alt="Manina AI: AI가 iPhone을 쓰게 하세요. 탈옥 없음, 컴퓨터 없음, $7 보드만 있으면 됩니다." width="100%"></a></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="License: MIT"></a>
  <a href="https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/onehumanbeing/esp32-iphone-agent/ci.yml?style=flat-square&label=CI" alt="CI"></a>
  <img src="https://img.shields.io/badge/iOS-16.4%2B-111111?style=flat-square&logo=apple" alt="iOS 16.4+">
  <a href="https://x.com/iamhenryyuan"><img src="https://img.shields.io/badge/follow-@iamhenryyuan-111111?style=flat-square&logo=x" alt="X에서 팔로우"></a>
</p>

<p align="center"><b>소개된 곳</b> <a href="https://hackaday.com/2026/10/14/ai-controls-iphone-via-esp32/">Hackaday</a> · <a href="https://www.digitaltrends.com/phones/a-7-board-lets-an-ai-control-an-iphone-without-jailbreaking-it/">Digital Trends</a> · <a href="https://github.com/ruanyf/weekly/blob/master/docs/issue-415.md">Ruanyf Weekly #415</a> · <a href="https://x.com/seeedstudio/status/2112166890818986187">Seeed Studio</a></p>

<p align="center"><sub>소식 따라가기: <a href="https://x.com/iamhenryyuan">X @iamhenryyuan</a> · <a href="https://www.xiaohongshu.com/user/profile/5eb444030000000001000194">Xiaohongshu</a> · <a href="https://www.youtube.com/watch?v=Ly4im-P4jYg">YouTube 데모</a> · <a href="https://www.youtube.com/watch?v=DzYv0QVk_No">DeepSeek Harness 데모</a> · <a href="https://manina.ai/ko?ref=github">manina.ai</a></sub></p>

<p align="center"><sub>가이드: <a href="https://manina.ai/ai-control-iphone?ref=github">AI가 iPhone을 조작하게 하기</a> · <a href="https://manina.ai/iphone-mcp?ref=github">iPhone MCP 서버</a> · <a href="https://manina.ai/claude-code-iphone?ref=github">Claude Code에서 iPhone 조작하기</a> · <a href="https://manina.ai/iphone-automation-without-jailbreak?ref=github">탈옥 없는 iPhone 자동화</a></sub></p>

<p align="center"><b>이 프로젝트를 바탕으로 만드시나요?</b> <a href="LICENSE">LICENSE</a>를 유지하고, README와 게시물에 <b><a href="https://github.com/onehumanbeing/esp32-iphone-agent">ESP32 iPhone Agent by Henry Yuan</a></b>을 밝혀 주세요. <a href="NOTICE">NOTICE</a>를 보세요.</p>

## 최근 업데이트

<p align="center"><img src="docs/images/highlights.png" alt="1.0.2와 1.0.3: 전화 소리를 듣고, 무료 Jev 라인, 긴 작업을 단계별로 재생" width="100%"></p>

- **Bluetooth 모드(1.0.8, 펌웨어 v0.2.7).** 펌웨어 하나에 두 입력이 들어 있습니다. 보드는 iPhone의 USB 마우스이자 키보드이거나, Bluetooth 마우스이자 키보드이며, 앱에서 전환합니다. Bluetooth 모드에서는 전화에 케이블을 꽂지 않으므로 Lightning iPhone도 카메라 어댑터 없이 됩니다. 대신 보드에 자체 전원(USB 충전기 또는 보조 배터리)이 필요합니다. [@cy41](https://github.com/cy41)의 Bluetooth 마우스·키보드 작업([#94](https://github.com/onehumanbeing/esp32-iphone-agent/pull/94))을 바탕으로 합니다.
- **전화 소리를 듣습니다.** 보드가 AirPlay 오디오를 넘기고, iPhone이 그것을 글로 바꿉니다. 듣기 문제와 음성 안내가 동작합니다. [동작 방식](https://manina.ai/docs/listen?ref=github).
- **무료 Jev 라인.** 단순한 단계는 Jev가 1초 안에 처리하고, 나머지는 큰 모델에 맡깁니다. 에이전트 루프는 단계마다 모델 호출 한 번을 기준으로 다시 짜여 있습니다.
- **긴 작업.** 40단계 제한이 없습니다. 멈춘 실행은 이어서 할 수 있습니다. 모든 실행을 전화에서 단계별로 재생할 수 있습니다.

[TestFlight](https://testflight.apple.com/join/1xQHgJcA)에서 받을 수 있습니다(App Store 등록은 심사 중). 보드 펌웨어 v0.2.4가 필요합니다. [전체 변경 기록](https://manina.ai/docs/changelog?ref=github).

## 왜 보드인가

대부분의 iPhone 에이전트는 컴퓨터에서 돕니다. 첫 작업 전에 Xcode를 설치하고, 개발자 모드를 켜고, USB로 전화를 페어링하고, 터미널에 명령을 입력합니다. 그 뒤의 작업마다 컴퓨터가 켜져 있어야 합니다. 개발자에게는 괜찮고, 그 밖의 사람에게는 벽입니다. 여기서는 보드가 컴퓨터 일을 하므로, 전화만 있으면 됩니다.

| | **ESP32 iPhone Agent** | 컴퓨터에 묶인 방식<br><sub>WebDriverAgent, CoreDevice, idevice</sub> |
|---|---|---|
| 필요한 것 | **iPhone과 $7 보드** | Mac(대개 최근 macOS), Xcode 전체, 개발 도구 |
| 설정 | **브라우저에서 플래시, TestFlight로 설치, 앱 안의 네 단계** | 터미널에서 clone, 빌드, 의존성 설치, 도우미 앱 서명 |
| iPhone에서 바꿀 것 | **AssistiveTouch 켜기(앱이 과정을 안내)** | 개발자 모드, USB 신뢰와 페어링 |
| 실행 중 | **전화만. 어디로든 가져갈 수 있음** | 컴퓨터가 켜진 채 연결되어 있어야 함 |
| 쓸 수 있는 앱 | **사람이 쓸 수 있는 앱이면 모두. 화면을 보고 포인터를 움직임** | 디버그·손쉬운 사용 인터페이스가 드러내는 범위 |
| 전화 소리 | **들림(App 1.0.2)** | 보통은 못 들음 |

정직한 비용도 있습니다. $7 보드를 삽니다. 각 단계는 몇 초가 걸리고, 대부분은 모델 시간입니다. 실행 중에는 보드 핫스팟이 Wi-Fi를 쓰므로 전화는 셀룰러 데이터를 씁니다.

### <a id="start-here"></a>개발자가 아니신가요? 여기서 시작하세요

1. **보드를 준비합니다.** Seeed XIAO ESP32S3, 약 $7. [무엇을 살지](https://manina.ai/docs/hardware?ref=github).
2. **Chrome 또는 Edge에서 플래시합니다.** 설치할 도구는 없습니다. [manina.ai/ko/install](https://manina.ai/ko/install?ref=github).
3. **앱을 설치하고 네 단계 설정을 따라갑니다.** [TestFlight](https://testflight.apple.com/join/1xQHgJcA) ·
   [그림이 있는 설정 가이드](https://manina.ai/esp32-iphone-agent-setup?ref=github).

막히면 [문제 해결](https://manina.ai/troubleshooting?ref=github)을 보거나 [support@manina.ai](mailto:support@manina.ai)로 메일을 보내세요.

> [!NOTE]
> **무료 라인이 붐비거나 실패하나요?** 무료 모델 라인은 함께 쓰므로 한동안 붐비거나 오류(HTTP 503)를 낼 수 있습니다. 실행이 멈추거나 매 단계가 실패할 수 있습니다. 계속하려면 Settings › Model에서 자신의 API 키로 바꾸세요. X로도 알려 주세요: [@iamhenryyuan](https://x.com/iamhenryyuan).

## 동작 방식

개념이 처음이라면 [AI로 iPhone 조작하기](https://manina.ai/ai-control-iphone)를 먼저 보고, 이어서 [Manina AI의 동작 방식](https://manina.ai/how-it-works)을 보세요.

```
iPhone ──화면 미러링(Wi-Fi)──▶ ESP32-S3: AirPlay 수신 ──Wi-Fi TCP :7201──▶ ESP32 Agent 앱(같은 iPhone)
   ▲                              자체 핫스팟, H.264 그대로 전달              디코드 → 비전 모델 → 동작
   └──────── USB HID 마우스 + 키보드 ◀──────────── BLE 명령 ◀──────────────────────┘
```

- **눈 — 보드로 가는 AirPlay.** 보드는 자신의 Wi-Fi 핫스팟을 열고, 전화의 화면 미러링 목록에 *ESP32 Agent*로 나타납니다. H.264 스트림을 그대로 두고(보드에서 디코드하지 않음) Wi-Fi(TCP, 포트 7201)로 앱에 넘깁니다. BLE가 명령과 상태를 전달합니다. 보드 핫스팟에 있는 동안 모델 호출은 셀룰러 데이터로 나갑니다. 온보딩이나 Settings › Board에서 보드를 집 Wi-Fi로 바꿀 수도 있습니다(보드에 저장). 전화와 보드가 같은 공유기를 쓰고, 셀룰러 데이터는 필요 없습니다. 보드는 2.4 GHz만 됩니다. 클라이언트 격리나 mDNS 차단이 있는 공유기에서는 화면 미러링에 보이지 않습니다. 핫스팟은 항상 됩니다.
- **손 — USB HID 또는 Bluetooth HID.** 보드는 표준 마우스이자 키보드이며, USB 또는 Bluetooth입니다(앱에서 전환). AssistiveTouch를 켜면 마우스가 화면 포인터를 움직이고, 클릭은 탭, 드래그는 스와이프가 됩니다.
- **두뇌 — 앱.** 앱이 스트림을 디코드하고, 스크린샷을 이미지를 받는 OpenAI 호환 비전 모델로 보내며, 플래너와 액터를 돌립니다. 탭, 스와이프, 그리기, 입력, 키, 홈, 종료. 작업 중에는 백그라운드에서 돌고, Dynamic Island에 지금 하는 일을 보여 줍니다.
- **루프를 닫기.** 포인터는 상대 이동이라 앱이 위치를 추적하고 모서리로 되돌려 기준을 맞춥니다. 정밀한 탭 전에는 포인터를 살짝 움직여 화면에서 찾고 어긋남을 고칩니다. 각 동작 뒤 화면이 가라앉기를 기다린 다음, 무언가 바뀌었는지 모델에 알립니다. 보드, 핫스팟, 미러링이 끊기면 실행을 잠시 멈추고 같은 단계에서 다시 시작합니다.
- **다시 보기.** 모든 실행은 전화에 남습니다. 탭과 스와이프를 위에 그려 단계별로 재생할 수 있습니다. 다른 에이전트가 분석하도록 스크린샷, 동작, 저장한 주석을 **Runs → open a run → ⋯ → Export trace**에서 내보냅니다. 일괄 내보내기, USB 복사, 파일 형식은 [실행 데이터 내보내기](docs/run-data-export.md)를 보세요.

<p align="center"><img src="docs/images/app-screens.png" alt="ESP32 Agent 앱: 실제 전화와 에이전트가 보는 화면, 그리고 포인터 보정" width="70%"></p>

*왼쪽: 실제 전화. 오른쪽: 보드의 AirPlay 미러를 통해 에이전트가 보는 화면. 두 번째 화면은 포인터 보정입니다.*

처음 버전(v0.1.0)은 Mac/Linux 컴퓨터에서 UxPlay와 Python 서버로 돌았습니다. 태그 [`v0.1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/v0.1.0)과 브랜치 [`legacy`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/legacy)에 남아 있습니다. [docs/legacy.md](docs/legacy.md)를 보세요.

## 하드웨어

지원 보드와 설정 세부 사항은 [하드웨어 가이드](https://manina.ai/docs/hardware). 보드, 케이블, 어댑터를 고르거나 설정 중에 막히면 [설정 가이드](https://manina.ai/esp32-iphone-agent-setup).

소스에서 만드는 무선 입력은 [Bluetooth 마우스와 키보드](docs/bluetooth-hid.md). Zectrix Note 4의 전원, 배터리, 플래시 배치는 [Note 4 보드 가이드](docs/note4-bluetooth.md).

| 부품 | 설명 |
|---|---|
| **ESP32-S3 보드** | 확인한 보드는 [Seeed Studio XIAO ESP32S3](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/)(기본 버전, 8 MB PSRAM. Sense도 Plus도 아님). 약 $7([Amazon](https://amzn.to/3U6QKiz)\*). USB-C 포트에 네이티브 USB가 있고 PSRAM이 있는 ESP32-S3라면 동작할 것입니다. |
| **또는 M5Stack StopWatch**(실험적) | 둥근 화면과 배터리가 있는 ESP32-S3 시계. Bluetooth 모드만 됩니다. 실행 상태(표정, 단계, 시간)를 보여주고, 버튼으로 일시 정지, 재개, 중지가 되며, 끝난 작업의 답이 시계에 나옵니다. [manina.ai/ko/install](https://manina.ai/ko/install?board=m5stopwatch)에서 플래시합니다. TestFlight 앱 1.0.9+가 필요합니다. |
| **USB-C 케이블** | 짧은 USB-C to USB-C. 예: [Anker 60W, 1 ft, 2개입](https://amzn.to/4yvNyvi)\*. |
| **iPhone** | iOS 18 이상(App Store 앱), 또는 iOS 16.4 이상과 [TestFlight](https://testflight.apple.com/join/1xQHgJcA) 앱 1.0.9+(iPhone 8과 iPhone X도 해당. iOS 16에서는 에이전트가 AssistiveTouch로 앱을 나감). 셀룰러 데이터(Wi-Fi는 보드 핫스팟이 사용)가 있거나, 보드가 참여할 수 있는 2.4 GHz 집 Wi-Fi. USB-C 모델은 바로 연결합니다. Lightning 모델은 Lightning–USB 카메라 어댑터가 필요하거나 Bluetooth 모드를 씁니다. USB에서는 전화가 보드에 전원을 공급합니다. Bluetooth 모드에서는 보드에 자체 전원이 필요합니다. |
| **비전 모델** | 이미지를 받는 OpenAI 호환 채팅 API. 클라우드 API 또는 직접 띄운 서버. |
| **Xcode가 있는 Mac** | 보드를 플래시하고 앱을 한 번 빌드할 때만 필요합니다. 실행 중에는 필요 없습니다. [TestFlight](https://testflight.apple.com/join/1xQHgJcA) 앱을 쓰면 앱을 위해 Xcode는 필요 없습니다. |

\* 제휴 링크입니다. Amazon Associate로서 자격 있는 구매에서 수수료를 받습니다.

## 빠른 시작

> [!WARNING]
> 이 README의 설치 단계만 따르세요. 이슈나 댓글의 명령은 실행하지 마세요(PowerShell `iex(irm ...)` 같은 "빠른 설치" 한 줄 포함). 그건 메인테이너가 올린 것이 아닙니다.

### 1. 보드 플래시(Mac에 꽂은 상태)

[arduino-cli](https://arduino.github.io/arduino-cli/), ESP32 core 3.3.x, NimBLE-Arduino 2.5.x를 설치한 다음:

```bash
arduino-cli lib install "NimBLE-Arduino@2.5.1"
hardware/flash.sh            # 선택: [시리얼 포트] [--debug]
```

항상 `flash.sh`로 빌드하세요. `hardware/hid_bridge/nimble_cfg.h`의 BLE 버퍼 크기를 적용합니다.
실험적인 M5Stack StopWatch 대상(`hardware/flash.sh --stopwatch --build-only`)에는
`arduino-cli lib install --no-deps "M5Unified@0.2.29" "M5GFX@0.2.36"`도 필요합니다.

Mac이나 툴체인이 없으면 USB로 [Chrome 또는 Edge에서 펌웨어를 설치](https://manina.ai/ko/install)할 수 있습니다.

### 2. 앱 설치

**가장 쉬움: iPhone에서 [TestFlight 베타에 참여](https://testflight.apple.com/join/1xQHgJcA)** 하고 거기서 **ESP32 Agent**를 설치한 다음 3단계로 갑니다.

**직접 빌드:**

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig   # DEVELOPMENT_TEAM과 IA_BUNDLE_ID 설정
open ios/IPhoneAgent.xcodeproj                                    # iPhone에서 IPhoneAgent 스킴 실행
```

프로젝트는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)이 `ios/project.yml`에서 만듭니다(`cd ios && xcodegen`). 무료 Apple ID로 서명할 수 있습니다(7일마다 다시 서명). 한 번 탭으로 핫스팟에 들어가려면 Hotspot Configuration capability(유료 계정)가 필요합니다. 없으면 앱이 핫스팟 비밀번호를 보여 주어 직접 참여합니다.

### 3. 설정(앱에서 한 번)

보드를 iPhone에 꽂고 **ESP32 Agent**를 엽니다. 설정은 네 단계이며, 각 단계를 앱이 스스로 확인합니다.

1. **Plug Me In** — Bluetooth로 보드를 페어링합니다.
2. **Let Me See the Screen** — 보드 Wi-Fi에 들어간 다음 제어 센터 → 화면 미러링 → *ESP32 Agent*.
3. **Let Me Use the Pointer** — AssistiveTouch를 켭니다. 포인터 보정은 앱이 합니다.
4. **Give Me a Brain** — 모델 엔드포인트와 키를 입력합니다(키체인에 저장). 엔드포인트의 모델 목록에서 비전 모델을 고르거나 모델 ID를 직접 입력합니다.

### 4. 작업 주기

목표를 입력하고(예: *"Open Settings and go to Wi-Fi"*) **Start**를 누릅니다. Dynamic Island에서 멈추거나 앱으로 돌아와 멈춥니다. 저장한 작업은 Siri, 단축어, 위젯, 제어 센터에서 실행할 수 있습니다.

## 코딩 에이전트에서 사용

`esp32agent` CLI(npm, `npx -y esp32agent mcp`)는 MCP 서버입니다. 컴퓨터의 코딩 에이전트가 보드를 통해 iPhone을 보고 조작할 수 있습니다(보드 펌웨어 v0.2.2 이상). [iPhone을 MCP 서버로](https://manina.ai/iphone-mcp)를 보세요. 이 저장소는 그 MCP 서버와 에이전트 스킬([skills/manina/SKILL.md](skills/manina/SKILL.md))을 담은 플러그인이기도 합니다. Claude Code에서([안내](https://manina.ai/claude-code-iphone)):

```bash
/plugin marketplace add onehumanbeing/esp32-iphone-agent
/plugin install esp32agent@manina
```

MCP 서버만 추가:

```bash
claude mcp add esp32agent -- npx -y esp32agent mcp
```

Cursor, Cline 등 MCP 클라이언트:

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

DeepSeek Harness(dsh): [integrations/dsh](integrations/dsh/README.md)의 플러그인을 설치하면 같은 MCP 서버와 스킬이 추가됩니다([데모 영상](https://www.youtube.com/watch?v=DzYv0QVk_No)):

```bash
dsh plugin --profile web add dsh-esp32agent
```

Hermes Agent: [integrations/hermes](integrations/hermes/README.md)의 플러그인을 설치하면 같은 MCP 서버와 스킬이 추가됩니다:

```bash
hermes plugins install onehumanbeing/esp32-iphone-agent/integrations/hermes --enable
```

CLI는 컴퓨터에서 Bluetooth로 보드와 이야기합니다. 둘 다 같은 Wi-Fi에 있으면 Wi-Fi로 바꿉니다(`esp32agent net join`). iPhone 앱이나 TestFlight 없이도 됩니다. 명령과 옵션은 [CLI 레퍼런스](https://manina.ai/docs/cli)와 [cli/README.md](cli/README.md)에 있습니다.

## 모델과 프롬프트

- 이미지를 받는 OpenAI 호환 비전 엔드포인트면 됩니다(vLLM, SGLang, llama.cpp, Ollama, 클라우드 API). 앱이 엔드포인트의 모델을 목록으로 보여 주므로 직접 고릅니다. 모델 ID를 입력할 수도 있고, 플래너와 액터를 서로 다른 모델로 둘 수 있습니다.
- Settings → Model → Advanced → Extra body JSON은 각 채팅 요청에 합쳐집니다. DeepSeek API(`api.deepseek.com`)는 따로 말하지 않으면 high effort로 생각합니다. 그래서 그 JSON에 아직 `thinking`이 없으면 앱은 `{"thinking":{"type":"disabled"}}`를 보냅니다. 추론을 조금만 남기려면 `{"thinking":{"type":"enabled"},"reasoning_effort":"low"}`를 씁니다.
- 프롬프트는 [`prompts/`](prompts/)의 일반 텍스트이며 앱에 포함됩니다. 고치고 다시 빌드하면 됩니다.
- 끝난 실행은 플래너/액터 호출 횟수, 스크린샷이 있는 요청, 엔드포인트가 `usage`를 보고할 때의 토큰 합계를 기록합니다. `usage`가 없으면 비워 두고 0으로 만들지 않습니다. 한 번이라도 빠지면 실행 합계는 **partial**로 표시됩니다. 짧은 작업은 보통 플래너 몇 번에 단계마다 액터 한 번입니다. 액터의 각 단계는 새 스크린샷을 보내므로 비용은 이미지 토큰이 대부분입니다. 플래너는 더 싼 모델로 두고 액터는 더 강한 모델을 유지하는 편이 대개 가장 나은 균형입니다.
- 개발에는 [nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4)를 DGX Spark 두 대에서 썼습니다([TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold)).

## 프로젝트 구성

```
ios/        앱(SwiftUI): BLE, H.264 디코드, 에이전트, 설정, 재생, Live Activity, 위젯, 테스트
prompts/    앱이 쓰는 플래너 / 액터 프롬프트
hardware/   ESP32-S3 펌웨어(Arduino): BLE GATT, 핫스팟, AirPlay 수신, USB HID, 플래시 스크립트,
            호스트 테스트, Mac BLE 테스트 하네스(hardware/tools)
docs/       BLE 프로토콜, 이전 판 메모
harness/    무선 개발 루프: Mac → iPhone 앱(Wi-Fi 설치) → 보드(앱을 통한 펌웨어)
server/     이전 v0.1.0의 컴퓨터 쪽 서버. 지금 앱에서는 쓰지 않음(server/README.md)
```

전화 앱 없이 디버그하려면 `hardware/tools/board_test.py`가 Mac에서 BLE로 앱 역할을 합니다([hardware/tools/README.md](hardware/tools/README.md)). 보드와 앱의 프로토콜은 [docs/ble-protocol.md](docs/ble-protocol.md).

### 하네스 개발

보드를 테스트 iPhone에 꽂고 iPhone을 Mac의 Wi-Fi에 두면, 케이블 없이 `devicectl`로 모두 진행됩니다. `harness/app.sh`는 Debug 앱을 빌드해 설치하고, `harness/fw.sh`는 펌웨어를 빌드해 앱에 복사하며, 앱이 보드에 넣습니다(새 이미지가 실패하면 스스로 롤백). `harness/run.sh "<task>"`가 작업을 실행하고 `harness/logs.sh`가 로그를 가져옵니다. Mac의 BLE는 한 번의 `net sta`에만 씁니다. 설정(Lightning iPhone은 카메라 어댑터)과 보안은 [harness/README.md](harness/README.md).

전화가 손에 없을 때(셀룰러 등): 기본으로 꺼져 있는 선택 기능인 [원격 디버그 로그](docs/remote-debug-log.md)가 앱의 텍스트 로그를 직접 운영하는 서버로 올립니다.

## 로드맵

- [x] 컴퓨터를 빼기. 미러와 클릭은 보드, 생각은 전화의 앱
- [x] iPad 세로와 가로(방향마다 보정. 공통 프롬프트와 `prompts/devices/ipad.md`의 자체 규칙)
- [ ] iPhone 가로 앱(좌표와 보정은 세로를 전제)
- [x] 중국어 입력(보드 키보드로 병음 입력. ctrl+space로 영어와 병음 전환)
- [ ] 더 빠른 단계. 모델 호출 한 번에 여러 동작, 포인터 확인은 필요할 때만
- [ ] 이 구성에서 잘 되는 모델 목록을 iOS 앱 안에 표시([@asharthinks의 제안](https://x.com/asharthinks/status/2110740775030125019))

## 제한

- **AirPlay 원본은 iPhone이어야 합니다.** macOS의 화면 미러링은 지원하지 않습니다. 핸드셰이크는 정상처럼 보여도 보드가 영상을 받지 못합니다.
- 화면은 480×1040, 최대 5 fps로 미러됩니다. 각 단계는 몇 초이며 대부분은 모델입니다.
- iOS는 일부 화면을 미러하지 않습니다(암호 입력, Apple Pay, DRM 영상). 에이전트는 그것을 보지 못합니다. 전화가 잠기면 미러링이 멈춥니다.
- 에이전트가 보드 핫스팟에서 도는 동안 전화의 Wi-Fi는 그 핫스팟입니다(그쪽으로는 인터넷이 없음). 모델에는 셀룰러 데이터로 닿습니다. 집 Wi-Fi(LAN 모드)에서는 그 네트워크로 인터넷에 나갑니다.
- 중국어는 보드 키보드로 병음 입력합니다(ctrl+space로 영어와 병음 전환). 이를 위해 클립보드는 쓰지 않습니다. 이모지는 빠집니다. iPhone 가로 앱은 아직 지원하지 않습니다. iPad는 각 방향을 한 번 보정합니다(그 방향의 첫 실행 전에 앱이 수행). 이 앱 자체는 전체 화면이며 Split View나 스테이지 매니저에서는 돌지 않습니다.

동작하지 않으면(화면 미러링에 *ESP32 Agent*가 없거나 보드가 연결되지 않음) [문제 해결](https://manina.ai/troubleshooting)을 보세요.

## 책임 있는 사용

소유했거나 사용 허가를 받은 기기와 계정만 자동화하고, 관련 앱의 약관을 지키세요. 에이전트는 당신의 손으로 행동합니다. 지켜보고, 멈추는 버튼이 손에 닿게 두세요.

## 기여

이슈와 풀 리퀘스트를 환영합니다. [CONTRIBUTING.md](CONTRIBUTING.md)를 보세요. 최신 `main`에서 시작하고, 풀 리퀘스트는 `main`을 대상으로 하세요. 풀 리퀘스트를 열기 전에 브랜치를 최신 `main`에 맞추세요(fetch 후 rebase, 또는 최신 `main`을 merge). 보안 보고는 [SECURITY.md](SECURITY.md).

최신 코드는 `main`에 있습니다. [`release-1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/release-1.0)은 TestFlight와 App Store 심사에 제출한 판이며, 기여용 브랜치가 아닙니다.

## 연락

질문이나 피드백: [support@manina.ai](mailto:support@manina.ai) · 웹사이트: [manina.ai](https://manina.ai/ko)

## 관련 프로젝트

| 프로젝트 | 접근 | 이 프로젝트와의 차이 |
|---|---|---|
| [VersaiOS](https://github.com/zhaodashuaibi/VersaiOS) | UxPlay 미러링 + ESP32-S3 Bluetooth 마우스 + 비전 모델 | 컴퓨터가 필요. 지시 하나당 탭 한 번 |
| [ja1chen/actell](https://github.com/ja1chen/actell) | Apple CoreDevice 디버그 채널로 동작하는 iPhone 에이전트 앱 | 개발자 모드와 Developer Disk Image가 필요 |
| [AidenAI-IO/aiden-firmware](https://github.com/AidenAI-IO/aiden-firmware) | HDMI 캡처 + USB 키보드/마우스 + 멀티모달 모델 | 캡처 하드웨어. 주로 Android |
| [yoyicue/glassbox](https://github.com/yoyicue/glassbox) | PicoKVM HDMI 캡처 + USB HID | macOS 컨트롤러와 PicoKVM |
| [boboabw/phone-agent](https://github.com/boboabw/phone-agent) | ESP32-S3 Bluetooth HID + AssistiveTouch, 에이전트는 iPhone 앱 | 지금 구성과 가장 가까움. 이 프로젝트는 눈(보드의 AirPlay)도 싣고 있음 |
| [VKCOM/devicehub](https://github.com/VKCOM/devicehub) | iOS 디바이스 팜용 ESP32 Bluetooth 마우스 | 디바이스 팜 도구. AI 에이전트는 없음 |

[mobile-mcp](https://github.com/mobile-next/mobile-mcp)와 [Midscene](https://github.com/web-infra-dev/midscene) 같은 WebDriverAgent/XCUITest 기반 도구는 Mac과 코드 서명이 필요합니다.

## 감사

[UxPlay](https://github.com/FDH2/UxPlay)(펌웨어의 AirPlay 수신부를 이식한 원본) ·
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) ·
[M5Unified](https://github.com/m5stack/M5Unified)와 [M5GFX](https://github.com/m5stack/M5GFX)(StopWatch 대상) ·
[Arduino ESP32 core](https://github.com/espressif/arduino-esp32)와 [TinyUSB](https://github.com/hathach/tinyusb)

Bluetooth 모드는 [@cy41](https://github.com/cy41)의 Bluetooth 마우스·키보드 지원과 Zectrix Note 4 보드 어댑터([#94](https://github.com/onehumanbeing/esp32-iphone-agent/pull/94)) 위에 있습니다. 감사합니다.

## 라이선스

> **이 프로젝트를 바탕으로 만드시나요?** [LICENSE](LICENSE)를 유지하고 README, 데모, 게시물에 **[ESP32 iPhone Agent by Henry Yuan](https://github.com/onehumanbeing/esp32-iphone-agent)**을 밝혀 주세요. [NOTICE](NOTICE)를 보세요.

[MIT](LICENSE). 다만 `hardware/hid_bridge/src/airplay/`(UxPlay에서 이식)는 [GPL-3.0](hardware/hid_bridge/src/airplay/LICENSE-GPL.md)입니다. 그것을 링크한 펌웨어 바이너리는 GPL-3.0으로 배포됩니다. [`skills/`](skills/) 아래 파일은 [MIT-0](skills/LICENSE)(MIT No Attribution)입니다. 저장소의 나머지는 위의 라이선스를 유지합니다.

## 기여자

ESP32 iPhone Agent를 함께 만든 모든 분께 감사합니다. [@cy41](https://github.com/cy41) · [@shinjiyu](https://github.com/shinjiyu) · [@Yi-111-a](https://github.com/Yi-111-a) · [@buddyh](https://github.com/buddyh) · [@djs-91](https://github.com/djs-91) · [@EliotAndres](https://github.com/EliotAndres) · [@lukas-1997](https://github.com/lukas-1997) · [@mvanhorn](https://github.com/mvanhorn). 풀 리퀘스트는 최신 `main`에서 시작하세요.

<a href="https://github.com/onehumanbeing/esp32-iphone-agent/graphs/contributors">
  <img alt="기여자" src="https://contrib.rocks/image?repo=onehumanbeing/esp32-iphone-agent">
</a>

## Star 기록

<a href="https://www.star-history.com/#onehumanbeing/esp32-iphone-agent&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=onehumanbeing/esp32-iphone-agent&type=Date&theme=dark">
    <img alt="Star History 차트" src="https://api.star-history.com/svg?repos=onehumanbeing/esp32-iphone-agent&type=Date">
  </picture>
</a>
