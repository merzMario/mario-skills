---
name: dankoe-letters-fetch
description: 抓取 Dan Koe newsletter（letters.thedankoe.com）上尚未入库的免费文章，存成 Vault 里的 Markdown 原文。用户说「抓 Dan Koe 文章」「拉 Dan Koe 最新 newsletter」「同步 Dan Koe」「dankoe 抓取」，或提到 Dan Koe / future-proof / letters.thedankoe.com 且意图是把新文章归档进 vault 时使用。不用于临时读某一篇、不用于翻译已存文件（那是 翻译/ 目录的职责）、不用于分析或总结文章。
---

# dankoe-letters-fetch

抓取 `letters.thedankoe.com/archive` 上**尚未入库**的免费文章，落到 `raw/DanKoe/原文/`。

---

## 一、调用契约

**抓取全部由 `scripts/` 接管。LLM 不自己分页、不自己判付费墙、不自己算 slug。**

所有脚本在本 SKILL.md 所在目录的 `scripts/` 下。**从 SKILL.md 的位置解析该目录**，不要依赖调用时的 CWD。

```bash
# 看还有什么新的（只走 curl，不开浏览器）
bash scripts/dankoe_fetch.sh list --count 10

# 抓（需要浏览器）
bash scripts/dankoe_fetch.sh fetch --count 10

# 只列清单，不写任何文件
bash scripts/dankoe_fetch.sh fetch --count 10 --dry-run
```

| 参数 | 说明 |
|------|------|
| `--count N` | 本次最多新增几篇，默认取 `DANKOE_COUNT`（10）。archive 里不足 N 篇新的就全抓并说明 |
| `--dry-run` | 只列待抓清单，**不写任何文件**。仍需网络（archive 是 HTTP 接口），但不开浏览器也不写盘 |

`list` 子命令本身就是只读的，对它加 `--dry-run` 没有意义。

### 回执

stdout 只有 JSON，人读信息全在 stderr。`list` / `fetch` / `dry_run` 各发一条。

| 字段 | 处理 |
|------|------|
| `ok:true, action:"fetch", saved:N` | 抓到了 N 篇。告诉用户落盘路径 |
| `stats.exhausted:true` | archive 里新的免费文章不足 `--count`，已追平 |
| `ok:false`，或有 `failed>0` | 逐条转述 `error`，别只说「失败了」 |
| `error:config_not_found` | **不要自动跑 `--init`**，转述 `searched` 数组 |
| `error:opencli_not_found` | 只有 `fetch` 会报这个；`list` 只走 curl 仍可用 |

**退出码**：`0` 成功；**有任何一篇抓取失败就是 `1`**；配置/参数错是 `2`。

---

## 二、配置（人跑，一次）

```bash
bash scripts/dankoe_fetch.sh --detect      # 看本机 vault 和 opencli 状态
bash scripts/dankoe_fetch.sh --init        # 写 ~/.mario-skills/.env
```

> ⚠️ **`--init` / `--detect` 不要在 LLM 调用里跑。** 配置归人管。

配置走 mario-skills 共享的 `.mario-skills/.env`。`VAULT_DIR` 与 `diary-writer`、`book-enquire-reader`、`dedao-course-sync` 同名同义 —— 写一次四个技能都看到。

排错先查来源，不要猜：

```bash
bash scripts/dankoe_fetch.sh --config-info           # 人读：值 + 来源 + 搜索路径
bash scripts/dankoe_fetch.sh --config-info --json    # 机读
```

---

## 三、四个不能踩的坑

这四条写死在 `dankoe_fetch.py` 里，改代码前先读它们的理由。

**① archive 的 `limit` 上限是 23，且超出会被静默钳回**

填 24/30 服务端**不报错**、直接给你 23 条；填 100 才报 `{"errors":[{"msg":"Invalid value"}]}`。所以必须 `offset` 步进 **23** 逐页拉，且步长必须等于请求值 —— 按「我以为拿了多少」步进会漏页。

