// kite-window：预览里 Mac App 的窗口（见 app-windows.ts）——只截这一个 App 的窗口、只向这个进程发输入、读它的界面结构，不动工作机上真的鼠标，
// App 也不用调到前台。做法与实测见 spikes/mac-app-window/README.md。
//
// 用法：
//   kite-window list <pid>...  这些进程里有窗口的 App，每个一行 JSON {pid, name, path}；不需要权限。
//   kite-window <pid>           从标准输入逐行读 JSON 命令，按顺序各回一条消息：1 字节类型加 4 字节大端长度再加内容，
//                               类型 J 是 JSON 文本，B 是紧跟在说明 bytes 的 J 后面的 JPEG。坐标一律是点，原点在截到的那一块的左上角
//                               （窗口整个在显示器上时就是窗口左上角，含标题栏；见 visibleOffset）。
// 启动失败时往标准错误写一行原因并退出；App 退出、起它的进程退出时也退出。
//
// 截图要「录屏与系统录音」权限，发输入、读界面结构要「辅助功能」权限。这两项按这个程序自己算：启动时以自己为责任进程重新执行自己，
// 不然系统算到起它的 kited 头上，kited 起的所有进程（含 agent 的命令）就都跟着有了这两项权限。反过来谁都能直接运行这个程序，
// 所以它只肯操作起它的进程的子孙进程（kited 只交给它预览实例进程树里起的 App），起它的进程退出了就退出。
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/sysctl.h>

extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);
extern char **environ;

// MARK: - 输出

static void emit(char type, NSData *data) {
  uint8_t header[5] = {(uint8_t)type, (uint8_t)(data.length >> 24), (uint8_t)(data.length >> 16), (uint8_t)(data.length >> 8), (uint8_t)data.length};
  fwrite(header, 1, 5, stdout);
  fwrite(data.bytes, 1, data.length, stdout);
  fflush(stdout);
}
static void reply(NSDictionary *object) { emit('J', [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]); }
static void sleepMs(double ms) { usleep((useconds_t)(ms * 1000)); }
static void fatal(NSString *message) {
  fprintf(stderr, "%s\n", message.UTF8String);
  exit(1);
}

// MARK: - 进程

static pid_t parentOf(pid_t pid) {
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return 0;
  return info.kp_eproc.e_ppid;
}

static BOOL descends(pid_t pid, pid_t ancestor) {
  for (int depth = 0; pid > 1 && depth < 64; depth++) {
    pid = parentOf(pid);
    if (pid == ancestor) return YES;
  }
  return NO;
}

