//go:build darwin

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
	"encoding/base64"
	"fmt"
	"unsafe"

	"golang.org/x/crypto/curve25519"
)

const (
	keychainService = "Kite 组网通道"
	keychainAccount = "router-wireguard"
)

// channelKey 取出受管网络通道的 WireGuard 私钥；没有就生成一把存进登录钥匙串。
// 钥匙串条目由创建它的程序独占，其他程序（包括重新编译后签名变了的 kite-net）读取要用户在弹窗里允许；私钥不落任何文件。
func channelKey() (private [32]byte, err error) {
	cService, cAccount := C.CString(keychainService), C.CString(keychainAccount)
	defer C.free(unsafe.Pointer(cService))
	defer C.free(unsafe.Pointer(cAccount))
	var length C.int
	status := C.kite_read(cService, cAccount, unsafe.Pointer(&private[0]), 32, &length)
	if status == C.errSecSuccess && length == 32 {
		return private, nil
	}
	if status != C.errSecItemNotFound {
		return private, fmt.Errorf("读钥匙串失败（OSStatus %d）", int(status))
	}
	if _, err := rand.Read(private[:]); err != nil {
		return private, err
	}
	private[0] &= 248
	private[31] = private[31]&127 | 64
	if status := C.kite_add(cService, cAccount, unsafe.Pointer(&private[0]), 32); status != C.errSecSuccess {
		return private, fmt.Errorf("写钥匙串失败（OSStatus %d）", int(status))
	}
	return private, nil
}

// channelPublicKey 是交给网络管理员登记的公钥（base64）；私钥还没有就先生成。
func channelPublicKey() (string, error) {
	private, err := channelKey()
	if err != nil {
		return "", err
	}
	public, err := curve25519.X25519(private[:], curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(public), nil
}
