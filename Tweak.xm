// ==========================================
// Tweak.xm - 通用广告跳过雷达 (增强诊断版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
        // 静默处理
    }
}

// ==========================================
// 🔬 增强诊断 + 多策略触发探针
// ==========================================
static void diagnoseAndTrigger(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *cls = NSStringFromClass([skipView class]);
            CGRect frame = [skipView convertRect:skipView.bounds toView:nil];
            CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
            
            writeDiagLog(@"====== 开始增强诊断 ======");
            writeDiagLog([NSString stringWithFormat:@"目标: %@ | 坐标: (%.0f,%.0f,%.0f,%.0f)", 
                          cls, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
            
            // 1. 向上查找携带手势的真实响应视图
            UIView *gestureHost = nil;
            UIGestureRecognizer *targetGesture = nil;
            UIView *searchView = skipView;
            int depth = 0;
            
            while (searchView && depth <= 10) {
                NSString *sCls = NSStringFromClass([searchView class]);
                writeDiagLog([NSString stringWithFormat:@"父级[%d]: %@ | userInteraction=%d | 手势数=%lu | isControl=%d", 
                              depth, sCls, searchView.userInteractionEnabled, 
                              (unsigned long)searchView.gestureRecognizers.count,
                              [searchView isKindOfClass:[UIControl class]]]);
                
                for (UIGestureRecognizer *g in searchView.gestureRecognizers) {
                    NSString *gCls = NSStringFromClass([g class]);
                    writeDiagLog([NSString stringWithFormat:@"  手势: %@ | enabled=%d | state=%ld | cancelsTouchesInView=%d", 
                                  gCls, g.isEnabled, (long)g.state, g.cancelsTouchesInView]);
                    
                    // 记录所有手势的方法列表（排查私有触发方法）
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([g class], &methodCount);
                    NSMutableArray *methodNames = [NSMutableArray array];
                    for (unsigned int i = 0; i < MIN(methodCount, 30); i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name containsString:@"touch"] || [name containsString:@"Touch"] || 
                            [name containsString:@"handle"] || [name containsString:@"Handle"] ||
                            [name containsString:@"recognize"] || [name containsString:@"fire"] ||
                            [name containsString:@"trigger"]) {
                            [methodNames addObject:name];
                        }
                    }
                    free(methods);
                    if (methodNames.count > 0) {
                        writeDiagLog([NSString stringWithFormat:@"  手势关键方法: %@", [methodNames componentsJoinedByString:@", "]]);
                    }
                    
                    if (!targetGesture && g.isEnabled) {
                        targetGesture = g;
                        gestureHost = searchView;
                    }
                }
                
                searchView = searchView.superview;
                depth++;
            }
            
            // 2. hitTest 验证
            UIWindow *keyWindow = skipView.window;
            if (!keyWindow) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        keyWindow = ((UIWindowScene *)scene).windows.firstObject;
                        if (keyWindow) break;
                    }
                }
            }
            
            UIView *hitView = nil;
            if (keyWindow) {
                hitView = [keyWindow hitTest:center withEvent:nil];
                NSString *hitCls = hitView ? NSStringFromClass([hitView class]) : @"nil";
                writeDiagLog([NSString stringWithFormat:@"hitTest(@%.0f,%.0f): %@", center.x, center.y, hitCls]);
            }
            
            // 3. ⭐ 依次尝试多种触发策略并记录结果
            writeDiagLog(@"--- 开始多策略触发测试 ---");
            
            // 策略A: 原始 state=Ended
            if (targetGesture) {
                @try {
                    [targetGesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                    writeDiagLog(@"策略A(state=Ended): 已执行");
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略A(state=Ended): 异常 %@", e]);
                }
            }
            
            // 策略B: 先 Began 再 Ended（模拟完整触摸序列）
            if (targetGesture) {
                @try {
                    [targetGesture setValue:@(UIGestureRecognizerStateBegan) forKey:@"state"];
                    usleep(50000); // 50ms延迟
                    [targetGesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                    writeDiagLog(@"策略B(Began->Ended): 已执行");
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略B(Began->Ended): 异常 %@", e]);
                }
            }
            
            // 策略C: touchesBegan + touchesEnded 注入到手势识别器
            if (targetGesture && keyWindow) {
                @try {
                    UITouch *fakeTouch = [[UITouch alloc] init];
                    // 注意：UITouch 初始化后 location 默认为 (0,0)，部分SDK会校验
                    NSSet *touches = [NSSet setWithObject:fakeTouch];
                    UIEvent *event = [[UIEvent alloc] init];
                    
                    SEL beganSel = @selector(touchesBegan:withEvent:);
                    SEL endedSel = @selector(touchesEnded:withEvent:);
                    
                    if ([targetGesture respondsToSelector:beganSel]) {
                        ((void(*)(id,SEL,id,id))objc_msgSend)(targetGesture, beganSel, touches, event);
                    }
                    if ([targetGesture respondsToSelector:endedSel]) {
                        ((void(*)(id,SEL,id,id))objc_msgSend)(targetGesture, endedSel, touches, event);
                    }
                    writeDiagLog(@"策略C(touches注入): 已执行");
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略C(touches注入): 异常 %@", e]);
                }
            }
            
            // 策略D: 对 gestureHost 发送 UIControl 事件（如果它是或继承自 UIControl）
            if (gestureHost && [gestureHost isKindOfClass:[UIControl class]]) {
                @try {
                    [(UIControl *)gestureHost sendActionsForControlEvents:UIControlEventTouchUpInside];
                    writeDiagLog(@"策略D(gestureHost UIControl): 已执行");
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略D: 异常 %@", e]);
                }
            }
            
            // 策略E: 对 hitView 执行 accessibilityActivate
            if (hitView && hitView != keyWindow) {
                @try {
                    BOOL result = [hitView accessibilityActivate];
                    writeDiagLog([NSString stringWithFormat:@"策略E(hitView accessibilityActivate): %d", result]);
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略E: 异常 %@", e]);
                }
            }
            
            // 策略F: 遍历 GDTSystemGestureRecognizer 的私有 target-action
            if (targetGesture) {
                @try {
                    // UIGestureRecognizer 内部有 _targets 数组存储 target-action
                    id targets = [targetGesture valueForKey:@"_targets"];
                    if ([targets isKindOfClass:[NSArray class]]) {
                        writeDiagLog([NSString stringWithFormat:@"策略F: 发现 %lu 个 target-action", (unsigned long)[(NSArray *)targets count]]);
                        for (id targetInfo in (NSArray *)targets) {
                            // _UIGestureRecognizerTargetInfo 结构
                            id target = [targetInfo valueForKey:@"_target"];
                            SEL action = NSSelectorFromString([targetInfo valueForKey:@"_action"]);
                            writeDiagLog([NSString stringWithFormat:@"  target: %@ | action: %@", 
                                          NSStringFromClass([target class]), NSStringFromSelector(action)]);
                            
                            if (target && action) {
                                #pragma clang diagnostic push
                                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                [target performSelector:action withObject:targetGesture];
                                #pragma clang diagnostic pop
                                writeDiagLog(@"策略F(直接调用target-action): 已执行");
                            }
                        }
                    } else {
                        writeDiagLog(@"策略F: _targets 不可访问");
                    }
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"策略F: 异常 %@", e]);
                }
            }
            
            writeDiagLog(@"--- 多策略触发测试结束 ---");
            writeDiagLog(@"====== 增强诊断结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 诊断异常: %@", e]);
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"🔬 已发现目标，正在诊断...\n文字: \"%@\"", textToCheck];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                // 执行增强诊断+多策略触发
                diagnoseAndTrigger(view);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"✅ 已尝试跳过！\n文字: \"%@\"\n请查看日志确认结果", textToCheck];
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
    writeDiagLog([NSString stringWithFormat:@"🚀 通用广告跳过雷达(增强诊断版)已启动: %@", bundleID]);

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
