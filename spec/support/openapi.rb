# frozen_string_literal: true

# Configures rspec-openapi to record real request/response shapes from
# controller specs and write them to tmp/openapi/from_rspec.yaml.
#
# Recording is opt-in. The rspec-openapi gem only hooks into RSpec when the
# OPENAPI env var is set, so this file is a no-op in normal spec runs. To
# record, run rspec with OPENAPI=1 (see script/openapi/run_rspec.sh).
#
# The gem itself is required only when OPENAPI is set, since the Gemfile
# entry uses `require: false` to keep it out of normal test boot.

if ENV["OPENAPI"]
  require "rspec/openapi"

  RSpec::OpenAPI.path = ENV.fetch(
    "RSPEC_OPENAPI_PATH",
    Rails.root.join("tmp", "openapi", "from_rspec.yaml").to_s,
  )

  RSpec::OpenAPI.title = "Gumroad API v2 (recorded from rspec)"
  RSpec::OpenAPI.application_version = "2.0.0"
  RSpec::OpenAPI.servers = [
    { url: "https://api.gumroad.com/v2" },
  ]

  # Gumroad's v2 specs live in spec/controllers, so they get type: :controller
  # via infer_spec_type_from_file_location!. Default rspec-openapi only records
  # type: :request, so we have to opt :controller in explicitly.
  RSpec::OpenAPI.example_types = %i[request controller]

  FileUtils.mkdir_p(File.dirname(RSpec::OpenAPI.path))

  # rspec-openapi's after(:each) hook reads the current @request to resolve a
  # Rails route. In controller specs, ActionController::TestCase synthesizes
  # the path from controller+action; the first matching v2 route is "/v2/..."
  # under ApiDomainConstraint. spec_helper.rb forces @request.host to DOMAIN
  # (app.test.gumroad.com) in a config.before hook, which fails the api-domain
  # constraint, so Rails falls through to application#e404_page ("/(*path)")
  # — that is what gets recorded as the path otherwise.
  #
  # Fix: in an after(:each) that runs BEFORE rspec-openapi's after hook,
  # rewrite @request.host to the api host. After-hooks run in reverse
  # registration order, and rspec-openapi was required above this block
  # so its hook registered first → ours runs first in the after chain.
  RSpec.configure do |config|
    config.after(:each, type: :controller) do
      next unless self.class.described_class&.name.to_s.start_with?("Api::V2::")
      next unless @request.respond_to?(:host=)

      api_host = (defined?(API_DOMAIN) && API_DOMAIN) ||
                 (defined?(VALID_API_REQUEST_HOSTS) && VALID_API_REQUEST_HOSTS.first)
      @request.host = api_host if api_host
    end
  end
end