/** 屏幕上的正常窗口（第 0 层、看得见、不太小），按从前到后排；pid 为 0 时是所有进程的。 */
static NSArray<NSDictionary *> *windowsOf(pid_t pid) {
  NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSMutableArray *found = [NSMutableArray array];
  for (NSDictionary *info in list) {
    if ((pid && [info[(id)kCGWindowOwnerPID] intValue] != pid) || [info[(id)kCGWindowLayer] intValue] != 0 || [info[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
    CGRect bounds;
    CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &bounds);
    if (bounds.size.width < 40 || bounds.size.height < 40) continue;
    [found addObject:info];
  }
  return found;
}

static void list(int count, const char *pids[]) {
  // 窗口表只取一次，按窗口的进程对上要找的那些
  NSMutableSet<NSNumber *> *windowed = [NSMutableSet set];
  for (NSDictionary *info in windowsOf(0)) [windowed addObject:info[(id)kCGWindowOwnerPID]];
  for (int i = 0; i < count; i++) {
    pid_t pid = atoi(pids[i]);
    if (pid <= 1 || ![windowed containsObject:@(pid)]) continue;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *path = (app.bundleURL ?: app.executableURL).path;
    if (!path) continue;
    NSString *name = app.localizedName ?: path.lastPathComponent.stringByDeletingPathExtension;
    NSData *line = [NSJSONSerialization dataWithJSONObject:@{@"pid" : @(pid), @"name" : name, @"path" : path} options:0 error:nil];
    printf("%s\n", [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding].UTF8String);
  }
}

// MARK: - 窗口与画面

static pid_t target;
static pid_t launcher;
/** 当前看的窗口：App 最前面的那个正常窗口。 */
static CGWindowID windowID;
static CGRect windowFrame;
/**
 * 最近截到的那块：窗口超出显示器的部分截不到，画面只是窗口在显示器上的那一块。visibleOffset 是它的左上角在窗口里的位置，
 * 画面上的坐标加上它才是窗口里的点；输入与界面结构的位置都照画面算。
 */
static CGPoint visibleOffset;

/** 找 App 最前面的窗口，记下编号和位置（全局坐标，左上角为原点）；没有窗口时返回 NO。 */
static BOOL locateWindow(void) {
  NSDictionary *info = windowsOf(target).firstObject;
  if (!info) return NO;
  windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
  CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &windowFrame);
  return YES;
}

static SCContentFilter *filter;
static SCDisplay *filterDisplay;
static CGWindowID filterWindow;

/** 只含这个 App 的窗口的内容过滤器：截它所在的显示器，裁到窗口的范围，菜单、弹出框落在窗口里的也截得到，别的 App 盖在上面的不截。 */
static NSString *prepareFilter(void) {
  if (filter && filterWindow == windowID && CGRectContainsRect(filterDisplay.frame, windowFrame)) return nil;
  __block NSString *error;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *failure) {
    if (failure) { error = [NSString stringWithFormat:@"读不到屏幕内容：%@", failure.localizedDescription]; dispatch_semaphore_signal(done); return; }
    SCWindow *window = nil;
    for (SCWindow *w in content.windows) if (w.windowID == windowID) window = w;
    if (!window) { error = @"找不到 App 的窗口"; dispatch_semaphore_signal(done); return; }
    CGPoint center = CGPointMake(CGRectGetMidX(window.frame), CGRectGetMidY(window.frame));
    SCDisplay *display = content.displays.firstObject;
    for (SCDisplay *d in content.displays) if (CGRectContainsPoint(d.frame, center)) display = d;
    filter = [[SCContentFilter alloc] initWithDisplay:display includingApplications:@[ window.owningApplication ] exceptingWindows:@[]];
    filterDisplay = display;
    filterWindow = windowID;
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  if (error) filter = nil;
  return error;
}

/** 截一帧编成 JPEG：给模型的按点截，给设备的按显示器像素截。 */
static NSData *capture(BOOL forModel, NSString **error) {
  if (!locateWindow()) { *error = @"App 没有打开的窗口"; return nil; }
  if ((*error = prepareFilter())) return nil;
  SCStreamConfiguration *config = [SCStreamConfiguration new];
  CGRect shown = CGRectIntersection(windowFrame, filterDisplay.frame);
  visibleOffset = CGPointMake(shown.origin.x - windowFrame.origin.x, shown.origin.y - windowFrame.origin.y);
  config.sourceRect = CGRectOffset(shown, -filterDisplay.frame.origin.x, -filterDisplay.frame.origin.y);
  float scale = forModel ? 1 : filter.pointPixelScale;
  config.width = (size_t)(config.sourceRect.size.width * scale);
  config.height = (size_t)(config.sourceRect.size.height * scale);
  config.showsCursor = NO;
  config.capturesAudio = NO;
  __block CGImageRef image = NULL;
  __block NSString *failure;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef result, NSError *problem) {
    if (result) image = CGImageRetain(result);
    else failure = problem.localizedDescription ?: @"截图失败";
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  if (!image) {
    // 显示器、窗口换了：下次重新取
    filter = nil;
    *error = [NSString stringWithFormat:@"截不到 App 的窗口：%@", failure];
    return nil;
  }
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)data, (CFStringRef)UTTypeJPEG.identifier, 1, NULL);
  CGImageDestinationAddImage(destination, image, (CFDictionaryRef) @{(id)kCGImageDestinationLossyCompressionQuality : forModel ? @0.7 : @0.6});
  CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(image);
  return data;
}

// MARK: - 输入

