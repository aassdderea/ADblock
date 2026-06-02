// ==========================================
// Tweak.xm - GDT开屏广告跳过 (带红圈点击反馈版)
// ==========================================
#import <UIKit/UIKit.h>

static void showTapIndicatorAtPoint(CGPoint point, UIWindow *window) {
    CGFloat size = 40.0;
    UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(point.x - size/2, point.y - size/2, size, size)];
    indicator.layer.cornerRadius = size / 2;
    indicator.layer.borderWidth = 3.0;
    indicator.layer.borderColor = [UIColor redColor].CGColor;
    indicator.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
    indicator.userInteractionEnabled = NO; // 关键：不拦截任何触摸事件
    indicator.windowLevel = UIWindowLevelAlert + 100; // 确保在最顶层
    
    [window addSubview:indicator];
    
    [UIView animateWithDuration:0.3 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
        indicator.alpha = 0.0;
        indicator.transform = CGAffineTransformMakeScale(1.5, 1.5);
    } completion:^(BOOL finished) {
        [indicator removeFromSuperview];
    }];
}

static void simulateSkipTap() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            // 1. 获取当前最顶层窗口
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

            // 2. 递归查找包含"跳过"文本的可见控件
            __block UIView *skipTarget = nil;
            void (^findSkipView)(UIView *) = nil;
            findSkipView = ^(UIView *view) {
                if (skipTarget || view.isHidden || view.alpha < 0.1) return;
                
                NSString *text = nil;
                if ([view isKindOfClass:[UILabel class]]) text = ((UILabel *)view).text;
                else if ([view isKindOfClass:[UIButton class]]) text = [(UIButton *)view currentTitle];
                
                if (text && [text containsString:@"跳过"]) {
                    skipTarget = view;
                    return;
                }
                for (UIView *sub in view.subviews) {
                    findSkipView(sub);
                    if (skipTarget) return;
                }
            };
            findSkipView(topWindow);
            
            if (!skipTarget) return;

            // 3. 计算屏幕绝对坐标并显示红圈
            CGPoint centerInTarget = CGPointMake(skipTarget.bounds.size.width / 2.0, skipTarget.bounds.size.height / 2.0);
            CGPoint screenPoint = [skipTarget convertPoint:centerInTarget toView:nil];
            showTapIndicatorAtPoint(screenPoint, topWindow);

            // 4. 简单粗暴：直接发送触摸事件
            if ([skipTarget isKindOfClass:[UIButton class]]) {
                [(UIButton *)skipTarget sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
            
            UITouch *touch = [[UITouch alloc] init];
            [touch setValue:skipTarget forKey:@"view"];
            [touch setValue:@(centerInTarget) forKey:@"locationInWindow"];
            
            UIEvent *event = [[UIEvent alloc] init];
            [event setValue:@[touch] forKey:@"touches"];
            
            [skipTarget touchesBegan:[NSSet setWithObject:touch] withEvent:event];
            [skipTarget touchesEnded:[NSSet setWithObject:touch] withEvent:event];
            
        } @catch (NSException *e) {}
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    simulateSkipTap();
}
%end
