& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/b').Content)) -Tool serverdiag
