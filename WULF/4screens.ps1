# ==========================================================
# 4SCREENS
# Eine Windows-Terminal-Instanz
# 4x PowerShell 7.6.5
# Exakt 4 gleich große Panes untereinander
# ==========================================================

wt.exe -w new `
    new-tab pwsh.exe `; `
    split-pane --horizontal --size 0.25 pwsh.exe `; `
    move-focus up `; `
    split-pane --horizontal --size 0.3333 pwsh.exe `; `
    move-focus up `; `
    split-pane --horizontal --size 0.5 pwsh.exe