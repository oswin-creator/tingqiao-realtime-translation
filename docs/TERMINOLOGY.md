# Local terminology / 本地专业术语

The application ships a public Wikidata snapshot (CC0-1.0), not any user's custom glossary or meeting data. The snapshot contains 10,018 concepts. Language labels and aliases do not count as separate concepts. Curated seeds and semantic deduplication produce 10,041 default entries.

内置快照日期为 2026-11-05，包含统计、计算机、经济金融、法律、医学和数学领域。韩语栏有 4,009 条，其中 3,822 条包含韩文字母；其他条目可能保留国际名称或缩写。缺失标签不通过机器翻译补齐，也不编造译名。支持的 16 种语言并不代表每条都有 16 种译名。

## Runtime behavior / 运行方式

- No online dictionary lookup occurs during translation. Relevant terms are retrieved locally.
- 用户自定义优先于人工校订词，人工校订词优先于 Wikidata。经过校验的本机更新包替代内置 Wikidata 快照；更新损坏时可回退上一版本地包或内置快照，保留用户文件。
- 检索只提示翻译模型，不直接覆盖识别原文。Index、自定义 Chat Completions 接口支持；当前 Google 接口保持原请求。
- 最近 60 秒的同会话语境可辅助消歧，最多 40 条活跃术语；每段最多 8 条、估算 300 Token、硬性 900 UTF-8 字节。没有相关命中就不添加提示。
- 设置 → 翻译设置 → 术语与语境，可导入/导出 JSON。导入替换自定义层，原自定义文件会备份；导出为当前合并后的有效词库。

The current audit covers schema, checksums, layering, priority, budget and sampled retrieval. It does not establish real meeting translation accuracy, battery life or multi-hour reliability. Wikidata labels are not professionally reviewed translation guarantees.

## Files and maintenance / 文件与维护

- `Resources/terminology.json`: 31 curated seeds.
- `Resources/wikidata.json` and `wikidata.manifest.json`: public snapshot and checksum metadata.
- `Sources/Terminology.swift`: offline lookup and layered loading.
- `Tools/update-wikidata.py`, `Tools/wikidata-terminology.json`: optional maintainer update pipeline; not run by the app or standard tests.
- `zsh test-terminology.sh`, `zsh test-wikidata.sh`: synthetic and bundled-pack validation.

Do not remove caches or relax quality gates merely to reach a larger count. The roughly 50,000-concept target is not yet met. Data maintenance uses official Wikimedia endpoints, caching and conservative request pacing. No full dump or automatic translation is required.

Source: https://www.wikidata.org/wiki/Wikidata:Licensing · CC0-1.0.
