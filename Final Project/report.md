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

本 project 的評分指標不是單看 clock、area 或 latency，而是三者相乘：

```text
performance = area x clk x latency
            = 11,599,150.327094 x 3.3 x 9493
            = 3.63e+11
```

因此這個設計的優化方向必須同時考慮三件事。降低 area 不一定會讓 performance 變好，因為若共用硬體造成 latency 明顯上升，最後乘積可能反而變差；加 pipeline register 也不一定有利，因為雖然 clock 可能變短，但 register area 與 control latency 也會增加。最後版本選擇維持 9493 cycles 的短 latency，並把主要心力放在 attention datapath 的面積縮減與 3.3 ns timing closure。

目前 synthesis 在 3.3 ns 下通過，worst slack 為 0.00 ns，代表這版已經接近 timing 邊界。若要再往 3.0 ns 推進，不能只調整 constraint，而需要重新分配 critical path 的運算量，例如把 score-by-V accumulation、activation threshold generation 或 PoT quantization 中較重的 combinational logic 切得更平均。不過這類改動會增加 cycle 或 register area，所以必須重新用完整 formula 評估。

### 2. 為什麼 Streaming Architecture 有幫助

舊版 stage-based attention design 需要比較多 control state、intermediate memory 與 stage-specific bookkeeping。最終版本改成 streaming datapath 後，每筆 RAM word 會依序通過 QKV projection、score、final accumulation、ACT 與 PoT，而不是先在某個 stage 存完整中間矩陣後再進入下一個 stage。

這個方向帶來三個主要好處：

1. Control 更簡單，只需要計算 RAM word 與 result word。
2. Storage 較少，不需要額外保存大量完整 Q/K/V/score matrices。
3. Pipeline timing 較規則，stage 之間形成固定的 producer-consumer 關係。

這個架構也比較容易做局部優化。例如 normal path 可以借用 attention Q projection pipe，而 PoT block 可以只保留一份 full precision source data，後面只 pipeline 256-bit quantized result。代價是為了維持 throughput，Q/K/V projection 仍然需要高度平行化，所以它仍是目前最大的 area source。

### 3. Write Scheduling 設計

Control logic 中最容易出錯的部分，是 RAM write command 與 datapath output data 並不是同一拍發生。因此設計中將 `result_pre_valid` 與 `result_valid` 分開處理。`result_pre_valid` 用來提前通知 Control 發出 write command，`result_valid` 則代表真正的 quantized output 已經產生，可以用來更新 result counter 與 output data。

這樣做的好處是可以把 RAM write timing 隱藏在 datapath pipeline 裡，不需要讓 datapath 因為 write command 尚未準備好而停住。同時，result counter 只看真正 valid 的 output，能避免 half-burst 邊界附近常見的 off-by-one error。DataPath 內部再加上一個小型 skid buffer，處理 `result_valid` 與 `wr_valid` 暫時錯位的情況，確保 output word 不會遺失。

### 4. 剩餘瓶頸

目前面積仍主要集中在 attention arithmetic。從 hierarchy 來看，最重的是 Q/K/V projection、final score-by-V accumulation 與 score dot-product stage。這些 block 之所以大，是因為它們為了維持每個 RAM word 都能連續流過 pipeline，保留了大量 lane-level parallelism。

後續若要繼續壓低 area，最有機會的方向如下：

1. 讓 Q/K/V projection 在更多 cycle 之間共用 multiplier，但要控制 latency 增幅。
2. 重新切分 final accumulation，使 Booth partial product 與 reduction tree 的工作量更平均。
3. 將 attention final/ACT 需要的較寬資料路徑限制在必要範圍內，避免 16-bit datapath 擴散到所有 matrix pipeline。
4. 檢查 PoT 與 ACT 是否仍有 full matrix pipeline 可以改成 single-source 或 narrow result pipeline。

不過目前 3.3 ns timing margin 很小，任何增加 mux depth 或拉長 adder tree 的 area optimization 都可能造成 timing violation。因此後續優化不能只看 gate count，還要觀察 critical path 是否被平均切開，以及新增 cycle 後整體 performance 是否真的下降。

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
