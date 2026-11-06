# frozen_string_literal: true

# Uploads live in a private S3-compatible bucket (Railway bucket). Browsers
# load files through presigned URLs and upload straight to the bucket (Active
# Storage direct uploads), so the bucket host has to be allowed by Decidim's
# Content-Security-Policy.
if Decidim::Env.new("STORAGE_PROVIDER", "local").to_s == "s3" && ENV["AWS_ENDPOINT"].present?
  endpoint_host = URI.parse(ENV.fetch("AWS_ENDPOINT")).host
  # Virtual-host style URLs put the bucket name in front of the endpoint host.
  sources = [endpoint_host, "*.#{endpoint_host}"]

  Decidim.configure do |config|
    config.content_security_policies_extra = {
      "img-src" => sources,
      "media-src" => sources,
      "connect-src" => sources
    }
  end
end
