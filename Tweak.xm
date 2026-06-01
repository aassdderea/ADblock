#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 核心配置：识别跳过按钮的“特征库”
// ==========================================
// 1. 文本特征：支持中英文、大小写、带数字倒计时（如 "跳过 3" 或 "3s"）
static NSString * const kSkipButtonRegex = @"(?i)^\\s*(跳过|skip|关闭|close|跳过\\s*\\d+|\\d+\\s*跳过|\\d+\\s*s|skip\\s*in\\s*\\d+)\\s*$";

// 2. 尺寸特征：跳过按钮通常不会太大（防误触全屏大按钮）
static const CGFloat kMaxButtonArea = 25000.0; // 例如 100x250 或 150x150

// 3. 位置特征：跳过按钮通常在屏幕边缘（右上角、右下角或左下角）
static const CGFloat kEdgeMarginRatio = 0.35; // 按钮中心点必须在屏幕边缘 35% 的区域内

// ==========================================
// 核心逻辑：扫描并点击
// ==========================================
%group UniversalSkipper

%hook UIView
- (void)didMoveToWindow {
    %orig;
    
    // 只有当视图被添加到 Window 时才触发扫描
    UIWindow *window = self.window;
    if (!window) return;
    
    // 过滤掉系统级 Window（如键盘、状态栏、Alert）
    if (window.windowLevel >= UIWindowLevelAlert - 1) return;
    
    // 延迟 0.2 秒扫描。原因：SDK 渲染 UI 有先后顺序，等 0.2 秒确保按钮的 Text 和 Frame 已经设置完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _scanAndClickSkipButtonInWindow:window];
    });
}

// 添加一个私有方法用于递归扫描
%new
- (void)_scanAndClickSkipButtonInWindow:(UIWindow *)window {
    // 防重复点击标志
    static NSDate *lastClickTime = nil;
    if (lastClickTime && [[NSDate date] timeIntervalSinceDate:lastClickTime] < 1.0) {
        return; // 1秒内不重复触发，防止死循环或疯狂点击
    }

    // 递归查找符合条件的按钮
    UIButton *targetButton = [self _findSkipButtonInView:window];
    
    if (targetButton) {
        NSLog(@"[UniversalSkipper] 🎯 发现跳过按钮: Class=%@, Text='%@', Frame=%@", 
              NSStringFromClass([targetButton class]), 
              [targetButton.titleLabel text] ?: @"(nil)", 
              NSStringFromCGRect(targetButton.frame));
        
        // 执行物理点击
        [targetButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        lastClickTime = [NSDate date];
    }
}

%new
- (UIButton *)_findSkipButtonInView:(UIView *)view {
    if (![view isKindOfClass:[UIView class]]) return nil;
    
    // 如果视图被隐藏或透明度极低，跳过
    if (view.isHidden || view.alpha < 0.1) return nil;
    
    // 检查当前视图是否是目标 Button
    if ([view isKindOfClass:[UIButton class]] || [view isKindOfClass:UIControl.class]) {
        UIButton *btn = (UIButton *)view;
        if ([self _isSkipButton:btn]) {
            return btn;
        }
    }
    
    // 递归检查子视图
    for (UIView *subview in view.subviews) {
        UIButton *found = [self _findSkipButtonInView:subview];
        if (found) return found;
    }
    
    return nil;
}

%new
- (BOOL)_isSkipButton:(UIButton *)btn {
    // 1. 检查尺寸（防误触）
    CGRect frame = btn.frame;
    CGFloat area = frame.size.width * frame.size.height;
    if (area > kMaxButtonArea || area < 100) return NO; // 太小或太大都不对
    
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
    if (!title) title = btn.accessibilityLabel; // 兼容某些无障碍标签
    
    if (title && title.length > 0 && title.length < 15) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", kSkipButtonRegex];
        if ([predicate evaluateWithObject:title]) {
            return YES;
        }
    }
    
    return NO;
}
%end

%end // UniversalSkipper


// ==========================================
// 初始化
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 Tweak loaded - 全局开屏广告秒杀已激活");
    %init(UniversalSkipper);
}