/**
 * 只发给这个进程（CGEventPostToPid），不经系统的输入队列，真的鼠标不动，别的 App 收不到。鼠标事件要带上窗口编号和窗口里的位置，
 * App 才知道落在哪个窗口哪一点：51 号字段（未公开，NSEvent 的 windowNumber 从这里来）、CGEventSetWindowLocation（未公开），
 * 外加公开的 91、92 号字段（指针下的窗口）。
 */
static void post(CGEventRef event, CGPoint local) {
  static void (*setWindowLocation)(CGEventRef, CGPoint);
  static dispatch_once_t once;
  dispatch_once(&once, ^{ setWindowLocation = dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation"); });
  CGEventSetLocation(event, CGPointMake(windowFrame.origin.x + local.x, windowFrame.origin.y + local.y));
  CGEventSetIntegerValueField(event, 51, windowID);
  CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, windowID);
  CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, windowID);
  if (setWindowLocation) setWindowLocation(event, local);
  CGEventPostToPid(target, event);
  CFRelease(event);
}

static void mouse(CGEventType type, CGPoint local, CGMouseButton button, int64_t clicks) {
  CGEventRef event = CGEventCreateMouseEvent(NULL, type, CGPointZero, button);
  CGEventSetIntegerValueField(event, kCGMouseEventClickState, clicks);
  post(event, local);
}

static void click(CGPoint p, int count, BOOL right) {
  CGEventType down = right ? kCGEventRightMouseDown : kCGEventLeftMouseDown, up = right ? kCGEventRightMouseUp : kCGEventLeftMouseUp;
  CGMouseButton button = right ? kCGMouseButtonRight : kCGMouseButtonLeft;
  for (int i = 1; i <= count; i++) {
    mouse(down, p, button, i);
    sleepMs(30);
    mouse(up, p, button, i);
    sleepMs(30);
  }
}

static void drag(CGPoint from, CGPoint to) {
  mouse(kCGEventLeftMouseDown, from, kCGMouseButtonLeft, 1);
  sleepMs(50);
  for (int i = 1; i <= 12; i++) {
    mouse(kCGEventLeftMouseDragged, CGPointMake(from.x + (to.x - from.x) * i / 12, from.y + (to.y - from.y) * i / 12), kCGMouseButtonLeft, 1);
    sleepMs(16);
  }
  mouse(kCGEventLeftMouseUp, to, kCGMouseButtonLeft, 1);
}

static void longPress(CGPoint p, double seconds) {
  mouse(kCGEventLeftMouseDown, p, kCGMouseButtonLeft, 1);
  sleepMs(seconds * 1000);
  mouse(kCGEventLeftMouseUp, p, kCGMouseButtonLeft, 1);
}

/** 滚动按像素：dx、dy 为正是往右、往下看（内容往左、往上走），同网页的滚轮。 */
static void scroll(CGPoint p, double dx, double dy) {
  CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, (int32_t)-dy, (int32_t)-dx, 0);
  post(event, p);
}

static void keyboard(CGKeyCode code, CGEventFlags flags, NSString *text) {
  for (int down = 1; down >= 0; down--) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, down);
    CGEventSetFlags(event, flags);
    if (text) {
      unichar chars[16];
      NSUInteger length = MIN(text.length, 16);
      [text getCharacters:chars range:NSMakeRange(0, length)];
      CGEventKeyboardSetUnicodeString(event, length, chars);
    }
    CGEventPostToPid(target, event);
    CFRelease(event);
    sleepMs(8);
  }
}

/** 逐个字符按 Unicode 发，中文、emoji 都能直接进输入框，不经输入法。 */
static void typeUnicode(NSString *text) {
  for (NSUInteger i = 0; i < text.length;) {
    NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:i];
    NSString *character = [text substringWithRange:range];
    if ([character isEqualToString:@"\n"]) keyboard(36, 0, nil);
    else keyboard(0, 0, character);
    i = NSMaxRange(range);
  }
}

