# GitHub Actions Runner Service Removal (Windows)

## Purpose

This document describes how to remove a repository-level GitHub Actions self-hosted runner from a Windows test machine.

A complete removal has two parts:

1. Remove the Windows service and local runner installation.
2. Remove the runner registration from GitHub.

Removing only the Windows service leaves an obsolete runner registration in GitHub.

---

## 1. Stop the Windows service

Find the installed runner service:

```powershell
Get-Service | Where-Object {
    $_.DisplayName -like "*GitHub Actions Runner*"
}
```

Stop it:

```powershell
Stop-Service -Name "<service-name>"
```

Verify:

```powershell
Get-Service -Name "<service-name>"
```

The state should be `Stopped`.

---

## 2. Remove the Windows service

Recent GitHub Actions Runner versions use the service executable:

```
bin\RunnerService.exe
```

From the runner installation directory:

```powershell
.\bin\RunnerService.exe uninstall
```

If the service wrapper is unavailable, remove the service using Windows Service Control Manager:

```powershell
sc.exe delete "<service-name>"
```

Verify:

```powershell
Get-Service | Where-Object {
    $_.DisplayName -like "*GitHub Actions Runner*"
}
```

---

## 3. Remove runner registration from GitHub

Change to the runner directory:

```powershell
cd <runner-directory>
```

Execute:

```powershell
.\config.cmd remove
```

A GitHub remove token is required.

The token can be created here:

```
Repository
  -> Settings
     -> Actions
        -> Runners
           -> Remove runner
```

---

## 4. Remove local files

Only after the runner has been removed from GitHub:

```powershell
Remove-Item "<runner-directory>" -Recurse -Force
```

---

## 5. Optional: remove dedicated service account

If a dedicated Windows account was created only for the runner, remove its permissions first:

```powershell
net localgroup docker-users <service-account> /delete
net localgroup "Hyper-V Administrators" <service-account> /delete
net localgroup administrators <service-account> /delete
```

The account itself can then be removed according to the local Windows administration policy.

---

## 6. Important cleanup boundary

Removing the GitHub runner does **not** remove:

- Docker containers
- Docker images
- SQL Server test databases
- Hyper-V virtual machines
- test data directories

These must be removed separately and deliberately.

Avoid unrestricted cleanup commands on shared test machines.

---

## Troubleshooting

### No `svc.cmd` exists

Some runner versions do not provide `svc.cmd`.

Use:

```powershell
.\bin\RunnerService.exe uninstall
```

or remove the Windows service with:

```powershell
sc.exe delete "<service-name>"
```

The installed service executable can be checked with:

```powershell
sc.exe qc "<service-name>"
```
