# DCS 數位電路與系統 — 期末考整理（2022 + 2025）

> 來源：`2022dcs_final.pdf`、`2025_DCS_Final_Exam.pdf`、`2025_DCS_Final_Exam_ans.pdf`
> 2025 附官方解答（紅字），2022 無解答（本檔解析為自行推導，標註「⊳推導」）。
> 內文已嵌入原卷的電路圖、FSM 表、波形格、程式碼、timing report 等圖片（存於 `images/`）。

---

## 0. 兩年考點對照表（Topic Map）

這門課每年題型高度重複，幾乎是固定 8 大主題。掌握下表即涵蓋全部：

| # | 主題 | 2022 | 2025 | 重要度 |
|---|------|------|------|--------|
| A | **Pipeline / Parallelism**（切 register、cycle time、throughput、latency、utilization） | Q1, Q11 | Q1, Q7 | ★★★★★ 必考 |
| B | **Timing Report 判讀**（critical path、slack、setup/hold violation） | Q2(b)(c) | Q2, Q6(a)(b) | ★★★★★ 必考 |
| C | **Block diagram ↔ RTL 互轉** | Q2(a) | Q6(d) | ★★★★ |
| D | **Waveform 畫圖**（FSM code → 波形） | Q3 | Q8 | ★★★★★ 必考 |
| E | **Setup/Hold time violation 計算** | Q12 | Q9 | ★★★★★ 必考 |
| F | **SRAM 擴充**（width/depth、多 port） | Q7, Q8 | Q4 | ★★★★ |
| G | **CDC / Metastability / Synchronizer / Gray code** | Q9 | Q5 | ★★★★ |
| H | **Microcode FSM**（ROM table） | Q10 | Q3 | ★★★ |
| I | **FPGA vs ASIC、valid-ready handshake** | Q4,5,6 | — | ★★ |

---

# 一、核心知識點與公式（先背這些）

## A. Pipeline / Parallelism

**切 pipeline register 的原則**：把 register 插在能讓「最長一段組合邏輯 delay」最小的位置 → **平衡各 stage delay**（balance the stages）。critical path = 最慢的那一段。

- **Cycle time（含 setup）**：`T_clk ≥ max(stage delay) + t_setup`
- **Throughput** = 1 / cycle time（每 cycle 一筆輸出，pipeline 填滿後）。若每筆需 N 個 operation：`throughput = N operations / cycle time`
- **Latency**（總延遲，從輸入到該筆輸出）：
  - 未 pipeline：`= 組合邏輯總 delay`
  - pipeline 後：`= 階數 × cycle time`（通常 **變長或不變，不會變短**！pipeline 提升 throughput，犧牲 single-item latency）
- **Hardware utilization** = 該 stage 實際忙碌時間 / 總時間。瓶頸 stage（最長）= 100%，其餘 = 自身 delay / 瓶頸 delay。
- **平衡 utilization 的切法**：把長 stage 切成多個等長子 stage，使每段 delay 一致 → 全部 100%。
- **避免 stall**：可變延遲 / 瓶頸 stage → 用 **FIFO buffer** 或 **複製（replicate）該 stage 硬體** 輪流處理。
- **Pipeline vs Replication**：pipeline 省面積但 latency 高；replication（平行複製整個 module）面積大但每份獨立。實務常 **replicated pipeline**（兩者並用）。

## B. Timing Report 判讀

```
data arrival time   = launch clk delay + CK→Q + 組合邏輯 delay
data required time  = clk period + capture clk delay − uncertainty − setup
slack = data required − data arrival      ( ≥0 = MET, <0 = VIOLATED )
```
- **Startpoint / Endpoint**：報告開頭直接寫明（launch FF / capture FF 或 input/output port）。
- **slack MET 不代表最小週期 = 週期−slack**：合成工具在更緊的 constraint 下會換不同 cell/架構，最小週期通常**還能更低**，不能直接相減。
- **reg-to-reg path 五段**（2025 Q2 標 a~e）：
  `a` launch clk network delay → `b` launch FF CK→Q → `c` 組合邏輯雲 → `d` capture clk network delay → `e` library setup time。

