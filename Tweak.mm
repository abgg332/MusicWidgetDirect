// MusicWidgetDirect —— 桌面小组件「按钮直控」插件
// ---------------------------------------------------------------
// 解决的问题：
//   第三方音乐 App 的桌面小组件，点播放/上一首/下一首的按钮，实际是把整个
//   小组件做成一个 Link，点了就 openURL 把 App 拉到前台，音乐并没有真的被控制。
//
// 做法（0.7 起）：用一个**独立的全屏透明窗口**把控制区那一小块触摸接走。
//
//   为什么非得是窗口：UIKit 里，手势识别器只要挂在祖先视图上，就能收到整棵子树里的
//   触摸。小组件的按钮是 SBIconView 的子视图，所以 SBIconView / SBIconListView /
//   SBHomeScreenWindow 上那些「点一下开 App」的识别器照样能看到这次点击 ——
//   在视图层面怎么盖、怎么关识别器都挡不住（0.3~0.6 全死在这里，日志可证）。
//   窗口之间才是硬隔离：图标窗口收不到别的窗口里的触摸。
//
//   所以覆盖窗口的 hitTest 只认「音乐小组件控制区」那三块矩形（实时换算屏幕坐标），
//   命中就自己发 MediaRemote 命令（播放/暂停、上一首、下一首），
//   没命中的点一律返回 nil 穿透 —— 点封面照常开 App、长按照常编辑、别的图标照常点。
//
// 另有两层兜底：直接拉起 App 的入口（FBSSystemService / FBSOpenApplicationService /
// LSApplicationWorkspace）在点击后 1.5 秒内掐掉同一个 App 的启动；老系统仍走
// openURL 的照旧吞掉。
//
// 编译：本文件是 .mm，不走 Logos（%hook 不会展开），所有 hook 都是手写
//       MSHookMessageEx —— 见每个 hook 上方的注释。
// ---------------------------------------------------------------

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
#include <substrate.h>

#import "Version.h"

// ============================ 0. 常量 ============================

static NSString *const kCfgPath = @"/var/mobile/Library/Preferences/com.mwdt.musicwidgetdirect.plist";
static NSString *const kLogPath = @"/var/mobile/Library/Logs/MusicWidgetDirect.log";
static const unsigned long long kLogMaxBytes = 2ull * 1024 * 1024;

// 配置结构版本：v1 → v2 把 SwallowTouch 默认改成 YES、RequireNowPlaying 改成 NO。
// 老配置里这两项是旧默认值，靠这个版本号自动迁移，用户不用手动删配置。
static const NSInteger kCfgCurrentVersion = 2;

// MRMediaRemoteCommand
enum {
    kMWCmdPlay      = 0,
    kMWCmdPause     = 1,
    kMWCmdToggle    = 2,
    kMWCmdNext      = 4,
    kMWCmdPrev      = 5,
};

// ======================= 1. 配置（全局状态） =======================

static BOOL        gEnabled            = YES;   // 总开关
static BOOL        gVerbose            = NO;    // 详细日志（调区域时打开）
static BOOL        gSwallow            = YES;   // YES=点击阶段直接吃掉手势（默认开，最直接地阻止跳转）
static BOOL        gRequireNowPlaying  = NO;    // YES=只拦「当前正在播放的那个 App」的小组件
static BOOL        gAttachAll          = NO;    // 组件的类型识别不出来时，挂到所有图标上
static CGFloat     gTapWindow          = 2.5;   // 点击 → openURL 的关联时间窗（秒）
static NSArray    *gBundleIDs          = nil;   // 白名单；空 = 所有小组件
static NSArray    *gRegions            = nil;   // 区域 → 动作
static NSDictionary *gURLKeywords      = nil;   // 自定义 URL 关键字 → 动作
static NSArray    *gMusicBundles       = nil;   // 额外的「音乐 App」白名单（空=用内置列表）
static NSInteger   gFallbackCmd        = kMWCmdToggle; // 都没命中时的兜底动作
static BOOL        gLoaded             = NO;
static time_t      gCfgSec             = 0;
static long        gCfgNsec            = 0;

// 最近一次小组件点击
static double      gTapTime            = 0;
static CGPoint     gTapPoint           = CGPointZero;
static CGSize      gTapSize            = CGSizeZero;
static CGFloat     gTapFx              = -1;    // 归一化坐标，仅用于日志
static CGFloat     gTapFy              = -1;
static NSString   *gTapBundle          = nil;
static NSArray    *gTapCands           = nil;   // 这个小组件所有能拿到的包名字符串

// 一次点击可能触发多个 URL，1.2s 内全部吞掉，且只发一次命令
static double      gSuppressUntil      = 0;

// 点击之后的一小段时间内，禁止把「刚点过的那个小组件所属 App」拉到前台。
// 这是最后一道保险：遮盖层已经让小组件收不到触摸了，但如果某个系统的
// hitTest 路径绕过了遮盖层，这里还能把启动动作掐掉。
static double      gBlockUntil         = 0;

// 当前「正在播放」的 App（定时刷新）
static NSString   *gNowPlayingBundle   = nil;

// ============================ 2. 日志 ============================

static dispatch_queue_t gLogQ = nil;

static void MPWrite(NSString *s) {
    if (!gLogQ) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gLogQ = dispatch_queue_create("com.mwdt.musicwidgetdirect.log", DISPATCH_QUEUE_SERIAL);
        });
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    dispatch_async(gLogQ, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [kLogPath stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:kLogPath error:NULL];
        if ([attr fileSize] > kLogMaxBytes) {
            [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) {
            [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (__unused NSException *e) { }
        }
    });
}

static void MPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MPWrite(s);
}

// 详细日志：只有 VerboseLog=YES 才写，避免正常使用时日志刷太快
static void MPLogD(NSString *fmt, ...) {
    if (!gVerbose) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MPWrite([@"[v] " stringByAppendingString:s]);
}

// ==================== 3. MediaRemote（私有框架） ====================
// 不链接私有框架，全部 dlsym —— 编不过的风险为零，缺符号时降级到
// SBMediaController（SpringBoard 自带的媒体控制器）。

typedef bool (*MWMRSendCommand)(int command, id userInfo);
typedef void (*MWMRGetDisplayID)(dispatch_queue_t q, void (^blk)(id displayID));
typedef void (*MWMRGetIsPlaying)(dispatch_queue_t q, void (^blk)(BOOL playing));

static MWMRSendCommand   pMRSendCommand = NULL;
static MWMRGetDisplayID  pMRGetDisplay  = NULL;
static MWMRGetIsPlaying  pMRGetIsPlaying = NULL;

static void MWLoadMediaRemote(void) {
    if (pMRSendCommand) return;
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) h = RTLD_DEFAULT;
    pMRSendCommand  = (MWMRSendCommand)dlsym(h, "MRMediaRemoteSendCommand");
    pMRGetDisplay   = (MWMRGetDisplayID)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationDisplayID");
    pMRGetIsPlaying = (MWMRGetIsPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!pMRSendCommand) {
        MPLog(@"[mr] 警告：MRMediaRemoteSendCommand 取不到，将降级用 SBMediaController");
    }
}

