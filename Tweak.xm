#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 核心配置：识别跳过按钮的“特征库”
// ==========================================
// 1. 文本特征：支持中英文、大小写、带数字倒计时（如 "跳过 3" 或 "3s"）
static NSString * const kSkipButtonRegex = @"(?i)^\\s*(跳过|skip|关闭|close|跳过\\s*\\d+|\\d+\\s*跳过|\\d+\\s*s|skip\\s*in\\s*\\d+)\\s*$";

// 2. 尺寸特征：跳过按钮通常不会太大（防误触全屏大按钮）
static const CGFloat kMaxButtonArea = 25000.0; 

// 3. 位置特征：跳过按钮通常在屏幕边缘（右上角、右下角或左下角）
static const CGFloat kEdgeMarginRatio = 0.35; 

// ==========================================
// 核心逻辑：C 语言静态函数 (彻底解决编译报错，性能更高)
// ==========================================

// 前置声明
static UIButton * findSkipButtonInView(UIView *view);
static BOOL isSkipButton(UIButton *btn);

// 判断是否是跳过按钮
static BOOL isSkipButton(UIButton *btn) {
    // 1. 检查尺寸（防误触）
    CGRect frame = btn.frame;
    CGFloat area = frame.size.width * frame.size.height;
    if (area > kMaxButtonArea || area < 100) return NO; 
    
    // 2. 检查位置（必须在屏幕边缘）
    UIWindow *window = btn.window;
    if (!window) return NO;
    
    CGFloat screenW = window.bounds.size.width;
    CGFloat screenH = window.bounds.size.height;
    CGPoint center = btn.center;
    
    // 转换到 Window 坐标系
    CGPoint centerInWindow = [btn.superview convertPoint:center toView:window];
    
    BOOL isOnRightEdge = centerInWindow.x > screenW * (1.0 - kEdgeMarginRatio);
    BOOL isOnLeftEdge = centerInWindow.x < screenW * kEdgeMarginRatio;
    BOOL isOnTopEdge = centerInWindow.y < screenH * kEdgeMarginRatio;
    BOOL isOnBottomEdge = centerInWindow.y > screenH * (1.0 - kEdgeMarginRatio);
    
    // 绝大多数跳过按钮在右上角，少数在右下角或左下角
    BOOL isOnEdge = (isOnRightEdge && (isOnTopEdge || isOnBottomEdge)) || 
                    (isOnLeftEdge && isOnBottomEdge);
    
    if (!isOnEdge) return NO;
    
    // 3. 检查文本特征（核心识别）
    NSString *title = [btn titleForState:UIControlStateNormal];
    if (!title) title = btn.titleLabel.text;
    if (!title) title = btn.accessibilityLabel; 
    
    if (title && title.length > 0 && title.length < 15) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", kSkipButtonRegex];
        if ([predicate evaluateWithObject:title]) {
            return YES;
        }
    }
    
    return NO;
}

// 递归查找按钮
static UIButton * findSkipButtonInView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return nil;
    if (view.isHidden || view.alpha < 0.1) return nil;
    
    if ([view isKindOfClass:[UIButton class]] || [view isKindOfClass:UIControl.class]) {
        UIButton *btn = (UIButton *)view;
        if (isSkipButton(btn)) {
            return btn;
        }
    }
    
    for (UIView *subview in view.subviews) {
        UIButton *found = findSkipButtonInView(subview);
        if (found) return found;
    }
    
    return nil;
}

// 扫描并点击
static void scanAndClickSkipButtonInWindow(UIWindow *window) {
    // 防重复点击标志
    static NSDate *lastClickTime = nil;
    if (lastClickTime && [[NSDate date] timeIntervalSinceDate:lastClickTime] < 1.0) {
        return; 
    }

    UIButton *targetButton = findSkipButtonInView(window);
    
    if (targetButton) {
        NSLog(@"[UniversalSkipper] 🎯 发现跳过按钮: Class=%@, Text='%@', Frame=%@", 
              NSStringFromClass([targetButton class]), 
              [targetButton.titleLabel text] ?: @"(nil)", 
              NSStringFromCGRect(targetButton.frame));
        
        [targetButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        lastClickTime = [NSDate date];
    }
}


// ==========================================
// Hook 组：拦截视图挂载
// ==========================================
%group UniversalSkipper

%hook UIView
- (void)didMoveToWindow {
    %orig;
    
    UIWindow *window = self.window;
    if (!window) return;
    
    // 过滤掉系统级 Window（如键盘、状态栏、Alert）
    if (window.windowLevel >= UIWindowLevelAlert - 1) return;
    
    // 延迟 0.2 秒扫描，确保 SDK 的 UI 渲染完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 直接调用 C 函数，完美避开 %new 的编译报错
        scanAndClickSkipButtonInWindow(window);
    });
}
%end

%end // UniversalSkipper


// ==========================================
// 初始化
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 Tweak loaded - 全局开屏广告秒杀已激活 (C-Function 优化版)");
    %init(UniversalSkipper);
}
