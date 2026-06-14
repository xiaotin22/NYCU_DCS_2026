# AI uselog 

> 分析一下目前CA.sv的架構 x_mem的存入能否用stream in stream out 排程呢，可以不用開到32個input buff吧

<details><summary>10 previous messages</summary>

> 我先把 `CA.sv` 和周邊檔案脈絡讀一下，特別看 `x_mem`、input buffer、排程狀態機怎麼接在一起，再回頭判斷能不能改成 stream in / stream out 的資料流。
>
> 目前找到 `DCS_FINAL\CA.sv`，另外有 `CA_TA.sv` 和 `ca_snapshot_prev.sv` 可當對照。剛才平行查詢有兩個 sandbox 程序啟動失敗，我改成逐個讀，先把主檔和關鍵訊號抓出來。
>
> `CA.sv` 已經有一版很明顯在朝「prefetch + 重用 x_mem」走，註解也寫了 x_mem 在 QKV issue 後可釋放。我現在看實際資料相依性：哪些 phase 真的會回頭讀 `x_mem`，哪些結果必須常駐在 Q/K/V/score memory。
>
> 重點輪廓已經出來了：目前不是 32 個「input buff」排隊等算，而是 32 個 256-bit 的 `x_mem` slot，拿來把一個 group 的 RAM burst 暫存住，然後 Q/K/V 三路同時對同一筆 X 做乘法。接下來我看 `Multiple_Processor` 裡每個 issue cycle 需要幾筆 X、是否有跨 cycle 回讀，這會決定能縮到多小。
>
> 這裡確認了：QKV phase `i` 同一 cycle 要把 `x_mem[i]` 同時送 engine0/1/2 產生 Q/K/V，之後 SV/FINAL 都只看 `q_mem/k_mem/v_mem/score_mem`，不再需要 X。也就是 X 的生命週期只到 32 個 QKV issue cycle 結束。
>
> `Multiple_Processor` 本身只有 1-cycle issue mux 加 multiplier pipeline，沒有會暫存整個 X group 的隱性需求；`x_mem` 是為了「先把 32 筆 RAM 回傳吃完，再用 32 cycle 連續 issue QKV」這個排程而存在。現在問題轉成：RAM 的 50-cycle latency 與 burst 回傳型態，能不能直接拿 `rd_valid/rd_data` 當 QKV issue stream。
>
> 我還需要確認 testbench RAM 的 handshake 形狀，因為「stream in」能不能成立的關鍵不是算術單元，而是 `rd_valid` 回來時能不能保證連續 32 拍，並且 write/read command 不會撞。
>
> RAM 本體是 protected，不過 repo 裡的規格筆記有接口約束：讀命令在 `rd_ready` 時送，資料 50 cycles 後 `rd_valid` 回來，burst 長度是 `2**burst`。這足夠支持「回傳串流連續 beat」的推論，但要看改排程後會犧牲多少 latency hiding。
>
> 我也會對照一下先前 snapshot/report，因為看起來這份 `CA.sv` 是從 group-4 一路推到 group-32 的版本；舊版可能有較小 x buffer 的設計理由，可以幫你判斷現在是不是「過度展開」。
>
> 我會把結論講成「可行，但要改的是排程而不是單純刪陣列」。因為 current design 的 32-slot `x_mem` 其實是在買 timing slack：讓 RAM 可以早回來、先收著，等 multiplier engine 空了再連續餵 QKV。
</details>

短答：**可以改成 stream in / stream out，而且 X 確實不一定要開到 32 個 256-bit buffer**。但以目前 [CA.sv](<./DCS_FINAL/CA.sv:695>) 的排程，不能直接刪 `x_mem[0:31]`，因為現在是「早 prefetch、晚使用」：下一組 X 在 current group 還在 SV/FINAL 時計回來，所以一定要有地方收。

目前架構是：

- `CA_Control` 管 FSM：`S_HA_PARAM -> S_HA_READ -> S_HA_ISSUE -> S_HA_WAIT`
- attention 用 group-32，`BURST_GRP = 3'd5`
- `S_HA_READ` 先把 32 筆 RAM data 存進 `x_mem`
- `ST_QKV` 再連續 32 cycles issue，`Multiple_Processor` 同一拍用 `x_mem[i]` 同時算 Q/K/V
- QKV 之後，SV/FINAL 都只讀 `q_mem/k_mem/v_mem/score_mem`，**不再讀 X**

所以 X 的生命週期其實很短：**每筆 X 只在 QKV issue 那一拍用一次**。這表示 stream-in 是合理的。

可行改法會是：

1. 新增一種 QKV stream issue 路徑
   例如 `IM_QKV_STREAM`，讓 `Multiple_Processor` 在 QKV 時用 `rd_data_cs` 當 `A`，不要用 `x_mem[issue_idx]`。

2. `rd_valid` 回來時直接 issue QKV
   用 `rd_valid` 當 `issue_valid`，`stream_cnt` 當 `issue_idx`，連續吃 32 beats。

3. prefetch 時間要改晚、改準
   現在 [ha_prefetch_fire](<./DCS_FINAL/CA.sv:265>) 在 `ST_QKV` 就可能發，資料會太早回來。若不要 32-slot buffer，就要讓 RAM return 剛好對齊下一組 QKV engine 空出來的時間。
   依目前常數大概是：
   - SHA：next group start = FINAL start + 35，所以 read cmd 約在 FINAL start - 15，也就是 SV 早期發
   - MHA：next group start = FINAL start + 67，所以 read cmd 約在 FINAL start + 17 發

4. 最好留一個小 skid FIFO
   完全 0-buffer 對 RAM latency / `rd_ready` 對齊很敏感。比較穩的是 2 到 4 entries 的 `x_fifo`，不是 32 entries。這樣若 `rd_valid` 早一兩拍或 QKV start 有 off-by-one，也不會整個爆掉。

`stream out` 這邊目前其實已經接近 stream：`result_valid` 直接更新 `wr_data/out_data`，control 用 `ha_wr_fire` 發 `BURST_GRP` write，不是先收滿 32 筆 output buffer。

我的判斷：**若目標是省 area，值得改；若目標是最小風險，保留 `x_mem[32]` 是目前排程最穩。** 最推薦的折衷是把 `x_mem[32]` 改成「QKV stream + 小 FIFO」，可以省掉大部分 X buffer，又不用把 timing 對齊壓到太硬。

> RAM latency / rd_ready 對齊這個都很準不用擔心，把時序算準一定可以 ，可以試試看把x_mem直接沖刷掉

<details><summary>51 previous messages</summary>

