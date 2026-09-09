Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = [Windows.Forms.Form]::new()
$form.Text = 'win-use-master smoke fixture'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [Drawing.Size]::new(520, 250)

$label = [Windows.Forms.Label]::new()
$label.Name = 'instructionLabel'
$label.Text = 'Safe local automation fixture'
$label.SetBounds(28, 25, 450, 28)

$edit = [Windows.Forms.TextBox]::new()
$edit.Name = 'fixtureInput'
$edit.AccessibleName = 'Fixture input'
$edit.SetBounds(28, 70, 455, 34)

$button = [Windows.Forms.Button]::new()
$button.Name = 'fixtureButton'
$button.AccessibleName = 'Apply fixture value'
$button.Text = 'Apply'
$button.SetBounds(28, 125, 120, 38)

$dangerButton = [Windows.Forms.Button]::new()
$dangerButton.Name = 'sendButton'
$dangerButton.AccessibleName = 'Continue'
$dangerButton.Text = 'Continue'
$dangerButton.SetBounds(160, 125, 90, 38)

$status = [Windows.Forms.Label]::new()
$status.Name = 'fixtureStatus'
$status.Text = 'status: idle'
$status.SetBounds(270, 132, 220, 30)
$button.Add_Click({ $status.Text = 'status: ' + $edit.Text })
$dangerButton.Add_Click({ $status.Text = 'status: DANGER-RAN' })

$form.Controls.AddRange(@($label, $edit, $button, $dangerButton, $status))
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 120000
$timer.Add_Tick({ $form.Close() })
$timer.Start()
[Windows.Forms.Application]::Run($form)
