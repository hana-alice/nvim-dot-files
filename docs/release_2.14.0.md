# hana-alice/nvim 2.14.0 — 私有前缀 PCH 离线索引与 Tier 1 离线吸收

> Minor；用户 2026-11-09 授权 sync / archive / commit / push，脱敏归档，不创建 tag。

## 新能力

- **私有前缀 PCH 离线索引**（`lua/ue/index/pch_offline.lua` + `tools/clangd_pch_offline.py`）：full CDB 发布后，在同一 writer lease 内，由能力探测通过的私有 clangd 预先产出 shard，再交给官方 reader 加载。工具缺失、失败或超时时回到原交付路径。`ue.config` 的 `index.pch_offline.enabled = false` 可关闭。
- **离线吸收普通 Tier 1**（`tools/pch_offline_tier1.py`）：同一次私有运行判定三项门禁，通过的组写出按官方 reader 计算 key 的 receipt。编译失败的组按原 UBT 行在 retry lane 重新索引，失败只影响该组。
- **调度**：按 TU 排序（每个上下文先跑 seed，其余按成员数降序）；seed gate；prefix shard 预载；按 prefix 头列表合并只差路径拼写的上下文。

## 实测范围与结论

- 全量回归 `nvim --headless -l tests/run.lua`：**4485 通过，0 失败，2 个显式跳过**。
- 正确性：多轮冷全量回落 0，官方 clangd 22.1.5 重载 0 重建、0 改动。
- 耗时：单次最好 509.9 s。宿主有并发负载时 640–780 s，同 TU 慢 25–90%，有 v20 对照确认。空闲宿主上的复测和 nvim 内端到端尚未完成，本版本不宣称用户侧冷索引已达 600 s。
- 私有 clangd 二进制与研究数据不进公开仓。

## 归档记录

### 2026-11-09 — 归档整理：_build.lua 拆分回到 800 行门禁内

**Implemented**
- 构建失败的日志与 notify 移到 `_delivery.lua` 的 `M.report_index_build_failure`，离线 Tier 1 请求的组装移到 `pch_offline.lua` 的 `M.pch_offline_tier1_request`，行为不变。`_build.lua` 从 821 行降到 799 行。
- `index_delivery` 的源码断言改为合并读取 `_build.lua` 和 `_delivery.lua`。
- `memory/project_overview.md`、`docs/architecture/overview.md` 补上私有前缀 PCH 离线索引子系统。

**Validation**
- 全量回归 4485/4485，2 个显式跳过；拆分后 `stability` 26/26、`index_delivery` 150/150、`index_pch_offline` 13/13（required-native）。

### 2026-11-09 — 离线 PCH prefix shard 预载 + gate 按 prefix 头列表分组（v21，保留；绝对耗时待空闲宿主复测）

**Implemented**
- 私有 fork v21 新增 `CLANGD_EXPERIMENTAL_PCH_PRELOAD_PREFIX=1`：loadProject 之后，对每个 manifest profile 的 full metadata 里的 prefix 源做登记。只有存储中已有 shard、且 digest 与磁盘文件一致的才登记进 ShardVersions。原因是 loader 只沿 main 文件的 include 边做 BFS，强制 `-include` 的 prefix 头不在这些边上，以前从来不会被加载。
- seed gate 的分组键从 FullPCH 路径改成规范化后的 prefix 头列表（小写、`/`）。有 9 对上下文只差路径分隔符，现在共用一个 seed。
- seed 自己选到 thin 时，立即释放被 park 的 TU。
- `tools/clangd_pch_offline.py`：默认开预载，`PCH_OFFLINE_PRELOAD_PREFIX=0` 关闭；retry lane 额外拷贝锚点上下文 prefix 源的 shard。
- 默认私有 bin 从 `metadata-v18` 切到 `metadata-v21`（`ue.config` 的 `pch_offline.bin_dir`）。