## E. Setup / Hold Time 檢查（最常算錯，務必熟）

```
Setup check（決定最快 clock）： T_c ≥ t_pcq + t_pd(max) + t_setup
Hold  check（與 clock 無關）：  t_ccq + t_cd(min) ≥ t_hold
```
- `t_pcq`=propagation clk→Q（max）, `t_ccq`=contamination clk→Q（min）
- `t_pd`=邏輯 propagation delay（max）, `t_cd`=邏輯 contamination delay（min）
- **Hold violation 解法**：在快路徑（短路徑）上 **加 delay（buffer）** 使 `t_ccq + t_cd + Δ ≥ t_hold`。加 delay 會吃進 setup 餘裕。
- **Hold 違反與頻率無關**，加快 clock 不會解決也不會惡化 hold。

## F. SRAM 擴充

- **加寬（word width）**：多顆 **並聯**，共用同一 address，輸出 **拼接（concatenate）**。例：1K×8 ×4 顆 → 1K×32。
- **加深（depth）**：多顆 **堆疊**，用 address 高位元當 **bank select**（decoder 選 chip enable / 輸出端 MUX）。例：1K×8 ×4 顆 → 4K×8，用 A[11:10] 選 bank。
- **多 port（同時讀寫）**：
  - 分 bank（address space 切兩半），兩 port 各自 MUX 連到所定址的 bank；保證不同時打同一 bank 即無衝突。
  - 或複製記憶體（read 用多份 copy，write 同步寫所有 copy）。

## G. Metastability / CDC / Synchronizer

- **Metastability**：FF 取樣時違反 setup/hold，輸出卡在 0/1 之間的不穩定態，需不定長時間才 resolve。
- **2-FF synchronizer**：第一級可能亞穩，但有將近一整個 clock cycle 讓它 resolve，第二級再取樣時穩定機率極高 → 大幅提升 MTBF。
- **Gray code 跨域**：相鄰值**只變 1 bit**，即使在轉態瞬間被取樣，也只會拿到舊值或新值（最多差 1），不會出現多 bit 同時變造成的錯誤中間值。
- **CDC 失敗波形**：來源資料在目標 clk 邊緣附近改變 → 違反 setup/hold → 目標 FF 取到亞穩/錯值。

## H. Microcode FSM

- 用 **ROM** 實作 FSM：**address = {現態 state, 輸入 input}**，**data = {次態 next state, 輸出 output}**。
- next state 經 register 回授當下一輪 address 高位。
- **縮小 memory 方法**：①把 output 與 next-state 分開存（Moore output 只用 state 定址）②用 **instruction + program counter** 取代狀態列舉（microsequencer）③state/output 編碼壓縮、只存有效列。

## I. FPGA vs ASIC / valid-ready

- **FPGA**：可重組、NRE 低、上市快、單顆貴、功耗高/效能較低 → 少量、原型。
- **ASIC**：光罩 NRE 高、固定不可改、效能/功耗/面積佳、量大才划算。
- **valid-ready handshake**：`valid && ready` 同時為 1 的 clock 邊緣才成功傳一筆。
- **簡化**：拿掉 ready（接收端永遠 ready）→ valid-only；或反之只留 ready。

---

# 二、2022 期末考逐題（共 100 分；⊳為推導解析）

### Part I 實作觀念（46%）

**Q1 Pipeline（8%）** — CL1~4 delay = 3/2/2/6 ns，A/B/C 為三個可插點。

<img src="images/2022_q1_pipeline.png" width="720">

- (a) 最佳單一插點？⊳ **C**。各方案最長 stage：A→max(3,10)=10、B→max(5,8)=8、C→max(7,6)=**7**。C 最平衡 → cycle time 最短。
- (b) A、C 兩處都插，最短 cycle time？⊳ 三段 = {CL1=3, CL2+CL3=4, CL4=6} → **6 ns**（題目只看 CL delay）。
- (c) (b) 的 throughput？運算量 45/40/50/60。⊳ 每筆共 195 operations、每 6 ns 出一筆 → **195 / 6 ns ≈ 32.5 G operations/s**（或每秒輸出 1/6ns ≈ 166.7M 筆）。
- (d) 一組 vs 兩組 register 誰 throughput 高？⊳ **兩組**。cycle time 6ns < 7ns，瓶頸段更短 → throughput 更高。

