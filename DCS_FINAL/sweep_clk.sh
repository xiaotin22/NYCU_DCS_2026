#!/bin/bash
# Clock-time sweep based on sweep_syn.sh format.
# Designed to survive SSH disconnection: launch with setsid + nohup + redirect.
# Results are written incrementally so a crash never loses completed points.

# ================= 設定區塊 =================
TCL_FILE="syn.tcl"
START_CYCLE=3.5
END_CYCLE=4.5
STEP=0.1
LOG_FILE="clk_sweep_report.log"
RAW_DATA_FILE="clk_sweep_data.tmp"
DONE_MARKER="SWEEP_COMPLETE"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;34m'
NC='\033[0m'

# 備份原始 syn.tcl，結束時還原
cp -f "$TCL_FILE" "${TCL_FILE}.sweepbak"
ORIG_CYCLE=$(grep '^set CYCLE' "$TCL_FILE" | head -n1 | awk '{print $3}')

restore_tcl() {
    if [ -f "${TCL_FILE}.sweepbak" ]; then
        cp -f "${TCL_FILE}.sweepbak" "$TCL_FILE"
        rm -f "${TCL_FILE}.sweepbak"
    fi
}

# 清空舊檔（含前一次掃頻殘留的逐點備份）
rm -f "$RAW_DATA_FILE"
rm -f "$LOG_FILE"
rm -f syn_*.log

# 1. 初始化 Log 總表標頭
{
echo "========================================================================================================================================="
echo "                         Digital Circuit Synthesis Report (CLK ${START_CYCLE} ~ ${END_CYCLE}, step ${STEP})                              "
echo "                                            Generate Time: $(date '+%Y-%m-%d %H:%M:%S')                                                  "
echo "========================================================================================================================================="
printf "%-10s %-10s %-15s %-15s %-8s %-40s %-40s\n" "Cycle(ns)" "Slack(ns)" "Total_Area" "Area*CLK" "Status" "Critical_Startpoint" "Critical_Endpoint"
echo "-----------------------------------------------------------------------------------------------------------------------------------------"
} >> "$LOG_FILE"

# 2. 開始掃頻迴圈
for cycle in $(seq -f '%.1f' $START_CYCLE $STEP $END_CYCLE); do
    echo "========================================================"
    echo " [$(date '+%H:%M:%S')] Start Synthesis: CYCLE = $cycle ns"
    echo "========================================================"

    sed -i "s/^set CYCLE.*/set CYCLE $cycle/g" "$TCL_FILE"
    # 先刪舊 syn.log，避免合成失敗時抽到上一輪殘留值
    rm -f syn.log make_temp.log
    ./01_run_dc > make_temp.log 2>&1

    LOG_BACKUP="syn_${cycle}.log"
    if [ -f "syn.log" ]; then
        cp syn.log "$LOG_BACKUP"
    else
        cp make_temp.log "$LOG_BACKUP"
    fi

    # ================= 數據萃取區塊 =================
    AREA=$(grep "Total cell area:" "$LOG_BACKUP" | head -n 1 | awk '{print $NF}')
    SLACK=$(grep "slack (" "$LOG_BACKUP" | head -n 1 | awk '{print $NF}')
    STARTPOINT=$(grep "Startpoint:" "$LOG_BACKUP" | head -n 1 | awk '{print $2}')
    ENDPOINT=$(grep "Endpoint:" "$LOG_BACKUP" | head -n 1 | awk '{print $2}')

    AREA=${AREA:-"N/A"}
    SLACK=${SLACK:-"N/A"}
    STARTPOINT=${STARTPOINT:-"N/A"}
    ENDPOINT=${ENDPOINT:-"N/A"}

    STATUS="N/A"
    AREA_CLK="N/A"
    PRINT_STATUS="N/A"

    if [ "$SLACK" != "N/A" ] && [ "$AREA" != "N/A" ]; then
        AREA_CLK=$(echo "$AREA * $cycle" | bc -l)
        IS_FAIL=$(echo "$SLACK < 0" | bc)
        if [ "$IS_FAIL" -eq 1 ]; then
            STATUS="FAIL"
            PRINT_STATUS="${RED}FAIL${NC}"
        else
            STATUS="PASS"
            PRINT_STATUS="${GREEN}PASS${NC}"
        fi
    fi

    # ================= 寫入紀錄（逐點即時寫入，斷線不丟）=================
    if [ "$AREA_CLK" != "N/A" ]; then
        printf "%-10s %-10s %-15s %-15.4f %-8s %-40s %-40s\n" "$cycle" "$SLACK" "$AREA" "$AREA_CLK" "$STATUS" "$STARTPOINT" "$ENDPOINT" >> "$LOG_FILE"
        # 只有 PASS 才進排名暫存檔
        if [ "$STATUS" = "PASS" ]; then
            echo "$AREA_CLK $cycle $SLACK $AREA $STATUS $STARTPOINT $ENDPOINT" >> "$RAW_DATA_FILE"
        fi
    else
        printf "%-10s %-10s %-15s %-15s %-8s %-40s %-40s\n" "$cycle" "$SLACK" "$AREA" "$AREA_CLK" "$STATUS" "$STARTPOINT" "$ENDPOINT" >> "$LOG_FILE"
    fi

    echo -e " [$(date '+%H:%M:%S')] Finish! $cycle ns | Slack: $SLACK | Area: $AREA | Performance: $AREA_CLK | Status: $PRINT_STATUS"
done

rm -f make_temp.log

# ================= 輸出排名並寫入 Log =================
{
echo ""
echo "========================================================================"
echo "  Ranking by Area*CLK — PASS only (FAIL entries excluded)"
echo "========================================================================"
} >> "$LOG_FILE"

if [ -f "$RAW_DATA_FILE" ]; then
    sort -n "$RAW_DATA_FILE" > sweep_sorted.tmp

    rank=1
    while read -r area_clk clk slack area status start_pt end_pt; do
        {
            echo "---------------------- RANK ${rank} -----------------------"
            echo "CLK      = ${clk} ns"
            echo "AREA     = ${area}"
            echo "Slack    = ${slack} (${status})"
            printf "Area*CLK = %.4f\n" "$area_clk"
            
            echo "Path     = ${start_pt} -> ${end_pt}"
        } >> "$LOG_FILE"
        rank=$((rank + 1))
    done < sweep_sorted.tmp

    rm -f sweep_sorted.tmp
else
    echo "  No PASS entries — all points may have timing violations (FAIL)." >> "$LOG_FILE"
fi

rm -f "$RAW_DATA_FILE"

# 還原 syn.tcl
restore_tcl

# 完成標記（供監看程式偵測）
echo "" >> "$LOG_FILE"
echo "${DONE_MARKER} $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "[$(date '+%H:%M:%S')] ${DONE_MARKER}"
