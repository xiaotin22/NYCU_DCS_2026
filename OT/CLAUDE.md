# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案

NYCU DCS 課程 "OT"（open take-home）：以 SystemVerilog 設計一個 3×3 線性方程組求解器（top module `GE`，定義在 [GE.sv](GE.sv)），同時分類 unique / infinite / no solution 三種狀況。設計目標是 **面積最小、Clk×Latency 越小越好**，所以微架構決策永遠要對著合成報告（area / timing）。

## 工作站 vs 本地

CAD 全部都要在工作站 `ssh dcs_mimi` 上跑（VCS / Verdi / Design Compiler 都在那）。本地的 `OT/` 目錄是個 **扁平鏡像**，只追蹤關鍵檔（`GE.sv`、`PATTERN.sv`、`TESTBED.sv`、`Makefile`、`filelist.f`、`equations.txt`、`answers.txt`、`readable.txt`）。**真正的目錄結構在工作站 `~/OT/`**，下面所有路徑都假設你在工作站。

### 工作站目錄佈局

```
~/OT/
├── 00_TESTBED/      # PATTERN.sv、TESTBED.sv、Makefile、filelist.f、equations.txt、answers.txt、readable.txt
├── 01_RTL/          # GE.sv（DUT 本體）+ helper scripts，Makefile/PATTERN.sv/TESTBED.sv/filelist.f 都是 symlink 回 00_TESTBED/
├── 02_SYN/          # syn.tcl、Report/、Netlist/、helper scripts；GE.sv 是 symlink 回 01_RTL/
├── 03_GATE/         # GE_SYN.v、GE_SYN.sdf 都是 symlink 回 02_SYN/Netlist/
└── 09_UPLOAD/       # 繳交腳本；GE.sv 是 symlink 回 01_RTL/
```

**改 RTL 就只改 `01_RTL/GE.sv`**——其他目錄看到的 `GE.sv` 是 symlink。

### Helper script 慣例（每個子目錄都有）

| 編號 | 功能 |
|---|---|
| `01_run_*` | 觸發該階段的主要工具（呼叫 `make`） |
| `02_*`、`03_*` | 其他模擬器（irun / xrun）或 debug GUI |
| `04_verdi`、`05_nWave` | 開波形 debugger |
| `08_check*` / `08_check_design` | 跑完後檢查 log、抽 Latency/Cycle/Area，印彩色 PASS/FAIL |
| `09_clean_up` | `make clean` |

最常用：`cd 01_RTL && ./08_check_design`（會自己先 clean → run vcs_rtl → grep 結果）。

### 從遠端非互動跑工作站指令（會踩雷）

login shell 是 **tcsh**，且必須跨「`yes` 關卡」才會載入 CAD 的 PATH / `LM_LICENSE_FILE`。標準範本：

```sh
ssh dcs_mimi << 'REMOTE'
yes
bash -c 'cd ~/OT/01_RTL && ./08_check_design'
exit
REMOTE
```

- 沒打 `yes` → `vcs: Command not found` / license 沒授權。
- tcsh 不支援 `2>&1` / `2>/dev/null` → 需要 bash 重導向就用 `bash -c '...'` 包起來。
- 長任務（合成 ~1hr）要斷線韌性：過 `yes` 後 `setsid bash <script> > log 2>&1 < /dev/null &`。掃 corner 前務必 `rm -f syn.log`，否則合成失敗會抽到上一輪殘留值。

## 常用指令

| 指令 | 在哪 | 做什麼 |
|---|---|---|
| `./08_check_design` | `01_RTL/` | RTL sim（VCS）+ 自動判 PASS/FAIL + 印 Latency 與 Cycle |
| `./01_run_vcs_rtl` | `01_RTL/` | 只跑 VCS RTL sim（保留所有 log） |
| `./04_verdi` / `./05_nWave` | `01_RTL/` 或 `03_GATE/` | 開波形（FSDB 在 `GE.fsdb` / `GE_SYN.fsdb`） |
| `./01_run_dc` | `02_SYN/` | 跑 Design Compiler（讀 `syn.tcl`，產 `Netlist/GE_SYN.v` + `.sdf` + `.sdc`） |
| `./08_check` | `02_SYN/` | 檢查 syn.log（Latch / Width Mismatch / Error / Timing violated）並印 **Cycle / Area / Gate count / Power** |
| `./08_check` | `03_GATE/` | Gate-level sim with SDF |
| `./09_clean_up` | 任一階段 | `make clean` |

