// MusicWidgetDirect —— 桌面小组件「按钮直控」插件
// ---------------------------------------------------------------
// 解决的问题：
//   第三方音乐 App 的桌面小组件，点播放/上一首/下一首的按钮，实际是把整个
//   小组件做成一个 Link，点了就 openURL 把 App 拉到前台，音乐并没有真的被控制。
//
// 做法（两层，互不干扰）：
//   ① 记录层：在小组件图标视图上挂一个「只观察、不吃掉」的点击手势，
//      记下这次点击发生在小组件的哪个位置（归一化坐标）+ 这个小组件属于哪个 App。
//   ② 拦截层：hook 进程内所有 URL 打开入口。当一次 URL 打开紧跟在「小组件点击」
//      之后发生，就把它吞掉，改发 MediaRemote 媒体命令（播放/暂停、上一首、下一首）。
//
//   之所以「先记位置、再拦 URL」而不是直接吃掉手势：
//     · 小组件如果用的是 iOS17 的 AppIntent 按钮，它本来就不跳 App，
//       我们不吃手势 → 它照常工作，我们不重复发命令；
//     · 只有它真的要去开 App 时我们才拦，行为可预期，不会把小组件的其它交互搞坏。
//   如果你的机型/系统上「URL 拦不住」（日志里没有 [url] 行、但 App 还是被拉起来了），
//   把配置里的 SwallowTouch 改成 true，改成在点击阶段直接吃掉手势。
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
static BOOL        gSwallow            = NO;    // YES=点击阶段直接吃掉手势
static BOOL        gRequireNowPlaying  = YES;   // 只拦「当前正在播放的那个 App」的小组件
static BOOL        gAttachAll          = NO;    // 组件的类型识别不出来时，挂到所有图标上
static CGFloat     gTapWindow          = 2.5;   // 点击 → openURL 的关联时间窗（秒）
static NSArray    *gBundleIDs          = nil;   // 白名单；空 = 所有小组件
static NSArray    *gRegions            = nil;   // 区域 → 动作
static NSDictionary *gURLKeywords      = nil;   // 自定义 URL 关键字 → 动作
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

typedef void (*MWMRSendCommand)(int command, id userInfo);
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
        pMRSendCommand(cmd, nil);
        MPLog(@"[cmd] MediaRemote 发送命令 %d", cmd);
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

static NSDictionary *MWDefaultConfig(void) {
    return @{
        @"Enabled"           : @YES,
        @"VerboseLog"        : @NO,
        @"SwallowTouch"      : @NO,
        @"RequireNowPlaying" : @YES,
        @"AttachToAllIcons"  : @NO,
        @"TapWindow"         : @2.5,
        @"BundleIDs"         : @[],
        @"Regions"           : MWDefaultRegions(),
        @"URLKeywords"       : @{},
        @"FallbackAction"    : @"toggle",
    };
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

static void MWLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kCfgPath];
    if (![d isKindOfClass:[NSDictionary class]]) {
        d = MWDefaultConfig();
        [d writeToFile:kCfgPath atomically:YES];   // 首次运行写一份默认配置，方便用户照着改
        MPLog(@"[cfg] 生成默认配置 %@", kCfgPath);
    }

    id v = nil;
    v = d[@"Enabled"];           gEnabled           = v ? [v boolValue] : YES;
    v = d[@"VerboseLog"];        gVerbose           = v ? [v boolValue] : NO;
    v = d[@"SwallowTouch"];      gSwallow           = v ? [v boolValue] : NO;
    v = d[@"RequireNowPlaying"]; gRequireNowPlaying = v ? [v boolValue] : YES;
    v = d[@"AttachToAllIcons"];  gAttachAll         = v ? [v boolValue] : NO;
    v = d[@"TapWindow"];         gTapWindow         = v ? [v doubleValue] : 2.5;
    if (gTapWindow < 0.3) gTapWindow = 0.3;
    if (gTapWindow > 10.0) gTapWindow = 10.0;

    NSArray *ids = d[@"BundleIDs"];
    gBundleIDs = [ids isKindOfClass:[NSArray class]] ? ids : @[];

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

