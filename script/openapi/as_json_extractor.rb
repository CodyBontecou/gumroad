#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Static analyzer that walks app/models/**/*.rb, extracts every
# as_json* method, and produces tmp/openapi/from_serializers.yaml — a
# library of named JSON schemas keyed by "<Class>.<method_name>" with
# field-level scope tags so the merger can render oneOf variants.
#
# Run:
#   ruby script/openapi/as_json_extractor.rb
#
# Output: tmp/openapi/from_serializers.yaml
#
# Scope of analysis: app/models/**/*.rb only. Methods matching
# /^as_json(_.*)?$/ are treated as named serializers. Concerns whose
# method bodies live under app/models/concerns/<owner>/as_json.rb are
# also emitted under the apparent owner constant (e.g., Product.as_json
# in addition to Product::AsJson.as_json) so downstream tools can key on
# the public model name.

require "prism"
require "yaml"
require "set"
require "pathname"

ROOT = File.expand_path("../..", __dir__)
MODELS_DIR = File.join(ROOT, "app", "models")
OUTPUT_PATH = File.join(ROOT, "tmp", "openapi", "from_serializers.yaml")

AS_JSON_RE = /\Aas_json(_.*)?\z/

# ---------------------------------------------------------------------------
# Helpers — node walking / literal extraction
# ---------------------------------------------------------------------------

def constant_name(node)
  case node
  when Prism::ConstantReadNode then node.name.to_s
  when Prism::ConstantPathNode
    parent = node.respond_to?(:parent) ? node.parent : nil
    child = node.respond_to?(:child) ? node.child : nil
    [constant_name(parent), child ? constant_name(child) : node.name.to_s].compact.reject(&:empty?).join("::")
  else
    nil
  end
end

def literal_symbol(node)
  return nil if node.nil?
  case node
  when Prism::SymbolNode then node.unescaped.to_sym
  when Prism::StringNode then node.unescaped.to_sym
  end
end

def literal_string(node)
  case node
  when Prism::StringNode then node.unescaped
  when Prism::SymbolNode then node.unescaped
  end
end

def literal_value(node)
  case node
  when Prism::StringNode then node.unescaped
  when Prism::SymbolNode then node.unescaped.to_sym
  when Prism::IntegerNode then node.value
  when Prism::FloatNode then node.value
  when Prism::TrueNode then true
  when Prism::FalseNode then false
  when Prism::NilNode then nil
  end
end

# Best-effort type inference from a value node returned in the hash.
def infer_type(node)
  case node
  when Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode then "string"
  when Prism::IntegerNode then "integer"
  when Prism::FloatNode then "number"
  when Prism::TrueNode, Prism::FalseNode then "boolean"
  when Prism::ArrayNode then "array"
  when Prism::HashNode, Prism::KeywordHashNode then "object"
  when Prism::NilNode then "unknown"
  when Prism::CallNode
    type_for_call(node)
  when Prism::AndNode, Prism::OrNode
    "unknown"
  when Prism::IfNode, Prism::UnlessNode
    "unknown"
  else
    "unknown"
  end
end

# Heuristic type inference based on method name suffixes.
TYPE_HINTS = {
  /\?\z/ => "boolean",
  /_at\z/ => "string",         # timestamp serialized as ISO8601
  /_on\z/ => "string",
  /_url\z/ => "string",
  /_email\z/ => "string",
  /_count\z/ => "integer",
  /_cents\z/ => "integer",
  /_id\z/ => "string",
  /_ids\z/ => "array",
  /\Ais_/ => "boolean",
  /\Ahas_/ => "boolean",
  /\Acan_/ => "boolean",
  /_type\z/ => "string",
  /_name\z/ => "string",
  /_code\z/ => "string",
  /_path\z/ => "string",
}.freeze

KNOWN_METHOD_TYPES = {
  "external_id" => "string",
  "unique_permalink" => "string",
  "long_url" => "string",
  "to_s" => "string",
  "to_i" => "integer",
  "to_f" => "number",
  "size" => "integer",
  "count" => "integer",
  "length" => "integer",
  "blank?" => "boolean",
  "present?" => "boolean",
  "empty?" => "boolean",
  "any?" => "boolean",
  "id" => "integer",
}.freeze

