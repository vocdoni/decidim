# frozen_string_literal: true

# One-off: creates the system admin, the organization and its admin, without
# seed data. Idempotent. Input is a JSON object, read from STDIN or, when that
# is empty, from the BOOTSTRAP_JSON variable:
#
#   bin/rails runner script/bootstrap_organization.rb < bootstrap.json
#
# Keys: host, organization_name, organization_short_name, reference_prefix,
# available_locales (array), default_locale, system_admin_email,
# org_admin_name, org_admin_email, and for each admin either `*_password` or
# `*_password_digest` (a bcrypt hash, so the plaintext never has to leave the
# operator's machine): system_admin_password[_digest],
# org_admin_password[_digest].

raw = $stdin.tty? ? "" : $stdin.read.to_s
raw = ENV.fetch("BOOTSTRAP_JSON", "") if raw.strip.empty?
abort "no input: pipe JSON on STDIN or set BOOTSTRAP_JSON" if raw.strip.empty?
input = JSON.parse(raw)
fetch = ->(key) { input.fetch(key) { abort "missing key: #{key}" } }

# Saves `record` with its password from the input: the plaintext goes through
# the model's validations; a digest is written after saving with a throwaway
# password, because Devise requires a password on create.
set_password = lambda do |record, prefix, &before_save|
  digest = input["#{prefix}_password_digest"]
  password = digest ? "#{SecureRandom.base64(36)}aA1!" : fetch.call("#{prefix}_password")
  record.password = password
  record.password_confirmation = password
  before_save&.call
  record.save!
  record.update_columns(encrypted_password: digest) if digest # rubocop:disable Rails/SkipsModelValidations
end

system_admin = Decidim::System::Admin.find_or_initialize_by(email: fetch.call("system_admin_email"))
if system_admin.new_record?
  set_password.call(system_admin, "system_admin")
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
if admin.invitation_accepted?
  puts "organization admin already set up"
else
  set_password.call(admin, "org_admin") do
    admin.password_updated_at = Time.current
    admin.tos_agreement = true
    admin.accepted_tos_version = organization.tos_version
    admin.admin = true
    admin.skip_confirmation! unless admin.confirmed?
    admin.accept_invitation
  end
  puts "organization admin set up"
end
