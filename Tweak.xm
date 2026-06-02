// ==========================================
// Tweak.xm - GDT跳过雷达 (最终生产版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasSkipped = NO;

// ==========================================
// 📁 日志工具
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
    if (!message) return;
    @try {
        NSString *logPath = getDiagLogPath();
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [[NSDate date] description], message];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// ==========================================
// 🎯 精准触发（基于日志验证的调用链）
// ==========================================
static void triggerVerifiedSkip(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            writeDiagLog(@"====== 精准触发开始 ======");
            
            // 1. 找到 GDTSystemGestureRecognizer
            UIGestureRecognizer *gdtGesture = nil;
            UIView *splashView = nil;
            UIView *searchView = skipView;
            int depth = 0;
            
            while (searchView && depth <= 10) {
                NSString *cls = NSStringFromClass([searchView class]);
                
                // 记录 SplashView
                if ([cls containsString:@"Splash"] && !splashView) {
                    splashView = searchView;
                }
                
                // 找 GDT 手势
                for (UIGestureRecognizer *g in searchView.gestureRecognizers) {
                    if ([NSStringFromClass([g class]) containsString:@"GDT"]) {
                        gdtGesture = g;
                        break;
                    }
                }
                if (gdtGesture) break;
                
                searchView = searchView.superview;
                depth++;
            }
            
            if (!gdtGesture || !splashView) {
                writeDiagLog([NSString stringWithFormat:@"❌ 未找到必要组件 gesture=%@ splash=%@", 
                              gdtGesture ? @"✅" : @"❌", splashView ? @"✅" : @"❌"]);
                return;
            }
            
            writeDiagLog([NSString stringWithFormat:@"✅ gesture: %@ | splash: %@", 
                          NSStringFromClass([gdtGesture class]), NSStringFromClass([splashView class])]);
            
            // 2. ⭐ 核心：调用 handleSkipClick: 并传入手势对象（type v@:@ 已验证）
            SEL handleSkipSel = @selector(handleSkipClick:);
            if ([splashView respondsToSelector:handleSkipSel]) {
                ((void(*)(id,SEL,id))objc_msgSend)(splashView, handleSkipSel, gdtGesture);
                writeDiagLog(@"✅ handleSkipClick: 已调用（参数=gdtGesture）");
            } else {
                writeDiagLog(@"⚠️ handleSkipClick: 不可用");
            }
            
            // 3. 备用：直接通知 delegate splashAdClosed:
            if ([splashView respondsToSelector:@selector(delegate)]) {
                id delegate = [splashView performSelector:@selector(delegate)];
                SEL closedSel = @selector(splashAdClosed:);
                if (delegate && [delegate respondsToSelector:closedSel]) {
                    ((void(*)(id,SEL,id))objc_msgSend)(delegate, closedSel, splashView);
                    writeDiagLog(@"✅ delegate.splashAdClosed: 已调用");
                }
            }
            
            writeDiagLog(@"====== 精准触发结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 触发异常: %@", e]);
        }
    });
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
            g_statusLabel.layer.cornerRadius = 10;
            g_statusLabel.clipsToBounds = YES;
            g_statusLabel.numberOfLines = 0;
            g_statusLabel.text = @"🔍 雷达已启动...\n正在扫描广告按钮";
            
            [g_overlayView addSubview:g_statusLabel];
            [topWindow addSubview:g_overlayView];
        }
    });
}

// ==========================================
// 深度雷达扫描
// ==========================================
static BOOL scanAndTrigger(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1 || view == g_overlayView) return NO;

    NSString *textToCheck = nil;
    if ([view isKindOfClass:[UILabel class]]) textToCheck = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) textToCheck = view.accessibilityLabel;

    if (textToCheck.length > 0 && textToCheck.length < 20) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 已锁定 \"%@\"\n正在触发跳过...", textToCheck];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                triggerVerifiedSkip(view);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"✅ 已尝试跳过\n文字: \"%@\"", textToCheck];
                        g_statusLabel.textColor = [UIColor greenColor];
                    }
                });
                return YES;
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndTrigger(view.subviews[i])) return YES;
    }
    return NO;
}

// ==========================================
// 定时器 & 生命周期
// ==========================================
static void radarTick() {
    if (g_hasSkipped) return;
    g_scanCount++;
    if (g_scanCount > 100) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = @"⏱️ 扫描超时";
                g_statusLabel.textColor = [UIColor grayColor];
            }
        });
        return;
    }
    ensureOverlayOnTop();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window;
        if (scanWindow) {
            BOOL found = scanAndTrigger(scanWindow);
            if (found) g_hasSkipped = YES;
            else if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 扫描中... (%d/100)", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    g_scanCount = 0;
    g_hasSkipped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_statusLabel) {
            g_statusLabel.text = @"🔍 雷达已重启...";
            g_statusLabel.textColor = [UIColor yellowColor];
        }
    });
    writeDiagLog(@"🔄 扫描状态已重置");
}
%end

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    [[NSFileManager defaultManager] removeItemAtPath:getDiagLogPath() error:nil];
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT最终生产版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 && !g_hasSkipped) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
