#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 1. 广点通 (GDT) 修复组
// ==========================================
%group GDTHooks

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    // 如果是 GDT 的开屏控制器，立刻无动画关闭，解决透明图层挡点击的问题
    if ([className containsString:@"GDTSplashViewController"] || 
        [className containsString:@"GDTSplashDisplayViewController"]) {
        NSLog(@"[AdBlock] Force dismissing GDT Splash ViewController: %@", className);
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}
%end

%hook UIView
- (void)didMoveToSuperview {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"GDTSplashDLView"]) {
        NSLog(@"[AdBlock] Removing GDTSplashDLView");
        [self removeFromSuperview];
    }
}
%end

%end // GDTHooks 结束


// ==========================================
// 2. 穿山甲 (CSJ/BU) 修复组
// ==========================================
%group CSJHooks

%hook UIView
- (void)didMoveToWindow {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"CSJSplashView"] || 
        [className containsString:@"CSJNativeExpressSplashVideoAdView"]) {
        NSLog(@"[AdBlock] Found CSJ splash view: %@", className);
        
        // 延迟 0.1 秒确保子视图（跳过按钮）已经加载
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 遍历寻找跳过按钮并自动点击
            for (UIView *subview in self.subviews) {
                if ([subview isKindOfClass:[UIButton class]]) {
                    UIButton *btn = (UIButton *)subview;
                    [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[AdBlock] Auto-clicked CSJ Skip Button");
                    return;
                }
            }
            // 没找到按钮则 0.5 秒后强制移除
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.superview) {
                    NSLog(@"[AdBlock] Forcibly removing CSJ splash view");
                    [self removeFromSuperview];
                }
            });
        });
    }
}

- (void)didMoveToSuperview {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"CSJNativeExpressSplashVideoAdView"]) {
        NSLog(@"[AdBlock] Removing CSJNativeExpressSplashVideoAdView");
        [self removeFromSuperview];
    }
}
%end

%end // CSJHooks 结束


// ==========================================
// 3. 通用防御组 (处理透明遮罩和流氓 Window)
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    // 拦截广告 SDK 创建的独立全屏 Window
    if ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"]) {
        NSLog(@"[AdBlock] Blocked suspicious UIWindow: %@", rootVCClass);
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%end // UniversalHooks 结束


// ==========================================
// 4. 初始化：按需激活 Hook 组
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak loaded successfully");
    
    // 激活 GDT Hook
    if (NSClassFromString(@"GDTSplashViewController") || NSClassFromString(@"GDTSplashDLView")) {
        NSLog(@"[AdBlock] Activating GDT hooks");
        %init(GDTHooks);
    }
    
    // 激活 CSJ Hook
    if (NSClassFromString(@"CSJSplashView") || NSClassFromString(@"CSJNativeExpressSplashVideoAdView")) {
        NSLog(@"[AdBlock] Activating CSJ hooks");
        %init(CSJHooks);
    }
    
    // 始终激活通用防御
    %init(UniversalHooks);
}
