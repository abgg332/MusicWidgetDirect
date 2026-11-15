// MusicWidgetDirect —— 桌面小组件「按钮直控」插件
// ---------------------------------------------------------------
// 解决的问题：
//   第三方音乐 App 的桌面小组件，点播放/上一首/下一首的按钮，实际是把整个
//   小组件做成一个 Link，点了就 openURL 把 App 拉到前台，音乐并没有真的被控制。
//
// 做法（三层，从物理到兜底）：
//   ① 遮盖层：在音乐 App 小组件的控制区上盖一层透明视图，hitTest 直接返回它。
//      触摸根本到不了小组件，App 自然不会被拉起来；点击由遮盖层自己接，发媒体命令。
//   ② 启动闸门：万一触摸漏到 SpringBoard 的图标手势上，就用 FBSSystemService /
//      FBSOpenApplicationService / _launchApplication 这些入口把「刚点过的那个 App」
//      的启动掐掉（只掐 1.5 秒内的、只掐同一个 App）。
//   ③ URL 拦截：老系统上仍然走 openURL 的，兜底吞掉并改发媒体命令。
//
// 0.1/0.2 只做了 ③ + 观察手势，真机日志证明酷狗/汽水根本不走 openURL，
// 所以 0.3 必须靠 ①（物理隔离）才拦得住。
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
        return;
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