**Q2 Block diagram & Timing Report（20%）** — 給一段 RTL（兩個累加器 data_0/data_1，依 in_sel 選一個累加 in_data，out_data = data_sel + in_data）。

圖例（adder / multiplexer / DFF）：

<img src="images/2022_q2_legend.png" width="520">

題目 RTL：

<img src="images/2022_q2_code.png" width="560">

(b) 的 timing report：

<img src="images/2022_q2_report.png" width="640">

- (a) 用 adder/mux/comparator/DFF 畫 block diagram（10%）。⊳ 重點：in_sel 控制兩顆 DFF 的 feedback MUX 與 data_sel MUX；adder 算 data_add；out_data 直接接 data_add。
- (b) critical path 起點/終點（2%）+ 畫在圖上（3%）。⊳ 報告寫明 **Startpoint: in_sel（input port）→ Endpoint: out_data[2]（output port）**；路徑 in_sel → MUX → adder → out_data。
- (c) 電路有何問題、原因、如何修（5%）。⊳ **slack = −0.82 → setup time violation**。原因：**input→output 為純組合路徑且輸出未暫存**（out_data 是 combinational assign），加上 in/out external delay 後留給邏輯的時間不足。修法：**把輸出暫存（加 output register）/ 切 pipeline / 減少邏輯**，使其變 reg-to-reg。

**Q3 Waveform（18%）** — 給 Pattern + Design（FSM：IDLE/DECODE/ALU1/ALU2，data_nxt 依狀態做 in_data / ×3 / +3 等），畫 rst_n、in_valid、in_data、cs、ns、data_reg（各 3%）。

題目 Pattern（左）與 Design（右）：

<img src="images/2022_q3_code.png" width="760">

畫法範例（1-bit / multi-bit）與要填的空白波形格：

<img src="images/2022_q3_wave_example.png" width="480">

<img src="images/2022_q3_wave_grid.png" width="760">

- ⊳ 方法：(1) 先依 Pattern 排出每個 negedge 的 in_valid/in_data；(2) cs 在 posedge 更新 = 前一刻 ns；(3) 注意 `cs<=IDLE` 由 rst_n 非同步；(4) 有號數用 2's complement 標十進位；(5) `repeat(n)@(negedge)` 展開週期數。需逐 cycle 手算 FSM 轉移。

### Part II 基本觀念（23%）

- **Q4（3%）** FPGA vs ASIC 兩點差異 → 見上「知識點 I」。
- **Q5（3%）** valid-ready 波形說明 → `valid&&ready` 同時 high 才傳；列 clock/data/valid/ready。
- **Q6（3%）** 簡化 valid-ready → 拿掉 ready 變 valid-only（或反向）。
- **Q7（3%）** 16K×4 SRAM 做 64-bit 輸出 → **16 顆並聯**（64/4），共用 14-bit address，輸出拼接。
- **Q8（3%）** 支援 3 組同時讀寫、每組 4-bit → 多 port 記憶體：以複製/分 bank + MUX 路由三組 address/data。
- **Q9（4%）** adat 跨 aclk→bclk 失敗波形 → adat 在 bclk 邊緣附近變動，bdat1 取到亞穩/錯值（列 aclk/adat/bclk/bdat1）。

  <img src="images/2022_q9_cdc.png" width="440">

- **Q10（4%）** Microcode FSM（gns/yns/gew/yew 號誌機）→ ROM：address={state, input(lc)}，data={next state, output 6-bit}。逐列列出位址與資料。

  <img src="images/2022_q10_fsm.png" width="420">

### Part III Design problem（31%）