def type_for_call(call_node)
  name = call_node.name.to_s
  return KNOWN_METHOD_TYPES[name] if KNOWN_METHOD_TYPES.key?(name)
  TYPE_HINTS.each { |re, t| return t if name =~ re }

  # Method-chain results: x.foo.bar — peek at the terminal call.
  if call_node.receiver.is_a?(Prism::CallNode)
    inner = type_for_call(call_node.receiver) if name == :"as_json".to_s
    return inner if inner
  end

  "unknown"
end

# Source string for a node — used as the field's "source" hint.
def source_for(node, source_text)
  case node
  when Prism::CallNode
    name = node.name.to_s
    # Prefer rendering simple "method" or "receiver.method" patterns.
    if node.receiver.nil? && (node.arguments.nil? || node.arguments.arguments.empty?)
      return name
    end
    snippet(node, source_text)
  when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode
    snippet(node, source_text)
  when Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode
    snippet(node, source_text)
  else
    snippet(node, source_text)
  end
end

def snippet(node, source_text)
  return nil unless node.respond_to?(:location) && node.location
  loc = node.location
  # Prism reports byte offsets; convert to char offsets via byteslice on the
  # source's binary representation, then force-encode back to UTF-8.
  bytes = source_text.b
  slice = bytes.byteslice(loc.start_offset, loc.end_offset - loc.start_offset)
  slice&.force_encoding("UTF-8")&.gsub(/\s+/, " ")&.strip
rescue StandardError
  nil
end

# ---------------------------------------------------------------------------
# Scope predicate detection
# ---------------------------------------------------------------------------
#
# We try to recognize calls like:
#   options[:api_scopes].include?("view_sales")
#   api_scopes.include?(:account)
#   api_scopes_options(options).include?("view_profile")
#   (options[:api_scopes] & %w[view_sales account]).present?
#   options[:api_scopes].present?
#   valid_api_scope?(options) / view_profile_scope?(options) — known helpers
#
# Returns an Array of scope strings, or nil if not a scope predicate.

KNOWN_SCOPE_HELPERS = {
  "valid_api_scope?" => %w[edit_products view_sales revenue_share ifttt view_profile account],
  "view_profile_scope?" => %w[view_profile account],
}.freeze

def detect_scopes(condition_node)
  return nil if condition_node.nil?

  case condition_node
  when Prism::CallNode
    # Helper predicates with known scope sets.
    if KNOWN_SCOPE_HELPERS.key?(condition_node.name.to_s)
      return KNOWN_SCOPE_HELPERS[condition_node.name.to_s]
    end

    # foo.include?("scope") — extract literal arg.
    if condition_node.name == :include?
      args = condition_node.arguments&.arguments || []
      scopes = args.map { |a| literal_string(a) }.compact
      return scopes if scopes.any? && receiver_mentions_api_scopes?(condition_node.receiver)
    end

    # foo.present? — receiver might be (api_scopes & %w[...])
    if condition_node.name == :present? || condition_node.name == :any?
      scopes = scopes_from_intersection(condition_node.receiver)
      return scopes if scopes
    end

    # & alone (rare in conditions)
    if condition_node.name == :&
      scopes = scopes_from_intersection(condition_node)
      return scopes if scopes
    end
  when Prism::ParenthesesNode
    return detect_scopes(condition_node.body) if condition_node.body
  when Prism::AndNode, Prism::OrNode
    left = detect_scopes(condition_node.left)
    right = detect_scopes(condition_node.right)
    combined = [left, right].compact.flatten.uniq
    return combined if combined.any?
  when Prism::StatementsNode
    if condition_node.body && condition_node.body.length == 1
      return detect_scopes(condition_node.body.first)
    end
  end
  nil
end

def receiver_mentions_api_scopes?(node)
  return false if node.nil?
  text = node.respond_to?(:location) && node.location ? node.slice : node.to_s
  text.include?("api_scopes") || text.include?("api_scope")
rescue StandardError
  false
end

