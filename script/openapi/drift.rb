# frozen_string_literal: true

# script/openapi/drift.rb
#
# Diff the freshly generated docs/openapi.yaml against the prior hand-written
# docs/openapi.yaml.handwritten.bak and produce a categorized drift report at
# tmp/openapi/drift_report.md.
#
# Re-run:
#   bundle exec ruby script/openapi/drift.rb
#
# The hand-written .bak has a YAML parse error on line 1258 (an unquoted scalar
# containing `version: 2`). We patch that single line in-memory before parsing;
# the source file is never modified.

require "yaml"
require "json"
require "set"
require "time"
require "stringio"
require "fileutils"

ROOT       = File.expand_path("../..", __dir__)
GEN_PATH   = File.join(ROOT, "docs/openapi.yaml")
HW_PATH    = File.join(ROOT, "docs/openapi.yaml.handwritten.bak")
ROUTES     = File.join(ROOT, "tmp/openapi/routes.json")
OUT_PATH   = File.join(ROOT, "tmp/openapi/drift_report.md")

VERBS = %w[get put post patch delete options head trace].freeze

def load_handwritten(path)
  raw = File.read(path)
  # Line 1258 contains an unquoted scalar with a colon inside backticks:
  #   description: Shape comes from `Purchase#as_json(version: 2)`.
  # Wrap that single description value in double quotes so YAML parses cleanly.
  patched = raw.sub(
    /^(\s+description:\s+)(Shape comes from `Purchase#as_json\(version: 2\)`\.)\s*$/,
    '\1"\2"'
  )
  YAML.safe_load(patched, aliases: true, permitted_classes: [Symbol])
end

def load_generated(path)
  YAML.load_file(path, aliases: true, permitted_classes: [Symbol])
end

def each_operation(doc)
  return enum_for(:each_operation, doc) unless block_given?
  (doc["paths"] || {}).each do |path, ops_h|
    next unless ops_h.is_a?(Hash)
    ops_h.each do |verb, op|
      next unless VERBS.include?(verb.to_s.downcase)
      next unless op.is_a?(Hash)
      yield verb.to_s.upcase, path, op
    end
  end
end

def operation_keys(doc)
  set = Set.new
  each_operation(doc) { |v, p, _| set << "#{v} #{p}" }
  set
end

def routes_index(routes_path)
  return {} unless File.exist?(routes_path)
  raw = JSON.parse(File.read(routes_path))
  routes = raw.is_a?(Array) ? raw : raw["routes"]
  index = {}
  Array(routes).each do |r|
    verb = r["verb"].to_s.upcase
    path = r["path"].to_s.sub(%r{\A/api/v2}, "").gsub(/:(\w+)/, '{\1}')
    index["#{verb} #{path}"] = r
  end
  index
end

def parameter_set(op)
  Array(op["parameters"]).filter_map do |p|
    next nil unless p.is_a?(Hash)
    [p["in"], p["name"]] if p["name"]
  end.to_set
end

def request_body_present?(op)
  op["requestBody"].is_a?(Hash) && !op["requestBody"].empty?
end

def response_codes(op)
  (op["responses"] || {}).keys.map(&:to_s).to_set
end

def has_examples?(node)
  return false unless node.is_a?(Hash)
  return true if node["example"] || node["examples"]
  node.values.any? { |v| has_examples?(v) }
end

