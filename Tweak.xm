// ==========================================
// Tweak.xm - 通用广告跳过雷达 (Documents日志版)
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
// 📁 动态获取 Documents 日志路径
// ==========================================
static NSString *getDiagLogPath() {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        path = [docDir stringByAppendingPathComponent:@"adblock_diag.log"];
    });
    return path;
}

// ==========================================
// 📝 文件日志写入工具
// ==========================================
static void writeDiagLog(NSString *message) {
    if (!message) return;
    @try {
        NSString *logPath = getDiagLogPath();
        NSString *timestamp = [[NSDate date] description];
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {
        // 静默处理，避免影响主流程
    }
}

// ==========================================
// 🔬 深度交互诊断探针（仅分析，不点击）
// ==========================================
static void diagnoseSkipButton(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *cls = NSStringFromClass([skipView class]);
            CGRect frame = [skipView convertRect:skipView.bounds toView:nil];
            
            writeDiagLog(@"====== 开始诊断 ======");
            writeDiagLog([NSString stringWithFormat:@"类名: %@", cls]);
            writeDiagLog([NSString stringWithFormat:@"坐标: (%.0f, %.0f, %.0f, %.0f)", 
                          frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
            writeDiagLog([NSString stringWithFormat:@"userInteractionEnabled: %d", skipView.userInteractionEnabled]);
            writeDiagLog([NSString stringWithFormat:@"hidden: %d | alpha: %.2f", skipView.isHidden, skipView.alpha]);
            writeDiagLog([NSString stringWithFormat:@"isAccessibilityElement: %d", skipView.isAccessibilityElement]);
            writeDiagLog([NSString stringWithFormat:@"accessibilityTraits: %lu", (unsigned long)skipView.accessibilityTraits]);
            writeDiagLog([NSString stringWithFormat:@"accessibilityLabel: %@", skipView.accessibilityLabel]);
            writeDiagLog([NSString stringWithFormat:@"自身手势数量: %lu", (unsigned long)skipView.gestureRecognizers.count]);
            
            for (NSInteger i = 0; i < skipView.gestureRecognizers.count; i++) {
                UIGestureRecognizer *g = skipView.gestureRecognizers[i];
                writeDiagLog([NSString stringWithFormat:@"  手势[%ld]: %@ enabled=%d state=%ld", 
                              (long)i, NSStringFromClass([g class]), g.isEnabled, (long)g.state]);
            }
            
            UIView *parent = skipView.superview;
            int depth = 1;
            while (parent && depth <= 5) {
                NSString *pCls = NSStringFromClass([parent class]);
                writeDiagLog([NSString stringWithFormat:@"父级[%d]: %@ | userInteraction=%d | 手势数=%lu | isControl=%d", 
                              depth, pCls, parent.userInteractionEnabled, 
                              (unsigned long)parent.gestureRecognizers.count,
                              [parent isKindOfClass:[UIControl class]]]);
                
                for (NSInteger i = 0; i < parent.gestureRecognizers.count; i++) {
                    UIGestureRecognizer *g = parent.gestureRecognizers[i];
                    writeDiagLog([NSString stringWithFormat:@"  父级[%d]手势[%ld]: %@ enabled=%d", 
                                  depth, (long)i, NSStringFromClass([g class]), g.isEnabled]);
                }
                parent = parent.superview;
                depth++;
            }
            
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
                CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
                UIView *hitView = [keyWindow hitTest:center withEvent:nil];
                NSString *hitCls = hitView ? NSStringFromClass([hitView class]) : @"nil";
                BOOL isSelfOrChild = [skipView isDescendantOfView:hitView] || [hitView isDescendantOfView:skipView] || hitView == skipView;
                
                writeDiagLog([NSString stringWithFormat:@"hitTest 结果: %@ | 与目标关联: %d", hitCls, isSelfOrChild]);
                
                if (hitView && hitView != skipView && !isSelfOrChild) {
                    writeDiagLog(@"⚠️ hitTest 命中了完全不同的视图！这可能是跳过失败的根本原因");
                    writeDiagLog([NSString stringWithFormat:@"hitView userInteraction=%d | 手势数=%lu | isControl=%d", 
                                  hitView.userInteractionEnabled, 
                                  (unsigned long)hitView.gestureRecognizers.count,
                                  [hitView isKindOfClass:[UIControl class]]]);
                }
            } else {
                writeDiagLog(@"⚠️ 无法获取 keyWindow，hitTest 跳过");
            }
            
            writeDiagLog(@"====== 诊断结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 诊断异常: %@", e]);
        }
    });
}

