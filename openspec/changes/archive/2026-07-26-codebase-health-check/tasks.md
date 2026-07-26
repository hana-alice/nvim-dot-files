# Tasks: codebase-health-check

## 1. 扫描基建（一次性脚本，tools/ 新文件，不碰运行时）

- [x] 1.1 写 `tools/health_scan.lua`（headless 可跑）：输出候选清单——
      (a) 所有 `new_timer`/`timer:start`/autocmd callback 内含
      `vim.fn.system|systemlist|io.popen|vim.wait` 的位置；
      (b) `lua/` 下超 800 行的文件及行数；
      (c) 所有 `new_timer`/`jobstart`/`new_fs_event` 位置与同文件内
      stop/close 引用配对表
- [x] 1.2 跑扫描，产出原始候选清单存 `tools/health_scan_output.txt`（工作产物，
      gitignore；报告只收录判读后的 finding）

## 2. 维度一：P6 阻塞面判读

- [x] 2.1 对 1.2 候选逐条人工判读：区分「用户命令路径的合法同步」vs
      「timer/autocmd/回调里的违例」，违例定级并记 finding
      （已知白名单：K40 已修的 liveness poller、K42 已修的 gitsigns 配置）
- [x] 2.2 重点复核 `vim.wait` 使用点（android.lua 4 处、ue.lua sync 路径）：
      标注哪些在异步回调链内（潜在重入/卡 UI）、哪些在显式 Sync 命令内（合法）

## 3. 维度二：约束自违反

- [x] 3.1 文件行数清单（ue.lua 10472 为已知 HIGH，量化其顶层职责块分布，给出
      切分建议大纲，不实施）
- [x] 3.2 P1–P17 逐条 rg 复核（如 P7 `string.format("%x"` 、P3 全局 handlers
      覆盖、P5 周期 ticker），逐条记「合规/违例+行号」
- [x] 3.3 C4 六约定抽查：重点「未变更时跳过写入」（各生成器写前比对）与
      「AST 优先于 regex」（新增代码抽 5 处）

## 4. 维度三：workaround 存活复审

- [x] 4.1 解析 9 个 workaround frontmatter（issue/removal_condition/introduced），
      对照 lazy-lock.json 锁定 commit 与上游 issue 状态，逐个给三态结论
- [x] 4.2 对结论为「可移除」的项，写出建议移除 change 名称与验证方案（不执行）

## 5. 维度四：并发/生命周期

- [x] 5.1 用 1.1(c) 配对表审查每个 timer/job/fs_event 的 stop 路径：会话异常
      结束、模块 reload、`_reset_for_test` 三种场景下是否泄漏
- [x] 5.2 persistent_dirty cap=1000 打满现场取证：dirty.json 内容分类（ThirdParty
      测试文件占比）、打满丢增量的静默行为、blocklist 缺口判定；定级 + 建议
      change（预期 HIGH）
- [x] 5.3 复查 INDEX_RT.timers / statusline timer / _progress timer 的 close
      语义与重入保护

## 6. 维度五：测试盲区

- [x] 6.1 27 个 spec 与子系统速查表交叉：列零覆盖（候选：_progress、ue_watch
      flush 排程、statusline、notification_history）与薄覆盖子系统
- [x] 6.2 对 HIGH finding 涉及的路径检查是否存在「本应有回归但没有」的缺口，
      写入对应后续 change 的验证要求

## 7. 报告与收尾

- [x] 7.1 汇总 `docs/health-check-2026-07.md`：头部（日期 + HEAD hash）、五维度
      分节、finding 总表（严重级排序）、后续 change 建议清单、未覆盖区声明、
      附录「未证实观察」
- [x] 7.2 把「timer 回调禁同步 spawn」「文件行数上限」评估为可固化 lint 的
      建议写入报告（是否落地由后续 change 决定）
- [x] 7.3 全量回归 `nvim --headless -l tests/run.lua` 确认审计未破坏任何行为
      （预期只增文档与 tools 脚本）；changelog Unreleased 记一条审计条目
      （Validation 写全量绿）