**Q11 Pipelining & parallelism（18%）** — HD media chip，2000×1000 @100Hz，單 module 處理 1 pixel 需 10µs，t_reg=0。
- (a) 需要的 throughput？⊳ 2000×1000×100 = **2×10⁸ pixels/s**。
- (b) 單一長 pipeline 能達標嗎？需幾級？⊳ pipeline throughput = 1/t_reg... 但每級至少要能每 (1/2e8 s = 5ns) 出一筆。單一 pipeline throughput 上限受最慢級限制；10µs 切成 N 級每級 10µs/N，要 ≤5ns → N ≥ 2000 級。⊳ 理論可行但級數巨大。
- (c) 為何 (b) 是壞主意？⊳ 級數太多 → register 面積/功耗暴增、latency = N×5ns 很大、設計不切實際。
- (d) 改用複製整個 module 要幾份？⊳ 每份 10µs 處理一筆，需 throughput 2e8/s → **需 2×10⁸ × 10µs = 2000 份**。
- (e) 為何也是壞主意？⊳ 2000 份完整 module → 面積/功耗/成本爆炸。
- (f) 改用「複製的 10 級 pipeline」要幾份？⊳ 每份 10 級、每級 1µs、每 1µs 出一筆 → 單份 throughput 1e6/s；需 2e8/s → **200 份**。

**Q12 Setup/Hold violation（13%）** — DFF A：t_s=20, t_h=30, t_ccq=10, t_pcq=20（ps），2GHz（T_c=500ps）。三條路徑 Logic A/B/C（tc/td 見表）。

<img src="images/2022_q12_fig.png" width="640">
- (a) 哪裡要加 delay？⊳ Hold check：`t_ccq + t_cd ≥ t_h=30`。最短路徑 Logic C：10+30=40≥30 OK；Logic A：10+10=20 < 30 → **A→X 違反 hold**，需加 delay。
- (b) 需加多少 delay？⊳ 補到 `10 + (10+Δ) ≥ 30` → **Δ ≥ 10ps**。
- (c) 重檢 setup、能否更快？⊳ Setup：`T_c ≥ t_pcq + t_pd(max) + t_s`。最大 td=400(Logic A)：20+400+20=440ps（加 hold 修正的 10ps→ 20+410+20=450ps）。⊳ 最快 cycle time ≈ **450ps（> 2GHz 可，約 2.22GHz）**。

---

# 三、2025 期末考逐題 + 官方解答（共 100 分）

**Q1 Pipeline & parallel（10%）** — 三段 A/B/C latency = 8/16/4 cycles。
- (a) 畫 4 筆連續輸入 pipeline diagram + utilization。**Ans：A=50%、B=100%、C=25%**（瓶頸 B=16，每 16 cycle 收一筆；圖中每格=4 cycles）。
- (b) 用**最少 stage** 同時讓 utilization 最大？**Ans：A 切 2 段（8→4/4）、B 切 4 段（16→4×4）、C 不切（4）**，全部 4 cycles → 100%，共 7 級。
- (c) B 變動延遲（input=1→16cyc, 0→4cyc），序列 1010 畫 pipeline diagram。**Ans：會 stall，需畫出氣泡**。
- (d) 如何防 stall？**Ans：加 FIFO 緩衝 / 複製 B 硬體**，給合理方法 + block diagram。

官方解答 pipeline diagram（(a) utilization、(b) 切法、(c) stall）：

<img src="images/ans_2025_q1_pipeline.png" width="760">

**Q2 Timing path a~e（10%）** — 由 timing report 畫 reg-to-reg 五段。

<img src="images/2025_q2_report_fig.png" width="560">

**Ans：a=0.15（launch clk network）、b=0.12（CK→Q）、c=0.07（組合邏輯）、d=0.18（capture clk network）、e=0.04（library setup time）**。

**Q3 Microcode FSM（10%）**

<img src="images/2025_q3_fsm.png" width="700">

- (a) 列 ROM 內容，**address = {Q1,Q2,Q3,X}（4-bit）→ data = {Q1⁺,Q2⁺,Q3⁺,Z}**：

  | Addr | Data | Addr | Data |
  |------|------|------|------|
  | 0000 | 1001 | 1000 | 1111 |
  | 0001 | 1010 | 1001 | 1100 |
  | 0010 | xxxx | 1010 | 1100 |
  | 0011 | xxxx | 1011 | 1101 |
  | 0100 | 0001 | 1100 | 0111 |
  | 0101 | xxxx | 1101 | 0100 |
  | 0110 | 0000 | 1110 | 0110 |
  | 0111 | 0001 | 1111 | 0111 |

  （需完整列 16 條；標 x 的三條可不寫。address/data 未標 bit 排列方式會扣分。）