**Validation**
- py 38/38；`index_pch_offline` 13/13。
- 小样本（s8 配方，j2）：v21 57.8 s，v20 72.3 s；retry full 2→0；main shard 字节相同。
- cold9：工具 639.1 s，正确性 ok（回落 0，shard 32450）。机制生效：retry 52/52 thin，paired full 25→18。但同一 TU 的耗时整体比 cold8 慢约 27%，宿主平均 CPU 87%（cold8 为 74%）。
- cold10（v21）695.8 s，cold11（v20 对照）779.7 s，宿主条件相同（用户进程并发）。v20 更慢，所以 cold9–11 的变慢属于宿主效应，v21 保留。cold10 官方 reader 0 重建、0 改动。绝对耗时待空闲宿主复测。

### 2026-11-09 — 离线 PCH seed gate；撤回 EcoQoS / skip-rebuild 实验

**Implemented**
- 私有 fork v20 新增 `CLANGD_EXPERIMENTAL_PCH_SEED_GATE=1`。同一个 manifest profile 里，seed 还在跑的时候，后面的 TU 先 park，不占 worker。seed 结束后按原优先级重新入队（`Key=0`，绕过 BackgroundQueue 去重），这样这些 TU 选到的是 thin PCH，不再做第二次 full 解析。
- `tools/clangd_pch_offline.py` 默认打开 gate，用 `PCH_OFFLINE_SEED_GATE=0` 关闭。没有这个 hook 的 clangd 会忽略该变量。

**Pitfalls / Gotchas**
- 已证伪：「clangd 里 background 优先级带 EcoQoS，会降低约 15% 吞吐」。实际上 LLVM 定义了 `_WIN32_WINNT 0x0601`，EcoQoS 分支被编译掉了，background 和 low 是等价的。工具保持 `background`，注释已更正。
- 停用 skip index rebuild（v19）：没有收益，而且头 shard 有不确定性。工具不再设置它。
- 第一版 gate 重新入队时，任务被 BackgroundQueue 按 Key 去重丢掉了，结果是 712/1001 shard、5 个回落。工具的回落检查当场发现了这个问题。

**Validation**
- `python -B -I tests/py/test_clangd_pch_offline.py` 38/38；`index_pch_offline` 13/13。
- 小样本 s21：开 gate 时 retry 1 full / 5 thin，回落 0，两次运行之间 shard 0 差异。
- 冷全量 cold8：工具 509.9 s（cold7 为 584.6 s），回落 0，shard 32450。官方 reader 0 重建、0 改动，33.8 s。n=1。

### 2026-11-06 — 离线 PCH 吸收普通 Tier 1 proof（方向 A）

**Implemented**
- 新增 `tools/pch_offline_tier1.py`，`tools/clangd_pch_offline.py` 增加 `--tier1-plan` / `--tier1-clangd` /
  `--server-profile`。私有 paired 输入接收后台 proof 计划里的普通 Tier 1 组，形式是规范 wrapper。
  compile_success、main_shards_complete 和 members_equal 三个门禁由同一次私有运行判定。
  通过的组写 schema-1 receipt，按官方 reader clangd 计算 key；被拒的组回落原 UBT 行，失败只影响该组。
- `lua/ue/index/pch_offline.lua`：full 阶段持有 writer lease，依次运行：
  1. `--plan --auto-tier1-large`；
  2. 离线工具；
  3. 针对 accepted ids 的 cache-only `--collect`，经隔离发布 worker 发布。
  plan 失败时工具照常运行，只是不带 Tier 1。collect 后 base 签名变化时拒绝激活。
- `lua/ue/index/_batch_background.lua`：抽出 `M.apply_background_activation`。新增
  `drain=false` / `restart=false` 两个选项，由离线路径自己负责一次 reader 重载。
- 私有 binary 名改用平台驱动的 `exe_suffix`，不再硬写 `.exe`。spawn 起点工具失败时报
  `offline-tool-spawn`。

**Pitfalls / Gotchas**
- 资格权威变更：吸收组的 Tier 1 资格证据从官方 clangd 重新索引改为私有 PCH clangd 索引。
  用户已批准；依据是 R47c 官方重载 0 重建、主 shard 逐字节一致。
