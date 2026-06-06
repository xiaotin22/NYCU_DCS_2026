# 計畫：3-Engine + 移除 score_mem 重構

> Branch: `mult3-on-burst32`
> 目標：把乘法引擎從 6 路縮到 3 路、移除 `score_mem`，評估 `cycle × clk × area` 的淨效益。
> 狀態：**設計階段，尚未動 RTL**。本檔為接手者的完整施工藍圖。
> 一句話結論：**這是 area↓↓ / cycle↑↑ 的高風險 trade，淨 performance 不確定，必須上工作站實測才能拍板。** 下面把帳算清楚，並給漸進步驟與備案。

---

## 0. 當前架構（重構的起點）

檔案 `CA.sv`（2431 行）。Attention 走 **burst-32 三段式**：

- **6 個乘法引擎**（每個 `Mult_5Stage_Parallel`，64 lane × 9 tap 的 s4×s4，5-stage pipeline）：
  - `u_mult`(e0)：Q / NORM / SCORE(head0/偶) / FINAL d0
  - `u_mult_k`(e1)：K / SV head1-奇 score / FINAL d1
  - `u_mult_v`(e2)：V / FINAL d2
  - `u_mult_aux0/1/2`：QKV-stream score(head0/head1) / MHA FINAL head1 d0/d1/d2
- **中間 buffer**：
  - `score_mem[0:63] × 768b` = **49,152 flops**（存 base-16 signed-digit `{d0,d1,d2}`）
  - `q_mem/k_mem/v_mem[0:31] × 256b` = **24,576 flops**
- **三段式**：QKV(32 phase) → SV(SHA 16 phase / MHA drain) → FINAL(SHA 3 路 / MHA 6 路, 32 phase)，group 間有 prefetch overlap，穩態約 **35 cycle/組**（`HA_RESTART_*`）。
- **signed-digit 的作用**：score(11-bit) 拆成 `d0+16·d1+256·d2`（各 s4），讓 FINAL 的 `score×V` 用 3 個 s4×s4 乘法器並行 + 重組，避免 s11×s4 寬乘法器，並把進位拆解搬到寫入端（FINAL 讀取端只切片，**短 critical path**）。這就是「每 head 要 3 路」的根源。

---

## 1. 核心洞察與「不可同時成立」的矛盾

**洞察 A：6 路 → 3 路的關鍵是放棄 signed-digit。**
若 FINAL 改用 **s11×s4 單路寬乘法器**（像 `CA_NE.sv` 的 `calc_final_lane`，`score_prod_t`=15-bit），則：
- SHA FINAL：3 路 → **1 路**
- MHA FINAL：6 路（head0 d0/d1/d2 + head1 d0/d1/d2）→ **2 路**（head0 + head1）
→ `aux0/1/2` 三個引擎中，FINAL 用途消失。

**洞察 B：移除 `score_mem` 需要 score「不落地」。**
`score_mem` 存在的根本原因 **不是 signed-digit**，而是 **QKV 階段和 FINAL 階段共用同一批引擎、不能同時做**，所以 score 算完要等到 FINAL 階段才被消化，中間必須 buffer。要拿掉它，必須讓 **score 算完立刻接 final**（用 pipeline register 串接，固定延遲，不是 random-access array）。

**⚠️ 矛盾（最重要，務必讓接手者理解）：**
> **「只開 3 路引擎」與「現狀的 group overlap」互斥。**
> 現狀能做到 ~35 cycle/組，是因為引擎多（QKV 用 e0/1/2、FINAL 用 6 路、score 藏在 stream），group N 的 FINAL 能和 group N+1 的 QKV 在不同引擎上重疊。
> 砍到 3 路後，QKV(e0/1/2)、score(e0)、final(e1) 全擠在同一批引擎上 → **group 之間無法 overlap，且組內 score/final 也被序列化** → cycle 大增（見 §3）。

結論：**3 engine + 移除 score_mem 在技術上可行，但代價是 cycle 約 2~2.8×。** 這不是 bug，是引擎數決定的平行度上限。

---

## 2. 提案架構（3-Engine，無 score_mem）

```
3 engines: e0, e1, e2   （e0/e1 升級為 s11×s4；e2 維持 s4×s4，只做 QKV）

階段 1  QKV  (32 phase)：
    e0 = Q[i] = x[i]×W_Q        ┐
    e1 = K[i] = x[i]×W_K        ├ 三路並行 (s4×s4)，各自 PoT → 存 q/k/v_mem
    e2 = V[i] = x[i]×W_V        ┘

階段 2  SCORE→FINAL 融合 (32 phase, score 不落地)：
    e0 = score[i] = Q[i]×K[i]ᵀ   (s4×s4, b_transpose)
         → comb: attention act (x<0→x>>2) + truncate 11-bit
         → 經固定 pipeline 延遲串到 e1（不寫任何 array）
    e1 = final[i] = score[i]×V[i] (s11×s4)
         → ACT (ReLU/RAT/CAT/BAT) → PoT → 輸出
```

