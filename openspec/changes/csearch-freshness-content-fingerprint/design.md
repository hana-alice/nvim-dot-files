## Context

`prepare_freshness(ctx)`（`lua/ue.lua` ~L3489）当前稳态判定（apply 前以代码为准）：

```
① prepare_jobid 在跑          → in_progress
② workspace_all.files 不存在   → never
③ watcher persistent_dirty>0   → stale        ← 确定性信号，保留
④ anchor_max = max(            ← 全是 mtime 代理，本 change 要删
     git_commit_state_mtime(engine), git_commit_state_mtime(project),
     dir_mtime(engine), dir_mtime(project))
   list_mt >= anchor_max ? fresh : stale
```

代理噪声史：
- `.git/index` mtime → fsmonitor/TortoiseGit 后台 touch → 假 stale（K30g，D8 换 commit-state）。
- `dir_mtime` → **编译产物落进引擎树 touch 目录** → 假 stale（本次现场：list 15:04 <
  engine dir 15:11，重编后即 stale，未增删任何文件）。

`workspace_all.files` 生成事实（已查证，L2 的两个前提成立）：
- 两个写入点（sync `lua/ue.lua` ~L8325 / cold ~L8728）都 `table.sort(workspace_all)` 后
  `write_lines` → **内容确定性**（同集合 → 同 bytes，行序稳定）。
- 只在 UEPrepare 的 lists 阶段（重新枚举文件树）写 → **hash 变 ⟺ 集合被重新枚举出不同结果**。
- 当前 22 MB；`vim.fn.sha256` 实测 46ms（一次性）。

消费者：`prepare_freshness` 同时喂 csearch grep 与 `<space><space>` 文件 picker。两者的数据源
都是 `workspace_all.files`，故「这份清单内容变没变」对**两个消费者都是正确的 freshness 定义**
——L2 天然同时服务二者，无冲突。

## Goals / Non-Goals

**Goals：**
- 用 `workspace_all.files` 内容指纹（确定性、零噪声）取代所有 mtime 代理 anchor。
- 退役 `git_commit_state_mtime`（D8）+ `dir_mtime` + `git_index_mtime` 残留。
- 保留两条非代理的确定性信号：存在性、watcher dirty。
- hash 成本可忽略：仅在 list 自身 (mtime,size) 变化时重算，稳态只 stat。

**Non-Goals：**
- 不检测「已有文件内容被编辑」——那是 clangd 的职责（用户边界），csearch freshness 不管。
- 不下沉到 per-file 内容 hash（L3/L4）；UE 万级文件不可行，且语义上不需要。
- 不改 `workspace_all.files` 的生成（它已是排序好的确定性清单）。
- 不动 D-3b（dirty-clear）——它与指纹记录是同一回调点的两件正交的事。

## Decisions

### D10-1 — freshness 稳态 = 内容指纹比对（取代 mtime 代理）

```
prepare_freshness 稳态（保留 ①②③，替换 ④）：
  ④' h = fingerprint(workspace_all.files)         -- sha256，带 (mtime,size) 缓存
     h == state.csearch_input_hash ? fresh : stale
```

`fingerprint(path)`：
- cache key = 该 list 文件自身的 `(mtime,size)`；命中则返回缓存 hash（稳态：只 stat，微秒级）。
- miss 则读文件 + `vim.fn.sha256`，更新缓存。
- **注意**：这里的 mtime 仅作「要不要重算 hash」的缓存键，**不是判定依据**；判定永远是内容
  hash 比对。代理 mtime 是「拿 mtime 当真相」，这里是「拿 mtime 当缓存失效提示，真相仍是内容」
  ——本质不同。

### D10-2 — 记录点：全量构建成功后写 state.csearch_input_hash

csearch 全量构建成功回调里（sync / cache fast-path / cold full 三路径，复用 D-3b 的
`clear_persistent_dirty_safe` 同一位置）：

```
on full-build success:
   clear_persistent_dirty_safe(...)                       -- D-3b（已有）
   state.csearch_input_hash = fingerprint(workspace_all.files)   -- D10（新增）
```

失败不写（与 D-3b 失败不清同理：索引没建成，指纹不能前移）。

### D10-3 — 退役所有 mtime 代理 anchor

删除 `git_commit_state_mtime`、`dir_mtime`、`git_index_mtime`（确认无其它引用后）。
freshness 不再读 git、不再读目录 mtime。三个噪声源（fsmonitor / 编译产物 / 未提交改动漏报）
随之消失——因为它们都不改 `workspace_all.files` 的内容。

### D10-4 — 保留 watcher dirty 作会话内信号

`persistent_dirty>0 → stale` 保留（判定 ③）。它是事件驱动的直接测量（不是代理），覆盖
「会话内增删文件、list 还没重新枚举」的窗口。会话间（关机期 git pull）由指纹兜底：下次开
nvim/UEPrepare 重算 list 后指纹自然不同。两者正交互补。

## Rejected Alternatives

| 方案 | 否决理由 |
|---|---|
| 继续换更好的 mtime 代理（如只看源码子目录的 dir_mtime） | 仍是代理，仍有噪声（源码目录也会被工具 touch）；打地鼠无尽头 |
| per-file 内容 hash（L4，理论最完美） | UE 万级文件每次检测重算 = 物理不可行；且语义上 csearch 不需要内容级 |
| per-file (mtime,size) 指纹（L3） | 检测要 stat 一万次；且「内容编辑」是 clangd 职责，csearch 不需要这粒度 |
| 保留 D8 commit-state 作兜底 | 指纹已覆盖 D8 全部场景且更准，保留只是冗余的噪声源 |

## Risks

| 风险 | 缓解 |
|---|---|
| 22MB sha256 每次 grep 重算拖慢入口 | (mtime,size) 缓存键：仅 list 重写才重算，稳态只 stat（微秒）。实测全量 hash 46ms，仅 miss 时付一次 |
| 旧 state 无 csearch_input_hash（升级首跑） | 字段缺失视为「无记录」→ stale → 提示 UEPrepare（一次），首次全量建成即写入，此后稳定 |
| workspace_all.files 生成逻辑未来变得不确定性（乱序） | 已 table.sort；新增 spec/test 守护「list 内容确定性」，回归会红 |
| 删 anchor 后丢失某个真实变更场景 | 集合变化必反映在 list 内容；会话内由 watcher dirty 覆盖；无真实场景遗漏（论证见 §正确性） |

## 正确性论证

```
要检测的真相：被索引的文件【集合】变了吗
   集合变（增/删/改名） ⟺ workspace_all.files 内容变（它就是集合的确定性序列化）
   ∴ hash(list) 比对 = 对该真相的【直接测量】，非代理，零噪声

噪声源消失：
   fsmonitor/TortoiseGit touch index   → 不改 list 内容 → 不再假 stale
   编译产物 touch 目录 mtime           → 不改 list 内容 → 不再假 stale
   未提交新增（git 漏报）              → 会话内 watcher dirty 捕获；
                                         会话间下次 list 重枚举后指纹不同
```

## Verification

- `nvim --headless -l tests/run.lua utils` / 新 freshness spec / `structure`。
- 跨子系统 → 提交前全量 `nvim --headless -l tests/run.lua`。
- 行为测：集合变→stale、集合不变→fresh、list 重写但内容相同→fresh、hash-cache 命中不重算、
  watcher dirty 短路 stale、缺 csearch_input_hash→stale。
- 真机验证（用户）：重编一次 UE → `<space><space>` **不再**假 stale（除非真增删文件）。
