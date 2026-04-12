# Script Translator 候选重排设计

## 背景

当前 `librime 1.13.1` 的 `script_translator` 在多音节输入上的候选生成，更接近“按可消费前缀长度分桶，再从长前缀往短前缀依次吐候选”，而不是“基于整串输入的全局最优解释”。

这在常规全拼下问题不大，但在开启大量 `speller/algebra` 模糊音、简拼、缩写规则后，输入图会显著膨胀，导致大量“中间前缀候选”挤占前几页候选位。用户输入完整串时，往往更希望候选顺序优先体现整串可解释性，而不是单纯最长前缀优先。

本文目标是为 fork `librime` 提供一份可评审的算法与实现设计文档，用于改造 `script_translator` 的候选排序逻辑。

## 现象与问题

例子：输入 `gengchajin`，用户预期 `更差劲` 或至少 `更差 + 劲` 这类“整串能解释通”的候选应排在前面。当前行为中，第一页可能出现与整串相关的候选，但翻页后会很快落入类似 `geng ch ...` 这样的中间前缀候选流；而像 `更` 这种更短前缀候选会被大量 `gengcha*`、`gengch*` 中间候选继续压后。

根本问题不是词频，也不是词典缺词，而是排序目标不合理：

- 当前逻辑偏向“前缀消费越长越优先”
- 但用户想要的是“整串剩余部分仍然可解释”的候选优先
- 对不能继续解释后缀的候选，当前实现缺少明确惩罚

## 设计目标

1. 对完整输入串进行全局感知排序，而不是仅按首词消费长度排序。
2. 对“后缀不可续接”的候选施加显式降权。
3. 保留现有词典、用户词典、造句和纠错能力，不要求用户修改现有 `schema` 或 `speller/algebra`。
4. 尽量将改动收敛在 `script_translator` 层，减少对 `Dictionary`、`Poet`、`Syllabifier` 的侵入。
5. 允许保留一个兼容模式或开关，降低上游 review 阻力。

## 非目标

- 不修改词典格式。
- 不重写 `speller/algebra`。
- 不试图在第一版中解决所有候选排序争议，例如多义词语义排序、上下文联想排序。
- 不改变 `table_translator`、`reverse_lookup_translator` 等其他 translator 的排序。

## 最新证据与策略调整

在最新 `librime master` 上，使用 `luna_pinyin` 通过 `rime_api_console.exe` 实测输入 `gengchajin`，第一页已经可以得到：

```text
1. 更差勁
2. 更差
3. 更
4. 庚
5. 耿
```

这说明本文前半部分对“现有 script_translator 排序目标不合理”的判断，更准确地说只适用于较旧版本，不能直接外推到最新上游。

因此，当前更稳妥的工程策略应调整为：

1. 先隔离变量：区分 `librime 版本变化` 与 `schema 差异`。
2. 优先做版本归因：定位 `1.13.1 -> master` 之间哪些提交改变了该例子的候选行为。
3. 只有在确认上游仍不能满足目标时，才继续推进本文提出的自定义全串重排方案。

当前已识别的高相关上游提交包括：

- `fee05a5f` `feat(script_translator): concatenate segments with a sliding window`
- `f6756b33` `feat(dictionary): 全碼長度積分`
- `fce47ee4` `feat(script_translator): 首選爲糾錯則啓動造句`

因此，本文更适合作为“若需要进一步超越上游行为时的候选设计方案”，而不是当前第一优先级的实施建议。当前第一优先级应是：

- 在 `master` 上使用同一份 `rime_mint`/相同 algebra 复现
- 在 `1.13.1` 上使用 `luna_pinyin` 复现
- 做最小范围的提交级 bisect 或手工回移植验证
## 现状机制

### 现有链路

以 `librime 1.13.1` 为例，`script_translator` 的主链路大致如下：

1. `ScriptTranslator::Query()` 创建 `ScriptTranslation`
2. `ScriptTranslation::Evaluate()` 调用 `BuildSyllableGraph()`
3. `Dictionary::Lookup(syllable_graph, 0, predict_word)` 查出从位置 `0` 开始的短语候选
4. `phrase_` / `user_phrase_` 都从 `rbegin()` 开始迭代
5. `PrepareCandidate()` 在“系统词候选组 / 用户词候选组 / 句子候选”之间选择下一个候选

相关源码：

- `script_translator.cc`
  - <https://github.com/rime/librime/blob/1.13.1/src/rime/gear/script_translator.cc>
