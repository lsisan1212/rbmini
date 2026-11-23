# 按鍵：從 BTLEServer log 到 UDP

## 為什麼唔用 IOHID

試過三條路，全部死：

| 方法 | 結果 |
|---|---|
| `IOHIDManager` + `IOHIDManagerSetDeviceMatchingMultiple` | 裝置配對成功，`elements` 有值，但 `IOHIDDeviceRegisterInputReportCallback` **永不觸發** |
| `IOHIDDeviceOpen`（seize） | 非 root：`kIOReturnNotPrivileged` = `-536870207`；root：`kIOReturnNotPermitted` = `-536870174` |
| `CGEventTap` 監 `keyDown`/`keyUp`/`systemDefined` | 只見到實體鍵盤 event，遙控器被歸類為 Joystick，不產生 CGEvent |

結論：report 在 `BTLEServer` 內部就被丟棄，user space 完全收唔到。

## 唯一可行出口：unified log

Apple 的 `BTLEServer` 在開啟藍牙私有除錯資料後，會把每個收到的 input report 寫入 unified log：

```
Updated input report for ID #2: {length = 2, bytes = 0x4200}
```

需要的條件：

1. **Bluetooth private logging 配置描述文件**（`Enable-Private-Data=1`）—— 冇它 `bytes = <private>`，睇唔到內容
2. `log stream --level debug` —— 預設 level 過濾掉這行（實測漏了 `--level debug` 時 helper 只輸出啟動行，之後全靜）

### 過濾與解析

```zsh
log stream --style ndjson --level debug \
  --predicate '(process == "BTLEServer" AND eventMessage BEGINSWITH "Updated input report for ID #")'
```

```
^Updated input report for ID #(\d+): \{length = (\d+), bytes = 0x([0-9a-fA-F]+)\}$
```

## Report 格式

### Report ID 1 —— 索引式

payload 是 **usage 索引**，不是 usage 本身：

```
if payload.count == 3 && payload[0] == 1 { drop first }
guard payload.count == 2
usages = payload.compactMap { $0 != 0 ? indexed[$0 - 1] : nil }
```

| # | usage | 按鍵 | # | usage | 按鍵 |
|---|---|---|---|---|---|
| 1 | `0x019E` | Power | 10 | `0x0223` | Home |
| 2 | `0x00CD` | 播放/暫停 | 11 | `0x0224` | 返回 |
| 3 | `0x0042` | 上 | 12 | `0x00E9` | 音量 + |
| 4 | `0x0043` | 下 | 13 | `0x00EA` | 音量 − |
| 5 | `0x0044` | 左 | 14 | `0x0077` | YouTube |
| 6 | `0x0045` | 右 | 15 | `0x0078` | Netflix |
| 7 | `0x0041` | OK | 16 | `0x0079` | 快進 |
| 8 | `0x00E2` | 靜音 | 17 | `0x0089` | Input |
| 9 | `0x0221` | 桌面 | | | |

> 這張表是實測 + 上游 `G9N9NProtocol` 對照得來。部分 usage 與 HID Consumer Page 標準語義有偏差（例如 `0x0077` 在標準是 Stop，這裡是 YouTube 鍵），照實測走。

### Report ID 2 —— 直接 uint16

兩兩一組，**小端**：

```
if payload.count % 2 == 1 && payload[0] == 2 { drop first }
for i in stride(0, count, 2) { usage = payload[i] | payload[i+1] << 8 }
```

實際 log 樣本（已驗證 end-to-end）：

| 原始 bytes | 解出 | 意義 |
|---|---|---|
| `42 00` | `0x0042` | 上（按下） |
| `00 00` | — | 全部放開 |
| `EA 00` | `0x00EA` | 音量 − |
| `E2 00` | `0x00E2` | 靜音 |

## 邊沿偵測與傳遞

helper 維護 `previous: Set<UInt16>`，與新集合做差集：

```swift
for u in now.subtracting(previous) { emit(name(u), pressed: true) }
for u in previous.subtracting(now) { emit(name(u), pressed: false) }
previous = now
```

吐成 newline JSON 到 UDP `127.0.0.1:51888`：

```json
{"button":"up","pressed":true}
```

RBMini.app 那邊開 `recv` 迴圈收，主執行緒 `handleButton()` → 查 action table → `perform()`。

用 UDP 而唔用 XPC / 通知，是因為兩邊生命週期完全獨立（daemon 開機就起，app 隨時開關），UDP 唔需要 handshake、掉包也無所謂。
