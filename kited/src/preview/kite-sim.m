// kite-sim：宿主开的 iOS 模拟器的画面、输入与界面结构，不开 Simulator.app，全用 Xcode 的私有框架（见 simulator-screen.ts）。
// 画面读主屏的 IOSurface 编 JPEG；输入走模拟器里的 dtuhidd（Xcode 27 起旧的 Indigo 输入被丢弃）；界面结构走 AXPTranslator 的请求。
// 做法与实测数据见 spikes/simulator-io/README.md，接口与报文格式参照 facebook/idb（MIT）的 FBSimulatorControl、FBSimulatorAX。
//
// 用法：kite-sim <UDID>，模拟器须已启动。从标准输入逐行读 JSON 命令，按顺序各回一条消息；坐标一律是点。
// 输出是一条条消息：1 字节类型加 4 字节大端长度再加内容，类型 J 是 JSON 文本，B 是紧跟在说明 bytes 的 J 后面的 JPEG。
// 启动失败时往标准错误写一行原因并退出。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <xpc/xpc.h>
#import <dlfcn.h>

// MARK: - 私有接口

@protocol KSServiceContextClass
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
@end
@protocol KSServiceContext
- (id)defaultDeviceSetWithError:(NSError **)error;
@end
@protocol KSDeviceSet
- (NSDictionary *)devicesByUDID;
@end
@protocol KSDevice
- (unsigned long long)state;
- (id)deviceType;
- (id)io;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id))handler;
@end
@protocol KSDeviceType
- (CGSize)mainScreenSize;
- (float)mainScreenScale;
@end
@protocol KSDeviceIO
- (NSArray *)ioPorts;
@end
@protocol KSPort
- (id)descriptor;
@end
@protocol KSDisplay
- (id)framebufferSurface;
- (id)ioSurface;
- (id)state;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(id, id))surfaces propertiesChangedCallback:(void (^)(id))properties;
@end
@protocol KSDisplayState
- (unsigned short)displayClass;
@end
@protocol KSAXRequestClass
+ (id)requestWithTranslation:(id)translation;
@end
@protocol KSAXRequest
- (void)setRequestType:(unsigned long long)type;
- (void)setClientType:(unsigned long long)type;
- (void)setParameters:(NSDictionary *)parameters;
@end
@protocol KSAXResponse
- (id)resultData;
@end
@protocol KSAXObject
- (int)pid;
- (void)setBridgeDelegateToken:(NSString *)token;
@end
@protocol KSAXTranslatorClass
+ (id)sharedInstance;
@end
@protocol KSAXTranslator
- (void)setBridgeTokenDelegate:(id)delegate;
- (void)setSupportsDelegateTokens:(BOOL)supports;
- (id)macPlatformElementFromTranslation:(id)translation;
@end
@protocol KSAXPlatformElement
- (void)setAccessibilityValue:(id)value;
@end

typedef xpc_object_t (*EndpointFromPort)(mach_port_t, uint64_t, uint64_t);
typedef xpc_connection_t (*ConnectionFromEndpoint)(xpc_object_t);
typedef void (*EnableSim2Host)(xpc_connection_t);

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

// MARK: - 设备与画面

static id<KSDevice> device;
static CGSize pointSize;
static float screenScale;
static id<KSDisplay> display;
static dispatch_queue_t callbackQueue;
/** 每呈现一帧加一：没变就不重新编码。回调表示呈现了一帧，不等于像素变了，是否稳定由宿主比对图片。 */
static volatile long frameCount;
/** 上次截给设备、给模型时的帧数；-1 是还没截过。 */
static long capturedAt[2] = {-1, -1};