> 我會用 `brainstorming` 先把這個改法的資料流和必要對齊點釘住，然後直接動 `CA.sv` 試一版。這次核心會是把 `x_mem` 的「capture 再 issue」改成「rd_valid 回來直接 QKV issue」。
>
> 設計我採你說的硬切版：不再用 32-slot `x_mem` 收下一組，RAM burst 回來那 32 拍直接 issue QKV；下一組 read command 用固定 latency 反推到剛好在下一組 QKV start 前 50 拍發出。先做小範圍 RTL 改動，然後跑 syntax/sim 看對齊有沒有 off-by-one。
>
> 工作樹目前是乾淨的。`CA.sv` 裡 `x_mem` 只有 QKV reader，且 control 的 `qkv_ready/sv_ready` 已不參與轉態，所以這版可以把 QKV start 改成由 read stream 驅動，不會牽一堆回報 barrier。
>
> 我準備改三塊：control 的 `S_HA_READ` 變成 QKV stream issue、prefetch command 從「早收進 x_mem」改成「50-cycle 對齊 next-group start」、datapath/multiplier 移除 `x_mem` port 並讓 `IM_QKV` 直接吃 registered `rd_data`。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+10 -16)
>
> </details>
>
> 先把 top-level 到 datapath 的 capture 線切掉了；接下來改 control 狀態機本體，讓 `rd_valid` 就是 QKV issue beat。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+5 -7)
>
> </details>
>
> 接下來是最容易 off-by-one 的地方：SHA read command 會放在 SV phase 2；MHA read command 會放在 FINAL timer count 17。這兩個點各自距離原本 `ha_next_group_fire` 正好 50 cycles。
>
> 現在把舊的 `ha_pf_done/ha_pf_capture` 拿掉，換成 `ha_qkv_stream_fire`。這個 fire 代表「這拍 rd_data 會在下一拍進 multiplier issue buffer」。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+43 -40)
>
> </details>
>
> 這段還有舊 capture 邏輯殘留，我用較窄的 patch 直接替掉 always_comb，避免跟亂碼註解對不上。
>
> 我把 patch 拆小，先處理 ASCII 穩定的行，再替換各 state 的內容。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+3 -5)
>
> </details>
>
> `S_HA_READ` 會改成看到 `rd_valid` 就發 `IM_QKV`，index 直接用 stream beat counter。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+7 -6)
>
> </details>
>
> `S_HA_WAIT` 則只在 safe-start 那拍吃第一個 beat；如果資料沒同拍到，就轉進 `S_HA_READ` 等後續回來。
>
> 這行註解編碼讓 patch 對不上，我只用 `S_HA_WAIT: begin` 這個穩定錨點插入。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+6 -1)
>
> </details>
>
> 最後把 always_comb 尾端的「prefetch capture 寫 x_mem」刪掉，避免還引用舊訊號。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+1 -7)
>
> </details>
>
> 現在開始處理 sequential 狀態更新：read command 發出就標記 pending，32 個 stream beat 吃完就清 pending，然後從 QKV stream 直接跳到 SV issue。
>
> `ha_pf_word_cs/ha_pf_done_cs` 已經不需要；`ha_prefetch_pending_cs` 之後只表示「有一個 read stream 尚未吃完」。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+4 -6)
>
> </details>
>
> 現在替換舊的「prefetched burst 寫 x_mem」區塊：read fire 設 pending，stream 最後一拍清 pending。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+7 -18)
>
> </details>
>
> 注意到同一拍 `S_HA_PARAM` 會覆蓋前面的 pending set，所以這裡要讓第二個 param 若同拍發 read command，就保留 pending。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+6 -8)
>
> </details>
>
> `S_HA_READ` 之後不再等「收滿再算」，而是每個 `rd_valid` beat 直接推進 QKV stream counter；第 32 拍結束後立刻進 SV。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+13 -21)
>
> </details>
>
> `S_HA_WAIT` 會在 next-group safe point 更新 base，若第一個 `rd_valid` 同拍到就先吃 idx0，後面 31 拍由 `S_HA_READ` 接著吃。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+9 -15)
>
> </details>
>
> Control 內舊的 prefetch/capture 訊號已清掉；剩下的是 datapath/multiplier 的 `x_mem` storage 和 port，現在開始拔掉。
>
> `CA_DataPath` 入口 buffer 留 `issue_*` 和 `rd_data_cs` 就好，capture buffer 相關暫存全刪。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+9 -14)
> - Wrote `./DCS_FINAL/CA.sv` (+3 -4)
>
> </details>
>
> 現在把 always_ff 裡對 capture reg 的 reset/update 和 `x_mem[...] <= rd_data` 寫入刪掉，這就是實際省掉 32 個大 slot 的地方。
>
> 同樣遇到註解編碼錨點問題，我分別刪 reset/update 與 `x_mem` 寫入。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+8 -12)
>
> </details>
>
> `x_mem` 寫入區塊用純程式碼錨點刪掉。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -4)
>
> </details>
>
> `Multiple_Processor` 會直接拿 `rd_data` 當 QKV 的 A operand，三個 engine 同拍共用同一筆 RAM beat。
>
> 再拆成穩定單行替換。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -1)
> - Wrote `./DCS_FINAL/CA.sv` (+3 -3)
>
> </details>
>
> `x_mem` 的 storage、write、reader 目前都應該沒了。我掃一次全檔找殘留。
>
> 只剩註解殘留，我順手改掉，避免之後看波形時誤導。
>
> 亂碼區塊不強修，先刪掉 ASCII 的 `x_mem capture` 那行，剩下大段亂碼註解不影響 RTL。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -1)
>
> </details>
>
> 這版比較 aggressive：第一組 latency 會直接省掉原本「收滿 32 拍再 QKV」的 32 cycle；後續 group 則靠 SHA phase2 / MHA timer17 對齊，理論上仍能藏住 50-cycle RAM latency。接下來跑語法檢查，看有沒有漏接 port 或訊號殘留。
>
> 先用文字掃描把可能的 port/signals 殘留找出來，再找可用的 simulation script。
>
> 本地沒有明顯的 VCS script，但 repo 提示遠端 `dcs_mimi:Final/01_RTL` 有正式 RTL sim。先快速看本機有沒有 Verilog 工具；沒有就直接同步到遠端跑 VCS。
>
> 本機工具查不到可用 simulator；我改用既有遠端流程，把 `CA.sv` 同步到 `dcs_mimi:Final/01_RTL/CA.sv` 後跑 `make vcs_rtl`。
>
> 已同步到遠端。現在跑 RTL simulation；如果第一輪出現 off-by-one，我會抓 fail 點再調 prefetch phase/count。
</details>

