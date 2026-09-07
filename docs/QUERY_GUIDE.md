# 交付自检查询指南（3.4-3）

> 适用对象：考核官 / 验收人。以下命令在部署服务器上（SSH 登录后）执行，
> 用于**现场验证**两套服务及其内部可查询的对象：agent-compose 的项目/触发器、
> OctoBus 的能力集/服务/暴露方法。全部为只读查询，不产生副作用。

---

## 0. 登录

```bash
ssh root@<SERVER_IP>
```

两套服务均以容器常驻运行，命令统一以 `docker exec <容器名> ...` 进入执行。

---

## 1. agent-compose 平台：项目与触发器

```bash
# 查看 agent-compose daemon 状态
docker exec agent-compose agent-compose --host http://127.0.0.1:7410 status

# 查看项目（含 agent 数、scheduler 数）
docker exec agent-compose agent-compose --host http://127.0.0.1:7410 project ls

# 查看触发器（scheduler）
docker exec agent-compose agent-compose --host http://127.0.0.1:7410 scheduler ls
```

**预期结果（本项目）：**

```
project ls →
  ID             NAME               CONFIG FILE                   AGENTS  SCHEDULERS
  6364062c5646   security-baseline  /data/work/agent-compose.yml  1       1

scheduler ls →
  SCHEDULER     AGENT     TRIGGER         KIND  SOURCE       ENABLED
  1c06032063b2  baseline  daily-baseline  cron  declarative  true
```

即：存在 1 个项目 `security-baseline`、1 个启用中的定时触发器 `daily-baseline`（cron，每日执行）。

---

## 2. OctoBus 能力网关：能力集 / 服务 / 暴露方法

```bash
# 网关整体状态
docker exec octobus octobus status  --addr 127.0.0.1:9000

# 能力集（capset）
docker exec octobus octobus capset  list --addr 127.0.0.1:9000

# 能力服务及暴露方法
docker exec octobus octobus service list --addr 127.0.0.1:9000
```

**预期结果（本项目）：**

```
status →
  { "services": 1, "status": "ok" }

capset list →
  "capsets": [ { "ID": "devcap", "Name": "DevCap", "Enabled": true } ]

service list →
  "ID": "hello-service"
  "Name": "Hello Service"
  "Methods": [
     { "full_name": "hello.v1.HelloService/SayHello",
       "input_full_name": "hello.v1.HelloRequest",
       "output_full_name": "hello.v1.HelloResponse",
       "unary": true }
  ]
```

即：存在能力集 `devcap`，承载服务 `hello-service`，暴露方法
`hello.v1.HelloService/SayHello`（一元调用，入参 HelloRequest、出参 HelloResponse）。

---

## 3. 运行记录在哪查（3.4-4 完整执行一轮 + 可查记录）

> **服务器现场**：SSH 登录后查看
> ```bash
> ls -lt /opt/agent-compose/data/work/
> cat  /opt/agent-compose/data/work/baseline_report.txt   # 评估报告：采集+OctoBus调用JSON+逐项评估+整改
> cat  /opt/agent-compose/data/work/run_74c6b760_full_logs.txt  # 完整运行日志(267行)
> ```

> **GitHub 仓库**（对应存档）：`runs/` 目录
> ```
> runs/baseline_report.txt
> runs/run_74c6b760_full_logs.txt
> runs/run_prompt.txt
> runs/scheduler_daily_run_log.txt
> runs/README_考核结果.md
> ```

> `baseline_report.txt` 内保留了 STEP2 经 OctoBus 调用能力的**原始 JSON 响应**
> （`{"greeting":"Hello, security-agent, from OctoBus!","serviceId":"hello-service","instanceId":"hello-inst"}`），
> 即完整执行一轮 + 可查证据闭环。

---

## 4. 一句话口径

> 通过 `agent-compose project/scheduler ls` 可查询到项目 `security-baseline`
> 与定时触发器 `daily-baseline`；通过 `octobus capset/service list` 可查询到
> 能力集 `devcap` 与其暴露方法 `hello.v1.HelloService/SayHello`。全程只读，
> 可用于交付验收时现场演示。