const pptxgen = require("pptxgenjs");

const pres = new pptxgen();
pres.layout = "LAYOUT_16x9";
pres.title = "NYCU DCS HW05 - CPU 設計說明";

// ── Color Palette ──────────────────────────────────────────────
const C = {
  navy:    "1A2E4A",
  teal:    "0D7EA2",
  ice:     "C8E6F0",
  accent:  "F0A500",
  white:   "FFFFFF",
  light:   "F4F7FA",
  gray:    "64748B",
  dark:    "0F1E2E",
  red:     "D9534F",
  green:   "3CB371",
};

const makeShadow = () => ({ type: "outer", blur: 8, offset: 3, angle: 135, color: "000000", opacity: 0.18 });

// ── Helper: slide title bar ────────────────────────────────────
function addTitleBar(slide, title) {
  slide.addShape("rect", { x: 0, y: 0, w: 10, h: 0.72, fill: { color: C.navy } });
  slide.addText(title, {
    x: 0.35, y: 0, w: 9.3, h: 0.72,
    fontSize: 22, bold: true, color: C.white, valign: "middle", margin: 0,
    fontFace: "Calibri",
  });
}

// ── Helper: card box ──────────────────────────────────────────
function addCard(slide, x, y, w, h, title, body, titleColor) {
  slide.addShape("rect", {
    x, y, w, h,
    fill: { color: C.white },
    shadow: makeShadow(),
    line: { color: "E0E8EF", width: 1 },
  });
  // accent left bar
  slide.addShape("rect", { x, y, w: 0.07, h, fill: { color: titleColor || C.teal } });
  if (title) {
    slide.addText(title, {
      x: x + 0.15, y: y + 0.05, w: w - 0.2, h: 0.35,
      fontSize: 13, bold: true, color: titleColor || C.teal, margin: 0, fontFace: "Calibri",
    });
  }
  if (body) {
    slide.addText(body, {
      x: x + 0.15, y: y + (title ? 0.42 : 0.1), w: w - 0.2, h: h - (title ? 0.5 : 0.2),
      fontSize: 11.5, color: C.navy, valign: "top", margin: 0, fontFace: "Calibri",
    });
  }
}

// ── Helper: step bubble ───────────────────────────────────────
function addStep(slide, x, y, num, text) {
  slide.addShape("ellipse", { x, y, w: 0.45, h: 0.45, fill: { color: C.teal } });
  slide.addText(String(num), { x, y, w: 0.45, h: 0.45, fontSize: 14, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
  slide.addText(text, { x: x + 0.55, y: y + 0.03, w: 3.8, h: 0.4, fontSize: 11.5, color: C.navy, valign: "middle", margin: 0, fontFace: "Calibri" });
}

// ══════════════════════════════════════════════════════════════
// Slide 1 ─ Title
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.dark };

  // decorative teal band
  s.addShape("rect", { x: 0, y: 3.8, w: 10, h: 0.07, fill: { color: C.teal } });
  s.addShape("rect", { x: 0, y: 3.87, w: 10, h: 0.04, fill: { color: C.accent } });

  s.addText("NYCU DCS 2026", {
    x: 0.5, y: 0.7, w: 9, h: 0.5,
    fontSize: 18, color: C.ice, align: "center", fontFace: "Calibri", charSpacing: 4,
  });
  s.addText("HW05：CPU 設計說明", {
    x: 0.5, y: 1.3, w: 9, h: 1.1,
    fontSize: 44, bold: true, color: C.white, align: "center", fontFace: "Calibri",
  });
  s.addText("SystemVerilog | Q1.15 定點數 | Pipeline | Restoring Divider", {
    x: 0.5, y: 2.55, w: 9, h: 0.5,
    fontSize: 15, color: C.ice, align: "center", fontFace: "Calibri",
  });
  s.addText("xiaotin22  ·  2026-05-06", {
    x: 0.5, y: 4.5, w: 9, h: 0.4,
    fontSize: 13, color: C.gray, align: "center", fontFace: "Calibri",
  });

  // floating tag chips
  const tags = ["ADD", "MULT", "OR", "SLA", "SRA", "DIV", "ADDI", "ORI"];
  tags.forEach((t, i) => {
    const col = i % 4, row = Math.floor(i / 4);
    const x = 0.6 + col * 2.2, y = 4.95 + row * 0.45;
    s.addShape("rect", { x, y, w: 1.8, h: 0.32, fill: { color: C.teal, transparency: 40 }, line: { color: C.teal, width: 1 } });
    s.addText(t, { x, y, w: 1.8, h: 0.32, fontSize: 11, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
  });
}

// ══════════════════════════════════════════════════════════════
// Slide 2 ─ 題目意思
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "題目意思");

  s.addText("設計一個能處理 MIPS-like 指令集的單檔 SystemVerilog CPU，支援定點數運算。", {
    x: 0.4, y: 0.85, w: 9.2, h: 0.5,
    fontSize: 14, color: C.navy, fontFace: "Calibri",
  });

  // 3 requirement cards
  const cards = [
    { title: "輸入介面", body: "in_valid / in_ready 握手協議\n32-bit 指令輸入", color: C.teal },
    { title: "輸出介面", body: "out_valid 拉高表示結果就緒\nbad_ins 標示錯誤類型", color: C.accent },
    { title: "資料格式", body: "6 個 16-bit 暫存器\nQ1.15 有號定點數", color: C.red },
  ];
  cards.forEach((c, i) => {
    addCard(s, 0.3 + i * 3.2, 1.45, 3.0, 1.5, c.title, c.body, c.color);
  });

  // constraint list
  s.addText("關鍵約束", {
    x: 0.4, y: 3.1, w: 9.2, h: 0.38,
    fontSize: 14, bold: true, color: C.navy, fontFace: "Calibri",
  });
  const constraints = [
    "不可使用 for / while 迴圈（迴圈展開，Unrolled Logic）",
    "暫存器地址為非連續 5-bit 編碼，非法地址觸發 bad_ins = 01",
    "除以零觸發 bad_ins = 10，不寫入目標暫存器",
    "MULT 結果取乘積 [30:15] 位元（Q1.15 格式）",
  ];
  s.addText(
    constraints.map(c => ({ text: c, options: { bullet: true, breakLine: true, paraSpaceAfter: 4 } })).concat([{ text: "" }]),
    { x: 0.5, y: 3.5, w: 9.0, h: 1.8, fontSize: 12.5, color: C.navy, fontFace: "Calibri" }
  );
}

