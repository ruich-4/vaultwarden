#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

check_environment() {
    [ -r /etc/os-release ] || fail '无法识别系统，仅支持 Debian 12/13。'
    . /etc/os-release
    [ "${ID-}" = debian ] || fail '仅支持 Debian 12/13。'
    case "${VERSION_ID-}" in
        12|13) ;;
        *) fail '仅支持 Debian 12/13。' ;;
    esac
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || fail '请以 root 用户运行；当前用户没有 sudo。'
        exec sudo -- sh "$0"
    fi

    packages=
    for dependency in openssl:openssl tar:tar gzip:gzip unzip:unzip curl:curl \
        awk:mawk find:findutils grep:grep sed:sed head:coreutils \
        mktemp:coreutils dirname:coreutils ln:coreutils rm:coreutils \
        install:coreutils chmod:coreutils cat:coreutils cp:coreutils; do
        command -v "${dependency%%:*}" >/dev/null 2>&1 || packages="$packages ${dependency#*:}"
    done
    if [ "$(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null || true)" != 'install ok installed' ]; then
        packages="$packages ca-certificates"
    fi

    docker_packages=
    if ! command -v docker >/dev/null 2>&1 || \
        { ! command -v dockerd >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; }; then
        docker_packages='docker-ce docker-ce-cli containerd.io'
    fi
    if ! docker compose version >/dev/null 2>&1; then
        docker_packages="$docker_packages docker-compose-plugin"
    fi

    if [ -n "$packages$docker_packages" ]; then
        mirror=https://mirrors.cernet.edu.cn
        # Keep suites, components and custom mirrors; support both APT source formats.
        for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$source" ] || continue
            if grep -Eq 'https?://(deb\.debian\.org|security\.debian\.org|download\.docker\.com)/' "$source"; then
                [ -e "$source.vaultwarden.bak" ] || cp -p -- "$source" "$source.vaultwarden.bak"
                # Preserve HTTP for Debian's initial CA-certificate bootstrap.
                sed -i -E \
                    -e "s#(https?://)deb\\.debian\\.org/debian/?#\\1${mirror#https://}/debian/#g" \
                    -e "s#(https?://)security\\.debian\\.org/debian-security/?#\\1${mirror#https://}/debian-security/#g" \
                    -e "s#https?://download\\.docker\\.com/#$mirror/docker-ce/#g" "$source"
            fi
        done
        apt-get update || fail 'APT 软件源更新失败。'
        if [ -n "$packages" ]; then
            # Package names come only from the fixed dependency list above.
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove $packages || fail '基础依赖安装失败。'
        fi
        if [ -n "$docker_packages" ]; then
            need_docker_repo=false
            for package in $docker_packages; do
                apt-cache show "$package" >/dev/null 2>&1 || need_docker_repo=true
            done
            if [ "$need_docker_repo" = true ]; then
                install -m 0755 -d /etc/apt/keyrings
                curl -fsSL --connect-timeout 10 --max-time 60 "$mirror/docker-ce/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc || \
                    curl -fsSL --connect-timeout 10 --max-time 60 https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || fail 'Docker 软件源密钥下载失败。'
                chmod 0644 /etc/apt/keyrings/docker.asc
                cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $mirror/docker-ce/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
                apt-get update || fail 'Docker 软件源更新失败。'
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove $docker_packages || fail 'Docker/Compose 安装失败，请检查 APT 报错或已有软件包冲突。'
        fi
    fi

    docker compose version >/dev/null 2>&1 || fail 'Docker Compose 插件不可用。'
    if ! docker info >/dev/null 2>&1; then
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            systemctl start docker || fail 'Docker 服务启动失败。'
        elif command -v service >/dev/null 2>&1; then
            service docker start || fail 'Docker 服务启动失败。'
        else
            fail '无法启动 Docker 服务，请检查系统服务管理器。'
        fi
        docker info >/dev/null 2>&1 || fail 'Docker 服务仍不可用，请检查服务状态及 Docker 连接配置。'
    fi
    printf '%s\n' '环境检查完成。'
}

import_db() {
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
            tar --no-same-owner --no-same-permissions -xf "$archive" -C "$archive_tmp" || fail '压缩包解压失败。'
            ;;
        *.zip)
            unzip -q "$archive" -d "$archive_tmp" || fail '压缩包解压失败。'
            ;;
        *.gz)
            # A single gzip stream has no directory tree; import_db detects its SQL/custom contents.
            gzip -dc -- "$archive" > "$archive_tmp/backup.dump" || fail '压缩包解压失败。'
            ;;
    esac
    backup_path=$(find "$archive_tmp" -type f \( -iname '*.sql' -o -iname '*.dump' \) -print -quit)
    [ -n "$backup_path" ] || fail '压缩包内未找到 .sql 或 .dump 备份。'
    import_db "$backup_path"
}

[ "$#" -eq 0 ] || fail "用法：$0（不带参数，通过菜单操作）"
check_environment

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

umask 077
CDPATH= cd -- "$(dirname -- "$0")"
[ ! -e .env ] && [ ! -L .env ] || fail '已存在 .env，保留原配置，不重新生成密码。'

printf '请输入域名（例如 vault.example.com）：'
IFS= read -r domain || fail '未读取到域名。'

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
    '迁移旧数据：将备份压缩包放在当前目录，再运行 ./setup.sh 选择 2 导入，之后启动服务。' \
    '新建账户：运行 SIGNUPS_ALLOWED=true docker compose up -d；注册后运行 docker compose up -d vaultwarden 关闭注册。'
