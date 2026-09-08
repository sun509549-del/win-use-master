$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$renderer = [Windows.Forms.Form]::new()
$renderer.Text = 'win-use-master sibling renderer'
$renderer.StartPosition = 'Manual'
$renderer.Location = [Drawing.Point]::new(220, 180)
$renderer.Size = [Drawing.Size]::new(560, 340)
$renderer.BackColor = [Drawing.Color]::White

$banner = [Windows.Forms.Panel]::new()
$banner.Dock = 'Top'
$banner.Height = 90
$banner.BackColor = [Drawing.Color]::FromArgb(32, 92, 170)
$renderer.Controls.Add($banner)

$label = [Windows.Forms.Label]::new()
$label.Text = 'renderer evidence surface'
$label.Font = [Drawing.Font]::new('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$label.ForeColor = [Drawing.Color]::White
$label.AutoSize = $true
$label.Location = [Drawing.Point]::new(24, 26)
$banner.Controls.Add($label)

$blocks = @([Drawing.Color]::OrangeRed, [Drawing.Color]::MediumSeaGreen, [Drawing.Color]::MediumPurple)
for ($i = 0; $i -lt $blocks.Count; $i++) {
    $panel = [Windows.Forms.Panel]::new()
    $panel.BackColor = $blocks[$i]
    $panel.Location = [Drawing.Point]::new(34 + 170 * $i, 135)
    $panel.Size = [Drawing.Size]::new(135, 110)
    $renderer.Controls.Add($panel)
}

$shell = [Windows.Forms.Form]::new()
$shell.Text = 'win-use-master sibling shell'
$shell.StartPosition = 'Manual'
$shell.Location = $renderer.Location
$shell.Size = $renderer.Size
$shell.BackColor = [Drawing.Color]::Black

$renderer.Show()
$shell.Add_Shown({
    $shell.Location = $renderer.Location
    $shell.Size = $renderer.Size
    $shell.BringToFront()
})
[Windows.Forms.Application]::Run($shell)

$renderer.Dispose()
$shell.Dispose()