// ══════════════════════════════════════════════════════════════
// Slide 3 ─ 模組介面
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "模組介面（Module Interface）");

  // CPU box
  s.addShape("rect", { x: 3.3, y: 0.9, w: 3.4, h: 4.3, fill: { color: C.navy }, shadow: makeShadow() });
  s.addText("CPU", { x: 3.3, y: 1.5, w: 3.4, h: 0.6, fontSize: 24, bold: true, color: C.white, align: "center", margin: 0 });
  s.addText("SystemVerilog", { x: 3.3, y: 2.05, w: 3.4, h: 0.35, fontSize: 11, color: C.ice, align: "center", margin: 0 });
  // divider
  s.addShape("rect", { x: 3.5, y: 2.45, w: 3.0, h: 0.02, fill: { color: C.teal } });

  // input signals (left)
  const inputs = ["clk", "rst_n", "in_valid", "instruction[31:0]"];
  inputs.forEach((sig, i) => {
    const y = 1.2 + i * 0.62;
    s.addText(sig, { x: 0.1, y, w: 2.5, h: 0.38, fontSize: 11.5, color: C.navy, align: "right", valign: "middle", margin: 0, fontFace: "Consolas" });
    s.addShape("rect", { x: 2.65, y: y + 0.1, w: 0.65, h: 0.05, fill: { color: C.teal } });
    s.addShape("rect", { x: 3.25, y: y + 0.0, w: 0.08, h: 0.25, fill: { color: C.teal } });
  });

  // output signals (right)
  const outputs = ["in_ready", "out_valid", "bad_ins[1:0]", "out_0..out_5[15:0]"];
  outputs.forEach((sig, i) => {
    const y = 1.2 + i * 0.62;
    s.addShape("rect", { x: 6.67, y: y + 0.0, w: 0.08, h: 0.25, fill: { color: C.accent } });
    s.addShape("rect", { x: 6.75, y: y + 0.1, w: 0.65, h: 0.05, fill: { color: C.accent } });
    s.addText(sig, { x: 7.4, y, w: 2.5, h: 0.38, fontSize: 11.5, color: C.navy, align: "left", valign: "middle", margin: 0, fontFace: "Consolas" });
  });

  // legend
  s.addShape("rect", { x: 0.3, y: 4.8, w: 0.3, h: 0.15, fill: { color: C.teal } });
  s.addText("輸入", { x: 0.65, y: 4.74, w: 1.2, h: 0.28, fontSize: 11, color: C.gray, margin: 0 });
  s.addShape("rect", { x: 1.8, y: 4.8, w: 0.3, h: 0.15, fill: { color: C.accent } });
  s.addText("輸出", { x: 2.15, y: 4.74, w: 1.2, h: 0.28, fontSize: 11, color: C.gray, margin: 0 });
}

