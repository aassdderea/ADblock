#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 🎯 自定义跳过按钮关键词（可自行添加）
// ==========================================
static NSArray *const kSkipKeywords = @[
    @"跳过",
    @"5s", @"4s", @"3s", @"2s", @"1s",
    @"跳过广告",
    @"关闭",
    @"Skip"
];

static UIWindow *g_debugWindow = nil;
static UILabel *g_statusLabel = nil;

// 显示底部调试提示
static void showDebugMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_debugWindow) {
            UIWindowScene *activeScene = nil;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    activeScene = scene;
                    break;
                }
            }
            
            if (activeScene) {
                g_debugWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
            } else {
                g_debugWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            
            g_debugWindow.frame = [UIScreen mainScreen].bounds;
            g_debugWindow.windowLevel = UIWindowLevelAlert + 100; // 悬浮在最上层
            g_debugWindow.hidden = NO;
            g_debugWindow.backgroundColor = [UIColor clearColor];
            g_debugWindow.userInteractionEnabled = NO; // 穿透点击
            
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, screenHeight - 120, screenWidth - 20, 40)];
            g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
            g_statusLabel.textColor = [UIColor cyanColor];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            g_statusLabel.font = [UIFont boldSystemFontOfSize:13];
            g_statusLabel.layer.cornerRadius = 8;
            g_statusLabel.clipsToBounds = YES;
            g_statusLabel.numberOfLines = 2;
            [g_debugWindow addSubview:g_statusLabel];
        }
        
        g_statusLabel.text = message;
        g_statusLabel.alpha = 1.0;
        
        [UIView animateWithDuration:0.5 delay:3.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            g_statusLabel.alpha = 0;
        } completion:nil];
    });
}

// 在指定坐标画红圈
static void drawRedCircleAtPoint(CGPoint point) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_debugWindow) return;
        UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(point.x - 25, point.y - 25, 50, 50)];
        circle.layer.cornerRadius = 25;
        circle.layer.borderWidth = 3;
        circle.layer.borderColor = [UIColor redColor].CGColor;
        circle.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.2];
        circle.userInteractionEnabled = NO;
        [g_debugWindow addSubview:circle];
        
        [UIView animateWithDuration:0.5 delay:1.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            circle.alpha = 0;
        } completion:^(BOOL finished) {
            [circle removeFromSuperview];
        }];
    });
}

// 物理模拟点击
static void simulatePhysicalClick(CGPoint point, UIWindow *window) {
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"location"];
    [touch setValue:window forKey:@"window"];
    
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [window sendEvent:event];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [window sendEvent:event];
    });
}

// 递归遍历视图查找包含关键词的控件
static void findAndClickSkipButton(UIView *view, UIWindow *window) {
    if (!view || view.isHidden || view.alpha < 0.1) return;

    // 修复点：使用 CGRectGetMidX 和 CGRectGetMidY 计算中心点
    CGPoint localCenter = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    CGPoint screenCenter = [view convertPoint:localCenter toView:window];

    // 1. 检查 UILabel
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text;
        if (text.length > 0) {
            for (NSString *keyword in kSkipKeywords) {
                if ([text containsString:keyword]) {
                    NSString *msg = [NSString stringWithFormat:@"发现“%@” -> 已尝试模拟点击（点：%.0f,%.0f）", keyword, screenCenter.x, screenCenter.y];
                    showDebugMessage(msg);
                    drawRedCircleAtPoint(screenCenter);
                    simulatePhysicalClick(screenCenter, window);
                    return; 
                }
            }
        }
    } 
    // 2. 检查 UIButton
    else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if (title.length > 0) {
            for (NSString *keyword in kSkipKeywords) {
                if ([title containsString:keyword]) {
                    NSString *msg = [NSString stringWithFormat:@"发现“%@” -> 已尝试模拟点击（点：%.0f,%.0f）", keyword, screenCenter.x, screenCenter.y];
                    showDebugMessage(msg);
                    drawRedCircleAtPoint(screenCenter);
                    simulatePhysicalClick(screenCenter, window);
                    return;
                }
            }
        }
    }

    // 3. 递归遍历子视图
    for (UIView *subview in view.subviews) {
        findAndClickSkipButton(subview, window);
    }
}

// ==========================================
// 🪝 核心 Hook：监听窗口层级变化，实时扫描
// ==========================================
%hook UIWindow

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (self.windowLevel == UIWindowLevelNormal || self.windowLevel == UIWindowLevelStatusBar) {
        // 延迟一点点，确保视图布局完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            findAndClickSkipButton(self, self);
        });
    }
}

- (void)makeKeyAndVisible {
    %orig;
    if (self.windowLevel == UIWindowLevelNormal) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            findAndClickSkipButton(self, self);
        });
    }
}

%end
