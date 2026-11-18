#!/bin/sh
# omp Desk 一键安装：在仓库目录执行 omp sh install.sh（Windows 也可运行 install.ps1）
set -e

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ID="omp-desk"
EXT_NAME="compact-tools.ts"
STAMP=$(date +%Y%m%d%H%M%S)

command -v omp >/dev/null 2>&1 || { echo "未找到 omp，请先安装 Tern（自带 omp）"; exit 1; }
jq -n 1 >/dev/null 2>&1 || { echo "缺少 jq，请用 omp sh install.sh 运行"; exit 1; }

IS_WIN=0
case "$(uname -s)" in
MSYS*|MINGW*|CYGWIN*) IS_WIN=1 ;;
esac

AGENT_DIR=$(omp config path | tr '\\' '/')

echo "== omp 配置：$AGENT_DIR =="
while read -r key value; do
	case "$key" in
	''|\#*) continue ;;
	modelRoles.*)
		role=${key#modelRoles.}
		roles=$(omp config get modelRoles --json </dev/null | jq -c --arg r "$role" --arg m "$value" '(.value // {}) | .[$r] = $m')
		omp config set modelRoles "$roles" </dev/null
		;;
	*)
		omp config set "$key" "$value" </dev/null
		;;
	esac
done < "$REPO_DIR/omp/settings.txt"

if [ "$IS_WIN" = 1 ]; then
	cur_shell=$(omp config get shellPath --json | jq -r '.value // empty')
	if [ -n "$cur_shell" ]; then
		echo "保留已有 shellPath：$cur_shell"
	else
		git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##')
		if [ -n "$git_root" ] && [ -f "$git_root/bin/bash.exe" ]; then
			omp config set shellPath "$(printf '%s' "$git_root/bin/bash.exe" | tr '/' '\\')"
		else
			echo "未找到 Git Bash，跳过 shellPath"
		fi
	fi
fi

echo "== omp 扩展 =="
mkdir -p "$AGENT_DIR/extensions"
dst="$AGENT_DIR/extensions/$EXT_NAME"
if [ -f "$dst" ] && ! cmp -s "$REPO_DIR/omp/extensions/$EXT_NAME" "$dst"; then
	cp "$dst" "$dst.bak"
	echo "已备份原文件：$dst.bak"
fi
cp "$REPO_DIR/omp/extensions/$EXT_NAME" "$dst"
echo "已安装：$dst"

echo "== omp 快捷键 =="
kb="$AGENT_DIR/keybindings.yml"
touch "$kb"
if [ -s "$kb" ] && [ -n "$(tail -c1 "$kb")" ]; then
	echo >> "$kb"
fi
while IFS= read -r line; do
	[ -z "$line" ] && continue
	key=${line%%:*}
	if grep -q "^$key:" "$kb"; then
		echo "跳过已有快捷键：$key"
	else
		printf '%s\n' "$line" >> "$kb"
		echo "已添加快捷键：$key"
	fi
done < "$REPO_DIR/omp/keybindings.yml"

TERN_DIR=$(printf '%s' "$APPDATA" | tr '\\' '/')/Tern
if [ "$IS_WIN" != 1 ]; then
	echo "== 跳过 Tern：omp-desk 插件只支持 Windows =="
elif [ ! -d "$TERN_DIR" ]; then
	echo "== 跳过 Tern：未找到 $TERN_DIR，请先安装并启动一次 Tern =="
else
	echo "== Tern：$TERN_DIR =="
	BACKUP_DIR="$TERN_DIR/backup-$PLUGIN_ID-$STAMP"
	mkdir -p "$TERN_DIR/plugins"
	if [ -d "$TERN_DIR/plugins/$PLUGIN_ID" ]; then
		mkdir -p "$BACKUP_DIR"
		cp -R "$TERN_DIR/plugins/$PLUGIN_ID" "$BACKUP_DIR/"
		rm -rf "$TERN_DIR/plugins/$PLUGIN_ID"
	fi
	cp -R "$REPO_DIR/tern/plugins/$PLUGIN_ID" "$TERN_DIR/plugins/"
	echo "已安装 Tern 插件：$TERN_DIR/plugins/$PLUGIN_ID"

	ts="$TERN_DIR/settings.json"
	if [ -f "$ts" ]; then
		mkdir -p "$BACKUP_DIR"
		cp "$ts" "$BACKUP_DIR/"
		jq -s '.[0] * .[1]' "$ts" "$REPO_DIR/tern/settings.json" > "$ts.tmp"
		mv "$ts.tmp" "$ts"
	else
		cp "$REPO_DIR/tern/settings.json" "$ts"
	fi
	echo "已合并 Tern 设置：$ts"
	if [ -d "$BACKUP_DIR" ]; then
		echo "原文件备份在：$BACKUP_DIR"
	fi
fi

echo "完成，重启 Tern 生效"
