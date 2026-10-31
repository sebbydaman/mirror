$ErrorActionPreference = 'Stop'

$out = Join-Path $PWD 'baseline-capture'
New-Item -ItemType Directory -Force -Path $out | Out-Null

git rev-parse HEAD | Set-Content (Join-Path $out 'HEAD.txt') -Encoding utf8
git status --porcelain=v1 | Set-Content (Join-Path $out 'STATUS.txt') -Encoding utf8
git log --oneline --decorate -80 | Set-Content (Join-Path $out 'LOG.txt') -Encoding utf8
git diff --name-status 01effa81ab0e151f8cfd674bf4da952d24645943..HEAD | Set-Content (Join-Path $out 'CHANGED_FILES.txt') -Encoding utf8
git diff --binary 01effa81ab0e151f8cfd674bf4da952d24645943..HEAD | Set-Content (Join-Path $out 'BASELINE.patch') -Encoding utf8
git diff --binary | Set-Content (Join-Path $out 'WORKTREE.patch') -Encoding utf8

git bundle create (Join-Path $out 'integrated-history.bundle') HEAD

Write-Host "Captured integrated NS2 baseline metadata, committed patch, worktree patch, and Git bundle."
