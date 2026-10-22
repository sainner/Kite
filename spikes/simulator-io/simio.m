// 模拟器画面、输入与界面结构的验证程序：不开 Simulator.app，直接用 CoreSimulator 的私有接口。
// 画面取 IOSurface 编 JPEG；输入走模拟器里的 dtuhidd（Xcode 27 起旧的 Indigo 输入被丢弃）；界面结构走 AXPTranslator 的请求。
// 接口与报文格式参照 facebook/idb（MIT）的 FBSimulatorControl、FBSimulatorAX。
//
// 用法：simio <UDID>            从标准输入逐行读命令，每条回一行 JSON（ax 先打树再回一行）
//       simio <UDID> <命令...>   只做一条
// 命令见 run() 里的分支。坐标一律是点（与 AX 的 frame 同一套）。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/resource.h>

// MARK: - 私有接口

@protocol SKServiceContextClass
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
@end
@protocol SKServiceContext
- (id)defaultDeviceSetWithError:(NSError **)error;
@end
@protocol SKDeviceSet
- (NSDictionary *)devicesByUDID;
@end
@protocol SKDevice
- (unsigned long long)state;
- (NSString *)name;
- (id)deviceType;
- (id)io;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id))handler;
@end
@protocol SKDeviceType
- (CGSize)mainScreenSize;
- (float)mainScreenScale;
@end
@protocol SKDeviceIO
- (NSArray *)ioPorts;
@end
@protocol SKPort
- (id)descriptor;
@end
@protocol SKDisplay
- (id)framebufferSurface;
- (id)ioSurface;
- (CGSize)displaySize;
- (id)state;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(id, id))surfaces propertiesChangedCallback:(void (^)(id))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end
@protocol SKDisplayState
- (unsigned short)displayClass;
@end
@protocol SKAXRequestClass
+ (id)requestWithTranslation:(id)translation;
@end
@protocol SKAXRequest
- (void)setRequestType:(unsigned long long)type;
- (void)setClientType:(unsigned long long)type;
- (void)setParameters:(NSDictionary *)parameters;
@end
@protocol SKAXResponse
- (id)resultData;
- (unsigned long long)error;
@end
@protocol SKAXObject
- (int)pid;
- (unsigned long long)objectID;
- (void)setBridgeDelegateToken:(NSString *)token;
@end
@protocol SKAXTranslatorClass
+ (id)sharedInstance;
@end
@protocol SKAXTranslator
- (void)setBridgeTokenDelegate:(id)delegate;
- (void)setSupportsDelegateTokens:(BOOL)supports;
- (id)macPlatformElementFromTranslation:(id)translation;
@end
@protocol SKAXPlatformElement
- (void)setAccessibilityValue:(id)value;
- (id)accessibilityValue;
- (BOOL)accessibilityPerformPress;
@end

typedef xpc_object_t (*EndpointFromPort)(mach_port_t, uint64_t, uint64_t);
typedef xpc_connection_t (*ConnectionFromEndpoint)(xpc_object_t);
typedef void (*EnableSim2Host)(xpc_connection_t);

// MARK: - 工具

static double nowMs(void) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}
static void sleepMs(double ms) { usleep((useconds_t)(ms * 1000)); }
static void fail(NSString *message) {
  fprintf(stderr, "simio: %s\n", message.UTF8String);
  exit(1);
}
static void reply(NSDictionary *object) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
  fwrite(data.bytes, 1, data.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}
static NSNumber *round1(double v) { return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.1f", v]]; }

// MARK: - 设备

static id<SKDevice> device;
static NSString *udidString;
static CGSize pointSize;   // 屏幕的逻辑尺寸（点）
static float screenScale;
static id<SKDisplay> display;
static dispatch_queue_t callbackQueue;

static NSString *developerDir(void) {
  NSString *env = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (env.length) return env;
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
  task.arguments = @[ @"-p" ];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  [task launchAndReturnError:nil];
  [task waitUntilExit];
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void openDevice(NSString *udid) {
  udidString = udid;
  if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) fail(@"载入 CoreSimulator 失败");
  if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW)) fail(@"载入 AccessibilityPlatformTranslation 失败");
  NSError *error;
  id ctx = [(id<SKServiceContextClass>)NSClassFromString(@"SimServiceContext") sharedServiceContextForDeveloperDir:developerDir() error:&error];
  if (!ctx) fail([NSString stringWithFormat:@"SimServiceContext：%@", error]);
  id set = [(id<SKServiceContext>)ctx defaultDeviceSetWithError:&error];
  if (!set) fail([NSString stringWithFormat:@"设备集：%@", error]);
  device = [(id<SKDeviceSet>)set devicesByUDID][[[NSUUID alloc] initWithUUIDString:udid]];
  if (!device) fail(@"没有这台模拟器");
  if (device.state != 3) fail([NSString stringWithFormat:@"模拟器没有启动（state %llu）", device.state]);
  id<SKDeviceType> type = device.deviceType;
  screenScale = type.mainScreenScale;
  pointSize = CGSizeMake(type.mainScreenSize.width / screenScale, type.mainScreenSize.height / screenScale);
  callbackQueue = dispatch_queue_create("simio.callbacks", DISPATCH_QUEUE_SERIAL);
}