- Rime 官方 wiki 对候选与代码段关系的说明
  - <https://github.com/rime/home/wiki/RimeWithSchemata>

### 当前排序特征

从源码和现象可以推导出以下特征：

1. `Evaluate()` 使用 `dict->Lookup(syllable_graph, 0, predict_word)`，只查“从起点开始”的候选。
2. `phrase_iter_ = phrase_->rbegin()`、`user_phrase_iter_ = user_phrase_->rbegin()`，意味着先处理更长 `code length` 的组。
3. `PrepareCandidate()` 先在“用户词当前组”和“系统词当前组”之间比较，再构造 `Phrase` 候选。
4. `candidate_->set_quality(...)` 是在候选被选中之后才设置，因此 `quality` 并不参与首轮候选排序。
5. `GetPreeditString()` 基于候选实际匹配到的编码片段生成 preedit，因此候选只覆盖前缀时，preedit 本来就会缩短。

### 问题的本质

当前逻辑缺少“后缀续接质量”的概念。只要某个候选能吃掉更长的前缀，它就天然排在更前面，即使它吃完之后留下的后缀根本无法形成合理拼音路径，或者只能形成很差的解释。

换句话说，现有实现关注的是：

```text
prefix_quality(candidate)
```

但用户更需要的是：

```text
global_quality(candidate, remaining_suffix)
```

## 提议算法

### 总体思路

将首词候选的排序目标从“最长前缀优先”改为“首词质量 + 后缀最佳续接质量”的全串打分。

对于每个从位置 `0` 出发的首词候选 `c`，定义：

```text
score(c) =
  base_score(c)
  + continuation_score(c.end)
  + exact_match_bonus(c)
  + normal_spelling_bonus(c)
  - abbreviation_penalty(c)
  - correction_penalty(c)
  - dead_end_penalty(c.end)
```

其中：

- `base_score(c)`：当前词条已有分数，可复用词典权重、用户词频、quality 等现有信号
- `continuation_score(c.end)`：从 `c.end` 到输入末尾的最佳续接路径分数
- `exact_match_bonus(c)`：完整精确覆盖整串时给予高奖励
- `normal_spelling_bonus(c)`：正常拼写优于模糊音/纠错路径
- `abbreviation_penalty(c)`：由简拼、缩写触发的候选给予轻度惩罚
- `correction_penalty(c)`：纠错路径给予轻度惩罚
- `dead_end_penalty(c.end)`：剩余后缀不可续接时给予强惩罚

### 核心原则

1. 整串可解释优先于局部最长前缀。
2. 完整覆盖优先于部分覆盖。
3. 可续接的部分覆盖优先于死路部分覆盖。
4. 正常拼写优先于缩写、模糊音、纠错。
5. 在同等整串解释质量下，再回退到原有词频和 quality。

### 例子

输入：`gengchajin`

- `更差劲`
  - 首词即覆盖全串
  - `continuation_score = 0`，但 `exact_match_bonus` 高
  - 应稳定靠前

- `更差`
  - 剩余 `jin` 仍可续接为“劲”
  - `continuation_score` 为正
  - 可排在完整精确词之后，但应高于死路前缀

- 某个 `gengch*` 候选
  - 剩余为 `ajin`
  - 后缀无法形成高质量拼音路径
  - `dead_end_penalty` 应显著拉低其排序

### 为什么不是简单“最长前缀 + 死路剔除”

仅做死路剔除仍不足够，因为还会遇到：

- 多个候选都不是死路，但其中一个后缀解释明显更自然
- 一个候选是模糊音路径，另一个是精确路径
- 一个候选是完整覆盖，但质量略低；另一个是部分覆盖，但可顺畅续接

因此需要统一评分，而不是只做布尔判断。

## 实现方案

### 方案选择

优先方案：在 `ScriptTranslation` 中增加“全量首词候选收集 + 后缀打分 + 重排”。

不建议的方案：

- 只改 `Dictionary::Lookup()`：
  `Dictionary` 看不到整串剩余解释，不适合做全串重排。
- 只调 `candidate->quality`：
  当前 `quality` 设置发生在候选选出之后，改这里无法改变候选顺序。
- 只做 Lua filter：
  Lua filter 看得到当前候选，但很难高效访问内部 syllable graph、词图和后缀最佳路径；实现复杂且性能和一致性都差。

### 代码落点

首选修改点：

- `src/rime/gear/script_translator.cc`

可能需要辅助修改的文件：

