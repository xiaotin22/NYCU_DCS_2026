# 🔧 CA.sv 每日設計日報｜2026-05-25

---

## 📐 目前架構摘要

CA.sv 目前已有相當完整的實作，並非空殼。整體採用 **5 狀態 FSM**（S_IDLE → S_RECV → S_STREAM → S_DRAIN → S_DONE）控制主流程，搭配深度為 **72 級的線性 Pipeline** 處理矩陣運算。RAM 存取使用 **Burst=7（一次 128 words）**，兩次 burst 即可覆蓋全部 256 筆矩陣。Pipeline 支援 FFN（8 級 MAC）、Conv（9 級 MAC）、SHA 與 MHA（包含 Q/K/V 投影、PoT 量化、Score 計算、Partial activation、Context 累加），以及所有 Activation（ReLU、RAT、CAT、BAT）與最終 PoT 量化，完整性高。

---

## 📝 昨日改動

此為排程任務首次成功讀取快照（前一份快照存放於不同 session 目錄，無法跨 session 存取）。**本次視為第一次執行，無 diff 可提供**。今日快照已儲存至當前 session 的 outputs 目錄，供未來比對使用。

---

## ✅ 語法與設計規則檢查

**✅ 無 Latch 風險**
所有 `always_comb` 區塊均在開頭設置預設值（`rd_en = 1'b0`、`wr_en = 1'b0`、`out_valid = 1'b0` 等），generate block 內各 stage 的 `always_comb` 也在迴圈頂端初始化 `mat_next`、`acc_next` 等，符合無 latch 要求。

**✅ FSM 有 default 分支**
`always_comb` 中的 case 包含 `default: ns = S_IDLE`，符合規定。

**⚠️ out_valid / out_data 為組合邏輯輸出**
規格要求「reset required」，目前兩者由 `always_comb` 驅動，**並非 FF 輸出**。雖然 reset 時 `wr_active_q=0` 使其自然為 0，但嚴格說來合成工具可能不認定其為「reset 歸零」訊號，且輸出無寄存器緩衝，timing 路徑較長。建議改為 registered output。

**✅ 禁用命名檢查**
全文掃描無任何 `error`、`latch`、`congratulation`、`fail` 字樣（含前後綴）。

**⚠️ param_cnt_q 寬度剛好夠用但有疑慮**
`param_cnt_q` 為 2-bit，最大值 3（SHA/MHA 需 3 組 param）。`param_cnt_q + 2'd1` 在值為 3 時若再加 1 會溢位回 0，但由於 `param_cnt_q >= param_need` 會先觸發跳 state，實際不會溢位。邏輯正確，但可考慮加 1 bit 防禦性設計。

**⚠️ rd_tile_q / wr_tile_q 寬度為 2-bit，最大用到值 2**
計數到 2 時條件 `< 2'd2` 即停，不會溢位。正確，但如果後續擴充需注意。

**✅ 無 sensitivity list 問題**
全部使用 `always_ff` / `always_comb`，符合 SystemVerilog 規範。

**⚠️ ACT threshold 計算位置：pipe_act_q[ps] vs final_src**
在 `ps == ACT_START`（stage 52）時，`act_thr_next[0]` 使用的是 `final_src`（已正確賦值為 `context_q[52]` 或 `pipe_acc_q[52]`）。但在 `ps > ACT_START && ps < ACT_APPLY` 時，使用的是 `pipe_act_q[ps]`（已經是前一級 FF 傳來的值）。由於 `act_next = final_src` 在 stage 52 寫入，且 FF 在 stage 52→53 之間觸發，`pipe_act_q[53]` 就是正確的最終矩陣值，後續 threshold 計算使用此值是正確的。✅

---

## ⚡ 優化分析（面積 & 速度）

**面積瓶頸：Pipeline 中大量的 s32_t 暫存陣列**

目前 generate 迴圈展開了 72 級，每級攜帶多組 8×8 的 s32_t（32-bit）矩陣：`pipe_acc_q`、`pipe_act_q`、`q_acc_q`、`k_acc_q`、`v_acc_q`、`q_mat_q`、`k_mat_q`、`v_mat_q`、`score_lo_q`、`score_hi_q`、`part_lo_q`、`part_hi_q`、`context_q` 等。每一組 8×8×32-bit = 2048 bits，超過 10 組乘以 73 個 stage 暫存器，總面積極為可觀（估計超過數十萬個 FF）。然而許多 stage 對這些矩陣只是透傳（pass-through），合成工具理論上可最佳化，但實際上仍會佔用相當資源。

**速度瓶頸：pot_shift 函數的優先編碼器（Priority Encoder）**

`pot_shift` 函數用 32 個 `if-else if` 實作 CLZ（Count Leading Zeros），展開後會形成一條長鏈形的組合邏輯，critical path 較長。建議改用 SystemVerilog 內建的 `$clog2` 或二分搜尋樹（tree-based priority encoder）實作。

