// 实验探针：只截一个 App 的窗口、只给这个进程发输入、读它的界面结构，看各要什么权限。用法见 README.md。
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <spawn.h>
#import <dlfcn.h>

extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);
extern char **environ;

static CGRect windowBounds;
static double now(void) { return [NSDate date].timeIntervalSince1970 * 1000; }

static NSDictionary *mainWindow(pid_t pid) {
  NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  for (NSDictionary *info in list) {
    if ([info[(id)kCGWindowOwnerPID] intValue] != pid || [info[(id)kCGWindowLayer] intValue] != 0) continue;
    CGRect bounds; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &bounds);
    if (bounds.size.width < 50 || bounds.size.height < 50) continue;
    return info;
  }
  return nil;
}

static CGRect boundsOf(NSDictionary *info) { CGRect r; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &r); windowBounds = r; return r; }
static CGPoint cursor(void) { CGEventRef e = CGEventCreate(NULL); CGPoint p = CGEventGetLocation(e); CFRelease(e); return p; }

static void post(pid_t pid, CGEventRef event, CGWindowID window) {
  if (window) {
    static void (*setWindowLocation)(CGEventRef, CGPoint);
    if (!setWindowLocation) setWindowLocation = dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
    CGPoint global = CGEventGetLocation(event);
    if (setWindowLocation && !getenv("PROBE_NO_WINLOC")) setWindowLocation(event, CGPointMake(global.x - windowBounds.origin.x, global.y - windowBounds.origin.y));
    CGEventSetIntegerValueField(event, 91, window);  // kCGMouseEventWindowUnderMousePointer
    CGEventSetIntegerValueField(event, 92, window);  // kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent
    if (!getenv("PROBE_NO51")) CGEventSetIntegerValueField(event, 51, window);  // 未公开：NSEvent 的 windowNumber 从这里来
  }
  CGEventPostToPid(pid, event);
  CFRelease(event);
}

// 让窗口在它的 App 里成为主窗口，不把 App 调到前台（做法同 yabai 的 window_manager_make_key_window）
static void makeKey(pid_t pid, CGWindowID window) {
  static int (*postRecord)(ProcessSerialNumber *, uint8_t *);
  if (!postRecord) {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    postRecord = dlsym(RTLD_DEFAULT, "SLPSPostEventRecordTo");
  }
  ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  GetProcessForPID(pid, &psn);
#pragma clang diagnostic pop
  uint8_t bytes[0xf8] = { [0x04] = 0xf8, [0x3a] = 0x10 };
  memcpy(bytes + 0x3c, &window, sizeof(uint32_t));
  memset(bytes + 0x20, 0xFF, 0x10);
  bytes[0x08] = 0x01; int a = postRecord(&psn, bytes);
  bytes[0x08] = 0x02; int b = postRecord(&psn, bytes);
  fprintf(stderr, "makeKey %d %d\n", a, b);
}

static void click(pid_t pid, double x, double y, int count, BOOL right) {
  NSDictionary *info = mainWindow(pid);
  CGRect b = boundsOf(info);
  CGWindowID window = [info[(id)kCGWindowNumber] unsignedIntValue];
  CGPoint at = CGPointMake(b.origin.x + x, b.origin.y + y);
  CGPoint before = cursor();
  if (getenv("PROBE_MAKEKEY")) makeKey(pid, window);
  for (int i = 1; i <= count; i++) {
    CGEventRef down = CGEventCreateMouseEvent(NULL, right ? kCGEventRightMouseDown : kCGEventLeftMouseDown, at, right ? kCGMouseButtonRight : kCGMouseButtonLeft);
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, i);
    post(pid, down, window);
    usleep(30000);
    CGEventRef up = CGEventCreateMouseEvent(NULL, right ? kCGEventRightMouseUp : kCGEventLeftMouseUp, at, right ? kCGMouseButtonRight : kCGMouseButtonLeft);
    CGEventSetIntegerValueField(up, kCGMouseEventClickState, i);
    post(pid, up, window);
    usleep(30000);
  }
  CGPoint after = cursor();
  printf("{\"window\":%u,\"global\":[%.0f,%.0f],\"cursorBefore\":[%.0f,%.0f],\"cursorAfter\":[%.0f,%.0f]}\n", window, at.x, at.y, before.x, before.y, after.x, after.y);
}

