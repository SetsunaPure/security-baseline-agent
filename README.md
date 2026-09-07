# Security Baseline Agent

基于 **Chaitin Agent-Compose + OctoBus** 主机安全基线巡检 Agent：由 LLM（DeepSeek）协调，**确定性事实采集交给脚本、风险判断交给模型**，能力调用经 **OctoBus 网关**路由。用于演示 Agent 平台（agent-compose）与能力网关（OctoBus）的协同实跑。

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│  agent-compose daemon                                          │
│   └─ agent "baseline" (provider=codex, model=deepseek-chat)    │
│        sandbox: chaitin/agent-compose-guest                    │
│        ├─ STEP1  bash security_baseline_check.sh   (确定性采集) │
│        ├─ STEP2  curl octobus:9000/.../SayHello    (能力调用)   │
│        ├─ STEP3  LLM 风险评估 (基于采集事实)                    │
│        └─ STEP4  写 baseline_report.txt                        │
└──────────────────────────────────────────────────────────────┘
                              │  octobus:9000 (agent-compose_default 网络)
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  OctoBus 能力网关 (127.0.0.1:9000, 不对外开放)                 │
│   └─ capset=devcap, instance=hello-inst                        │
│        └─ hello.v1.HelloService/SayHello                        │
└──────────────────────────────────────────────────────────────┘
              │  LLM call (chat_completions)
              ▼
        DeepSeek API (密钥由 daemon 环境变量管理，不入库)
```

## 目录结构

```
.
├── agent-compose.yml                      # project 定义（含每日定时触发 scheduler，无明文密钥）
├── .env.example                           # 密钥模板（真实值写入 .env，不入库）
├── scripts/
│   └── security_baseline_check.sh         # 确定性事实采集脚本（纯 bash）
├── knowledge/
│   └── security-baseline-rules.md         # 安全基线知识规则集
└── runs/
    ├── baseline_report.txt                # 实跑评估报告（示例输出）
    └── run_74c6b760_full_logs.txt         # Agent 完整运行日志
```

## 快速开始

### 1. 前置环境

- 部署 [Chaitin Agent-Compose](https://chaitin.com) 与 OctoBus，二者处于同一 Docker 网络（默认 `agent-compose_default`）。
- 准备 `chaitin/agent-compose-guest` 沙箱镜像。

### 2. 配置 LLM（密钥不落盘）

复制 `.env.example` 为 `.env` 并填入真实 DeepSeek key，挂载进容器 `/data/work/.env`（只读）：

```bash
cp .env.example .env
# 编辑 .env，填入 LLM_API_KEY=sk-xxx
```

### 3. 应用并运行

```bash
# 校验配置（在 /opt/agent-compose/data/work 下）
agent-compose config --quiet

# 应用 project
agent-compose up

# 触发一轮巡检
agent-compose run baseline --prompt "$(cat run_prompt.txt)" --agent-workdir /workspace

# 定时触发：项目已内置每日 08:00 的 cron scheduler（daily-baseline）
# 可查询触发器 / 手动触发一次验证
agent-compose scheduler ls
agent-compose scheduler trigger <scheduler-id> daily-baseline
```

> `run_prompt.txt` 见 `runs/` 下的执行 prompt（STEP1-4 流程，已同步保留在部署环境）。

### 4. 查看结果

```bash
agent-compose ps                       # run 状态
cat /workspace/baseline_report.txt     # 评估报告
```

## 安全要求（部署硬性约定）

- **OctoBus 不对公网开放端口**：仅绑定 `127.0.0.1:9000`，沙箱经内部网络以 DNS 名 `octobus:9000` 访问。
- **控制台/UI 不无鉴权公开**：保持关闭或仅内网可访问。
- **仓库无明文密钥**：所有凭据走环境变量（`.env` 不入库），认证由 agent-compose daemon 的 LLM Facade 管理。
- **关键路径经 OctoBus 网关**：能力调用显式走 `octobus:9000/...`，不绕过网关。
- **重启自恢复**：容器 `restart: always` + systemd 开机自启。


## 实施过程中遇到的问题及处理方式

| 问题 | 现象与定位 | 解决方式 |
| --- | --- | --- |
| workspace 字段不兼容 | `provider: local` / 绝对路径均报校验失败 | 反推官方 schema，定位为 `provider: file` + 相对路径 `path: baseline-scripts`（相对容器工作目录 /data/work） |
| API key 不能落入沙箱 | 直接 curl 验证了 key 有效，但怕密钥进仓库/沙箱 | 认证交由 agent-compose daemon 的 LLM Facade 托管，yml 与展示文件均不含 key，服务端 grep 校验 `no key leaked` |
| 内存 1.6G 是硬约束 | 多沙箱会 OOM | 只起 1 个 sandbox（guest 镜像已预装 CLI），命令严格串行、加大超时，全程 free -m 监控可用内存 |
| OctoBus 网络可达性 | 宿主 127.0.0.1:9000 在沙箱内不通 | 同网络用 DNS 名 `octobus:9000` 访问，网关链路透传正常 |
| 定时触发未生效 | 初版 project 缺 scheduler，SCHEDULERS=0 | 在 agent 下补 `scheduler.enabled + triggers.cron`，重新 `up` 后 scheduler 数变为 1，定时触发 run 实测 succeeded |

## 实跑验收结果（摘要）

- Run `74c6b760932...`：`status=succeeded`, `exit_code=0`。
- 一轮完成：确定性采集（bash 脚本）→ OctoBus 能力调用（返回 `{"greeting":"Hello, security-agent, from OctoBus!"}`）→ LLM 风险评估 → 写入 `baseline_report.txt`。
- 重启 daemon 后 project/agent 保留、沙箱重新挂接保持 running、报告仍在。

详见 `runs/baseline_report.txt` 与 `runs/run_74c6b760_full_logs.txt`。