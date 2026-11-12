#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

import_db() {
    [ "$#" -eq 1 ] || fail "用法：$0 import-db /路径/vaultwarden.sql 或 /路径/vaultwarden.dump"
    backup=$1
    [ -f "$backup" ] && [ -r "$backup" ] && [ -s "$backup" ] || fail '备份文件不存在、不可读或为空。'
    case "$backup" in
        /*) ;;
        *) backup="$(pwd)/$backup" ;;
    esac

    # Detect the contents instead of trusting the filename extension.
    if [ "$(head -c 5 -- "$backup")" = PGDMP ]; then
        format=custom
    else
        format=plain
        grep -q '^-- PostgreSQL database dump' "$backup" || fail '仅支持 pg_dump 生成的 SQL 或 custom 格式备份。'
        # Reconnecting would escape psql's single transaction and target database.
        if LC_ALL=C grep -Eq '^(CREATE|DROP) DATABASE[[:space:]]|^\\(connect|c)([[:space:]]|$)' "$backup"; then
            fail 'SQL 备份包含建库或切换数据库命令，请用 pg_dump --no-owner --no-acl 重新导出，不要使用 --create 或 pg_dumpall。'
        fi
    fi

    CDPATH= cd -- "$(dirname -- "$0")"
    [ -f .env ] || fail '请先运行 ./setup.sh 生成 .env。'
    docker compose config --quiet
    running=$(docker compose ps --status running --quiet vaultwarden)
    [ -z "$running" ] || \
        fail 'Vaultwarden 正在运行，请先执行 docker compose stop vaultwarden 后重试。'
    docker compose up -d --wait postgres

    objects=$(docker compose exec -T postgres psql -X --username vaultwarden --dbname vaultwarden \
        --set ON_ERROR_STOP=1 --tuples-only --no-align --command \
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema';")
    [ "$objects" = 0 ] || fail '目标数据库非空，拒绝覆盖。请在新的空数据库中导入，且先不要启动 Vaultwarden。'

    if [ "$format" = custom ]; then
        docker compose exec -T postgres pg_restore --username vaultwarden --dbname vaultwarden \
            --no-owner --no-privileges --single-transaction < "$backup" || \
            fail '导入失败，事务已回滚；请检查备份格式及 PostgreSQL 版本。'
    else
        docker compose exec -T postgres psql -X --username vaultwarden --dbname vaultwarden \
            --set ON_ERROR_STOP=1 --single-transaction --file=- --quiet < "$backup" || \
            fail '导入失败；兼容的 pg_dump 备份会事务回滚。SQL 需使用 --no-owner --no-acl 导出。'
    fi

    printf '%s\n' '数据库导入完成。旧实例的 /data 附件等文件需另外恢复到 vaultwarden_data 卷。' \
        '确认数据文件就绪后，执行 docker compose up -d 启动服务。'
}

import_archive() {
    archive=
    for file in ./*.tar.gz ./*.gz ./*.zip ./*.tar; do
        [ -f "$file" ] || continue
        archive=$file
        break
    done
    [ -n "$archive" ] || fail '当前目录未找到 .gz、.tar.gz、.zip 或 .tar 压缩包。'

    umask 077
    archive_tmp=$(mktemp -d)
    trap 'rm -rf -- "$archive_tmp"' 0
    trap 'exit 1' HUP INT TERM
    printf '正在解压：%s\n' "$archive"
    case "$archive" in
        *.tar.gz|*.tar)
            command -v tar >/dev/null 2>&1 || fail '需要 tar，请先安装。'
            tar --no-same-owner --no-same-permissions -xf "$archive" -C "$archive_tmp" || fail '压缩包解压失败。'
            ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || fail '需要 unzip，请先安装。'
            unzip -q "$archive" -d "$archive_tmp" || fail '压缩包解压失败。'
            ;;
        *.gz)
            command -v gzip >/dev/null 2>&1 || fail '需要 gzip，请先安装。'
            # A single gzip stream has no directory tree; import_db detects its SQL/custom contents.
            gzip -dc -- "$archive" > "$archive_tmp/backup.dump" || fail '压缩包解压失败。'
            ;;
    esac
    backup_path=$(find "$archive_tmp" -type f \( -iname '*.sql' -o -iname '*.dump' \) -print -quit)
    [ -n "$backup_path" ] || fail '压缩包内未找到 .sql 或 .dump 备份。'
    import_db "$backup_path"
}

if [ "$#" -eq 0 ]; then
    printf '%s\n' '1) 生成 .env 配置' '2) 导入 PostgreSQL 备份' '0) 退出'
    printf '请选择 [0-2]：'
    IFS= read -r choice || fail '未读取到选项。'
    case "$choice" in
        1) ;;
        2)
            import_archive
            exit 0
            ;;
        0) exit 0 ;;
        *) fail '无效选项，请输入 0、1 或 2。' ;;
    esac
fi

if [ "${1-}" = import-db ]; then
    shift
    import_db "$@"
    exit 0
fi

umask 077
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

vault_password=$(openssl rand -hex 32)

# Link the completed file without replacing an existing .env, even on concurrent runs.
tmp=$(mktemp .env.tmp.XXXXXX)
trap 'rm -f "$tmp"' 0
trap 'exit 1' HUP INT TERM
sed -e "s/^VAULT_DOMAIN=.*/VAULT_DOMAIN=$domain/" \
    -e "s/^VAULT_DB_PASSWORD=.*/VAULT_DB_PASSWORD=$vault_password/" \
    .env.example > "$tmp"
ln -T -- "$tmp" .env || fail '无法创建 .env，已有配置未被覆盖。'

printf '%s\n' '已生成 .env（权限 600），数据库密码已保存，不在终端显示。' \
    '迁移旧数据：先运行 ./setup.sh import-db /路径/备份.dump，再启动服务。' \
    '新建账户：运行 SIGNUPS_ALLOWED=true docker compose up -d；注册后运行 docker compose up -d vaultwarden 关闭注册。'
