# Vaultwarden + Caddy + PostgreSQL

用于新实例的 Docker Compose 模板。Caddy 提供 HTTPS 并自动申请、续期证书；Vaultwarden 使用独立的 PostgreSQL 账户和数据库。

当前固定镜像版本：

- Caddy：`2.11.9-alpine`
- Vaultwarden：`1.37.5-alpine`
- PostgreSQL：`17.11-alpine`

## 准备

- 安装 Docker Engine、Docker Compose 插件和 OpenSSL，在 Linux 上执行以下脚本。
- 准备域名，将 DNS 的 A 记录指向服务器；如设置 AAAA 记录，IPv6 也必须可达。
- 确保主机的 TCP 80、443 端口空闲，并在防火墙和云安全组中开放。UDP 443 用于 HTTP/3，可选开放。

此模板按域名直接访问 Caddy 配置。仅 Caddy 发布宿主机端口，Vaultwarden 和 PostgreSQL 通过 Docker 网络访问，PostgreSQL 所在网络设为 `internal`。

## 初始化：只输入域名

```sh
git clone https://github.com/ruich-4/vaultwarden.git
cd vaultwarden
./setup.sh
```

按提示输入域名，例如 `vault.example.com`；也可以直接运行 `./setup.sh vault.example.com`。

脚本分别生成两套 32 字节随机数据库密码，以十六进制写入 `.env`，文件权限为 `600`。密码不在终端显示；已有 `.env` 时拒绝覆盖，不会改变现有数据库密码。

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

先运行 `setup.sh`，在首次启动 Vaultwarden **之前**导入：

```sh
./import-db.sh /路径/vaultwarden.dump
# 或：./import-db.sh /路径/vaultwarden.sql
```

脚本自动启动 PostgreSQL 并等待就绪，从文件内容识别格式，用普通应用账户导入。目标数据库必须为空，Vaultwarden 必须停止；脚本不会清空已有数据，也不会自动启动应用。

支持 `pg_dump` 的完整单库备份：

- 推荐 custom 格式（`pg_dump -Fc`），恢复时自动忽略原来的对象所有者和授权。
- SQL 格式须通过 `pg_dump --no-owner --no-acl` 导出，不带 `--create`。不支持 `pg_dumpall`、SQLite、压缩包或自行编写的跨库/事务控制脚本。
- 使用不高于目标 PostgreSQL 主版本的兼容备份；本模板的导入工具为 PostgreSQL 17。
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

- `postgres_data`：数据库。应用账户拥有自己的数据库，但没有超级用户、创建数据库或创建角色权限。
- `vaultwarden_data`：附件、密钥等 Vaultwarden 数据。使用 PostgreSQL 仍需保留此卷。
- `caddy_data`：证书和 ACME 状态。
- `caddy_config`：Caddy 配置状态。

初始化脚本只在 PostgreSQL 数据目录为空时执行。已有数据后，仅修改 `.env` 中的密码不会更新数据库中的角色密码；密码轮换需要同步修改数据库角色和应用配置。

备份应同时覆盖 PostgreSQL 数据库和 `vaultwarden_data`，并妥善保存 `.env` 与 Caddy 状态。常规停止或更新时不要使用 `docker compose down -v`，它会删除本项目的数据卷。

`.env` 已列入 Git 忽略规则。不要将真实凭据、数据库备份或导出的密码库提交到仓库。

## 验证范围

已使用上述镜像在隔离的本地 Compose 项目中验证数据库初始化、Vaultwarden 数据库迁移、服务健康检查，以及经 Caddy 代理的 `/alive` 响应。Caddy 配置通过校验。

已验证自动生成密码、`.env` 权限与重复执行保护；使用实际 Vaultwarden 表结构及测试数据验证了 SQL/custom 备份导入、损坏备份回滚、非空数据库拒绝覆盖，以及恢复后应用的健康检查。

本地代理测试使用 HTTP，没有针对占位域名申请公网证书。实际域名的证书签发和服务器部署需要在目标环境验证。

## 官方文档

- [Vaultwarden Docker Compose](https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose)
- [Vaultwarden PostgreSQL 后端](https://github.com/dani-garcia/vaultwarden/wiki/Using-the-PostgreSQL-Backend)
- [Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)
- [PostgreSQL 备份与恢复](https://www.postgresql.org/docs/17/backup-dump.html)
