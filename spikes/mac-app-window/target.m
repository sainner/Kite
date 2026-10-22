// 实验用的靶子 App：一个窗口，有按钮、输入框和一块画布，收到的点按、按键、滚动都往标准输出写一行，用来判断探针的输入有没有送到。
#import <AppKit/AppKit.h>

static void say(NSString *text) { printf("%s\n", text.UTF8String); fflush(stdout); }

@interface Canvas : NSView
@end
@implementation Canvas
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return NO; }
- (void)drawRect:(NSRect)rect { [[NSColor colorWithCalibratedRed:0.85 green:0.9 blue:1 alpha:1] setFill]; NSRectFill(self.bounds); }
- (NSPoint)at:(NSEvent *)event { return [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDown:(NSEvent *)e { NSPoint p = [self at:e]; say([NSString stringWithFormat:@"canvas down %.0f,%.0f clicks=%ld", p.x, p.y, (long)e.clickCount]); }
- (void)mouseUp:(NSEvent *)e { NSPoint p = [self at:e]; say([NSString stringWithFormat:@"canvas up %.0f,%.0f", p.x, p.y]); }
- (void)mouseDragged:(NSEvent *)e { NSPoint p = [self at:e]; say([NSString stringWithFormat:@"canvas drag %.0f,%.0f", p.x, p.y]); }
- (void)rightMouseDown:(NSEvent *)e { NSPoint p = [self at:e]; say([NSString stringWithFormat:@"canvas right %.0f,%.0f", p.x, p.y]); }
- (void)scrollWheel:(NSEvent *)e { say([NSString stringWithFormat:@"canvas scroll dx=%.1f dy=%.1f precise=%d", e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas]); }
@end

@interface App : NSApplication
@end
@implementation App
- (void)sendEvent:(NSEvent *)event {
  if (event.type != NSEventTypeAppKitDefined && event.type != NSEventTypeSystemDefined && event.type != NSEventTypePeriodic && event.type != NSEventTypeMouseMoved && event.type != NSEventTypeFlagsChanged)
    say([NSString stringWithFormat:@"event type=%lu window=%ld key=%d active=%d at=%.0f,%.0f", (unsigned long)event.type, (long)event.windowNumber, self.keyWindow != nil, self.isActive, event.locationInWindow.x, event.locationInWindow.y]);
  [super sendEvent:event];
}
@end

@interface Delegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property NSWindow *window;
@property NSInteger clicks;
@end
@implementation Delegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 600, 400)
    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"Kite Spike Target";
  NSView *content = self.window.contentView;
  NSButton *button = [NSButton buttonWithTitle:@"点我" target:self action:@selector(pressed:)];
  button.frame = NSMakeRect(20, 350, 100, 32);
  [content addSubview:button];
  NSTextField *field = [NSTextField textFieldWithString:@""];
  field.frame = NSMakeRect(140, 354, 300, 24);
  field.delegate = self;
  [content addSubview:field];
  Canvas *canvas = [[Canvas alloc] initWithFrame:NSMakeRect(20, 20, 560, 310)];
  [content addSubview:canvas];
  [self.window makeKeyAndOrderFront:nil];
  [self.window makeFirstResponder:field];
  if (getenv("TARGET_ACTIVATE")) [NSApp activateIgnoringOtherApps:YES];
  [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { say(@"app active"); }];
  [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { say(@"app inactive"); }];
  say([NSString stringWithFormat:@"ready pid=%d", getpid()]);
}
- (void)pressed:(id)sender { self.clicks++; say([NSString stringWithFormat:@"button %ld", (long)self.clicks]); }
- (void)controlTextDidChange:(NSNotification *)note { say([NSString stringWithFormat:@"text '%@'", ((NSTextField *)note.object).stringValue]); }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
@end

int main(void) {
  @autoreleasepool {
    NSApplication *app = [App sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    Delegate *delegate = [Delegate new];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
