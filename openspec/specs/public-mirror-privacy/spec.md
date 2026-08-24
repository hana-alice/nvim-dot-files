# public-mirror-privacy Specification

## Purpose

约束公开镜像的隐私防线：公开仓库只保存通用安全策略，任何可反推出私有项目、组织、人员、设备或
工作站身份的专属关键词 denylist 必须留在 Git worktree 之外，并由本地 Git hooks 在提交和推送前
强制执行，避免“为了检测泄漏而再次上传泄漏词表”。

## Requirements

### Requirement: 专属 denylist 只能存在于本地 Git 状态

私有项目、组织、人员、设备、网络和工作站的专属匹配词 SHALL NOT 出现在任何 tracked 文件、提交
消息、测试 fixture、生成物或 Git 历史中。该限制同样适用于拆分字符串、编码、混淆、运行时拼装和
仅供扫描器使用的正则；“用于检测”不构成上传专属关键词的例外。

专属 denylist MUST 存放在 Git directory（默认 `$(git rev-parse --git-path private-denylist)`）或由
repo-local Git config 指向的 worktree 外部文件。该文件 MUST NOT 被 staging、commit、push、归档或
复制进公开诊断证据。

#### Scenario: 检测器需要新增专属关键词

- **WHEN** 贡献者发现新的私有项目、组织、人员、设备或工作站标识需要拦截
- **THEN** 只更新本地 denylist
- **AND** 不修改公开 scanner、spec、hook 模板、测试 fixture 或文档来携带该关键词

#### Scenario: 专属关键词被混淆后写入 tracked 文件

- **WHEN** 某 tracked 文件通过字符串拆分、编码或运行时拼装保存专属关键词
- **THEN** 仍视为隐私泄漏并拒绝提交/推送
- **AND** 不得以“源码中没有连续明文”为理由放行

### Requirement: 本地 hooks 对专属 denylist fail closed

本地 `pre-commit` 与 `pre-push` hooks MUST 从 worktree 外部加载同一份专属 denylist，并扫描对应
staged/pushed diff 的全部新增行。专属扫描 MUST 覆盖公开 scanner、hook 安装器和安全文档本身，
不得设置 allowlist；否则 denylist 最容易通过“检测器规则”重新进入仓库。

denylist 文件缺失、为空、不可读或包含无效正则时，hooks MUST fail closed 并拒绝操作。报错 MAY
报告本地规则序号和命中行，但 MUST NOT 将完整 denylist 复制进 tracked 日志或生成物。

#### Scenario: scanner 源码重新包含专属规则

- **WHEN** staged 或 pushed diff 向公开 scanner 加入专属关键词、其正则或可还原的混淆形式
- **THEN** 本地 denylist 扫描该文件并拒绝操作
- **AND** scanner 自身的通用规则 allowlist 不得绕过专属扫描

#### Scenario: 本地 denylist 不可用

- **WHEN** hook 找不到本地 denylist、文件为空或某条正则无效
- **THEN** commit/push 被拒绝
- **AND** 提示修复本地 hook 配置，不得降级为 warning 后继续发布

### Requirement: 隐私门禁独立于测试与可跳过 hooks

隐私扫描 SHALL 被视为发布安全边界而不是测试。跳过测试、lint 或其他验证的指令 MUST NOT 被解释为
允许跳过隐私扫描。公开 remote 的 push MUST NOT 使用 `--no-verify`；`--all` 与 `--mirror` 也 MUST NOT
用于公开 remote，因为它们会扩大 ref 范围并可能重新发布本地恢复历史。

除 `pre-commit` 与 `pre-push` 外，本地 Git directory MUST 安装 `reference-transaction` hook，并在
`prepared` 状态检查所有将要更新的 `refs/heads/*` 与 `refs/tags/*`。该门禁 MUST 扫描新增 commit 的
提交消息、路径和 diff 新增行；非 fast-forward、root rewrite 或新 ref MUST 扫描新 ref 可达的完整
历史。这样 `git commit --no-verify`、`git commit-tree` 加 `git update-ref` 等路径仍不能移动含命中的
本地公开 ref。