def description_quality(desc)
  return :missing if desc.nil? || desc.to_s.strip.empty?
  return :template if desc.to_s.match?(/\A(GET|POST|PUT|PATCH|DELETE) `[^`]+` \(handled by/)
  return :template if desc.to_s.match?(/\A(Successful response|Unauthorized|Not found|Bad request|Forbidden)\s*[—.\-]?/)
  :prose
end

def collect_param_types(op)
  out = {}
  Array(op["parameters"]).each do |p|
    next unless p.is_a?(Hash)
    name = p["name"]
    schema = p["schema"]
    next unless name && schema.is_a?(Hash)
    out[name] = schema["type"] || (schema["oneOf"] && "oneOf") || schema["$ref"]
  end
  out
end

def schema_field_types(schema)
  return {} unless schema.is_a?(Hash)
  props = schema["properties"]
  return {} unless props.is_a?(Hash)
  props.transform_values do |v|
    next "ref" if v.is_a?(Hash) && v["$ref"]
    next v["type"] if v.is_a?(Hash) && v["type"]
    "any"
  end
end

# ---------------------------------------------------------------------------
# Load both specs.
# ---------------------------------------------------------------------------

puts "Loading docs/openapi.yaml.handwritten.bak ..."
hw = load_handwritten(HW_PATH)
puts "Loading docs/openapi.yaml ..."
gen = load_generated(GEN_PATH)
routes = routes_index(ROUTES)

hw_ops_set  = operation_keys(hw)
gen_ops_set = operation_keys(gen)

new_endpoints     = (gen_ops_set - hw_ops_set).sort
removed_endpoints = (hw_ops_set - gen_ops_set).sort
common_endpoints  = (gen_ops_set & hw_ops_set).sort

# Build (verb, path) => operation lookup for each side.
def op_lookup(doc)
  out = {}
  each_operation(doc) { |v, p, op| out["#{v} #{p}"] = [v, p, op] }
  out
end

hw_lookup  = op_lookup(hw)
gen_lookup = op_lookup(gen)

# ---------------------------------------------------------------------------
# Section C / D / E / F walk: per-endpoint diff.
# ---------------------------------------------------------------------------

schema_improvements = []   # C — generated more accurate
schema_regressions  = []   # D — handwritten richer
status_drift        = []   # E
type_mismatches     = []   # F

# Operation-level walk
common_endpoints.each do |key|
  _, _, hw_op  = hw_lookup[key]
  _, _, gen_op = gen_lookup[key]

  # E. Status codes
  hw_codes  = response_codes(hw_op)
  gen_codes = response_codes(gen_op)
  added   = (gen_codes - hw_codes).sort
  removed = (hw_codes - gen_codes).sort
  if added.any? || removed.any?
    status_drift << {
      endpoint: key,
      added: added,
      removed: removed
    }
  end

  # D. Description quality regressions
  hw_summary  = hw_op["summary"]
  gen_summary = gen_op["summary"]
  hw_desc_q   = description_quality(hw_op["description"])
  gen_desc_q  = description_quality(gen_op["description"])
  if hw_desc_q == :prose && gen_desc_q != :prose
    schema_regressions << {
      kind: :operation_description,
      endpoint: key,
      note: "handwritten had prose description; generated has template/none",
      hw_summary: hw_summary
    }
  end
  if hw_summary && gen_summary && hw_summary != gen_summary && hw_summary.length > gen_summary.length + 4
    schema_regressions << {
      kind: :operation_summary,
      endpoint: key,
      note: "handwritten summary is longer/more descriptive",
      hw: hw_summary,
      gen: gen_summary
    }
  end

  # D. Examples present in handwritten but not in generated
  hw_has_examples  = has_examples?(hw_op)
  gen_has_examples = has_examples?(gen_op)
  if hw_has_examples && !gen_has_examples
    schema_regressions << {
      kind: :operation_examples,
      endpoint: key,
      note: "handwritten included examples; generated has none"
    }
  end

  # F. Parameter type / format mismatches
  hw_param_types  = collect_param_types(hw_op)
  gen_param_types = collect_param_types(gen_op)
  (hw_param_types.keys & gen_param_types.keys).each do |name|
    h = hw_param_types[name]
    g = gen_param_types[name]
    next if h == g
    next if h.nil? || g.nil?
    next if h == "ref" || g == "ref" # $ref vs inline is not a real type drift
    type_mismatches << {
      endpoint: key,
      kind: :parameter,
      name: name,
      hw: h,
      gen: g
    }
  end

  # D. requestBody descriptions / examples lost
  hw_body  = hw_op["requestBody"]
  gen_body = gen_op["requestBody"]
  if hw_body.is_a?(Hash) && gen_body.is_a?(Hash)
    if has_examples?(hw_body) && !has_examples?(gen_body)
      schema_regressions << {
        kind: :request_body_examples,
        endpoint: key,
        note: "handwritten requestBody has examples; generated has none"
      }
    end
  elsif hw_body.is_a?(Hash) && gen_body.nil?
    schema_regressions << {
      kind: :request_body_missing,
      endpoint: key,
      note: "handwritten declared a requestBody; generated has none"
    }
  elsif gen_body.is_a?(Hash) && hw_body.nil?
    schema_improvements << {
      kind: :request_body_added,
      endpoint: key,
      note: "generated includes a requestBody schema (recorded from rspec); handwritten had none"
    }
  end

  # C. Generated has scope-conditional oneOf, more responses, etc.
  if gen_codes.size > hw_codes.size + 1
    schema_improvements << {
      kind: :more_response_codes,
      endpoint: key,
      note: "generated documents #{gen_codes.size} response codes (handwritten: #{hw_codes.size})",
      added: added
    }
  end
end

# ---------------------------------------------------------------------------
# Section C/D for component schemas.
# ---------------------------------------------------------------------------

hw_schemas  = (hw.dig("components", "schemas") || {})
gen_schemas = (gen.dig("components", "schemas") || {})

shared_schemas       = hw_schemas.keys & gen_schemas.keys
schemas_only_hw      = hw_schemas.keys - gen_schemas.keys
schemas_only_gen     = gen_schemas.keys - hw_schemas.keys

shared_schemas.each do |name|
  hw_schema  = hw_schemas[name]
  gen_schema = gen_schemas[name]
  hw_props   = schema_field_types(hw_schema)
  gen_props  = schema_field_types(gen_schema)

  # C. Generated discovered real fields where handwritten was open-ended.
  if hw_schema.is_a?(Hash) && hw_schema["additionalProperties"] == true && (gen_props.keys - hw_props.keys).any?
    schema_improvements << {
      kind: :schema_concrete_fields,
      schema: name,
      note: "handwritten was `additionalProperties: true`; generated lists #{gen_props.size} concrete fields",
      added_fields: (gen_props.keys - hw_props.keys).sort
    }
  end

  # C. Generated has oneOf scope variants (e.g. ForViews / ForSeller).
  gen_oneof = gen_schema.is_a?(Hash) && gen_schema["oneOf"].is_a?(Array)
  hw_oneof  = hw_schema.is_a?(Hash) && hw_schema["oneOf"].is_a?(Array)
  if gen_oneof && !hw_oneof
    titles = Array(gen_schema["oneOf"]).filter_map { |v| v["title"] if v.is_a?(Hash) }
    schema_improvements << {
      kind: :schema_oneof_variants,
      schema: name,
      note: "generated has scope-conditional oneOf variants; handwritten was flat",
      variants: titles
    }
  end

  # D. Field descriptions / types in handwritten that generated lost.
  hw_props_full = (hw_schema.is_a?(Hash) ? hw_schema["properties"] : nil) || {}
  gen_props_full = (gen_schema.is_a?(Hash) ? gen_schema["properties"] : nil) || {}
  fields_lost_descriptions = []
  fields_lost_examples     = []
  fields_lost_format       = []
  (hw_props_full.keys & gen_props_full.keys).each do |fname|
    h = hw_props_full[fname]
    g = gen_props_full[fname]
    next unless h.is_a?(Hash) && g.is_a?(Hash)
    fields_lost_descriptions << fname if h["description"] && (g["description"].nil? || g["description"].to_s.strip.empty?)
    fields_lost_examples     << fname if h["example"] && g["example"].nil?
    fields_lost_format       << fname if h["format"] && g["format"].nil?
  end
  if fields_lost_descriptions.any? || fields_lost_examples.any? || fields_lost_format.any?
    schema_regressions << {
      kind: :schema_field_metadata_lost,
      schema: name,
      lost_descriptions: fields_lost_descriptions,
      lost_examples: fields_lost_examples,
      lost_formats: fields_lost_format
    }
  end

  # F. Type mismatches at the schema field level.
  (hw_props.keys & gen_props.keys).each do |fname|
    h = hw_props[fname]
    g = gen_props[fname]
    next if h == g || h == "ref" || g == "ref" || h == "any" || g == "any"
    type_mismatches << {
      schema: name,
      kind: :schema_field,
      name: fname,
      hw: h,
      gen: g
    }
  end

  # D. Top-level schema description in handwritten lost in generated.
  hw_desc = hw_schema.is_a?(Hash) && hw_schema["description"]
  gen_desc = gen_schema.is_a?(Hash) && gen_schema["description"]
  if hw_desc && (!gen_desc || gen_desc.to_s.strip.length < hw_desc.to_s.strip.length / 2)
    schema_regressions << {
      kind: :schema_description_lost,
      schema: name,
      hw: hw_desc.to_s.strip,
      gen: gen_desc.to_s.strip
    }
  end
end

schemas_only_hw.each do |name|
  schema_regressions << {
    kind: :schema_dropped,
    schema: name,
    note: "schema present in handwritten but missing from generated"
  }
end

schemas_only_gen.each do |name|
  schema_improvements << {
    kind: :schema_added,
    schema: name,
    note: "schema present in generated but missing from handwritten"
  }
end

# ---------------------------------------------------------------------------
# Section G: x-gumroad-coverage: inferred operations.
# ---------------------------------------------------------------------------

inferred_ops = []
each_operation(gen) do |verb, path, op|
  next unless op["x-gumroad-coverage"] == "inferred"
  inferred_ops << [verb, path, op["summary"], op["operationId"]]
end
inferred_ops.sort_by! { |v, p, *_| [p, v] }

# ---------------------------------------------------------------------------
# Render report.
# ---------------------------------------------------------------------------

def md_h2(t); "## #{t}\n"; end
def md_h3(t); "### #{t}\n"; end

now = Time.now.strftime("%Y-%m-%d %H:%M:%S %z")

io = StringIO.new
io.puts "# OpenAPI Drift Report"
io.puts ""
io.puts "Generated: #{now}"
io.puts "Comparing: `docs/openapi.yaml` (generated) vs `docs/openapi.yaml.handwritten.bak`"
io.puts ""

io.puts md_h2("Summary")
io.puts ""
io.puts "- Operations: handwritten=#{hw_ops_set.size}, generated=#{gen_ops_set.size} (#{(gen_ops_set - hw_ops_set).size} new, #{(hw_ops_set - gen_ops_set).size} removed)"
io.puts "- Paths: handwritten=#{(hw['paths'] || {}).keys.size}, generated=#{(gen['paths'] || {}).keys.size}"
io.puts "- Component schemas: handwritten=#{hw_schemas.size}, generated=#{gen_schemas.size}"
io.puts "- Schema improvements (C): #{schema_improvements.size}"
io.puts "- Schema regressions (D): #{schema_regressions.size}"
io.puts "- Status-code drift (E): #{status_drift.size} endpoints"
io.puts "- Type/format mismatches (F): #{type_mismatches.size}"
io.puts "- `x-gumroad-coverage: inferred` operations (G): #{inferred_ops.size}"
io.puts ""

# A. New endpoints
io.puts md_h2("A. New endpoints (generated has, handwritten missing)")
io.puts ""
if new_endpoints.empty?
  io.puts "_None — the generated spec covers exactly the same operations as the handwritten one._"
  io.puts ""
  io.puts "(The original task brief said handwritten had 23 ops; the actual file has 57. The generated spec adds no new surface — it only enriches per-operation detail.)"
else
  new_endpoints.each do |key|
    verb, path = key.split(" ", 2)
    r = routes["#{verb} #{path}"]
    if r
      io.puts "- `#{verb} #{path}` — #{r['controller']}##{r['action']}#{r['has_spec'] ? '' : ' (no spec)'}"
    else
      io.puts "- `#{verb} #{path}` — (no matching entry in routes.json)"
    end
  end
