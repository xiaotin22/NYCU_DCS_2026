# DCS 2026 Final Project Report — Conformer Accelerator (CA)

**Name**：楊庭瑞　**Student ID**：113511266　**Server Account**：dcs151

---

## Architecture (2 pts)

> 此處放 block diagram，建議格式：左側 PATTERN/RAM 介面，中間 Control + DataPath，右側三個 compute submodule。

**頂層階層（4 層）**：

```
CA  (Top)
├── CA_Control            FSM、RAM read/write 命令、prefetch 排程
└── CA_DataPath           Sideband pipeline、中間儲存、submodule 串接
    ├── Multiple_Processor       Issue 控制 + nibble accumulator
    │   └── Mult_5Stage_Parallel    64 lanes × 9-tap s5×s4 MAC
    ├── ACT_5Stage_Parallel      ReLU / RAT / CAT / BAT
    └── PoT_5Stage_Parallel      量化
        └── Matrix_Max_3Stage     64-input OR + priority encode
```

**資料流概觀**：RAM → `x_mem` → `Mult` → (`score_mem` | `ACT`) → `PoT` → `q/k/v_mem` / `wr_data` / `out_data`。所有跨模組同步皆走 `mult_tag_t`（NORM/Q/K/V/SCORE/FINAL）+ `idx` sideband，使 control 完全與 datapath 內部解耦。

**Pipeline 總深度 = 18 級**（DP issue buf 1 + Mult input buf 1 + Mult stage 4 + MP 輸出 1 + ACT input buf 1 + ACT stage 4 + PoT input buf 1 + Matrix_Max 3 + PoT 輸出 1 + DP 輸出 1）。

---

## Design Methodology (8 pts)

### 1. Data Flow（CA_Control ↔ CA_DataPath 互動 + DataPath 內部模組互動）

**頂層拆兩 sibling module**：`CA_Control` 完全看不到 datapath 內部寬資料，`CA_DataPath` 完全不碰 RAM 介面，兩者只透過下列極窄的 sideband 溝通：

| 方向 | 訊號 | 意義 |
|---|---|---|
| C → D | `issue_valid`, `issue_mode`∈{NONE,NORM,QKV,SV,FINAL}, `issue_idx[4:0]` | 「這一拍對 Mult 發一筆什麼運算」 |
| C → D | `capture_valid`, `capture_idx[1:0]` | 「把這拍從 RAM 收到的 256-bit 收進 `x_mem[capture_idx]`」 |
| C → D | `op[1:0]`, `act[1:0]`, `param`, `weight_k`, `weight_v` | 整個 job 內常數，僅在 S_IDLE / S_HA_PARAM 改寫 |
| D → C | `qkv_ready` | 4 組 Q+K+V 全部 PoT 完了，可進 SV |
| D → C | `sv_ready` | SHA 4 / MHA 8 個 SCORE 全到位，可進 FINAL |
| D → C | `result_valid` | PoT 出了一個 NORM 或 FINAL 結果（用來計 `out_cnt_cs`） |

**Control 端職責**：6-state FSM (`S_IDLE / S_FAST_RUN / S_HA_PARAM / S_HA_READ / S_HA_ISSUE / S_HA_WAIT`) 加 attention 子階段 `ha_stage_cs` (`ST_QKV → ST_SV → ST_FINAL`)。三個 ha_stage 共用 ISSUE+WAIT 骨架，差別只在 `ha_phase_last` (QKV=11、SV=3/7、FINAL=11/23)。**Control 對 datapath pipeline 深度完全不知情**，只看 `qkv_ready / sv_ready` 切換 stage，看 `result_valid` 算 out_cnt，這層抽象讓 datapath 內部隨時可調 pipeline 深度而不破壞 FSM。

**DataPath 端職責**：用 `issue_idx` 解碼出該餵 Mult 的 (A_s5, B, b_transpose, tag) 並 issue 進 Mult；同時維護所有跨 issue 中間 buffer (`x/q/k/v_mem`, `score_mem`)；用 sideband pipeline 把 `mult_tag_t` 一路 delay 到 PoT 出口，決定寫進哪個 buffer。

**DataPath 內三個 compute submodule 的互動**完全用 `mult_tag_t` 做分流，每個 submodule 出口都帶 `tag_out + idx_out`：