- 暖缓存下大部分组已被后台 proof 替换。live plan 实测只剩 7 个候选组，吸收的收益主要在冷构建。
- 已 cached-accepted 的组若私有运行失败，会映射回 wrapper，但 reader CDB 在 collect 发布前仍是原行。
- 带 packing 的大组（large-first 升级组）不吸收，仍由后台 proof 处理。

**Validation**
- `python -B -I tests/py/test_clangd_pch_offline.py` 35/35（新增 6 个 Tier1 用例）。
- `index_pch_offline` 13/13（新增 3 个接线用例）。
- `NVIM_TEST_REQUIRE_NATIVE=1` 下：`index_generation` 46/46、`cpp_semantic_index` 1/1、`clangd_commands` 23/23、
  `ue_api` 67/67、`index_batch_background` 104/104、`index_verified_batch` 131/131、`index_tier1_cohort` 28/28、
  `ue_config` 11/11、`ue_platform_boundary` 20/20、`host_resource_discipline` 13/13、`structure` 85/85。
  spawn 审计已为新的 vim.system 分类。
- 真实工程：live plan 步骤 29.8 s（3408 条目，7 组）。
  单组小样本（6 UBT/171 成员，j2）：wrapper 被私有运行接受，工具 77.6 s，峰值 3.56 GB。
  proof 的 cache-only `reuse_tier1` 对离线 receipt 命中 1/1。输入未变时重复运行 6.5 s，走 reuse。
  官方 reader 加载 wrapper shard 的 0 重建未单独验证。未跑全量回归。
- 修复：离线 reuse/delta 跳过时只上报 prepare 刚重新校验过的 receipt，不再沿用上次的 accepted ids。
  工具内 Tier 1 准备出错时 Lua 侧报 `tier1-prepare:` 并且不做 collect。Python 用例增至 36/36。
- 冷全量（离线工具段，私有实验目录，输入与 R48 相同 1225 行）：
  - 282 组吸收，1225 → 602 行，272 组通过，10 组编译失败回落 55 TU，producer 失败 0。
  - 工具 829.7 s（R48 1261 s），paired 592.7 s，解析量 −53%。
  - 抽查 7 组 cache-only 复用全部命中。
  - 后半程与另一离线运行并发。未达 600 s。
- 降低非索引开销（行为不变）：
  - Tier 1 prepare/commit 每组只开一个 overlay 读视图。共享的 owned overlay 每组读一次，退出时复核。
    冷输入上 prepare 从 30 s 降到约 20 s，输出与逐条读取版本一致；postcheck 从 19.6 s 降到 17.7 s。
  - shard 图解码、依赖 stamp 和发布拷贝改用 4 线程（`IO_THREADS`）。这几步都受文件打开延迟限制。
    发布仍是每个 shard 各自原子 copy+replace。线程化 rename 实测更慢，所以没有采用。
  - 验证：py 36/36；`index_pch_offline` 13/13、`host_resource_discipline` 13/13、`index_tier1_cohort` 28/28（required-native）。
    单组小样本（2 UBT，j2）：ok，发布 shard 与源逐字节一致，无残留临时文件；重复运行走 reuse，5.6 s。
    冷全量未重跑。
