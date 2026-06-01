#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 兼容 iOS 13+ 的 KeyWindow 获取函数
// ==========================================
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static UIWindow *getKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) return window;
                }
            }
        }
    }
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) return window;
    }
    return windows.firstObject;
}
#pragma clang diagnostic pop

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
    
    if (frame.origin.y < screenBounds.size.height * 0.25) {
        score += 20;
        if (frame.origin.x < screenBounds.size.width * 0.25 || 
            frame.origin.x > screenBounds.size.width * 0.75) {
            score += 30;
        }
    }
    
    if (frame.size.width > 10 && frame.size.width < 150 && 
        frame.size.height > 10 && frame.size.height < 80) {
        score += 20;
    }
    
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
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d+" options:0 error:nil];
        if ([regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0) {
            score += 40;
        }
    }
    
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
    
    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[UniversalSkipper] ⚡️ 自动点击了 UIControl: %@", view);
        return;
    }
    
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
    
    UIResponder *responder = view;
    while (responder) {
        responder = [responder nextResponder];
        if ([responder isKindOfClass:[UIControl class]]) {
            [(UIControl *)responder sendActionsForControlEvents:UIControlEventTouchUpInside];
            NSLog(@"[UniversalSkipper] ⚡️ 向上冒泡点击了: %@", responder);
            return;
        }
    }
    
    NSLog(@"[UniversalSkipper] ⚡️ 兜底方案，未找到可点击目标: %@", view);
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
    
    // 【终极修复】：ARC 下的安全递归 Block 写法
    // 1. 声明一个弱引用指针
    __weak void (^weakTraverse)(UIView *);
    
    // 2. 实现强引用 Block
    void (^traverse)(UIView *) = ^(UIView *view) {
        if (!view || view.isHidden || view.alpha < 0.1 || clicked) return;
        
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
        
        if (isLearningMode) {
            NSInteger score = calculateSkipScore(view);
            if (score > highestScore && score >= 60) {
                highestScore = score;
                bestCandidate = view;
            }
        }
        
        // 3. 在内部调用弱引用，彻底打破循环引用 (Retain Cycle)
        if (weakTraverse) {
            for (UIView *subview in view.subviews) {
                weakTraverse(subview);
            }
        }
    };
    
    // 4. 将强引用赋值给弱引用
    weakTraverse = traverse;
    
    // 5. 开始执行
    traverse(keyWindow);
    
    if (isLearningMode && bestCandidate) {
        NSString *className = NSStringFromClass([bestCandidate class]);
        NSString *text = @"";
        if ([bestCandidate isKindOfClass:[UILabel class]]) text = ((UILabel *)bestCandidate).text ?: @"";
        else if ([bestCandidate isKindOfClass:[UIButton class]]) text = [(UIButton *)bestCandidate currentTitle] ?: @"";
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:kIsLearnedKey];
        [defaults setObject:className forKey:kLearnedClassKey];
        [defaults setObject:text forKey:kLearnedTextKey];
        [defaults synchronize];
        
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
            BOOL learningMode = !isLearned && (scanCount <= 25);
            
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