static NSString *MWClassName(id obj) {
    if (!obj) return @"(nil)";
    return NSStringFromClass([obj class]);
}

// 通用 objc_msgSend 包装（selectors 都是简单类型，直接强转可用）
static id MWObj(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static void MWSendCommand(int cmd) {
    MWLoadMediaRemote();
    if (pMRSendCommand) {
        bool ok = pMRSendCommand(cmd, nil);
        MPLog(@"[cmd] MediaRemote 发送命令 %d（返回 %d）", cmd, ok ? 1 : 0);
        if (ok) return;
        // 返回 0 = 没有活跃播放会话，命令被丢弃。再试一下 SpringBoard 自带的控制器
        // （只能处理播放/暂停，下一首/上一首没有对应方法就到此为止）。
    }
    // 降级：只能处理播放/暂停
    Class c = objc_getClass("SBMediaController");
    if (!c) {
        MPLog(@"[cmd] 没有可用的发送通道，命令 %d 丢弃", cmd);
        return;
    }
    id mc = ((id (*)(id, SEL))objc_msgSend)((id)c, @selector(sharedInstance));
    const char *selName = (cmd == kMWCmdPlay) ? "play"
                        : (cmd == kMWCmdPause) ? "pause"
                        : "togglePlayPause";
    SEL s = sel_registerName(selName);
    if ([mc respondsToSelector:s]) {
        ((void (*)(id, SEL))objc_msgSend)(mc, s);
        MPLog(@"[cmd] SBMediaController 执行 %s", selName);
    } else {
        MPLog(@"[cmd] SBMediaController 不认识 %s", selName);
    }
}

// 每 3 秒问一次「现在是谁在放歌」，只在内存里缓存，拦截时零等待
static void MWFetchNowPlaying(void) {
    MWLoadMediaRemote();
    if (!pMRGetDisplay) return;
    pMRGetDisplay(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(id displayID) {
        NSString *s = nil;
        if ([displayID isKindOfClass:[NSString class]]) {
            s = (NSString *)displayID;
        } else if (displayID) {
            s = [displayID description];   // 老系统给的是 CFStringRef，description 一样能用
        }
        if (![s isEqual:gNowPlayingBundle]) {
            gNowPlayingBundle = [s copy];
            MPLog(@"[np] 当前播放 App = %@", s.length ? s : @"(无)");
        }
    });
}

// ============================ 4. 配置读取 ============================

static NSArray *MWDefaultRegions(void) {
    // 归一化坐标（0~1）。默认：小组件下半部分横向三等分 —— 左/中/右 = 上一首/播放暂停/下一首。
    // 这是绝大多数音乐小组件的布局；如果你的不是，按日志里的 frac 调这里。
    return @[
        @{ @"x": @0.00, @"y": @0.55, @"w": @0.34, @"h": @0.45, @"action": @"prev"   },
        @{ @"x": @0.33, @"y": @0.55, @"w": @0.34, @"h": @0.45, @"action": @"toggle" },
        @{ @"x": @0.66, @"y": @0.55, @"w": @0.34, @"h": @0.45, @"action": @"next"   },
    ];
}

static NSInteger MWCommandForAction(NSString *a) {
    if (![a isKindOfClass:[NSString class]]) return -1;
    NSString *s = [[a lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s isEqualToString:@"prev"] || [s isEqualToString:@"previous"] || [s isEqualToString:@"上一首"]) return kMWCmdPrev;
    if ([s isEqualToString:@"next"] || [s isEqualToString:@"下一首"]) return kMWCmdNext;
    if ([s isEqualToString:@"toggle"] || [s isEqualToString:@"playpause"] || [s isEqualToString:@"播放暂停"]) return kMWCmdToggle;
    if ([s isEqualToString:@"play"] || [s isEqualToString:@"播放"]) return kMWCmdPlay;
    if ([s isEqualToString:@"pause"] || [s isEqualToString:@"暂停"]) return kMWCmdPause;
    if ([s isEqualToString:@"none"] || [s isEqualToString:@"pass"]) return -1;
    return -1;
}

static NSDictionary *MWDefaultConfig(void) {
    return @{
        @"ConfigVersion"     : @(kCfgCurrentVersion),
        @"Enabled"           : @YES,
        @"VerboseLog"        : @NO,
        @"SwallowTouch"      : @YES,   // 默认在点击阶段就吃掉，最直接地阻止跳转
        @"RequireNowPlaying" : @NO,    // 不再要求「必须先有播放会话」，否则首次点播放会被放行
        @"AttachToAllIcons"  : @NO,
        @"TapWindow"         : @2.5,
        @"BundleIDs"         : @[],
        @"MusicBundleIDs"    : @[],   // 内置音乐 App 列表之外的补充（写主包名即可）
        @"Regions"           : MWDefaultRegions(),
        @"URLKeywords"       : @{},
        @"FallbackAction"    : @"toggle",
    };
}

static void MWLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kCfgPath];
    if (![d isKindOfClass:[NSDictionary class]]) {
        d = MWDefaultConfig();
        [d writeToFile:kCfgPath atomically:YES];   // 首次运行写一份默认配置，方便用户照着改
        MPLog(@"[cfg] 生成默认配置 %@", kCfgPath);
    }

    // 老版本（v1）留下的配置里 SwallowTouch=NO / RequireNowPlaying=YES 是旧默认值，
    // 会让「点按钮还是跳转」。升级到 v2 时把这两项换成新默认，其它自定义项原样保留。
    NSInteger ver = [d[@"ConfigVersion"] integerValue];
    if (ver < kCfgCurrentVersion) {
        NSMutableDictionary *m = [d mutableCopy];
        if (![m[@"SwallowTouch"] boolValue])      m[@"SwallowTouch"] = @YES;
        if ([m[@"RequireNowPlaying"] boolValue])  m[@"RequireNowPlaying"] = @NO;
        m[@"ConfigVersion"] = @(kCfgCurrentVersion);
        [m writeToFile:kCfgPath atomically:YES];
        d = m;
        MPLog(@"[cfg] 配置升级 v%ld → v%ld（SwallowTouch=YES, RequireNowPlaying=NO）",
              (long)ver, (long)kCfgCurrentVersion);
    }

    id v = nil;
    v = d[@"Enabled"];           gEnabled           = v ? [v boolValue] : YES;
    v = d[@"VerboseLog"];        gVerbose           = v ? [v boolValue] : NO;
    v = d[@"SwallowTouch"];      gSwallow           = v ? [v boolValue] : YES;
    v = d[@"RequireNowPlaying"]; gRequireNowPlaying = v ? [v boolValue] : NO;
    v = d[@"AttachToAllIcons"];  gAttachAll         = v ? [v boolValue] : NO;
    v = d[@"TapWindow"];         gTapWindow         = v ? [v doubleValue] : 2.5;
    if (gTapWindow < 0.3) gTapWindow = 0.3;
    if (gTapWindow > 10.0) gTapWindow = 10.0;

    NSArray *ids = d[@"BundleIDs"];
    gBundleIDs = [ids isKindOfClass:[NSArray class]] ? ids : @[];

    NSArray *mb = d[@"MusicBundleIDs"];
    gMusicBundles = [mb isKindOfClass:[NSArray class]] ? mb : @[];

    NSArray *regs = d[@"Regions"];
    gRegions = [regs isKindOfClass:[NSArray class]] && regs.count ? regs : MWDefaultRegions();

    NSDictionary *kw = d[@"URLKeywords"];
    gURLKeywords = [kw isKindOfClass:[NSDictionary class]] ? kw : @{};

    NSInteger fb = MWCommandForAction(d[@"FallbackAction"]);
    gFallbackCmd = (fb >= 0) ? fb : kMWCmdToggle;

    struct stat st;
    if (stat(kCfgPath.fileSystemRepresentation, &st) == 0) {
        gCfgSec = st.st_mtimespec.tv_sec;
        gCfgNsec = st.st_mtimespec.tv_nsec;
    }
    gLoaded = YES;

    MPLog(@"[cfg] enabled=%d swallow=%d requireNP=%d attachAll=%d window=%.1f 白名单=%@ 区域数=%lu",
          gEnabled, gSwallow, gRequireNowPlaying, gAttachAll, gTapWindow,
          gBundleIDs.count ? [gBundleIDs componentsJoinedByString:@","] : @"(全部)",
          (unsigned long)gRegions.count);
}

