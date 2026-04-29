#!/usr/bin/env ruby
# frozen_string_literal: true

# Merges three intermediate OpenAPI artifacts plus the canonical routes list
# into a single authoritative OpenAPI 3.1 spec at docs/openapi.yaml.
#
# Inputs (relative to repo root):
#   - tmp/openapi/routes.json          - canonical v2 endpoints
#   - tmp/openapi/from_rspec.yaml      - runtime-recorded structural truth
#   - tmp/openapi/from_serializers.yaml- static as_json schemas + scope variants
#   - tmp/openapi/from_specs.yaml      - test-claimed required/forbidden fields
#                                         and 4xx/5xx status codes
#   - docs/openapi.yaml                - existing hand-written spec (for info,
#                                         servers, securitySchemes preservation)
#
# Output:
#   - docs/openapi.yaml (overwritten with generated spec)
#
# Idempotent: running the merger twice with the same inputs produces byte
# identical output.

require "json"
require "yaml"
require "set"

REPO_ROOT = File.expand_path("../..", __dir__)
ROUTES_JSON       = File.join(REPO_ROOT, "tmp/openapi/routes.json")
FROM_RSPEC_PRIMARY = File.join(REPO_ROOT, "tmp/openapi/from_rspec.yaml")
FROM_RSPEC_CACHED  = File.join(REPO_ROOT, "script/openapi/cached/from_rspec.yaml")
FROM_RSPEC    = File.exist?(FROM_RSPEC_PRIMARY) ? FROM_RSPEC_PRIMARY : FROM_RSPEC_CACHED
FROM_SERIAL   = File.join(REPO_ROOT, "tmp/openapi/from_serializers.yaml")
FROM_SPECS    = File.join(REPO_ROOT, "tmp/openapi/from_specs.yaml")
HANDWRITTEN   = File.join(REPO_ROOT, "docs/openapi.yaml.handwritten.bak")
OUTPUT        = File.join(REPO_ROOT, "docs/openapi.yaml")

# ---------------------------------------------------------------------------
# Tag mapping: controller -> human-friendly tag (matches existing handwritten
# spec's tag names).
TAG_FOR_CONTROLLER = {
  "api/v2/users"                  => "User",
  "api/v2/links"                  => "Products",
  "api/v2/variant_categories"     => "Variant categories",
  "api/v2/variants"               => "Variants",
  "api/v2/custom_fields"          => "Custom fields",
  "api/v2/offer_codes"            => "Offer codes",
  "api/v2/skus"                   => "SKUs",
  "api/v2/subscribers"            => "Subscribers",
  "api/v2/sales"                  => "Sales",
  "api/v2/payouts"                => "Payouts",
  "api/v2/licenses"               => "Licenses",
  "api/v2/resource_subscriptions" => "Resource subscriptions",
  "api/v2/tax_forms"              => "Tax forms",
  "api/v2/earnings"               => "Earnings",
  "api/v2/files"                  => "Files",
  "api/v2/thumbnails"             => "Thumbnails",
  "api/v2/covers"                 => "Covers",
  "api/v2/bundle_contents"        => "Bundle contents",
  "api/v2/notion_unfurl_urls"     => "Notion unfurl URLs",
}.freeze

# Map controller#action -> reusable schema name to use as response.
# Used for endpoints not covered by from_rspec.yaml.
CONTROLLER_ACTION_SCHEMA = {
  "api/v2/users#show"                     => { wrapper: "user",       schema: "User" },
  "api/v2/sales#index"                    => { wrapper: "sales",      schema: "Sale", array: true, paginated: true },
  "api/v2/sales#show"                     => { wrapper: "sale",       schema: "Sale" },
  "api/v2/sales#mark_as_shipped"          => { wrapper: "sale",       schema: "Sale" },
  "api/v2/sales#refund"                   => { wrapper: "sale",       schema: "Sale" },
  "api/v2/sales#resend_receipt"           => { wrapper: nil,          schema: nil },
  "api/v2/subscribers#index"              => { wrapper: "subscribers", schema: "Subscriber", array: true, paginated: true },
  "api/v2/subscribers#show"               => { wrapper: "subscriber", schema: "Subscriber" },
  "api/v2/payouts#upcoming"               => { wrapper: "payouts",    schema: "Payout", array: true },
  "api/v2/licenses#decrement_uses_count"  => { wrapper: nil,          schema: nil },
  "api/v2/licenses#disable"               => { wrapper: nil,          schema: nil },
  "api/v2/licenses#enable"                => { wrapper: nil,          schema: nil },
  "api/v2/licenses#rotate"                => { wrapper: "license_key", schema: nil, scalar: "string" },
  "api/v2/licenses#verify"                => { wrapper: "purchase",   schema: "License" },
}.freeze

# ---------------------------------------------------------------------------