**② 付费墙只能用 `audience` 字段判，不能扫正文关键词**

被付费墙截断的正文可能**完全不含显式文案** —— 直接断在词中间。关键词法会漏判，而漏判方向最坏：把截断稿当完整稿存进库。

archive 列表每条自带 `audience`：`everyone` = 免费，`only_paid` = 付费墙。它在**枚举时**就拿到了，零额外请求。

**③ archive 列表里的 `body_html` 恒为 `null`**

正文只在单篇端点 `/api/v1/posts/<slug>` 里有。浏览器路径两次失败时的兜底就走那个端点。

**④ slug 必须精确匹配，不能前缀匹配**

Substack 给重发/改写文章加消歧后缀（`-ef8`）。`how-to-launch-into-a-completely-new` 和它的 `-ef8` 版是**两篇不同文章**，正文不同。前缀匹配会把新后缀误判成已抓。

若发现 slug 前缀相同的已存文件，报告里标注让用户人工过目。

---

## 四、渲染等待是必须的

Substack 文章页渐进渲染。extract 跑太早会拿到两种坏结果：

- `selector_not_found` —— article 还没挂载（好认）
- **半截正文** —— 断在词中间，长得像付费墙截断，实为假阳性（难认）

所以流程是：`open` → `wait selector article` → 等 2.5s → `extract`。若尾部缺少 `Likes` / `Restacks` / `– Dan` 这类收尾特征，再 `wait text "Restacks"` 后重抽一次。

**落盘前的完整性判据**（也是付费墙兜底）：正文 ≥ 1000 字符 **且** 尾部有收尾特征。不满足就不落盘，报告里列出。

---

## 五、落盘格式

命名：`YYYYMMDD-{url-slug}-原文.md`。

- 文件名日期取 archive 的 `post_date` ISO 日期部分去横线（`2026-09-19` → `20260919`）
- `**Published**` 用同一个 ISO 日期

**不要用页面显示日期**（`Sep 20, 2026` 是本地时区渲染，会跟 archive 差一天）。**不要做时区换算。**

```markdown
# {English Title}

{### Subtitle（若有）}

**Source**: https://letters.thedankoe.com/p/{slug}
**Published**: {YYYY-MM-DD}
**Author**: Dan Koe

---

{正文：起点在第一个 MMM D, YYYY 日期行之后；末尾 likes/restacks 页脚保留}
```

**用粗体键值行，不要加 YAML frontmatter。** 这是 `raw/DanKoe/` 的既有惯例（`翻译/` 下 95 篇也是这个格式），换了会让下游解析失效。

末尾页脚保留 —— 翻译流程不用它，但删了没收益、留着可复查。

---

## 六、绝对禁止

- ❌ 在 LLM 调用里跑 `--init` / `--detect`
- ❌ 自己读或打印 `.mario-skills/.env` —— 用 `--config-info` 查
- ❌ 把去重改成 slug 前缀匹配（会吞掉 `-ef8` 消歧版）
- ❌ 改用正文关键词判付费墙
- ❌ 给文件加 YAML frontmatter（该目录是粗体键值行惯例）
- ❌ 用页面显示日期命名，或做时区换算
- ❌ 落盘尾部缺收尾特征的半截正文
- ❌ 下载图片 —— 保留 CDN URL 引用即可
- ❌ 翻译或润色 —— 那是 `翻译/` 目录的职责
- ❌ 给已存文件补抓 —— slug 精确匹配，命中即跳

---

## 七、验证

抓完逐篇确认：

- 文件名 `YYYYMMDD-{slug}-原文.md`，slug 段与 URL 末段一致
- `**Source**` / `**Published**`（ISO）/ `**Author**` 三行齐全
- 正文 ≥ 1000 字符，尾部有收尾特征
- 全部落盘文件无重复 slug
- **重跑一次：所有候选应全部命中「已入库」跳过**
