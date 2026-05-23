# CA Final Project RTL Implementation Guide

日期：2026-05-24  
目標檔案：`DCS_FINAL/CA.sv`  
相關檔案：`DCS_FINAL/00_TESTBED/TESTBED.sv`, `DCS_FINAL/00_TESTBED/RAM.sv`, `DCS_FINAL/00_TESTBED/PATTERN.sv`, `DCS_FINAL/2026_DCS_Final.pdf`, `DCS_FINAL/2026_DCS_Final_appendix.pdf`

這份文件不是 final report，而是給實作 `CA.sv` 用的 RTL checklist。重點是先讓 RAM 資料流動起來，再逐步加入 unpack/pack、FFN、activation、quantization、Conv、Attention，最後才優化 performance。

## 1. Project Goal

`CA.sv` 是 Conformer Accelerator top module，必須：

- 接收 `in_valid`, `op`, `act`, `param`。
- 等待 `mem_set` 後，透過 RAM interface 讀取 input data。
- 根據 `op` 執行 FFN、Conv、Single-Head Attention、Multi-Head Attention。
- 根據 `act` 執行 ReLU、RAT、CAT、BAT。
- 執行 PoT quantization，將結果壓回 signed 4-bit。
- 將結果寫回 RAM。
- 輸出 `out_valid` 與 `out_data[31:0]`。
- 通過 RTL simulation、synthesis、gate simulation。
- synthesis 不可產生 latch，timing slack 必須 met。

第一版不要追求 performance。第一版的成功標準是：reset 正確、input register 正確、RAM read/write handshake 正確、FSM 不會卡死。

## 2. Actual Top Interface Notes

目前 repository 裡的 `CA.sv` interface 與 testbench 使用以下訊號名稱：

```systemverilog
input  logic clk;
input  logic rst_n;
input  logic mem_set;
input  logic in_valid;
input  logic [1:0] op;
input  logic [1:0] act;
input  logic [255:0] param;

output logic out_valid;
output logic [31:0] out_data;

output logic rd_en;
output logic [$clog2(RAM_DEPTH)-1:0] rd_addr;
output logic [BURST_BIT-1:0] rd_burst;
input  logic rd_valid;
input  logic [RAM_WIDTH-1:0] rd_data;
input  logic rd_ready;

output logic wr_en;
output logic [$clog2(RAM_DEPTH)-1:0] wr_addr;
output logic [BURST_BIT-1:0] wr_burst;
output logic [RAM_WIDTH-1:0] wr_data;
input  logic wr_valid;
input  logic wr_ready;
```

注意：

- `mem_set` 是小寫，不是 `Mem_set`。
- Actual top module 比簡化版多一個 `wr_valid` input。
- `RAM_DEPTH`, `RAM_WIDTH`, `BURST_BIT` 都由 testbench parameter 傳入。
- `out_valid` 和 `out_data` reset 後必須為 0。
- 所有 RAM/output control signals reset 後也應歸零。

## 3. Recommended File Structure Inside CA.sv

即使只能交單一 `CA.sv`，也要用清楚區塊分層：

```text
CA.sv
├── localparam / typedef
├── FSM state and counters
├── input registers
├── RAM read/write controller
├── packed data buffers
├── unpack logic
├── compute logic
│   ├── FFN
│   ├── Conv
│   ├── SHA
│   └── MHA
├── activation logic
├── quantization logic
├── pack logic
└── output/writeback logic
```

不要一開始拆成多個 module，除非確認助教 flow 允許額外檔案。安全做法是先把所有 helper logic 放在同一個 `CA.sv`。

## 4. RTL Coding Rules

### 4.1 Sequential Block Rule

`always_ff` 只放 register update。

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cs <= S_IDLE;
        op_reg <= 2'd0;
        act_reg <= 2'd0;
        param_reg <= 256'd0;
    end else begin
        cs <= ns;
        op_reg <= op_reg_ns;
        act_reg <= act_reg_ns;
        param_reg <= param_reg_ns;
    end
end
```

### 4.2 Combinational Block Rule

`always_comb` 一開始先給所有 next-state 與 output default。

```systemverilog
always_comb begin
    ns = cs;

    rd_en = 1'b0;
    rd_addr = '0;
    rd_burst = '0;

    wr_en = 1'b0;
    wr_addr = '0;
    wr_burst = '0;
    wr_data = '0;

    out_valid = 1'b0;
    out_data = 32'd0;

    op_reg_ns = op_reg;
    act_reg_ns = act_reg;
    param_reg_ns = param_reg;

    case (cs)
        default: ns = S_IDLE;
    endcase