```
                 ┌── MT_NORM ──→ ACT ──→ PoT ──→ wr_data / out_data
                 │
                 ├── MT_Q/K/V ──────────→ PoT ──→ q/k/v_mem  (跳過 ACT)
                 │
   Mult ─────────┼── MT_SCORE ────────────────→ score_mem   (跳過 ACT + 跳過 PoT)
                 │                          ↑ pack_attention_score (comb)
                 │
                 ├── MT_FINAL (SHA) ──→ ACT ──→ PoT ──→ wr_data
                 │
                 ├── MT_FINAL (MHA head0) ────→ q_mem + k_mem[255:32]  (借住)
                 │
                 └── MT_FINAL (MHA head1) ──→ combine_mha_heads ──→ ACT ──→ PoT
                                                     ↑ 與 head0 partial 合
```

- 入口端：`issue_valid_cs` / `rd_data_cs` 都先打一拍把上游 mux 切掉
- 中段：`act_tag_cs[0:4]`、`pot_tag_cs[0:4]` 兩條 sideband 跟著資料一起 delay 5 拍對齊 ACT / PoT 內部 stage
- 出口端：PoT 出來時用 `pot_tag_cs[4]` case-by-case 寫 `q_mem` / `k_mem` / `v_mem`，並 set 對應 `q/k/v_ready_cs[idx]`；NORM/FINAL 走 output buffer 變 `wr_data` 與 `out_data`

**Ready 訊號回報**：`qkv_ready = &q_ready_ns & &k_ready_ns & &v_ready_ns`、`sv_ready = (op==MHA) ? &score_ready_ns : &score_ready_ns[3:0]`，在 ready_ns 而非 ready_cs 看，省一拍 ready 通知延遲。

### 2. Execution Cycle Optimization（Prefetch 機制與排程）

**問題**：RAM read latency = 50 cycle。Attention 每組 4 筆 input 用 BURST_4 一次讀完，若每組都從頭等 50 cycle，64 組 × 50 = 3200 cycle 純等待，幾乎跟整個計算時間一樣長。

**核心機制：一組超前 prefetch + Capture 完全與 FSM 解耦**。三條訊號協同：

```verilog
ha_prefetch_fire  =  (state==S_HA_ISSUE || state==S_HA_WAIT)
                  && (ha_stage_cs == ST_QKV)        // ← 當前組正在算 QKV
                  && !ha_prefetch_pending_cs
                  && !ha_pf_done_cs
                  && ha_has_next_group              // group_base != 252
                  && rd_ready;

ha_pf_capture     =  ha_prefetch_pending_cs        // ← 任何 state 都抓
                  && !ha_pf_done_cs
                  && rd_valid;
```

**為什麼能在 ST_QKV 就發 prefetch**：`x_mem` 的唯一 reader 是 QKV stage 的 Mult(IM_QKV) 12 issue。一旦這 12 個 issue 發完，`x_mem` 立刻死亡（SV / FINAL 都不再讀），下一組 RAM 回來的 4-word 就算覆蓋 `x_mem` 也不會撞到當前組。50-cycle latency 在這段時間早已過完，**capture 可以發生在 SV 中、FINAL 中、甚至下一組 QKV 還沒發前**。

**`ha_pf_capture` 不綁 state 是關鍵**：原本 capture 只在 `S_HA_READ` 啟動，prefetch 一發出 FSM 已進 ISSUE/WAIT 反而抓不到 `rd_valid`。改成「任何 state 下，只要 `ha_prefetch_pending_cs && rd_valid` 就抓」，並用 `ha_pf_done_cs` flag 通知 `S_HA_READ` 可直接 bypass 到 `S_HA_ISSUE`。

**寫回 + 切下一組 + Prefetch 完全並行**：用單一 `ha_wr_cnt_cs` timer，從 FINAL 啟動瞬間開始計：

| 事件 | Counter 觸發值 | 動作 |
|---|---|---|
| `ha_next_group_fire` | SHA=15, MHA=27 | `ha_group_base_cs += 4`，rd_req_cnt 重置，state 跳 ISSUE (若 pf_done) 或 READ |
| `ha_wr_fire` | SHA=19, MHA=31 | 對 RAM 拉 `wr_en` + BURST_4，地址用 `ha_write_base_cs`（FINAL 啟動瞬間鎖住的舊位址） |