// ======================= 7. 点击记录 =======================

static char kMWGRKey;

@interface MWTapProxy : NSObject <UIGestureRecognizerDelegate>
@end

@implementation MWTapProxy

- (void)recordTap:(UIGestureRecognizer *)gr {
    UIView *v = gr.view;
    if (!v) return;
    NSArray *cands = MWIconCandidates(v);
    CGPoint p = [gr locationInView:v];
    CGSize sz = v.bounds.size;

    gTapPoint  = p;
    gTapSize   = sz;
    gTapFx     = (sz.width  > 0) ? p.x / sz.width  : -1;
    gTapFy     = (sz.height > 0) ? p.y / sz.height : -1;
    gTapTime   = CFAbsoluteTimeGetCurrent();
    gTapCands  = [cands copy];
    gTapBundle = [MWBestBundle(cands) copy];
    gSuppressUntil = 0;   // 新的一次点击，解除上一次的去重窗口

    MPLogD(@"[tap] 图标=%@ icon=%@ bundle=%@ cands=%@ frac=(%.2f,%.2f) size=(%.0f,%.0f)",
           MWClassName(v), MWClassName(MWObj(v, @"icon")),
           gTapBundle ?: @"(未知)", [cands componentsJoinedByString:@"|"],
           gTapFx, gTapFy, sz.width, sz.height);
}

- (void)handle:(UITapGestureRecognizer *)gr {
    [self recordTap:gr];
    if (!gSwallow) return;   // 记录模式：后面交给 URL 拦截层处理

    // 吃掉模式：点击当场就判定，不再等 URL
    MWEnsureConfig();
    if (!gEnabled) return;
    NSInteger cmd = MWActionFromPoint(gTapPoint, gTapSize);
    if (cmd < 0) cmd = gFallbackCmd;
    if (gRequireNowPlaying && !MWCandsMatchList(gTapCands, @[ gNowPlayingBundle ?: @"" ])) {
        MPLogD(@"[tap] 当前播放 App 不是这个小组件，放行");
        return;
    }
    MWSendCommand((int)cmd);
    gTapTime = 0;
    gSuppressUntil = CFAbsoluteTimeGetCurrent() + 1.2;
    MPLog(@"[hit-swallow] bundle=%@ frac=(%.2f,%.2f) cmd=%ld",
          gTapBundle ?: @"?", gTapFx, gTapFy, (long)cmd);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    MWEnsureConfig();
    if (!gEnabled) return NO;
    if (!gSwallow) return YES;   // 记录模式永远放行，不影响小组件自身交互

    // 吃掉模式：只有落在控制区里的点击才吞，点封面/其它地方依旧可以打开 App
    UIView *v = gr.view;
    if (!v) return NO;
    CGPoint p = [gr locationInView:v];
    return MWActionFromPoint(p, v.bounds.size) >= 0;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;   // 不抢小组件/桌面自己的手势
}

@end