end
```

這是避免 latch 的第一條防線。每個 `always_comb` 都必須有完整 default assignment。

### 4.3 Signed Rule

所有 4-bit data、weight、kernel 都視為 signed。

建議固定 typedef：

```systemverilog
typedef logic signed [3:0]  s4_t;
typedef logic signed [7:0]  mul_t;
typedef logic signed [15:0] acc_t;
typedef logic signed [31:0] wide_t;
```

乘加時不要依賴隱式 signed extension，能寫清楚就寫清楚：

```systemverilog
sum = sum + $signed(w[i][k]) * $signed(x[k][j]);
```

## 5. Development Roadmap

### Stage 0：只確認 top interface 能 compile

目標：

- `CA.sv` module interface 不改壞。
- 所有 output 有宣告、有 default。
- 不加入任何運算。

完成條件：

- RTL compile 不因 interface mismatch 失敗。
- reset 後 output 都是 0。

### Stage 1：FSM skeleton

先建立主要 FSM，不做真正運算。

建議 state：

```systemverilog
typedef enum logic [3:0] {
    S_IDLE,
    S_LOAD_PARAM,
    S_WAIT_MEM,
    S_READ_REQ,
    S_WAIT_RD,
    S_UNPACK,
    S_COMPUTE,
    S_ACT,
    S_QUANT,
    S_PACK,
    S_WRITE_REQ,
    S_WAIT_WR,
    S_OUTPUT
} state_t;
```

第一版可以只用：

```text
S_IDLE -> S_WAIT_MEM -> S_READ_REQ -> S_WAIT_RD -> S_WRITE_REQ -> S_OUTPUT
```

之後再插入 `S_UNPACK`, `S_COMPUTE`, `S_ACT`, `S_QUANT`, `S_PACK`。

### Stage 2：input capture

在 `S_IDLE` 收到 `in_valid` 時，先存：

- `op_reg`
- `act_reg`
- `param_reg`

需要注意：

- FFN/Conv 的 `param` 通常是一個 cycle。
- Attention 可能需要多個 `in_valid` cycle 才收完 `WQ`, `WK`, `WV`。
- 不要在還沒確定 `op` 前就開始 RAM access。

建議建立：

```systemverilog
logic [1:0] op_reg, act_reg;
logic [255:0] param_reg [0:2];
logic [1:0] param_cnt, param_need;
```

第一版可以只存 `param_reg[0]`。等 FFN/Conv 通過後，再擴充 Attention 的 3-cycle parameter capture。

### Stage 3：RAM read/write pass-through

這是第一個真正有價值的版本。

行為：

1. 收到 command。
2. 等 `mem_set == 1'b1`。
3. 等 `rd_ready == 1'b1`。
4. 送一筆 read request。
5. 等 `rd_valid == 1'b1`。
6. 把 `rd_data` 存到 `data_buf`。
7. 等 `wr_ready == 1'b1`。
8. 送一筆 write request。
9. 在 write data phase 提供 `wr_data = data_buf`。
10. `out_valid` 拉高一個 cycle，`out_data = data_buf[31:0]`。

第一版設定：

```systemverilog
rd_burst = 3'd0;  // 2^0 = 1 word
wr_burst = 3'd0;  // 2^0 = 1 word
rd_addr  = 8'd0;
wr_addr  = 8'd0;
```

`wr_valid` 是 RAM 端給 `CA` 的 data-phase 訊號。實作時應在送出 write request 後等待 `wr_valid`，並在 `wr_valid` 有效時提供穩定的 `wr_data`。若後續使用 burst write，需用 `wr_valid` 推進 write beat counter。

完成條件：

- `rd_en` 只在 `rd_ready` 可接受 request 時拉高。
- `rd_data` 只在 `rd_valid` 時被 sample。
- `wr_en` 只在 `wr_ready` 可接受 request 時拉高。
- `wr_data` 來自已註冊的 buffer，不直接 combinational 接 `rd_data`。
- FSM 不會超過 10000 cycles 卡死。

## 6. RAM Controller Plan

先把 RAM 控制當成獨立子問題。

### 6.1 Read Request

控制訊號：

- `rd_en`
- `rd_addr`
- `rd_burst`

規則：

- `rd_ready == 1` 時才送 `rd_en`。
- `rd_en` 建議只拉一個 cycle。
- 送出 request 後進入 `S_WAIT_RD`。
- `rd_valid == 1` 時 sample `rd_data`。

