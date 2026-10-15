//go:build !darwin

package main

// watchSystemPower 只在 macOS 上有；其他系统收不到睡眠预告。
func watchSystemPower(func(sleep bool, allow func())) {}