/** 虚拟键码，键名照 Playwright 的小写（别的写法 kited 解析动作时已统一）。 */
static NSDictionary<NSString *, NSNumber *> *namedKeys(void) {
  return @{
    @"enter" : @36, @"tab" : @48, @"space" : @49, @"backspace" : @51, @"escape" : @53, @"delete" : @117,
    @"arrowleft" : @123, @"arrowright" : @124, @"arrowdown" : @125, @"arrowup" : @126,
    @"home" : @115, @"end" : @119, @"pageup" : @116, @"pagedown" : @121,
    @"f1" : @122, @"f2" : @120, @"f3" : @99, @"f4" : @118, @"f5" : @96, @"f6" : @97, @"f7" : @98, @"f8" : @100, @"f9" : @101, @"f10" : @109, @"f11" : @103, @"f12" : @111,
  };
}

/** 美式键盘上字符的虚拟键码；没有的返回 -1。 */
static int asciiKey(unichar c) {
  const char *keys = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.\0\0`";
  for (int i = 0; i < 51; i++) if (keys[i] && (unichar)keys[i] == c) return i;
  return -1;
}

/** 组合键：Control+A、Meta+Shift+Z 这样的写法。 */
static BOOL pressCombo(NSString *combo) {
  CGEventFlags flags = 0;
  NSArray<NSString *> *parts = [combo.lowercaseString componentsSeparatedByString:@"+"];
  for (NSString *part in [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]) {
    if ([part isEqualToString:@"meta"]) flags |= kCGEventFlagMaskCommand;
    else if ([part isEqualToString:@"control"]) flags |= kCGEventFlagMaskControl;
    else if ([part isEqualToString:@"alt"]) flags |= kCGEventFlagMaskAlternate;
    else if ([part isEqualToString:@"shift"]) flags |= kCGEventFlagMaskShift;
    else return NO;
  }
  NSString *last = parts.lastObject;
  NSNumber *code = namedKeys()[last];
  if (code) { keyboard(code.unsignedShortValue, flags, nil); return YES; }
  if (last.length != 1) return NO;
  int ascii = asciiKey([last characterAtIndex:0]);
  keyboard(ascii >= 0 ? (CGKeyCode)ascii : 0, flags, last);
  return YES;
}

// MARK: - 界面结构

static NSString *stringAttribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess || !value) return nil;
  id object = CFBridgingRelease(value);
  if ([object isKindOfClass:NSString.class]) return [object length] ? object : nil;
  if ([object isKindOfClass:NSNumber.class]) return [object description];
  return nil;
}

static void axWalk(AXUIElementRef element, int depth, NSMutableString *out, int *budget) {
  if (--*budget < 0) return;
  NSString *role = [stringAttribute(element, kAXRoleAttribute) ?: @"?" stringByReplacingOccurrencesOfString:@"AX" withString:@""];
  NSString *label = stringAttribute(element, kAXTitleAttribute) ?: stringAttribute(element, kAXDescriptionAttribute);
  NSString *value = stringAttribute(element, kAXValueAttribute), *identifier = stringAttribute(element, kAXIdentifierAttribute);
  CFTypeRef position = NULL, size = NULL;
  CGPoint p = CGPointZero;
  CGSize s = CGSizeZero;
  if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &position) == kAXErrorSuccess && position) { AXValueGetValue(position, kAXValueTypeCGPoint, &p); CFRelease(position); }
  if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) == kAXErrorSuccess && size) { AXValueGetValue(size, kAXValueTypeCGSize, &s); CFRelease(size); }
  [out appendFormat:@"%*s%@", depth * 2, "", role];
  if (label) [out appendFormat:@" \"%@\"", label];
  if (value) [out appendFormat:@" value=%@", value.length > 200 ? [[value substringToIndex:200] stringByAppendingString:@"…"] : value];
  if (identifier) [out appendFormat:@" id=%@", identifier];
  CFTypeRef enabled = NULL;
  if (AXUIElementCopyAttributeValue(element, kAXEnabledAttribute, &enabled) == kAXErrorSuccess && enabled) {
    if (!CFBooleanGetValue(enabled)) [out appendString:@" disabled"];
    CFRelease(enabled);
  }
  // 位置换成窗口里的点，同点按的坐标
  [out appendFormat:@" (%.0f,%.0f %.0fx%.0f)\n", p.x - windowFrame.origin.x - visibleOffset.x, p.y - windowFrame.origin.y - visibleOffset.y, s.width, s.height];
  CFArrayRef children = NULL;
  if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef *)&children) == kAXErrorSuccess && children) {
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) axWalk(CFArrayGetValueAtIndex(children, i), depth + 1, out, budget);
    CFRelease(children);
  }
}

/** 当前看的窗口的元素树，一行一个元素：角色、标签、值、位置（窗口里的点）。 */
static NSString *axTree(void) {
  if (!locateWindow()) return nil;
  AXUIElementRef app = AXUIElementCreateApplication(target);
  CFArrayRef windows = NULL;
  NSMutableString *out = nil;
  if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
    // 按位置和大小对上当前看的那个窗口；对不上时用第一个
    AXUIElementRef chosen = CFArrayGetCount(windows) ? CFArrayGetValueAtIndex(windows, 0) : NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
      AXUIElementRef window = CFArrayGetValueAtIndex(windows, i);
      CFTypeRef position = NULL;
      CGPoint p = CGPointZero;
      if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position) == kAXErrorSuccess && position) { AXValueGetValue(position, kAXValueTypeCGPoint, &p); CFRelease(position); }
      if (fabs(p.x - windowFrame.origin.x) < 1 && fabs(p.y - windowFrame.origin.y) < 1) { chosen = window; break; }
    }
    if (chosen) {
      out = [NSMutableString string];
      int budget = 800;
      axWalk(chosen, 0, out, &budget);
    }
    CFRelease(windows);
  }
  CFRelease(app);
  return out;
}

// MARK: - 命令

/** 画面上的点换成窗口里的点（见 visibleOffset）。 */
static CGPoint pointOf(NSDictionary *object) {
  return CGPointMake([object[@"x"] doubleValue] + visibleOffset.x, [object[@"y"] doubleValue] + visibleOffset.y);
}

static void run(NSDictionary *command) {
  NSString *cmd = command[@"cmd"];
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:command[@"id"] ?: @0 forKey:@"id"];
  if (getppid() != launcher) exit(0);
  if ([cmd isEqualToString:@"frame"]) {
    BOOL forModel = [command[@"model"] boolValue];
    NSString *error;
    NSData *jpeg = capture(forModel, &error);
    if (!jpeg) { result[@"error"] = error; reply(result); return; }
    // 截到的那一块的尺寸：窗口有一部分在显示器外时比窗口小
    CGSize shown = CGRectIntersection(windowFrame, filterDisplay.frame).size;
    result[@"width"] = @(shown.width);
    result[@"height"] = @(shown.height);
    result[@"bytes"] = @(jpeg.length);
    reply(result);
    emit('B', jpeg);
    return;
  }
  if ([cmd isEqualToString:@"info"]) {
    if (locateWindow()) {
      result[@"width"] = @(windowFrame.size.width);
      result[@"height"] = @(windowFrame.size.height);
      result[@"title"] = [NSRunningApplication runningApplicationWithProcessIdentifier:target].localizedName ?: @"";
    } else result[@"error"] = @"App 没有打开的窗口";
  } else if ([cmd isEqualToString:@"ax"]) {
    NSString *tree = axTree();
    if (tree) result[@"text"] = tree; else result[@"error"] = @"读不到界面结构";
  } else if ([@[ @"tap", @"drag", @"scroll", @"longpress", @"key", @"type" ] containsObject:cmd]) {
    // 每次都重新找窗口：窗口可能挪了、换了
    if (!locateWindow()) { result[@"error"] = @"App 没有打开的窗口"; reply(result); return; }
    if ([cmd isEqualToString:@"tap"]) click(pointOf(command), MAX(1, [command[@"count"] intValue]), [command[@"button"] isEqual:@"right"]);
    else if ([cmd isEqualToString:@"drag"]) drag(pointOf(command[@"from"]), pointOf(command[@"to"]));
    else if ([cmd isEqualToString:@"scroll"]) scroll(pointOf(command), [command[@"dx"] doubleValue], [command[@"dy"] doubleValue]);
    else if ([cmd isEqualToString:@"longpress"]) longPress(pointOf(command), command[@"seconds"] ? [command[@"seconds"] doubleValue] : 1);
    else if ([cmd isEqualToString:@"key"]) { if (!pressCombo(command[@"key"] ?: @"")) result[@"error"] = @"不认识这个键"; }
    else typeUnicode(command[@"text"] ?: @"");
  } else {
    result[@"error"] = @"不认识的命令";
  }
  reply(result);
}

/** 以自己为责任进程重新执行自己（进程号、标准输入输出不变），隐私权限按这个程序算。 */
static void disclaim(char *argv[]) {
#ifdef KITE_WINDOW_INHERIT
  // 只在本机实验时编进来：权限跟着起它的终端 App 走，不弹系统的权限提示
  setenv("KITE_WINDOW_LAUNCHER", [NSString stringWithFormat:@"%d", getppid()].UTF8String, 1);
  return;
#endif
  if (getenv("KITE_WINDOW_DISCLAIMED")) return;
  setenv("KITE_WINDOW_DISCLAIMED", "1", 1);
  // 起它的进程记在环境变量里：重新执行不换进程号，但要在第一次执行时记下
  setenv("KITE_WINDOW_LAUNCHER", [NSString stringWithFormat:@"%d", getppid()].UTF8String, 1);
  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETEXEC);
  responsibility_spawnattrs_setdisclaim(&attributes, 1);
  pid_t pid;
  int error = posix_spawn(&pid, argv[0], NULL, &attributes, argv, environ);
  fatal([NSString stringWithFormat:@"重新执行失败：%s", strerror(error)]);
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc >= 2 && strcmp(argv[1], "list") == 0) { list(argc - 2, (const char **)argv + 2); return 0; }
    if (argc < 2) fatal(@"用法：kite-window <pid> 或 kite-window list <pid>...");
    disclaim(argv);
    launcher = atoi(getenv("KITE_WINDOW_LAUNCHER") ?: "0");
    target = atoi(argv[1]);
    if (launcher <= 1 || getppid() != launcher) fatal(@"起它的进程已经退出");
    if (target <= 1 || !descends(target, launcher)) fatal(@"只能操作起它的进程的子孙进程");
    if (!locateWindow()) fatal(@"App 没有打开的窗口");
    // 没有权限时让系统提示一次（在工作机的屏幕上），允许之后重开预览才生效
    if (!CGPreflightScreenCaptureAccess()) {
      CGRequestScreenCaptureAccess();
      fatal([NSString stringWithFormat:@"工作机上还没允许录屏：在系统设置的「隐私与安全性 → 录屏与系统录音」里打开 %s，再重新打开预览", getprogname()]);
    }
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES})) {
      fatal([NSString stringWithFormat:@"工作机上还没允许辅助功能：在系统设置的「隐私与安全性 → 辅助功能」里打开 %s，再重新打开预览", getprogname()]);
    }
    // App 退出了（脚本重启、用户关掉）：退出，宿主按新的进程重开
    dispatch_source_t exited = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)target, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(exited, ^{ fatal(@"App 退出了"); });
    dispatch_resume(exited);
    // 起它的进程退出时这个程序的父进程变成 launchd，不再接命令
    dispatch_source_t orphaned = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)launcher, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(orphaned, ^{ exit(0); });
    dispatch_resume(orphaned);
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) > 0) {
      @autoreleasepool {
        NSData *data = [NSData dataWithBytes:line length:strlen(line)];
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![command isKindOfClass:NSDictionary.class]) { reply(@{@"id" : @0, @"error" : @"命令不是 JSON"}); continue; }
        @try {
          run(command);
        } @catch (NSException *exception) {
          reply(@{@"id" : command[@"id"] ?: @0, @"error" : [NSString stringWithFormat:@"%@：%@", exception.name, exception.reason]});
        }
      }
    }
  }
  return 0;
}
