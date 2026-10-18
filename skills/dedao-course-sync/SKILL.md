---
name: dedao-course-sync
description: 增量抓取得到 APP 的两个付费专栏（得到精选 / 得到头条）最新内容，存成 Vault 里的 Markdown 笔记，按 article_id 自动跳过已抓过的。用户说「抓得到精选」「同步得到头条」「更新一下得到课程」「得到专栏有新文章吗」「dedao 同步」时使用 —— 哪怕用户没说「dedao」或「得到专栏」这几个字，只要提到得到 APP、得到精选、得到头条、课程笔记增量同步，就该用这个 skill。也用于查看某期讲了什么、某专栏最近更新了什么。
---

# 得到专栏增量同步

把得到 APP 的付费专栏增量抓进 Vault，产出 `raw/Courses-GetIt/{得到精选,得到头条}/` 下的 Markdown。**只抓不加工** —— 整理、提炼、判断留给写稿环节。

---

## 一、前置条件

抓取依赖用户的 Chrome 登录态。跑之前确认两件事，缺一件都会失败：

```bash
opencli doctor          # 必须全绿，尤其 "Extension: connected"
```

- **Chrome 没开**，或 OpenCLI 扩展没装（[Chrome Web Store](https://chromewebstore.google.com/detail/opencli/ildkmabpimmkaediidaifkhjpohdnifk)）
- **Chrome 掉了得到登录态** —— 最常见的失败原因，报错通常是「等了 45s 仍不合格」

> ⚠️ **不要自己试着登录。** 得到是付费课，脚本里没有账号密码，登录必须由用户在浏览器里完成。你能做的是让用户重新登录，然后把 `opencli doctor` 的输出转述给他。

---

## 二、配置（人跑，一次）

```bash
bash scripts/dedao_sync.sh --detect      # 看本机 vault 和 opencli 状态
bash scripts/dedao_sync.sh --init        # 写 ~/.mario-skills/.env
```

> ⚠️ **`--init` / `--detect` 不要在 LLM 调用里跑。** 配置归人管。

配置走 mario-skills 共享的 `.mario-skills/.env`，**不额外造配置文件**。`VAULT_DIR` 与 `diary-writer`、`book-enquire-reader` 同名同义 —— 写一次三个技能都看到，本 skill 通常根本不需要单独配置。

排错时先查来源，不要猜：

```bash
bash scripts/dedao_sync.sh --config-info           # 人读：值 + 来源 + 搜索路径
bash scripts/dedao_sync.sh --config-info --json    # 机读
```

回执里 `error:config_not_found` 时，把 `searched` 数组**原样**转述给用户 —— 那是所有找过的位置，不要压缩成一句「没配置」。

---

## 三、调用契约

**抓取全部由 `scripts/` 接管。LLM 不自己拼路径、不自己判断哪些抓过了。**

```bash
bash scripts/dedao_sync.sh list  --course all
bash scripts/dedao_sync.sh fetch --course all --count 20
bash scripts/dedao_sync.sh fetch --course all --count 20 --dry-run
```

| 参数 | 说明 |
|------|------|
| `--course` | `jingxuan`（精选）/ `toutiao`（头条）/ `all`（默认两个都抓） |
| `--count N` | 本次要抓的**新**篇数，不给就用 `DEDAO_COUNT`（默认 20） |
| `--dry-run` | 只列待抓清单，**不写任何文件** |
| `list` 子命令 | 同参数，但只列清单不抓正文。它本身就是只读的 |

**`--dry-run` 仍然需要浏览器。** 待抓清单来自得到那个 JSON 接口，不调它就没有清单可列。它保证的是「一个文件都不写」，不是「不碰浏览器」。

单篇约 4~6 秒（等页面加载是大头）。`--count 20` × 2 个专栏大约 4 分钟 —— **放后台跑**，别让用户干等。

### 回执

stdout 只有 JSON，人读信息全在 stderr。`list` / `fetch` / `dry_run` 各发一条；`--course all` 跑完再补一条 `summary`。

| 字段 | 处理 |
|------|------|
| `ok:true, action:"dry_run"` | 还没抓。问用户是否要真跑，或直接跑 |
| `ok:true, action:"fetch", saved:N` | 抓到了 N 篇。告诉用户落盘路径 |
| `ok:false`，或有 `failed>0` | 逐条转述 `error`，别只说「失败了」 |
| `error:config_not_found` | **不要自动跑 `--init`**，转述 `searched` |
| `error:opencli_not_found` | opencli 不在 PATH，让用户装 |

**退出码**：`0` 成功；**有任何一篇抓取失败就是 `1`**；配置/参数错是 `2`。所以 `fetch` 返回非 0 一定要看 —— 部分失败不会被吞掉。

---

## 四、它是怎么工作的

理解这几条有助于判断问题出在哪。

1. **列表走 JSON 接口，不爬 DOM。** 课程页背后是
   `POST /pc/bauhinia/pc/class/purchase/article_list`，`reverse: true` 即倒序，
   `count` 上限 50（给 100 会返回空），翻页用 `max_id = 上一页最后一条的 id`。
   2023 年那套老脚本假设只能逐条点击拿 URL、要跑 2 小时初始化 —— **那个前提早已
   不成立**，不要再往那个方向修。

2. **去重靠 frontmatter 的 `article_id`（= 得到侧 enid），不靠文件名。**
   标题会改、slug 清洗规则也变过，用文件名匹配必然出错。存量里得到精选 47 篇
   （1 篇缺该字段，会从 `source` 链接兜底）、得到头条 80 篇（全部有）。

3. **正文只取 `.article-body` 一个容器**，所以页面头部、侧栏目录、评论区
   天然不会混进来。抓完还要剥掉首尾的页面元素（标题回显、时长、「建议 WiFi
   环境下播放」、结尾的「写笔记划线删除划线复制」工具条）。

4. **图片不用管。** 正文里保留 `![](https://...)` 远程链接，Vault 的
   `obsidian-local-images-plus` 插件会自动下载进 `assets/` 并改写成
   `![[...]]`。存量文件里的本地图片都是它干的，不是这个脚本干的。

5. **失败清单落在 `DEDAO_STATE_DIR/dedao-sync-errors.json`**，不在 skill 目录里。
   某轮全部成功后旧清单会被自动删掉 —— 留着只会误导。

---

## 五、出问题时

脚本失败不会静默 —— 单篇失败会进失败清单，正文过短会被判为失败而不是写出一篇残稿。

| 症状 | 多半是 | 动作 |
|------|--------|------|
| `等了 45s 仍不合格` / `正文只到 N 字` | Chrome 掉了登录态，或网络慢 | 跑 `opencli doctor`；不行就让用户重新登录得到 |
| `.article-body 始终没出现` | 页面结构变了 | `opencli browser <session> open <文章URL>` 后 `eval "document.querySelector('.article-body')?.innerText.length"` 确认 |
| `extract 只拿到 N 字，DOM 探到 M 字` | 分块循环漏了 | 抽一篇手动 `opencli browser <session> extract --selector .article-body --chunk-size 20000` 对照 |
| 清洗后只剩 N 字 | 清洗锚点切错了 | 见下 |
| 接口返回空列表 | 用户可能已退订这个专栏（`is_buy` 为 false） | 告诉用户，不要重试 |

**清洗规则（`strip_preamble`）踩过的坑值得记住：不要用「以动作词开头」来识别结尾工具条。**
「分享一部2018年出版的书…」「收藏了这个想法」这类正常正文会被误判，从中间腰斩文章。
判据必须是「整行只有动作词」。

---

## 六、绝对禁止

- ❌ 在 LLM 调用里跑 `--init` / `--detect`
- ❌ 自己尝试登录得到
- ❌ 自己读或打印 `.mario-skills/.env` —— 用 `--config-info` 查
- ❌ 改去重逻辑（换成按文件名比对）。文件名会被标题改动和 slug 规则变更打穿
- ❌ 把清洗锚点从「整行只有动作词」放宽成「以动作词开头」—— 会腰斩正文
- ❌ 把失败当成「抓完了」。`failed > 0` 必须转述给用户
- ❌ 抓完之后主动建议跑写稿流水线。除非用户问了

---

## 七、和其他技能的关系

- `wewrite-topic` 在选题阶段会检索 `raw/Courses-GetIt/` —— 抓回来的新内容就是它的
  素材来源。本 skill 只负责往 `raw/` 灌原始素材。
- `01-Wiki/00-素材库/课程论据库/得到精选-选题素材索引.md` 是给流水线用的选题索引，
  **本 skill 不碰它**。
- 同目录下另外 4 个课程目录（`个人影响力打造35讲`、`刘澜学习力30讲`、
  `刘澜领导力30讲`、`宁向东的管理学课`）是已完结课程，由更早的流程一次性抓完，
  **不在本 skill 范围内**，不要去动。
