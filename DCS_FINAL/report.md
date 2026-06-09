# DCS 2026 Final Project Report：Conformer Accelerator (CA)

**Name**：楊庭瑞　**Student ID**：113511266　**Server Account**：dcs151

---

## 架構設計 (Architecture, 2 pts)

本設計的頂層模組為 `CA`，介面遵守題目提供的 RAM/PATTERN protocol。整體架構切成兩個主要 sibling module：`CA_Control` 負責控制流程與 RAM command，`CA_DataPath` 負責所有寬資料運算。Control 與 DataPath 之間只用少量 sideband 訊號溝通，因此控制 FSM 不需要知道 datapath 內部 pipeline 深度，也不會直接處理 1024-bit 的中間矩陣資料。

```text
CA
├── CA_Control
│   ├── FSM: S_IDLE / S_FAST_RUN / S_ATT_PARAM / S_ATT_READ / S_ATT_WAIT
│   ├── RAM read command: BURST_128, address 0 / 128
│   ├── RAM write command: BURST_128, address 0 / 128
│   └── 依 result_pre_valid / result_valid 安排 write timing
└── CA_DataPath
    ├── ATT_Stream_Core
    │   ├── ATT_QKV_Proj_Quant_Parallel
    │   ├── ATT_Score_8Tap
    │   └── ATT_Final_Booth_Acc
    ├── ACT_5Stage_Parallel
    └── PoT_5Stage_Parallel
        └── Matrix_Max_3Stage_Parallel
```

### 頂層資料流

`CA_Control` 在 job start 時保存 `op`、`act` 與第一筆 `param`。對 attention operation 而言，第一筆 `param` 代表 WQ，接下來兩個 `in_valid` 週期分別保存 WK 與 WV。參數準備完成後，Control 會發出 RAM read burst，並將每一拍 `rd_valid` 對應成一筆 datapath issue。

DataPath 每拍接收一個 256-bit RAM word。每個 256-bit word 代表一個 signed 4-bit 的 8x8 matrix。第一段 compute stage 會把資料展開成 64 lane signed 16-bit 中間結果，再經過共用的 activation 與 PoT quantization block，最後轉回 256-bit signed 4-bit output。

```text
RAM rd_data
   │
   ▼
CA_DataPath input register
   │
   ├── IM_NORM ──► normal/conv projection ──► ACT ──► PoT ──► wr_data/out_data
   │
   └── IM_ATT  ──► Q/K/V projection ──► score ──► final ──► ACT ──► PoT
                                                            │
                                                            └── wr_data/out_data
```

目前 RTL 只保留兩種 issue mode：

| Issue mode | 意義 |
|---|---|
| `IM_NORM` | FFN / Conv path。normal matrix/conv 運算會共用 Q projection 的硬體。 |
| `IM_ATT` | Attention path。stream core 會完成 Q/K/V projection、attention score、final weighted sum、activation 與 PoT。 |

### 最終結果

目前報告採用的最佳合成版本結果如下：

| 項目 | 數值 |
|---|---:|
| RTL simulation | PASS |
| Synthesis clock | 3.3 ns |
| Timing status | MET, worst slack 0.00 ns |
| Latency | 9493 cycles |
| Area | 11,599,150.327094 |
| Performance = area x clk x latency | 3.63e+11 |

相較於前一版 area 為 12,800,902.173878 的架構，最終版本在 latency 不變的情況下面積約下降 9.4%。目前主要面積仍集中在 attention datapath，特別是 Q/K/V projection 與 final score-by-V accumulation。

---

## 設計方法 (Design Methodology, 8 pts)

### 1. Control 與 DataPath 切分

本設計最重要的切分方式，是讓 `CA_Control` 維持窄而單純。Control block 只負責下列工作：

1. 偵測 job start 並保存 operation 參數。
2. 產生 RAM read/write burst command。
3. 依照目前 operation 對每筆 RAM word 發出 `IM_NORM` 或 `IM_ATT`。
4. 計算 result word 數量，判斷每個 128-word half 是否完成。

所有寬資料運算都集中在 `CA_DataPath`。兩邊的介面刻意維持精簡：

| 方向 | 訊號 | 用途 |
|---|---|---|
| Control to DataPath | `issue_valid`, `issue_mode` | 對目前 RAM word 啟動一筆 datapath 運算。 |
| Control to DataPath | `exec_op`, `exec_act`, `exec_param`, `exec_weight_k`, `exec_weight_v` | 保存整個 job 期間使用的 operation 與 weight。 |
| DataPath to Control | `result_pre_valid` | output data 即將準備好，Control 可提前發出 RAM write command。 |
| DataPath to Control | `result_valid` | 真正的 quantized output valid，用來計算完成的 output word 數量。 |