第一版只讀一個 256-bit word。

後續如果要 burst：

- `rd_burst = burst_log2`。
- 需要 `read_beat_cnt`。
- 每次 `rd_valid` 收一個 word。
- 收滿 `2 ** rd_burst` 筆後才離開 read state。

### 6.2 Write Request

控制訊號：

- `wr_en`
- `wr_addr`
- `wr_burst`
- `wr_data`

規則：

- `wr_ready == 1` 時才送 `wr_en`。
- `wr_en` 建議只拉一個 cycle。
- 送出 request 後進入 `S_WAIT_WR`。
- `wr_valid == 1` 時提供當前 beat 的 `wr_data`，並推進 `write_beat_cnt`。

第一版只寫一個 256-bit word。

後續如果要 burst：

- `wr_burst = burst_log2`。
- `wr_data` 由 `write_beat_cnt` 選擇結果 buffer。
- `wr_valid` 有效時才前進到下一筆。

## 7. Data Layout: 256-bit to 8x8 Signed 4-bit

一個 256-bit word 可視為 64 個 signed 4-bit element。

使用 MSB 到 LSB raster scan order：

```text
word[255:252] -> matrix[0][0]
word[251:248] -> matrix[0][1]
...
word[31:28]   -> matrix[7][0]
...
word[3:0]     -> matrix[7][7]
```

Unpack pattern：

```systemverilog
for (int i = 0; i < 8; i++) begin
    for (int j = 0; j < 8; j++) begin
        x_mat[i][j] = data_buf[255 - 4 * (i * 8 + j) -: 4];
    end
end
```

Pack pattern：

```systemverilog
for (int i = 0; i < 8; i++) begin
    for (int j = 0; j < 8; j++) begin
        result_word[255 - 4 * (i * 8 + j) -: 4] = result_q[i][j];
    end
end
```

建議先做一個固定測試：

- 將 `256'h0123...` 類似資料讀入。
- waveform 確認 `x_mat[0][0]` 對到 MSB nibble。
- waveform 確認 `x_mat[7][7]` 對到 LSB nibble。

如果 unpack/pack 順序錯，後面的 FFN、Conv、Attention 都會全錯。

## 8. Compute Implementation Order

### 8.1 First Compute Target: FFN

先只支援 `op == 2'b00`。

建議先實作 combinational full matmul，求功能正確：

```systemverilog
for (int i = 0; i < 8; i++) begin
    for (int j = 0; j < 8; j++) begin
        sum = '0;
        for (int k = 0; k < 8; k++) begin
            sum += $signed(w_mat[i][k]) * $signed(x_mat[k][j]);
        end
        y_mat[i][j] = sum;
    end
end
```

文件中的工作假設是 `Y = W x X`。實作前仍要以 PDF/appendix 的公式為準，因為若 pattern 期待 `X x W`，row/column 會完全相反。

第一版可接受面積與 critical path 偏大，因為目的只是通 RTL functional。

第二版再考慮：

- 每 cycle 算一個 output element。
- 用 8 個 multiplier + adder tree。
- 或用更少 MAC 多 cycle 重複使用。

### 8.2 Activation

Activation 不要混在 matmul 裡。

固定 pipeline：

```text
compute_result -> activation_result -> quantized_result
```

ReLU：

```systemverilog
act_y[i][j] = (y_mat[i][j] < 0) ? '0 : y_mat[i][j];
```

RAT：

- 每 row 算 average threshold。
- `value >= threshold` 保留。
- `value < threshold` 則除以 8。

CAT：

- 每 column 算 average threshold。
- 其他規則同 RAT。

BAT：

- 每個 4x4 block 算 average threshold。
- 8x8 matrix 共有 4 個 block。
- 其他規則同 RAT。

Signed division by 8 要特別處理。若 spec 要求 truncate toward zero，不可單純對所有 signed value 使用 `>>> 3`，因為負數 arithmetic shift 是向負無限方向靠近。

建議 helper 行為：

```systemverilog
function automatic acc_t div8_toward_zero(input acc_t v);
    if (v < 0)
        div8_toward_zero = -((-v) >>> 3);
    else
        div8_toward_zero = v >>> 3;
endfunction
```

### 8.3 Quantization

Quantization 放在 activation 後面。

目標：

- 找 matrix 中最大 absolute value。
- 選擇 power-of-two scaling shift。
- 全部 element 右移。
- clamp 到 signed 4-bit range `[-8, 7]`。

建議行為：

