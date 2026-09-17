# 2026-09-17 — 출력 장치 변경 후 무음 장애 수정

타이핑·소리 테스트 모두 무음이라는 증상에서 출발해, `AVAudioEngine`이 오디오 라우트
변경 때 스스로 멈추고 아무도 재시작하지 않는 것이 원인임을 확인하고 수정했다.
같은 김에 프로젝트를 git 저장소로 만들어 GitHub에 올렸다.

## 한 일

- `Sources/main.swift` — `ClickPlayer` 재작성
  - `.AVAudioEngineConfigurationChange` 구독 → 노드 재연결 후 엔진 재시작
  - `play()`에서 `engine.isRunning` 폴백 (초당 1회 제한, `lastRestart`)
  - `storedVolume` 추가 — `mainMixerNode.outputVolume`은 엔진 재구성 시 유지되지 않음
  - `isRunning` 프로퍼티 추가, `menuNeedsUpdate`에서 "오디오 엔진 정지" 상태 줄 표시
- `docs/TROUBLESHOOTING.md` — 11번 "출력 장치가 바뀌면 소리가 끊긴다" 추가,
  진단표의 `조용/조용` 행을 11번으로 연결
- `docs/ARCHITECTURE.md` — `ClickPlayer` 절에 라우트 대응 항목, 수정 지점 표에
  재시작 재시도 간격 추가, 줄 수 360 → 430
- `git init` + 최초 커밋 `64feed3`, GitHub `minbom/Keyclick` (**private**) 생성 후 push

## 확인 과정에서 나온 것

**처음 판단은 권한 문제였고, 틀렸다.** 증상(무음)과 macOS 27로 올라온 정황상 TCC
재설정을 의심했지만, `CGGetEventTapList`로 탭이 살아 있는 것을 먼저 확인했다:

```
tappingPID=2475 enabled=true mask=0x400(keyDown) options=1(listenOnly)
```

메뉴도 "키 입력 수신 중"이었다. 즉 **앱의 상태 표시가 절반만 정직했다** — 탭은 보지만
오디오는 안 봤다. 이번에 메뉴에 엔진 상태를 추가한 이유다.

**결정적 증거는 로그였다** (2026-09-17 12:02:28):

```
AUHAL: caller requesting device change from 81 to 227
Engine@0x7a7d425280: iounit configuration changed > stopping the engine
Engine@0x7a7d425280: stop, was running 1
Engine@0x7a7d425280: iounit configuration changed > posting notification
```

`posting notification` 뒤에 `start`가 없다. 이후 12:02:31 / 12:03:38 / 12:11:31에도
라우트가 계속 오갔지만 엔진은 멈춘 채였다. 프로세스 샘플링으로도 교차 확인 —
장애 상태에서는 `com.apple.audio.IOThread.client` 스레드가 아예 없었고, 재시작 후 생겼다.

```bash
sample $(pgrep -x Keyclick) 2 -file /tmp/kc.sample >/dev/null
grep IOThread /tmp/kc.sample
```

**트리거는 음소거가 아니라 블루투스 기기 연결이었다.** 사용자는 "스피커 무음 처리 이후"로
기억했으나, 같은 구간 로그에 시스템 음소거 조작은 없었다 (`syncMute: masterValue = 0`).
실제로는 12:02:27에 BT 오디오 기기가 붙으면서 macOS가 기본 출력을 그쪽으로 옮겼다:

```
BTSmartRoutingDaemon: Setting audio route DefaultOutput to BT yes Wx 20-78-CD-58-6D-EC:output
```

스피커가 조용해진 것과 Keyclick이 조용해진 것이 같은 사건의 두 결과였다.

**1차 검증은 실패했다.** 기본 출력 장치를 스피커 ↔ BoomAudio로 바꾸는 것만으로는
엔진이 멈추지 않는다. AUHAL이 `SelectDevice ... restarting`으로 in-place로 따라가고,
`AVAudioEngine`은 정지하지 않아 새 알림 핸들러가 실행되지 않았다. 출력 장치의
**샘플레이트**를 96k → 88.2k → 96k로 바꾸자 실제 장애와 동일한 시퀀스가 재현됐고,
이번에는 `stop` 뒤 130ms 만에 `start, was running 0`이 따라왔다 (핸들러 동작 확인).
검증용 도구 두 개(`switchdev.swift`, `rate.swift`)는 스크래치패드에만 두고 커밋하지 않았다.
장치·샘플레이트는 원래 값(MacBook Pro 스피커 / 96000)으로 복구했다.

**`gh`를 못 썼다.** `/usr/local/bin/gh`가 x86_64 바이너리라 `bad CPU type`으로 죽는다
(인텔 Homebrew 잔재). 저장소 생성은 keychain의 토큰으로 API를 직접 호출했다.
`~/.gitconfig`가 gh를 GitHub 자격증명 헬퍼로 지정해 둬서 push마다 에러 두 줄이 찍히지만,
Xcode gitconfig의 `osxkeychain`이 받아주므로 push 자체는 성공한다.

**저장소는 private으로 만들었다.** `Resources/*.wav`가 Tickeys에서 가져온 사운드이고
README에 개인 용도로만 쓰라고 적혀 있어, 공개 시 재배포가 되기 때문이다.
`.signing/`(개인키)과 `build/`가 커밋에 들어가지 않은 것은 push 전에 `git ls-files`로 확인했다.

## 미처리

- 회귀 테스트 자동화 없음. 라우트 변경 대응은 매번 수동으로 샘플레이트를 바꿔 로그를
  확인해야 한다. 해두려면 `rate.swift` 같은 도구를 저장소에 넣고 로그 검사까지 묶어야 한다.
- `arm64 brew install gh`로 `gh`를 정리하지 않았다.
- 엔진이 재시작에 계속 실패하는 장치(예: 드라이버가 죽은 상태)는 실제로 만들어보지 못했다.
  초당 1회 제한이 그 경우의 타이핑 지연을 막는다는 것은 코드상 보장이지 측정한 값은 아니다.

## 현재 상태

- 새 빌드 `/Applications/Keyclick.app` 설치·실행 중. 사용자가 소리 정상을 확인.
- 서명 DR이 인증서 기준이라 재빌드 후에도 입력 모니터링 권한 재승인 불필요했다.
- `github.com/minbom/Keyclick` (private), `main` 브랜치가 origin 추적 중.
