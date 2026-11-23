# ATVV 協議筆記（Android TV Voice over BLE v1.0）

G9N9N 用 ATVV 送語音。macOS 冇現成實作，以下全部由實際抓包 + 位元組推導得出，數值已在本機驗證。

## GATT 結構

| 角色 | UUID | 用途 |
|---|---|---|
| Service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` | ATVV |
| Transmit | `AB5E0002-…` | host → remote 指令（write） |
| Audio | `AB5E0003-…` | remote → host 音訊（notify） |
| Control | `AB5E0004-…` | remote → host 控制（notify） |

另有一個 `0x1812`（HID over GATT）service，特徵 `0x2A4D` / `0x2A22`。**不要靠它收按鍵** —— 見 [buttons.md](buttons.md)。

## 握手流程

```
host                                remote
 │  ── GET_CAPS 0A 01 00 00 03 03 ──►
 │  ◄── 0B ... capabilities ... ─────
 │  ⏳ 等 1 秒
 │  ── MIC_OPEN 0C 00 ──────────────►   （proactive，唔等按鍵）
 │
 │  ◄── 08 （remote 語音鍵按下）──────
 │  ◄── 04 00 02 01 （stream start）──
 │  ◄── 03 …audio… ──────────────────
 │  ── MIC_EXTEND 0E 01（每 10 秒）──►
 │  ◄── 00 …（stream stop）──────────
 │  ── MIC_CLOSE 0D 01 ──────────────►
```

本機實測 caps：`version=0x100 codec=2 frame=247 rate=16000`。

## Control opcode

| op | 方向 | 名稱 | 編碼 |
|---|---|---|---|
| `0x0A` | host → remote | GET_CAPABILITIES | `0A 01 00 00 03 03` |
| `0x0B` | remote → host | CAPABILITIES | 見下 |
| `0x08` | remote → host | MIC_OPEN_REQUEST（語音鍵按下） | 唔需要回應，但回 `MIC_OPEN` 才會出音 |
| `0x0C` | host → remote | MIC_OPEN | v1.0: `0C 00`；v0.x: `0C 00 <codec>` |
| `0x0D` | host → remote | MIC_CLOSE | v1.0: `0D <session>`；v0.x: `0D` |
| `0x0E` | host → remote | MIC_EXTEND（keepalive） | `0E <session>`，v1.0 才有 |
| `0x04` | remote → host | STREAM_START | `04 00 <codec> <session>` |
| `0x00` | remote → host | STREAM_STOP | `00 <session>` |
| `0x0A` | remote → host | AUDIO_SYNC | `0A ?? ?? ?? <predHi> <predLo> <stepIndex>` |

### CAPABILITIES (`0x0B`) 解析

```
version >= 0x0100:
  version  = b[1]<<8 | b[2]
  codecs   = b[3]
  frame    = b[5]<<8 | b[6]
version < 0x0100:
  version  = b[1]<<8 | b[2]
  codecs   = b[4]
  frame    = b[7]<<8 | b[8]

codec      = (codecs & 0x02) ? 0x02 : 0x01
frameSize  = frame == 0 ? 120 : frame
sampleRate = (codec == 0x02) ? 16000 : 8000
```

### AUDIO_SYNC (`0x0A`)

解碼器狀態由 remote 側維護，host 必須用這個封包校正，否則長句會漂移失真：

- `predictor  = Int16(b[4]<<8 | b[5])`
- `stepIndex  = b[6]`

收到後不要立刻套用 —— 先讓手上那個殘缺 frame 解完（`framesBeforeSync` 計數），再 `reset(predictor:stepIndex:)`。

### STREAM_START 的陷阱

`b[3] == 0` 代表 **session 0**，是 remote 發出的「空啟動」噪音，必須忽略。同理 `STREAM_STOP` 若 `audioPackets == 0` 也要忽略，否則會陷入每 30 ms 一次的 stop 迴圈（實測踩過）。

## IMA ADPCM

- 每 frame `247` bytes → `494` samples
- **高位 nibble 先解**
- 標準 IMA step table（89 項）與 index table `[-1,-1,-1,-1,2,4,6,8]`
- predictor 夾在 `[-32768, 32767]`，stepIndex 夾在 `[0, 88]`

實作見 `Sources/RBMini/main.swift` 的 `ADPCM` class。輸出直接轉 16-bit PCM 單聲道 WAV 落地方便比對。

## 為什麼一開始冇聲

最初只等 remote 主動要求才發 `MIC_OPEN`，結果 remote 完全唔出音訊。原因是它在按下語音鍵後會停住等 host 回應；等唔到就唔開串流。

解法：caps 拿到後 1 秒主動送 `MIC_OPEN`（`proactive MIC_OPEN`），之後 remote 一按鍵就直接進 `STREAM_START`。
