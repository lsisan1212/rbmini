# RBMini

> macOS bridge for the **G9N9N** remote (Chromecast / Google TV voice remote, VID `0x18D1` / PID `0x9450`).
> Adds the two things macOS refuses to do out of the box: **microphone audio** and **all 14 buttons**.

極簡替代方案 —— 唔需要 Remote Buddy，唔需要 kernel extension。單一二進位 + 一個 root helper。

```
RBMini.app   1.6 MB  (binary 210 KB + 圖示 1.4 MB)
rbhid        124 KB
```

---

## 為什麼需要它

macOS 對這支遙控器有兩個缺口：

| 缺口 | 原因 |
|---|---|
| **語音冇聲** | 遙控器走 ATVV over BLE 送 IMA ADPCM 音訊，macOS 冇對應 stack，配對了也只會被當成普通 Chromecast remote |
| **按鍵收唔到** | `BTLEServer` 收到 GATT input report，但部分 report 在送入 IOHID 之前就被丟棄 → `IOHIDManager` 的 callback 永不觸發，`CGEventTap` 也看不到（裝置被歸類為 Joystick，不產生 CGEvent） |

RBMini 用兩條完全不同的路徑分別解決。

---

## 架構

```
┌──────────────────────────────┐
│  G9N9N remote                │
│   · BLE / ATVV  →  voice     │
│   · BLE / GATT HID → buttons │
└───────┬──────────────┬───────┘
        │              │
        │ ATVV         │ GATT input report
        ▼              ▼
┌──────────────┐  ┌──────────────────────┐
│ RBMini.app   │  │ BTLEServer (Apple)   │
│ (user,       │  │ + Bluetooth private  │
│  menu bar)   │  │   logging profile    │
│              │  └──────────┬───────────┘
│ 1. ATVV      │             │ unified log
│    handshake │             ▼
│ 2. ADPCM     │  ┌──────────────────────┐
│    decode    │  │ rbhid  (root daemon) │
│ 3. play into │  │  log stream --level  │
│    virtual   │  │  debug --predicate   │
│    mic       │  │  → parse report      │
│              │  │  → button edges      │
│ 4. Fn hold   │◄─┼── UDP 127.0.0.1:51888│
│    inject    │  └──────────────────────┘
│ 5. action    │
│    table     │
└──────────────┘
```

**為什麼按鍵要繞這麼遠？** 因為 `IOHIDDeviceOpen` 在非 root 下回 `kIOReturnNotPrivileged`（-536870207），root 下 seize 也回 `kIOReturnNotPermitted`（-536870174）。report 根本到不了 user space，唯一可靠的出口是 Apple 自己寫在 unified log 裡的除錯訊息。

---

## 需求

- macOS 14 Sonoma 或以上，**arm64**（`-target arm64-apple-macosx14.0`）
- 自簽 codesign 身份（ad-hoc 每次 rebuild 都變，TCC 授權會失效）
- **Bluetooth private logging 配置描述文件**（`Enable-Private-Data=1`）—— 冇它 `rbhid` 讀唔到 report
- 一個 UID 為 `BuddyMic2ch_UID` 的虛擬音訊裝置（HAL plugin，例如 BlackHole 改 UID）
- 一個支援 **Fn-hold PTT** 的輸入法（微信輸入法 / macOS 聽寫）

---

## 建置

```zsh
zsh scripts/make-app.sh          # → dist/RBMini.app（含 icon）
zsh scripts/make-helper.sh       # → dist/rbhid
sudo zsh scripts/install-helper.sh   # 裝 LaunchDaemon /Library/LaunchDaemons/com.pman.rbhid.plist
open dist/RBMini.app
```

改過 `tools/make-icon.swift` 之後要重生圖示：

```zsh
zsh scripts/make-icns.sh         # → Resources/RBMini.icns
```

用非預設簽名身份：

```zsh
CODE_SIGN_IDENTITY="Your Identity" zsh scripts/make-app.sh
```

> `swift build` 在這個專案用唔到（sandbox 內 `sandbox_apply: Operation not permitted`），所以兩個腳本都直接叫 `swiftc`。

---

## 權限（TCC）

| 權限 | 用嚟做乜 | 幾時彈 |
|---|---|---|
| 藍牙 | 連 ATVV service | 首次執行 |
| 輸入監控 | `IOHIDManager` 探測 / `CGEventTap` 觀察 | 首次執行 |
| 輔助功能 | 注入 Fn 與按鍵事件 | 首次注入 |