static NSString *developerDir(void) {
  NSString *env = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (env.length) return env;
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
  task.arguments = @[ @"-p" ];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  if (![task launchAndReturnError:nil]) return @"/Applications/Xcode.app/Contents/Developer";
  [task waitUntilExit];
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void openDevice(NSString *udid) {
  if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) fatal(@"载入 CoreSimulator 失败，需要 Xcode");
  dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW);
  NSError *error;
  id context = [(id<KSServiceContextClass>)NSClassFromString(@"SimServiceContext") sharedServiceContextForDeveloperDir:developerDir() error:&error];
  if (!context) fatal([NSString stringWithFormat:@"连不上 CoreSimulator：%@", error.localizedDescription]);
  id set = [(id<KSServiceContext>)context defaultDeviceSetWithError:&error];
  if (!set) fatal([NSString stringWithFormat:@"读不到模拟器列表：%@", error.localizedDescription]);
  device = [(id<KSDeviceSet>)set devicesByUDID][[[NSUUID alloc] initWithUUIDString:udid]];
  if (!device) fatal(@"没有这台模拟器");
  if (device.state != 3) fatal(@"模拟器没有启动");
  id<KSDeviceType> type = device.deviceType;
  screenScale = type.mainScreenScale;
  pointSize = CGSizeMake(type.mainScreenSize.width / screenScale, type.mainScreenSize.height / screenScale);
  callbackQueue = dispatch_queue_create("kite-sim.callbacks", DISPATCH_QUEUE_SERIAL);
  // 主屏：displayClass 为 0 的显示描述符
  Protocol *renderable = NSProtocolFromString(@"SimDisplayIOSurfaceRenderable");
  for (id port in [(id<KSDeviceIO>)device.io ioPorts]) {
    id descriptor = [(id<KSPort>)port descriptor];
    if (!descriptor || (renderable && ![descriptor conformsToProtocol:renderable]) || ![descriptor respondsToSelector:@selector(framebufferSurface)]) continue;
    id state = [(id<KSDisplay>)descriptor state];
    if (state && [(id<KSDisplayState>)state displayClass] != 0) continue;
    display = descriptor;
    break;
  }
  if (!display) fatal(@"找不到模拟器的主屏");
  // 回调要一开始就注册：注册后要等真正呈现了一帧才有第一次回调
  [display registerScreenCallbacksWithUUID:[NSUUID UUID] callbackQueue:callbackQueue frameCallback:^{ frameCount++; }
                   surfacesChangedCallback:^(id a, id b) { frameCount++; } propertiesChangedCallback:^(id p) {}];
}

/** 截一帧：forModel 时按逻辑尺寸（点），否则按设备像素的一半，在设备上看够清楚、体积是全尺寸的三分之一。 */
static NSData *capture(BOOL forModel) {
  id surfaceObject = display.framebufferSurface ?: display.ioSurface;
  IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceObject;
  if (!surface) return nil;
  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
  size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface), bpr = IOSurfaceGetBytesPerRow(surface);
  double scale = forModel ? 1.0 / screenScale : 0.5;
  size_t ow = (size_t)lround(w * scale), oh = (size_t)lround(h * scale);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
  CGContextRef context = CGBitmapContextCreate(NULL, ow, oh, 8, 0, space, info);
  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, IOSurfaceGetBaseAddress(surface), bpr * h, NULL);
  CGImageRef source = CGImageCreate(w, h, 8, 32, bpr, space, info, provider, NULL, false, kCGRenderingIntentDefault);
  CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  CGContextDrawImage(context, CGRectMake(0, 0, ow, oh), source);
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
  CGImageRelease(source);
  CGDataProviderRelease(provider);
  CGImageRef image = CGBitmapContextCreateImage(context);
  NSMutableData *jpeg = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
  CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef) @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(forModel ? 0.7 : 0.6)});
  CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(image);
  CGContextRelease(context);
  CGColorSpaceRelease(space);
  return jpeg;
}

// MARK: - 输入（dtuhidd）

static NSString *const kDigitizer = @"com.apple.coredevice.feature.remote.hid.digitizer";
static xpc_connection_t hid;
static NSString *hidError;
static dispatch_group_t hidReady;
static CGPoint lastTap = {-1, -1};

static xpc_object_t hidMessage(const char *type, xpc_object_t payload, bool barrier) {
  xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(message, "messageType", type);
  xpc_dictionary_set_bool(message, "isBarrier", barrier);
  xpc_dictionary_set_string(message, "featureIdentifier", kDigitizer.UTF8String);
  xpc_dictionary_set_value(message, "payload", payload);
  return message;
}

static xpc_object_t keyPayload(uint64_t usage, bool down) {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
  return payload;
}

/**
 * 连上 dtuhidd：冷启动要 2–8 秒，在后台连，输入等它。连上后先发一个要回复的空按键，回了才算它真在；
 * 刚连上的第一个输入多半会丢，再等一秒才交给输入用。
 */