`reference-transaction`、`pre-commit` 与 `pre-push` MUST 将 PASS/BLOCKED 结果写入仅位于 Git
directory 的审计日志，且日志 MUST NOT 复制 denylist 或命中内容。任何 client-side hook 都无法阻止
显式指定远端 URL 并配合 `push --no-verify` 的主动绕过，因此该命令属于流程级禁止项；“本地关键词
不得上传”的约束也排除了把真实 denylist 放入公开 CI 作为补偿。

#### Scenario: 使用 plumbing 命令创建并发布提交

- **WHEN** 提交由 `git commit-tree` 创建并通过 `git update-ref` 移动 branch/tag
- **THEN** `reference-transaction` 在 ref 更新落盘前执行同一份本地 denylist
- **AND** 命中、denylist 缺失或无效时 ref 更新被拒绝

#### Scenario: 用户要求跳过测试

- **WHEN** 用户明确要求本次不运行测试或 lint
- **THEN** 只使用该验证项自己的显式本地 override
- **AND** commit/ref/push 隐私门禁仍必须运行，不得改用 `--no-verify`

#### Scenario: 改写公开历史

- **WHEN** public ref 被 root rewrite、force-update 或移动到非后代 commit
- **THEN** ref/push 门禁扫描新 ref 可达的完整历史，而不是只扫描旧 tip 到新 tip 的空范围
- **AND** 扫描范围包含提交消息、路径和新增内容

### Requirement: 公开 ref 使用本地 allowlist

本地 `pre-push` MUST 从 Git directory 或 repo-local config 指向的 worktree 外文件加载公开 ref
allowlist，并拒绝向未列出的 remote ref 推送。allowlist 缺失或为空 MUST fail closed。公开 remote 的
默认 push refspec MUST 只包含批准的公开分支。

包含未脱敏历史的恢复引用 MUST 存储在 `refs/private-backup/` 或其他不会被 `git push --all` 包含的
本地私有 namespace；不得使用 `refs/heads/backup/*`、tag 或 remote-tracking ref 保存。新增公开分支
或 tag 前 MUST 先显式更新本地 allowlist 并重新执行完整隐私扫描。

#### Scenario: 意外执行宽范围 push

- **WHEN** 操作者尝试 `git push --all`、`git push --mirror` 或推送未批准 ref
- **THEN** 流程规则拒绝该命令，且 `pre-push` 对未列入 allowlist 的 remote ref fail closed
- **AND** 私有恢复引用因不位于 `refs/heads/*` 或 `refs/tags/*` 而不进入普通分支/tag 发布集合

### Requirement: 公开 scanner 只保存通用规则

tracked scanner SHALL 只包含不可关联特定主体的通用凭据和网络风险模式，例如私钥格式、通用 token
格式或 RFC1918 地址范围。专属身份规则 MUST 由本地 denylist 承担；公开 scanner 与本地 denylist
是叠加关系，前者不得成为后者的备份副本。

#### Scenario: 公开安全规则需要扩展

- **WHEN** 新规则描述的是跨项目通用的凭据或网络风险类别
- **THEN** 可以更新 tracked scanner
- **AND** 规则不得包含或编码任何特定项目、组织、人员、设备或工作站标识

### Requirement: 历史泄漏处置覆盖所有公开 refs

发现已发布的专属关键词时，处置 MUST 审计全部公开 heads、tags 和其他可见 refs；只清理默认分支
或只追加 redaction commit 不构成完成。旧 refs MUST 被安全重写或删除，并保留不被推送的本地恢复
引用。托管平台搜索缓存或隐藏 refs 仍暴露内容时，MUST 记录为外部清理项。

#### Scenario: 默认分支已清理但旧 ref 仍引用泄漏 DAG

- **WHEN** 任一公开 branch/tag 仍可到达含专属关键词的旧 commit/blob
- **THEN** 隐私清理状态仍为未完成
- **AND** 该 ref 必须被重写或删除后才能声明公开 refs 已清理