// 每次点击/拦截前检查一下配置文件有没有被改过，改了就热加载（不用 respring）
static void MWEnsureConfig(void) {
    // layoutSubviews 会高频调用，别每次都 stat 文件
    static double lastCheck = 0;
    double nowTs = CFAbsoluteTimeGetCurrent();
    if (gLoaded && nowTs - lastCheck < 1.0) return;
    lastCheck = nowTs;

    struct stat st;
    BOOL exists = (stat(kCfgPath.fileSystemRepresentation, &st) == 0);
    if (!gLoaded) { MWLoadConfig(); return; }
    if (!exists) return;
    if (st.st_mtimespec.tv_sec != gCfgSec || st.st_mtimespec.tv_nsec != gCfgNsec) {
        MPLog(@"[cfg] 检测到配置变更，重新加载");
        MWLoadConfig();
    }
}

// ============================ 5. 匹配工具 ============================

// 双向包含匹配：小组件给的可能是 com.x.y 或 com.x.y.WidgetExtension，白名单写主包名即可
static BOOL MWStrOverlap(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    NSString *x = [a lowercaseString];
    NSString *y = [b lowercaseString];
    return [x isEqualToString:y] || [x containsString:y] || [y containsString:x];
}

static BOOL MWCandsMatchList(NSArray *cands, NSArray *list) {
    if (!list.count) return YES;
    for (NSString *c in cands) {
        for (NSString *p in list) {
            if ([p isKindOfClass:[NSString class]] && MWStrOverlap(c, p)) return YES;
        }
    }
    return NO;
}

// 从图标对象上能捞到的所有「包名/标识」字符串
static void MWCollect(id obj, NSMutableArray *out) {
    if (!obj) return;
    NSArray *sels = @[@"applicationBundleIdentifier", @"bundleIdentifier", @"leafIdentifier",
                      @"uniqueIdentifier", @"widgetIdentifier", @"extensionBundleIdentifier",
                      @"containingBundleIdentifier", @"kind"];
    for (NSString *s in sels) {
        id v = MWObj(obj, s);
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
            if (![out containsObject:v]) [out addObject:v];
        }
    }
}

static NSArray *MWIconCandidates(id iconView) {
    NSMutableArray *out = [NSMutableArray array];
    id icon = MWObj(iconView, @"icon");
    MWCollect(icon, out);
    MWCollect(iconView, out);
    if (icon) {
        MWCollect(MWObj(icon, @"activeWidget"), out);
        id widgets = MWObj(icon, @"widgets");
        if ([widgets isKindOfClass:[NSArray class]]) {
            NSInteger n = 0;
            for (id w in (NSArray *)widgets) {
                MWCollect(w, out);
                if (++n >= 2) break;
            }
        }
        // 有些版本把 SBWidget 挂在 icon 的 _widgets / allowedWidgets 上
        id aw = MWObj(icon, @"allowedWidgets");
        if ([aw isKindOfClass:[NSArray class]] && [(NSArray *)aw count]) MWCollect([(NSArray *)aw firstObject], out);
    }
    return out;
}


static NSString *MWBestBundle(NSArray *cands) {
    NSString *best = nil;
    for (NSString *c in cands) {
        if (![c isKindOfClass:[NSString class]]) continue;
        if ([c rangeOfString:@"."].location == NSNotFound) continue;
        if (!best || c.length > best.length) best = c;
    }
    if (!best && cands.count) {
        id first = cands.firstObject;
        if ([first isKindOfClass:[NSString class]]) best = first;
    }
    return best;
}

// 内置「音乐 App」主包名前缀。
// 只对这批 App 的小组件做接管——否则天气、日历、支付宝这些小部件的下半部分
// 也会被吃掉，反而把正常功能搞坏（0.1/0.2 就吃了这个亏）。
static NSArray *MWDefaultMusicBundles(void) {
    static NSArray *cached = nil;
    if (cached) return cached;
    cached = @[
        @"com.kugou.kugou1002",          // 酷狗
        @"com.tencent.qqmusic",          // QQ 音乐
        @"com.netease.cloudmusic",       // 网易云音乐
        @"com.soda.music",               // 汽水音乐
        @"com.kuwo.player",              // 酷我
        @"com.migu.music",               // 咪咕音乐
        @"com.hongyun.music",            // 番茄畅听音乐版
        @"com.spotify.client",           // Spotify
        @"com.apple.music",              // Apple Music
        @"com.google.ios.youtubemusic",  // YouTube Music
        @"com.ximalaya.ting",            // 喜马拉雅
        @"com.gemd.iting",               // 喜马拉雅（旧版）
    ];
    return cached;
}

// 这个小组件是不是音乐 App 的：按主包名前缀匹配（com.x.y.KGWidget → com.x.y）
static BOOL MWIsMusicCands(NSArray *cands) {
    NSMutableArray *list = [NSMutableArray arrayWithArray:MWDefaultMusicBundles()];
    for (id p in gMusicBundles) {
        if ([p isKindOfClass:[NSString class]] && [p length]) [list addObject:p];
    }
    for (NSString *c in cands) {
        if (![c isKindOfClass:[NSString class]] || ![c length]) continue;
        NSString *x = [c lowercaseString];
        for (NSString *p in list) {
            NSString *lp = [p lowercaseString];
            if ([x isEqualToString:lp] || [x hasPrefix:[lp stringByAppendingString:@"."]]) return YES;
        }
    }
    return NO;
}

// 目标 App 是不是「刚被点的那个小组件」的宿主 App
static BOOL MWTapOwnsTarget(NSString *target) {
    if (![target isKindOfClass:[NSString class]] || ![target length]) return NO;
    NSString *t = [target lowercaseString];
    for (NSString *c in gTapCands) {
        if (![c isKindOfClass:[NSString class]] || ![c length]) continue;
        NSString *x = [c lowercaseString];
        if ([x isEqualToString:t]) return YES;
        if ([x hasPrefix:[t stringByAppendingString:@"."]]) return YES;   // com.a.b.KGWidget vs com.a.b
        if ([t hasPrefix:[x stringByAppendingString:@"."]]) return YES;
    }
    return NO;
}