⚠️ **每次重新簽名後 TCC 授權即失效**，要去「系統設定 → 隱私權與安全性」移除再重加。`tccutil reset` 在沙盒內跑唔到。

---

## 用法

菜單欄出現 **RBMini**（遙控器圖示 + 名稱）。點開 → **動作映射** → 選鍵 → 選動作。設定存在 `UserDefaults`（`actionMap`），重開保留。

### 14 個按鍵

| 鍵 | 預設動作 | 鍵 | 預設動作 |
|---|---|---|---|
| 上 | ↑ | 音量 + | 音量 + |
| 下 | ↓ | 音量 − | 音量 − |
| 左 | ← | 靜音 | 靜音 |
| 右 | → | YouTube | 上一曲 |
| OK | Return | Netflix | 下一曲 |
| 返回 | Esc | Input | 播放/暫停 |
| Home | 切換 App (⌘Tab) | Power | Delete |

### 可選動作（41 項 + 自訂）

每個鍵的子選單按用途分節：

| 分節 | 動作 |
|---|---|
| **基本** | ↑ ↓ ← →、Return／Enter、數字鍵盤 Enter、Esc、Tab、Space、Delete（退格）、Delete（向前）、Home、End、Page Up、Page Down |
| **編輯** | 複製 ⌘C、貼上 ⌘V、剪下 ⌘X、全選 ⌘A、還原 ⌘Z、儲存 ⌘S、尋找 ⌘F |
| **系統** | 切換 App ⌘Tab、Mission Control、App Exposé、Launchpad、Spotlight ⌘Space、關閉視窗 ⌘W、結束 App ⌘Q、鎖定螢幕 ⌃⌘Q、截圖全螢幕、截圖選取範圍 |
| **媒體** | 音量 +／−／靜音、亮度 +／−、播放暫停、上一曲／下一曲、向上／向下捲動 |
| **自訂** | 執行指令／開網址…、清除自訂動作、無 |

### 自訂指令（v0.2 起）

每個鍵都可以綁一條 shell 指令或一個網址。選單選 **執行指令／開網址…**，輸入後按儲存：

| 輸入 | 效果 | 實際儲存 |
|---|---|---|
| `open -a Music` | 開音樂 App | `sh:open -a Music` |
| `osascript -e 'tell app "Finder" to activate'` | 跑 AppleScript | `sh:…` |
| `https://youtube.com` | 預設瀏覽器開啟 | `open:https://youtube.com` |

以 `http://` / `https://` 開頭自動當網址，其餘一律經 `/bin/zsh -lc` 非同步執行（不阻塞 UI）。設定值存於 `~/Library/Preferences/com.pman.rbmini.plist`。

> ⚠️ 這等於把一個 shell 綁上遙控器。只在自己部機用，別把這個 plist 分享出去。

### 語音

按住遙控器語音鍵 → 遙控器發 `MIC_OPEN` 請求 → RBMini 收串流、解碼、播入虛擬麥克風，同時注入 **Fn hold** → 輸入法的 PTT 被觸發 → 放開後 `0.35s` 收尾。

---

## 已知限制

- 輸出目錄寫死 `~/Workbuddy/remotebuddy-mini/out`（WAV 與 log），未做成可設定
- 只編 arm64；Intel Mac 需要改 `-target`
- 只驗證過 G9N9N（`0x18D1:0x9450`），其他 ATVV 遙控器未測
- 按鍵路徑依賴 Apple 未公開的 `BTLEServer` 除錯字串格式，macOS 更新可能失效
- 動作表有 41 個預設動作 + 自訂指令，但 **未支援自訂組合鍵錄製**（要 ⌘⇧K 這類組合只能寫 `sh:` 或自行加 case）
- 「向上／向下捲動」方向受系統「自然捲動」設定影響，覺得反了就把兩個對調
- 14 鍵中只系統性驗證過「上」（`0x0042`）

---

## 文件

| 檔案 | 內容 |
|---|---|
| [docs/atvv-protocol.md](docs/atvv-protocol.md) | ATVV service / opcode / IMA ADPCM / sync 細節 |
| [docs/buttons.md](docs/buttons.md) | report 格式、consumer usage 對照表 |
| [docs/gotchas.md](docs/gotchas.md) | 踩過的坑與錯誤碼 |

---

## 授權

未指定。使用前請自行判斷。
