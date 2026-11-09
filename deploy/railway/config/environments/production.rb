require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  config.asset_host = ENV['RAILS_ASSET_HOST'] if ENV['RAILS_ASSET_HOST'].present?

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = Decidim::Env.new("STORAGE_PROVIDER", "local").to_s

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Railway's edge terminates TLS and forwards plain HTTP to the container.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # Decidim sets `config.force_ssl` itself from DECIDIM_FORCE_SSL, which is on in production.

  # Skip http-to-https redirect for the default health check endpoint.
  # Railway's healthcheck calls it over plain HTTP from inside the network.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.action_mailer.smtp_settings = {
    :address        => Decidim::Env.new("SMTP_ADDRESS").to_s,
    :port           => Decidim::Env.new("SMTP_PORT", 587).to_i,
    :authentication => Decidim::Env.new("SMTP_AUTHENTICATION", "plain").to_s,
    :user_name      => Decidim::Env.new("SMTP_USERNAME").to_s,
    :password       => Decidim::Env.new("SMTP_PASSWORD").to_s,
    :domain         => Decidim::Env.new("SMTP_DOMAIN").to_s,
    :enable_starttls_auto => Decidim::Env.new("SMTP_STARTTLS_AUTO", true).present?,
    :openssl_verify_mode => 'none'
  }
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)


  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # The `worker` service runs Sidekiq; config/sidekiq.yml lists the queues.
  config.active_job.queue_adapter = :sidekiq

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  # config.action_mailer.default_url_options = { host: "example.com" }

  # Mail goes out over SMTP (settings above) once SMTP_ADDRESS is set. Until
  # then it is discarded rather than retried forever by the worker.
  config.action_mailer.delivery_method = ENV["SMTP_ADDRESS"].present? ? :smtp : :test

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # RAILS_HOSTS is a comma-separated list; each host also needs a Decidim
  # organization (or secondary host) to serve anything but /system.
  config.hosts = ENV.fetch("RAILS_HOSTS", "decidim.vocdoni.dev").split(",").map(&:strip).compact_blank

  # Railway's healthcheck sends its own Host header.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