- (b) state/input 增加時 memory 變大，提兩種縮法。**Ans：①把 state 與 output 分開存；②用 instruction + program counter 取代 state 列舉**（每法 2 分）。

**Q4 Memory usage（10%）** — 基本 1K×8 SRAM。
- (a) 組 1K×32：**4 顆並聯，同 address A[9:0]，輸出拼成 32-bit**。
- (b) 組 4K×8：**4 顆，A[9:0] 進每顆，用 A[11:10] 在輸出端 MUX 選 bank**。
- (c) 組 2K×8 雙 port（一讀一寫/兩讀/兩寫，兩 port 不同 address space）：**用兩塊 1K×8，依 address MSB 用 MUX 把每個 port 路由到對應 bank**；因兩 port 不會同時打同一 bank → 無衝突。需 MUX 路由 address/data + 讀資料 MUX 回兩 port。

官方解答 (a)(b) 與 (c) block diagram：

<img src="images/ans_2025_q4_sram_ab.png" width="620">

<img src="images/ans_2025_q4_sram_c.png" width="700">

**Q5 Metastability & Synchronizer（10%）** — 見上「知識點 G」。
- (a) metastability 定義（取樣違反 setup/hold → 不穩定態，需不定時間 resolve）。
- (b) 2-FF 為何有效（給將近一 cycle resolve，第二級取到穩定值，提升 MTBF）。
- (c) Gray code 為何適合多 bit 跨域（相鄰只變 1 bit，避免多 bit 同變的錯誤中間值）。

**Q6 Jerry SystemVerilog（12%）** — 八個 8-bit 輸入分兩組各 4 個相加再相乘；4ns clock，slack=0.01。

block diagram 與 timing report：

<img src="images/2025_q6_block_report.png" width="620">

- (a) slack 0.01 → 最小週期是 3.99ns 嗎？**Ans：不能（不對）**。合成在更緊 constraint 下會換不同硬體/架構，最小週期通常**還能更低**，不能直接用 4−0.01 推；且 slack>0 幾乎必有優化空間（不接受「小數點精確度」鑽牛角尖式回答）。
- (b) 在 stage0↔stage1 的 adder tree 插 pipeline 能降週期嗎？**Ans：不能**。**critical path 在 s1→s2（乘法器）之間，不在 s0→s1**，縮 s0→s1 無效。
- (c) reset 測試 task 的問題？**Ans：應用 `!==` 而非 `!=`**。`!=` 無法偵測 unknown（X）；訊號為 X 時會偵測不到錯誤。

  <img src="images/2025_q6c_task.png" width="600">

- (d) 加 in_mode 做 circular shift，Tom vs Jerry 哪個面積小？

  <img src="images/2025_q6d_tomjerry.png" width="760">**Ans：Tom 較小**。Jerry 在 4 種 mode 各開一套加法硬體（4 套）；Tom 先用 MUX 選資料、只保留一套加法器 → 面積較小。（參考面積 Tom≈25181、Jerry≈32941）

**Q7 Pipeline（12%）** — CL1~4 delay=3/5/7/1 ns，setup=1ns、hold=0，A/B/C 三插點。

<img src="images/2025_q7_pipeline.png" width="720">
- (a) 最佳插點？**Ans：B**（cycle time 最小、throughput 最大）。各方案最低 cycle time（含 setup 1ns）：
  - 切 A：max(3, 5+7+1)+1 = **14ns**
  - 切 B：max(3+5, 7+1)+1 = **9ns** ✅ 最平衡
  - 切 C：max(3+5+7, 1)+1 = **16ns**
- (b) (a) 後最短 cycle time？**Ans：9ns**（兩段各 8ns 邏輯 + 1ns setup = 9ns）。
- (c) pipeline 前/後 throughput？
  - 前：cycle = 3+5+7+1 + 1(setup) = **17ns** → throughput = 1/17ns ≈ **58.82 MOPS**
  - 後：cycle = **9ns** → throughput = 1/9ns ≈ **111.11 MOPS**
