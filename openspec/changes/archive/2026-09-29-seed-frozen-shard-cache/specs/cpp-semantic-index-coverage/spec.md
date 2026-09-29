## MODIFIED Requirements

### Requirement: Frozen batch activation SHALL be guarded and preserve the original semantic authority

默认发布路径 SHALL 始终保留原 UBT/exact CDB。冻结批次 SHALL 使用独立 CDB 和独立 shard 缓存，
phase manifest SHALL 绑定独立原始 semantic CDB 的路径与内容。native definition 查询 MUST NOT
把二次合并 AST 当作原始编译上下文。

#### Scenario: An editor starts with persisted frozen batches
- **WHEN** 新进程发现批次产物
- **THEN** SHALL 先建立经过宿主能力验证的输入监听，再异步验证 receipts 和发布内容，成功后才选择冻结 CDB
- **AND** 主循环 MUST NOT 扫描依赖或同步计算大型 CDB/hash；能力缺失或验证失败 SHALL 使用原 UBT CDB

#### Scenario: Windows validation reads its own watched input directories
- **WHEN** reading inputs updates only their last-access timestamps
- **THEN** the Windows frozen-input watcher SHALL exclude LAST_ACCESS at the native subscription, without revoking otherwise current batch authority
- **AND** it SHALL retain filename, directory-name, attributes, size, last-write, creation and security notifications; source-only notification filtering MUST NOT substitute for this input guard
- **AND** recursive and direct capability probes SHALL exercise the selected backend and notification profile on owned temporary inputs
- **AND** asynchronous watch registration SHALL remain unavailable for batch authority until every required root acknowledges that its native subscription is armed
- **AND** early input events, unavailable roots, overflow, helper exit, malformed notifications and readiness failure SHALL revoke authority, including during partial installation
- **AND** grouped native watches SHALL share one parent-bound helper per activation, respect the existing root budgets and release the whole group on invalidation or cancellation; pending, duplicate or late readiness MUST NOT start validation

#### Scenario: A subscribed ordinary directory receives only a write notification
- **WHEN** the Windows grouped backend separates namespace/attributes/creation/security (`0x147`) from size/last-write (`0x18`) notifications
- **THEN** each root SHALL acknowledge readiness only after both subscriptions are armed; either stream's errors or overflow SHALL revoke authority
- **AND** activation SHALL install actual parent-entry watches for ancestors of every protected recursive root, as well as lexical driver lookup ancestors, within the existing recursive/direct root budgets
- **AND** runtime MAY ignore a write-stream action 3 only for an exact subscribed directory whose nonzero device/inode and ordinary, non-reparse attributes still match the backend's initial `lstat` identity, under the explicit `stable-directory-write-v1` descriptor policy
- **AND** validation SHALL bind that policy and the full installed topology; unknown policy, legacy/unclassified notifications, files, unsubscribed directories, changed identities, metadata and namespace notifications SHALL retain conservative invalidation
- **AND** ignored directory writes SHALL NOT trigger revalidation, CDB rewriting or a clangd restart; source-only subscriptions SHALL remain unchanged
- **AND** notification coverage MUST NOT be reported as complete reparse protection: an in-place reparse-target change that the host does not notify remains an explicitly recorded capability gap, not evidence of unchanged identity

#### Scenario: A frozen database has no local shard-cache directory yet
- **WHEN** startup is preparing a frozen database whose owned local cache tree does not yet exist
- **THEN** runtime SHALL create the canonical `verified/.cache/clangd/index` directory tree before installing input watches, deriving its location from the original semantic CDB rather than an arbitrary descriptor path
- **AND** existing directories and shard contents SHALL remain untouched; conflicting files, redirected components, an unexpected frozen CDB path or creation failure SHALL retain the original CDB
- **AND** this preparation SHALL NOT bypass receipt validation or ignore content, namespace, metadata or unclassified ancestor notifications; only the separately specified stable-directory write policy MAY suppress classified ancestor writes, and first cache writes within the existing excluded tree SHALL not revoke otherwise current authority

#### Scenario: A new frozen shard cache is seeded from the original cache
- **WHEN** the owned frozen `verified/.cache/clangd/index` directory exists and holds no `*.idx` shard while the original semantic CDB's `.cache/clangd/index` holds shards
- **THEN** runtime SHALL, before any input watch or frozen client starts, add only shard names absent from the frozen cache by hard link (or exclusive-create copy across volumes), skipping temporary `.temp-stream-` files
- **AND** it MUST NOT modify, delete or rename any original shard or any shard already present in the frozen cache, and SHALL leave no truncated copy on failure; clangd rewrites shards by temporary file plus rename, so a later frozen rewrite replaces only the frozen directory entry
- **AND** the seed outcome SHALL NOT grant or revoke frozen authority: seeding failure, a missing helper or a timeout SHALL continue startup with the unseeded cache, and receipt validation and watches SHALL proceed unchanged
- **RATIONALE** retained frozen commands equal original commands byte-for-byte (activation coverage), clangd 22 keys shards by source path and judges staleness by content digest only, so original shards are valid for retained TUs; batch TUs have new paths and are indexed normally. Measured on the live Client Android cache: cold first frozen activation ≈1714 s wall / 12.9k CPU s; seeded ≈42 s wall reindexing only batch TUs

