& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/p').Content)) -Tool serverdiag