`result_pre_valid` 與 `result_valid` 分開，是因為 RAM write command timing 與 datapath output timing 並不相同。`result_pre_valid` 由 ACT/PoT output pipeline 前段產生，經過 `RESULT_PRE_PIPE = 4` cycles 的 delay 後送給 Control，讓 Control 能在 `pot_data` 真正出來前先發 `wr_en`。`result_valid` 則是 PoT 產生的實際 output valid，只用來計數與輸出。

這個切法讓設計可以隱藏一部分 RAM write latency，同時避免 Control FSM 依賴 ACT 或 PoT 的內部 pipeline 實作。

### 2. RAM Streaming 與 Burst 排程

normal 與 attention 兩種 mode 都把 256 筆 RAM word 分成兩個 128-word half 處理。Control 固定使用 `BURST_128`，先讀 address 0，再讀 address 128。

normal path 的控制流程如下：

```text
S_IDLE
  └── job_start, op[1] = 0
        └── S_FAST_RUN
              ├── 對 address 0 發出 read burst
              ├── 將 128 筆 rd_valid word stream 到 IM_NORM
              ├── 對前 128 筆 output 發出 write burst
              ├── 對 address 128 發出 read burst
              ├── stream 第二段 128 筆 word
              └── 對後 128 筆 output 發出 write burst，完成後回到 idle
```

attention path 的控制流程如下：

```text
S_IDLE
  └── job_start, op[1] = 1, capture WQ
        └── S_ATT_PARAM
              ├── capture WK
              ├── capture WV
              └── S_ATT_READ / S_ATT_WAIT
                    ├── read address 0，stream 128 筆 word 到 IM_ATT
                    ├── write 前 128 筆 output word
                    ├── 第一段 write command 發出後，read address 128
                    └── write 後 128 筆 output word，完成後回到 idle
```

本設計沒有把完整 256-word input 都存進內部 buffer，而是讓每個 `rd_valid` word 立刻進入 streaming datapath。這樣可以減少 storage，也能讓 latency 接近 RAM streaming 時間加上 pipeline drain。

### 3. Streaming Attention Pipeline

早期版本使用較大的 FSM 分別控制 QKV、score 與 final stage。最終版本改成連續的 attention stream，使每一筆 RAM word 依序流過三個 attention compute block：

```text
one 256-bit input word
   │
   ▼
ATT_QKV_Proj_Quant_Parallel
   │  產生 quantized Q, K, V
   ▼
ATT_Score_8Tap
   │  產生 score0 與 score1
   ▼
ATT_Final_Booth_Acc
   │  產生 64 個 signed-16 result
   ▼
ACT_5Stage_Parallel
   │
   ▼
PoT_5Stage_Parallel
   │
   ▼
one 256-bit output word
```

由於各 stage 都是 pipeline，當 `rd_valid` 連續 streaming 時，datapath 每拍都能接收新的 RAM word。雖然單筆資料的 pipeline latency 較長，但 throughput 較高，而且 timing closure 比大型 combinational datapath 容易許多。

### 4. Normal Path 與 Q Projection 共用

最主要的結構性 area optimization，是把 normal FFN/Conv 的乘法硬體與 attention 的 Q projection datapath 共用，並集中在 `ATT_QKV_Proj_Quant_Parallel` 內。

`ATT_QKV_Proj_Quant_Parallel` 內部有三條 projection pipe：

| Pipe | Attention mode | Normal mode |
|---|---|---|
| Q pipe | 計算 Q = X x WQ | 作為 FFN/Conv compute engine |
| K pipe | 計算 K = X x WK | normal mode 不使用 |
| V pipe | 計算 V = X x WV | normal mode 不使用 |

FFN 時，Q pipe 執行 8-tap matrix multiply。Conv 時，同一條 pipe 會切換 operand selection，改成 3x3 zero-padding convolution window。由於 attention pipeline 本來已經需要 projection 硬體，這個共用方式可以避免額外保留一套 normal multiplier array。

attention mode 下，Q/K/V 會從同一筆 input word 平行計算。接著 module 在內部做類似 PoT 的 scaling，並把 Q/K/V clamp 回 signed 4-bit，送到下一個 score stage。這能讓 score 與 final stage 的資料寬度維持較窄。

### 5. Score Stage 設計

`ATT_Score_8Tap` 計算 Q 與 K 之間的 64 個 dot product。每個 score lane 有四段 pipeline：

