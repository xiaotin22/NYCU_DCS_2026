from PIL import Image
import sys

# 已經過濾掉會報錯的字元，由暗(空白)到亮(密集)排列
ASCII_CHARS = [" ", ".", ":", "-", "=", "+", "*", "#", "&", "@"]

# 提取好的 PASS 後綴 (綠色 \033[32m)
PASS_SUFFIX = [
    "\\033[32m      :BBQvi.                                            \\033[m",
    "\\033[32m     BBBBBBBBQi                                          \\033[m",
    "\\033[32m    :BBBP :7BBBB.                                        \\033[m",
    "\\033[32m    BBBB     BBBB                                        \\033[m",
    "\\033[32m   iBBBv     BBBB        vBr                             \\033[m",
    "\\033[32m   BBBBBKrirBBBB.     :BBBBBB:                           \\033[m",
    "\\033[32m  rBBBBBBBBBBBR.    .BBBM:BBB                            \\033[m",
    "\\033[32m  BBBB   .::.      EBBBi :BBU                            \\033[m",
    "\\033[32m MBBBr           vBBBu   BBB.                            \\033[m",
    "\\033[32m i7PB          iBBBBB.  iBBB                             \\033[m",
    "\\033[32m             vBBBBPBBBBPBBB7       .7QBB5i               \\033[m",
    "\\033[32m            :RBBB.  .rBBBBB.      rBBBBBBBB7             \\033[m",
    "\\033[32m               .       BBBB       BBBB  :BBBB            \\033[m",
    "\\033[32m                      rBBBr       BBBB    BBBU           \\033[m",
    "\\033[32m                      vBBB        .BBBB   :7i.           \\033[m",
    "\\033[32m                       .7   BBB7   iBBBg                 \\033[m",
    "\\033[32m                            ZBBBr  EBBBv     .BBBBQi     \\033[m",
    "\\033[32m                             iBBBBBBBBD     rBBBBBBBB.   \\033[m",
    "\\033[32m                               :LBBBr      :vBBi  5BBB   \\033[m",
    "\\033[32m                                           :BBB:   BBBu  \\033[m",
    "\\033[32m                                    .BBBi   :BBr         \\033[m",
    "\\033[32m                                     BBBX   :BBBr        \\033[m",
    "\\033[32m                                     .BBBv  :BBBQ        \\033[m",
    "\\033[32m                                      .BBBBBBBBB:        \\033[m",
    "\\033[32m                                        rBBBBB1.         \\033[m"
]

# 提取好的 FAIL 後綴 (紅色 \033[31m)
FAIL_SUFFIX = [
    "\\033[31m  i:..::::::i.      :::::         ::::    .:::.          \\033[m",
    "\\033[31m  BBBBBBBBBBBi     iBBBBBL       .BBBB    7BBB7          \\033[m",
    "\\033[31m  BBBB.::::ir.     BBB:BBB.      .BBBv    iBBB:          \\033[m",
    "\\033[31m  BBBQ            :BBY iBB7       BBB7    :BBB:          \\033[m",
    "\\033[31m  BBBB            BBB. .BBB.      BBB7    :BBB:          \\033[m",
    "\\033[31m  BBBB:r7vvj:    :BBB   gBBs      BBB7    :BBB:          \\033[m",
    "\\033[31m  BBBBBBBBBB7    BBB:   .BBB.     BBB7    :BBB:          \\033[m",
    "\\033[31m  BBBB    ..    iBBBBBBBBBBBP     BBB7    :BBB:          \\033[m",
    "\\033[31m  BBBB          BBBBi7vviQBBB.    BBB7    :BBB.          \\033[m",
    "\\033[31m  BBBB         rBBB.      BBBQ   .BBBv    iBBB2ir777L7   \\033[m",
    "\\033[31m .BBBB        :BBBB       BBBB7  .BBBB    7BBBBBBBBBBB   \\033[m",
    "\\033[31m  . ..        ....         ...:   ....    ..   .......   \\033[m"      
]

def suffix_process(suffix_list, type_check):
    processed = []
    for line in suffix_list:
        # 移除已有的 ANSI 代碼，保留純文字部分
        clean_line = line.replace("\\033[32m", "").replace("\\033[31m", "").replace("\\033[m", "")
        processed.append(clean_line)

    # 根據 type_check 將每個非空白字元單獨加上顏色碼（保留空白）
    if type_check == "PASS":
        color = "\\033[32m"
    elif type_check == "FAIL":
        color = "\\033[31m"
    else:
        return processed

    reset = "\\033[m"
    result = []
    for line in processed:
        new_chars = []
        for ch in line:
            if ch == " ":
                new_chars.append(" ")
            else:
                new_chars.append(f"{color}{ch}{reset}")
        result.append("".join(new_chars))

    return result
    
SUFFIX_PROCESSED_PASS = suffix_process(PASS_SUFFIX, "PASS")
SUFFIX_PROCESSED_FAIL = suffix_process(FAIL_SUFFIX, "FAIL")

def resize_image(image, new_width=100):
    width, height = image.size
    ratio = height / width
    # 抵銷終端機字元長方形比例
    new_height = int(new_width * ratio * 0.55)
    return image.resize((new_width, new_height))

