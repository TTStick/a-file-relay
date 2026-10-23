#!/bin/bash
# FileSwitch 开发环境:  source scripts/env.sh
export PATH="$HOME/sdk/flutter/bin:$HOME/sdk/go-1.26.9/bin:$PATH"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
# 国内镜像（Flutter 依赖与引擎下载）
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
# 未执行 xcode-select -s 时直接指向 Xcode.app
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$HOME/Library/Android/sdk" ] && export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ] && export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