1. 八個 signed 4-bit multiplication。
2. pairwise add reduction。
3. head partial sum。
4. full score selection 與 attention activation。

SHA 與 MHA 的 score 使用方式不同：

| Mode | `score0` | `score1` |
|---|---|---|
| SHA | 完整 8-tap score | 不使用 |
| MHA | lower 4-tap head | upper 4-tap head |

attention activation 直接整合在 score lane 中：負數 score 右移 2 bits，非負數直接通過。這樣 score 不需要再經過通用 ACT block，可以省下額外 pipeline 與 mux。

score width 被縮到 10 bits (`SCORE_ELEM_W = 10`)。對 8-tap signed 4-bit dot-product 加上 activation 後的範圍而言，10 bits 足夠表示，同時也能縮小 score bus 與 final stage multiplier。

### 6. 使用 Booth Accumulation 的 Final Stage

`ATT_Final_Booth_Acc` 負責計算 final attention output，也就是將 score row 與 V column 相乘累加。如果直接使用 score-by-V multiplier，每個 output lane 都需要八個 score x V 乘法器，面積會很大。因此最終版本對 signed 4-bit V 使用 radix-4 Booth encoding。

每個 tap 的部分積可表示為：

```text
V[1:0] 與 V[3:1] 分別選出兩個 score 的 Booth partial product
partial = pp_lo + (pp_hi << 2)
```

接著每個 lane 用 pipeline reduction 把八個 partial product 加總：

```text
8 products -> 4 pair sums -> 2 half sums -> 1 final result
```

MHA 時，lane 0 到 3 使用 `score0`，lane 4 到 7 使用 `score1`。SHA 時，low lanes 與 high lanes 都重複使用 `score0`。此外，module 會把 `v_data` 複製到八個 row register。這會增加少量 flops，但可以降低 V 對 64 個 final lanes 的 fanout，讓 timing 較穩定。

### 7. 共用 ACT Pipeline

normal compute 或 attention final compute 的 signed 16-bit result，都會進入共用的 `ACT_5Stage_Parallel`。ACT block 包含一個 input buffer 與四個主要 stage：

| Stage | 功能 |
|---|---|
| Input buffer | 保存 1024-bit matrix 與 activation mode。 |
| Stage 0 | 計算 threshold generation 所需的 pair sums。 |
| Stage 1 | 將 pair sums 合成 partial sums。 |
| Stage 2 | 計算 RAT/CAT/BAT thresholds。 |
| Stage 3 | 對每個 element 套用 ReLU/RAT/CAT/BAT。 |

threshold logic 採用 element-centric 寫法。RAT、CAT、BAT 不需要真的重排整個 8x8 matrix，而是讓每個 output position 自己決定要使用哪個 threshold。這樣可以維持簡單的 write ordering，也避免額外的 matrix transpose storage。

### 8. PoT Quantization 與 Matrix_Max

`PoT_5Stage_Parallel` 將 64 個 signed 16-bit value 轉回 64 個 signed 4-bit value。PoT scaling 不需要完整比較出最大值，只需要知道所有 absolute value 中最高 set bit 的位置。因此 `Matrix_Max_3Stage_Parallel` 使用 bitwise OR reduction 取代 full max tree：

```text
max_abs_msb = MSB position of OR(abs(value[0]), abs(value[1]), ..., abs(value[63]))
shift       = max(max_abs_msb - 2, 0)
```

這個方法把較寬的 comparison tree 換成 16-bit OR tree 與 priority encoder。shift computation 也被移到一個小型 3-stage pipeline 中，因此最後 quantization stage 只需要對每個 lane 做 arithmetic shift 與 clamp。

### 9. 寫入資料 Skid Buffer

DataPath 內含一個小型 `wr_data` skid buffer。若 `result_valid` 出現時 `wr_valid` 尚未拉起，256-bit `pot_data` 會先被存入 `wr_data_skid_cs`。當 RAM write channel 可以接收資料時，會優先送出保存的資料。若同一拍又有新的 result，skid buffer 會更新為新的 `pot_data`。

這個 buffer 可以避免 RAM write channel 與 datapath output 暫時錯位時遺失 output data。

### 10. 面積最佳化整理

目前 synthesized hierarchy 顯示，面積主要集中在 attention arithmetic：

| 模組 | 約略面積 | 比例 |
|---|---:|---:|
| Q/K/V projection and quantization | 5.143M | 44.3% |
| Final score-by-V accumulation | 3.122M | 26.9% |
| Score dot-product stage | 1.941M | 16.7% |
| PoT / Matrix_Max | 0.534M | 4.6% |

