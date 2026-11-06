# frozen_string_literal: true

# One-off: creates the system admin, the organization and its admin, without
# seed data. Idempotent; reads a JSON object from STDIN so passwords never
# appear in a command line:
#
#   railway ssh --service web -- bin/rails runner script/bootstrap_organization.rb < creds.json
#
# Keys: host, organization_name, organization_short_name, reference_prefix,
# available_locales (array), default_locale, system_admin_email,
# system_admin_password, org_admin_name, org_admin_email, org_admin_password.

input = JSON.parse($stdin.read)
fetch = ->(key) { input.fetch(key) { abort "missing key: #{key}" } }

system_admin = Decidim::System::Admin.find_or_initialize_by(email: fetch.call("system_admin_email"))
if system_admin.new_record?
  system_admin.password = fetch.call("system_admin_password")
  system_admin.password_confirmation = system_admin.password
  system_admin.save!
  puts "system admin created"
else
  puts "system admin already exists"
end

organization = Decidim::Organization.find_by(host: fetch.call("host"))
if organization
  puts "organization already exists (id #{organization.id})"
else
  form = Decidim::System::RegisterOrganizationForm.from_params(
    name: fetch.call("organization_name"),
    short_name: fetch.call("organization_short_name"),
    host: fetch.call("host"),
    reference_prefix: fetch.call("reference_prefix"),
    available_locales: fetch.call("available_locales"),
    default_locale: fetch.call("default_locale"),
    users_registration_mode: "enabled",
    force_users_to_authenticate_before_access_organization: false,
    organization_admin_name: fetch.call("org_admin_name"),
    organization_admin_email: fetch.call("org_admin_email")
  ).with_context(current_user: nil)
  form.file_upload_settings = Decidim::System::FileUploadSettingsForm.from_model({})

  result = nil
  Decidim::System::CreateOrganization.call(form) do
    on(:ok) { result = :ok }
    on(:invalid) { result = :invalid }
    on(:invalid_invitation) { result = :invalid_invitation }
  end
  abort "organization not created (#{result}): #{form.errors.full_messages.join("; ")}" unless result == :ok

  organization = Decidim::Organization.find_by!(host: fetch.call("host"))
  puts "organization created (id #{organization.id})"
end

# CreateOrganization invites the admin by email. Give the account its password
# and accept the invitation here, so it works before SMTP is configured.
admin = Decidim::User.find_by!(organization:, email: fetch.call("org_admin_email"))
if admin.encrypted_password.present? && admin.invitation_accepted?
  puts "organization admin already set up"
else
  admin.password = fetch.call("org_admin_password")
  admin.password_confirmation = admin.password
  admin.password_updated_at = Time.current
  admin.tos_agreement = true
  admin.accepted_tos_version = organization.tos_version
  admin.admin = true
  admin.skip_confirmation! unless admin.confirmed?
  admin.accept_invitation!
  admin.save!
  puts "organization admin set up"
end
