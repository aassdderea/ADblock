#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心逻辑：自动寻找并点击“跳过”按钮
// ==========================================
static void autoClickSkipButton(UIView *rootView) {
    if (!rootView) return;
    
    // 使用 NSMutableArray 作为队列进行广度优先遍历
    NSMutableArray *queue = [NSMutableArray arrayWithObject:rootView];
    
    while (queue.count > 0) {
        UIView *currentView = queue.firstObject;
        [queue removeObjectAtIndex:0];
        
        // 1. 检查是否是 UIButton 且包含“跳过”字样
        if ([currentView isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)currentView;
            NSString *title = [btn titleForState:UIControlStateNormal];
            
            // 匹配常见的跳过按钮文本
            if (title && ([title containsString:@"跳过"] || 
                          [title containsString:@"Skip"] || 
                          [title containsString:@"关闭"])) {
                NSLog(@"[AdBlock] 🎯 Found Skip Button: '%@', Auto-Clicking!", title);
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                return; // 找到并点击后退出
            }
        }
        
        // 2. 检查类名是否包含 Skip (有些跳过按钮不是标准 UIButton)
        NSString *className = NSStringFromClass([currentView class]);
        if ([className containsString:@"Skip"] || [className containsString:@"Countdown"]) {
            if ([currentView respondsToSelector:@selector(sendActionsForControlEvents:)]) {
                NSLog(@"[AdBlock] 🎯 Found Skip View by class: %@, Auto-Clicking!", className);
                [(UIControl *)currentView sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
        }
        
        // 将子视图加入队列
        [queue addObjectsFromArray:currentView.subviews];
    }
}

// ==========================================
// 1. 广点通 (GDT) 修复组
// ==========================================
%group GDTHooks

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return; // 确保视图已经添加到窗口上
    
    NSString *className = NSStringFromClass([self class]);
    // 拦截 GDT 的开屏视图
    if ([className containsString:@"GDTSplash"] || [className containsString:@"GDTAdView"]) {
        NSLog(@"[AdBlock] GDT Splash View detected: %@", className);
        
        // 延迟 0.2 秒，确保“跳过”按钮已经渲染出来
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            autoClickSkipButton(self);
        });
    }
}
%end

%end 


// ==========================================
// 2. 穿山甲 (CSJ/BU) 修复组
// ==========================================
%group CSJHooks

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    
    NSString *className = NSStringFromClass([self class]);
    // 拦截穿山甲的开屏视图
    if ([className containsString:@"CSJSplash"] || [className containsString:@"BUSplash"]) {
        NSLog(@"[AdBlock] CSJ Splash View detected: %@", className);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            autoClickSkipButton(self);
        });
    }
}
%end

%end 


// ==========================================
// 3. 通用防御组 (拦截流氓 Window)
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    
    // 如果 SDK 创建了一个独立的 Window 来放广告，我们拦截它并尝试点击跳过
    if ([rootVCClass containsString:@"Splash"] || [rootVCClass containsString:@"Ad"]) {
        NSLog(@"[AdBlock] Suspicious UIWindow detected: %@", rootVCClass);
        
        // 先让它显示，然后立刻去里面找“跳过”按钮
        %orig; 
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.rootViewController.view) {
                autoClickSkipButton(self.rootViewController.view);
            }
        });
        return;
    }
    %orig;
}
%end

%end 


// ==========================================
// 4. 初始化
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak loaded - Auto Skip Mode");
    
    // 激活 GDT Hook
    if (NSClassFromString(@"GDTSplashViewController") || NSClassFromString(@"GDTSplashDLView")) {
        %init(GDTHooks);
    }
    
    // 激活 CSJ Hook
    if (NSClassFromString(@"CSJSplashView") || NSClassFromString(@"BUSplashAd")) {
        %init(CSJHooks);
    }
    
    // 始终激活通用防御
    %init(UniversalHooks);
}
