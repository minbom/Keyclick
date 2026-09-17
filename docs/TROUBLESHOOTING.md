# Keyclick — 문제 해결

실제로 겪은 함정만 적었다. 대부분 macOS의 TCC(권한) 시스템 쪽이다.

---

## 증상별 진단

먼저 메뉴바 아이콘을 클릭해 맨 위 줄과 **"소리 테스트"** 결과를 확인한다.
이 둘이 원인을 거의 확정한다.

| 타이핑 | 소리 테스트 | 원인 | 조치 |
|---|---|---|---|
| 조용 | 소리 남 | 권한 미부여 | [입력 모니터링 권한](#1-권한-종류를-혼동하기-쉽다) |
| 조용 | 조용 | 오디오 경로 | 맨 위 줄이 "오디오 엔진 정지"면 [11번](#11-출력-장치가-바뀌면-소리가-끊긴다), 아니면 볼륨 슬라이더·시스템 출력 장치 확인 |
| 소리 남 | 소리 남 | 정상 | — |
| 두 번 남 | — | Tickeys 등이 같이 실행 중 | `pkill -x Tickeys` |
| 메뉴바 아이콘 자체가 없음 | — | 앱이 안 떠 있거나 크래시 | `pgrep -lx Keyclick` |

---

## 1. 권한 종류를 혼동하기 쉽다

**필요한 것은 "입력 모니터링"이지 "손쉬운 사용"이 아니다.**

macOS 10.15부터 이렇게 갈렸다:

| 권한 | TCC 서비스명 | 무엇을 허용하나 |
|---|---|---|
| 입력 모니터링 | `kTCCServiceListenEvent` | 키 입력을 **수동으로 읽기** ← Keyclick이 쓰는 것 |
| 손쉬운 사용 | `kTCCServiceAccessibility` | 이벤트 **주입·수정**, 다른 앱 UI 제어 |

`CGEventTap`을 `.listenOnly`로 만들거나 `NSEvent.addGlobalMonitorForEvents(.keyDown)`을
쓰는 건 전부 전자다. 손쉬운 사용을 아무리 켜도 소리는 안 난다.

혼동하기 쉬운 이유: 인터넷의 오래된 예제와 `AXIsProcessTrustedWithOptions()` 문서가
전부 손쉬운 사용을 가리킨다. 10.14 이전에는 실제로 그게 맞았다.

**확인 명령:**

```bash
# 요청이 실제로 나가는지 (TCCAccessRequest 줄이 보여야 정상)
log stream --predicate 'process == "Keyclick"' --level debug --style compact
```

**권한 초기화:**

```bash
tccutil reset ListenEvent com.minbom.keyclick     # 입력 모니터링
tccutil reset Accessibility com.minbom.keyclick   # 손쉬운 사용 (혹시 켜뒀다면)
```

---

## 2. 왜 자체 서명 인증서가 필요한가

**증상:** 코드를 고쳐 재빌드하면 권한이 사라지고 다시 승인해야 한다.
심하면 시스템 설정 목록에 **Keyclick이 여러 개** 쌓인다.

**원인:** TCC는 앱을 "지정 요구사항(designated requirement, DR)"으로 식별한다.
ad-hoc 서명(`codesign -s -`)의 DR은 **바이너리 해시 그 자체**다:

```
designated => cdhash H"f4b4425a6d179211be2ee4afd005c57c50838e84"
```

한 글자만 고쳐 재빌드해도 해시가 바뀌므로, TCC 입장에서는 **완전히 다른 앱**이 된다.
이전 항목은 목록에 남아 아무 바이너리와도 매칭되지 않는 유령이 되고,
그걸 켜면 실제 실행 중인 앱에는 권한이 안 붙는다.

**해결:** 자체 서명 인증서로 서명하면 DR이 인증서 기준이 된다:

```
designated => identifier "com.minbom.keyclick" and certificate leaf = H"969e0f4a..."
```

번들 ID와 인증서는 재빌드해도 그대로이므로 권한이 유지된다.
`./setup-signing.sh`가 이 인증서를 만든다.

**유령 항목 청소:**

```bash
tccutil reset ListenEvent com.minbom.keyclick
```

출력이 두 번 이상 나오면 그만큼 항목이 있었다는 뜻이다.

**현재 DR 확인:**

```bash
codesign -d -r- /Applications/Keyclick.app
```

---

## 3. `security import`가 PKCS#12 암호 오류를 낸다

```
security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
```

암호는 맞다. OpenSSL 3이 기본으로 쓰는 최신 PBE/MAC 알고리즘을
macOS의 Security.framework가 못 읽는 것이다. 레거시 알고리즘을 강제해야 한다:

```bash
openssl pkcs12 -export ... -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
```

`setup-signing.sh`에 이미 반영돼 있다.

---

## 4. `codesign`이 "resource fork, Finder information, or similar detritus not allowed"

Tickeys에서 가져온 2015년 wav 파일에 Finder 확장 속성이 붙어 있어서 그렇다.
서명 전에 지운다:

```bash
xattr -cr build/Keyclick.app
```

`build.sh`에 이미 들어 있다.

---

## 5. `spctl -a` 가 rejected를 반환한다

```
/Applications/Keyclick.app: rejected
origin=Keyclick Local Signing
```

**정상이다.** Gatekeeper는 Apple 공증(notarization)을 요구하는데 이 앱은 공증받지 않았다.
직접 빌드해 실행하는 로컬 앱은 Gatekeeper 평가 대상이 아니므로 실행에 지장이 없다.
`codesign --verify`가 통과하면 그걸로 충분하다.

---

## 6. 조용히 실패하는 API를 피할 것

`NSEvent.addGlobalMonitorForEvents`는 권한이 없어도 **아무 신호를 주지 않는다.**
콜백이 그냥 안 불릴 뿐이라 오디오 문제인지 권한 문제인지 구분할 수 없다.

`CGEvent.tapCreate`는 권한이 없으면 `nil`을 반환한다. 그래서 이 앱은 후자를 쓰고,
실패를 로그와 메뉴에 그대로 드러낸다. 진단 가능성 때문에 고른 선택이다.

같은 이유로 앱은 `AXIsProcessTrusted()` 같은 권한 플래그를 신뢰하지 않는다.
**탭 생성 성공 여부**를 1.5초마다 재시도하며 그 결과만 믿는다 —
실제로 필요한 것과 정확히 일치하는 유일한 테스트이기 때문이다.

---

## 7. 로그가 안 보인다

`NSLog` 메시지는 `log show`에서 잘 안 잡히고, 잡혀도 `<private>`로 가려진다.
실시간 스트림이 그나마 낫다:

```bash
log stream --predicate 'process == "Keyclick"' --level debug --style compact
```

`(Foundation) <private>`가 **1.5초 간격으로 반복**되면 탭 생성 재시도 루프가 도는 중,
즉 권한이 아직 없다는 뜻이다. 이 반복이 멎으면 탭이 붙은 것이다.

---

## 8. 비밀번호 입력란에서 소리가 안 난다

**의도된 동작이다.** macOS의 secure input mode가 켜지면 이벤트 탭에 키가 전달되지 않는다.
앱 버그가 아니라 OS 차원의 보호이고, 프라이버시 측면에서 바람직하다.

같은 맥락으로 이 앱은 키의 **가상 키코드만** 읽고 문자 내용은 아예 조회하지 않는다.
`Scheme.byKeyCode`에 해당하는지 보고 아니면 랜덤 샘플을 고를 뿐이다.

---

## 9. 수식키를 눌러도 소리가 안 난다

Shift·Command·Option·Control·Caps Lock은 `keyDown`이 아니라 `flagsChanged` 이벤트로 온다.
현재 탭은 `keyDown`만 구독하므로 무음이다. 원한다면
`CGEventMask`에 `.flagsChanged`를 추가하면 되지만, 조합키를 누를 때마다 소리가 겹쳐
실제로는 시끄럽다.

---

## 10. 키를 누르고 있어도 연타 소리가 안 난다

의도된 동작이다. `handle()`에서 auto-repeat 이벤트를 걸러낸다:

```swift
guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
```

연타를 원하면 이 줄을 지우면 된다.

---

## 11. 출력 장치가 바뀌면 소리가 끊긴다

**증상:** 한동안 잘 쓰다가 어느 순간부터 타이핑도 소리 테스트도 무음이 된다.
메뉴는 "키 입력 수신 중"이라 권한 문제처럼 보이지 않는다. 앱을 재시작하면 돌아온다.

**원인:** `AVAudioEngine`은 오디오 라우트가 바뀌면 **스스로 멈춘다.** 이어폰 연결,
블루투스 장치 해제, 가상 드라이버(Boom 등)가 기본 출력을 가져가는 경우, 출력 장치의
샘플레이트 변경이 모두 해당한다. 엔진은 멈추면서 알림만 던질 뿐 아무도 다시 켜주지 않고,
멈춘 엔진에 `scheduleBuffer()`를 불러도 **에러 없이 조용히** 버퍼만 쌓인다.

로그에 그대로 남는다:

```
AUHAL: caller requesting device change from 81 to 227
Engine@0x...: iounit configuration changed > stopping the engine
Engine@0x...: stop, was running 1
Engine@0x...: iounit configuration changed > posting notification
```

`posting notification` 뒤에 `start, was running 0`이 따라오지 않으면 그때부터 무음이다.

**해결:** `ClickPlayer`가 `.AVAudioEngineConfigurationChange`를 구독해 노드를 다시 연결하고
엔진을 재시작한다. 알림을 놓친 경우를 대비해 `play()`도 `engine.isRunning`을 확인한다
(초당 한 번으로 제한 — 시작이 계속 실패하는 장치에서 타이핑이 끊기지 않도록).

**확인 명령:**

```bash
# 출력 장치를 바꾼 뒤, stop 다음에 start가 따라오는지 본다
log show --last 5m --predicate 'process == "Keyclick"' --style compact \
  | grep -E "configuration changed|Engine@.*(start|stop)"
```

살아 있는 엔진은 오디오 IO 스레드를 갖는다. 이게 없으면 멈춘 것이다:

```bash
sample $(pgrep -x Keyclick) 2 -file /tmp/kc.sample >/dev/null
grep IOThread /tmp/kc.sample     # com.apple.audio.IOThread.client
```
