@{
    EnvironmentName      = 'SI-TEST'
    OrgUrl               = 'https://REDACTEDORGTEST.crm17.dynamics.com'
    # Same tenant as SI-DEV.
    TenantId             = '00000000-0000-0000-0000-000000000000'
    SolutionUniqueName   = 'HSVServiceIntakeV2'
    SolutionDisplayName  = 'HSV Service Intake V2'
    PublisherUniqueName  = 'HSV'
    PublisherDisplayName = 'HSV'
    PublisherPrefix      = 'hsv'
    # Not yet verified free in SI-TEST (was verified in SI-DEV only) -
    # discover.ps1 -ConfigPath config.si-test.psd1 checks this before deploy
    # touches it. If it collides, deploy.ps1 will surface it as CONFLICT,
    # not silently pick another value.
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