「下一組計算（用新 `ha_group_base_cs`）」與「當組寫回（用舊 `ha_write_base_cs`）」**完全平行不衝突**，因為 wr_burst 走 negedge RAM、issue 走 datapath，物理通道不同。

**排程結果（latency 結算）**：

| Mode | Cycles | 公式拆解 |
|---|---|---|
| FAST_RUN (FFN/Conv) | **375** | 68（啟動到第 1 個 out） + 127（batch1 剩餘） + 53（gap） + 127（batch2） |
| SHA | **3,645** | 113（group1 第 1 out） + 3（group1 剩 3 out） + 57（group2，prefetch 對齊代價 +1） + 56×62（group3..64，每組 53 拍 ISSUE+WAIT+drain + 3 拍 4-out 串流） |
| MHA | **4,290** | 129（group1 第 1 out） + 3（group1 剩 3 out） + 66×63（每組 = QKV12 + SV8 + FINAL24 + drain ≈ 63 + 3 拍 4-out） |

第一組的啟動成本（113 / 129）是無法省的；第二組起每組只剩**純計算**成本，50-cycle RAM read **完全藏掉**。

**其他 cycle 級優化**：
- **FAST_RUN BURST_128 雙批串流**：兩個 BURST_128 蓋掉整顆 RAM，pipeline 滿載時 throughput = 1 out/cycle。
- **SCORE 跳過 ACT pipeline**：把 attention act `x<0 → x>>2` 與 16→11 bit truncate 一起內嵌進 combinational `pack_attention_score`，`mult → score_mem` 直走，每筆 SCORE 省 5 cycle (ACT 5-stage)。
- **Interleaved FINAL counter** (`fin_mat`內 → `fin_nibble`中 → `fin_head`外)：phase 2 (high nibble) 那輪 4 個 matrix 結果在連續 4 cycle 出，與 BURST_4 寫回拍數對齊，wr_data 不留 bubble。

### 3. Cycle Time Optimization（資料 pipeline 切法）

**設計原則**：每一級 pipeline 把「最寬的 MUX / 最深的加法樹 / 最遠 fanout」其中一條切到 register 邊界，下一級看到的 cone 就乾淨。

**Mult_5Stage_Parallel — 5 級切法**：

| Stage | 暫存內容 | 切這級的理由 |
|---|---|---|
| 0 input buf | `in_data_A_cs[319:0]` (s5 packed)、`in_data_B_cs[255:0]`、`b_transpose_cs` | 切掉上游 4-mode issue MUX（IM_NORM / QKV / SV / FINAL 的 A/B 來源） |
| 1 operand | `operand_a_cs[64][9]` s5、`operand_b_cs[64][9]` s4 | **核心切法**：把 `sel_a` / `sel_b` 兩個 op-dependent function（含 Conv padding、b_transpose、bias slot）的 cone 全部結束在這級。下一級 prod_next **看不到 op[1:0]**，乘法器 input cone 變純資料 |
| 2 product | `prod_cs[64][9]` s8 | 純 `s5 × s4`，~120ps |
| 3 partial | `partial_cs[64][2]` s12 | 9-tap 拆 5+4 兩個 partial，加法樹深度從 log2(9)=4 變 log2(5)=3 |
| 4 sum | `sum_cs[64]` s16 | 兩個 partial 加合，1 級 |

關鍵：把 `op[1:0]` 從乘法器 input cone 移走是 Mult 從 4-stage 改 5-stage 的根本目的，乘法器面積也因此可以縮到純 s5×s4。

**ACT_5Stage_Parallel — 1 input buf + 4 stages**：

| Stage | 暫存內容 | 切這級的理由 |
|---|---|---|
| Input buf | `in_data_buf[1023:0]`、`act_buf`、`act_chunk_buf[0:3]`（`dont_touch` 複製降 fanout）、`mode_buf` | 切掉上游 dispatch mux (mult / mha_combine / SCORE 早走) |
| 0 pair sum | `pair_a_cs[c][p]` = e0+e1、`pair_b_cs[c][p]` = e2+e3，s17 | 原本 4-element 加法樹 (act-MUX + 2 級加) 切成 (act-MUX + 1 級加)，加法樹深度切半 |
| 1 psum | `psum_cs[c][p]` = pair_a + pair_b，s18 | 純 1 級加合，沒 act-MUX |
| 2 threshold | `thr_a/b_cs[c]` s16 | RAT/CAT 走 `>>>3`、BAT 走 `(part01+part23)>>>4`，用 part_sum01/23 中繼 |
| 3 apply | `matrix_cs[3]` 1024-bit | **Element-centric**：每個 pos 用**常數**read/write 位址查 `matrix_cs[2]`，再用 `thr_for_position` 做 3-way MUX。避開原 (chunk, lane)→pos 的 cross-bar，cone 深度顯著下降 |