// MARK: - 画面

static Protocol *protocolNamed(NSString *name) { return NSProtocolFromString(name); }

static void openDisplay(void) {
  if (display) return;
  Protocol *renderable = protocolNamed(@"SimDisplayIOSurfaceRenderable");
  for (id port in [(id<SKDeviceIO>)device.io ioPorts]) {
    id desc = [(id<SKPort>)port descriptor];
    if (!desc || (renderable && ![desc conformsToProtocol:renderable])) continue;
    if (![desc respondsToSelector:@selector(framebufferSurface)]) continue;
    id state = [(id<SKDisplay>)desc state];
    // iOS 的主屏 displayClass 为 0
    if (state && [(id<SKDisplayState>)state displayClass] != 0) continue;
    display = desc;
    return;
  }
  fail(@"找不到主屏");
}

static IOSurfaceRef currentSurface(void) {
  id surface = display.framebufferSurface ?: display.ioSurface;
  return (__bridge IOSurfaceRef)surface;
}

// 帧计数：每呈现一帧回调一次，用来判断画面是否还在变，不必比对图片。
static volatile long frameCount;
static volatile double lastFrameAt;
static double registeredAt, firstCallbackAt;
static BOOL watching;

static void watchFrames(void) {
  if (watching) return;
  openDisplay();
  watching = YES;
  registeredAt = nowMs();
  [display registerScreenCallbacksWithUUID:[NSUUID UUID]
                             callbackQueue:callbackQueue
                             frameCallback:^{
                               frameCount++;
                               lastFrameAt = nowMs();
                               if (firstCallbackAt == 0) firstCallbackAt = lastFrameAt;
                             }
                   surfacesChangedCallback:^(id a, id b) {}
                 propertiesChangedCallback:^(id p) {}];
}

typedef struct { NSData *jpeg; size_t width, height; double lockMs, drawMs, encodeMs; } Capture;

// 按 outScale 缩放（1 为设备像素，1/scale 为逻辑尺寸），quality 为 JPEG 质量。
static Capture capture(double outScale, double quality) {
  openDisplay();
  Capture result = {0};
  IOSurfaceRef surface = currentSurface();
  if (!surface) fail(@"主屏还没有画面");
  double t0 = nowMs();
  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
  size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface), bpr = IOSurfaceGetBytesPerRow(surface);
  OSType format = IOSurfaceGetPixelFormat(surface);
  if (format != 'BGRA') fprintf(stderr, "simio: 像素格式 %08x，不是 BGRA\n", (unsigned)format);
  size_t ow = (size_t)lround(w * outScale), oh = (size_t)lround(h * outScale);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
  CGContextRef ctx = CGBitmapContextCreate(NULL, ow, oh, 8, 0, cs, info);
  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, IOSurfaceGetBaseAddress(surface), bpr * h, NULL);
  CGImageRef source = CGImageCreate(w, h, 8, 32, bpr, cs, info, provider, NULL, false, kCGRenderingIntentDefault);
  double t1 = nowMs();
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, CGRectMake(0, 0, ow, oh), source);
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
  CGImageRelease(source);
  CGDataProviderRelease(provider);
  CGImageRef image = CGBitmapContextCreateImage(ctx);
  double t2 = nowMs();
  NSMutableData *jpeg = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef) @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality)});
  CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(image);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  double t3 = nowMs();
  result.jpeg = jpeg;
  result.width = ow;
  result.height = oh;
  result.lockMs = t1 - t0;
  result.drawMs = t2 - t1;
  result.encodeMs = t3 - t2;
  return result;
}

// 等画面稳定：连续 stableMs 没有新帧算稳定，最多等 maxMs。
static NSDictionary *settle(double stableMs, double maxMs) {
  watchFrames();
  double start = nowMs();
  long startCount = frameCount;
  double firstFrame = -1;
  if (lastFrameAt < start) lastFrameAt = start;  // 从现在起算
  while (nowMs() - start < maxMs) {
    if (firstFrame < 0 && frameCount > startCount) firstFrame = nowMs() - start;
    if (nowMs() - lastFrameAt >= stableMs) break;
    sleepMs(5);
  }
  double waited = nowMs() - start;
  return @{@"settled" : @(waited < maxMs), @"waitedMs" : round1(waited), @"frames" : @(frameCount - startCount),
           @"firstFrameMs" : firstFrame < 0 ? NSNull.null : round1(firstFrame)};
}

// MARK: - 输入（dtuhidd）

static NSString *const kDigitizer = @"com.apple.coredevice.feature.remote.hid.digitizer";
static xpc_connection_t hid;