- 私有 clangd 调度（metadata-v18，默认 bin 由 v17 切到 v18）：
  - fork 加 `CLANGD_EXPERIMENTAL_INDEX_ORDER_FILE`：按文件排名定序，替代默认随机 shuffle；
    未列出的文件排在最后，读不到文件时打 elog 并保持原行为。
  - fork 加 `CLANGD_EXPERIMENTAL_SKIP_PUBLISHED_SHARDS`：头 shard 已由别的 TU 以相同 digest 写过（且不比它更差）时不再重写。
    工具默认开启，`PCH_OFFLINE_SKIP_PUBLISHED_SHARDS=0` 可关闭做对照。
  - 工具为每个 lane 写 `index-order.txt`：每个 PCH 上下文先跑一个最小 TU，让它的前缀 shard 先落地；
    其余按嵌套 `.cpp` 成员数从大到小（LPT）。成员数与 TU 耗时相关系数 0.769。
  - 坑：共享头 shard 内容取决于最后写它的 TU。两次都不开 skip、只是顺序不同，就有 306 个头 shard 字节不同。
    所以 skip 带来的差异（270 个）不是新的语义偏差，名字集合不变。
  - 验证：py 37/37；`index_pch_offline` 13/13（required-native）、`ue_config` 11/11。
    6 行小样本（j2）skip 关/开：工具 50.8 / 42.3 s，shard 数 1786 一致。
  - 冷全量（同 1225 行输入，空 store，j12，单次）：工具 545.2 s（829.7 s），paired 429.3 s（592.7 s）。
    282 组吸收，272 accepted，同样 10 组失败，回落 51 TU，producer 失败 0。
    宿主空闲内存最低 59.8 GB。前一次尝试在第 8 分钟遇到整机意外掉电，原因未定，结果作废。
  - 官方 clangd 22.1.5 重载这份 store（j12）：只重建回落的 51 个 TU，其余 31110 个 shard 0 改动，90 s。
    nvim 内端到端未跑。