static BOOL MWIsWidgetIcon(id icon) {
    if (!icon) return NO;
    NSString *cn = MWClassName(icon);
    if ([cn rangeOfString:@"Widget"].location != NSNotFound) return YES;
    if ([icon respondsToSelector:@selector(activeWidget)]) return YES;
    if ([icon respondsToSelector:@selector(widgets)]) return YES;
    // 有的版本图标类叫 SBLeafIcon，但是小组件类型的 icon 会有 SBIconTypeWidget 之类的类型串
    id t = MWObj(icon, @"iconType");
    if (t && [[t description] rangeOfString:@"Widget" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
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
    return @[
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

static NSInteger MWActionFromPoint(CGPoint p, CGSize sz) {
    if (sz.width < 2 || sz.height < 2) return -1;
    CGFloat fx = p.x / sz.width;
    CGFloat fy = p.y / sz.height;
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

// ======================= 7. 触摸接管（透明遮盖层） =======================
//
// 0.2.0 的「挂观察手势 + 拦 URL」在真机上不成立。日志已经证明了：
//   [tap] 有、[hit-swallow] 有、[cmd] 也发出去了，但**一条 [url] 都没有** ——
//   说明酷狗/汽水这类小组件根本不走 openURL，而是小组件自己（或 SpringBoard
//   的图标手势）直接把 App 拉起来。拦 URL 等于拦空气。
//
// 0.3.0 改成物理隔离：在小组件的控制区上面盖一层**透明遮盖层**。
//   · 触摸落在遮盖层上，hitTest 直接返回遮盖层 —— 小组件和 SpringBoard 的手势
//     都收不到这次触摸，App 自然不会起来；
//   · 遮盖层自己收点击 → 发 MediaRemote 命令（和耳机线控同一套指令）；
//   · 长按遮盖层 0.55 秒 → 暂停接管 6 秒，方便正常拖动/编辑小组件。
// 遮盖层只装给「音乐 App 的小组件」，其它小组件一个像素都不碰。

static char kMWShieldKey;
static char kMWProxyKey;
static double gShieldOffUntil = 0;

@interface MWTapProxy : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *hostView;
@end

@implementation MWTapProxy

- (void)handleShieldTap:(UITapGestureRecognizer *)gr {
    UIView *host = self.hostView;
    if (!host || !gr) return;
    MWEnsureConfig();
    if (!gEnabled) return;

    NSArray *cands = MWIconCandidates(host);
    CGPoint p  = [gr locationInView:host];
    CGSize  sz = host.bounds.size;

    gTapPoint  = p;
    gTapSize   = sz;
    gTapFx     = (sz.width  > 0) ? p.x / sz.width  : -1;
    gTapFy     = (sz.height > 0) ? p.y / sz.height : -1;
    gTapCands  = [cands copy];
    gTapBundle = [MWBestBundle(cands) copy];
    gTapTime   = CFAbsoluteTimeGetCurrent();
    gSuppressUntil = 0;

    NSInteger cmd = MWActionFromPoint(p, sz);
    NSString *via = @"region";
    if (cmd < 0) { cmd = gFallbackCmd; via = @"fallback"; }

    MPLog(@"[tap] bundle=%@ frac=(%.2f,%.2f) size=(%.0f,%.0f) icon=%@ cmd=%ld via=%@",
          gTapBundle ?: @"(未知)", gTapFx, gTapFy, sz.width, sz.height,
          MWClassName(MWObj(host, @"icon")), (long)cmd, via);

    MWSendCommand((int)cmd);

    double now = CFAbsoluteTimeGetCurrent();
    gTapTime       = 0;
    gSuppressUntil = now + 1.5;
    gBlockUntil    = now + 1.5;   // 这 1.5s 内不许把这个 App 拉到前台
    MPLog(@"[hit] shield bundle=%@ frac=(%.2f,%.2f) cmd=%ld np=%@",
          gTapBundle ?: @"?", gTapFx, gTapFy, (long)cmd, gNowPlayingBundle ?: @"(无)");
}

// 长按：暂时撤掉接管，让用户能正常拖动 / 删除 / 编辑小组件
- (void)handleShieldLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    gShieldOffUntil = CFAbsoluteTimeGetCurrent() + 6.0;
    UIView *host = self.hostView;
    UIView *shield = host ? objc_getAssociatedObject(host, &kMWShieldKey) : nil;
    if ([shield isKindOfClass:[UIView class]]) ((UIView *)shield).hidden = YES;
    MPLog(@"[shield] 长按：暂停接管 6 秒（可拖动/编辑小组件）");
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}

@end

// 控制区的外接矩形（归一化 Region 的并集），遮盖层就盖这一块
static CGRect MWRegionsUnionRect(CGSize sz) {
    CGFloat x0 = 1, y0 = 1, x1 = 0, y1 = 0;
    BOOL any = NO;
    for (NSDictionary *r in gRegions) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        CGFloat x = [r[@"x"] doubleValue];
        CGFloat y = [r[@"y"] doubleValue];
        CGFloat w = [r[@"w"] doubleValue];
        CGFloat h = [r[@"h"] doubleValue];
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x + w > x1) x1 = x + w;
        if (y + h > y1) y1 = y + h;
        any = YES;
    }
    if (!any || x1 <= x0 || y1 <= y0) return CGRectZero;
    return CGRectMake(x0 * sz.width, y0 * sz.height,
                      (x1 - x0) * sz.width, (y1 - y0) * sz.height);
}

static void MWEnsureShield(UIView *v) {
    if (![v isKindOfClass:[UIView class]]) return;

    CGSize sz = v.bounds.size;
    if (sz.width < 60 || sz.height < 40) return;   // 不是小组件的尺度，忽略

    UIView *shield = objc_getAssociatedObject(v, &kMWShieldKey);

    // 已经装过：只更新位置和层级。layoutSubviews 调用很频繁，这条路必须够便宜，
    // 不要在这里读配置、也不要再算包名。
    if (shield) {
        CGRect r = MWRegionsUnionRect(sz);
        if (!CGRectIsEmpty(r) && !CGRectEqualToRect(shield.frame, r)) shield.frame = r;
        if (shield.superview != v) [v addSubview:shield];
        if (v.subviews.lastObject != shield) [v bringSubviewToFront:shield];
        if (!gEnabled || !gSwallow) { shield.hidden = YES; return; }
        shield.hidden = (CFAbsoluteTimeGetCurrent() < gShieldOffUntil);
        return;
    }

    MWEnsureConfig();
    if (!gEnabled || !gSwallow) return;   // SwallowTouch=false 时不装遮盖层，只留 URL 兜底

    NSArray *cands = MWIconCandidates(v);
    if (!MWIsMusicCands(cands)) return;   // 只接管音乐 App 的小组件

    CGRect r = MWRegionsUnionRect(sz);
    if (CGRectIsEmpty(r)) return;

    shield = [[UIView alloc] initWithFrame:r];
    shield.backgroundColor = [UIColor clearColor];
    shield.opaque = NO;
    shield.clearsContextBeforeDrawing = NO;
    shield.autoresizingMask = UIViewAutoresizingNone;
    shield.isAccessibilityElement = NO;

    MWTapProxy *proxy = [[MWTapProxy alloc] init];
    proxy.hostView = v;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:proxy action:@selector(handleShieldTap:)];
    tap.delegate = proxy;
    [shield addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:proxy action:@selector(handleShieldLongPress:)];
    lp.minimumPressDuration = 0.55;
    lp.delegate = proxy;
    [shield addGestureRecognizer:lp];

    objc_setAssociatedObject(shield, &kMWProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [v addSubview:shield];
    objc_setAssociatedObject(v, &kMWShieldKey, shield, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    MPLog(@"[shield] 已接管 %@ bundle=%@ rect=(%.0f,%.0f,%.0f,%.0f)",
          MWClassName(v), MWBestBundle(cands) ?: @"?", r.origin.x, r.origin.y, r.size.width, r.size.height);
}

// 图标被复用（换成别的小组件/普通 App）时，把上一轮的遮盖层拆掉
static void MWDetachShield(UIView *v) {
    if (![v isKindOfClass:[UIView class]]) return;
    UIView *shield = objc_getAssociatedObject(v, &kMWShieldKey);
    if (![shield isKindOfClass:[UIView class]]) return;
    [shield removeFromSuperview];
    objc_setAssociatedObject(v, &kMWShieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MPLog(@"[shield] 图标换内容，拆除旧遮盖层 %@", MWClassName(v));
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

// --- 9.3 SBIconView：桌面图标/小组件容器，用来装遮盖层 ---

static void (*orig_icon_didMove)(id, SEL);
static void mw_icon_didMove(id self, SEL _cmd) {
    if (orig_icon_didMove) orig_icon_didMove(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWEnsureShield((UIView *)self);
}

static void (*orig_icon_layout)(id, SEL);
static void mw_icon_layout(id self, SEL _cmd) {
    if (orig_icon_layout) orig_icon_layout(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWEnsureShield((UIView *)self);
}

static void (*orig_icon_setIcon)(id, SEL, id);
static void mw_icon_setIcon(id self, SEL _cmd, id icon) {
    if ([self isKindOfClass:[UIView class]]) MWDetachShield((UIView *)self);
    if (orig_icon_setIcon) orig_icon_setIcon(self, _cmd, icon);
    if ([self isKindOfClass:[UIView class]]) MWEnsureShield((UIView *)self);
}

// 关键一步：落在控制区的触摸直接判给遮盖层。
// 只靠「加个子视图」不够——SBIconView 若自己重写过 hitTest，会完全绕过子视图顺序。
static id (*orig_icon_hitTest)(id, SEL, CGPoint, UIEvent *);
static id mw_icon_hitTest(id self, SEL _cmd, CGPoint p, UIEvent *e) {
    id r = orig_icon_hitTest ? orig_icon_hitTest(self, _cmd, p, e) : nil;
    if (!gEnabled || ![self isKindOfClass:[UIView class]]) return r;
    UIView *shield = objc_getAssociatedObject(self, &kMWShieldKey);
    if (![shield isKindOfClass:[UIView class]]) return r;
    if (shield.hidden || shield.superview != (UIView *)self) return r;
    if (CGRectContainsPoint(shield.frame, p)) return shield;
    return r;
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
    MWInstallHook("SBIconView", "hitTest:withEvent:", (IMP)mw_icon_hitTest, (IMP *)&orig_icon_hitTest);

    // 启动闸门（这些入口和 URL 无关，是直接「把 App 拉起来」的路径）
    MWInstallHook("FBSSystemService", "openApplication:options:withResult:",
                  (IMP)mw_fbs_open, (IMP *)&orig_fbs_open);
    MWInstallHook("FBSOpenApplicationService", "openApplication:withOptions:clientHandle:completion:",
                  (IMP)mw_fbo_open, (IMP *)&orig_fbo_open);
    MWInstallHook("UIApplication", "_launchApplicationWithIdentifier:suspended:",
                  (IMP)mw_launchApp, (IMP *)&orig_launchApp);
    MWInstallHook("LSApplicationWorkspace", "openApplicationWithBundleID:",
                  (IMP)mw_ls_openApp, (IMP *)&orig_ls_openApp);

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
