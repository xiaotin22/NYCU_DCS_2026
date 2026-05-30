#!/bin/bash

# ================= 設定區塊 =================
TCL_FILE="syn.tcl"
START_CYCLE=10
END_CYCLE=20
STEP=5
LOG_FILE="sweep_report.log"       
RAW_DATA_FILE="sweep_data.tmp"     

# 定義顏色
RED='\e[1;31m'
GREEN='\e[1;32m'
NC='\e[0m'

# 清空舊檔
rm -f $RAW_DATA_FILE
rm -f $LOG_FILE

# 1. 初始化 Log 總表標頭
echo "=========================================================================================================================================" >> $LOG_FILE
echo "                                            數位電路合成掃頻自動化分析報告                                                               " >> $LOG_FILE
echo "=========================================================================================================================================" >> $LOG_FILE
printf "%-10s %-10s %-15s %-15s %-8s %-40s %-40s\n" "Cycle(ns)" "Slack(ns)" "Total_Area" "Area*CLK" "Status" "Critical_Startpoint" "Critical_Endpoint" >> $LOG_FILE
echo "-----------------------------------------------------------------------------------------------------------------------------------------" >> $LOG_FILE

# 2. 開始掃頻迴圈
for cycle in $(seq $START_CYCLE $STEP $END_CYCLE); do
    echo "========================================================"
    echo " 🚀 開始合成: CYCLE = $cycle ns"
    echo "========================================================"

    sed -i "s/^set CYCLE.*/set CYCLE $cycle/g" $TCL_FILE
    ./01_run_dc > make_temp.log 2>&1

    LOG_BACKUP="syn_${cycle}.log"
    if [ -f "syn.log" ]; then
        cp syn.log $LOG_BACKUP
    else
        cp make_temp.log $LOG_BACKUP
    fi

    # ================= 數據萃取區塊 =================
    AREA=$(grep "Total cell area:" $LOG_BACKUP | head -n 1 | awk '{print $NF}')
    SLACK=$(grep "slack (" $LOG_BACKUP | head -n 1 | awk '{print $NF}')
    STARTPOINT=$(grep "Startpoint:" $LOG_BACKUP | head -n 1 | awk '{print $2}')
    ENDPOINT=$(grep "Endpoint:" $LOG_BACKUP | head -n 1 | awk '{print $2}')

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

    # ================= 寫入紀錄 =================
    printf "%-10s %-10s %-15s %-15.4f %-8s %-40s %-40s\n" "$cycle" "$SLACK" "$AREA" "$AREA_CLK" "$STATUS" "$STARTPOINT" "$ENDPOINT" >> $LOG_FILE
    
    if [ "$AREA_CLK" != "N/A" ]; then
        echo "$AREA_CLK $cycle $SLACK $AREA $STATUS $STARTPOINT $ENDPOINT" >> $RAW_DATA_FILE
    fi

    echo -e " ✅ 完成 $cycle ns | Slack: $SLACK | Area: $AREA | Status: $PRINT_STATUS"
done

rm -f make_temp.log

# ================= 輸出排名並寫入 Log =================
echo "" >> $LOG_FILE
echo "========================================================================" >> $LOG_FILE
echo "🏆 根據 AREA * CLK 大小排序之晶片效益排名 (由優到劣) 🏆" >> $LOG_FILE
echo "========================================================================" >> $LOG_FILE

if [ -f "$RAW_DATA_FILE" ]; then
    sort -n $RAW_DATA_FILE > sweep_sorted.tmp
    
    echo ""
    echo "🎯 掃頻合成結束！總表與排名結果已完整寫入：$LOG_FILE"
    echo "========================================================"
    echo "🏆 根據 AREA * CLK 大小排序之晶片效益排名 (由優到劣) 🏆"
    echo "========================================================"

    rank=1
    while read -r area_clk clk slack area status start_pt end_pt; do
        if [ "$status" = "FAIL" ]; then
            COLOR_SLACK="${RED}${slack} (FAIL)${NC}"
        else
            COLOR_SLACK="${GREEN}${slack} (PASS)${NC}"
        fi
        
        # 1. 打印到螢幕
        echo "====Rank${rank}===="
        echo "CLK      = ${clk} ns"
        echo "AREA     = ${area}"
        echo -e "Slack    = ${COLOR_SLACK}"
        printf "Area*CLK = %.4f\n" "$area_clk"
        
        # 只有 Rank 1 才會印出 Path
        if [ "$rank" -eq 1 ]; then
            echo "Path     = ${start_pt} -> ${end_pt}"
        fi
        
        # 2. 寫入到 Log
        {
            echo "====Rank${rank}===="
            echo "CLK      = ${clk} ns"
            echo "AREA     = ${area}"
            echo "Slack    = ${slack} (${status})"
            printf "Area*CLK = %.4f\n" "$area_clk"
            
            # 同樣只有 Rank 1 寫入 Path 到 Log
            if [ "$rank" -eq 1 ]; then
                echo "Path     = ${start_pt} -> ${end_pt}"
            fi
        } >> $LOG_FILE
        
        rank=$((rank + 1))
    done < sweep_sorted.tmp
    
    rm -f sweep_sorted.tmp
else
    echo "沒有收集到有效的資料，無法進行排名。" | tee -a $LOG_FILE
fi

rm -f $RAW_DATA_FILE