RTL simulation 已經過全部 patterns，execution cycles 顯示 15332。功能上這個 stream 版成立了。下一步我看一下 synth 腳本吃哪份 `CA.sv`，能順手跑 DC 的話就確認 area/timing 變化。

> 先不用跑面積，為何MHA SHA的latency差這麼多，MHA快要是兩倍的SHA

<details><summary>2 previous messages</summary>

> 我先停在功能分析，不跑面積。這個差距主要不是 RAM，也不是 `x_mem` 本身，而是 MHA 在 SV/FINAL 的 issue 數和可輸出點都比 SHA 多一整段 head1 對齊成本。
>
> 我抓了一下剛剛 RTL log 裡的 per-op latency：stream 版目前 SHA 是 742 cycles，MHA 是 1126 cycles，所以倍率約 1.52；差值 384 cycles 剛好是 8 個 group × 每 group 多 48 cycles。這個數字很乾淨，能直接對回排程。
</details>

不是 `x_mem` 造成的，主因是 MHA 的 **SV + FINAL 工作量本來就比 SHA 多**。

目前 stream 版 RTL log：

- `op=2` SHA：`742 cycles`
- `op=3` MHA：`1126 cycles`
- 差值：`384 = 8 groups * 48`

每個 group 的 issue 數大概是：

| stage | SHA | MHA | 差 |
|---|---:|---:|---:|
| QKV | 32 | 32 | 0 |
| SV / score | 16 | 32 | +16 |
| FINAL / context | 32 | 64 | +32 |
| total | 80 | 128 | +48 |

所以 MHA 慢的核心是：

1. **SV 多 16 cycles**
   SHA 在 SV 可以一拍算兩個 matrix：engine0 算 even，engine1 算 odd，所以 32 個 matrix 只要 16 cycles。
   MHA 的 SV 則是 engine0 算 head0、engine1 算 head1，同一個 matrix 的兩個 head，所以 32 個 matrix 還是要 32 cycles。

2. **FINAL 多 32 cycles，這是最大塊**
   FINAL 現在三個 multiplier engine 都被同一個 head 的 `d0/d1/d2` nibble 乘法吃掉。
   所以 MHA 不能 head0/head1 同拍算，只能：
   - head0 final 先算 32 cycles，暫存在 `q_mem/k_mem`
   - head1 final 再算 32 cycles，才跟 head0 combine 後輸出

3. **MHA 第一個有效 output 晚 32 cycles**
   這也反映在 timer 常數：`HA_WR_MHA=43` vs `HA_WR_SHA=11`，`HA_RESTART_MHA=67` vs `HA_RESTART_SHA=35`。
   多出來的 32 就是 MHA FINAL head0 先跑完、head1 才能開始產生可輸出的 combine 結果。

所以結論是：**flush 掉 `x_mem` 省的是兩者共同的 input staging latency；MHA/SHA 差距主要來自 MHA head 序列化，尤其 FINAL。**

如果要再砍 MHA latency，要打 FINAL head0/head1 serial 這件事。最直接但最貴的是多開 final multiplier lanes，讓兩個 head 同時做 `d0/d1/d2`。只改排程、沒有額外算力的話，MHA 很難接近 SHA。

> 現在的qkv不是都是同步算完的嗎，如果input x 用沖刷的， qkv可以用shift的方式嗎? qkv_ready應該可以直接合併吧

<details><summary>1 previous message</summary>

> 我先對一下現在 Q/K/V 三路的 latency 和 ready flag 寫法；這題很像可以再砍掉三組 32-bit ready flags，改成單一路徑的 shift/計數判斷。
</details>

對，你這個判斷是對的，但要分兩層講：

**1. `qkv_ready` 可以合併，甚至可以刪**
現在 Q/K/V 是同一個 `x` 同一拍 issue：

- engine0: `X * Wq`
- engine1: `X * Wk`
- engine2: `X * Wv`

三個 multiplier latency 一樣，三個 PoT lane latency也一樣，所以同一個 index 的 Q/K/V 會同步完成。現在分開的：

```sv
q_ready_cs[31:0]
k_ready_cs[31:0]
v_ready_cs[31:0]
```

其實是舊 barrier 排程留下來的保險。現在 control 已經不等 `qkv_ready/sv_ready` 轉態，所以這三組 ready flag 功能上是 dead logic。最簡單可以直接移掉；如果想保留觀察訊號，一個就夠：

```sv
qkv_done_fire = pot_valid && (pot_tag_cs[4] == MT_Q);
// 更保守：&& pot_k_valid && pot_v_valid
qkv_ready_vec[pot_idx_cs[4][4:0]] <= 1'b1;
qkv_ready = &qkv_ready_vec;
```

**2. QKV 的 valid/index 可以用 shift，但 Q/K/V data 不一定都能 shift 掉**
如果你說的是「ready / valid / index sideband」：可以。因為 input X 已經是 stream，QKV output 也是固定 latency、固定順序，`issue_idx -> output_idx` 可以用 shift/counter 取代三份 ready flag。

但如果你說的是「`q_mem/k_mem/v_mem` 也全部改成 shift FIFO 不開 32 slot」：這就不能直接全刪。原因是後面還需要：

- SV 讀 `q_mem/k_mem`
- FINAL 讀 `v_mem`
- MHA FINAL head0 partial 還借用 `q_mem/k_mem` 當 scratch 做 head0/head1 combine

所以 Q/K/V 的 **ready flags** 可以合併或刪掉，QKV 的 **sideband index** 可以 shift 化；但 Q/K/V 的 **資料 storage** 目前還不能像 `x_mem` 一樣直接沖掉，除非連 SV/FINAL 排程一起改成完全 streaming consumer。

我建議下一刀先做小而穩的版本：刪 `q_ready/k_ready/v_ready`，`qkv_ready` 直接 tie 或移除 port，K/V 的 `pot_k_idx_cs/pot_v_idx_cs` 也可合成單一路徑。這會省一些 FF/ready logic，但不會改 latency。

> 先移除這些冗於邏輯 把控制邏輯寫簡單一點

<details><summary>30 previous messages</summary>

