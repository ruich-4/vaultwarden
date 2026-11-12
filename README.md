# Vaultwarden + Caddy + PostgreSQL

用于新实例的 Docker Compose 模板。Caddy 提供 HTTPS 并自动申请、续期证书；PostgreSQL 镜像通过环境变量自动创建 `vaultwarden` 账户和同名数据库，无需挂载初始化脚本。

当前固定镜像版本：

- Caddy：`2.11.9-alpine`
- Vaultwarden：`1.37.5-alpine`
- PostgreSQL：`18.6-alpine`

## 准备

- 仅支持 Debian 12/13，需要能访问软件源。脚本启动时检查 Docker Engine、Compose 插件、OpenSSL、解压工具及所需基础命令，缺失时自动通过 APT 安装。
- 安装依赖时优先使用清华 TUNA 的 Debian 和 Docker CE 镜像：替换已配置的官方源地址，保留其他自定义镜像，原文件备份为 `.vaultwarden.bak`；新增 Docker 源也使用 TUNA。Docker 签名密钥优先从 TUNA 下载，失败时尝试官方地址。
- 以下操作建议在 root shell 中执行。普通用户运行脚本时会自动通过 `sudo` 提权；没有 `sudo` 时需切换到 root。已有可用依赖不会重复安装；Docker 未运行时尝试启动，检查失败则停止。
- 准备域名，将 DNS 的 A 记录指向服务器；如设置 AAAA 记录，IPv6 也必须可达。
- 确保主机的 TCP 80、443 端口空闲，并在防火墙和云安全组中开放。UDP 443 用于 HTTP/3，可选开放。

此模板按域名直接访问 Caddy 配置。仅 Caddy 发布宿主机端口，Vaultwarden 和 PostgreSQL 通过 Docker 网络访问，PostgreSQL 所在网络设为 `internal`。

## 初始化配置

```sh
git clone https://github.com/ruich-4/vaultwarden.git
cd vaultwarden
./setup.sh
```

选择 `1) 生成 .env 配置`，再按提示输入域名，例如 `vault.example.com`；也可以直接运行 `./setup.sh vault.example.com`。

`setup.sh` 是唯一 Shell 入口。不带参数运行时显示选项菜单：`1` 生成配置、`2` 导入备份、`0` 退出；也保留域名参数和 `import-db` 子命令用法。

脚本生成一个 32 字节随机数据库密码，以十六进制写入 `.env`，文件权限为 `600`。密码不在终端显示；已有 `.env` 时拒绝覆盖，不会改变现有数据库密码。

迁移旧数据请先执行下一节的导入步骤，再启动服务。全新安装需要注册账户时执行：

```sh
SIGNUPS_ALLOWED=true docker compose up -d
```

访问 `https://你的域名` 完成注册后，执行以下命令恢复 `.env` 中默认的关闭注册配置：

```sh
docker compose up -d vaultwarden
```

注册开放期间，其他能访问站点的人也能注册。模板默认关闭注册，未启用 `/admin` 管理入口。

## 导入 PostgreSQL 备份

先通过选项 `1` 生成配置，将 `.gz`、`.tar.gz`、`.zip` 或 `.tar` 备份放在运行命令时的当前目录，再运行 `./setup.sh`，选择 `2) 导入 PostgreSQL 备份`。脚本自动解压到临时目录，递归查找其中的 `.sql` 或 `.dump` 并导入，无需输入路径；只取找到的第一个压缩包和备份文件，退出时清理临时文件，保留原压缩包。单文件 `.gz` 解压后按内容识别 SQL/custom 格式。

请在首次启动 Vaultwarden **之前**导入。对于未压缩的备份，也可以直接执行：

```sh
./setup.sh import-db /路径/vaultwarden.dump
# 或：./setup.sh import-db /路径/vaultwarden.sql
```

脚本自动启动 PostgreSQL 并等待就绪，从文件内容识别格式，用 `vaultwarden` 数据库账户导入。目标数据库必须为空，Vaultwarden 必须停止；脚本不会清空已有数据，也不会自动启动应用。

支持 `pg_dump` 的完整单库备份：

- 推荐 custom 格式（`pg_dump -Fc`），恢复时自动忽略原来的对象所有者和授权。
- SQL 格式须通过 `pg_dump --no-owner --no-acl` 导出，不带 `--create`。不支持 `pg_dumpall`、SQLite 或自行编写的跨库/事务控制脚本。
- 使用不高于目标 PostgreSQL 主版本的兼容备份；本模板的导入工具为 PostgreSQL 18。
- 导入按单个事务执行，遇到错误停止；兼容的 `pg_dump` 备份会回滚本次写入。