主要 area optimization 如下：

1. normal multiply/conv engine 與 attention Q projection pipe 共用。
2. 將 Q/K/V projection 與 quantization 融合在同一個 module。
3. 將 score storage 與 final score bus 縮到 10 bits。
4. 用 Booth partial product 取代較一般的 score-by-V multiplication。
5. stream architecture 穩定後，刪除未使用的 legacy modules。

---

## 討論 (Discussion, 3 pts)

### 1. Performance 取捨

最終 performance 為：

```text
performance = area x clk x latency
            = 11,599,150.327094 x 3.3 x 9493
            = 3.63e+11
```

本設計在 3.3 ns 下 timing clean，但 worst slack 剛好是 0.00 ns。這代表目前架構已經接近合成後的 timing limit。若要把 clock 推到 3.2 ns 或更低，應該需要額外的 timing-oriented RTL change，而不只是單純修改 constraint。

### 2. 為什麼 Streaming Architecture 有幫助

舊版 stage-based attention design 需要更多 control state、更多 intermediate memory，以及更多 stage-specific bookkeeping。最終版本將 attention 改成 streaming datapath，使每筆 RAM word 連續流過 QKV、score、final、ACT 與 PoT。這有三個好處：

1. Control 更簡單，只需要計算 RAM word 與 result word。
2. Storage 較少，不需要為許多 word 保存完整 Q/K/V/score memories。
3. Pipeline timing 較規則，因為每個 stage 都有固定的 producer-consumer 關係。

代價是 area：為了維持 throughput，Q/K/V 仍然平行計算，因此 projection module 仍是最大面積來源。

### 3. Write Scheduling 設計

Control logic 中最容易出錯的地方，是 `result_pre_valid` 與 `result_valid` 的分離。Write command 必須在真正資料出現前發出，但 result counter 只能計算真正 valid 的 output。把兩個 signal 分開後，可以避免 off-by-one error，也能在不增加 datapath stall 的情況下隱藏 RAM write timing。

### 4. 剩餘瓶頸

目前設計仍有三個主要 bottleneck：

1. `ATT_QKV_Proj_Quant_Parallel` 面積大，因為它包含三條 parallel projection pipe。
2. `ATT_Final_Booth_Acc` 面積大，因為它有 64 個 final lanes，每個 lane 都有 Booth partial-product logic 與 reduction tree。
3. 3.3 ns timing 剛好通過，因此任何增加 mux depth 的 area reduction 都可能破壞 timing。

未來若要繼續優化，可以考慮 partial serialization final stage，或讓 Q/K/V 硬體在更多 cycle 之間共用。不過這些方法都會增加 latency，因此必須用完整 performance formula 評估，而不能只看 area。

---

## 心得 (Reflection, 2 pts)

這次 project 讓 area、clock 與 latency 的 trade-off 變得非常具體。共用硬體可以降低 area，但很容易增加 latency；加 pipeline register 可以改善 clock timing，但也會提高 control complexity；datapath 全平行化可以提升 throughput，卻會讓 area 變大。最後分數取決於三者相乘，因此只優化其中一項常常不會讓整體 performance 變好。

最有幫助的架構改動，是從 stage-controlled attention design 轉成 streaming datapath。當每個 RAM word 都變成 pipeline 中的一個獨立 item 後，Control 不再需要理解 QKV、score、final 的內部 pipeline 細節。這讓後續優化比較容易進行，特別是 normal path 與 Q projection 共用，以及刪除不再使用的 legacy modules。

最終結果雖然還沒有達到理想中的 10M area target，但相較於早期 12.8M 的版本已有明顯改善，並且 latency 保持在約 9500 cycles。若要進一步做 aggressive area reduction，必須仔細計算 latency 影響並重新合成，因為目前 3.3 ns 的 timing margin 已經用完。

---

## AI 使用紀錄

1. **使用工具**：本次設計過程使用 ChatGPT / Codex 作為 RTL design assistant。
2. **主要用途**：
   - 分析目前 `CA.sv` module hierarchy，找出 report 中已經過時的架構描述。
   - 依照 final performance formula 比較 area、latency 與 clock 的取捨。
   - 協助評估 datapath optimization，例如 normal path 與 Q projection 共用、score width 縮減，以及移除 unused legacy modules。
   - 重寫本報告，使內容與最終 stream-based RTL architecture 對齊。
3. **人工確認**：
   - RTL simulation 與 synthesis result 已在 workstation 上確認。
   - 最終採用數據為 latest passing version：clk 3.3 ns，area 11,599,150.327094，latency 9493，performance 3.63e+11。
