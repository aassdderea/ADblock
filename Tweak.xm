#import <Foundation/Foundation.h>

// 目标 App 的 Bundle ID (也就是 plist 的文件名)
static NSString *const kAppDomain = @"com.welove520.welove";

%ctor {
    NSLog(@"[PlistCleaner] 🚀 插件开始执行清理...");
    
    // ==========================================
    // 第一重打击：调用系统 API 清空 Domain 缓存
    // ==========================================
    // 这会告诉系统：“把 com.welove520.welove 的所有偏好设置全部作废”
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kAppDomain];
    
    // ==========================================
    // 第二重打击：物理删除 plist 文件 (降维打击)
    // ==========================================
    // 为了防止 iOS 系统的 cfprefsd 守护进程有缓存延迟，我们直接去文件系统里把文件删了
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *prefsDir = [paths.firstObject stringByAppendingPathComponent:@"Preferences"];
        NSString *plistPath = [prefsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", kAppDomain]];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:plistPath]) {
            NSError *error = nil;
            [fileManager removeItemAtPath:plistPath error:&error];
            if (!error) {
                NSLog(@"[PlistCleaner] 🗑️ 物理删除成功: %@", plistPath);
            } else {
                NSLog(@"[PlistCleaner] ⚠️ 物理删除失败: %@", error.localizedDescription);
            }
        } else {
            NSLog(@"[PlistCleaner] ℹ️ 文件不存在，无需删除");
        }
    }
    
    // 强制同步一次，确保系统立刻刷新状态
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSLog(@"[PlistCleaner] ✅ 清理完成！App 将以为自己是第一次安装。");
}
