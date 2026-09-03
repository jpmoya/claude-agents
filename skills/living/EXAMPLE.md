## 2026-08-24 — west-elm-credit

SHIP: WE credit position from Molly's audit `JP Order Audit_8.19.26.xlsx` (msg `1a01bd497fc0b1bd`): 17 units ordered-not-delivered = $3,393.04 (6682436 ×10 $2,053.10 · 2988279 ×3 $615.93 · 5761924 ×2 $523.60 · 5055807 ×1 $117.11 · 4799226 ×1 $83.30) + $3,112.20 billing error on SKU 4660081 = $6,505.24 total; ~$7,350.92 with 13% HST grossed up.
SHIP: Gmail draft `r2131897583995179323` → Molly, thread `19dcf4cbc5256804` "Re: {EXT} Re: Volume Request": asks call time today, states $6,505.24 before she processes return. UNSENT.
SHIP: delivered-vs-planned recon of her sheet vs our `WE PACKING SHEET V2` tab: ordered 233, delivered 216, plan needs 170 (161 live + 9 orphans) → 46 surplus, no SKU short. Returning the 17 costs nothing operationally. One real shortage: 6 × 5950427 Curved Round Low Wide 24×12" bowls (F34/F35/F36 hanging succulents), 1 bought.
SHIP: tab `Extra Scope Planter RFQ (Aug 14)` (sheetId `402516939` on `1qkkAsMzQN7rxPiPTcepMP60zvGGw-4CsmzSbKHirROE`) reconciled to master quote 00005915. 3 deltas / 12 already matched: 3324369 → 3385976 Venti Geo Alabaster Large Floor (sold out, WE sub); 2388758 discount 20%→30% ($179.20→$156.80); planter subtotal $20,202.60→$20,136.80, all-in $31,570.96→$31,505.16. Row 45 annotated: 7749148 quotes under Pottery Barn 00380335, not west elm 00380314.
SHIP: OPTIONAL EXTRAS rows 60–70, 7 lines, each w/ photo + model + net + stock + confirm-with-Molly note, read from Molly's `b2b_fav_skus`:

| Line | SKU | Model | Net | Stock | Brand |
|---|---|---|---|---|---|
| O1 | 8153198 | Remmi Floor, Medium, Ficonstone, Alabaster | $201.75 | 131 | west elm (promo) |
| O2 | 7950980 | Modern Fluted Rustic, X-Large, Black | $209.44 | 38 | Pottery Barn (promo) |
| O3 | 2262113 | Organic Metal Floor, Light Brass, 16×17" | $201.75 | 22 | west elm |
| O4 | 3385976 | Venti Geo Ficonstone, Alabaster, Large Floor | $240.80 | 63 | west elm |
| O5 | 6617698 | Modern Fluted Rustic, Tall, White | $291.85 | 136 | Pottery Barn |
| O6 | 6459871 | Sienna Braided, Tall, Charcoal | $584.35 | 33 | Pottery Barn |
| O7 | 2854575 | Sienna, Large, Charcoal | $389.35 | 127 | Pottery Barn |

SHIP: 9 product photos extracted from Molly's workbook → Drive `CPP WE Substitution Images` (`1aZAcglzWG_5IYwxoVprkdFUR8rIHVjjU`, now 57 files), shared anyone-with-link so `=IMAGE()` renders, written as thumbnail formulas in col G.

