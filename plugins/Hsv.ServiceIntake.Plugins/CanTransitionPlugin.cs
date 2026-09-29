using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace Hsv.ServiceIntake.Plugins
{
    /// <summary>
    /// Pre-Operation Update validator for hsv_workorder and hsv_inboundmessage's
    /// hsv_status field. This is the CanTransition mechanism described in
    /// docs/architecture.md, made unavoidable across every channel (UI, Web
    /// API, flows) by living in a plugin rather than only in a flow that a
    /// direct API write could bypass.
    ///
    /// Blocks the write outright (InvalidPluginExecutionException, which
    /// aborts the whole transaction) unless hsv_statustransition contains an
    /// active row for the exact (entity, fromStatus, toStatus) triple -
    /// see schema/statustransitions.yaml for the seeded configuration.
    ///
    /// Deliberately NOT implemented here: hsv_allowedtrigger enforcement.
    /// That column's values are an unconfirmed placeholder (see the flag at
    /// the top of schema/tables.yaml) - enforcing an unconfirmed rule would
    /// be worse than not enforcing it. Only the from/to transition itself is
    /// validated. Logging a hsv_processingattempt row with
    /// Result=Skipped/ReasonCode=INVALID_TRANSITION for a blocked attempt is
    /// the calling flow's job (it catches this exception), not this
    /// plugin's - a Pre-Operation step that's about to fail the whole
    /// transaction should not also try to write a separate log record in
    /// the same breath.
    /// </summary>
    public class CanTransitionPlugin : IPlugin
    {
        private const string StatusTransitionEntity = "hsv_statustransition";
        private const int PreOperationStage = 20;

        // hsv_workorderstatus global choice values (schema/choices.yaml).
        // Hardcoded rather than looked up via metadata on every call: these
        // are our own custom option sets, and schema/choices.yaml documents
        // that their numeric values must never change once created.
        private static readonly Dictionary<int, string> WorkOrderStatusLabels = new Dictionary<int, string>
        {
            { 209710101, "Neu" },
            { 209710102, "Zugewiesen" },
            { 209710103, "In Arbeit" },
            { 209710104, "Abgeschlossen" },
            { 209710105, "Storniert" },
        };

        // hsv_messagestatus global choice values (schema/choices.yaml).
        private static readonly Dictionary<int, string> MessageStatusLabels = new Dictionary<int, string>
        {
            { 209710001, "Received" },
            { 209710002, "Parsed" },
            { 209710003, "Validated" },
            { 209710004, "Needs Clarification" },
            { 209710005, "Potential Duplicate" },
            { 209710006, "Duplicate" },
            { 209710007, "Not Relevant" },
            { 209710008, "Linked" },
            { 209710009, "Converted" },
            { 209710010, "Technical Retry" },
            { 209710011, "Failed" },
        };

        // hsv_statustransition.hsv_entityname local choice values (schema/tables.yaml localOptionSets).
        private const int EntityNameMessage = 209710731;
        private const int EntityNameWorkOrder = 209710732;

        public void Execute(IServiceProvider serviceProvider)
        {
            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));

            if (context.MessageName != "Update" || context.Stage != PreOperationStage)
            {
                return;
            }

            if (!(context.InputParameters["Target"] is Entity target) || !target.Contains("hsv_status"))
            {
                return; // Status isn't part of this update - nothing to validate.
            }

            Dictionary<int, string> labels;
            int entityNameValue;
            switch (context.PrimaryEntityName)
            {
                case "hsv_workorder":
                    labels = WorkOrderStatusLabels;
                    entityNameValue = EntityNameWorkOrder;
                    break;
                case "hsv_inboundmessage":
                    labels = MessageStatusLabels;
                    entityNameValue = EntityNameMessage;
                    break;
                default:
                    return; // Registered on something else by mistake - do nothing.
            }

            var newStatusValue = ((OptionSetValue)target["hsv_status"]).Value;
            if (!labels.TryGetValue(newStatusValue, out var newStatusLabel))
            {
                throw new InvalidPluginExecutionException(
                    $"hsv_status value {newStatusValue} on {context.PrimaryEntityName} is not a recognized status - refusing to guess. Reason: UNKNOWN_STATUS_VALUE.");
            }

            // The pre-image must be registered on the step (see
            // scripts/register-plugin.ps1) with at least hsv_status, or this
            // plugin has no way to know the "from" status.
            if (!context.PreEntityImages.Contains("PreImage") || !context.PreEntityImages["PreImage"].Contains("hsv_status"))
            {
                throw new InvalidPluginExecutionException(
                    "CanTransitionPlugin's Pre-Image ('PreImage', must include hsv_status) is missing - registration is incomplete.");
            }

            var oldStatusValue = ((OptionSetValue)context.PreEntityImages["PreImage"]["hsv_status"]).Value;
            if (oldStatusValue == newStatusValue)
            {
                return; // Not actually a status change - some other field triggered this update.
            }

            if (!labels.TryGetValue(oldStatusValue, out var oldStatusLabel))
            {
                throw new InvalidPluginExecutionException(
                    $"hsv_status pre-image value {oldStatusValue} on {context.PrimaryEntityName} is not a recognized status. Reason: UNKNOWN_STATUS_VALUE.");
            }

            // Deliberately CreateOrganizationService(null) - runs as SYSTEM,
            // not context.UserId. hsv_statustransition is configuration data
            // the security model gives Techniker zero access to ("kein
            // Zugriff" - schema/security.yaml); querying it as the calling
            // user meant a Techniker could never successfully transition
            // their OWN work order, valid transition or not - the plugin's
            // internal rule lookup would 403 before it ever got to evaluate
            // the rule. Confirmed live: HTTP 403,
            // "missing prvReadhsv_StatusTransition privilege", on a
            // Neu -> Zugewiesen transition by the record's own owner.
            // This does not expose hsv_statustransition's contents to the
            // caller - it's used only internally to decide allow/deny, and
            // the actual Update being validated still runs under the
            // caller's own privileges (this plugin never writes anything).
            var service = ((IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory)))
                .CreateOrganizationService(null);

            var query = new QueryExpression(StatusTransitionEntity)
            {
                ColumnSet = new ColumnSet(false),
                Criteria = new FilterExpression(LogicalOperator.And)
                {
                    Conditions =
                    {
                        new ConditionExpression("hsv_entityname", ConditionOperator.Equal, entityNameValue),
                        new ConditionExpression("hsv_fromstatus", ConditionOperator.Equal, oldStatusLabel),
                        new ConditionExpression("hsv_tostatus", ConditionOperator.Equal, newStatusLabel),
                        new ConditionExpression("hsv_isactive", ConditionOperator.Equal, true),
                    },
                },
                TopCount = 1,
            };

            var matches = service.RetrieveMultiple(query);
            if (matches.Entities.Count == 0)
            {
                throw new InvalidPluginExecutionException(
                    $"Transition '{oldStatusLabel}' -> '{newStatusLabel}' on {context.PrimaryEntityName} is not configured in hsv_statustransition (or is inactive). Reason: INVALID_TRANSITION.");
            }
        }
    }
}