**移除**：`score_mem`、`u_mult_aux0/1/2`、`pack_attention_score`、`extract_score_nibble_s4`、`nibb_combine*`、`combine_mha_heads_full`、IM_SV 的 signed-digit 路徑。
**保留**：`q/k/v_mem[0:31]`（階段 2 需 random access 讀 Q/K/V）、`u_pot`/`u_pot_k`/`u_pot_v`（QKV 三路量化）、ACT、最終 PoT。
**升級**：`Mult_5Stage_Parallel` 的 e0/e1 要支援 A operand = s11（FINAL 的 score 是 11-bit），`prod` s8→s15，`partial/sum` 對應加寬。e2 維持 s4×s4。

> 註：score 路徑 **不過 PoT**（規格 Step 4 只有 activation+truncate，無量化），與現狀一致。

---

## 3. 排程計算（核心交付物）

### Pipeline 延遲常數（沿用現狀，cycle）
| 路徑 | 延遲 |
|---|---|
| issue → mult_valid | 7（1 issue buf + 5 mult + 1 out reg） |
| mult → PoT out | 5 |
| mult → ACT out | 5 |
| ACT → PoT out | 5 |

### SHA 一組（32 matrix）排程
```
階段1 QKV:   issue cycle 0..31   (e0=Q, e1=K, e2=V)
             q/k/v_mem[i] ready @ cycle i+12   (mult 7 + PoT 5)

階段2 score: e0 free @ cycle 32
             score[i] issue @ 32+i      (i=0..31 → 32..63)   q/k_mem[i] 早 ready
             score[i] mult_valid @ 39+i  → comb act+truncate

階段2 final: e1 free @ cycle 32
             final[i] issue @ 40+i       (i=0..31 → 40..71)  v_mem[i] 早 ready
             final[i] 輸出 @ 40+i+18 = 58+i  (mult7+ACT5+PoT5+outreg1)
             → 末筆輸出 @ cycle 89
```
- **組內 latency**：~89 cycle。
- **Group restart**：e0 忙到 63、e1 忙到 71 → group N+1 的 QKV(需 e0/1/2) 最早 ~72 起。
- **穩態 group 間距**：~**72 cycle/組**。
- **8 組 SHA**：7×72 + 89 ≈ **~593 cycle**。（現狀 6-engine ≈ 280）

### MHA 一組（32 matrix，head0+head1）排程
每 matrix 需 score0/score1（2 路）+ final0/final1（2 路），但只有 e0/e1 能做（e2 階段2 閒）：
```
階段1 QKV:    cycle 0..31 (同 SHA)
階段2 score:  score0[i]=e0, score1[i]=e1   @ 32+i  (32..63)
階段2 final:  score 用到 63 → final 從 64 起
              final0[i]=e0, final1[i]=e1   @ 64+i  (64..95)
              輸出 @ 64+i+18 = 82+i        (82..113)
```
- 組內 latency ~113，e0/e1 忙到 95 → group 間距 ~**96 cycle/組**。
- **8 組 MHA**：7×96 + 113 ≈ **~785 cycle**。（現狀 6-engine ≈ 280）

### Cycle 對照總表
| | 現狀 6-engine | 提案 3-engine | 倍率 |
|---|---|---|---|
| SHA（8 組） | ~280 | ~593 | 2.1× |
| MHA（8 組） | ~280 | ~785 | 2.8× |
| FFN/Conv | 不變（仍走 FAST_RUN，e0 即可） | 不變 | 1.0× |

> MHA 最痛：3 路引擎要序列化 4 種運算（score0/1 + final0/1）。**備案見 §6。**

---

## 4. 面積帳（flop 估算，待合成實測）

**省下：**
| 項目 | flops |
|---|---|
| `score_mem[0:63]×768b` | 49,152 |
| 3 個引擎（aux0/1/2）的 pipeline register（operand/prod/partial/sum，~12K/engine） | ~36,000 |
| signed-digit 組合邏輯（`pack_attention_score`/`extract`/`nibb_combine`/`combine_heads`） | combinational，省 gate |
| 相關 sideband（aux idx/score pipeline、score_mem 寫入 mux） | ~數百 |
| **小計** | **~85,000 flops** |

**增加：**
| 項目 | 成本 |
|---|---|
| e0/e1 升級 s11×s4：`prod` s8→s15、`partial/sum` 加寬 | 2 engine × ~(64×9×7 額外 prod bits) ≈ +8K flops |
| `q/k/v_mem` 維持（不能 stream，階段2 要 random read） | 0（本來就在） |
| **小計** | **~+8,000 flops** |