// ======================= 6. 动作判定 =======================

// URL 里的动作关键字。按 token 精确匹配，避免 "player" 里的 "play" 造成误判。
static NSInteger MWActionFromURL(NSString *urlAbs) {
    if (!urlAbs.length) return -1;
    NSString *low = [urlAbs lowercaseString];

    // ① 用户自定义关键字优先（按长度倒序，长的更具体）
    if (gURLKeywords.count) {
        NSArray *keys = [gURLKeywords.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [(NSString *)b length] > [(NSString *)a length] ? NSOrderedDescending : NSOrderedAscending;
        }];
        for (NSString *k in keys) {
            if (![k isKindOfClass:[NSString class]] || !k.length) continue;
            if ([low containsString:[k lowercaseString]]) {
                NSInteger c = MWCommandForAction(gURLKeywords[k]);
                if (c >= 0) { MPLogD(@"[url] 命中自定义关键字 %@ → %ld", k, (long)c); return c; }
            }
        }
    }

    // ② 中文关键字（无分隔符，只能 contains）
    if ([low containsString:@"下一首"] || [low containsString:@"下一曲"]) return kMWCmdNext;
    if ([low containsString:@"上一首"] || [low containsString:@"上一曲"]) return kMWCmdPrev;
    if ([low containsString:@"播放暂停"] || [low containsString:@"暂停"] || [low containsString:@"播放"]) return kMWCmdToggle;

    // ③ 英文按分隔符切词后精确比对
    NSMutableCharacterSet *sep = [NSMutableCharacterSet alphanumericCharacterSet];
    [sep addCharactersInString:@"-"];   // 保留连字符，play-pause 当一个词
    NSArray *tokens = [low componentsSeparatedByCharactersInSet:[sep invertedSet]];
    NSDictionary *map = @{
        @"playpause": @(kMWCmdToggle), @"play-pause": @(kMWCmdToggle), @"toggle": @(kMWCmdToggle),
        @"next": @(kMWCmdNext), @"nexttrack": @(kMWCmdNext), @"forward": @(kMWCmdNext),
        @"prev": @(kMWCmdPrev), @"previous": @(kMWCmdPrev), @"prevtrack": @(kMWCmdPrev),
        @"backward": @(kMWCmdPrev), @"rewind": @(kMWCmdPrev),
        @"pause": @(kMWCmdPause), @"play": @(kMWCmdPlay),
    };
    // 先扫一遍「组合词」，避免 play 抢在 playpause 前面
    for (NSString *t in tokens) {
        NSNumber *n = map[t];
        if (n && ([t isEqualToString:@"playpause"] || [t isEqualToString:@"play-pause"] || [t isEqualToString:@"toggle"])) {
            return n.integerValue;
        }
    }
    for (NSString *t in tokens) {
        NSNumber *n = map[t];
        if (n) return n.integerValue;
    }
    return -1;
}

// 归一化坐标 → 动作。覆盖窗口精确算好了 0~1 的比例，直接查表，不做任何二次换算。
static NSInteger MWActionFromNormalized(CGFloat fx, CGFloat fy) {
    for (NSDictionary *r in gRegions) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        CGFloat x = [r[@"x"] doubleValue];
        CGFloat y = [r[@"y"] doubleValue];
        CGFloat w = [r[@"w"] doubleValue];
        CGFloat h = [r[@"h"] doubleValue];
        if (fx >= x && fx <= x + w && fy >= y && fy <= y + h) {
            return MWCommandForAction(r[@"action"]);
        }
    }
    return -1;
}

static NSInteger MWActionFromPoint(CGPoint p, CGSize sz) {
    if (sz.width < 2 || sz.height < 2) return -1;
    return MWActionFromNormalized(p.x / sz.width, p.y / sz.height);
}

// ======================= 7. 触摸隔离（独立覆盖窗口） =======================
//
// 前六版为什么都没成，日志已经把答案写死了：
//
//   0.1/0.2  记位置 + 拦 openURL        → 小组件根本不调 openURL，日志里一条 [url] 都没有。
//   0.3      整块透明遮盖 + hitTest     → 触摸被接住了，App 照跳。
//   0.5      按钮条 + 手势 delegate 拦截 → 日志里一条 [gr] 都没有（那个钩子根本没被调用）。
//   0.6      关掉图标上的点按识别器      → 日志写着「已关点按=2」，点下去照样跳。
//
// 根因是 UIKit 的一条既定行为：**手势识别器挂在祖先视图上时，能收到整棵子树里的触摸**。
// 我们的按钮是 SBIconView 的子视图，所以 SBIconView、SBIconListView、SBIconScrollView、
// SBHomeScreenWindow 上那些「点一下开 App」的识别器，照样看得见这次点击 —— 盖住、关掉
// 单独一个识别器都没用，因为触发点在别的层。
//
// 唯一能真正隔离的办法：**让这次触摸属于另一个窗口**。
// 窗口之间是硬隔离的 —— 图标窗口收不到别的窗口里的触摸，它下面那些识别器也就无从触发。
//
// 所以 0.7 改成：
//   · 建一个全屏透明窗口，级别比图标窗口高 1；
//   · 它的 hitTest 只认「音乐小组件控制区」那几个矩形，其它位置一律返回 nil（穿透）；
//   · 矩形是**实时**从图标视图换算到屏幕坐标的，所以翻页、滚动、旋转、图标复用都不用同步；
//   · 命中就自己接 touchesBegan/Ended，发 MediaRemote 命令；
//   · 没命中的点完全不受影响：点封面照常开 App、长按照常编辑、别的图标照常点。
//
// 这一版没有往小组件里加任何子视图，所以 0.4 那种「接管→拆除刷屏把主线程拖死」的
// 问题从结构上就不存在了。

// 登记表：当前接管中的小组件图标视图（弱引用，视图销毁自动出表）
static NSHashTable *gIconViews = nil;

// 防重入：layoutSubviews 里可能会走到登记流程
static BOOL gMaintaining = NO;

static UIWindow *gOverlayWin  = nil;
static UIView   *gOverlayRoot = nil;

@interface MWTouchTarget : NSObject
@property (nonatomic, weak)   UIView   *iconView;
@property (nonatomic, assign) NSInteger cmd;
@property (nonatomic, assign) CGFloat   fx;
@property (nonatomic, assign) CGFloat   fy;
@property (nonatomic, copy)   NSArray  *cands;
@property (nonatomic, copy)   NSString *bundle;
@end

@implementation MWTouchTarget
@end

static MWTouchTarget *MWResolveScreenPoint(CGPoint sp);
static void MWEnsureOverlay(UIWindow *like);

// ---------------------- 7.1 覆盖窗口的内容视图 ----------------------

@interface MWOverlayRootView : UIView
@end

@implementation MWOverlayRootView {
    BOOL      _tracking;
    CGPoint   _startPoint;
    NSInteger _pendingCmd;
    NSArray  *_pendingCands;
    NSString *_pendingBundle;
}

// 视图坐标 → 屏幕坐标
- (CGPoint)mwScreenPoint:(CGPoint)p {
    CGPoint inWin = [self convertPoint:p toView:nil];
    UIWindow *w = self.window;
    return w ? [w convertPoint:inWin toWindow:nil] : inWin;
}

