#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 持久化存储 Key (记忆库)
// ==========================================
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";

// ==========================================
// 核心升级：获取屏幕上所有的 Window，并按层级从高到低排序
// ==========================================
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSArray<UIWindow *> *getAllWindowsSorted(void) {
    NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
    
    // iOS 13+ 多 Scene 架构
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                [allWindows addObjectsFromArray:scene.windows];
            }
        }
    }
    
    // 兜底方案 (兼容老版本或无 Scene 的情况)
    if (allWindows.count == 0) {
        [allWindows addObjectsFromArray:[UIApplication sharedApplication].windows];
    }
    
    // 按 windowLevel 降序排列（层级越高的越靠前，开屏广告通常在最上面）
    [allWindows sortUsingComparator:^NSComparisonResult(UIWindow *obj1, UIWindow *obj2) {
        return [@(obj2.windowLevel) compare:@(obj1.windowLevel)];
    }];
    
    return allWindows;
}
#pragma clang diagnostic pop

// ==========================================
// 辅助函数：计算控件的"跳过嫌疑"得分
// ==========================================
static NSInteger calculateSkipScore(UIView *view) {
    NSInteger score = 0;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    
    // 将视图的 frame 转换到屏幕坐标系
    CGRect frame = [view convertRect:view.bounds toView:nil];
    
    // 1. 位置打分：通常在顶部 (y < 30%)，且偏左或偏右
    if (frame.origin.y < screenBounds.size.height * 0.30 && frame.origin.y >= 0) {
        score += 20;
        if (frame.origin.x < screenBounds.size.width * 0.30 || 
            frame.origin.x > screenBounds.size.width * 0.60) {
            score += 30;
        }
    }
    
    // 2. 尺寸打分：跳过按钮通常很小
    if (frame.size.width > 10 && frame.size.width < 200 && 
        frame.size.height > 10 && frame.size.height < 100) {
        score += 20;
    }
    
    // 3. 文本打分 (核心权重)
    NSString *text = @"";
    if ([view isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)view).text ?: @"";
    } else if ([view isKindOfClass:[UIButton class]]) {
        text = [(UIButton *)view currentTitle] ?: @"";
    }
    
    if (text.length > 0) {
        NSString *lowerText = [text lowercaseString];
        if ([lowerText containsString:@"跳过"] || [lowerText containsString:@"skip"] || 
            [lowerText containsString:@"关闭"] || [lowerText containsString:@"close"] ||
            [lowerText containsString:@"跳过广告"]) {
            score += 150; // 文本匹配权重极高
        }
        // 匹配纯数字倒计时 (如 "3", "5s")
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d+" options:0 error:nil];
        if ([regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0) {
            score += 40;
        }
    }
    
    // 4. 类名打分
    NSString *className = NSStringFromClass([view class]);
    if ([className rangeOfString:@"Skip" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"Close" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"CountDown" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"GDT" options:NSCaseInsensitiveSearch].location != NSNotFound || // 广点通
        [className rangeOfString:@"CSJ" options:NSCaseInsensitiveSearch].location != NSNotFound) { // 穿山甲
        score += 50;
    }
    
    return score;
}

// ==========================================
// 核心执行函数：模拟点击
// ==========================================
static void performClick(UIView *view) {
    if (!view) return;
    
    // 方式1：UIControl 直接触发
    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[UniversalSkipper] ⚡️ 自动点击了 UIControl: %@", view);
        return;
    }
    
    // 方式2：触发手势识别器
    if (view.gestureRecognizers.count > 0) {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                typedef void (*MsgSendVoidSEL)(id, SEL, NSInteger);
                ((MsgSendVoidSEL)objc_msgSend)(gesture, @selector(setState:), 3);
                
                typedef void (*MsgSendVoidEvent)(id, SEL, UIEvent *);
                UIEvent *event = [UIEvent new];
                ((MsgSendVoidEvent)objc_msgSend)(gesture, NSSelectorFromString(@"_recognize:"), event);
                
                NSLog(@"[UniversalSkipper] ⚡️ 触发了手势识别器");
                return;
            }
        }
    }
    
    // 方式3：向上冒泡找能响应的父视图
    UIResponder *responder = view;
    while (responder) {
        responder = [responder nextResponder];
        if ([responder isKindOfClass:[UIControl class]]) {
            [(UIControl *)responder sendActionsForControlEvents:UIControlEventTouchUpInside];
            NSLog(@"[UniversalSkipper] ⚡️ 向上冒泡点击了: %@", responder);
            return;
        }
    }
    
    NSLog(@"[UniversalSkipper] ⚠️ 找到了目标但无法触发点击: %@", view);
}

