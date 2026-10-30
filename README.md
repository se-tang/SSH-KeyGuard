# SSH KeyGuard

轻量 SSH 公钥管理与认证加固工具，支持 Debian / Ubuntu / Alpine Linux。

## 一键运行

在 VPS 的 **root SSH 终端**执行：

```sh
curl -fsSL https://raw.githubusercontent.com/se-tang/SSH-KeyGuard/refs/heads/main/install.sh | sh
```

普通用户将末尾 `sh` 改成 `sudo sh`。Alpine 首次使用可先安装依赖：

```sh
apk add bash curl ca-certificates
```

需要已运行的 OpenSSH Server、Bash 4+ 和 `ssh-keygen`；给普通用户添加公钥还需要 `runuser` 或 `su`。

## 功能

- 添加、查看 SSH 公钥，保留已有密钥。
- 关闭密码认证，或恢复普通用户密码认证。
- 备份、恢复 SSH 主配置，失败时尝试回滚。
- 检查认证策略及匹配用户/IP 的登录日志。

## 使用顺序

**添加公钥 → 在另一个独立 SSH 会话验证密钥登录 → 应用安全配置 → 再次验证。**

应用后全局配置为：

```text
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
```

操作期间保留当前连接，并确保服务商控制台可用。`Match` 规则可能覆盖全局设置；备份仅包含主配置文件，不回滚 `Include` 文件。工具不修改 SSH 端口或防火墙，也不上传密钥。

版本：**0.3.3** · [更新记录](CHANGELOG.md) · [MIT License](LICENSE)
