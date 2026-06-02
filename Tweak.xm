// 替换原来的 NSLog，将日志追加写入文件
static void WriteDebugLog(NSString *message) {
    NSString *logPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject 
                         stringByAppendingPathComponent:@"adblocker_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        // 文件不存在则创建
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 使用时替换 NSLog：
// WriteDebugLog([NSString stringWithFormat:@"🎯 真实点击命中: %@", className]);