// ==========================================
// 扫描引擎 (V4 全局扫描版)
// ==========================================
static void scanAndProcess(BOOL isLearningMode) {
    NSArray<UIWindow *> *allWindows = getAllWindowsSorted();
    if (allWindows.count == 0) {
        NSLog(@"[UniversalSkipper] ❌ 未找到任何 Window");
        return;
    }
    
    NSString *savedClass = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedClassKey];
    NSString *savedText = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedTextKey];
    
    __block UIView *bestCandidate = nil;
    __block NSInteger highestScore = 0;
    __block BOOL clicked = NO;
    
    // 递归遍历函数
    __weak void (^weakTraverse)(UIView *);
    void (^traverse)(UIView *) = ^(UIView *view) {
        if (!view || view.isHidden || view.alpha < 0.1 || clicked) return;
        
        // 【执行模式】：精确匹配已学习的目标
        if (!isLearningMode && savedClass) {
            NSString *currentClass = NSStringFromClass([view class]);
            if ([currentClass isEqualToString:savedClass]) {
                NSString *currentText = @"";
                if ([view isKindOfClass:[UILabel class]]) currentText = ((UILabel *)view).text ?: @"";
                else if ([view isKindOfClass:[UIButton class]]) currentText = [(UIButton *)view currentTitle] ?: @"";
                
                if (savedText.length == 0 || [currentText containsString:savedText] || [savedText containsString:currentText]) {
                    performClick(view);
                    clicked = YES;
                    return;
                }
            }
        }
        
        // 【学习模式】：计算得分
        if (isLearningMode) {
            NSInteger score = calculateSkipScore(view);
            if (score > highestScore && score >= 80) { // 稍微提高一点阈值，防止误触
                highestScore = score;
                bestCandidate = view;
            }
        }
        
        if (weakTraverse) {
            for (UIView *subview in view.subviews) {
                weakTraverse(subview);
            }
        }
    };
    weakTraverse = traverse;
    
    // 遍历所有 Window
    for (UIWindow *window in allWindows) {
        if (clicked) break;
        traverse(window);
    }
    
    // 学习模式下，找到了最佳候选者
    if (isLearningMode && bestCandidate) {
        NSString *className = NSStringFromClass([bestCandidate class]);
        NSString *text = @"";
        if ([bestCandidate isKindOfClass:[UILabel class]]) text = ((UILabel *)bestCandidate).text ?: @"";
        else if ([bestCandidate isKindOfClass:[UIButton class]]) text = [(UIButton *)bestCandidate currentTitle] ?: @"";
        
        // 保存记忆
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:kIsLearnedKey];
        [defaults setObject:className forKey:kLearnedClassKey];
        [defaults setObject:text forKey:kLearnedTextKey];
        [defaults synchronize];
        
        NSLog(@"[UniversalSkipper] ✅ 学习完成！目标类: %@, 文本: %@, 得分: %ld", className, text, (long)highestScore);
        
        // 弹窗通知用户
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *topVC = nil;
            for (UIWindow *w in allWindows) {
                UIViewController *vc = w.rootViewController;
                while (vc.presentedViewController) vc = vc.presentedViewController;
                if (vc) { topVC = vc; break; }
            }
            
            if (topVC) {
                NSString *message = [NSString stringWithFormat:@"类名: %@\n文本: %@\n得分: %ld\n\n下次启动将自动点击它！", 
                    className, text.length > 0 ? text : @"(无文本)", (long)highestScore];
                UIAlertController *alert = [UIAlertController 
                    alertControllerWithTitle:@"🎯 已识别到跳过按钮" 
                    message:message 
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:alert animated:YES completion:nil];
            }
        });
    }
}

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已注入，正在初始化自学习引擎...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL isLearned = [[NSUserDefaults standardUserDefaults] boolForKey:kIsLearnedKey];
        NSLog(@"[UniversalSkipper] 📖 当前记忆状态: %@", isLearned ? @"已学习(执行模式)" : @"未学习(学习模式)");
        
        __block NSInteger scanCount = 0;
        // 延长扫描时间：每 0.5 秒扫一次，最多扫 20 次（共 10 秒）
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            scanCount++;
            BOOL learningMode = !isLearned; 
            
            NSLog(@"[UniversalSkipper] 🔍 第 %ld 次扫描 (模式: %@)", (long)scanCount, learningMode ? @"学习" : @"执行");
            
            // 执行模式下，如果点击成功或者扫描次数过多，停止定时器
            if (isLearned && scanCount > 10) {
                [timer invalidate];
                return;
            }
            
            // 学习模式下，扫描 10 秒后停止，并弹窗汇报结果
            if (!isLearned && scanCount > 20) {
                [timer invalidate];
                
                // 如果 10 秒都没找到，弹窗提示
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSArray<UIWindow *> *allWindows = getAllWindowsSorted();
                    UIViewController *topVC = nil;
                    for (UIWindow *w in allWindows) {
                        UIViewController *vc = w.rootViewController;
                        while (vc.presentedViewController) vc = vc.presentedViewController;
                        if (vc) { topVC = vc; break; }
                    }
                    
                    if (topVC) {
                        UIAlertController *alert = [UIAlertController 
                            alertControllerWithTitle:@"⚠️ 未识别到跳过按钮" 
                            message:@"在 10 秒内没有找到得分 >= 80 的控件。请检查广告是否出现，或尝试摇一摇手机重置。" 
                            preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }
                });
                return;
            }
            
            scanAndProcess(learningMode);
        }];
    });
}

// ==========================================
// 隐藏功能：摇一摇手机，清除记忆，重新学习
// ==========================================
%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSLog(@"[UniversalSkipper] 📱 检测到摇一摇，正在清除记忆...");
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kIsLearnedKey];
        [defaults removeObjectForKey:kLearnedClassKey];
        [defaults removeObjectForKey:kLearnedTextKey];
        [defaults synchronize];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *topVC = self.rootViewController;
            while (topVC.presentedViewController) topVC = topVC.presentedViewController;
            
            if (topVC) {
                UIAlertController *alert = [UIAlertController 
                    alertControllerWithTitle:@"🧹 记忆已清除" 
                    message:@"插件已重置！将在下次出现广告时重新学习。" 
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:alert animated:YES completion:nil];
            }
        });
    }
    %orig;
}
%end
