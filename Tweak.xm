#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
// 调试日志工具：将日志写入 /var/mobile/Documents/adblocker_debug.log
// 请在触发广告后，使用 Filza 打开上述路径查看日志
// ============================================================
static void WriteDebugLog(NSString *message) {
    @autoreleasepool {
        // 固定写入全局可访问目录，避免陷入 App 沙盒 UUID 迷宫
        static NSString *logPath = @"/var/mobile/Documents/adblocker_debug.log";
        
        NSString *timestamp = [[NSDate date] description];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } else {
            // 文件不存在时自动创建
            [data writeToFile:logPath atomically:YES];
        }
    }
}

// ============================================================
// 以下为你的广告拦截 Hook 示例，请根据实际目标类替换
// ============================================================
%hook SomeAdManagerClass

- (void)showAd {
    WriteDebugLog(@"🎯 [AdBlock] 命中 showAd，已拦截");
    // 直接 return 跳过广告展示
    return;
}

- (BOOL)isAdReady {
    WriteDebugLog(@"🔍 [AdBlock] isAdReady 被调用，返回 NO");
    return NO;
}

%end