> 我會照剛剛確認的方向動：把 `qkv_ready/sv_ready` 這些已經不參與轉態的回報線和 ready bitmap 拔掉，讓 control 只靠固定排程和 result counter。這一刀不改資料儲存 `q_mem/k_mem/v_mem/score_mem`，只清掉冗餘控制/ready 邏輯。
>
> 先讀目前修改後的相關區塊，避免把還有資料用途的 memory 寫入一起誤刪。
>
> 我會從介面開始拔：top 不再拉 `datapath_qkv_ready/datapath_sv_ready`，`CA_Control` 不再收這兩條，`CA_DataPath` 不再輸出。之後再刪 bitmap FF。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+7 -13)
> - Wrote `./DCS_FINAL/CA.sv` (+4 -6)
> - Wrote `./DCS_FINAL/CA.sv` (+1 -3)
>
> </details>
>
> 介面拔完後，開始清掉 `q_ready/k_ready/v_ready/score_ready` 的宣告、comb next-state 和 FF 寫入。資料 memory 寫入都保留。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -9)
>
> </details>
>
> `ready` 的 comb 區塊現在整段都沒有作用，可以直接改成只有 `result_valid`。
>
> 這段有亂碼註解，patch 錨點不好對，我用純程式碼行分段刪。
>
> 這個 ready block 卡在舊註解編碼，`apply_patch` 對不上。我改用一次性的 regex rewrite，只針對 `always_comb` ready block 到 `assign sv_ready` 這段，不碰資料路徑。
>
> ready block 已經移掉；接下來把 FF reset 和更新裡對 ready flags 的賦值刪掉，只留下 q/k/v/score memory 寫入。
>
> 同樣分小段處理，只用程式碼行做錨點。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -5)
>
> </details>
>
> reset 那組已刪，還剩 QKV group-start clear 和各 ready bit set。這些全是死邏輯。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -4)
> - Wrote `./DCS_FINAL/CA.sv` (+0 -5)
>
> </details>
>
> 我再掃一次；如果留下 empty block 會清掉，讓控制邏輯真的乾淨。
>
> 掃描乾淨了，只剩兩個註解提到 ready，加上一個 empty `if`。我把這些也收掉。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+3 -3)
>
> </details>
>
> 接著清 empty block 和區塊標題。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+2 -6)
>
> </details>
>
> 現在檢查全檔 ready bitmap 相關名詞是否都不見，然後跑 RTL sim。
>
> 訊號名稱已經完全消失了，只剩兩個註解裡還寫 ready flags。我把註解也更新。
>
> 這裡也是小編碼差異，我看一下實際行再改。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+2 -3)
>
> </details>
>
> 再順手把「capture buffer」文字改掉，讓檔案跟實作一致。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+3 -3)
>
> </details>
>
> 剛剛 regex rewrite 讓檔頭多了 UTF-8 BOM，我把它去掉，避免 VCS 或 diff 顯示怪字元。
>
> 現在同步到遠端再跑一次 RTL sim，確認簡化後沒有打破固定排程。
>
> 同步完成，開始跑 VCS。
>
> RTL sim 通過，cycles 保持 15332；這次只清控制/ready 邏輯，沒有再跑面積。最後我快速照 code-review checklist 掃一遍殘留訊號和空 port。
>
> 我有 code-review skill，但這個環境沒有直接提供 Task subagent 工具；我用本地掃描和 VCS 取代，重點檢查 port 殘留、dead signal、功能回歸。
</details>

我沒有可用的 spawn reviewer 工具，所以用 VCS + 靜態掃描收尾：現在 `rg` 已確認 qkv/sv ready bitmap、capture/x_mem 殘留訊號都清乾淨。

> 為何現在第一筆MHA要經過164 cycle 扣掉RAM input delay 50也還有 114 是怎麼算的，是否可以通過排程串流解決

<details><summary>1 previous message</summary>

> 我先把這個 164 拆成「RAM 回來後 datapath pipeline + MHA head 序列化」兩段看；這裡要小心，因為 QKV 已經是 stream，但 MHA 第一筆 output 卡在 FINAL head0/head1 combine，不只是 input read。
</details>

對，這個 `164` 可以很漂亮地拆開：

```text
MHA first output = RAM 50
                 + QKV stream 32
                 + SV score 32
                 + FINAL head0 32
                 + head1 FINAL datapath 18
               = 164
```

扣掉 RAM 50 後的 `114` 就是：

```text
32 + 32 + 32 + 18 = 114
```

其中：

- `32`：QKV 吃完整個 group 的 32 筆 X。三個 engine 同拍算 Q/K/V，這段已經是 stream-in。
- `32`：MHA SV/score。engine0 算 head0，engine1 算 head1，所以 32 matrix 要 32 cycles。
- `32`：MHA FINAL head0。這段結果不輸出，只先 packed 存到 `q_mem/k_mem` 當 scratch。
- `18`：head1 FINAL issue 後到 `out_valid` 的 datapath latency：
  `issue buffer 1 + mult 5 + mult output reg 1 + ACT 5 + PoT 5 + output reg 1 = 18`

所以真正讓第一筆 MHA 晚的是這個：

```text
SV 全部做完 → FINAL head0 全部做完 → FINAL head1 才開始輸出
```

可以用排程串流改善第一筆 latency，但不是免費的。

如果改成 matrix-wise streaming：

```text
QKV 全部完成後：
SV[0] → FINAL head0[0] → FINAL head1[0] → 第一筆 output
SV[1] → FINAL head0[1] → FINAL head1[1] → 第二筆 output
...
```

第一筆大概會變成：

```text
RAM 50 + QKV 32 + SV[0]/FINAL h0/h1 約 3 + datapath 18
≈ 103 cycles
```

比現在 `164` 早很多。

但代價是：output 不會連續 32 拍，而是中間有 bubble。現在設計刻意先把 head0 32 筆都算完，然後 head1 連續 32 拍，這樣 `out_valid/wr_data` 可以對齊 `BURST_32` write。若改 matrix-wise streaming，就要：

- 改 write 排程，不能假設 burst-32 連續資料；
- 或加 output FIFO，先收 sparse output 再 burst write；
- 或改成小 burst/window，例如 4 或 8 筆一段。

所以結論：**可以靠串流排程降低第一筆 MHA latency，但若不加 output buffer，就會破壞現在連續 burst write 的漂亮對齊。**
如果目標是總 cycles/area，我會優先試 windowed schedule，例如 `SV all → FINAL head0 8 → FINAL head1 8 output → ...`，先看 latency 省多少、write bubble 能不能接受。

> 我想要的是每一步都可以1matrix/1cycle 這樣從輸入到輸出不就一直串出去就好了嗎

你想的「每一步都 1 matrix/cycle，input 進來後後面一直串出去」是**正統 streaming pipeline**，概念上對。

但目前 `CA.sv` 不是這種架構；它是 **同一組 multiplier engines 分時做 QKV / SV / FINAL**。所以卡點不是控制寫得不夠串，而是硬體資源被同一批 engine 共用。

目前資源使用是：