- (d) latency 會變短嗎？**Ans：不會**。latency 是輸出總時間，pipeline 後 latency 反而**增加或不變**（級數×cycle time）。
- (e) 能否再加一個 register 進一步提升 throughput？**Ans：不能**。切 B 後**兩段都是 8ns（兩個並列 critical path）**，且 CL3=7ns 為不可分割的單一 block；再把 register 擺 A 或 C 只能切開其中一段，另一段 8ns 仍在 → cycle time 卡在 9ns 無法下降。

**Q8 Waveform（14%）** — FSM：IDLE/DIN/COM1/COM2/OUT，out_num 在 COM1 做 +2、COM2 做 >>1，in_reg 有號。

題目 Pattern（左）+ Design（右）與要填的空白格：

<img src="images/2025_q8_code.png" width="760">

<img src="images/2025_q8_wave_grid.png" width="700">

**Ans 波形（10 cycle）**：

| cycle | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|-------|---|---|---|---|---|---|---|---|---|----|
| in_num | 0 | 8 | 5 | 0 | 0 | 2 | 0 | 0 | 0 | 0 |
| out_num | x | 0 | 8 | 5 | 7 | 5 | — | 2 | — | — |
| cs | x | 0 | 1 | 2 | 4 | 0 | 1 | 4 | 0 | — |
| in_reg | x | 0 | −8 | — | 5 | — | — | 2 | — | — |

官方解答波形：

<img src="images/ans_2025_q8_wave.png" width="700">

（評分每訊號 2 分。常見扣分：in_reg=−8 寫成 output 錯/晚一 cycle；out_valid 高的 cycle 沒對；第二筆 input 跳錯導致輸出錯；reset 在 posedge 變動。）

**Q9 Setup/Hold（12%）** — DFF A：t_setup=30, t_hold=35, t_ccq=10, t_pcq=20（ps），2GHz（T_c=500ps）。Logic A/B/C：tc=10/100/30, td=400/200/50 ps。

<img src="images/2025_q9_setuphold.png" width="640">
- (a) 有無 violation？**Ans：Hold violation @ A→X**。`t_hold ≤ t_ccq + t_cd` → `35 ≤ 10 + 10 = 20` **違反**。（Setup：T_c=500 ≥ 20+400+30=450 OK，無 setup violation。）
- (b) 如何解？**Ans：在 Logic A 加 15ps delay**，使 `35 ≤ 10 + (10+15)=35` 成立。（沒寫不等式 / 解法錯 / 數字錯 扣 2 分。）
- (c) 重檢、能否更快？**Ans：加 15ps 後 setup：`T_c ≥ t_pcq + t_pd + t_setup + 15 = 20+400+30+15 = 465ps`** → 最快 ≈465ps（>2GHz，約 2.15GHz）。

---

# 四、考前衝刺重點（最容易考 & 最容易錯）

1. **Setup/Hold 公式方向別記反**：setup 決定**最快 clock**（`T_c ≥ t_pcq+t_pd+t_setup`）；hold 與 clock 無關（`t_ccq+t_cd ≥ t_hold`），違反就在**最短路徑**加 delay。
2. **Pipeline latency 不會變短**——只提升 throughput；考題每年都問，標準答案一律「不變或變長」。
3. **切 register = 平衡各 stage**，cycle time = 最長段 + setup。
4. **slack≠最小週期−slack**：最小週期要重新合成，通常更低。
5. **Waveform**：cs 在 posedge 更新（=上一 ns）、非同步 reset、有號數用 2's complement、`repeat(n)` 要展開、輸出比輸入晚一級。
6. **SRAM**：加寬=並聯拼接、加深=高位選 bank、多 port=分 bank+MUX。
7. **CDC**：2-FF synchronizer 原理、Gray code 只變 1 bit、metastability 定義。
8. **Microcode**：address={state,input}、data={next state,output}；縮 memory=分存 output / 用 PC+instruction。
9. **Verilog 驗證細節**：比較含 X 要用 `===`/`!==`，不可用 `==`/`!=`。
10. **面積比較**：用 MUX 提前選資料（共用一套運算）比每個 mode 各開一套硬體小。

---
*整理時間：2026-06-08*
