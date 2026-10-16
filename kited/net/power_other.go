//go:build !darwin

package main

// watchSystemPower 只在 macOS 上有；其他系统收不到睡眠与关机预告。
func watchSystemPower(func(event string, allow func())) {}