static xpc_object_t hidMessage(const char *type, xpc_object_t payload, bool barrier) {
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(m, "messageType", type);
  xpc_dictionary_set_bool(m, "isBarrier", barrier);
  xpc_dictionary_set_string(m, "featureIdentifier", kDigitizer.UTF8String);
  xpc_dictionary_set_value(m, "payload", payload);
  return m;
}

static xpc_object_t keyPayload(uint64_t usage, bool down) {
  xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(p, "usageCode", usage);
  xpc_dictionary_set_uint64(p, "state", down ? 1 : 2);
  return p;
}

// 连上后发一个带回复的空按键，回了才算 dtuhidd 真在（服务查得到不代表守护进程起得来）。
static double connectHID(void) {
  if (hid) return 0;
  double start = nowMs();
  EndpointFromPort endpointFromPort = (EndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
  ConnectionFromEndpoint fromEndpoint = (ConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
  EnableSim2Host enableSim2Host = (EnableSim2Host)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  if (!endpointFromPort || !fromEndpoint || !enableSim2Host) fail(@"缺 _4sim 的 XPC 符号");
  for (int attempt = 1; attempt <= 5; attempt++) {
    NSError *error;
    mach_port_t port = [device lookup:kDigitizer error:&error];
    if (port == MACH_PORT_NULL) fail([NSString stringWithFormat:@"查不到 %@：%@", kDigitizer, error]);
    xpc_object_t endpoint = endpointFromPort(port, 0, 0);
    xpc_connection_t connection = fromEndpoint(endpoint);
    enableSim2Host(connection);
    xpc_connection_set_target_queue(connection, callbackQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
      if (event == XPC_ERROR_CONNECTION_INTERRUPTED) fprintf(stderr, "simio: dtuhidd 连接中断\n");
    });
    xpc_connection_resume(connection);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    xpc_connection_send_message_with_reply(connection, hidMessage("IndigoKeyboardButtonEvent", keyPayload(0, false), true), callbackQueue, ^(xpc_object_t r) {
      ok = xpc_get_type(r) != XPC_TYPE_ERROR;
      dispatch_semaphore_signal(answered);
    });
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0 && ok) {
      hid = connection;
      sleepMs(200);  // 对端激活后打开设备的余量
      return nowMs() - start;
    }
    fprintf(stderr, "simio: dtuhidd 没回应（第 %d 次）\n", attempt);
    xpc_connection_cancel(connection);
    sleepMs(4000);
  }
  fail(@"dtuhidd 一直没回应");
  return 0;
}

static void hidSend(const char *type, xpc_object_t payload) {
  connectHID();
  xpc_connection_send_message(hid, hidMessage(type, payload, false));
}

// 等之前发的都交给了内核，再留一点给模拟器里分发。
static void hidFlush(void) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  xpc_connection_send_barrier(hid, ^{ dispatch_semaphore_signal(done); });
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

static xpc_object_t point(CGPoint p) {
  xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(d, "x", p.x / pointSize.width);
  xpc_dictionary_set_double(d, "y", p.y / pointSize.height);
  return d;
}

// phase：0 起、1 移动、2 抬起。
static void touch(CGPoint p, uint64_t phase) {
  xpc_object_t e = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(e, "pointOne", point(p));
  xpc_dictionary_set_uint64(e, "eventType", phase);
  xpc_dictionary_set_uint64(e, "edge", 0);
  xpc_dictionary_set_uint64(e, "target", 0);
  hidSend("IndigoDigitizerEvent", e);
}

static void touch2(CGPoint a, CGPoint b, uint64_t phase) {
  xpc_object_t e = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(e, "pointOne", point(a));
  xpc_dictionary_set_value(e, "pointTwo", point(b));
  xpc_dictionary_set_uint64(e, "eventType", phase);
  xpc_dictionary_set_uint64(e, "edge", 0);
  xpc_dictionary_set_uint64(e, "target", 0);
  hidSend("IndigoDigitizerEvent", e);
}

static void tap(CGPoint p, int count) {
  for (int i = 0; i < count; i++) {
    touch(p, 0);
    sleepMs(50);
    touch(p, 2);
    if (i + 1 < count) sleepMs(80);
  }
  hidFlush();
}

// 拖动：每 16 ms 一个点，hold 是到终点后按住多久再抬起（大于 0 时松手没有惯性）。
static void drag(CGPoint from, CGPoint to, double ms, double hold) {
  touch(from, 0);
  int steps = MAX(1, (int)(ms / 16));
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    sleepMs(16);
    touch(CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t), 1);
  }
  if (hold > 0) {
    for (double held = 0; held < hold; held += 16) {
      sleepMs(16);
      touch(to, 1);
    }
  }
  touch(to, 2);
  hidFlush();
}

static void longPress(CGPoint p, double seconds) {
  touch(p, 0);
  sleepMs(seconds * 1000);
  touch(p, 2);
  hidFlush();
}

