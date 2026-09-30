# headless-test-harness Specification

## Purpose

提供在 `nvim --headless` 无 UI 环境下运行的轻量测试框架：统一运行入口、最小断言与分组 API、
按约定自动发现用例，以及 runtimepath 自举，使配置模块可在不加载完整 `init.lua` 的情况下被
`require` 与测试。框架本身不承载具体业务断言，只提供跑测试所需的最小基础设施。

## Requirements

### Requirement: 统一 headless 运行入口且宿主能力如实上报

测试套件 SHALL 提供单一运行入口（`nvim -l tests/run.lua`），顺序执行 `tests/` 下全部注册用例，
末尾输出 PASS/FAIL/SKIP 汇总与非零退出码（存在失败时）。宿主能力缺失 SHALL 报告为带原因的
SKIP，MUST NOT 用空成功用例冒充执行；`NVIM_TEST_REQUIRE_NATIVE=1` 时此类跳过 SHALL 转为失败。
测试 SHALL 区分「本机不适用」（如目标操作系统不同）与「适用但工具缺失」，不得混淆两者的原因
上报；production 指定的安全 fallback SHALL 被验证而不注入假宿主或授予其证明资格。

#### Scenario: 一条命令跑全量回归并如实反映能力缺口

- **WHEN** 开发者执行统一运行入口
- **THEN** 终端输出每个用例的 PASS/FAIL 状态与失败原因，末尾打印汇总行
- **AND** 缺少原生工具时该组报告为带原因的 SKIP；设置 `NVIM_TEST_REQUIRE_NATIVE=1` 后此类跳过
  SHALL 变为失败并返回非零退出码
- **AND** 全部通过时退出码为 `0`，任意失败时为非零且失败名称与错误先于汇总打印

### Requirement: CI 提前退出时仍保留进度可见性

CI 执行权威套件时，运行入口 SHALL 在执行每个 spec/case 前先落盘其名称，使进程意外退出后最后
进入的用例仍可见；这类进度记录 MUST NOT 替代结果断言、最终汇总或失败退出码。

#### Scenario: 进程在最终报告前退出

- **WHEN** CI 执行过程中进程意外退出
- **THEN** 最后进入的 spec/case 名称已先于执行落盘，可用于定位卡住的位置
- **AND** 进度记录不构成通过证明，仍需完整汇总与退出码才算验收

### Requirement: 断言、分组 API 与用例隔离

测试框架 SHALL 提供最小可用的断言集（`assert_eq`/`assert_true`/`assert_type`/`assert_error`/
`assert_contains`）与 `describe`/`it` 分组，使每个用例可独立声明、独立失败而不影响其他用例；
框架 SHALL 提供按 `(mode, lhs)` 查询已注册 keymap 的辅助函数（`<leader>` 与空格前缀差异被规范化）。

#### Scenario: 单个用例失败被隔离

- **WHEN** 某个 `it` 块抛出错误
- **THEN** 框架捕获该错误并标记该用例为 FAIL，继续执行后续用例

### Requirement: 自动发现与 runtimepath 自举

测试框架 SHALL 按约定（如 `*_spec.lua`）自动发现并加载测试文件，新增用例无需修改运行入口；
SHALL 在 headless 环境下自行将配置根目录前置到 `runtimepath`/`package.path`，使 `require("ue")`
等模块解析不依赖完整 `init.lua` 加载；本地运行时 SHALL 使用隔离的测试日志/状态路径，MUST NOT
写入或清理用户真实日志目录。

#### Scenario: 无完整 init 也能 require 模块且不污染真实状态

- **WHEN** 测试入口以 `nvim -l` 启动且未加载完整插件管理器
- **THEN** `require("ue")` 等均可解析成功
- **AND** 测试产生的日志/状态写入隔离路径，不触及用户真实目录

## 选型与踩坑

- **选型**：required-native 语义（`NVIM_TEST_REQUIRE_NATIVE=1` 把 SKIP 升级为失败）用于 CI
  强制验收真实编译器/工具链路径，避免本地开发默认要求全部原生依赖齐全。
- **选型**：CI 车道分工——仅 Windows 列为必需 LLVM 验收通道，Linux/macOS 不强制要求 LLVM，
  依赖能力时报告显式 skip；这是当前既定范围划分，不是遗漏。
- **踩坑**：CI 进程可能在最终汇总前异常退出，若不预先落盘每个 spec/case 名称，排障时无法定位
  卡在哪一个用例；处置为执行前先写入进度记录（不作为通过证明）。
- **重要事项**：「不适用」（宿主/平台天然不支持）与「适用但工具缺失」必须区分上报原因，否则
  会把真实缺口误报为设计外场景而被忽略。
