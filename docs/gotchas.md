# 踩過的坑

按時間順序，每條都係實際咬過的。

## 建置

**`swift build` 直接死** — `sandbox-exec: sandbox_apply: Operation not permitted`。SwiftPM 需要 sandbox，而某些環境（含 Agent 沙盒）唔准 nested sandbox。改用 `swiftc` 逐檔編譯，`Package.swift` 留著但冇用。

**`IOHIDValueRef` 已改名** — `error: 'IOHIDValueRef' has been renamed to 'IOHIDValue'`。

**`CGEventType.systemDefined` 唔存在** — 要 `CGEventType(rawValue: 14)!`。

**`a C function pointer cannot be formed from a closure that captures context`** — CGEventTap 的 callback 唔可以捕獲外部變數，要全部靠參數或 global。

**`NSEvent.otherEvent(...)` 造 media key** — `CGEvent(otherEventSource:)` 參數唔對，正確係：

```swift
NSEvent.otherEvent(with: .systemDefined, location: .zero,
                   modifierFlags: [], timestamp: 0, windowNumber: 0,
                   context: nil, subtype: 8, data1: data1, data2: -1)
```

`data1 = (key << 16) | (isDown ? 0x0a00 : 0x0b00)`。

## IOHID

**callback 必須在 matching 之前註冊** —— `IOHIDManagerSetDeviceMatchingMultiple` 會**立刻**枚舉已連接裝置，之後註冊的 callback 不會補發。順序錯了就會出現「裝置 matched 但永遠冇 report」。

**非 root 唔可以 seize** —— `-536870207` = `kIOReturnNotPrivileged`；root 下 `-536870174` = `kIOReturnNotPermitted`。fallback 到普通 open 都一樣冇 report。

## 藍牙 log

**漏 `--level debug`** —— helper 只輸出一行啟動訊息，之後完全靜音。`report` 那行屬 debug level。

**`bytes = <private>`** —— 冇安裝 `Enable-Private-Data=1` 的描述文件時，log 會遮罩實際內容，regex 永遠 match 唔到。

**孤兒 `log stream` 進程** —— 改參數重啟後舊進程仍在跑，`pgrep -fl` 會見到兩個。裝 daemon 前先 `launchctl bootout system/com.pman.rbhid`。

## ATVV

**`STREAM_START` 帶 session 0** — `04 00 02 00` 是噪音，要忽略，否則會當成新串流清空緩衝。

**`STREAM_STOP` 無限迴圈** — remote 在冇音訊時每 30 ms 送一次 `00`。加 `guard streaming` 與 `audioPackets == 0 → ignore` 才斷得掉。

**冇主動送 `MIC_OPEN` 就冇聲** — remote 按下語音鍵後停住等 host 回應，等唔到就唔開串流。caps 到手 1 秒後主動送。

**sync 太早套用會爆音** — `AUDIO_SYNC` 到達時手上還有半個 frame，要先用舊狀態解完再 reset，否則第一個 sample 會跳一大截。

## 虛擬麥克風

**要設 `engine.outputNode.audioUnit` 的 `kAudioOutputUnitProperty_CurrentDevice`** —— 而且必須在 `engine.start()` **之前**設。靠系統預設輸出裝置的話，聲音會播去喇叭而唔係麥克風。

**裝置靠 UID 匹配**，唔係靠名稱（名稱會本地化）。本例匹配 `BuddyMic2ch_UID`。

## 權限

**重新簽名 = TCC 授權失效** —— ad-hoc 簽名每個 build 都唔同，`AXIsProcessTrusted` 會變 false。必須用固定自簽身份（本例 `SysBar Self-Signed`），改完仍要去設定裡移除舊條目再加。

**`tccutil reset` 跑唔到** —— 沙盒封鎖，`Operation not permitted from sandbox`，即使關掉沙盒也一樣。只能人手在 GUI 操作。

**`sudo` 完全封鎖** —— Agent 環境下 `sudo` 與 `sudo -n` 都 `operation not permitted`。`install-helper.sh` 必須由使用者自己開 Terminal 跑。

## 輸入法

**`AppleFnUsageType = 3` = 按兩下 🌐 啟動聽寫** —— 但微信輸入法的語音是**按住 Fn** PTT。兩者衝突：只按一下 Fn 唔會觸發聽寫。

微信輸入法相關設定（MMKV）：

```
voicePTTShortcut_keyCodes    = [63]        // 單獨按住 Fn
voiceToggleShortcut_keyCodes = [63, 49]    // Fn + Space 切換
voice.input.preferredDeviceUID.v2 = BuddyMic2ch_UID
```

RBMini 的做法是 `onStreamStart` 注入 Fn down、`onStreamStop` 延遲 0.35 秒注入 Fn up —— 模擬「按住」，避開 toggle 手勢。

> 診斷技巧：`DictationIMLastDictationDate` 停留在舊日期，就證明系統聽寫從未真正啟動，可以排除聽寫路徑。