# Recognize `(options[:api_scopes] & %w[view_sales account])` and similar.
def scopes_from_intersection(node)
  cur = node
  cur = cur.body if cur.is_a?(Prism::ParenthesesNode) && cur.respond_to?(:body)
  cur = cur.body.first if cur.is_a?(Prism::StatementsNode) && cur.body.length == 1
  return nil unless cur.is_a?(Prism::CallNode) && cur.name == :&

  left = cur.receiver
  right = cur.arguments&.arguments&.first
  return nil if left.nil? || right.nil?

  if receiver_mentions_api_scopes?(left)
    return scope_array(right)
  elsif receiver_mentions_api_scopes?(right)
    return scope_array(left)
  end
  nil
end

def scope_array(node)
  case node
  when Prism::ArrayNode
    node.elements.map { |e| literal_string(e) }.compact
  end
end

# ---------------------------------------------------------------------------
# Core extractor — walks methods named as_json*
# ---------------------------------------------------------------------------

class ExtractedField
  attr_accessor :name, :type, :source, :nested, :required_when_scopes,
                :required_when_condition, :gated, :inherited_from
  def initialize(name)
    @name = name
    @type = "unknown"
    @source = nil
    @nested = nil
    @required_when_scopes = []
    @required_when_condition = nil
    @gated = false
  end

  def to_h
    h = { "type" => @type }
    h["source"] = @source if @source
    h["properties"] = @nested if @nested
    h["required_when_scopes"] = @required_when_scopes.uniq unless @required_when_scopes.empty?
    h["required_when_condition"] = @required_when_condition if @required_when_condition
    h
  end
end

class SerializerBuilder
  attr_reader :fields, :inherits, :variants, :returns, :notes

  def initialize
    @fields = {}            # name => ExtractedField
    @inherits = []          # list of "<Class>.<method>" or symbolic notes
    @variants = []          # [{ scopes: [...], adds: [...] }]
    @returns = []           # for `return {...}` early-returns: list of hashes
    @notes = []
  end

  def add_field(name, field)
    return if name.nil?
    if @fields[name]
      # Merge: keep most specific type, accumulate scope tags.
      existing = @fields[name]
      existing.type = field.type if existing.type == "unknown" && field.type != "unknown"
      existing.source ||= field.source
      existing.nested ||= field.nested
      # If a field appears unconditionally in one branch and conditionally in
      # another, the unconditional path makes it always-present.
      if existing.gated && !field.gated
        existing.required_when_scopes = []
        existing.required_when_condition = nil
        existing.gated = false
      elsif !existing.gated && field.gated
        # keep existing as ungated
      else
        existing.required_when_scopes |= field.required_when_scopes
        existing.required_when_condition ||= field.required_when_condition
      end
    else
      @fields[name] = field
    end
  end

  def add_inherits(ref)
    @inherits << ref unless @inherits.include?(ref)
  end

  def to_schema
    properties = {}
    required = []
    @fields.each do |name, f|
      properties[name.to_s] = f.to_h
      required << name.to_s unless f.gated
    end
    schema = { "type" => "object", "properties" => properties }
    schema["required"] = required unless required.empty?
    schema["inherits"] = @inherits.uniq unless @inherits.empty?
    schema["scope_variants"] = @variants unless @variants.empty?
    schema["return_variants"] = @returns unless @returns.empty?
    schema["notes"] = @notes unless @notes.empty?
    schema
  end
end

