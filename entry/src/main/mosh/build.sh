#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# 固定 Go 编译器与 JS 运行时的版本，普通 HAP 构建直接使用已打包的资源。
export GOTOOLCHAIN=go1.26.11
export GOOS=js GOARCH=wasm CGO_ENABLED=0
vendor=../resources/rawfile/terminal/vendor
licenses=../resources/rawfile/licenses
go build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w" -o "$vendor/nerve-mosh.wasm" .
go_root=$(go env GOROOT)
install -m 644 "$go_root/lib/wasm/wasm_exec.js" "$vendor/go-wasm-exec.js"
install -m 644 "$go_root/LICENSE" "$licenses/go-LICENSE"
install -m 644 internal/protocol/LICENSE "$licenses/mosh-go-LICENSE"
