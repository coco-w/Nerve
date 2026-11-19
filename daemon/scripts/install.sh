#!/bin/sh
set -eu

# 默认配置当前账号的 Agent。指定 --no-agents 时只安装程序。
setup_agents=1
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 1 ] || [ "$1" != '--no-agents' ]; then
    printf '用法为 ./install.sh [--no-agents]\n' >&2
    exit 1
  fi
  setup_agents=0
fi

# NERVE_INSTALL_DIR 可指定安装位置，临时文件与目标同目录以便原子替换。
install_dir=${NERVE_INSTALL_DIR:-"$HOME/.local/bin"}
bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$install_dir"
install_dir=$(CDPATH= cd -- "$install_dir" && pwd)
destination="$install_dir/nerve"
if [ -d "$destination" ]; then
  printf '安装目标已是目录 %s\n' "$destination" >&2
  exit 1
fi
temporary=$(mktemp "$install_dir/.nerve.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
install -m 755 -- "$bundle_dir/nerve" "$temporary"
mv -f -- "$temporary" "$destination"
printf '已安装 %s\n' "$destination"
if [ "$setup_agents" -eq 1 ]; then
  "$destination" setup-agents
fi