class HashWalker
  # Walks a method body and accumulates fields into a SerializerBuilder.
  # Tracks the "current" hash variable being built up across statements.
  def initialize(builder, source_text, scope_stack: [], condition_stack: [])
    @builder = builder
    @source_text = source_text
    @scope_stack = scope_stack         # array of scope-string arrays (AND-stacked)
    @condition_stack = condition_stack # array of free-form conditions (AND-stacked)
    @hash_var = nil                    # name of the hash local var, e.g. :json
    @hash_var_scopes = []              # scopes assigned at variable creation time
  end

  def walk_method(method_node)
    body = method_node.body
    return unless body

    walk_statements(body, top_level: true)
  end

  def walk_statements(stmts_node, top_level: false)
    return unless stmts_node
    list =
      if stmts_node.is_a?(Prism::StatementsNode)
        stmts_node.body
      elsif stmts_node.is_a?(Prism::BeginNode)
        stmts_node.statements&.body || []
      else
        [stmts_node]
      end

    list.each_with_index do |stmt, idx|
      is_last = top_level && idx == list.length - 1
      walk_statement(stmt, is_last: is_last)
    end
  end

  def walk_statement(stmt, is_last: false)
    case stmt
    when Prism::ReturnNode
      handle_return(stmt)
    when Prism::LocalVariableWriteNode
      handle_local_assign(stmt)
    when Prism::CallNode
      handle_call(stmt, is_last: is_last)
    when Prism::IfNode
      handle_conditional(stmt, negate: false)
    when Prism::UnlessNode
      handle_conditional(stmt, negate: true)
    when Prism::HashNode, Prism::KeywordHashNode
      # bare hash at end of method == implicit return
      if is_last
        absorb_hash(stmt)
      end
    when Prism::LocalVariableReadNode
      # `json` at end of method — nothing new to absorb
    when Prism::IndexOperatorWriteNode, Prism::IndexAndWriteNode, Prism::IndexOrWriteNode
      handle_index_write(stmt)
    when Prism::BeginNode
      walk_statements(stmt.statements) if stmt.statements
    end
  end

  def handle_return(ret_node)
    val = ret_node.arguments&.arguments&.first
    return unless val

    if val.is_a?(Prism::HashNode) || val.is_a?(Prism::KeywordHashNode)
      # Capture as a return variant if we're inside a guard, otherwise fold in.
      if @condition_stack.any? || @scope_stack.any?
        capture_return_variant(val)
      else
        absorb_hash(val)
      end
    elsif val.is_a?(Prism::CallNode)
      # `return as_json_for_admin_review` etc.
      handle_terminal_call_value(val)
    end
  end

  def handle_local_assign(assign)
    return unless assign.respond_to?(:value) && assign.value
    val = assign.value
    name = assign.name.to_s

    if val.is_a?(Prism::HashNode) || val.is_a?(Prism::KeywordHashNode)
      @hash_var = name.to_sym
      @hash_var_scopes = @scope_stack.flatten.uniq
      absorb_hash(val)
    elsif val.is_a?(Prism::CallNode) && hash_chain?(val)
      @hash_var = name.to_sym
      @hash_var_scopes = @scope_stack.flatten.uniq
      walk_call_chain(val)
    elsif val.is_a?(Prism::IfNode)
      # `result = if cond ; chain1 ; else ; chain2 ; end` — walk both branches.
      @hash_var = name.to_sym
      @hash_var_scopes = @scope_stack.flatten.uniq
      walk_branching_assign(val)
    elsif val.is_a?(Prism::UnlessNode)
      @hash_var = name.to_sym
      @hash_var_scopes = @scope_stack.flatten.uniq
      walk_branching_assign(val, negate: true)
    end
  end

  def walk_branching_assign(if_node, negate: false)
    predicate = if_node.predicate
    scopes = detect_scopes(predicate)
    cond_text = nil
    if scopes.nil?
      cond_text = snippet(predicate, @source_text)
      cond_text = "!(#{cond_text})" if negate && cond_text
    end

    push_scopes = scopes
    push_cond = cond_text

    @scope_stack.push(push_scopes) if push_scopes
    @condition_stack.push(push_cond) if push_cond

    if if_node.statements
      if_node.statements.body.each { |s| walk_assigned_branch_value(s) }
    end

    @scope_stack.pop if push_scopes
    @condition_stack.pop if push_cond

    sub = if_node.respond_to?(:subsequent) ? if_node.subsequent : nil
    if sub
      # For an if/else assigned-value, fields in either branch are unconditionally
      # present. Don't tag the else branch with the negated condition — that
      # produces noisy, mutually-exclusive constraints. The merger can deduce
      # variants from `scope_variants` if needed.
      if sub.is_a?(Prism::ElseNode)
        sub.statements&.body&.each { |s| walk_assigned_branch_value(s) }
      elsif sub.is_a?(Prism::IfNode)
        walk_branching_assign(sub)
      end
    end
  end

  def walk_assigned_branch_value(stmt)
    case stmt
    when Prism::HashNode, Prism::KeywordHashNode
      absorb_hash(stmt)
    when Prism::CallNode
      if hash_chain?(stmt)
        walk_call_chain(stmt)
      else
        # bare method call returning a hash, e.g. some_helper(options)
        @builder.add_inherits(snippet(stmt, @source_text))
      end
    end
  end

  def hash_chain?(call_node)
    cur = call_node
    while cur.is_a?(Prism::CallNode)
      return true if cur.name == :merge || cur.name == :merge!
      arg = cur.arguments&.arguments&.first
      return true if arg.is_a?(Prism::HashNode) || arg.is_a?(Prism::KeywordHashNode)
      cur = cur.receiver
    end
    false
  end

  def walk_call_chain(call_node)
    chain = []
    cur = call_node
    while cur.is_a?(Prism::CallNode)
      chain << cur
      cur = cur.receiver
    end

    # Detect super.merge(...)
    super_node = chain.last && chain.last.receiver
    super_node ||= chain.last  # same thing

    # The bottom of a super-rooted chain has receiver=SuperNode. Find it.
    super_node = nil
    chain.each do |c|
      if c.respond_to?(:receiver) && c.receiver.is_a?(Prism::SuperNode)
        super_node = c.receiver
        break
      end
    end
    if super_node
      sc_args = super_node.arguments&.arguments || []
      hash_arg = sc_args.grep(Prism::HashNode).first || sc_args.grep(Prism::KeywordHashNode).first
      if hash_arg
        only_node = hash_arg.elements.find do |e|
          e.is_a?(Prism::AssocNode) && literal_symbol(e.key) == :only
        end&.value
        if only_node.is_a?(Prism::ArrayNode)
          only_node.elements.each do |fname_node|
            fname = literal_symbol(fname_node)
            next unless fname
            field = ExtractedField.new(fname.to_s)
            TYPE_HINTS.each do |re, t|
              if fname.to_s =~ re
                field.type = t
                break
              end
            end
            field.source = "super(only: #{fname})"
            scopes = @scope_stack.flatten.uniq
            cond = @condition_stack.compact.join(" && ")
            if scopes.any?
              field.required_when_scopes = scopes
              field.gated = true
            elsif !cond.empty?
              field.required_when_condition = cond
              field.gated = true
            end
            @builder.add_field(fname.to_s, field)
          end
        end
      end
      @builder.add_inherits("super")
    end

    # Only :merge / :merge! contribute fields to the resulting hash.
    # The base call (e.g. `super(only: ...)` or `as_json(original: true, only: keep)`)
    # has kwargs that configure the call, not output fields — skip its args.
    chain.reverse.each do |c|
      next unless c.name == :merge || c.name == :merge!
      args = c.arguments&.arguments || []
      args.each do |a|
        if a.is_a?(Prism::HashNode) || a.is_a?(Prism::KeywordHashNode)
          absorb_hash(a)
        elsif a.is_a?(Prism::CallNode)
          ref_name = a.name.to_s
          if ref_name =~ AS_JSON_RE
            @builder.add_inherits(ref_name)
          else
            @builder.add_inherits(snippet(a, @source_text))
          end
        end
      end
    end
  end

  def handle_call(call, is_last: false)
    # super-call chains:  super(only: ...).merge(...)
    if call.receiver.is_a?(Prism::SuperNode) || call.name == :merge || call.name == :merge!
      walk_call_chain(call)
      return
    end

    if call.is_a?(Prism::SuperNode) || call.is_a?(Prism::ForwardingSuperNode)
      @builder.add_inherits("super")
      return
    end

    # Index assignment as_call: json[:foo] = ... is already an IndexOperatorWriteNode normally
    # but Prism sometimes emits CallNode with name :[]= — handle that:
    if call.name == :[]= && call.receiver.is_a?(Prism::LocalVariableReadNode)
      args = call.arguments&.arguments || []
      key = args.first
      val = args[1]
      add_field_from_assign(key, val) if key && val
      return
    end

    # Trailing expressions like `json` or chained merges as the final returned value
    if is_last && hash_chain?(call)
      walk_call_chain(call)
    end
  end

  def handle_index_write(node)
    receiver = node.receiver
    return unless receiver.is_a?(Prism::LocalVariableReadNode) || receiver.is_a?(Prism::CallNode)

    args = node.arguments&.arguments || []
    key = args.first
    val = node.respond_to?(:value) ? node.value : nil
    return unless key && val

    add_field_from_assign(key, val)
  end

  def handle_conditional(if_node, negate:)
    predicate = if_node.predicate
    scopes = detect_scopes(predicate)
    cond_text = nil
    if scopes.nil?
      cond_text = snippet(predicate, @source_text)
      cond_text = "!(#{cond_text})" if negate && cond_text
    end

    push_scopes = scopes
    push_cond = cond_text

    if scopes && negate
      # `unless api_scopes.include?(...)` — flip into a non-scope condition.
      push_scopes = nil
      push_cond = "!api_scopes.include?(#{scopes.join(',')})"
    end

    @scope_stack.push(push_scopes) if push_scopes
    @condition_stack.push(push_cond) if push_cond

    walk_statements(if_node.statements) if if_node.statements

    # Else branch: scope is "not in scopes" — record condition only.
    if if_node.respond_to?(:subsequent) && if_node.subsequent
      @scope_stack.pop if push_scopes
      @condition_stack.pop if push_cond
      neg_cond = scopes ? "!api_scopes.include?(#{scopes.join(',')})" : (cond_text ? "!(#{cond_text})" : nil)
      @condition_stack.push(neg_cond) if neg_cond
      sub = if_node.subsequent
      if sub.is_a?(Prism::ElseNode)
        walk_statements(sub.statements) if sub.statements
      elsif sub.is_a?(Prism::IfNode)
        handle_conditional(sub, negate: false)
      end
      @condition_stack.pop if neg_cond
      return
    end

    @scope_stack.pop if push_scopes
    @condition_stack.pop if push_cond
  end

  # Top-level hash literal — absorb all key/value pairs as fields.
  def absorb_hash(hash_node)
    elements = hash_node.respond_to?(:elements) ? hash_node.elements : []
    elements.each do |elem|
      case elem
      when Prism::AssocNode
        add_field_from_assign(elem.key, elem.value)
      when Prism::AssocSplatNode
        # **other_hash — treat as inherits if it's a method call.
        if elem.value.is_a?(Prism::CallNode)
          @builder.add_inherits("**#{snippet(elem.value, @source_text)}")
        end
      end
    end
  end

  def capture_return_variant(hash_node)
    fields = []
    hash_node.elements.each do |elem|
      next unless elem.is_a?(Prism::AssocNode)
      key = literal_symbol(elem.key) || (elem.key.is_a?(Prism::CallNode) && elem.key.name)
      fields << key.to_s if key
    end
    variant = { "fields" => fields }
    variant["scopes"] = @scope_stack.flatten.uniq if @scope_stack.any?
    variant["condition"] = @condition_stack.compact.join(" && ") if @condition_stack.any?
    @builder.returns << variant unless variant["fields"].empty?

    # Also fold into main schema as gated fields.
    hash_node.elements.each do |elem|
      next unless elem.is_a?(Prism::AssocNode)
      add_field_from_assign(elem.key, elem.value)
    end
  end

  def add_field_from_assign(key_node, val_node)
    name = literal_symbol(key_node) || (key_node.is_a?(Prism::StringNode) && key_node.unescaped.to_sym)
    return unless name

    field = ExtractedField.new(name.to_s)
    field.type = infer_type(val_node)
    field.source = source_for(val_node, @source_text)

    # Type fallback from key naming if still unknown.
    if field.type == "unknown"
      TYPE_HINTS.each do |re, t|
        if name.to_s =~ re
          field.type = t
          break
        end
      end
    end

    if val_node.is_a?(Prism::HashNode) || val_node.is_a?(Prism::KeywordHashNode)
      field.nested = build_nested(val_node)
    end

    scopes = @scope_stack.flatten.uniq
    cond = @condition_stack.compact.join(" && ")
    if scopes.any?
      field.required_when_scopes = scopes
      field.gated = true
    elsif !cond.empty?
      field.required_when_condition = cond
      field.gated = true
    end

    @builder.add_field(name.to_s, field)
  end

  def build_nested(hash_node)
    nested = {}
    hash_node.elements.each do |elem|
      next unless elem.is_a?(Prism::AssocNode)
      sub_name = literal_symbol(elem.key) || (elem.key.is_a?(Prism::StringNode) && elem.key.unescaped.to_sym)
      next unless sub_name
      sub_field = ExtractedField.new(sub_name.to_s)
      sub_field.type = infer_type(elem.value)
      sub_field.source = source_for(elem.value, @source_text)
      if elem.value.is_a?(Prism::HashNode) || elem.value.is_a?(Prism::KeywordHashNode)
        sub_field.nested = build_nested(elem.value)
      end
      nested[sub_name.to_s] = sub_field.to_h
    end
    nested
  end

  def handle_terminal_call_value(call)
    return unless call
    # Prefer the bare method name when it's a simple method call so the
    # merger can resolve it later.
    ref =
      if call.is_a?(Prism::CallNode) && call.receiver.nil? && (call.arguments.nil? || call.arguments.arguments.empty?)
        call.name.to_s
      elsif call.is_a?(Prism::CallNode)
        # `json.merge!(foo)` — terminal in a return — record a generic ref.
        if call.name == :merge! || call.name == :merge
          call.arguments&.arguments&.each do |a|
            if a.is_a?(Prism::HashNode) || a.is_a?(Prism::KeywordHashNode)
              absorb_hash(a)
            elsif a.is_a?(Prism::CallNode)
              @builder.add_inherits(a.name.to_s)
            end
          end
          return
        else
          call.name.to_s
        end
      end
    @builder.add_inherits(ref) if ref && !ref.empty?
  end
