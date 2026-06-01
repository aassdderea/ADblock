#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 持久化存储 Key (记忆库)
// ==========================================
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";
static NSString *const kLearnedParentKey   = @"UniversalSkipper_LearnedParent";

// ==========================================
// 辅助函数：计算控件的“跳过嫌疑”得分
// ==========================================
static NSInteger calculateSkipScore(UIView *view) {
    NSInteger score = 0;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return 0;
    
    CGRect screenBounds = window.bounds;
    CGRect frame = [view convertRect:view.bounds toView:window];
    
    // 1. 位置打分：通常在顶部 (y < 20%)，且偏左或偏右 (x < 20% 或 x > 80%)
    if (frame.origin.y < screenBounds.size.height * 0.25) {
        score += 20;
        if (frame.origin.x < screenBounds.size.width * 0.25 || 
            frame.origin.x > screenBounds.size.width * 0.75) {
            score += 30; // 边缘位置加分
        }
    }
    
    // 2. 尺寸打分：跳过按钮通常很小 (宽<150, 高<80)
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
            score += 100; // 包含明确文字，直接高分
        }
        // 匹配纯数字倒计时 (如 "3", "5s", "跳过 3s")
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
    
    // 尝试触发 UIControl 事件
    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[UniversalSkipper] ⚡️ 自动点击了 UIControl: %@", view);
    } 
    // 尝试触发 GestureRecognizer
    else if (view.gestureRecognizers.count > 0) {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                objc_msgSend(gesture, @selector(setState:), 3); // UIGestureRecognizerStateRecognized
                objc_msgSend(gesture, NSSelectorFromString(@"_recognize:"), [UIEvent new]);
                NSLog(@"[UniversalSkipper] ⚡️ 触发了手势识别器");
                break;
            }
        }
    }
    // 兜底：向上找能响应的父视图
    else {
        UIResponder *responder = view;
        while (responder) {
            responder = [responder nextResponder];
            if ([responder isKindOfClass:[UIControl class]]) {
                [(UIControl *)responder sendActionsForControlEvents:UIControlEventTouchUpInside];
                NSLog(@"[UniversalSkipper] ⚡️ 向上冒泡点击了: %@", responder);
                break;
            }
        }
    }
}

// ==========================================
// 扫描引擎 (定时器回调)
// ==========================================
static void scanAndProcess(BOOL isLearningMode) {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) return;
    
    NSString *savedClass = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedClassKey];
    NSString *savedText = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedTextKey];
    
    __block UIView *bestCandidate = nil;
    __block NSInteger highestScore = 0;
    
    // 递归遍历函数
    void (^traverse)(UIView *) = ^(UIView *view) {
        if (!view || view.isHidden || view.alpha < 0.1) return;
        
        // 【执行模式】：如果已经学习过，直接精确匹配
        if (!isLearningMode && savedClass) {
            NSString *currentClass = NSStringFromClass([view class]);
            if ([currentClass isEqualToString:savedClass]) {
                // 验证文本是否也匹配 (防止误伤同名类)
                NSString *currentText = @"";
                if ([view isKindOfClass:[UILabel class]]) currentText = ((UILabel *)view).text ?: @"";
                else if ([view isKindOfClass:[UIButton class]]) currentText = [(UIButton *)view currentTitle] ?: @"";
                
                if (savedText.length == 0 || [currentText containsString:savedText] || [savedText containsString:currentText]) {
                    performClick(view);
                    return;
                }
            }
        }
        
        // 【学习模式】：计算得分
        if (isLearningMode) {
            NSInteger score = calculateSkipScore(view);
            if (score > highestScore && score >= 60) { // 阈值设为60分
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
            UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topVC.presentedViewController) topVC = topVC.presentedViewController;
            
            if (topVC) {
                NSString *message = [NSString stringWithFormat:@"类名: %@\n文本: %@\n\n下次启动将自动点击它！", className, text.length > 0 ? text : @"(无文本)"];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 已识别到跳过按钮" message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:alert animated:YES completion:nil];
            }
        });
        
        NSLog(@"[UniversalSkipper] 🧠 学习完成！目标类: %@, 文本: %@", className, text);
    }
}

// ==========================================
// 插件入口与生命周期管理
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已注入，正在初始化自学习引擎...");
    
    // 延迟启动，等待 App UI 加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL isLearned = [[NSUserDefaults standardUserDefaults] boolForKey:kIsLearnedKey];
        
        // 启动高频扫描定时器 (每 0.2 秒扫描一次)
        // 前 5 秒为学习窗口期，之后停止学习模式的扫描以节省性能
        __block NSInteger scanCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull timer) {
            scanCount++;
            BOOL learningMode = !isLearned && (scanCount <= 25); // 25次 * 0.2s = 5秒
            
            if (!isLearned && scanCount > 25) {
                // 如果 5 秒内没学到，可能是没有广告，停止扫描
                [timer invalidate];
                return;
            }
            
            // 如果已经学会了，执行 3 次后也停止扫描
            if (isLearned && scanCount > 15) {
                [timer invalidate];
                return;
            }
            
            scanAndProcess(learningMode);
        }];
    });
}
