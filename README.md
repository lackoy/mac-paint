# 그림판 (Paint for Mac)

설명할 때 빠르게 그려 보여주기 위한 macOS용 간단한 그림판. Windows 그림판 느낌으로 만들었습니다.

## 설치

[Releases](../../releases)에서 `Paint.dmg`를 받아 열고, `Paint`를 `Applications`로 끌어다 놓으세요.

서명·공증되지 않은 앱이라 처음 실행할 때 macOS가 막을 수 있습니다. 그럴 땐 Finder에서 앱을 **오른쪽 클릭 → 열기**, 또는:

```sh
xattr -dr com.apple.quarantine /Applications/Paint.app
```

## 기능

- 펜, 직선, 화살표, 사각형, 원, 텍스트, 지우개, 페인트 통, 스포이드
- 색상 팔레트(기본 색 / 사용자 색 / 스펙트럼 / HEX·RGB), 사용자 색 3번 클릭으로 삭제
- 사각형·자유형 선택: 닿는 그림·이미지 선택, 끌어서 이동, ⌫로 삭제
- 이미지 삽입(⇧⌘I, ⌘V, 끌어다 놓기): 모서리로 크기 조절(정사각형 스냅, ⇧ 비율 유지), 모서리 바깥으로 회전, 90°/180° 회전, 대칭, 크기 조정·기울이기(⇧⌘R), 자르기(⇧⌘X)
- 무한 캔버스: 핀치 / ⌘+스크롤 확대·축소, 스크롤 이동, ⌘= ⌘- ⌘0
- ⌘C 이미지 복사, ⌘S PNG 저장 (현재 화면 영역), ⌘Z / ⇧⌘Z

## 빌드

Xcode Command Line Tools(Swift 6) 필요. macOS 14 이상, Apple Silicon.

```sh
./build.sh      # build/Paint.app
./make_dmg.sh   # build/Paint.dmg
```
