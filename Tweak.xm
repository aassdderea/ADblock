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
                objc_msgSend(gesture, @selector(setState:)
