# public-mirror-privacy Specification

## Purpose

约束公开镜像的隐私防线：公开仓库只保存通用安全策略，任何可反推出私有项目、组织、人员、设备
或工作站身份的专属关键词 denylist 必须留在 Git worktree 之外，并由本地 Git hooks 在提交和
推送前强制执行，避免"为了检测泄漏而再次上传泄漏词表"。

## Requirements

### Requirement: 专属 denylist 只能存在于本地 Git 状态，本地 hooks fail closed

私有项目、组织、人员、设备、网络和工作站的专属匹配词 SHALL NOT 出现在任何 tracked 文件、
提交消息或 Git 历史中，拆分、编码、混淆或运行时拼装均不构成例外。专属 denylist MUST 存放在
Git directory 或 repo-local config 指向的 worktree 外部文件，不得被 staging/commit/push/归档。
本地 `pre-commit`、`pre-push` 与 `reference-transaction`（在 `prepared` 状态检查所有将更新的
`refs/heads/*`/`refs/tags/*`）MUST 从 worktree 外部加载同一份 denylist 并覆盖公开 scanner、
hook 安装器和安全文档本身；denylist 缺失、为空、不可读或正则无效时 hooks MUST fail closed。
这三个 hook 的 PASS/BLOCKED 结果 MUST 写入仅位于 Git directory 的审计日志，且日志 MUST NOT
复制 denylist 或命中内容。

#### Scenario: plumbing 命令绕过与 scanner 自我携带专属词

- **WHEN** 提交由 `git commit-tree` 创建并通过 `git update-ref` 移动 branch/tag，或 staged/
  pushed diff 向公开 scanner 加入专属关键词的可还原混淆形式
- **THEN** `reference-transaction` 在 ref 更新落盘前执行同一份本地 denylist，命中或 denylist
  缺失/无效时拒绝该 ref 更新
- **AND** scanner 自身的通用规则 allowlist 不得绕过对 scanner 源码本身的专属扫描

### Requirement: 隐私门禁独立于测试与可跳过 hooks，且不使用宽范围 push

隐私扫描 SHALL 被视为发布安全边界而不是测试；跳过测试/lint 的指令 MUST NOT 被解释为允许跳过
隐私扫描，也 MUST NOT 改用 `--no-verify`。公开 remote 的 push MUST NOT 使用 `--no-verify`、
`--all` 或 `--mirror`（会扩大 ref 范围并可能重新发布本地恢复历史）。本地 `pre-push` MUST 从
worktree 外文件加载公开 ref allowlist 并拒绝向未列出的 remote ref 推送；allowlist 缺失或为空
MUST fail closed。包含未脱敏历史的恢复引用 MUST 存储在 `refs/private-backup/` 等不会被
`git push --all` 包含的本地私有 namespace，不得使用 `refs/heads/*`、tag 或 remote-tracking ref。

#### Scenario: 用户要求跳过测试或尝试宽范围 push

- **WHEN** 用户明确要求本次不运行测试/lint，或操作者尝试 `git push --all`/`--mirror`/未批准 ref
- **THEN** 跳过指令只作用于该验证项自己的显式 override，commit/ref/push 隐私门禁仍必须运行
- **AND** `pre-push` 对未列入 allowlist 的 remote ref fail closed，私有恢复引用因不在
  `refs/heads/*`/`refs/tags/*` 而不进入普通发布集合

### Requirement: 公开 scanner 只保存通用规则，历史泄漏处置覆盖全部公开 refs

tracked scanner SHALL 只包含不可关联特定主体的通用凭据和网络风险模式（如私钥格式、通用 token
格式、RFC1918 地址范围）；专属身份规则 MUST 由本地 denylist 承担，公开 scanner 不得成为其
备份副本。发现已发布的专属关键词时，处置 MUST 审计全部公开 heads/tags/可见 refs；只清理默认
分支或只追加 redaction commit 不构成完成，旧 refs MUST 被安全重写或删除。改写公开历史时，
ref/push 门禁 SHALL 扫描新 ref 可达的完整历史而不是旧 tip 到新 tip 的空范围。

#### Scenario: 默认分支已清理但旧 ref 仍可达泄漏 DAG

- **WHEN** 任一公开 branch/tag 仍可到达含专属关键词的旧 commit/blob
- **THEN** 隐私清理状态仍为未完成，该 ref 必须被重写或删除后才能声明公开 refs 已清理
- **AND** 托管平台搜索缓存或隐藏 refs 仍暴露内容时记录为外部清理项

## 选型与踩坑

- **选型**：真实 denylist 只存在于 worktree 外部（Git directory 或 repo-local config 指向的
  外部文件），而不是作为"仅供扫描器使用"的仓内正则——因为"用于检测"不构成上传专属关键词的
  例外，混淆/编码/拆分同样视为泄漏。
- **选型**：额外挂 `reference-transaction` hook 而不仅依赖 `pre-commit`/`pre-push`，是因为
  `git commit-tree` + `git update-ref` 等 plumbing 路径可以绕过前两者；`reference-transaction`
  在 ref 真正移动前拦截，覆盖面更完整。
- **踩坑**：显式指定远端 URL 并配合 `push --no-verify` 是主动绕过，任何 client-side hook 都
  无法阻止，因此该命令被列为流程级禁止项而非依赖技术手段拦截；同理，真实 denylist 不能被
  放入公开 CI 作为"补偿"，因为公开 CI 本身就是需要防护的公开面。
- **重要事项**：只清理默认分支或只追加一条 redaction commit 不算处置完成——只要有任何公开
  ref 仍可达含泄漏内容的旧 commit/blob，就必须继续重写或删除该 ref。