static void drag(pid_t pid, double x1, double y1, double x2, double y2) {
  NSDictionary *info = mainWindow(pid);
  CGRect b = boundsOf(info);
  CGWindowID window = [info[(id)kCGWindowNumber] unsignedIntValue];
  CGPoint from = CGPointMake(b.origin.x + x1, b.origin.y + y1);
  CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, from, kCGMouseButtonLeft);
  CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
  post(pid, e, window);
  for (int i = 1; i <= 10; i++) {
    CGPoint p = CGPointMake(from.x + (x2 - x1) * i / 10, from.y + (y2 - y1) * i / 10);
    e = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, p, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
    post(pid, e, window);
    usleep(16000);
  }
  e = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, CGPointMake(b.origin.x + x2, b.origin.y + y2), kCGMouseButtonLeft);
  CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
  post(pid, e, window);
  printf("{\"ok\":true}\n");
}

static void sendText(pid_t pid, NSString *text) {
  for (NSUInteger i = 0; i < text.length; ) {
    NSRange r = [text rangeOfComposedCharacterSequenceAtIndex:i];
    unichar chars[8]; [text getCharacters:chars range:r];
    for (int down = 1; down >= 0; down--) {
      CGEventRef e = CGEventCreateKeyboardEvent(NULL, 0, down);
      CGEventKeyboardSetUnicodeString(e, r.length, chars);
      post(pid, e, 0);
    }
    usleep(8000);
    i = NSMaxRange(r);
  }
  printf("{\"ok\":true}\n");
}

static void key(pid_t pid, CGKeyCode code, CGEventFlags flags) {
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
    CGEventSetFlags(e, flags);
    post(pid, e, 0);
  }
  printf("{\"ok\":true}\n");
}

static void scroll(pid_t pid, double x, double y, int dy) {
  NSDictionary *info = mainWindow(pid);
  CGRect b = boundsOf(info);
  CGWindowID window = [info[(id)kCGWindowNumber] unsignedIntValue];
  CGEventRef e = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, dy, 0, 0);
  CGEventSetLocation(e, CGPointMake(b.origin.x + x, b.origin.y + y));
  post(pid, e, window);
  printf("{\"ok\":true}\n");
}

static void capture(pid_t pid, NSString *path, BOOL app) {
  NSDictionary *info = mainWindow(pid);
  CGWindowID windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
  double t0 = now();
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
    if (error) { printf("{\"error\":\"%s\"}\n", error.localizedDescription.UTF8String); dispatch_semaphore_signal(done); return; }
    double t1 = now();
    SCWindow *window = nil;
    for (SCWindow *w in content.windows) if (w.windowID == windowID) window = w;
    if (!window) { printf("{\"error\":\"no window\"}\n"); dispatch_semaphore_signal(done); return; }
    SCContentFilter *filter;
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    if (app) {
      SCDisplay *display = content.displays.firstObject;
      for (SCDisplay *d in content.displays) if (CGRectContainsPoint(d.frame, window.frame.origin)) display = d;
      filter = [[SCContentFilter alloc] initWithDisplay:display includingApplications:@[window.owningApplication] exceptingWindows:@[]];
      config.sourceRect = CGRectOffset(window.frame, -display.frame.origin.x, -display.frame.origin.y);
    } else {
      filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
      config.ignoreShadowsSingleWindow = YES;
    }
    float scale = filter.pointPixelScale;
    config.width = window.frame.size.width * scale;
    config.height = window.frame.size.height * scale;
    config.showsCursor = NO;
    config.capturesAudio = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError *error) {
      double t2 = now();
      if (error) { printf("{\"error\":\"%s\"}\n", error.localizedDescription.UTF8String); dispatch_semaphore_signal(done); return; }
      NSMutableData *data = [NSMutableData data];
      CGImageDestinationRef dest = CGImageDestinationCreateWithData((CFMutableDataRef)data, (CFStringRef)UTTypeJPEG.identifier, 1, NULL);
      CGImageDestinationAddImage(dest, image, (CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.6});
      CGImageDestinationFinalize(dest); CFRelease(dest);
      [data writeToFile:path atomically:YES];
      printf("{\"contentMs\":%.0f,\"captureMs\":%.0f,\"encodeMs\":%.0f,\"pixels\":[%zu,%zu],\"points\":[%.0f,%.0f],\"scale\":%.1f,\"bytes\":%lu,\"onScreen\":%d}\n",
        t1 - t0, t2 - t1, now() - t2, CGImageGetWidth(image), CGImageGetHeight(image), window.frame.size.width, window.frame.size.height, scale, (unsigned long)data.length, window.onScreen);
      dispatch_semaphore_signal(done);
    }];
  }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

static NSString *attr(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess || !value) return nil;
  id object = CFBridgingRelease(value);
  return [object isKindOfClass:[NSString class]] ? object : nil;
}

