# frozen_string_literal: true

require "fileutils"
require "tempfile"

namespace :openapi do
  REPO_ROOT = File.expand_path("../..", __dir__)
  SCRIPT_DIR = File.join(REPO_ROOT, "script", "openapi")
  TMP_DIR = File.join(REPO_ROOT, "tmp", "openapi")
  CACHED_DIR = File.join(SCRIPT_DIR, "cached")
  CACHED_RSPEC = File.join(CACHED_DIR, "from_rspec.yaml")
  TMP_RSPEC = File.join(TMP_DIR, "from_rspec.yaml")
  OUTPUT_YAML = File.join(REPO_ROOT, "docs", "openapi.yaml")
  DRIFT_REPORT = File.join(TMP_DIR, "drift_report.md")

  def banner(msg)
    line = "=" * 72
    puts ""
    puts line
    puts "  #{msg}"
    puts line
  end

  def run!(cmd, description)
    puts "[openapi] #{description}"
    puts "[openapi] $ #{cmd}"
    success = system(cmd)
    abort("[openapi] FAILED: #{description}") unless success
  end

  desc "Run the full OpenAPI generation pipeline (phases A -> C). Set SKIP_RSPEC=1 to skip slow rspec recording."
  task :generate do
    FileUtils.mkdir_p(TMP_DIR)
    FileUtils.mkdir_p(CACHED_DIR)

    banner "Phase A: Routes scraper (Rails)"
    run!(
      "bin/rails runner #{File.join(SCRIPT_DIR, 'routes_scraper.rb').shellescape}",
      "Scraping Rails routes for api/v2"
    )

    banner "Phase B2: Static as_json extractor"
    run!(
      "ruby #{File.join(SCRIPT_DIR, 'as_json_extractor.rb').shellescape}",
      "Extracting as_json schemas from app/models"
    )

    banner "Phase B3: Static spec analyzer"
    run!(
      "ruby #{File.join(SCRIPT_DIR, 'static_specs.rb').shellescape}",
      "Analyzing v2 controller specs for required/forbidden fields"
    )

    if ENV["SKIP_RSPEC"] == "1"
      warn "[openapi] Skipping rspec recording (SKIP_RSPEC=1)."
      if File.exist?(TMP_RSPEC)
        warn "[openapi] Will use existing #{TMP_RSPEC}"
      elsif File.exist?(CACHED_RSPEC)
        warn "[openapi] tmp/openapi/from_rspec.yaml missing, falling back to #{CACHED_RSPEC}"
      else
        warn "[openapi] WARNING: neither #{TMP_RSPEC} nor #{CACHED_RSPEC} exists — merger will fail."
      end
    else
      banner "Phase B1: rspec-openapi recording"
      run!(
        File.join(SCRIPT_DIR, "run_rspec.sh").shellescape,
        "Recording v2 controller specs with OPENAPI=1"
      )
      if File.exist?(TMP_RSPEC)
        FileUtils.cp(TMP_RSPEC, CACHED_RSPEC)
        puts "[openapi] Updated cached rspec recording: #{CACHED_RSPEC}"
      end
    end

    banner "Phase C: Merger"
    run!(
      "ruby #{File.join(SCRIPT_DIR, 'merger.rb').shellescape}",
      "Merging intermediates into docs/openapi.yaml"
    )

    print_summary
  end

  desc "Quick OpenAPI regeneration without re-running rspec (uses cached from_rspec.yaml)"
  task :regen do
    ENV["SKIP_RSPEC"] = "1"
    Rake::Task["openapi:generate"].invoke
  end

  desc "Verify docs/openapi.yaml is up to date (regenerates and diffs). Exits non-zero on drift."
  task :check do
    abort("[openapi] docs/openapi.yaml does not exist — run rake openapi:generate first.") unless File.exist?(OUTPUT_YAML)

    backup = Tempfile.new(["openapi-current-", ".yaml"])
    backup.write(File.read(OUTPUT_YAML))
    backup.close

    puts "[openapi] Current docs/openapi.yaml saved to #{backup.path}"
    puts "[openapi] Regenerating..."

    ENV["SKIP_RSPEC"] = "1"
    Rake::Task["openapi:generate"].invoke

    puts ""
    puts "[openapi] Diffing regenerated spec against the previous one..."
    diff = `diff -u #{backup.path.shellescape} #{OUTPUT_YAML.shellescape}`
    backup.unlink

    if diff.empty?
      puts "[openapi] OpenAPI spec is up to date."
      exit 0
    else
      puts ""
      puts "[openapi] DRIFT DETECTED. docs/openapi.yaml does not match what the pipeline would generate."
      puts ""
      puts diff
      exit 1
    end
  end

  desc "Print drift report comparing generated vs. handwritten spec"
  task :drift do
    drift_script = File.join(SCRIPT_DIR, "drift.rb")
    unless File.exist?(drift_script)
      abort("[openapi] #{drift_script} does not exist. Phase D1 (drift detector) must be implemented before this task can run.")
    end

    FileUtils.mkdir_p(TMP_DIR)
    run!("ruby #{drift_script.shellescape}", "Comparing generated spec to handwritten backup")

    if File.exist?(DRIFT_REPORT)
      puts ""
      puts File.read(DRIFT_REPORT)
    else
      warn "[openapi] No drift report at #{DRIFT_REPORT}."
    end
  end

  def print_summary
    return unless File.exist?(OUTPUT_YAML)

    require "yaml"
    spec = YAML.unsafe_load_file(OUTPUT_YAML)
    paths = spec["paths"] || {}
    schemas = (spec.dig("components", "schemas") || {})
    operation_count = paths.values.sum do |verbs|
      verbs.is_a?(Hash) ? verbs.count { |k, _| %w[get post put patch delete head options trace].include?(k.to_s.downcase) } : 0
    end

    banner "Summary"
    puts "  output:     #{OUTPUT_YAML.sub(REPO_ROOT + '/', '')}"
    puts "  paths:      #{paths.size}"
    puts "  operations: #{operation_count}"
    puts "  schemas:    #{schemas.size}"
    puts ""
  end
end
