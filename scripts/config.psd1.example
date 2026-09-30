@{
    EnvironmentName      = 'SI-DEV'
    OrgUrl               = 'https://REDACTEDORGDEV.crm16.dynamics.com'
    # Entra tenant hosting SI-DEV. Not a secret (it's public metadata), but
    # pin it explicitly so auth doesn't silently fall back to a "common"/
    # multi-tenant sign-in.
    TenantId             = '00000000-0000-0000-0000-000000000000'
    SolutionUniqueName   = 'HSVServiceIntakeV2'
    SolutionDisplayName  = 'HSV Service Intake V2'
    PublisherUniqueName  = 'HSV'
    PublisherDisplayName = 'HSV'
    PublisherPrefix      = 'hsv'
    # Five-digit option value prefix for the publisher. Not yet confirmed free —
    # see docs/discovery-report.md. Placeholder chosen from Microsoft's
    # documented safe custom range (10000-99999, avoiding well-known reserved
    # blocks); verify/adjust before Phase B actually creates the publisher.
    OptionValuePrefix    = 20971

    TargetTables = @(
        'hsv_serviceobject',
        'hsv_workorder',
        'hsv_inboundmessage',
        'hsv_processingattempt',
        'hsv_statustransition'
    )

    TargetGlobalChoices = @(
        'hsv_messagestatus',
        'hsv_workorderstatus',
        'hsv_stage',
        'hsv_result',
        'hsv_reasoncode',
        'hsv_trade',
        'hsv_priority'
    )
}