**PoT + Matrix_Max — 5 級**：

| Stage | 暫存內容 | 切這級的理由 |
|---|---|---|
| PoT input buf | `in_data_cs`、`abs_cs[1023:0]` | **abs 抽到 input edge**：64 lanes abs (~15-gate carry chain) 從 Matrix_Max 內部移到 PoT input 前一拍 comb 算好，切短 `in_data_cs → abs → max4 → max16_cs` |
| Matrix_Max st1 | `or_cs[15:0]` | 64-input bitwise OR（取代 max-tree；max_abs 的 MSB 位置 = OR 結果的 MSB），6-level OR tree ≈ 0.6 ns |
| Matrix_Max st2 | `shift_cs[3:0]` | `pot_shift` 16-bit casez → 4-bit shift 量 |
| Matrix_Max st3 | `out_shift[3:0]` | 純 fanout register，給 PoT 64 lanes |
| PoT output | `out_data[255:0]` | `quant_all` 64 lane 平行 arithmetic shift + clamp_s4 |

介面從 16-bit max 改成 **4-bit shift**，下游 quant MUX 變窄、又省 12 flops（shift register × 3 級）。

**Multiple_Processor 輸出 register（+1 cycle 換 cycle time）**：FINAL 階段 `nibb_final_data = lane_shift_add(nibb_acc, mult_raw_data, 8)` 是 64 lane × 16-bit 的 shift-add，cone 很深；下游 DataPath 還要接 ACT 入口 mux + PoT 入口 abs，全部串在一拍會炸。加一級 output reg (`mult_data` / `mult_tag_out` / `mult_idx_out`) 把這 1.3 ns 的 cone 切成兩半，付出 1 cycle latency。

**ACT `act_chunk_buf[0:3]` 用 `dont_touch` 強制保 4 份複製**：避免 synthesis 把這 4 個等值 register 合併成單一高 fanout driver，cycle time 改善 ~0.1 ns。

### 4. Area Optimization（Multiplier 共用 + Nibble prod）

**核心策略**：FFN / Conv / SHA / MHA-SCORE / SHA-FINAL / MHA-FINAL **六種運算共用同一個 Mult_5Stage_Parallel**（576 = 64 × 9 個 s5×s4 multiplier），不重複例化任何 MAC array。

**達成方法：`sel_a` / `sel_b` 兩個函式統一座標**。每個 multiplier 對應 (row, lane, tap) 三元組，下表是 sel_a / sel_b 怎麼把 6 種 mode 的操作數對映到同一個 multiplier：

```verilog
sel_a(mat_A, op, row, lane, tap):
  op==Conv  : get_pad_s5(mat_A, row + tap/3 - 1, col + tap%3 - 1)  // 3×3 + zero-pad
  tap==8    : 5'sd0                                                // bias slot
  其他      : get_s5(mat_A, row*8 + tap)                           // 平坦 row 讀 (FFN/SHA/MHA/FINAL)

sel_b(mat_B, op, b_transpose, lane, tap):
  op==Conv      : get_s4(mat_B, tap)                               // kernel 全 lane 共用
  tap==8        : 4'sd0
  b_transpose=1 : get_s4(mat_B, lane*8 + tap)                      // SV Q×K^T
  其他          : get_s4(mat_B, tap*8 + lane)                      // FFN 一般 GEMM
```

兩個 function 都在 **Stage 1 (operand register) 之前** evaluate，op[1:0] 與 b_transpose 的 cone 結束在 register 邊界，**完全不進乘法器 input cone**。乘法器永遠看到的是純 `s5 × s4`，這個資料寬度的乘法器面積極小。