static void MWAttachToIconView(UIView *v) {
    if (!v) return;
    if (objc_getAssociatedObject(v, &kMWGRKey)) return;

    MWEnsureConfig();
    if (!gEnabled) return;

    id icon = MWObj(v, @"icon");
    NSArray *cands = MWIconCandidates(v);
    BOOL widgetish = MWIsWidgetIcon(icon);
    if (!widgetish) {
        // 图标类名里也可能直接带 Widget（不同系统版本容器类不一样），一并认掉
        NSString *vn = MWClassName(v);
        if ([vn rangeOfString:@"Widget"].location != NSNotFound) widgetish = YES;
    }
    BOOL wlMatch = MWCandsMatchList(cands, gBundleIDs);
    BOOL should = gAttachAll ? YES : (gBundleIDs.count ? wlMatch : widgetish);
    if (!should) return;

    MWTapProxy *proxy = [[MWTapProxy alloc] init];
    UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc] initWithTarget:proxy action:@selector(handle:)];
    gr.delegate = proxy;
    gr.cancelsTouchesInView = NO;
    gr.delaysTouchesEnded = NO;
    [v addGestureRecognizer:gr];
    objc_setAssociatedObject(v, &kMWGRKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    MPLog(@"[attach] 已挂载 %@ (icon=%@, widget=%d, bundle=%@)",
          MWClassName(v), MWClassName(icon), widgetish, MWBestBundle(cands) ?: @"?");
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
    if (gTapTime <= 0 || now - gTapTime > gTapWindow) {
        MPLogD(@"[url] 不是小组件点击引发的，放行: %@ (%@)", abs, src);
        return NO;
    }

    // ③ 白名单
    if (!MWCandsMatchList(gTapCands, gBundleIDs)) {
        MPLogD(@"[url] 不在白名单: %@ 放行", gTapBundle ?: @"?");
        return NO;
    }

    // ④ 只处理「当前正在播放的那个 App」的小组件，其它 App 的小组件照常打开 App
    if (gRequireNowPlaying) {
        if (!gNowPlayingBundle.length) {
            MPLogD(@"[url] 当前没有正在播放的 App，放行: %@", abs);
            return NO;
        }
        if (!MWCandsMatchList(gTapCands, @[ gNowPlayingBundle ])) {
            MPLogD(@"[url] 正在播放的是 %@，不是这个小组件(%@)，放行",
                   gNowPlayingBundle, gTapBundle ?: @"?");
            return NO;
        }
    }

    // ⑤ 定动作：URL 关键字 → 点击区域 → 兜底
    NSInteger cmd = MWActionFromURL(abs);
    NSString *via = @"url";
    if (cmd < 0) {
        cmd = MWActionFromPoint(gTapPoint, gTapSize);
        via = @"region";
    }
    if (cmd < 0) {
        if (!gSwallow) {
            MPLogD(@"[url] 落在非控制区且 URL 无动作信息，放行（正常打开 App）: %@", abs);
            return NO;
        }
        cmd = gFallbackCmd;
        via = @"fallback";
    }

    MWSendCommand((int)cmd);
    gTapTime = 0;
    gSuppressUntil = now + 1.2;
    MPLog(@"[hit] %@ bundle=%@ frac=(%.2f,%.2f) cmd=%ld via=%@ url=%@",
          src, gTapBundle ?: @"?", gTapFx, gTapFy, (long)cmd, via, abs);
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

// --- 9.3 SBIconView：桌面图标/小组件容器，用来挂观察手势 ---

static void (*orig_icon_didMove)(id, SEL);
static void mw_icon_didMove(id self, SEL _cmd) {
    if (orig_icon_didMove) orig_icon_didMove(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWAttachToIconView((UIView *)self);
}

static void (*orig_icon_layout)(id, SEL);
static void mw_icon_layout(id self, SEL _cmd) {
    if (orig_icon_layout) orig_icon_layout(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) MWAttachToIconView((UIView *)self);
}

static void (*orig_icon_setIcon)(id, SEL, id);
static void mw_icon_setIcon(id self, SEL _cmd, id icon) {
    if (orig_icon_setIcon) orig_icon_setIcon(self, _cmd, icon);
    if ([self isKindOfClass:[UIView class]]) MWAttachToIconView((UIView *)self);
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

    MWInstallHook("LSApplicationWorkspace", "openURL:withOptions:", (IMP)mw_ls_openURL, (IMP *)&orig_ls_openURL);
    MWInstallHook("LSApplicationWorkspace", "openSensitiveURL:withOptions:",
                  (IMP)mw_ls_openSensitive, (IMP *)&orig_ls_openSensitive);
    MWInstallHook("LSApplicationWorkspace", "openURL:withOptions:error:",
                  (IMP)mw_ls_openURLErr, (IMP *)&orig_ls_openURLErr);

    MWInstallHook("SBIconView", "didMoveToWindow", (IMP)mw_icon_didMove, (IMP *)&orig_icon_didMove);
    MWInstallHook("SBIconView", "layoutSubviews", (IMP)mw_icon_layout, (IMP *)&orig_icon_layout);
    MWInstallHook("SBIconView", "setIcon:", (IMP)mw_icon_setIcon, (IMP *)&orig_icon_setIcon);

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
