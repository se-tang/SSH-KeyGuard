# SSH KeyGuard

**SSH KeyGuard** 是一个纯 Bash 编写的 VPS SSH 密钥管理与认证加固工具。主要适配安装了 OpenSSH Server 的 **Debian / Ubuntu / Alpine Linux**，提供交互式菜单，不需要 Docker、Python、数据库或常驻后台服务。

- 当前版本：`0.3.3`
- 运行权限：`root`
- 默认配置：`/etc/ssh/sshd_config`
- 默认备份目录：`/var/backups/ssh-keyguard/`
- 服务管理：systemd（Debian / Ubuntu 常见）或 OpenRC（Alpine）
- 许可证：MIT

## 一键运行

在 VPS 的 **root SSH 终端**复制执行，下载并打开交互菜单：

```sh
curl -fsSL https://raw.githubusercontent.com/se-tang/SSH-KeyGuard/main/install.sh | sh
```

普通 sudo 用户使用：

```sh
curl -fsSL https://raw.githubusercontent.com/se-tang/SSH-KeyGuard/main/install.sh | sudo sh
```

只有 wget 时（root）：

```sh
wget -qO- https://raw.githubusercontent.com/se-tang/SSH-KeyGuard/main/install.sh | sh
```

需要 Bash 和 curl/wget；Alpine 首次可执行 `apk add bash curl ca-certificates`。启动器完整下载管理脚本并检查语法后，从当前终端读取菜单输入；退出后删除本次下载的临时文件。每次运行获取 main 分支最新版，不安装常驻服务，也不会直接修改 SSH 配置。添加公钥、独立会话验证和输入 `YES` 确认的流程保持不变。

仓库必须对运行命令的机器公开可读；出现 404 时请先确认仓库可见性。命令执行的是此仓库提供的代码。

## 系统要求