// 两指以 center 为中心、横向排开，指距从 d 变到 d*scale。
static void pinch(CGPoint center, double scale) {
  double d0 = scale >= 1 ? 40 : 160, d1 = d0 * scale;
  int steps = 20;
  for (int i = 0; i <= steps; i++) {
    double d = d0 + (d1 - d0) * i / steps;
    touch2(CGPointMake(center.x - d / 2, center.y), CGPointMake(center.x + d / 2, center.y), i == 0 ? 0 : 1);
    sleepMs(16);
  }
  touch2(CGPointMake(center.x - d1 / 2, center.y), CGPointMake(center.x + d1 / 2, center.y), 2);
  hidFlush();
}

static void button(uint64_t page, uint64_t code) {
  xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(p, "usagePage", page);
  xpc_dictionary_set_uint64(p, "usageCode", code);
  xpc_dictionary_set_uint64(p, "state", 1);
  hidSend("IndigoButtonEvent", p);
  sleepMs(50);
  p = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(p, "usagePage", page);
  xpc_dictionary_set_uint64(p, "usageCode", code);
  xpc_dictionary_set_uint64(p, "state", 2);
  hidSend("IndigoButtonEvent", p);
  hidFlush();
}

static void keyEvent(uint64_t usage, bool down) { hidSend("IndigoKeyboardButtonEvent", keyPayload(usage, down)); }

// USB HID 键盘用法码（Keyboard/Keypad 页）。
static NSDictionary<NSString *, NSNumber *> *namedKeys(void) {
  return @{
    @"enter" : @40, @"return" : @40, @"escape" : @41, @"esc" : @41, @"backspace" : @42, @"delete" : @42, @"tab" : @43, @"space" : @44,
    @"right" : @79, @"left" : @80, @"down" : @81, @"up" : @82, @"arrowright" : @79, @"arrowleft" : @80, @"arrowdown" : @81, @"arrowup" : @82,
    @"home" : @74, @"pageup" : @75, @"end" : @77, @"pagedown" : @78,
    @"ctrl" : @224, @"control" : @224, @"shift" : @225, @"alt" : @226, @"option" : @226, @"cmd" : @227, @"meta" : @227, @"command" : @227, @"super" : @227,
  };
}

// 可直接敲的 ASCII：返回用法码，shift 表示要按住 Shift；不支持的返回 0。
static uint64_t asciiUsage(unichar c, bool *shift) {
  *shift = false;
  if (c >= 'a' && c <= 'z') return 4 + (c - 'a');
  if (c >= 'A' && c <= 'Z') { *shift = true; return 4 + (c - 'A'); }
  if (c >= '1' && c <= '9') return 30 + (c - '1');
  if (c == '0') return 39;
  const char *plain = " -=[]\\;',./`\n\t";
  const uint64_t plainCodes[] = {44, 45, 46, 47, 48, 49, 51, 52, 54, 55, 56, 53, 40, 43};
  for (int i = 0; plain[i]; i++) if (c == (unichar)plain[i]) return plainCodes[i];
  const char *shifted = "!@#$%^&*()_+{}|:\"<>?~";
  const uint64_t shiftedCodes[] = {30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 47, 48, 49, 51, 52, 54, 55, 56, 53};
  for (int i = 0; shifted[i]; i++) if (c == (unichar)shifted[i]) { *shift = true; return shiftedCodes[i]; }
  return 0;
}

// 组合键：cmd+a、Control+Shift+Tab 这样的写法。
static BOOL pressCombo(NSString *combo) {
  NSArray *parts = [combo.lowercaseString componentsSeparatedByString:@"+"];
  NSMutableArray<NSNumber *> *codes = [NSMutableArray array];
  for (NSString *part in parts) {
    NSNumber *code = namedKeys()[part];
    if (!code && part.length == 1) {
      bool shift;
      uint64_t u = asciiUsage([part characterAtIndex:0], &shift);
      if (u) code = @(u);
    }
    if (!code) return NO;
    [codes addObject:code];
  }
  for (NSNumber *c in codes) { keyEvent(c.unsignedLongLongValue, true); sleepMs(10); }
  sleepMs(30);
  for (NSNumber *c in codes.reverseObjectEnumerator) { keyEvent(c.unsignedLongLongValue, false); sleepMs(10); }
  hidFlush();
  return YES;
}

// 逐字敲 ASCII；遇到敲不出来的字返回它的位置。
static NSInteger typeASCII(NSString *text) {
  for (NSUInteger i = 0; i < text.length; i++) {
    bool shift;
    uint64_t u = asciiUsage([text characterAtIndex:i], &shift);
    if (!u) return (NSInteger)i;
  }
  for (NSUInteger i = 0; i < text.length; i++) {
    bool shift;
    uint64_t u = asciiUsage([text characterAtIndex:i], &shift);
    if (shift) keyEvent(225, true);
    keyEvent(u, true);
    sleepMs(8);
    keyEvent(u, false);
    if (shift) keyEvent(225, false);
    sleepMs(8);
  }
  hidFlush();
  return -1;
}

