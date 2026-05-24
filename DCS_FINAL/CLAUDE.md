# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## 語言偏好

**預設使用繁體中文回答**。改 code 時永遠追求：**面積更小（Area↓）、速度更快（Cycle↓）、timing met**。

---

## 專案目標

實作 `CA.sv`（Conformer Accelerator），頂層模組名稱固定為 `CA`。  
從 RAM 讀取 4-bit 8×8 矩陣 → 執行 op+act 運算 → PoT 量化 → 存回 RAM + 輸出 last token。

**Performance 目標**（佔 25 分）：最小化 `execution_cycles × cycle_time × area`

---

## 執行說明

因為在本機跑Verilog Code會錯誤，做完code review或是完成一段代碼後不用測試執行看看檔案。
不要在本機跑verilog套件會錯誤。
只需要做語法跟邏輯檢查就好了。
PATTERN.sv, RAM.sv 現在被保護，不用去查看裡面寫什麼
---

## CA.sv 介面

### 來自 PATTERN 的輸入
| 訊號 | 寬度 | 說明 |
|------|------|------|
| `clk` | 1 | 時脈 |
| `rst_n` | 1 | 非同步主動低重置 |
| `mem_set` | 1 | RAM 已就緒，高電位時此輪 RAM 仍有 op set 待算 |
| `in_valid` | 1 | FFN/Conv：高 1 cycle；Attention：高 3 cycles |
| `op[1:0]` | 2 | 00=FFN, 01=Conv, 10=SHA, 11=MHA |
| `act[1:0]` | 2 | 00=ReLU, 01=RAT, 10=CAT, 11=BAT |
| `param[255:0]` | 256 | weights（signed 4-bit packed，MSB→LSB raster order） |

### 輸出到 PATTERN
| 訊號 | 說明 |
|------|------|
| `out_valid` | 輸出有效（**reset required**） |
| `out_data[31:0]` | last token = result matrix 最後一列（8個 signed 4-bit）（**reset required**） |

### RAM 介面
- **Read**：`rd_ready=1` 時同步拉高 `rd_en`，同時給 `rd_addr`、`rd_burst`；50 cycles 後 `rd_valid=1` 時資料到
- **Write**：`wr_ready=1` 時同步拉高 `wr_en`，同時給 `wr_addr`、`wr_burst`；等 `wr_valid=1` 時放 `wr_data`（burst 時每 cycle 換一筆）
- RAM 為 **negative edge triggered**
- Burst：`rd_burst`/`wr_burst` 為 3-bit，一次傳 `2^burst` 個 words（最多 128 words = 全部 RAM）

---

## 運算規格

### Computation（op）

**FFN**（`2'b00`）：`y = Wx`，8×8 矩陣乘法  
- param = 64 個 signed 4-bit（raster MSB→LSB）  
- `output[i][j] = sum_k(input[i][k] * weight[k][j])`

**Convolution**（`2'b01`）：kernel 3×3, zero-padding=1, stride=1  
- param = 9 個 signed 4-bit（raster MSB→LSB）

**Single-Head Attention**（`2'b10`）：  
- param = 3×64 = 192 個（3 cycles in_valid，依序 W_Q, W_K, W_V）  
- Step 1: Q=input×W_Q, K=input×W_K, V=input×W_V  
- Step 2: Q, K, V 各自 PoT quantize 到 4-bit  
- Step 3: score = Q × K^T  
- Step 4: partial = act(score)（此處 act 固定為 x≥0 保留，x<0 → x>>2）  
- Step 5: attn_ctx = partial × V

**Multi-Head Attention**（`2'b11`）：  
- 同 SHA，但 Q/K 沿 column 方向切半：head1=col[0:3], head2=col[4:7]  
- head_dim = 4，分別計算 score_1, score_2，再各自與 V 的對應部分相乘

### Activation（act，作用於 computation 結果）

**ReLU**（`2'b00`）：`x < 0 → 0`

**RAT**（`2'b01`）：row-wise 平均為 threshold，`value < threshold → value / 8`

**CAT**（`2'b10`）：column-wise 平均為 threshold，`value < threshold → value / 8`

**BAT**（`2'b11`）：4×4 block 平均為 threshold，`value < threshold → value / 8`

### PoT Quantization（每次 activation 後執行）

```python
OUT_MAX = 7  # 2^(4-1) - 1
OUT_MIN = -8
LOG2_OUT_MAX = 2  # OUT_WIDTH - 2

max_abs = max(abs(x) for all x in matrix)
shift = max(bit_length(max_abs) - 1 - LOG2_OUT_MAX, 0)  # CLZ 找 MSB 位置
result[i][j] = clamp(x >> shift, OUT_MIN, OUT_MAX)       # arithmetic right shift
```

---

## 整體流程（每輪 RAM）

1. `mem_set=1` → RAM 就緒
2. `in_valid=1` → 接收 op, act, param
3. 從 RAM 讀取所有 256 筆 input matrix（地址 0~255）
4. 每筆 matrix：computation → activation → PoT quantize → 存回原址
5. 每筆完成後：拉高 `out_valid`，`out_data` = result matrix 最後一列（last token）
6. 256 筆全部完成後，接收下一組 op set（`in_valid` 再次來臨）
7. 所有 op set 完成後 `mem_set=0`，等待下一輪 RAM

**timing 限制**：output 必須在 `in_valid` 下降後 **10000 cycles** 內產生

---

## 硬體設計原則（效能優化）


- **Pipeline 讀寫**：RAM read latency=50 cycles，write=5 cycles，可在等待 read 時做前一筆的 computation
- **面積考量**：乘法器共用（FFN/Conv/Attention 都是 MAC），避免重複例化
- **不可修改** `RAM.sv`、`PATTERN.sv`
- **禁止命名**：任何 logic/wire/reg/submodule/parameter 名稱不得含 `error`、`latch`、`congratulation`、`fail`（含前後綴）
- **禁止 latch**：所有 if-else/case 必須有 default，或用 always_ff
- `out_valid` 和 `out_data` 需在 reset 時歸零（reset required）

---

## 評分

| 項目 | 比重 |
|------|------|
| RTL/SYN/GATE 正確（no error, no latch, timing met） | 60% |
| Performance = cycles × cycle_time × area（越小越好） | 25% |
| Report（≤4 頁 A4） | 15% |
| PATTERN bonus | +5% |

**繳交**：1de 2026/06/11；2de 2026/06/18（2de 總分 -30%）
