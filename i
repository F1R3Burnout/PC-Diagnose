& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/r').Content.TrimStart([char]0xFEFF))) -Tool serverdiag
