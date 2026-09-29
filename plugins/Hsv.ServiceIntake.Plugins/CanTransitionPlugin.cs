using System;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace Hsv.ServiceIntake.Plugins
{
    /// <summary>
    /// Pre-Operation Create/Update validator for hsv_workorder and
    /// hsv_inboundmessage's hsv_status field. This is the CanTransition
    /// mechanism described in docs/architecture.md, made unavoidable across
    /// every channel (UI, Web API, flows) by living in a plugin rather than
    /// only in a flow that a direct API write could bypass.
    ///
    /// Blocks the write outright (InvalidPluginExecutionException, which
    /// aborts the whole transaction) unless hsv_statustransition contains an
    /// active row for the exact (entity, fromStatusValue, toStatusValue)
    /// triple - see schema/statustransitions.yaml for the seeded
    /// configuration.
    ///
    /// hsv_statustransition is the actual source of truth (review item 12,
    /// 2026-09): this plugin does no number&lt;-&gt;label translation of its
    /// own and has no hardcoded Choice values for either status option set -
    /// it reads hsv_FromStatusValue/hsv_ToStatusValue directly and compares
    /// them to the OptionSetValue.Value already on the entity/pre-image.
    ///
    /// Create is validated the same way as Update, by treating "the record
    /// does not exist yet" as fromStatusValue = 0 (a sentinel documented in
    /// schema/tables.yaml, not a real Choice value in either option set) -
    /// review items 15/16. There is no separate Create-only code path or
    /// hardcoded "initial status" constant; the allowed initial value(s) are
    /// just the hsv_statustransition rows where hsv_FromStatusValue = 0.
    ///
    /// Deliberately NOT implemented here: hsv_AllowedTrigger enforcement -
    /// see the DECISION note on that column in schema/tables.yaml (review
    /// item 14). Only the from/to transition itself is validated. Logging a
    /// hsv_processingattempt row with Result=Skipped/ReasonCode=INVALID_TRANSITION
    /// for a blocked attempt is the calling flow's job (it catches this
    /// exception), not this plugin's - a Pre-Operation step that's about to
    /// fail the whole transaction should not also try to write a separate
    /// log record in the same breath.
    /// </summary>
    public class CanTransitionPlugin : IPlugin
    {
        private const string StatusTransitionEntity = "hsv_statustransition";
        private const int PreOperationStage = 20;

        // "Record does not exist yet" - see schema/tables.yaml's
        // hsv_FromStatusValue description. Not a real Choice value in
        // either hsv_WorkOrderStatus or hsv_MessageStatus (both start at
        // 209710xxx).
        private const int NoneSentinel = 0;

        // hsv_statustransition.hsv_entityname local choice values (schema/tables.yaml localOptionSets).
        private const int EntityNameMessage = 209710731;
        private const int EntityNameWorkOrder = 209710732;

        public void Execute(IServiceProvider serviceProvider)
        {
            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));

            if (context.Stage != PreOperationStage)
            {
                return;
            }

            bool isCreate;
            switch (context.MessageName)
            {
                case "Create":
                    isCreate = true;
                    break;
                case "Update":
                    isCreate = false;
                    break;
                default:
                    return;
            }

            if (!(context.InputParameters["Target"] is Entity target) || !target.Contains("hsv_status"))
            {
                return; // Status isn't part of this write - nothing to validate.
            }

            int entityNameValue;
            switch (context.PrimaryEntityName)
            {
                case "hsv_workorder":
                    entityNameValue = EntityNameWorkOrder;
                    break;
                case "hsv_inboundmessage":
                    entityNameValue = EntityNameMessage;
                    break;
                default:
                    return; // Registered on something else by mistake - do nothing.
            }

            var newStatusValue = ((OptionSetValue)target["hsv_status"]).Value;

            int oldStatusValue;
            if (isCreate)
            {
                oldStatusValue = NoneSentinel;
            }
            else
            {
                // The pre-image must be registered on the Update step (see
                // scripts/register-plugin.ps1) with at least hsv_status, or
                // this plugin has no way to know the "from" status.
                if (!context.PreEntityImages.Contains("PreImage") || !context.PreEntityImages["PreImage"].Contains("hsv_status"))
                {
                    throw new InvalidPluginExecutionException(
                        "CanTransitionPlugin's Pre-Image ('PreImage', must include hsv_status) is missing on the Update step - registration is incomplete.");
                }

                oldStatusValue = ((OptionSetValue)context.PreEntityImages["PreImage"]["hsv_status"]).Value;
                if (oldStatusValue == newStatusValue)
                {
                    return; // Not actually a status change - some other field triggered this update.
                }
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
            // the actual write being validated still runs under the
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
                        new ConditionExpression("hsv_fromstatusvalue", ConditionOperator.Equal, oldStatusValue),
                        new ConditionExpression("hsv_tostatusvalue", ConditionOperator.Equal, newStatusValue),
                        new ConditionExpression("hsv_isactive", ConditionOperator.Equal, true),
                    },
                },
                TopCount = 1,
            };

            var matches = service.RetrieveMultiple(query);
            if (matches.Entities.Count == 0)
            {
                var fromDescription = isCreate ? "(new record)" : oldStatusValue.ToString();
                throw new InvalidPluginExecutionException(
                    $"Transition '{fromDescription}' -> '{newStatusValue}' on {context.PrimaryEntityName} is not configured in hsv_statustransition (or is inactive). Reason: INVALID_TRANSITION.");
            }
        }
    }
}
