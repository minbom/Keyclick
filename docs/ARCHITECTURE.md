# Keyclick — 구조

전체가 `Sources/main.swift` 한 파일 약 430줄이다. Xcode 프로젝트 파일 없이
`swiftc` 직접 호출 + 번들 수동 조립으로 빌드한다. 규모가 작아 그게 더 들여다보기 쉽다.

```
~/Programs/Keyclick/
├── Sources/main.swift    전체 로직
├── Resources/*.wav       Cherry G80-3494 샘플 6개
├── Info.plist            번들 메타데이터
├── build.sh              빌드 + 서명 + 설치
├── setup-signing.sh      서명 인증서 생성 (기기당 1회)
├── .signing/             인증서·개인키 (기기 로컬, 공유 금지)
├── build/                산출물
└── docs/
```

---

## 구성 요소 셋

### 1. `Scheme` — 키 → 사운드 매핑

```swift
static let generic = ["G80-3494", "G80-3494_fast1", "G80-3494_slow1"]
static let byKeyCode: [UInt16: String] = [
    36: "G80-3494_enter",      // Return
    49: "G80-3494_space",      // Space
    51: "G80-3494_backspace",  // Delete
]
```

Tickeys의 `schemes.json`에 있던 매핑을 그대로 옮겼다. 전용 샘플이 없는 키는
`generic` 3개 중 랜덤이며, **직전에 쓴 것과 같은 샘플은 다시 뽑지 않는다** —
같은 소리가 연속으로 나는 게 3개짜리 루프임을 가장 크게 드러내기 때문이다.

### 2. `ClickPlayer` — 저지연 재생

```
AVAudioEngine
  ├─ AVAudioPlayerNode ×16 ──┐
  └─ ...                     ├─→ mainMixerNode → 출력
                             ┘
```

- 시작할 때 wav 6개를 전부 `AVAudioPCMBuffer`로 디코딩해 메모리에 올린다.
  키를 누르는 시점의 비용은 `scheduleBuffer` 호출 하나뿐이다.
- 키마다 `AVAudioPlayer`를 만드는 방식은 할당 지연 때문에 쓰면 안 된다.
- 노드 16개를 라운드로빈으로 돌려 소리가 겹치게 한다(폴리포니).
  샘플이 0.12~0.22초이므로 초당 100타 이상에서만 순환이 겹친다.
  겹칠 때는 `.interrupts`로 해당 노드의 이전 소리를 끊는다.
- 볼륨은 `mainMixerNode.outputVolume` 하나로 제어한다.
- **라우트가 바뀌면 엔진을 되살린다.** 이어폰 연결, 블루투스 해제, 가상 드라이버의
  기본 출력 탈취, 샘플레이트 변경이 있으면 `AVAudioEngine`은 스스로 멈추고 알림만 던진다.
  `.AVAudioEngineConfigurationChange`를 구독해 노드를 다시 연결하고 재시작한다.
  `play()`도 `engine.isRunning`을 확인한다 — 이벤트 탭 쪽에서 플래그 대신 탭 존재 여부를
  믿는 것과 같은 이유로, 오디오 쪽도 "엔진이 실제로 도는가"만 믿는다.

동시 재생 한계를 바꾸려면 `ClickPlayer.poolSize`.

### 3. `AppDelegate` — 이벤트 탭 + 메뉴바

`LSUIElement = true` + `setActivationPolicy(.accessory)`로 Dock에 안 뜨는
메뉴바 전용 앱이 된다.

---

## 키 이벤트 경로

```
CGEvent.tapCreate(.cgSessionEventTap, .listenOnly, keyDown)
        │  실패하면 nil → 권한 없음이 즉시 드러남
        ▼
CFMachPortCreateRunLoopSource → 메인 런루프(.commonModes)
        ▼
handle(type:event:)          ← 메인 스레드
        ├ tapDisabled* → 탭 재활성화
        ├ isARepeat    → 버림
        ├ keycode 조회 (문자 내용은 읽지 않음)
        └ player.play(샘플)
```

**설계상 중요한 두 가지:**

