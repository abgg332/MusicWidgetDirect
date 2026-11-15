# MusicWidgetDirect · 桌面小组件按钮直控

让第三方音乐 App 的**桌面小组件**变成真正的遥控器：点播放/暂停、上一首、下一首**在桌面直接生效**，不再被拽进 App。

> 适用于 iOS 15 / 16 / 17 越狱设备（多巴胺 Dopamine、palera1n rootless、RootHide 都可以）。

---

## 1. 为什么会出现「点按钮就跳 App」

小组件是 WidgetKit 画的，它本身**没有权限直接控制音乐**（App 不在前台）。所以绝大多数音乐 App 的小组件把按钮做成了一个 `Link`：你点下去，小组件只做一件事 —— 打开一个 URL，把 App 拉到前台，App 再自己开始播放。

也就是说：**跳转不是 Bug，是它唯一的实现方式。**

本插件的思路是把这一跳截下来：

```
点击按钮 → 小组件要 openURL(App) ─┬─ 放行 → App 被拉到前台（原行为）
                                   └─ 拦截 → 改发 MediaRemote 媒体命令（新行为）
                                             播放/暂停、上一首、下一首原地生效
```

## 2. 它怎么做到「点了不跳」

**关键事实一**：第三方音乐小组件的按钮不调用 `openURL`，小组件自己（或 SpringBoard
的图标手势）直接把 App 拉起来。所以拦 URL 等于拦空气 —— 真机日志里 `[tap]`、`[cmd]`
全有，`[url]` 一条没有。

**关键事实二**（0.7 才吃透）：UIKit 里，手势识别器只要挂在**祖先视图**上，就能收到
整棵子树里的触摸。小组件按钮是 `SBIconView` 的子视图，所以 `SBIconView`、
`SBIconListView`、`SBHomeScreenWindow` 上那些「点一下开 App」的识别器照样看得见这次
点击。于是：

- 在小组件上盖透明视图 → 挡不住（0.3）
- 把按钮做成子视图 → 挡不住（0.5）
- 关掉图标视图上的点击识别器 → 挡不住，因为触发点在别的层（0.6，日志写着「已关点按=2」照样跳）

**唯一有效的办法是换一个窗口**：窗口之间是硬隔离，图标窗口收不到别的窗口里的触摸，
它下面那些识别器也就无从触发。

所以 0.7 的架构是：

| 层 | 做法 |
|---|---|
| ① 覆盖窗口（主） | 建一个全屏透明窗口，级别比图标窗口高 1。它的 `hitTest` **只认音乐小组件控制区那三块矩形**，其余位置一律返回 `nil` 穿透 |
| ② 实时坐标 | 矩形在触摸发生的瞬间从图标视图换算到屏幕坐标，所以翻页/滚动/旋转/图标复用都不需要同步位置，也不会出现负数落点 |
| ③ 点击兜底 | 不同系统把「图标被点」写成不同方法（`handleTapGesture:` / `_handleTapGesture:` / `_iconTapped:` …），存在就挂，命中接管区就丢掉 |
| ④ 启动闸门 + URL | 万一还漏，掐掉 1.5 秒内同一个 App 的启动；老系统走 `openURL` 的照旧吞掉 |

命中后发私有框架 `MediaRemote` 命令（0=播放、1=暂停、2=播放暂停、4=下一首、5=上一首），
和耳机线控、锁屏控制中心是**同一套指令**，App 看来和真按了按钮没区别。

边界：

- **只接管音乐 App 的小组件**（内置酷狗、QQ 音乐、网易云、汽水、酷我、咪咕、Spotify、
  Apple Music 等主包名），而且必须是「真小组件」：宽 ≥130 且 icon 是 `SBWidgetIcon`。
  普通 App 图标、资源库堆叠、天气/日历/支付宝小组件一个像素都不碰。
- **控制区之外全部穿透**：点封面照常打开 App，长按照常抖动编辑，别的图标照常点。
  这一版没有往小组件里加任何子视图，所以 0.4 那种「接管→拆除刷屏把主线程拖死」
  的问题从结构上就不存在。

## 3. 目录

```
MusicWidgetDirect/
├── Makefile                          # 改 TWEAK_NAME 时注意 5 处前缀
├── control                           # 包元信息，CI 从这里读版本
├── MusicWidgetDirect.plist           # 注入规则（只注入 SpringBoard）
├── Tweak.mm                          # 全部逻辑（手写 hook，不走 Logos）
├── Version.h                         # 版本号唯一来源
├── config.example.plist              # 配置样例（拷到设备对应路径改）
├── push2.py                          # 推送脚本，改顶部 REPO 一行
└── .github/workflows/build.yml       # CI：一次出 rootless + roothide 两个包
```

**源文件是 `.mm`**，不是模板里的 `.xm`：`%hook` 在 `.mm` 里不会展开，本工程所有 hook 都是 `MSHookMessageEx` 手写（每个 hook 上方都有注释说明为什么挂这个点）。想改代码时别把 `%hook` 写进来。

