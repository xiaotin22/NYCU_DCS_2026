# NYCU DCS 2026

This repo is for **114 Spring NYCU Digital Circuit and System** (張添烜教授), including Lab, Exam, OT, homework, and the Final Project.  
主要程式碼以 **SystemVerilog** 撰寫，題目 PDF、testbench、report 與 RTL implementation 都整理在各資料夾中。

> 📌 Performance / rank 資料以修課總人數 **141 人** 為基準。

## 📂 Project Index

| Folder | Main RTL | Topic | Performance Formula |
|---|---|---|---|
| `HW01` | `ComplexCalc.sv` | Complex number calculator + seven-segment display | `area` |
| `HW02` | `SOBEL.sv` | Sobel edge detector | `latency * area` |
| `HW03` | `ECTRL.sv` | Multi-elevator controller | `latency * area * area` |
| `HW04` | `MHA.sv` | Multi-Head Attention accelerator | `clk * latency * area * area` |
| `HW05` | `CPU.sv` | Fixed-point in-order CPU | `clk * clk * latency * latency * area` |
| `OT` | `GE.sv` | 3x3 linear equation solver | `latency * area * area` |
| `Final Project` | `CA.sv` | Conformer Accelerator | `clk * latency * area` |

## 🧮 HW01 - `ComplexCalc.sv`

`ComplexCalc.sv` 是複數計算器。輸入資料使用 BCD 格式表示複數的 real / imaginary part，電路會先檢查 BCD 是否合法，再計算 complex norm、依照 norm 排序，最後根據 opcode 執行指定的複數運算。

輸出端會把運算結果轉成七段顯示器格式，因此這份作業重點包含 BCD checking、複數運算、排序邏輯與 display encoding。

**Performance**  
計算方式：`area`

| HW01 | AREA | PERFORMANCE | RANK | Perf Score (30%) |
|---|---:|---:|---:|---:|
| `MY Code` | 27076.89 | 27076.89 | 32 | 23.36 |
| `BEST Code` | 14805.80 | 14805.80 | 1 | 30.00 |

## 🖼️ HW02 - `SOBEL.sv`

`SOBEL.sv` 是 Sobel edge detector。輸入影像資料以 streaming 方式進入，電路用 line buffer / sliding window 保存鄰近 pixel，計算 `Gx`、`Gy` 與 gradient magnitude。

最後依照 threshold 將結果二值化輸出，用來判斷影像中的 edge。這份作業主要練習 streaming datapath、buffer 控制與即時計算。

**Performance**  
計算方式：`latency * area`

| HW02 | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (35%) |
|---|---:|---:|---:|---:|---:|
| `MY Code` | 68921 | 25397.06 | 1.75E+09 | 23 | 29.50 |
| `BEST Code` | 68921 | 19871.91 | 1.37E+09 | 1 | 35.00 |

## 🛗 HW_03 - `ECTRL.sv`

`ECTRL.sv` 是三台電梯的控制器。系統會接收 hall request、car request、open / close button 與 passenger count，並輸出每台電梯目前樓層、狀態、服務方向與滿載旗標。

設計上包含 request allocation、各電梯獨立 FSM，以及滿載時的服務限制。主要目標是讓多台電梯能依照請求與方向合理移動並開關門。

**Performance**  
計算方式：`latency * area * area`

| HW03 | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (30%) |
|---|---:|---:|---:|---:|---:|
| `MY Code` | 1308564 | 5977.54 | 4.68E+13 | 16 | 26.79 |
| `BEST Code` | 1267447 | 3678.67 | 1.71E+13 | 1 | 30.00 |

## 🧠 HW04 - `MHA.sv`

`MHA.sv` 是 Multi-Head Attention 計算模組。電路會載入 Q、K、V matrix，計算 attention score，再與 V 相乘得到輸出矩陣。

此設計使用 pipeline 拆開 score 計算與 output accumulation，降低 critical path，同時支援不同 mode 下的 attention 行為。本次作業可以自行調整 `clk period`，因此 performance 會同時受到 clock、latency 與 area 影響。

**Performance**  
計算方式：`clk * latency * area * area`

| HW04 | CLK(ns) | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (30%) |
|---|---:|---:|---:|---:|---:|---:|
| `MY Code` | 3.4 | 266000 | 173175.71 | 2.71E+16 | 8 | 28.50 |
| `BEST Code` | 2.7 | 280088 | 156061.38 | 1.84E+16 | 1 | 30.00 |

## 🧩 HW05 - `CPU.sv`

`CPU.sv` 是簡化版 in-order CPU。它支援 MIPS-like instruction encoding、六個 16-bit Q1.15 fixed-point register，以及 ADD、ADDI、OR、ORI、MULT、DIV、SLA、SRA 等指令。

架構上使用 FIFO issue、hazard / pending register tracking，以及 MULT / DIV pipeline。輸出會回報 register file 狀態與 invalid instruction、divide-by-zero 等例外狀況。

**Performance**  
計算方式：`clk * clk * latency * latency * area`

| HW05 | CLK(ns) | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (30%) |
|---|---:|---:|---:|---:|---:|---:|
| `MY Code` | 4.5 | 5526 | 198496.26 | 1.23E+14 | 28 | 24.21 |
| `BEST Code` | 3.6 | 5940 | 114285.12 | 5.23E+13 | 1 | 30.00 |

## ✏️ OT - `GE.sv`

`GE.sv` 是 3x3 線性方程組求解器。輸入三條 packed equation，電路會判斷方程組屬於 unique solution、infinite solutions 或 no solution，並在 unique solution 時輸出 `x1/x2/x3`。

設計上使用 `S_LOAD -> S_OUT` 的簡單 FSM，核心計算包含消去、determinant、modular inverse / shift-based division 等邏輯。Pattern 預設為 1000 筆測資，clock time 固定為 20.0 ns 不可更改。

註：OT 為實體上機考，不可使用 AI。1DE 目標是在三小時內完成並拿滿分；2DE 則以 performance 排名計分。

**Performance**  
計算方式：`latency * area * area`

| OT | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (20%) |
|---|---:|---:|---:|---:|---:|
| `MY Code` | 1000 | 45288.94 | 2.05E+12 | 1 | 20.00 |
| `BEST Code` | 1000 | 45288.94 | 2.05E+12 | 1 | 20.00 |

## 🚀 Final Project - `CA.sv`

`CA.sv` 是 Conformer Accelerator。它會從 RAM 讀取 8x8 signed 4-bit matrix，依照 `op` 執行 FFN、Conv、SHA 或 MHA，接著套用 activation 與 PoT quantization，再寫回 RAM 並輸出最後一列結果。

主要架構分成 `CA_Control` 與 `CA_DataPath`。Control 負責 RAM burst read/write、operation scheduling 與 result timing；DataPath 負責 streaming computation，包括 Q/K/V projection、score stage、final accumulation、activation 與 quantization。

Final Project 的重點是同時平衡 clock、latency 與 area。硬體共用可以降低 area，但可能拉高 latency；pipeline 可以改善 timing，但也會增加 register 與 control cost。

**Performance**  
計算方式：`clk * latency * area`

| Final Project | CLK(ns) | LATENCY | AREA | PERFORMANCE | RANK | Perf Score (25%) |
|---|---:|---:|---:|---:|---:|---:|
| `MY Code` | 3.0 | 38020 | 11238927.81 | 1.28E+12 | 4 | 24.46 |
| `BEST Code` | 3.4 | 35369 | 7905053.31 | 9.51E+11 | 1 | 25.00 |