如果旧服务使用同样的 Compose 服务名及数据库账户，可在旧服务目录导出：

```sh
umask 077
docker compose exec -T postgres pg_dump -U vaultwarden -d vaultwarden -Fc > vaultwarden.dump
# 纯 SQL：
# docker compose exec -T postgres pg_dump -U vaultwarden -d vaultwarden --no-owner --no-acl > vaultwarden.sql
```

导入完成后，将旧实例 `/data` 中的附件等文件另行恢复到新实例的 `vaultwarden_data` 卷，再运行 `docker compose up -d`。仅导入数据库不会恢复附件文件；此时保持注册关闭，用原有账户登录。

## HTTPS

`Caddyfile` 使用域名作为站点地址，Caddy 自动启用 HTTPS，并将 HTTP 请求跳转至 HTTPS，无需手动放置证书。

自动签发要求域名正确解析、服务器可访问证书颁发机构，且公网能访问验证端口。证书和 ACME 状态保存在 `caddy_data` 卷中，请保留该卷。

查看签发或代理错误：

```sh
docker compose logs --tail=100 caddy
```

## 可选邮件配置

如需发送邮件，先填写 `.env` 中的 `SMTP_*` 字段，再取消 `compose.yaml` 中对应 SMTP 环境变量块的注释，执行 `docker compose up -d vaultwarden`。

默认示例使用端口 `587` 和 `starttls`，请按邮件服务商要求调整。不要启用未填写的 SMTP 配置；未配置邮件时，不应依赖邮件验证、邮件双重验证或邮件通知。

## 数据与维护

- `postgres_data`：数据库，挂载到 PostgreSQL 18 使用的 `/var/lib/postgresql`。镜像通过 `POSTGRES_USER` 创建的 `vaultwarden` 账户是数据库超级用户，应用也使用此账户。
- `vaultwarden_data`：附件、密钥等 Vaultwarden 数据。使用 PostgreSQL 仍需保留此卷。
- `caddy_data`：证书和 ACME 状态。
- `caddy_config`：Caddy 配置状态。

镜像仅在 PostgreSQL 数据目录为空时，按环境变量创建账户和数据库。已有数据后，仅修改 `.env` 中的密码不会更新数据库中的角色密码；密码轮换需要同步修改数据库角色和应用配置。

从 PostgreSQL 17 升级时，不能直接复用旧数据卷；应先导出备份，在新的 PostgreSQL 18 数据卷中导入，并保留旧卷直到恢复验证完成。

备份应同时覆盖 PostgreSQL 数据库和 `vaultwarden_data`，并妥善保存 `.env` 与 Caddy 状态。常规停止或更新时不要使用 `docker compose down -v`，它会删除本项目的数据卷。

`.env` 已列入 Git 忽略规则。不要将真实凭据、数据库备份或导出的密码库提交到仓库。

## 验证范围

已在干净的 Debian 12/13 容器中验证缺失依赖自动安装、配置生成和重复执行不再安装。测试通过挂载现有 Docker socket 验证连接可用；服务启动成功、失败及启动后仍不可用的分支使用模拟验证，未验证全新宿主机的 Docker 守护进程启动。

已使用上述镜像在隔离的本地 Compose 项目中验证数据库初始化、Vaultwarden 数据库迁移、服务健康检查，以及经 Caddy 代理的 `/alive` 响应。Caddy 配置通过校验。

已验证自动生成密码、`.env` 权限与重复执行保护；使用实际 Vaultwarden 表结构及测试数据验证了 SQL/custom 备份导入、损坏备份回滚、非空数据库拒绝覆盖，以及恢复后应用的健康检查。

本地代理测试使用 HTTP，没有针对占位域名申请公网证书。实际域名的证书签发和服务器部署需要在目标环境验证。

## 官方文档

- [Vaultwarden Docker Compose](https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose)
- [Vaultwarden PostgreSQL 后端](https://github.com/dani-garcia/vaultwarden/wiki/Using-the-PostgreSQL-Backend)
- [Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)
- [PostgreSQL 备份与恢复](https://www.postgresql.org/docs/18/backup-dump.html)