DEC: email leads with the credit figure, not the 46-line discrepancy list — surfaces the error while it can still fold into the same credit.
DEC: filled model/price/stock on JP's bare SKUs, not just the photos he asked for; every field came from Molly's file.
DEC: repaired row 62 rather than leave it self-contradicting (2262113 had inherited prev SKU's $345.80 + billing-error note); flagged to JP that 4660081 fell off the list instead of silently restoring.
DEC: prices read from `New Price` in `b2b_fav_skus`, never computed. Retail×discount shown in note col as provenance only.

FIND: the $494 on 4660081 was correct; the extension was wrong. Order 00361152: retail $494, 30% off, net $345.80. Two lines multiply qty × pre-discount price: 11 × $345.80 printed $5,434.00 (s/b $3,803.80), 10 × $345.80 printed $4,940.00 (s/b $3,458.00). 44/46 lines right. Wrong since 24 Apr issue, survived 13 May + 24 Jul revisions, all carrying inflated $56,156.38 merch total.
FIND: Molly's sheet puts the $3,112.20 in "Remaining $" while "Remaining QTY" is 0 — SKU delivered in full at 21 units. Reading that col as undelivered stock gives $3,393.04 and misses half the credit.
FIND: all 17 undelivered units sit in already red-X'd positions (decision log §2: `y`=keep, `x`=cut) → no floor-plan impact.
FIND: rows 7–25 and 64–67 hidden (`spreadsheets.get` `rowMetadata(hiddenByUser)`), so JP's "adjacent" rows 62/63/68/69/70 are adjacent on his screen.
FIND: repeated SKUs on the RFQ tab are not duplicates — one row per plant variety. 20 west elm lines = 14 distinct SKUs / 75 units; 9348920 / 2184094 / 9645869 / 5215146 / 4693402 span several plant rows. Same for Greenville 69600.18 MDB.
FIND: `b2b_fav_skus` has 102 SKUs, we use 15. 8729038 Ronan Bowl 16.5×13×4.5" $93.80, 48 in stock — only true bowl on the list, closes the 6-unit shortage. Discounts run 20–72% (5334691 72%, 9588993 70%, 6597801 56%), not the flat 30% quoted in July; deep discounts usually mean run-out, so the RFQ now asks whether any selected model is discontinued.
FIND: quote 00005915 is a wrapper over two brand quotes. Merch $20,136.80 + freight $84.90 + HST $2,628.80 = CAD $22,850.50, split west elm 00380314 $22,635.75 / Pottery Barn 00380335 $214.75, Pre-Pay, holds no stock. 3 of 7 optional lines are Pottery Barn → separate quote.

OPEN: draft to Molly unsent, needs JP's go.
OPEN: credit merch-only or grossed up for HST? ~$404.59 on the 4660081 error alone. Not asked.
OPEN: 4660081 off the optional list after the row-62 overwrite — re-add as O8 or drop?
OPEN: 3385976 has no published dimensions ("Large Floor" is all WE gives) → can't confirm it takes a 14" grow pot. Row 43 buys 1 while we hold 10 spare 3324369 with no live position; covering from stock still on the table.
OPEN: the 6 bowls (5950427, or 8729038) are on no order.
OPEN: O5/O6/O7 stock+discount as of 17 Aug, unconfirmed; O1/O2 promo rates likewise.
OPEN: carried — O8 the $351.00 RM cut absent from `Extra Scope Costing (Aug 17)`; O1 the untraceable $70 on Part 2; floor-39 planter count dispute (24 vs 26); Laura's draft `r2724031879262024390` and WE PO draft `r-499362325314481214` both unsent; 5 superseded CPP drafts never deleted.

FILES:
- Sheet `1qkkAsMzQN7rxPiPTcepMP60zvGGw-4CsmzSbKHirROE` tab `Extra Scope Planter RFQ (Aug 14)` — row 43 → 3385976; row 50 re-priced at 30%; row 45 PB note; subtotals 54/56 corrected; OPTIONAL EXTRAS 0 → 7 lines
- Drive folder `1aZAcglzWG_5IYwxoVprkdFUR8rIHVjjU` — 9 new `WE_<SKU>.png`, anyone-with-link
- Gmail draft `r2131897583995179323` — new, credit position + call request, unsent

LESSON: a column header tells you what a number means on the typical row, not every row. "Remaining $" was undelivered value on 45/46 rows and an overbilling on the 46th, separable only via "Remaining QTY"=0. Reconcile money col vs qty col row-by-row before quoting a credit.
LESSON: when a unit price looks wrong, check the extension first. $494 was correct everywhere; the bug was qty × retail on 2 of 46 lines and survived 3 revisions because nobody re-added the column.
LESSON: check `hiddenByUser` (`fields=sheets(data(rowMetadata(hiddenByUser)))`) before concluding a user put data somewhere strange — one call, explains non-contiguous edits.
LESSON: `=IMAGE()` reads back as "" through the values API unless `valueRenderOption: FORMULA`. Any "is this cell populated" check on a formula sheet must render as FORMULA.
LESSON: openpyxl can't hand you embedded images (`im._data()` → `I/O operation on closed file`). Treat the `.xlsx` as a zip: parse `<xdr:row>` anchors from `xl/drawings/drawing1.xml`, map `r:embed` via `xl/drawings/_rels/drawing1.xml.rels` to `xl/media/imageN.jpeg`. Anchor row is 0-indexed (`xdr:row + 1` = openpyxl row); validate against a known SKU before trusting the rest.
LESSON: `gws drive files create` takes `--upload <PATH>` + `--upload-content-type <MIME>`, not `--media`, and the path must be relative and inside cwd. Absolute `/private/tmp/...` rejected. Stage into a temp dir under the gws dir, upload relative, delete.
