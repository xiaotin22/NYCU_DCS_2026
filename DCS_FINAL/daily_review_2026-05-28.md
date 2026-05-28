# 🔧 CA.sv 每日設計日報｜2026-05-28

---

## 📐 目前架構摘要

CA.sv 已是完整實作，全檔約 1780 行，共包含 8 個模組：`CA`（頂層）、`CA_Control`（FSM 控制器）、`CA_DataPath`（資料路徑協調）、`Multiple_Processor`（矩陣乘法分派）、`Mult_2Stage_Parallel`（2-stage pipeline 乘法器）、`ACT_FiveStage_Parallel`（5-stage 激活函數）、`PoT_FiveStage_Parallel`（PoT 量化）、`Matrix_Max_3Stage_Parallel`（3-stage max-abs 搜尋）。

控制器採用 10 狀態 FSM：`S_IDLE` → FFN/Conv 走 `S_FAST_RUN`；Attention 走 `S_ATT_PARAM` → `S_ATT_READ` → `S_ATT_ISSUE_QKV` → `S_ATT_WAIT_QKV` → `S_ATT_ISSUE_SV` → `S_ATT_WAIT_SV` → `S_ATT_ISSUE_FINAL` → `S_ATT_WAIT_FINAL`。FFN/Conv 使用 BURST_128（一次讀 128 words）；Attention 以 BURST_4 分組讀入 4×1 矩陣行。整體 datapath pipeline 深度約 12 cycles（乘法 2 + ACT 5 + PoT 5）。

檔案末尾附有綜合後的 timing report，時脈週期 10 ns，critical path 終止於乘法器的 `prod_q` register（data arrival = 9.50 ns，slack = 0.00）。

---

## 📝 昨日改動

**無法取得昨日快照**（排程任務跨 session 執行，舊快照路徑位於不同 session 目錄，無法存取）。今日已將 CA.sv 備份至 `DCS_FINAL/ca_snapshot_prev.sv`，明日起可正常比對。本次視為**第一次有效執行**，跳過 diff 分析。

---

## ✅ 語法與設計規則檢查

**1. `att_param_phase_q` 未在 reset 中歸零（⚠️ 潛在問題）**
- 在 `CA_Control` 的 `always_ff` reset block 中，`att_param_phase_q` 未列入初始化。雖然 state 回到 `S_IDLE` 後只有在 `attention_start` 才會進入 `S_ATT_PARAM`，且在 `S_IDLE` → `S_ATT_PARAM` 時會被 `job_start` 設為 `1'b0`（line 312），但 reset 後直接接收 attention 操作的邊界情況可能導致 `att_param_phase_q` 為不定值。建議加入 reset。

**2. `selected_burst` 死代碼（⚠️ 面積浪費）**
- Line 461–462 定義並 assign 了 `selected_burst`，但全檔無任何地方使用此訊號。綜合工具會將其優化掉，但保留此死代碼不夠整潔，建議刪除。

**3. `wr_burst` 未在 reset block 初始化（⚠️ 非同步 reset 不完整）**
- `wr_burst` 在 else branch 有 `<= '0`（line 286），但 reset block 中未賦值。功能上因 `wr_en` reset 為 0 故不影響 RAM 操作，但波形中 reset 後 `wr_burst` 可能為 X，建議補上。

**4. `att_prefetch_pending_q` 永遠為 0：Prefetch 邏輯潛在 Bug（🔴 重大問題）**
- `att_prefetch_fire` 的條件（line 217）要求 `state_q == S_ATT_ISSUE_SV`。
- 然而將 `att_prefetch_pending_q <= 1'b1` 的賦值（line 397）位於 `S_ATT_WAIT_QKV` case 內的 `if (att_prefetch_fire)` 分支——此分支**永遠不會執行**（state 為 WAIT_QKV 時 att_prefetch_fire 必為 false）。
- 結果：`att_prefetch_pending_q` 始終為 0，guard `!att_prefetch_pending_q` 恆成立，導致在 `S_ATT_ISSUE_SV` 的每個 cycle（只要 rd_ready && att_group_base_q != 252）都會重複發送 prefetch read command，SHA 每組可發 4 次、MHA 每組可發 8 次重複命令。
- **修正建議**：將 `att_prefetch_pending_q <= 1'b1` 移至 `rd_en` 的 always_ff 中，當 `att_prefetch_fire` 為 true 時設為 1；或將 `att_prefetch_fire` 的 state 條件改為 `S_ATT_WAIT_QKV`。

