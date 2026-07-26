@{
    SchemaVersion = '1.0'
    DataClassification = 'SYNTHETIC_EXAMPLE'
    ExecutionMode = 'AUTO'
    AllowedExecutionModes = @(
        'WINDOWS_SINGLE_HOST'
        'LINUX_NATIVE'
        'DISTRIBUTED'
    )
    SqlVersionPriority = @(2025, 2022, 2019)
    ContainerEngine = 'DOCKER'
    ContainerImageLogicalIds = @{
        '2019' = 'SQL_SERVER_2019_DEVELOPER_LINUX'
        '2022' = 'SQL_SERVER_2022_DEVELOPER_LINUX'
        '2025' = 'SQL_SERVER_2025_DEVELOPER_LINUX'
    }
    AcceptSqlServerEula = $false
    ResourceProfile = 'Compact'

    StorageRoleBindings = @{
        IMAGE_CACHE = 'LOCAL_TARGET_REFERENCE_REQUIRED'
        ACTIVE_VM = 'LOCAL_TARGET_REFERENCE_REQUIRED'
        EPHEMERAL_DATA = 'LOCAL_TARGET_REFERENCE_REQUIRED'
        FAULT_TARGET = 'DEDICATED_BOUNDED_TARGET_REFERENCE_REQUIRED'
    }

    StorageTargets = @(
        @{
            LogicalTargetId = 'LOCAL_TARGET_REFERENCE_REQUIRED'
            Path = 'LOCAL_PATH_REQUIRED'
            Roles = @(
                'IMAGE_CACHE'
                'ACTIVE_VM'
                'EPHEMERAL_DATA'
            )
            IsSystemTarget = $false
            IsApprovedLabTarget = $false
        }
        @{
            LogicalTargetId = 'DEDICATED_BOUNDED_TARGET_REFERENCE_REQUIRED'
            Path = 'LOCAL_FAULT_TARGET_PATH_REQUIRED'
            Roles = @('FAULT_TARGET')
            IsSystemTarget = $false
            IsApprovedLabTarget = $false
            MaximumSizeGiB = 64
        }
    )

    MediaBindings = @{
        WINDOWS_SERVER = 'LOCAL_MEDIA_REFERENCE_REQUIRED'
        SQL_SERVER = 'LOCAL_MEDIA_REFERENCE_REQUIRED'
    }

    ImageLockPath = 'LOCAL_IMAGE_LOCK_PATH_REQUIRED'

    RemoteHosts = @()

    SecretPolicy = @{
        Provider = 'NONE'
        RequiredSecretNames = @('SQL_SA_PASSWORD')
        AllowInteractive = $false
    }

    NetworkPolicy = @{
        PrivateRangeReference = 'LOCAL_PRIVATE_RANGE_REFERENCE_REQUIRED'
        PrivateRangeCidr = 'LOCAL_PRIVATE_CIDR_REQUIRED'
        RejectRouteCollision = $true
        AllowExternalLabDataNetwork = $false
    }

    Retention = @{
        MaximumCacheAgeDays = 30
        MaximumArtifactAgeDays = 7
    }

    Timeouts = @{
        PreflightSeconds = 120
        SetupSeconds = 1800
        ObserveSeconds = 300
        CleanupSeconds = 900
    }
}
