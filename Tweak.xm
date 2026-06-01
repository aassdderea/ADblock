#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 持久化存储 Key (独立 Domain，防误删)
// ==========================================
static NSString *const kPluginDomain       = @"com.universalskipper.welove520";
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedXKey        = @"UniversalSkipper_X"; // 记忆 X 坐标
static NSString *const kLearnedYKey        = @"UniversalSkipper_Y"; // 记忆 Y 坐标
static NSString *const kScreenWidthKey     = @"UniversalSkipper_SW"; // 记忆屏幕宽
static NSString *const kScreenHeightKey    = @"UniversalSkipper_SH"; // 记忆屏幕高

static BOOL isCapturing = NO;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSArray<UIWindow *> *getAllWindowsSorted(void) {
    NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                [allWindows addObjectsFromArray:scene.windows];
            }
        }
    }
    if (allWindows.count == 0) [allWindows addObjectsFromArray:[UIApplication sharedApplication].windows];
    [allWindows sortUsingComparator:^NSComparisonResult(UIWindow *obj1, UIWindow *obj2) {
        return [@(obj2.windowLevel) compare:@(obj1.windowLevel)];
    }];
    return allWindows;
}
#pragma clang diagnostic pop

// ==========================================
// 核心升级 1：视觉反馈 (画红圈)
// ==========================================
static void showRedCircleAtPoint(CGPoint point) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(point.x - 25, point.y - 25, 50, 50)];
        circle.layer.cornerRadius = 25;
        circle.layer.borderWidth = 4;
        circle.layer.borderColor = [UIColor redColor].CGColor;
        circle.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
        circle.userInteractionEnabled = NO;
        
        // 添加到最顶层的 Window
        NSArray *windows = getAllWindowsSorted();
        if (windows.count > 0) {
            [windows.firstObject addSubview:circle];
        }
        
        // 1.5秒后淡出消失
        [UIView animateWithDuration:0.5 delay:1.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            circle.alpha = 0;
        } completion:^(BOOL finished) {
            [circle removeFromSuperview];
        }];
    });
}

// ==========================================
// 核心升级 2：物理级坐标模拟点击 (无视任何控件类型)
// ==========================================
static void simulatePhysicalClick(CGPoint point, UIWindow *window) {
    // 构造 UITouch 和 UIEvent
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"location"];
    [touch setValue:window forKey:@"window"];
    
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    
    // 发送按下事件
    [window sendEvent:event];
    
    // 0.05秒后发送抬起事件
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [window sendEvent:event];
        NSLog(@"[UniversalSkipper] ⚡️ 模拟物理点击坐标: (%.1f, %.1f)", point.x, point.y);
    });
}

// ==========================================
// 执行模式：根据记忆的坐标自动点击
// ==========================================
static void autoSkipAd(void) {
    NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
    BOOL isLearned = [pluginDefaults boolForKey:kIsLearnedKey];
    if (!isLearned) return;
    
    CGFloat savedX = [pluginDefaults floatForKey:kLearnedXKey];
    CGFloat savedY = [pluginDefaults floatForKey:kLearnedYKey];
    CGFloat savedSW = [pluginDefaults floatForKey:kScreenWidthKey];
    CGFloat savedSH = [pluginDefaults floatForKey:kScreenHeightKey];
    
    if (savedSW <= 0 || savedSH <= 0) return;
    
    // 计算比例，适配不同分辨率的屏幕 (防止你换设备或者横竖屏)
    CGFloat currentSW = [UIScreen mainScreen].bounds.size.width;
    CGFloat currentSH = [UIScreen mainScreen].bounds.size.height;
    
    CGFloat targetX = (savedX / savedSW) * currentSW;
    CGFloat targetY = (savedY / savedSH) * currentSH;
    
    CGPoint targetPoint = CGPointMake(targetX, targetY);
    
    // 获取最顶层的 Window 进行点击
    NSArray *windows = getAllWindowsSorted();
    if (windows.count > 0) {
        simulatePhysicalClick(targetPoint, windows.firstObject);
    }
}

%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已加载！");
    
    NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
    BOOL isLearned = [pluginDefaults boolForKey:kIsLearnedKey];
    
    if (isLearned) {
        NSLog(@"[UniversalSkipper] 🧠 坐标记忆已存在，进入自动点击模式");
        // 延迟 1 秒后开始高频点击，持续 5 秒
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSInteger count = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *timer) {
                count++;
                autoSkipAd();
                if (count >= 16) [timer invalidate]; // 约 5 秒后停止
            }];
        });
    } else {
        NSLog(@"[UniversalSkipper] 🎯 首次运行，等待用户手动点击...");
        isCapturing = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isCapturing = NO;
        });
    }
}

// ==========================================
// 核心 Hook：拦截全局触摸，记录坐标并画红圈
// ==========================================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (!isCapturing || event.type != UIEventTypeTouches) return;
    
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseEnded) {
            // 获取屏幕绝对坐标
            CGPoint point = [touch locationInView:nil]; 
            
            // 【视觉反馈】立刻在点击位置画红圈
            showRedCircleAtPoint(point);
            
            // 获取屏幕宽高
            CGFloat sw = [UIScreen mainScreen].bounds.size.width;
            CGFloat sh = [UIScreen mainScreen].bounds.size.height;
            
            // 过滤掉明显的边缘误触 (如底部 Home 条区域，顶部状态栏)
            if (point.y < 40 || point.y > sh - 30) continue;
            
            NSLog(@"[UniversalSkipper] 🕵️ 捕获到点击坐标: (%.1f, %.1f)", point.x, point.y);
            
            // 保存坐标记忆
            NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
            [pluginDefaults setBool:YES forKey:kIsLearnedKey];
            [pluginDefaults setFloat:point.x forKey:kLearnedXKey];
            [pluginDefaults setFloat:point.y forKey:kLearnedYKey];
            [pluginDefaults setFloat:sw forKey:kScreenWidthKey];
            [pluginDefaults setFloat:sh forKey:kScreenHeightKey];
            [pluginDefaults synchronize];
            
            isCapturing = NO; // 停止捕获
            
            // 弹窗通知
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *topVC = nil;
                for (UIWindow *w in getAllWindowsSorted()) {
                    UIViewController *vc = w.rootViewController;
                    while (vc.presentedViewController) vc = vc.presentedViewController;
                    if (vc) { topVC = vc; break; }
                }
                if (topVC) {
                    NSString *msg = [NSString stringWithFormat:@"已锁定点击坐标:\nX: %.1f, Y: %.1f\n\n下次启动将自动模拟点击此位置！", point.x, point.y];
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 坐标捕获成功" message:msg preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                    [topVC presentViewController:alert animated:YES completion:nil];
                }
            });
            break;
        }
    }
}
%end

// ==========================================
// 隐藏功能：摇一摇清除记忆
// ==========================================
%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
        [pluginDefaults removeObjectForKey:kIsLearnedKey];
        [pluginDefaults removeObjectForKey:kLearnedXKey];
        [pluginDefaults removeObjectForKey:kLearnedYKey];
        [pluginDefaults removeObjectForKey:kScreenWidthKey];
        [pluginDefaults removeObjectForKey:kScreenHeightKey];
        [pluginDefaults synchronize];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🧹 记忆已清除" message:@"请重启App并手动点击一次跳过按钮重新学习。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = self.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc) [vc presentViewController:alert animated:YES completion:nil];
    }
    %orig;
}
%end
