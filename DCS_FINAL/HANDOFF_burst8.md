# Burst-8 Port — Session Handoff

## 目標脈絡
- Performance = `execution_cycles × cycle_time × area`。現在 baseline（main, commit `6ac9121`）= **48570 × 3.0ns × 5,367,592 = 7.82E11**。
- 同學達到 **3.3E11**（~2.4× better），靠「一次收更多 word」。使用者要往那 level 走，**一步一步、有進步就 commit**（不用追求一次到位）。
- 本任務：把 **burst-8（attention group-of-4 → group-of-8）** 套到現在的 s4 baseline。
  - 原理：group 變大 → group 數 64→32 → **stage 間 bubble 減半** → cycle ↓（舊實驗 48570→43366, −10.7%）。
  - 舊 burst-8（branch `Brust-8-fast-ha`, commit `417c985`/`d475615`）卡在 timing 3.8ns（沒有 s4/pipeline 優化）→ 8.33E11（比 baseline 差）。現在 baseline 的好 pipeline 應能讓它在 3.0 MET。
- **務實期待**：burst-8 就算成功，樂觀也只 ~6.5–7.0E11，**不是 3.3E11**（burst 邊際遞減：cycle 省 `4864/N`、area 漲 `∝N`；burst-16 反而更差，別做）。是往 3.3E11 的一步。

## 現在狀態（branch `burst8-on-s4`，3 個 WIP commit）
- **結構 port 完成、可 compile、`PATTERN 0 / OP SET 0`（256 data）全 PASS**。
- **BUG：`OP SET 1` timeout（10000 cycle 無 output），且零 output 就卡死。**
- main 仍乾淨（7.82E11 可交付）。

## ⚠️ 要 debug 的 BUG（首要）
`OP SET 1` attention flow 起不來、完全不出 output → 卡在第一個 FINAL output 之前。

**先做的判斷**：確認 `OP SET 0` 是 FFN 還是 attention（PATTERN.sv 被保護不能讀，但可從行為推）：
- 若 OP SET 0 = attention 且全過 → group-8 attention 邏輯**正確**，bug 在 **op-set 邊界 transition**（某 state 沒清：`q/k/v_ready_cs`、`score_ready_cs`、`ha_prefetch_pending_cs`、`ha_pf_done_cs` 在進第二 op set 時殘留 → qkv_ready/sv_ready 永遠不 fire 或 prefetch 卡死）。
- 若 OP SET 0 = FFN → OP SET 1 是第一個 attention，bug 在 **attention 本身**（某 matrix 0..7 的 Q/K/V 或 score ready 永遠不 set → `qkv_ready`/`sv_ready` 不 fire → FSM 卡在 S_HA_WAIT，FINAL 不跑）。

**重點檢查清單**：
1. `qkv_ready = &q_ready[7:0] && &k_ready[7:0] && &v_ready[7:0]`（line ~867）—— 8 個 matrix 是否都 set？查 IM_QKV idx 0..23 → matrix 0..7 映射、`pot_idx_cs[4][2:0]` 寫 q/k/v_ready。
2. `sv_ready`（line ~868）—— MHA `&score_ready_ns[15:0]`、SHA `[7:0]`。score 16 entry 是否都寫到？
3. op-set 邊界：S_IDLE→S_HA_PARAM→S_HA_READ 時 ready/pf flags 有沒有清。看 S_HA_PARAM 的 reset（line ~455-470）。
4. FSM taps（我**推導**的，OP SET 0 過代表大致對，但 op-set 第一組可能不同）：`HA_RESTART_SHA=23/MHA=47`、`HA_WR_SHA=27/MHA=51`（line 169-172）。first-final phase SHA=16/MHA=40，offset +7（restart）/+11（wr）。
5. 用 `nWave`/`$display` 看 OP SET 1 卡在哪個 ha_stage_cs（QKV/SV/FINAL），就知道哪個 ready 沒 fire。