```text
QKV:
  engine0 = Q
  engine1 = K
  engine2 = V
  => 3 engines 全滿，1 input matrix/cycle

SV:
  engine0 = head0 score
  engine1 = head1 score
  engine2 = idle
  => MHA 1 matrix/cycle，但不能跟 QKV 同時跑，因為 engine0/1 被搶

FINAL:
  engine0 = d0 * V
  engine1 = d1 * V
  engine2 = d2 * V
  => 1 head/cycle
  => MHA 一個 matrix 要 head0 + head1，所以平均 2 cycles/matrix
```

所以如果你要真正做到：

```text
X stream in
→ QKV 1/cycle
→ SV 1/cycle
→ FINAL 1/cycle
→ output stream out
```

那每個 stage 要有自己的硬體：

```text
QKV stage:   3 mult engines
SV stage:    2 mult engines
FINAL stage: 6 mult engines  // head0/head1 各 d0/d1/d2
```

也就是至少從現在的 3 個 mult engine 增到大概 11 個 mult engine。這樣當然可以一路串，但 area 會爆很多。

如果**不加硬體**，只能做「排程更漂亮」，不能真的所有 step 同時 1 matrix/cycle。比較實際的優化是：

```text
QKV 32
SV 32
FINAL 改 head0/head1 interleave:
  h0[0], h1[0], h0[1], h1[1], ...
```

這可以把第一筆 MHA output 從：

```text
RAM 50 + QKV 32 + SV 32 + head0 prepass 32 + pipeline 18 = 164
```

降成大約：

```text
RAM 50 + QKV 32 + SV 32 + h0/h1 pair 2 + pipeline 18 = 132
```

但後面 output 會變成約每 2 cycles 一筆，不再是現在 head1 phase 的連續 32 筆 burst stream。總 group 完成時間不一定更短，只是第一筆更早出來。

所以結論：

- **要真 streaming：需要加 multiplier stage，面積換 latency/throughput。**
- **只靠排程：可以降低第一筆 MHA latency，但無法維持全流程 1 matrix/cycle。**
- 目前最值得試的小改是 `FINAL h0/h1 interleave`，看第一筆 latency 是否值得犧牲 write burst 對齊。

> 乘出qkv之後不是還會先送去PoT運算嗎

對，沒錯。Q/K/V 不是 multiplier 一出來就直接能給 SV/FINAL 用，會先走 PoT 量化：

```text
X * Wq/Wk/Wv
→ mult_valid / mult_k_valid / mult_v_valid
→ 3 路 PoT
→ q_mem / k_mem / v_mem
```

所以 QKV 從 issue 到真正寫進 `q_mem/k_mem/v_mem` 大約是：

```text
issue buffer 1
+ mult pipeline 5
+ mult output reg 1
+ PoT pipeline 5
= 約 12 cycles
```

但這段目前被 **QKV 32-cycle stream 本身藏住了**。

例如：

```text
cycle 0   issue QKV[0]
cycle 1   issue QKV[1]
...
cycle 31  issue QKV[31]

約 cycle 12  Q/K/V[0] ready
約 cycle 13  Q/K/V[1] ready
...
約 cycle 43  Q/K/V[31] ready
```

現在 SV 是在 QKV issue 完後才開始：

```text
cycle 32 issue SV[0]
cycle 33 issue SV[1]
...
cycle 63 issue SV[31]
```

所以 SV[0] 用到的 Q/K[0] 早就 ready 了；SV[31] 到 cycle 63 才用 Q/K[31]，也早就 ready 了。這就是為什麼 `qkv_ready` 可以移掉，因為固定順序下 PoT latency 被自然 hide 掉。

你想的更完整 streaming 是：

```text
QKV[0] 經 PoT ready 後，SV[0] 馬上接著算
QKV[1] 經 PoT ready 後，SV[1] 接著算
...
```

這在資料相依性上是可以的。真正卡住的是：**SV 用的 multiplier 跟 QKV 是同一批 engine**。QKV 連續 32 cycles 已經把 engine0/1/2 塞滿了，SV 沒有自己的 multiplier 可以同時跑。

所以：

- QKV → PoT 這段已經是串流的。
- Q/K/V ready 也確實可以用 shift/固定延遲理解，不需要 bitmap。
- 但要讓 SV 在 QKV 還沒跑完時就接上，必須有獨立 SV multiplier engine。
- 同理，要讓 FINAL 也完全接上，就要獨立 FINAL engine，尤其 MHA head0/head1 現在是序列化的。

也就是說，你的 pipeline 想法是對的，只是目前硬體是「三顆 multiplier 分時共用」，不是「QKV/SV/FINAL 各自一組 stage」。

<details><summary>4 previous messages</summary>

> Context compaction
>
> Source: automatic
> Status: completed
>
> 我先快速對一下目前 `CA.sv` 的實際狀態，確認 QKV bitmap 已經清掉多少、哪些地方還是用 index RAM 存取，然後再回答六個 multiplier engine 能不能把整條 pipe 撐到 1 matrix/cycle。
>
> 我會用 brainstorming 的方式先把架構邊界講清楚，這裡先不動檔案。重點是分辨「QKV ready 控制改 shift」和「加 multiplier engine 做真正 pipeline」這兩件事，前者是控制簡化，後者是硬體資源切分。
>
> 我看到目前本地版其實已經沒有 Q/K/V/score 的 ready bitmap，也沒有 `x_mem`；QKV 是在 `rd_valid` 時直接用 `rd_data` 發進三路 Q/K/V。剩下的「shift」比較像是把 `issue_idx`/stage counter 的 fixed schedule 再整理成 pipeline tap，而不是功能上還需要 bitmap。
</details>

對，QKV 可以完全用 shift/fixed-latency stream，不需要 bitmap。其實目前這版本地 `CA.sv` 已經沒有 `q_ready/k_ready/v_ready/score_ready` bitmap，也沒有 `x_mem`；QKV 是 `rd_valid` 來一拍就直接用 `rd_data` 發 Q/K/V 三路 multiplier，後面靠固定 latency 對齊。

但「六個 multiplier engine」要分清楚：

- **總共 6 顆 engine：還不能達到完整 1 matrix/cycle 串流。**
  因為同一個 cycle 若要 pipeline 同時跑：
  `QKV` 需要 3 顆，`SV/score` 需要 2 顆，`MHA FINAL` 兩個 head、三個 digit 需要 6 顆。
  所以真正全串流 MHA 約要 **3 + 2 + 6 = 11 顆 multiplier engine**，另外 lane0 的 PoT 也不能再跟 Q 共用，final output 需要獨立 PoT/ACT path 才不撞。