- `src/rime/gear/script_translator.h` 或等价声明位置
- 如需抽公共结构，可能新建小型 helper，但第一版建议先内聚在 `script_translator.cc`

### 数据结构

建议在 `ScriptTranslation` 内新增一个中间结构：

```cpp
struct RankedPhraseCandidate {
  CandidateSource source;
  size_t code_length;
  size_t end_pos;
  double base_score;
  double continuation_score;
  double penalty;
  double final_score;
  bool exact_match;
  bool normal_spelling;
  bool is_correction;
  bool is_abbreviation_like;
  an<Candidate> candidate;
};
```

`candidate` 可以延迟构造，也可以在收集阶段直接构造。为了降低复杂度，建议先在收集阶段构造最终 `Phrase` 候选对象。

### 计算流程

#### Step 1：保留现有 syllable graph 构建

继续沿用：

- `BuildSyllableGraph()`
- `dict->Lookup(syllable_graph, 0, predict_word)`
- `user_dict->Lookup(...)`

这一步不改。

#### Step 2：收集所有首词候选

新增 `CollectRankedCandidates()`，遍历 `phrase_` 和 `user_phrase_` 的全部组，而不是像现在一样仅保留一个“当前迭代器”。

每个首词候选需要记录：

- 来源：系统词 / 用户词
- 覆盖到的结束位置
- 当前词条已有质量分
- 是否精确匹配整串
- 是否包含 correction
- 是否属于 abbreviation / non-normal spelling

#### Step 3：为每个结束位置计算后缀最佳续接分

新增一个针对 suffix 的 DP 或 memoized DFS：

```text
best_suffix_score[pos] = 从 pos 出发到 consumed 的最佳路径分
```

边界：

- `best_suffix_score[consumed] = 0`
- 若 `pos` 无法到达 `consumed`，则为 `-INF`

转移：

```text
best_suffix_score[pos] =
  max over candidate k starting at pos:
    base_score(k)
    + spelling_bonus(k)
    - penalties(k)
    + best_suffix_score[k.end]
```

这一层可以复用 `MakeSentence()` 的思路，但不必强依赖 `Poet`。第一版直接在 `script_translator` 内针对当前输入局部做 DP，工程上最稳。

#### Step 4：重排首词候选

对每个首词候选：

```text
continuation_score =
  best_suffix_score[c.end]                  if reachable
  dead_end_penalty                          otherwise

final_score =
  base_score(c)
  + continuation_score
  + exact_match_bonus
  + normal_spelling_bonus
  - correction_penalty
  - abbreviation_penalty
```

然后统一排序。

建议排序键：

1. `final_score` 降序
2. `exact_match` 优先
3. `normal_spelling` 优先
4. `code_length` 降序
5. 原始词典顺序 / 原始 quality 作为最终 tie-breaker

#### Step 5：`Next()` 改为顺序吐出重排后的候选

当前 `Next()` 是流式从 `phrase_iter_` / `user_phrase_iter_` 中推进。

改造后建议：

- `Evaluate()` 一次性构建 `ranked_candidates_`
- `Next()` 只从 `ranked_candidates_` 中按索引输出

这样实现最直接，也方便调试与测试。

## MVP 与演进路线

### MVP

第一版只做三件事：

1. 收集全部首词候选
2. 计算“后缀是否可达 + 最佳后缀分”
3. 用统一分数重排

先不做的内容：

- 深度上下文联想
- 更复杂的语言模型
- 外部可配置权重

### 第二阶段

如 MVP 效果成立，再考虑：

1. 将若干权重开放为配置项
2. 将 suffix DP 抽象成可复用 helper
3. 评估与 `Poet` 融合，减少重复打分逻辑

## 参数建议

第一版建议把权重写死在代码里，便于 review 和调优：

```text
exact_match_bonus        = +100
normal_spelling_bonus    = +8
abbreviation_penalty     = -12
correction_penalty       = -16
dead_end_penalty         = -1000
```

说明：

- `dead_end_penalty` 需要足够大，确保不可续接候选稳定落后
- `exact_match_bonus` 要高于一般词频波动
- `normal_spelling_bonus` 和 `abbreviation_penalty` 只做轻中度偏置，避免伤害已有模糊音体验

这些数值不是最终答案，但适合作为第一版启发式起点。

## 与现有造句逻辑的关系

现有 `MakeSentence()` 已经有“从词图找最优路径”的能力，但它在当前 `script_translator` 中主要用于“没有 exact-matching phrase 时生成句子候选”。

