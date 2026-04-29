# frozen_string_literal: true

# Static analyzer for v2 controller specs.
#
# Walks the Prism AST of every spec file under `spec/controllers/api/v2/`
# and emits structured "test claims" — required/forbidden fields, observed
# enum values, status codes, and request param shapes — that rspec-openapi
# can't infer at runtime.
#
# Output: tmp/openapi/from_specs.yaml, keyed by `Controller#action`.
#
# Usage:
#   ruby script/openapi/static_specs.rb
#
# Notes:
#   - The analyzer is best-effort. When it can't resolve `@action` or
#     `@params` ivars across nested scopes, it skips rather than emit
#     garbage. Endpoints with zero facts are dropped from output.
#   - Status codes follow the response: when an `it` block contains a
#     `have_http_status(:not_found)` or `eq 404` assertion on the
#     response, all parsed_body assertions in that block are tagged with
#     that status. Default is 200.

require "prism"
require "yaml"
require "set"
require "json"

module OpenAPI
  module StaticSpecs
    SPEC_DIR = File.expand_path("../../spec/controllers/api/v2", __dir__)
    OUTPUT_PATH = File.expand_path("../../tmp/openapi/from_specs.yaml", __dir__)

    HTTP_VERBS = %i[get post patch put delete head].freeze

    STATUS_SYMBOL_MAP = {
      ok: 200, created: 201, accepted: 202, no_content: 204,
      moved_permanently: 301, found: 302, not_modified: 304,
      bad_request: 400, unauthorized: 401, payment_required: 402,
      forbidden: 403, not_found: 404, method_not_allowed: 405,
      not_acceptable: 406, conflict: 409, gone: 410,
      unprocessable_entity: 422, too_many_requests: 429,
      internal_server_error: 500, bad_gateway: 502,
      service_unavailable: 503, gateway_timeout: 504,
      success: 200
    }.freeze

    # Per-controller-action collector. Statuses keep their own field set
    # so success vs error response shapes don't bleed together.
    class ActionFacts
      attr_reader :controller, :http_method, :action,
                  :request_params, :statuses_seen, :status_data,
                  :notes

      def initialize(controller:, http_method:, action:)
        @controller = controller
        @http_method = http_method
        @action = action
        @request_params = {}
        @statuses_seen = Set.new
        @status_data = Hash.new do |h, k|
          h[k] = {
            fields: Hash.new do |fh, fk|
              fh[fk] = { facts: Set.new, values: Set.new, types: Set.new }
            end
          }
        end
        @notes = Set.new
      end

      def merge_request_params!(params)
        params.each { |k, v| @request_params[k.to_s] ||= v }
      end

      def serializable(val)
        case val
        when Symbol then val.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass then val
        else val.to_s
        end
      end

      def empty?
        @request_params.empty? && @statuses_seen.empty? && @notes.empty? &&
          @status_data.values.all? { |s| s[:fields].empty? }
      end

      def to_h
        statuses = {}
        all_statuses = @statuses_seen.dup
        all_statuses.merge(@status_data.keys)

        all_statuses.to_a.sort.each do |code|
          data = @status_data[code]
          required = []
          forbidden = []
          conditional = []
          observed_values = {}
          types = {}

          data[:fields].each do |path, info|
            facts = info[:facts]
            field_name = path.join(".")
            if facts.include?(:required) && facts.include?(:forbidden)
              conditional << field_name
            elsif facts.include?(:required)
              required << field_name
            elsif facts.include?(:forbidden)
              forbidden << field_name
            end

            unless info[:values].empty?
              observed_values[field_name] = info[:values].to_a.map { |v| serializable(v) }.sort_by(&:to_s).uniq
            end

            unless info[:types].empty?
              types[field_name] = info[:types].to_a.sort.join("|")
            end
          end

          status_entry = {}
          status_entry["required_fields"] = required.sort unless required.empty?
          status_entry["forbidden_fields"] = forbidden.sort unless forbidden.empty?
          unless conditional.empty?
            status_entry["conditional_presence_fields"] = conditional.sort
          end
          status_entry["observed_values"] = observed_values unless observed_values.empty?
          status_entry["types"] = types unless types.empty?
          statuses[code] = status_entry unless status_entry.empty?
        end

        # Keep status codes that were observed but had no fields
        @statuses_seen.each do |code|
          next if statuses.key?(code)
          statuses[code] = {}
        end

        out = {
          "http_method" => @http_method.to_s,
          "action" => @action.to_s,
          "controller" => @controller
        }
        out["statuses"] = statuses unless statuses.empty?
        out["request_params"] = @request_params unless @request_params.empty?
        out["notes"] = @notes.to_a.sort unless @notes.empty?
        out
      end
    end

    # A scope tracks the lexical bindings (ivars and `let` defs are not
    # supported beyond ivars) and the `it_behaves_like` shared examples.
    # We use it to resolve `@action` / `@params` references and to
    # carry an "implied" current-action when we descend into a
    # `describe "GET 'show'"` block.
    class Scope
      attr_accessor :controller, :ivars, :current_method, :current_action,
                    :current_status

      def initialize(parent = nil)
        @parent = parent
        @controller = parent&.controller
        @ivars = parent ? parent.ivars.dup : {}
        @current_method = parent&.current_method
        @current_action = parent&.current_action
        @current_status = parent&.current_status
      end

      def lookup_ivar(name)
        @ivars[name]
      end
    end

    class Visitor < Prism::Visitor
      attr_reader :endpoints

      def initialize
        @endpoints = {}
        @scope = Scope.new
        # Stack mirrors @scope chain — Prism Visitor doesn't accept a
        # block-form descent, so we manage scope stack manually around
        # describe/context calls.
        @scope_stack = [@scope]
      end

      def visit_call_node(node)
        # describe Api::V2::FooController do ... end (sets controller)
        # describe "GET 'show'" do ... end (sets method+action)
        # context "when ..." do ... end (just opens a sub-scope)
        if describe_or_context?(node)
          handle_describe_or_context(node)
          return
        end

        # `before { @action = :show; @params = {...} }` — visit normally,
        # but the ivar-write logic below picks them up.

        # Track ivar assignments inside before blocks.
        if assignment_to_ivar?(node)
          # nothing — handled by visit_instance_variable_write_node
        end

        # Capture http verb calls inside `it` blocks.
        if HTTP_VERBS.include?(node.name) && node.receiver.nil?
          record_http_call(node)
        end

        # Capture matcher chains: expect(...).to / .to_not / .not_to ...
        if %i[to to_not not_to].include?(node.name)
          record_assertion(node)
        end

        super
      end

      # @action = :show, @params = { foo: 1 }
      def visit_instance_variable_write_node(node)
        @scope.ivars[node.name] = node.value
        super
      end

      # @params.merge!(access_token: ...)
      def visit_call_node_for_merge_bang(_); end

      private

      def describe_or_context?(node)
        return false unless node.arguments
        %i[describe context].include?(node.name)
      end

      def handle_describe_or_context(node)
        push_scope
        first_arg = node.arguments.arguments.first

        case first_arg
        when Prism::ConstantPathNode, Prism::ConstantReadNode
          @scope.controller = constant_name(first_arg)
        when Prism::StringNode
          str = first_arg.unescaped
          if (m = str.match(/\A\s*(GET|POST|PATCH|PUT|DELETE|HEAD)\s+['"](\w+)['"]/i))
            @scope.current_method = m[1].downcase
            @scope.current_action = m[2]
          end
        end

        # Visit children with the new scope active.
        node.block&.body&.accept(self) if node.block
        node.arguments.arguments[1..]&.each { |a| a.accept(self) }
        pop_scope
      end

      def push_scope
        @scope = Scope.new(@scope)
        @scope_stack.push(@scope)
      end

      def pop_scope
        @scope_stack.pop
        @scope = @scope_stack.last
      end

      def assignment_to_ivar?(_node)
        false
      end

      # ------------------------------------------------------------------
      # HTTP verb call recording
      # ------------------------------------------------------------------

      def record_http_call(node)
        return unless node.arguments
        return unless @scope.controller

        args = node.arguments.arguments
        action_arg = args.first
        action_name = literal_action_name(action_arg) || @scope.current_action
        method_name = node.name.to_s
        method_name = @scope.current_method if @scope.current_method

        # If neither the call nor the surrounding describe pinned an
        # action we can't usefully attribute facts.
        return unless action_name

        endpoint = endpoint_for(@scope.controller, method_name, action_name)
        @scope.current_action ||= action_name
        @scope.current_method ||= method_name

        # Find the params: keyword. Could be a literal hash, an ivar
        # (@params), or @params.merge(...).
        params_value = extract_params_value(args)
        param_hashes = []
        if params_value
          param_hashes.concat(unwrap_merge_chain(params_value))
          # If the receiver in a merge chain bottoms out at @params, pull
          # in the recorded ivar value.
          ivar_root = ivar_root_of(params_value)
          if ivar_root
            ivar_val = @scope.lookup_ivar(ivar_root)
            param_hashes << ivar_val if ivar_val
          elsif params_value.is_a?(Prism::HashNode) || params_value.is_a?(Prism::KeywordHashNode)
            param_hashes << params_value
          end
        end

        params_collected = {}
        param_hashes.each do |h|
          next unless h.respond_to?(:elements)
          h.elements.each do |elem|
            next unless elem.is_a?(Prism::AssocNode)
            key = literal_symbol(elem.key) || string_to_sym(literal_value(elem.key))
            next unless key
            next if %i[access_token format].include?(key)
            params_collected[key] ||= infer_type(elem.value)
          end
        end

        endpoint.merge_request_params!(params_collected)
      end

      def literal_action_name(node)
        sym = literal_symbol(node)
        return sym.to_s if sym
        if node.is_a?(Prism::InstanceVariableReadNode)
          ivar = @scope.lookup_ivar(node.name)
          return literal_action_name(ivar) if ivar
        end
        if node.is_a?(Prism::StringNode)
          return node.unescaped
        end
        nil
      end

      def extract_params_value(args)
        kwh = args.grep(Prism::KeywordHashNode).first || args.grep(Prism::HashNode).first
        return nil unless kwh
        params_assoc = kwh.elements.find do |e|
          e.is_a?(Prism::AssocNode) && literal_symbol(e.key) == :params
        end
        params_assoc&.value
      end

      # Walks a `.merge(...).merge(...)` chain returning each appended hash.
      def unwrap_merge_chain(node)
        hashes = []
        cur = node
        while cur.is_a?(Prism::CallNode) && %i[merge merge!].include?(cur.name)
          arg = cur.arguments&.arguments&.first
          hashes << arg if arg.is_a?(Prism::HashNode) || arg.is_a?(Prism::KeywordHashNode)
          cur = cur.receiver
        end
        hashes
      end

      def ivar_root_of(node)
        cur = node
        while cur.is_a?(Prism::CallNode) && %i[merge merge!].include?(cur.name)
          cur = cur.receiver
        end
        cur.is_a?(Prism::InstanceVariableReadNode) ? cur.name : nil
      end

      # ------------------------------------------------------------------
      # Assertion recording
      # ------------------------------------------------------------------

      def record_assertion(matcher_call)
        receiver = matcher_call.receiver
        return unless receiver.is_a?(Prism::CallNode) && receiver.name == :expect
        return unless receiver.arguments
        subject = receiver.arguments.arguments.first
        matcher = matcher_call.arguments&.arguments&.first
        return unless matcher

        negated = matcher_call.name == :to_not || matcher_call.name == :not_to

        if subject_is_response_status?(subject)
          handle_response_status_assertion(subject, matcher, negated)
          return
        end

        if subject_is_response_or_response_status_or_code?(subject)
          handle_response_assertion(subject, matcher, negated)
          return
        end

        # parsed_body subject — expect(response.parsed_body[...]).to ...
        path = parsed_body_path(subject)
        return unless path

        endpoint = current_endpoint
        return unless endpoint

        status_code = current_status_code(matcher_call)
        endpoint.statuses_seen << status_code

        if path.empty?
          handle_top_level_parsed_body(endpoint, status_code, matcher, negated)
        else
          handle_nested_parsed_body(endpoint, status_code, path, matcher, negated)
        end
      end

      def subject_is_response_status?(node)
        # response.status / response.code / response.code.to_i
        return false unless node.is_a?(Prism::CallNode)
        if node.name == :to_i && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :code
          inner = node.receiver.receiver
          return inner.is_a?(Prism::CallNode) && inner.name == :response && inner.receiver.nil?
        end
        if %i[status code].include?(node.name)
          return node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :response && node.receiver.receiver.nil?
        end
        false
      end

      def subject_is_response_or_response_status_or_code?(node)
        node.is_a?(Prism::CallNode) && node.name == :response && node.receiver.nil?
      end

      def handle_response_status_assertion(_subject, matcher, _negated)
        endpoint = current_endpoint
        return unless endpoint
        return unless matcher.is_a?(Prism::CallNode)

        if matcher.name == :eq
          val = literal_value(matcher.arguments&.arguments&.first)
          if val.is_a?(Integer)
            endpoint.statuses_seen << val
          elsif val.is_a?(String) && val =~ /\A\d+\z/
            endpoint.statuses_seen << val.to_i
          end
        end
      end

      def handle_response_assertion(_subject, matcher, _negated)
        endpoint = current_endpoint
        return unless endpoint
        return unless matcher.is_a?(Prism::CallNode)

        case matcher.name
        when :have_http_status
          arg = matcher.arguments&.arguments&.first
          code = status_code_for(arg)
          endpoint.statuses_seen << code if code
        when :be_successful
          endpoint.statuses_seen << 200
        when :be_success
          endpoint.statuses_seen << 200
        end
      end

      def handle_top_level_parsed_body(endpoint, status_code, matcher, negated)
        return unless matcher.is_a?(Prism::CallNode)

        case matcher.name
        when :eq, :eql
          # expect(response.parsed_body).to eq({...}.as_json)
          target = matcher.arguments&.arguments&.first
          keys = extract_top_level_keys(target)
          if keys.empty? && target && !target.is_a?(Prism::HashNode) &&
             !target.is_a?(Prism::KeywordHashNode)
            note_runtime_body(endpoint, target)
          end
          keys.each do |key|
            mark_required(endpoint, status_code, [key])
          end
          extract_success_value(target).tap do |val|
            unless val.nil?
              endpoint.status_data[status_code][:fields][["success"]][:facts] << :required
              endpoint.status_data[status_code][:fields][["success"]][:values] << val
            end
          end
        when :include
          # expect(response.parsed_body).to include("a", "b")
          # expect(response.parsed_body).to include({ "success" => true })
          matcher.arguments&.arguments&.each do |a|
            if (k = literal_value(a))
              mark_required(endpoint, status_code, [k.to_s]) unless negated
            elsif a.is_a?(Prism::HashNode) || a.is_a?(Prism::KeywordHashNode)
              a.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode)
                k = literal_value(elem.key)
                next unless k
                key_path = [k.to_s]
                mark_required(endpoint, status_code, key_path) unless negated
                v = literal_value(elem.value)
                unless v.nil?
                  endpoint.status_data[status_code][:fields][key_path][:values] << v
                end
              end
            end
          end
        when :have_key
          k = literal_value(matcher.arguments&.arguments&.first)
          if k
            if negated
              mark_forbidden(endpoint, status_code, [k.to_s])
            else
              mark_required(endpoint, status_code, [k.to_s])
            end
          end
        end
      end

      def handle_nested_parsed_body(endpoint, status_code, path, matcher, negated)
        return unless matcher.is_a?(Prism::CallNode)
        field = endpoint.status_data[status_code][:fields][path]

        case matcher.name
        when :be_present
          if negated
            field[:facts] << :forbidden
          else
            field[:facts] << :required
          end
        when :be_nil
          if negated
            field[:facts] << :required
          else
            field[:facts] << :forbidden
          end
        when :be_blank
          # blank doesn't tell us much; skip
        when :eq, :eql, :equal
          arg = matcher.arguments&.arguments&.first
          if arg.is_a?(Prism::NilNode)
            # `eq nil` — the field is asserted absent/null. Treat as
            # forbidden in the non-negated case (the field's value is
            # null) and required when negated (`not_to eq nil`).
            if negated
              field[:facts] << :required
            else
              field[:facts] << :forbidden
            end
          else
            val = literal_value(arg)
            field[:facts] << :required unless negated
            field[:values] << val unless val.nil?
          end
        when :be_a, :be_kind_of, :be_an, :be_an_instance_of
          type = constant_name(matcher.arguments&.arguments&.first)
          if type
            field[:types] << type
            field[:facts] << :required unless negated
          end
        when :include
          # `include("foo", "bar")` is hash key inclusion when the subject
          # is a Hash, substring matching when the subject is a String.
          # We can't always tell statically. Heuristic: well-known string
          # fields (message, error, errors, reason) treat include as
          # substring. Otherwise, only descend if the arg looks like an
          # identifier.
          last_seg = path.last
          string_field = %w[message error reason].include?(last_seg)
          # Always mark the parent as required if not negated
          field[:facts] << :required unless negated
          unless string_field
            matcher.arguments&.arguments&.each do |a|
              k = literal_value(a)
              next unless k
              key_str = k.to_s
              next unless key_str.match?(/\A[A-Za-z_][A-Za-z0-9_\-]*\z/)
              child_path = path + [key_str]
              if negated
                mark_forbidden(endpoint, status_code, child_path)
              else
                mark_required(endpoint, status_code, child_path)
              end
            end
          end
        when :have_key
          k = literal_value(matcher.arguments&.arguments&.first)
          if k
            child_path = path + [k.to_s]
            if negated
              mark_forbidden(endpoint, status_code, child_path)
            else
              mark_required(endpoint, status_code, child_path)
            end
          end
        when :match_array, :contain_exactly
          field[:facts] << :required unless negated
          field[:types] << "Array"
        end
      end

      def mark_required(endpoint, status_code, path)
        endpoint.status_data[status_code][:fields][path][:facts] << :required
      end

      def mark_forbidden(endpoint, status_code, path)
        endpoint.status_data[status_code][:fields][path][:facts] << :forbidden
      end

      def note_runtime_body(endpoint, node)
        # Pluck a probable method name out of the rhs so the note hints
        # at the actual serializer being used.
        method_chain = collect_method_chain(node)
        if method_chain.empty?
          endpoint.notes << "expected body computed at runtime; static analysis blind"
        else
          endpoint.notes << "expected body computed at runtime via #{method_chain.last}; static analysis blind"
        end
      end

      def collect_method_chain(node)
        chain = []
        cur = node
        while cur.is_a?(Prism::CallNode)
          chain << cur.name
          cur = cur.receiver
        end
        chain
      end

      # response.parsed_body["user"]["email"] → ["user", "email"]
      # response.parsed_body                  → []
      # any non-parsed_body subject           → nil
      def parsed_body_path(node)
        path = []
        cur = node
        while cur.is_a?(Prism::CallNode) && cur.name == :[]
          key = literal_value(cur.arguments&.arguments&.first)
          return nil unless key
          path.unshift(key.to_s)
          cur = cur.receiver
        end
        return path if cur.is_a?(Prism::CallNode) && cur.name == :parsed_body
        nil
      end

      # Find or create the endpoint key for the current scope.
      def current_endpoint
        controller = @scope.controller
        action = @scope.current_action
        method = @scope.current_method
        return nil unless controller && action && method
        endpoint_for(controller, method, action)
      end

      def endpoint_for(controller, method, action)
        key = "#{controller}##{action}"
        @endpoints[key] ||= ActionFacts.new(
          controller: controller,
          http_method: method.to_s,
          action: action.to_s
        )
      end

      def current_status_code(_node)
        # Default: 200. Status codes from response assertions in the
        # same `it` block bump this. We'd need a smarter walker for
        # per-`it` scope tracking; for now we attribute fields to the
        # most recently observed status in the endpoint, falling back
        # to 200. The merger treats 200 as the canonical success
        # response shape.
        endpoint = current_endpoint
        return 200 unless endpoint
        @scope.current_status || 200
      end

      # ------------------------------------------------------------------
      # Hash literal extraction
      # ------------------------------------------------------------------

      # Walks `{ a: 1, b: 2 }.as_json` (or `JSON.parse(...)`) and returns
      # the top-level keys of the literal hash. Returns [] if the target
      # isn't a literal hash we can introspect.
      def extract_top_level_keys(node)
        h = unwrap_to_hash(node)
        return [] unless h
        h.elements.filter_map do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          k = literal_value(elem.key)
          k&.to_s
        end
      end

      def extract_success_value(node)
        h = unwrap_to_hash(node)
        return nil unless h
        h.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          k = literal_value(elem.key)
          next unless k.to_s == "success"
          v = literal_value(elem.value)
          return v unless v.nil?
        end
        nil
      end

      def unwrap_to_hash(node)
        cur = node
        loop do
          case cur
          when Prism::HashNode, Prism::KeywordHashNode
            return cur
          when Prism::CallNode
            if %i[as_json to_json with_indifferent_access deep_stringify_keys
                  deep_symbolize_keys stringify_keys symbolize_keys].include?(cur.name)
              cur = cur.receiver
            elsif cur.name == :parse && cur.receiver.is_a?(Prism::ConstantReadNode) && cur.receiver.name == :JSON
              cur = cur.arguments&.arguments&.first
            else
              return nil
            end
          else
            return nil
          end
        end
      end

      # ------------------------------------------------------------------
      # Generic helpers
      # ------------------------------------------------------------------

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          [constant_name(node.parent), constant_name(node.child)].compact.join("::")
        end
      end

      def literal_symbol(node)
        node.is_a?(Prism::SymbolNode) ? node.unescaped.to_sym : nil
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

      def string_to_sym(val)
        val.is_a?(String) ? val.to_sym : nil
      end

      def infer_type(node)
        case node
        when Prism::StringNode, Prism::InterpolatedStringNode then "string"
        when Prism::IntegerNode then "integer"
        when Prism::FloatNode then "number"
        when Prism::TrueNode, Prism::FalseNode then "boolean"
        when Prism::ArrayNode then "array"
        when Prism::HashNode, Prism::KeywordHashNode then "object"
        when Prism::SymbolNode then "string"
        when Prism::NilNode then "null"
        else "unknown"
        end
      end

      def status_code_for(node)
        sym = literal_symbol(node)
        return STATUS_SYMBOL_MAP[sym] if sym
        val = literal_value(node)
        return val if val.is_a?(Integer)
        nil
      end
    end

    # ------------------------------------------------------------------
    # Status-aware visitor wrapper
    # ------------------------------------------------------------------
    #
    # The basic visitor doesn't know which status code to attribute a
    # parsed_body assertion to. This pre-pass walks each `it` block and
    # tags the surrounding scope with the status code asserted within
    # that block (if any), so the inner assertion logic can pick it up.
    class StatusAwareVisitor < Visitor
      IT_LIKE = %i[it specify example focus fit xit].freeze

      def visit_call_node(node)
        if IT_LIKE.include?(node.name) && node.block
          status = scan_status_in_block(node.block)
          prev = @scope.current_status
          @scope.current_status = status if status
          super
          @scope.current_status = prev
          return
        end
        super
      end

      private

      def scan_status_in_block(block_node)
        finder = StatusFinder.new
        block_node.body&.accept(finder)
        finder.status
      end
    end

    # Inspects an `it` block body for an explicit status code. Returns
    # the first one it finds (or nil). When multiple statuses are
    # asserted in a single `it` block, the parsed_body assertions get
    # attributed to whichever was first (good enough for our use).
    class StatusFinder < Prism::Visitor
      attr_reader :status

      def initialize
        @status = nil
      end

      def visit_call_node(node)
        return if @status
        if node.name == :to || node.name == :to_not || node.name == :not_to
          matcher = node.arguments&.arguments&.first
          if matcher.is_a?(Prism::CallNode)
            receiver = node.receiver
            if receiver.is_a?(Prism::CallNode) && receiver.name == :expect
              subj = receiver.arguments&.arguments&.first

              if response_subject?(subj) && matcher.name == :have_http_status
                code = code_from_arg(matcher.arguments&.arguments&.first)
                @status = code if code
              elsif response_subject?(subj) && matcher.name == :be_successful
                @status = 200
              elsif response_status_subject?(subj) && matcher.name == :eq
                val = literal_value(matcher.arguments&.arguments&.first)
                if val.is_a?(Integer)
                  @status = val
                elsif val.is_a?(String) && val =~ /\A\d+\z/
                  @status = val.to_i
                end
              end
            end
          end
        end
        super
      end

      private

      def response_subject?(node)
        node.is_a?(Prism::CallNode) && node.name == :response && node.receiver.nil?
      end

      def response_status_subject?(node)
        return false unless node.is_a?(Prism::CallNode)
        if node.name == :to_i && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :code
          inner = node.receiver.receiver
          return inner.is_a?(Prism::CallNode) && inner.name == :response && inner.receiver.nil?
        end
        if %i[status code].include?(node.name)
          return node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :response && node.receiver.receiver.nil?
        end
        false
      end

      def code_from_arg(node)
        return nil unless node
        sym = node.is_a?(Prism::SymbolNode) ? node.unescaped.to_sym : nil
        return STATUS_SYMBOL_MAP[sym] if sym
        if node.is_a?(Prism::IntegerNode)
          return node.value
        end
        nil
      end

      def literal_value(node)
        case node
        when Prism::StringNode then node.unescaped
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::IntegerNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        end
      end
    end

    # ------------------------------------------------------------------
    # Driver
    # ------------------------------------------------------------------

    def self.run
      spec_files = Dir.glob(File.join(SPEC_DIR, "*_spec.rb")).sort
      visitor = StatusAwareVisitor.new

      spec_files.each do |path|
        source = File.read(path)
        result = Prism.parse(source)
        if result.failure?
          warn "[static_specs] parse failed for #{path}: #{result.errors.map(&:message).join(", ")}"
          next
        end
        result.value.accept(visitor)
      end

      endpoints = visitor.endpoints
        .reject { |_k, ep| ep.empty? }
        .sort_by { |k, _| k }
        .to_h

      output = {
        "generated_at" => Time.now.utc.iso8601,
        "source" => "spec/controllers/api/v2/*_spec.rb",
        "endpoints" => endpoints.transform_values(&:to_h)
      }

      FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
      File.write(OUTPUT_PATH, output.to_yaml)
      puts "Wrote #{endpoints.size} endpoints to #{OUTPUT_PATH}"
      endpoints
    end
  end
end

require "fileutils"
require "time"

if $PROGRAM_NAME == __FILE__
  OpenAPI::StaticSpecs.run
end