end
io.puts ""

# B. Removed endpoints
io.puts md_h2("B. Removed endpoints (handwritten has, generated missing)")
io.puts ""
if removed_endpoints.empty?
  io.puts "_None._"
else
  removed_endpoints.each do |key|
    verb, path = key.split(" ", 2)
    r = routes["#{verb} #{path}"]
    if r
      io.puts "- `#{verb} #{path}` — still in routes.json (#{r['controller']}##{r['action']}); investigate why merger dropped it"
    else
      io.puts "- `#{verb} #{path}` — NOT in routes.json; probably a real removal"
    end
  end
end
io.puts ""

# C. Schema improvements
io.puts md_h2("C. Schema improvements (generated more accurate)")
io.puts ""
if schema_improvements.empty?
  io.puts "_None._"
else
  schema_improvements.sort_by { |i| [i[:kind].to_s, i[:schema] || i[:endpoint] || ""] }.each do |i|
    case i[:kind]
    when :schema_concrete_fields
      io.puts "- `#{i[:schema]}`: #{i[:note]}"
      sample = i[:added_fields].first(8).join(", ")
      io.puts "  - new fields: #{sample}#{i[:added_fields].size > 8 ? ", ... (+#{i[:added_fields].size - 8} more)" : ''}"
    when :schema_oneof_variants
      io.puts "- `#{i[:schema]}`: #{i[:note]}"
      io.puts "  - variants: #{i[:variants].join(', ')}" if i[:variants].any?
    when :schema_added
      io.puts "- `#{i[:schema]}`: #{i[:note]}"
    when :more_response_codes
      io.puts "- `#{i[:endpoint]}`: #{i[:note]} — added: #{i[:added].join(', ')}"
    when :request_body_added
      io.puts "- `#{i[:endpoint]}`: #{i[:note]}"
    else
      io.puts "- #{i.inspect}"
    end
  end
end
io.puts ""

# D. Schema regressions
io.puts md_h2("D. Schema regressions (handwritten richer)")
io.puts ""
if schema_regressions.empty?
  io.puts "_None._"
else
  schema_regressions.sort_by { |r| [r[:kind].to_s, (r[:schema] || r[:endpoint]).to_s] }.each do |r|
    case r[:kind]
    when :operation_description
      io.puts "- `#{r[:endpoint]}` (operation description) — #{r[:note]}"
    when :operation_summary
      io.puts "- `#{r[:endpoint]}` (summary) — #{r[:note]}: hw=`#{r[:hw]}` gen=`#{r[:gen]}`"
    when :operation_examples
      io.puts "- `#{r[:endpoint]}` (examples) — #{r[:note]}"
    when :request_body_examples
      io.puts "- `#{r[:endpoint]}` (requestBody examples) — #{r[:note]}"
    when :request_body_missing
      io.puts "- `#{r[:endpoint]}` (requestBody) — #{r[:note]}"
    when :schema_description_lost
      io.puts "- `#{r[:schema]}` (top-level description) — handwritten: #{r[:hw][0, 120]}#{r[:hw].length > 120 ? '…' : ''}"
    when :schema_field_metadata_lost
      bits = []
      bits << "descriptions: #{r[:lost_descriptions].join(', ')}" if r[:lost_descriptions].any?
      bits << "examples: #{r[:lost_examples].join(', ')}"         if r[:lost_examples].any?
      bits << "formats: #{r[:lost_formats].join(', ')}"           if r[:lost_formats].any?
      io.puts "- `#{r[:schema]}` (field-level metadata lost) — #{bits.join('; ')}"
    when :schema_dropped
      io.puts "- `#{r[:schema]}` — #{r[:note]}"
    else
      io.puts "- #{r.inspect}"
    end
  end
end
io.puts ""

# E. Status code drift
io.puts md_h2("E. Status code changes")
io.puts ""
if status_drift.empty?
  io.puts "_None._"
else
  status_drift.sort_by { |s| s[:endpoint] }.each do |s|
    bits = []
    bits << "added: #{s[:added].join(', ')}"     if s[:added].any?
    bits << "removed: #{s[:removed].join(', ')}" if s[:removed].any?
    io.puts "- `#{s[:endpoint]}` — #{bits.join('; ')}"
  end
end
io.puts ""

# F. Type mismatches
io.puts md_h2("F. Type / format mismatches")
io.puts ""
if type_mismatches.empty?
  io.puts "_None._"
else
  type_mismatches.sort_by { |t| [t[:schema] || t[:endpoint] || "", t[:name] || ""] }.each do |t|
    if t[:kind] == :parameter
      io.puts "- `#{t[:endpoint]}` parameter `#{t[:name]}` — handwritten=`#{t[:hw]}`, generated=`#{t[:gen]}`"
    else
      io.puts "- schema `#{t[:schema]}.#{t[:name]}` — handwritten=`#{t[:hw]}`, generated=`#{t[:gen]}`"
    end
  end
end
io.puts ""

# G. Inferred coverage watchlist
io.puts md_h2("G. Operations marked `x-gumroad-coverage: inferred`")
io.puts ""
io.puts "These operations were not exercised by rspec; their schemas come from"
io.puts "static analysis and route shape only. Lowest confidence in the spec."
io.puts ""
inferred_ops.each do |verb, path, summary, op_id|
  io.puts "- `#{verb.upcase} #{path}` — #{summary} (`#{op_id}`)"
end
io.puts ""

# Recommended manual cleanup
io.puts md_h2("Recommended manual cleanup (prioritized)")
io.puts ""

priorities = []

# 1. Schema descriptions / field-level prose lost — biggest wins for docs UX.
desc_lost = schema_regressions.select { |r| r[:kind] == :schema_description_lost }
fld_meta = schema_regressions.select { |r| r[:kind] == :schema_field_metadata_lost }
if desc_lost.any? || fld_meta.any?
  priorities << "Re-import schema descriptions and field-level prose from the handwritten spec into `script/openapi/static_specs.rb` (or hand-merge into `docs/openapi.yaml` after generation). Affected: #{(desc_lost.map { |r| r[:schema] } + fld_meta.map { |r| r[:schema] }).uniq.sort.join(', ')}."
end

# 2. requestBody schemas dropped — these break docs for write endpoints.
body_lost = schema_regressions.select { |r| r[:kind] == :request_body_missing }
if body_lost.any?
  priorities << "Restore requestBody schemas dropped on #{body_lost.size} endpoint(s): #{body_lost.map { |r| r[:endpoint] }.sort.join(', ')}. The handwritten file is the only place these payload contracts are written down today."
end

# 3. Inferred coverage — write or fix specs to flip these to rspec-recorded.
if inferred_ops.any?
  priorities << "Add controller specs (or fix existing ones) for the #{inferred_ops.size} `inferred` endpoints in section G so the next regen pulls real responses."
end

# 4. Operation prose / examples lost.
op_desc_lost = schema_regressions.select { |r| r[:kind] == :operation_description }
op_examples = schema_regressions.select { |r| r[:kind] == :operation_examples || r[:kind] == :request_body_examples }
if op_desc_lost.any? || op_examples.any?
  priorities << "Carry over operation-level prose descriptions and examples from the handwritten file (#{op_desc_lost.size} description regressions, #{op_examples.size} example regressions). The generator currently writes a template like `GET \\`/v2/foo\\` (handled by ...)` — the human prose is more useful."
end

# 5. Type mismatches.
if type_mismatches.any?
  priorities << "Reconcile #{type_mismatches.size} type/format mismatch(es) listed in section F. Most are likely the handwritten spec being lazy (`type: string`) vs the generator picking up the actual runtime type — verify each."
end

# 6. Schemas dropped.
dropped = schema_regressions.select { |r| r[:kind] == :schema_dropped }
if dropped.any?
  priorities << "#{dropped.size} hand-defined component schema(s) are missing from the generated spec: #{dropped.map { |r| r[:schema] }.sort.join(', ')}. Decide whether each is still useful and re-add to `static_specs.rb`."
end

if priorities.empty?
  io.puts "_No drift detected — generated and handwritten match closely._"
else
  priorities.each_with_index do |p, i|
    io.puts "#{i + 1}. #{p}"
  end
end
io.puts ""

FileUtils.mkdir_p(File.dirname(OUT_PATH))
File.write(OUT_PATH, io.string)
puts "Wrote #{OUT_PATH} (#{File.size(OUT_PATH)} bytes)"
