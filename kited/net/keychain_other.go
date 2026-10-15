//go:build !darwin

package main

import "errors"

var errNoKeychain = errors.New("受管网络通道只支持 macOS")

func channelKey() (private [32]byte, created bool, err error) { return private, false, errNoKeychain }

func channelPublicKey() (string, error) { return "", errNoKeychain }
