# Agent 安全基线巡检 考核结果摘要 (agent-compose + OctoBus + DeepSeek)

考核项 | 状态 | 说明
--- | --- | ---
Project apply | ✅ | project `security-baseline`，agent `baseline`，已 `up` 到 daemon
Agent 真实跑通一轮 | ✅ | `agent-compose run baseline --prompt ...` ，status=succeeded, exit_code=0, stopReason=completed
DeepSeek LLM 参与 | ✅ | provider `codex` + model `deepseek-chat`，经 daemon LLM Facade + 环境 LLM_API_PROTOCOL=chat_completions 指向 DeepSeek
LLM 与脚本分工明确 | ✅ | 确定性采集由 `security_baseline_check.sh`（纯 bash）完成；LLM 只做风险评估/整改建议
能力调用走 OctoBus | ✅ | agent 在工作区 curl `octobus:9000/capsets/devcap/connect/hello-inst/hello.v1.HelloService/SayHello`，网关返回 JSON，未绕过
重启自恢复 | ✅ | 重启 daemon 后 project/agent 持久（DB），sandbox 被 daemon 重新挂接存活

## 关键目录/文件（服务器路径）
- /opt/agent-compose/data/work/agent-compose.yml                # 构建的 project 定义
- /opt/agent-compose/data/work/baseline-scripts/security_baseline_check.sh  # 确定性采集脚本
- /opt/agent-compose/data/work/run_prompt.txt                   # 本次 run 的 prompt
- /opt/agent-compose/data/work/run_74c6b760_full_logs.txt       # 完整运行日志(267行)
- /opt/agent-compose/data/work/baseline_report.txt              # Agent 产出评估报告(56行)

## 运行关键片段
run id: 74c6b760932922a93ea768309be36c1a861962bc14147e5076416667dda2de1f
sandbox: beecf2023a53
OctoBus 调用响应: {"greeting":"Hello, security-agent, from OctoBus!","serviceId":"hello-service","instanceId":"hello-inst"}