**bit-width 緊縮（s5×s4→s8 的範圍分析）**：
- A 是 5-bit signed = [−16, 15]；其中 op==Conv 時 `a_unsigned=0` 走 sign-extend；其他 mode 上游 `sign_extend_s4_vec` 把 4-bit signed → 5-bit signed，範圍 [−8, 7]
- B 是 4-bit signed = [−8, 7]
- Product 範圍 = max(|−16×−8|, |15×−8|) = max(128, 120)；實際上 A∈[−8,15]（Conv padding 後最大 15），所以 product ∈ [−120, 105]，落在 s8 [−128, 127]

| 暫存器寬度緊縮 | 寬度 | 數量 | 省下 |
|---|---|---|---|
| `prod_cs` | s8（原 s16） | 576 | **4,608 flops** |
| `operand_a_cs` | s5（原 s8） | 576 | 1,728 flops |
| `operand_b_cs` | s4（原 s8） | 576 | 2,304 flops |
| `partial_cs` | s12（原 s16） | 128 | 512 flops |

乘法器陣列本身從 s16×s16 → s5×s4，面積約 **4× 縮小**，是整體 area 的主貢獻。

**Nibble prod：用同一個 s5×s4 multiplier 算 11-bit × 4-bit**

FINAL 階段是 `output = score × V`，其中 score 是 11-bit signed（SCORE 那級已 packed 進 `score_mem`）、V 是 4-bit signed。若直接 s11 × s4 → 需要更寬的乘法器，等於放棄 multiplier 共用。

**解法**：把 11-bit score 拆三段 nibble，每段 4-bit 餵進**同一個 s5×s4 multiplier**：

```
score(11-bit signed) = ls[10:8] · 256  +  ls[7:4] · 16  +  ls[3:0]
                       ─signed 3-bit─    ─unsigned 4-bit─  ─unsigned 4-bit─
                          phase 2            phase 1           phase 0

extract_score_nibble_s5(src, phase):
  phase 0: {1'b0, ls[3:0]}            ← unsigned，餵 A_s5 的低 5-bit
  phase 1: {1'b0, ls[7:4]}            ← unsigned，餵 A_s5 的低 5-bit
  phase 2: {{2{ls[10]}}, ls[10:8]}    ← sign-extend 3-bit 到 s5
```

每個 phase 都產生一筆 `s5 × s4 → s8` 的 partial product，由 `lane_shift_add` 做 per-lane shift-accumulate（避免整個 1024-bit 加會跨 lane carry）：

```verilog
nibb_acc[mat] <= 0                                              // phase 0：覆蓋
nibb_acc[mat] <= lane_shift_add(nibb_acc[mat], prod, 4)         // phase 1：+ prod<<4
nibb_final    =  lane_shift_add(nibb_acc[mat], prod, 8)  (comb) // phase 2：comb 完成
```

**為什麼這比直接 s11×s4 划算**：
1. **Multiplier 數量不變**：仍是 576 個 s5×s4，沒多拉一組獨立的 11-bit multiplier
2. **Accumulator 只 4 × 1024 = 4,096 flops**（4 個 matrix 各一個累加器），遠少於另開一組 64 lane × s16 multiplier 的代價
3. **Phase 2 走 comb**（`nibb_final_data` assign），不額外加 register；MP 輸出 reg 同時切了下游 cone
4. **與 interleaved counter 完美配合**：4 個 matrix 在每個 nibble phase 連續發 4 issue，phase 2 那輪的 4 個 `nibb_final` 自然在連續 4 cycle 出，BURST_4 寫回零 bubble

代價只有 nibble 拆解多花 2 個 issue cycle 每 matrix（phase 1, 2），SHA = 12 issue/group、MHA = 24 issue/group，但這部分被 prefetch + 寫回重疊吸收。

**其他 area 措施**：

| 措施 | 省下 |
|---|---|
| MHA head0 partial 借住 `q_mem` + `k_mem[255:32]`（SV 後 Q/K 已死） | **1,920 flops** |
| `score_mem` 用 11-bit × 64（非 16-bit）× 8 slot | ~2,560 flops |
| Matrix_Max 對外從 16-bit max → 4-bit shift（下游 quant MUX 變窄） | 24 flops |
| `rd_data_cs` 共享 capture (寫 x_mem) 與 IM_NORM (送 MP)（互斥） | 256-bit register |
| PoT 不用 in_valid gate D path（讓 synthesis 自由優化） | 切短 enable-mux cone |