- **6 顆專門拿來做 MHA FINAL 是有用的。**
  這可以把現在 MHA 的 FINAL 從 `head0 32 cycle + head1 32 cycle` 變成 `head0/head1 同拍算完 = 32 cycle`。
  第一筆 MHA latency 會從現在約：
  `RAM 50 + QKV 32 + SV 32 + head0 prepass 32 + final pipe 18 = 164`
  降到約：
  `RAM 50 + QKV 32 + SV 32 + final pipe 18 = 132`

所以結論是：**QKV 改 shift/fixed stream 沒問題；6 顆 engine 可以解 MHA FINAL 的兩倍 latency，但不是完整 input-to-output 1 matrix/cycle。**
若目標是每拍 input、每拍 score、每拍 output 全部重疊流動，就要走 11-engine 的 stage-separated pipeline。我的建議是先把控制邏輯再整理成「QKV 只屬於 read-stream，不再放在 HA stage enum」，接著再評估 6-final-engine 版本。

> 6-final-engine 的話 可以分成前後串流嗎，這樣QKV+SV可以連續計算，如果排程算好的話可以省下蠻多cycle的，我想讓QKV變成shift reg固定用q[0]來算下一筆然後一直串流那種的不知道可不可以

<details><summary>1 previous message</summary>

> 我先把這個當架構討論，不直接改 RTL。你這個方向其實很接近「把 attention 拆成前段 QKV/SV stream、後段 FINAL stream」，關鍵不是 QKV 能不能 shift，而是 SV 的 score 是不是只需要同 index 的 Q/K，還是需要整段 K/V 視窗。
</details>

可以，但要分兩個層級看。

**如果是「6 顆 final engine + 前段仍共用原本 3 顆 engine」**，可以做成 group-level 前後串流：

```text
group n:      QKV 32cy -> SV 32cy
group n-1:                    FINAL 32cy -> output
```

這樣 MHA FINAL 從 64cy 壓成 32cy，而且可以跟下一組的 QKV/SV 疊起來，會省不少 total cycles。但這不是你說的「每一筆 matrix 都一路流到底」，因為 QKV 跑的時候，原本 engine 已經被 Q/K/V 吃滿，SV 不能同時用它們。

**如果你要的是 q[0] 那種真正 shift stream：可以，而且目前演算法看起來資料相依允許。**

每個 matrix 只依賴同 index 的 `Q/K/V`：

```text
rd_data[i]
  -> Q/K/V mult + PoT
  -> q/k 出來立刻算 score
  -> score 出來配 delayed v
  -> 6 final engines 同拍算 head0/head1 的 d0/d1/d2
  -> combine heads -> ACT -> PoT -> output
```

也就是：

```text
QKV issue i at t=i
Q/K/V ready at t=i+Lqkv
SV issue i at t=i+Lqkv
score ready at t=i+Lqkv+Lsv
FINAL issue i at t=i+Lqkv+Lsv
output i after final/ACT/PoT latency
```

這時 `q_mem/k_mem/v_mem/score_mem` 可以大幅變成 latency shift/FIFO：

- `q/k`：QKV PoT 出來後直接進 SV，不需要 32-entry bitmap。
- `v`：延遲 `Lsv` cycles，等同 index 的 score 到了再進 FINAL。
- `score`：SV output 後直接進 FINAL，不一定要寫 `score_mem`。
- MHA head0 scratch 也可以拿掉，因為 6 final engines 讓 head0/head1 同 cycle 算完、同 cycle combine。

但硬體需求要補齊：**真正 1 matrix/cycle 需要前段 3 顆 QKV + 2 顆 SV + 後段 6 顆 FINAL = 11 顆 multiplier engine**。如果只有 6 顆 total，或只有 6 顆後端同時拿來 SV/FINAL，共用會撞，穩態沒辦法每 cycle 同時吃 SV 和 FINAL。

另外還有一個容易漏掉的點：PoT 也要分開。現在 lane0 PoT 同時服務 `Q` 和 FINAL output；如果 QKV 和 FINAL 重疊串流，這條也會撞。所以至少要把 `Q` 的 PoT lane 和 final output 的 `ACT->PoT` 拆開。

我的判斷：你想要的 q[0] shift stream 是可做的，而且會比現在 group-stage schedule 省很多 latency；但它不是只改控制，會是 datapath 重切成固定 pipeline。最乾淨版本是 11-mult + 獨立 PoT lanes，然後把 attention 主路徑改成 valid shift pipe。

> 只用六mult 這樣前面不是可以同時算QKV+SV嗎 之後stall 等這個group都算完再進FINAL串流輸出?

可以，你這個 **6 mult total** 的想法是成立的，而且比我前面說的 11 mult 更像「折衷版」：

```text
前段 stream：
  3 mult 算 Q/K/V
  2 mult 算 SV head0/head1
  1 mult 空著或之後拿來做小優化

後段 stream：
  6 mult 全部切去 FINAL
  head0 d0/d1/d2 + head1 d0/d1/d2 同拍算
```

所以排程會變成：

```text
QKV issue:    0 ........ 31
SV issue:          12 ........ 43     // Q/K PoT 出來後接著算
score ready:             ~18 ........ ~49
FINAL issue:                          ~50 ........ ~81
output:                                      ~68 ........ ~99
```

跟現在 MHA 相比，現在是：

```text
QKV 32 + SV 32 + FINAL head0 32 + FINAL head1 32
```

新排程會變成近似：

```text
max(QKV 32, QKV_latency + SV 32) + FINAL 32
≈ 50 + 32
```

也就是每 group issue work 從約 `128 cycles` 壓到約 `82 cycles`，省下的確很多。

你說的 `q[0]` shift stream 也可以做，而且這應該是正確方向。前段可以不用 `q_mem/k_mem` bitmap access，而是：

```text
rd_data stream
  -> Q/K/V mult
  -> Q/K/V PoT
  -> q_shift/k_shift 直接餵 SV
  -> score_fifo
  -> FINAL phase 再讀 score_fifo + v_fifo
```

比較重要的是：因為後段 FINAL 要等整個 group 的 score 都算完才用 6 顆 mult 串流輸出，所以仍然要存：

- `v_fifo[32]` 或 `v_mem[32]`
- `score_fifo[64]`，MHA 兩個 head
- 不需要 Q/K 長期保存，只要 Q/K latency shift 到 SV 即可
- 不需要 QKV ready bitmap，只要 valid shift pipe

唯一要注意的是 **PoT lane 會撞**。現在 Q 的 PoT 和 FINAL output 的 PoT 是同一條 `u_pot`。如果 FINAL issue 完立刻開始下一 group QKV，上一 group 的 FINAL 還在 ACT/PoT drain，下一 group 的 Q 也會要進 PoT。解法有兩個：