**Burst 利用率**

目前 burst=7（128 words）充分利用了 RAM 的最大 burst 能力，每輪 RAM 只需 2 次讀取 + 2 次寫入，非常高效。✅

**Pipeline 氣泡（Stall）**

目前 pipeline 為純流水線，不支援背壓（back-pressure），當 `rd_valid` 不連續時，`pipe_valid_q` 會帶著 invalid bubble 流過，導致有效矩陣間有空泡。由於 read latency 固定為 50 cycles，且 burst 後資料會連續到來，實際氣泡主要在首次讀取等待期間，影響有限。

**FFN/Conv 執行效率**

對 FFN/Conv，pipeline 只需 9 個有效計算 stage（0~8），但整個 pipeline 深度仍為 72，後 63 個 stage 是空轉傳遞。這對 throughput 不影響（下一筆矩陣在 stage 1 進入時，前一筆矩陣在 stage 2 等等），但增加了每筆輸出的 latency（從輸入到輸出為 72 cycles + read latency）。

---

## 🎯 今日建議改動

### 1. 將 out_valid / out_data 改為 registered output（正確性修正 + Cycle↓）

**預期效益**：明確滿足「reset required」規格，避免合成工具誤判；同時縮短 combinatorial timing path（out_valid 目前從 wr_valid → 組合邏輯 → 輸出，registered 後可減少一層 timing pressure）。

```systemverilog
// 改為 FF 輸出：
logic out_valid_d, out_data_d [31:0];

always_comb begin
    out_valid_d = 1'b0;
    out_data_d  = 32'd0;
    if ((wr_active_q || wr_en) && wr_valid) begin
        out_valid_d = 1'b1;
        out_data_d  = out_row_q[wr_tile_q[0]][wr_count_q[6:0]];
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 1'b0;
        out_data  <= 32'd0;
    end else begin
        out_valid <= out_valid_d;
        out_data  <= out_data_d;
    end
end
```

### 2. 用樹狀結構取代 pot_shift 的鏈形 if-else（速度↑ / Cycle↓）

**預期效益**：CLZ 用 32 個 if-else 深度約為 O(32)，改為 5 層二元樹則深度降為 O(5)，大幅縮短 critical path，有助於提高最大工作頻率（cycle_time↓）。

```systemverilog
function automatic logic [4:0] pot_shift(input s32_t max_abs);
    logic [4:0] sh;
    logic [31:0] v;
    v = max_abs[31] ? ~max_abs : max_abs; // handle negative (shouldn't occur)
    sh = 0;
    if (v[31:16] != 0) begin sh = sh | 5'd16; v = v >> 16; end
    if (v[15:8]  != 0) begin sh = sh | 5'd8;  v = v >> 8;  end
    if (v[7:4]   != 0) begin sh = sh | 5'd4;  v = v >> 4;  end
    if (v[3:2]   != 0) begin sh = sh | 5'd2;  v = v >> 2;  end
    if (v[1]     != 0) begin sh = sh | 5'd1;              end
    // shift = bit_length(max_abs) - 1 - LOG2_OUT_MAX = sh - 2
    pot_shift = (sh > 5'd2) ? (sh - 5'd2) : 5'd0;
endfunction
```

### 3. 減少 Pipeline 中不必要的矩陣複製（面積↓）

**預期效益**：許多 stage 對 `q_acc_q`、`k_acc_q`、`v_acc_q` 等矩陣只做透傳（在超出計算範圍的 stage 中，`xxx_next = xxx_q[ps]`），這些 FF 可以透過合理的 stage 合併或只在「活躍計算範圍」分配 FF 來減少。考慮將 Q/K/V projection 結果在量化後只攜帶 4-bit 的 `q_mat`、`k_mat`、`v_mat`，丟棄 32-bit 的 `q_acc`、`k_acc`、`v_acc`（量化後就不再需要這三個 32-bit 陣列）。

### 4. 驗證 S_DONE → S_STREAM 重啟路徑的正確性（正確性修正）

**預期效益**：目前 `job_start` 在 `cs == S_DONE` 且 `mem_set && in_valid` 時觸發，並重置 `rd_tile_q`、`wr_tile_q`、`in_seen_q`、`out_seen_q` 等計數器。但在 always_comb 中 `rd_active_d` 的重置條件是 `job_start || (cs == S_IDLE) || (cs == S_RECV)`，**S_DONE 狀態下 job_start=1 可觸發重置**，邏輯正確。建議加入 assertion 或在 simulation 環境中手動驗證多輪 op set 的場景，確保連續兩個 op set 之間不會有計數器殘留。

---

*報告產生時間：2026-05-25 | 自動排程任務執行*