class Merger
  def initialize
    @routes      = JSON.parse(File.read(ROUTES_JSON))
    @rspec       = YAML.unsafe_load_file(FROM_RSPEC)
    @serializers = YAML.unsafe_load_file(FROM_SERIAL)
    @specs       = YAML.unsafe_load_file(FROM_SPECS)
    @handwritten = read_handwritten_blocks
  end

  def run
    canonical = collect_canonical_routes
    paths     = build_paths(canonical)
    schemas   = build_components_schemas

    spec = {
      "openapi"    => "3.1.0",
      "info"       => @handwritten["info"],
      "servers"    => @handwritten["servers"],
      "security"   => @handwritten["security"] || [
        { "oauth2" => [] },
        { "bearerAuth" => [] },
        { "accessTokenQuery" => [] },
      ],
      "tags"       => build_tags,
      "paths"      => paths,
      "components" => {
        "securitySchemes" => @handwritten["securitySchemes"],
        "schemas"         => schemas,
      },
    }

    # Final pass: fuse hand-written prose, requestBody schemas, and missing
    # named component schemas back into the generated structural spec.
    apply_prose_merge!(spec)

    File.write(OUTPUT, header_comment + spec.to_yaml(line_width: 100))
    summary(canonical, spec["paths"], spec["components"]["schemas"])
  end

  private

  def header_comment
    <<~YAML
      # AUTO-GENERATED by script/openapi/merger.rb. Do not edit by hand.
      # Inputs:
      #   - tmp/openapi/routes.json
      #   - tmp/openapi/from_rspec.yaml
      #   - tmp/openapi/from_serializers.yaml
      #   - tmp/openapi/from_specs.yaml
      #   - docs/openapi.yaml.handwritten.bak (info/servers/securitySchemes)
      # Re-run: bundle exec ruby script/openapi/merger.rb
    YAML
  end

  # Read the hand-written spec as text and pull out the four blocks we want to
  # preserve. The hand-written file currently has a YAML parse error around
  # markdown content (line 1258), so we work around it instead of trying to
  # parse the whole document.
  def read_handwritten_blocks
    text = File.read(HANDWRITTEN)
    {
      "info"            => extract_top_level_block(text, "info"),
      "servers"         => extract_top_level_block(text, "servers"),
      "security"        => extract_top_level_block(text, "security"),
      "securitySchemes" => extract_security_schemes(text),
    }
  end

  def extract_top_level_block(text, key)
    lines = text.lines
    start_idx = lines.index { |l| l =~ /\A#{Regexp.escape(key)}:\s*(\#.*)?$/ }
    return nil unless start_idx

    block = [lines[start_idx]]
    (start_idx + 1).upto(lines.length - 1) do |i|
      line = lines[i]
      if line =~ /\A\S/ && line !~ /\A#/
        break
      end
      block << line
    end
    parsed = YAML.unsafe_load(block.join)
    parsed.is_a?(Hash) ? parsed[key] : nil
  rescue Psych::SyntaxError
    nil
  end

  def extract_security_schemes(text)
    lines = text.lines
    comp_idx = lines.index { |l| l =~ /\Acomponents:\s*$/ }
    return nil unless comp_idx

    sec_idx = nil
    (comp_idx + 1).upto(lines.length - 1) do |i|
      break if lines[i] =~ /\A\S/ && lines[i] !~ /\A#/
      if lines[i] =~ /\A\s{2}securitySchemes:\s*$/
        sec_idx = i
        break
      end
    end
    return nil unless sec_idx

    block = [lines[sec_idx]]
    (sec_idx + 1).upto(lines.length - 1) do |i|
      line = lines[i]
      if line =~ /\A\s{0,2}\S/ && line !~ /\A\s{2,}\S/ && line !~ /\A\s{4,}\S/ && line !~ /\A#/
        break unless line =~ /\A\s{4}/
      end
      if line =~ /\A\s{2}\S/ && line !~ /\A\s{2}securitySchemes:/
        break
      end
      block << line
    end
    parsed = YAML.unsafe_load(block.join("").gsub(/\A  /, "")) rescue nil
    parsed.is_a?(Hash) ? parsed["securitySchemes"] : parsed
  end

  # Dedupe routes to /v2/ form, collapse PATCH+PUT update pairs into PUT.
  def collect_canonical_routes
    v2 = @routes.select { |r| r["path"].start_with?("/v2/") }
    # Keep PATCH only if no PUT exists for same path/controller/action
    v2.reject do |r|
      r["verb"] == "PATCH" && v2.any? do |o|
        o["verb"] == "PUT" &&
          o["path"] == r["path"] &&
          o["controller"] == r["controller"] &&
          o["action"] == r["action"]
      end
    end
  end

  def normalize_path(path)
    # /v2/products/:id -> /products/{id}; servers already include /v2 prefix
    stripped = path.sub(%r{\A/v2}, "")
    stripped.gsub(/:(\w+)/, '{\1}')
  end

  def build_tags
    seen = Set.new
    tags = []
    TAG_FOR_CONTROLLER.each_value do |t|
      next if seen.include?(t)
      seen << t
      tags << { "name" => t }
    end
    tags
  end

  def build_paths(canonical)
    paths = {}
    canonical.each do |route|
      norm_path = normalize_path(route["path"])
      paths[norm_path] ||= {}
      verb = route["verb"].downcase
      paths[norm_path][verb] = build_operation(route, norm_path)
    end
    # sort by path for deterministic output
    paths.sort.to_h
  end

  def build_operation(route, norm_path)
    rspec_op = lookup_rspec_op(route)
    spec_data = lookup_spec_data(route)
    op = {}
    op["tags"] = [TAG_FOR_CONTROLLER.fetch(route["controller"], route["controller"].split("/").last.gsub("_", " ").capitalize)]
    op["summary"] = build_summary(route, rspec_op)
    op["operationId"] = build_operation_id(route)
    desc = build_description(route, spec_data)
    op["description"] = desc if desc

    op["parameters"] = build_parameters(route, norm_path, rspec_op, spec_data)
    body = build_request_body(route, rspec_op, spec_data)
    op["requestBody"] = body if body
    op["responses"] = build_responses(route, rspec_op, spec_data)

    if rspec_op.nil?
      op["x-gumroad-coverage"] = "inferred"
    else
      op["x-gumroad-coverage"] = "rspec-recorded"
    end
    op
  end

  def build_summary(route, rspec_op)
    rspec_summary = rspec_op && rspec_op["summary"]
    if rspec_summary && !rspec_summary.empty? &&
        rspec_summary !~ /\A(GET|POST|PUT|DELETE|PATCH|HEAD)/i &&
        !%w[show index update create destroy].include?(rspec_summary)
      return capitalize_first(rspec_summary)
    end
    default_summary(route)
  end

  def default_summary(route)
    action = route["action"]
    resource = route["controller"].split("/").last.gsub("_", " ").sub(/s\z/, "")
    case action
    when "index"   then "List #{pluralize(resource)}"
    when "show"    then "Get a #{resource}"
    when "create"  then "Create a #{resource}"
    when "update"  then "Update a #{resource}"
    when "destroy" then "Delete a #{resource}"
    else "#{action.tr("_", " ").capitalize} #{resource}"
    end
  end

  def pluralize(word)
    word.end_with?("s") ? word : "#{word}s"
  end

  def capitalize_first(s)
    return s if s.nil? || s.empty?
    s[0].upcase + s[1..]
  end

  def build_operation_id(route)
    parts = [route["controller"].split("/").last, route["action"]]
    parts.join("_").gsub(/[^a-zA-Z0-9_]/, "_")
  end

  def build_description(route, spec_data)
    parts = []
    parts << "#{route["verb"]} `#{route["path"]}` (handled by `#{route["controller"]}##{route["action"]}`)."
    if route["verb"] == "PUT" && route["action"] == "update"
      parts << "Also accepts PATCH."
    end
    if spec_data&.dig("notes") && !spec_data["notes"].empty?
      parts << spec_data["notes"]
    end
    parts.join("\n\n")
  end

  def lookup_rspec_op(route)
    norm = normalize_path(route["path"]) # without /v2 prefix
    full = "/v2#{norm}"
    entry = @rspec["paths"][full]
    return nil unless entry
    entry[route["verb"].downcase]
  end

  def lookup_spec_data(route)
    klass = route["controller"].split("/").map { |seg| camelize(seg) }.join("::")
    key = "#{klass}Controller##{route["action"]}"
    @specs["endpoints"][key]
  end

  def camelize(s)
    s.split("_").map(&:capitalize).join.then { |x| x == "Api" ? "Api" : x.sub(/\AApi\z/, "Api").sub(/\AV2\z/, "V2") }
  end

  def build_parameters(route, norm_path, rspec_op, spec_data)
    params = []
    seen_names = Set.new

    # Always emit path params from the path string itself (truth)
    path_params = norm_path.scan(/\{(\w+)\}/).flatten
    path_params.each do |name|
      params << {
        "name"     => name,
        "in"       => "path",
        "required" => true,
        "schema"   => { "type" => "string" },
        "description" => path_param_description(name),
      }
      seen_names << name
    end

    # Add params from rspec, skipping path params already added and the
    # ubiquitous access_token (covered by global security)
    if rspec_op && rspec_op["parameters"]
      rspec_op["parameters"].each do |p|
        next if seen_names.include?(p["name"])
        next if p["name"] == "access_token"
        next if %w[action controller format].include?(p["name"])
        cleaned = p.dup
        cleaned.delete("example") if cleaned["in"] == "query" && cleaned["example"].is_a?(String) && cleaned["example"].length > 80
        # Don't emit body params as query params; those go into requestBody
        next unless %w[query path header cookie].include?(cleaned["in"])
        params << cleaned
        seen_names << p["name"]
      end
    end

    # For GET endpoints, add query params from from_specs request_params
    if route["verb"] == "GET" && spec_data&.dig("request_params")
      spec_data["request_params"].each do |name, type|
        next if seen_names.include?(name.to_s)
        next if %w[access_token format action controller].include?(name.to_s)
        params << {
          "name"     => name.to_s,
          "in"       => "query",
          "required" => false,
          "schema"   => { "type" => normalize_type(type) },
        }
        seen_names << name.to_s
      end
    end

    params
  end

  def path_param_description(name)
    case name
    when "id"                  then "External ID of the resource."
    when "link_id"             then "External ID of the product."
    when "variant_category_id" then "External ID of the variant category."
    when "year"                then "Calendar year (e.g., 2024)."
    when "tax_form_type"       then "Tax form type (e.g., '1099-K', '1099-MISC')."
    else "Path parameter."
    end
  end

  def normalize_type(t)
    case t.to_s
    when "integer", "int" then "integer"
    when "boolean", "bool" then "boolean"
    when "array" then "array"
    when "object", "hash" then "object"
    when "number", "float" then "number"
    when "string" then "string"
    else "string"
    end
  end

  def build_request_body(route, rspec_op, spec_data)
    return nil if %w[GET DELETE].include?(route["verb"])

    body_props = {}
    required = []

    # First try params recorded by rspec that look like body params
    if rspec_op && rspec_op["parameters"]
      rspec_op["parameters"].each do |p|
        next if %w[path].include?(p["in"])
        next if p["name"] == "access_token"
        next if %w[action controller format id link_id variant_category_id year tax_form_type].include?(p["name"])
        body_props[p["name"]] = p["schema"] || { "type" => "string" }
      end
    end

    # Augment from spec request_params
    if spec_data&.dig("request_params")
      spec_data["request_params"].each do |name, type|
        next if %w[access_token format action controller id link_id variant_category_id year tax_form_type].include?(name.to_s)
        body_props[name.to_s] ||= { "type" => normalize_type(type) }
      end
    end

    return nil if body_props.empty?

    body_props = body_props.transform_values { |v| sanitize_schema(v) }

    {
      "required" => false,
      "content"  => {
        "application/json" => {
          "schema" => {
            "type"       => "object",
            "properties" => body_props,
          },
        },
        "application/x-www-form-urlencoded" => {
          "schema" => {
            "type"       => "object",
            "properties" => body_props,
          },
        },
      },
    }
  end

  def build_responses(route, rspec_op, spec_data)
    responses = {}

    # 200 from rspec if available, else inferred from controller/action
    primary = build_200_response(route, rspec_op, spec_data)
    responses["200"] = primary if primary

    # Augment with rspec-recorded non-200 responses
    if rspec_op && rspec_op["responses"]
      rspec_op["responses"].each do |code, payload|
        next if code == "200"
        next if responses[code]
        responses[code] = simplify_response(payload)
      end
    end

    # Augment with from_specs status codes (4xx, 5xx) using error envelope
    if spec_data&.dig("statuses")
      spec_data["statuses"].each do |code, _info|
        code_str = code.to_s
        next if responses[code_str]
        next if code_str == "200"
        responses[code_str] = error_response(code_str)
      end
    end

    # Always advertise the documented 401 from the global security scheme
    responses["401"] ||= error_response("401")

    responses
  end

  def build_200_response(route, rspec_op, spec_data)
    if rspec_op && rspec_op["responses"] && rspec_op["responses"]["200"]
      base = simplify_response(rspec_op["responses"]["200"])
      apply_specs_overrides!(base, spec_data, "200")
      return base
    end

    # Fallback: synthesize from controller-action mapping
    key = "#{route["controller"]}##{route["action"]}"
    mapping = CONTROLLER_ACTION_SCHEMA[key]
    if mapping
      schema = success_envelope(mapping)
      return {
        "description" => spec_summary_text(spec_data, "200") || default_200_description(route),
        "content"     => { "application/json" => { "schema" => schema } },
      }
    end

    # Last fallback: generic success envelope
    {
      "description" => default_200_description(route),
      "content"     => {
        "application/json" => {
          "schema" => { "$ref" => "#/components/schemas/SuccessEnvelope" },
        },
      },
    }
  end

  def success_envelope(mapping)
    base = { "$ref" => "#/components/schemas/SuccessEnvelope" }
    extra_props = {}
    if mapping[:wrapper]
      if mapping[:array]
        extra_props[mapping[:wrapper]] = {
          "type"  => "array",
          "items" => mapping[:schema] ? { "$ref" => "#/components/schemas/#{mapping[:schema]}" } : { "type" => "object" },
        }
      elsif mapping[:scalar]
        extra_props[mapping[:wrapper]] = { "type" => mapping[:scalar] }
      else
        extra_props[mapping[:wrapper]] = mapping[:schema] ? { "$ref" => "#/components/schemas/#{mapping[:schema]}" } : { "type" => "object" }
      end
    end
    if mapping[:paginated]
      extra_props["next_page_url"] = { "type" => "string", "nullable" => true }
      extra_props["next_page_key"] = { "type" => "string", "nullable" => true }
    end
    if extra_props.empty?
      base
    else
      {
        "allOf" => [
          base,
          { "type" => "object", "properties" => extra_props },
        ],
      }
    end
  end

  def spec_summary_text(spec_data, code)
    info = spec_data&.dig("statuses", code.to_i) || spec_data&.dig("statuses", code)
    return nil unless info.is_a?(Hash)
    info["summary"]
  end

  def default_200_description(route)
    "Successful response."
  end

  def simplify_response(resp)
    out = {}
    out["description"] = resp["description"].is_a?(String) && !resp["description"].empty? ? resp["description"] : "Successful response."
    if resp["content"]
      out["content"] = {}
      resp["content"].each do |mime, body|
        cleaned_body = {}
        if body["schema"]
          cleaned_body["schema"] = sanitize_schema(strip_examples(body["schema"]))
        end
        # Drop response-level example to avoid OAS 3.1 strictness with `nullable`
        # in example values; we can re-add specific examples later if needed.
        out["content"][mime] = cleaned_body
      end
    end
    out
  end

  # Recursively normalize schemas for OpenAPI 3.1:
  # - Convert `nullable: true` to `type: [<orig>, "null"]` (or just drop if no type)
  # - Ensure arrays have `items`
  # - Drop empty `properties: {}` on objects without type? Keep, harmless.
  def sanitize_schema(node)
    case node
    when Hash
      h = {}
      node.each do |k, v|
        h[k] = sanitize_schema(v)
      end
      # nullable -> type: ["x", "null"]
      if h.delete("nullable")
        if h["type"].is_a?(String)
          h["type"] = [h["type"], "null"]
        elsif !h.key?("type")
          # without a type, default to permissive
          # OAS 3.1: omit nullable; node type stays unconstrained
        end
      end
      # Arrays must have items
      if h["type"] == "array" && !h.key?("items")
        h["items"] = {}
      end
      h
    when Array
      node.map { |x| sanitize_schema(x) }
    else
      node
    end
  end

  def strip_examples(node)
    case node
    when Hash
      node.each_with_object({}) do |(k, v), acc|
        next if k == "example"
        acc[k] = strip_examples(v)
      end
    when Array
      node.map { |x| strip_examples(x) }
    else
      node
    end
  end

  def trim_example(value, depth: 0)
    return value if depth > 4
    case value
    when Hash
      value.first(20).each_with_object({}) do |(k, v), acc|
        acc[k] = trim_example(v, depth: depth + 1)
      end
    when Array
      value.first(2).map { |v| trim_example(v, depth: depth + 1) }
    when String
      value.length > 200 ? value[0, 200] + "..." : value
    else
      value
    end
  end

  def apply_specs_overrides!(response, spec_data, code)
    return unless spec_data
    statuses = spec_data["statuses"] || {}
    info = statuses[code.to_i] || statuses[code]
    return unless info.is_a?(Hash)

    schema = response.dig("content", "application/json", "schema")
    return unless schema.is_a?(Hash)

    # Required fields override
    required = info["required_fields"]
    if required && !required.empty?
      flat = required.reject { |f| f.include?(".") }
      apply_required_to_top!(schema, flat)
    end

    # Forbidden fields: drop from properties
    forbidden = info["forbidden_fields"]
    if forbidden && !forbidden.empty?
      drop_forbidden!(schema, forbidden)
    end

    # Enum candidates from observed_values
    if info["observed_values"]
      info["observed_values"].each do |field, values|
        values = Array(values).uniq
        next unless values.length >= 2
        attach_enum!(schema, field.to_s, values)
      end
    end
  end

  def apply_required_to_top!(schema, required)
    if schema["type"] == "object"
      existing = schema["required"] || []
      schema["required"] = (existing + required).uniq
    end
    if schema["allOf"].is_a?(Array)
      schema["allOf"].each { |sub| apply_required_to_top!(sub, required) }
    end
  end

  def drop_forbidden!(schema, forbidden)
    if schema["type"] == "object" && schema["properties"]
      forbidden.each { |f| schema["properties"].delete(f) }
      schema["required"] = (schema["required"] || []).reject { |x| forbidden.include?(x) }
    end
    if schema["allOf"].is_a?(Array)
      schema["allOf"].each { |sub| drop_forbidden!(sub, forbidden) }
    end
  end

  def attach_enum!(schema, field, values)
    return unless schema.is_a?(Hash)
    if schema["properties"] && schema["properties"][field].is_a?(Hash)
      schema["properties"][field]["enum"] = values
    end
    if schema["allOf"].is_a?(Array)
      schema["allOf"].each { |sub| attach_enum!(sub, field, values) }
    end
  end

  def error_response(code)
    desc = case code
           when "400" then "Bad request — invalid parameters."
           when "401" then "Unauthorized — missing or invalid access token."
           when "403" then "Forbidden — token lacks required scope."
           when "404" then "Not found — resource does not exist or is not visible to caller."
           when "500" then "Internal server error."
           else "Error response."
           end
    {
      "description" => desc,
      "content"     => {
        "application/json" => {
          "schema" => { "$ref" => "#/components/schemas/ErrorResponse" },
        },
      },
    }
  end

  # ---- components.schemas ----

  def build_components_schemas
    schemas = {}

    schemas["SuccessEnvelope"] = {
      "type"        => "object",
      "description" => "Standard success wrapper. Real responses extend this with additional payload keys.",
      "properties"  => {
        "success" => { "type" => "boolean", "enum" => [true] },
        "message" => { "type" => "string" },
      },
      "required"    => ["success"],
    }

    schemas["ErrorResponse"] = {
      "type"        => "object",
      "description" => "Standard error envelope. Note: the API often returns errors with HTTP 200 status; the `success` flag is the source of truth.",
      "properties"  => {
        "success" => { "type" => "boolean", "enum" => [false] },
        "message" => { "type" => "string" },
      },
      "required"    => ["success", "message"],
    }

    schemas["Pagination"] = {
      "type"       => "object",
      "properties" => {
        "next_page_url" => { "type" => "string", "nullable" => true },
        "next_page_key" => { "type" => "string", "nullable" => true },
      },
    }

    schemas["User"]         = build_user_schema
    schemas["Product"]      = build_product_schema
    schemas["Sale"]         = build_sale_schema
    schemas["Subscriber"]   = build_subscriber_schema
    schemas["OfferCode"]    = build_offer_code_schema
    schemas["Variant"]      = build_variant_schema
    schemas["VariantCategory"] = build_variant_category_schema
    schemas["CustomField"]  = build_custom_field_schema
    schemas["Sku"]          = build_sku_schema
    schemas["Payout"]       = build_payout_schema
    schemas["License"]      = build_license_schema
    schemas["AssetPreview"] = ref_serializer_props(@serializers["schemas"]["AssetPreview.as_json"], description: "Asset preview / cover image attached to a product.")

    schemas.transform_values { |s| sanitize_schema(s) }
  end

  def ref_serializer_props(s, description: nil)
    return nil unless s
    out = {
      "type"       => "object",
      "properties" => {},
    }
    out["description"] = description if description
    s["properties"].each do |k, v|
      out["properties"][k] = serializer_prop_to_openapi(v)
    end
    if s["required"] && !s["required"].empty?
      out["required"] = s["required"]
    end
    out
  end

  def serializer_prop_to_openapi(prop)
    return { "type" => "string" } unless prop.is_a?(Hash)
    type = prop["type"]
    schema = case type
             when "string"  then { "type" => "string" }
             when "integer" then { "type" => "integer" }
             when "boolean" then { "type" => "boolean" }
             when "object"  then { "type" => "object" }
             when "array"   then { "type" => "array", "items" => { "type" => "object" } }
             when nil, "unknown" then {} # leave free-form
             else { "type" => type.to_s }
             end
    schema["nullable"] = true if prop["nullable"]
    schema
  end

  def build_user_schema
    base = ref_serializer_props(@serializers["schemas"]["User.as_json"], description: "Authenticated user.")
    return base if base
    { "type" => "object", "additionalProperties" => true }
  end

  def build_product_schema
    # Merge Link.as_json + Link.as_json_for_api for the canonical product shape.
    link = @serializers["schemas"]["Link.as_json"]
    link_api = @serializers["schemas"]["Link.as_json_for_api"]
    properties = {}
    required = []
    [link, link_api].compact.each do |s|
      (s["properties"] || {}).each { |k, v| properties[k] ||= serializer_prop_to_openapi(v) }
      required.concat(Array(s["required"]))
    end

    # Build oneOf for scope variants: api scope, mobile_api scope, etc.
    variants = []
    %w[Link.as_json_for_api Link.as_json_for_mobile_api Link.as_json_variant_details_only].each do |sname|
      s = @serializers["schemas"][sname]
      next unless s
      conditional_props = (s["properties"] || {}).select { |_k, v| v.is_a?(Hash) && v["required_when_condition"] }
      next if conditional_props.empty?
      variants << {
        "title"    => sname.split(".").last,
        "type"     => "object",
        "properties" => conditional_props.transform_values { |v| serializer_prop_to_openapi(v) },
      }
    end

    schema = {
      "type"        => "object",
      "description" => "Product (alias for Link). Different OAuth scopes return different field subsets — see oneOf for scope-specific fields.",
      "properties"  => properties,
    }
    schema["required"] = required.uniq if required.any?
    if variants.any?
      schema["oneOf"] = variants
    end
    schema
  end

  def build_sale_schema
    s = @serializers["schemas"]["Purchase.as_json"]
    base = ref_serializer_props(s, description: "Sale. Backed by Purchase#as_json(version: 2). Many fields are scope-conditional — see oneOf.")
    return { "type" => "object", "additionalProperties" => true } unless base

    # Build scope variants from conditional fields
    conditional = (s["properties"] || {}).select { |_k, v| v.is_a?(Hash) && v["required_when_condition"] }
    if conditional.any?
      base["oneOf"] = [
        {
          "title"    => "WithCreatorAppFields",
          "type"     => "object",
          "properties" => conditional.transform_values { |v| serializer_prop_to_openapi(v) },
        },
      ]
    end
    base
  end

  def build_subscriber_schema
    base = ref_serializer_props(@serializers["schemas"]["Follower.as_json"], description: "Subscriber to a creator's mailing list. Backed by Follower#as_json.")
    return { "type" => "object", "additionalProperties" => true } unless base
    base
  end

  def build_offer_code_schema
    s = @serializers["schemas"]["OfferCode.as_json_for_api"]
    base = ref_serializer_props(s, description: "Discount/offer code. Mutually exclusive percent_off vs amount_cents — see oneOf.")
    return { "type" => "object", "additionalProperties" => true } unless base

    # Real conditional: percent vs cents
    base["oneOf"] = [
      {
        "title"    => "PercentOff",
        "type"     => "object",
        "properties" => { "percent_off" => { "type" => "integer" } },
        "required" => ["percent_off"],
      },
      {
        "title"    => "AmountOff",
        "type"     => "object",
        "properties" => { "amount_cents" => { "type" => "integer" } },
        "required" => ["amount_cents"],
      },
    ]
    base
  end

  def build_variant_schema
    s = @serializers["schemas"]["Variant.as_json"] || @serializers["schemas"]["BaseVariant.as_json"]
    base = ref_serializer_props(s, description: "Product variant. Many fields are scope-conditional (rendered only when for_views: true and/or for_seller: true) — see oneOf.")
    return { "type" => "object", "additionalProperties" => true } unless base

    bv = @serializers["schemas"]["BaseVariant.as_json"]
    if bv
      for_views   = (bv["properties"] || {}).select { |_k, v| v.is_a?(Hash) && v["required_when_condition"] == "options[:for_views]" }
      for_seller  = (bv["properties"] || {}).select { |_k, v| v.is_a?(Hash) && v["required_when_condition"]&.include?("for_seller") }
      base["oneOf"] = [
        {
          "title"    => "ForViews",
          "type"     => "object",
          "properties" => for_views.transform_values { |v| serializer_prop_to_openapi(v) },
        },
        {
          "title"    => "ForSeller",
          "type"     => "object",
          "properties" => for_seller.transform_values { |v| serializer_prop_to_openapi(v) },
        },
      ]
    end
    base
  end

  def build_variant_category_schema
    base = ref_serializer_props(@serializers["schemas"]["VariantCategory.as_json"], description: "Variant category — a grouping of variants (e.g., 'Size', 'Color').")
    base || { "type" => "object", "additionalProperties" => true }
  end

  def build_custom_field_schema
    base = ref_serializer_props(@serializers["schemas"]["CustomField.as_json"], description: "Custom checkout field on a product.")
    base || { "type" => "object", "additionalProperties" => true }
  end

  def build_sku_schema
    s = @serializers["schemas"]["Sku.as_json"]
    base = ref_serializer_props(s, description: "Product SKU.")
    return { "type" => "object", "additionalProperties" => true } unless base

    conditional = (s["properties"] || {}).select { |_k, v| v.is_a?(Hash) && v["required_when_condition"] }
    if conditional.any?
      base["oneOf"] = [
        {
          "title"    => "WithCustomSku",
          "type"     => "object",
          "properties" => conditional.transform_values { |v| serializer_prop_to_openapi(v) },
        },
      ]
    end
    base
  end

  def build_payout_schema
    base = ref_serializer_props(@serializers["schemas"]["Payment.as_json"], description: "Payout (creator payment).")
    base || { "type" => "object", "additionalProperties" => true }
  end

  def build_license_schema
    base = ref_serializer_props(@serializers["schemas"]["Purchase.as_json_for_license"], description: "License-scoped purchase view returned by /licenses/verify.")
    base || { "type" => "object", "additionalProperties" => true }
  end

  # ---- prose merge pass ----------------------------------------------------
  #
  # The structural pipeline (rspec + serializers + specs) gives us correct
  # schemas, status codes, and oneOf scope variants — but it strips the
  # human prose, requestBody contracts, and named envelope schemas that the
  # hand-written .bak file carried. This pass walks the generated spec and
  # selectively folds those back in. The hand-written file is the public
  # contract for write endpoints; the generated file is structural truth.
  #
  # Rules per docs/openapi merge plan:
  # - summary: hand-written wins if generated is a generic verb-noun template.
  # - description: hand-written wins; generated description appended below
  #   under "Auto-generated notes:" if non-empty.
  # - parameters: merged by name; hand-written description/example wins;
  #   type/required from generated unless generated says `integer` for a
  #   query param the hand-written declared as `string` (the order_id case —
  #   HTTP query params are strings on the wire).
  # - requestBody: hand-written wins if generated has none; both present →
  #   prefer hand-written (it's the documented public contract).
  # - responses[code].description: hand-written wins if non-empty.
  # - responses[code].content.*.schema: generated always wins (structural
  #   truth from rspec).
  # - components.schemas.<Name>: copy in any hand-written schemas that don't
  #   exist in generated; if both have it, keep generated unless generated
  #   is a placeholder (no properties, no oneOf/allOf), in which case
  #   hand-written wins; either way, augment generated property entries
  #   with hand-written description / format if generated lacks them.
  def apply_prose_merge!(spec)
    @handwritten_spec = load_handwritten_full
    return unless @handwritten_spec.is_a?(Hash)

    merge_operation_prose!(spec)
    merge_component_schemas!(spec)
  end

  # Load the full hand-written spec, patching the known YAML parse error on
  # line 1258 in-memory (an unquoted scalar containing `version: 2`). The
  # source file is never modified.
  def load_handwritten_full
    raw = File.read(HANDWRITTEN)
    patched = raw.sub(
      /^(\s+description:\s+)(Shape comes from `Purchase#as_json\(version: 2\)`\.)\s*$/,
      '\1"\2"'
    )
    YAML.safe_load(patched, aliases: true, permitted_classes: [Symbol])
  rescue Psych::SyntaxError => e
    warn "prose-merge: could not parse handwritten spec: #{e.message}"
    nil
  end

  GENERIC_SUMMARY_RE = /\A(Get|Create|Update|Delete|List|Show|Index)( a| an| the)?(\s+\w+)+\z/i.freeze
  GENERIC_VERB_PREFIX = /\A(Disable|Enable|Presign|Abort|Complete|Verify|Rotate|Refund|Resend|Decrement|Upcoming|Download|Show|Index|Get|Create|Update|Delete|List|Mark)\b/i.freeze

  # A "generic" summary is a verb-noun template that the merger generated
  # mechanically from the controller#action name (e.g. "Get a earning",
  # "Disable", "Resend receipt sale", "Create a resource subscription",
  # "Decrement uses count license"). When the hand-written spec has a
  # fuller phrase ("Get yearly earnings", "Resend the receipt for a sale",
  # "Decrement a license's uses count") we prefer it.
  def generic_summary?(s)
    return true if s.nil? || s.empty?
    return true if s =~ GENERIC_SUMMARY_RE
    return false unless s =~ GENERIC_VERB_PREFIX
    # Starts with a generic verb. If it has no English connective tokens
    # (articles, prepositions, possessives) it almost certainly came from
    # the `action.tr("_", " ").capitalize` + resource fallback — treat as
    # generic. Hand-written prose virtually always has at least one of
    # these tokens once it's longer than two words.
    return true unless s =~ /\b(a|an|the|for|of|to|with|from|in|on|by|and|or|its|your|the|webhook)\b/i ||
                        s =~ /[''](s|t|re|ve|d|ll|m)\b/i
    false
  end

  def merge_operation_prose!(spec)
    hw_paths = @handwritten_spec["paths"] || {}
    paths    = spec["paths"] || {}

    paths.each do |path, ops_h|
      next unless ops_h.is_a?(Hash)
      hw_ops_h = hw_paths[path]
      next unless hw_ops_h.is_a?(Hash)

      # Path-level shared parameters in the handwritten file (e.g. `parameters: [LinkId, Id]` at path level)
      hw_path_params = hw_ops_h["parameters"].is_a?(Array) ? hw_ops_h["parameters"] : []

      ops_h.each do |verb, op|
        next unless %w[get put post patch delete head options].include?(verb.to_s)
        next unless op.is_a?(Hash)
        hw_op = hw_ops_h[verb]
        next unless hw_op.is_a?(Hash)

        merge_summary!(op, hw_op)
        merge_description!(op, hw_op)
        merge_parameters!(op, hw_op, hw_path_params)
        merge_request_body!(op, hw_op)
        merge_response_descriptions!(op, hw_op)
      end
    end
  end

  def merge_summary!(op, hw_op)
    hw_summary = hw_op["summary"]
    return if hw_summary.nil? || hw_summary.empty?
    if generic_summary?(op["summary"])
      op["summary"] = hw_summary
    end
  end

  def merge_description!(op, hw_op)
    hw_desc = hw_op["description"]
    return if hw_desc.nil? || hw_desc.to_s.strip.empty?
    gen_desc = op["description"]
    if gen_desc.nil? || gen_desc.to_s.strip.empty?
      op["description"] = hw_desc
    elsif gen_desc.to_s.strip == hw_desc.to_s.strip
      # noop
    else
      op["description"] = "#{hw_desc.to_s.rstrip}\n\n**Auto-generated notes:**\n\n#{gen_desc.to_s.lstrip}"
    end
  end

  # Resolve $ref params against handwritten spec so we can merge by name.
  def resolve_hw_param(p)
    return nil unless p.is_a?(Hash)
    if p["$ref"].is_a?(String) && p["$ref"].start_with?("#/components/parameters/")
      name = p["$ref"].split("/").last
      params = @handwritten_spec.dig("components", "parameters") || {}
      return params[name]
    end
    p
  end

  def merge_parameters!(op, hw_op, hw_path_params)
    return unless op["parameters"].is_a?(Array)
    hw_params_raw = Array(hw_op["parameters"]) + Array(hw_path_params)
    hw_by_name = {}
    hw_params_raw.each do |p|
      resolved = resolve_hw_param(p)
      next unless resolved.is_a?(Hash) && resolved["name"]
      hw_by_name[resolved["name"]] = resolved
    end
    return if hw_by_name.empty?

    op["parameters"].each do |gp|
      next unless gp.is_a?(Hash)
      name = gp["name"]
      hp = hw_by_name[name]
      next unless hp.is_a?(Hash)

      # description / example: hand-written wins
      if hp["description"].is_a?(String) && !hp["description"].empty?
        gp["description"] = hp["description"]
      end
      if hp["example"] && !gp.key?("example")
        gp["example"] = hp["example"]
      end

      # type override: query param marked `integer` by generator but `string`
      # by hand-written → trust hand-written (HTTP query params are strings
      # on the wire; e.g. order_id was forced to integer by an rspec literal).
      gp_schema = gp["schema"]
      hp_schema = hp["schema"]
      if gp.dig("in") == "query" && gp_schema.is_a?(Hash) && hp_schema.is_a?(Hash)
        if gp_schema["type"] == "integer" && hp_schema["type"] == "string"
          gp["schema"] = hp_schema
          gp_schema = gp["schema"]
        end
        # Carry hand-written enum if generated lacks one and the value types
        # are compatible (don't paste string-y enums onto a boolean schema).
        if hp_schema["enum"] && !gp_schema["enum"] && enum_compatible?(gp_schema, hp_schema["enum"])
          gp_schema["enum"] = hp_schema["enum"]
        end
        # Carry hand-written format
        if hp_schema["format"] && !gp_schema["format"]
          gp_schema["format"] = hp_schema["format"]
        end
      end
    end
  end

  def enum_compatible?(schema, values)
    type = schema["type"]
    return true if type.nil?
    case type
    when "boolean" then values.all? { |v| v == true || v == false }
    when "integer" then values.all? { |v| v.is_a?(Integer) }
    when "number"  then values.all? { |v| v.is_a?(Numeric) }
    when "string"  then values.all? { |v| v.is_a?(String) }
    else true
    end
  end

  def merge_request_body!(op, hw_op)
    hw_body = hw_op["requestBody"]
    return if hw_body.nil?

    if op["requestBody"].nil?
      # Generator had none; resolve handwritten $refs against components and
      # adopt verbatim. Keep as $ref strings — schemas section will pull them in.
      op["requestBody"] = hw_body
      return
    end

    # Both have a requestBody. Hand-written is the public contract — prefer it.
    # But preserve the generator's `required` flag if hand-written omits one.
    merged = deep_dup(hw_body)
    if !merged.key?("required") && op["requestBody"].key?("required")
      merged["required"] = op["requestBody"]["required"]
    end
    op["requestBody"] = merged
  end

  def merge_response_descriptions!(op, hw_op)
    return unless op["responses"].is_a?(Hash)
    hw_resps = hw_op["responses"] || {}
    hw_resps.each do |code, hw_resp|
      next unless hw_resp.is_a?(Hash)
      gen_resp = op["responses"][code]
      if gen_resp.nil?
        # Hand-written documents a status the generator didn't capture —
        # adopt verbatim (e.g. 500 on /licenses/verify).
        op["responses"][code] = hw_resp
        next
      end
      next unless gen_resp.is_a?(Hash)
      if hw_resp["description"].is_a?(String) && !hw_resp["description"].empty?
        gen_resp["description"] = hw_resp["description"]
      end
      # Don't override generated content[*].schema — that's structural truth.
    end
  end

  # ---- component schema merge ---------------------------------------------

  def merge_component_schemas!(spec)
    hw_schemas = @handwritten_spec.dig("components", "schemas") || {}
    return if hw_schemas.empty?

    spec["components"] ||= {}
    spec["components"]["schemas"] ||= {}
    gen_schemas = spec["components"]["schemas"]

    hw_schemas.each do |name, hw_schema|
      next unless hw_schema.is_a?(Hash)
      gen_schema = gen_schemas[name]

      if gen_schema.nil?
        gen_schemas[name] = sanitize_schema(deep_dup(hw_schema))
        next
      end

      if placeholder_schema?(gen_schema) && !placeholder_schema?(hw_schema)
        # Generated is a stub (e.g. `additionalProperties: true`); hand-written
        # carries real fields → prefer hand-written but keep any generated
        # description as a fallback.
        merged = sanitize_schema(deep_dup(hw_schema))
        if (gen_schema["description"].is_a?(String) && !gen_schema["description"].empty?) && (merged["description"].nil? || merged["description"].empty?)
          merged["description"] = gen_schema["description"]
        end
        gen_schemas[name] = merged
      else
        # Both real — generated wins on structure, augment with hand-written
        # field-level description / format prose.
        augment_schema_props!(gen_schema, hw_schema)
        # Pull in description if generated lacks one
        if (gen_schema["description"].nil? || gen_schema["description"].empty?) &&
            hw_schema["description"].is_a?(String) && !hw_schema["description"].empty?
          gen_schema["description"] = hw_schema["description"]
        end
      end
    end

    # Also pull in any handwritten-only top-level $ref targets cited from
    # operations we just merged (e.g. requestBody $refs to ProductCreate
    # components/parameters etc).
    pull_in_referenced_handwritten_components!(spec)
  end

  def placeholder_schema?(schema)
    return true unless schema.is_a?(Hash)
    return false if schema["properties"].is_a?(Hash) && !schema["properties"].empty?
    return false if schema["oneOf"].is_a?(Array) && !schema["oneOf"].empty?
    return false if schema["allOf"].is_a?(Array) && !schema["allOf"].empty?
    return false if schema["anyOf"].is_a?(Array) && !schema["anyOf"].empty?
    return false if schema["enum"].is_a?(Array) && !schema["enum"].empty?
    true
  end

  # Merge field-level description / format from hand-written into generated
  # schema's properties (without overwriting generated structure).
  def augment_schema_props!(gen_schema, hw_schema)
    gen_props = gen_schema["properties"]
    hw_props  = hw_schema["properties"]
    return unless gen_props.is_a?(Hash) && hw_props.is_a?(Hash)

    hw_props.each do |field, hw_prop|
      next unless hw_prop.is_a?(Hash)
      gen_prop = gen_props[field]
      next unless gen_prop.is_a?(Hash)

      if hw_prop["description"].is_a?(String) && !hw_prop["description"].empty? &&
          (gen_prop["description"].nil? || gen_prop["description"].empty?)
        gen_prop["description"] = hw_prop["description"]
      end
      if hw_prop["format"].is_a?(String) && !hw_prop["format"].empty? &&
          (gen_prop["format"].nil? || gen_prop["format"].empty?)
        gen_prop["format"] = hw_prop["format"]
      end
      if hw_prop["example"] && !gen_prop.key?("example")
        gen_prop["example"] = hw_prop["example"]
      end
    end
  end

  # After folding hand-written operations and schemas, walk the spec for any
  # $ref to #/components/schemas/<X> that doesn't yet exist in
  # spec["components"]["schemas"], and pull <X> in from the hand-written
  # components.schemas if available. Repeat until fixed point so transitive
  # refs (e.g. ProductCreate -> FileInput) are resolved.
  def pull_in_referenced_handwritten_components!(spec)
    hw_schemas = @handwritten_spec.dig("components", "schemas") || {}
    target = spec.dig("components", "schemas") || {}

    loop do
      missing = collect_missing_schema_refs(spec, target)
      newly_added = false
      missing.each do |name|
        if hw_schemas[name]
          target[name] = sanitize_schema(deep_dup(hw_schemas[name]))
          newly_added = true
        end
      end
      break unless newly_added
    end
  end

  def collect_missing_schema_refs(node, present)
    refs = Set.new
    walk_refs = lambda do |n|
      case n
      when Hash
        n.each do |k, v|
          if k == "$ref" && v.is_a?(String) && v.start_with?("#/components/schemas/")
            refs << v.split("/").last
          else
            walk_refs.call(v)
          end
        end
      when Array
        n.each { |x| walk_refs.call(x) }
      end
    end
    walk_refs.call(node)
    refs.reject { |r| present.key?(r) }
  end

  def deep_dup(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
    when Array then obj.map { |x| deep_dup(x) }
    when String then obj.dup
    else obj
    end
  end

  def summary(canonical, paths, schemas)
    path_count = paths.length
    op_count = paths.values.sum { |ops| ops.keys.count { |k| %w[get put post patch delete head options].include?(k.to_s) } }
    schema_count = schemas.length
    one_ofs = count_oneofs(paths) + count_oneofs_in_schemas(schemas)
    multi_status = paths.values.flat_map { |ops| ops.values.select { |v| v.is_a?(Hash) && v["responses"] } }
                        .count { |op| op["responses"].keys.length > 1 }

    puts "merger: wrote #{OUTPUT}"
    puts "  canonical routes: #{canonical.length}"
    puts "  paths:            #{path_count}"
    puts "  operations:       #{op_count}"
    puts "  schemas:          #{schema_count}"
    puts "  oneOf usages:     #{one_ofs}"
    puts "  multi-status ops: #{multi_status}"
  end

  def count_oneofs(paths)
    n = 0
    walk = ->(node) {
      case node
      when Hash
        n += 1 if node.key?("oneOf")
        node.each_value { |v| walk.call(v) }
      when Array
        node.each { |v| walk.call(v) }
      end
    }
    walk.call(paths)
    n
  end

  def count_oneofs_in_schemas(schemas)
    schemas.values.count { |s| s.is_a?(Hash) && s["oneOf"] }
  end
end

if $PROGRAM_NAME == __FILE__
  Merger.new.run
end
