# Cost guardrail. Everything in this project is Always Free, so ANY actual
# spend means something left the free tier. With the default budget of 1
# (in your billing currency), 1% is the first cent: you get an email right away.
resource "oci_budget_budget" "skybook" {
  # Budgets are always created in the root compartment, whatever they target.
  compartment_id = var.tenancy_ocid
  display_name   = "skybook-monthly"
  description    = "SkyBook cost guardrail: actual spend in the skybook compartment should stay at 0"
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [oci_identity_compartment.skybook.id]
  freeform_tags  = local.freeform_tags
}

resource "oci_budget_alert_rule" "actual_spend" {
  budget_id      = oci_budget_budget.skybook.id
  display_name   = "skybook-actual-1pct"
  description    = "Email as soon as actual spend reaches 1% of the budget"
  type           = "ACTUAL"
  threshold      = 1
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "SkyBook: actual OCI spend in the skybook compartment reached 1% of its monthly budget (${var.budget_amount}). Something is outside Always Free - check Billing > Cost Analysis."
  freeform_tags  = local.freeform_tags
}
