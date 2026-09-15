## ADDED Requirements

### Requirement: 归属分层契约 SHALL 通过唯一内容源对三端 agent 第一手可见

当某子系统定义了归属分层契约（failure layering）时，该契约 SHALL 通过既有唯一内容源
（根 `AGENTS.md` 层级）下发，使 Claude Code、Codex 与 pi 在 SESSION START 阶段即读到，
无需 per-agent 配置。MUST NOT 为让某一个 agent 生效而新增并行入口文件。

根 `AGENTS.md` 的 SESSION START SHALL 包含一条指引：改动带归属分层契约的子系统前，
先读该契约。该指引 SHALL 以指针形式给出权威出处，MUST NOT 在根文件复制契约全文
（避免与本地规则、CONSTRAINTS、spec 形成四份可漂移副本）。

#### Scenario: 三端读到同一份分层纪律

- **WHEN** 分别以 Claude Code、Codex、pi 在仓库根启动新会话
- **THEN** 三者自动加载的项目上下文均包含该分层契约的指引与出处指针
- **AND** 不存在 per-agent 分叉或第四份并行入口

#### Scenario: 根文件只给指针不复制正文

- **WHEN** 分层契约的细节发生变化
- **THEN** 仅需更新其权威出处
- **AND** 根 `AGENTS.md` 的指针 SHALL 仍然有效，不产生需要同步的正文副本

#### Scenario: 指引缺失被回归拦下

- **WHEN** 根 `AGENTS.md` 的 SESSION START 缺少该分层契约指引
- **THEN** 结构可发现性回归 SHALL 失败
