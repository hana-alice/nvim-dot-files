## 1. 测试框架（harness）

- [x] 1.1 新建 `tests/` 目录与 `tests/harness/init.lua`，实现 runtimepath/package.path 自举（前置 `vim.fn.stdpath("config")`），确保 `nvim -l` 下 `require("ue")` 可解析
- [x] 1.2 在 harness 中实现断言集合：`assert_eq`、`assert_true`、`assert_false`、`assert_nil`、`assert_type`、`assert_error`，失败时抛出含 expected/actual 的可读信息
- [x] 1.3 实现 `describe(name, fn)` 与 `it(name, fn)` 分组，用例名拼接为 `describe > it`，并用 `pcall` 隔离单个 `it` 失败不中断后续
- [x] 1.4 实现结果收集与报告：逐条打印 PASS/FAIL（FAIL 在前并附错误），末尾打印 `=== N/M passed, K failed ===`，全绿 `vim.cmd("quit")`，有失败 `vim.cmd("cquit 1")`
- [x] 1.5 导出 harness 公共接口（`describe`/`it`/各 `assert_*`/`run`），供用例文件 require 复用

## 2. 统一运行入口

- [x] 2.1 新建 `tests/run.lua`：自举 rtp、设置 `vim.g.started_with_stdin=true`，用 `vim.fn.glob` 发现 `tests/cases/*_spec.lua` 并按名排序 `loadfile` 执行
- [x] 2.2 在 `run.lua` 中调用 harness 的 `run()` 汇总并以正确退出码结束
- [x] 2.3 （可选增强）支持 `--filter <pattern>` 环境变量/参数，仅运行匹配的用例文件，便于开发中快速迭代
- [x] 2.4 新建 `scripts/run_regression.ps1`：定位 `nvim`、调用 `nvim -l tests/run.lua`、转发退出码（仅做转发，不含测试逻辑）

## 3. 配置加载冒烟用例

- [x] 3.1 新建 `tests/cases/smoke_spec.lua`：断言 `require("ue")`、`ue.config`、`utils.platform`、`utils.log` 均返回 table
- [x] 3.2 在 smoke 用例中调用 `require("ue").setup()` 无异常，并用 `vim.fn.exists(":Cmd")==2` 验证 `UEDAPAttach`/`UEDAPLaunch`/`UEDAPContinue` 等关键命令已注册

## 4. 平台驱动契约用例

- [x] 4.1 新建 `tests/cases/platform_spec.lua`：遍历 `windows/macos/linux/stub`，断言 `id` 匹配且 `shell/open_path/reveal_file/cmd_quote/default_clangd_candidates/default_lldb_dap_paths/default_lldb_server_paths` 均为 function
- [x] 4.2 断言 `utils.platform` 的 `is_windows/is_mac/is_linux` 为 boolean、`id` 为非空 string、`driver().shell()` 非空

## 5. ue 公共 API 与 config 用例

- [x] 5.1 新建 `tests/cases/ue_api_spec.lua`：迁移 `headless_smoke.lua` 的 PUBLIC_TABLES 与 PUBLIC_FUNCTIONS 冻结断言
- [x] 5.2 新建 `tests/cases/ue_config_spec.lua`：断言 `index.idle_cold_ms`/`context.ttl_s`/`cdb.steps`/`dap` 默认值，验证 `setup()` override 后 `reset_for_test()` 可恢复

## 6. ue.cdb 子模块用例

- [x] 6.1 新建 `tests/cases/ue_cdb_spec.lua`：迁移并断言 `ue.cdb.json.template_entry/program`、`ue.cdb.paths.targets/candidates`、`ue.cdb.shaders.augment/make_entry` 的既有契约

## 7. DAP 平台注册用例

- [x] 7.1 新建 `tests/cases/dap_spec.lua`：断言 `ue.dap.platforms.register_attach`+`attach_handler` 可调用、未注册 `launch_handler` 返回 nil、`_reset_for_test` 生效
- [x] 7.2 遍历 `win64/mac/linux/ios/android`，断言各模块 `attach`/`launch` 为 function，且 `ue.setup()` 后均在 platforms 注册

## 8. 工具函数加载用例

- [x] 8.1 新建 `tests/cases/utils_spec.lua`：require `utils.code_search`、`utils.ue_goto`、`utils.log`、`utils.ue_paths`，断言返回 table 且被回归依赖的关键函数为 function

## 9. 旧脚本收编与文档

- [x] 9.1 确认 `tests/run.lua` 全量执行后覆盖等价于 `headless_smoke.lua`；旧文件保留为兼容入口，不删除
- [x] 9.2 评估 `scripts/test_*.lua`（ue_goto）可在纯 headless 跑通的子集，在 `run.lua` 旁路调度纳入，需 clangd/socket 的标注跳过（与 `run_all_tests.ps1` 现有排除一致）
- [x] 9.3 新增 `docs/` 回归测试文档：如何一键跑全量、如何新增 `*_spec.lua`、退出码约定、覆盖口径说明
- [x] 9.4 在 `README.md` / `docs/TOOLING.md` 指向新入口为权威回归方式

## 10. 验证

- [x] 10.1 运行 `nvim -l tests/run.lua`，确认全部用例 PASS、退出码 0
- [x] 10.2 故意制造一个失败用例，确认 FAIL 输出含 `describe > it` 归属与 expected/actual，退出码为 1，验证后还原
- [x] 10.3 运行 `scripts/run_regression.ps1`，确认本机一键路径与退出码转发正确