// 只有「落在音乐小组件控制区」时才算命中；其它任何位置返回 nil = 完全不拦。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!event || event.type != UIEventTypeTouches) return nil;
    if (!gEnabled || !gSwallow) return nil;
    MWEnsureConfig();
    if (!gEnabled || !gSwallow) return nil;
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    return MWResolveScreenPoint([self mwScreenPoint:point]) ? self : nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (!t) { [super touchesBegan:touches withEvent:event]; return; }
    CGPoint p = [t locationInView:self];
    MWTouchTarget *tg = MWResolveScreenPoint([self mwScreenPoint:p]);
    if (!tg) { _tracking = NO; [super touchesBegan:touches withEvent:event]; return; }

    _tracking       = YES;
    _startPoint     = p;
    _pendingCmd     = tg.cmd;
    _pendingCands   = tg.cands;
    _pendingBundle  = tg.bundle;
    MPLog(@"[touch] 命中控制区 bundle=%@ frac=(%.2f,%.2f) cmd=%ld",
          tg.bundle ?: @"?", tg.fx, tg.fy, (long)tg.cmd);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 只是记录，判定统一放在 touchesEnded（拖动超过 22pt 就当误触丢弃）
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tracking) { [super touchesEnded:touches withEvent:event]; return; }
    _tracking = NO;

    UITouch *t = touches.anyObject;
    CGPoint p = t ? [t locationInView:self] : _startPoint;
    CGFloat dx = p.x - _startPoint.x;
    CGFloat dy = p.y - _startPoint.y;
    if (dx * dx + dy * dy > 22.0 * 22.0) {
        _pendingCmd = -1;
        MPLogD(@"[touch] 位移过大，当作滑动忽略");
        return;
    }

    NSInteger cmd = _pendingCmd;
    _pendingCmd = -1;
    if (cmd < 0 || !gEnabled) return;

    gTapCands      = [_pendingCands copy];
    gTapBundle     = [_pendingBundle copy];
    gSuppressUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    gBlockUntil    = CFAbsoluteTimeGetCurrent() + 1.5;   // 保险：这 1.5s 内不许把这个 App 拉起来
    gTapTime       = 0;

    MWSendCommand((int)cmd);
    MPLog(@"[hit] overlay bundle=%@ cmd=%ld np=%@",
          _pendingBundle ?: @"?", (long)cmd, gNowPlayingBundle ?: @"(无)");
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _tracking = NO;
    _pendingCmd = -1;
    [super touchesCancelled:touches withEvent:event];
}

@end

@interface MWOverlayWindow : UIWindow
@end

@implementation MWOverlayWindow
@end

// ---------------------- 7.2 覆盖窗口本身 ----------------------

static void MWOverlayCreate(UIWindow *like) {
    if (gOverlayWin || !like) return;
    CGRect f = [UIScreen mainScreen].bounds;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *sc = like.windowScene;
        if (!sc) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
            }
        }
        if (sc) gOverlayWin = [[MWOverlayWindow alloc] initWithWindowScene:sc];
    }
    if (!gOverlayWin) gOverlayWin = [[MWOverlayWindow alloc] initWithFrame:f];

    gOverlayWin.frame = f;
    gOverlayWin.backgroundColor = [UIColor clearColor];
    gOverlayWin.opaque = NO;
    gOverlayWin.windowLevel = like.windowLevel + 1;   // 刚好压在图标窗口上面，仍在系统浮层下面

    gOverlayRoot = [[MWOverlayRootView alloc] initWithFrame:f];
    gOverlayRoot.backgroundColor = [UIColor clearColor];
    gOverlayRoot.opaque = NO;
    gOverlayRoot.userInteractionEnabled = YES;
    gOverlayRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gOverlayWin addSubview:gOverlayRoot];

    gOverlayWin.hidden = NO;

    MPLog(@"[ovl] 覆盖窗口已建立 level=%.0f（图标窗口 %.0f）",
          gOverlayWin.windowLevel, like.windowLevel);
}

static void MWEnsureOverlay(UIWindow *like) {
    if (gOverlayWin || !like) return;
    // 在 layout 回调里同步建窗容易踩到重入，挪到下一轮主队列
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gOverlayWin) return;
        MWOverlayCreate(like);
    });
}

// ---------------------- 7.3 登记 / 注销 ----------------------

static BOOL MWIsRegisteredView(id v) {
    if (![v isKindOfClass:[UIView class]] || !gIconViews) return NO;
    return [gIconViews containsObject:(UIView *)v];
}

static void MWRegisterIconView(UIView *v) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIconViews = [NSHashTable weakObjectsHashTable];
    });
    if (![gIconViews containsObject:v]) {
        [gIconViews addObject:v];
        MPLog(@"[shield] 已接管 %@ bundle=%@ bounds=(%.0f,%.0f)",
              MWClassName(v), MWBestBundle(MWIconCandidates(v)) ?: @"?",
              v.bounds.size.width, v.bounds.size.height);
    }
    MWEnsureOverlay(v.window);

    // 图标窗口的层级若比先前高（换了场景/系统版本不同），跟着抬上去
    if (gOverlayWin && v.window && v.window.windowLevel + 1 > gOverlayWin.windowLevel) {
        gOverlayWin.windowLevel = v.window.windowLevel + 1;
        MPLog(@"[ovl] 覆盖窗口层级抬到 %.0f", gOverlayWin.windowLevel);
    }
}

static void MWUnregisterIconView(UIView *v) {
    if (!gIconViews || !gIconViews.count) return;
    if (![gIconViews containsObject:v]) return;
    [gIconViews removeObject:v];
    MPLog(@"[shield] 取消接管 %@（剩 %lu 个）", MWClassName(v), (unsigned long)gIconViews.count);
}

// ---------------------- 7.4 命中判定 ----------------------

static MWTouchTarget *MWResolveScreenPoint(CGPoint sp) {
    if (!gIconViews || !gIconViews.count) return nil;
    if (!gEnabled || !gSwallow) return nil;

    for (UIView *v in gIconViews.allObjects) {
        UIWindow *w = v.window;
        if (!w || w.hidden || v.hidden || v.alpha < 0.05) continue;

        // 图标视图 → 窗口 → 屏幕
        CGRect r = [v convertRect:v.bounds toView:nil];
        r = [w convertRect:r toWindow:nil];
        if (r.size.width < 60 || r.size.height < 40) continue;
        if (!CGRectContainsPoint(r, sp)) continue;

        CGFloat fx = (sp.x - r.origin.x) / r.size.width;
        CGFloat fy = (sp.y - r.origin.y) / r.size.height;
        NSInteger cmd = MWActionFromNormalized(fx, fy);
        if (cmd < 0) return nil;    // 控制区之外：穿透，交给系统原逻辑（点封面照常开 App）

        MWTouchTarget *t = [MWTouchTarget new];
        t.iconView = v;
        t.cmd      = cmd;
        t.fx       = fx;
        t.fy       = fy;
        t.cands    = MWIconCandidates(v);
        t.bundle   = MWBestBundle(t.cands);
        return t;
    }
    return nil;
}