**總 flop 估算 ≈ 40.5K**（Mult 13K + DataPath state 10K + ACT 6K + PoT 5.4K + MP 5.2K + Control 0.9K）。

---

## Discussion (3 pts)

1. **Nibble accumulator 跨 lane carry**：FINAL 階段 SCORE 是 11-bit，需要拆 3 個 nibble 累加（×1, ×16, ×256）。一開始用整個 1024-bit 一次加，結果某個 lane 溢位 carry 進相鄰 lane 造成 off-by-one。改用 `lane_shift_add` 函式對每個 16-bit slot **獨立** 做 `acc + (prod <<< sh)` 並 truncate 才修好。
2. **MHA head0 / head1 timing 對齊**：head0 是 FINAL 前半部、head1 是後半部，但 `combine_mha_heads` 需要兩者同 row 同時到齊。最後選擇把 head0 包成 480-bit packed 借住 `q_mem/k_mem`，再用 interleaved counter 把同 matrix 的 head0/head1 鎖在同 nibble 階段下，配合 wr_burst=4 寫回。
3. **Prefetch capture 與 FSM 解耦**：原本 capture 只在 `S_HA_READ` 啟動，導致 prefetch 一發出後 FSM 已進 ISSUE/WAIT 反而抓不到 `rd_valid`。把 `ha_pf_capture` 改成「不管 state，只要 `ha_prefetch_pending_cs && rd_valid` 就抓」，並用 `ha_pf_done_cs` flag 通知下一組可直接跳 ISSUE。
4. **BURST_4 寫回時序**：interleaved FINAL counter 必須恰好讓 4 個 matrix 在連續 4 cycle 出 PoT 結果，且 `wr_data` 出現在 `wr_en` 之後 `WRITE_LATENCY` 拍。靠單一 `ha_wr_cnt_cs` timer 與 `ha_write_base_cs` 鎖位址，才把「下一組計算啟動」與「當組寫回」完全並行不衝突。
5. **Critical path 反覆遷移**：每修一次合成後 critical path 都跳到新位置（先 max-tree → 改 OR-reduce、再 abs in PoT → 抽到 input、再 FINAL MUX → 加 MP 輸出 reg）。等於每一輪 timing 收斂都要重新讀 reports，逐 stage 把長路砍碎。

---

## Reflection (2 pts)

本次 Final 整個過程最大的體會是：**performance = cycle × cycle_time × area** 三者根本是互相牽動的，不能只盯一個。最初為了減 cycle 把所有 logic 全壓在 combinational，cycle time 直接爆 4 ns；改成 18 級 pipeline 之後 cycle time 下來了但起步成本暴漲，又得回頭想 prefetch 和 BURST 怎麼把這 18 級藏掉。每一輪修改幾乎都在「省 4 cycle vs 多 2K flops」、「砍 0.3 ns cycle time vs +1 cycle latency」之間做取捨。

很受用的另一件事是「sideband tag」這個 pattern：透過 `mult_tag_t` 把 Mult / ACT / PoT 分隔成獨立 producer-consumer，control 完全不必知道內部 pipeline 多深，只看 `result_valid` 就好。這讓我可以隨時調整 pipeline 深度而不破壞 FSM。

如果再做一次，我會更早把 attention 的三個 stage（QKV / SV / FINAL）的 issue/wait skeleton 抽成統一介面，而不是先寫各自的 FSM 再合併——後者讓我 debug 了快兩週的 corner case。

整體來說這份作業把 RTL design / synthesis / timing closure / area budget 串成完整流程，是這學期最有收穫的一份作業。

---

## AI-use Log（不計頁數）

1. **AI Chat 連結**：（請貼上 Claude Code 對話分享連結）
2. **Key Prompts**（3–5 張截圖）：
   - 「分析一下目前 FINAL CA.sv 的程式架構」
   - 「幫我時序分析一下目前 resource 的使用情況以及 latency cycle 總數」
   - 「Multiple_Processor / Mult_5Stage 的 pipeline 應該怎麼切才能把 op-MUX 從 multiplier input cone 移出去」
   - 「MHA head0 partial 怎麼借 q_mem / k_mem 才不會跟下一組 QKV 衝到」
   - 「Matrix_Max 改用 OR-reduction 代替 max-tree 的正確性怎麼證明」
