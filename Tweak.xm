// ==========================================
// Tweak.xm - 定点点击测试插件 (4秒后点击345,83并显示红圈)
// ==========================================
#import <UIKit/UIKit.h>

#define TESTLOG(fmt, ...) NSLog(@"[TAPTEST] " fmt, ##__VA_ARGS__)

static void showTapIndicatorAtPoint(CGPoint screenPoint) {
    CGFloat size = 40.0;
    UIWindow *indicatorWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenPoint.x - size/2, screenPoint.y - size/2, size, size)];
    indicatorWindow.windowLevel = UIWindowLevelAlert + 100;
    indicatorWindow.backgroundColor = [UIColor clearColor];
    indicatorWindow.userInteractionEnabled = NO;
    indicatorWindow.hidden = NO;
    
    UIView *indicator = [[UIView alloc] initWithFrame:indicatorWindow.bounds];
    indicator.layer.cornerRadius = size / 2;
    indicator.layer.borderWidth = 3.0;
    indicator.layer.borderColor = [UIColor redColor].CGColor;
    indicator.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
    [indicatorWindow addSubview:indicator];
    
    TESTLOG(@"✅ 红圈已显示于屏幕绝对坐标: (%.1f, %.1f)", screenPoint.x, screenPoint.y);
    
    [UIView animateWithDuration:0.3 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
        indicator.alpha = 0.0;
        indicator.transform = CGAffineTransformMakeScale(1.5, 1.5);
    } completion:^(BOOL finished) {
        indicatorWindow.hidden = YES;
    }];
}

static void performFixedTap() {
    CGPoint targetPoint = CGPointMake(345, 83);
    TESTLOG(@"🎯 准备点击固定坐标: (%.1f, %.1f)", targetPoint.x, targetPoint.y);
    
    // 1. 先显示红圈反馈
    showTapIndicatorAtPoint(targetPoint);
    
    // 2. 获取当前顶层窗口用于派发触摸事件
    UIWindow *targetWindow = nil;
    CGFloat maxLevel = -1;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    targetWindow = w;
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!targetWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                maxLevel = w.windowLevel;
                targetWindow = w;
            }
        }
    }
#pragma clang diagnostic pop
    
    if (!targetWindow) {
        TESTLOG(@"❌ 未找到可用窗口，无法派发触摸事件");
        return;
    }
    
    // 3. 将屏幕绝对坐标转换为目标窗口的局部坐标
    CGPoint windowPoint = [targetWindow convertPoint:targetPoint fromWindow:nil];
    UIView *hitView = [targetWindow hitTest:windowPoint withEvent:nil];
    if (!hitView) hitView = targetWindow;
    
    TESTLOG(@"✅ 命中视图: %@ | 窗口坐标: (%.1f, %.1f)", NSStringFromClass([hitView class]), windowPoint.x, windowPoint.y);
    
    // 4. 构造并发送完整触摸事件序列
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:hitView forKey:@"view"];
    [touch setValue:@(windowPoint) forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:@[touch] forKey:@"touches"];
    [event setValue:@(UIEventTypeTouches) forKey:@"type"];
    
    [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:event];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
        TESTLOG(@"✅ 触摸事件序列发送完成");
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    TESTLOG(@"🚀 App激活，开始4秒倒计时...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TESTLOG(@"⏱️ 4秒计时结束，执行定点点击");
        @try {
            performFixedTap();
        } @catch (NSException *e) {
            TESTLOG(@"💥 执行异常: %@", e);
        }
    });
}
%end