**淨省 ≈ 77,000 flops**（約佔目前 register 面積一個顯著比例）。combinational 面積另估（少了 6→3 engine 的乘法器陣列，但 e0/e1 變寬，淨減）。

---

## 5. Performance 評估與決策點

`performance = cycle × cycle_time × area`（越小越好）。

| 因子 | 變化（估） | 備註 |
|---|---|---|
| cycle | ×2.1（SHA）/ ×2.8（MHA） | 引擎平行度下降，失去 group overlap |
| area | ×0.6 ~ 0.7 | 省 ~77K flops + 少 3 engine 乘法陣列 |
| clk | ×1.0 ~ 1.15 | FINAL s11×s4 加法樹變寬（s15×8→s18），可能略增 |

**粗估淨乘積**：`2.1 × 0.65 × 1.1 ≈ 1.50`（SHA）/ `2.8 × 0.65 × 1.1 ≈ 2.0`（MHA）→ **很可能變差**，除非：
- area 省得比估計多（score_mem 大 fanout 移除可能連帶降 clk），或
- 把 MHA 救回（§6 備案，避免 2.8×）。

**決策建議**：先做 **Step A+B+C 的 SHA-only 版本** 上工作站量 area/clk/cycle，用真實數字回填本表再決定要不要做 MHA。**不要一次全改。**

---

## 6. 實施步驟（分階段、可中斷，每步可獨立驗證）

### Step A — 乘法器支援 s11×s4（不改行為）
- `Mult_5Stage_Parallel`：把 A operand 型別從 s4 擴成 s11（新增 `wide_a` 或參數化），`prod_t` s8→s15，`partial/sum` 對應加寬。
- 加一個 input flag（如 `a_is_wide`）：QKV/score 時 A 走 s4（高位 sign-extend），FINAL 時 A 走 s11。
- e2 可保留純 s4×s4 窄版（只做 QKV）以省面積 → e0/e1 用寬版、e2 用窄版（兩種 instance）。
- **驗證**：先讓現狀 6-engine 用寬 e0/e1 跑通（行為不變），確認 timing 退化幅度（量 clk）。這步先確認 **s11×s4 的 critical path 代價**，是 go/no-go 的關鍵閘門。

### Step B — score→final pipeline 串接（SHA 先行，仍保留 score_mem 不刪）
- 新增 dispatch：score 的 mult 輸出 → comb `attention_act + truncate11`（搬現有 `pack_attention_score` 的 activation/truncate 部分，去掉 signed-digit）→ 直接餵 e1 的 FINAL issue。
- 此時先**雙軌並存**：score 同時寫 score_mem（舊路）+ 串接 final（新路），用一個編譯期開關選輸出，比對結果一致。
- **驗證**：RTL sim 比對新舊 FINAL 結果 bit-exact。

### Step C — 移除 score_mem + aux 引擎（SHA 完成）
- 刪 `score_mem`、`u_mult_aux0/1/2`、`pack_attention_score`/`extract_score_nibble_s4`/`nibb_combine*`/`combine_mha_heads_full`。
- 改 Control：SHA 階段 2 改成 score(e0)+final(e1) 兩條連續 issue，重排 `S_HA_ISSUE` 的 stage 機。
- **驗證**：SHA RTL pass + 合成量 area/clk/cycle，回填 §5 表。

### Step D — MHA 排程（高風險，視 Step C 結果決定要不要做）
- MHA score0/score1 用 e0/e1（32 phase），final0/final1 用 e0/e1（再 32 phase）。
- 末端用現有 head-combine 概念把 head0/head1 的 col 0-3 / 4-7 拼回（combinational）。
- **驗證**：MHA RTL pass + 合成。

### Step E — 重新校準排程常數
- 重算 `HA_RESTART_*`、`HA_WR_*`、`HA_FRONT_WAIT` 為新的 group 間距（SHA ~72、MHA ~96）。
- 確認寫回 burst（`ha_wr_fire`）對齊新的 FINAL 輸出 stream。

### Step F — 工作站驗證（依 CLAUDE.md 流程，需使用者許可）
1. `ssh dcs_mimi` → `yes` → `cd Final/`
2. 用本地 `CA.sv` 覆蓋工作站 `01_RTL/CA.sv`
3. `01_RTL/` 跑 `./01_run_vcs_rtl`（RTL sim）
4. `02_SYN/` 跑 `./01_run_dc`（合成、面積、critical path）
5. 調 `02_SYN/syn.tcl` 第 11 行的 clk time 掃面積/performance 曲線

---

## 7. 風險與備案

