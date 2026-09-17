# Keyclick — 다른 Mac에 설치하기

메뉴바에 상주하며 키 입력마다 Cherry G80-3494 기계식 키보드 소리를 내는 앱.
App Store 배포용이 아니라 **본인 소유 Mac에 직접 빌드해 설치하는 로컬 앱**이다.

---

## 0. 준비물

| 항목 | 필요 조건 |
|---|---|
| macOS | 13(Ventura) 이상 — `SMAppService`(로그인 항목 API)가 13부터다 |
| 빌드 도구 | Xcode 또는 Command Line Tools (`xcode-select --install`) |
| 권한 | 관리자 계정 불필요. `sudo` 한 번도 안 쓴다 |
| 소요 시간 | 3분 |

Apple Developer 계정($99/년)은 **필요 없다.** 배포하지 않고 본인 기기에서만 쓰기 때문이다.

---

## 1. 프로젝트 폴더 옮기기

이 Mac의 `~/Programs/Keyclick/`를 통째로 새 Mac의 같은 위치(아무 데나 무방)로 복사한다.
AirDrop, USB, git, rsync 무엇이든 상관없다.

**복사에서 반드시 제외할 것:**

```
build/       빌드 산출물. 새 Mac에서 다시 만든다
.signing/    개인키가 들어 있다 (아래 설명)
```

`.gitignore`에 이미 두 항목이 들어 있으므로 git으로 옮기면 자동으로 빠진다.
수동 복사라면:

```bash
rsync -av --exclude build --exclude .signing \
  ~/Programs/Keyclick/ 새맥:~/Programs/Keyclick/
```

### `.signing/`을 왜 안 옮기나

코드 서명용 개인키다. 새 Mac에서 새로 만드는 게 맞다 — 개인키를 기기 간에 옮길 이유가 없고,
서명 인증서가 달라도 앱 동작에는 아무 차이가 없다. 각 Mac에서 권한을 한 번씩 주면 끝이다.

---

## 2. 서명 인증서 만들기

```bash
cd ~/Programs/Keyclick
./setup-signing.sh
```

로그인 키체인에 `Keyclick Local Signing`이라는 **코드 서명 전용** 자체 서명 인증서를 만들고
신뢰 설정을 건다. 도중에 키체인 암호를 물을 수 있다 — 맥 로그인 암호를 넣으면 된다.

성공하면 마지막 줄에 이렇게 나온다:

```
  1) 969E0F4A...  "Keyclick Local Signing"
done. now run ./build.sh --install
```

