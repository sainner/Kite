package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <stdlib.h>

static CFMutableDictionaryRef kite_query(const char *service, const char *account) {
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef s = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
	CFStringRef a = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
	CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(q, kSecAttrService, s);
	CFDictionarySetValue(q, kSecAttrAccount, a);
	CFRelease(s);
	CFRelease(a);
	return q;
}

static OSStatus kite_read(const char *service, const char *account, void *out, int capacity, int *length) {
	CFMutableDictionaryRef q = kite_query(service, account);
	CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef data = NULL;
	OSStatus status = SecItemCopyMatching(q, &data);
	CFRelease(q);
	if (status != errSecSuccess) return status;
	CFIndex n = CFDataGetLength((CFDataRef)data);
	if (n > capacity) { CFRelease(data); return errSecParam; }
	CFDataGetBytes((CFDataRef)data, CFRangeMake(0, n), (UInt8 *)out);
	*length = (int)n;
	CFRelease(data);
	return errSecSuccess;
}

static OSStatus kite_add(const char *service, const char *account, const void *bytes, int length) {
	CFMutableDictionaryRef q = kite_query(service, account);
	CFDataRef d = CFDataCreate(NULL, bytes, length);
	CFDictionarySetValue(q, kSecValueData, d);
	OSStatus status = SecItemAdd(q, NULL);
	CFRelease(d);
	CFRelease(q);
	return status;
}
*/
import "C"

import (
	"crypto/rand"
	"fmt"
	"unsafe"

	"golang.org/x/crypto/curve25519"
)

const keychainService = "Kite 组网通道"

// channelKey 取出通道的 WireGuard 私钥；没有就生成一把存进登录钥匙串。
// 钥匙串条目由本程序创建，访问控制默认只信任创建它的程序，其他程序读取要用户批准；私钥不落任何文件。
func channelKey(account string) (private [32]byte, created bool, err error) {
	cService, cAccount := C.CString(keychainService), C.CString(account)
	defer C.free(unsafe.Pointer(cService))
	defer C.free(unsafe.Pointer(cAccount))
	var length C.int
	status := C.kite_read(cService, cAccount, unsafe.Pointer(&private[0]), 32, &length)
	if status == C.errSecSuccess && length == 32 {
		return private, false, nil
	}
	if status != C.errSecItemNotFound {
		return private, false, fmt.Errorf("读钥匙串失败（OSStatus %d）", int(status))
	}
	if _, err := rand.Read(private[:]); err != nil {
		return private, false, err
	}
	private[0] &= 248
	private[31] = private[31]&127 | 64
	if status := C.kite_add(cService, cAccount, unsafe.Pointer(&private[0]), 32); status != C.errSecSuccess {
		return private, false, fmt.Errorf("写钥匙串失败（OSStatus %d）", int(status))
	}
	return private, true, nil
}

func publicKey(private [32]byte) ([32]byte, error) {
	var public [32]byte
	out, err := curve25519.X25519(private[:], curve25519.Basepoint)
	copy(public[:], out)
	return public, err
}