1. **`CGEventTap`을 쓴 이유는 진단 가능성이다.** `NSEvent.addGlobalMonitorForEvents`는
   권한이 없어도 조용히 아무것도 안 한다. `tapCreate`는 `nil`을 반환하므로
   실패를 로그와 메뉴에 드러낼 수 있다.

2. **권한 판정을 `AXIsProcessTrusted()` 같은 플래그로 하지 않는다.**
   `isListening`은 `eventTap != nil`, 즉 탭이 실제로 존재하는지만 본다.
   권한이 없으면 1.5초 타이머로 `installTap()`을 재시도하고, 성공하면 타이머를 끈다.
   그래서 사용자가 설정에서 권한을 켜면 **앱 재시작 없이** 붙는다.

읽는 것은 가상 키코드와 auto-repeat 플래그뿐이다. 문자 내용은 조회하지 않으며,
아무것도 기록하거나 전송하지 않는다.

---

## 권한과 서명

| 항목 | 값 |
|---|---|
| 필요 권한 | 입력 모니터링 (`kTCCServiceListenEvent`) |
| 요청 API | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` |
| 확인 API | `IOHIDCheckAccess(...)` — 단, 실제 판정은 탭 생성 성공 여부로 한다 |
| 서명 | 자체 서명 인증서 `Keyclick Local Signing` |
| DR | `identifier "com.minbom.keyclick" and certificate leaf = H"..."` |

DR이 인증서 기준이라 재빌드해도 권한이 유지된다.
자세한 배경은 [TROUBLESHOOTING.md](TROUBLESHOOTING.md#2-왜-자체-서명-인증서가-필요한가).

---

## 상태 저장

`UserDefaults` 도메인 `com.minbom.keyclick`:

| 키 | 기본값 | 용도 |
|---|---|---|
| `enabled` | `true` | 소리 on/off |
| `volume` | `0.7` | 0~1 |
| `didSetupLoginItem` | — | 첫 실행 때만 로그인 항목을 등록하기 위한 플래그 |

`didSetupLoginItem`이 있는 이유: 첫 실행에서 자동 등록하되, 사용자가 나중에 메뉴에서
자동 실행을 껐을 때 다음 실행이 그걸 되돌리지 않게 하기 위해서다.

---

## 자주 고칠 만한 곳

| 하고 싶은 것 | 고칠 곳 |
|---|---|
| 다른 사운드 스킴 | `Resources/`의 wav 교체 + `Scheme` 수정 |
| 키별 전용 소리 추가 | `Scheme.byKeyCode`에 키코드 추가 |
| 동시 재생 한계 | `ClickPlayer.poolSize` (현재 16) |
| 키 반복 시 연타 | `handle()`의 `keyboardEventAutorepeat` guard 삭제 |
| 수식키 소리 | `CGEventMask`에 `.flagsChanged` 추가 + `handle()` 분기 |
| 스크롤 소리 | `CGEventMask`에 `.scrollWheel` 추가 |
| 기본 볼륨 | `volume` getter의 `?? 0.7` |
| 권한 재시도 주기 | `requestPermission()`의 `withTimeInterval: 1.5` |
| 엔진 재시작 재시도 간격 | `play()`의 `timeIntervalSince(lastRestart) > 1` |

키코드는 `Carbon/HIToolbox/Events.h`의 `kVK_*` 상수를 참고한다.
자주 쓰는 것: Return 36, Tab 48, Space 49, Delete 51, Escape 53, 방향키 123~126.

---

## 빌드 파이프라인 (`build.sh`)

```
swiftc -O -target <arch>-apple-macos13.0  →  Contents/MacOS/Keyclick
cp Info.plist                             →  Contents/Info.plist
cp Resources/*.wav                        →  Contents/Resources/
xattr -cr                                 (2015년 wav의 Finder 속성 제거)
codesign --sign "Keyclick Local Signing"  (없으면 ad-hoc로 폴백 + 경고)
codesign --verify
[--install] pkill → /Applications로 복사
```

`-target`의 아키텍처는 `uname -m`에서 가져오므로 빌드하는 기기에 맞춰 네이티브로 나온다.
유니버설 바이너리는 만들지 않는다 — 기기마다 직접 빌드하는 전제라 필요가 없다.