```text
max_abs = max(abs(act_y[i][j]))
shift = max(msb_index(max_abs) - 2, 0)
q = act_y[i][j] >>> shift
q = clamp(q, -8, 7)
```

`2` 來自 signed 4-bit positive max `7` 的有效 magnitude bit 位置。若 appendix 定義不同 scaling rule，以 appendix 為準。

Debug 順序：

1. 先看 raw compute result。
2. 再看 activation result。
3. 最後看 quantized result。

不要一開始就把 quantization 混進 FFN，否則很難判斷錯在哪一層。

### 8.4 Conv

FFN + activation + quantization 通過後，再做 `op == 2'b01`。

工作假設：

- kernel 為 3x3。
- zero padding = 1。
- stride = 1。
- `param` 的 kernel 以 MSB 到 LSB raster scan order unpack。

實作重點：

- 邊界超出 matrix 時視為 0。
- kernel index 與 input patch index 要清楚。
- 輸出仍是 8x8。
- Conv raw result 也走共用 activation 與 quantization。

建議先寫獨立 combinational conv block，再重構共用 MAC。

### 8.5 Single-Head Attention

最後才做 `op == 2'b10`。

拆成多個已知 block：

```text
Q = WQ x X
K = WK x X
V = WV x X
Q_q, K_q, V_q = quantize(Q, K, V)
Score = Q_q x K_q^T
Prob = activation(Score)
Context = Prob x V_q
Result = quantize(Context)
```

實作方式：

- 不要一次寫完整 attention。
- 先重用 FFN matmul block 產生 Q/K/V。
- 再做 transpose read 或 index swap，算 `Q x K^T`。
- `Score` 再進 activation。
- 最後做第二次 matmul。

Attention 需要多組 parameter，建議 `param_reg[0]`, `param_reg[1]`, `param_reg[2]` 分別存 `WQ`, `WK`, `WV`。

### 8.6 Multi-Head Attention

`op == 2'b11` 最後處理。

工作假設：

- 基本流程與 SHA 相同。
- Q/K 依 column 分成兩個 head。
- head0 使用 column 0 到 3。
- head1 使用 column 4 到 7。
- 各 head 分別算 score/prob，再與 V 對應部分相乘。

MHA 不要寫成全新資料路徑。優先重用：

- matmul block
- transpose/indexing logic
- activation block
- quantization block

## 9. Suggested Internal Registers and Counters

Control：

```systemverilog
state_t cs, ns;
logic [1:0] op_reg, act_reg;
logic [1:0] param_cnt, param_need;
logic [7:0] cycle_guard;
```

RAM：

```systemverilog
logic [7:0] read_addr_reg, write_addr_reg;
logic [7:0] read_beat_cnt, write_beat_cnt;
logic [255:0] data_buf;
logic [255:0] result_word;
```

Matrix buffers：

```systemverilog
s4_t  x_mat [0:7][0:7];
s4_t  w_mat [0:7][0:7];
acc_t y_mat [0:7][0:7];
acc_t act_mat [0:7][0:7];
s4_t  q_mat [0:7][0:7];
```

Attention buffers can be added after FFN/Conv:

```systemverilog
s4_t q_buf [0:7][0:7];
s4_t k_buf [0:7][0:7];
s4_t v_buf [0:7][0:7];
acc_t score_buf [0:7][0:7];
acc_t prob_buf [0:7][0:7];
```

若 synthesis 面積太大，第二版再把 large matrix buffers 減少或改成逐 row/element 運算。

## 10. Output Plan

`out_valid`：

- reset 後為 0。
- 預設為 0。
- 只在 `S_OUTPUT` 拉高。
- 建議第一版拉高一個 cycle。

`out_data`：

- reset 後為 0。
- 非 `out_valid` cycle 建議輸出 0。
- 第一版 pass-through：`out_data = data_buf[31:0]`。
- 完整版：輸出 result matrix 的最後 8 個 signed 4-bit element，即 packed result 的最後 32-bit。

## 11. Verification Checklist

每完成一小段就跑 simulation，不要寫完整 Attention 後才 debug。

### Checkpoint 1：reset

- `out_valid == 0`
- `out_data == 0`
- `rd_en == 0`
- `wr_en == 0`
- `wr_data == 0`
- FSM 回到 `S_IDLE`

### Checkpoint 2：input capture

- `in_valid` 時 `op_reg` 正確。
- `act_reg` 正確。
- `param_reg` 正確。
- Attention 多 cycle parameter capture 不覆蓋錯位置。