已经用真实 iPhoneOS 16.5 SDK 做过 `-Wall -Wextra` 全量编译校验，无告警。

---

## 4. 装完是什么样

不用配置就能用。默认行为：**音乐 App 的小组件**、**下半部三等分区域**
（左/中/右 = 上一首/播放暂停/下一首）由覆盖窗口接管，点了原地生效、不跳 App；
其它位置（封面、上半部分、小组件外）完全不受影响。

装好后：

1. 桌面能正常滑动、能点开任何 App（这一版不动任何视图，不会再卡屏）
2. 打开酷狗放一首，回桌面
3. 点小组件的播放/上一首/下一首 → 原地生效，App 不起来
4. 点小组件的封面区 → 照常进入 App
5. 长按小组件 → 照常进入编辑/拖动

## 5. 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `Enabled` | `true` | 总开关 |
| `VerboseLog` | `false` | 详细日志。调参时打开，日常关掉 |
| `SwallowTouch` | `true` | `true` = 用按钮条接管（默认，也是唯一有效的方案）；`false` = 完全不管触摸（只留启动闸门 + URL 兜底，用来对比） |
| `RequireNowPlaying` | `false` | `true` = 只有当**确实有别的 App 在放歌**、且不是这个小组件时才放行（防误伤） |
| `AttachToAllIcons` | `false` | 已废弃，保留只为兼容老配置 |
| `TapWindow` | `2.5` | 点击 → openURL 的关联时间窗（秒）。慢速机型可调大到 3.5 |
| `MusicBundleIDs` | `[]` | 在**内置音乐 App 列表之外**再补充，写主包名即可，例如 `["com.xxx.player"]` |
| `BundleIDs` | `[]` | 进一步限定只接管哪些（空 = 内置列表里的全部） |
| `Regions` | 见下 | 落点区域 → 动作 |
| `URLKeywords` | `{}` | 自定义 URL 关键字 → 动作，优先级最高 |
| `FallbackAction` | `toggle` | 动作完全判不出来时的兜底 |

### 5.1 只对某一个 App 生效

```xml
<key>BundleIDs</key>
<array>
    <string>com.netease.cloudmusic</string>
</array>
```

匹配是**双向包含**：小组件报上来的可能是 `com.netease.cloudmusic.NetEaseMusicWidget`，白名单写主包名 `com.netease.cloudmusic` 也能命中。

不知道包名？见 6.1 看日志里的 `bundle=`。

### 5.2 区域映射（默认值）

坐标是归一化的（0~1，左上角为原点）：

```xml
<key>Regions</key>
<array>
  <dict><key>x</key><real>0.00</real><key>y</key><real>0.55</real>
        <key>w</key><real>0.34</real><key>h</key><real>0.45</real>
        <key>action</key><string>prev</string></dict>
  <dict><key>x</key><real>0.33</real><key>y</key><real>0.55</real>
        <key>w</key><real>0.34</real><key>h</key><real>0.45</real>
        <key>action</key><string>toggle</string></dict>
  <dict><key>x</key><real>0.66</real><key>y</key><real>0.55</real>
        <key>w</key><real>0.34</real><key>h</key><real>0.45</real>
        <key>action</key><string>next</string></dict>
</array>
```

`action` 取值：`prev` / `next` / `toggle` / `play` / `pause` / `none`（`none` = 这块别管，放行）。

**落在所有区域以外 = 放行**，也就是「点封面照常打开 App」。想让整个小组件都是控制区，就把三个区域的 `y` 改成 `0.0`、`h` 改成 `1.0`。

### 5.3 自定义 URL 关键字（最准的一招）

如果日志里看到每次按钮打开的 URL 长得不一样，比如 `app://widget?do=next`，那就别靠区域猜了，直接按关键字锁死：

```xml
<key>URLKeywords</key>
<dict>
    <key>do=next</key><string>next</string>
    <key>do=prev</key><string>prev</string>
    <key>do=play</key><string>toggle</string>
</dict>
```

匹配是「URL 里包含这个子串」，大小写不敏感，**优先于内置关键字和区域判断**。

---

## 6. 调参 / 排错（重要）

### 6.1 三步定位问题

1. 在桌面上点一次那个不听话的按钮
2. Filza 打开 `/var/mobile/Library/Logs/MusicWidgetDirect.log`，看最后几行
3. 对照下表

装好第一次 respring 后，出现这两行说明接管成立：

```
[shield] 已接管 SBIconView bundle=com.kugou.kugou1002.KGWidget bounds=(364,184)
[ovl] 覆盖窗口已建立 level=1（图标窗口 0）
```

点一下按钮，成功的样子（**只有这些，不应该有任何 App 被拉起来**）：