| 風險 | 緩解 / 備案 |
|---|---|
| **MHA 2.8× cycle 太傷** | **備案 1（4-engine）**：保留 `aux0`，MHA final0/final1 用 e0/e1、score0/score1 用 e0/aux0 → 減少序列化，cycle 介於 6 與 3 engine 之間。area 只多回 1 engine。 |
| **s11×s4 critical path 超標** | Step A 先量。若 clk 退太多，FINAL 改回 signed-digit **但只在 e0/e1 兩路**（仍省 aux2 + 縮 score_mem），放棄「完全拿掉 score_mem」改成「縮小」。 |
| **score 不落地的時序對齊** | score[i]→final[i] 固定延遲，需確認 e0(score) 與 e1(final) 的 issue 間距 = mult+act latency，且 q/k/v_mem[i] 在 final issue 前已 ready（排程已保證，但要 sim 驗）。 |
| **q/k/v_mem 仍佔 24K** | 本方案 **不能** 同時 stream 化 q/k_mem（階段 2 要 random read）。若要連這 16K 一起省，需走「完全融合 streaming」但那要 5 engine（與 3-engine 目標衝突）。二選一。 |
| **淨 performance 變差** | §5 已預警。先 SHA-only 實測，數字不好就停在 Step C 或回備案。 |

### 備案總覽（依 area 省幅排序，cycle 代價遞減）
1. **本計畫（3-engine, 無 score_mem）**：省最多（~77K），cycle 2~2.8×。
2. **4-engine（保 aux0）**：省 ~65K，cycle ~1.6×。MHA 較救得回。
3. **保守（3-engine + 小 score_mem raw-s11）**：省 ~40K，cycle ~1.5×，clk 風險低（FINAL 仍可 signed-digit）。
4. **最低風險（不動引擎，只砍 q_mem/k_mem + score_mem 縮半）**：見另一份分析，省 ~40K，cycle 幾乎不變，**critical path 完全不動**。← 若 performance 優先，建議先做這個。

---

## 8. 關鍵修改點（檔案 / 行號，以當前 CA.sv 為準）

| 區塊 | 行號 | 動作 |
|---|---|---|
| `score_mem` 宣告 | `CA.sv:640` | 刪 |
| `score_mem` 寫入（4 處） | `CA.sv:962-974` | 刪 |
| `q/k/v_mem` 宣告 | `CA.sv:637-639` | 保留 |
| `pack_attention_score` | `CA.sv:729-754` | 抽出 activation+truncate，刪 signed-digit |
| `qk_stream_valid` / aux dispatch | `CA.sv:809-812`,`1310-1362` | 刪 stream-score 機制 |
| `extract_score_nibble_s4` | `CA.sv:1114-1131` | 刪 |
| `combine_mha_heads_full` | `CA.sv:1152-1165` | 刪（MHA 改新 head-combine） |
| IM_SV / IM_FINAL issue（e0） | `CA.sv:1198-1234` | 重寫成 score(e0)/final(e1) |
| engine1 issue（e1） | `CA.sv:1247-1308` | 重寫 |
| aux0/1/2 issue + instance | `CA.sv:1310-1362`,`1444-1478` | 刪 |
| `nibb_combine*` 重組 | `CA.sv:1539-1581` | 刪 |
| `Mult_5Stage_Parallel` 型別 | `CA.sv:1644-1651` | s4→s11(A)、s8→s15(prod) for e0/e1 |
| Control `S_HA_ISSUE` 狀態機 | `CA.sv:298-326`,`457-498` | 改兩段式 score→final 排程 |
| 排程常數 | `CA.sv:162-167` | 重新校準 |

---

## 9. 驗證 Checklist
- [ ] Step A：寬 e0/e1 行為不變，量 clk 退化幅度（go/no-go）
- [ ] Step B：新舊 FINAL bit-exact（雙軌比對）
- [ ] Step C：SHA RTL pass、no latch、no error/fail 命名
- [ ] SHA 合成：area / critical path / cycle 回填 §5
- [ ] Step D：MHA RTL pass
- [ ] MHA 合成數字
- [ ] `out_valid`/`out_data` reset 歸零、無 signed-digit 殘留
- [ ] 256 筆 last-token 輸出正確、寫回 RAM 位址對齊
- [ ] 排程在 in_valid 下降後 10000 cycle 內出完

---

## 附錄：為什麼不是「砍乘法器就省面積」
`CA_NE.sv` 看似「只用 1 個乘法器」其實是錯覺——它的 attention 乘法是 `att_full_parallel` 內 combinational 全展開（~3072 個），總數和本設計同級。**面積大頭從來不是乘法器邏輯，而是「為平行排程而背的 register」**（6 套 pipeline reg + score_mem + qkv_mem）。本計畫真正在砍的就是這些 register，代價是平行度（cycle）。這也是為什麼 §7 備案 4「不動引擎、只砍 buffer」對 performance 反而可能最安全。
