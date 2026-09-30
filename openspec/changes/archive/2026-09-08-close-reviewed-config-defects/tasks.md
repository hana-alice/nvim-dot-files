本清单在实施与验证后补录，勾选项只表示已有实现或已有验证证据。归档、隐私检查、提交与推送由后续收尾执行，不计为本清单已完成工作。详细证据见 `docs/release_1.9.0.md`。

## 1. Android 既有修复收口

- [x] 1.1 统一 build/DAP 的 Target/Configuration 解析与入口，验证当前配置产物的真实 DWARF 和 SONAME，拒绝不唯一的符号猜测。
- [x] 1.2 分离 host symbol 与 runtime module，普通 attach 不回放旧符号，只有成功 attach response 更新 reattach 快照。
- [x] 1.3 保留 app uid / shell control 的同设备同 binary 握手诊断边界，记录真机端到端仍受阻，不声明修复成功。

## 2. 状态归属与索引发布

- [x] 2.1 修复桌面 DAP binary prompt 的缺失依赖，并覆盖断点项目交接及活跃会话延迟交接。
- [x] 2.2 以完整 token owner 发布 lease，回收仅触及观察到的 owner；补充真实文件系统交错与 fail-closed 回归。
- [x] 2.3 隔离 watcher 项目状态与事件 generation，将绑定原 owner 的有界保存重试提取到 `dirty_save.lua`。
- [x] 2.4 使 iOS install/launch 完成状态写回捕获的项目地址，保持用户当前选择。
- [x] 2.5 使 Go reset/add 在暂存完成后发布，并使 Lua 索引可用性检查只读正式路径、校验格式、保留失败前的完整索引。

## 3. 编译语义与编辑交互

- [x] 3.1 移除 CDB 的 Editor 路径猜测，验证显式 response/Definitions/PCH，矛盾 unity 使用 exact fallback。
- [x] 3.2 修复 client position encoding、同行不同实体判断和 header 回调副作用前的新鲜度检查。
- [x] 3.3 使用 compiler inclusion 与磁盘签名失效 warm TU 和 destination cache，并以真实 Clang/sidecar fixture 验证保存变化。
- [x] 3.4 修复当前 Visual 替换、picker 后正常移动和 Git NUL 路径/rename/copy 解析，补充实际交互回归。

## 4. 工具与持续验证入口

- [x] 4.1 清空继承的 Mason 自动安装计划，保持已配置 server 的启用/禁用选择；只读 health 缺少 lazy.nvim 时直接失败。
- [x] 4.2 修正旧 smoke 的真实 host matrix 与 KEY=VALUE 数组断言；增加隔离 CI bootstrap、全量 Lua 和既有 Go 回归门禁。
- [x] 4.3 对齐 spawn 审计清单，将旧 header 源码形状断言改为实际异步行为测试，并保持 watcher 与 façade 行数门禁。

## 5. 已完成验证

- [x] 5.1 本机 `nvim --headless -l tests/run.lua`：1521/1521，0 failed；Clang/sidecar fixture 使用真实 LLVM 能力。
- [x] 5.2 新建隔离 Windows config/data，恢复锁定插件、编译并加载 c/cpp/hlsl parser；同一全量入口 1521/1521，退出码 0，core_health 范围 28/28。
- [x] 5.3 `scripts/headless_smoke.lua`：97/97；`scripts/lint_no_bare_globals.lua`：186 个 Lua 文件通过。
- [x] 5.4 `tools/cindex-uefilter` 的 `go test -p 1 -count=1 ./...` 通过；5 个改动 Python 文件 AST parse 与 `git diff --check` 通过。
- [x] 5.5 本轮 8 项修改行为规格严格验证通过；最终文档/规则 `structure` 回归 75/75；本机核心健康检查 PASS，未运行 live workspace/device。
