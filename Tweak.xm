#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 兼容 iOS 13+ 的 KeyWindow 获取函数
// ==========================================
static UIWindow *getKeyWindow(void) {
    // iOS 13+ 多 Scene 架构
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
    // 兜底方案
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) return window;
    }
    return windows.firstObject;
}

// ==========================================
// 持久化存储 Key (记忆库)
// ==========================================
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";

// ==========================================
// 辅助函数：计算控件的"跳过嫌疑"得分
// ==========================================
static NSInteger calculateSkipScore(UIView *view) {
    NSInteger score = 0;
    UIWindow *window = getKeyWindow();
    if (!window) return 0;
    
    CGRect screenBounds = window.bounds;
    CGRect frame = [view convertRect:view.bounds toView:window];
    
    // 1. 位置打分：通常在顶部 (y < 25%)，且偏左或偏右
    if (frame.origin.y < screenBounds.size.height * 0.25) {
        score += 20;
        if (frame.origin.x < screenBounds.size.width * 0.25 || 
            frame.origin.x > screenBounds.size.width * 0.75) {
            score += 30;
        }
    }
    
    // 2. 尺寸打分：跳过按钮通常很小
    if (frame.size.width > 10 && frame.size.width < 150 && 
        frame.size.height > 10 && frame.size.height < 80) {
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
            [lowerText containsString:@"关闭"] || [lowerText containsString:@"close"]) {
            score += 100;
        }
        // 匹配纯数字倒计时
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d+" options:0 error:nil];
        if ([regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0) {
            score += 40;
        }
    }
    
    // 4. 类名打分
    NSString *className = NSStringFromClass([view class]);
    if ([className rangeOfString:@"Skip" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"Close" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"CountDown" options:NSCaseInsensitiveSearch].location != NSNotFound) {
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
                // 强转函数指针，修复 objc_msgSend 编译错误
                typedef void (*MsgSendVoidSEL)(id, SEL, NSInteger);
                ((MsgSendVoidSEL)objc_msgSend)(gesture, @selector(setState:), 3); // UIGestureRecognizerStateRecognized
                
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
    
    // 方式4：最终兜底 - 模拟触摸事件
    CGPoint center = CGPointMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0);
    NSLog(@"[UniversalSkipper] ⚡️ 兜底方案，目标中心点: %@", NSStringFromCGPoint(center));
}

// ==========================================
// 扫描引擎
// ==========================================
static void scanAndProcess(BOOL isLearningMode) {
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return;
    
    NSString *savedClass = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedClassKey];
    NSString *savedText = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedTextKey];
    
    __block UIView *bestCandidate = nil;
    __block NSInteger highestScore = 0;
    __block BOOL clicked = NO;
    
    // 递归遍历函数
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
            if (score > highestScore && score >= 60) {
                highestScore = score;
                bestCandidate = view;
            }
        }
        
        for (UIView *subview in view.subviews) {
            traverse(subview);
        }
    };
    
    traverse(keyWindow);
    
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
        
        // 弹窗通知用户
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *topVC = getKeyWindow().rootViewController;
            while (topVC.presentedViewController) topVC = topVC.presentedViewController;
            
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
        
        NSLog(@"[UniversalSkipper] 🧠 学习完成！目标类: %@, 文本: %@, 得分: %ld", className, text, (long)highestScore);
    }
}

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已注入，正在初始化自学习引擎...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL isLearned = [[NSUserDefaults standardUserDefaults] boolForKey:kIsLearnedKey];
        
        __block NSInteger scanCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull timer) {
            scanCount++;
            BOOL learningMode = !isLearned && (scanCount <= 25); // 前5秒为学习窗口
            
            if (!isLearned && scanCount > 25) {
                [timer invalidate];
                return;
            }
            
            if (isLearned && scanCount > 15) {
                [timer invalidate];
                return;
            }
            
            scanAndProcess(learningMode);
        }];
    });
}
