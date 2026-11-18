# Server Account Provisioning

面向实验室和教学服务器的 Codex skill。根据学号或用户名定位 Linux 账号，查重后按统一目录布局开户，并记录逐账号的验收结果。

## 安装与配置

1. 在 GitHub 下载 ZIP 或克隆仓库。
2. 将仓库内的 `server-account-provisioning/` 文件夹完整复制到 Codex 的个人 skills 目录，或操作项目的 `.agents/skills/`。
3. 在操作工作区创建权限为 700 的 `.server-account-local/`，按 [配置示例](servers.example.md) 填写服务器。把该目录加入操作工作区的 Git 忽略规则。
4. 如需开户，通过权限为 600 的私有文件或受保护的标准输入提供初始密码。目标须支持 Bash、sudo 和 GNU/Linux 常见账号管理工具。开户脚本要求独立挂载的 `/data`、已存在的 `/data/private` 和符合要求的父目录权限。先在测试服务器运行 `--check`，再验收实际开户。

## 使用示例

- `$server-account-provisioning 查一下学号 000000000001 的账号在哪台服务器，先看本地记录。`
- `$server-account-provisioning 在 lab-a 为学号 000000000001 开户。`

实时查询和开户使用调用者授权的服务器访问。开户会配置 Conda 路径，安装 Conda 由部署方负责。开户脚本只为新账号设置初始密码，现有账号的密码重置由管理员另行处理。