1. 加一條獨立 FINAL output PoT，這樣下一 group 前段可以更早開始。
2. 不加 PoT，控制上多等 final 的 PoT input drain 清掉，再發下一 group QKV，省一點 area 但少賺幾拍。

所以我的結論：**可以，只用 6 mult 也能做前段 QKV+SV 串流，然後 stall 切到 FINAL 6-way 串流輸出。**
這版應該是目前最值得做的折衷架構：控制比 bitmap 簡單很多，area 比 11 mult 小很多，MHA latency 又能明顯降。

> 那你實作看看這版

<details><summary>71 previous messages</summary>

> 好，我來做這版。我的落點會是：6 顆 mult total、前段用 3(QKV)+2(SV) 串流重疊，前段結束後切到 6-way FINAL 串流；Q/K 不再長期存，score/V 用固定延遲與小 buffer 接到 FINAL。
>
> 我先讀 current RTL 的幾個關鍵區塊：Control 的 HA FSM、DataPath 的 q/k/v/score 寫入、以及 Multiple_Processor 的三顆 engine issue/return。接下來會把新排程盡量塞在既有模組邊界裡，不先拆大檔。
>
> 現在的 datapath 邊界還算好用：`Multiple_Processor` 已經把 Q/K/V、SV、FINAL 的 operand mux 包住。我要做的改法會先盡量保持 `CA_DataPath` 外部介面不變，只在 `issue_mode` 裡增加「前段 stream 時由 QKV valid 自動觸發 SV」的內部 pipe。
>
> 設計上我會先做「不跨 group 重疊 QKV 與前一組 FINAL」的安全版：同一組內 QKV/SV 前段重疊，前段完成後 6-way FINAL。這樣 PoT lane 不會先被下一組 Q 搶走，等 sim 過後再看要不要把 next-group prefetch/restart 拉早。
>
> 我準備開始改檔：先改 Control 成「QKV read stream → 固定 front-drain → 32-cycle FINAL」，再改 datapath 裡的 6 顆 mult。這一步會把 MHA 的 FINAL phase 從 64 改成 32，write/restart tap 也跟著拉到 SHA 同級。
>
> 第一個 patch 因為檔案裡有一些舊中文註解編碼已經亂掉，context 沒對上。我改用只抓 RTL 語句的窄 patch，避免被註解干擾。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+3 -4)
>
> </details>
>
> Control constants 先換成新版：MHA 的 write/restart tap 跟 SHA 一樣，front wait 暫抓 18 cycle，這是從 QKV PoT 最後一筆到 score write 最後一筆的固定 pipeline 延遲。
>
> 順手注意到一個舊註解顯示把 `ha_final_start` 擠在同一行，這可能只是編碼顯示問題，但我會趁這次把那段整理乾淨，避免後面 patch 或 VCS 吃到奇怪 context。
>
> 我會把 prefetch 改成 FINAL phase 0 就發下一組 read，這樣前段不用重新吃 50-cycle RAM 空泡；但下一組真正 QKV 仍等目前 FINAL output drain 後才開始，先保持資源不撞。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+10 -19)
>
> </details>
>
> Control 已切成 front wait + 32-cycle FINAL。接下來改 datapath：新增三顆 `Mult_5Stage_Parallel`，前段其中兩顆吃 Q/K PoT stream 算 score，後段三顆吃 head1 的 d0/d1/d2。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+10 -4)
>
> </details>
>
> 我先加了兩條 SV score 回寫通道，會讓 score stream 不再借用 Q/K/V 那幾條 valid/data，因為前段重疊時 K/V PoT output 和 score output 可能同拍，不能共用同一條線。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+6 -4)
> - Wrote `./DCS_FINAL/CA.sv` (+11 -18)
> - Wrote `./DCS_FINAL/CA.sv` (+8 -4)
> - Wrote `./DCS_FINAL/CA.sv` (+16 -6)
>
> </details>
>
> DataPath 這裡我會保留舊 `q_mem/k_mem` 寫入先不刪，因為它不影響功能也方便比較；真正新的 SV score 會由 Q/K PoT output 直接進兩顆 stream score engine，再寫 `score_mem`。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+9 -3)
> - Wrote `./DCS_FINAL/CA.sv` (+1 -1)
>
> </details>
>
> 接下來是核心改動：`Multiple_Processor` 會多收 `q_stream/k_stream`，並多吐兩條 score writeback。後端 FINAL 則會在 MHA 時用新增三顆 engine 算 head1，跟原本三顆 head0 同拍 combine。
>
> 這段 port list 也有舊編碼註解，我改成分段塞，先塞 input，再改 output 末端。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+10 -5)
>
> </details>
>
> 新版 score stream 會有 `sv0` 和 `sv1` 兩條結果：MHA 時分別是 head0/head1，SHA 時只用 `sv0`。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+8 -2)
>
> </details>
>
> 我會把新增三顆命名成 aux0/aux1/aux2：前段 aux0/aux1 算 score，後段 aux0/aux1/aux2 算 MHA head1 的三個 digit。原本三顆則保留 QKV 與 FINAL head0。
>
> `rg` 顯示註解實際是正常 UTF-8，先前只是終端輸出亂碼。我會以 `rg` 看到的精確文字做 patch。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+23 -5)
> - Wrote `./DCS_FINAL/CA.sv` (+6 -2)
>
> </details>
>
> 我會在 `Multiple_Processor` 內補三個小 helper：MHA head0/head1 的 Q/K mask，以及 head combine。這樣 final combine 不必再借 `q_mem/k_mem` scratch。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+34 -1)
>
> </details>
>
> 接下來加 aux operand mux。注意它會優先服務 FINAL；前段 score 只在 `q_stream_valid` 時啟動，MHA 兩頭同拍，SHA 只開一顆 score engine。
>
> Aux mux 這裡也會讓舊 `IM_SV` path 保留但不再由 Control 發，方便我們先不大拆；真正前段 score 走新的 `q_stream_valid`。
>
> 又是註解 context；我直接插在 final counter 的 `always_ff` 前面。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+55 -1)
>
> </details>
>
> 我剛才用太寬的 `always_ff` context，有可能插到前面第一個 always_ff。先檢查位置，如果插錯我會立刻搬回 `Multiple_Processor`，不會硬往下堆。
>
> 確認插錯了，是在 Control。這塊我現在移除，等一下用 `fin_mat_cs` 附近的明確錨點插回正確 module。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -54)
> - Wrote `./DCS_FINAL/CA.sv` (+55 -1)
>
> </details>
>
> 現在新增三顆實體 mult。這會是面積增加的主因，但排程就能做到「前段 5 顆一起跑、後段 6 顆一起跑」。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+54 -12)
>
> </details>
>
> 我也要幫 aux0/aux1 做 idx/score sideband pipeline，這樣 score output 回寫 `score_mem` 的 index 會跟 mult raw output 對齊。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+30 -18)
>
> </details>
>
> 後端 combine 現在要從兩組三顆 mult 的 raw result 各自做 signed-digit 合併，再把 head0/head1 的 columns 拼起來送 ACT/PoT。
>
> 這段開始改 final raw combine；原本只合一組 d0/d1/d2，現在多一組 head1 的 d0/d1/d2。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+23 -13)
> - Wrote `./DCS_FINAL/CA.sv` (+15 -8)
>
> </details>
>
> 最後把 aux score output 註冊出去；這跟既有 `mult_valid` 一樣多打一拍，維持 ACT/PoT 前面的 timing buffer。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+20 -10)
>
> </details>
>
> RTL 改完第一輪了。我先跑一次靜態搜尋抓漏：確認舊 `HA_PF_*` 沒殘留、`aux` 沒插錯 module，然後就同步到遠端跑 VCS。
>
> 靜態搜尋看起來沒有舊 prefetch 常數殘留，module 邊界也還完整。現在同步到 `dcs_mimi` 跑 RTL sim，第一輪大概率會抓到幾個 timing 或 SV 語法小錯，我會逐個修。
>
> 好，第一輪 RTL sim 直接過了，execution cycles 從前一版 15332 降到 14666。現在我再從 log 裡抓 SHA/MHA 各自 latency，確認 MHA 是否真的吃到這次前後段串流的收益。
>
> Sim 過了，不過我 grep 到現在還有幾個「已經被常數關掉」的舊 MHA scratch signal。功能沒問題，但控制邏輯要更乾淨的話我會把這些殘留也拿掉，避免之後看 RTL 被誤導。先抓完整 opset latency。
>
> 我會把舊 MHA head0 scratch 殘留清掉：`mha_head0_pack`、`mha_comb_*`、pack/unpack helper 都是舊兩段 FINAL 用的，現在 6-way FINAL 在 `Multiple_Processor` 內直接 combine，不需要留著。
>
> 清理會分小 patch 做，避免一次刪太大片誤傷 `pack_attention_score` 這個仍然需要的 score 壓縮函式。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -3)
>
> </details>
>
> 先移掉常數，再移掉舊 scratch signal 和 disabled write。剩下註解我會順手修成符合新架構，避免讀到舊敘述。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+1 -6)
> - Wrote `./DCS_FINAL/CA.sv` (+0 -15)
>
> </details>
>
> `combine_mha_heads` 在 DataPath 裡已經沒用了，真正的 head combine 已搬到 `Multiple_Processor` 的 6-way FINAL path。接著刪 pack/unpack scratch helper。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+0 -27)
>
> </details>
>
> 現在清掉原本把 MHA head0 partial 寫回 `q_mem/k_mem` 的 disabled block；新版不再需要這個 scratch reuse。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+1 -8)
> - Wrote `./DCS_FINAL/CA.sv` (+1 -9)
>
> </details>
>
> 舊 signal 已經清乾淨了。剩下是註解還在講舊架構，我會修掉，這樣之後看 latency 常數不會誤會還是 MHA=64 final。
>
> `rg` 看到註解其實是正常的；我會用它顯示的 UTF-8 內容直接替換成新版說法。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+7 -14)
> - Wrote `./DCS_FINAL/CA.sv` (+3 -4)
> - Wrote `./DCS_FINAL/CA.sv` (+3 -5)
>
> </details>
>
> 舊註解集中在 DataPath 區塊，我改成新版敘述：Q/K 只是保留作 debug/相容，SV 從 stream 算；MHA FINAL 不再寫 scratch。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+7 -11)
>
> </details>
>
> 我也把 `Multiple_Processor` 裡 final counter 的註解修成新版：不是 head0 先算再 head1，而是同一個 `fin_mat` 同拍發 head0/head1。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+4 -3)
> - Wrote `./DCS_FINAL/CA.sv` (+2 -2)
>
> </details>
>
> 清理後沒有舊 scratch/bitmap 關鍵字殘留，`git diff --check` 也乾淨。雖然只改註解和 dead block，還是重跑一次 RTL sim 確認最終檔案一致通過。
>
> 最終版也過了，execution cycles 維持 14666。最後我抓一次 final log 的 opset latency，整理一下 SHA/MHA 的實際改善幅度。
>
> 我注意到新版把 SHA 也改成 stream score，雖然功能過了，但 SHA latency 從前一版約 742 變成 856。這不划算。我要把分支收回來：MHA 用新 6-mult 前後串流；SHA 保留原本 2-way SV 排程，這樣 MHA 變快、SHA 不被拖慢。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+17 -3)
>
> </details>
>
> Control 已改成：`exec_op==3(MHA)` 時 ST_SV 只做 front wait；`exec_op==2(SHA)` 時 ST_SV 照舊發 16 phase `IM_SV`。接著關掉 SHA 的 q/k stream score，避免 duplicate score write。
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./DCS_FINAL/CA.sv` (+3 -3)
> - Wrote `./DCS_FINAL/CA.sv` (+1 -0)
>
> </details>
>
> 這個分支比較合理：MHA 吃新架構，SHA 保持原本快的 2-way SV。現在重跑 VCS，確認沒有因為 prefetch 分支切回來導致對齊問題。
>
> 這版比較漂亮：MHA 856、SHA 回到 742，總 cycles 降到 13982。現在我做最後掃描與 diff check，確認沒有 dead keyword 或 whitespace 問題。
</details>

已實作在 [CA.sv](<./DCS_FINAL/CA.sv>)。

這版是 **6 mult total** 的折衷排程：

- MHA 前段：`Q/K/V` 用原本 3 顆 mult 串流，`Q/K` PoT 出來後直接觸發 2 顆 aux mult 算 head0/head1 score。
- MHA 後段：切到 6 顆 mult，同拍算 `head0 d0/d1/d2` + `head1 d0/d1/d2`，再 combine 進 ACT/PoT。
- SHA 保留原本 2-way `IM_SV` 排程，避免被 MHA stream 改法拖慢。
- 已清掉舊 MHA head0 scratch / `mha_comb_*` / pack-unpack dead logic。

驗證結果：

```text
VCS RTL: passed all patterns
Cycle Time = 3.0 ns
execution cycles = 13982
```

latency 變化：

```text
SHA op=2: 742 cycles   // 保持原本速度
MHA op=3: 856 cycles   // 原本約 1126，降 270 cycles
total:    15332 -> 13982
```

沒有跑 area/synthesis，先照你前面說的只看架構與 RTL latency。