本设计不是替代 `MakeSentence()`，而是把“全串最优”的思想前移到首词候选排序阶段。

两者关系如下：

- 当前：
  - 先按首词前缀长度出候选
  - 无精确词时，再用 `MakeSentence()` 兜底生成句子候选
- 改造后：
  - 先对首词候选做“首词 + 后缀”全串打分
  - `MakeSentence()` 仍可保留为完整句子候选来源

## 性能分析

### 当前成本

当前实现倾向流式出候选，首屏延迟较低，但排序目标较弱。

### 新增成本

新增成本主要是：

1. 收集全部首词候选
2. 计算 suffix DP
3. 对首词候选排序

在单个 segment 内，状态数由 syllable graph 的位置数决定，通常不大。即便开启较多 algebra，`best_suffix_score[pos]` 仍然只需按位置做一次 memoization。

粗略复杂度：

- 收集候选：`O(N)`
- suffix DP：`O(E)` 到 `O(E log E)`，取决于内部容器
- 排序：`O(N log N)`

其中 `N` 是起点候选数，`E` 是可续接候选边数。

对典型中文输入长度，这个代价可接受。

### 性能控制手段

1. 仅对起点候选数超过阈值时启用重排。
2. 仅在 `consumed >= 2` 时启用。
3. 给 suffix DP 设置最大探索深度或候选数上限。
4. 保留配置开关，必要时允许回退旧逻辑。

## 兼容性与风险

### 兼容性收益

- 不需要用户改词典
- 不需要用户改 algebra
- 对“完整输入串但候选被中间前缀淹没”的问题更稳

### 潜在风险

1. 某些依赖“最长前缀优先”习惯的用户会感觉排序变了。
2. 在极端膨胀的 syllable graph 上，首屏延迟可能上升。
3. 若惩罚过重，可能误伤合理的简拼、模糊音候选。
4. 用户词典候选与系统词候选的融合方式可能需要重新校准。

### 风险控制

1. 提供实验开关，例如：
   `translator/global_rerank: true`
2. 默认只在 `script_translator` 生效
3. 保留原排序作为 fallback
4. 加入日志与 profiling 点，便于比较新旧逻辑

## 测试计划

### 单元测试

建议新增测试覆盖以下场景：

1. 完整精确词优先
   - 输入 `gengchajin`
   - 期望 `更差劲` 早于 `更差`，且明显早于死路前缀候选

2. 可续接前缀优先于死路前缀
   - 输入构造为：
     - 候选 A：吃更长前缀，但剩余不可达
     - 候选 B：吃稍短前缀，但剩余可达
   - 期望 B 早于 A

3. 正常拼写优先于缩写
   - 同一词条精确拼写与简拼同时存在
   - 期望精确拼写优先

4. 正常拼写优先于纠错
   - 同一候选既可由精确路径得到，也可由 correction 路径得到
   - 期望精确路径优先

5. 用户词保留优势但不压倒全串死路惩罚
   - 用户词 A 质量高但死路
   - 系统词 B 质量略低但可完整续接
   - 期望 B 仍优先

### 回归测试

需要回归的典型输入：

- 常规全拼整词
- 模糊音整词
- 简拼整词
- 长句输入
- 启用用户词典后的高频词
- 开启 `enable_word_completion` 的预测词场景

## 代码级落地建议

### 预估修改点

高概率需要改动的方法：

- `ScriptTranslation::Evaluate()`
- `ScriptTranslation::Next()`
- `ScriptTranslation::PrepareCandidate()`
- 新增：
  - `CollectRankedCandidates()`
  - `ComputeBestSuffixScores()`
  - `RankCandidates()`

### 建议最小入侵实现

先不要动 `Dictionary::Lookup()` 和 `Poet` 的对外接口。

在 `script_translator.cc` 内完成：

1. 读取候选
2. 建立局部候选图
3. 计算后缀分数
4. 重排首词候选

这样最适合作为 fork 的 MVP，也最容易单独 review。

## 备选方案比较

### 方案 A：死路惩罚

只判断后缀是否可达，不做完整后缀打分。

优点：

- 实现最简单
- 对当前问题已经有明显改善

缺点：

- 无法区分“都可达，但后缀质量差异很大”的场景

### 方案 B：首词 + 后缀 DP 重排

本文主推方案。

优点：

- 能稳定表达“整串可解释性优先”
- 算法简单，工程上可落地

缺点：

- 需要一次性收集并排序起点候选

### 方案 C：引入更重的语言模型

优点：

- 理论上效果最好

