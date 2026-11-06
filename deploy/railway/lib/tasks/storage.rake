# frozen_string_literal: true

namespace :storage do
  desc "Allow browser direct uploads (CORS PUT) to the S3 bucket from RAILS_HOSTS"
  task cors: :environment do
    service = ActiveStorage::Blob.service
    abort "storage:cors needs the S3 service (STORAGE_PROVIDER=s3)" unless service.respond_to?(:bucket)

    origins = ENV.fetch("RAILS_HOSTS", "decidim.vocdoni.dev").split(",").map { |host| "https://#{host.strip}" }
    service.bucket.cors.put(
      cors_configuration: {
        cors_rules: [{
          allowed_origins: origins,
          allowed_methods: %w(PUT),
          allowed_headers: %w(*),
          expose_headers: %w(Origin Content-Type Content-MD5 Content-Disposition),
          max_age_seconds: 3600
        }]
      }
    )
    puts "CORS set on #{service.bucket.name} for #{origins.join(", ")}"
  end
end