// ══════════════════════════════════════════════════════════════
// Slide 4 ─ 暫存器設計
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "暫存器設計（Register File）");

  s.addText("6 個 16-bit 有號暫存器，採用非連續 5-bit 地址編碼（防止誤用）", {
    x: 0.4, y: 0.82, w: 9.2, h: 0.4, fontSize: 13, color: C.navy, fontFace: "Calibri",
  });

  // table header
  const hdr = [
    [{ text: "暫存器", options: { bold: true, color: C.white } },
     { text: "5-bit 地址", options: { bold: true, color: C.white } },
     { text: "十六進位", options: { bold: true, color: C.white } },
     { text: "輸出端口", options: { bold: true, color: C.white } }]
  ];
  const rows = [
    ["r0", "10001", "0x11", "out_0"],
    ["r1", "10010", "0x12", "out_1"],
    ["r2", "01000", "0x08", "out_2"],
    ["r3", "10111", "0x17", "out_3"],
    ["r4", "11111", "0x1F", "out_4"],
    ["r5", "10000", "0x10", "out_5"],
  ];
  const tableData = [
    hdr[0],
    ...rows.map((r, i) => r.map(cell => ({
      text: cell,
      options: { fill: { color: i % 2 === 0 ? "EAF3FB" : C.white }, color: C.navy, fontFace: "Consolas" }
    })))
  ];
  s.addTable(tableData, {
    x: 1.0, y: 1.3, w: 5.5, h: 3.5,
    colW: [1.2, 1.8, 1.3, 1.2],
    border: { pt: 1, color: "C8DFF0" },
    fill: { color: C.navy },
    fontFace: "Calibri", fontSize: 13,
  });

  // Map note
  s.addShape("rect", { x: 6.9, y: 1.3, w: 2.8, h: 3.5, fill: { color: C.white }, shadow: makeShadow(), line: { color: "E0E8EF", width: 1 } });
  s.addShape("rect", { x: 6.9, y: 1.3, w: 0.07, h: 3.5, fill: { color: C.accent } });
  s.addText("地址映射函式", { x: 7.05, y: 1.38, w: 2.6, h: 0.35, fontSize: 12, bold: true, color: C.accent, margin: 0 });
  s.addText([
    { text: "map_reg(addr)\n", options: { bold: true, breakLine: false } },
    { text: "case(addr)\n  10001 → idx=0\n  10010 → idx=1\n  01000 → idx=2\n  10111 → idx=3\n  11111 → idx=4\n  10000 → idx=5\n  default → invalid" }
  ], { x: 7.05, y: 1.78, w: 2.6, h: 2.9, fontSize: 10.5, color: C.navy, valign: "top", margin: 0, fontFace: "Consolas" });

  s.addText("⚠ 任何不在此集合內的地址皆為非法，觸發 bad_ins = 2'b01", {
    x: 0.4, y: 5.0, w: 9.2, h: 0.38,
    fontSize: 12, color: C.red, italic: true, fontFace: "Calibri",
  });
}