end

# ---------------------------------------------------------------------------
# File-level walker — locates classes/modules and as_json* methods.
# ---------------------------------------------------------------------------

class FileExtractor
  attr_reader :schemas, :as_json_method_count

  def initialize
    @schemas = {}                      # "Owner.method_name" => schema hash
    @as_json_method_count = 0
    @class_stack = []                  # stack of constant names
  end

  def process(path)
    source = File.read(path)
    parsed = Prism.parse(source)
    return if parsed.failure?

    visit(parsed.value, source)
  end

  private

  def visit(node, source)
    case node
    when Prism::ProgramNode
      visit(node.statements, source) if node.statements
    when Prism::StatementsNode
      node.body.each { |c| visit(c, source) }
    when Prism::ClassNode
      name = constant_name(node.constant_path) || node.name.to_s
      @class_stack.push(name)
      visit(node.body, source) if node.body
      @class_stack.pop
    when Prism::ModuleNode
      name = constant_name(node.constant_path) || node.name.to_s
      @class_stack.push(name)
      visit(node.body, source) if node.body
      @class_stack.pop
    when Prism::DefNode
      method_name = node.name.to_s
      if method_name =~ AS_JSON_RE
        @as_json_method_count += 1
        emit_method_schema(node, source)
      end
    when Prism::SingletonClassNode
      visit(node.body, source) if node.body
    when Prism::BeginNode
      visit(node.statements, source) if node.statements
    end
  rescue StandardError => e
    warn "ERROR while visiting #{node.class} in some file: #{e.class}: #{e.message}"
  end

  def emit_method_schema(method_node, source)
    builder = SerializerBuilder.new
    walker = HashWalker.new(builder, source)
    walker.walk_method(method_node)

    owner = compose_owner_name
    return if owner.nil? || owner.empty?

    schema_key = "#{owner}.#{method_node.name}"
    @schemas[schema_key] = builder.to_schema

    # Concern alias: Product::AsJson#as_json => emit Product.as_json too.
    if owner.end_with?("::AsJson")
      base = owner.delete_suffix("::AsJson")
      alias_key = "#{base}.#{method_node.name}"
      unless @schemas.key?(alias_key)
        aliased = deep_dup(builder.to_schema)
        aliased["source_module"] = owner
        @schemas[alias_key] = aliased
      end
    end
  end

  def deep_dup(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
    when Array then obj.map { |e| deep_dup(e) }
    when String then obj.dup
    else obj
    end
  end

  def compose_owner_name
    parts = @class_stack.compact.reject(&:empty?)
    return nil if parts.empty?
    parts.join("::")
  end
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run!
  models = Dir.glob(File.join(MODELS_DIR, "**", "*.rb"))
  extractor = FileExtractor.new

  files_with_as_json = 0
  models.each do |path|
    src = File.read(path)
    next unless src.match?(/def\s+as_json/)
    files_with_as_json += 1
    extractor.process(path)
  end

  schemas = extractor.schemas

  # Second-pass: scan model files for `include <Concern>::AsJson` and alias
  # the concern's schemas under the including model's name (e.g., Link.as_json
  # when `Link` does `include Product::AsJson`). This makes keys match the
  # public model names callers actually use.
  scan_concern_includes(models).each do |including_class, concern_name|
    schemas.keys.grep(/\A#{Regexp.escape(concern_name)}\./).each do |concern_key|
      method_name = concern_key.split(".", 2).last
      alias_key = "#{including_class}.#{method_name}"
      next if schemas.key?(alias_key)
      aliased = deep_dup_for_yaml(schemas[concern_key])
      aliased["source_module"] = concern_name
      schemas[alias_key] = aliased
    end
  end

  # Deep-dup to ensure no aliases (Psych emits & references for shared objects).
  output = { "schemas" => deep_dup_for_yaml(schemas) }

  FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
  File.write(OUTPUT_PATH, Psych.dump(output, line_width: -1))

  warn "Models scanned: #{models.size}"
  warn "Models with as_json*: #{files_with_as_json}"
  warn "as_json* methods found: #{extractor.as_json_method_count}"
  warn "Named schemas emitted: #{schemas.size}"
  warn "Wrote: #{OUTPUT_PATH}"
end

# Scan model files for `include Foo::AsJson` and similar; return a list of
# [including_class_name, concern_name] tuples.
def scan_concern_includes(model_paths)
  result = []
  model_paths.each do |path|
    # Skip concern files themselves.
    next if path.include?("/concerns/")
    src = File.read(path)
    next unless src.include?("AsJson")
    parsed = Prism.parse(src)
    next if parsed.failure?
    visitor = IncludeScanner.new
    parsed.value.accept(visitor)
    visitor.includes.each do |class_name, concern_name|
      result << [class_name, concern_name]
    end
  end
  result
end

class IncludeScanner < Prism::Visitor
  attr_reader :includes
  def initialize
    @includes = []
    @class_stack = []
  end

  def visit_class_node(node)
    name = constant_name(node.constant_path) || node.name.to_s
    @class_stack.push(name)
    super
    @class_stack.pop
  end

  def visit_module_node(node)
    name = constant_name(node.constant_path) || node.name.to_s
    @class_stack.push(name)
    super
    @class_stack.pop
  end

  def visit_call_node(node)
    if node.name == :include && @class_stack.any?
      args = node.arguments&.arguments || []
      args.each do |a|
        cn = constant_name(a)
        next unless cn
        if cn.end_with?("::AsJson") || cn == "AsJson"
          # Resolve bare `AsJson` to enclosing namespace's AsJson if possible.
          full = if cn == "AsJson"
            ["#{@class_stack.last}::AsJson"]
          else
            [cn]
          end
          full.each { |n| @includes << [@class_stack.last, n] }
        end
      end
    end
    super
  end

  private

  def constant_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode
      parent = node.respond_to?(:parent) ? node.parent : nil
      child = node.respond_to?(:child) ? node.child : nil
      [constant_name(parent), child ? constant_name(child) : node.name.to_s].compact.reject(&:empty?).join("::")
    end
  end
end

require "fileutils"

def deep_dup_for_yaml(obj)
  case obj
  when Hash then obj.each_with_object({}) { |(k, v), h| h[deep_dup_for_yaml(k)] = deep_dup_for_yaml(v) }
  when Array then obj.map { |e| deep_dup_for_yaml(e) }
  when String then obj.dup
  when Symbol then obj.to_s.dup
  else obj
  end
end

run! if $PROGRAM_NAME == __FILE__
