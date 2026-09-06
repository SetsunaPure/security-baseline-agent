# 主机安全基线巡检 — 知识规则集

本文件定义 Agent 在巡检与评估时遵循的知识规则与基线标准。Agent 据此对 `security_baseline_check.sh` 采集到的**客观事实**进行风险评估与整改建议输出。

## 1. 职责分工（重要）

- **确定性采集**：一律由 `scripts/security_baseline_check.sh`（纯 bash）完成，结果客观、可复现。
- **模糊判断**：仅 LLM 基于采集事实输出风险等级与整改建议。
- **Agent 不得修改任何系统配置**，只读巡检。

## 2. SSH 加固基线

| 项 | 合规值 | 说明 |
|---|---|---|
| PermitRootLogin | `no` | 禁止 root 远程登录 |
| PasswordAuthentication | `no` | 禁用口令认证，仅密钥 |
| PermitEmptyPasswords | `no` | 禁用空口令 |
| PubkeyAuthentication | `yes` | 启用公钥认证 |

## 3. 防火墙基线

- 主机应安装管理工具（ufw / nftables / iptables），默认入站 `policy drop`，仅放行必要端口与回环流量。
- 无任何防火墙管理工具视为**高风险（裸奔）**。

## 4. 口令老化策略（/etc/login.defs 或 chage）

| 项 | 合规值 |
|---|---|
| PASS_MAX_DAYS | ≤ 90 |
| PASS_MIN_DAYS | ≥ 1 |
| PASS_WARN_AGE | ≥ 7 |

- `PASS_MAX_DAYS=99999` 视为高风险（永不过期）。
- 注意 login.defs 仅影响新账户；现有账户须 `chage -M 90 -m 7 -W 14 <user>` 落地。

## 5. SUID/SGID

- 仅允许系统包管理器管理的标准程序（如 su、passwd、mount 等），属主 root:root，且不被其他用户可写（非 world-writable）。
- 世界可写 + setuid/setgid（/6000 & world-write）视为高风险提权面。
- 出现非常规/自研 SUID 视为可疑。

## 6. 监听端口

- 对外开放的 `0.0.0.0`/`::` 监听视为高风险暴露面。
- 回环 `127.x.x.x` 内部监听属常见/低风险，但仍建议最小化。

## 7. 关键文件权限

| 文件 | 合规 |
|---|---|
| /etc/passwd | 644 root:root |
| /etc/shadow | 640 root:shadow（或更严 600），拒绝普通用户可读 |
| /etc/group | 644 root:root |

## 8. 输出规范

- 每个发现输出四项：`事实` + `风险等级(高/中/低)` + `整改建议` + （如适用）`落地命令`。
- 只读巡检，末尾声明"未对任何系统配置做出修改"。