**5. 禁用命名規則**
- 全檔未發現含 `error`、`latch`、`congratulation`、`fail` 的命名。✅

**6. Latch 檢查**
- 所有 `always_comb` 均有 default 賦值（issue/dispatch/act 等）。`always_ff` 使用完整 reset。未發現明顯 latch 來源。✅

**7. `out_valid` / `out_data` reset 歸零**
- `out_valid <= 1'b0`、`out_data <= 32'd0` 在 `CA_DataPath` reset block 均有設置。✅

---

## ⚡ 優化分析（面積 & 速度）

**Timing 極度緊繃（slack = 0.00）**
Critical path 在 `Mult_2Stage_Parallel` 的 Stage 1 乘加樹，9.50 ns 剛好等於 required time。任何微小的工具版本差異或 SI 效應都可能導致 timing violation。目前 10 ns 是 100 MHz 時脈；若能調整 Stage 2 的加法樹（目前為簡單連加）改用 balanced tree，可能讓 timing 更鬆弛，但需謹慎。

**FFN/Conv Pipeline 效率高**
`S_FAST_RUN` 對兩個 128-word burst 進行 pipeline 重疊：rd_cmd 可連發 2 次，write 跟在 compute 之後 8 cycles 的 pipe（`wr_pre_pipe_q`）。整體讀寫 pipeline 利用良好。

**Attention 的 Prefetch 機制（因 Bug 而失效）**
設計意圖是在 ISSUE_SV 期間預取下一個 group 的資料，但由於 `att_prefetch_pending_q` 永遠為 0，保護機制失效。修復後 prefetch 可節省每個 group 約 50 cycles 的讀取等待。

**MHA vs SHA 的 score/final issue 次數**
MHA 的 SV/FINAL phase 各需 8 次 issue（att_phase_cnt 到 7），SHA 各需 4 次（到 3）。對應正確，與規格一致。

**ACT 的 threshold 計算（可優化）**
目前 `calc_threshold_pair` 每個 stage 都重新計算（從原始 matrix），但 stage 1–4 都是從前一個 stage 的 matrix 計算——實際上 threshold 的計算應基於 **輸入** matrix（activation 前），目前做法是對已部分 activate 的 matrix 計算後續 chunk 的 threshold，這在跨 chunk 間的互動下可能造成與黃金模型的數值差異。需驗證 PATTERN 是否接受此行為。

---

## 🎯 今日建議改動

### 1. 🔴 修復 Prefetch Bug（正確性修正，Cycle↓）
將 `att_prefetch_pending_q <= 1'b1` 從 `S_ATT_WAIT_QKV` 移出，改在 `rd_en` always_ff 中判斷 `att_prefetch_fire` 來設置：
```systemverilog
// 在 rd_en always_ff 的 att_prefetch_fire 分支加入：
if (att_read_fire || att_prefetch_fire) begin
    rd_en    <= 1'b1;
    rd_burst <= BURST_4;
    if (att_prefetch_fire)
        att_prefetch_pending_q <= 1'b1;  // ← 加入此行
end
```
並將 `S_ATT_WAIT_QKV` 中的 dead-code `if (att_prefetch_fire)` block 移除。**預期效益**：每個 attention group 少發送 3–7 次多餘 read command，修復 prefetch 保護邏輯。

### 2. ⚠️ 補全 Reset（正確性修正）
在 `CA_Control` 的 reset block 補上：
```systemverilog
att_param_phase_q <= 1'b0;
wr_burst          <= '0;
```

### 3. ⚡ 刪除死代碼（面積↓，微小）
刪除 lines 461–462 的 `selected_burst` 宣告與 assign，減少綜合工具雜訊。

### 4. 🔬 上 VCS 驗證 ACT 數值正確性
透過 `ssh dcs_mimi` 執行 `./01_run_vcs_gate`，確認 RAT/CAT/BAT 的 threshold 計算在跨 chunk 時與 PATTERN 的黃金輸出一致。若有不符，需審視 `calc_threshold_pair` 在 Stage 1–3 是否應該始終從 **stage 0（原始輸入）** 的 matrix 計算閾值，而非從已部分激活的 matrix 計算。

---

*報告產生時間：2026-05-28 | 快照已儲存至 DCS_FINAL/ca_snapshot_prev.sv*