- Linux，已安装并运行 OpenSSH Server。
- Bash 4+（Alpine 默认环境通常只有 BusyBox `ash`，需要额外安装 Bash）。
- root 权限。
- `ssh-keygen`（用于解析并验证公钥，通常随 OpenSSH 安装）；给普通用户添加公钥还需要 `runuser` 或 `su`，所有文件写入均降权到目标用户执行。

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash curl ca-certificates openssh-server
```

### Alpine Linux

```sh
apk add bash curl ca-certificates openssh
```

如果 SSH 服务尚未启用，可通过 OpenRC 启用并启动：

```sh
rc-update add sshd default
rc-service sshd start
```

如果服务器已经能通过 SSH 正常登录，通常不需要重复启动服务。Alpine 上请用 root 执行 `./ssh-keyguard.sh`；如果安装了 sudo，也可以使用 `sudo ./ssh-keyguard.sh`。

## 菜单预览

```text
========== SSH KeyGuard ==========
轻量 SSH 密钥管理与安全加固工具 v0.3.3
当前系统：...
----------------------------------
1. 添加 SSH 公钥
2. 查看授权公钥
3. 检查 SSH 全局认证配置
4. 一键应用四项 SSH 密钥安全配置（先验证密钥）
5. 恢复普通用户密码认证（Root 仍仅限密钥）
6. 备份 SSH 配置
7. 恢复 SSH 配置
8. 检查当前连接策略与最近登录记录
0. 退出
----------------------------------
请选择：
```

## 手动下载运行（可选）

下载并解压 ZIP，进入项目目录：

```bash
unzip ssh-keyguard.zip
cd ssh-keyguard
chmod +x ssh-keyguard.sh
sudo ./ssh-keyguard.sh
```

Alpine 已安装 Bash 后，以 root 执行：

```sh
chmod +x ssh-keyguard.sh
./ssh-keyguard.sh
```

也可以只上传 `ssh-keyguard.sh` 到 VPS 再运行。

## 菜单功能

| 编号 | 功能 | 说明 |
|---|---|---|
| 1 | 添加 SSH 公钥 | 添加到指定用户的 `~/.ssh/authorized_keys`，不覆盖原有公钥 |
| 2 | 查看授权公钥 | 查看指定用户当前授权的公钥 |
| 3 | 检查 SSH 全局认证配置 | 查看 `sshd -T` 的全局有效配置 |
| 4 | 应用四项安全配置 | 适用于公钥已经安装、并且已在第二个独立 SSH 会话验证成功的服务器 |
| 5 | 恢复普通用户密码认证 | 重新开启普通用户密码认证；Root 仍仅允许密钥等非密码认证 |
| 6 | 备份 SSH 配置 | 备份主配置文件 `sshd_config` |
| 7 | 恢复 SSH 配置 | 从指定备份恢复主配置文件 |
| 8 | 检查当前连接策略与最近登录记录 | 检查当前连接上下文的 `Match` 策略，并按来源显示精确匹配 IP/用户名的 SSH 认证日志及时间范围 |

**新 VPS 的推荐操作顺序：** 先选 **1** 添加公钥，在另一个 SSH 会话中验证密钥登录成功，再选 **4** 应用四项安全配置。选项 4 不负责添加公钥；这样将添加公钥与关闭密码认证分开，避免重复菜单。

## 四项安全配置

菜单 **4** 应用以下配置：

```text
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
```

`PermitRootLogin prohibit-password` 与旧别名 `without-password` 在 OpenSSH 中语义相同。有些版本执行 `sshd -T` 时会把它显示为 `permitrootlogin without-password`，KeyGuard 会将两者都识别为正确结果。

## 选项 8：连接策略与最近认证日志

选项 8 分两部分工作：

1. 使用 `sshd -T -C` 尽可能按当前用户名、来源 IP、目标地址和端口计算 `Match` 条件下的有效认证策略。
2. 按完整用户名和来源 IP 筛选成功/失败认证记录，例如 `Accepted publickey`、`Accepted password`、`Failed password` 或 `Invalid user`；不同日志来源分别展示，每个来源最多 10 条匹配记录。

`journalctl` 结果限制为最近 24 小时的最后 1500 条候选记录。`logread` 和日志文件读取末尾 1500 条候选记录；由于其时间格式可能缺少年份或时区，明确标注“未验证时间范围”，不将它们称为最近 24 小时，也不合并宣称跨来源的最新顺序。候选上限可能遗漏更早的匹配记录。

日志来源按系统能力尝试读取：

- Debian / Ubuntu：`journalctl`、`/var/log/auth.log`。
- Alpine：BusyBox `logread`、`/var/log/messages`；如果系统安装并启用了其他 syslog，也会尝试常见日志文件。

**注意：** 这是 SSH 认证日志检查，不是完整的 shell 会话审计或 `last` 登录历史报告。日志可能未启用、已轮转、被清理或只保留在内存环形缓冲区；没有匹配记录不代表没有登录。`Match Host`、`LocalAddress` 等复杂条件也可能需要人工核对。

## 推荐使用流程

### 新 VPS 初始化

1. 先通过 VPS 服务商网页控制台或当前可用方式登录服务器。
2. 在 Termius 中生成密钥对，并复制 **公钥**（通常是 `.pub` 内容）。私钥留在自己的设备上。
3. 运行脚本，选择 **1**，按提示粘贴公钥。
4. 不要关闭当前 SSH 会话；另开一个 Termius 会话，明确选择刚才对应的私钥，尝试登录。
5. 确认新会话成功登录后，回到菜单选择 **4**，输入 `YES` 确认，脚本才会关闭密码认证。
6. 再开一个新会话复测，确认密钥登录正常后，才关闭旧会话。

### 已经添加过公钥

如果公钥已添加且已在新会话中验证成功，可以直接选择 **4**。脚本仍会要求输入 `YES` 二次确认。

## 安全设计与限制

- 管理脚本为纯 Bash，不联网、不生成或上传私钥、不修改 SSH 端口和防火墙。一键启动器为 POSIX sh，只联网下载本仓库的管理脚本，不会发送密钥或服务器配置。
- 添加公钥时采用追加方式，不覆盖已有 `authorized_keys`；重复公钥不会重复写入。
- 写入前使用 `ssh-keygen` 验证真实密钥结构并显示指纹；已有文件缺少末尾换行时先补换行，避免两条密钥粘在同一行。
- 普通用户的目录创建、权限修改和公钥追加均以该用户身份执行，不再由 root 对其目录执行 `chown`。已有目录或文件若归 root 所有而不可写，将报告错误并要求人工检查。Root 的家目录及其父目录、已有 `.ssh` 目录必须归 root 所有、不可被组或其他用户写入且不含符号链接，否则拒绝写入。
- 修改前自动备份主配置文件；先用 `sshd -T -f` 检查候选配置，再安装配置并执行 `sshd -t`、`sshd -T` 验证，最后重载 SSH 服务。
- Debian / Ubuntu 优先通过 systemd 重载 SSH 服务；Alpine 通过 OpenRC 的 `rc-service sshd reload`，若服务脚本不支持 reload，则尝试 restart。
- 如果语法、生效值检查或服务重载失败，脚本会尝试恢复备份。重载/重启失败时，使用原服务管理器和服务名重启恢复，即使该服务已停止；再次失败会显示严重错误、备份位置和服务恢复命令，不会隐藏恢复失败。服务状态检查不等于一次真实的远程登录测试。
- 为兼容 Alpine / BusyBox，脚本避免使用 GNU 专属的 `chmod --reference`、`chown --reference` 和 `find -printf`。
- 修改的是 `/etc/ssh/sshd_config` 主配置文件。配置文件中的 `Include` 会被 OpenSSH 正常解析；脚本将四项设置放在主配置文件开头，以优先于后续 Include 中的同名全局设置。
- `Match` 条件可能覆盖全局设置。选项 8 会尽可能按用户和来源 IP 计算连接上下文，但复杂条件仍需人工核对。
- 选项 7 只恢复主配置文件，不会回滚其他 Include 文件或云厂商外部配置管理系统。
- 不同 OpenSSH 版本、非标准 SSH 服务名、特殊 PAM/LDAP/堡垒机配置可能需要人工适配。

## 重要提醒

**绝不要在密钥登录尚未通过第二个独立 SSH 会话验证前关闭密码登录。** 新 VPS 应先用选项 1 添加公钥，再从另一个 Termius 会话验证；成功后才使用选项 4。始终保留当前会话，并确保可以使用 VPS 服务商控制台救援。选项 4 会要求用户明确确认，但脚本无法自动证明另一条密钥连接一定可用。

## 检查命令

```bash
bash -n ssh-keyguard.sh
sudo sshd -t
sudo sshd -T | grep -Ei '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
```

项目另附隔离回归检查（使用真实公钥工具、降权子进程和模拟服务，不重启真实 SSH）：

```bash
sudo bash tests/regression.sh
# 一键启动器检查（需要 util-linux 的 script 工具）：
sudo bash tests/launcher.sh
```

安全回归测试需要存在 `nobody` 用户、`ssh-keygen` 和 `runuser`/`su`。启动器测试使用伪终端和模拟下载，覆盖菜单输入、下载/语法失败、退出码和清理。回归测试不能替代目标发行版的真实新连接验证。

## 自定义测试路径

脚本支持通过环境变量指定配置文件、备份目录和 sshd 可执行文件，便于在隔离测试环境验证：

```bash
sudo SSH_KEYGUARD_CONFIG=/path/to/sshd_config \
  SSH_KEYGUARD_BACKUP_DIR=/path/to/backups \
  SSHD_BIN=/usr/sbin/sshd \
  ./ssh-keyguard.sh
```

请只在隔离测试环境中使用自定义配置路径；正式服务器应使用系统实际 SSH 配置。
