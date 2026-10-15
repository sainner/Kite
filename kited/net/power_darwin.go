//go:build darwin

package main

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>

extern void kitePowerEvent(int kind, long notification);

static io_connect_t kite_root;
static IONotificationPortRef kite_port;
static io_object_t kite_notifier;

static void kite_power_callback(void *refcon, io_service_t service, natural_t type, void *argument) {
	switch (type) {
	case kIOMessageCanSystemSleep:
		// 空闲睡眠先问能不能睡：不拦，真要睡时会再收到 WillSleep。
		IOAllowPowerChange(kite_root, (long)argument);
		break;
	case kIOMessageSystemWillSleep:
		kitePowerEvent(1, (long)argument);
		break;
	case kIOMessageSystemHasPoweredOn:
		kitePowerEvent(2, 0);
		break;
	}
}

static int kite_power_run(void) {
	kite_root = IORegisterForSystemPower(NULL, &kite_port, kite_power_callback, &kite_notifier);
	if (kite_root == 0) return -1;
	CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(kite_port), kCFRunLoopCommonModes);
	CFRunLoopRun();
	return 0;
}

static void kite_power_allow(long notification) { IOAllowPowerChange(kite_root, notification); }
*/
import "C"

import (
	"log"
	"runtime"
)

var powerEvents = make(chan powerEvent, 4)

type powerEvent struct {
	sleep        bool
	notification C.long
}

//export kitePowerEvent
func kitePowerEvent(kind C.int, notification C.long) {
	powerEvents <- powerEvent{sleep: kind == 1, notification: notification}
}

// watchSystemPower 在自己的系统线程上跑 IOKit 的电源通知，事件交给 handle；睡眠事件要在 handle 给的 allow 被调用后才放行。
func watchSystemPower(handle func(sleep bool, allow func())) {
	go func() {
		runtime.LockOSThread()
		if C.kite_power_run() != 0 {
			log.Print("注册系统电源通知失败，睡眠前不会交出工作区")
		}
	}()
	go func() {
		for event := range powerEvents {
			if event.sleep {
				notification := event.notification
				handle(true, func() { C.kite_power_allow(notification) })
			} else {
				handle(false, func() {})
			}
		}
	}()
}