// ==========================================
// 🎯 四层强制触发引擎
// ==========================================
static void forceTriggerSkip(UIView *skipView) {
    if (!skipView || ![skipView isKindOfClass:[UIView class]]) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *className = NSStringFromClass([skipView class]);
            writeDiagLog([NSString stringWithFormat:@"🚀 开始强制跳过: %@", className]);
            
            // 1. UIControl 事件模拟
            if ([skipView isKindOfClass:[UIControl class]]) {
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchUpInside];
                writeDiagLog(@"✅ 触发自身 UIControl");
                return;
            }
            
            // 2. 无障碍激活
            if ([skipView respondsToSelector:@selector(accessibilityActivate)]) {
                BOOL result = [skipView accessibilityActivate];
                writeDiagLog([NSString stringWithFormat:@"✅ accessibilityActivate 结果: %d", result]);
                if (result) return;
            }
            
            // 3. 向上遍历父视图寻找手势/UIControl
            UIView *targetView = skipView;
            int maxDepth = 5;
            while (targetView && maxDepth-- > 0) {
                for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                    if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                        [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        writeDiagLog([NSString stringWithFormat:@"✅ 成功触发手势: %@ on %@", 
                                      NSStringFromClass([gesture class]), 
                                      NSStringFromClass([targetView class])]);
                        return;
                    }
                }
                
                if ([targetView isKindOfClass:[UIControl class]] && targetView != skipView) {
                    [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    writeDiagLog([NSString stringWithFormat:@"✅ 成功触发父级 UIControl: %@", 
                                  NSStringFromClass([targetView class])]);
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
                if (realHitView && realHitView != keyWindow && realHitView != skipView) {
                    writeDiagLog([NSString stringWithFormat:@"🎯 hitTest 命中真实视图: %@", 
                                  NSStringFromClass([realHitView class])]);
                    
                    if ([realHitView isKindOfClass:[UIControl class]]) {
                        [(UIControl *)realHitView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    } else {
                        for (UIGestureRecognizer *g in realHitView.gestureRecognizers) {
                            if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                                writeDiagLog([NSString stringWithFormat:@"✅ hitTest 触发了手势: %@", NSStringFromClass([g class])]);
                                break;
                            }
                        }
                    }
                    return;
                }
            }
            
            writeDiagLog([NSString stringWithFormat:@"⚠️ 所有触发方式均未成功: %@", className]);
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 跳过异常: %@", e]);
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
// 深度雷达扫描（发现 -> 诊断 -> 触发）
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
                // 先执行诊断并写入文件
                diagnoseSkipButton(view);
                
                CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
                NSString *msg = [NSString stringWithFormat:@"🔬 已发现目标，正在诊断...\n文字: \"%@\"\n类名: %@\n坐标: (%.0f, %.0f)", 
                                 textToCheck, NSStringFromClass([view class]), 
                                 frameInWindow.origin.x, frameInWindow.origin.y];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = msg;
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                // 延迟0.1秒确保诊断日志先写入，再执行点击
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    forceTriggerSkip(view);
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (g_statusLabel) {
                            g_statusLabel.text = [NSString stringWithFormat:@"✅ 已尝试跳过！\n文字: \"%@\"", textToCheck];
                            g_statusLabel.textColor = [UIColor greenColor];
                        }
                    });
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
// 监听前台恢复，重置扫描状态
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
    writeDiagLog(@"🔄 扫描状态已重置");
}
%end

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    // 每次启动清空旧日志
    [[NSFileManager defaultManager] removeItemAtPath:getDiagLogPath() error:nil];
    writeDiagLog([NSString stringWithFormat:@"🚀 通用广告跳过雷达(Documents日志版)已启动: %@", bundleID]);

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
