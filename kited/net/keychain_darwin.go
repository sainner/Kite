//go:build darwin

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/crypto/curve25519"
)

const (
	keychainService = "Kite 组网通道"
	keychainAccount = "router-wireguard"
)

// channelKey 取出受管网络通道的 WireGuard 私钥；没有就生成一把存进登录钥匙串，私钥不落任何文件。
// 经系统自带的 security 读写：钥匙串条目只认建它或被允许过的程序，kite-net 每次更新二进制都会变，直接用 Security 框架读
// 会在每台机器上弹窗等人允许，没人看着的机器就一直停在 waitingKey；security 不随更新变。以前由 kite-net 自己建的条目，
// 头一次经 security 读还要允许一次，选「始终允许」以后不再问。条目里存原始 32 字节，security -w 读出来是它的十六进制。
func channelKey() (private [32]byte, err error) {
	read := func() (string, string, int, error) {
		return security([]string{"find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"}, "")
	}
	out, stderr, code, err := read()
	if err != nil {
		return private, err
	}
	if code == 0 {
		return parseChannelKey(out)
	}
	// 44 是找不到条目；其他（钥匙串锁着、被拒绝）不能另建一把，否则路由器登记的公钥就对不上了。
	if code != 44 {
		return private, fmt.Errorf("读钥匙串失败：%s", securityError(stderr, code))
	}
	if _, err := rand.Read(private[:]); err != nil {
		return private, err
	}
	private[0] &= 248
	private[31] = private[31]&127 | 64
	// 私钥经标准输入交给 security 的交互模式，不出现在命令行里；交互模式里命令失败时退出码不一定反映出来，存完读回核对。
	_, addErr, _, err := security([]string{"-i"}, fmt.Sprintf("add-generic-password -s \"%s\" -a \"%s\" -X %s\n",
		keychainService, keychainAccount, hex.EncodeToString(private[:])))
	if err != nil {
		return private, err
	}
	out, stderr, code, err = read()
	if err != nil {
		return private, err
	}
	stored, parseErr := parseChannelKey(out)
	if code != 0 || parseErr != nil || stored != private {
		return private, fmt.Errorf("写钥匙串失败：%s", securityError(addErr+stderr, code))
	}
	return private, nil
}

func parseChannelKey(out string) (private [32]byte, err error) {
	raw, err := hex.DecodeString(strings.TrimSpace(out))
	if err != nil || len(raw) != 32 {
		return private, errors.New("钥匙串里的通道私钥损坏")
	}
	copy(private[:], raw)
	return private, nil
}

func security(args []string, input string) (stdout, stderr string, code int, err error) {
	cmd := exec.Command("/usr/bin/security", args...)
	cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=/usr/bin:/bin"}
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err = cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return out.String(), errOut.String(), exit.ExitCode(), nil
	}
	return out.String(), errOut.String(), 0, err
}

func securityError(stderr string, code int) string {
	if text := strings.TrimSpace(stderr); text != "" {
		return text
	}
	return fmt.Sprintf("security 退出码 %d", code)
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