> **이 단계를 건너뛰면 어떻게 되나**
> `build.sh`가 ad-hoc 서명으로 넘어간다. 앱은 동작하지만, 코드를 고쳐 재빌드할 때마다
> 입력 모니터링 권한이 초기화되어 매번 다시 승인해야 한다. 자세한 이유는
> [TROUBLESHOOTING.md](TROUBLESHOOTING.md#왜-자체-서명-인증서가-필요한가)에 있다.

키체인 항목이 싫으면 언제든 Keychain Access에서 `Keyclick Local Signing`을 지우면 원상복구된다.

---

## 3. 빌드 & 설치

```bash
./build.sh --install
```

`build/Keyclick.app`을 만들고 `/Applications/Keyclick.app`으로 복사한다.
`--install` 없이 실행하면 빌드만 하고 설치는 안 한다.

정상 출력:

```
build/Keyclick.app: valid on disk
build/Keyclick.app: satisfies its Designated Requirement
built: build/Keyclick.app
installed: /Applications/Keyclick.app
```

---

## 4. 실행 & 권한 부여

```bash
open -a /Applications/Keyclick.app
```

메뉴바에 키보드 아이콘이 생긴다. 처음에는 흐리게 보이고,
**"Keyclick에서 입력을 모니터링하려고 합니다"** 요청 창이 뜬다.

> ### ⚠️ 필요한 권한은 "입력 모니터링"이다. "손쉬운 사용"이 아니다.
>
> **시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링**에서 Keyclick을 켠다.
>
> macOS 10.15부터 키 입력을 *수동으로 듣기만* 하는 건 입력 모니터링
> (`kTCCServiceListenEvent`) 소관이다. 손쉬운 사용(Accessibility)은 이벤트를
> *주입·수정*할 때 필요한 별개 권한이고, 그쪽을 켜도 이 앱은 동작하지 않는다.
> 이 구분을 놓치면 "권한을 줬는데 소리가 안 나는" 상태로 한참 헤맨다.

요청 창을 놓쳤다면 메뉴바 아이콘 → **"입력 모니터링 설정 열기"**로 바로 갈 수 있다.

권한을 켜면 **앱 재시작 없이 1.5초 안에** 자동으로 붙는다.
앱은 권한 플래그가 아니라 이벤트 탭 생성 성공 여부를 1.5초마다 재시도하며 판정한다.

---

## 5. 동작 확인

메뉴바 아이콘을 클릭했을 때 맨 위 줄로 판단한다:

| 표시 | 의미 |
|---|---|
| **키 입력 수신 중** | 정상. 아이콘도 선명해진다 |
| **입력 모니터링 권한 없음 — 소리 안 남** | 4단계 미완료 |

메뉴의 **"소리 테스트"**는 권한과 무관하게 소리가 난다.
따라서 진단이 갈린다:

- 테스트는 나는데 타이핑은 조용함 → **권한 문제**
- 테스트도 조용함 → **오디오 출력 문제** (볼륨 슬라이더, 출력 장치 확인)

---

## 6. 메뉴 항목

| 항목 | 설명 |
|---|---|
| 소리 켜기 | 전체 on/off. 회의·녹화 중 즉시 음소거 |
| 볼륨 | 0~1 슬라이더. 기본 0.7 |
| 소리 테스트 | 샘플 1회 재생 (권한 없이도 동작) |
| 로그인 시 자동 실행 | `SMAppService` 등록/해제. 첫 실행 때 자동으로 켜진다 |
| 입력 모니터링 설정 열기 | 권한이 없을 때만 표시 |
| 종료 | ⌘Q |

설정은 `UserDefaults`(도메인 `com.minbom.keyclick`)에 저장된다.

---

## 7. 기존 Tickeys 정리 (설치돼 있다면)

Keyclick과 동시에 돌면 소리가 두 번 난다.

```bash
osascript -e 'tell application "Tickeys" to quit'
```

Tickeys는 자체 방식으로 자동 실행을 등록하므로 시스템 설정의 로그인 항목 목록에
안 보일 수 있다. 재부팅 후에도 메뉴바에 뜬다면 Tickeys 자체 설정에서 꺼야 한다.
아예 안 쓸 거면 `/Applications/Tickeys.app`을 휴지통으로 옮기면 된다.

참고로 Tickeys는 **x86_64 전용**이라 Apple Silicon에서는 Rosetta로 돈다.
Keyclick은 빌드하는 기기의 아키텍처로 네이티브 빌드된다.

---

## 8. 제거

```bash
pkill -x Keyclick
rm -rf /Applications/Keyclick.app
defaults delete com.minbom.keyclick
tccutil reset ListenEvent com.minbom.keyclick
```

키체인 인증서까지 지우려면 Keychain Access에서 `Keyclick Local Signing` 삭제.

---

## 사운드 자산에 대해

`Resources/`의 wav 6개는 [Tickeys](https://github.com/BlueCocoa/Tickeys)의
Cherry G80-3494 스킴에서 가져온 것이다. **개인 용도로만 쓴다.**
남에게 배포하거나 공개 저장소에 올리려면 원본 라이선스를 먼저 확인해야 한다.

---

## 관련 문서

- [ARCHITECTURE.md](ARCHITECTURE.md) — 어떻게 동작하고 어디를 고치면 되는지
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — 권한·서명 관련 함정 모음
