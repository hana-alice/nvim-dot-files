# hana-alice/nvim 2.15.1 — 默认 v26 私有 bin、llvm fork 子模块、三平台 CI 恢复全绿

> Patch。用户 2026-11-11 授权 sync / archive / commit / push，按脱敏要求归档。tag 待用户确认。

## 新能力与调整

- **默认私有 bin 改为 `metadata-v26`**：`index.pch_offline.bin_dir` 现在指向 2.15.0 计时实际使用的构建（PGO + ThinLTO + rpmalloc + overlay 缓存）。目录不存在时行为不变：探测失败，不走离线路径。
- **fork 源码公开**：
  - 仓库 `hana-alice/llvm-project`，分支 `clangd-pch/v26`，tag `clangd-pch-v26`。
  - 在 `llvmorg-22.1.5` 之上只有 1 个提交，改动 20 个文件，+2033/-75。
- **子模块 `third_party/llvm-project`**：
  - 设为 `update = none`、`shallow = true`，递归 clone 时不会拉 llvm。
  - 需要源码时手动执行 `git submodule update --init --checkout --depth 1 third_party/llvm-project`。
- **预编译二进制**：GitHub release `v2.15.0` 附带 `clangd-pch-22.1.5-v26-windows-x64.zip`，内含 `clangd.exe`、`clangd-pch-probe.exe`、LICENSE 和补丁。两个 exe 只依赖系统 DLL。

## 实测范围与结论

- **headless CI 三平台全绿**：push 和 pull_request 两轮都通过。

  | 平台 | 结果 |
  | --- | --- |
  | ubuntu | 4278/4278，100 skip |
  | macOS | 4393/4393，75 skip |
  | Windows | 4485/4485，4 skip |

  Windows 上 3 个原生离线加载用例这次是实际执行通过的，不是跳过。
- **CI 失败的起点**：从 `c7090a0`（2026-11-05）开始一直失败，并不是本次改动引入的。
- **待验证**：本地全量回归中 `git_review_tree` 有 1 例偶发失败（关闭 explorer 后仍残留 1 个引用）。单独重跑 3/3 通过，CI 三平台都没出现，原因尚未定位。

## 归档记录

### 2026-11-11 — Default private offline-index bin to the v26 build

**Implemented**
- `lua/ue/config.lua`、`lua/ue/index/pch_offline.lua`、`tests/cases/index_pch_offline_spec.lua`：默认 bin 从 `metadata-v24c` 改为 `metadata-v26`。
- 新增 `.gitmodules` 和 gitlink `third_party/llvm-project`，指向 `hana-alice/llvm-project` 的 `clangd-pch/v26`。
- fork 提交的作者和 tagger 改用 GitHub noreply 身份，没有直接推送带公司邮箱的本地快照提交。

**Validation**
- `index_pch_offline` 13/13；py 42/42；`structure` 85/85；本地全量 4484/4485 + 2 skip（唯一失败即上文的 `git_review_tree` 偶发项）。

### 2026-11-11 — Fix headless CI on all three hosts

**Implemented**
- `tools/clangd_pch_offline.py` `parse_depfile`：在 POSIX 宿主上也把 Windows 盘符路径（`D:\...`、`C:/...`）当作绝对路径。修复 ubuntu/macOS 的 Python 用例。
- `lua/utils/clangd_workspace.lua` `add_candidate`：额外按 `compile_commands.json` 的 dev:inode 去重。在大小写不敏感的文件系统上，不再让 `build/Debug` 覆盖 preset 声明的 `build/debug`。修复 macOS 的 2 个用例。
- `.github/workflows/headless.yml`：Windows 原生通道下载 release `v2.15.0` 的 zip，校验固定的 sha256 后装到默认 bin 目录。修复 3 个 `private-binaries-missing` 用例。

**Pitfalls / Gotchas**
- PR #21 在 CI 修复推送之前就以 `2f238ed` 合并了，修复只能通过 PR #22 进入 main。我曾把"PR head 没更新"误判为 GitHub 同步延迟，实际原因是 PR 已关闭，特此更正。
- 用 `| Select-String` 过滤回归输出时，统计行会被吞掉。改为先把完整日志落盘，再从文件中提取。

**Validation**
- CI run 42964097652（push）和 42969061278（pull_request）均 success，各平台数字见上表。