static void connectHID(void) {
  EndpointFromPort endpointFromPort = (EndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
  ConnectionFromEndpoint fromEndpoint = (ConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
  EnableSim2Host enableSim2Host = (EnableSim2Host)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  if (!endpointFromPort || !fromEndpoint || !enableSim2Host) { hidError = @"这个版本的系统缺模拟器输入要用的接口"; return; }
  for (int attempt = 1; attempt <= 5; attempt++) {
    NSError *error;
    mach_port_t port = [device lookup:kDigitizer error:&error];
    if (port == MACH_PORT_NULL) { hidError = [NSString stringWithFormat:@"模拟器里没有输入服务：%@", error.localizedDescription]; return; }
    xpc_connection_t connection = fromEndpoint(endpointFromPort(port, 0, 0));
    enableSim2Host(connection);
    xpc_connection_set_target_queue(connection, callbackQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
    xpc_connection_resume(connection);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    xpc_connection_send_message_with_reply(connection, hidMessage("IndigoKeyboardButtonEvent", keyPayload(0, false), true), callbackQueue, ^(xpc_object_t response) {
      ok = xpc_get_type(response) != XPC_TYPE_ERROR;
      dispatch_semaphore_signal(answered);
    });
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0 && ok) {
      sleepMs(1000);
      hid = connection;
      return;
    }
    xpc_connection_cancel(connection);
    sleepMs(3000);
  }
  hidError = @"模拟器的输入服务一直没有回应";
}

/** 等输入连好；连不上时返回原因。 */
static NSString *waitHID(void) {
  dispatch_group_wait(hidReady, DISPATCH_TIME_FOREVER);
  return hid ? nil : (hidError ?: @"模拟器的输入没有连上");
}

static void hidSend(const char *type, xpc_object_t payload) { xpc_connection_send_message(hid, hidMessage(type, payload, false)); }

/** 等之前发的都交给了模拟器。 */
static void hidFlush(void) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  xpc_connection_send_barrier(hid, ^{ dispatch_semaphore_signal(done); });
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

static CGPoint clamp(CGPoint p) {
  return CGPointMake(MIN(MAX(p.x, 0), pointSize.width - 1), MIN(MAX(p.y, 0), pointSize.height - 1));
}

/** 坐标按屏幕点数归一化。 */
static xpc_object_t pointValue(CGPoint p) {
  xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(value, "x", p.x / pointSize.width);
  xpc_dictionary_set_double(value, "y", p.y / pointSize.height);
  return value;
}

/** phase：0 按下、1 移动、2 抬起；b 是第二根手指，捏合用。 */
static void touch(CGPoint a, const CGPoint *b, uint64_t phase) {
  xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(event, "pointOne", pointValue(clamp(a)));
  if (b) xpc_dictionary_set_value(event, "pointTwo", pointValue(clamp(*b)));
  xpc_dictionary_set_uint64(event, "eventType", phase);
  xpc_dictionary_set_uint64(event, "edge", 0);
  xpc_dictionary_set_uint64(event, "target", 0);
  hidSend("IndigoDigitizerEvent", event);
}

static void tap(CGPoint p, int count) {
  lastTap = p;
  for (int i = 0; i < count; i++) {
    touch(p, NULL, 0);
    sleepMs(50);
    touch(p, NULL, 2);
    if (i + 1 < count) sleepMs(80);
  }
  hidFlush();
}

/** 拖动：每 16 ms 一个点；hold 是到终点后按住多久再抬起，大于 0 时松手没有惯性。 */
static void drag(CGPoint from, CGPoint to, double ms, double hold) {
  touch(from, NULL, 0);
  int steps = MAX(1, (int)(ms / 16));
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    sleepMs(16);
    touch(CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t), NULL, 1);
  }
  for (double held = 0; held < hold; held += 16) {
    sleepMs(16);
    touch(to, NULL, 1);
  }
  touch(to, NULL, 2);
  hidFlush();
}

static void longPress(CGPoint p, double seconds) {
  lastTap = p;
  touch(p, NULL, 0);
  sleepMs(seconds * 1000);
  touch(p, NULL, 2);
  hidFlush();
}

/** 两指以 center 为中心横向排开，指距从 d 变到 d*scale。 */
static void pinch(CGPoint center, double scale) {
  double d0 = scale >= 1 ? 40 : 160, d1 = d0 * scale;
  for (int i = 0; i <= 20; i++) {
    double d = d0 + (d1 - d0) * i / 20;
    CGPoint b = CGPointMake(center.x + d / 2, center.y);
    touch(CGPointMake(center.x - d / 2, center.y), &b, i == 0 ? 0 : 1);
    sleepMs(16);
  }
  CGPoint b = CGPointMake(center.x + d1 / 2, center.y);
  touch(CGPointMake(center.x - d1 / 2, center.y), &b, 2);
  hidFlush();
}