- Tier 1 wrapper 编译失败组的离线重试（retry lane）：
  - 10 个失败 wrapper 的原因是成员之间真的冲突，不是环境问题。例如：同一 `StaticEnum<…>` 在实例化后又被显式特化；
    `redefinition of default argument` 导致 `LoadPackageInternal` 调用歧义；STAT 符号重复定义。
    这些组的原 UBT 行单独编译没有问题。
  - 工具在 tier1 judge 之后，把 `tier1-candidate-index-failed` 组的原 UBT 行（`pch_offline_tier1.retry_rows`）
    放进 `retry` lane，用同一个私有 PCH clangd 再索引一次。每个 PCH 上下文带一个已发布的干净锚点行，
    并把锚点的 shard 闭包拷进 lane。retry 产生的 shard 不覆盖 paired 已发布的 shard；HadErrors 的 shard 仍判拒绝。
    干净覆盖到的原行从 `fallback_tus` 中移除，官方 reader 不再重建它们。
  - 坑：私有 clangd 的 loader 只认「从 CDB 主文件沿 shard include 边能走到」的 shard 的 digest。
    强制 `-include` 的前缀头走不到，所以拷进去的前缀 shard 不会被看见，每个上下文的第一个 retry TU 会走 full PCH。
    曾试过用干净行闭包贪心覆盖前缀源文件（1563 个），最多只能覆盖 1204 个，覆盖不全就跳过了 retry（s9 回退）。
    已撤回，改回单锚点：首个 TU 走 full PCH，结果正确。
  - 验证：py 38/38（新增 retry_rows / covered 用例）；`index_pch_offline` 13/13。
    小样本（2 个失败组 4 UBT 行 + 2 个干净行，j2）：retry 4/4 覆盖，回落 0，工具 76.5 s（index_retry 18.9 s）。
    官方 reader 重载：0 重建、0 改动，10.4 s。冷全量未重跑。
  - 拆块回落的评估：cold3 的 51 个回落 TU 只落在 3 个 PCH 上下文。
    按官方 `_tier1_fallback_chunks` 规则（只拆跨 gen/src 类的组）模拟这 10 组，只有 2 组能拆（[3]、[4,4]），
    与官方 proof 的结果一致。离线拆块最多把 11 个 retry TU 换成 3 个 wrapper，收益小，暂不实现。
    失败组不写 receipt，稳态下二次合并仍由后台 proof 按官方规则拆块（C11 不退化）。
  - `lua/ue/index/pch_offline.lua`：`index-pch-offline-tier1` 探针新增 `retry_tus` / `retry_covered` / `fallback` 三个字段，
    nvim 端可以看到 retry 覆盖了多少、还剩多少回落。验证：`index_pch_offline` 13/13、`index_prepare_fixture` 8/8（required-native）。
  - 冷全量（同输入，v18 j12）验证 retry lane：工具 572.0 s（无 retry 时 545.2 s），retry 45/45 覆盖，index_retry 52.4 s，
    回落从 51 降到 6，mismatch 0。官方 reader 重载：passed，只重建这 6 个回落 TU，耗时 41.5 s（之前 90.1 s）；
    32280 个 shard 中 1 个改动（libc++ 头，同 digest 的 last-writer 差异），新增 170。
  - 剩下的 6 个回落属于同一个 PCH 上下文，该上下文没有任何已发布行，所以没有 profile，retry 筛选把它们丢掉了。
    修复：retry 行所在上下文缺少 profile 时，现场补跑 prefix PCH producer；同时补上 query-driver 缓存未命中的情况
    （只出现在 retry 行里的驱动以前会 KeyError）。新增报告字段 `tier1_retry_new_contexts`。
    验证：py 38/38、`index_pch_offline` 13/13；小样本只含这个失败组的 6 行（j2）：补 1 个上下文，retry 6/6，回落 0，
    工具 40.8 s；官方 reader 0 重建、0 改动，3.9 s。
  - 冷全量复测（带补上下文修复，同输入，j12）：retry 51/51，回落 0，mismatch 0；官方 reader 重载 0 重建、0 改动、0 新增，27.0 s。
    工具 646.4 s，比上次 572 s 慢：这次宿主有其他负载，私有 clangd 未运行时 CPU 仍有 32–90%，各阶段同时变慢；
    retry 段 68.5 s。性能这一次没有达标，待在空闲宿主上复测。
  - 空闲宿主复测：工具 635.8 s，回落 0。paired 在 4 次冷全量里分别是 429/414/437/435 s，cold4 偏快，真实基线约 630–645 s。
    之前说 646 s 主要是宿主干扰，这个说法不成立：私有 clangd 没在跑时，工具自己的 Python 阶段也占 CPU。
    慢的真正原因是 paired 之后各段串行：retry 66 s → publish 24.6 s → receipt commit 17.9 s。
  - 后台并行：judge 结束后，已发布 paired shard 的 publish 和 Tier 1 receipt commit 放到后台线程跑，与 retry lane 同时进行。
    retry 新产出的 shard 等 retry 结束后再补发布。retry 出现 mismatch 时只作废 retry 结果，paired 发布不受影响。
    新增报告字段 `contended_shards`、`tier1_commit_busy`。
    验证：py 38/38、`index_pch_offline` 13/13。
    小样本 s13（只含 retry 行）：shard 名集合与改动前相同，回落 0。
    小样本 s14（只含 accepted 组）：receipt 由后台写出，重复运行走复用，cache_hits 1。
    冷全量（同输入，j12）：
    - 工具 **584.6 s**（上次 635.8 s），回落 0，shard 32450，contended 0。
    - 分段：paired 429.6、retry 71.9；publish 1.0 s，后台 commit 48.5 s 被 retry 段完全盖住，tier1_receipts 0.01 s。
    - 官方 reader 重载：passed，0 重建、0 改动、0 新增，28.7 s。
    - 离线工具段 ≤600 s 达标（单次）。加上 reader 共 613 s。nvim 内端到端尚未验证。

### 2026-11-05 — 离线 PCH 全量验收：overlay 缓存、依赖回落、可配内存上限

**Implemented**
- `tools/clangd_pch_offline.py`：overlay 外部依赖按内容摘要缓存（同一 overlay 不再逐行重解析）；
  `phase_s` 记录各阶段耗时；干净 TU 的 include 闭包命中失败 TU 的 HadErrors 头 shard 时计入
  `dependency_fallback_tus` 并入回落集合；新增 `--process-gib`（每子进程内存上限，默认提到 16 GiB，宿主 8 GiB 保底不变）。
- 报告新增 `producer_failure_reasons`（每个失败 producer 上下文的首条 error）。

