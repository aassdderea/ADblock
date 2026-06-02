#import <UIKit/UIKit.h>

// ==========================================
// 全局变量
// ==========================================
static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;

// ==========================================
// 第一步：确保 UI 在任何页面（包括广告页）绝对置顶
// ==========================================
static void ensureOverlayOnTop() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 找到当前屏幕上层级最高的 Window (广告通常会弹出一个新的 Window)
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

        // 2. 如果我们的提示框还没创建，或者不在最顶层的 Window 上，就重新挂载
        if (!g_overlayView || g_overlayView.window != topWindow) {
            if (g_overlayView) [g_overlayView removeFromSuperview];
            
            g_overlayView = [[UIView alloc] initWithFrame:topWindow.bounds];
            g_overlayView.backgroundColor = [UIColor clearColor];
            g_overlayView.userInteractionEnabled = NO; // 绝对不拦截任何触摸
            g_overlayView.layer.zPosition = 999999;   // 强制置顶
            
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, topWindow.bounds.size.height - 150, topWindow.bounds.size.width - 40, 80)];
            g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
            g_statusLabel.textColor = [UIColor yellowColor]; // 用黄色，醒目
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
// 第二步：深度雷达扫描（只发现，不点击）
// ==========================================
static BOOL scanAndDetect(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1) return NO;
    if (view == g_overlayView) return NO; // 排除自己

    NSString *textToCheck = nil;

    if ([view isKindOfClass:[UILabel class]]) {
        textToCheck = ((UILabel *)view).text;
    } 
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) {
        textToCheck = view.accessibilityLabel;
    }

    if (textToCheck.length > 0 && textToCheck.length < 20) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
                NSString *msg = [NSString stringWithFormat:@"🎯 发现目标！\n文字: \"%@\"\n类名: %@\n坐标: (%.0f, %.0f)\n【当前仅扫描，未执行点击】", 
                                 textToCheck, NSStringFromClass([view class]), frameInWindow.origin.x, frameInWindow.origin.y];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = msg;
                        g_statusLabel.textColor = [UIColor greenColor]; // 找到后变绿
                    }
                });
                return YES; // 找到就返回
            }
        }
    }

    // 递归扫描子视图
    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndDetect(view.subviews[i])) return YES;
    }
    
    return NO;
}

// ==========================================
// 定时器核心逻辑
// ==========================================
static void radarTick() {
    g_scanCount++;
    if (g_scanCount > 100) { // 扫描 100 次（约 10 秒）后停止，节省性能
        return; 
    }

    ensureOverlayOnTop(); // 确保 UI 置顶

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window; // 直接扫描我们挂载的那个 Window
        if (scanWindow) {
            BOOL found = scanAndDetect(scanWindow);
            if (!found && g_statusLabel) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 雷达扫描中... (%d/100)\n暂未发现跳过按钮", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    // 过滤掉系统核心应用
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    NSLog(@"[AdBlocker] 🚀 第一阶段：安全扫描雷达已启动: %@", bundleID);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    // 使用 NSTimer 每 0.1 秒扫描一次
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100) {
                [timer invalidate];
                return;
            }
            radarTick();
        }];
    });
}