// 这个图标视图是不是「真小组件」。普通 App 图标约 64×78，小组件中号至少 155×155。
static BOOL MWIsWidgetHost(UIView *v) {
    if (![v isKindOfClass:[UIView class]]) return NO;
    CGSize sz = v.bounds.size;
    if (sz.width < 130 || sz.height < 60) return NO;
    id icon = MWObj(v, @"icon");
    NSString *cn = MWClassName(icon);
    if (!cn.length) return NO;
    if ([cn rangeOfString:@"Widget"].location == NSNotFound) return NO;   // SBWidgetIcon
    return YES;
}

// 名字沿用老版本，内部改成「登记到覆盖窗口」；对外行为由 hook 决定
static void MWAttachShield(UIView *v) {
    if (![v isKindOfClass:[UIView class]]) return;
    if (gMaintaining) return;
    gMaintaining = YES;

    MWEnsureConfig();

    BOOL want = (gEnabled && gSwallow) && MWIsWidgetHost(v);
    if (!want) {
        MWUnregisterIconView(v);
        gMaintaining = NO;
        return;
    }

    NSArray *cands = MWIconCandidates(v);
    // cands 为空 = 小组件正在刷新，保持现状（拆了再接会造成空档）
    if (cands.count && !MWIsMusicCands(cands)) {
        MWUnregisterIconView(v);
        gMaintaining = NO;
        return;
    }

    MWRegisterIconView(v);
    gMaintaining = NO;
}

static void MWDetachShield(UIView *v) {
    MWUnregisterIconView(v);
}

// ======================= 8. URL 拦截核心 =======================

static BOOL MWHandleURL(NSURL *url, NSString *src) {
    if (!url) return NO;
    MWEnsureConfig();
    if (!gEnabled) return NO;

    NSString *abs = [url absoluteString] ?: @"";
    double now = CFAbsoluteTimeGetCurrent();

    // ① 同一次点击引发的后续 URL：吞掉但不再发命令（避免一次点击跳两首）
    if (now < gSuppressUntil) {
        MPLogD(@"[url] 同一次点击的后续打开，吞掉: %@ (%@)", abs, src);
        return YES;
    }

    // ② 前提：必须刚刚在小组件上点过。没有这个前提一律放行，避免误伤 App 内部跳转。
    if (gTapTime <= 0) {
        MPLogD(@"[url] 没有小组件点击前情，放行: %@ (%@)", abs, src);
        return NO;
    }
    if (now - gTapTime > gTapWindow) {
        // 记录到了点击、但 URL 来得太晚：说明「点击→跳转」的间隔比窗口长，需要调大 TapWindow
        MPLog(@"[url] 点击已过 %.1fs（窗口 %.1fs），放行: %@", now - gTapTime, gTapWindow, abs);
        return NO;
    }

    // ③ 白名单
    if (!MWCandsMatchList(gTapCands, gBundleIDs)) {
        MPLog(@"[url] 不在白名单: %@ 放行", gTapBundle ?: @"?");
        return NO;
    }

    // ④ 若系统明确报告「另一个 App 正在放歌」，而这个小组件不是它 → 放行，避免误伤非音乐小组件。
    //    注意：不再要求「必须先有播放会话」。首次点播放按钮时 App 还没起来、没有会话，
    //    旧逻辑在这里放行，结果就是「点了还是跳转」。
    if (gRequireNowPlaying && gNowPlayingBundle.length &&
        !MWCandsMatchList(gTapCands, @[ gNowPlayingBundle ])) {
        MPLog(@"[url] 正在播放的是 %@，不是这个小组件(%@)，放行", gNowPlayingBundle, gTapBundle ?: @"?");
        return NO;
    }

    // ⑤ 定动作：URL 关键字 → 点击区域
    NSInteger cmd = MWActionFromURL(abs);
    NSString *via = @"url";
    if (cmd < 0) {
        cmd = MWActionFromPoint(gTapPoint, gTapSize);
        via = @"region";
    }
    if (cmd < 0) {
        MPLog(@"[url] 非控制区且 URL 无动作信息，放行（正常打开 App）: %@", abs);
        return NO;
    }

    MWSendCommand((int)cmd);
    gTapTime = 0;
    gSuppressUntil = now + 1.2;
    MPLog(@"[hit] %@ bundle=%@ frac=(%.2f,%.2f) cmd=%ld via=%@ np=%@ url=%@",
          src, gTapBundle ?: @"?", gTapFx, gTapFy, (long)cmd, via,
          gNowPlayingBundle ?: @"(无)", abs);
    return YES;
}

// ======================= 9. Hooks =======================

// --- 9.1 UIApplication：小组件链接最终都会走这里（SpringBoard 就是 UIApplication 的子类）---

static BOOL (*orig_openURL_basic)(id, SEL, NSURL *);
static BOOL mw_openURL_basic(id self, SEL _cmd, NSURL *url) {
    if (MWHandleURL(url, @"UIApplication.openURL:")) return YES;
    return orig_openURL_basic ? orig_openURL_basic(self, _cmd, url) : NO;
}

static void (*orig_openURL_opts)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void mw_openURL_opts(id self, SEL _cmd, NSURL *url, NSDictionary *opts, void (^completion)(BOOL)) {
    if (MWHandleURL(url, @"UIApplication.openURL:options:")) {
        if (completion) completion(YES);
        return;
    }
    if (orig_openURL_opts) orig_openURL_opts(self, _cmd, url, opts, completion);
    else if (completion) completion(NO);
}

// --- 9.1b SpringBoard 自己可能覆盖了 openURL:，只在 UIApplication 上挂钩子会漏 ---

static BOOL (*orig_sb_openURL)(id, SEL, NSURL *);
static BOOL mw_sb_openURL(id self, SEL _cmd, NSURL *url) {
    if (MWHandleURL(url, @"SpringBoard.openURL:")) return YES;
    return orig_sb_openURL ? orig_sb_openURL(self, _cmd, url) : NO;
}

static void (*orig_sb_openURL_opts)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void mw_sb_openURL_opts(id self, SEL _cmd, NSURL *url, NSDictionary *opts, void (^completion)(BOOL)) {
    if (MWHandleURL(url, @"SpringBoard.openURL:options:")) {
        if (completion) completion(YES);
        return;
    }
    if (orig_sb_openURL_opts) orig_sb_openURL_opts(self, _cmd, url, opts, completion);
    else if (completion) completion(NO);
}

// --- 9.2 LSApplicationWorkspace：部分系统版本绕开 UIApplication 直接走这里 ---

static BOOL (*orig_ls_openURL)(id, SEL, NSURL *, NSDictionary *);
static BOOL mw_ls_openURL(id self, SEL _cmd, NSURL *url, NSDictionary *opts) {
    if (MWHandleURL(url, @"LSWorkspace.openURL")) return YES;
    return orig_ls_openURL ? orig_ls_openURL(self, _cmd, url, opts) : NO;
}

static BOOL (*orig_ls_openSensitive)(id, SEL, NSURL *, NSDictionary *);
static BOOL mw_ls_openSensitive(id self, SEL _cmd, NSURL *url, NSDictionary *opts) {
    if (MWHandleURL(url, @"LSWorkspace.openSensitiveURL")) return YES;
    return orig_ls_openSensitive ? orig_ls_openSensitive(self, _cmd, url, opts) : NO;
}

