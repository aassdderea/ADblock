// ==========================================
// Tweak.xm - GDT跳过雷达 (持续监听+异步日志版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static CFAbsoluteTime g_startTime = 0;
static BOOL g_collectionEnded = NO;

// ⭐ 异步日志队列，避免主线程阻塞
static dispatch_queue_t g_logQueue = nil;

// ==========================================
// 📁 异步日志工具
// ==========================================
static NSString *getDiagLogPath() {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = [paths.firstObject stringByAppendingPathComponent:@"adblock_diag.log"];
    });
    return path;
}

static void writeDiagLog(NSString *message) {
    if (!message || g_collectionEnded) return;
    NSString *msgCopy = [message copy];
    dispatch_async(g_logQueue, ^{
        @try {
            NSString *logPath = getDiagLogPath();
            CFAbsoluteTime relative = CFAbsoluteTimeGetCurrent() - g_startTime;
            NSString *entry = [NSString stringWithFormat:@"[+%.2fs] %@\n", relative, msgCopy];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            }
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    });
}

// ==========================================
// 🔬 轻量级持续诊断（可在主线程安全执行）
// ==========================================
static void lightweightDiagnose(UIView *skipView, NSString *triggerReason) {
    if (!skipView) return;
    
    writeDiagLog([NSString stringWithFormat:@"📍 诊断触发: %@", triggerReason]);
    
    // 仅记录视图层级和类名，不做 method enumeration
    NSMutableArray *info = [NSMutableArray array];
    UIView *v = skipView;
    int depth = 0;
    while (v && depth <= 15) {
        NSString *cls = NSStringFromClass([v class]);
        [info addObject:[NSString stringWithFormat:@"d%d:%@", depth, cls]];
        
        // 仅对 GDT/Splash 类记录手势和 delegate（轻量）
        if ([cls containsString:@"GDT"] || [cls containsString:@"Splash"]) {
            NSUInteger gestureCount = v.gestureRecognizers.count;
            [info addObject:[NSString stringWithFormat:@"  ↳ gestures:%lu", (unsigned long)gestureCount]];
            
            if ([v respondsToSelector:@selector(delegate)]) {
                @try {
                    id del = [v performSelector:@selector(delegate)];
                    [info addObject:[NSString stringWithFormat:@"  ↳ delegate:%@", del ? NSStringFromClass([del class]) : @"nil"]];
                } @catch (NSException *e) {
                    [info addObject:@"  ↳ delegate:EXCEPTION"];
                }
            }
        }
        v = v.superview;
        depth++;
    }
    
    writeDiagLog([info componentsJoinedByString:@"\n"]);
}

// ==========================================
// UI 置顶保障
// ==========================================
static void ensureOverlayOnTop() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *topWindow = nil;
        CGFloat maxLevel = -1;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (!w.isHidden && w.windowLevel > maxLevel) {
                        maxLevel = w.windowLevel;
                        topWindow = w;
                    }
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!topWindow) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (!w.isHidden && w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    topWindow = w;
                }
            }
        }
#pragma clang diagnostic pop
        if (!topWindow) return;

        if (!g_overlayView || g_overlayView.window != topWindow) {
            [g_overlayView removeFromSuperview];
            g_overlayView = [[UIView alloc] initWithFrame:topWindow.bounds];
            g_overlayView.backgroundColor = [UIColor clearColor];
            g_overlayView.userInteractionEnabled = NO;
            g_overlayView.layer.zPosition = 999999;
            
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, topWindow.bounds.size.height - 150, topWindow.bounds.size.width - 40, 80)];
            g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
            g_statusLabel.textColor = [UIColor yellowColor];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            g_statusLabel.font = [UIFont boldSystemFontOfSize:16];
            g_statusLabel.l
