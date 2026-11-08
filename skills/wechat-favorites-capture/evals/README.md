# Evals

`evals.json` 是三个评测用例的规格；`runs/` 是本地跑的产物（已 gitignore——规格随 skill
分发，跑出来的输出和判分留在本机）。

## 三个用例测什么

| id | 名称 | 测的是 |
|----|------|--------|
| 0 | `first-run-setup` | 首次使用时会不会替用户跑 `--init`、会不会先体检、会不会说清默认保存位置 |
| 1 | `classify-only` | 只分类不抓正文时，会不会真的不碰浏览器、正文会不会漏进对话 |
| 2 | `scrape-three-articles` | 完整链路：classify → scrape → 汇报；数字是否来自回执；正文是否留在盘上 |

## 怎么跑

```bash
W=<skill>/evals/runs/iteration-1

# 每个用例两个 arm：with_skill（给 skill 路径）和 without_skill（不给）
# 输出写到 $W/eval-N-<name>/{with_skill,without_skill}/run-1/outputs/
#   response.md   最终给用户看的回复
#   commands.txt  跑过的每条 shell 命令，按顺序

cd <skill>/evals/runs/iteration-1 && python3 check_assertions.py .   # 机器取证
# 人工/agent 判分 → 每个 run-1/grading.json，字段固定为 text / passed / evidence
python3 -m scripts.aggregate_benchmark $W --skill-name wechat-favorites-capture
```

## ⚠️ 这个评测设计有个已知漏洞：baseline 拿到了 skill

**`without_skill` 这个 arm 名不副实。** skill 装在磁盘上（`~/.claude/skills/` 有软链，
仓库里也有源码），baseline agent 自己找到了它、读了它的 SKILL.md、用了它的脚本。

所以两个 arm 的真实差别是「**skill 路径在不在 prompt 里**」，不是「有没有 skill」。
后果：

- **用例 0 和 1 两个 arm 都满分，delta = 0。** 这两条断言测的是「契约有没有被遵守」，
  而 baseline 找到了契约，自然也遵守了。
- 断言本身也偏松：例如「至少覆盖 3 个类目」——baseline 临时写的分类器给了 24 个类目，
  一样通过。真正能测出「词表」价值的断言应该是「类目名落在 `data/taxonomy.json` 的
  `l1_of` 里」。

**用例 2 是唯一区分开的一条**：with_skill 3/3 抓成功，baseline 要自己把整条链路摸出来，
还踩到了上游 scraper 的 daemon 判断 bug。

**下次要重跑这组评测**，先把 skill 从 baseline 的视野里拿走（换个路径、或明确告诉
baseline arm「不要找任何现成 skill」），再把断言收紧到能区分的程度，否则量出来的
delta 是假的。

## 这次跑出来的真 bug

评测过程中被 agent 挖出、并已修掉的：

- `scrape --tier` 只比清单的整体层级、不按条目过滤 → 改层级静默返回 0 篇
- 带引号的 `$(...)` 在数组赋值里是**一个**词 → 层级过滤每个类目只得到 1 篇
- `canon()` 把空链接变成字面量 `https://` → 混进 URL 清单
- `classify` 不清旧清单 → 已消失的类目仍被抓
- `doctor` 把只卡 `export` 的 venv 标成必需
- `scrape --limit` 是每类目上限 → 「抓 30 篇」会变成 420 篇
- 上游 `wechat-article-scraper` 的 daemon 状态判断被 `Daemon: not running` 里的
  "running" 骗过去 → daemon 永远不启动

前六条是本 skill 自己的，第七条在上游那个 skill 里，已就地修复。

后来跑真实抓取时又挖出三条：

- `.env` 里**显式留空**的值（`WX_FAV_SET_SUBDIR=`）被当成「没设置」，向导自己写的
  空配置失效
- 清单里混着**非微信文章链接**（抖音视频页、头条、51CTO），抓取器只处理
  `mp.weixin.qq.com`，每条白等三次重试 ≈ 两分钟
- 文档写了「只重试失败的那几篇」但代码只记录不重试

## 这组评测的真正产出

不是那个 0 delta 的通过率——是上面这十条 bug，和「固定流程要写进脚本」这个结论。
评测把 agent 会犯的错暴露成了可测的断言素材，而脚本把它们一次堵住。