#### Scenario: The server uses a query-driver profile not covered by the proof
- **WHEN** effective server arguments contain a nonempty query-driver allowlist and receipts do not certify that driver-query profile
- **THEN** automatic build/activation SHALL retain original UBT commands and preserve the user's server arguments and environment
- **AND** prepare SHALL reject the profile before expensive validation; a ready metadata cache or a directly supplied verified path MUST NOT bypass this check
- **AND** the system MUST NOT delete query-driver options merely to make frozen batches eligible

#### Scenario: Inputs change while references or rename is in flight
- **WHEN** 受监视的源码、头文件、工具、lookup 目录或冻结产物发生变化
- **THEN** SHALL 立即撤销该客户端的批次 epoch，拒绝新的 references/rename/prepareRename 与迟到的旧结果
- **AND** SHALL 退回独立原 UBT 路径，并只重启受影响的本进程客户端；不得清理其他进程的缓存
- **AND** an invalidation triggered by a watch callback SHALL retain the first triggering watch root, filename or error, and available event flags in bounded guard status and the normal warning log; later callbacks MUST NOT overwrite that evidence
- **AND** returned evidence SHALL be an independent copy, oversized fields SHALL be explicitly marked truncated, and logging failure MUST NOT delay revocation or suppress fallback; ordinary accepted/ignored events SHALL NOT accumulate a trace

#### Scenario: A later startup retries an input-event invalidation
- **WHEN** a normal startup requests the same publication and generation after an `input-changed`, `live-document-modified`, `live-document-changed` or unattached `activation-abandoned` fallback
- **THEN** it MAY retry only after a 30-second monotonic cooldown and confirmed completion of the previous activation helpers; cancellation alone MUST NOT establish completion
- **AND** relevant loaded documents SHALL be clean before retry; a clean buffer SHALL NOT substitute for fresh validation of the on-disk inputs
- **AND** retry SHALL repeat description, watch readiness and full receipt validation before granting authority; concurrent requests SHALL share the attempt and later input events SHALL still revoke it
- **AND** each configured frozen client SHALL bind to its activation attempt; a late client from an older attempt MUST NOT acquire the fresh guard merely because the publication stamp matches
- **AND** elapsed time without pending document recovery or a new startup request SHALL NOT launch helpers or restart clients; unchanged ready activations SHALL remain reusable without revalidation, and other failure reasons SHALL remain sticky for that publication

#### Scenario: A loaded document already contains unsaved changes
- **WHEN** a named, normal, loaded document is modified and is the requested buffer, already attached to a clangd client for the selected CDB, or admitted by the configured filetypes inside the selected engine/project roots
- **THEN** startup SHALL retain original commands before metadata/generation work, validation helpers or watch installation; an initial blocked request SHALL NOT create a sticky failed activation
- **AND** unrelated foreign, scratch and unsupported-filetype buffers SHALL NOT block merely because project selection is pinned; existing same-CDB attachments and explicit requests SHALL remain protected when their filetype changes
- **AND** an already pending or ready activation SHALL revoke immediately when the document check detects an edit; description, watch installation after capability probing, validation, readiness, command-selection, process-configuration and attachment boundaries SHALL recheck documents so asynchronous edits cannot acquire frozen authority
- **AND** late callbacks from cancelled description/probe work SHALL NOT replace the first document failure with a nonretryable failure; repeated dirty requests SHALL NOT extend the original cooldown or treat cancellation as helper completion
- **AND** clearing a document SHALL NOT save/discard any user text or reuse invalid authority; clean demand and the bounded document-recovery coordinator SHALL run the normal complete activation and preserve generation, profile, environment and attempt checks
- **AND** document checks SHALL inspect loaded buffer metadata and existing ownership only, without reading source contents, scanning dependency trees or resolving a project separately for every buffer

#### Scenario: Previously modified documents become clean while an original reader remains active
- **WHEN** a registered document-blocked CDB scope receives a buffer or client lifecycle event and its relevant documents are clean
- **THEN** an event-driven coordinator MAY revalidate after a 200ms settling delay, the existing retry cooldown and actual helper completion; an original reader attaching after the clean event SHALL also wake recovery
- **AND** the coordinator SHALL retain at most eight canonical CDB scopes, one cancelable timer per scope and one automatic validation at a time; failed callbacks SHALL NOT release that serial slot before helpers exit, and cancelled timer callbacks SHALL NOT consume a newer timer
- **AND** the original reader SHALL remain running throughout full validation; before one scoped restart the coordinator SHALL recheck the exact reader object, attachment, command/configuration, context, generation, publication, effective environment and clean documents
- **AND** promotion SHALL respect ordinary restart debounce, reuse successful validation while waiting, and require a matching frozen client attachment within 15 seconds; an external matching attachment SHALL also cancel the pending restart
- **AND** redirty, lost context or changed identity SHALL abandon the candidate; non-document failures SHALL disarm automatic recovery, and late callbacks SHALL NOT promote abandoned attempts
- **AND** cancellation SHALL apply only to the matching unattached activation attempt; runtime state notifications and detached scalar snapshots SHALL convey no proof authority
- **AND** recovery SHALL NOT poll, rewrite CDBs, save/discard documents, clear caches, force a full index or restart unrelated clients