```
[touch] 命中控制区 bundle=com.kugou.kugou1002.KGWidget frac=(0.50,0.78) cmd=2
[cmd] MediaRemote 发送命令 2（返回 1）
[hit] overlay bundle=com.kugou.kugou1002.KGWidget cmd=2 np=com.kugou.kugou1002
```

`cmd`：`0`播放 `1`暂停 `2`播放/暂停切换 `4`下一首 `5`上一首。
`返回 1` = 系统接受了这条媒体命令；`返回 0` = 没有活跃播放会话。

| 你看到的 | 含义 | 怎么办 |
|---|---|---|
| 没有 `[shield] 已接管` | 没被认成音乐小组件（尺寸或 icon 类型不符） | 把小组件主包名写进 `MusicBundleIDs`，日志发我 |
| 有 `[shield]` 没有 `[ovl]` | 覆盖窗口没建起来 | 把这行和 `level=` 发我 |
| 有 `[touch]` 但 App 还是起来 | 覆盖窗口层级不够，被图标窗口抢了 | 日志里会有 `[ovl]` 的 level 值，发我 |
| 点按钮完全没日志 | 落点不在控制区，或没在放歌 | 先放一首再测；仍无日志就把 `VerboseLog` 打开，看 `frac` |
| 动作不对（点播放变切歌） | 三块区域划分和这个小组件不匹配 | 照 6.2 改 `Regions` |

### 6.2 按日志改区域

日志里 `frac=(0.50,0.86)` 就是这次点击在小组件里的相对位置（宽 0.50 处、高 0.86 处）。
三个按钮各点一次记下 `frac`，然后把 `Regions` 改成覆盖它们的矩形（留点余量）：

```xml
<!-- 播放键在 (0.50, 0.86)，做成 0.40~0.60 × 0.75~1.00 -->
<dict><key>x</key><real>0.40</real><key>y</key><real>0.75</real>
      <key>w</key><real>0.20</real><key>h</key><real>0.25</real>
      <key>action</key><string>toggle</string></dict>
```

### 6.3 彻底不动了怎么办

```bash
# 看插件有没有被注入
tail -20 /var/mobile/Library/Logs/MusicWidgetDirect.log
# 期望开头有：==== MusicWidgetDirect 0.7.0 载入 (pid=..., SpringBoard) ====

# 卸载
dpkg -r com.mwdt.musicwidgetdirect && killall -9 SpringBoard
```

---

## 7. 编译发版（CI）

一次 push 出两个 deb（rootless / roothide），大约 8~12 分钟。

```bash
# 一次性
echo "ghp_xxxx" > ~/.gh_token && chmod 600 ~/.gh_token
# push2.py 顶部 REPO 改成 你的账号/仓库

# 发版
grep -E '^Version:' control; grep -E 'MY_VERSION' Version.h   # 两个版本号必须一致
python3 push2.py "0.7.0: 按钮条 + 整块兜底" Makefile control MusicWidgetDirect.plist Tweak.mm Version.h .github/workflows/build.yml

# 取包
gh run list --repo <owner/repo> --limit 1
gh run watch <run-id> --repo <owner/repo> --exit-status
gh run download <run-id> --repo <owner/repo> -D out
```

装：

```bash
export PATH=/var/jb/usr/bin:$PATH
dpkg -i out/pkg-rootless/MusicWidgetDirect-0.7.0-rootless-arm64-arm64e.deb
killall -9 SpringBoard
```

> 首次 CI 大概率卡在 SDK 下载（上游 504），重跑一次即可。想一劳永逸：把 `iPhoneOS16.5.sdk.tar.xz` 传到自己仓库的 Release，tag 用 `sdk-cache`，workflow 会优先用它。

改版本时只有两个地方要同步：`control` 的 `Version:` 和 `Version.h` 的 `MY_VERSION`。

---

## 8. 已知限制

- **只能控制「系统认为正在播放」的那个 App。** 点按会走到 `MediaRemote`，所以如果小组件对应的 App 当前没有播放会话（完全没启动过），拦下来也没东西可控制 —— 这种情况插件会放行，让它正常打开 App。
- **App 用 AppIntent 做的按钮本来就不跳转**，插件不会重复发命令（不吃手势，第 2 节的取舍）。
- **点小组件的非按钮区域仍会打开 App**，这是保留的正常行为（想在小组件里进 App 时还得能进）。
- 小组件里的**进度条拖动**、**收藏/喜欢** 这类非播放类按钮，插件不处理，照常打开 App。
- 只在 **SpringBoard** 生效：锁屏播放控制、控制中心、耳机线控本来就不走这套，不受影响。

## 9. 卸载

```bash
dpkg -r com.mwdt.musicwidgetdirect
killall -9 SpringBoard
```

配置文件 `/var/mobile/Library/Preferences/com.mwdt.musicwidgetdirect.plist` 和日志不会被自动删，想清干净就手动删掉。
