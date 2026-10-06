#!/bin/bash
# 双击只打包，不安装或启动服务。
exec "$(cd "$(dirname "$0")" && pwd)/install.command" --package "$@"