static BOOL (*orig_ls_openURLErr)(id, SEL, NSURL *, NSDictionary *, NSError **);
static BOOL mw_ls_openURLErr(id self, SEL _cmd, NSURL *url, NSDictionary *opts, NSError **err) {
    if (MWHandleURL(url, @"LSWorkspace.openURL:error:")) return YES;
    return orig_ls_openURLErr ? orig_ls_openURLErr(self, _cmd, url, opts, err) : NO;
}

// --- 9.3 SBIconView：桌面图标/小组件容器，用来装按钮条 ---

static void (*orig_icon_didMove)(id, SEL);
static void mw_icon_didMove(id self, SEL _cmd) {
    if (orig_icon_didMove) orig_icon_didMove(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWAttachShield((UIView *)self);
}

static void (*orig_icon_layout)(id, SEL);
static void mw_icon_layout(id self, SEL _cmd) {
    if (orig_icon_layout) orig_icon_layout(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWAttachShield((UIView *)self);
}

static void (*orig_icon_setIcon)(id, SEL, id);
static void mw_icon_setIcon(id self, SEL _cmd, id icon) {
    if (orig_icon_setIcon) orig_icon_setIcon(self, _cmd, icon);
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)self;

    // 图标视图会被复用。icon 清空通常只是刷新中间态，这时不动；
    // 只有「确认换成别的东西」才注销，避免出现空档让点击漏出去。
    if (icon != nil) {
        if (!MWIsWidgetHost(v)) { MWDetachShield(v); return; }
        NSArray *cands = MWIconCandidates(v);
        if (cands.count && !MWIsMusicCands(cands)) { MWDetachShield(v); return; }
    }
    MWAttachShield(v);
}

// 兜底：万一某个系统版本不是走手势识别器，而是直接调图标视图上的点击处理方法，
// 这里也把这次点击丢掉。窗口隔离已经能保证触摸到不了这一层，所以这些钩子只是保险，
// 方法不存在就跳过（日志里会写明）。
static struct { const char *sel; IMP orig; } gTapSlots[8];
static int gTapSlotCount = 0;

static IMP MWTapOrigFor(SEL s) {
    const char *n = sel_getName(s);
    for (int i = 0; i < gTapSlotCount; i++) {
        if (strcmp(gTapSlots[i].sel, n) == 0) return gTapSlots[i].orig;
    }
    return NULL;
}

static void mw_tapGeneric(id self, SEL _cmd, id arg) {
    if (MWIsRegisteredView(self)) {
        MPLog(@"[tap] 丢弃 %@ 上的图标点击（-%@）", MWClassName(self), NSStringFromSelector(_cmd));
        return;
    }
    IMP o = MWTapOrigFor(_cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
}

// --- 9.3b 启动闸门：遮盖层万一没接到触摸，这里把「刚点过的那个 App」的启动掐掉 ---
// 日志已经证明小组件不走 openURL，所以这几条「直接把 App 拉起来」的入口必须单独堵。

static BOOL MWGate(NSString *bundle, NSString *src, NSString *detail) {
    if (CFAbsoluteTimeGetCurrent() > gBlockUntil) return NO;
    if (!MWTapOwnsTarget(bundle)) {
        MPLog(@"[gate] %@ → %@ 不是刚点的小组件，放行", src, bundle ?: @"?");
        return NO;
    }
    gBlockUntil = 0;
    MPLog(@"[gate] 已拦下 %@ 启动 %@ %@", src, bundle ?: @"?", detail ?: @"");
    return YES;
}

static NSString *MWIDStr(id v) {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if (v) return [v description];
    return nil;
}

// FBSSystemService -openApplication:options:withResult:
static void (*orig_fbs_open)(id, SEL, id, id, id);
static void mw_fbs_open(id self, SEL _cmd, id app, id opts, id result) {
    if (MWGate(MWIDStr(app), @"FBSSystemService", nil)) return;
    if (orig_fbs_open) orig_fbs_open(self, _cmd, app, opts, result);
}

// FBSOpenApplicationService -openApplication:withOptions:clientHandle:completion:
static void (*orig_fbo_open)(id, SEL, id, id, id, id);
static void mw_fbo_open(id self, SEL _cmd, id app, id opts, id handle, id completion) {
    if (MWGate(MWIDStr(app), @"FBSOpenApplicationService", nil)) {
        if (completion) ((void (^)(id, id))completion)(nil, nil);
        return;
    }
    if (orig_fbo_open) orig_fbo_open(self, _cmd, app, opts, handle, completion);
}

// UIApplication -_launchApplicationWithIdentifier:suspended:
static void (*orig_launchApp)(id, SEL, id, BOOL);
static void mw_launchApp(id self, SEL _cmd, id ident, BOOL suspended) {
    if (MWGate(MWIDStr(ident), @"UIApplication._launchApplication", nil)) return;
    if (orig_launchApp) orig_launchApp(self, _cmd, ident, suspended);
}

// LSApplicationWorkspace -openApplicationWithBundleID:
static BOOL (*orig_ls_openApp)(id, SEL, id);
static BOOL mw_ls_openApp(id self, SEL _cmd, id bid) {
    if (MWGate(MWIDStr(bid), @"LSWorkspace.openApplication", nil)) return NO;
    return orig_ls_openApp ? orig_ls_openApp(self, _cmd, bid) : NO;
}

// 兜底：图标点击最终会汇报给 SBIconController，这里再拦一道
static void (*orig_iconTapped)(id, SEL, id);
static void mw_iconTapped(id self, SEL _cmd, id icon) {
    if (gEnabled) {
        BOOL shielded = MWIsRegisteredView(icon);
        BOOL sameTap = (CFAbsoluteTimeGetCurrent() < gBlockUntil && gTapCands.count &&
                        MWCandsMatchList(MWIconCandidates(icon), gTapCands));
        if (shielded || sameTap) {
            MPLog(@"[gate] 拦下 iconTapped: %@", MWClassName(icon));
            return;
        }
    }
    if (orig_iconTapped) orig_iconTapped(self, _cmd, icon);
}

// LSApplicationWorkspace 还有几个带 options 的变体，激活/打开都可能走这些
static BOOL (*orig_ls_openAppOpts)(id, SEL, id, id);
static BOOL mw_ls_openAppOpts(id self, SEL _cmd, id bid, id opts) {
    if (MWGate(MWIDStr(bid), @"LSWorkspace.openApplication:options:", nil)) return NO;
    return orig_ls_openAppOpts ? orig_ls_openAppOpts(self, _cmd, bid, opts) : NO;
}

static BOOL (*orig_ls_openAppOptsErr)(id, SEL, id, id, id);
static BOOL mw_ls_openAppOptsErr(id self, SEL _cmd, id bid, id opts, id err) {
    if (MWGate(MWIDStr(bid), @"LSWorkspace.openApplication:options:error:", nil)) return NO;
    return orig_ls_openAppOptsErr ? orig_ls_openAppOptsErr(self, _cmd, bid, opts, err) : NO;
}

static BOOL (*orig_ls_openSensitiveErr)(id, SEL, id, id, id);
static BOOL mw_ls_openSensitiveErr(id self, SEL _cmd, id url, id opts, id err) {
    NSString *s = MWIDStr(url);
    if (s.length && MWGate(nil, @"LSWorkspace.openSensitiveURL:error:", s)) return NO;
    return orig_ls_openSensitiveErr ? orig_ls_openSensitiveErr(self, _cmd, url, opts, err) : NO;
}

// --- 9.4 安装 ---

static void MWInstallHook(const char *clsName, const char *selName, IMP hook, IMP *orig) {
    Class c = objc_getClass(clsName);
    if (!c) {
        MPLog(@"[hook] 类 %s 不存在，跳过 %s", clsName, selName);
        return;
    }
    SEL s = sel_registerName(selName);
    Method m = class_getInstanceMethod(c, s);
    if (!m) {
        MPLog(@"[hook] %s 上没有 %s，跳过", clsName, selName);
        return;
    }
    MSHookMessageEx(c, s, hook, orig);
    MPLog(@"[hook] 已挂 %s -%s", clsName, selName);
}

// 点击兜底钩子：记录 orig，供 mw_tapGeneric 回放
static void MWInstallTapHandler(const char *clsName, const char *selName) {
    Class c = objc_getClass(clsName);
    if (!c || gTapSlotCount >= 8) return;
    SEL s = sel_registerName(selName);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { MPLog(@"[hook] %s 上没有 %s，跳过", clsName, selName); return; }
    IMP orig = NULL;
    MSHookMessageEx(c, s, (IMP)mw_tapGeneric, &orig);
    gTapSlots[gTapSlotCount].sel  = selName;
    gTapSlots[gTapSlotCount].orig = orig;
    gTapSlotCount++;
    MPLog(@"[hook] 已挂 %s -%s（点击兜底）", clsName, selName);
}

static void MWInstallAllHooks(void) {
    MWInstallHook("UIApplication", "openURL:", (IMP)mw_openURL_basic, (IMP *)&orig_openURL_basic);
    MWInstallHook("UIApplication", "openURL:options:completionHandler:",
                  (IMP)mw_openURL_opts, (IMP *)&orig_openURL_opts);

    // SpringBoard 若自己实现了 openURL:，上面的 UIApplication 钩子不会生效，这里补一份
    MWInstallHook("SpringBoard", "openURL:", (IMP)mw_sb_openURL, (IMP *)&orig_sb_openURL);
    MWInstallHook("SpringBoard", "openURL:options:completionHandler:",
                  (IMP)mw_sb_openURL_opts, (IMP *)&orig_sb_openURL_opts);

    MWInstallHook("LSApplicationWorkspace", "openURL:withOptions:", (IMP)mw_ls_openURL, (IMP *)&orig_ls_openURL);
    MWInstallHook("LSApplicationWorkspace", "openSensitiveURL:withOptions:",
                  (IMP)mw_ls_openSensitive, (IMP *)&orig_ls_openSensitive);
    MWInstallHook("LSApplicationWorkspace", "openURL:withOptions:error:",
                  (IMP)mw_ls_openURLErr, (IMP *)&orig_ls_openURLErr);

    MWInstallHook("SBIconView", "didMoveToWindow", (IMP)mw_icon_didMove, (IMP *)&orig_icon_didMove);
    MWInstallHook("SBIconView", "layoutSubviews", (IMP)mw_icon_layout, (IMP *)&orig_icon_layout);
    MWInstallHook("SBIconView", "setIcon:", (IMP)mw_icon_setIcon, (IMP *)&orig_icon_setIcon);

    // 启动闸门（这些入口和 URL 无关，是直接「把 App 拉起来」的路径）
    MWInstallHook("FBSSystemService", "openApplication:options:withResult:",
                  (IMP)mw_fbs_open, (IMP *)&orig_fbs_open);
    MWInstallHook("FBSOpenApplicationService", "openApplication:withOptions:clientHandle:completion:",
                  (IMP)mw_fbo_open, (IMP *)&orig_fbo_open);
    MWInstallHook("UIApplication", "_launchApplicationWithIdentifier:suspended:",
                  (IMP)mw_launchApp, (IMP *)&orig_launchApp);
    MWInstallHook("LSApplicationWorkspace", "openApplicationWithBundleID:",
                  (IMP)mw_ls_openApp, (IMP *)&orig_ls_openApp);
    MWInstallHook("LSApplicationWorkspace", "openApplicationWithBundleID:options:",
                  (IMP)mw_ls_openAppOpts, (IMP *)&orig_ls_openAppOpts);
    MWInstallHook("LSApplicationWorkspace", "openApplicationWithBundleID:options:withError:",
                  (IMP)mw_ls_openAppOptsErr, (IMP *)&orig_ls_openAppOptsErr);
    MWInstallHook("LSApplicationWorkspace", "openSensitiveURL:withOptions:error:",
                  (IMP)mw_ls_openSensitiveErr, (IMP *)&orig_ls_openSensitiveErr);

    MWInstallHook("SBIconController", "iconTapped:", (IMP)mw_iconTapped, (IMP *)&orig_iconTapped);

    // 点击兜底：不同系统把这些点击处理方法命名成不同样子，全部试一遍，存在才挂。
    const char *tapSels[] = { "handleTapGesture:", "_handleTapGesture:", "tapGestureRecognized:",
                              "_tapGestureRecognized:", "_iconTapped:", "_handleIconTapGesture:" };
    for (int i = 0; i < (int)(sizeof(tapSels) / sizeof(tapSels[0])); i++) {
        MWInstallTapHandler("SBIconView", tapSels[i]);
    }

    // 兜底：类名换了的系统上，把带 Widget 字样的图标容器类也挂上
    const char *extra[] = { "SBHWidgetIconView", "SBWidgetIconView" };
    for (int i = 0; i < 2; i++) {
        Class c = objc_getClass(extra[i]);
        if (!c) continue;
        SEL s = @selector(didMoveToWindow);
        Method m = class_getInstanceMethod(c, s);
        if (m) {
            static IMP o1, o2;
            IMP *slot = (i == 0) ? &o1 : &o2;
            MSHookMessageEx(c, s, (IMP)mw_icon_didMove, slot);
            MPLog(@"[hook] 已挂 %s -didMoveToWindow", extra[i]);
        }
    }
}

// ======================= 10. 入口 =======================

__attribute__((constructor))
static void MusicWidgetDirectInit(void) {
    @autoreleasepool {
        NSString *pn = NSProcessInfo.processInfo.processName;
        MPLog(@"==== MusicWidgetDirect %@ 载入 (pid=%d, %@) ====", MY_VERSION, getpid(), pn);

        // 只该注入 SpringBoard；注入错了直接不干活
        if (![pn isEqualToString:@"SpringBoard"]) {
            MPLog(@"当前进程不是 SpringBoard，不做任何处理");
            return;
        }

        MWEnsureConfig();
        MWLoadMediaRemote();
        MWInstallAllHooks();
        MWFetchNowPlaying();

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 1ull * NSEC_PER_SEC),
            3ull * NSEC_PER_SEC,
            500ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ MWFetchNowPlaying(); });
        dispatch_resume(timer);

        MPLog(@"初始化完成");
    }
}