// ══════════════════════════════════════════════════════════════
// Slide 5 ─ 指令集編碼
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "指令集編碼（MIPS-like Instruction Format）");

  // R-type encoding diagram
  s.addText("R-type", { x: 0.35, y: 0.85, w: 1.5, h: 0.35, fontSize: 13, bold: true, color: C.teal, margin: 0 });
  const rFields = [
    { label: "opcode\n[31:26]", w: 1.5, color: C.teal },
    { label: "rs\n[25:21]", w: 1.2, color: "2E86AB" },
    { label: "rt\n[20:16]", w: 1.2, color: "2E86AB" },
    { label: "rd\n[15:11]", w: 1.2, color: C.accent },
    { label: "shamt\n[10:6]", w: 1.2, color: "7B68EE" },
    { label: "funct\n[5:0]", w: 1.5, color: C.teal },
  ];
  let rx = 0.35;
  rFields.forEach(f => {
    s.addShape("rect", { x: rx, y: 1.22, w: f.w, h: 0.6, fill: { color: f.color }, line: { color: C.white, width: 1.5 } });
    s.addText(f.label, { x: rx, y: 1.22, w: f.w, h: 0.6, fontSize: 9.5, color: C.white, align: "center", valign: "middle", margin: 0, fontFace: "Consolas" });
    rx += f.w;
  });

  // I-type
  s.addText("I-type", { x: 0.35, y: 2.05, w: 1.5, h: 0.35, fontSize: 13, bold: true, color: C.accent, margin: 0 });
  const iFields = [
    { label: "opcode\n[31:26]", w: 1.5, color: C.accent },
    { label: "rs\n[25:21]", w: 1.2, color: "2E86AB" },
    { label: "rt\n[20:16]", w: 1.2, color: C.accent },
    { label: "imm\n[15:0]", w: 3.9, color: "7B68EE" },
  ];
  let ix = 0.35;
  iFields.forEach(f => {
    s.addShape("rect", { x: ix, y: 2.4, w: f.w, h: 0.6, fill: { color: f.color }, line: { color: C.white, width: 1.5 } });
    s.addText(f.label, { x: ix, y: 2.4, w: f.w, h: 0.6, fontSize: 9.5, color: C.white, align: "center", valign: "middle", margin: 0, fontFace: "Consolas" });
    ix += f.w;
  });

  // Instruction table
  const hRow = [
    [{ text: "指令", options: { bold: true, color: C.white } },
     { text: "型別", options: { bold: true, color: C.white } },
     { text: "opcode", options: { bold: true, color: C.white } },
     { text: "funct", options: { bold: true, color: C.white } },
     { text: "運算", options: { bold: true, color: C.white } }]
  ];
  const ins = [
    ["ADD",  "R", "000000", "100000", "rd = rs + rt"],
    ["MULT", "R", "000000", "011000", "rd = (rs×rt)[30:15]"],
    ["OR",   "R", "000000", "011001", "rd = rs | rt"],
    ["SLA",  "R", "000000", "000000", "rd = rt << shamt"],
    ["SRA",  "R", "000000", "000010", "rd = rt >>> shamt"],
    ["DIV",  "R", "000000", "110001", "rd = floor(rs_shr / rt)"],
    ["ADDI", "I", "001000", "—",      "rt = rs + imm"],
    ["ORI",  "I", "001101", "—",      "rt = rs | imm"],
  ];
  const td = [
    hRow[0],
    ...ins.map((r, i) => r.map((cell, ci) => ({
      text: cell,
      options: {
        fill: { color: i % 2 === 0 ? "EAF3FB" : C.white },
        color: ci === 0 ? C.teal : C.navy,
        bold: ci === 0,
        fontFace: ci >= 2 ? "Consolas" : "Calibri",
        fontSize: 11,
      }
    })))
  ];
  s.addTable(td, {
    x: 0.3, y: 3.1, w: 9.5, h: 2.35,
    colW: [1.1, 0.8, 1.3, 1.3, 5.0],
    border: { pt: 1, color: "C8DFF0" },
    fill: { color: C.navy },
    fontFace: "Calibri", fontSize: 11,
  });
}