def main():
    type_check = input("PASS or FAIL?").strip().upper()
    image_path = input("請輸入圖片路徑 (例如 cat.jpg / cat.png): ")
    try:
        new_width = int(input("請輸入想要的寬度 (建議 70 到 90): "))
    except ValueError:
        print("寬度必須是整數，預設使用 100")
        new_width = 100

    try:
        # 確保圖片是 RGB 模式，而不是灰階
        image = Image.open(image_path).convert("RGB")
    except Exception as e:
        print(f"找不到圖片或發生錯誤: {e}")
        return

    resized_image = resize_image(image, new_width)
    width, height = resized_image.size
    pixels = list(resized_image.getdata())
    
    ascii_lines = []

    # 逐行、逐像素處理
    for y in range(height):
        line_str = ""
        last_color = ""
        
        for x in range(width):
            # 取得目前的 RGB 數值
            r, g, b = pixels[y * width + x]
            
            # 計算人眼感知的亮度 (0~255)，用來決定要用哪個字元
            brightness = int(0.299 * r + 0.587 * g + 0.114 * b)
            char_idx = min(brightness // 28, 9)
            char = ASCII_CHARS[char_idx]
            
            # 如果是空白，不需要上色，直接重置顏色即可
            if char == " ":
                if last_color != "\\033[0m":
                    line_str += "\\033[0m"
                    last_color = "\\033[0m"
                line_str += " "
            else:
                # 組裝 ANSI 全彩代碼
                current_color = f"\\033[38;2;{r};{g};{b}m"
                
                # 只有當顏色改變時，才印出顏色代碼，避免字串過長
                if current_color != last_color:
                    line_str += current_color
                    last_color = current_color
                
                # 處理跳脫字元保平安
                if char == '\\': char = '\\\\'
                if char == '"': char = '\\"'
                line_str += char
                
        # 每一行結束前，強制重置顏色
        if last_color != "\\033[0m":
            line_str += "\\033[0m"
            
        ascii_lines.append(line_str)
    
    print("\n" + "="*50)
    print("✨ 全彩轉換完成！請複製以下 Verilog 程式碼：")
    print("="*50 + "\n")
    
    if type_check == "PASS":
        print("// 這是 PASS 的圖片，請將以下程式碼貼到 PATTERN.sv 中的 YOU_PASS_TASK 裡")
        print("task YOU_PASS_TASK; begin")
        
        # 併排輸出圖片與後綴 (PASS 預設靠上對齊)
        for i, line in enumerate(ascii_lines):
            suffix = SUFFIX_PROCESSED_PASS[i] if i < len(SUFFIX_PROCESSED_PASS) else ""
            print(f'    $display("{line}{suffix}");')
            
        # 如果圖片高度不夠，把剩下的 PASS 後綴印完
        if len(ascii_lines) < len(PASS_SUFFIX):
            pad_spaces = " " * new_width
            for i in range(len(ascii_lines), len(PASS_SUFFIX)):
                print(f'    $display("{pad_spaces}{PASS_SUFFIX[i]}");')
                
        print("end endtask")
    
    elif type_check == "FAIL":
        print("// 這是 FAIL 的圖片，請將以下程式碼貼到 PATTERN.sv 中的 YOU_FAIL_TASK 裡")
        print("task YOU_FAIL_TASK; begin")
        
        # 為了讓 FAIL 靠在圖片最底下，我們計算需要的總行數
        total_lines = max(len(ascii_lines), len(FAIL_SUFFIX))
        img_pad_top = total_lines - len(ascii_lines)
        suf_pad_top = total_lines - len(FAIL_SUFFIX)
        
        for i in range(total_lines):
            # 圖片行：如果不夠高就補空白
            img_str = ascii_lines[i - img_pad_top] if i >= img_pad_top else " " * new_width
            # 後綴行：如果不夠高就留白，達到底部時才印出 FAIL_SUFFIX
            suf_str = SUFFIX_PROCESSED_FAIL[i - suf_pad_top] if i >= suf_pad_top else ""
            print(f'    $display("{img_str}{suf_str}");')
                
        print("end endtask")
    
    # OUTPUT 生成到 {type_check}_task.txt，方便複製
    with open(f"{type_check}_task.txt", "w") as f:
        if type_check == "PASS":
            f.write("// 這是 PASS 的圖片，請將以下程式碼貼到 PATTERN.sv 中的 YOU_PASS_TASK 裡\n")
            f.write("task YOU_PASS_TASK; begin\n")
            for i, line in enumerate(ascii_lines):
                suffix = SUFFIX_PROCESSED_PASS[i] if i < len(SUFFIX_PROCESSED_PASS) else ""
                f.write(f'    $display("{line}{suffix}");\n')
            if len(ascii_lines) < len(SUFFIX_PROCESSED_PASS):
                pad_spaces = " " * new_width
                for i in range(len(ascii_lines), len(SUFFIX_PROCESSED_PASS)):
                    f.write(f'    $display("{pad_spaces}{SUFFIX_PROCESSED_PASS[i]}");\n')
            f.write("end endtask\n")
        
        elif type_check == "FAIL":
            f.write("// 這是 FAIL 的圖片，請將以下程式碼貼到 PATTERN.sv 中的 YOU_FAIL_TASK 裡\n")
            f.write("task YOU_FAIL_TASK; begin\n")
            total_lines = max(len(ascii_lines), len(SUFFIX_PROCESSED_FAIL))
            img_pad_top = total_lines - len(ascii_lines)
            suf_pad_top = total_lines - len(SUFFIX_PROCESSED_FAIL)
            for i in range(total_lines):
                img_str = ascii_lines[i - img_pad_top] if i >= img_pad_top else " " * new_width
                suf_str = SUFFIX_PROCESSED_FAIL[i - suf_pad_top] if i >= suf_pad_top else ""
                f.write(f'    $display("{img_str}{suf_str}");\n')
            f.write("end endtask\n")

if __name__ == '__main__':
    main()