缺点：

- 过重
- 依赖外部模型与额外资源
- 不适合作为针对 `script_translator` 排序的第一刀

## 开放问题

1. `base_score` 最终取哪些现有字段最合适？
2. 简拼和模糊音的惩罚是否应该区分层级？
3. 是否要把“完整覆盖但低频词”强制锁在第一页？
4. 是否需要把新逻辑做成默认开启，还是先以实验开关进入 fork？
5. 是否要复用 `Poet` 的内部打分，避免重复维护两套“路径分数”？

## 结论

当前 `script_translator` 的主要问题不是词典，而是排序目标函数偏向“最长前缀优先”。在高膨胀的 syllable graph 下，这会让大量中间前缀候选挤占前排，损害完整输入串的用户体验。

更合理的 fork 方向不是继续改词典或要求用户收缩 algebra，而是在 `script_translator` 中引入“首词 + 后缀最佳续接”的全串重排。第一版只需在 `script_translator` 内做局部候选收集、suffix DP 和统一排序，就足以显著改善 `更差劲` 这类问题，同时保持工程改动范围可控。


## 版本归因结论（2026-04-09 补充）

在固定用户现有 `rime_mint` 配置不变的前提下，当前排查已经可以得出两个更可靠的结论：

1. 同一份用户配置下，`librime 旧版本` 的表现明显弱于 `librime master`。
2. 即便升级到 `librime master`，现有行为仍未达到“按整串可解释性优先”的预期。

这意味着问题定义需要修正为：

- 不是“用户配置不合理”。
- 也不是“上游完全没改进”。
- 而是“上游已经修正了一部分候选可靠性与长度质量问题，但现有排序目标仍不足以覆盖该场景”。

### 实测证据

`master + luna_pinyin` 的 `gengchajin` 已可得到：

```text
1. 更差勁
2. 更差
3. 更
4. 庚
5. 耿
```

但 `master + 同一份 rime_mint 配置` 仍会得到类似：

```text
1. 更差技能
2. 更差
3. 更宠爱
4. 更长
5. 根除
6. 庚辰
```

因此，“新版更好但仍不够”已经被实测确认。

### 源码层差异

`1.13.1 -> master` 间与该问题最相关的改动主要集中在：

- `src/rime/gear/script_translator.cc`
- `src/rime/dict/dictionary.cc`

其中可以确认的关键增量包括：

1. `dictionary.cc` 新增 `quality_len`，并在 `DictEntryIterator::Peek()` 中回填到 `entry->quality_len`。
2. `script_translator.cc` 在 `PrepareCandidate()` 中不再使用旧的 `IsNormalSpelling() ? 0/-1` 这类粗粒度质量补偿，而改为使用：

```text
entry->quality_len / full_code_length
```

这说明新版已经开始按“实际匹配码长质量”对候选做更细粒度的加分。

3. `script_translator.cc` 在 `Evaluate()` 中引入了“可靠候选”判断：
   - `has_reliable_phrase`
   - `has_reliable_user_phrase`
   - 对“纠错首选”不再直接视为可靠精确匹配

这会影响是否进入 `MakeSentence()` 兜底路径。

4. `PrepareCandidate()` 中新增了对“用户词是纠错结果”时的优先级回退逻辑，避免纠错用户词无条件压过系统词。

5. `MakeSentence()` / `Lookup()` 现在会带 `blacklist` 过滤，并修复了部分迭代器推进问题。

### 对本问题的意义

这些改动足以解释为什么：

- 新版比旧版更容易把 `更差劲`、`更` 这类候选拉回前排。
- 但新版仍然可能在高膨胀输入图下，把“局部前缀较长但整体解释较差”的候选保留在较前位置。

因为当前 master 的核心仍然是：

- 先按 `code_length` 组从长到短迭代
- 再在组内按词典权重与 `quality_len` 细排

它改进了“同组内质量”和“纠错可靠性”问题，但还没有把“后缀是否还能形成高质量路径”纳入首词排序目标。

### 设计结论修正

因此，若后续要在 fork 中继续改进，最合理的目标不是“推翻上游现有逻辑”，而是：

1. 保留上游已经引入的 `quality_len`、可靠候选判定、纠错优先级修正。
2. 在此基础上再补一层“首词 + 后缀最佳续接”的全串重排。
3. 将该补丁定义为“超越 master 当前行为的增强”，而不是“修复 1.13.1 的历史缺陷”。

这样更符合现有证据，也更容易让 reviewer 理解问题边界。
