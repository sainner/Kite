//go:build darwin

package main

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#include <stdlib.h>

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

// 同一个描述符收几个 notify 键，每来一次写入那个键的 token（网络字节序）。
static int kite_notify_register(const char *name, int *fd, int *token) {
	return notify_register_file_descriptor(name, fd, *fd < 0 ? 0 : NOTIFY_REUSE, token) == NOTIFY_STATUS_OK ? 0 : -1;
}
*/
import "C"

import (
	"encoding/binary"
	"log"
	"os"
	"runtime"
	"unsafe"
)

var powerEvents = make(chan powerEvent, 4)

type powerEvent struct {
	event        string
	notification C.long
}

//export kitePowerEvent
func kitePowerEvent(kind C.int, notification C.long) {
	event := "wake"
	if kind == 1 {
		event = "sleep"
	}
	powerEvents <- powerEvent{event: event, notification: notification}
}

// loginwindow 在登出、重启、关机开始时（系统更新的重启与关机由安装程序）用 notify(3) 广播，登出被某个 App 拦下时广播取消。
// 这几个键不是公开接口，取自 loginwindow 里的字符串；收不到时退回到只有睡眠预告。
var sessionKeys = map[string]string{
	"com.apple.system.loginwindow.logoutInitiated":   "shutdown",
	"com.apple.system.loginwindow.restartinitiated":  "shutdown",
	"com.apple.system.loginwindow.shutdownInitiated": "shutdown",
	"com.apple.system.install.restartinitiated":      "shutdown",
	"com.apple.system.install.shutdowninitiated":     "shutdown",
	"com.apple.system.loginwindow.logoutcancelled":   "stay",
}

// watchSession 把登出、重启、关机的预告与登出取消送进电源事件。
func watchSession() {
	var fd C.int = -1
	events := map[uint32]string{}
	for key, event := range sessionKeys {
		name := C.CString(key)
		var token C.int
		failed := C.kite_notify_register(name, &fd, &token) != 0
		C.free(unsafe.Pointer(name))
		if failed {
			log.Printf("注册 %s 失败，登出、重启、关机前可能不会交出工作区", key)
			continue
		}
		events[uint32(token)] = event
	}
	if fd < 0 {
		return
	}
	go func() {
		file := os.NewFile(uintptr(fd), "notify")
		token := make([]byte, 4)
		for {
			if _, err := file.Read(token); err != nil {
				log.Printf("读取登出预告失败：%v", err)
				return
			}
			if event, ok := events[binary.BigEndian.Uint32(token)]; ok {
				powerEvents <- powerEvent{event: event}
			}
		}
	}()
}

// watchSystemPower 在自己的系统线程上跑 IOKit 的电源通知，连同登出、重启、关机的预告交给 handle：
// sleep 将要睡眠，wake 醒来，shutdown 将要登出、重启或关机，stay 登出被取消。睡眠要在 handle 给的 allow 被调用后才放行，其余的拦不住。
func watchSystemPower(handle func(event string, allow func())) {
	go func() {
		runtime.LockOSThread()
		if C.kite_power_run() != 0 {
			log.Print("注册系统电源通知失败，睡眠前不会交出工作区")
		}
	}()
	watchSession()
	go func() {
		for event := range powerEvents {
			if event.event == "sleep" {
				notification := event.notification
				handle(event.event, func() { C.kite_power_allow(notification) })
			} else {
				handle(event.event, func() {})
			}
		}
	}()
}
