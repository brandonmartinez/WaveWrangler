#!/bin/sh
# Reproduces every glyph-statistic figure in WW-007 evidence §10 (Mac mini (M2 Pro), products 475adf3).
# Regions are image-pixel rectangles @x,y,w,h (origin top-left) on the committed 2x crops:
# - "visible-text" / "text" regions cut out the cell's own text band, excluding scroller, divider, window border
#   and neighbouring-row pixels that the element screenshot also contains (see each crop).
# - "visible" regions on the Setup selected-row crops are the top 14 px band: the row is clipped by the Sources
#   table's scroll edge, and the lower band is the next row / table background.
# Output: glyphstat-results-475adf3.txt
cd "$(dirname "$0")"
swift ../glyphstat.swift \
 ic-shows-selected-100=mini-475adf3-ic-sidebar-shows-selected-100.png \
 ic-shows-selected-200=mini-475adf3-ic-sidebar-shows-selected-200.png \
 ic-date-cell-full=mini-475adf3-ic-date-cell.png \
 "ic-date-cell-visible-text=mini-475adf3-ic-date-cell.png@0,0,30,36" \
 ic-library-title-full=mini-475adf3-ic-library-title.png \
 "ic-library-title-text=mini-475adf3-ic-library-title.png@20,30,130,50" \
 aqua-date-cell-full=mini-475adf3-aqua-date-cell.png \
 "aqua-date-cell-visible-text=mini-475adf3-aqua-date-cell.png@0,0,30,36" \
 dark-sidebar-collection=mini-475adf3-dark-sidebar-collection.png \
 setup-row-status-full=mini-475adf3-setup-selected-row-clipped.png \
 "setup-row-status-visible=mini-475adf3-setup-selected-row-clipped.png@0,0,121,14" \
 setup-row-name-full=mini-475adf3-setup-selected-row-name.png \
 "setup-row-name-visible=mini-475adf3-setup-selected-row-name.png@0,0,108,14" \
 setup-row-speaker-full=mini-475adf3-setup-selected-row-speaker.png \
 "setup-row-speaker-visible=mini-475adf3-setup-selected-row-speaker.png@0,0,26,14" \
 setup-row-role-full=mini-475adf3-setup-selected-row-role.png \
 "setup-row-role-visible=mini-475adf3-setup-selected-row-role.png@0,0,24,14" \
 ic-setup-row-status-full=mini-475adf3-ic-setup-selected-row-clipped.png \
 "ic-setup-row-status-visible=mini-475adf3-ic-setup-selected-row-clipped.png@0,0,121,14" \
 ic-setup-row-name-full=mini-475adf3-ic-setup-selected-row-name.png \
 "ic-setup-row-name-visible=mini-475adf3-ic-setup-selected-row-name.png@0,0,108,14" \
 "ic-setup-row-speaker-visible=mini-475adf3-ic-setup-selected-row-speaker.png@0,0,26,14" \
 "ic-setup-row-role-visible=mini-475adf3-ic-setup-selected-row-role.png@0,0,24,14"