static void homeButton(void) {
  for (int state = 1; state <= 2; state++) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usagePage", 0x0C);
    xpc_dictionary_set_uint64(payload, "usageCode", 0x40);
    xpc_dictionary_set_uint64(payload, "state", state);
    hidSend("IndigoButtonEvent", payload);
    if (state == 1) sleepMs(50);
  }
  hidFlush();
}

static void keyEvent(uint64_t usage, bool down) { hidSend("IndigoKeyboardButtonEvent", keyPayload(usage, down)); }

/** USB HID 键盘用法码（Keyboard/Keypad 页），键名照 Playwright 的小写（别的写法 kited 解析动作时已统一）。 */
static NSDictionary<NSString *, NSNumber *> *namedKeys(void) {
  return @{
    @"enter" : @40, @"escape" : @41, @"backspace" : @42, @"delete" : @76, @"tab" : @43, @"space" : @44,
    @"arrowright" : @79, @"arrowleft" : @80, @"arrowdown" : @81, @"arrowup" : @82,
    @"home" : @74, @"pageup" : @75, @"end" : @77, @"pagedown" : @78,
    @"control" : @224, @"shift" : @225, @"alt" : @226, @"meta" : @227,
  };
}

/** 能直接敲的 ASCII 的用法码，shift 表示要按住 Shift；敲不出来的返回 0。 */
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

/** 组合键：Control+A、cmd+shift+tab 这样的写法。 */
static BOOL pressCombo(NSString *combo) {
  NSMutableArray<NSNumber *> *codes = [NSMutableArray array];
  for (NSString *part in [combo.lowercaseString componentsSeparatedByString:@"+"]) {
    NSNumber *code = namedKeys()[part];
    if (!code && part.length == 1) {
      bool shift;
      uint64_t usage = asciiUsage([part characterAtIndex:0], &shift);
      if (usage) code = @(usage);
    }
    if (!code) return NO;
    [codes addObject:code];
  }
  for (NSNumber *code in codes) { keyEvent(code.unsignedLongLongValue, true); sleepMs(10); }
  sleepMs(30);
  for (NSNumber *code in codes.reverseObjectEnumerator) { keyEvent(code.unsignedLongLongValue, false); sleepMs(10); }
  hidFlush();
  return YES;
}

static BOOL isASCII(NSString *text) {
  for (NSUInteger i = 0; i < text.length; i++) {
    bool shift;
    if (!asciiUsage([text characterAtIndex:i], &shift)) return NO;
  }
  return YES;
}

static void typeASCII(NSString *text) {
  for (NSUInteger i = 0; i < text.length; i++) {
    bool shift;
    uint64_t usage = asciiUsage([text characterAtIndex:i], &shift);
    if (shift) keyEvent(225, true);
    keyEvent(usage, true);
    sleepMs(8);
    keyEvent(usage, false);
    if (shift) keyEvent(225, false);
    sleepMs(8);
  }
  hidFlush();
}

// MARK: - 界面结构（AXPTranslator 请求）

enum { AXReqApplication = 1, AXReqFrontmost = 4, AXReqMultiple = 5, AXReqHitTest = 6 };
enum { AXChildren = 8, AXFrame = 21, AXIdentifier = 25, AXEnabled = 27, AXLabel = 33, AXRole = 45, AXValue = 53, AXRemote = 66, AXPlaceholder = 42 };
enum { RoleTextField = 15, RoleTextArea = 17 };

static id axSendRequest(id request, double timeout) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block id response;
  [device sendAccessibilityRequestAsync:request completionQueue:callbackQueue completionHandler:^(id r) {
    response = r;
    dispatch_semaphore_signal(done);
  }];
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) return nil;
  return response;
}

static id axSend(unsigned long long type, id translation, NSDictionary *parameters, double timeout) {
  id request = [(id<KSAXRequestClass>)NSClassFromString(@"AXPTranslatorRequest") requestWithTranslation:translation];
  [(id<KSAXRequest>)request setRequestType:type];
  [(id<KSAXRequest>)request setClientType:0];
  [(id<KSAXRequest>)request setParameters:parameters];
  return [axSendRequest(request, timeout) resultData];
}

static NSString *roleName(NSNumber *n) {
  NSArray *names = @[ @"?", @"Application", @"Button", @"CheckBox", @"GenericElement", @"Group", @"Heading", @"Image", @"Link", @"RadioButton", @"ScrollArea",
                      @"ScrollBar", @"TabGroup", @"Slider", @"StaticText", @"TextField", @"WebArea", @"TextArea", @"Splitter", @"PopUpButton", @"Sheet", @"Grid" ];
  NSInteger i = n.integerValue;
  return (i > 0 && i < (NSInteger)names.count) ? names[i] : [NSString stringWithFormat:@"role%ld", (long)i];
}

