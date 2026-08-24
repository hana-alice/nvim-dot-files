# Proposal — restore-macos-unreal-semantics-and-search

## Why

macOS 上的 Unreal 编辑链存在三个互相放大的缺口：原生 LSP 没有在 root 解析后选择工程级受控
CDB；csearch/cindex 仍按 Windows/预装工具假设运行，真实增量 merge 会 panic；Apple toolchain
不保留 `.o.rsp` 时 super-unity 只能全量 exact fallback。与此同时，卡在 libclang native parse
中的 sidecar 没有 host-side 回收边界，会让后续 `gd` 持续排队。

这些问题必须以 compiler-authored evidence 为边界修复：可以复用真实 argv 和 exact file paths，
但不能合成编译 flags、用宽泛 root 覆盖增量索引，或把无证据的 fallback 宣称为语义成功。

## What Changes

- 在 LSP root 解析后生成 clangd project-scoped cmd，并让 exact-command transport 读取 resolved argv。
- 将 command-only CDB 按原始宿主语法正规化为 arguments，避免后续工具重新拼引号。
- 为 macOS/POSIX 提供固定版本 csearch + 仓内 cindex 安装入口和统一 Go bin discovery。
- 修复 `cindex-uefilter -files-from` 的 native merge Paths：add 只 shadow exact delta files，reset 只记录 roots。
- Apple 无 `.o.rsp` 时，仅对 exact compile context 完全一致且有 Apple target/SDK 证据的 unity group 压缩。
- 为 semantic sidecar 增加 host-side timeout 回收和下一请求冷启动恢复。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `ue-code-search`：补齐 POSIX 工具 bootstrap/discovery 与 exact-path incremental merge 合同。
- `macos-ios-cdb-semantic-prepare`：补齐 project-scoped clangd、command-only CDB 与 Apple no-rsp grouping 合同。
- `cpp-contextual-definition-navigation`：补齐卡死 semantic sidecar 的超时回收合同。

## Impact

- 修改 Neovim UE/LSP/search glue、受控 CDB Python 工具与仓内 Go cindex fork。
- 增加 Lua、Go 与真实命令链集成回归，并同步 README、bootstrap、architecture 和 changelog。
- 不修改 engine/project 源码，不新增运行时依赖，不把私有工程、用户、设备或凭据写入公开产物。
