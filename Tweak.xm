// ==========================================
// Tweak.xm - 通用广告跳过雷达 (GDT修复版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ==========================================
// 全局变量
// ==========================================
static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasSkipped = NO;

// ==========================================
// 🎯 四层强制触发引擎（已修复GDT私有手势）
// ==========================================
static void forceTriggerSkip(UIView *skipView) {
    if (!skipView || ![skipView isKindOfClass:[UIView class]]) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1. UIControl 事件模拟
            if ([skipView isKindOfClass:[UIControl class]]) {
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
            
            // 2. 无障碍激活
            if ([skipView respondsToSelector:@selector(accessibilityActivate)]) {
                if ([skipView accessibilityActivate]) return;
            }
            
            // 3. ⭐ 核心修复：向上遍历，触发任意手势（不再限制UITapGestureRecognizer）
            UIView *targetView = skipView;
            int maxDepth = 8; // GDT层级较深，扩大到8层
            while (targetView && maxDepth-- > 0) {
                // 优先尝试触发父视图上的所有手势
                for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                    if (gesture.isEnabled) {
                        [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        return;
                    }
                }
                
                // 兜底：如果父视图是UIControl
                if ([targetView isKindOfClass:[UIControl class]] && targetView != skipView) {
                    [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    return;
                }
                
                targetView = targetView.superview;
            }
            
            // 4. hitTest 坐标硬探（终极兜底）
            CGRect rectInWindow = [skipView convertRect:skipView.bounds toView:nil];
            CGPoint centerPoint = CGPointMake(CGRectGetMidX(rectInWindow), CGRectGetMidY(rectInWindow));
            
            UIWindow *keyWindow = skipView.window;
            if (!keyWindow) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        keyWindow = ((UIWindowScene *)scene).windows.firstObject;
                        if (keyWindow) break;
                    }
                }
            }
            
            if (keyWindow) {
                UIView *realHitView = [keyWindow hitTest:centerPoint withEvent:nil];
                if (realHitView && realHitView != keyWindow) {
                    if ([realHitView isKindOfClass:[UIControl class]]) {
                        [(UIControl *)realHitView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    } else {
                        for (UIGestureRecognizer *g in realHitView.gestureRecognizers) {
                            if (g.isEnabled) {
                                [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                                break;
                            }
                        }
                    }
                }
            }
            
        } @catch (NSException *e) {
            // 静默处理
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
            if (g_overlayView) [g_overlayView removeFromSuperview];
            
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
    if (!view || view.isHidden || view.alpha < 0.1) return NO;
    if (view == g_overlayView) return NO;

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
                NSString *msg = [NSString stringWithFormat:@"✅ 已跳过！\n文字: \"%@\"\n类名: %@", 
                                 textToCheck, NSStringFromClass([view class])];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = msg;
                        g_statusLabel.textColor = [UIColor greenColor];
                    }
                });
                
                forceTriggerSkip(view);
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
// 定时器核心逻辑
// ==========================================
static void radarTick() {
    if (g_hasSkipped) return;
    
    g_scanCount++;
    if (g_scanCount > 100) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = @"⏱️ 扫描超时\n未发现可跳过的广告";
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
            if (found) {
                g_hasSkipped = YES;
            } else if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 雷达扫描中... (%d/100)\n暂未发现跳过按钮", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

// ==========================================
// 监听前台恢复
// ==========================================
%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    g_scanCount = 0;
    g_hasSkipped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_statusLabel) {
            g_statusLabel.text = @"🔍 雷达已重启...\n正在扫描广告按钮";
            g_statusLabel.textColor = [UIColor yellowColor];
        }
    });
}
%end

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 && !g_hasSkipped) {
                [timer invalidate];
                return;
            }
            radarTick();
        }];
    });
}
