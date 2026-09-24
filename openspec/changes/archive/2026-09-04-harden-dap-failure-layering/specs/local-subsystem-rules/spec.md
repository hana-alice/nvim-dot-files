## ADDED Requirements

### Requirement: 高踩坑密度目录的本地规则 SHALL 声明其归属分层契约

当某目录的失败按**归属层**分类（例如 DAP 的宿主工具链 / 传输 / 目标 OS 策略 / 调试引擎 /
符号语义五层）时，该目录 `AGENTS.md` SHALL 声明这套分层与每层 owner，并 SHALL 声明
「失败必须先报层再给处置」的纪律。

该声明 SHALL 位于本地规则内容源（`AGENTS.md`）中，使进入该目录的 agent 就地发现，
MUST NOT 只存在于源码注释或 changelog。

#### Scenario: DAP 目录规则声明五层契约

- **WHEN** agent 进入 `lua/ue/dap/` 并读取其 `AGENTS.md`
- **THEN** 该文件 SHALL 列出五层归属契约与每层 owner
- **AND** SHALL 声明失败先报层的纪律
- **AND** SHALL 指向治理该契约的 capability spec
