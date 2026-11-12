#!/bin/sh
set -eu
umask 077

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ "$#" -le 1 ] || fail "用法：$0 [域名]"
CDPATH= cd -- "$(dirname -- "$0")"
[ ! -e .env ] && [ ! -L .env ] || fail '已存在 .env，保留原配置，不重新生成密码。'
command -v openssl >/dev/null 2>&1 || fail '需要 openssl，请先安装。'

domain=${1-}
if [ "$#" -eq 0 ]; then
    printf '请输入域名（例如 vault.example.com）：'
    IFS= read -r domain || fail '未读取到域名。'
fi

printf '%s\n' "$domain" | LC_ALL=C awk -F. '
    NR != 1 || length($0) > 253 || NF < 2 { exit 1 }
    {
        for (i = 1; i <= NF; i++) {
            if (length($i) < 1 || length($i) > 63 || $i ~ /[^a-zA-Z0-9-]/ ||
                $i ~ /^-/ || $i ~ /-$/) exit 1
        }
        if ($NF !~ /[a-zA-Z]/) exit 1
    }
' || fail '请输入有效域名，不带 https://、端口或路径；国际化域名请使用 Punycode。'

postgres_password=$(openssl rand -hex 32)
vault_password=$(openssl rand -hex 32)

# Link the completed file without replacing an existing .env, even on concurrent runs.
tmp=$(mktemp .env.tmp.XXXXXX)
trap 'rm -f "$tmp"' 0
trap 'exit 1' HUP INT TERM
sed -e "s/^VAULT_DOMAIN=.*/VAULT_DOMAIN=$domain/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$postgres_password/" \
    -e "s/^VAULT_DB_PASSWORD=.*/VAULT_DB_PASSWORD=$vault_password/" \
    .env.example > "$tmp"
ln -T -- "$tmp" .env || fail '无法创建 .env，已有配置未被覆盖。'

printf '%s\n' '已生成 .env（权限 600），两套独立数据库密码已保存，不在终端显示。' \
    '迁移旧数据：先运行 ./import-db.sh /路径/备份.dump，再启动服务。' \
    '新建账户：运行 SIGNUPS_ALLOWED=true docker compose up -d；注册后运行 docker compose up -d vaultwarden 关闭注册。'