**Pitfalls / Gotchas**
- 每行重解析 25215 条目 overlay 让 633 行后处理耗时 460 s；缓存后 1–2 s。
- 单个 paired clangd j12 全量峰值 9.6 GB，默认 8 GiB 守卫会在启动后数秒杀掉它。
- 研究输入曾混用两份引擎目录导致 producer redefinition；生产不存在该情况，不做兼容。

**Validation**
- 真实全工程 633 行 CDB（自洽引擎根输入）j12、`--process-gib 16`：工具 550.3 s，paired 621 + ordinary 12，回落 0，
  发布 32451 shard；官方 clangd 22.1.5 重载 0 TU 重建、0 shard 改动（28.6 s）；633 主 shard 逐字节一致。
- `python -B -I tests/py/test_clangd_pch_offline.py` 29/29；`index_pch_offline` 10/10、`index_generation` 46/46、
  `cpp_semantic_index` 1/1。未跑全量回归。
- nvim 内真实 `:UEPrepare` 端到端（1225 行 CDB）：离线工具 ok、回落 0、producer 失败 0，工具 1261 s
  （paired 索引 1054 s），从触发到首次交付 1598 s，未达 600 s 目标；期间官方 clangd 并发全量索引。

**Follow-ups**
- 离线期间官方 clangd 并发全量索引造成重复工作；SuperUnity proof 在离线交付后继续改写 CDB 并重启 clangd。

### 2026-11-05 — R43 放行后接入 prepare full 的私有 PCH 离线索引（S2）

**Task**
- 保留 R42/R43 的证据，完成失败 receipt、私有能力探测与 prepare full 异步接线。

**Implemented**
- `tools/clangd_pch_offline.py`：完成态失败也写 receipt，记录失败 TU 与官方回落集合；
  producer 失败组直接交官方，输入不变跳过。OS advisory lock 在异常退出后自动释放；
  生产 `-j` 接受正整数，Windows IDLE、每进程 8 GiB 与宿主 8 GiB 内存守卫保持。
- `lua/ue/index/pch_offline.lua`：home 展开的私有 bin 通过真实 `clangd --version` 探测，
  按两二进制 size+mtime 缓存；`ue.config` 的 `index.pch_offline` 默认自动启用，可设 false。
- `_build.lua` 在 full CDB 发布后异步运行工具，持续持有原 lease/job；完成后复用唯一 reader
  交付路径。跳过且 CDB 未变不重启，缺工具/失败/超时记 probe 与日志后走原逻辑。
  SuperUnity 二次合并与 Tier 1 发布逻辑保持。
- 新增 Python 纯函数/receipt/锁单测与 Lua 宿主能力守卫、失败回落、异步交付回归；治理 spec
  `cpp-semantic-index-coverage` 记录该阶段选择与证据边界。

**Pitfalls / Gotchas**
- manifest 的文件键保留 CDB 原始拼写；argv 末尾的源路径使用 clangd 的本机形式，不能把两者统一。
- snapshot overlay 的解析字节与磁盘字节可能不同；官方 clangd 的启动失效检查使用物理文件系统，
  不能据此承诺该样本零重建，也不能篡改 shard 摘要绕过检查。
- producer 无 shard 时只有主 TU、直接 forced header 和 overlay 等已知依赖，完整传递依赖
  失效策略仍待 S3；本轮不将小样本接线验收当作全工程性能恢复。

**Validation**
- 保留历史：R42 的 20 TU overlay 样本 Stage 1 **FAIL**，官方重建 8 TU；R43 已确认与 R41
  重建集合相同，按磁盘真相重测后，已发布 12 TU 官方重建 0，18 个重建等于离线失败集合，放行 S2。
- R44 同一 30 TU 工作区、j2：3 上下文、4 paired、0 mismatch/unlisted、8 普通 TU；
  1 个 producer 上下文失败（18 TU），直接留给官方，发布 640 shard；首次 58.396 s，
  重复 skipped=true，工具 2.010 s / 墙钟 2.210 s，receipt mtime 未变。STAGE-1 在 30 分钟内通过。