#### Scenario: Frozen publication changes while a document-blocked original reader is unchanged
- **WHEN** a successful phase publication changes frozen products or their metadata but explicitly confirms that original commands are unchanged
- **THEN** index delivery SHALL retain the sole initialized, attached original reader for that CDB when relevant documents are modified and an existing idle document-recovery registration is waiting for that same scope
- **AND** retention SHALL inspect actual client commands and loaded document metadata, start no helper or restart timer, and leave restart debounce untouched; a corresponding frozen reader or ambiguous reader ownership SHALL prevent this optimization
- **AND** clean documents, missing recovery ownership, unknown command-change status, changed original commands, pending source refresh and frozen-authority invalidation SHALL retain their existing delivery behavior
- **AND** later document-clean events SHALL still invoke normal complete validation and scoped promotion; retaining an original reader SHALL grant no frozen authority or permission to alter unsaved text

#### Scenario: Certifying a supported driver-query profile
- **WHEN** a secondary proof explicitly supports a nonempty query-driver profile
- **THEN** all original and candidate compiler runs SHALL use the same supported server profile, actual launch cwd and compiler environment
- **AND** native discovery SHALL identify the driver actually executed and bind its bytes, ordered system paths, target and builtin-header handling; PATH guessing or a recorded allowlist alone MUST NOT certify the profile
- **AND** binding and VFS-alias proofs SHALL consume the original TU's structured main-shard effective command, retaining driver identity and semantic argument order; raw commands MUST NOT substitute for absent evidence
- **AND** the profile SHALL bind cache/frozen/receipt identities, effective lookup roots SHALL be monitored, and activation SHALL asynchronously repeat native driver discovery after installing watches

#### Scenario: Certifying the pinned Android NDK driver profile
- **WHEN** the active Android CDB resolves the compiler to the pinned Android clang 9.0.9 build
  (`7019983` / `r365631c3`, LLVM commit `a2a1e703c0edb03ba29944e529ccbf457742737b`)
- **THEN** the LLVM 22.1.5 clangd query extractor MAY certify that driver as the explicit
  `android-clang-9.0.9-build-7019983` profile
- **AND** the exact driver version string, bytes, target, ordered system includes, builtin-header
  handling, compiler environment and lookup roots SHALL remain bound in the evidence
- **AND** any other Android/NDK version or build identity SHALL remain unsupported and retain the
  original UBT commands until a separately reviewed profile is added
- **AND** the version first line SHALL match the full reviewed build banner exactly; custom suffixes, changed build numbers or commits SHALL reject certification
- **AND** compiler build identity MUST NOT be reported as an inferred NDK package release; a changed parser/profile identity SHALL invalidate older receipts

#### Scenario: Driver lookup depends on directories outside source trees
- **WHEN** native driver discovery can search executable candidates outside recursively monitored compiler inputs
- **THEN** activation SHALL monitor those candidate names and their lexical ancestors, including the nearest existing ancestor of missing directories
- **AND** direct directory watches SHALL be explicitly nonrecursive; their separate budget MUST NOT weaken the source-tree recursive-watch budget
- **AND** installation SHALL yield between bounded batches and cancel on epoch invalidation; native validation MUST NOT start until all required watches are installed
- **AND** a missing event filename, changed lookup candidate, renamed ancestor or unavailable required watch SHALL revoke the frozen selection
- **AND** validation SHALL confirm the installed watch topology still matches its newly discovered requirements; a directory appearing between describe and watch installation MUST NOT leave an unmonitored lookup root eligible for activation

#### Scenario: The effective compiler environment changes during activation
- **WHEN** launch cwd, query profile or effective compiler environment differs from the snapshot being validated
- **THEN** the pending frozen activation SHALL be rejected and the original UBT process configuration SHALL remain available
- **AND** helper processes SHALL receive the exact merged environment, including variable removal, without accidentally inheriting removed variables
- **AND** Windows process overrides SHALL preserve case-insensitive environment semantics; an unsupported RPC removal or cwd alias SHALL reject frozen activation rather than silently change user configuration
- **AND** ambiguous duplicate environment keys SHALL reject certification; a certified process SHALL execute the absolute clangd path whose identity was validated, while fallback retains the original user command
- **AND** command selection and process startup SHALL reject changed cwd, environment, query results or unsupported server flags while preserving user arguments and the original UBT fallback