縮短 debug 用 sim：改 [PATTERN.sv:1-3](PATTERN.sv) 的 `` `define PAT_NUM `` / `` `define CYCLE_TIME `` / `` `define RAND_SEED ``，預設 `PAT_NUM=1000`、`CYCLE_TIME=20.0 ns`、`RAND_SEED=54243`。

## 合成設定（02_SYN/syn.tcl）

關鍵點（要改 clock 就改這裡）：

- `set CYCLE 20.0`（ns），input/output delay 各 `0.5 * CYCLE`。
- `compile_ultra`，沒呼 `compile`/`uniquify`。
- DRC：`set_max_transition 3`、`set_max_capacitance 0.15`、`set_max_fanout 10`（UMC 180nm LUT 上限）。
- `set_clock_uncertainty 0.1`、`set_input_transition 0.5`。
- `set_load 0.05 [all_outputs]`。
- 報告全寫到 `Report/GE.{check,design,resource,timing,area,power,clock,port}`，netlist 寫到 `Netlist/GE_SYN.{v,sdf,sdc}` + `GE_SYN.ddc`。
- 結尾才 `report_area` / `report_timing` 印到 stdout / `syn.log`。

效能指標換算（在 `02_SYN/08_check` 內）：
- **Cycle** 從 `Report/GE.timing` 抽（`clock clk (rise edge)` 第 4 個數字）。
- **Area** 從 `Report/GE.area` 的 `Total cell area:` 抽。
- **Gate count = Area ÷ 9.9792**（UMC180 NAND2 標準面積；越低代表設計越精簡）。

## DUT 介面與通訊協定

`GE` 是固定 valid-only 協定：

- **輸入**（`in_valid` 高 1 個 cycle）：`in_data_eq{0,1,2}` 每筆 16 bits，封裝 `{b[6:0], a2[2:0], a1[2:0], a0[2:0]}`，全部 signed。PATTERN 用 `%d` 從 `equations.txt` 讀 4 個整數再拼起來（[PATTERN.sv:173-189](PATTERN.sv)）。
- **輸出**：`out_data{0,1,2}` 是 signed 6-bit 的 `x0/x1/x2`；`exception[1:0]` 分類解的型態。
- **PATTERN 規則**（違反就 FAIL，[PATTERN.sv:95-124](PATTERN.sv)、[PATTERN.sv:259-269](PATTERN.sv)）：
  - `out_valid` 不可與 `in_valid` 同時拉高。
  - `out_valid` 低時，`out_data*` 與 `exception` 都必須是 0（每個 cycle 都檢查，不只是 reset）。
  - `out_valid` 必須剛好 1 cycle 高。
  - **Latency ≤ 50 cycles**（從 `in_valid` 上升到 `out_valid` 上升）。

### Exception 編碼（兩邊必須對齊）

| `exception` | 意義 | [answers.txt](answers.txt) 的標記 |
|---|---|---|
| `2'b00` | Unique integer solution | 三個 signed 整數 |
| `2'b01` | Infinite solutions | `9999` |
| `2'b10` | No solution | `9998` |

PATTERN 對應在 [PATTERN.sv:208-222](PATTERN.sv)；`GE` 用 localparam `E_UNIQUE / E_INF_SOL / E_NO_SOL`（[GE.sv:33-35](GE.sv)）。Exception ≠ UNIQUE 時 `out_data*` 必須是 0。

Unique 解的 `x_i` 會被 **截到 6 bits**（`result_x*[5:0]`）—— 測資保證 |x_i| ≤ 31，但任何超寬度都會悄悄 wrap。

## 目前實作（GE.sv）

兩態 FSM（`S_IDLE → S_OUT`，1 cycle latency）跑全 combinational Cramer's rule：

- 12 個 signed-32 register（`aXY` / `bX`）從 `in_data_eqN` 做 sign-extend slice 寫入。
- 4 個 3×3 行列式 `det_a`、`det_x{0,1,2}` 用 automatic function `det3`/`det2` 全 combinational 算（[GE.sv:56-86](GE.sv)）。
- Rank 分類 exception：`coeff_rank{1,2}` / `aug_rank{1,2,3}` 用 2×2 / 3×3 行列式比 `rank(A)` vs `rank([A|b])`。
- `result_x* = det_x* / det_a` —— 合成出來的 signed divider 通常是面積最大的單一 cell。

**面積/時序熱點**（依優先順序）：

1. **四個 `det3` 各自展開 9 個 signed 32-bit 乘法器**（3 次 `det2` call）→ 把 datapath 收成「一組 `det2`/`det3` 跨多 cycle 共用」是最大的面積贏面。
2. **`aug_rank2` / `coeff_rank2` 大 OR-tree** 評估 9–18 個 2×2 行列式 → 一旦有非零就可以早結束，目前是平行全跑。
3. **單 cycle signed divide** 在 unique 路徑上 → pipeline `S_OUT` 或改成 shift-add，可以換 latency 省面積。
4. **register width 過寬**：register 用 32-bit 但輸入只需要 ~4 bit 的 a、8 bit 的 b → 在 determinant 之前就把寬度縮窄，乘法器面積會直線下降。

每次微架構改完都要 `01_RTL/08_check_design` → `02_SYN/01_run_dc` → `02_SYN/08_check` → `03_GATE/08_check` 一整輪，確認 RTL/Gate 都過、timing met、area 確實下降。

## 命名與風格

- State register 用 `_cs` / `_ns`（current/next state），**不要**改成 `_q`/`_d`。
- 算術寬度在 determinant 層一律 32-bit signed，跨乘法要用 `$signed(...)` 強迫號別。
- 註解保持最少，識別字以英文為主（與既有程式碼一致）。