- `python -B -I tests/py/test_clangd_pch_offline.py`：20/20；逐个运行 headless filters
  `index_generation` 46/46、`cpp_semantic_index` 1/1、`clangd_commands` 23/23、`ue_api` 67/67、
  `index_pch_offline` 10/10，共 147/147，0 失败、0 跳过（required-native、实验 j2）。
- 隔离真实 headless loader/tool 调用成功复用 receipt；4 个运行时文件的 bare-globals AST lint、
  Python AST 解析与 diff whitespace 检查通过。未触碰用户运行中的 nvim/clangd，未跑全量索引或全量回归。

**Follow-ups**
- S3 的完整依赖失效策略、非 Windows 宿主与更大规模真实 prepare/reader 性能仍未验收。

### 2026-11-05 — 离线 PCH：producer 失败闭包入 receipt、并发发布容错、40 TU 中样本验收

**Implemented**
- `tools/clangd_pch_offline.py`：producer 失败的上下文用同一命令 `-M -MG` 预处理列出前缀头闭包
  （缺失的 generated 头也列出），写入 receipt 依赖；修好任一头即重新触发离线工具。
  shard 发布改为 `publish_shard`：目标被运行中的 reader 占用时短重试，仍失败则跳过该 shard
  （reader 自持等价副本），报告 `contended_shards`，不再让整次发布抛错。
- Python 单测新增 depfile 解析、扫描参数、发布替换/占用回落用例。

**Validation**
- 40 TU 真实中样本（j2）：5 上下文、14 paired、0 mismatch/unlisted、1 producer 上下文失败（26 TU，
  引擎漂移缺 generated 头），发布 625 shard，工具 52 s；官方 clangd 加载后重建 26 TU == 回落集合，
  14 个已发布主 shard 逐字节不变。加入闭包后同样本 receipt 绑定 1563 个失败前缀头，重跑 skipped 1.2 s。
- `python -B -I tests/py/test_clangd_pch_offline.py` 24/24；`index_pch_offline` 10/10、
  `index_generation` 46/46、`cpp_semantic_index` 1/1、`clangd_commands` 23/23。未跑全量回归/全量索引。

**Follow-ups**
- 非 Windows 宿主；全量验收需先征得用户同意。

### 2026-11-05 — 离线 PCH 两档失效（S3）与并发发布实测

**Implemented**
- receipt v2：记录二进制/工具 identity、每 TU 命令摘要与根、shard include 图和失败 PCH 上下文闭包。
  `drift_plan` 反向求受影响 TU：无变化 `reuse`；比例 ≤ `--drift-threshold`（默认 0.5）为 `delta`，
  跳过离线重跑并由官方 reader 按摘要重建过期 shard；超过阈值、缺 shard、identity 变化或 receipt 损坏均重跑全量。
- overlay 只作为 TU 根，不展开映射文件为图边（实测否则 25215 条边让任一引擎头命中全部 TU）。
- spec `cpp-semantic-index-coverage` 增「离线 PCH 失效两档」方向条目。

**Validation**
- R45 40 TU 真实样本：首次全量 49.8 s；重复 `reuse` 1.4 s；touch 1 个 TU 源 → `delta` 受影响 1/40、1.4 s；
  阈值 0.01 时同漂移转全量（70.1 s）。去 overlay 扇出后单文件命中分布：116 个文件只命中 1 TU，507 个命中全部 40。
- R46 并发：空索引目录下官方 clangd j2 与离线工具同时写，工具 625 shard、contended 0、reader 0 错误、
  无 `.new-` 残留；合并后的 1712 shard 交官方 clangd 重载：0 重建、0 改动（PASS）。
- `python -B -I tests/py/test_clangd_pch_offline.py` 26/26；`index_pch_offline` 10/10、`index_generation` 46/46、
  `cpp_semantic_index` 1/1、`clangd_commands` 23/23、`ue_api` 67/67、`ue_config` 11/11。未跑全量回归/全量索引。
- 本轮不提交、不发布，也不修改用户引擎 checkout、构建产物或已安装工具。
