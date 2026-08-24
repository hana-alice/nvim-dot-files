# editor-behavior-regression Specification

## Purpose

定义针对本 Neovim 配置中编辑器行为的回归测试覆盖范围：验证 `lua/config/options.lua` 设置的关键 option 取值、自定义 filetype 映射与 FileType autocmd 的可观察行为、workarounds 注册表完整性，以及关键模块重复加载/初始化的幂等与稳定性，确保「开发完跑一遍」即可发现编辑器行为层面的回归。

## Requirements

### Requirement: 编辑器 options 回归

回归套件 SHALL 验证 `lua/config/options.lua` 设置的关键 option 取值符合预期。

#### Scenario: 缩进与行号 option

- **WHEN** options 用例加载 `lua/config/options.lua` 后读取
- **THEN** `expandtab` 为 true、`shiftwidth`/`softtabstop`/`tabstop` 均为 4
- **AND** `number` 为 true、`relativenumber` 为 false

#### Scenario: session 与 list option

- **WHEN** options 用例读取
- **THEN** `sessionoptions` 含 `buffers`、`tabpages`、`winsize`、`skiprtp`
- **AND** `list` 为 false

### Requirement: filetype 与 autocmd 行为回归

回归套件 SHALL 验证自定义 filetype 映射与 FileType autocmd 的可观察行为。

#### Scenario: usf/ush 解析为 hlsl

- **WHEN** 用例加载 options 配置后，对 `foo.usf` / `bar.ush` 调用 `vim.filetype.match`
- **THEN** 返回的 filetype 为 `hlsl`

#### Scenario: C 家族缩进切换为 cindent

- **WHEN** 用例创建一个 `cpp` filetype 的 buffer 并触发 FileType autocmd
- **THEN** 该 buffer 的 `cindent` 为 true、`smartindent` 为 false
- **AND** `cinoptions` 为配置中的 `g0,:0,l1,(0,W4,t0,j1,J1`

#### Scenario: commentstring 回退

- **WHEN** 用例对 `hlsl` filetype 调用 commentstring 回退逻辑
- **THEN** 解析出的 commentstring 含 `%s` 且为 `// %s`

### Requirement: workarounds 注册表完整性回归

回归套件 SHALL 验证 workarounds 注册表能发现所有 workaround 文件、frontmatter 合法且无加载错误。

#### Scenario: 全部 workaround 被发现且无 error

- **WHEN** 用例调用 `require("workarounds").setup({ auto_apply = false })` 后读取 `list()`
- **THEN** 返回的条目数 ≥ 实际 `lua/workarounds/<scope>/*.lua` 文件数
- **AND** 没有任何条目带有非 nil 的 `error` 字段

#### Scenario: frontmatter 必填字段齐全

- **WHEN** 用例遍历注册表条目
- **THEN** 每个无 error 条目均含 `name`、`scope`、`symptom`、`introduced`、`removal_condition` 等必填字段
- **AND** `enabled` 字段为 boolean

#### Scenario: status 查询形状正确

- **WHEN** 用例对任一已注册 workaround 调用 `status(name)`
- **THEN** 返回 table，含 `name`、`scope`、`applied` 字段
- **AND** 对未知名称调用返回 nil

### Requirement: 稳定性与幂等回归

回归套件 SHALL 验证关键模块的重复加载与重复初始化是幂等且无状态泄漏的，守护 nvim 功能稳定性。

#### Scenario: 模块重复 require 幂等

- **WHEN** 用例对 `ue`、`ue.config`、`utils.platform`、`utils.ue_paths` 连续 require 两次
- **THEN** 两次返回同一 table 引用（`==`）

#### Scenario: ue.setup 可重复调用

- **WHEN** 用例连续调用 `require("ue").setup()` 两次
- **THEN** 两次均无异常
- **AND** 关键命令（如 `UEBuild`、`UEDAPAttach`）在两次后仍 `exists == 2`

#### Scenario: config 多轮 override/reset 无泄漏

- **WHEN** 用例执行三轮 `ue.config.setup({...})` → `reset_for_test()`
- **THEN** 每轮 reset 后 `index.idle_cold_ms` 均恢复为默认 120000
- **AND** 末轮结束后 `dap.lldb_dap_path` 为 nil

#### Scenario: DAP 平台注册可重复清空

- **WHEN** 用例连续两次 `ue.dap.platforms._reset_for_test()` 后注册并查询
- **THEN** 注册的 handler 可被 `attach_handler` 取回
- **AND** reset 后未注册项返回 nil
