# Keyclick

메뉴바에 상주하며 키 입력마다 Cherry G80-3494 기계식 키보드 소리를 내는 macOS 앱.
[Tickeys](https://github.com/BlueCocoa/Tickeys)를 대체하는 arm64 네이티브 로컬 빌드.

```bash
./setup-signing.sh      # 기기당 1회
./build.sh --install
open -a /Applications/Keyclick.app
```

실행 후 **시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링**에서 Keyclick을 켠다.
(손쉬운 사용이 아니다.)

## 문서

| 문서 | 내용 |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | 다른 Mac에 설치하는 전체 절차 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 구조와 수정 지점 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 권한·서명 함정 모음 |

`Resources/`의 사운드는 Tickeys에서 가져왔다. 개인 용도로만 사용할 것.