### Checkpoint 3：RAM read request

- `mem_set` 前不送 RAM request。
- `rd_ready` 前不拉 `rd_en`。
- `rd_en` pulse 時 `rd_addr`, `rd_burst` 穩定。

### Checkpoint 4：RAM read data

- 只在 `rd_valid` sample `rd_data`。
- `data_buf` 保持到 write/output 完成。

### Checkpoint 5：pass-through writeback

- `wr_ready` 前不拉 `wr_en`。
- `wr_en` pulse 時 `wr_addr`, `wr_burst` 穩定。
- `wr_valid` data phase 時 `wr_data` 穩定。
- `out_valid` 在合理 cycle 內出現。

### Checkpoint 6：unpack/pack

- `x_mat[0][0]` 對應 packed MSB nibble。
- `x_mat[7][7]` 對應 packed LSB nibble。
- pack 回去後 bit order 不變。

### Checkpoint 7：FFN

- 先比對 raw matrix multiply。
- 再加入 ReLU。
- 再加入其他 activation。
- 最後加入 quantization。

### Checkpoint 8：Conv

- 先驗 3x3 center case。
- 再驗四個 corner zero-padding。
- 再驗完整 8x8 output。

### Checkpoint 9：Attention

- 先驗 Q/K/V matmul。
- 再驗 Q/K/V quantization。
- 再驗 score。
- 再驗 score activation。
- 再驗 output context。
- 最後驗 MHA head split。

### Checkpoint 10：SYN/GATE

- `syn.log` 沒有 latch。
- timing slack met。
- gate simulation output 與 RTL 一致。

## 12. Performance Upgrade Path

功能正確後再優化。

優化方向：

- 將 full combinational matmul 改成 multi-cycle MAC。
- 共用 FFN/Attention 的 matmul hardware。
- Activation 和 quantization 共用一組 block。
- RAM read/write 使用 burst，降低 handshake overhead。
- Read/compute/write pipeline 化。
- 減少 large register arrays。
- 用 balanced adder tree 降低 critical path。

Ranking 公式是：

```text
execution_cycles x cycle_time x area
```

所以不是 cycle 越少越好。若把所有乘加完全展開，可能 cycle 少但 area 與 clock period 爆掉。第一版先求正確，第二版再在 cycle、timing、area 之間找平衡。

## 13. First Commit Scope Recommendation

第一個 implementation commit 建議只做：

- `CA.sv` typedef/localparam。
- reset-safe FSM skeleton。
- `in_valid` capture `op/act/param`。
- 等 `mem_set`。
- 單筆 RAM read request。
- `rd_valid` sample `rd_data`。
- 單筆 RAM write request。
- pass-through `wr_data`。
- `out_valid/out_data` 一 cycle output。

不要在第一個 commit 加 FFN。原因是 RAM interface 若錯，後面的 compute 都沒有 debug 意義。

## 14. Common Bug List

實作時優先檢查這些問題：

- `always_comb` 漏 default，造成 latch。
- `out_valid` reset 後不是 0。
- `out_data` 在非 valid cycle 殘留舊值。
- `rd_en` 或 `wr_en` 拉太多 cycle，造成重複 request。
- 沒等 `mem_set` 就開始 RAM access。
- 沒等 `rd_ready` 或 `wr_ready` 就送 request。
- 沒等 `rd_valid` 就 sample `rd_data`。
- write data phase 沒處理 `wr_valid`。
- signed 4-bit 被當 unsigned。
- unpack/pack 順序反了。
- FFN row/column 方向反了。
- 負數除以 8 用錯 rounding rule。
- quantization clamp 忘記處理 `-8` 和 `7`。
- Attention parameter 多 cycle capture 覆蓋錯誤。
- FSM 某 state 沒有 exit condition，超過 10000 cycles。

## 15. Implementation Start Checklist

開始寫 `CA.sv` 前先確認：

- Testbench 連接的 signal name 完全照現有 `CA.sv`。
- 不修改 protected `PATTERN.sv` 與 `RAM.sv`。
- 先不要改 Makefile 或 testbench。
- 每個 output 都由單一地方驅動。
- 每個 state 都能回到下一個 state 或 `S_IDLE`。
- 第一版只讀寫一筆 RAM word。
- 第一版不做 FFN，不做 quantization，不做 Attention。

完成第一版後，再依序加入：

1. unpack/pack
2. FFN raw compute
3. ReLU
4. RAT/CAT/BAT
5. quantization
6. Conv
7. SHA
8. MHA
9. performance optimization