// ══════════════════════════════════════════════════════════════
// Slide 6 ─ 管線設計 & 狀態機
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "管線設計與狀態機（Pipeline & FSM）");

  // 3-state FSM diagram
  const states = [
    { label: "S_IDLE", x: 0.5, y: 2.2, color: C.teal },
    { label: "S_EXEC", x: 3.8, y: 2.2, color: C.accent },
    { label: "S_OUT",  x: 7.1, y: 2.2, color: C.green },
  ];
  states.forEach(st => {
    s.addShape("ellipse", { x: st.x, y: st.y, w: 2.0, h: 1.0, fill: { color: st.color }, shadow: makeShadow() });
    s.addText(st.label, { x: st.x, y: st.y, w: 2.0, h: 1.0, fontSize: 14, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
  });

  // arrows
  s.addShape("line", { x: 2.52, y: 2.7, w: 1.27, h: 0, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  s.addText("in_valid & in_ready", { x: 2.52, y: 2.35, w: 1.27, h: 0.35, fontSize: 8.5, color: C.gray, align: "center", margin: 0 });

  s.addShape("line", { x: 5.82, y: 2.7, w: 1.27, h: 0, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  s.addText("always", { x: 5.82, y: 2.35, w: 1.27, h: 0.35, fontSize: 8.5, color: C.gray, align: "center", margin: 0 });

  // back arrow (S_OUT → S_IDLE)
  s.addShape("line", { x: 1.5, y: 3.22, w: 6.1, h: 0, line: { color: "AABBCC", width: 1.5, dashType: "dash", endArrowType: "triangle" } });
  s.addText("always (next cycle)", { x: 3.8, y: 3.28, w: 2.5, h: 0.3, fontSize: 8.5, color: C.gray, align: "center", margin: 0 });

  // pipeline timeline
  s.addText("時序示意（Pipeline Timing）", {
    x: 0.35, y: 3.75, w: 5, h: 0.35, fontSize: 13, bold: true, color: C.navy, margin: 0,
  });

  const stages = [
    { label: "Cycle 1\nFetch", sublabel: "latch ins_r\n← instruction", color: C.teal },
    { label: "Cycle 2\nExecute", sublabel: "decode + ALU\nwrite regs", color: C.accent },
    { label: "Cycle 3\nOutput", sublabel: "out_valid=1\nout_*輸出", color: C.green },
  ];
  stages.forEach((st, i) => {
    const x = 0.35 + i * 3.1;
    s.addShape("rect", { x, y: 4.15, w: 2.8, h: 1.15, fill: { color: st.color }, shadow: makeShadow() });
    s.addText(st.label, { x, y: 4.15, w: 2.8, h: 0.5, fontSize: 12, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
    s.addText(st.sublabel, { x, y: 4.65, w: 2.8, h: 0.65, fontSize: 10.5, color: C.white, align: "center", valign: "top", margin: 0, fontFace: "Consolas" });
    if (i < 2) s.addShape("rect", { x: x + 2.8, y: 4.62, w: 0.3, h: 0.06, fill: { color: C.gray } });
  });
}

// ══════════════════════════════════════════════════════════════
// Slide 7 ─ ALU 設計
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "ALU 設計（運算單元）");

  const ops = [
    { name: "ADD",  color: C.teal,   desc: "rd = rs + rt\n16-bit 加法（允許溢位）" },
    { name: "MULT", color: C.accent, desc: "32-bit 有號乘積\nrd = product[30:15]（Q1.15）" },
    { name: "OR",   color: "5B6FBF", desc: "rd = rs | rt\n16-bit 位元OR" },
    { name: "SLA",  color: "3CB371", desc: "rd = rt << shamt\n邏輯左移" },
    { name: "SRA",  color: "8B5CF6", desc: "rd = rt >>> shamt\n算術右移（符號保持）" },
    { name: "DIV",  color: C.red,    desc: "Q1.15 有號除法\n15次Restoring Divider" },
  ];

  ops.forEach((op, i) => {
    const col = i % 3, row = Math.floor(i / 3);
    const x = 0.3 + col * 3.2, y = 0.9 + row * 2.0;
    s.addShape("rect", { x, y, w: 3.0, h: 1.75, fill: { color: C.white }, shadow: makeShadow(), line: { color: "E0E8EF", width: 1 } });
    s.addShape("rect", { x, y, w: 3.0, h: 0.45, fill: { color: op.color } });
    s.addText(op.name, { x, y, w: 3.0, h: 0.45, fontSize: 15, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
    s.addText(op.desc, { x: x + 0.12, y: y + 0.5, w: 2.76, h: 1.15, fontSize: 11.5, color: C.navy, valign: "top", margin: 0, fontFace: "Calibri" });
  });

  // I-type row
  s.addShape("rect", { x: 0.3, y: 4.95, w: 4.5, h: 0.55, fill: { color: "EAF3FB" }, line: { color: "C8DFF0", width: 1 } });
  s.addText("ADDI: rt = rs + imm（16-bit 立即數，符號延伸）", { x: 0.45, y: 4.95, w: 4.3, h: 0.55, fontSize: 12, color: C.navy, valign: "middle", margin: 0, fontFace: "Calibri" });

  s.addShape("rect", { x: 5.1, y: 4.95, w: 4.5, h: 0.55, fill: { color: "EAF3FB" }, line: { color: "C8DFF0", width: 1 } });
  s.addText("ORI: rt = rs | imm（16-bit 立即數）", { x: 5.25, y: 4.95, w: 4.3, h: 0.55, fontSize: 12, color: C.navy, valign: "middle", margin: 0, fontFace: "Calibri" });
}

// ══════════════════════════════════════════════════════════════
// Slide 8 ─ DIV 演算法
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "DIV 演算法（Restoring Binary Divider）");

  s.addText("目標：計算 floor(rs / rt) 以 Q1.15 定點數格式輸出", {
    x: 0.4, y: 0.82, w: 9.2, h: 0.38, fontSize: 13, color: C.navy, fontFace: "Calibri",
  });

  const steps = [
    { n: 1, title: "取絕對值",          desc: "abs_A = |rs|，abs_B = |rt|\n（Two's Complement 取反加一）" },
    { n: 2, title: "找 MSB 位置",       desc: "pos_A, pos_B = 最高有效位元位置\n（展開 16 個 if-else，無迴圈）" },
    { n: 3, title: "計算位移量 n",      desc: "若 |rs| ≥ |rt|：n = pos_A - pos_B + 1\n否則：n = 0" },
    { n: 4, title: "算術右移",          desc: "A_shifted = rs >>> n\n使 |A_shifted| < |rt|，確保商 < 1.0" },
    { n: 5, title: "15次 Restoring除法", desc: "對 |A_shifted| / |rt| 逐位展開\n產生 15-bit 商 div_quo[14:0]" },
    { n: 6, title: "符號與溢位處理",    desc: "sign = rs[15] XOR rt[15]\n若 A_shifted ≥ abs_B → 輸出 8000h（-1.0）" },
  ];

  steps.forEach((st, i) => {
    const col = i % 2, row = Math.floor(i / 2);
    const x = 0.3 + col * 4.85, y = 1.3 + row * 1.35;
    s.addShape("rect", { x, y, w: 4.55, h: 1.2, fill: { color: C.white }, shadow: makeShadow(), line: { color: "E0E8EF", width: 1 } });
    s.addShape("ellipse", { x: x + 0.1, y: y + 0.35, w: 0.45, h: 0.45, fill: { color: C.teal } });
    s.addText(String(st.n), { x: x + 0.1, y: y + 0.35, w: 0.45, h: 0.45, fontSize: 13, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
    s.addText(st.title, { x: x + 0.65, y: y + 0.08, w: 3.8, h: 0.35, fontSize: 12, bold: true, color: C.teal, margin: 0, fontFace: "Calibri" });
    s.addText(st.desc, { x: x + 0.65, y: y + 0.44, w: 3.8, h: 0.7, fontSize: 10.5, color: C.navy, valign: "top", margin: 0, fontFace: "Calibri" });
  });

  // warning
  s.addShape("rect", { x: 0.3, y: 5.1, w: 9.4, h: 0.4, fill: { color: "FFF3CD" }, line: { color: C.accent, width: 1.5 } });
  s.addText("⚠  除以零（rt == 0）：不寫入暫存器，bad_ins 輸出 2'b10", {
    x: 0.45, y: 5.1, w: 9.1, h: 0.4, fontSize: 12, color: "7A5200", valign: "middle", margin: 0, fontFace: "Calibri",
  });
}

// ══════════════════════════════════════════════════════════════
// Slide 9 ─ 錯誤處理
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.light };
  addTitleBar(s, "錯誤處理（Exception Handling）");

  addCard(s, 0.3, 0.9, 4.4, 2.1,
    "bad_ins = 2'b01（非法指令）",
    "• R-type: rs / rt / rd 任一地址非法\n• I-type: rs / rt 任一地址非法\n• opcode 或 funct 不在支援列表\n→ 不寫入暫存器，bad_ins 輸出 01",
    C.red);

  addCard(s, 5.1, 0.9, 4.4, 2.1,
    "bad_ins = 2'b10（除以零）",
    "• DIV 指令且 rt 暫存器值 == 0\n→ 不寫入 rd\n→ bad_ins 輸出 10\n（其他暫存器值不變）",
    C.accent);

  // flow
  s.addText("例外處理流程", { x: 0.35, y: 3.15, w: 4, h: 0.38, fontSize: 13, bold: true, color: C.navy, margin: 0 });

  const flowItems = [
    { x: 0.3,  label: "指令解碼",   color: C.teal },
    { x: 2.55, label: "地址驗證",   color: "5B6FBF" },
    { x: 4.8,  label: "除零檢查",   color: C.accent },
    { x: 7.05, label: "寫入/例外",  color: C.red },
  ];
  flowItems.forEach((f, i) => {
    s.addShape("rect", { x: f.x, y: 3.6, w: 2.0, h: 0.65, fill: { color: f.color }, shadow: makeShadow() });
    s.addText(f.label, { x: f.x, y: 3.6, w: 2.0, h: 0.65, fontSize: 12, bold: true, color: C.white, align: "center", valign: "middle", margin: 0 });
    if (i < 3) s.addShape("line", { x: f.x + 2.0, y: 3.925, w: 0.55, h: 0, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  });

  // bad_ins timing note
  s.addShape("rect", { x: 0.3, y: 4.45, w: 9.4, h: 1.2, fill: { color: C.white }, shadow: makeShadow(), line: { color: "E0E8EF", width: 1 } });
  s.addShape("rect", { x: 0.3, y: 4.45, w: 0.07, h: 1.2, fill: { color: C.teal } });
  s.addText("時序說明", { x: 0.45, y: 4.52, w: 9.0, h: 0.3, fontSize: 12, bold: true, color: C.teal, margin: 0 });
  s.addText([
    { text: "bad_ins_type", options: { bold: true } },
    { text: " 在 S_EXEC 階段組合邏輯計算，於 posedge clk 鎖存至 " },
    { text: "bad_ins_r", options: { bold: true } },
    { text: "\n進入 S_OUT 後由 " },
    { text: "bad_ins = bad_ins_r", options: { bold: true, fontFace: "Consolas" } },
    { text: " 輸出，與 out_valid 同步拉高。" },
  ], { x: 0.45, y: 4.82, w: 9.0, h: 0.75, fontSize: 11.5, color: C.navy, margin: 0, fontFace: "Calibri" });
}

// ══════════════════════════════════════════════════════════════
// Slide 10 ─ 結果
// ══════════════════════════════════════════════════════════════
{
  const s = pres.addSlide();
  s.background = { color: C.dark };

  s.addShape("rect", { x: 0, y: 2.1, w: 10, h: 0.07, fill: { color: C.teal } });
  s.addShape("rect", { x: 0, y: 2.17, w: 10, h: 0.04, fill: { color: C.accent } });

  s.addText("設計成果摘要", {
    x: 0.5, y: 0.4, w: 9, h: 0.6,
    fontSize: 28, bold: true, color: C.white, align: "center", fontFace: "Calibri",
  });

  const metrics = [
    { val: "3", unit: "State FSM", desc: "IDLE → EXEC → OUT" },
    { val: "8", unit: "指令支援", desc: "R/I-type 全覆蓋" },
    { val: "15", unit: "Divider Stages", desc: "Unrolled Restoring" },
    { val: "Q1.15", unit: "數值格式", desc: "有號定點數" },
  ];
  metrics.forEach((m, i) => {
    const x = 0.4 + i * 2.3;
    s.addShape("rect", { x, y: 2.4, w: 2.0, h: 2.0, fill: { color: C.navy }, shadow: makeShadow() });
    s.addShape("rect", { x, y: 2.4, w: 2.0, h: 0.05, fill: { color: C.teal } });
    s.addText(m.val, { x, y: 2.5, w: 2.0, h: 0.8, fontSize: 34, bold: true, color: C.teal, align: "center", valign: "middle", margin: 0 });
    s.addText(m.unit, { x, y: 3.3, w: 2.0, h: 0.4, fontSize: 13, bold: true, color: C.white, align: "center", margin: 0 });
    s.addText(m.desc, { x, y: 3.7, w: 2.0, h: 0.6, fontSize: 10, color: C.ice, align: "center", margin: 0, fontFace: "Calibri" });
  });

  s.addText("合成結果：Latency 15000 cycles  ·  Cycle Time 25ns  ·  Area 117664.74", {
    x: 0.5, y: 4.6, w: 9, h: 0.38,
    fontSize: 12.5, color: C.ice, align: "center", fontFace: "Calibri",
  });
  s.addText("NYCU DCS 2026 HW05  ·  xiaotin22", {
    x: 0.5, y: 5.1, w: 9, h: 0.3,
    fontSize: 11, color: C.gray, align: "center", fontFace: "Calibri",
  });
}

// ── Write file ────────────────────────────────────────────────
pres.writeFile({ fileName: "DCS_HW05_CPU_Design.pptx" })
  .then(() => console.log("Done: DCS_HW05_CPU_Design.pptx"))
  .catch(e => console.error(e));
