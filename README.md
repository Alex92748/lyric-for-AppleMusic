# lyric

macOS 桌面悬浮歌词。

从 Apple Music 本地缓存读取歌词，在桌面底部显示悬浮歌词面板。支持逐字时间戳高亮，自动跟随系统深浅色模式。

## 特性

- **桌面悬浮** — 无边框透明面板，鼠标穿透，覆盖在所有窗口之上
- **逐字高亮** — 支持 TTML 字级时间戳，已唱完的词高亮、正在唱的词渐变扫过
- **浅色/深色模式** — 自动跟随系统外观
- **无依赖** — 纯 Swift，从 Apple Music 本地缓存读取，不需要开发者 Token 或第三方 API
- **菜单栏控制** — 菜单栏音符图标，点击 Quit 退出

## 系统要求

- macOS 14+
- Apple Music 订阅（用于获取歌词缓存）
- 已安装 Xcode Command Line Tools

## 安装

### 直接运行

```bash
git clone https://github.com/yourname/lyric.git
cd lyric
swift build -c release
open .build/release/lyric
```

首次运行需要授权：
- **系统设置 → 隐私与安全性 → 自动化** → 允许 `lyric` 控制 `Music`

退出：点击菜单栏 ♩ 音符图标 → Quit

## 工作原理

`lyric` 直接从 Apple Music 的本地 SQLite 缓存中读取歌词数据，不需要网络请求或开发者 Token。

### 数据链路

```
Apple Music → SQLite 缓存 → JSON → TTML 解析 → 逐字时间戳 → 渲染
```

- 缓存位置: `~/Library/Caches/com.apple.Music/Cache.db`
- 歌词格式: TTML (Timed Text Markup Language)

### 进度同步

- **AppleScript 校准** — 通过 AppleScript 获取 `player position`，自调度约 100ms 一次
- **硬件时钟插值** — 60fps 用 `CACurrentMediaTime()` 在两次校准之间平滑推进
- 不需要控制音频播放，完全是只读读取

## 项目结构

```
lyric/
├── Sources/
│   ├── App.swift              # 入口 + 菜单栏
│   ├── LyricsDisplayView.swift  # SwiftUI 渲染
│   ├── ViewModel.swift        # 状态管理 + 进度计算
│   ├── LyricsCache.swift      # SQLite 缓存读取 + TTML 解析
│   └── MusicBridge.swift      # AppleScript 桥接
├── Package.swift
└── README.md
```

## 许可证

MIT
