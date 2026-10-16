# 日常编辑：内联提示实测（2026-10-03）

## 已验证范围

真实 Neovim 0.11.5、clangd 22.1.5，Windows x86_64。输入为工具现场生成的
**6007 行、186007 字节 UE-like C++ fixture**：包含 `UCLASS` / `GENERATED_BODY`
占位宏、`UObject` / `AActor` / `FVector` 示例类型、1000 个函数，以及密集的 `auto`
推导和参数调用。它没有真实 UE 头文件、UHT 生成代码、项目 CDB 或预编译头。

clangd 返回 **9000 条** `textDocument/inlayHint`，诊断 **0 条**；测试使用
`--background-index=false --enable-config=false -j=2 --log=error`，不启动工程全量索引。
缓存与 LSP 日志隔离在指定输出目录，用户已有编辑实例、缓冲区与工程文件未修改。

UI 客户端通过 MessagePack-RPC 调用 `nvim_ui_attach(120, 45, ...)`，启用
`ext_linegrid` / `ext_hlstate`，实际消费 Neovim 的 `redraw`、`grid_line`、`flush`
事件并重建屏幕。尽管子进程带 `--headless`，**这里挂有真实外部 UI 管道**，并非
仅测无 UI 的 headless 回调。所测范围为 Neovim 栅格生成、RPC 输出与 Python 解码；
**没有物理终端/Neovide 的字体栅格化、GPU、合成器或显示器帧率测量**。

## 请求与重绘结果

20 次全文件请求（测量工具使用同步请求以单独计时；日常内联提示仍由 Neovim
内置异步机制请求）：

| 指标 | 毫秒 |
|---|---:|
| clangd 初始化（含进程启动） | 405.609 |
| 首次请求（含本次 TU 冷解析；不代表 OS 冷缓存） | 289.575 |
| 后续 19 次请求 p50 | 113.182 |
| 后续 19 次请求 p95 / 最大值 | 123.973 |
| 内置提示从开启到可见 UI grid，第 1 / 2 轮 | 96.139 / 93.962 |

交替 OFF / ON / OFF / ON 四轮，每轮回放相同的 100 次移动光标、居中、完整重绘，
并通过额外 RPC barrier 消费该次绘制的输出。统计含 RPC 往返和客户端解码，不等于
纯 CPU 渲染时间：

| 内联提示 | p50 ms | p95 ms | 最大 ms | grid_line 事件 | 提示高亮 cell |
|---|---:|---:|---:|---:|---:|
| OFF 第 1 轮 | 1.992 | 2.373 | 3.219 | 4553 | 0 |
| ON 第 1 轮 | 1.918 | 2.359 | 2.707 | 4677 | 34852 |
| OFF 第 2 轮 | 1.427 | 1.737 | 1.902 | 4598 | 0 |
| ON 第 2 轮 | 1.929 | 2.117 | 2.391 | 4677 | 34852 |

ON 两轮均从内置 API 读到 9000 条提示；OFF 两轮为 0。重建屏幕中 ON 出现以下
可见行，OFF 没有 `Value:` / `Factor:`，工具对此有断言，避免「开关变 true 但根本没画」：

```cpp
2290     auto Speed: float = Scale(Value: DeltaSeconds, Factor: 381.0f);
```

ON 的 grid flush 数为 199，而 OFF 为 102：内联装饰产生额外刷新是实际观测，
不可表述为「零开销」。上述低个位数毫秒对照未显示明显重绘退化，但仅能支持此
fixture 和此 UI 管道的结论，不能推出真实 UE 工程或 Neovide 不会卡顿。

## 默认与开关：源码核对

已核对本机安装的 LazyVim / Snacks 源码：

- LazyVim `lua/lazyvim/plugins/lsp/init.lua` 的 `inlay_hints.enabled` 默认 `true`；
  自动启用监听支持 `textDocument/inlayHint` 的客户端，仅排除配置的 filetype
  （当前默认 `vue`），要求普通、有效缓冲区。
- LazyVim `lua/lazyvim/config/keymaps.lua` 将 `<leader>uh` 接到
  `Snacks.toggle.inlay_hints()`；Snacks `lua/snacks/toggle.lua` 通过
  `vim.lsp.inlay_hint.is_enabled/enable(..., {bufnr=0})` 仅切当前缓冲区。
- Snacks `lua/snacks/bigfile.lua` 默认在文件大于 **1.5 MiB**，或平均行长大于
  **1000 字节**时改为 `bigfile` filetype；不是超过 5000 行就禁用 LSP。本 fixture
  不达到该阈值。不建议为内联提示绕过原有 `bigfile` 保护。

**本次建议**：保留 clangd 普通 C/C++ 缓冲区默认开启，让 `<leader>uh` 随时关闭。
实测范围内请求为异步日常能力、UI 成本较小；没有证据支持把所有 UE 文件默认关掉。
这项建议不包含真实 UE 头/PCH/CDB、超大长行、索引高负载、实际 Neovide 渲染性能
保证，这些仍未验证。

## 复跑

工具只用 Python 标准库，不安装包：

```powershell
python tools/measure_inlay_hints.py --clangd 'C:/Program Files/LLVM/bin/clangd.exe' --output-dir .tmp/daily-edit-inlay --samples 100
```

输出目录保存生成 fixture、`result.json` 和 stderr 日志。报告数字来自本次
`result.json`；复跑结果会随宿主负载、缓存与工具版本变化。工具的屏幕断言要求
OFF / ON 提示可见性一致，否则直接失败。

本次验证：工具完整执行成功，`python -m py_compile tools/measure_inlay_hints.py`
通过；`nvim --headless -i NONE -l tests/run.lua structure` **78/78 passed，0 failed，
0 skipped**。运行时默认接线和最终全量回归由主任务另行验收。