## 已完成的改動（group-4 → group-8，全在 `burst8-on-s4`）
**Control**：BURST_4→BURST_8；counter 寬度 ha_rd_word[2:0]/ha_phase_cnt[5:0]/ha_wr_cnt[5:0]/ha_pf_word[2:0]/ha_phase_last[5:0]；`ha_has_next_group` 252→248；`ha_next_group_base +4→+8`；`ha_phase_last` QKV23/SV15/7/FINAL47/23；HA_RESTART 23/47、HA_WR 27/51；prefetch/read 計數 `==3→==7`；3 個 rd_burst + wr_burst → BURST_8。

**DataPath**：x/q/k/v_mem`[0:7]`；**score_mem`[0:15]`（4-bit idx，沒走 head-split）**；ready `[7:0]`/score_ready`[15:0]`；所有 idx 3→4 bit（mult_idx_out/act_in_idx/pot_in_idx/mha_comb_idx/act_idx_cs/pot_idx_cs）；mha_comb `mult_idx_out[3]`(head)/`[2:0]`(matrix)；q/k/v/score/mha-borrow write idx `[2:0]`；`q/k/v_ready_ns[pot_idx_cs[4][2:0]]`；ready clear `issue_idx_cs==6'd0`。

**Multiple_Processor**：port issue_idx`[5:0]`/buffers`[0:7]`/score_mem`[0:15]`/mult_idx_out`[3:0]`；mult_issue_idx`[3:0]`/mult_idx_cs`[3:0]`；**IM_QKV 8 cases**（idx 0-23→matrix 0-7, Q/K/V by %3）；IM_SV `issue_idx[3]`(head)/`[2:0]`(matrix)；IM_FINAL `score_mem[{fin_head,fin_mat}]`/`v_mem[fin_mat]`；`fin_mat_cs[2:0]`/interleave`==7`；**nibb_acc`[0:7]`（8 banks）**；**one-hot WE`[7:0]`**（`nibb_we_p0/p1_in[mult_issue_idx[2:0]]`）；**fin_sel_cs`[2:0]`**（保 4 copies, `mult_idx_cs[..][2:0]`, `i/16` grouping 不變）。

## 與舊 burst-8 delta 的關鍵分歧（為何不能照抄）
現在 main 已演化，跟 `417c985` base（f04e784）不同：
| 項目 | 舊 base | 現 main（已採用）|
|---|---|---|
| SCORE 路徑 | 走 ACT | **bypass ACT**（mult→score_mem 直寫, `pack_attention_score`）|
| MHA head0 scratch | 專用 `mha_out0_mem` | **借用 q/k_mem**（`mult_idx_out[2:0]`, gate `!mult_idx_out[3]`）|
| score 格式 | unsigned 11-bit | **signed-digit 12-bit**（`extract_score_nibble_s4`）|
| score_mem 結構 | head-split h0/h1 | **單一 `[0:15]` 4-bit idx**（我選的，較機械化；若 timing 卡 score 寫 fanout 再改 head-split）|
| FSM next-group | out_cnt | **HA_RESTART/HA_WR counter** |

## 剩餘小事（cosmetic，不影響功能，lint warning only）
Control 內幾個 reset 仍是窄 literal 配寬 reg（`5'd0`→`6'd0`、`2'd0`→`3'd0`，~line 357/363/364/367/462/464/467/482/490/534/535）。0=0 無害，可順手清。

## 完成後流程
1. RTL 過（Congratulations + 看 cycle 數，預期 ~43000）。
2. synth：`syn.tcl` line 11 可改 CYCLE（**只能改這行**）。跑 `02_SYN/01_run_dc`，看 slack MET + area。
3. 算乘積 vs 7.82E11。**優於就 merge 回 main commit**（使用者授權自動 commit，不用問）。
4. 若 area 爆掉（burst-8 buffer ×2 ~ +0.6–0.9M）導致乘積變差 → 老實報告、可能要 head-split score_mem 省 fanout，或放棄 burst-8 留 baseline。

## 工作站測試
```
ssh dcs_mimi → 餵 yes 過登入關卡（CAD env 只在 yes 後載入）
scp 本地 CA.sv → dcs_mimi:Final/01_RTL/CA.sv
01_RTL: ./01_run_vcs_rtl    # RTL（~1分，看 Congratulations / Timeout）
02_SYN: ./01_run_dc          # synth（~17分，看 slack / Total cell area）
```
tcsh 非互動不能用 `2>&1`；長任務前 `rm -f syn.log`。