static id hitTranslation(CGPoint p) {
  return axSend(AXReqHitTest, [NSClassFromString(@"AXPTranslationObject") new], @{@"point" : [NSValue valueWithPoint:NSMakePoint(p.x, p.y)], @"displayId" : @0}, 3);
}

static void axWalk(id translation, int depth, NSMutableString *out, int *budget) {
  if (--*budget < 0) return;
  NSArray *attributes = @[ @(AXFrame), @(AXRole), @(AXLabel), @(AXValue), @(AXIdentifier), @(AXEnabled), @(AXPlaceholder), @(AXRemote), @(AXChildren) ];
  NSDictionary *values = axSend(AXReqMultiple, translation, @{@"attributes" : attributes}, 3);
  if (![values isKindOfClass:NSDictionary.class]) return;
  NSRect frame = [values[@(AXFrame)] rectValue];
  NSString *label = values[@(AXLabel)], *identifier = values[@(AXIdentifier)], *placeholder = values[@(AXPlaceholder)];
  id value = values[@(AXValue)];
  [out appendFormat:@"%*s%@", depth * 2, "", [values[@(AXRemote)] boolValue] ? @"Remote" : roleName(values[@(AXRole)])];
  if ([label isKindOfClass:NSString.class] && label.length) [out appendFormat:@" \"%@\"", label];
  if (value && ![value isKindOfClass:NSNull.class] && [[value description] length]) [out appendFormat:@" value=%@", value];
  if ([placeholder isKindOfClass:NSString.class] && placeholder.length) [out appendFormat:@" placeholder=\"%@\"", placeholder];
  if ([identifier isKindOfClass:NSString.class] && identifier.length) [out appendFormat:@" id=%@", identifier];
  if (values[@(AXEnabled)] && ![values[@(AXEnabled)] boolValue]) [out appendString:@" disabled"];
  [out appendFormat:@" (%.0f,%.0f %.0fx%.0f)\n", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
  for (id child in values[@(AXChildren)]) axWalk(child, depth + 1, out, budget);
}

/** 最前面的 App 的元素树，一行一个元素：角色、标签、值、位置（点）。最前面的 App 取不到时命中屏幕中心取进程再按进程取（同 idb）。 */
static NSString *axTree(void) {
  id root = axSend(AXReqFrontmost, [NSClassFromString(@"AXPTranslationObject") new], @{@"displayId" : @0}, 5);
  if (!root) {
    id center = hitTranslation(CGPointMake(pointSize.width / 2, pointSize.height / 2));
    if (center) root = axSend(AXReqApplication, nil, @{@"pid" : @([(id<KSAXObject>)center pid])}, 5);
  }
  if (!root) return nil;
  NSMutableString *out = [NSMutableString string];
  int budget = 500;
  axWalk(root, 0, out, &budget);
  return out;
}

// 写值要经 AXPTranslator 单例的平台元素：它把读写拆成请求，回调到这里转给模拟器。
@interface KiteSimTranslatorDelegate : NSObject
@end
@implementation KiteSimTranslatorDelegate
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  return ^id(id request) {
    [(id<KSAXRequest>)request setClientType:0];
    return axSendRequest(request, 3) ?: [NSClassFromString(@"AXPTranslatorResponse") performSelector:@selector(emptyResponse)];
  };
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token { return rect; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }
@end

/**
 * 往最近点过的输入框里追加文字：经无障碍接口直接写值，不经键盘，中文、emoji 和空格都写得进去，也不受模拟器当前输入法影响。
 * 最近点的不是输入框时返回 NO。
 */
static BOOL appendToField(NSString *text) {
  static KiteSimTranslatorDelegate *delegate;
  static id<KSAXTranslator> translator;
  if (lastTap.x < 0) return NO;
  id hit = hitTranslation(lastTap);
  if (!hit) return NO;
  NSDictionary *values = axSend(AXReqMultiple, hit, @{@"attributes" : @[ @(AXRole), @(AXValue), @(AXPlaceholder) ]}, 3);
  NSInteger role = [values[@(AXRole)] integerValue];
  if (role != RoleTextField && role != RoleTextArea) return NO;
  if (!translator) {
    delegate = [KiteSimTranslatorDelegate new];
    translator = [(id<KSAXTranslatorClass>)NSClassFromString(@"AXPTranslator") sharedInstance];
    [translator setSupportsDelegateTokens:YES];
    [translator setBridgeTokenDelegate:delegate];
  }
  [(id<KSAXObject>)hit setBridgeDelegateToken:@"kite-sim"];
  id<KSAXPlatformElement> element = [translator macPlatformElementFromTranslation:hit];
  if (!element) return NO;
  // 空输入框的值读出来是占位文字
  id current = values[@(AXValue)], placeholder = values[@(AXPlaceholder)];
  NSString *before = [current isKindOfClass:NSString.class] && ![current isEqual:placeholder] ? current : @"";
  [element setAccessibilityValue:[before stringByAppendingString:text]];
  return YES;
}

// MARK: - 命令

static CGPoint pointOf(NSDictionary *object) { return CGPointMake([object[@"x"] doubleValue], [object[@"y"] doubleValue]); }

static void run(NSDictionary *command) {
  NSString *cmd = command[@"cmd"];
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:command[@"id"] ?: @0 forKey:@"id"];
  if ([cmd isEqualToString:@"frame"]) {
    BOOL forModel = [command[@"model"] boolValue];
    long count = frameCount;
    // 上次截过之后没有呈现过新的一帧：画面没变，宿主用上次那帧
    if ([command[@"cached"] boolValue] && capturedAt[forModel] == count) { result[@"unchanged"] = @YES; reply(result); return; }
    NSData *jpeg = capture(forModel);
    if (!jpeg) { result[@"error"] = @"模拟器的主屏还没有画面"; reply(result); return; }
    capturedAt[forModel] = count;
    result[@"width"] = @(pointSize.width);
    result[@"height"] = @(pointSize.height);
    result[@"bytes"] = @(jpeg.length);
    reply(result);
    emit('B', jpeg);
    return;
  }
  if ([cmd isEqualToString:@"info"]) {
    result[@"width"] = @(pointSize.width);
    result[@"height"] = @(pointSize.height);
    result[@"scale"] = @(screenScale);
  } else if ([cmd isEqualToString:@"ax"]) {
    NSString *tree = axTree();
    if (tree) result[@"text"] = tree; else result[@"error"] = @"读不到界面结构";
  } else if ([@[ @"tap", @"drag", @"scroll", @"longpress", @"pinch", @"home", @"key", @"type" ] containsObject:cmd]) {
    NSString *error = waitHID();
    if (error) { result[@"error"] = error; reply(result); return; }
    if ([cmd isEqualToString:@"tap"]) tap(pointOf(command), MAX(1, [command[@"count"] intValue]));
    else if ([cmd isEqualToString:@"drag"]) drag(pointOf(command[@"from"]), pointOf(command[@"to"]), 300, 0);
    else if ([cmd isEqualToString:@"scroll"]) {
      // 滚动：手指往反方向慢拖、到终点停住再松手，没有惯性，滚多少就是多少
      CGPoint from = pointOf(command);
      drag(from, clamp(CGPointMake(from.x - [command[@"dx"] doubleValue], from.y - [command[@"dy"] doubleValue])), 400, 100);
    } else if ([cmd isEqualToString:@"longpress"]) longPress(pointOf(command), command[@"seconds"] ? [command[@"seconds"] doubleValue] : 1);
    else if ([cmd isEqualToString:@"pinch"]) pinch(pointOf(command), [command[@"scale"] doubleValue]);
    else if ([cmd isEqualToString:@"home"]) homeButton();
    else if ([cmd isEqualToString:@"key"]) { if (!pressCombo(command[@"key"] ?: @"")) result[@"error"] = @"不认识这个键"; }
    else {
      NSString *text = command[@"text"] ?: @"";
      if (!appendToField(text)) {
        if (isASCII(text)) typeASCII(text);
        else result[@"error"] = @"先点一下要输入的框，再输入中文或符号";
      }
    }
  } else {
    result[@"error"] = @"不认识的命令";
  }
  reply(result);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) fatal(@"用法：kite-sim <UDID>");
    openDevice(@(argv[1]));
    // 模拟器在 Kite 之外被关掉、重启时，手上的主屏和输入连接都失效了：退出，宿主下次要用时重新启动、重开
    dispatch_source_t watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(watch, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(watch, ^{ if (device.state != 3) fatal(@"模拟器关机了"); });
    dispatch_resume(watch);
    hidReady = dispatch_group_create();
    dispatch_group_async(hidReady, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ connectHID(); });
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