// MARK: - 界面结构（AXPTranslator 请求）

enum { AXReqApplication = 1, AXReqFrontmost = 4, AXReqMultiple = 5, AXReqHitTest = 6 };
enum { AXChildren = 8, AXFrame = 21, AXIdentifier = 25, AXEnabled = 27, AXLabel = 33, AXRole = 45, AXSubrole = 51, AXValue = 53, AXTraits = 77, AXRemote = 66, AXPlaceholder = 42 };
static unsigned long long axClient = 0;
static long axRequests;

static id axSendRequest(id req, double timeout);

static id axSend(unsigned long long type, id translation, NSDictionary *params, double timeout) {
  id req = [(id<SKAXRequestClass>)NSClassFromString(@"AXPTranslatorRequest") requestWithTranslation:translation];
  [(id<SKAXRequest>)req setRequestType:type];
  [(id<SKAXRequest>)req setClientType:axClient];
  [(id<SKAXRequest>)req setParameters:params];
  return axSendRequest(req, timeout);
}

static id axSendRequest(id req, double timeout) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block id response;
  axRequests++;
  [device sendAccessibilityRequestAsync:req completionQueue:callbackQueue completionHandler:^(id r) {
    response = r;
    dispatch_semaphore_signal(done);
  }];
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) return nil;
  return response;
}

static NSString *roleName(NSNumber *n, BOOL remote) {
  NSArray *names = @[ @"?", @"Application", @"Button", @"CheckBox", @"GenericElement", @"Group", @"Heading", @"Image", @"Link", @"RadioButton", @"ScrollArea", @"ScrollBar", @"TabGroup", @"Slider", @"StaticText", @"TextField", @"WebArea", @"TextArea", @"Splitter", @"PopUpButton", @"Sheet", @"Grid" ];
  if (remote) return @"Remote";
  NSInteger i = n.integerValue;
  return (i > 0 && i < (NSInteger)names.count) ? names[i] : [NSString stringWithFormat:@"role%ld", (long)i];
}

static long axNodes;
static id hitTranslation(CGPoint p);

