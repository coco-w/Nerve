#!/bin/sh
set -eu

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# 按安装包自带的程序设置入口，只在安装 Daemon 时注册 Agent。
if [ -f "$bundle_dir/nerve" ]; then
  program=nerve
  if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 1 ] || [ "$1" != '--no-agents' ]; then
      printf '用法为 ./install.sh [--no-agents]\n' >&2
      exit 1
    fi
  fi
elif [ -f "$bundle_dir/nerve-gateway" ]; then
  program=nerve-gateway
  if [ "$#" -ne 0 ]; then
    printf '用法为 ./install.sh\n' >&2
    exit 1
  fi
else
  printf '安装包中缺少 Nerve 可执行文件\n' >&2
  exit 1
fi

# NERVE_INSTALL_DIR 可指定安装位置，临时文件与目标同目录以便原子替换。
install_dir=${NERVE_INSTALL_DIR:-"$HOME/.local/bin"}
mkdir -p -- "$install_dir"
install_dir=$(CDPATH= cd -- "$install_dir" && pwd)
destination="$install_dir/$program"
if [ -d "$destination" ]; then
  printf '安装目标已是目录 %s\n' "$destination" >&2
  exit 1
fi
temporary=$(mktemp "$install_dir/.$program.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
install -m 755 -- "$bundle_dir/$program" "$temporary"
mv -f -- "$temporary" "$destination"
printf '已安装 %s\n' "$destination"
if [ "$program" = nerve ] && [ "$#" -eq 0 ]; then
  "$destination" setup-agents
fi