static void dump(AXUIElementRef element, int depth, CGPoint origin) {
  NSString *role = attr(element, kAXRoleAttribute) ?: @"?";
  NSString *title = attr(element, kAXTitleAttribute) ?: attr(element, kAXDescriptionAttribute) ?: @"";
  NSString *value = attr(element, kAXValueAttribute);
  if (value.length) title = [title stringByAppendingFormat:@" = %@", value];
  CFTypeRef pos = NULL, size = NULL; CGPoint p = {0}; CGSize s = {0};
  if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &pos) == kAXErrorSuccess) { AXValueGetValue(pos, kAXValueTypeCGPoint, &p); CFRelease(pos); }
  if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) == kAXErrorSuccess) { AXValueGetValue(size, kAXValueTypeCGSize, &s); CFRelease(size); }
  printf("%*s%s \"%s\" (%.0f,%.0f %.0fx%.0f)\n", depth * 2, "", role.UTF8String, title.UTF8String, p.x - origin.x, p.y - origin.y, s.width, s.height);
  CFArrayRef children = NULL;
  if (depth < 8 && AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef *)&children) == kAXErrorSuccess && children) {
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) dump(CFArrayGetValueAtIndex(children, i), depth + 1, origin);
    CFRelease(children);
  }
}

static void ax(pid_t pid) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  CFArrayRef windows = NULL;
  AXError error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows);
  if (error != kAXErrorSuccess) { printf("{\"axError\":%d}\n", error); return; }
  CGRect b = boundsOf(mainWindow(pid));
  for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) dump(CFArrayGetValueAtIndex(windows, i), 0, b.origin);
  CFRelease(windows); CFRelease(app);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (getenv("PROBE_DISCLAIM") && !getenv("PROBE_DISCLAIMED")) {
      // 以自己为责任进程重新执行自己：系统的隐私权限按这个程序算，不再算到起它的进程头上
      setenv("PROBE_DISCLAIMED", "1", 1);
      posix_spawnattr_t attr; posix_spawnattr_init(&attr);
      posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);
      responsibility_spawnattrs_setdisclaim(&attr, 1);
      pid_t child; int rc = posix_spawn(&child, argv[0], NULL, &attr, argv, environ);
      fprintf(stderr, "disclaim re-exec failed: %d\n", rc);
      return 1;
    }
    NSString *cmd = argc > 1 ? @(argv[1]) : @"perms";
    pid_t pid = argc > 2 ? atoi(argv[2]) : 0;
    if ([cmd isEqual:@"perms"]) {
      printf("{\"screen\":%d,\"postEvent\":%d,\"accessibility\":%d,\"disclaimed\":%d}\n", CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess(), AXIsProcessTrusted(), getenv("PROBE_DISCLAIMED") != NULL);
    } else if ([cmd isEqual:@"request"]) {
      printf("{\"screen\":%d,\"postEvent\":%d}\n", CGRequestScreenCaptureAccess(), CGRequestPostEventAccess());
      NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
      printf("{\"accessibility\":%d}\n", AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options));
    } else if ([cmd isEqual:@"window"]) {
      NSDictionary *info = mainWindow(pid);
      CGRect b = boundsOf(info);
      printf("{\"window\":%u,\"bounds\":[%.0f,%.0f,%.0f,%.0f],\"onScreen\":%d,\"name\":\"%s\"}\n", [info[(id)kCGWindowNumber] unsignedIntValue], b.origin.x, b.origin.y, b.size.width, b.size.height,
        [info[(id)kCGWindowIsOnscreen] boolValue], [info[(id)kCGWindowName] UTF8String] ?: "");
    } else if ([cmd isEqual:@"capture"]) capture(pid, @(argv[3]), NO);
    else if ([cmd isEqual:@"capture-app"]) capture(pid, @(argv[3]), YES);
    else if ([cmd isEqual:@"click"]) click(pid, atof(argv[3]), atof(argv[4]), argc > 5 ? atoi(argv[5]) : 1, NO);
    else if ([cmd isEqual:@"right"]) click(pid, atof(argv[3]), atof(argv[4]), 1, YES);
    else if ([cmd isEqual:@"drag"]) drag(pid, atof(argv[3]), atof(argv[4]), atof(argv[5]), atof(argv[6]));
    else if ([cmd isEqual:@"type"]) sendText(pid, @(argv[3]));
    else if ([cmd isEqual:@"key"]) key(pid, (CGKeyCode)atoi(argv[3]), argc > 4 ? (CGEventFlags)strtoull(argv[4], NULL, 0) : 0);
    else if ([cmd isEqual:@"scroll"]) scroll(pid, atof(argv[3]), atof(argv[4]), atoi(argv[5]));
    else if ([cmd isEqual:@"ax"]) ax(pid);
  }
  return 0;
}