static void axWalk(id translation, int depth, NSMutableString *out) {
  NSArray *attrs = @[ @(AXFrame), @(AXRole), @(AXSubrole), @(AXLabel), @(AXValue), @(AXIdentifier), @(AXEnabled), @(AXPlaceholder), @(AXRemote), @(AXChildren) ];
  id resp = axSend(AXReqMultiple, translation, @{@"attributes" : attrs}, 3);
  NSDictionary *values = [resp resultData];
  if (![values isKindOfClass:NSDictionary.class]) {
    [out appendFormat:@"%*s<没有回答>\n", depth * 2, ""];
    return;
  }
  axNodes++;
  NSRect frame = [values[@(AXFrame)] rectValue];
  NSString *label = values[@(AXLabel)], *ident = values[@(AXIdentifier)], *placeholder = values[@(AXPlaceholder)];
  id value = values[@(AXValue)];
  BOOL remote = [values[@(AXRemote)] boolValue];
  [out appendFormat:@"%*s%@", depth * 2, "", roleName(values[@(AXRole)], remote)];
  if ([label isKindOfClass:NSString.class] && label.length) [out appendFormat:@" \"%@\"", label];
  if (value && ![value isKindOfClass:NSNull.class] && [[value description] length]) [out appendFormat:@" value=%@", value];
  if ([placeholder isKindOfClass:NSString.class] && placeholder.length) [out appendFormat:@" placeholder=\"%@\"", placeholder];
  if ([ident isKindOfClass:NSString.class] && ident.length) [out appendFormat:@" id=%@", ident];
  if (values[@(AXEnabled)] && ![values[@(AXEnabled)] boolValue]) [out appendString:@" disabled"];
  [out appendFormat:@" (%.0f,%.0f %.0fx%.0f)\n", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
  for (id child in values[@(AXChildren)]) axWalk(child, depth + 1, out);
}

static NSDictionary *axDump(BOOL print) {
  double start = nowMs();
  axNodes = 0;
  axRequests = 0;
  id resp = axSend(AXReqFrontmost, [NSClassFromString(@"AXPTranslationObject") new], @{@"displayId" : @0}, 5);
  id root = [resp resultData];
  NSString *via = @"frontmost";
  if (!root) {
    // 「最前面的 App」有时回空（重启模拟器后一直如此）：照 idb 的 center-point 办法，命中屏幕中心取进程，再按进程要 App
    id center = hitTranslation(CGPointMake(pointSize.width / 2, pointSize.height / 2));
    if (center) root = [axSend(AXReqApplication, nil, @{@"pid" : @([(id<SKAXObject>)center pid])}, 5) resultData];
    via = @"center-point";
  }
  if (!root) return @{@"error" : @"拿不到最前面的 App"};
  double rootMs = nowMs() - start;
  NSMutableString *out = [NSMutableString string];
  axWalk(root, 0, out);
  if (print) fputs(out.UTF8String, stdout);
  return @{@"nodes" : @(axNodes), @"requests" : @(axRequests), @"rootMs" : round1(rootMs), @"ms" : round1(nowMs() - start), @"pid" : @([(id<SKAXObject>)root pid]), @"via" : via};
}

// 写值要经 AXPTranslator 单例的平台元素，它把读写拆成请求，回调到这里转给模拟器。
@interface SimioTranslatorDelegate : NSObject
@end
@implementation SimioTranslatorDelegate
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  return ^id(id request) {
    [(id<SKAXRequest>)request setClientType:axClient];
    return axSendRequest(request, 3) ?: [NSClassFromString(@"AXPTranslatorResponse") performSelector:@selector(emptyResponse)];
  };
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token { return rect; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }
@end

static id hitTranslation(CGPoint p) {
  id resp = axSend(AXReqHitTest, [NSClassFromString(@"AXPTranslationObject") new], @{@"point" : [NSValue valueWithPoint:NSMakePoint(p.x, p.y)], @"displayId" : @0}, 3);
  return [resp resultData];
}

static NSDictionary *axSetValue(CGPoint p, NSString *text) {
  static SimioTranslatorDelegate *delegate;
  static id<SKAXTranslator> translator;
  if (!translator) {
    delegate = [SimioTranslatorDelegate new];
    translator = [(id<SKAXTranslatorClass>)NSClassFromString(@"AXPTranslator") sharedInstance];
    [translator setSupportsDelegateTokens:YES];
    [translator setBridgeTokenDelegate:delegate];
  }
  double start = nowMs();
  id hit = hitTranslation(p);
  if (!hit) return @{@"error" : @"没有命中"};
  [(id<SKAXObject>)hit setBridgeDelegateToken:@"simio"];
  id<SKAXPlatformElement> element = [translator macPlatformElementFromTranslation:hit];
  if (!element) return @{@"error" : @"拿不到平台元素"};
  [element setAccessibilityValue:text];
  return @{@"ms" : round1(nowMs() - start), @"value" : [[element accessibilityValue] description] ?: NSNull.null};
}

// 网格命中：树里走不到的别的进程的内容（网页、部分系统视图）只能按点命中找出来。
static NSDictionary *axGrid(double step, BOOL print) {
  double start = nowMs();
  NSMutableSet *seen = [NSMutableSet set];
  NSMutableString *out = [NSMutableString string];
  int points = 0;
  for (double y = step / 2; y < pointSize.height; y += step) {
    for (double x = step / 2; x < pointSize.width; x += step) {
      points++;
      id hit = hitTranslation(CGPointMake(x, y));
      if (!hit) continue;
      NSString *key = [NSString stringWithFormat:@"%d-%llu", [(id<SKAXObject>)hit pid], [(id<SKAXObject>)hit objectID]];
      if ([seen containsObject:key]) continue;
      [seen addObject:key];
      NSDictionary *v = [axSend(AXReqMultiple, hit, @{@"attributes" : @[ @(AXFrame), @(AXRole), @(AXLabel), @(AXValue) ]}, 3) resultData];
      NSRect f = [v[@(AXFrame)] rectValue];
      [out appendFormat:@"%@ \"%@\" pid=%d (%.0f,%.0f %.0fx%.0f)\n", roleName(v[@(AXRole)], NO), v[@(AXLabel)] ?: @"", [(id<SKAXObject>)hit pid], f.origin.x, f.origin.y, f.size.width, f.size.height];
    }
  }
  if (print) fputs(out.UTF8String, stdout);
  return @{@"points" : @(points), @"elements" : @(seen.count), @"ms" : round1(nowMs() - start)};
}

static NSDictionary *axHit(CGPoint p) {
  double start = nowMs();
  id resp = axSend(AXReqHitTest, [NSClassFromString(@"AXPTranslationObject") new], @{@"point" : [NSValue valueWithPoint:NSMakePoint(p.x, p.y)], @"displayId" : @0}, 3);
  id hit = [resp resultData];
  if (!hit) return @{@"error" : @"没有命中"};
  NSMutableString *out = [NSMutableString string];
  axNodes = 0;
  NSArray *attrs = @[ @(AXFrame), @(AXRole), @(AXLabel), @(AXValue) ];
  NSDictionary *values = [axSend(AXReqMultiple, hit, @{@"attributes" : attrs}, 3) resultData];
  NSRect f = [values[@(AXFrame)] rectValue];
  [out appendFormat:@"%@ \"%@\" (%.0f,%.0f %.0fx%.0f)", roleName(values[@(AXRole)], NO), values[@(AXLabel)] ?: @"", f.origin.x, f.origin.y, f.size.width, f.size.height];
  return @{@"hit" : out, @"ms" : round1(nowMs() - start)};
}

// MARK: - 命令

static CGPoint pt(NSArray *a, NSUInteger i) { return CGPointMake([a[i] doubleValue], [a[i + 1] doubleValue]); }

// 缩放参数：device 为设备像素，model 为逻辑尺寸（点），数字为相对设备像素的比例。
static double outScaleArg(NSArray<NSString *> *a, NSUInteger i) {
  if (a.count <= i || [a[i] isEqualToString:@"device"]) return 1;
  if ([a[i] isEqualToString:@"model"]) return 1.0 / screenScale;
  return a[i].doubleValue;
}

static void run(NSString *line) {
  NSArray<NSString *> *a = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "];
  NSString *cmd = a.firstObject;
  if (!cmd.length || [cmd hasPrefix:@"#"]) return;
  double start = nowMs();
  NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObject:cmd forKey:@"cmd"];
  if ([cmd isEqualToString:@"info"]) {
    openDisplay();
    IOSurfaceRef s = currentSurface();
    r[@"name"] = device.name;
    r[@"points"] = @[ @(pointSize.width), @(pointSize.height) ];
    r[@"scale"] = @(screenScale);
    r[@"surface"] = @[ @(IOSurfaceGetWidth(s)), @(IOSurfaceGetHeight(s)) ];
  } else if ([cmd isEqualToString:@"frame"]) {
    // frame <路径> [device|model|比例] [质量]
    double scale = outScaleArg(a, 2);
    double quality = a.count > 3 ? a[3].doubleValue : (scale < 1 ? 0.8 : 0.7);
    Capture c = capture(scale, quality);
    [c.jpeg writeToFile:a[1] atomically:NO];
    r[@"size"] = @[ @(c.width), @(c.height) ];
    r[@"bytes"] = @(c.jpeg.length);
    r[@"lockMs"] = round1(c.lockMs);
    r[@"drawMs"] = round1(c.drawMs);
    r[@"encodeMs"] = round1(c.encodeMs);
  } else if ([cmd isEqualToString:@"bench"]) {
    // bench <次数> [device|model|比例] [质量]：连续截帧取平均
    int n = a.count > 1 ? a[1].intValue : 20;
    double scale = outScaleArg(a, 2);
    double quality = a.count > 3 ? a[3].doubleValue : (scale < 1 ? 0.8 : 0.7);
    double total = 0, maxMs = 0;
    size_t bytes = 0;
    for (int i = 0; i < n; i++) {
      double t = nowMs();
      Capture c = capture(scale, quality);
      double ms = nowMs() - t;
      total += ms;
      maxMs = MAX(maxMs, ms);
      bytes = c.jpeg.length;
    }
    r[@"avgMs"] = round1(total / n);
    r[@"maxMs"] = round1(maxMs);
    r[@"bytes"] = @(bytes);
  } else if ([cmd isEqualToString:@"live"]) {
    // live <秒> <间隔毫秒> [device|model|比例] [质量]：模拟实时画面，画面有新帧才截，最多每个间隔一次；报 CPU 时间
    watchFrames();
    double seconds = a.count > 1 ? a[1].doubleValue : 5, interval = a.count > 2 ? a[2].doubleValue : 120;
    double scale = outScaleArg(a, 3);
    double quality = a.count > 4 ? a[4].doubleValue : (scale < 1 ? 0.8 : 0.7);
    struct rusage before, after;
    getrusage(RUSAGE_SELF, &before);
    long seen = frameCount, captures = 0;
    size_t bytes = 0;
    double end = nowMs() + seconds * 1000, captureMs = 0;
    while (nowMs() < end) {
      double tick = nowMs();
      if (frameCount != seen) {
        seen = frameCount;
        Capture c = capture(scale, quality);
        captures++;
        bytes += c.jpeg.length;
        captureMs += nowMs() - tick;
      }
      double rest = interval - (nowMs() - tick);
      if (rest > 0) sleepMs(rest);
    }
    getrusage(RUSAGE_SELF, &after);
    double cpu = (after.ru_utime.tv_sec - before.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_stime.tv_sec) * 1000.0 +
                 (after.ru_utime.tv_usec - before.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1000.0;
    r[@"captures"] = @(captures);
    r[@"avgBytes"] = @(captures ? bytes / captures : 0);
    r[@"avgCaptureMs"] = round1(captures ? captureMs / captures : 0);
    r[@"cpuPercent"] = round1(cpu / (seconds * 1000) * 100);
    r[@"kbPerSecond"] = round1(bytes / 1024.0 / seconds);
  } else if ([cmd isEqualToString:@"watch"]) {
    // watch <秒>：数这段时间呈现了几帧
    BOOL fresh = !watching;
    watchFrames();
    long before = frameCount;
    sleepMs((a.count > 1 ? a[1].doubleValue : 1) * 1000);
    r[@"frames"] = @(frameCount - before);
    if (fresh) r[@"firstCallbackMs"] = firstCallbackAt > 0 ? round1(firstCallbackAt - registeredAt) : NSNull.null;
  } else if ([cmd isEqualToString:@"settle"]) {
    [r addEntriesFromDictionary:settle(300, 3000)];
  } else if ([cmd isEqualToString:@"connect"]) {
    r[@"connectMs"] = round1(connectHID());
  } else if ([cmd isEqualToString:@"tap"]) {
    tap(pt(a, 1), a.count > 3 ? a[3].intValue : 1);
  } else if ([cmd isEqualToString:@"drag"]) {
    drag(pt(a, 1), pt(a, 3), a.count > 5 ? a[5].doubleValue : 300, a.count > 6 ? a[6].doubleValue : 0);
  } else if ([cmd isEqualToString:@"longpress"]) {
    longPress(pt(a, 1), a.count > 3 ? a[3].doubleValue : 1);
  } else if ([cmd isEqualToString:@"pinch"]) {
    pinch(pt(a, 1), a[3].doubleValue);
  } else if ([cmd isEqualToString:@"home"]) {
    button(0x0C, 0x40);
  } else if ([cmd isEqualToString:@"lock"]) {
    button(0x0C, 0x30);
  } else if ([cmd isEqualToString:@"type"]) {
    NSString *text = [line substringFromIndex:MIN(line.length, [line rangeOfString:@"type"].location + 5)];
    NSInteger bad = typeASCII(text);
    if (bad >= 0) r[@"error"] = [NSString stringWithFormat:@"第 %ld 个字敲不出来，改用粘贴", (long)bad];
  } else if ([cmd isEqualToString:@"paste"]) {
    // paste <文字>：经 simctl pbcopy 放进模拟器的剪贴板，再按 Command+V
    NSString *text = [line substringFromIndex:MIN(line.length, [line rangeOfString:@"paste"].location + 6)];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[ @"simctl", @"pbcopy", udidString ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardInput = pipe;
    [task launchAndReturnError:nil];
    [pipe.fileHandleForWriting writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [pipe.fileHandleForWriting closeFile];
    [task waitUntilExit];
    r[@"pbcopyMs"] = round1(nowMs() - start);
    pressCombo(@"cmd+v");
  } else if ([cmd isEqualToString:@"rawkey"]) {
    // rawkey <用法码> <down|up>：单发一个键，测时序
    keyEvent(a[1].longLongValue, [a[2] isEqualToString:@"down"]);
    hidFlush();
  } else if ([cmd isEqualToString:@"key"]) {
    if (!pressCombo(a[1])) r[@"error"] = @"不认识的键";
  } else if ([cmd isEqualToString:@"ax"]) {
    // ax [客户端类型]：打出最前面 App 的树
    if (a.count > 1) axClient = a[1].longLongValue;
    [r addEntriesFromDictionary:axDump(YES)];
  } else if ([cmd isEqualToString:@"axtime"]) {
    if (a.count > 1) axClient = a[1].longLongValue;
    [r addEntriesFromDictionary:axDump(NO)];
  } else if ([cmd isEqualToString:@"setvalue"]) {
    // setvalue x y <文字>：把命中的输入框的值设成这段文字
    NSRange r3 = [line rangeOfString:[NSString stringWithFormat:@"%@ %@ ", a[1], a[2]]];
    [r addEntriesFromDictionary:axSetValue(pt(a, 1), [line substringFromIndex:NSMaxRange(r3)])];
  } else if ([cmd isEqualToString:@"axgrid"]) {
    // axgrid [步长]：按网格逐点命中，列出去重后的元素
    [r addEntriesFromDictionary:axGrid(a.count > 1 ? a[1].doubleValue : 50, YES)];
  } else if ([cmd isEqualToString:@"hit"]) {
    [r addEntriesFromDictionary:axHit(pt(a, 1))];
  } else if ([cmd isEqualToString:@"sleep"]) {
    sleepMs(a[1].doubleValue);
  } else if ([cmd isEqualToString:@"quit"]) {
    exit(0);
  } else {
    r[@"error"] = @"不认识的命令";
  }
  r[@"ms"] = r[@"ms"] ?: round1(nowMs() - start);
  reply(r);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) fail(@"用法：simio <UDID> [命令...]");
    setvbuf(stdout, NULL, _IOLBF, 0);
    openDevice(@(argv[1]));
    if (argc > 2) {
      NSMutableArray *parts = [NSMutableArray array];
      for (int i = 2; i < argc; i++) [parts addObject:@(argv[i])];
      run([parts componentsJoinedByString:@" "]);
      return 0;
    }
    char buffer[65536];
    while (fgets(buffer, sizeof buffer, stdin)) {
      @autoreleasepool {
        NSString *line = [@(buffer) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        @try {
          run(line);
        } @catch (NSException *e) {
          reply(@{@"cmd" : line, @"error" : [NSString stringWithFormat:@"%@: %@", e.name, e.reason]});
        }
      }
    }
  }
  return 0;
}
